import router from '@ohos.router';
import { HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, DividerShowType } from '@kit.UIDesignKit';
import { LengthMetrics } from '@kit.ArkUI';
import { ImmersiveHost } from '../services/ImmersiveHost';
import common from '@ohos.app.ability.common';
import { NetworkWarmup } from '../common/NetworkWarmup';
import { FlowingLightBackground } from '../components/FlowingLightBackground';
import { AdaptiveProgressColor } from '../common/AdaptiveProgressColor';
import pasteboard from '@ohos.pasteboard';
import { HtmlCleaner } from '../utils/HtmlCleaner';
import { Feed } from '../model/Feed';
import { FeedItem } from '../model/FeedItem';
import { FeedMedia } from '../model/FeedMedia';
import { FeedFilter } from '../model/FeedFilter';
import { SortOrder } from '../model/Enums';
import { FeedRepository } from '../db/repositories/FeedRepository';
import { EpisodeRepository } from '../db/repositories/EpisodeRepository';
import { FavoritesRepository } from '../db/repositories/FavoritesRepository';
import { RefreshService } from '../services/RefreshService';
import { FeedFetcher } from '../services/FeedFetcher';
import { SubscriptionService } from '../services/SubscriptionService';
import { AutoDownloadService } from '../services/AutoDownloadService';
import { DownloadManager } from '../download/DownloadManager';
import { QueueEngine } from '../player/QueueEngine';
import { PlayerManager } from '../player/PlayerManager';
import { Playable } from '../model/Playable';
import { MediaType } from '../model/Enums';
import { UserPreferences } from '../prefs/UserPreferences';
import { EventHub, EventType, EpisodeDownloadData, FeedItemUpdateData } from '../events/EventHub';
import { LazyDataSource } from '../components/LazyDataSource';
import { FeedCover } from '../components/FeedCover';
import { DurationUtils } from '../utils/DurationUtils';
import { DateUtils } from '../utils/DateUtils';
import { DesignTokens } from '../common/DesignTokens';
import { menuIcon } from '../common/MenuIcons';
import { openEpisodeDetail } from '../common/EpisodeRoute';
import {
  SwipeActionId,
  SwipeActionSpec,
  SwipeActions,
  SwipeScreen,
  isDestructiveSwipeAction,
  swipeActionSpec
} from '../common/SwipeActions';
import { AppBar } from '../components/AppBar';
import { AppIconButton } from '../components/AppIconButton';
import { OverflowButton } from '../components/OverflowButton';
import { TagChip } from '../components/TagChip';
import { EmptyState } from '../components/EmptyState';
import { EpisodeRow } from '../components/EpisodeRow';
import { SwipeActionButton } from '../components/SwipeActionButton';

/** 相对时间展示描述：「刚刚」或「N + 单位」，由 UI 层用 $r(..., count) 组装 */
interface RelativeLabel {
  /** 'just_now' | 'minutes' | 'hours' | 'days'，或已是成品的日期字符串 */
  text: string;
  /** 参与格式化的数字（just_now / 日期字符串时为 0） */
  count: number;
}

interface FeedDetailParams {
  feedId: number;
  /**
   * 未订阅预览：搜索结果点卡片进来时只带 feedUrl、不带 feedId。
   * 该模式下**只读**——不写库、不显示管理动作，底部给「订阅」按钮。
   */
  feedUrl?: string;
  previewTitle?: string;
  previewAuthor?: string;
  previewImageUrl?: string;
}

/** 预览单集传给单集详情页的快照结构（避免无类型对象字面量） */
interface PreviewSnapshot {
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

@Entry
@Component
struct FeedDetailPage {
  /** 本页在系统栏管理里的所有权标识 */
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  /** 划出后继续拖动的距离阈值（vp）：进入该区域松手立即执行「标记为已播放/未播放」 */
  private static readonly SWIPE_ACTION_DISTANCE: number = 40;
  private dataSource: LazyDataSource<FeedItem> = new LazyDataSource<FeedItem>();
  /**
   * 列表控制器。`swipeAction.onAction` 触发后行不会自动回弹，
   * 必须靠 `ListScroller.closeAllSwipeActions()` 收回（见 `closeSwipes`）。
   */
  private listScroller: ListScroller = new ListScroller();
  @State feed: Feed | undefined = undefined;
  @State episodes: FeedItem[] = [];
  @State filter: string = 'all';
  @State loading: boolean = false;
  @State errorMessage: string = '';
  @State favoriteIds: number[] = [];
  @State queueIds: number[] = [];
  @State message: string = '';
  /** 是否已订阅：驱动书签按钮的灰 / 紫两态（进入页面时读库，操作成功后回写） */
  @State subscribed: boolean = false;
  /**
   * 只读预览模式：从推荐 / 搜索结果点进来、且该播客尚未订阅时为 true。
   * 此时节目信息与单集来自内存里解析的 RSS（`previewItems`），**不写库、不订阅**；
   * 用户点「订阅」后才会落库并把列表切回数据库来源。
   */
  @State previewMode: boolean = false;
  /** 头部内容实测高度（vp）：流光背景按它取高，随头部一起滚动 */
  @State headerHeight: number = 0;
  @State statusInset: number = 0;
  @State pullDistance: number = 0;
  /** 当前封面主色相对亮度（0–1）：决定状态栏与顶栏图标用深色还是浅色 */
  @State coverLuminance: number = 0.5;
  /** 页面是否在前台：异步回调返回时挡住过期写入 */
  private mounted: boolean = false;
  /** 头部内容实测高度（vp），流光背景按它取高 */



  /** 预览模式下的单集（来自 RSS 解析结果，未入库） */
  private previewItems: FeedItem[] = [];
  /** 订阅 / 取消订阅进行中：防连点重复请求 */
  @State togglingSubscribe: boolean = false;
  /** 节目简介是否展开（默认收起，仅保留一行入口） */
  @State descriptionExpanded: boolean = false;
  @State filterActive: boolean = false;
  // 弹层
  @State showSortSheet: boolean = false;
  @State showFilterSheet: boolean = false;
  @State showActionSheet: boolean = false;
  @State actionTitle: string = '';
  @State filterInclude: string = '';
  @State filterExclude: string = '';
  @State filterMinDuration: string = '';
  @State showStreamConfirm: boolean = false;
  /** 剧集列表左右滑动作 id（对照上游 SwipeActions.getSwipeActions；设置页保存后重新解析） */
  @State swipeRightId: string = SwipeActionId.NONE;
  @State swipeLeftId: string = SwipeActionId.NONE;
  // 多选（对照上游 EpisodeMultiSelectActionHandler + FloatingSelectMenu）
  @State selecting: boolean = false;
  @State selectedIds: number[] = [];
  /**
   * 下载进度版本号（每个下载进度事件 +1）：下载状态与进度存在 `DownloadManager` 的静态表里、
   * 不是 @State，行内进度环要靠本页重渲染才重算。**不能用行键编码进度**：
   * 键一变 LazyForEach 会把整行（含封面 `Image`）拆掉重建、图片重新解码
   * → 用户报的「下载单集时封面时不时闪一下」（实测一次 2.4 MB 下载重建 20 次）。
   */
  @State downloadTick: number = 0;
  private actionItem: FeedItem | undefined = undefined;
  private pendingItem: FeedItem | undefined = undefined;
  private streamConfirmed: boolean = false;
  private downloadToken: number = -1;
  /** 滑动动作偏好变化订阅 token */
  private swipeToken: number = -1;
  private messageTimerId: number = -1;

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      HdsNavigation() {
        // 整页滚动：头部（封面/标题/简介/单集工具条）作为列表的第一项，
        // 与首页一致 —— 上滑时头部一起滑走，单集继续上移，而不是页内局部滚动。
        List({ space: 0, scroller: this.listScroller }) {
          ListItem() {
            Column() {
          // feed 尚未加载（从首页推荐卡片进来时的预览加载阶段）时不能渲染 header：
          // header 里用 `this.feed!` 取 imageUrl / getTitle，feed 为 undefined 会抛
          // TypeError → 应用直接闪退（实测 log: Cannot read property imageUrl of undefined）。
          if (this.feed !== undefined) {
            this.header()
          }

          if (this.message !== '') {
            Text(this.message).fontFamily(this.appFontFamily)
              .fontSize(DesignTokens.FONT_FOOTNOTE)
              .fontColor($r('app.color.primary'))
              .padding({ left: DesignTokens.PAGE_MARGIN, top: DesignTokens.SPACE_XS })
          }
          if (this.selecting) {
            this.selectionBar()
          }

          // ---- 单集区：第一行「单集」+ 排序 / 筛选 / 设置；第二行筛选标签（同一功能区域，间距收紧）
          Row() {
            Text($r('app.string.episodes_label')).fontFamily(this.appFontFamily)
              .fontSize(DesignTokens.FONT_SECTION)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
            // 预览模式（未订阅）下这些动作都依赖已入库的 Feed：排序落库、筛选落库、设置页按 feedId 读库，
            // 因此只在已订阅时提供，避免点了没反应或写坏数据。
            if (!this.previewMode) {
              this.listToolIcon($r('sys.symbol.sort'), () => {
                this.showSortSheet = true;
              })
              this.listToolIcon($r('sys.symbol.funnel'), () => {
                this.openFilterSheet();
              })
              this.listToolIcon($r('sys.symbol.gearshape'), () => {
                router.pushUrl({ url: 'pages/FeedSettingsPage', params: { feedId: this.feed!.id } });
              })
            }
          }
          .width('100%')
          .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.SPACE_S, top: DesignTokens.SPACE_XS })
          .alignItems(VerticalAlign.Center)

          Row({ space: DesignTokens.SPACE_S }) {
            TagChip({
              label: $r('app.string.filter_all'),
              selected: this.filter === 'all',
              onTap: () => {
                this.filter = 'all';
                this.loadEpisodes();
              }
            })
            TagChip({
              label: $r('app.string.filter_unplayed'),
              selected: this.filter === 'unplayed',
              onTap: () => {
                this.filter = 'unplayed';
                this.loadEpisodes();
              }
            })
            TagChip({
              label: $r('app.string.filter_downloaded'),
              selected: this.filter === 'downloaded',
              onTap: () => {
                this.filter = 'downloaded';
                this.loadEpisodes();
              }
            })
          }
          .width('100%')
          .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN, top: DesignTokens.SPACE_XS, bottom: DesignTokens.SPACE_XS })

