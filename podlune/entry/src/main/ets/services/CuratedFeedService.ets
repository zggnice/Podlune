/**
 * 六个推荐板块的真实数据服务。
 *
 * 数据来源（都是公开接口，不需要 API Key）：
 * - 「全球热门」：Apple Podcasts 官方榜单（多市场合并）
 * - 其余五个板块：iTunes Search 主题检索 + 分类元数据过滤打分
 *
 * 关键约束：
 * 1. 不伪造数据：拿不到就返回空，由页面显示原有空状态。
 * 2. 缓存优先：内存 + 本地文件双缓存（TTL 12 小时），未过期不发网络请求。
 * 3. 并发去重：同一个板块同时只跑一个请求。
 * 4. 失败回退：网络失败时使用上一次有效缓存（即使已过期）。
 */
import fs from '@ohos.file.fs';
import type common from '@ohos.app.ability.common';
import { HttpClient } from '../net/HttpClient';
import { Discovery, PodcastSearchResult } from '../net/Discovery';
import { AppleCharts, ChartEntry, ItunesPodcast } from '../net/AppleCharts';
import { CuratedCategories, CuratedCategory } from '../common/CuratedCategories';
import { Logger } from '../utils/Logger';

const TAG: string = 'CuratedFeedService';
const CACHE_FILE: string = 'curated_feeds.json';

interface CacheEntry {
  items: PodcastSearchResult[];
  fetchedAt: number;
  /** 拉取当天的日期键（YYYY-MM-DD）：跨天即失效，保证首页每天换内容 */
  day?: string;
}

/** 落盘结构（只存必要字段，避免把大对象写进 JSON） */
interface StoredItem {
  t: string;
  a: string;
  i: string;
  f: string;
  g: string;
  r: string;
  c: number;
}

interface StoredEntry {
  at: number;
  /** 拉取当天的日期键（老缓存文件没有这个字段，读到时按 undefined 处理） */
  d?: string;
  items: StoredItem[];
}

export class CuratedFeedService {
  /** 缓存有效期：12 小时（榜单/检索结果一天内变化不大，避免频繁打接口） */
  static readonly TTL_MS: number = 12 * 60 * 60 * 1000;
  /** 单个板块的缓存上限：分类页「一直往下滑」靠它兜底，避免无限抓取 */
  private static readonly MAX_ITEMS: number = 120;
  /** 主题词的长尾变体（预置词用完后继续换词，保证分类页还能往下翻） */
  private static readonly TERM_SUFFIXES: string[] = ['podcast', 'daily', 'weekly', 'interview', 'show', 'explained', '2026'];
  /** 榜单每市场取前 N 名 */
  private static readonly CHART_DEPTH: number = 50;

  private static context: common.Context | undefined = undefined;
  private static memory: Map<string, CacheEntry> = new Map<string, CacheEntry>();
  private static inflight: Map<string, Promise<PodcastSearchResult[]>> = new Map<string, Promise<PodcastSearchResult[]>>();
  /** 每个分类已用掉的检索词下标（跨调用累计，loadMore 才能继续往后换词） */
  private static termCursor: Map<string, number> = new Map<string, number>();
  private static fileLoaded: boolean = false;
  /** 各板块上次失败时间：短时间内不再重试，避免网络差时反复超时拖慢启动 */
  private static lastFailAt: Map<string, number> = new Map<string, number>();
  private static readonly FAIL_BACKOFF_MS: number = 5 * 60 * 1000;
  private static readonly FAIL_FILE: string = 'curated_fails.json';
  private static failLoaded: boolean = false;

  /** 应用启动时注入上下文（用于本地缓存文件） */
  static init(context: common.Context): void {
    CuratedFeedService.context = context;
  }

