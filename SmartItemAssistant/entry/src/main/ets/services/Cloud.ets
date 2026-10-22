import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Records, RecordPayload } from '../data/Records';
import { errorMessage } from './Errors';

export interface DeviceConfig {deviceId: string; deviceSecret: string; baseUrl: string;}
interface TokenReply {accessToken: string; expiresAt: number;}
interface BatchReply {results: Ack[];}
interface Ack {recordId: string; acceptedRevision: number; status: string; error: string;}
interface BatchBody {records: RecordPayload[];}
export interface CloudPage {items: RecordPayload[]; total: number; page: number; pageSize: number;}
export interface ClassCount {classId: number; count: number;}
export interface CloudStats {recordCount: number; itemCount: number; byClass: ClassCount[];}
export class ApiError extends Error {
  status: number;
  retryAfter: number;
  constructor(status: number, delay: number = 0) {super(`服务请求失败 (${status})`);this.status=status;this.retryAfter=delay;}
}
export class Cloud {
  config: DeviceConfig = {deviceId:'',deviceSecret:'',baseUrl:'http://127.0.0.1:8765'};
  private prefs?: preferences.Preferences;
  private token: string = '';
  private expires: number = 0;
  private refreshing?: Promise<void>;
  private syncing: boolean = false;
  async initialize(context: common.UIAbilityContext): Promise<void> {
    this.prefs=await preferences.getPreferences(context,{name:'cloud'});
    const stored=await this.prefs.get('config','') as string;
    if(stored) this.config=JSON.parse(stored) as DeviceConfig;
    else {this.config.deviceId=util.generateRandomUUID(true);await this.configure(this.config);}
  }
  async configure(config: DeviceConfig): Promise<void> {
    if(!/^https:\/\/[^/]+$/.test(config.baseUrl) && !/^http:\/\/127\.0\.0\.1:\d+$/.test(config.baseUrl)) throw new Error('远程服务须使用 HTTPS；本机调试仅支持 127.0.0.1');
    if(!/^[a-fA-F0-9-]{36}$/.test(config.deviceId)) throw new Error('设备 ID 必须为 UUID');
    this.config={deviceId:config.deviceId,deviceSecret:config.deviceSecret,baseUrl:config.baseUrl};
    this.token='';this.expires=0;
    await this.prefs!.put('config',JSON.stringify(this.config));await this.prefs!.flush();
  }
  private async refresh(): Promise<void> {
    if(this.refreshing) return this.refreshing;
    this.refreshing=this.fetchToken();
    try {await this.refreshing;} finally {this.refreshing=undefined;}
  }
  private async fetchToken(): Promise<void> {
    if(!this.config.deviceSecret) throw new Error('请先配置已登记的设备凭据');
    const req=http.createHttp();
    try {
      const reply=await req.request(`${this.config.baseUrl}/api/v1/auth/token`,{method:http.RequestMethod.POST,header:{'Content-Type':'application/json'},extraData:JSON.stringify({deviceId:this.config.deviceId,deviceSecret:this.config.deviceSecret}),expectDataType:http.HttpDataType.STRING,connectTimeout:8000,readTimeout:15000,usingProxy:false});
      if(reply.responseCode!==200) throw new ApiError(reply.responseCode);
      const token=JSON.parse(reply.result as string) as TokenReply;
      this.token=token.accessToken;this.expires=token.expiresAt;
    } finally {req.destroy();}
  }
  async request(path: string, body: string = '', binary: boolean = false): Promise<string|ArrayBuffer> {
    if(!path.startsWith('/api/v1/') || path.includes('..')) throw new Error('无效接口地址');
    if(!this.token || this.expires<Date.now()/1000+30) await this.refresh();
    for(let attempt=0;attempt<2;attempt++) {
      const tokenUsed=this.token;
      const req=http.createHttp();
      try {
        const reply=await req.request(`${this.config.baseUrl}${path}`,{method:body?http.RequestMethod.POST:http.RequestMethod.GET,header:{'Content-Type':'application/json','Authorization':`Bearer ${tokenUsed}`},extraData:body,expectDataType:binary?http.HttpDataType.ARRAY_BUFFER:http.HttpDataType.STRING,connectTimeout:8000,readTimeout:30000,maxLimit:32*1024*1024,usingProxy:false});
        if(reply.responseCode===401 && attempt===0) {
          if(this.token===tokenUsed) await this.refresh();
          continue;
        }
        if(reply.responseCode!==200) {
          const headers=reply.header as Record<string,string>;
          const raw=headers['retry-after']||headers['Retry-After']||'0';
          const seconds=Number(raw);
          const delay=Number.isFinite(seconds)?Math.max(0,seconds*1000):Math.max(0,Date.parse(raw)-Date.now());
          throw new ApiError(reply.responseCode,Number.isFinite(delay)?Math.min(delay,3600000):0);
        }
        return reply.result as string|ArrayBuffer;
      } finally {req.destroy();}
    }
    throw new ApiError(401);
  }
  async sync(records: Records, force: boolean = false): Promise<string> {
    if(this.syncing) return '正在同步';
    if(!this.config.deviceSecret) return '离线模式 · 未配置云端';
    this.syncing=true;
    try {
      const pending=await records.pending(force);
      if(!pending.length) return await records.queueStatus();
      try {
        const body: BatchBody={records:pending.map(p=>JSON.parse(p.payload) as RecordPayload)};
        const reply=JSON.parse(await this.request('/api/v1/records/batch',JSON.stringify(body)) as string) as BatchReply;
        for(let i=0;i<pending.length;i++) {
          const item=pending[i];
          const ack=reply.results[i];
          if(ack && ack.recordId===item.recordId && ['accepted','duplicate','stale'].includes(ack.status) && ack.acceptedRevision>=item.revision) await records.acknowledge(item,ack.acceptedRevision);
          else await records.retry(item,ack?.error || '响应不完整',ack?.status==='invalid'||ack?.status==='conflict');
        }
      } catch(error) {
        const api=error as ApiError;
        const permanent=api.status===400||api.status===422||api.status===413;
        const message=api.status?errorMessage(api as Error):'连接不可用，记录已排队，稍后自动重试';
        for(const item of pending) await records.retry(item,message,permanent,api.retryAfter||0);
        throw new Error(message);
      }
      return await records.queueStatus();
    } finally {this.syncing=false;}
  }
}
