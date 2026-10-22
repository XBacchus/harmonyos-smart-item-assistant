import { common } from '@kit.AbilityKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util, taskpool } from '@kit.ArkTS';

@Concurrent
export async function normalizeImage(uri: string, output: string): Promise<string> {
  const file=fs.openSync(uri,fs.OpenMode.READ_ONLY);
  let source: image.ImageSource|undefined;
  let pixels: image.PixelMap|undefined;
  const packer=image.createImagePacker();
  try {
    if(fs.statSync(file.fd).size>30*1024*1024) throw new Error('图片文件超过 30 MB');
    source=image.createImageSource(file.fd);
    const info=await source.getImageInfo();
    if(info.size.width*info.size.height>64000000) throw new Error('图片超过 6400 万像素');
    const ratio=Math.min(1,1600/Math.max(info.size.width,info.size.height));
    pixels=await source.createPixelMap({editable:true,desiredSize:{width:Math.max(1,Math.round(info.size.width*ratio)),height:Math.max(1,Math.round(info.size.height*ratio))},desiredPixelFormat:image.PixelMapFormat.RGBA_8888});
    let orientation=1;
    try {
      const value=await source.getImageProperty(image.PropertyKey.ORIENTATION);
      const names=['Top-left','Top-right','Bottom-right','Bottom-left','Left-top','Right-top','Right-bottom','Left-bottom'];
      orientation=names.indexOf(value)+1 || parseInt(value) || 1;
    } catch (_) {}
    if(orientation===2) pixels.flipSync(true,false);
    else if(orientation===3) pixels.rotateSync(180);
    else if(orientation===4) pixels.flipSync(false,true);
    else if(orientation===5) {pixels.flipSync(true,false);pixels.rotateSync(270);}
    else if(orientation===6) pixels.rotateSync(90);
    else if(orientation===7) {pixels.flipSync(true,false);pixels.rotateSync(90);}
    else if(orientation===8) pixels.rotateSync(270);
    const bytes=await packer.packing(pixels,{format:'image/jpeg',quality:94});
    const dest=fs.openSync(output,fs.OpenMode.CREATE|fs.OpenMode.WRITE_ONLY|fs.OpenMode.TRUNC);
    try {fs.writeSync(dest.fd,bytes);fs.fsyncSync(dest.fd);} finally {fs.closeSync(dest);}
    return output;
  } finally {packer.release();if(pixels) await pixels.release();if(source) source.release();fs.closeSync(file);}
}
export async function importImage(context: common.UIAbilityContext, uri: string): Promise<string> {
  const path=`${context.filesDir}/image-${util.generateRandomUUID(true)}.jpg`;
  return await taskpool.execute(new taskpool.Task(normalizeImage,uri,path)) as string;
}
export async function thumbnail(path: string): Promise<Uint8Array> {
  const file=fs.openSync(path,fs.OpenMode.READ_ONLY);
  const source=image.createImageSource(file.fd);
  const packer=image.createImagePacker();
  let pixels: image.PixelMap|undefined;
  try {
    const info=await source.getImageInfo();
    const ratio=Math.min(1,240/Math.max(info.size.width,info.size.height));
    pixels=await source.createPixelMap({desiredSize:{width:Math.max(1,Math.round(info.size.width*ratio)),height:Math.max(1,Math.round(info.size.height*ratio))}});
    return new Uint8Array(await packer.packing(pixels,{format:'image/jpeg',quality:70}));
  } finally {if(pixels) await pixels.release();packer.release();source.release();fs.closeSync(file);}
}
