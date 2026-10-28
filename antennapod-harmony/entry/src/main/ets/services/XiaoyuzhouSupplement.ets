import { HttpClient, HttpResponse } from '../net/HttpClient';
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
      const item: Record<string, Object> = entry as Record<string, Object>;
      const eid: string = item['eid'] !== undefined ? String(item['eid']) : '';
      const title: string = item['title'] !== undefined ? String(item['title']) : '';
      const enclosure: Record<string, Object> = item['enclosure'] as Record<string, Object>;
      const audioUrl: string = enclosure !== undefined && enclosure['url'] !== undefined
        ? String(enclosure['url']) : '';
      if (eid === '' || title === '' || audioUrl === '') {
        continue;
      }
      const pubDateText: string = item['pubDate'] !== undefined ? String(item['pubDate']) : '';
      const pubDate: number = pubDateText === '' ? 0 : Date.parse(pubDateText);
      const durationText: string = item['duration'] !== undefined ? String(item['duration']) : '0';
      const duration: number = Number(durationText);
      const imageUrl: string = item['image'] !== undefined ? String(item['image']) : feed.imageUrl;
      output.push(new FeedItem({
        id: 0,
        title: title,
        pubDate: Number.isFinite(pubDate) ? pubDate : 0,
        isPlayed: false,
        playState: FeedItem.UNPLAYED,
        link: XiaoyuzhouSupplement.PAGE_BASE.replace('/podcast/', '/episode/') + eid,
        description: item['shownotes'] !== undefined ? String(item['shownotes'])
          : (item['description'] !== undefined ? String(item['description']) : ''),
        paymentLink: '',
        media: new FeedMedia({
          id: 0,
          duration: Number.isFinite(duration) ? duration : 0,
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
        // 用平台 eid 作为去重标识：与 RSS 的 guid 不冲突，也不会重复插入
        itemIdentifier: 'xz:' + eid,
        imageUrl: imageUrl,
        autoDownloadEnabled: false,
        podcastIndexChapterUrl: '',
        podcastIndexTranscriptType: '',
        podcastIndexTranscriptUrl: '',
        socialInteractUrl: ''
      }));
    }
    return output;
  }
}
