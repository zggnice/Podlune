import { HttpClient, HttpResponse } from '../net/HttpClient';
import { FeedFetcher } from './FeedFetcher';
import { Feed } from '../model/Feed';
import { FeedItem } from '../model/FeedItem';
import { FeedMedia } from '../model/FeedMedia';
import { RefreshService, MergeResult } from './RefreshService';
import { UserPreferences } from '../prefs/UserPreferences';
import { Logger } from '../utils/Logger';

const TAG: string = 'XiaoyuzhouSupplement';

/**
 * 停更订阅的「平台网页补全」（实验性，默认关闭）。
 *
 * 背景：小宇宙为每个播客生成的公开 RSS（`feed.xyzfm.space/<id>`）可能长期不重新生成，
 * 于是 App 只能拿到旧条目（实测「钱婧老师的会客厅」停在 Vol.155，而平台内已到 184 期）。
 * 小宇宙的播客网页是服务端渲染的，首屏 `__NEXT_DATA__` 里带有**最新 15 期**的完整信息
 * （标题 / 发布时间 / 时长 / 音频地址），可以把这些条目补进本地库。
 *
 * 边界（重要）：
 * - 仅在用户打开开关后生效；
 * - 每次刷新最多请求 1 次页面，失败静默，不影响正常 RSS 刷新；
 * - 只读取公开页面里的公开数据，不登录、不抓付费/私密内容、不转存音频（只把地址交给播放器）；
 * - 平台改版或加反爬时该功能自动失效。
 */
export class XiaoyuzhouSupplement {
  /** 只处理小宇宙公开源 */
  private static readonly RSS_HOST: string = 'feed.xyzfm.space';
  private static readonly PAGE_BASE: string = 'https://www.xiaoyuzhoufm.com/podcast/';
  private static readonly TIMEOUT_MS: number = 12000;
  /** 页面首屏给多少条就补多少（当前固定 15） */
  private static readonly MAX_ITEMS: number = 20;

  static isEnabled(): boolean {
    return UserPreferences.getSupplementStaleFeeds();
  }

  /**
   * 尝试为某个订阅补全缺失的最新条目。
   *
   * @returns 实际新增的条目数（0 表示不需要 / 未开启 / 失败）
   */
  static async trySupplement(feed: Feed): Promise<number> {
    if (!XiaoyuzhouSupplement.isEnabled()) {
      return 0;
    }
    if (!feed.downloadUrl.toLowerCase().includes(XiaoyuzhouSupplement.RSS_HOST)) {
      return 0;
    }
    const pid: string = XiaoyuzhouSupplement.podcastId(feed.link);
    if (pid === '') {
      return 0;
    }
    try {
      const pageUrl: string = XiaoyuzhouSupplement.PAGE_BASE + pid;
      const response: HttpResponse = await HttpClient.get(pageUrl,
        { 'User-Agent': 'Mozilla/5.0 (Linux; HarmonyOS) Podlune/1.0' }, XiaoyuzhouSupplement.TIMEOUT_MS);
      const items: FeedItem[] = XiaoyuzhouSupplement.parseEpisodes(response.body, feed);
      if (items.length === 0) {
        return 0;
      }
      // initialSubscribe=true：补进来的是历史条目，不进收件箱，按「未播放」落库
      const merge: MergeResult = await RefreshService.mergeSupplementItems(feed, items);
      if (merge.count > 0) {
        Logger.info(TAG, 'supplemented feed ' + feed.id + ' +' + merge.count + ' items from ' + pageUrl);
      }
      return merge.count;
    } catch (error) {
      // 页面结构变化 / 网络失败：保持静默，不影响用户正在进行的刷新
      Logger.warn(TAG, 'supplement failed for feed ' + feed.id + ': ' + (error as Error).message);
      return 0;
    }
  }


  /** 手动补全最多一次处理多少条链接（防止误粘几百行把网络打满） */
  private static readonly MAX_LINKS: number = 50;

