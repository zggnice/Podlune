import { router } from '@kit.ArkUI';
import { DesignTokens } from '../common/DesignTokens';
import { CuratedCategories, CuratedCategory } from '../common/CuratedCategories';
import { AppBar } from '../components/AppBar';
import { AppIconButton } from '../components/AppIconButton';
import { FeedCover } from '../components/FeedCover';
import { PodcastSearchResult } from '../net/Discovery';
import { CuratedFeedService } from '../services/CuratedFeedService';

/**
 * 分类浏览页：六个主题专区**共用一个组件**，靠路由参数 `categoryId` 区分内容。
 *
 * 布局：紧凑导航（返回 / 标题 / 搜索）+ 一行简介 + 轻量排序 + 三列正方形封面网格。
 * 数据来自在线目录（`Discovery.searchPodcasts`），多检索词合并去重，
 * 因此比首页预览更全，且不同分类的检索词不同，不会六页一样。
 * 不展示未读角标、不加悬浮添加按钮 —— 这是浏览页，不是订阅页。
 */

type SortMode = 'recommend' | 'latest' | 'az';

@Entry
@Component
struct CategoryPage {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  @State categoryId: string = '';
  @State items: PodcastSearchResult[] = [];
  @State loading: boolean = true;
  @State failed: boolean = false;
  @State sortMode: SortMode = 'recommend';
  /** 已展示条数：滚动到底再追加，避免一次性解码全部封面 */
  @State shown: number = CategoryPage.PAGE_STEP;
  private scroller: Scroller = new Scroller();