  /** 同步读取当前缓存（可能为空数组）：先把已有内容画出来，再决定是否刷新 */
  static peek(id: string): PodcastSearchResult[] {
    CuratedFeedService.loadFileOnce();
    const entry: CacheEntry | undefined = CuratedFeedService.memory.get(id);
    if (entry === undefined) {
      return [];
    }
    return entry.items.slice();
  }

  /** 缓存是否仍然新鲜 */
  static isFresh(id: string): boolean {
    CuratedFeedService.loadFileOnce();
    const entry: CacheEntry | undefined = CuratedFeedService.memory.get(id);
    if (entry === undefined) {
      return false;
    }
    // 跨天直接视为过期：即便 12 小时 TTL 还没到，第二天也要重新取一批
    if (entry.day !== undefined && entry.day !== CuratedFeedService.todayKey()) {
      return false;
    }
    return Date.now() - entry.fetchedAt < CuratedFeedService.TTL_MS;
  }

  /** 当地日期键（YYYY-MM-DD），用于「每天一批」的判定 */
  private static todayKey(): string {
    const now: Date = new Date();
    const month: string = (now.getMonth() + 1) < 10
      ? '0' + (now.getMonth() + 1) : (now.getMonth() + 1).toString();
    const day: string = now.getDate() < 10 ? '0' + now.getDate() : now.getDate().toString();
    return now.getFullYear().toString() + '-' + month + '-' + day;
  }

  /** 日期 + 板块 id 的稳定种子（同一天同一板块顺序固定，换天就换一批） */
  private static dailySeed(id: string): number {
    const key: string = CuratedFeedService.todayKey() + '#' + id;
    let hash: number = 2166136261;
    for (let i = 0; i < key.length; i++) {
      hash ^= key.charCodeAt(i);
      hash = Math.imul(hash, 16777619);
    }
    return hash >>> 0;
  }