          if (this.filterActive) {
            Row({ space: DesignTokens.SPACE_XS }) {
              SymbolGlyph($r('sys.symbol.funnel'))
                .fontSize(DesignTokens.ICON_XS)
                .fontColor([$r('app.color.text_tertiary')])
              Text($r('app.string.filter_active_hint')).fontFamily(this.appFontFamily)
                .fontSize(DesignTokens.FONT_CAPTION)
                .fontColor($r('app.color.text_tertiary'))
            }
            .padding({ left: DesignTokens.PAGE_MARGIN, bottom: DesignTokens.SPACE_XS })
          }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }

          if (this.loading) {
            ListItem() {
              Text($r('app.string.loading')).fontFamily(this.appFontFamily)
                .fontSize(DesignTokens.FONT_PARAGRAPH)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding(DesignTokens.PAGE_MARGIN)
            }
          } else if (this.errorMessage !== '') {
            ListItem() {
              Row({ space: DesignTokens.SPACE_S }) {
                SymbolGlyph($r('sys.symbol.warning'))
                  .fontSize(DesignTokens.ICON_L)
                  .fontColor([$r('app.color.error')])
                Text(this.errorMessage).fontFamily(this.appFontFamily)
                  .fontSize(DesignTokens.FONT_PARAGRAPH)
                  .fontColor($r('app.color.error'))
                  .layoutWeight(1)
              }
              .width('100%')
              .padding(DesignTokens.PAGE_MARGIN)
            }
          } else if (this.episodes.length === 0) {
            ListItem() {
              Column() {
                EmptyState({ icon: $r('sys.symbol.music'), title: $r('app.string.placeholder_episodes') })
              }
              .width('100%')
              .padding({ top: DesignTokens.SPACE_XXL })
            }
          } else {
            ForEach(this.episodes, (item: FeedItem) => {
              ListItem() {
                this.episodeRow(item)
              }
              .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
              // 左右滑动作来自设置页配置（`start` = 右滑，`end` = 左滑）
              .swipeAction(this.swipeOptions(item))
            }, (item: FeedItem) => this.rowKey(item))
          }
        }
        .width('100%')
        .height('100%')
        // 根容器把背景铺到了手势条下方（expandSafeArea BOTTOM），列表需要额外的底部余量，
        // 否则最后一行会被系统手势条压住 / 被屏幕边缘裁掉（原来只留 SPACE_XXL 不够）。
        .padding({ bottom: DesignTokens.SPACE_XXL + 56 })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onDidScroll(() => {
          // 仅下拉回弹时向上延展同一个头部背景，正常滚动不做位移补偿。
          this.pullDistance = Math.max(0, -this.listScroller.currentOffset().yOffset);
        })
        .id('feed-detail-scroll')
      }
      .width('100%')
      .height('100%')
      .mode(NavigationMode.Stack)
      .titleMode(HdsNavigationTitleMode.MINI)
      .hideBackButton(true)
      .hideToolBar(true)
      .titleBar({
        padding: { start: LengthMetrics.vp(0), end: LengthMetrics.vp(0) },
        content: {
          stackBuilder: this.navigationActions.bind(this),
          divider: { showType: DividerShowType.OFF }
        },
        style: {
          originalStyle: { backgroundStyle: { backgroundColor: Color.Transparent } },
          scrollEffectOpts: {
            enableScrollEffect: true,
            scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
            blurEffectiveStartOffset: LengthMetrics.vp(0),
            blurEffectiveEndOffset: LengthMetrics.vp(120)
          }
        }
      })
      .bindToScrollable([this.listScroller])
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      // 关键：HdsNavigation 已经忽略布局安全区（内容会画到底部手势区），
      // 但它自己的背景是透明的 → 底部露出窗口默认白底。
      // 这里给它铺上页面底色，背景就真正延伸到了小白条背后。
      .backgroundColor($r('app.color.page_bg'))


      if (this.showSortSheet) {
        this.sortSheet()
      }
      if (this.showFilterSheet) {
        this.filterSheet()
      }
      if (this.showActionSheet) {
        this.actionSheet()
      }
      if (this.showStreamConfirm) {
        this.streamConfirmSheet()
      }


    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    // 安全区统一交给 HdsNavigation，根容器不再重复 expandSafeArea。
  }

  @Builder
  navigationActions() {
    AppBar({ title: '', showBack: true, bgColor: Color.Transparent }) {
      this.appBarActions()
    }
  }

  /** 标题栏右侧（对齐上游 menu/feedlist：搜索常驻，其余进溢出菜单） */
  @Builder
  appBarActions() {
    // 预览模式（未订阅）不提供「站内搜索本节目」和溢出菜单：两者都按 feedId 查库 / 改库，
    // 未入库时无从执行。此时右侧只剩「订阅」这一个决定，语义更清晰。
    if (!this.previewMode) {
      Row({ space: DesignTokens.SPACE_XS }) {
        AppIconButton({
          symbol: $r('sys.symbol.magnifyingglass'),
          onTap: () => {
            router.pushUrl({ url: 'pages/SearchPage', params: { term: '', feedId: this.feed!.id } });
          }
        })
        OverflowButton({ symbol: $r('sys.symbol.ellipsis_circle') }) {
          this.feedMenu()
        }
      }
    }
  }

  @Builder
  feedMenu() {
    Menu() {
      MenuItem({ symbolStartIcon: menuIcon($r('sys.symbol.sort')), content: $r('app.string.feed_sort') })
        .onClick(() => {
          this.showSortSheet = true;
        })
      MenuItem({ symbolStartIcon: menuIcon($r('sys.symbol.arrow_clockwise')), content: $r('app.string.refresh_label') })
        .onClick(() => {
          this.refreshFeed();
        })
      MenuItem({ symbolStartIcon: menuIcon($r('sys.symbol.funnel')), content: $r('app.string.feed_filter') })
        .onClick(() => {
          this.openFilterSheet();
        })
      MenuItem({ symbolStartIcon: menuIcon($r('sys.symbol.share')), content: $r('app.string.episode_share') })
        .onClick(() => {
          if (this.episodes.length > 0) {
            this.share(this.episodes[0]);
          }
        })
      MenuItem({ symbolStartIcon: menuIcon($r('sys.symbol.gearshape')), content: $r('app.string.feed_settings') })
        .onClick(() => {
          router.pushUrl({ url: 'pages/FeedSettingsPage', params: { feedId: this.feed!.id } });
        })
    }
  }

  @Builder
  streamConfirmSheet() {
    Column({ space: DesignTokens.SPACE_L }) {
      Text($r('app.string.stream_confirm_message')).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_PARAGRAPH)
        .fontColor($r('app.color.text_primary'))
        .padding({ top: DesignTokens.SPACE_XL, left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
      Row({ space: DesignTokens.SPACE_M }) {
        Button($r('app.string.dialog_cancel'))
          .layoutWeight(1)
          .height(DesignTokens.HEIGHT_BUTTON)
          .fontSize(DesignTokens.FONT_PARAGRAPH)
          .backgroundColor($r('app.color.surface_secondary'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.showStreamConfirm = false;
            this.pendingItem = undefined;
          })
        Button($r('app.string.stream_confirm_play'))
          .layoutWeight(1)
          .height(DesignTokens.HEIGHT_BUTTON)
          .fontSize(DesignTokens.FONT_PARAGRAPH)
          .backgroundColor($r('app.color.primary'))
          .fontColor($r('app.color.on_primary'))
          .onClick(() => {
            this.showStreamConfirm = false;
            this.streamConfirmed = true;
            const item: FeedItem | undefined = this.pendingItem;
            this.pendingItem = undefined;
            if (item !== undefined) {
              this.playNow(item);
            }
          })
      }
      .width('90%')
      .margin({ bottom: DesignTokens.SPACE_L })
    }
    .width('100%')
    .backgroundColor($r('app.color.surface'))
    .borderRadius({ topLeft: DesignTokens.RADIUS_SHEET, topRight: DesignTokens.RADIUS_SHEET })
  }

  /** 同一 List 的头部：背景绝对定位于头部内，高度由封面、简介等内容实测决定。 */
  @Builder
  header() {
    // 背景与封面属于同一个 ListItem，正常滚动时位移完全一致。
    // 不在页面根 Stack 保留任何封面副本。
    Stack({ alignContent: Alignment.Top }) {
      Column() {
        FlowingLightBackground({
          imageUrl: this.feed === undefined ? '' : this.feed.imageUrl,
          fallbackTitle: '',
          extendSafeArea: false
        })
      }
      .width('100%')
      .height(Math.max(1, this.headerHeight) + this.pullDistance)
      .position({ x: 0, y: -this.pullDistance })
      .hitTestBehavior(HitTestMode.None)

      // 只属于滚动头部的主题遮罩，保证状态栏图标在亮/暗封面上均有对比度。
      Column()
        .width('100%')
        .height(this.statusInset + DesignTokens.HEIGHT_APP_BAR + DesignTokens.SPACE_XL + this.pullDistance)
        .position({ x: 0, y: -this.pullDistance })
        .linearGradient({ angle: 180, colors: [[$r('app.color.page_bg'), 0], [Color.Transparent, 1]] })
        .opacity(0.65)
        .hitTestBehavior(HitTestMode.None)

      // 全高度渐变避免局部遮罩的起始边界；透明端 RGB 与页面底色一致，防止深色泛白。
      Column()
        .width('100%')
        .height(this.headerHeight)
        .position({ x: 0, y: 0 })
        .linearGradient({
          angle: 180,
          colors: [
            [$r('app.color.flow_fade_transparent'), 0],
            [$r('app.color.flow_fade_transparent'), 0.48],
            [$r('app.color.page_bg'), 1]
          ]
        })
        .hitTestBehavior(HitTestMode.None)

      Column({ space: DesignTokens.SPACE_M }) {
      FeedCover({
        imageUrl: this.feed!.imageUrl,
        coverSize: 176,
        radius: 20,
        fallbackTitle: this.feed!.getTitle(),
        placeholderColor: $r('app.color.cover_placeholder')
      })
        .margin({ top: DesignTokens.SPACE_S })

      // ---- 节目名 + 主播：整体居中
      Column({ space: DesignTokens.SPACE_XS }) {
        Text(this.feed!.getTitle()).fontFamily(this.appFontFamily)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .textAlign(TextAlign.Center)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(29)
        if (this.feedAuthor() !== '') {
          Text(this.feedAuthor()).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_SUBTITLE)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)

      // ---- 操作行：主按钮 + 圆形订阅
      Row({ space: DesignTokens.SPACE_M }) {
        if (this.episodes.length > 0) {
          this.latestEpisodeAction()
        }
        this.subscribeAction()
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

      // ---- 简介：默认 2 行，可展开/收起
      if (this.feedDescription() !== '') {
        Column({ space: DesignTokens.SPACE_XS }) {
          Text(this.feedDescription()).fontFamily(this.appFontFamily)
            .width('100%')
            .fontSize(DesignTokens.FONT_PARAGRAPH)
            .fontColor($r('app.color.text_secondary'))
            .lineHeight(21)
            .maxLines(this.descriptionExpanded ? 60 : 2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.descriptionExpanded ? $r('app.string.feed_show_less') : $r('app.string.home_more')).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_FOOTNOTE)
            .fontColor($r('app.color.primary'))
            .onClick(() => {
              this.descriptionExpanded = !this.descriptionExpanded;
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }

      // ---- 元信息：单集数 · 最近更新
      Row({ space: DesignTokens.SPACE_XS }) {
        Text($r('app.string.feed_episode_count', this.episodeCountText())).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_FOOTNOTE)
          .fontColor($r('app.color.text_secondary'))
        if (this.lastUpdateText() !== '') {
          Text('·').fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_FOOTNOTE)
            .fontColor($r('app.color.text_tertiary'))
          Text($r('app.string.feed_updated_at', this.lastUpdateText())).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_FOOTNOTE)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.Start)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({
        left: DesignTokens.PAGE_MARGIN,
        right: DesignTokens.PAGE_MARGIN,
        top: this.statusInset + DesignTokens.HEIGHT_APP_BAR + DesignTokens.SPACE_S,
        bottom: DesignTokens.SPACE_M
      })
      .onAreaChange((_old: Area, next: Area) => {
        const height: Length = next.height;
        if (typeof height === 'number' && height > 0 && Math.abs(height - this.headerHeight) > 0.5) {
          this.headerHeight = height;
        }
      })
    }
    .width('100%')
  }

  /** 主播 / 作者（为空时回落到站点链接） */
  private feedAuthor(): string {
    if (this.feed === undefined) {
      return '';
    }
    return this.feed.author !== '' ? this.feed.author : this.feed.link;
  }

  /** 单集数（当前列表条数，不做额外查询） */
  private episodeCountText(): string {
    return this.episodes.length.toString();
  }

  /**
   * 最近更新的日期（本地化）：
   * 优先用 Feed.lastUpdate；解析不出来（空串 / 格式异常）时回落到最新一集的发布日期，
   * 都没有就返回空串——调用方据此隐藏这一段，不显示占位符。
   */
  private lastUpdateText(): string {
    if (this.feed === undefined) {
      return '';
    }
    if (this.feed.lastUpdate !== '') {
      const millis: number = DateUtils.parseToEpochMillis(this.feed.lastUpdate);
      if (millis > 0) {
        return new Date(millis).toLocaleDateString();
      }
    }
    if (this.episodes.length > 0 && this.episodes[0].pubDate > 0) {
      return new Date(this.episodes[0].pubDate).toLocaleDateString();
    }
    return '';
  }
  feedDescription(): string {
    if (this.feed === undefined || this.feed.description === '') {
      return '';
    }
    return HtmlCleaner.stripHtml(this.feed.description).replace(/\s+/g, ' ').trim();
  }
  /**
   * 订阅按钮（按参考图：主按钮右侧的圆形按钮）。
   * 未订阅 = 加号（品牌紫）；已订阅 = 对勾（正文色）。点击行为不变（toggleSubscribe）。
   */
  @Builder
  subscribeAction() {
    Stack() {
      SymbolGlyph(this.subscribed ? $r('sys.symbol.checkmark') : $r('sys.symbol.plus'))
        .fontSize(DesignTokens.ICON_M)
        .fontColor([this.subscribed ? $r('app.color.player_text') : $r('app.color.primary')])
    }
    .width(46)
    .height(46)
    .borderRadius(23)
    .backgroundColor($r('app.color.detail_action_chip'))
    .alignContent(Alignment.Center)
    .accessibilityText($r('app.string.discover_subscribe'))
    .accessibilitySelected(this.subscribed)
    .onClick(() => {
      this.toggleSubscribe();
    })
  }

  /** 「最近单集」：复用项目已有的真实播放能力（当前排序第一条），不编造数据 */
  @Builder
  latestEpisodeAction() {
    Row({ space: DesignTokens.SPACE_S }) {
      SymbolGlyph($r('sys.symbol.play_fill'))
        .fontSize(DesignTokens.ICON_S)
        .fontColor([$r('app.color.player_text')])
      Text($r('app.string.feed_latest_episode')).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_SUBTITLE)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.player_text'))
        .maxLines(1)
    }
    // 与参考图一致：胶囊比封面窄、居中排在圆形订阅按钮左侧
    .width(196)
    .height(46)
    .justifyContent(FlexAlign.Center)
    .borderRadius(23)
    .backgroundColor($r('app.color.detail_action_chip'))
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.play(this.episodes[0]);
    })
  }

  /** 单集区工具图标（排序 / 筛选 / 设置）：统一 40vp 热区、无背景圆圈 */
  @Builder
  listToolIcon(icon: Resource, onTap: () => void) {
    Stack() {
      SymbolGlyph(icon)
        .fontSize(DesignTokens.ICON_M)
        .fontColor([$r('app.color.text_secondary')])
    }
    .width(40)
    .height(40)
    .alignContent(Alignment.Center)
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  headerIcon(icon: Resource, onTap: () => void) {
    Stack() {
      SymbolGlyph(icon)
        .fontSize(DesignTokens.ICON_XL)
        .fontColor([Color.White])
    }
    .width(48)
    .height(48)
    .alignContent(Alignment.Center)
    .onClick(() => {
      onTap();
    })
  }

  /**
   * 多选操作条（对照上游 multi_select_options.xml + FloatingSelectMenu）。
   *
   * 排版按 iOS / HarmonyOS 系统面板口径重做：
   * - 整条是一个 16 圆角卡片，左右各 16vp 页面边距，不再贴边；
   * - 第一行「已选 N」+ 右侧两个纯文字动作（全选 / 完成），用品牌色、无底色块；
   * - 中间一条 0.5vp 分隔线，把「计数区」与「动作区」分开；
   * - 动作区固定 5 等分（layoutWeight），不再横向滚动 —— 原来用 Scroll + 4vp 间距，
   *   内容超宽时右侧会被裁掉，看起来就是「贴着屏幕边」。
   */
  @Builder
  selectionBar() {
    // 外面这层 Row 只负责左右 16vp 边距：卡片本身不再带 margin + width('100%')，
    // 否则「100% 宽 + 左右 margin」会超出父容器，右端被裁掉（上一版「完成」被切掉就是这个原因）。
    Row() {
      Column() {
      Row() {
        Text(getContext(this).resourceManager.getStringSync($r('app.string.queue_selected')) + ' '
          + this.selectedIds.length).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_PARAGRAPH)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text($r('app.string.select_all_label')).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_PARAGRAPH)
          .fontColor($r('app.color.primary'))
          .padding({ left: DesignTokens.SPACE_M, right: DesignTokens.SPACE_M })
          .onClick(() => {
            this.selectedIds = this.episodes.map((item: FeedItem) => item.id);
          })
        Text($r('app.string.queue_cancel_select')).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_PARAGRAPH)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.primary'))
          .padding({ left: DesignTokens.SPACE_M, right: DesignTokens.SPACE_M })
          .onClick(() => {
            this.exitSelection();
          })
      }
      .width('100%')
      .height(44)
      .alignItems(VerticalAlign.Center)
      .padding({ left: DesignTokens.SPACE_M, right: DesignTokens.SPACE_XS })

      Divider()
        .color($r('app.color.divider'))
        .strokeWidth(0.5)
        .margin({ left: DesignTokens.SPACE_M, right: DesignTokens.SPACE_M })

      Row() {
        this.selectionAction($r('sys.symbol.checkmark_circle'), $r('app.string.episode_mark_played'), () => {
          this.batchMarkPlayed(true);
        })
        this.selectionAction($r('sys.symbol.circle'), $r('app.string.episode_mark_unplayed'), () => {
          this.batchMarkPlayed(false);
        })
        this.selectionAction($r('sys.symbol.music_note_list'), $r('app.string.episode_add_queue'), () => {
          this.batchAddToQueue();
        })
        this.selectionAction($r('sys.symbol.arrow_down_circle'), $r('app.string.episode_download'), () => {
          this.batchDownload();
        })
        this.selectionAction($r('sys.symbol.trash'), $r('app.string.episode_delete_download'), () => {
          this.batchDeleteDownload();
        })
      }
      .width('100%')
      .padding({ top: DesignTokens.SPACE_S, bottom: DesignTokens.SPACE_S })
      }
      .width('100%')
      .backgroundColor($r('app.color.surface'))
      .borderRadius(16)
      .shadow({ radius: 12, color: '#14000000', offsetY: 2 })
    }
    .width('100%')
    .padding({
      left: DesignTokens.PAGE_MARGIN,
      right: DesignTokens.PAGE_MARGIN,
      top: DesignTokens.SPACE_S
    })
  }

  /** 单个动作：图标在上、文案在下，两行居中；5 个等分整行宽度 */
  @Builder
  selectionAction(icon: Resource, label: ResourceStr, onTap: () => void) {
    Column({ space: 6 }) {
      SymbolGlyph(icon)
        .fontSize(DesignTokens.ICON_M)
        .fontColor([$r('app.color.text_primary')])
      Text(label).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .maxLines(2)
        .lineHeight(14)
    }
    .layoutWeight(1)
    .height(56)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: DesignTokens.SPACE_XS, right: DesignTokens.SPACE_XS })
    .onClick(() => {
      onTap();
    })
  }

  toggleSelected(itemId: number): void {
    if (this.selectedIds.includes(itemId)) {
      this.selectedIds = this.selectedIds.filter((id: number) => id !== itemId);
    } else {
      this.selectedIds = this.selectedIds.concat([itemId]);
    }
  }

  exitSelection(): void {
    this.selecting = false;
    this.selectedIds = [];
  }

  selectedItems(): FeedItem[] {
    return this.episodes.filter((item: FeedItem) => this.selectedIds.includes(item.id));
  }

  async batchMarkPlayed(played: boolean): Promise<void> {
    try {
      for (const item of this.selectedItems()) {
        await EpisodeRepository.markPlayed(item.id, played);
        const data: FeedItemUpdateData = { feedId: item.feedId, itemId: item.id };
        EventHub.publish(EventType.FEED_ITEM_UPDATE, data);
      }
      this.exitSelection();
      await this.loadEpisodes();
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }

  async batchAddToQueue(): Promise<void> {
    try {
      for (const item of this.selectedItems()) {
        await QueueEngine.add(item);
      }
      this.exitSelection();
      this.showMessage(getContext(this).resourceManager.getStringSync($r('app.string.queue_added')));
      await this.loadEpisodes();
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }

  async batchDownload(): Promise<void> {
    try {
      for (const item of this.selectedItems()) {
        if (item.media !== undefined && item.media.downloadUrl !== '' && item.media.fileUrl === '') {
          await DownloadManager.startDownload(item.media, item.title);
        }
      }
      this.exitSelection();
      await this.loadEpisodes();
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }

  async batchDeleteDownload(): Promise<void> {
    try {
      for (const item of this.selectedItems()) {
        if (item.media !== undefined && item.media.fileUrl !== '') {
          await DownloadManager.deleteFile(item.media);
        }
      }
      this.exitSelection();
      await this.loadEpisodes();
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }

  /** 剧集行（对齐上游 feeditemlist_item.xml：封面 + 状态行 + 标题 + 进度行 + 48vp 次级操作） */
  /**
   * 单集行（参考图 1 的版式）。
   *
   * 布局：左侧文字区（相对时间 → 标题 → 摘要 → 时长胶囊），右上方形缩略图，
   * 右下角三点操作入口，行与行之间用细分割线区分（无独立卡片、无阴影）。
   * 下载状态通过时长胶囊左侧的图标体现：已下载 = 播放，未下载 = 下载箭头。
   */
  @Builder
  episodeRow(item: FeedItem) {
    Column({ space: DesignTokens.SPACE_S }) {
      Row({ space: DesignTokens.SPACE_M }) {
        // ---- 左：文字区（决定行高）
        Column({ space: DesignTokens.SPACE_XS }) {
          // 相对时间：用 Text($r(..., count)) 让框架替换 %1$s 占位
          if (this.relativeTimeLabel(item).text === 'just_now') {
            Text($r('app.string.time_just_now')).fontFamily(this.appFontFamily)
              .fontSize(DesignTokens.FONT_FOOTNOTE)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
          } else if (this.relativeTimeLabel(item).text === 'minutes') {
            Text($r('app.string.time_minutes_ago', this.relativeTimeLabel(item).count.toString())).fontFamily(this.appFontFamily)
              .fontSize(DesignTokens.FONT_FOOTNOTE)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
          } else if (this.relativeTimeLabel(item).text === 'hours') {
            Text($r('app.string.time_hours_ago', this.relativeTimeLabel(item).count.toString())).fontFamily(this.appFontFamily)
              .fontSize(DesignTokens.FONT_FOOTNOTE)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
          } else if (this.relativeTimeLabel(item).text === 'days') {
            Text($r('app.string.time_days_ago', this.relativeTimeLabel(item).count.toString())).fontFamily(this.appFontFamily)
              .fontSize(DesignTokens.FONT_FOOTNOTE)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
          } else {
            Text(this.relativeTimeLabel(item).text).fontFamily(this.appFontFamily)
              .fontSize(DesignTokens.FONT_FOOTNOTE)
              .fontColor($r('app.color.text_tertiary'))
              .maxLines(1)
          }
          Text(item.title).fontFamily(this.appFontFamily)
            .width('100%')
            .fontSize(DesignTokens.FONT_SUBTITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(21)

          Text(this.episodeSummary(item)).fontFamily(this.appFontFamily)
            .width('100%')
            .fontSize(DesignTokens.FONT_FOOTNOTE)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(17)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // ---- 右：方形缩略图（参考图尺寸偏大，88vp / 圆角 14）
        FeedCover({
          imageUrl: item.imageUrl !== '' ? item.imageUrl : (this.feed === undefined ? '' : this.feed.imageUrl),
          coverSize: 88,
          radius: 14,
          fallbackTitle: this.feed === undefined ? '' : this.feed.getTitle(),
          placeholderColor: $r('app.color.cover_placeholder')
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // ---- 底部：时长胶囊（兼下载入口）+ 三点菜单
      Row() {
        this.durationChip(item)
        Blank()
        if (this.downloadState(item) === 'RUNNING' || this.downloadState(item) === 'PAUSED') {
          Text(this.downloadProgress(item) >= 0 ? this.downloadProgress(item).toFixed(0) + '%' : '').fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_OVERLINE)
            .fontColor($r('app.color.primary'))
        }
        Stack() {
          SymbolGlyph($r('sys.symbol.ellipsis_circle'))
            .fontSize(DesignTokens.ICON_M)
            .fontColor([$r('app.color.text_tertiary')])
        }
        .width(36)
        .height(36)
        .alignContent(Alignment.Center)
        .onClick(() => {
          this.openActionSheet(item);
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 细分割线（参考图 1 的条目分隔）
      Divider()
        .color($r('app.color.divider'))
        .strokeWidth(0.5)
    }
    .width('100%')
    .padding({ top: DesignTokens.SPACE_M, bottom: DesignTokens.SPACE_S })
    .backgroundColor(this.selectedIds.includes(item.id)
      ? $r('app.color.primary_container')
      : Color.Transparent)
    .borderRadius(this.selectedIds.includes(item.id) ? 12 : 0)
    .onClick(() => {
      if (this.selecting) {
        this.toggleSelected(item.id);
      } else {
        // 预览态也能点开：先按需订阅拿到真实单集 id，再进详情页
        this.handleOpenEpisode(item);
      }
    })
    // Column 没有 onLongPress 属性，长按用 gesture 绑定（与全工程其它列表一致）
    .gesture(LongPressGesture().onAction(() => {
      if (this.previewMode) {
        // 预览态长按没有意义（未入库无法多选），先订阅再交给用户
        this.handlePreviewLongPress();
        return;
      }
      if (this.selecting) {
        this.openActionSheet(item);
      } else {
        this.selecting = true;
        this.selectedIds = [item.id];
      }
    }))
  }

  /** 时长胶囊：左侧图标随下载状态变化，点击 = 播放 / 下载（复用原有动作分支） */
  @Builder
  durationChip(item: FeedItem) {
    Row({ space: DesignTokens.SPACE_XS }) {
      SymbolGlyph(this.downloadState(item) === 'DONE'
        ? $r('sys.symbol.play_fill') : $r('sys.symbol.arrow_down'))
        .fontSize(DesignTokens.ICON_XS)
        .fontColor([$r('app.color.primary')])
      Text(this.durationText(item) === '' ? '--' : this.durationText(item)).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_FOOTNOTE)
        .fontColor($r('app.color.primary'))
        .maxLines(1)
    }
    .height(26)
    .padding({ left: DesignTokens.SPACE_S, right: DesignTokens.SPACE_M })
    .borderRadius(13)
    .backgroundColor($r('app.color.primary_container'))
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (this.selecting) {
        this.toggleSelected(item.id);
        return;
      }
      if (this.previewMode) {
        // 预览态：点胶囊直接播放（按需订阅以保存进度），不再弹「订阅后可收听」
        this.handlePreviewPlay(item);
        return;
      }
      if (this.downloadState(item) === 'DONE') {
        this.play(item);
      } else if (this.downloadState(item) === 'RUNNING') {
        DownloadManager.pause(item.media!.id);
      } else if (this.downloadState(item) === 'PAUSED') {
        DownloadManager.resume(item.media!.id);
      } else {
        this.startDownload(item);
      }
    })
  }
  /**
   * 划出项配置：左右两个动作都取自偏好（`SwipeActions.resolve`），
   * 该屏幕关闭滑动动作、或某一侧配置为「无」时，对应侧不挂划出项。
   */
  private swipeOptions(item: FeedItem): SwipeActionOptions {
    const options: SwipeActionOptions = {};
    if (!SwipeActions.isEnabled(SwipeScreen.FEED_DETAIL)) {
      return options;
    }
    if (this.swipeRightId !== SwipeActionId.NONE) {
      const rightSpec: SwipeActionSpec = swipeActionSpec(this.swipeRightId);
      const rightItem: SwipeActionItem = {
        builder: () => {
          this.swipeButton(rightSpec, item);
        },
        actionAreaDistance: FeedDetailPage.SWIPE_ACTION_DISTANCE,
        onAction: () => {
          this.runSwipeAction(this.swipeRightId, item);
        }
      };
      options.start = rightItem;
    }
    if (this.swipeLeftId !== SwipeActionId.NONE) {
      const leftSpec: SwipeActionSpec = swipeActionSpec(this.swipeLeftId);
      const leftItem: SwipeActionItem = {
        builder: () => {
          this.swipeButton(leftSpec, item);
        },
        actionAreaDistance: FeedDetailPage.SWIPE_ACTION_DISTANCE,
        onAction: () => {
          this.runSwipeAction(this.swipeLeftId, item);
        }
      };
      options.end = leftItem;
    }
    return options;
  }

  /**
   * 划出项按钮（图标 + 名称，破坏性动作用 error 配色）。
   * 拖到动作区松手由 `onAction` 触发，近距划出后点按钮同样执行动作。
   * 注意：builder 在渲染期就会执行，绝不能在这里直接调用副作用方法。
   */
  @Builder
  swipeButton(spec: SwipeActionSpec, item: FeedItem) {
    SwipeActionButton({
      spec: spec,
      destructive: isDestructiveSwipeAction(spec.id),
      onTap: () => {
        this.runSwipeAction(spec.id, item);
      }
    })
  }

  /**
   * 收起已划出的行。`swipeAction.onAction` 触发后框架不会自动复位
   * （官方 FAQ「如何将 ListItem 的 swipeAction 滑动效果恢复至未滑动」给的正是
   * `ListScroller.closeAllSwipeActions()`）；上游 ItemTouchHelper 会自动复位，
   * 本移植版漏掉这段，「左滑标记为已播放」这种不删行的动作会把行一直停在滑出状态。
   */
  private closeSwipes(): void {
    try {
      this.listScroller.closeAllSwipeActions();
    } catch (error) {
      // 列表未绑定时（加载中 / 空列表）忽略：此时不可能有展开的划出项
    }
  }

  /** 划出项动作分发：只调用本页已有方法，不在这里重复实现动作逻辑 */
  private runSwipeAction(id: string, item: FeedItem): void {
    // 先收回划出项再执行动作：动作多为异步落库，等它回来再收会有明显延迟
    this.closeSwipes();
    if (id === SwipeActionId.MARK_PLAYED) {
      this.togglePlayed(item);
      return;
    }
    if (id === SwipeActionId.ADD_TO_QUEUE) {
      this.addToQueue(item);
      return;
    }
    if (id === SwipeActionId.START_DOWNLOAD) {
      this.startDownload(item);
      return;
    }
    if (id === SwipeActionId.DELETE) {
      this.deleteDownload(item);
      return;
    }
    if (id === SwipeActionId.MARK_FAV) {
      this.setFavorite(item, true);
      return;
    }
    if (id === SwipeActionId.REMOVE_FROM_FAVORITES) {
      this.setFavorite(item, false);
      return;
    }
    if (id === SwipeActionId.REMOVE_FROM_INBOX) {
      this.removeFromInbox(item);
      return;
    }
    if (id === SwipeActionId.SHARE) {
      this.share(item);
    }
  }

  /** 解析本屏的 [右滑, 左滑] 动作 id（aboutToAppear 与 SWIPE_ACTIONS_CHANGED 时调用） */
  private loadSwipeActions(): void {
    const ids: string[] = SwipeActions.resolve(SwipeScreen.FEED_DETAIL);
    this.swipeRightId = ids[0];
    this.swipeLeftId = ids[1];
  }

  @Builder
  sortSheet() {
    Column({ space: 2 }) {
      Text($r('app.string.feed_sort')).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .padding(DesignTokens.SPACE_L)
      this.sortOption($r('app.string.sort_date_new_old'), SortOrder.DATE_NEW_OLD)
      this.sortOption($r('app.string.sort_date_old_new'), SortOrder.DATE_OLD_NEW)
      this.sortOption($r('app.string.sort_title_a_z'), SortOrder.TITLE_A_Z)
      this.sortOption($r('app.string.sort_title_z_a'), SortOrder.TITLE_Z_A)
      this.sortOption($r('app.string.sort_duration_short_long'), SortOrder.DURATION_SHORT_LONG)
      this.sortOption($r('app.string.sort_duration_long_short'), SortOrder.DURATION_LONG_SHORT)
      Button($r('app.string.dialog_cancel'))
        .width('100%')
        .height(DesignTokens.HEIGHT_BUTTON)
        .backgroundColor($r('app.color.surface_secondary'))
        .fontColor($r('app.color.text_primary'))
        .fontSize(DesignTokens.FONT_PARAGRAPH)
        .margin({ top: DesignTokens.SPACE_M, bottom: DesignTokens.SPACE_M })
        .onClick(() => {
          this.showSortSheet = false;
        })
    }
    .width('100%')
    .backgroundColor($r('app.color.surface'))
    .borderRadius({ topLeft: DesignTokens.RADIUS_SHEET, topRight: DesignTokens.RADIUS_SHEET })
    .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
  }

  @Builder
  sortOption(label: ResourceStr, order: SortOrder) {
    Row({ space: DesignTokens.SPACE_S }) {
      Text(label).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_SUBTITLE)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      if (this.feed !== undefined && this.feed!.sortOrder === order) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(DesignTokens.ICON_M)
          .fontColor([$r('app.color.primary')])
      }
    }
    .width('100%')
    .padding({ left: DesignTokens.SPACE_S, top: DesignTokens.SPACE_M, bottom: DesignTokens.SPACE_M })
    .onClick(() => {
      this.applySort(order);
    })
  }

  @Builder
  filterSheet() {
    Column({ space: DesignTokens.SPACE_S }) {
      Text($r('app.string.feed_filter')).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .padding({ top: DesignTokens.SPACE_L })
      Text($r('app.string.filter_include_label')).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_FOOTNOTE)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
      TextInput({ text: this.filterInclude }).fontFamily(this.appFontFamily)
        .width('100%')
        .height(DesignTokens.HEIGHT_BUTTON)
        .fontSize(DesignTokens.FONT_PARAGRAPH)
        .backgroundColor($r('app.color.surface_secondary'))
        .onChange((value: string) => {
          this.filterInclude = value;
        })
      Text($r('app.string.filter_exclude_label')).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_FOOTNOTE)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
      TextInput({ text: this.filterExclude }).fontFamily(this.appFontFamily)
        .width('100%')
        .height(DesignTokens.HEIGHT_BUTTON)
        .fontSize(DesignTokens.FONT_PARAGRAPH)
        .backgroundColor($r('app.color.surface_secondary'))
        .onChange((value: string) => {
          this.filterExclude = value;
        })
      Text($r('app.string.filter_min_duration_label')).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_FOOTNOTE)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
      TextInput({ text: this.filterMinDuration }).fontFamily(this.appFontFamily)
        .width('100%')
        .height(DesignTokens.HEIGHT_BUTTON)
        .fontSize(DesignTokens.FONT_PARAGRAPH)
        .type(InputType.Number)
        .backgroundColor($r('app.color.surface_secondary'))
        .onChange((value: string) => {
          this.filterMinDuration = value;
        })
      Text($r('app.string.filter_terms_hint')).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
      Row({ space: DesignTokens.SPACE_M }) {
        Button($r('app.string.dialog_cancel'))
          .layoutWeight(1)
          .height(DesignTokens.HEIGHT_BUTTON)
          .fontSize(DesignTokens.FONT_PARAGRAPH)
          .backgroundColor($r('app.color.surface_secondary'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.showFilterSheet = false;
          })
        Button($r('app.string.dialog_save'))
          .layoutWeight(1)
          .height(DesignTokens.HEIGHT_BUTTON)
          .fontSize(DesignTokens.FONT_PARAGRAPH)
          .backgroundColor($r('app.color.primary'))
          .fontColor($r('app.color.on_primary'))
          .onClick(() => {
            this.saveFilter();
          })
      }
      .width('100%')
      .margin({ top: DesignTokens.SPACE_XS, bottom: DesignTokens.SPACE_L })
    }
    .width('100%')
    .backgroundColor($r('app.color.surface'))
    .borderRadius({ topLeft: DesignTokens.RADIUS_SHEET, topRight: DesignTokens.RADIUS_SHEET })
    .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
  }

  @Builder
  actionSheet() {
    Column({ space: 2 }) {
      Text(this.actionTitle).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_FOOTNOTE)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .padding(DesignTokens.SPACE_L)
      this.actionRow($r('sys.symbol.checkmark_circle'),
        this.actionItem !== undefined && this.actionItem!.isPlayed
          ? $r('app.string.episode_mark_unplayed') : $r('app.string.episode_mark_played'), () => {
          this.showActionSheet = false;
          if (this.actionItem !== undefined) {
            this.togglePlayed(this.actionItem!);
          }
        })
      this.actionRow($r('sys.symbol.music_note_list'), $r('app.string.episode_add_queue'), () => {
        this.showActionSheet = false;
        if (this.actionItem !== undefined) {
          this.addToQueue(this.actionItem!);
        }
      })
      this.actionRow($r('sys.symbol.share'), $r('app.string.episode_share'), () => {
        this.showActionSheet = false;
        if (this.actionItem !== undefined) {
          this.share(this.actionItem!);
        }
      })
      if (this.actionItem !== undefined && this.actionItem!.media !== undefined) {
        if (this.downloadState(this.actionItem!) === 'DONE') {
          this.actionRow($r('sys.symbol.trash'), $r('app.string.episode_delete_download'), () => {
            this.showActionSheet = false;
            if (this.actionItem !== undefined) {
              this.deleteDownload(this.actionItem!);
            }
          })
        } else {
          this.actionRow($r('sys.symbol.arrow_down_circle'), $r('app.string.episode_download'), () => {
            this.showActionSheet = false;
            if (this.actionItem !== undefined) {
              this.startDownload(this.actionItem!);
            }
          })
        }
      }
      Button($r('app.string.dialog_cancel'))
        .width('100%')
        .height(DesignTokens.HEIGHT_BUTTON)
        .backgroundColor($r('app.color.surface_secondary'))
        .fontColor($r('app.color.text_primary'))
        .fontSize(DesignTokens.FONT_PARAGRAPH)
        .margin({ top: DesignTokens.SPACE_M, bottom: DesignTokens.SPACE_M })
        .onClick(() => {
          this.showActionSheet = false;
        })
    }
    .width('100%')
    .backgroundColor($r('app.color.surface'))
    .borderRadius({ topLeft: DesignTokens.RADIUS_SHEET, topRight: DesignTokens.RADIUS_SHEET })
    .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
  }

  @Builder
  actionRow(icon: Resource, label: ResourceStr, onTap: () => void) {
    Row({ space: DesignTokens.SPACE_M }) {
      SymbolGlyph(icon)
        .fontSize(DesignTokens.ICON_L)
        .fontColor([$r('app.color.text_secondary')])
      Text(label).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_SUBTITLE)
        .fontColor($r('app.color.text_primary'))
    }
    .width('100%')
    .padding({ left: DesignTokens.SPACE_S, top: DesignTokens.SPACE_M, bottom: DesignTokens.SPACE_M })
    .onClick(() => {
      onTap();
    })
  }

  aboutToAppear(): void {
    this.mounted = true;
    ImmersiveHost.statusBarHeight(getContext(this) as common.UIAbilityContext).then((height: number) => {
      if (this.mounted) {
        this.statusInset = height;
      }
    });
    this.loadSwipeActions();
    const params = router.getParams() as FeedDetailParams;
    if (params !== undefined && params.feedId !== undefined) {
      this.load(params.feedId);
    } else if (params !== undefined && params.feedUrl !== undefined && params.feedUrl !== '') {
      // 从搜索结果进入：已订阅直接打开，未订阅先入库再打开——两者界面完全一致
      this.openFromSearch(params);
    }
    // 下载进度实时刷新（token 精确退订，不影响 Index/DownloadsPage 的监听）
    this.downloadToken = EventHub.subscribe(EventType.EPISODE_DOWNLOAD, (data: object) => {
      this.onDownloadEvent(data as Record<string, Object>);
    });
    // 设置页保存「滑动动作」后重新解析左右滑动作
    this.swipeToken = EventHub.subscribe(EventType.SWIPE_ACTIONS_CHANGED, (data: object) => {
      this.loadSwipeActions();
    });
  }

  aboutToDisappear(): void {
    this.mounted = false;
    EventHub.unsubscribeToken(this.downloadToken);
    EventHub.unsubscribeToken(this.swipeToken);
    if (this.messageTimerId >= 0) {
      clearTimeout(this.messageTimerId);
    }
  }

  /** 顶部提示自动消失（上游是 Toast/Snackbar 语义），避免提示条永久占位 */
  private showMessage(text: string): void {
    this.message = text;
    if (this.messageTimerId >= 0) {
      clearTimeout(this.messageTimerId);
    }
    this.messageTimerId = setTimeout(() => {
      this.message = '';
      this.messageTimerId = -1;
    }, 3000);
  }

  onDownloadEvent(record: Record<string, Object>): void {
    const state: string = record['state'] as string;
    if (state === 'DONE') {
      // 下载完成后 file_url 变了，需要重新查库才能反映"已下载"
      this.loadEpisodes();
      return;
    }
    // RUNNING / PAUSED / PROGRESS / FAILED / REMOVED 都只影响行内进度环与图标：
    // 本页重渲染一次、可视行按新状态重算 @Prop 即可。
    // **不能走 reloadRows()（setData → onDataReloaded）**：那会把整页行连同封面一起重建，
    // 下载期间（每来一次进度回调就整页重建一次）封面会连续闪 —— 用户报的故障。
    this.downloadTick = this.downloadTick + 1;
  }

  reloadRows(): void {
    this.dataSource.setData(this.episodes);
  }

  /**
   * 预览模式：只抓取解析、**不写库**。
   * 解析出的 `Feed` 直接当成本页的 `this.feed` 用（它带 `items`），
   * 于是头图、单集列表、筛选胶囊全部复用现有界面，无需另写一套预览 UI。
   */
  /**
   * 从「搜索结果卡片」进入详情：无论是否已订阅，最终都渲染**与订阅后完全一致的详情页**。
   *
   * 处理顺序：
   * 1. 已订阅（`getByDownloadUrl` 命中）→ 直接 `load(feedId)`，走原有逻辑；
   * 2. 未订阅 → 用 `SubscriptionService.subscribe` 入库并抓取单集，然后同样 `load(feedId)`。
   *    这样头图、筛选、排序、下载、取消订阅等**全部动作都可用且真实有效**，
   *    不存在「预览态缺功能」的问题。
   *
   * 之所以入库而不是内存预览：详情页的筛选 / 下载 / 播放都建立在数据库记录之上，
   * 只读预览会让这些按钮点了没反应，违背「内容完全一样」的要求。
   */
  async openFromSearch(params: FeedDetailParams): Promise<void> {
    const url: string = params.feedUrl === undefined ? '' : params.feedUrl;
    if (url === '') {
      this.loading = false;
      return;
    }
    // 先预热 RSS 域名（DNS/TLS），再拉正文：跨境源这一步能省下几秒
    NetworkWarmup.warm(url);
    this.loading = true;
    try {
      const existing: Feed | undefined = await FeedRepository.getByDownloadUrl(url);
      if (existing !== undefined) {
        // 已经订阅过：直接读库，行为与从订阅列表进入完全一致
        await this.load(existing.id);
        return;
      }
      // 未订阅：只抓一次 RSS 做「只读预览」，**不写库、不订阅**。
      // 用户是否订阅由书签按钮决定（见 toggleSubscribe）。
      const parsed = await FeedFetcher.fetchFeed(url);
      const preview: Feed = parsed.feed;
      preview.downloadUrl = url;
      preview.id = 0;
      if (params.previewTitle !== undefined && params.previewTitle !== '') {
        preview.title = params.previewTitle;
      }
      if (params.previewImageUrl !== undefined && params.previewImageUrl !== '') {
        preview.imageUrl = params.previewImageUrl;
      }
      this.previewItems = preview.items.slice();
      // 预览单集还没入库，id 全是 0。列表用 item.id 做 ForEach 的键，
      // 键重复时 ArkUI 只会渲染一行 —— 这就是「只显示一个单集」的原因。
      // 这里给预览条目编一批**负数合成 id**（与真实自增 id 永不相撞），保证每行都有独立键。
      let syntheticId: number = -1;
      for (const entry of this.previewItems) {
        entry.id = syntheticId;
        syntheticId--;
      }
      this.previewMode = true;
      this.feed = preview;
      this.subscribed = false;
      this.loading = false;
      await this.loadEpisodes();
    } catch (error) {
      this.feed = undefined;
      this.errorMessage = getContext(this).resourceManager.getStringSync($r('app.string.feed_preview_failed'))
        + (error as Error).message;
    } finally {
      this.loading = false;
    }
  }
  /**
   * 订阅 / 取消订阅（书签按钮的唯一写入口）。
   *
   * - 未订阅 → 写入订阅并抓取单集；已订阅 → 取消订阅。
   * - **只有业务成功后才更新 `subscribed`**，失败则保持原状态并给出提示。
   * - `togglingSubscribe` 防止连续点击造成重复请求。
   */
  async toggleSubscribe(): Promise<void> {
    if (this.feed === undefined || this.togglingSubscribe) {
      return;
    }
    this.togglingSubscribe = true;
    this.message = '';
    const url: string = this.feed.downloadUrl;
    try {
      if (this.subscribed) {
        // 取消订阅：先摘掉订阅记录，**保留已下载文件与播放记录**（与全局取消订阅语义区分）
        await SubscriptionService.unsubscribeKeepingFiles(this.feed.id);
        this.subscribed = false;
        this.showMessage(getContext(this).resourceManager.getStringSync($r('app.string.feed_unsubscribed')));
      } else {
        const feed: Feed = await SubscriptionService.subscribe(url);
        this.subscribed = true;
        // 订阅成功后退出预览态：单集、收藏、队列、滑动动作全部改走数据库
        this.previewMode = false;
        this.previewItems = [];
        this.feed = feed;
        this.showMessage(getContext(this).resourceManager.getStringSync($r('app.string.feed_subscribed')));
        // 新订阅会带回单集：重新载入列表，避免界面停留���「无内容」
        await this.loadEpisodes();
      }
    } catch (error) {
      // 失败：回读真实状态，保证界面与库一致
      await this.syncSubscribedState();
      this.message = getContext(this).resourceManager.getStringSync($r('app.string.subscribe_failed'))
        + (error as Error).message;
    } finally {
      this.togglingSubscribe = false;
    }
  }

  /** 按当前 feed 回读真实订阅状态（进入页面 / 操作失败后的纠偏） */
  async syncSubscribedState(): Promise<void> {
    if (this.feed === undefined || this.feed.downloadUrl === '') {
      this.subscribed = false;
      return;
    }
    try {
      const existing: Feed | undefined = await FeedRepository.getByDownloadUrl(this.feed.downloadUrl);
      this.subscribed = existing !== undefined;
    } catch (error) {
      this.subscribed = false;
    }
  }
  async load(feedId: number): Promise<void> {
    try {
      this.feed = await FeedRepository.getById(feedId);
      if (this.feed !== undefined) {
        this.filterInclude = this.feed.includeFilter;
        this.filterExclude = this.feed.excludeFilter;
        this.filterMinDuration = this.feed.minimalDurationFilter > 0
          ? this.feed.minimalDurationFilter.toString() : '';
        // 书签按钮的真实状态：由 feed.state 决定（重启 / 重新进入都能正确还原）
        this.subscribed = this.feed.state === 1;
      }
    } catch (error) {
      this.feed = undefined;
      this.errorMessage = (error as Error).message;
    }
    await this.loadEpisodes();
  }

  async loadEpisodes(): Promise<void> {
    if (this.feed === undefined) {
      return;
    }
    // 只有首屏（列表还是空的时候）才整页显示「加载中」：`loading` 是 build 的结构分支，
    // 每次重载都置 true 会把整个列表拆掉重建（上千集时要建上千个行组件，主线程卡死）
    this.loading = this.episodes.length === 0;
    this.errorMessage = '';
    if (this.previewMode) {
      // 预览：单集来自刚解析的 RSS（未入库），只做内存里的过滤与排序
      this.loadPreviewEpisodes();
      this.loading = false;
      return;
    }
    try {
      const unplayed: boolean = this.filter === 'unplayed';
      let items: FeedItem[] = await EpisodeRepository.listByFeed(this.feed.id, unplayed, this.feed.sortOrder);
      if (this.filter === 'downloaded') {
        items = items.filter((item: FeedItem) => item.media !== undefined && item.media.fileUrl !== '');
      }
      // 每 Feed 过滤器：命中规则的剧集不进入列表（与自动下载判定同一套规则）
      const filter: FeedFilter = new FeedFilter(
        this.feed.includeFilter, this.feed.excludeFilter, this.feed.minimalDurationFilter);
      this.filterActive = filter.hasIncludeFilter() || filter.hasExcludeFilter() || filter.hasMinimalDurationFilter();
      if (this.filterActive) {
        items = items.filter((item: FeedItem) => filter.shouldAutoDownload(item));
      }
      this.episodes = items;
      this.dataSource.setData(items);
      await this.loadFavoriteIds();
    } catch (error) {
      this.episodes = [];
      this.dataSource.setData([]);
      this.errorMessage = (error as Error).message;
    } finally {
      this.loading = false;
    }
  }

  /**
   * 预览模式的列表：内存过滤 + 排序，不查库。
   *
   * 预览单集没有数据库 id（未订阅），所以这里也不做收藏 / 队列标记，
   * 行交互由 `previewGuard()` 统一拦截为「订阅后可收听」。
   */
  private loadPreviewEpisodes(): void {
    let items: FeedItem[] = this.previewItems.slice();
    if (this.filter === 'downloaded') {
      // 未订阅时不可能有下载文件
      items = [];
    } else if (this.filter === 'unplayed') {
      items = items.filter((item: FeedItem) => !item.isPlayed);
    }
    if (this.feed !== undefined) {
      const order: SortOrder = this.feed.sortOrder;
      items.sort((a: FeedItem, b: FeedItem) => {
        const ra: number = a.pubDate;
        const rb: number = b.pubDate;
        return order === SortOrder.DATE_OLD_NEW ? ra - rb : rb - ra;
      });
    }
    this.episodes = items;
    this.dataSource.setData(items);
    this.filterActive = false;
  }

  /**
   * 预览态按需订阅：播放 / 打开详情前自动订阅一次。
   * 订阅后单集才入库（有真实 id），播放进度、收藏、队列等功能才成立。
   */
  private async ensureSubscribed(): Promise<boolean> {
    if (!this.previewMode) {
      return true;
    }
    if (this.feed === undefined || this.togglingSubscribe) {
      return false;
    }
    this.togglingSubscribe = true;
    try {
      const feed: Feed = await SubscriptionService.subscribe(this.feed.downloadUrl);
      this.subscribed = true;
      this.previewMode = false;
      this.previewItems = [];
      this.feed = feed;
      await this.loadEpisodes();
      await this.loadFavoriteIds();
      return true;
    } catch (error) {
      this.showMessage((error as Error).message);
      return false;
    } finally {
      this.togglingSubscribe = false;
    }
  }

  /**
   * 把预览条目对应到入库后的那条单集：优先 RSS guid（itemIdentifier），
   * guid 缺失时退回「标题 + 发布时间」匹配。
   */
  private resolvePersisted(item: FeedItem): FeedItem | undefined {
    if (item.itemIdentifier !== '') {
      const byGuid: FeedItem | undefined = this.episodes.find(
        (entry: FeedItem) => entry.itemIdentifier === item.itemIdentifier);
      if (byGuid !== undefined) {
        return byGuid;
      }
    }
    return this.episodes.find((entry: FeedItem) =>
      entry.title === item.title && entry.pubDate === item.pubDate);
  }

  /**
   * 行点击：预览态**不订阅**，直接把单集快照传给详情页（只读 + 可在线播放）。
   * 订阅与否完全由用户点书签按钮决定。
   */
  private async handleOpenEpisode(item: FeedItem): Promise<void> {
    if (!this.previewMode) {
      openEpisodeDetail(item.id);
      return;
    }
    router.pushUrl({
      url: 'pages/EpisodeDetailPage',
      params: { itemId: item.id, previewJson: this.previewSnapshot(item) }
    });
  }

  /** 时长胶囊点击：预览态直接在线播放，不订阅、不入库、不入队 */
  private async handlePreviewPlay(item: FeedItem): Promise<void> {
    const media: FeedMedia | undefined = item.media;
    if (media === undefined || media.downloadUrl === '') {
      this.showMessage(getContext(this).resourceManager.getStringSync($r('app.string.feed_preview_play_failed')));
      return;
    }
    // 移动流量确认与正式播放保持一致
    if (!this.streamConfirmed && UserPreferences.getStreamConfirmMobile()
      && AutoDownloadService.isMetered()) {
      this.pendingItem = item;
      this.showStreamConfirm = true;
      return;
    }
    const playable: Playable = new Playable(
      media.id, item.id, item.title, item.feedTitle, media.downloadUrl, '',
      media.duration, 0, media.getMediaType(), 1.0, 0, 0, 0,
      item.imageUrl !== '' ? item.imageUrl : item.feedImage);
    try {
      await PlayerManager.load(playable, 0, true);
      router.pushUrl({ url: 'pages/PlayerPage' });
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }

  /** 把预览单集序列化成详情页可用的只读快照 */
  private previewSnapshot(item: FeedItem): string {
    const media: FeedMedia | undefined = item.media;
    const payload: PreviewSnapshot = {
      id: item.id,
      title: item.title,
      pubDate: item.pubDate,
      link: item.link,
      description: item.description,
      feedId: item.feedId,
      feedTitle: item.feedTitle,
      feedImage: item.feedImage,
      itemIdentifier: item.itemIdentifier,
      imageUrl: item.imageUrl,
      transcriptType: item.podcastIndexTranscriptType,
      transcriptUrl: item.podcastIndexTranscriptUrl,
      mediaId: media === undefined ? 0 : media.id,
      audioUrl: media === undefined ? '' : media.downloadUrl,
      duration: media === undefined ? 0 : media.duration,
      mimeType: media === undefined ? '' : media.mimeType
    };
    return JSON.stringify(payload);
  }

  /** 预览态长按：先订阅，之后用户可正常多选 */
  private handlePreviewLongPress(): void {
    this.showMessage(getContext(this).resourceManager.getStringSync($r('app.string.feed_preview_longpress_hint')));
  }

  /** 同步收藏状态到 @State，驱动 ★ 按钮显示 */
  async loadFavoriteIds(): Promise<void> {
    // 一条 SQL 取回全部收藏 id，不再逐条 isFavorite（上千集的播客 = 上千次串行查询）
    try {
      this.favoriteIds = await FavoritesRepository.listIds();
    } catch (error) {
      // 收藏查询失败不阻断列表
      this.favoriteIds = [];
    }
    try {
      await QueueEngine.load();
      this.queueIds = QueueEngine.getItems().map((entry: FeedItem) => entry.id);
    } catch (error) {
      this.queueIds = [];
    }
  }

  async refreshFeed(): Promise<void> {
    if (this.feed === undefined) {
      return;
    }
    this.message = '';
    try {
      const added: number = await RefreshService.refreshFeed(this.feed!.id);
      this.feed = await FeedRepository.getById(this.feed!.id);
      this.showMessage(getContext(this).resourceManager.getStringSync($r('app.string.feed_refresh_done')) + added);
      await this.loadEpisodes();
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }

  async applySort(order: SortOrder): Promise<void> {
    this.showSortSheet = false;
    if (this.feed === undefined) {
      return;
    }
    this.feed.sortOrder = order;
    try {
      await FeedRepository.updatePreferences(this.feed!);
      await this.loadEpisodes();
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }

  openFilterSheet(): void {
    if (this.feed !== undefined) {
      this.filterInclude = this.feed.includeFilter;
      this.filterExclude = this.feed.excludeFilter;
      this.filterMinDuration = this.feed.minimalDurationFilter > 0
        ? this.feed.minimalDurationFilter.toString() : '';
    }
    this.showFilterSheet = true;
  }

  async saveFilter(): Promise<void> {
    this.showFilterSheet = false;
    if (this.feed === undefined) {
      return;
    }
    const minDuration: number = this.filterMinDuration.trim() === ''
      ? -1 : Number(this.filterMinDuration.trim());
    this.feed.includeFilter = this.filterInclude.trim();
    this.feed.excludeFilter = this.filterExclude.trim();
    this.feed.minimalDurationFilter = Number.isFinite(minDuration) ? minDuration : -1;
    try {
      await FeedRepository.updatePreferences(this.feed!);
      this.showMessage(getContext(this).resourceManager.getStringSync($r('app.string.dialog_saved')));
      await this.loadEpisodes();
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }

  openActionSheet(item: FeedItem): void {
    this.actionItem = item;
    this.actionTitle = item.title;
    this.showActionSheet = true;
  }

  async togglePlayed(item: FeedItem): Promise<void> {
    const target: boolean = !item.isPlayed;
    try {
      await EpisodeRepository.markPlayed(item.id, target);
      item.isPlayed = target;
      const data: FeedItemUpdateData = { feedId: item.feedId, itemId: item.id };
      EventHub.publish(EventType.FEED_ITEM_UPDATE, data);
      await this.loadEpisodes();
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }

  async addToQueue(item: FeedItem): Promise<void> {
    try {
      await QueueEngine.add(item);
      this.showMessage(getContext(this).resourceManager.getStringSync($r('app.string.queue_added')));
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }

  /**
   * 移出收件箱（对照上游 RemoveFromInboxSwipeAction）：清除「新」标记并刷新列表。
   * 与列表里的其它改动一样发 FEED_ITEM_UPDATE，让首页 / 收件箱同步。
   */
  private async removeFromInbox(item: FeedItem): Promise<void> {
    try {
      await EpisodeRepository.setNewFlag(item.id, false);
      const data: FeedItemUpdateData = { feedId: item.feedId, itemId: item.id };
      EventHub.publish(EventType.FEED_ITEM_UPDATE, data);
      await this.loadEpisodes();
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }

  async startDownload(item: FeedItem): Promise<void> {
    if (item.media === undefined) {
      return;
    }
    try {
      await DownloadManager.startDownload(item.media, item.title);
      this.reloadRows();
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }

  async deleteDownload(item: FeedItem): Promise<void> {
    if (item.media === undefined) {
      return;
    }
    try {
      await DownloadManager.deleteFile(item.media);
      await this.loadEpisodes();
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }

  async play(item: FeedItem): Promise<void> {
    if (item.media === undefined) {
      return;
    }
    // 移动流量播放二次确认（仅流播、且开关开启、且当前为计费网络）
    if (item.media.fileUrl === '' && !this.streamConfirmed
      && UserPreferences.getStreamConfirmMobile() && AutoDownloadService.isMetered()) {
      this.pendingItem = item;
      this.showStreamConfirm = true;
      return;
    }
    await this.playNow(item);
  }

  async playNow(item: FeedItem): Promise<void> {
    if (item.media === undefined) {
      return;
    }
    const feed: Feed | undefined = this.feed;
    const playable: Playable = new Playable(
      item.media.id,
      item.id,
      item.title,
      feed !== undefined ? feed.getTitle() : '',
      item.media.downloadUrl,
      item.media.fileUrl,
      item.media.duration,
      item.media.position,
      item.media.getMediaType(),
      feed !== undefined && feed.feedPlaybackSpeed > 0 ? feed.feedPlaybackSpeed : 1.0,
      feed !== undefined ? feed.feedSkipIntro : 0,
      feed !== undefined ? feed.feedSkipEnding : 0,
      feed !== undefined ? feed.feedVolumeAdaption : 0,
      item.imageUrl !== '' ? item.imageUrl : (feed !== undefined ? feed.imageUrl : '')
    );
    await QueueEngine.ensureQueued(item);
    await PlayerManager.load(playable, item.media.position, true);
    router.pushUrl({ url: 'pages/PlayerPage' });
  }

  async toggleFavorite(item: FeedItem): Promise<void> {
    const fav: boolean = await FavoritesRepository.isFavorite(item.id);
    if (fav) {
      await FavoritesRepository.remove(item.id);
      this.favoriteIds = this.favoriteIds.filter((id: number) => id !== item.id);
    } else {
      await FavoritesRepository.add(item.id, item.feedId);
      this.favoriteIds = this.favoriteIds.concat([item.id]);
    }
  }

  /**
   * 收藏动作（划出项「加入收藏 / 移出收藏」）：本页只有「切换」实现，
   * 因此先比对目标状态，已经是目标状态就不做无谓的切换。
   */
  private async setFavorite(item: FeedItem, favorite: boolean): Promise<void> {
    if (this.favoriteIds.includes(item.id) === favorite) {
      return;
    }
    await this.toggleFavorite(item);
  }

  /** 分享：复制单集链接到剪贴板（本 SDK 无系统分享面板 API） */
  async share(item: FeedItem): Promise<void> {
    let link: string = item.link;
    if (link === '' && item.media !== undefined) {
      link = item.media.downloadUrl;
    }
    if (link === '' && this.feed !== undefined) {
      link = this.feed.link;
    }
    if (link === '') {
      this.showMessage(getContext(this).resourceManager.getStringSync($r('app.string.share_no_link')));
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, link);
      await pasteboard.getSystemPasteboard().setData(data);
      this.showMessage(getContext(this).resourceManager.getStringSync($r('app.string.share_copied')));
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }

  /** 下载按钮状态：优先看数据库 file_url，再看会话内任务状态 */
  downloadState(item: FeedItem): string {
    if (item.media === undefined) {
      return 'IDLE';
    }
    if (item.media.fileUrl !== '') {
      return 'DONE';
    }
    return DownloadManager.getStatus(item.media.id);
  }

  /** 行内下载进度环的百分比；-1 = 不显示（对照上游 secondaryActionProgress 的百分比） */
  downloadProgress(item: FeedItem): number {
    // 读一次下载版本号：进度存在 DownloadManager 的静态表里，靠这个 @State 让本行随进度事件重算
    const tick: number = this.downloadTick;
    if (item.media === undefined || tick < 0) {
      return -1;
    }
    return DownloadManager.getProgressPercent(item.media.id);
  }

  /** 总大小未知（进度不可确定）时环走等待动画 */
  downloadIndeterminate(item: FeedItem): boolean {
    return item.media !== undefined && DownloadManager.isProgressIndeterminate(item.media.id);
  }

  /**
   * LazyForEach 只在 key 变化时重建行：**只把下载状态编进 key，不编百分比**。
   * 状态变化（未下载 → 下载中 → 已下载）本来就要换行内图标，重建一次可以接受；
   * 百分比进 key 会让每次进度回调都重建整行（含封面 `Image` 重新解码）——
   * 用户报的「下载单集时封面时不时闪一下」就是这么来的。进度改由 `downloadTick` 驱动重算。
   */
  rowKey(item: FeedItem): string {
    if (item.media === undefined) {
      return item.id.toString();
    }
    return item.id.toString() + '-' + this.downloadState(item);
  }

  /** 播放进度百分比（上游把小于 5% 抬到 5%，否则圆角下看不见） */
  progressPercent(item: FeedItem): number {
    if (item.media === undefined || item.media.duration <= 0 || item.media.position <= 0) {
      return 0;
    }
    const percent: number = Math.floor(item.media.position * 100 / item.media.duration);
    return percent > 100 ? 100 : (percent < 5 ? 5 : percent);
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

  /**
   * 相对时间（参考图 1 的「4小时前 / 1天前」）。
   * 超过 30 天回落为具体日期，避免出现「237天前」这种难读的表述。
   */
  /**
   * 相对时间（参考图 1 的「4小时前 / 1天前」）。
   * 返回一个描述符而不是拼好的字符串：ArkUI 的 `Text($r(..., arg))` 能正确处理 `%1$s` 占位，
   * 而 `getStringSync(resource, arg)` 在本工程里不会替换占位符（实测会原样显示 %1$s）。
   */
  relativeTimeLabel(item: FeedItem): RelativeLabel {
    if (item.pubDate <= 0) {
      return { text: '', count: 0 };
    }
    const diff: number = Date.now() - item.pubDate;
    if (diff < 0) {
      return { text: new Date(item.pubDate).toLocaleDateString(), count: 0 };
    }
    const minutes: number = Math.floor(diff / 60000);
    if (minutes < 1) {
      return { text: 'just_now', count: 0 };
    }
    if (minutes < 60) {
      return { text: 'minutes', count: minutes };
    }
    const hours: number = Math.floor(minutes / 60);
    if (hours < 24) {
      return { text: 'hours', count: hours };
    }
    const days: number = Math.floor(hours / 24);
    if (days <= 30) {
      return { text: 'days', count: days };
    }
    return { text: new Date(item.pubDate).toLocaleDateString(), count: 0 };
  }
  /** 单集摘要（去 HTML、压空白、单行展示；没有描述时返回空串，调用方据此不渲染） */
  episodeSummary(item: FeedItem): string {
    if (item.description === '' || item.description === undefined) {
      return '';
    }
    return HtmlCleaner.stripHtml(item.description).replace(/\s+/g, ' ').trim();
  }
  /** 状态行：发布日期 · 文件大小（上游 feeditemlist_item 的 pubDate · size） */
  metaText(item: FeedItem): string {
    const parts: string[] = [];
    if (item.pubDate > 0) {
      parts.push(new Date(item.pubDate).toLocaleDateString());
    }
    if (item.media !== undefined && item.media.size > 0) {
      const mb: number = item.media.size / (1024 * 1024);
      parts.push(mb < 1 ? (item.media.size / 1024).toFixed(0) + ' KB' : mb.toFixed(1) + ' MB');
    }
    return parts.join(' · ');
  }
}
