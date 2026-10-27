import router from '@ohos.router';
import { Discovery, PodcastSearchResult } from '../net/Discovery';
import { SubscriptionService } from '../services/SubscriptionService';
import { EventHub, EventType, FeedUpdateData } from '../events/EventHub';
import { FeedRepository } from '../db/repositories/FeedRepository';
import { EpisodeRepository } from '../db/repositories/EpisodeRepository';
import { Feed } from '../model/Feed';
import { FeedItem } from '../model/FeedItem';
import { FeedMedia } from '../model/FeedMedia';
import { MediaType } from '../model/Enums';
import { Playable } from '../model/Playable';
import { QueueEngine } from '../player/QueueEngine';
import { PlayerManager } from '../player/PlayerManager';
import { DurationUtils } from '../utils/DurationUtils';
import { LazyDataSource } from '../components/LazyDataSource';
import { FeedCover } from '../components/FeedCover';
import { DesignTokens } from '../common/DesignTokens';
import { openEpisodeDetail } from '../common/EpisodeRoute';
import { EpisodeRow } from '../components/EpisodeRow';

interface SearchParams {
  term: string;
  /** true = 队列内搜索（上游 QueueFragment 的搜索动作传 FeedItemFilter(QUEUED)） */
  queuedOnly?: boolean;
}

/** 本地剧集搜索结果上限（对齐上游列表按发布时间倒序的展示方式） */
const MAX_EPISODE_RESULTS: number = 50;

/**
 * Search（视觉重构版）。
 *
 * 版式：
 * - 顶栏：返回箭头 + 22fp 标题 + 右侧搜索动作，无背景条与分割线；
 * - 搜索框：大圆角胶囊、白色半透明底、左侧放大镜、有内容时右侧出现清除钮，光标品牌紫；
 * - 空状态：线性放大镜（柔和中灰）+ 主提示 + 副提示，整体略偏上，留白安静；
 * - 结果：播客结果卡 + 单集行，卡片化与收件箱一致（白卡、22vp 圆角、12vp 间距）。
 *
 * 底部沉浸：`expandSafeArea` 同时上延到状态栏、下延到手势区，让页面背景一直画到屏幕底边，
 * 系统手势条自然悬浮在同色背景上（不改窗口全局配置，只在本页生效）。
 *
 * 业务逻辑（search / searchEpisodes / searchQueue / subscribe / play）保持原样。
 */
@Entry
@Component
export struct SearchPage {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  /**
   * 作为底部页签内嵌时（与首页 / 单集 / 订阅一致）：
   * 不显示返回箭头，并为底栏 + 迷你播放器预留高度。
   * 从页内其它入口以路由页打开时保持原有带返回箭头的形态。
   */
  @Prop asTab: boolean = false;
  @Prop bottomInset: number = 0;
  /** 主滚动容器的垂直增量：供外壳 Dock 折叠判定（与首页同一套逻辑） */
  onScrollDelta: (delta: number) => void = () => {
  };
  private dataSource: LazyDataSource<PodcastSearchResult> = new LazyDataSource<PodcastSearchResult>();
  /** FEED_LIST_UPDATE 订阅 token（详情页订阅后刷新卡片状态） */
  private feedListToken: number = -1;
  /** 正在订阅的 feedUrl（只给那一行显示转圈） */
  @State subscribingUrl: string = '';
  @State term: string = '';
  @State results: PodcastSearchResult[] = [];
  @State episodes: FeedItem[] = [];
  @State loading: boolean = false;
  @State message: string = '';
  @State searched: boolean = false;
  /**
   * 已订阅集合（归一化地址）。
   * 用「URL 数组」存不下 feedId，而取消订阅需要 feedId（`SubscriptionService.unsubscribe`）。
   * 用字符串存成 "url\u0001id" 的数组形式，规避 ArkUI 对 Map 的状态监听限制。
   */
  @State subscribedLinks: string[] = [];
  /** 队列内搜索：不查在线播客目录，只在队列里找单集 */
  @State queuedOnly: boolean = false;
  /** 防止行点击与行内按钮同时触发导致重复订阅 */
  private subscribing: boolean = false;
  private feedTitles: Map<number, string> = new Map<number, string>();
  private feedImages: Map<number, string> = new Map<number, string>();

