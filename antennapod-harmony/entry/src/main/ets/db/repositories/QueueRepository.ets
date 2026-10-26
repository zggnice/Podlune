// Port of: storage/database Queue table + ItemEnqueuePositionCalculator.java
//
// 排序模型（v4）：
//   position   : 显式排序字段，**越小越靠上**；新增 / 播放置顶都取「当前最小值 - 1」
//   created_at : 同一 position 的稳定兜底（DESC，后加的在前）
//   id         : 最终兜底（DESC），保证同一时刻插入的多条也不随机跳动
//
// 展示顺序恒定 = ORDER BY position ASC, created_at DESC, id DESC
// 手动拖拽 / 播放置顶都会**重写 position**，因此不会被 created_at 默认排序覆盖。
import relationalStore from '@ohos.data.relationalStore';
import { DbManager } from '../DbManager';
import { TABLE_QUEUE } from '../Tables';
import { QueueItem } from '../../model/QueueItem';
import { QueueMapper } from '../mappers/QueueMapper';

/** 分页游标：对应 (position, created_at, id) 三元组，保证翻页不重不漏 */
export class QueueCursor {
  position: number = 0;
  createdAt: number = 0;
  id: number = 0;

  constructor(position: number, createdAt: number, id: number) {
    this.position = position;
    this.createdAt = createdAt;
    this.id = id;
  }

  static empty(): QueueCursor {
    return new QueueCursor(0, 0, 0);
  }
}

export class QueueRepository {
  /** 展示顺序：position 升序（手动顺序优先）→ created_at 降序 → id 降序 */
  private static readonly ORDER_BY: string = 'ORDER BY position ASC, created_at DESC, id DESC';

  /** 全量列表（队列规模小，内存里直接持有顺序） */
  static async list(): Promise<QueueItem[]> {
    const rs: relationalStore.ResultSet = await DbManager.querySql(
      `SELECT * FROM ${TABLE_QUEUE} ${QueueRepository.ORDER_BY}`
    );
    const items: QueueItem[] = [];
    if (rs.goToFirstRow()) {
      do {
        items.push(QueueMapper.map(rs));
      } while (rs.goToNextRow());
    }
    rs.close();
    return items;
  }

  /**
   * 稳定游标分页。
   *
   * 游标比较条件（严格排在 (position ASC, created_at DESC, id DESC) 之后）：
   *   position > cur.position
   *   OR (position = cur.position AND created_at < cur.createdAt)
   *   OR (position = cur.position AND created_at = cur.createdAt AND id < cur.id)
   *
   * 新增 / 置顶只会把 position 变得更小，因此只会出现在**第一页**，
   * 不会插入到已翻过的区间里造成重复或漏项。
   */
  static async listPage(limit: number, cursor: QueueCursor = QueueCursor.empty(),
                        hasCursor: boolean = false): Promise<QueueItem[]> {
    const safeLimit: number = limit > 0 ? Math.floor(limit) : 50;
    let where: string = '';
    if (hasCursor) {
      where = ' WHERE (position > ?)'
        + ' OR (position = ? AND created_at < ?)'
        + ' OR (position = ? AND created_at = ? AND id < ?)';
    }
    const sql: string = `SELECT * FROM ${TABLE_QUEUE}${where} ${QueueRepository.ORDER_BY} LIMIT ${safeLimit}`;
    const args: Array<relationalStore.ValueType> = hasCursor
      ? [cursor.position, cursor.position, cursor.createdAt, cursor.position, cursor.createdAt, cursor.id]
      : [];
    const rs: relationalStore.ResultSet = await DbManager.querySqlArgs(sql, args);
    const items: QueueItem[] = [];
    if (rs.goToFirstRow()) {
      do {
        items.push(QueueMapper.map(rs));
      } while (rs.goToNextRow());
    }
    rs.close();
    return items;
  }

  /** 头部排序值：当前最小值 - 1（空队列为 -1），永远比所有已有行更靠上 */
  private static async nextTopPosition(): Promise<number> {
    const rs: relationalStore.ResultSet = await DbManager.querySql(
      `SELECT COALESCE(MIN(position), 0) AS minPos FROM ${TABLE_QUEUE}`
    );
    let minPos: number = 0;
    if (rs.goToFirstRow()) {
      minPos = rs.getLong(rs.getColumnIndex('minPos'));
    }
    rs.close();
    return minPos - 1;
  }

