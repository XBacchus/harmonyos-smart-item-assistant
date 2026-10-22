export interface Detection {
  id: string; classId: number; originalClassId: number; confidence: number;
  x1: number; y1: number; x2: number; y2: number; deleted: boolean; edited: boolean;
}
export interface Letterbox {
  width: number; height: number; scaledWidth: number; scaledHeight: number;
  left: number; top: number; size: number;
}
export const LABELS: string[] = ['人','自行车','汽车','摩托车','飞机','公交车','火车','卡车','船','红绿灯','消防栓','停车标志','停车计时器','长椅','鸟','猫','狗','马','羊','牛','大象','熊','斑马','长颈鹿','背包','雨伞','手提包','领带','行李箱','飞盘','滑雪板','单板滑雪板','运动球','风筝','棒球棒','棒球手套','滑板','冲浪板','网球拍','瓶子','红酒杯','水杯','叉子','刀','勺子','碗','香蕉','苹果','三明治','橙子','西兰花','胡萝卜','热狗','披萨','甜甜圈','蛋糕','椅子','沙发','盆栽','床','餐桌','马桶','电视','笔记本电脑','鼠标','遥控器','键盘','手机','微波炉','烤箱','烤面包机','水槽','冰箱','书本','时钟','花瓶','剪刀','泰迪熊','吹风机','牙刷'];
export function letterbox(width: number, height: number, size: number = 640): Letterbox {
  if (width <= 0 || height <= 0) throw new Error('Invalid image dimensions');
  const ratio = Math.min(size / width, size / height);
  const w = Math.max(1, Math.round(width * ratio));
  const h = Math.max(1, Math.round(height * ratio));
  return { width, height, scaledWidth: w, scaledHeight: h, left: Math.floor((size-w)/2), top: Math.floor((size-h)/2), size };
}
export function preprocess(rgba: Uint8Array, box: Letterbox): Float32Array {
  if (rgba.length !== box.width * box.height * 4) throw new Error('Invalid RGBA buffer');
  const plane = box.size * box.size;
  const result = new Float32Array(plane * 3);
  result.fill(114 / 255);
  for (let y = 0; y < box.scaledHeight; y++) {
    const sy = Math.max(0, Math.min(box.height - 1, (y + 0.5) * box.height / box.scaledHeight - 0.5));
    const y0 = Math.floor(sy), y1 = Math.min(y0+1,box.height-1), fy = sy-y0;
    for (let x = 0; x < box.scaledWidth; x++) {
      const sx = Math.max(0, Math.min(box.width-1,(x+0.5)*box.width/box.scaledWidth-0.5));
      const x0 = Math.floor(sx), x1 = Math.min(x0+1,box.width-1), fx = sx-x0;
      const target = (y+box.top)*box.size+x+box.left;
      for (let c = 0; c < 3; c++) {
        const a = rgba[(y0*box.width+x0)*4+c]*(1-fx)+rgba[(y0*box.width+x1)*4+c]*fx;
        const b = rgba[(y1*box.width+x0)*4+c]*(1-fx)+rgba[(y1*box.width+x1)*4+c]*fx;
        result[c*plane+target] = (a*(1-fy)+b*fy)/255;
      }
    }
  }
  return result;
}
export function iou(a: Detection, b: Detection): number {
  const intersection = Math.max(0,Math.min(a.x2,b.x2)-Math.max(a.x1,b.x1))*Math.max(0,Math.min(a.y2,b.y2)-Math.max(a.y1,b.y1));
  const union = (a.x2-a.x1)*(a.y2-a.y1)+(b.x2-b.x1)*(b.y2-b.y1)-intersection;
  return union > 0 ? intersection/union : 0;
}
export function nms(candidates: Detection[], overlap: number): Detection[] {
  const sorted = candidates.sort((a: Detection,b: Detection) => b.confidence-a.confidence).slice(0,3000);
  const kept: Detection[] = [];
  for (const candidate of sorted) {
    if (!kept.some((item: Detection) => item.classId === candidate.classId && iou(item,candidate)>overlap)) kept.push(candidate);
    if (kept.length >= 100) break;
  }
  return kept;
}
export function postprocess(output: Float32Array, box: Letterbox, confidence: number, overlap: number): Detection[] {
  if (output.length !== 84*8400) throw new Error('Unexpected YOLO output');
  const candidates: Detection[] = [];
  for (let i=0;i<8400;i++) {
    let best = -1, score = 0;
    for (let c=0;c<80;c++) { const v = output[(c+4)*8400+i]; if (Number.isFinite(v) && v>score) {score=v;best=c;} }
    if (best<0 || score<confidence || score>1) continue;
    const x=output[i], y=output[8400+i], w=output[16800+i], h=output[25200+i];
    if (![x,y,w,h].every((v: number) => Number.isFinite(v)) || w<=0 || h<=0) continue;
    const x1=Math.max(0,(x-w/2-box.left)*box.width/box.scaledWidth);
    const y1=Math.max(0,(y-h/2-box.top)*box.height/box.scaledHeight);
    const x2=Math.min(box.width,(x+w/2-box.left)*box.width/box.scaledWidth);
    const y2=Math.min(box.height,(y+h/2-box.top)*box.height/box.scaledHeight);
    if(x2>x1 && y2>y1) candidates.push({id:`d${i}`,classId:best,originalClassId:best,confidence:score,x1,y1,x2,y2,deleted:false,edited:false});
  }
  return nms(candidates,overlap);
}