  build() {
    Column() {
      // ------------------------------------------------ 顶栏（无背景条 / 无分割线）
      Row({ space: DesignTokens.SPACE_XS }) {
        if (!this.asTab) {
          Stack() {
            SymbolGlyph($r('sys.symbol.chevron_backward'))
              .fontSize(DesignTokens.ICON_XL)
              .fontColor([$r('app.color.text_primary')])
          }
          .width(DesignTokens.HIT_MIN)
          .height(DesignTokens.HIT_MIN)
          .alignContent(Alignment.Center)
          .onClick(() => {
            router.back();
          })
        }

        Text(this.queuedOnly ? $r('app.string.search_in_queue') : $r('app.string.discover_search')).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_FLOAT_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .layoutWeight(1)
          .margin({ left: this.asTab ? DesignTokens.PAGE_MARGIN - DesignTokens.SPACE_S : DesignTokens.SPACE_S })

        // 榜单入口：全球 / 中文 / 中文单集（图标位改为「榜单」二字，与顶栏文字同一视觉重量）
        Stack() {
          Text($r('app.string.charts_title')).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_PARAGRAPH)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
        }
        .width(DesignTokens.HIT_MIN)
        .height(DesignTokens.HIT_MIN)
        .alignContent(Alignment.Center)
        .accessibilityText('榜单')
        .onClick(() => {
          router.pushUrl({ url: 'pages/ChartsPage' });
        })

        Stack() {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(DesignTokens.ICON_L)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(DesignTokens.HIT_MIN)
        .height(DesignTokens.HIT_MIN)
        .alignContent(Alignment.Center)
        .onClick(() => {
          this.search();
        })
      }
      .width('100%')
      .height(DesignTokens.HEIGHT_FLOAT_TOP_BAR)
      .padding({ left: DesignTokens.SPACE_S, right: DesignTokens.SPACE_S })
      .alignItems(VerticalAlign.Center)

      // ------------------------------------------------ 搜索框
      // 外层 Row 负责左右边距，内层胶囊负责外观（避免 width 100% + margin 的右溢出问题）
      Row() {
        Row({ space: DesignTokens.SPACE_S }) {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(DesignTokens.ICON_M)
            .fontColor([$r('app.color.search_hint_icon')])

          TextInput({
            placeholder: this.queuedOnly ? $r('app.string.search_in_queue_hint') : $r('app.string.discover_hint'),
            text: this.term
          }).fontFamily(this.appFontFamily)
            .layoutWeight(1)
            .height(40)
            .padding(0)
            .fontSize(DesignTokens.FONT_SUBTITLE)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.search_hint_icon'))
            .caretColor($r('app.color.primary'))
            .backgroundColor(Color.Transparent)
            .onChange((value: string) => {
              this.term = value;
            })
            .onSubmit(() => {
              this.search();
            })

          if (this.term !== '') {
            Stack() {
              SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
                .fontSize(DesignTokens.ICON_M)
                .fontColor([$r('app.color.search_hint_icon')])
            }
            .width(28)
            .height(28)
            .alignContent(Alignment.Center)
            .onClick(() => {
              this.term = '';
            })
          }
        }
        .width('100%')
        .height(44)
        .padding({ left: DesignTokens.SPACE_L, right: DesignTokens.SPACE_M })
        .borderRadius(22)
        .backgroundColor($r('app.color.search_field_bg'))
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
      .margin({ bottom: DesignTokens.SPACE_S })

      if (this.message !== '') {
        Text(this.message).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_FOOTNOTE)
          .fontColor($r('app.color.error'))
          .width('100%')
          .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN, top: DesignTokens.SPACE_S })
      }

