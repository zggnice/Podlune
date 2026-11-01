// 榜单数据源（每天 08:00 换一次缓存）
//
// 中文播客榜：xyzrank.com（小宇宙榜单的公开镜像）
//   /api/episodes       热门节目
//   /api/podcasts       热门播客
//   /api/new-episodes   新锐节目
//   /api/new-podcasts   新锐播客
//
// 苹果播客榜：Apple 官方公开榜单（与 podcasts.apple.com/cn/charts 同源）
//   rss.marketingtools.apple.com/api/v2/cn/podcasts/top/N/podcasts.json → 热门播客
//   热门节目：Apple 未公开单集热度接口，这里取「Apple 榜单节目的最新一集」，界面会注明
import { HttpClient, HttpResponse } from '../net/HttpClient';
import { AppleCharts, ChartEntry } from '../net/AppleCharts';
import { FeedFetcher } from './FeedFetcher';
import { ParseResult } from '../parser/FeedParser';
import { Logger } from '../utils/Logger';

const TAG: string = 'ChartService';

/** 中文播客榜的四种列表 */
export enum XyzList {
  HOT_EPISODES = 'episodes',
  HOT_PODCASTS = 'podcasts',
  NEW_EPISODES = 'new-episodes',
  NEW_PODCASTS = 'new-podcasts'
}

/** 榜单条目（节目 / 播客共用） */
export interface RankItem {
  rank: number;
  title: string;
  subtitle: string;
  imageUrl: string;
  /** 播客：可订阅；节目：为空 */
  feedUrl: string;
  playCount: number;
  commentCount: number;
  /** 节目时长（分钟） */
  durationMin: number;
  podcastName: string;
  /** 外部链接（小宇宙 / Apple），仅展示 */
  link: string;
  /** 单集快照（previewJson）：非空时点卡片直接进单集详情 */
  previewJson: string;
  /** true = 单集条目；false = 播客条目（决定点击去哪个页面） */
  isEpisode: boolean;
}

/** Apple charts 页面里解析出来的一条单集 */
interface RawAppleEpisode {
  title: string;
  podcastId: number;
  episodeId: string;
  link: string;
}

/** iTunes lookup 得到的播客简介 */
interface ApplePodcastBrief {
  title: string;
  imageUrl: string;
  feedUrl: string;
}