  private static readonly COL_GAP: number = 12;
  private static readonly PAGE_STEP: number = 21;
  /**
   * 首屏至少要有几条才算「能滚动」：3 列网格下 10 条经常仍不满一屏，
   * 不满一屏就收不到 onReachEnd，页面会卡死在首批条目上。
   */
  private static readonly MIN_FILL: number = 21;
  /** 首屏不满时最多自动续拉几轮 */
  private static readonly INITIAL_FILL_ROUNDS: number = 2;
  private static readonly COLUMNS: number = 3;

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, string> | undefined;
    const id: string = params === undefined || params['categoryId'] === undefined
      ? 'global' : params['categoryId'];
    this.categoryId = id;
    this.load();
  }

  private category(): CuratedCategory {
    return CuratedCategories.find(this.categoryId);
  }

  private titleRes(): Resource {
    const id: string = this.categoryId;
    if (id === 'silicon') {
      return $r('app.string.home_curated_silicon');
    }
    if (id === 'investor') {
      return $r('app.string.home_curated_investor');
    }
    if (id === 'health') {
      return $r('app.string.home_curated_health');
    }
    if (id === 'women') {
      return $r('app.string.home_curated_women');
    }
    if (id === 'language') {
      return $r('app.string.home_curated_language');
    }
    return $r('app.string.home_curated_global');
  }

  private descRes(): Resource {
    const id: string = this.categoryId;
    if (id === 'silicon') {
      return $r('app.string.curated_desc_silicon');
    }
    if (id === 'investor') {
      return $r('app.string.curated_desc_investor');
    }
    if (id === 'health') {
      return $r('app.string.curated_desc_health');
    }
    if (id === 'women') {
      return $r('app.string.curated_desc_women');
    }
    if (id === 'language') {
      return $r('app.string.curated_desc_language');
    }
    return $r('app.string.curated_desc_global');
  }

  /**
   * 拉取当前分类：与首页共用 `CuratedFeedService` 的同一份数据与缓存，
   * 按 feedUrl 去重并保持推荐顺序。
   */
  /** 首屏：直接用服务里的缓存（可能已在首页加载过），没有就现场拉 */
  private async load(): Promise<void> {
    this.loading = true;
    this.failed = false;
    this.hitsTheEnd = false;
    this.items = CuratedFeedService.peek(this.categoryId).slice();
    try {
      const results: PodcastSearchResult[] = await CuratedFeedService.load(this.categoryId, CategoryPage.PAGE_STEP);
      this.items = results.slice();
      // 首屏条目太少时 grid 撑不满一屏 → `onReachEnd` 永远不会触发，页面就「到底了」。
      // 这里主动续拉几批，直到够一屏（或确实没有更多内容）。
      let guard: number = 0;
      while (this.items.length < CategoryPage.MIN_FILL && guard < CategoryPage.INITIAL_FILL_ROUNDS) {
        guard++;
        const added: number = await CuratedFeedService.loadMore(this.categoryId, CategoryPage.PAGE_STEP);
        if (added <= 0) {
          this.hitsTheEnd = true;
          break;
        }
        this.items = this.mergeFromCache();
      }
      this.failed = this.items.length === 0;
    } catch (error) {
      this.failed = this.items.length === 0;
    }
    this.loading = false;
    this.shown = CategoryPage.PAGE_STEP;
  }

  /** 把服务缓存里的结果合并进当前列表（按 feedUrl 去重，保持顺序） */
  private mergeFromCache(): PodcastSearchResult[] {
    const seen: Set<string> = new Set<string>();
    const merged: PodcastSearchResult[] = [];
    for (const item of CuratedFeedService.peek(this.categoryId)) {
      if (item.feedUrl === '' || seen.has(item.feedUrl)) {
        continue;
      }
      seen.add(item.feedUrl);
      merged.push(item);
    }
    return merged;
  }

  /** 触底：还有数据就多露一屏；数据不够就向服务再要一批新内容 */
  private async loadMore(): Promise<void> {
    if (this.loadingMore || this.hitsTheEnd) {
      return;
    }
    if (this.shown < this.items.length) {
      this.shown = Math.min(this.shown + CategoryPage.PAGE_STEP, this.items.length);
      return;
    }
    this.loadingMore = true;
    try {
      const added: number = await CuratedFeedService.loadMore(this.categoryId, CategoryPage.PAGE_STEP);
      if (added > 0) {
        this.items = this.mergeFromCache();
        this.shown = Math.min(this.shown + CategoryPage.PAGE_STEP, this.items.length);
      } else {
        // 服务已经拿不出新内容：和之前的「检索词用完」语义一致，停止继续触底
        this.hitsTheEnd = true;
      }
    } catch (error) {
      // 单次失败不打断已展示内容，下次触底会重试
    }
    this.loadingMore = false;
  }

  /** 排序后的列表（不改原数组，避免反复排序打乱去重顺序） */
  private sorted(): PodcastSearchResult[] {
    const list: PodcastSearchResult[] = this.items.slice();
    if (this.sortMode === 'az') {
      list.sort((a: PodcastSearchResult, b: PodcastSearchResult) => a.title.localeCompare(b.title));
    } else if (this.sortMode === 'latest') {
      // 目录接口不返回时间，这里按标题里的年份做降序（有年份的排前面，无年份保持原序）
      list.sort((a: PodcastSearchResult, b: PodcastSearchResult) => {
        const ya: number = CategoryPage.yearOf(a.title);
        const yb: number = CategoryPage.yearOf(b.title);
        return yb - ya;
      });
    }
    return list;
  }

  private static yearOf(text: string): number {
    const matched: RegExpMatchArray | null = text.match(/(19|20)\d{2}/);
    return matched === null ? 0 : parseInt(matched[0]);
  }

  private visible(): PodcastSearchResult[] {
    const list: PodcastSearchResult[] = this.sorted();
    return list.slice(0, this.shown);
  }

  /** 三列等宽：列宽 = (内容宽 - 左右边距 - 两个间隙) / 3 */
  private cellWidth(): number {
    const w: number = this.contentWidth > 0 ? this.contentWidth : 360;
    return (w - DesignTokens.PAGE_MARGIN * 2 - CategoryPage.COL_GAP * 2) / CategoryPage.COLUMNS;
  }

  @State contentWidth: number = 360;
  @State loadingMore: boolean = false;
  @State hitsTheEnd: boolean = false;

  private open(item: PodcastSearchResult): void {
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

  /** 分类内搜索：现有搜索页尚不支持分类过滤，这里把分类名作为初始关键词带入，
   *  保证「点了真的有结果」，而不是做一个点了没用的控件。 */
  private openSearch(): void {
    router.pushUrl({ url: 'pages/SearchPage', params: { keyword: this.category().id } });
  }

  /**
   * 排序按钮。`@Builder` 的参数按值传递、不随 @State 重绘，
   * 所以高亮必须在 builder 内部按 `index` 重新比对 `this.sortMode`，否则点了不亮。
   */
  private sortLabel(index: number): Resource {
    if (index === 1) {
      return $r('app.string.curated_sort_latest');
    }
    if (index === 2) {
      return $r('app.string.curated_sort_az');
    }
    return $r('app.string.curated_sort_recommend');
  }

  private sortModeOf(index: number): SortMode {
    if (index === 1) {
      return 'latest';
    }
    if (index === 2) {
      return 'az';
    }
    return 'recommend';
  }

  @Builder
  sortChip(index: number) {
    Text(this.sortLabel(index)).fontFamily(this.appFontFamily)
      .fontSize(13)
      .fontWeight(this.sortMode === this.sortModeOf(index) ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.sortMode === this.sortModeOf(index)
        ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .borderRadius(14)
      .backgroundColor(this.sortMode === this.sortModeOf(index)
        ? $r('app.color.category_chip_active') : Color.Transparent)
      .onClick(() => {
        this.sortMode = this.sortModeOf(index);
        this.scroller.scrollToIndex(0);
      })
  }

  @Builder
  skeletonCell() {
    Column()
      .width(this.cellWidth())
      .aspectRatio(1)
      .borderRadius(DesignTokens.RADIUS_ROW)
      .backgroundColor($r('app.color.category_skeleton'))
  }

  build() {
    Column() {
      // 紧凑导航：返回 + 标题 + 搜索
      AppBar({ title: this.titleRes(), showBack: true, bgColor: $r('app.color.player_bg') }) {
        AppIconButton({ symbol: $r('sys.symbol.magnifyingglass'), onTap: () => this.openSearch() })
      }

      if (this.loading) {
        // 灰色骨架屏
        Grid() {
          ForEach([0, 1, 2, 3, 4, 5, 6, 7, 8], (i: number) => {
            GridItem() {
              this.skeletonCell()
            }
          }, (i: number) => 'sk-' + i.toString())
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(CategoryPage.COL_GAP)
        .rowsGap(CategoryPage.COL_GAP)
        .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN, top: DesignTokens.SPACE_M })
        .layoutWeight(1)
      } else if (this.items.length === 0) {
        // 空态 / 失败重试
        Column({ space: DesignTokens.SPACE_M }) {
          Text($r('app.string.curated_empty')).fontFamily(this.appFontFamily)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
          Text($r('app.string.curated_retry')).fontFamily(this.appFontFamily)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
            .borderRadius(16)
            .backgroundColor($r('app.color.category_chip_active'))
            .onClick(() => {
              this.load();
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // 简介 + 排序（滚动区外，始终可见）
        Text(this.descRes()).fontFamily(this.appFontFamily)
          .width('100%')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })

        Row({ space: 8 }) {
          this.sortChip(0)
          this.sortChip(1)
          this.sortChip(2)
        }
        .width('100%')
        .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN, top: DesignTokens.SPACE_S })

        // 三列正方形封面网格：只画封面，标题放到无障碍标签里
        Grid(this.scroller) {
          ForEach(this.visible(), (item: PodcastSearchResult) => {
            GridItem() {
              FeedCover({
                imageUrl: item.imageUrl,
                coverSize: this.cellWidth(),
                radius: DesignTokens.RADIUS_ROW,
                fallbackTitle: item.title,
                placeholderColor: $r('app.color.cover_placeholder')
              })
                .width(this.cellWidth())
                .height(this.cellWidth())
                .accessibilityText(item.title)
                .onClick(() => {
                  this.open(item);
                })
            }
          }, (item: PodcastSearchResult) => this.categoryId + '-' + item.feedUrl)
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(CategoryPage.COL_GAP)
        .rowsGap(CategoryPage.COL_GAP)
        .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN, top: DesignTokens.SPACE_M })
        .backgroundColor($r('app.color.player_bg'))
        .scrollBar(BarState.Off)
        .cachedCount(6)
        .layoutWeight(1)
        .onReachEnd(() => {
          // 触底自动续：先多露一屏，不够就去搜新一批（见 loadMore）
          this.loadMore();
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.player_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const w: number = Number(newValue.width);
      if (w > 0 && Math.abs(w - this.contentWidth) > 1) {
        this.contentWidth = w;
      }
    })
  }
}
