// Port of: storage/database/DBUpgrader.java -> HarmonyOS relationalStore migration skeleton
import relationalStore from '@ohos.data.relationalStore';
import { Logger } from '../utils/Logger';

const TAG: string = 'DbMigration';

export class DbMigration {
  static async migrate(store: relationalStore.RdbStore, fromVersion: number, toVersion: number): Promise<void> {
    if (fromVersion >= toVersion) {
      return;
    }
    Logger.info(TAG, 'migrate db from ' + fromVersion + ' to ' + toVersion);
    if (fromVersion < 2) {
      await DbMigration.migrateTo2(store);
    }
    if (fromVersion < 3) {
      await DbMigration.migrateTo3(store);
    }
    if (fromVersion < 4) {
      await DbMigration.migrateTo4(store);
    }
    store.version = toVersion;
    Logger.info(TAG, 'migration done');
  }

  /**
   * v3 -> v4：Queue 增加显式排序字段。
   *
   * - position：按旧的 id 顺序回填（老队列的展示顺序就是 id 升序），保证升级后顺序不变；
   * - created_at：用 id 当代理值（id 是自增的，天然单调），这样「同一 position」时
   *   仍能按加入顺序稳定兜底。
   */
  private static async migrateTo4(store: relationalStore.RdbStore): Promise<void> {
    if (!await DbMigration.columnExists(store, 'Queue', 'position')) {
      await store.executeSql('ALTER TABLE Queue ADD COLUMN position INTEGER NOT NULL DEFAULT 0');
    }
    if (!await DbMigration.columnExists(store, 'Queue', 'created_at')) {
      await store.executeSql('ALTER TABLE Queue ADD COLUMN created_at INTEGER NOT NULL DEFAULT 0');
    }
    // 老数据回填：position = 旧 id 的升序名次，created_at = id
    // 先去重（同 feeditem 只保留 id 最小的一条）：老版本允许重复入队，
    // 而重复行会让后续唯一索引/顺序计算出问题，也会出现「一张卡出现两次」。
    await store.executeSql(
      'DELETE FROM Queue WHERE feeditem IN ('
      + 'SELECT feeditem FROM Queue GROUP BY feeditem HAVING COUNT(*) > 1) '
      + 'AND id NOT IN (SELECT MIN(id) FROM Queue GROUP BY feeditem)'
    );
    await store.executeSql(
      'UPDATE Queue SET position = (SELECT COUNT(*) FROM Queue q2 WHERE q2.id < Queue.id) '
      + 'WHERE position = 0 AND created_at = 0'
    );
    await store.executeSql('UPDATE Queue SET created_at = id WHERE created_at = 0');
    await store.executeSql('DROP INDEX IF EXISTS Queue_feeditem');
    await store.executeSql('CREATE INDEX IF NOT EXISTS Queue_feeditem ON Queue (feeditem)');
    await store.executeSql('CREATE INDEX IF NOT EXISTS Queue_order ON Queue (position, created_at, id)');
  }

  /** v2 -> v3：新增文字稿表。只建表，不动既有订阅、单集与音频数据。 */
  private static async migrateTo3(store: relationalStore.RdbStore): Promise<void> {
    await store.executeSql(
      'CREATE TABLE IF NOT EXISTS Transcripts ('
      + 'id INTEGER PRIMARY KEY AUTOINCREMENT, feeditem INTEGER, source_type INTEGER, language TEXT, '
      + 'provider TEXT, model TEXT, is_timed INTEGER, is_ai INTEGER, created_at INTEGER, updated_at INTEGER, '
      + 'segments_json TEXT)'
    );
    await store.executeSql('CREATE INDEX IF NOT EXISTS Transcripts_feeditem ON Transcripts (feeditem)');
    await store.executeSql(
      'CREATE UNIQUE INDEX IF NOT EXISTS Transcripts_feeditem_source ON Transcripts (feeditem, source_type, language)'
    );
  }

  private static async migrateTo2(store: relationalStore.RdbStore): Promise<void> {
    // v1 -> v2：Feeds 新增「收件箱基线」列（= 订阅 / 批量导入时刻）。
    // 早于基线发布的单集落库为「未播放」而非「新」，因此不会灌进收件箱。
    if (!await DbMigration.columnExists(store, 'Feeds', 'inbox_baseline')) {
      await store.executeSql('ALTER TABLE Feeds ADD COLUMN inbox_baseline INTEGER DEFAULT 0');
    }
    // 存量订阅回填：以「最近一次刷新时刻」作为基线，避免继续把历史剧集当新单集收进收件箱。
    // 不回写已入库单集的 read 值（不动用户已有的收件箱内容）。
    await store.executeSql(
      'UPDATE Feeds SET inbox_baseline = last_refresh_attempt '
      + 'WHERE (inbox_baseline IS NULL OR inbox_baseline = 0) AND last_refresh_attempt > 0'
    );
  }

  /** 列是否已存在：新库由 DDL 直接建出该列，只有旧库才需要 ALTER TABLE */
  private static async columnExists(store: relationalStore.RdbStore, table: string,
                                    column: string): Promise<boolean> {
    try {
      const rs: relationalStore.ResultSet = await store.querySql('PRAGMA table_info(' + table + ')');
      let found: boolean = false;
      if (rs.goToFirstRow()) {
        do {
          const nameIndex: number = rs.getColumnIndex('name');
          if (nameIndex >= 0 && rs.getString(nameIndex) === column) {
            found = true;
            break;
          }
        } while (rs.goToNextRow());
      }
      rs.close();
      return found;
    } catch (error) {
      Logger.warn(TAG, 'PRAGMA table_info(' + table + ') failed: ' + (error as Error).message);
      return false;
    }
  }
}
