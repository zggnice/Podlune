import common from '@ohos.app.ability.common';
import preferences from '@ohos.data.preferences';

const PREF_NAME: string = 'feed_validators';

/** 单个订阅源的缓存校验信息 */
export interface FeedValidator {
  etag: string;
  lastModified: string;
}

/**
 * RSS 条件请求用的校验器（ETag / Last-Modified）。
 *
 * 作用：重新拉取订阅时带上 `If-None-Match` / `If-Modified-Since`，
 * 服务端返回 304 就说明「自上次以来没更新」——此时**不下载正文、不解析 XML**，
 * 对境外慢源来说能省掉整次传输（这是客户端侧对「境外播客慢」最直接的优化）。
 *
 * 存储用 Preferences（键 = feed URL，值 = JSON），不写数据库、不参与迁移。
 */
export class FeedValidators {
  private static instance: preferences.Preferences | undefined = undefined;
  private static memory: Map<string, FeedValidator> = new Map<string, FeedValidator>();
  private static loaded: boolean = false;

  static init(context: common.Context): void {
    if (FeedValidators.instance !== undefined) {
      return;
    }
    const options: preferences.Options = { name: PREF_NAME };
    FeedValidators.instance = preferences.getPreferencesSync(context, options);
  }

  private static loadOnce(): void {
    if (FeedValidators.loaded) {
      return;
    }
    FeedValidators.loaded = true;
    const prefs: preferences.Preferences | undefined = FeedValidators.instance;
    if (prefs === undefined) {
      return;
    }
    try {
      const raw: string = prefs.getSync('map', '') as string;
      if (raw === '') {
        return;
      }
      const parsed: Record<string, FeedValidator> = JSON.parse(raw) as Record<string, FeedValidator>;
      for (const key of Object.keys(parsed)) {
        FeedValidators.memory.set(key, parsed[key]);
      }
    } catch (error) {
      FeedValidators.memory.clear();
    }
  }

  static get(url: string): FeedValidator | undefined {
    FeedValidators.loadOnce();
    return FeedValidators.memory.get(url);
  }

  static set(url: string, etag: string, lastModified: string): void {
    FeedValidators.loadOnce();
    if (etag === '' && lastModified === '') {
      FeedValidators.memory.delete(url);
    } else {
      FeedValidators.memory.set(url, { etag: etag, lastModified: lastModified });
    }
    FeedValidators.persist();
  }

  private static persist(): void {
    const prefs: preferences.Preferences | undefined = FeedValidators.instance;
    if (prefs === undefined) {
      return;
    }
    const obj: Record<string, FeedValidator> = {};
    FeedValidators.memory.forEach((value: FeedValidator, key: string) => {
      obj[key] = value;
    });
    prefs.putSync('map', JSON.stringify(obj));
    prefs.flush();
  }
}