export class ChartService {
  private static readonly XYZ_BASE: string = 'https://xyzrank.com/api';
  /** Apple 榜单页（服务端渲染，单集条目在 HTML 里） */
  private static readonly APPLE_CHARTS_URL: string = 'https://podcasts.apple.com/cn/charts';
  private static readonly APPLE_HEADERS: Record<string, string> = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      + '(KHTML, like Gecko) Chrome/124.0 Safari/537.36',
    'Accept-Language': 'zh-CN,zh;q=0.9'
  };
  private static readonly TIMEOUT_MS: number = 12000;
  /** 每天 08:00 视为新的一天：过了这个点旧缓存作废 */
  private static readonly REFRESH_HOUR: number = 8;
  private static cache: Map<string, RankItem[]> = new Map<string, RankItem[]>();
  private static cacheStamp: Map<string, string> = new Map<string, string>();

  /** 当前「榜单日」：08:00 之前仍算前一天 */
  private static chartDay(): string {
    const now: Date = new Date();
    const shifted: Date = new Date(now.getTime() - ChartService.REFRESH_HOUR * 3600 * 1000);
    return shifted.getFullYear() + '-' + (shifted.getMonth() + 1) + '-' + shifted.getDate();
  }

  private static isFresh(key: string): boolean {
    const stamp: string | undefined = ChartService.cacheStamp.get(key);
    return stamp !== undefined && stamp === ChartService.chartDay()
      && (ChartService.cache.get(key) ?? []).length > 0;
  }

  /** 中文榜：四种列表之一 */
  static async xyz(list: XyzList, force: boolean = false): Promise<RankItem[]> {
    const key: string = 'xyz:' + list;
    if (!force && ChartService.isFresh(key)) {
      return ChartService.cache.get(key) ?? [];
    }
    const url: string = `${ChartService.XYZ_BASE}/${list}?offset=0&limit=50`;
    try {
      const response: HttpResponse = await HttpClient.get(url, {}, ChartService.TIMEOUT_MS);
      const root: Record<string, Object> = JSON.parse(response.body) as Record<string, Object>;
      const rawItems: Object[] = (root['items'] as Object[]) ?? [];
      const isEpisode: boolean = list === XyzList.HOT_EPISODES || list === XyzList.NEW_EPISODES;
      const out: RankItem[] = [];
      for (const raw of rawItems) {
        const item: Record<string, Object> = raw as Record<string, Object>;
        const rank: number = Number(item['rank'] !== undefined ? String(item['rank']) : '0');
        out.push({
          rank: rank > 0 ? rank : out.length + 1,
          title: isEpisode ? ChartService.text(item['title']) : ChartService.text(item['name']),
          subtitle: isEpisode ? ChartService.text(item['podcastName'])
            : ChartService.text(item['authorsText']),
          imageUrl: ChartService.text(item['logoURL']),
          feedUrl: isEpisode ? '' : ChartService.rssOf(item),
          playCount: ChartService.numOf(item, 'playCount', 'avgPlayCount'),
          commentCount: ChartService.numOf(item, 'commentCount', 'avgCommentCount'),
          durationMin: ChartService.numOf(item, 'duration', 'avgDuration'),
          podcastName: ChartService.text(item['podcastName']),
          link: ChartService.text(item['link']),
          previewJson: '',
          isEpisode: list === XyzList.HOT_EPISODES || list === XyzList.NEW_EPISODES
        });
      }
      ChartService.cache.set(key, out);
      ChartService.cacheStamp.set(key, ChartService.chartDay());
      return out;
    } catch (error) {
      Logger.warn(TAG, 'xyz ' + list + ' failed: ' + (error as Error).message);
      return ChartService.cache.get(key) ?? [];
    }
  }

  /** 苹果播客榜：热门播客（Apple cn 官方榜单，与网页版同一个数据源） */
  static async applePodcasts(force: boolean = false): Promise<RankItem[]> {
    const key: string = 'apple:podcasts';
    if (!force && ChartService.isFresh(key)) {
      return ChartService.cache.get(key) ?? [];
    }
    const entries: ChartEntry[] = await AppleCharts.top('cn', 60);
    // 榜单只给目录 id：批量 lookup 拿 feedUrl，用户点进去能直接订阅
    const ids: number[] = [];
    for (const entry of entries) {
      ids.push(entry.id);
    }
    const feeds: Map<number, string> = await ChartService.feedUrls(ids);
    const out: RankItem[] = [];
    for (let i: number = 0; i < entries.length; i++) {
      const entry: ChartEntry = entries[i];
      out.push({
        rank: i + 1,
        title: entry.title,
        subtitle: entry.author,
        imageUrl: entry.artworkUrl100,
        feedUrl: feeds.get(entry.id) ?? '',
        playCount: 0,
        commentCount: 0,
        durationMin: 0,
        podcastName: '',
        link: 'https://podcasts.apple.com/cn/podcast/id' + entry.id,
        previewJson: '',
        isEpisode: false
      });
    }
    ChartService.cache.set(key, out);
    ChartService.cacheStamp.set(key, ChartService.chartDay());
    return out;
  }

  /**
   * 苹果播客榜：热门单集。
   *
   * Apple 没有公开的单集榜 JSON 接口（`/top/N/episodes.json` 返回 404），
   * 但 `podcasts.apple.com/cn/charts` 是**服务端渲染**的：单集条目直接写在 HTML 里
   * （`data-testid="episode-wrapper__artwork"` + `?i=` 单集链接 + `img alt` 标题）。
   * 这里解析这份 HTML 得到与网页完全一致的热门单集顺序，再用 iTunes lookup
   * 把 podcastId 换成 feedUrl（点进去即可订阅）。
   *
   * 注意：依赖 Apple 页面结构，改版会失效——失败时返回空数组并保留旧缓存。
   */
  static async appleHotEpisodes(force: boolean = false): Promise<RankItem[]> {
    const key: string = 'apple:hot-episodes';
    if (!force && ChartService.isFresh(key)) {
      return ChartService.cache.get(key) ?? [];
    }
    try {
      const response: HttpResponse = await HttpClient.get(ChartService.APPLE_CHARTS_URL,
        ChartService.APPLE_HEADERS, 20000);
      const html: string = response.body;
      const blocks: string[] = html.split('data-testid="episode-wrapper__artwork"');
      const rawEpisodes: RawAppleEpisode[] = [];
      const seen: Set<string> = new Set<string>();
      for (let i: number = 1; i < blocks.length; i++) {
        const block: string = blocks[i];
        const linkMatch: RegExpMatchArray | null =
          block.match(/href="(https:\/\/podcasts\.apple\.com\/cn\/podcast\/[^"]+?\/id(\d+)\?i=(\d+))"/);
        const altMatch: RegExpMatchArray | null = block.match(/alt="([^"]+)"/);
        if (linkMatch === null || altMatch === null) {
          continue;
        }
        const episodeId: string = linkMatch[3];
        if (seen.has(episodeId)) {
          continue;
        }
        seen.add(episodeId);
        rawEpisodes.push({
          title: ChartService.unescape(altMatch[1]),
          podcastId: Number(linkMatch[2]),
          episodeId: episodeId,
          link: linkMatch[1]
        });
        if (rawEpisodes.length >= 40) {
          break;
        }
      }
      const podcastIds: number[] = [];
      for (const raw of rawEpisodes) {
        if (podcastIds.indexOf(raw.podcastId) < 0) {
          podcastIds.push(raw.podcastId);
        }
      }
      const info: Map<number, ApplePodcastBrief> = await ChartService.appleInfo(podcastIds);
      const out: RankItem[] = [];
      for (const raw of rawEpisodes) {
        const brief: ApplePodcastBrief | undefined = info.get(raw.podcastId);
        out.push({
          rank: out.length + 1,
          title: raw.title,
          subtitle: brief === undefined ? '' : brief.title,
          imageUrl: brief === undefined ? '' : brief.imageUrl,
          feedUrl: brief === undefined ? '' : brief.feedUrl,
          playCount: 0,
          commentCount: 0,
          durationMin: 0,
          podcastName: brief === undefined ? '' : brief.title,
          link: raw.link,
          previewJson: '',
          isEpisode: true
        });
      }
      ChartService.cache.set(key, out);
      ChartService.cacheStamp.set(key, ChartService.chartDay());
      return out;
    } catch (error) {
      Logger.warn(TAG, 'apple hot episodes failed: ' + (error as Error).message);
      return ChartService.cache.get(key) ?? [];
    }
  }

  /**
   * 苹果播客榜：热门订阅节目（页面里的 `热门订阅节目` 区块）。
   *
   * 该区块在 HTML 里由 `aria-label="热门订阅节目"` 的 section 承载，
   * 条目是 `https://podcasts.apple.com/cn/podcast/<slug>/id<id>`（不带 ?i= 单集参数）。
   */
  static async appleSubscribedShows(force: boolean = false): Promise<RankItem[]> {
    const key: string = 'apple:subscribed';
    if (!force && ChartService.isFresh(key)) {
      return ChartService.cache.get(key) ?? [];
    }
    try {
      const response: HttpResponse = await HttpClient.get(ChartService.APPLE_CHARTS_URL,
        ChartService.APPLE_HEADERS, 20000);
      const html: string = response.body;
      const marker: number = html.indexOf('aria-label="热门订阅节目"');
      const scope: string = marker >= 0 ? html.substring(marker, marker + 60000) : html;
      const ids: number[] = [];
      const titles: Map<number, string> = new Map<number, string>();
      const re: RegExp = /href="https:\/\/podcasts\.apple\.com\/cn\/podcast\/[^"]*?\/id(\d+)"/g;
      let match: RegExpExecArray | null = re.exec(scope);
      while (match !== null) {
        const id: number = Number(match[1]);
        if (id > 0 && ids.indexOf(id) < 0) {
          ids.push(id);
          // 标题优先取同一条目里的 alt 文本
          const slice: string = scope.substring(match.index, Math.min(scope.length, match.index + 1200));
          const alt: RegExpMatchArray | null = slice.match(/alt="([^"]+)"/);
          if (alt !== null) {
            titles.set(id, ChartService.unescape(alt[1]));
          }
        }
        match = re.exec(scope);
      }
      const info: Map<number, ApplePodcastBrief> = await ChartService.appleInfo(ids.slice(0, 50));
      const out: RankItem[] = [];
      for (const id of ids) {
        const brief: ApplePodcastBrief | undefined = info.get(id);
        if (brief === undefined) {
          continue;
        }
        out.push({
          rank: out.length + 1,
          title: brief.title !== '' ? brief.title : (titles.get(id) ?? ''),
          subtitle: '',
          imageUrl: brief.imageUrl,
          feedUrl: brief.feedUrl,
          playCount: 0,
          commentCount: 0,
          durationMin: 0,
          podcastName: brief.title,
          link: 'https://podcasts.apple.com/cn/podcast/id' + id,
          previewJson: '',
          isEpisode: false
        });
      }
      ChartService.cache.set(key, out);
      ChartService.cacheStamp.set(key, ChartService.chartDay());
      return out;
    } catch (error) {
      Logger.warn(TAG, 'apple subscribed shows failed: ' + (error as Error).message);
      return ChartService.cache.get(key) ?? [];
    }
  }

  /** 批量把 Apple podcastId 换成 feedUrl（榜单订阅用） */
  private static async feedUrls(ids: number[]): Promise<Map<number, string>> {
    const map: Map<number, string> = new Map<number, string>();
    if (ids.length === 0) {
      return map;
    }
    const info: Map<number, ApplePodcastBrief> = await ChartService.appleInfo(ids);
    info.forEach((brief: ApplePodcastBrief, id: number) => {
      map.set(id, brief.feedUrl);
    });
    return map;
  }

  /** iTunes lookup 批量取 {标题, 封面, feedUrl} */
  private static async appleInfo(ids: number[]): Promise<Map<number, ApplePodcastBrief>> {
    const out: Map<number, ApplePodcastBrief> = new Map<number, ApplePodcastBrief>();
    const batch: number = 25;
    for (let start: number = 0; start < ids.length; start += batch) {
      const chunk: number[] = ids.slice(start, start + batch);
      try {
        const url: string = 'https://itunes.apple.com/lookup?id=' + chunk.join(',') + '&entity=podcast';
        const response: HttpResponse = await HttpClient.get(url, {}, 10000);
        const root: Record<string, Object> = JSON.parse(response.body) as Record<string, Object>;
        const results: Object[] | undefined = root['results'] as Object[];
        if (results === undefined) {
          continue;
        }
        for (const raw of results) {
          const item: Record<string, Object> = raw as Record<string, Object>;
          const id: number = Number(ChartService.text(item['collectionId']));
          if (!(id > 0)) {
            continue;
          }
          out.set(id, {
            title: ChartService.text(item['collectionName']),
            imageUrl: ChartService.text(item['artworkUrl600']),
            feedUrl: ChartService.text(item['feedUrl'])
          });
        }
      } catch (error) {
        Logger.warn(TAG, 'apple lookup failed');
      }
    }
    return out;
  }

  private static unescape(text: string): string {
    return text.replace(/&amp;/g, '&').replace(/&quot;/g, '"').replace(/&#39;/g, '\'')
      .replace(/&lt;/g, '<').replace(/&gt;/g, '>');
  }

  /** Apple 榜单条目 → feedUrl（iTunes lookup） */
  private static async feedUrlOfAppleLink(link: string): Promise<string> {
    const match: RegExpMatchArray | null = link.match(/id(\d+)/);
    if (match === null || match[1] === undefined) {
      return '';
    }
    try {
      const url: string = 'https://itunes.apple.com/lookup?id=' + match[1] + '&entity=podcast';
      const response: HttpResponse = await HttpClient.get(url, {}, 8000);
      const root: Record<string, Object> = JSON.parse(response.body) as Record<string, Object>;
      const results: Object[] | undefined = root['results'] as Object[];
      if (results === undefined || results.length === 0) {
        return '';
      }
      const item: Record<string, Object> = results[0] as Record<string, Object>;
      return ChartService.text(item['feedUrl']);
    } catch (error) {
      return '';
    }
  }

  private static numOf(item: Record<string, Object>, primary: string, fallback: string): number {
    const raw: Object | undefined = item[primary] !== undefined ? item[primary] : item[fallback];
    const value: number = Number(raw !== undefined ? String(raw) : '0');
    return isNaN(value) ? 0 : Math.round(value);
  }

  private static text(raw: Object | undefined): string {
    return raw === undefined || raw === null ? '' : String(raw);
  }

  /** 播客条目取 rss 链接（links 里 name = rss） */
  private static rssOf(item: Record<string, Object>): string {
    const links: Object[] | undefined = item['links'] as Object[];
    if (links === undefined) {
      return '';
    }
    for (const raw of links) {
      const link: Record<string, Object> = raw as Record<string, Object>;
      if (ChartService.text(link['name']) === 'rss') {
        return ChartService.text(link['url']);
      }
    }
    return '';
  }
}
