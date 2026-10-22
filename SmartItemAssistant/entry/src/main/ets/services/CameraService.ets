import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class CameraService {
  private input?: camera.CameraInput;
  private preview?: camera.PreviewOutput;
  private output?: camera.PhotoOutput;
  private session?: camera.PhotoSession;
  private resolveCapture?: (value: string) => void;
  private rejectCapture?: (error: Error) => void;
  private capturePath: string = '';
  private timer: number = -1;
  async start(context: common.UIAbilityContext, surface: string, front: boolean): Promise<void> {
    await this.stop();
    const permission=await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context,['ohos.permission.CAMERA']);
    if(permission.authResults[0]!==0) throw new Error('相机权限未授权，可改用相册');
    const manager=camera.getCameraManager(context);
    const cameras=manager.getSupportedCameras();
    const device=cameras.find(c=>c.cameraPosition===(front?camera.CameraPosition.CAMERA_POSITION_FRONT:camera.CameraPosition.CAMERA_POSITION_BACK));
    if(!device) throw new Error(front?'当前设备没有前置摄像头':'当前设备没有后置摄像头');
    try {
      const capability=manager.getSupportedOutputCapability(device,camera.SceneMode.NORMAL_PHOTO);
      console.info(`SMARTITEM_CAMERA profiles=${JSON.stringify(capability)}`);
      const previews=capability.previewProfiles.filter(p=>p.size.width<=1920).sort((a,b)=>b.size.width-a.size.width);
      const photos=capability.photoProfiles.filter(p=>p.format===camera.CameraFormat.CAMERA_FORMAT_JPEG&&p.size.width*p.size.height<=64000000).sort((a,b)=>a.size.width-b.size.width);
      if(!previews.length)previews.push(...capability.previewProfiles.slice().sort((a,b)=>a.size.width-b.size.width));
      if(!previews.length) throw new Error('摄像头不支持预览输出');
      this.input=manager.createCameraInput(device);await this.input.open();
      this.preview=manager.createPreviewOutput(previews[0],surface);
      this.output=photos.length?manager.createPhotoOutput(photos[0]):manager.createPhotoOutput(capability.photoProfiles[0]);
      this.output.on('photoAvailable',async (error: BusinessError, photo: camera.Photo)=>{
        if(error) {this.finishError(new Error(`拍照失败 (${error.code})`));return;}
        try {
          if(!this.resolveCapture) return;
          const component=await photo.main.getComponent(image.ComponentType.JPEG);
          const file=fs.openSync(this.capturePath,fs.OpenMode.CREATE|fs.OpenMode.WRITE_ONLY|fs.OpenMode.TRUNC);
          try {fs.writeSync(file.fd,component.byteBuffer);} finally {fs.closeSync(file);}
          const done=this.resolveCapture;this.clearCapture();done(this.capturePath);
        } catch(e) {this.finishError(new Error(String(e)));}
        finally {await photo.release();}
      });
      this.session=manager.createSession<camera.PhotoSession>(camera.SceneMode.NORMAL_PHOTO);
      this.session.beginConfig();this.session.addInput(this.input);this.session.addOutput(this.preview);this.session.addOutput(this.output);
      await this.session.commitConfig();await this.session.start();
    } catch(error) {await this.stop();throw new Error(String(error));}
  }
  private clearCapture(): void {if(this.timer>=0) clearTimeout(this.timer);this.timer=-1;this.resolveCapture=undefined;this.rejectCapture=undefined;}
  private finishError(error: Error): void {const reject=this.rejectCapture;this.clearCapture();if(reject) reject(error);}
  capture(path: string): Promise<string> {
    if(!this.output||this.resolveCapture) return Promise.reject(new Error('相机未就绪或正在拍摄'));
    this.capturePath=path;
    return new Promise<string>((resolve,reject)=>{
      this.resolveCapture=resolve;this.rejectCapture=reject;
      this.timer=setTimeout(()=>this.finishError(new Error('拍照超时，请重试')),15000);
      this.output!.capture({quality:camera.QualityLevel.QUALITY_LEVEL_HIGH,rotation:camera.ImageRotation.ROTATION_0}).catch((e: BusinessError)=>this.finishError(new Error(`拍照失败 (${e.code})`)));
    });
  }
  async stop(): Promise<void> {
    this.finishError(new Error('相机会话已关闭'));
    if(this.session) {try{await this.session.stop();}catch(_){} try{await this.session.release();}catch(_){} this.session=undefined;}
    if(this.preview) {try{await this.preview.release();}catch(_){} this.preview=undefined;}
    if(this.output) {try{await this.output.release();}catch(_){} this.output=undefined;}
    if(this.input) {try{await this.input.close();}catch(_){} this.input=undefined;}
  }
}
