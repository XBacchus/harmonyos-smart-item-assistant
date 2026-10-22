export interface NativeResult {
  output: ArrayBuffer;
  inferenceMs: number;
  loadMs: number;
  runtime: string;
}
export const infer: (modelPath: string, input: ArrayBuffer) => NativeResult;
export const validate: (modelPath: string) => string;