  /**
   * 按当天种子做确定性洗牌（mulberry32）。
   * 数组内部顺序每天不同，但同一天内每次读取顺序一致 —— 首页不会「划走再回来就变样」。
   */
  private static shuffleForDay(items: PodcastSearchResult[], id: string): PodcastSearchResult[] {
    const out: PodcastSearchResult[] = items.slice();
    let state: number = CuratedFeedService.dailySeed(id);
    const next = (): number => {
      state += 0x6D2B79F5;
      let t: number = state;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
    for (let i = out.length - 1; i > 0; i--) {
      const j: number = Math.floor(next() * (i + 1));
      const tmp: PodcastSearchResult = out[i];
      out[i] = out[j];
      out[j] = tmp;
    }
    return out;
  }

  /**
   * 取某个板块的推荐节目。
   *
   * - 缓存新鲜 → 直接返回，不发请求
   * - 缓存过期或没有 → 拉一次；失败则回退到旧缓存（可能为空）
   * - 同一板块并发调用共用同一个 Promise
   */
  static async load(id: string, want: number): Promise<PodcastSearchResult[]> {
    CuratedFeedService.loadFileOnce();
    const wanted: number = want > 0 ? want : CuratedCategories.PREVIEW_SIZE;
    // 缓存新鲜就直接用：即使条数少于 wanted 也不重新打接口（分类页会靠 loadMore 增量补齐），
    // 否则首页已经拉过一轮，进分类页又要为「凑够 21 条」重跑一遍榜单/检索，表现为长时间「加载中」。
    if (CuratedFeedService.isFresh(id)) {
      const cached: PodcastSearchResult[] = CuratedFeedService.peek(id);
      if (cached.length > 0) {
        return cached;
      }
    }
    CuratedFeedService.loadFailsOnce();
    // 刚失败过：短时间内不再请求，直接用现有缓存（可能为空），保证首页滚动不被超时拖慢
    const failedAt: number | undefined = CuratedFeedService.lastFailAt.get(id);
    if (failedAt !== undefined && Date.now() - failedAt < CuratedFeedService.FAIL_BACKOFF_MS) {
      return CuratedFeedService.peek(id);
    }
    const running: Promise<PodcastSearchResult[]> | undefined = CuratedFeedService.inflight.get(id);
    if (running !== undefined) {
      return running;
    }
    const task: Promise<PodcastSearchResult[]> = CuratedFeedService.fetchAndCache(id, wanted)
      .catch((error: Error) => {
        CuratedFeedService.lastFailAt.set(id, Date.now());
        CuratedFeedService.persistFails();
        Logger.warn(TAG, 'fetch failed for ' + id + ': ' + error.message);
        // 网络失败：回退到旧缓存（即使过期），没有就返回空
        return CuratedFeedService.peek(id);
      })
      .finally(() => {
        CuratedFeedService.inflight.delete(id);
      });
    CuratedFeedService.inflight.set(id, task);
    return task;
  }

  /**
   * 分类页继续下滑时追加数据：在已有结果之外再抓一批（按 feedUrl 去重的增量）。
   * 返回**新增**的条数（0 表示已经到底或本次没抓到新内容）。
   */
  static async loadMore(id: string, wantExtra: number): Promise<number> {
    CuratedFeedService.loadFileOnce();
    const existing: PodcastSearchResult[] = CuratedFeedService.peek(id);
    const before: number = existing.length;
    if (before >= CuratedFeedService.MAX_ITEMS) {
      return 0;
    }
    await CuratedFeedService.fetchAndCache(id, before + wantExtra);
    return CuratedFeedService.peek(id).length - before;
  }

  // ------------------------------------------------------------------ 抓取

  private static async fetchAndCache(id: string, want: number): Promise<PodcastSearchResult[]> {
    const category: CuratedCategory = CuratedCategories.find(id);
    // 多取一些（首页只展示前几条）：池子够大，按日期洗牌后才看得出「每天不一样」
    const poolWant: number = Math.max(want + 10, CuratedCategories.PREVIEW_SIZE * 2);
    const target: number = Math.min(poolWant, CuratedFeedService.MAX_ITEMS);
    const existing: PodcastSearchResult[] = CuratedFeedService.peek(id);
    const items: PodcastSearchResult[] = category.source === 'charts'
      ? await CuratedFeedService.fetchFromCharts(category, target, existing)
      : await CuratedFeedService.fetchFromSearch(category, target, existing);
    if (items.length === 0) {
      // 抓不到就别覆盖旧缓存
      return existing;
    }
    // 按「日期 + 板块」洗牌后再存：同一天稳定，跨天换一批
    const rotated: PodcastSearchResult[] = CuratedFeedService.shuffleForDay(items, id);
    CuratedFeedService.lastFailAt.delete(id);
    const entry: CacheEntry = {
      items: rotated,
      fetchedAt: Date.now(),
      day: CuratedFeedService.todayKey()
    };
    CuratedFeedService.memory.set(id, entry);
    CuratedFeedService.persist();
    return rotated.slice();
  }

  /**
   * 分类的检索词全集：预置主题词 + 基于首个主题词的长尾变体。
   *
   * 分类页「一直往下滑」靠的是**换词继续搜**（iTunes Search 单次最多 50 条、没有稳定分页），
   * 所以词表必须比首页用到的长；词用完才真正到底。
   */
  private static termsFor(category: CuratedCategory): string[] {
    const list: string[] = category.searchTerms.slice();
    const base: string = category.searchTerms.length > 0 ? category.searchTerms[0] : '';
    if (base !== '') {
      for (const suffix of CuratedFeedService.TERM_SUFFIXES) {
        list.push(base + ' ' + suffix);
      }
    }
    return list;
  }

  /** 榜单检索深度随需求量增长（Apple 榜单支持更深的名次） */
  private static chartDepthFor(target: number): number {
    if (target <= CuratedFeedService.CHART_DEPTH) {
      return CuratedFeedService.CHART_DEPTH;
    }
    // Apple 榜单接口实测：top/100 正常，top/200 会卡到超时，所以深度封顶 100
    return 100;
  }

  /**
   * 取单个市场的榜单：失败重试一次。
   * 各市场是并发发起的（见 fetchFromCharts），单个市场慢/失败不会拖住其它市场。
   */
  private static async fetchMarket(market: string, depth: number): Promise<ChartEntry[]> {
    try {
      return await AppleCharts.top(market, depth);
    } catch (error) {
      // 主通道失败：换 Apple 的另一条官方榜单通道（同一份数据的另一个出口）
      Logger.warn(TAG, 'chart ' + market + ' primary failed: ' + (error as Error).message);
    }
    try {
      const rows: ChartEntry[] = await AppleCharts.topRss(market, Math.min(depth, 100));
      if (rows.length > 0) {
        return rows;
      }
    } catch (error) {
      Logger.warn(TAG, 'chart ' + market + ' rss failed: ' + (error as Error).message);
    }
    return [];
  }

  /**
   * 「全球热门」：合并多市场榜单。
   *
   * 排序依据是**跨市场表现**：`Σ(51 - rank)`，即上榜市场越多、名次越靠前分数越高；
   * 只上榜一次的单市场节目仍会保留，但排在多市场共同上榜的节目后面。
   * 榜单只给目录 id，feedUrl 需要再 lookup 一次；拿不到 feedUrl 的直接丢弃
   * （否则点进去订阅不了，等于假数据）。
   */
  private static async fetchFromCharts(category: CuratedCategory, want: number,
                                       existing: PodcastSearchResult[]): Promise<PodcastSearchResult[]> {
    const depth: number = CuratedFeedService.chartDepthFor(want);
    const scores: Map<number, number> = new Map<number, number>();
    const charts: Map<number, ChartEntry> = new Map<number, ChartEntry>();
    const marketCount: Map<number, number> = new Map<number, number>();
    // 先并发发起所有市场的请求，再按顺序收集结果：
    // 串行 await 时四个市场要排 4 个超时，页面会长时间停在骨架屏。
    const tasks: Promise<ChartEntry[]>[] = [];
    for (const market of category.markets) {
      tasks.push(CuratedFeedService.fetchMarket(market, depth));
    }
    const perMarket: ChartEntry[][] = [];
    for (const task of tasks) {
      perMarket.push(await task);
    }
    for (const rows of perMarket) {
      for (const row of rows) {
        const previous: number = scores.get(row.id) !== undefined ? (scores.get(row.id) as number) : 0;
        const weight: number = (depth + 1) - row.rank;
        scores.set(row.id, previous + weight);
        marketCount.set(row.id, (marketCount.get(row.id) !== undefined ? (marketCount.get(row.id) as number) : 0) + 1);
        if (!charts.has(row.id)) {
          charts.set(row.id, row);
        }
      }
    }
    if (scores.size === 0) {
      // 四个市场全挂（网络/接口临时故障）：先退回上一次缓存，
      // 连缓存都没有时用通用热词兜底，避免用户看到完全空白的「全球热门」。
      if (existing.length > 0) {
        return existing;
      }
      return CuratedFeedService.fetchChartFallback(category, want);
    }
    const ranked: number[] = Array.from(scores.keys());
    ranked.sort((a: number, b: number) => {
      const sa: number = scores.get(a) as number;
      const sb: number = scores.get(b) as number;
      if (sa !== sb) {
        return sb - sa;
      }
      // 同分时多市场上榜者优先
      return (marketCount.get(b) as number) - (marketCount.get(a) as number);
    });
    // 只 lookup 需要的数量（多取一些，防止部分拿不到 feedUrl）
    const wanted: number[] = ranked.slice(0, Math.min(ranked.length, want * 2));
    let meta: Map<number, ItunesPodcast> = new Map<number, ItunesPodcast>();
    try {
      meta = await AppleCharts.lookup(wanted);
    } catch (error) {
      Logger.warn(TAG, 'lookup failed: ' + (error as Error).message);
      return existing;
    }
    const output: PodcastSearchResult[] = [];
    const seen: Set<string> = new Set<string>();
    for (const id of ranked) {
      const info: ItunesPodcast | undefined = meta.get(id);
      if (info === undefined || info.feedUrl === '' || seen.has(info.feedUrl)) {
        continue;
      }
      seen.add(info.feedUrl);
      const entry: ChartEntry | undefined = charts.get(id);
      output.push({
        title: info.title !== '' ? info.title : (entry !== undefined ? entry.title : ''),
        author: info.author !== '' ? info.author : (entry !== undefined ? entry.author : ''),
        imageUrl: info.imageUrl !== '' ? info.imageUrl : (entry !== undefined ? entry.artworkUrl100 : ''),
        feedUrl: info.feedUrl,
        genre: info.genre,
        releaseDate: info.releaseDate,
        collectionId: id
      });
      if (output.length >= want) {
        break;
      }
    }
    // 深榜单也补不满时，把旧结果里没出现在本轮榜单的节目接在后面（只增不减）
    for (const item of existing) {
      if (!seen.has(item.feedUrl)) {
        seen.add(item.feedUrl);
        output.push(item);
      }
    }
    return output;
  }

  /**
   * 榜单完全不可用时的兜底：用通用热词检索一批热门节目。
   *
   * 注意：这只是**降级路径**，结果按 iTunes 相关度排序，不代表任何国家榜单名次；
   * 正常情况下永远不会走到这里（榜单可用时优先真实榜单）。
   */
  private static async fetchChartFallback(category: CuratedCategory, want: number): Promise<PodcastSearchResult[]> {
    const output: PodcastSearchResult[] = [];
    const seen: Set<string> = new Set<string>();
    for (const term of category.searchTerms) {
      if (output.length >= want) {
        break;
      }
      let rows: PodcastSearchResult[] = [];
      try {
        rows = await Discovery.searchPodcasts(term, 50);
      } catch (error) {
        continue;
      }
      for (const row of rows) {
        if (row.feedUrl === '' || seen.has(row.feedUrl)) {
          continue;
        }
        seen.add(row.feedUrl);
        output.push(row);
        if (output.length >= want) {
          break;
        }
      }
    }
    if (output.length > 0) {
      Logger.warn(TAG, 'charts unavailable, served ' + output.length + ' search results as fallback');
    }
    return output;
  }
  /**
   * 其余五个板块：主题检索 → 分类/关键词打分 → 过滤 → 去重。
   *
   * 增量语义：从「上次用到的检索词下标」继续往后搜（`termCursor`），
   * 新结果接在已有结果后面。这样分类页每滑到底都能真的拿到新节目，
   * 而不是把同一批搜索结果重算一遍（那样 `added` 永远是 0，页面看起来「没有更多了」）。
   */
  private static async fetchFromSearch(category: CuratedCategory, want: number,
                                       existing: PodcastSearchResult[]): Promise<PodcastSearchResult[]> {
    const collected: Map<string, PodcastSearchResult> = new Map<string, PodcastSearchResult>();
    const scored: Map<string, number> = new Map<string, number>();
    const known: Set<string> = new Set<string>();
    for (const item of existing) {
      known.add(item.feedUrl);
    }
    const terms: string[] = CuratedFeedService.termsFor(category);
    let cursor: number = CuratedFeedService.termCursor.get(category.id) !== undefined
      ? (CuratedFeedService.termCursor.get(category.id) as number) : 0;
    while (cursor < terms.length && existing.length + collected.size < want) {
      const term: string = terms[cursor];
      cursor++;
      let rows: PodcastSearchResult[] = [];
      try {
        rows = await Discovery.searchPodcasts(term, 50);
      } catch (error) {
        Logger.warn(TAG, 'search "' + term + '" failed: ' + (error as Error).message);
        continue;
      }
      for (const row of rows) {
        if (row.feedUrl === '' || known.has(row.feedUrl)) {
          continue;
        }
        const score: number = CuratedFeedService.scoreOf(category, row);
        if (score <= 0) {
          continue;
        }
        const key: string = row.feedUrl;
        const previous: number = scored.get(key) !== undefined ? (scored.get(key) as number) : -1;
        if (previous < score) {
          scored.set(key, score);
          collected.set(key, row);
        }
      }
    }
    CuratedFeedService.termCursor.set(category.id, cursor);
    const keys: string[] = Array.from(collected.keys());
    keys.sort((a: string, b: string) => {
      const sa: number = scored.get(a) as number;
      const sb: number = scored.get(b) as number;
      if (sa !== sb) {
        return sb - sa;
      }
      const ra: PodcastSearchResult = collected.get(a) as PodcastSearchResult;
      const rb: PodcastSearchResult = collected.get(b) as PodcastSearchResult;
      return CuratedFeedService.recency(rb.releaseDate) - CuratedFeedService.recency(ra.releaseDate);
    });
    // 已有结果保持不变（首页顺序稳定），新抓到的按相关性接在后面
    const output: PodcastSearchResult[] = existing.slice();
    for (const key of keys) {
      output.push(collected.get(key) as PodcastSearchResult);
      if (output.length >= CuratedFeedService.MAX_ITEMS) {
        break;
      }
    }
    return output;
  }

  /**
   * 相关性打分（0 分 = 直接丢弃）。
   *
   * 以**平台分类元数据**为主判据，关键词只做加权与兜底：
   * +4 分类命中白名单；+3 标题/作者命中主题词；+2 命中必须词；
   * +1 近一年内仍在更新；分类不在白名单且没有任何关键词命中 = 0 分。
   */
  private static scoreOf(category: CuratedCategory, row: PodcastSearchResult): number {
    const genre: string = (row.genre !== undefined ? row.genre : '').toLowerCase();
    const text: string = (row.title + ' ' + row.author).toLowerCase();
    let genreHit: boolean = false;
    for (const g of category.genres) {
      if (genre !== '' && genre === g.toLowerCase()) {
        genreHit = true;
        break;
      }
    }
    let keywordHits: number = 0;
    for (const k of category.keywords) {
      if (k !== '' && text.indexOf(k.toLowerCase()) >= 0) {
        keywordHits++;
      }
    }
    let guardHit: boolean = true;
    if (category.requiredAny.length > 0) {
      guardHit = false;
      for (const k of category.requiredAny) {
        if (k !== '' && text.indexOf(k.toLowerCase()) >= 0) {
          guardHit = true;
          break;
        }
      }
    }
    if (!guardHit) {
      return 0;
    }
    // 分类不对、关键词也没命中：不要因为检索噪声混进来
    if (!genreHit && keywordHits === 0) {
      return 0;
    }
    let score: number = 0;
    if (genreHit) {
      score += 4;
    }
    if (keywordHits > 0) {
      score += 3;
    }
    if (guardHit && category.requiredAny.length > 0) {
      score += 2;
    }
    if (CuratedFeedService.isActive(row.releaseDate)) {
      score += 1;
    }
    return score;
  }

  /** 近一年内还有更新 */
  private static isActive(releaseDate: string | undefined): boolean {
    const ms: number = CuratedFeedService.recency(releaseDate);
    if (ms <= 0) {
      return false;
    }
    return Date.now() - ms < 365 * 24 * 60 * 60 * 1000;
  }

  /** 发布时间戳；解析失败返回 0（用于排序与活跃度判断） */
  private static recency(releaseDate: string | undefined): number {
    if (releaseDate === undefined || releaseDate === '') {
      return 0;
    }
    const ms: number = Date.parse(releaseDate);
    return isNaN(ms) ? 0 : ms;
  }

  // ------------------------------------------------------------------ 缓存落盘

  private static cachePath(): string {
    if (CuratedFeedService.context === undefined) {
      return '';
    }
    return CuratedFeedService.context.filesDir + '/' + CACHE_FILE;
  }

  /** 失败时间只在首次使用时读一次 */
  private static loadFailsOnce(): void {
    if (CuratedFeedService.failLoaded) {
      return;
    }
    CuratedFeedService.failLoaded = true;
    const path: string = CuratedFeedService.cachePath().replace(CACHE_FILE, CuratedFeedService.FAIL_FILE);
    if (path === '') {
      return;
    }
    try {
      if (!fs.accessSync(path)) {
        return;
      }
      const text: string = fs.readTextSync(path);
      if (text === '') {
        return;
      }
      const obj: Record<string, number> = JSON.parse(text) as Record<string, number>;
      for (const key of Object.keys(obj)) {
        CuratedFeedService.lastFailAt.set(key, obj[key]);
      }
    } catch (error) {
      CuratedFeedService.lastFailAt.clear();
    }
  }

  /** 把失败时间写盘（很小，几十字节） */
  private static persistFails(): void {
    const path: string = CuratedFeedService.cachePath().replace(CACHE_FILE, CuratedFeedService.FAIL_FILE);
    if (path === '') {
      return;
    }
    const obj: Record<string, number> = {};
    CuratedFeedService.lastFailAt.forEach((at: number, key: string) => {
      obj[key] = at;
    });
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(obj));
      } finally {
        fs.closeSync(file.fd);
      }
    } catch (error) {
    }
  }

  private static loadFileOnce(): void {
    if (CuratedFeedService.fileLoaded) {
      return;
    }
    CuratedFeedService.fileLoaded = true;
    const path: string = CuratedFeedService.cachePath();
    if (path === '') {
      return;
    }
    let text: string = '';
    try {
      if (!fs.accessSync(path)) {
        return;
      }
      text = fs.readTextSync(path);
    } catch (error) {
      return;
    }
    if (text === '') {
      return;
    }
    try {
      const root: Record<string, StoredEntry> = JSON.parse(text) as Record<string, StoredEntry>;
      for (const key of Object.keys(root)) {
        const stored: StoredEntry = root[key];
        if (stored === undefined || stored.items === undefined) {
          continue;
        }
        const items: PodcastSearchResult[] = [];
        for (const raw of stored.items) {
          if (raw.f === undefined || raw.f === '') {
            continue;
          }
          items.push({
            title: raw.t,
            author: raw.a,
            imageUrl: raw.i,
            feedUrl: raw.f,
            genre: raw.g,
            releaseDate: raw.r,
            collectionId: raw.c
          });
        }
        CuratedFeedService.memory.set(key, {
          items: items,
          fetchedAt: stored.at,
          day: stored.d
        });
      }
    } catch (error) {
      Logger.warn(TAG, 'cache parse failed: ' + (error as Error).message);
    }
  }

  private static persist(): void {
    const path: string = CuratedFeedService.cachePath();
    if (path === '') {
      return;
    }
    const root: Record<string, StoredEntry> = {};
    CuratedFeedService.memory.forEach((entry: CacheEntry, key: string) => {
      const items: StoredItem[] = [];
      for (const item of entry.items) {
        items.push({
          t: item.title,
          a: item.author,
          i: item.imageUrl,
          f: item.feedUrl,
          g: item.genre !== undefined ? item.genre : '',
          r: item.releaseDate !== undefined ? item.releaseDate : '',
          c: item.collectionId !== undefined ? item.collectionId : 0
        });
      }
      root[key] = { at: entry.fetchedAt, d: entry.day, items: items };
    });
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(root));
      } finally {
        fs.closeSync(file.fd);
      }
    } catch (error) {
      Logger.warn(TAG, 'cache write failed: ' + (error as Error).message);
    }
  }
}
