// Apple Podcasts 公开榜单 + iTunes Lookup 客户端（无需 API Key，均为公开接口）
import { HttpClient, HttpResponse } from './HttpClient';

/** 榜单条目（先只有目录 id，feedUrl 需要再查一次 lookup） */
export interface ChartEntry {
  id: number;
  title: string;
  author: string;
  artworkUrl100: string;
  genres: string[];
  /** 在该市场的名次（1 = 第 1 名） */
  rank: number;
  country: string;
}

/** iTunes Lookup 结果（含 feedUrl、分类、发布时间） */
export interface ItunesPodcast {
  id: number;
  title: string;
  author: string;
  imageUrl: string;
  feedUrl: string;
  genre: string;
  /** ISO 时间；解析失败为空串 */
  releaseDate: string;
}

export class AppleCharts {
  /** Apple 官方公开榜单（Top Shows），无鉴权 */
  private static readonly CHART_BASE: string = 'https://rss.marketingtools.apple.com/api/v2';
  /** iTunes Search/Lookup，无鉴权 */
  private static readonly ITUNES_LOOKUP: string = 'https://itunes.apple.com/lookup';
  /** 榜单/lookup 允许的等待时间：拿不到就降级，不让整页卡在骨架屏 */
  // 榜单接口本身较慢（实测偶尔要 10s+）：15 秒内拿不到才放弃该市场，
  // 四个市场是并发发起的，整页等待不超过这个值。
  private static readonly TIMEOUT_MS: number = 15000;
  /** lookup 单次可带多个 id；分批发请求，避免 URL 过长 */
  private static readonly LOOKUP_BATCH: number = 25;

  private static hdArtwork(url: string): string {
    if (url === '') {
      return '';
    }
    return url.replace(/\/\d+x\d+bb\.(jpg|png|jpeg)$/, '/600x600bb.$1');
  }

  /**
   * 取某个国家/地区的播客榜单。
   *
   * 注意：这是 Apple 的公开榜单，反映该市场的收录与热度排序，
   * **不等同于全网精确收听人数排名**，只能当热度依据。
   */
  static async top(country: string, limit: number): Promise<ChartEntry[]> {
    const url: string = `${AppleCharts.CHART_BASE}/${country}/podcasts/top/${limit}/podcasts.json`;
    const response: HttpResponse = await HttpClient.get(url, {}, AppleCharts.TIMEOUT_MS);
    const root: Record<string, Object> = JSON.parse(response.body) as Record<string, Object>;
    const feed: Record<string, Object> = root['feed'] as Record<string, Object>;
    if (feed === undefined) {
      return [];
    }
    const results: Object[] = feed['results'] as Object[];
    if (results === undefined) {
      return [];
    }
    const output: ChartEntry[] = [];
    let rank: number = 0;
    for (const raw of results) {
      rank++;
      const item: Record<string, Object> = raw as Record<string, Object>;
      const idText: string = item['id'] !== undefined ? String(item['id']) : '';
      const id: number = Number(idText);
      if (!(id > 0)) {
        continue;
      }
      const genres: string[] = [];
      const rawGenres: Object[] | undefined = item['genres'] as Object[];
      if (rawGenres !== undefined) {
        for (const g of rawGenres) {
          const gm: Record<string, string> = g as Record<string, string>;
          if (gm['name'] !== undefined && gm['name'] !== '') {
            genres.push(gm['name']);
          }
        }
      }
      output.push({
        id: id,
        title: item['name'] !== undefined ? String(item['name']) : '',
        author: item['artistName'] !== undefined ? String(item['artistName']) : '',
        artworkUrl100: item['artworkUrl100'] !== undefined ? String(item['artworkUrl100']) : '',
        genres: genres,
        rank: rank,
        country: country
      });
    }
    return output;
  }

