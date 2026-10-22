import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import detector from 'libdetector.so';
import { Detection, letterbox, preprocess, postprocess } from './Vision';

export interface DetectionResult {
  detections: Detection[]; width: number; height: number; preprocessMs: number;
  inferenceMs: number; postprocessMs: number; loadMs: number; totalMs: number; runtime: string;
}
@Concurrent
export async function detectImage(path: string, modelPath: string, confidence: number, overlap: number): Promise<string> {
  const started = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP);
  const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
  let source: image.ImageSource | undefined;
  let pixels: image.PixelMap | undefined;
  try {
    source = image.createImageSource(file.fd);
    const info = await source.getImageInfo();
    if (info.size.width*info.size.height > 16000000) throw new Error('图片超过 1600 万像素，请先缩小');
    pixels = await source.createPixelMap({desiredPixelFormat:image.PixelMapFormat.RGBA_8888});
    const buffer = new ArrayBuffer(pixels.getPixelBytesNumber());
    await pixels.readPixelsToBuffer(buffer);
    const box = letterbox(info.size.width, info.size.height);
    const input = preprocess(new Uint8Array(buffer),box);
    const prepared = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP);
    const native = detector.infer(modelPath,input.buffer as ArrayBuffer);
    const inferred = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP);
    const detections = postprocess(new Float32Array(native.output),box,confidence,overlap);
    const ended = systemDateTime.getUptime(systemDateTime.TimeType.STARTUP);
    const result: DetectionResult = {detections,width:info.size.width,height:info.size.height,preprocessMs:prepared-started,inferenceMs:native.inferenceMs,postprocessMs:ended-inferred,loadMs:native.loadMs,totalMs:ended-started,runtime:native.runtime};
    return JSON.stringify(result);
  } finally {
    if (pixels) await pixels.release();
    if (source) source.release();
    fs.closeSync(file);
  }
}
@Concurrent
export function validateModel(path: string): string { return detector.validate(path); }