  /**
   * 手动补全：解析用户粘贴的小宇宙单集链接，逐条抓取单集页并入到该订阅。
   *
   * 与自动补全的区别：允许插入比库里更早的条目（补历史空档），仍然按标题去重、
   * 仍然只写「未播放」，不进收件箱。封面取 `image.picUrl`，正文取 `shownotes` → `description`。
   *
   * @returns 实际新增的条目数
   */
  static async addFromLinks(feed: Feed, text: string): Promise<number> {
    const urls: string[] = XiaoyuzhouSupplement.extractLinks(text);
    if (urls.length === 0) {
      return 0;
    }
    const items: FeedItem[] = [];
    for (const url of urls) {
      try {
        if (XiaoyuzhouSupplement.isAudioLink(url)) {
          // 单集音频直链：直接建条目，标题取文件名，时长交给播放器加载后回填
          const direct: FeedItem | undefined = XiaoyuzhouSupplement.buildAudioItem(url, feed);
          if (direct !== undefined) {
            items.push(direct);
          }
          continue;
        }
        if (XiaoyuzhouSupplement.isEpisodePage(url)) {
          // 小宇宙单集页：从页面数据里取标题 / 时长 / 封面 / 正文
          const response: HttpResponse = await HttpClient.get(url,
            { 'User-Agent': 'Mozilla/5.0 (Linux; HarmonyOS) Podlune/1.0' }, XiaoyuzhouSupplement.TIMEOUT_MS);
          const item: FeedItem | undefined = XiaoyuzhouSupplement.parseEpisodePage(response.body, feed, url);
          if (item !== undefined) {
            items.push(item);
          }
          continue;
        }
        // 其余按 RSS / Atom 订阅源处理：抓取后把其中的单集并入当前节目
        const parsed = await FeedFetcher.fetchFeed(url);
        for (const item of parsed.feed.items) {
          item.feedId = feed.id;
          items.push(item);
        }
      } catch (error) {
        Logger.warn(TAG, 'supplement link failed ' + url + ': ' + (error as Error).message);
      }
    }
    if (items.length === 0) {
      return 0;
    }
    const merge: MergeResult = await RefreshService.mergeSupplementItems(feed, items, true);
    Logger.info(TAG, 'manual supplement feed ' + feed.id + ' +' + merge.count + ' / ' + items.length);
    return merge.count;
  }

  /**
   * 从一段文本里提取链接（换行 / 空格 / 逗号分隔，自动去重）。
   *
   * 三类都接受：小宇宙单集页链接、单集音频直链、播客 RSS/Atom 地址。
   */
  private static extractLinks(text: string): string[] {
    const output: string[] = [];
    const parts: string[] = text.split(/[\s,，]+/);
    for (const raw of parts) {
      const value: string = raw.trim();
      const normalized: string = value.startsWith('http') ? value
        : (value.startsWith('www.') ? 'https://' + value : '');
      if (normalized === '' || output.includes(normalized)) {
        continue;
      }
      output.push(normalized);
      if (output.length >= XiaoyuzhouSupplement.MAX_LINKS) {
        break;
      }
    }
    return output;
  }

  /** 是否小宇宙单集页 */
  private static isEpisodePage(url: string): boolean {
    const lower: string = url.toLowerCase();
    return lower.includes('xiaoyuzhoufm.com/episode') || lower.includes('/episode/');
  }

  /** 是否是音频直链（按扩展名判断） */
  private static isAudioLink(url: string): boolean {
    const lower: string = url.toLowerCase().split('?')[0];
    return lower.endsWith('.m4a') || lower.endsWith('.mp3') || lower.endsWith('.aac')
      || lower.endsWith('.ogg') || lower.endsWith('.wav') || lower.endsWith('.flac')
      || lower.endsWith('.opus');
  }

  /** URL 解码失败时退回原字符串，避免因为标题里的 % 让整条链接被丢弃 */
  private static safeTitle(name: string): string {
    try {
      return decodeURIComponent(name);
    } catch (error) {
      return name;
    }
  }