  /**
   * Apple 的另一条官方榜单通道（iTunes Store Top Podcasts RSS）。
   *
   * 与 `top()` 是同源数据的不同出口：marketingtools 偶尔整体超时/Internal error，
   * 这条通常更快，作为备用通道可显著降低「榜单拿不到 → 页面空白」的概率。
   * 同样只给目录 id，feedUrl 仍需 lookup。
   */
  static async topRss(country: string, limit: number): Promise<ChartEntry[]> {
    const url: string = `https://itunes.apple.com/${country}/rss/toppodcasts/limit=${limit}/json`;
    const response: HttpResponse = await HttpClient.get(url, {}, AppleCharts.TIMEOUT_MS);
    const root: Record<string, Object> = JSON.parse(response.body) as Record<string, Object>;
    const feed: Record<string, Object> = root['feed'] as Record<string, Object>;
    if (feed === undefined) {
      return [];
    }
    const entries: Object[] = feed['entry'] as Object[];
    if (entries === undefined) {
      return [];
    }
    const output: ChartEntry[] = [];
    let rank: number = 0;
    for (const raw of entries) {
      rank++;
      const item: Record<string, Object> = raw as Record<string, Object>;
      const nameObj: Record<string, string> = item['im:name'] as Record<string, string>;
      const idObj: Record<string, Object> = item['id'] as Record<string, Object>;
      let id: number = 0;
      if (idObj !== undefined) {
        const attrs: Record<string, string> = idObj['attributes'] as Record<string, string>;
        if (attrs !== undefined && attrs['im:id'] !== undefined) {
          id = Number(attrs['im:id']);
        }
      }
      if (!(id > 0)) {
        continue;
      }
      const artistObj: Record<string, string> = item['im:artist'] as Record<string, string>;
      // im:image 是「小 → 大」的数组，取最后一个当封面
      let artwork: string = '';
      const images: Object[] = item['im:image'] as Object[];
      if (images !== undefined && images.length > 0) {
        const last: Record<string, string> = images[images.length - 1] as Record<string, string>;
        artwork = last['label'] !== undefined ? last['label'] : '';
      }
      const genres: string[] = [];
      const categoryObj: Record<string, Object> = item['category'] as Record<string, Object>;
      if (categoryObj !== undefined) {
        const attrs: Record<string, string> = categoryObj['attributes'] as Record<string, string>;
        if (attrs !== undefined && attrs['label'] !== undefined) {
          genres.push(attrs['label']);
        }
      }
      output.push({
        id: id,
        title: nameObj !== undefined && nameObj['label'] !== undefined ? nameObj['label'] : '',
        author: artistObj !== undefined && artistObj['label'] !== undefined ? artistObj['label'] : '',
        artworkUrl100: artwork,
        genres: genres,
        rank: rank,
        country: country
      });
    }
    return output;
  }

  /** 按目录 id 批量查 feedUrl / 分类 / 发布时间（iTunes Lookup） */
  static async lookup(ids: number[]): Promise<Map<number, ItunesPodcast>> {
    const output: Map<number, ItunesPodcast> = new Map<number, ItunesPodcast>();
    for (let start: number = 0; start < ids.length; start += AppleCharts.LOOKUP_BATCH) {
      const batch: number[] = ids.slice(start, start + AppleCharts.LOOKUP_BATCH);
      if (batch.length === 0) {
        continue;
      }
      const url: string = `${AppleCharts.ITUNES_LOOKUP}?id=${batch.join(',')}&entity=podcast`;
      let response: HttpResponse;
      try {
        response = await HttpClient.get(url, {}, AppleCharts.TIMEOUT_MS);
      } catch (error) {
        // 单批失败不影响其它批：调用方会按「拿不到 feedUrl 就丢弃」处理
        continue;
      }
      const root: Record<string, Object> = JSON.parse(response.body) as Record<string, Object>;
      const results: Object[] | undefined = root['results'] as Object[];
      if (results === undefined) {
        continue;
      }
      for (const raw of results) {
        const item: Record<string, Object> = raw as Record<string, Object>;
        const id: number = item['collectionId'] !== undefined ? Number(item['collectionId']) : 0;
        const feedUrl: string = item['feedUrl'] !== undefined ? String(item['feedUrl']) : '';
        if (!(id > 0)) {
          continue;
        }
        const cover: string = item['artworkUrl600'] !== undefined
          ? String(item['artworkUrl600'])
          : AppleCharts.hdArtwork(item['artworkUrl100'] !== undefined ? String(item['artworkUrl100']) : '');
        output.set(id, {
          id: id,
          title: item['collectionName'] !== undefined ? String(item['collectionName']) : '',
          author: item['artistName'] !== undefined ? String(item['artistName']) : '',
          imageUrl: cover,
          feedUrl: feedUrl,
          genre: item['primaryGenreName'] !== undefined ? String(item['primaryGenreName']) : '',
          releaseDate: item['releaseDate'] !== undefined ? String(item['releaseDate']) : ''
        });
      }
    }
    return output;
  }
}
