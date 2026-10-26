// 文字稿持久化：按 (单集, 来源类型, 语言) 唯一保存。
// 官方与 AI 文字稿可以同时存在，互不覆盖；正文以 JSON 段落形式独立存储。
import relationalStore from '@ohos.data.relationalStore';
import { DbManager } from '../DbManager';
import { TABLE_TRANSCRIPTS } from '../Tables';
import { TranscriptDocument, TranscriptSegment, TranscriptSourceType } from '../../model/Transcript';
import { Logger } from '../../utils/Logger';

const TAG: string = 'TranscriptRepository';

export class TranscriptRepository {
  /** 同一单集下所有已缓存的文字稿（官方 + AI，可分语言） */
  static async listByEpisode(episodeId: number): Promise<TranscriptDocument[]> {
    const rs: relationalStore.ResultSet = await DbManager.querySql(
      `SELECT * FROM ${TABLE_TRANSCRIPTS} WHERE feeditem = ${episodeId} ORDER BY is_ai ASC, created_at DESC`
    );
    const output: TranscriptDocument[] = [];
    while (rs.goToNextRow()) {
      output.push(TranscriptRepository.mapRow(rs));
    }
    rs.close();
    return output;
  }

  /** 取指定来源的文字稿；sourceType 未命中时返回 undefined */
  static async findBySource(episodeId: number, sourceType: number,
                            language: string = ''): Promise<TranscriptDocument | undefined> {
    const docs: TranscriptDocument[] = await TranscriptRepository.listByEpisode(episodeId);
    for (const doc of docs) {
      if (doc.sourceType !== sourceType) {
        continue;
      }
      if (language === '' || doc.language === language) {
        return doc;
      }
    }
    return undefined;
  }

  /**
   * 保存（同来源同语言覆盖）。返回带 transcriptId 的文档。
   * 生成成功后立即落库，重启 App 可继续读取与离线阅读。
   */
  static async save(doc: TranscriptDocument): Promise<TranscriptDocument> {
    const now: number = Date.now();
    const payload: string = JSON.stringify(doc.segments);
    const values: relationalStore.ValuesBucket = {
      feeditem: doc.episodeId,
      source_type: doc.sourceType,
      language: doc.language === undefined || doc.language === null ? '' : doc.language,
      provider: doc.provider,
      model: doc.model,
      is_timed: doc.isTimed ? 1 : 0,
      is_ai: doc.isAiGenerated ? 1 : 0,
      created_at: doc.createdAt > 0 ? doc.createdAt : now,
      updated_at: now,
      segments_json: payload
    };
    const existing: TranscriptDocument | undefined =
      await TranscriptRepository.findBySource(doc.episodeId, doc.sourceType, doc.language);
    if (existing !== undefined) {
      const predicates: relationalStore.RdbPredicates =
        new relationalStore.RdbPredicates(TABLE_TRANSCRIPTS);
      predicates.equalTo('id', existing.transcriptId);
      await DbManager.getStore().update(values, predicates);
      doc.transcriptId = existing.transcriptId;
    } else {
      try {
        const id: number = await DbManager.insert(TABLE_TRANSCRIPTS, values);
        doc.transcriptId = id;
      } catch (error) {
        // 唯一索引冲突（并发写入同一来源）：回退成覆盖更新
        Logger.warn(TAG, 'insert conflict, fallback to update: ' + (error as Error).message);
        const again: TranscriptDocument | undefined =
          await TranscriptRepository.findBySource(doc.episodeId, doc.sourceType, doc.language);
        if (again !== undefined) {
          const predicates: relationalStore.RdbPredicates =
            new relationalStore.RdbPredicates(TABLE_TRANSCRIPTS);
          predicates.equalTo('id', again.transcriptId);
          await DbManager.getStore().update(values, predicates);
          doc.transcriptId = again.transcriptId;
        }
      }
    }
    doc.updatedAt = now;
    return doc;
  }

  /** 删除单集文字稿；只影响文字稿，不动订阅与音频 */
  static async deleteByEpisode(episodeId: number, onlyAi: boolean = false): Promise<void> {
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_TRANSCRIPTS);
    predicates.equalTo('feeditem', episodeId);
    if (onlyAi) {
      predicates.equalTo('is_ai', 1);
    }
    await DbManager.getStore().delete(predicates);
  }

  /** 清理全部 AI 文字稿（官方文字稿保留） */
  static async deleteAllAi(): Promise<void> {
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_TRANSCRIPTS);
    predicates.equalTo('is_ai', 1);
    await DbManager.getStore().delete(predicates);
  }
  /** 已缓存文字稿统计（设置页展示占用与数量） */
  static async stats(): Promise<Map<string, number>> {
    const output: Map<string, number> = new Map<string, number>();
    const rs: relationalStore.ResultSet = await DbManager.querySql(
      `SELECT COUNT(*) AS c, COALESCE(SUM(LENGTH(segments_json)), 0) AS s FROM ${TABLE_TRANSCRIPTS}`
    );
    let count: number = 0;
    let bytes: number = 0;
    if (rs.goToFirstRow()) {
      count = rs.getLong(rs.getColumnIndex('c'));
      bytes = rs.getLong(rs.getColumnIndex('s'));
    }
    rs.close();
    output.set('count', count);
    output.set('bytes', bytes);
    return output;
  }

  private static mapRow(rs: relationalStore.ResultSet): TranscriptDocument {
    const segments: TranscriptSegment[] = TranscriptRepository.parseSegments(
      rs.getString(rs.getColumnIndex('segments_json'))
    );
    return {
      episodeId: rs.getLong(rs.getColumnIndex('feeditem')),
      transcriptId: rs.getLong(rs.getColumnIndex('id')),
      sourceType: rs.getLong(rs.getColumnIndex('source_type')),
      language: rs.getString(rs.getColumnIndex('language')),
      provider: rs.getString(rs.getColumnIndex('provider')),
      model: rs.getString(rs.getColumnIndex('model')),
      isTimed: rs.getLong(rs.getColumnIndex('is_timed')) === 1,
      isAiGenerated: rs.getLong(rs.getColumnIndex('is_ai')) === 1,
      createdAt: rs.getLong(rs.getColumnIndex('created_at')),
      updatedAt: rs.getLong(rs.getColumnIndex('updated_at')),
      segments: segments
    };
  }

  private static parseSegments(raw: string): TranscriptSegment[] {
    if (raw === undefined || raw === null || raw === '') {
      return [];
    }
    try {
      const list: Object[] = JSON.parse(raw) as Object[];
      const output: TranscriptSegment[] = [];
      for (const entry of list) {
        const item: Record<string, Object> = entry as Record<string, Object>;
        output.push({
          segmentId: TranscriptRepository.num(item['segmentId'], 0),
          startMs: TranscriptRepository.num(item['startMs'], 0),
          endMs: TranscriptRepository.num(item['endMs'], 0),
          text: item['text'] === undefined ? '' : String(item['text']),
          speaker: item['speaker'] === undefined ? '' : String(item['speaker'])
        });
      }
      return output;
    } catch (error) {
      Logger.warn(TAG, 'parse segments failed');
      return [];
    }
  }

  private static num(value: Object, fallback: number): number {
    if (value === undefined || value === null) {
      return fallback;
    }
    const n: number = Number(value);
    return isNaN(n) ? fallback : n;
  }
}