  static async exists(feedItemId: number): Promise<boolean> {
    const rs: relationalStore.ResultSet = await DbManager.querySqlArgs(
      `SELECT 1 FROM ${TABLE_QUEUE} WHERE feeditem = ? LIMIT 1`, [feedItemId]
    );
    const found: boolean = rs.goToFirstRow();
    rs.close();
    return found;
  }

  /**
   * 新增到**头部**（规则：新添加的排第一）。
   *
   * 幂等：已在队列里则返回 false（不重复插入、不产生重复卡片）。
   * 事务内完成「判重 + 读最小 position + 插入」，避免并发下拿到同一个头部排序值。
   */
  static async addTop(feedItemId: number, feedId: number): Promise<boolean> {
    const store: relationalStore.RdbStore = DbManager.getStore();
    store.beginTransaction();
    try {
      if (await QueueRepository.exists(feedItemId)) {
        store.commit();
        return false;
      }
      const position: number = await QueueRepository.nextTopPosition();
      const createdAt: number = Date.now();
      const rs: relationalStore.ResultSet = await DbManager.querySql(
        `SELECT COALESCE(MAX(id), 0) AS maxId FROM ${TABLE_QUEUE}`
      );
      let nextId: number = 1;
      if (rs.goToFirstRow()) {
        nextId = rs.getLong(rs.getColumnIndex('maxId')) + 1;
      }
      rs.close();
      const values: relationalStore.ValuesBucket = {
        id: nextId,
        feeditem: feedItemId,
        feed: feedId,
        position: position,
        created_at: createdAt
      };
      await DbManager.insert(TABLE_QUEUE, values);
      store.commit();
      return true;
    } catch (error) {
      store.rollBack();
      throw error as Error;
    }
  }

  /**
   * 在指定下标插入新项（0 = 头部；1 = 「当前播放项」之后）。
   *
   * 规则：当前播放项在头部时，新增项插到它下一行；连续新增时后加的更靠前
   * （因为每次都插在同一个下标 1 上）。落库用「插入 + 全表重编号」保证 position 连续。
   *
   * 幂等：已存在则返回 false（不重复插入）。
   */
  static async insertAt(feedItemId: number, feedId: number, index: number): Promise<boolean> {
    const store: relationalStore.RdbStore = DbManager.getStore();
    store.beginTransaction();
    try {
      if (await QueueRepository.exists(feedItemId)) {
        store.commit();
        return false;
      }
      const rs: relationalStore.ResultSet = await DbManager.querySql(
        `SELECT * FROM ${TABLE_QUEUE} ${QueueRepository.ORDER_BY}`
      );
      const ordered: number[] = [];
      if (rs.goToFirstRow()) {
        do {
          ordered.push(rs.getLong(rs.getColumnIndex('feeditem')));
        } while (rs.goToNextRow());
      }
      rs.close();
      const safeIndex: number = index < 0 ? 0 : (index > ordered.length ? ordered.length : index);
      ordered.splice(safeIndex, 0, feedItemId);

      // 先插入一行（position 用占位值），随后整表重编号 0..n-1
      const idRs: relationalStore.ResultSet = await DbManager.querySql(
        `SELECT COALESCE(MAX(id), 0) AS maxId FROM ${TABLE_QUEUE}`
      );
      let nextId: number = 1;
      if (idRs.goToFirstRow()) {
        nextId = idRs.getLong(idRs.getColumnIndex('maxId')) + 1;
      }
      idRs.close();
      const values: relationalStore.ValuesBucket = {
        id: nextId,
        feeditem: feedItemId,
        feed: feedId,
        position: 0,
        created_at: Date.now()
      };
      await DbManager.insert(TABLE_QUEUE, values);
      await QueueRepository.applyOrderByIdsLocked(ordered);
      store.commit();
      return true;
    } catch (error) {
      store.rollBack();
      throw error as Error;
    }
  }

  /** 事务内：按 id 顺序重写 position（0..n-1） */
  private static async applyOrderByIdsLocked(orderedIds: number[]): Promise<void> {
    const store: relationalStore.RdbStore = DbManager.getStore();
    for (let i: number = 0; i < orderedIds.length; i++) {
      const predicates: relationalStore.RdbPredicates =
        new relationalStore.RdbPredicates(TABLE_QUEUE);
      predicates.equalTo('feeditem', orderedIds[i]);
      const values: relationalStore.ValuesBucket = { position: i };
      await store.update(values, predicates);
    }
  }

