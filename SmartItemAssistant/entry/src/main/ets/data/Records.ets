import { relationalStore as rdb } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Detection } from '../inference/Vision';
import { DetectionResult } from '../inference/DetectionWorker';

export interface Timings { preprocessMs: number; inferenceMs: number; postprocessMs: number; loadMs: number; totalMs: number; }
export interface RecordPayload {
  recordId: string; revision: number; createdAt: string; updatedAt: string; modelVersion: string;
  width: number; height: number; confidenceThreshold: number; nmsThreshold: number;
  detections: Detection[]; timings: Timings;
}
export interface LocalRecord { payload: RecordPayload; imagePath: string; thumbnail: Uint8Array; syncedRevision: number; }
export interface Pending { recordId: string; revision: number; payload: string; attempts: number; }

export class Records {
  private store?: rdb.RdbStore;
  private writeChain: Promise<void> = Promise.resolve();
  async initialize(context: common.UIAbilityContext): Promise<void> {
    this.store = await rdb.getRdbStore(context,{name:'smart_items.db',securityLevel:rdb.SecurityLevel.S1});
    await this.store.executeSql('CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY, created TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL, image_path TEXT NOT NULL, thumbnail BLOB NOT NULL, synced_revision INTEGER NOT NULL DEFAULT 0)');
    await this.store.executeSql('CREATE TABLE IF NOT EXISTS detections (record_id TEXT NOT NULL, class_id INTEGER NOT NULL, deleted INTEGER NOT NULL)');
    await this.store.executeSql('CREATE INDEX IF NOT EXISTS detection_class ON detections(class_id,record_id)');
    await this.store.executeSql('CREATE TABLE IF NOT EXISTS outbox (record_id TEXT NOT NULL, revision INTEGER NOT NULL, payload TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_retry INTEGER NOT NULL DEFAULT 0, error TEXT NOT NULL DEFAULT \'\', PRIMARY KEY(record_id,revision))');
  }
  make(result: DetectionResult, model: string, confidence: number): RecordPayload {
    const now = new Date().toISOString();
    return {recordId:util.generateRandomUUID(true),revision:1,createdAt:now,updatedAt:now,modelVersion:model,width:result.width,height:result.height,confidenceThreshold:confidence,nmsThreshold:0.45,detections:result.detections,timings:{preprocessMs:result.preprocessMs,inferenceMs:result.inferenceMs,postprocessMs:result.postprocessMs,loadMs:result.loadMs,totalMs:result.totalMs}};
  }
  async save(record: RecordPayload, path: string, thumbnail: Uint8Array): Promise<void> {
    // Serialize writes so asynchronous SQL cannot interleave two transactions.
    const snapshot = JSON.stringify(record);
    const operation = this.writeChain.then(async () => {
      const db = this.store!;
      db.beginTransaction();
      try {
        await db.executeSql('INSERT INTO records(id,created,revision,payload,image_path,thumbnail) VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,payload=excluded.payload,image_path=excluded.image_path,thumbnail=excluded.thumbnail',[record.recordId,record.createdAt,record.revision,snapshot,path,thumbnail]);
        await db.executeSql('DELETE FROM detections WHERE record_id=?',[record.recordId]);
        for (const d of record.detections) await db.executeSql('INSERT INTO detections VALUES (?,?,?)',[record.recordId,d.classId,d.deleted?1:0]);
        await db.executeSql('INSERT INTO outbox(record_id,revision,payload) VALUES (?,?,?)',[record.recordId,record.revision,snapshot]);
        db.commit();
      } catch (error) { db.rollBack(); throw new Error(String(error)); }
    });
    this.writeChain = operation.catch(() => {});
    await operation;
  }
  async list(start: string = '', end: string = '', classId: number = -1): Promise<LocalRecord[]> {
    let sql = 'SELECT * FROM records WHERE 1=1';
    const args: rdb.ValueType[] = [];
    if(start) {sql+=' AND created>=?';args.push(start);}
    if(end) {sql+=' AND created<?';args.push(end);}
    if(classId>=0) {sql+=' AND id IN (SELECT record_id FROM detections WHERE class_id=? AND deleted=0)';args.push(classId);}
    sql+=' ORDER BY created DESC LIMIT 200';
    const result = await this.store!.querySql(sql,args);
    const items: LocalRecord[] = [];
    try {
      while(result.goToNextRow()) items.push({payload:JSON.parse(result.getString(result.getColumnIndex('payload'))) as RecordPayload,imagePath:result.getString(result.getColumnIndex('image_path')),thumbnail:result.getBlob(result.getColumnIndex('thumbnail')),syncedRevision:result.getLong(result.getColumnIndex('synced_revision'))});
    } finally {result.close();}
    return items;
  }
  async pending(force: boolean = false): Promise<Pending[]> {
    const result = await this.store!.querySql('SELECT * FROM outbox WHERE next_retry>=0 AND next_retry<=? ORDER BY revision LIMIT 50',[force?Number.MAX_SAFE_INTEGER:Date.now()]);
    const items: Pending[] = [];
    try { while(result.goToNextRow()) items.push({recordId:result.getString(0),revision:result.getLong(1),payload:result.getString(2),attempts:result.getLong(3)}); }
    finally {result.close();}
    return items;
  }
  async acknowledge(item: Pending, accepted: number): Promise<void> {
    await this.store!.executeSql('UPDATE records SET synced_revision=MAX(synced_revision,?) WHERE id=?',[accepted,item.recordId]);
    await this.store!.executeSql('DELETE FROM outbox WHERE record_id=? AND revision=?',[item.recordId,item.revision]);
  }
  async retry(item: Pending, message: string, permanent: boolean = false, delayMs: number = 0): Promise<void> {
    const delay = Math.max(delayMs,Math.min(300000,2000*Math.pow(2,Math.min(item.attempts,8)))+Math.floor(Math.random()*1000));
    await this.store!.executeSql('UPDATE outbox SET attempts=attempts+1,next_retry=?,error=? WHERE record_id=? AND revision=?',[permanent?-1:Date.now()+delay,message.slice(0,200),item.recordId,item.revision]);
  }
  async queueStatus(): Promise<string> {
    const result=await this.store!.querySql('SELECT COUNT(*),SUM(CASE WHEN next_retry<0 THEN 1 ELSE 0 END) FROM outbox');
    try {result.goToFirstRow();return `${result.getLong(0)} 条待同步，${result.getLong(1)} 条需处理`;}
    finally {result.close();}
  }
  async resetFailed(): Promise<void> { await this.store!.executeSql('UPDATE outbox SET next_retry=0 WHERE next_retry<0'); }
}
