import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { taskpool } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';
import { validateModel } from '../inference/DetectionWorker';
import { Cloud } from './Cloud';

export interface ModelManifest {version: string; sha256: string; size: number; inputShape: number[]; outputShape: number[]; labelsVersion: string; downloadPath: string;}
interface ModelPointer {path: string; version: string;}
export class Models {
  path: string = '';
  version: string = 'yolov13n-coco-v1';
  private prefs?: preferences.Preferences;
  private context?: common.UIAbilityContext;
  private previous?: ModelPointer;
  async initialize(context: common.UIAbilityContext): Promise<void> {
    this.context=context;
    this.prefs=await preferences.getPreferences(context,{name:'models'});
    this.path=`${context.filesDir}/yolov13n.onnx`;
    if(!fs.accessSync(this.path)) {
      const raw=await context.resourceManager.getRawFileContent('yolov13n.onnx');
      const file=fs.openSync(this.path,fs.OpenMode.CREATE|fs.OpenMode.WRITE_ONLY);
      try {fs.writeSync(file.fd,raw.buffer);fs.fsyncSync(file.fd);} finally {fs.closeSync(file);}
    }
    const active=await this.prefs.get('active','') as string;
    const prior=await this.prefs.get('previous','') as string;
    if(prior) this.previous=JSON.parse(prior) as ModelPointer;
    if(active) {
      const pointer=JSON.parse(active) as ModelPointer;
      try {await taskpool.execute(new taskpool.Task(validateModel,pointer.path));this.path=pointer.path;this.version=pointer.version;}
      catch (_) {await this.prefs.delete('active');await this.prefs.flush();}
    }
  }
  async update(cloud: Cloud): Promise<string> {
    const manifest=JSON.parse(await cloud.request('/api/v1/models/latest') as string) as ModelManifest;
    if(manifest.version===this.version) return '当前已是最新模型';
    if(!/^[a-zA-Z0-9._-]{1,100}$/.test(manifest.version)||! /^[0-9a-f]{64}$/.test(manifest.sha256)||manifest.size<=0||manifest.size>30*1024*1024||manifest.inputShape.join(',')!=='1,3,640,640'||manifest.outputShape.join(',')!=='1,84,8400'||manifest.labelsVersion!=='coco80-v1') throw new Error('模型清单不兼容，保留当前版本');
    const bytes=await cloud.request(manifest.downloadPath,'',true) as ArrayBuffer;
    if(bytes.byteLength!==manifest.size) throw new Error('模型大小不符，保留当前版本');
    const md=cryptoFramework.createMd('SHA256');await md.update({data:new Uint8Array(bytes)});
    const digest=(await md.digest()).data;
    const hash=Array.from(digest).map((b:number)=>b.toString(16).padStart(2,'0')).join('');
    if(hash!==manifest.sha256) throw new Error('模型校验失败，保留当前版本');
    const path=`${this.context!.filesDir}/model-${manifest.sha256}-${manifest.version}.onnx`;
    const temporary=`${path}.pending`;
    const file=fs.openSync(temporary,fs.OpenMode.CREATE|fs.OpenMode.WRITE_ONLY|fs.OpenMode.TRUNC);
    try {fs.writeSync(file.fd,bytes);fs.fsyncSync(file.fd);} finally {fs.closeSync(file);}
    try {
      await taskpool.execute(new taskpool.Task(validateModel,temporary));
      fs.renameSync(temporary,path);
      const previous: ModelPointer={path:this.path,version:this.version};
      const next: ModelPointer={path,version:manifest.version};
      await this.prefs!.put('previous',JSON.stringify(previous));
      await this.prefs!.put('active',JSON.stringify(next));await this.prefs!.flush();
      this.previous=previous;this.path=path;this.version=manifest.version;
      return `已切换 ${this.version}`;
    } catch(error) {if(fs.accessSync(temporary)) fs.unlinkSync(temporary);throw new Error(String(error));}
  }
  async rollback(): Promise<string> {
    if(!this.previous) throw new Error('没有可回退版本');
    await taskpool.execute(new taskpool.Task(validateModel,this.previous.path));
    const old: ModelPointer={path:this.path,version:this.version};
    await this.prefs!.put('active',JSON.stringify(this.previous));await this.prefs!.put('previous',JSON.stringify(old));await this.prefs!.flush();
    this.path=this.previous.path;this.version=this.previous.version;this.previous=old;
    return `已回退 ${this.version}`;
  }
}
