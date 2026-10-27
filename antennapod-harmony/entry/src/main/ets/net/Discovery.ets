// Port of: net/discovery/{ItunesPodcastSearcher,PodcastSearchResult}.java
import { HttpClient, HttpResponse } from './HttpClient';
import { AppleCharts, ItunesPodcast } from './AppleCharts';

export interface PodcastSearchResult {
  title: string;
  author: string;
  imageUrl: string;
  feedUrl: string;
  /**
   * 以下为「分类推荐」需要的元数据，检索结果里能拿到就填，拿不到留空。
   * 首页 / 分类页的卡片只用到前四个字段，因此新增字段不影响现有 UI。
   */
  /** iTunes 的 primaryGenreName，如 "Technology"、"Society & Culture" */
  genre?: string;
  /** 发布日期（ISO 8601），用于判断节目是否仍在更新 */
  releaseDate?: string;
  /** Apple 目录 id（同一个节目在不同市场的榜单里 id 相同，用于去重） */
  collectionId?: number;
}

export class Discovery {
  private static readonly ITUNES_URL: string = 'https://itunes.apple.com/search';

  /**
   * 把 iTunes 的 100×100 缩略图换成 600×600 高清图。
   *
   * 原实现直接用 `artworkUrl100`（100×100），而首页卡片 116vp ≈ 348px、分类页格子更大，
   * 小图被放大 3~5 倍就是用户看到的「很糊」。Apple 的图片 CDN 约定路径里带尺寸段
   * （`.../100x100bb.jpg`），改成 `600x600bb.jpg` 即可取到同一张图的高清版，无需额外请求。
   */
  private static hdArtwork(url: string | undefined): string {
    if (url === undefined || url === '') {
      return '';
    }
    // 只替换路径末段的 `<n>x<n>bb.jpg`，避免误伤域名或查询串
    return url.replace(/\/\d+x\d+bb\.(jpg|png|jpeg)$/, '/600x600bb.$1');
  }

  /**
   * 补齐 feedUrl。
   *
   * iTunes **Search** 接口不返回 `feedUrl`（只有 Lookup 才返回），所以直接拿搜索结果去订阅
   * 会得到空串——表现为「点订阅没反应、详情页也显示未订阅」。这里按 collectionId 批量
   * Lookup 一次，把真实的 RSS 地址填回去。
   */
  static async resolveFeedUrls(items: PodcastSearchResult[]): Promise<void> {
    const ids: number[] = [];
    for (const item of items) {
      const cid: number = item.collectionId === undefined ? 0 : item.collectionId;
      if (item.feedUrl === '' && cid > 0) {
        ids.push(cid);
      }
    }
    if (ids.length === 0) {
      return;
    }
    try {
      const found: Map<number, ItunesPodcast> = await AppleCharts.lookup(ids);
      for (const item of items) {
        const cid: number = item.collectionId === undefined ? 0 : item.collectionId;
        const hit = found.get(cid);
        if (hit !== undefined && hit.feedUrl !== '') {
          item.feedUrl = hit.feedUrl;
        }
      }
    } catch (error) {
      // Lookup 失败就保留空串：调用方会把卡片标成「暂无订阅地址」，不会假装成功
    }
  }

  static async searchPodcasts(term: string, limit: number = 30): Promise<PodcastSearchResult[]> {
    const url: string = Discovery.ITUNES_URL + '?media=podcast&limit=' + limit + '&term=' + encodeURIComponent(term);
    const response: HttpResponse = await HttpClient.get(url);
    const data: Record<string, object> = JSON.parse(response.body) as Record<string, object>;
    const results: object[] = data['results'] as object[];
    const output: PodcastSearchResult[] = [];
    if (results === undefined) {
      return output;
    }
    for (const raw of results) {
      const item: Record<string, string> = raw as Record<string, string>;
      const collectionId: number = item['collectionId'] !== undefined ? Number(item['collectionId']) : 0;
      output.push({
        title: item['collectionName'] !== undefined ? item['collectionName'] : '',
        author: item['artistName'] !== undefined ? item['artistName'] : '',
        imageUrl: Discovery.hdArtwork(item['artworkUrl100']),
        feedUrl: item['feedUrl'] !== undefined ? item['feedUrl'] : '',
        genre: item['primaryGenreName'] !== undefined ? item['primaryGenreName'] : '',
        releaseDate: item['releaseDate'] !== undefined ? item['releaseDate'] : '',
        collectionId: collectionId
      });
    }
    return output;
  }
}
