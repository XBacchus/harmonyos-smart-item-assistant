const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.DEVECO_HOME
  ? path.join(process.env.DEVECO_HOME, 'tools/ohpm/node_modules/typescript/lib/typescript.js')
  : 'typescript');
const source = fs.readFileSync(path.join(__dirname,'../SmartItemAssistant/entry/src/main/ets/inference/Vision.ts'),'utf8');
const output = ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;
const context = {exports:{},Float32Array,Uint8Array};
vm.runInNewContext(output,context);
const {letterbox,preprocess,postprocess,nms,LABELS}=context.exports;
const square=letterbox(2,2,2);
const channels=preprocess(new Uint8Array([255,0,0,255,0,255,0,255,0,0,255,255,255,255,255,255]),square);
assert.deepEqual(Array.from(channels),[1,0,0,1,0,1,0,1,0,0,1,1]);
const odd=letterbox(101,50);
assert.equal(odd.scaledHeight,317);assert.equal(odd.top,161);
const pad=preprocess(new Uint8Array(101*50*4),odd);
assert(Math.abs(pad[0]-114/255)<1e-7);
const shape=letterbox(320,640);
const tensor=new Float32Array(84*8400);
function box(i,c,score,x,y,w,h){tensor[i]=x;tensor[8400+i]=y;tensor[16800+i]=w;tensor[25200+i]=h;tensor[(4+c)*8400+i]=score;}
box(0,41,.9,320,320,100,200);box(1,41,.8,320,320,100,200);box(2,67,.7,320,320,100,200);
box(3,41,.95,NaN,320,100,200);box(4,41,.1,320,320,100,200);
const result=postprocess(tensor,shape,.25,.45);
assert.equal(result.length,2);assert.equal(result[0].x1,110);assert.equal(result[0].x2,210);assert.equal(result[0].y1,220);
assert.equal(result[0].classId,41);assert.equal(result[1].classId,67);
assert.equal(postprocess(new Float32Array(84*8400),shape,.25,.45).length,0);
assert.throws(()=>preprocess(new Uint8Array(1),square));
assert.equal(LABELS.length,80);assert.equal(LABELS[66],'键盘');assert.equal(LABELS[73],'书本');
console.log('PASS: RGB/NCHW, padding, odd letterbox, coordinate restoration, same-class NMS, class isolation, non-finite and empty output');
