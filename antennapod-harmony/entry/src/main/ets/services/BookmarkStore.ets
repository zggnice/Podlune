import common from '@ohos.app.ability.common';
import preferences from '@ohos.data.preferences';

const PREF_NAME: string = 'podcast_bookmarks';

/** 一条时间点书签 */
export interface EpisodeBookmark {
  /** 位置（毫秒） */
  positionMs: number;
  /** 备注（可空） */
  note: string;
  /** 创建时间（毫秒时间戳） */
  createdAt: number;
}

/**
 * 时间点书签：按「单集 id」分组存在 Preferences 里。
 *
 * 为什么不用数据库表：书签是低频、少量数据，用 Preferences(JSON) 可以避免
 * DB 版本迁移带来的风险；单集删除后残留的孤儿数据也只是几十字节。
 */
export class BookmarkStore {
  private static instance: preferences.Preferences | undefined = undefined;
  private static memory: Map<number, EpisodeBookmark[]> = new Map<number, EpisodeBookmark[]>();
  private static loaded: boolean = false;

  static init(context: common.Context): void {
    if (BookmarkStore.instance !== undefined) {
      return;
    }
    const options: preferences.Options = { name: PREF_NAME };
    BookmarkStore.instance = preferences.getPreferencesSync(context, options);
  }

  private static loadOnce(): void {
    if (BookmarkStore.loaded) {
      return;
    }
    BookmarkStore.loaded = true;
    const prefs: preferences.Preferences | undefined = BookmarkStore.instance;
    if (prefs === undefined) {
      return;
    }
    try {
      const raw: string = prefs.getSync('map', '') as string;
      if (raw === '') {
        return;
      }
      const parsed: Record<string, EpisodeBookmark[]> = JSON.parse(raw) as Record<string, EpisodeBookmark[]>;
      for (const key of Object.keys(parsed)) {
        const id: number = Number(key);
        if (!isNaN(id)) {
          BookmarkStore.memory.set(id, parsed[key]);
        }
      }
    } catch (error) {
      BookmarkStore.memory.clear();
    }
  }

  /** 某单集的全部书签（按位置升序） */
  static list(episodeId: number): EpisodeBookmark[] {
    BookmarkStore.loadOnce();
    const items: EpisodeBookmark[] = BookmarkStore.memory.get(episodeId) ?? [];
    return items.slice().sort((a: EpisodeBookmark, b: EpisodeBookmark) => a.positionMs - b.positionMs);
  }

  /** 新增一条；同一位置 3 秒内重复点击视为同一条 */
  static add(episodeId: number, positionMs: number, note: string = ''): boolean {
    BookmarkStore.loadOnce();
    if (episodeId <= 0) {
      return false;
    }
    const items: EpisodeBookmark[] = BookmarkStore.memory.get(episodeId) ?? [];
    for (const existing of items) {
      if (Math.abs(existing.positionMs - positionMs) < 3000) {
        return false;
      }
    }
    items.push({ positionMs: positionMs, note: note, createdAt: Date.now() });
    BookmarkStore.memory.set(episodeId, items);
    BookmarkStore.persist();
    return true;
  }

  /** 当前位置附近（默认 ±2.5s）是否已有标记：决定按钮显示实心还是空心 */
  static hasNear(episodeId: number, positionMs: number, windowMs: number = 2500): boolean {
    const items: EpisodeBookmark[] = BookmarkStore.list(episodeId);
    for (const item of items) {
      if (Math.abs(item.positionMs - positionMs) <= windowMs) {
        return true;
      }
    }
    return false;
  }

  /** 删除当前位置附近的标记（返回是否真的删掉），供「再点一次取消」使用 */
  static removeNear(episodeId: number, positionMs: number, windowMs: number = 2500): boolean {
    const items: EpisodeBookmark[] = BookmarkStore.list(episodeId);
    for (const item of items) {
      if (Math.abs(item.positionMs - positionMs) <= windowMs) {
        BookmarkStore.remove(episodeId, item.positionMs);
        return true;
      }
    }
    return false;
  }

  static remove(episodeId: number, positionMs: number): void {
    BookmarkStore.loadOnce();
    const items: EpisodeBookmark[] = BookmarkStore.memory.get(episodeId) ?? [];
    const next: EpisodeBookmark[] = [];
    let removed: boolean = false;
    for (const item of items) {
      if (!removed && Math.abs(item.positionMs - positionMs) < 1) {
        removed = true;
        continue;
      }
      next.push(item);
    }
    BookmarkStore.memory.set(episodeId, next);
    BookmarkStore.persist();
  }

  /** 导出为 Markdown（用于「笔记导出」） */
  static toMarkdown(episodeTitle: string, episodeId: number): string {
    const items: EpisodeBookmark[] = BookmarkStore.list(episodeId);
    if (items.length === 0) {
      return '';
    }
    const lines: string[] = ['# ' + episodeTitle, ''];
    for (const item of items) {
      const total: number = Math.floor(item.positionMs / 1000);
      const m: number = Math.floor(total / 60);
      const s: number = total % 60;
      const stamp: string = m.toString() + ':' + (s < 10 ? '0' + s : s.toString());
      lines.push('- [' + stamp + '] ' + (item.note === '' ? '' : item.note));
    }
    return lines.join('\n');
  }

  private static persist(): void {
    const prefs: preferences.Preferences | undefined = BookmarkStore.instance;
    if (prefs === undefined) {
      return;
    }
    const obj: Record<string, EpisodeBookmark[]> = {};
    BookmarkStore.memory.forEach((value: EpisodeBookmark[], key: number) => {
      obj[key.toString()] = value;
    });
    prefs.putSync('map', JSON.stringify(obj));
    prefs.flush();
  }
}