  /** 音频直链 → 条目（标题取文件名去掉扩展名，发布时间与时长留空由播放器回填） */
  private static buildAudioItem(url: string, feed: Feed): FeedItem | undefined {
    let name: string = url.split('?')[0];
    const slash: number = name.lastIndexOf('/');
    if (slash >= 0) {
      name = name.substring(slash + 1);
    }
    const dot: number = name.lastIndexOf('.');
    if (dot > 0) {
      name = name.substring(0, dot);
    }
    if (name === '') {
      return undefined;
    }
    return new FeedItem({
      id: 0,
      title: XiaoyuzhouSupplement.safeTitle(name),
      pubDate: 0,
      isPlayed: false,
      playState: FeedItem.UNPLAYED,
      link: url,
      description: '',
      paymentLink: '',
      media: new FeedMedia({
        id: 0,
        duration: 0,
        fileUrl: '',
        downloadUrl: url,
        downloadDate: 0,
        position: 0,
        size: 0,
        mimeType: 'audio/mp4',
        lastPlayedTimeHistory: 0,
        feedItemId: 0,
        playedDuration: 0,
        hasEmbeddedPicture: false,
        lastPlayedTimeStatistics: 0
      }),
      feedId: feed.id,
      hasChapters: false,
      itemIdentifier: 'url:' + url,
      imageUrl: feed.imageUrl,
      autoDownloadEnabled: false,
      podcastIndexChapterUrl: '',
      podcastIndexTranscriptType: '',
      podcastIndexTranscriptUrl: '',
      socialInteractUrl: ''
    });
  }

  /** 解析单集页 `pageProps.episode` */
  private static parseEpisodePage(html: string, feed: Feed, url: string): FeedItem | undefined {
    const open: number = html.indexOf('id="__NEXT_DATA__"');
    if (open < 0) {
      return undefined;
    }
    const jsonStart: number = html.indexOf('>', open);
    const jsonEnd: number = html.indexOf('</script>', jsonStart);
    if (jsonStart < 0 || jsonEnd < 0) {
      return undefined;
    }
    const root: Record<string, Object> = JSON.parse(html.substring(jsonStart + 1, jsonEnd)) as Record<string, Object>;
    const props: Record<string, Object> = root['props'] as Record<string, Object>;
    if (props === undefined) {
      return undefined;
    }
    const pageProps: Record<string, Object> = props['pageProps'] as Record<string, Object>;
    if (pageProps === undefined) {
      return undefined;
    }
    const episode: Record<string, Object> = pageProps['episode'] as Record<string, Object>;
    if (episode === undefined) {
      return undefined;
    }
    return XiaoyuzhouSupplement.buildItem(episode, feed, url);
  }