      // ------------------------------------------------ 内容区
      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(40)
            .height(40)
            .color($r('app.color.primary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.results.length === 0 && this.episodes.length === 0) {
        this.emptyState()
      } else {
        List({ space: DesignTokens.SPACE_M }) {
          // 播客结果（卡片化）
          LazyForEach(this.dataSource, (item: PodcastSearchResult, index: number) => {
            ListItem() {
              Row({ space: DesignTokens.SPACE_L }) {
                FeedCover({ imageUrl: item.imageUrl, coverSize: 56, radius: 12 })
                Column({ space: DesignTokens.SPACE_XS }) {
                  Text(item.title).fontFamily(this.appFontFamily)
                    .fontSize(DesignTokens.FONT_BODY)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(item.author).fontFamily(this.appFontFamily)
                    .fontSize(DesignTokens.FONT_FOOTNOTE)
                    .fontColor($r('app.color.search_hint_icon'))
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                // 右侧订阅按钮：书签轮廓（未订阅，中性灰）↔ 实心书签（已订阅，品牌紫）
                // 点击切换：订阅后变紫，再点取消订阅、紫色消失
                Stack() {
                  if (this.subscribing && this.subscribingUrl === item.feedUrl) {
                    // 订阅中：抓取 RSS 需要时间，转圈提示，避免「点了没反应」
                    LoadingProgress()
                      .width(DesignTokens.ICON_M)
                      .height(DesignTokens.ICON_M)
                      .color($r('app.color.primary'))
                  } else {
                    SymbolGlyph(this.isSubscribed(item.feedUrl)
                      ? $r('sys.symbol.bookmark_fill') : $r('sys.symbol.bookmark'))
                      .fontSize(DesignTokens.ICON_L)
                      .fontColor([this.isSubscribed(item.feedUrl)
                        ? $r('app.color.primary') : $r('app.color.search_hint_icon')])
                  }
                }
                .width(36)
                .height(36)
                .borderRadius(18)
                .backgroundColor(this.isSubscribed(item.feedUrl)
                  ? $r('app.color.search_action_bg') : Color.Transparent)
                .alignContent(Alignment.Center)
                .accessibilityText($r('app.string.discover_subscribe'))
                .opacity(item.feedUrl === '' ? 0.35 : 1)
                .onClick(() => {
                  if (item.feedUrl === '') {
                    this.message = getContext(this).resourceManager
                      .getStringSync($r('app.string.search_result_no_feed'));
                    return;
                  }
                  this.toggleSubscribe(item.feedUrl);
                })
              }
              .width('100%')
              .padding(DesignTokens.SPACE_M)
              .borderRadius(22)
              .backgroundColor($r('app.color.search_card_bg'))
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                // 点卡片 = 只看详情（只读预览，不订阅）；订阅是右侧「+」的职责
                if (item.feedUrl === '') {
                  this.message = getContext(this).resourceManager
                    .getStringSync($r('app.string.search_result_no_feed'));
                  return;
                }
                this.openPreview(item);
              })
            }
          }, (item: PodcastSearchResult, index: number) => item.feedUrl + '-' + index)

          // 剧集结果（共享 EpisodeRow，开启卡片样式与收件箱一致）
          ForEach(this.episodes, (item: FeedItem) => {
            ListItem() {
              EpisodeRow({
                title: item.title,
                imageUrl: item.imageUrl !== '' ? item.imageUrl : this.feedImage(item.feedId),
                metaText: this.metaText(item),
                positionText: this.positionText(item),
                durationText: this.durationText(item),
                progress: this.progress(item),
                isPlayed: item.isPlayed,
                isNew: item.isNew(),
                isFavorite: false,
                inQueue: false,
                isVideo: this.isVideo(item),
                actionIcon: $r('sys.symbol.play_fill'),
                reference: true,
      cardStyle: false,
                onTap: () => {
                  // 单击 = 打开单集详情页（与收件箱一致）；播放仍走右侧播放钮
                  openEpisodeDetail(item.id);
                },
                onAction: () => {
                  this.play(item);
                }
              })
            }
          }, (item: FeedItem) => item.id.toString())
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN, top: DesignTokens.SPACE_M })
        // 页签模式下给底栏 + 迷你播放器让位
        .contentEndOffset(this.bottomInset)
        .scrollBar(BarState.Off)
        // 作为常驻 Tab 时不会触发 onPageShow：用可见性变化兜底刷新订阅状态
        .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, _ratio: number) => {
          if (isVisible) {
            this.refreshSubscribedState();
          }
        })
        // 与首页一致：把真实垂直滚动增量交给外壳，驱动 Dock 折叠
        .onScrollFrameBegin((offset: number, _state: ScrollState) => {
          if (offset !== 0) {
            this.onScrollDelta(offset);
          }
          return { offsetRemain: offset };
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.search_bg'))
    // 顶部上延到状态栏、底部下延到手势区：背景与手势条所在区域连续，无独立色块
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /**
   * 空状态：居中的线性放大镜 + 主副两行提示。
   * 位置为「搜索框下方的内容区」内略偏上（flexGrow 0.42 让内容重心自然上移）。
   */
  @Builder
  emptyState() {
    Column() {
      Column({ space: DesignTokens.SPACE_M }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(44)
          .fontColor([$r('app.color.search_hint_icon')])
        Text(this.searched ? $r('app.string.discover_empty') : $r('app.string.type_to_search')).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_SECTION)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
        Text($r('app.string.search_empty_sub')).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_PARAGRAPH)
          .fontColor($r('app.color.search_hint_icon'))
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .padding({ left: 40, right: 40 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ bottom: 120 })
  }

  /** 从节目详情页返回时刷新订阅状态：那边订阅/取消订阅后，搜索结果卡片要立刻跟着变 */
  onPageShow(): void {
    this.refreshSubscribedState();
  }

  aboutToAppear(): void {
    // 订阅状态跨页同步：详情页订阅 / 取消订阅后会广播 FEED_LIST_UPDATE，
    // 搜索结果卡片的书签图标据此立即刷新（返回本页时不再是旧状态）。
    this.feedListToken = EventHub.subscribe(EventType.FEED_LIST_UPDATE, (_data: object) => {
      this.refreshSubscribedState();
    });
    const params = router.getParams() as SearchParams;
    if (params !== undefined && params.queuedOnly === true) {
      this.queuedOnly = true;
    }
    if (params !== undefined && params.term !== undefined) {
      this.term = params.term;
      this.search();
    }
  }

  aboutToDisappear(): void {
    EventHub.unsubscribeToken(this.feedListToken);
  }

  async search(): Promise<void> {
    const query: string = this.term.trim();
    if (query === '') {
      return;
    }
    this.loading = true;
    this.message = '';
    this.searched = true;
    if (!this.queuedOnly) {
      try {
        const results: PodcastSearchResult[] = await Discovery.searchPodcasts(query);
        // iTunes Search 不返回 feedUrl：批量 Lookup 补齐，否则订阅按钮会「点了没反应」
        await Discovery.resolveFeedUrls(results);
        this.results = results;
        this.dataSource.setData(results);
      } catch (error) {
        this.results = [];
        this.dataSource.setData([]);
        this.message = getContext(this).resourceManager.getStringSync($r('app.string.search_failed')) + (error as Error).message;
      }
    } else {
      this.results = [];
      this.dataSource.setData([]);
    }
    // 每次搜索后刷新「已订阅」集合，让结果卡片右侧的「+ / 对号」与实际库记录一致
    await this.refreshSubscribedState();
    try {
      await this.searchEpisodes(query);
    } catch (error) {
      this.episodes = [];
    }
    this.loading = false;
  }

  /**
   * 本地剧集搜索：遍历已订阅 Feed（复用 EpisodeRepository.searchByFeed），按发布时间倒序。
   * 队列内搜索（上游 FeedItemFilter(QUEUED)）只保留队列里命中的单集，且不查在线目录。
   */
  async searchEpisodes(query: string): Promise<void> {
    if (this.queuedOnly) {
      await this.searchQueue(query);
      return;
    }
    const feeds: Feed[] = await FeedRepository.listSubscribed();
    const titles: Map<number, string> = new Map<number, string>();
    const images: Map<number, string> = new Map<number, string>();
    for (const feed of feeds) {
      titles.set(feed.id, feed.getTitle());
      images.set(feed.id, feed.imageUrl);
    }
    this.feedTitles = titles;
    this.feedImages = images;

    const merged: FeedItem[] = [];
    for (const feed of feeds) {
      const items: FeedItem[] = await EpisodeRepository.searchByFeed(feed.id, query);
      for (const item of items) {
        merged.push(item);
      }
      if (merged.length >= MAX_EPISODE_RESULTS) {
        break;
      }
    }
    merged.sort((a: FeedItem, b: FeedItem) => b.pubDate - a.pubDate);
    this.episodes = merged.slice(0, MAX_EPISODE_RESULTS);
  }

  /** 队列内搜索：只在当前队列里按标题匹配（上游 FeedItemFilter(QUEUED) + 关键词） */
  async searchQueue(query: string): Promise<void> {
    await QueueEngine.load();
    const queued: FeedItem[] = QueueEngine.getItems();
    const titles: Map<number, string> = new Map<number, string>();
    const images: Map<number, string> = new Map<number, string>();
    const feeds: Feed[] = await FeedRepository.listByIds(queued.map((item: FeedItem) => item.feedId));
    for (const feed of feeds) {
      titles.set(feed.id, feed.getTitle());
      images.set(feed.id, feed.imageUrl);
    }
    this.feedTitles = titles;
    this.feedImages = images;

    const keyword: string = query.toLowerCase();
    const matched: FeedItem[] = [];
    for (const item of queued) {
      const feedTitle: string | undefined = titles.get(item.feedId);
      const haystack: string = (item.title + ' ' + (feedTitle === undefined ? '' : feedTitle)).toLowerCase();
      if (haystack.includes(keyword)) {
        matched.push(item);
      }
      if (matched.length >= MAX_EPISODE_RESULTS) {
        break;
      }
    }
    this.episodes = matched;
  }

  /**
   * 点卡片：进入**只读预览**。
   *
   * 预览复用 `pages/FeedDetailPage`（同一套头图 / 筛选 / 单集卡片），
   * 只传 `feedUrl` 不传 `feedId`，因此该页走「未订阅」分支：
   * 只抓取解析、不写库，也不显示管理动作；底部提供「订阅」按钮。
   */
  private openPreview(item: PodcastSearchResult): void {
    router.pushUrl({
      url: 'pages/FeedDetailPage',
      params: {
        feedUrl: item.feedUrl,
        previewTitle: item.title,
        previewAuthor: item.author,
        previewImageUrl: item.imageUrl
      }
    });
  }

  /**
   * 让搜索结果每一行重新渲染。
   *
   * 结果列表是 `LazyForEach`：只改 `@State subscribedLinks` 不会重建已渲染的行，
   * 图标会一直停在旧状态（这就是「订阅了但卡片没变紫」的直接原因）。
   * 逐个通知单行刷新，既能让图标立即变，也不会把列表滚动位置重置。
   */
  private refreshResultRows(): void {
    for (let i: number = 0; i < this.results.length; i++) {
      this.dataSource.notifyDataChange(i);
    }
  }

  /**
   * 归一化 feed 地址后再比较。
   *
   * Apple 返回的 `feedUrl` 与库里存的 `download_url` 经常只差「http / https」「末尾斜杠」
   * 或大小写，逐字符比较会误判成「未订阅」（图标不亮、点订阅又插一条重复记录）。
   */
  private normalizeFeedUrl(url: string): string {
    let value: string = url.trim().toLowerCase();
    if (value.startsWith('https://')) {
      value = value.substring(8);
    } else if (value.startsWith('http://')) {
      value = value.substring(7);
    }
    const hash: number = value.indexOf('#');
    if (hash >= 0) {
      value = value.substring(0, hash);
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  /** 该 feedUrl 是否已订阅（比对归一化地址；数据来源始终是数据库） */
  private isSubscribed(feedUrl: string): boolean {
    if (feedUrl === '') {
      return false;
    }
    return this.subscribedLinks.indexOf(this.normalizeFeedUrl(feedUrl)) >= 0;
  }

  /**
   * 点订阅图标：切换订阅状态。
   *
   * 这里不再依赖「进入页面时缓存的 feedId 映射」——那套映射只要 URL 有一点差异、
   * 或列表刷新时机不对，就会出现「订阅成功但图标不变 / 点第二次又插一条」。
   * 现在点下去先回库查真实状态，再决定订阅还是取消，成功后再刷新整页状态。
   */
  private async toggleSubscribe(feedUrl: string): Promise<void> {
    if (feedUrl === '' || this.subscribing) {
      return;
    }
    this.subscribing = true;
    this.subscribingUrl = feedUrl;
    this.message = '';
    try {
      const existing: Feed | undefined = await FeedRepository.getByDownloadUrl(feedUrl);
      const subscribedNow: boolean = existing !== undefined && existing.state === 1;
      if (subscribedNow && existing !== undefined) {
        await SubscriptionService.unsubscribe(existing.id);
        const off: FeedUpdateData = { feedId: existing.id };
        EventHub.publish(EventType.FEED_LIST_UPDATE, off);
      } else {
        const feed: Feed = await SubscriptionService.subscribe(feedUrl);
        const on: FeedUpdateData = { feedId: feed.id };
        EventHub.publish(EventType.FEED_LIST_UPDATE, on);
      }
      await this.refreshSubscribedState();
    } catch (error) {
      this.message = getContext(this).resourceManager.getStringSync($r('app.string.subscribe_failed'))
        + (error as Error).message;
    } finally {
      this.subscribing = false;
      this.subscribingUrl = '';
      this.refreshResultRows();
    }
  }

  /**
   * 回填订阅状态（数据来源：数据库）。
   *
   * 除了「整库已订阅集合」，还会对当前搜索结果逐条按 URL 回查一次：
   * `listSubscribed()` 的集合与搜索结果的 URL 只差一点（协议/斜杠/大小写）时，
   * 单靠集合比对会漏判，逐条回查能把真实状态捞回来。
   */
  private async refreshSubscribedState(): Promise<void> {
    const keys: string[] = [];
    try {
      const feeds: Feed[] = await FeedRepository.listSubscribed();
      for (const feed of feeds) {
        if (feed.downloadUrl !== '') {
          keys.push(this.normalizeFeedUrl(feed.downloadUrl));
        }
      }
    } catch (error) {
      // 整库读取失败不致命：下面还会逐条回查
    }
    for (const item of this.results) {
      if (item.feedUrl === '') {
        continue;
      }
      try {
        const hit: Feed | undefined = await FeedRepository.getByDownloadUrl(item.feedUrl);
        if (hit !== undefined && hit.state === 1) {
          const key: string = this.normalizeFeedUrl(item.feedUrl);
          if (keys.indexOf(key) < 0) {
            keys.push(key);
          }
        }
      } catch (error) {
        // 单条失败忽略
      }
    }
    this.subscribedLinks = keys;
    this.refreshResultRows();
  }

  feedImage(feedId: number): string {
    return this.feedImages.get(feedId) ?? '';
  }

  isVideo(item: FeedItem): boolean {
    const media: FeedMedia | undefined = item.media;
    return media !== undefined && media.getMediaType() === MediaType.VIDEO;
  }

  positionText(item: FeedItem): string {
    if (item.media === undefined || item.media.position <= 0) {
      return '';
    }
    return DurationUtils.format(item.media.position);
  }

  durationText(item: FeedItem): string {
    if (item.media === undefined || item.media.duration <= 0) {
      return '';
    }
    return DurationUtils.format(item.media.duration);
  }

  progress(item: FeedItem): number {
    if (item.media === undefined || item.media.duration <= 0 || item.media.position <= 0) {
      return 0;
    }
    const percent: number = Math.floor(item.media.position * 100 / item.media.duration);
    return percent > 100 ? 100 : (percent < 5 ? 5 : percent);
  }

  metaText(item: FeedItem): string {
    const title: string | undefined = this.feedTitles.get(item.feedId);
    const parts: string[] = [];
    if (title !== undefined) {
      parts.push(title);
    }
    if (item.pubDate > 0) {
      parts.push(new Date(item.pubDate).toLocaleDateString());
    }
    return parts.join(' · ');
  }

  async play(item: FeedItem): Promise<void> {
    if (item.media === undefined) {
      return;
    }
    try {
      const playable: Playable | undefined = await QueueEngine.toPlayable(item);
      if (playable === undefined) {
        return;
      }
      await QueueEngine.ensureQueued(item);
      await PlayerManager.load(playable, item.media.position, true);
      router.pushUrl({ url: 'pages/PlayerPage' });
    } catch (error) {
      this.message = (error as Error).message;
    }
  }
}
