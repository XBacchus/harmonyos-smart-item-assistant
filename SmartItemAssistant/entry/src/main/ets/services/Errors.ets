import { BusinessError } from '@kit.BasicServicesKit';

export function errorMessage(error: Error): string {
  const detail=error as BusinessError;
  if(detail.message) return detail.code?`${detail.message} (${detail.code})`:detail.message;
  return detail.code?`操作失败 (${detail.code})`:'操作未完成，请重试';
}
