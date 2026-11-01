// 榜单里的「节目」条目（没有 feedUrl，只有播客名 + 标题）→ 单集详情快照
//
// 流程（点卡片时按需执行，避免一进页面就批量拉 RSS）：
//   1. 用播客名做 iTunes 检索，拿到该播客的 RSS 地址；
//   2. 拉一次 RSS（内存缓存），按标题归一化匹配这一集；
//   3. 用匹配到的 FeedItem 生成 EpisodeDetailPage 的 previewJson（可只读浏览 + 在线播放）。
import { HttpClient, HttpResponse } from '../net/HttpClient';
import { FeedFetcher } from './FeedFetcher';
import { ParseResult } from '../parser/FeedParser';
import { FeedItem } from '../model/FeedItem';
import { FeedMedia } from '../model/FeedMedia';
import { Logger } from '../utils/Logger';

const TAG: string = 'ChartResolver';

/** 与 EpisodeDetailPage.loadPreview 读取的字段一一对应 */
interface EpisodeSnapshot {
  id: number;
  title: string;
  pubDate: number;
  link: string;
  description: string;
  feedId: number;
  feedTitle: string;
  feedImage: string;
  itemIdentifier: string;
  imageUrl: string;
  transcriptType: string;
  transcriptUrl: string;
  mediaId: number;
  audioUrl: string;
  duration: number;
  mimeType: string;
}

export interface ResolvedEpisode {
  feedUrl: string;
  /** EpisodeDetailPage 直接消费的快照 JSON；空串表示没匹配到 */
  previewJson: string;
}

export class ChartEpisodeResolver {
  /** 播客名 → feedUrl 缓存 */
  private static feedByNames: Map<string, string> = new Map<string, string>();
  /** feedUrl → 单集列表缓存 */
  private static itemsByFeed: Map<string, FeedItem[]> = new Map<string, FeedItem[]>();

  /** 播客名 → RSS（iTunes 检索；结果缓存，失败返回空串） */
  static async feedUrlByName(name: string): Promise<string> {
    const cached: string | undefined = ChartEpisodeResolver.feedByNames.get(name);
    if (cached !== undefined) {
      return cached;
    }
    let feedUrl: string = '';
    try {
      const url: string = 'https://itunes.apple.com/search?term=' + encodeURIComponent(name)
        + '&entity=podcast&country=cn&limit=5';
      const response: HttpResponse = await HttpClient.get(url, {}, 10000);
      const root: Record<string, Object> = JSON.parse(response.body) as Record<string, Object>;
      const results: Object[] | undefined = root['results'] as Object[];
      if (results !== undefined) {
        for (const raw of results) {
          const item: Record<string, Object> = raw as Record<string, Object>;
          const collection: string = item['collectionName'] === undefined
            ? '' : String(item['collectionName']);
          const candidate: string = item['feedUrl'] === undefined ? '' : String(item['feedUrl']);
          if (candidate === '') {
            continue;
          }
          if (collection === name) {
            feedUrl = candidate;
            break;
          }
          if (feedUrl === '') {
            feedUrl = candidate;
          }
        }
      }
    } catch (error) {
      Logger.warn(TAG, 'lookup failed: ' + name);
    }
    ChartEpisodeResolver.feedByNames.set(name, feedUrl);
    return feedUrl;
  }

  /** 按「播客名 + 单集标题」解析出可播放的单集快照 */
  /**
   * @param feedUrlHint 已知的 RSS（苹果榜能从 podcastId 精确查到，优先用它；
   *                    为空时再用播客名做 iTunes 检索）
   */
  static async resolve(podcastName: string, episodeTitle: string,
                       imageUrl: string, feedUrlHint: string = ''): Promise<ResolvedEpisode> {
    const feedUrl: string = feedUrlHint !== ''
      ? feedUrlHint : await ChartEpisodeResolver.feedUrlByName(podcastName);
    if (feedUrl === '') {
      return { feedUrl: '', previewJson: '' };
    }
    const items: FeedItem[] = await ChartEpisodeResolver.itemsOf(feedUrl);
    const matched: FeedItem | undefined = ChartEpisodeResolver.match(items, episodeTitle);
    if (matched === undefined) {
      return { feedUrl: feedUrl, previewJson: '' };
    }
    return { feedUrl: feedUrl, previewJson: ChartEpisodeResolver.snapshot(matched, podcastName, imageUrl) };
  }

  private static async itemsOf(feedUrl: string): Promise<FeedItem[]> {
    const cached: FeedItem[] | undefined = ChartEpisodeResolver.itemsByFeed.get(feedUrl);
    if (cached !== undefined) {
      return cached;
    }
    try {
      const result: ParseResult = await FeedFetcher.fetchFeed(feedUrl, '', '', 10000);
      const items: FeedItem[] = result.feed.items;
      ChartEpisodeResolver.itemsByFeed.set(feedUrl, items);
      return items;
    } catch (error) {
      Logger.warn(TAG, 'rss failed: ' + feedUrl);
      return [];
    }
  }

  /** 标题归一化后匹配（排行榜标题与 RSS 标题常有引号/空格/标点差异） */
  private static match(items: FeedItem[], title: string): FeedItem | undefined {
    const target: string = ChartEpisodeResolver.normalize(title);
    if (target === '' || items.length === 0) {
      return undefined;
    }
    const head: string = target.length > 8 ? target.substring(0, 8) : target;
    let fuzzy: FeedItem | undefined = undefined;
    let byPrefix: FeedItem | undefined = undefined;
    for (const item of items) {
      const normalized: string = ChartEpisodeResolver.normalize(item.title);
      if (normalized === target) {
        return item;
      }
      if (fuzzy === undefined && normalized !== ''
        && (normalized.indexOf(target) >= 0 || target.indexOf(normalized) >= 0)) {
        fuzzy = item;
      }
      if (byPrefix === undefined && normalized !== ''
        && (normalized.indexOf(head) >= 0 || head.indexOf(normalized.substring(0, 8)) === 0)) {
        byPrefix = item;
      }
    }
    return fuzzy !== undefined ? fuzzy : byPrefix;
  }

  private static normalize(text: string): string {
    return text
      // Apple 榜单会把过长标题截断成「…」/「...」：先去掉尾巴再比
      .replace(/[…\.]{2,}$/g, '')
      .replace(/[\s\u3000「」『』“”"'’‘《》<>\[\]()（）!！?？,，.。:：;；·—–\-]/g, '')
      .toLowerCase();
  }

  private static snapshot(item: FeedItem, feedTitle: string, imageUrl: string): string {
    const media: FeedMedia | undefined = item.media;
    const payload: EpisodeSnapshot = {
      id: item.id,
      title: item.title,
      pubDate: item.pubDate,
      link: item.link,
      description: item.description,
      feedId: item.feedId,
      feedTitle: feedTitle,
      feedImage: imageUrl !== '' ? imageUrl : item.feedImage,
      itemIdentifier: item.itemIdentifier,
      imageUrl: item.imageUrl !== '' ? item.imageUrl : imageUrl,
      transcriptType: '',
      transcriptUrl: '',
      mediaId: media === undefined ? 0 : media.id,
      audioUrl: media === undefined ? '' : media.downloadUrl,
      duration: media === undefined ? 0 : media.duration,
      mimeType: media === undefined ? '' : media.mimeType
    };
    return JSON.stringify(payload);
  }
}
