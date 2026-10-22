import { common } from '@kit.AbilityKit';
import { taskpool, util } from '@kit.ArkTS';
import { fileIo as fs, picker, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { connection } from '@kit.NetworkKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import { detectImage, DetectionResult } from '../inference/DetectionWorker';
import { LABELS, Detection } from '../inference/Vision';
import { Records, LocalRecord, RecordPayload } from '../data/Records';
import { Cloud, DeviceConfig, CloudPage, CloudStats } from '../services/Cloud';
import { Models } from '../services/Models';
import { importImage, thumbnail } from '../services/ImageFiles';
import { CameraService } from '../services/CameraService';
import BuildProfile from 'BuildProfile';
import { errorMessage } from '../services/Errors';

interface Benchmark {mode: string; iteration: number; totalMs: number; inferenceMs: number; heartbeatDelayMs: number;}

@Entry
@Component
struct Index {
  @State tab: number = 0;
  @State ready: boolean = false;
  @State busy: boolean = false;
  @State status: string = '正在准备离线模型';
  @State syncStatus: string = '离线可用';
  @State picture: string = '';
  @State items: Detection[] = [];
  @State confidence: number = 0.25;
  @State result?: DetectionResult = undefined;
  @State saved: boolean = false;
  @State history: LocalRecord[] = [];
  @State cloudRows: RecordPayload[] = [];
  @State cloudTotal: number = 0;
  @State cloudPage: number = 1;
  @State cloudSummary: string = '';
  @State filterClass: number = -1;
  @State dateFrom: string = '';
  @State dateTo: string = '';
  @State baseUrl: string = 'http://127.0.0.1:8765';
  @State deviceId: string = '';
  @State deviceSecret: string = '';
  @State modelVersion: string = '';
  @State cameraVisible: boolean = false;
  @State cameraReady: boolean = false;
  @State cameraStarting: boolean = false;
  @State front: boolean = false;
  @State performance: string = '';
  @StorageLink('foreground') @Watch('foregroundChanged') foreground: boolean = true;
  private records: Records = new Records();
  private cloud: Cloud = new Cloud();
  private models: Models = new Models();
  private camera: CameraService = new CameraService();
  private surface: XComponentController = new XComponentController();
  private canvas: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private scroller: Scroller = new Scroller();
  private current?: RecordPayload;
  private timer: number = -1;
  private network?: connection.NetConnection;
  private canvasW: number = 0;
  private readonly canvasH: number = 300;
  private active: boolean = true;
  private host?: common.UIAbilityContext;
  async aboutToAppear(): Promise<void> {
    try {
      const host=this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.host=host;
      console.info(`SMARTITEM_INIT context=${host.filesDir}`);
      await this.records.initialize(host);console.info('SMARTITEM_INIT rdb');
      await this.cloud.initialize(host);console.info('SMARTITEM_INIT cloud');
      await this.models.initialize(host);console.info('SMARTITEM_INIT model');
      this.modelVersion=this.models.version;this.loadConfig();
      const demo=`${this.host!.filesDir}/demo-bus.jpg`;
      if(!fs.accessSync(demo)) {
        const bytes=await this.host!.resourceManager.getRawFileContent('demo-bus.jpg');
        const file=fs.openSync(demo,fs.OpenMode.CREATE|fs.OpenMode.WRITE_ONLY);
        try{fs.writeSync(file.fd,bytes.buffer);}finally{fs.closeSync(file);}
      }
      this.picture=demo;this.ready=true;this.status='选择照片，或识别当前示例';
      this.timer=setInterval(()=>{if(this.foreground) this.sync(false);},15000);
      this.network=connection.createNetConnection();
      this.network.on('netAvailable',()=>this.sync(false));
      this.network.register(()=>{});
      this.sync(false);
      if(this.cloud.config.deviceSecret) this.updateModel(false);
    } catch(error) {this.status=`初始化失败：${String(error)}`;}
  }
  aboutToDisappear(): void {
    this.active=false;if(this.timer>=0)clearInterval(this.timer);this.camera.stop();
    if(this.network)this.network.unregister(()=>{});
  }
  foregroundChanged(): void {
    if(!this.foreground) {this.camera.stop();this.cameraReady=false;this.cameraVisible=false;}
    else if(this.ready)this.sync(false);
  }
  loadConfig(): void {this.baseUrl=this.cloud.config.baseUrl;this.deviceId=this.cloud.config.deviceId;this.deviceSecret=this.cloud.config.deviceSecret;}
  async sync(force: boolean): Promise<void> {
    if(!this.ready)return;
    try {this.syncStatus=await this.cloud.sync(this.records,force);}
    catch(error) {this.syncStatus=`等待重试 · ${String(error)}`;}
  }
  async choose(): Promise<void> {
    if(this.busy)return;
    try {
      const selected=await new photoAccessHelper.PhotoViewPicker().select({MIMEType:photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,maxSelectNumber:1});
      if(!selected.photoUris.length)return;
      this.busy=true;this.status='正在准备图片';
      this.resetImage(await importImage(this.host!,selected.photoUris[0]));
    }catch(error){this.status=String(error);}finally{this.busy=false;}
  }
  resetImage(path: string): void {this.picture=path;this.items=[];this.result=undefined;this.current=undefined;this.saved=false;this.status='图片已就绪';this.draw();}
  async exportSample(): Promise<void> {
    if(!BuildProfile.DEBUG||this.busy)return;
    this.busy=true;
    const helper=photoAccessHelper.getPhotoAccessHelper(this.host!);
    try {
      const path=`${this.host!.filesDir}/demo-bus.jpg`;
      const configs: photoAccessHelper.PhotoCreationConfig[]=[{title:'智能识物相册验收',fileNameExtension:'jpg',photoType:photoAccessHelper.PhotoType.IMAGE}];
      const uris=await helper.showAssetsCreationDialog([fileUri.getUriFromPath(path)],configs);
      if(!uris.length){this.status='已取消保存示例';return;}
      const input=fs.openSync(path,fs.OpenMode.READ_ONLY);
      try {
        const output=fs.openSync(uris[0],fs.OpenMode.WRITE_ONLY);
        try {fs.copyFileSync(input.fd,output.fd);} finally {fs.closeSync(output);}
      } finally {fs.closeSync(input);}
      this.status='示例已存入系统相册，可从相册入口选择';
    } catch(error){this.status=errorMessage(error as Error);} finally {helper.release();this.busy=false;}
  }
  async cameraStart(): Promise<void> {
    if(this.cameraStarting)return;
    this.cameraStarting=true;
    this.cameraReady=false;
    try {await this.camera.start(this.host!,this.surface.getXComponentSurfaceId(),this.front);this.cameraReady=true;this.status=this.front?'前置摄像头':'后置摄像头';}
    catch(error){this.status=String(error);}
    finally{this.cameraStarting=false;if(!this.cameraVisible||!this.foreground){await this.camera.stop();this.cameraReady=false;}}
  }
  async capture(): Promise<void> {
    if(this.busy||!this.cameraReady)return;
    this.busy=true;
    try {
      const raw=await this.camera.capture(`${this.host!.cacheDir}/capture.jpg`);
      const path=await importImage(this.host!,raw);
      await this.camera.stop();this.cameraVisible=false;this.resetImage(path);
    }catch(error){this.status=String(error);}finally{this.busy=false;}
  }
  async detect(): Promise<void> {
    if(this.busy||!this.ready)return;
    this.busy=true;this.status='正在识别，界面仍可响应';
    const threshold=this.confidence;
    try {
      const text=await taskpool.execute(new taskpool.Task(detectImage,this.picture,this.models.path,threshold,0.45)) as string;
      if(!this.active)return;
      this.result=JSON.parse(text) as DetectionResult;this.items=this.result.detections;
      this.current=this.records.make(this.result,this.models.version,threshold);this.saved=false;
      this.status=this.items.length?`发现 ${this.items.length} 件物品`:'未发现符合阈值的物品，可降低阈值重试';
      this.draw();console.info(`SMARTITEM_RESULT ${text}`);
    }catch(error){this.status=`识别失败：${String(error)}`;console.error(`SMARTITEM_ERROR ${String(error)}`);}
    finally{this.busy=false;}
  }
  draw(): void {
    this.canvas.clearRect(0,0,this.canvasW,this.canvasH);
    if(!this.result||!this.canvasW)return;
    const ratio=Math.min(this.canvasW/this.result.width,this.canvasH/this.result.height);
    const ox=(this.canvasW-this.result.width*ratio)/2,oy=(this.canvasH-this.result.height*ratio)/2;
    this.canvas.strokeStyle='#6EE7B7';this.canvas.lineWidth=2;this.canvas.font='bold 11vp sans-serif';
    for(const d of this.items) {
      if(d.deleted)continue;
      const x=ox+d.x1*ratio,y=oy+d.y1*ratio;
      this.canvas.strokeRect(x,y,(d.x2-d.x1)*ratio,(d.y2-d.y1)*ratio);
      const label=`${LABELS[d.classId]} ${(d.confidence*100).toFixed(0)}%`;
      const width=this.canvas.measureText(label).width+8;
      const labelY=Math.max(0,y-18),labelX=Math.max(0,Math.min(x,this.canvasW-width));
      this.canvas.fillStyle='#083F35';this.canvas.fillRect(labelX,labelY,width,18);
      this.canvas.fillStyle='#FFFFFF';this.canvas.fillText(label,labelX+4,labelY+13);
    }
  }
  async edit(id: string, classId: number, deleted: boolean): Promise<void> {
    if(!this.current||this.busy)return;
    const updated=JSON.parse(JSON.stringify(this.current)) as RecordPayload;
    const d=updated.detections.find(item=>item.id===id);if(!d)return;
    this.busy=true;
    d.classId=classId;d.deleted=deleted;d.edited=true;
    updated.updatedAt=new Date().toISOString();
    try {
      if(this.saved){updated.revision++;await this.records.save(updated,this.picture,await thumbnail(this.picture));}
      this.current=updated;this.items=updated.detections;this.draw();this.status=this.saved?'修改已保存，等待同步':'修改已应用，请保存记录';
      if(this.saved)this.sync(false);
    }catch(error){this.status=`保存修改失败：${String(error)}`;}finally{this.busy=false;}
  }
  async save(): Promise<void> {
    if(!this.current||this.saved||this.busy)return;
    this.busy=true;
    try {await this.records.save(this.current,this.picture,await thumbnail(this.picture));this.saved=true;this.status='已保存到本地';this.sync(false);}
    catch(error){this.status=`保存失败：${String(error)}`;}finally{this.busy=false;}
  }
  counts(detections: Detection[]): string {
    const counts: number[]=new Array<number>(80).fill(0);detections.forEach(d=>{if(!d.deleted)counts[d.classId]++;});
    return counts.map((n,i)=>n?`${LABELS[i]} ${n}`:'').filter(s=>s.length>0).join(' · ')||'无有效物品';
  }
  range(): string[] {
    const values=[this.dateFrom,this.dateTo].map(s=>s.trim()?new Date(`${s.trim()}T00:00:00+08:00`).toISOString():'');
    if(values[0]&&values[1]&&values[0]>=values[1])throw new Error('开始日期须早于结束日期');
    return values;
  }
  async queryLocal(): Promise<void> {
    try{const range=this.range();this.history=await this.records.list(range[0],range[1],this.filterClass);this.status=`本地 ${this.history.length} 条记录（最多显示 200 条）`;}
    catch(error){this.status=String(error);}
  }
  async queryCloud(page: number = 1): Promise<void> {
    try {
      const range=this.range();let params='';
      if(range[0])params+=`&from=${encodeURIComponent(range[0])}`;
      if(range[1])params+=`&to=${encodeURIComponent(range[1])}`;
      if(this.filterClass>=0)params+=`&classId=${this.filterClass}`;
      const result=JSON.parse(await this.cloud.request(`/api/v1/records?page=${page}&pageSize=10${params}`) as string) as CloudPage;
      const stats=JSON.parse(await this.cloud.request(`/api/v1/stats?${params.slice(1)}`) as string) as CloudStats;
      this.cloudRows=result.items;this.cloudTotal=result.total;this.cloudPage=page;
      this.cloudSummary=`${stats.recordCount} 条记录 · ${stats.itemCount} 件物品\n${stats.byClass.map(c=>`${LABELS[c.classId]} ${c.count}`).join(' · ')}`;
      this.status='云端数据已更新';
    }catch(error){this.status=String(error);}
  }
  openRecord(record: LocalRecord): void {
    if(this.busy)return;
    this.current=record.payload;this.picture=record.imagePath;this.items=record.payload.detections;
    const p=record.payload;
    this.result={detections:p.detections,width:p.width,height:p.height,preprocessMs:p.timings.preprocessMs,inferenceMs:p.timings.inferenceMs,postprocessMs:p.timings.postprocessMs,loadMs:p.timings.loadMs,totalMs:p.timings.totalMs,runtime:''};
    this.confidence=p.confidenceThreshold;this.saved=true;this.tab=0;this.status=`本地记录 · 第 ${p.revision} 版`;setTimeout(()=>{this.scroller.scrollTo({xOffset:0,yOffset:0});this.draw();},100);
  }
  async configure(): Promise<void> {
    try{await this.cloud.configure({deviceId:this.deviceId,deviceSecret:this.deviceSecret,baseUrl:this.baseUrl});this.status='配置已保存';await this.records.resetFailed();this.sync(true);}
    catch(error){this.status=String(error);}
  }
  async importConfig(debug: boolean = false): Promise<void> {
    try {
      let path=`${this.host!.filesDir}/device-credentials.json`;
      if(!debug){const paths=await new picker.DocumentViewPicker(this.host!).select({maxSelectNumber:1});if(!paths.length)return;path=paths[0];}
      else if(!BuildProfile.DEBUG) return;
      const file=fs.openSync(path,fs.OpenMode.READ_ONLY);
      let value='';
      try {if(fs.statSync(file.fd).size>4096)throw new Error('配置文件过大');value=fs.readTextSync(path);}finally{fs.closeSync(file);}
      const config=JSON.parse(value) as DeviceConfig;
      await this.cloud.configure(config);this.loadConfig();this.status='设备配置已导入';this.sync(true);
    }catch(error){this.status=`导入失败：${String(error)}`;}
  }
  async updateModel(rollback: boolean): Promise<void> {
    if(this.busy||!this.ready)return;
    this.busy=true;
    try{this.status=rollback?await this.models.rollback():await this.models.update(this.cloud);this.modelVersion=this.models.version;}
    catch(error){this.status=`模型保持原版本：${String(error)}`;}finally{this.busy=false;}
  }
  async benchmark(): Promise<void> {
    if(this.busy||!this.ready)return;
    this.busy=true;this.performance='对比测试中，请保持应用在前台';
    const results: Benchmark[]=[];
    try {
      await taskpool.execute(new taskpool.Task(detectImage,this.picture,this.models.path,this.confidence,0.45));
      for(const mode of ['同步','TaskPool']) {
        for(let iteration=1;iteration<=3;iteration++) {
          let last=systemDateTime.getUptime(systemDateTime.TimeType.STARTUP),delay=0;
          const timer=setInterval(()=>{const now=systemDateTime.getUptime(systemDateTime.TimeType.STARTUP);delay=Math.max(delay,now-last-16);last=now;},16);
          try {
            const text=mode==='同步'?await detectImage(this.picture,this.models.path,this.confidence,0.45):await taskpool.execute(new taskpool.Task(detectImage,this.picture,this.models.path,this.confidence,0.45)) as string;
            await new Promise<void>(resolve=>setTimeout(resolve,40));
            const r=JSON.parse(text) as DetectionResult;results.push({mode,iteration,totalMs:r.totalMs,inferenceMs:r.inferenceMs,heartbeatDelayMs:delay});
          }finally{clearInterval(timer);}
          await new Promise<void>(resolve=>setTimeout(resolve,100));
        }
      }
      this.performance=results.map(r=>`${r.mode} #${r.iteration}：${r.totalMs} ms，心跳延迟 ${r.heartbeatDelayMs} ms`).join('\n');
      const file=fs.openSync(`${this.host!.filesDir}/benchmark.json`,fs.OpenMode.CREATE|fs.OpenMode.WRITE_ONLY|fs.OpenMode.TRUNC);
      try{fs.writeSync(file.fd,JSON.stringify(results));}finally{fs.closeSync(file);}
      console.info(`SMARTITEM_BENCHMARK ${JSON.stringify(results)}`);
    }catch(error){this.performance=String(error);}finally{this.busy=false;}
  }
  @Builder filters() {
    Column({space:8}) {
      Row({space:8}) {
        TextInput({placeholder:'开始 YYYY-MM-DD',text:this.dateFrom}).layoutWeight(1).onChange(v=>this.dateFrom=v)
        TextInput({placeholder:'结束（不含）',text:this.dateTo}).layoutWeight(1).onChange(v=>this.dateTo=v)
      }
      Select([{value:'所有类别'},...LABELS.map((label:string):SelectOption=>({value:label}))]).value(this.filterClass<0?'所有类别':LABELS[this.filterClass]).onSelect(index=>this.filterClass=index-1).width('100%')
    }
  }
  @Builder recognition() {
    Column({space:12}) {
      Row({space:8}) {
        Button('拍照').backgroundColor('#E2EAE4').fontColor('#174E3E').id('cameraButton').onClick(()=>{this.cameraVisible=true;}).enabled(this.ready&&!this.busy)
        Button('相册').backgroundColor('#E2EAE4').fontColor('#174E3E').id('galleryButton').onClick(()=>this.choose()).enabled(this.ready&&!this.busy)
        Button('示例').backgroundColor('#E2EAE4').fontColor('#174E3E').onClick(()=>this.resetImage(`${this.host!.filesDir}/demo-bus.jpg`)).enabled(this.ready&&!this.busy)
      }.width('100%').justifyContent(FlexAlign.Start)
      if(this.cameraVisible) {
        Text(this.status).fontSize(13).width('100%')
        XComponent({id:'cameraPreview',type:XComponentType.SURFACE,controller:this.surface}).height(300).width('100%').onLoad(()=>this.cameraStart())
        Row({space:8}) {
          Button('拍摄').id('captureButton').enabled(this.cameraReady&&!this.busy).onClick(()=>this.capture())
          Button('切换镜头').enabled(!this.busy&&!this.cameraStarting).onClick(()=>{this.front=!this.front;this.cameraStart();})
          Button('关闭').onClick(()=>{this.camera.stop();this.cameraVisible=false;})
        }
      } else {
        Stack() {
          Image(`file://${this.picture}`).height(this.canvasH).width('100%').objectFit(ImageFit.Contain)
          Canvas(this.canvas).height(this.canvasH).width('100%').onReady(()=>this.draw()).onAreaChange((oldValue,newValue)=>{this.canvasW=Number(newValue.width);this.draw();})
        }.height(this.canvasH).width('100%').backgroundColor('#102722').borderRadius(14).clip(true)
      }
      Row() {Text('置信度阈值').fontSize(14);Blank();Text(`${Math.round(this.confidence*100)}%`).fontColor('#126C57')}.width('100%')
      Slider({value:this.confidence*100,min:5,max:95,step:5}).selectedColor('#126C57').enabled(!this.busy).onChange(v=>this.confidence=v/100)
      Row({space:10}) {
        Button(this.busy?'处理中…':'开始识别').id('detectButton').layoutWeight(1).backgroundColor('#126C57').enabled(this.ready&&!this.busy&&!this.cameraVisible).onClick(()=>this.detect())
        Button(this.saved?'已保存':'保存记录').backgroundColor('#E2EAE4').fontColor('#174E3E').id('saveButton').enabled(!!this.result&&!this.saved&&!this.busy).onClick(()=>this.save())
      }
      if(this.result&&!this.cameraVisible) {
        Text(this.counts(this.items)).fontSize(19).fontWeight(FontWeight.Medium).width('100%')
        Text(`预处理 ${this.result.preprocessMs.toFixed(0)} · 推理 ${this.result.inferenceMs.toFixed(0)} · 后处理 ${this.result.postprocessMs.toFixed(0)} ms`).fontSize(12).fontColor('#64716A').width('100%')
        ForEach(this.items,(d: Detection)=>{
          if(!d.deleted) {
            Row({space:8}) {
              Select(LABELS.map((label:string):SelectOption=>({value:label}))).id(`class-${d.id}`).value(LABELS[d.classId]).selected(d.classId).layoutWeight(1).enabled(!this.busy).onSelect(index=>this.edit(d.id,index,false))
              Text(`${(d.confidence*100).toFixed(1)}%`).fontSize(13)
              Button('删除',{type:ButtonType.Normal}).id(`delete-${d.id}`).fontSize(13).backgroundColor('#EDF1EE').fontColor('#39483F').onClick(()=>this.edit(d.id,d.classId,true))
            }.width('100%').padding({top:5,bottom:5})
          }
        },(d:Detection)=>`${d.id}-${d.classId}-${d.deleted}`)
      }
    }.width('100%')
  }
  @Builder localRecords() {
    Column({space:14}) {
      this.filters()
      Button('查询本地记录').id('localQuery').onClick(()=>this.queryLocal())
      ForEach(this.history,(record:LocalRecord)=>{
        Row({space:12}) {
          Image(`data:image/jpeg;base64,${new util.Base64Helper().encodeToStringSync(record.thumbnail)}`).width(64).height(70).objectFit(ImageFit.Contain).borderRadius(6)
          Column({space:4}) {
            Text(this.counts(record.payload.detections)).fontSize(16).width('100%')
            Text(new Date(record.payload.createdAt).toLocaleString()).fontSize(12).fontColor('#64716A').width('100%')
            Text(record.syncedRevision>=record.payload.revision?'已同步':`待同步 · 第 ${record.payload.revision} 版`).fontSize(12).fontColor('#126C57').width('100%')
          }.layoutWeight(1)
        }.width('100%').padding({top:12,bottom:12}).onClick(()=>this.openRecord(record))
        Divider().color('#DCE3DD')
      },(record:LocalRecord)=>`${record.payload.recordId}-${record.payload.revision}-${record.syncedRevision}`)
      if(!this.history.length){Text('暂无记录，先识别并保存一张图片。').fontColor('#64716A').margin({top:24})}
    }.width('100%')
  }
  @Builder cloudRecords() {
    Column({space:14}) {
      this.filters()
      Row({space:10}) {
        Button('立即同步').id('syncButton').onClick(()=>this.sync(true))
        Button('查询云端').id('cloudQuery').onClick(()=>this.queryCloud())
      }
      Text(this.cloudSummary||'配置设备凭据后可查询云端记录与统计。').fontSize(16).width('100%')
      ForEach(this.cloudRows,(record:RecordPayload)=>{
        Column({space:6}) {
          Text(this.counts(record.detections)).fontSize(17).width('100%')
          Text(`${new Date(record.createdAt).toLocaleString()} · v${record.revision}`).fontSize(12).fontColor('#64716A').width('100%')
        }.width('100%').padding({top:12,bottom:12})
        Divider()
      },(record:RecordPayload)=>`${record.recordId}-${record.revision}`)
      Row({space:10}) {
        Button('上一页').enabled(this.cloudPage>1).onClick(()=>this.queryCloud(this.cloudPage-1))
        Text(`${this.cloudPage} / ${Math.max(1,Math.ceil(this.cloudTotal/10))}`)
        Button('下一页').enabled(this.cloudPage*10<this.cloudTotal).onClick(()=>this.queryCloud(this.cloudPage+1))
      }
    }.width('100%')
  }
  @Builder settings() {
    Column({space:12}) {
      Text('云端连接').fontSize(21).fontWeight(FontWeight.Medium).width('100%')
      TextInput({placeholder:'服务地址',text:this.baseUrl}).id('baseUrl').onChange(v=>this.baseUrl=v)
      TextInput({placeholder:'设备 UUID',text:this.deviceId}).onChange(v=>this.deviceId=v)
      TextInput({placeholder:'设备密钥',text:this.deviceSecret}).type(InputType.Password).onChange(v=>this.deviceSecret=v)
      Row({space:8}) {Button('保存配置').onClick(()=>this.configure());Button('导入配置').onClick(()=>this.importConfig());}
      if(BuildProfile.DEBUG){Button('读取本机调试配置').id('debugConfig').fontSize(13).onClick(()=>this.importConfig(true))}
      if(BuildProfile.DEBUG){Button('保存示例到系统相册').id('debugGallery').fontSize(13).enabled(!this.busy).onClick(()=>this.exportSample())}
      Divider().margin({top:12,bottom:12})
      Text('离线模型').fontSize(21).fontWeight(FontWeight.Medium).width('100%')
      Text(this.modelVersion).fontColor('#64716A').fontSize(13).width('100%')
      Row({space:8}) {
        Button('检查更新').id('modelUpdate').enabled(!this.busy).onClick(()=>this.updateModel(false))
        Button('回退版本').id('modelRollback').enabled(!this.busy).onClick(()=>this.updateModel(true))
      }
      Divider().margin({top:12,bottom:12})
      Text('性能对比').fontSize(21).fontWeight(FontWeight.Medium).width('100%')
      Text('同图预热后各测 3 次。同步模式会短暂阻塞界面；心跳延迟不等于触摸延迟。').fontSize(13).fontColor('#64716A')
      Button(this.busy?'测试中…':'运行同步 / TaskPool 对比').id('benchmarkButton').enabled(!this.busy).onClick(()=>this.benchmark())
      Text(this.performance).fontSize(13).width('100%')
    }.width('100%')
  }
  build() {
    Column() {
      Row() {
        Column({space:3}) {
          Text(['识物助手','本地记录','云端记录','设置与实验'][this.tab]).fontSize(28).fontWeight(FontWeight.Bold).width('100%')
          Text(this.syncStatus).fontSize(11).fontColor('#64716A').maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis}).width('100%')
        }.layoutWeight(1)
        Text('离线识别').fontSize(12).fontColor('#126C57')
      }.width('100%').padding({left:22,right:22,top:16,bottom:16})
      Scroll(this.scroller) {
        Column({space:14}) {
          if(this.tab===0){this.recognition()}
          else if(this.tab===1){this.localRecords()}
          else if(this.tab===2){this.cloudRecords()}
          else{this.settings()}
          Text(this.status).id('statusText').fontSize(13).fontColor('#526059').width('100%').padding({top:8,bottom:16})
        }.padding({left:22,right:22}).width('100%')
      }.layoutWeight(1).width('100%').align(Alignment.Top)
      Row() {
        ForEach(['识别','本地','云端','设置'],(label:string,index:number)=>{
          Text(label).id(`tab${index}`).fontSize(15).fontWeight(this.tab===index?FontWeight.Bold:FontWeight.Normal).fontColor(this.tab===index?'#126C57':'#6A766E').textAlign(TextAlign.Center).layoutWeight(1).padding({top:18,bottom:20}).onClick(()=>{
            this.getUIContext().animateTo({duration:160},()=>{this.tab=index;});
            setTimeout(():void=>{this.scroller.scrollTo({xOffset:0,yOffset:0});},180);
            if(index!==0&&this.cameraVisible){this.camera.stop();this.cameraVisible=false;}
            if(index===1)this.queryLocal();
          })
        })
      }.width('100%').backgroundColor('#E9EFEB')
    }.height('100%').width('100%').backgroundColor('#F7F9F6').padding({top:8,bottom:8})
  }
}