  /** 从 RSS channel link 里取小宇宙播客 id（形如 .../podcast/<24 位十六进制>） */
  private static podcastId(link: string): string {
    const marker: string = '/podcast/';
    const index: number = link.indexOf(marker);
    if (index < 0) {
      return '';
    }
    let tail: string = link.substring(index + marker.length);
    const cut: number = tail.search(/[?#/]/);
    if (cut >= 0) {
      tail = tail.substring(0, cut);
    }
    return tail.length === 24 ? tail : '';
  }


  /**
   * 由一条小宇宙单集记录构造 FeedItem（列表页与单集页共用）。
   *
   * @param linkUrl 单集页地址；为空时用 `/episode/<eid>` 拼一个
   */
  private static buildItem(item: Record<string, Object>, feed: Feed,
                           linkUrl: string): FeedItem | undefined {
    if (item === undefined || item === null) {
      return undefined;
    }
    const eid: string = item['eid'] !== undefined ? String(item['eid']) : '';
    const title: string = item['title'] !== undefined ? String(item['title']) : '';
    const enclosure: Record<string, Object> = item['enclosure'] as Record<string, Object>;
    const audioUrl: string = enclosure !== undefined && enclosure['url'] !== undefined
      ? String(enclosure['url']) : '';
    if (eid === '' || title === '' || audioUrl === '') {
      return undefined;
    }
    const pubDateText: string = item['pubDate'] !== undefined ? String(item['pubDate']) : '';
    const pubDateRaw: number = pubDateText === '' ? 0 : Date.parse(pubDateText);
    // 小宇宙的 duration 是**秒**，库里（RSS 解析结果）统一用**毫秒**：
    // 不换算会让列表显示成「0:03」这种 3 秒时长。
    const durationText: string = item['duration'] !== undefined ? String(item['duration']) : '0';
    const durationSeconds: number = Number(durationText);
    const durationMs: number = Number.isFinite(durationSeconds) && durationSeconds > 0
      ? Math.round(durationSeconds * 1000) : 0;
    const episodeLink: string = linkUrl !== '' ? linkUrl
      : 'https://www.xiaoyuzhoufm.com/episode/' + eid;
    return new FeedItem({
      id: 0,
      title: title,
      pubDate: Number.isFinite(pubDateRaw) ? pubDateRaw : 0,
      isPlayed: false,
      playState: FeedItem.UNPLAYED,
      link: episodeLink,
      description: XiaoyuzhouSupplement.episodeText(item['shownotes'], item['description']),
      paymentLink: '',
      media: new FeedMedia({
        id: 0,
        duration: durationMs,
        fileUrl: '',
        downloadUrl: audioUrl,
        downloadDate: 0,
        position: 0,
        size: 0,
        mimeType: 'audio/mp4',
        lastPlayedTimeHistory: 0,
        feedItemId: 0,
        playedDuration: 0,
        hasEmbeddedPicture: false,
        lastPlayedTimeStatistics: 0
      }),
      feedId: feed.id,
      hasChapters: false,
      itemIdentifier: 'xz:' + eid,
      imageUrl: XiaoyuzhouSupplement.episodeImage(item['image'], feed.imageUrl),
      autoDownloadEnabled: false,
      podcastIndexChapterUrl: '',
      podcastIndexTranscriptType: '',
      podcastIndexTranscriptUrl: '',
      socialInteractUrl: ''
    });
  }

  /**
   * 单集封面：小宇宙给的 `image` 是对象（`{ picUrl }`），直接 String() 会得到
   * "[object Object]" 而加载失败；取不到时回落到播客封面。
   */
  private static episodeImage(raw: Object | undefined, feedImage: string): string {
    if (raw === undefined || raw === null) {
      return feedImage;
    }
    if (typeof raw === 'string') {
      const text: string = raw as string;
      return text === '' || text === 'null' ? feedImage : text;
    }
    const record: Record<string, Object> = raw as Record<string, Object>;
    const pic: Object | undefined = record['picUrl'];
    if (pic !== undefined && pic !== null) {
      const url: string = String(pic);
      if (url !== '' && url !== 'null') {
        return url;
      }
    }
    return feedImage;
  }

  /**
   * 单集正文：`shownotes` 经常是空字符串，真正的内容在 `description`；
   * 两者都空时返回空串（详情页只显示标题与音频，不会出现 "null"）。
   */
  private static episodeText(shownotes: Object | undefined, description: Object | undefined): string {
    const notes: string = shownotes === undefined || shownotes === null ? '' : String(shownotes);
    if (notes !== '' && notes !== 'null') {
      return notes;
    }
    const desc: string = description === undefined || description === null ? '' : String(description);
    return desc === 'null' ? '' : desc;
  }

  /**
   * 解析页面里的 `__NEXT_DATA__`，产出待补全的条目。
   *
   * 只取公开首屏给到的 `podcast.episodes`；跳过没有音频地址或标题为空的条目。
   */
  private static parseEpisodes(html: string, feed: Feed): FeedItem[] {
    const open: number = html.indexOf('id="__NEXT_DATA__"');
    if (open < 0) {
      return [];
    }
    const jsonStart: number = html.indexOf('>', open);
    const jsonEnd: number = html.indexOf('</script>', jsonStart);
    if (jsonStart < 0 || jsonEnd < 0) {
      return [];
    }
    const raw: string = html.substring(jsonStart + 1, jsonEnd);
    const root: Record<string, Object> = JSON.parse(raw) as Record<string, Object>;
    const props: Record<string, Object> = root['props'] as Record<string, Object>;
    if (props === undefined) {
      return [];
    }
    const pageProps: Record<string, Object> = props['pageProps'] as Record<string, Object>;
    if (pageProps === undefined) {
      return [];
    }
    const podcast: Record<string, Object> = pageProps['podcast'] as Record<string, Object>;
    if (podcast === undefined) {
      return [];
    }
    const episodes: Object[] = podcast['episodes'] as Object[];
    if (episodes === undefined) {
      return [];
    }
    const output: FeedItem[] = [];
    for (const entry of episodes) {
      if (output.length >= XiaoyuzhouSupplement.MAX_ITEMS) {
        break;
      }
      const built: FeedItem | undefined = XiaoyuzhouSupplement.buildItem(
        entry as Record<string, Object>, feed, '');
      if (built !== undefined) {
        output.push(built);
      }
    }
    return output;
  }
}