  /**
   * 播放置顶：把已在队列里的项移到头部（显式排序操作，覆盖原位置）。
   * 已经是最上面时是空操作（规则 2.6：重复播放头部项不产生变化）。
   */
  static async moveToTop(feedItemId: number): Promise<void> {
    const store: relationalStore.RdbStore = DbManager.getStore();
    store.beginTransaction();
    try {
      const rs: relationalStore.ResultSet = await DbManager.querySql(
        `SELECT * FROM ${TABLE_QUEUE} ${QueueRepository.ORDER_BY}`
      );
      const ordered: QueueItem[] = [];
      if (rs.goToFirstRow()) {
        do {
          ordered.push(QueueMapper.map(rs));
        } while (rs.goToNextRow());
      }
      rs.close();
      const index: number =
        ordered.findIndex((item: QueueItem) => item.feedItemId === feedItemId);
      if (index < 0 || index === 0) {
        store.commit();
        return;
      }
      // 统一重编号 0..n-1：被置顶的项放在 0，其余保持相对顺序
      const reordered: QueueItem[] = [ordered[index]];
      for (let i: number = 0; i < ordered.length; i++) {
        if (i !== index) {
          reordered.push(ordered[i]);
        }
      }
      await QueueRepository.applyOrderLocked(reordered);
      store.commit();
    } catch (error) {
      store.rollBack();
      throw error as Error;
    }
  }

  /**
   * 手动拖拽后的整体顺序持久化（事务内批量 UPDATE position）。
   * 入参为**完整**顺序（页面看到什么就传什么），因此不会与 created_at 兜底打架。
   */
  static async reorder(feedItemIds: number[]): Promise<void> {
    const store: relationalStore.RdbStore = DbManager.getStore();
    store.beginTransaction();
    try {
      for (let i: number = 0; i < feedItemIds.length; i++) {
        const predicates: relationalStore.RdbPredicates =
          new relationalStore.RdbPredicates(TABLE_QUEUE);
        predicates.equalTo('feeditem', feedItemIds[i]);
        const values: relationalStore.ValuesBucket = { position: i };
        await store.update(values, predicates);
      }
      store.commit();
    } catch (error) {
      store.rollBack();
      throw error as Error;
    }
  }

  /** 事务内已持有连接时使用：按传入顺序重写 position（0..n-1） */
  private static async applyOrderLocked(ordered: QueueItem[]): Promise<void> {
    const store: relationalStore.RdbStore = DbManager.getStore();
    for (let i: number = 0; i < ordered.length; i++) {
      const predicates: relationalStore.RdbPredicates =
        new relationalStore.RdbPredicates(TABLE_QUEUE);
      predicates.equalTo('feeditem', ordered[i].feedItemId);
      const values: relationalStore.ValuesBucket = { position: i };
      await store.update(values, predicates);
    }
  }

  static async remove(feedItemId: number): Promise<void> {
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_QUEUE);
    predicates.equalTo('feeditem', feedItemId);
    await DbManager.getStore().delete(predicates);
  }

  /** 兼容旧调用：插入到指定位置（0 = 队首），内部仍落到 position 排序 */
  static async addAt(feedItemId: number, feedId: number, index: number): Promise<void> {
    await QueueRepository.addTop(feedItemId, feedId);
    if (index > 0) {
      const items: QueueItem[] = await QueueRepository.list();
      const currentIndex: number =
        items.findIndex((item: QueueItem) => item.feedItemId === feedItemId);
      if (currentIndex >= 0 && currentIndex !== index) {
        const moved: QueueItem = items[currentIndex];
        items.splice(currentIndex, 1);
        items.splice(Math.min(index, items.length), 0, moved);
        await QueueRepository.reorder(items.map((item: QueueItem) => item.feedItemId));
      }
    }
  }

  /** 整体替换顺序（排序菜单 / 随机 / 智能乱序） */
  static async replaceOrder(items: QueueItem[]): Promise<void> {
    await QueueRepository.reorder(items.map((item: QueueItem) => item.feedItemId));
  }

  static async clear(): Promise<void> {
    const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_QUEUE);
    await DbManager.getStore().delete(predicates);
  }

  /** 兼容旧调用：把某项移到指定下标 */
  static async move(feedItemId: number, targetIndex: number): Promise<void> {
    const items: QueueItem[] = await QueueRepository.list();
    const currentIndex: number = items.findIndex((item: QueueItem) => item.feedItemId === feedItemId);
    if (currentIndex < 0) {
      return;
    }
    const moved: QueueItem = items[currentIndex];
    items.splice(currentIndex, 1);
    items.splice(Math.min(targetIndex, items.length), 0, moved);
    await QueueRepository.reorder(items.map((item: QueueItem) => item.feedItemId));
  }
}
