import router from '@ohos.router';
import { EpisodeRepository, FeedStat } from '../db/repositories/EpisodeRepository';
import { FeedItem } from '../model/FeedItem';
import { FeedMedia } from '../model/FeedMedia';
import { Playable } from '../model/Playable';
import { MediaType, SortOrder } from '../model/Enums';
import { QueueEngine } from '../player/QueueEngine';
import { PlayerManager } from '../player/PlayerManager';
import { FeedRepository } from '../db/repositories/FeedRepository';
import { FavoritesRepository } from '../db/repositories/FavoritesRepository';
import { DownloadManager } from '../download/DownloadManager';
import { RefreshService } from '../services/RefreshService';
import { Feed } from '../model/Feed';
import { UserPreferences } from '../prefs/UserPreferences';
import { EventHub, EventType, FeedItemUpdateData } from '../events/EventHub';
import { DurationUtils } from '../utils/DurationUtils';
import { DesignTokens } from '../common/DesignTokens';
import { openEpisodeDetail } from '../common/EpisodeRoute';
import {
  SwipeActionId,
  SwipeActionSpec,
  SwipeActions,
  SwipeScreen,
  isDestructiveSwipeAction,
  swipeActionSpec
} from '../common/SwipeActions';
import { EpisodeCard } from '../components/EpisodeCard';
import { ContinueCard } from '../components/ContinueCard';
import { PodcastSearchResult } from '../net/Discovery';
import { CuratedFeedService } from '../services/CuratedFeedService';
import { EpisodeRow } from '../components/EpisodeRow';
import { FeedCover } from '../components/FeedCover';
import { SectionHeader } from '../components/SectionHeader';
import { SwipeActionButton } from '../components/SwipeActionButton';
import { FloatingTopBar } from '../components/FloatingTopBar';
import { OverflowButton } from '../components/OverflowButton';
import { AppIconButton } from '../components/AppIconButton';
import { menuIcon } from '../common/MenuIcons';

/** 编辑模式里的区块行（顺序 + 显隐，对照上游 HomeSectionsSettingsDialog 的两个分组） */
interface HomeSectionRow {
  tag: string;
  title: ResourceStr;
  icon: Resource;
  hidden: boolean;
}

/** 随机惊喜的种子（上游 `EpisodesSurpriseSection.seed`）：页面内稳定，只在点「乱序」时更换 */
function newSurpriseSeed(): number {
  return Math.floor(Math.random() * 2147483646) + 1;
}

/**
 * 首页五区块（对齐上游 HomeFragment / home_section.xml / 五个 Section）：
 * 待播清单（队列横滑卡片）/ 看新内容（竖排两行 + 未读角标）/ 随机惊喜（横滑卡片 + 乱序）/
 * 常听经典（横滑订阅封面）/ 管理下载（竖排两行）。
 *
 * 数据源与上游逐条对齐：
 * - 待播清单 = 队列 `DBReader.getPausedQueue(8)`（不是播放历史）；
 * - 随机惊喜 = `getRandomEpisodes(8, seed)`（2 年内、每订阅 1 集、seed 稳定）；
 * - 常听经典 = 最近 3 年的 feedTime、仅已订阅源；
 * - 管理下载 = 用户设置的下载排序；
 * - 欢迎页条件 = 全库单集总数为 0（不是订阅数为 0）。
 */
@Component
export struct HomePage {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  @Prop bottomInset: number = 0;
  @State continueItems: FeedItem[] = [];
  @State newItems: FeedItem[] = [];
  @State newCount: number = 0;
  @State surpriseItems: FeedItem[] = [];
  @State topFeeds: FeedStat[] = [];
  /** 主题化精选板块的检索结果：key 为板块 id，值为在线目录命中的播客 */
  @State curatedRows: Map<string, PodcastSearchResult[]> = new Map<string, PodcastSearchResult[]>();
  /** 主题板块的缓存日期（yyyy-mm-dd 语义，用于「每天刷新一次」） */
  /** 上次点「更多」的时间戳（节流用） */
  private lastCategoryOpenAt: number = 0;
  private static readonly CURATED_SIZE: number = 10;
  /** 首页横滑卡片边长（正方形）与标题两行高度 */
  private static readonly CURATED_CARD_SIZE: number = 116;
  /** 顶栏「更多」浮层距页面顶部的距离（顶栏高度 + 一点间隙） */
  private static readonly MORE_MENU_TOP: number = 60;
  private static readonly CURATED_TITLE_H: number = 36;
  /**
   * 六个推荐板块的 id（顺序即首页默认顺序）。
   * 名称 / 分类规则 / 数据来源统一由 `CuratedCategories` + `CuratedFeedService` 提供，
   * 这里只保留顺序，避免两处各写一份配置。
   */
  private static readonly CURATED_IDS: string[] = [
    'global', 'chinese', 'silicon', 'investor', 'health', 'women', 'language'
  ];

  @State downloadItems: FeedItem[] = [];
  @State queueIds: number[] = [];
  @State favoriteIds: number[] = [];
  @State feedImages: Map<number, string> = new Map<number, string>();
  /** 全库是否已有单集（上游 updateWelcomeScreenVisibility 的条件） */
  @State hasEpisodes: boolean = false;
  @State loading: boolean = true;
  @State refreshing: boolean = false;
  /** 区块顺序 / 隐藏区块（对照上游 PrefHomeSectionOrder 与 PrefHomeSectionsString） */
  @State sectionOrder: string[] = [];
  @State hiddenSections: string[] = [];
  @State message: string = '';
  /** 当前播放项的实时进度（PlaybackPositionEvent 只更新它，不重查数据库） */
  @State playbackPercent: number = 0;
  /** 当前播放项的实时播放位置（上游 notifyPlaybackPositionUpdated 会同时刷新进度条与位置文本） */
  @State playbackPositionMs: number = 0;
  /** 上次已应用的位置（秒）：用于跳过无变化的进度更新，避免整页重建 */
  private lastPositionSecond: number = -1;
  /**
   * 下载进度版本号（每个下载进度事件 +1）：下载状态/进度存在 `DownloadManager` 的静态表里、
   * 不是 @State。旧实现每次进度回调都 `load()`（重查数据库 + 换掉几个 @State 数组），
   * 首页每个区块连同卡片封面都会重建一次 —— 卡片封面因此连续闪；
   * 现在只 +1 这个版本号，卡片就地重算下载进度环（`cardDownloadProgress` 读它）。
   */
  @State downloadTick: number = 0;
  /** 长按操作菜单的目标单集 */
  @State menuItem: FeedItem | undefined = undefined;
  @State menuShown: boolean = false;
  /** 顶栏「更多」浮层（下载 / 播放历史 / 收听统计 / 设置） */
  @State homeMoreShown: boolean = false;
  /** 「看新内容」区块的左右滑动作 id（对照上游 InboxFragment 的滑动动作配置） */
  @State newRightId: string = SwipeActionId.NONE;
  @State newLeftId: string = SwipeActionId.NONE;
  /** 「管理下载」区块的左右滑动作 id（对照上游 CompletedDownloadsFragment 的滑动动作配置） */
  @State dlRightId: string = SwipeActionId.NONE;
  @State dlLeftId: string = SwipeActionId.NONE;
  /**
   * 长按打开菜单的时刻。`EpisodeRow` / `EpisodeCard` 用的是
   * `.onClick()` + `.parallelGesture(LongPressGesture())`（项目的既有写法，换成普通
   * `.gesture()` 会把单击吞掉），两者是并行识别：长按抬手时 onClick 仍会命中。
   * 首页 onClick = 播放（会 push 播放页），所以必须在这个窗口期内把随后的 click 吞掉，
   * 否则「长按弹菜单」会同时跳进播放页。
   */
  private menuOpenedAt: number = 0;
  /** refreshAll 防重入标记（见该方法注释） */
  private refreshingNow: boolean = false;
  /**
   * 「待播清单」区块卡片数。
   * 上游 InboxSection 只取 2 条（纵向两行）；本应用把该区块改成了横滑卡片，
   * 2 条撑不满一屏、左右滑也没有内容可翻，因此取 6 条（约可滑 2~3 屏）。
   */
  private static readonly NEW_EPISODES: number = 6;
  /** 待播清单 / 随机惊喜条数（上游 QueueSection、EpisodesSurpriseSection 的 NUM_EPISODES = 8） */
  private static readonly NUM_EPISODES: number = 8;
  /** 常听经典最多几个订阅（上游 SubscriptionsSection.NUM_FEEDS = 8） */
  private static readonly NUM_FEEDS: number = 8;
  /** 管理下载两行（上游 DownloadsSection.NUM_EPISODES = 2） */
  private static readonly NUM_DOWNLOADS: number = 2;
  /** 默认区块顺序（上游 R.array.home_section_tags） */
  // 默认顺序：待播清单（'new'）置顶，其后是播放列表（'continue'）等；
  // 用户仍可在「编辑区块」里自由拖动排序，保存后会覆盖这个默认值。
  private static readonly DEFAULT_SECTIONS: string[] = ['new', 'continue', 'random', 'top',
    'curated_global', 'curated_chinese', 'curated_silicon', 'curated_investor', 'curated_health',
    'curated_women', 'curated_language',
    'downloads'];
  /** 滑动动作触发距离（与收件箱页保持一致） */
  private static readonly SWIPE_ACTION_DISTANCE: number = 40;
  private surpriseSeed: number = newSurpriseSeed();
  private eventTokens: number[] = [];
  /**
   * 列表控制器。`swipeAction.onAction` 触发后行不会自动回弹，
   * 必须靠 `ListScroller.closeAllSwipeActions()` 收回（见 `closeSwipes`）。
   * 两个区块（看新内容 / 管理下载）在同一个 `List` 里，共用一个控制器即可。
   */
  private listScroller: ListScroller = new ListScroller();
  /** 页面可用宽度（vp），用于按比例算「待播清单」大卡宽度 */
  @State availableWidth: number = 360;
  onNavigate: (target: string) => void = () => {
  };
  /** 主列表的真实滚动增量（正 = 内容上滑）：供外壳 Dock 折叠判定 */
  onScrollDelta: (delta: number) => void = () => {
  };
  /** 上一次滚动偏移：把 onDidScroll 的绝对偏移换算成增量 */
  private lastScrollOffset: number = 0;

  /**
   * 大卡宽度：整屏能放下「完整一张卡 + 下一张的左半边」，整体缩小一档。
   * 卡宽 = (屏宽 - 16×2 - 12) / 2.0 ≈ 屏宽 × 0.42，右侧露出更多下一张的边。
   */
  private get cardWidth(): number {
    const width: number = this.availableWidth > 0 ? this.availableWidth : 360;
    const cardW: number = Math.round((width - 44) / 1.9);
    return cardW;
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        // 顶栏：大标题顶格 + 右侧「更多」（下载 / 播放历史 / 收听统计 / 设置）
        Row() {
          FloatingTopBar({
            title: $r('app.string.home_title')
          }) {
            AppIconButton({
              symbol: $r('sys.symbol.more'),
              symbolActive: $r('sys.symbol.more_fill'),
              active: this.homeMoreShown,
              // 与「待播清单」等区块标题（SectionHeader 的 text_primary）保持同一深浅
              tint: $r('app.color.text_primary'),
              // 激活态只做「图标填充 + 变紫」，不铺圆形底色（去掉那圈范围圆圈）
              bg: Color.Transparent,
              onTap: () => {
                this.homeMoreShown = !this.homeMoreShown;
              }
            })
          }
        }
        .width('100%')
        .padding({ left: DesignTokens.PAGE_MARGIN })
        .margin({ bottom: DesignTokens.SPACE_XS })

        if (this.message !== '') {
          Text(this.message).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_FOOTNOTE)
            .fontColor($r('app.color.primary'))
            .width('100%')
            .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
        }

          Refresh({ refreshing: this.refreshing }) {
            // 内容区是一个纵向 List（上游 homeContainer 里每个 Section 都是独立 RecyclerView）：
            // 竖排的单集行必须是 ListItem，`swipeAction`（ListItem 的属性）才能挂上去。
            List({ space: 0, scroller: this.listScroller }) {
              ForEach(this.visibleSections(), (tag: string) => {
                if (tag === 'continue') {
                  ListItem() {
                    this.continueHeader()
                  }
                  if (this.hasSectionContent('continue')) {
                    ListItem() {
                      if (this.continueItems.length === 0) {
                        this.emptyLabel($r('app.string.home_continue_empty'))
                      } else {
                        this.horizontalCards()
                      }
                    }
                  }
                } else if (tag === 'new') {
                  ListItem() {
                    this.newSectionHeader()
                  }
                  if (this.hasSectionContent('new')) {
                    if (this.newItems.length === 0) {
                      ListItem() {
                        this.emptyLabel($r('app.string.home_new_empty'))
                      }
                    } else {
                      // 与「待播清单」完全一致：横向 List + ContinueCard 大卡
                      ListItem() {
                        this.newCards()
                      }
                    }
                  }
                } else if (tag === 'random') {
                  ListItem() {
                    this.randomHeader()
                  }
                  if (this.hasSectionContent('random')) {
                    ListItem() {
                      if (this.surpriseItems.length === 0) {
                        this.emptyLabel($r('app.string.home_surprise_empty'))
                      } else {
                        this.horizontalEpisodes()
                      }
                    }
                  }
                } else if (tag === 'top') {
                  ListItem() {
                    this.topHeader()
                  }
                  if (this.hasSectionContent('top') && this.topFeeds.length > 0) {
                    ListItem() {
                      this.horizontalFeeds()
                    }
                  }
                } else if (tag.startsWith('curated_')) {
                  // 6 个主题板块：全球精选 / 硅谷热门 / 投资者 / 健康 / 女性视角 / 语言学习
                  ListItem() {
                    this.curatedHeader(tag.substring(8))
                  }
                  if (this.hasSectionContent(tag) && this.curatedOf(tag.substring(8)).length > 0) {
                    ListItem() {
                      this.horizontalCurated(tag.substring(8))
                    }
                  }
                } else if (tag === 'downloads') {
                  ListItem() {
                    this.downloadsHeader()
                  }
                  if (this.hasSectionContent('downloads') && this.downloadItems.length === 0) {
                    ListItem() {
                      this.emptyLabel($r('app.string.home_downloads_empty'))
                    }
                  } else if (this.hasSectionContent('downloads')) {
                    ForEach(this.downloadItems, (item: FeedItem) => {
                      ListItem() {
                        this.episodeRow(item)
                      }
                      .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
                      // 「管理下载」区块的左右滑动作取自「已完成下载」屏幕的配置
                      .swipeAction(this.downloadSwipeOptions(item))
                    }, (item: FeedItem) => 'd-' + item.id.toString())
                  }
                }
              }, (tag: string) => tag)
            }
            .width('100%')
            .layoutWeight(1)
            .contentEndOffset(this.bottomInset + DesignTokens.SPACE_XXL)
            .scrollBar(BarState.Off)
            // 用列表的真实滚动回调上报增量：只有用户真的滚动内容才算，
            // 横向列表 / 进度条 / 弹层都不会触发；也不抢占任何手势。
            // onScrollFrameBegin 每帧给出真实滚动增量（vp），是判断方向的可靠来源：
            // 只上报偏移，不改变滚动行为（原样返回 offsetRemain）
            .onScrollFrameBegin((offset: number, _state: ScrollState) => {
              if (offset !== 0) {
                this.onScrollDelta(offset);
              }
              return { offsetRemain: offset };
            })
            // 预留上下各 2 个区块：滚动时直接复用，避免整段重新构建（含内部横滑列表）
            .cachedCount(2)
          }
          .layoutWeight(1)
          .onRefreshing(() => {
            this.refreshAll();
          })
        }
      .width('100%')
      .height('100%')

      // 顶栏「更多」浮层：与底栏「更多」同一套形态（圆角卡片 + 图标文案行），
      // 只是锚点在右上角、贴顶栏下方。
      //
      // 结构要点：遮罩与卡片是 Stack 的**兄弟节点**，卡片按内容自适应尺寸。
      // 之前把卡片包在一层满屏 Column 里，那个容器会把所有点击吃掉（遮罩收不到事件），
      // 表现就是「弹出后怎么点都关不掉」。现在点遮罩、再点「更多」、左右滑都能收起。
      if (this.homeMoreShown) {
        Stack({ alignContent: Alignment.TopEnd }) {
          // 遮罩保持完全透明：只负责接住「点空白处关闭」的点击。
          // 之前用 #0A000000 会把整页压暗，浅色模式下背景发灰。
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              this.homeMoreShown = false;
            })

          Column() {
            this.homeMoreRow($r('sys.symbol.download_1'), $r('app.string.tab_downloads'), 'pages/DownloadsPage')
            this.homeMoreRow($r('sys.symbol.music_note_list'), $r('app.string.tab_queue'), 'pages/QueuePage')
            this.homeMoreRow($r('sys.symbol.histogram'), $r('app.string.more_statistics'), 'pages/StatsPage')
            this.homeMoreRow($r('sys.symbol.gearshape'), $r('app.string.tab_settings'), 'pages/SettingsPage')
          }
          .padding(DesignTokens.SPACE_S)
          .backgroundColor($r('app.color.surface'))
          .borderRadius(DesignTokens.RADIUS_CARD)
          .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
          .margin({ top: HomePage.MORE_MENU_TOP, right: DesignTokens.PAGE_MARGIN })
        }
        .width('100%')
        .height('100%')
        // 左右横滑也能收起（菜单已展开时优先响应滑动，不与下面的列表滚动冲突）
        .gesture(
          PanGesture({ direction: PanDirection.Horizontal, distance: 24 })
            .onActionEnd(() => {
              this.homeMoreShown = false;
            })
        )
      }

      // 长按操作菜单（对照上游 HomeSection 的 registerForContextMenu + FeedItemMenuHandler）
      Stack({ alignContent: Alignment.Bottom }) {
      // 长按操作菜单（对照上游 HomeSection 的 registerForContextMenu + FeedItemMenuHandler）
      if (this.menuShown) {
        this.sheetBackdrop()
      }
      if (this.menuShown) {
        this.actionSheet()
      }
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: this.bottomInset })
      .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    .onAreaChange((_old: Area, area: Area) => {
      const width: number = Number(area.width);
      if (width > 0 && width !== this.availableWidth) {
        this.availableWidth = width;
      }
    })
  }


  // ---------------------------------------------------------------- 欢迎页

  @Builder
  welcome() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column({ space: DesignTokens.SPACE_L }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.mic'))
            .fontSize(40)
            .fontColor([$r('app.color.primary')])
        }
        .width(64)
        .height(64)
        .borderRadius(DesignTokens.RADIUS_CARD)
        .backgroundColor($r('app.color.primary_container'))
        .alignContent(Alignment.Center)
        .margin({ top: 48 })

        Text($r('app.string.home_welcome_title')).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_TITLE3)
          .fontColor($r('app.color.text_primary'))
          .textAlign(TextAlign.Center)

        Text($r('app.string.home_welcome_text')).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_PARAGRAPH)
          .fontColor($r('app.color.text_primary'))
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .height('100%')
      .padding({ left: 32, right: 32 })
      .alignItems(HorizontalAlign.Center)

      // 引导箭头（上游 80dp ic_curved_arrow，底部导航时在右下角、margin 16dp，指向底部「更多」入口）
      SymbolGlyph($r('sys.symbol.arrow_uturn_down'))
        .fontSize(80)
        .fontColor([$r('app.color.text_tertiary')])
        .margin({ right: DesignTokens.SPACE_L, bottom: DesignTokens.SPACE_L + this.bottomInset })
    }
    .width('100%')
    .layoutWeight(1)
  }

  // ---------------------------------------------------------------- 悬浮顶栏菜单

  // 首页顶栏不再有溢出菜单：
  // 刷新已移除（下拉刷新仍在），「编辑首页区块」已移到「设置 → 用户界面」。

  // ---------------------------------------------------------------- 五个区块（表头 + 内容分别成 ListItem）

  @Builder
  continueHeader() {
    // 右上角动作统一显示「更多」；点击目标保持原样（队列页）
    this.sectionHeader($r('app.string.home_continue'), $r('app.string.home_more'), -1, false,
      () => {
        this.onNavigate('queue');
      }, () => {
      })
  }

  @Builder
  randomHeader() {
    // 右上角动作统一显示「更多」；点击目标保持原样（单集页签）
    this.sectionHeader($r('app.string.home_random'), $r('app.string.home_more'), -1, true, () => {
      this.onNavigate('episodes');
    }, () => {
      this.shuffleSurprise();
    })
  }

  @Builder
  topHeader() {
    // 上游 SubscriptionsSection 不设置 emptyLabel：没有收听数据时该区块只留标题
    // 右上角动作统一显示「更多」；点击目标保持原样（订阅页签）
    this.sectionHeader($r('app.string.home_top'), $r('app.string.home_more'), -1, false,
      () => {
        this.onNavigate('subscriptions');
      }, () => {
      })
  }

  @Builder
  downloadsHeader() {
    this.sectionHeader($r('app.string.home_downloads'), $r('app.string.tab_downloads'), -1, false,
      () => {
        this.onNavigate('downloads');
      }, () => {
      })
  }

  @Builder
  sectionHeader(title: ResourceStr, moreLabel: ResourceStr, countPill: number, shuffle: boolean,
                onMore: () => void, onShuffle: () => void) {
    Row() {
      SectionHeader({
        title: title,
        actionText: moreLabel,
        countPill: countPill,
        shuffle: shuffle,
        onAction: onMore,
        onShuffle: onShuffle
      })
    }
    .width('100%')
    // 左 16vp（标题 marginStart）+ 右 8vp（「更多」按钮的 marginEnd），与上游 home_section.xml 一致
    .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.SPACE_S })
  }

  /**
   * 「看新内容」区块标题（上游 InboxSection 的 `numNewItemsLabel`：未读数胶囊，空则不显示）。
   *
   * 计数必须在这里直接读 `this.newCount`：`@Builder` 的多参数是**按值传递**，参数变化不会刷新
   * —— 经 `sectionHeader(..., this.newCount, ...)` 传入时，胶囊永远停在首帧（加载完成前的 0），
   * 收件箱有内容也显示不出来。本文件其余区块的 `sectionHeader` 参数都是静态资源，不受影响。
   */
  @Builder
  newSectionHeader() {
    Row() {
      SectionHeader({
        title: $r('app.string.home_new'),
        // 右上角动作统一显示「更多」；点击目标保持原样（收件箱）
        actionText: $r('app.string.home_more'),
        // 不显示未读数胶囊（用户要求去掉这一块顶栏的数字）
        countPill: -1,
        onAction: () => {
          this.onNavigate('inbox');
        }
      })
    }
    .width('100%')
    .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.SPACE_S })
  }

  /**
   * 待播清单横滑大卡（参考「满图卡片」样式）：封面铺满 + 渐变遮罩 + 叠字信息区。
   * 卡片宽度按屏宽自适应（约 3/4 屏），高度 1.25 倍宽，露出下一张的一半作为滑动暗示。
   */
  @Builder
  /**
   * 待播清单横滑卡片：样式与浏览方式完全复刻「随机惊喜」（EpisodeCard 小卡 + 横向 List）。
   * 进度条由 EpisodeCard 画在封面内部底边。
   */
  @Builder
  horizontalCards() {
    List({ space: DesignTokens.SPACE_M }) {
      ForEach(this.continueItems, (item: FeedItem) => {
        ListItem() {
          EpisodeCard({
            title: item.title,
            dateText: this.dateText(item.pubDate),
            imageUrl: this.itemImage(item),
            feedItemId: item.id,
            progress: this.progressFor(item),
            playing: this.isPlayingNow(item.id),
            actionIcon: this.secondaryIcon(item),
            downloadProgress: this.cardDownloadProgress(item),
            downloadIndeterminate: this.downloadIndeterminate(item),
            onTap: () => {
              this.onRowTap(item);
            },
            onAction: () => {
              this.secondaryAction(item);
            },
            onLongPress: () => {
              this.openRowMenu(item);
            }
          })
        }
      }, (item: FeedItem) => 'c-' + item.id.toString())
    }
    .listDirection(Axis.Horizontal)
    // 预取相邻卡片，滚动时复用节点而不是反复销毁重建
    .cachedCount(2)
    .scrollBar(BarState.Off)
    .width('100%')
    .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
  }
  /** 「看新内容」横滑大卡：样式与浏览方式完全复刻待播清单（ContinueCard + 横向 List） */
  @Builder
  newCards() {
    List({ space: DesignTokens.SPACE_M }) {
      ForEach(this.newItems, (item: FeedItem) => {
        ListItem() {
          ContinueCard({
            title: item.title,
            dateText: this.dateText(item.pubDate),
            summaryText: ContinueCard.summaryOf(item.description),
            remainingText: this.remainingText(item),
            progress: this.progressFor(item),
            imageUrl: this.itemImage(item),
            feedImageUrl: this.feedImage(item.feedId),
            cardWidth: this.cardWidth,
            playing: this.isPlayingNow(item.id),
            onTap: () => {
              this.onRowTap(item);
            },
            onMore: () => {
              this.openRowMenu(item);
            }
          })
        }
        // 与待播清单一致：ListItem 必须显式给宽度，否则 cardWidth 不生效
        .width(this.cardWidth)
      }, (item: FeedItem) => 'nc-' + item.id.toString())
    }
    .listDirection(Axis.Horizontal)
    // 预取相邻卡片，滚动时复用节点而不是反复销毁重建
    .cachedCount(2)
    .scrollBar(BarState.Off)
    .width('100%')
    .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
  }

  /** 「随机惊喜」横滑小卡（保持原有 EpisodeCard 样式） */
  @Builder
  horizontalEpisodes() {
    List({ space: DesignTokens.SPACE_M }) {
      ForEach(this.surpriseItems, (item: FeedItem) => {
        ListItem() {
          EpisodeCard({
            title: item.title,
            dateText: this.dateText(item.pubDate),
            imageUrl: this.itemImage(item),
            feedItemId: item.id,
            progress: this.progressFor(item),
            playing: this.isPlayingNow(item.id),
            actionIcon: this.secondaryIcon(item),
            downloadProgress: this.cardDownloadProgress(item),
            downloadIndeterminate: this.downloadIndeterminate(item),
            onTap: () => {
              this.onRowTap(item);
            },
            onAction: () => {
              this.secondaryAction(item);
            },
            onLongPress: () => {
              this.openRowMenu(item);
            }
          })
        }
      }, (item: FeedItem) => 'h-' + item.id.toString())
    }
    .listDirection(Axis.Horizontal)
    // 预取相邻卡片，滚动时复用节点而不是反复销毁重建
    .cachedCount(2)
    .scrollBar(BarState.Off)
    .width('100%')
    .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
  }
  /**
   * 横滑订阅封面（上游 horizontal_feed_item）。
   * 封面尺寸与圆角对齐「随机惊喜」的单集卡片（`COVER_HOME_CARD` + `RADIUS_ROW`），
   * 让首页两条横滑轨道的卡片大小一致；标题也沿用卡片的两行 14fp / FOOTNOTE 日期行。
   */
  /** 主题板块标题行 */
  /** 主题板块标题资源（`$r()` 只接受字面量，不能拼变量，所以这里逐个列出来） */
  /**
   * 进入分类页。加 600ms 节流：连续点「更多」只会打开一次，
   * 避免同一分类被 push 多层（返回时要退好几次）。
   */
  /**
   * 新用户（全库还没有任何单集 / 播放记录）时，只给这些板块填内容。
   *
   * 理由：本地订阅类板块此时本来就是空的，而七个在线目录板块无需任何本地数据即可展示，
   * 正好承担「冷启动时让用户先看到内容」。
   */
  private static readonly COLD_START_SECTIONS: string[] = [
    'random', 'curated_global', 'curated_silicon', 'curated_investor',
    'curated_health', 'curated_women', 'curated_language'
  ];

  /** 该板块此刻是否展示内容（板块标题始终展示，只是内容区留空） */
  private hasSectionContent(tag: string): boolean {
    if (this.hasEpisodes) {
      return true;
    }
    return HomePage.COLD_START_SECTIONS.includes(tag);
  }
  openCategory(id: string): void {
    const now: number = Date.now();
    if (now - this.lastCategoryOpenAt < 600) {
      return;
    }
    this.lastCategoryOpenAt = now;
    router.pushUrl({ url: 'pages/CategoryPage', params: { categoryId: id } });
  }
  curatedTitle(id: string): Resource {
    if (id === 'chinese') {
      return $r('app.string.home_curated_chinese');
    }
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

  /**
   * 主题板块标题行：`[更多 ›] [标题]`。
   * 「更多」在最左侧、无背景、中性灰小字，点击进入该分类的浏览页；
   * 用 44vp 热区包一层透明容器，保证可点面积够大但不画出按钮感。
   */
  @Builder
  curatedHeader(id: string) {
    Row() {
      Text(this.curatedTitle(id)).fontFamily(this.appFontFamily)
        .fontSize(21)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .textAlign(TextAlign.Start)

      // 更多 ›：与标题同一行、贴最右，无背景无描边，44vp 热区只撑高度不改样子。
      // 文案与箭头用全局强调紫（primary）：与「订阅」「队列」等右侧入口同一个 token，色调一致。
      Row({ space: 4 }) {
        Text($r('app.string.home_more')).fontFamily(this.appFontFamily)
          .fontSize(13)
          .fontColor($r('app.color.primary'))
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(12)
          .fontColor([$r('app.color.primary')])
      }
      .height(44)
      .padding({ left: 8 })
      .onClick(() => {
        this.openCategory(id);
      })
    }
    .width('100%')
    .height(44)
    .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
  }


  /**
   * 主题板块横滑卡片：样式与浏览方式完全复刻「常听经典」（128vp 封面 + 两行标题）。
   * 卡片数据来自在线目录，点击进入播客详情（已订阅直接打开，未订阅先订阅再打开）。
   */
  @Builder
  horizontalCurated(id: string) {
    // 与「常听经典」(horizontalFeeds) 完全一致：space 0 + 卡片 4vp 外边距、左右 12vp
    List({ space: 0 }) {
      ForEach(this.curatedOf(id), (item: PodcastSearchResult) => {
        ListItem() {
          Column({ space: DesignTokens.SPACE_XS }) {
            FeedCover({
              imageUrl: item.imageUrl,
              coverSize: DesignTokens.COVER_HOME_CARD,
              radius: DesignTokens.RADIUS_ROW,
              fallbackTitle: item.title,
              placeholderColor: $r('app.color.cover_placeholder')
            })
            Text(item.title).fontFamily(this.appFontFamily)
              .width(DesignTokens.COVER_HOME_CARD)
              .height(HomePage.CURATED_TITLE_H)
              .fontSize(DesignTokens.FONT_SUBTITLE)
              .fontColor($r('app.color.text_primary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: DesignTokens.SPACE_XS, right: DesignTokens.SPACE_XS })
          }
          .width(DesignTokens.COVER_HOME_CARD)
          .margin(DesignTokens.SPACE_XS)
          .alignItems(HorizontalAlign.Start)
          .onClick(() => {
            // 与搜索结果一致：带 feedUrl 进详情页，未订阅会先完成订阅
            router.pushUrl({
              url: 'pages/FeedDetailPage',
              params: {
                feedUrl: item.feedUrl,
                previewTitle: item.title,
                previewAuthor: item.author,
                previewImageUrl: item.imageUrl
              }
            });
          })
        }
      }, (item: PodcastSearchResult) => id + '-' + item.feedUrl)
    }
    .listDirection(Axis.Horizontal)
    // 预取相邻卡片，滚动时复用节点而不是反复销毁重建
    .cachedCount(2)
    .scrollBar(BarState.Off)
    .width('100%')
    .padding({ left: DesignTokens.SPACE_M, right: DesignTokens.SPACE_M })
  }
  @Builder
  horizontalFeeds() {
    List({ space: 0 }) {
      ForEach(this.topFeeds, (stat: FeedStat) => {
        ListItem() {
          Column({ space: DesignTokens.SPACE_XS }) {
            FeedCover({
              imageUrl: this.feedImage(stat.feedId),
              coverSize: DesignTokens.COVER_HOME_CARD,
              radius: DesignTokens.RADIUS_ROW,
              fallbackTitle: stat.title,
              placeholderColor: $r('app.color.cover_placeholder')
            })
            Text(stat.title).fontFamily(this.appFontFamily)
              .width(DesignTokens.COVER_HOME_CARD)
              .fontSize(DesignTokens.FONT_SUBTITLE)
              .fontColor($r('app.color.text_primary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: DesignTokens.SPACE_XS, right: DesignTokens.SPACE_XS })
          }
          .width(DesignTokens.COVER_HOME_CARD)
          .margin(DesignTokens.SPACE_XS)
          .alignItems(HorizontalAlign.Start)
          .onClick(() => {
            router.pushUrl({ url: 'pages/FeedDetailPage', params: { feedId: stat.feedId } });
          })
          // 订阅封面长按进订阅设置（与订阅页同一套交互）
          .gesture(LongPressGesture().onAction(() => {
            router.pushUrl({ url: 'pages/FeedSettingsPage', params: { feedId: stat.feedId } });
          }))
        }
      }, (stat: FeedStat) => 't-' + stat.feedId.toString())
    }
    .listDirection(Axis.Horizontal)
    // 预取相邻卡片，滚动时复用节点而不是反复销毁重建
    .cachedCount(2)
    .scrollBar(BarState.Off)
    .width('100%')
    .padding({ left: DesignTokens.SPACE_M, right: DesignTokens.SPACE_M })
  }

  /**
   * 竖排单集行（上游 InboxSection / DownloadsSection 用 feeditemlist_item + EpisodeItemListAdapter）。
   * 左右滑动由外层 `ListItem.swipeAction` 提供（`swipeAction` 是 ListItem 的属性），
   * 长按打开操作菜单（上游 registerForContextMenu）。
   */
  @Builder
  episodeRow(item: FeedItem) {
    EpisodeRow({
      rowItem: item,
      title: item.title,
      imageUrl: this.itemImage(item),
      metaText: this.metaText(item),
      positionText: this.positionText(item),
      durationText: this.durationText(item),
      progress: this.progressFor(item),
      playing: this.isCurrentlyPlaying(item.id),
      isPlayed: item.isPlayed,
      isNew: item.isNew(),
      isFavorite: this.favoriteIds.includes(item.id),
      inQueue: this.queueIds.includes(item.id),
      isVideo: this.isVideo(item),
      actionIcon: this.secondaryIcon(item),
      downloadProgress: this.downloadProgress(item),
      downloadIndeterminate: this.downloadIndeterminate(item),
      onTap: () => {
        this.onRowTap(item);
      },
      onAction: () => {
        this.secondaryAction(item);
      },
      onLongPress: () => {
        this.openRowMenu(item);
      }
    })
  }

  /**
   * 划出项配置：「看新内容」区块（对照上游 InboxSection，屏幕 = 收件箱）。
   * 该屏幕关闭滑动动作、或某一侧配置为「无」时，对应侧不挂划出项。
   */
  private newSwipeOptions(item: FeedItem): SwipeActionOptions {
    const options: SwipeActionOptions = {};
    if (!SwipeActions.isEnabled(SwipeScreen.INBOX)) {
      return options;
    }
    if (this.newRightId !== SwipeActionId.NONE) {
      const rightSpec: SwipeActionSpec = swipeActionSpec(this.newRightId);
      const rightItem: SwipeActionItem = {
        builder: () => {
          this.swipeButton(rightSpec, SwipeScreen.INBOX, item);
        },
        actionAreaDistance: HomePage.SWIPE_ACTION_DISTANCE,
        onAction: () => {
          this.runSwipeAction(SwipeScreen.INBOX, this.newRightId, item);
        }
      };
      options.start = rightItem;
    }
    if (this.newLeftId !== SwipeActionId.NONE) {
      const leftSpec: SwipeActionSpec = swipeActionSpec(this.newLeftId);
      const leftItem: SwipeActionItem = {
        builder: () => {
          this.swipeButton(leftSpec, SwipeScreen.INBOX, item);
        },
        actionAreaDistance: HomePage.SWIPE_ACTION_DISTANCE,
        onAction: () => {
          this.runSwipeAction(SwipeScreen.INBOX, this.newLeftId, item);
        }
      };
      options.end = leftItem;
    }
    return options;
  }

  /**
   * 划出项配置：「管理下载」区块（对照上游 DownloadsSection，屏幕 = 已完成下载）。
   * 该屏幕关闭滑动动作、或某一侧配置为「无」时，对应侧不挂划出项。
   */
  private downloadSwipeOptions(item: FeedItem): SwipeActionOptions {
    const options: SwipeActionOptions = {};
    if (!SwipeActions.isEnabled(SwipeScreen.DOWNLOADS)) {
      return options;
    }
    if (this.dlRightId !== SwipeActionId.NONE) {
      const rightSpec: SwipeActionSpec = swipeActionSpec(this.dlRightId);
      const rightItem: SwipeActionItem = {
        builder: () => {
          this.swipeButton(rightSpec, SwipeScreen.DOWNLOADS, item);
        },
        actionAreaDistance: HomePage.SWIPE_ACTION_DISTANCE,
        onAction: () => {
          this.runSwipeAction(SwipeScreen.DOWNLOADS, this.dlRightId, item);
        }
      };
      options.start = rightItem;
    }
    if (this.dlLeftId !== SwipeActionId.NONE) {
      const leftSpec: SwipeActionSpec = swipeActionSpec(this.dlLeftId);
      const leftItem: SwipeActionItem = {
        builder: () => {
          this.swipeButton(leftSpec, SwipeScreen.DOWNLOADS, item);
        },
        actionAreaDistance: HomePage.SWIPE_ACTION_DISTANCE,
        onAction: () => {
          this.runSwipeAction(SwipeScreen.DOWNLOADS, this.dlLeftId, item);
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
  swipeButton(spec: SwipeActionSpec, screen: string, item: FeedItem) {
    SwipeActionButton({
      spec: spec,
      destructive: isDestructiveSwipeAction(spec.id),
      onTap: () => {
        this.runSwipeAction(screen, spec.id, item);
      }
    })
  }

  /**
   * 收起已划出的行。`swipeAction.onAction` 触发后框架不会自动复位
   * （上游 ItemTouchHelper 会自动复位，本移植版必须显式调用
   * `ListScroller.closeAllSwipeActions()`，见官方 FAQ「如何将 ListItem 的
   * swipeAction 滑动效果恢复至未滑动」）；否则「加入队列 / 标记已播 / 收藏」
   * 这类不删行的动作会把行一直停在滑出状态。
   */
  private closeSwipes(): void {
    try {
      this.listScroller.closeAllSwipeActions();
    } catch (error) {
      // 列表未绑定时（欢迎页 / 编辑模式）忽略：此时不可能有展开的划出项
    }
  }

  /** 划出项动作分发：只调用本页已有方法，不在这里重复实现动作逻辑 */
  private runSwipeAction(screen: string, id: string, item: FeedItem): void {
    if (id === SwipeActionId.NONE) {
      return;
    }
    // 先收回划出项再执行动作：动作多为异步落库，等它回来再收会有明显延迟
    this.closeSwipes();
    if (id === SwipeActionId.ADD_TO_QUEUE) {
      this.addToQueue(item);
      return;
    }
    if (id === SwipeActionId.MARK_PLAYED) {
      this.markPlayed(item);
      return;
    }
    if (id === SwipeActionId.REMOVE_FROM_INBOX) {
      this.removeFromInbox(item);
      return;
    }
    if (id === SwipeActionId.START_DOWNLOAD) {
      this.downloadAction(item);
      return;
    }
    if (id === SwipeActionId.DELETE) {
      // 「删除已下载文件」只属于「管理下载」区块
      if (screen === SwipeScreen.DOWNLOADS) {
        this.deleteDownload(item);
      }
      return;
    }
    if (id === SwipeActionId.MARK_FAV && !this.favoriteIds.includes(item.id)) {
      this.toggleFavorite(item);
      return;
    }
    if (id === SwipeActionId.REMOVE_FROM_FAVORITES && this.favoriteIds.includes(item.id)) {
      this.toggleFavorite(item);
    }
    // 其余动作（SHARE / MOVE_* / NONE）本页没有对应实现，按「无动作」处理
  }

  /** 解析两个区块的 [右滑, 左滑] 动作 id（aboutToAppear 与 SWIPE_ACTIONS_CHANGED 时调用） */
  private loadSwipeActions(): void {
    const newIds: string[] = SwipeActions.resolve(SwipeScreen.INBOX);
    this.newRightId = newIds[0];
    this.newLeftId = newIds[1];
    const downloadIds: string[] = SwipeActions.resolve(SwipeScreen.DOWNLOADS);
    this.dlRightId = downloadIds[0];
    this.dlLeftId = downloadIds[1];
  }

  @Builder
  emptyLabel(text: ResourceStr) {
    Text(text).fontFamily(this.appFontFamily)
      .width('100%')
      .fontSize(DesignTokens.FONT_FOOTNOTE)
      .fontColor($r('app.color.text_tertiary'))
      .textAlign(TextAlign.Center)
      .padding({ left: 32, right: 32, top: DesignTokens.SPACE_S, bottom: DesignTokens.SPACE_S })
  }

  // ---------------------------------------------------------------- 编辑模式

  /** 编辑模式：区块顺序（上/下移）+ 显示开关（上游 HomeSectionsSettingsDialog 的「显示 / 隐藏」两组） */
  @Builder
  // ---------------------------------------------------------------- 长按菜单

  /** 菜单遮罩：点击关闭（不拦截列表滚动，仅在菜单打开时存在） */
  /** 「更多」浮层里的一行：与底栏「更多」的 moreRow 完全同款 */
  /** 与 homeMoreRow 相同，但图标走 SVG 图片（统计图标换成了自定义图形） */
  @Builder
  homeMoreRowImage(icon: Resource, label: Resource, url: string) {
    Row({ space: DesignTokens.SPACE_M }) {
      Image(icon)
        .width(DesignTokens.ICON_M)
        .height(DesignTokens.ICON_M)
        .objectFit(ImageFit.Contain)
      Text(label).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_SUBTITLE)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
    }
    .width(196)
    .height(48)
    .padding({ left: DesignTokens.SPACE_M, right: DesignTokens.SPACE_M })
    .borderRadius(DesignTokens.RADIUS_ROW)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.homeMoreShown = false;
      router.pushUrl({ url: url });
    })
  }

  @Builder
  homeMoreRow(icon: Resource, label: Resource, url: string) {
    Row({ space: DesignTokens.SPACE_M }) {
      SymbolGlyph(icon)
        .fontSize(DesignTokens.ICON_M)
        .fontColor([$r('app.color.text_primary')])
      Text(label).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_SUBTITLE)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
    }
    .width(196)
    .height(48)
    .padding({ left: DesignTokens.SPACE_M, right: DesignTokens.SPACE_M })
    .borderRadius(DesignTokens.RADIUS_ROW)
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.homeMoreShown = false;
      router.pushUrl({ url: url });
    })
  }
  @Builder
  sheetBackdrop() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('#66000000')
      .onClick(() => {
        this.menuShown = false;
      })
  }

  /** 单集操作菜单（对照上游 FeedItemMenuHandler 的常用动作） */
  @Builder
  actionSheet() {
    Column({ space: 2 }) {
      Text(this.menuTitle()).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_FOOTNOTE)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding(DesignTokens.SPACE_L)

      this.menuRow($r('sys.symbol.play_fill'), $r('app.string.episode_play'), () => {
        this.playMenuItem();
      })
      this.menuRow($r('sys.symbol.checkmark_circle'),
        this.menuItemPlayed() ? $r('app.string.episode_mark_unplayed') : $r('app.string.episode_mark_played'),
        () => {
          this.togglePlayedMenuItem();
        })
      this.menuRow($r('sys.symbol.music_note_list'),
        this.menuItemQueued() ? $r('app.string.queue_remove') : $r('app.string.episode_add_queue'),
        () => {
          this.toggleQueueMenuItem();
        })
      this.menuRow(this.menuItemFavorite() ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'),
        $r('app.string.favorites_button'),
        () => {
          this.toggleFavoriteMenuItem();
        })
      this.menuRow($r('sys.symbol.arrow_down_circle'), this.menuDownloadLabel(), () => {
        this.downloadMenuItem();
      })

      Button($r('app.string.dialog_cancel'))
        .width('100%')
        .height(DesignTokens.HEIGHT_BUTTON)
        .backgroundColor($r('app.color.surface_secondary'))
        .fontColor($r('app.color.text_primary'))
        .fontSize(DesignTokens.FONT_PARAGRAPH)
        .margin({ top: DesignTokens.SPACE_M, bottom: DesignTokens.SPACE_M })
        .onClick(() => {
          this.menuShown = false;
          this.menuItem = undefined;
        })
    }
    .width('100%')
    .backgroundColor($r('app.color.surface'))
    .borderRadius({ topLeft: DesignTokens.RADIUS_SHEET, topRight: DesignTokens.RADIUS_SHEET })
    .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
  }

  @Builder
  menuRow(icon: Resource, label: ResourceStr, onTap: () => void) {
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
      this.menuShown = false;
      onTap();
    })
  }

  // ---------------------------------------------------------------- 生命周期与数据

  aboutToAppear(): void {
    this.sectionOrder = UserPreferences.getHomeSectionOrder();
    this.hiddenSections = UserPreferences.getHiddenHomeSections();
    this.loadSwipeActions();
    // 事件订阅（上游各 Section 分别监听；这里统一重载首屏，播放进度走轻量更新）
    this.eventTokens.push(EventHub.subscribe(EventType.FEED_ITEM_UPDATE, () => {
      this.load();
    }));
    this.eventTokens.push(EventHub.subscribe(EventType.FEED_LIST_UPDATE, () => {
      this.load();
    }));
    this.eventTokens.push(EventHub.subscribe(EventType.QUEUE, () => {
      this.load();
    }));
    this.eventTokens.push(EventHub.subscribe(EventType.PLAYER_STATUS, () => {
      this.load();
    }));
    this.eventTokens.push(EventHub.subscribe(EventType.EPISODE_DOWNLOAD, (data: object) => {
      // 进度回调很密（实测约每秒一次）：只 +1 版本号让卡片就地重算进度环，
      // 不 load() —— load() 会重查数据库并换掉区块数组，卡片封面每次都重建、连续闪。
      // 开始/暂停/完成/失败这些状态变化仍然走 load()，卡片图标与「管理下载」区块要跟着变。
      const state: string = (data as Record<string, string>)['state'];
      if (state === 'PROGRESS') {
        this.downloadTick = this.downloadTick + 1;
        return;
      }
      this.load();
    }));
    this.eventTokens.push(EventHub.subscribe(EventType.DOWNLOAD_LOG, () => {
      this.load();
    }));
    this.eventTokens.push(EventHub.subscribe(EventType.PLAYBACK_POSITION, (data: object) => {
      this.onPlaybackPosition(data);
    }));
    // 设置页保存「滑动动作」后重新解析两个区块的左右滑动作
    // 编辑页改了区块顺序/显隐：首页是被覆盖的那个页面，不会重建，
    // 必须在这里重读配置，否则要清后台重进才生效。
    this.eventTokens.push(EventHub.subscribe(EventType.HOME_SECTIONS_CHANGED, () => {
      this.sectionOrder = UserPreferences.getHomeSectionOrder();
      this.hiddenSections = UserPreferences.getHiddenHomeSections();
    }));
    this.eventTokens.push(EventHub.subscribe(EventType.SWIPE_ACTIONS_CHANGED, () => {
      this.loadSwipeActions();
    }));
    this.load();
    this.loadCurated();
  }

  aboutToDisappear(): void {
    for (const token of this.eventTokens) {
      EventHub.unsubscribeToken(token);
    }
    this.eventTokens = [];
  }

  /**
   * 加载 6 个推荐板块（全球热门 / 科技前沿 / 商业与投资 / 身心健康 / 社会与文化 / 语言学习）。
   *
   * 数据全部来自 `CuratedFeedService`（Apple 榜单 + iTunes 分类检索）：
   * - 缓存新鲜（12h 内）时直接复用，不发请求；
   * - 过期才逐个板块拉取，串行执行，避免一次性打满网络与接口额度；
   * - 失败时服务内部会回退到上一次有效缓存，页面不会出现伪造内容。
   */
  /**
   * 中文内容判定：标题或作者中至少出现一个 CJK 字符即视为中文节目。
   * 用于「中文专区」过滤 —— Apple 大中华区榜单里会混入纯英文节目。
   */
  private static onlyChinese(items: PodcastSearchResult[]): PodcastSearchResult[] {
    const kept: PodcastSearchResult[] = [];
    for (const item of items) {
      if (HomePage.hasCjk(item.title) || HomePage.hasCjk(item.author)) {
        kept.push(item);
      }
    }
    return kept;
  }

  private static hasCjk(text: string): boolean {
    if (text === undefined || text === '') {
      return false;
    }
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code >= 0x4E00 && code <= 0x9FFF) {
        return true;
      }
    }
    return false;
  }

  async loadCurated(): Promise<void> {
    const rows: Map<string, PodcastSearchResult[]> = new Map<string, PodcastSearchResult[]>();
    for (const id of HomePage.CURATED_IDS) {
      // 先用内存/本地缓存把已有内容画出来（可能是上次的），再按需刷新
      const cached: PodcastSearchResult[] = CuratedFeedService.peek(id);
      if (cached.length > 0) {
        rows.set(id, cached.slice(0, HomePage.CURATED_SIZE));
      }
    }
    if (rows.size > 0) {
      this.curatedRows = rows;
    }
    // 并发发起（最多 6 个），而不是一个个 await：
    // 「全球热门」要打 4 个市场的榜单接口，串行会把后面五个板块一起拖住。
    const tasks: Promise<void>[] = [];
    for (const id of HomePage.CURATED_IDS) {
      if (CuratedFeedService.isFresh(id) && CuratedFeedService.peek(id).length > 0) {
        continue;
      }
      tasks.push(this.loadOneCurated(id));
    }
    for (const task of tasks) {
      await task;
    }
  }

  /** 加载单个推荐板块并把结果并回列表（失败保留已有缓存） */
  private async loadOneCurated(id: string): Promise<void> {
    try {
      const fetched: PodcastSearchResult[] = await CuratedFeedService.load(id, HomePage.CURATED_SIZE);
      // 「中文专区」只保留中文节目：Apple 大中华区榜单里也会混入英文/其它语言节目
      const results: PodcastSearchResult[] = id === 'chinese'
        ? HomePage.onlyChinese(fetched) : fetched;
      if (results.length > 0) {
        const next: Map<string, PodcastSearchResult[]> = new Map<string, PodcastSearchResult[]>(this.curatedRows);
        next.set(id, results.slice(0, HomePage.CURATED_SIZE));
        this.curatedRows = next;
      }
    } catch (error) {
      // 单个板块失败不影响其它板块
    }
  }

  /** 某个主题板块的条目 */
  curatedOf(id: string): PodcastSearchResult[] {
    const rows: PodcastSearchResult[] | undefined = this.curatedRows.get(id);
    return rows === undefined ? [] : rows;
  }
  async load(): Promise<void> {
    this.loading = true;
    try {
      // 上游 QueueSection.loadItems()：DBReader.getPausedQueue(8)
      this.continueItems = await EpisodeRepository.listPausedQueue(HomePage.NUM_EPISODES);

      // 上游 InboxSection.loadItems()：`DBReader.getEpisodes(0, 2, FeedItemFilter(NEW), ...)`
      // + `getTotalEpisodeCount(FeedItemFilter(NEW))` —— 「看新内容」就是收件箱（read = -1）
      // 里的前两条，计数也是收件箱总数，不是全库未播放（read != 1）。
      this.newItems = await EpisodeRepository.listInboxPage(HomePage.NEW_EPISODES,
        UserPreferences.getInboxSortedOrder());
      this.newCount = await EpisodeRepository.countNew();

      // 上游 EpisodesSurpriseSection.loadItems()：DBReader.getRandomEpisodes(8, seed)
      this.surpriseItems = await EpisodeRepository.listRandomEpisodes(HomePage.NUM_EPISODES, this.surpriseSeed);

      // 上游 SubscriptionsSection.loadItems()：最近 3 年的 feedTime，按收时长降序取 8 个已订阅源
      const threeYearsAgo: number = Date.now() - 3 * 365 * 24 * 60 * 60 * 1000;
      const stats: FeedStat[] = await EpisodeRepository.listStatsByFeed(
        UserPreferences.getStatisticsIncludeMarked(), threeYearsAgo, Number.MAX_SAFE_INTEGER);
      this.topFeeds = stats.slice(0, HomePage.NUM_FEEDS);

      // 上游 DownloadsSection.loadItems()：按用户设置的下载排序取前 2 条
      this.downloadItems = await EpisodeRepository.listDownloadedItems(
        HomePage.NUM_DOWNLOADS, UserPreferences.getDownloadsSortedOrder() as SortOrder);

      await QueueEngine.load();
      this.queueIds = QueueEngine.getItems().map((item: FeedItem) => item.id);

      // 上游 updateWelcomeScreenVisibility()：全库单集总数为 0 才显示欢迎页
      this.hasEpisodes = (await EpisodeRepository.countAllEpisodes()) > 0;

      const feeds: Feed[] = await FeedRepository.listSubscribed();
      const images: Map<number, string> = new Map<number, string>();
      for (const feed of feeds) {
        images.set(feed.id, feed.imageUrl);
      }
      this.feedImages = images;

      const favorites: FeedItem[] = await FavoritesRepository.list();
      this.favoriteIds = favorites.map((item: FeedItem) => item.id);
    } catch (error) {
      this.message = (error as Error).message;
    } finally {
      this.loading = false;
      this.refreshing = false;
    }
  }

  async shuffleSurprise(): Promise<void> {
    this.surpriseSeed = newSurpriseSeed();
    this.surpriseItems = await EpisodeRepository.listRandomEpisodes(HomePage.NUM_EPISODES, this.surpriseSeed);
  }

  async refreshAll(): Promise<void> {
    // 防重入：`Refresh` 组件在 `refreshing` 被置真时会再回调一次 `onRefreshing`，
    // 而标题栏的刷新动作也会置真 —— 不拦的话一次点击会并发跑两遍 refreshAll，
    // 同一个源被插入两次（第 40 轮验收实测到重复单集）。
    if (this.refreshingNow) {
      return;
    }
    this.refreshingNow = true;
    this.refreshing = true;
    try {
      await RefreshService.refreshAll();
    } catch (error) {
      this.message = (error as Error).message;
    } finally {
      this.refreshingNow = false;
      await this.load();
    }
  }

  /** 播放进度事件：只更新当前播放项的进度条（上游 notifyPlaybackPositionUpdated），不重查数据库 */
  onPlaybackPosition(data: object): void {
    const payload: Record<string, number> = data as Record<string, number>;
    const time: number = payload['time'];
    const duration: number = payload['duration'];
    if (duration <= 0) {
      return;
    }
    const percent: number = Math.floor(time * 100 / duration);
    const clamped: number = percent > 100 ? 100 : (percent < 5 ? 5 : percent);
    const second: number = Math.floor(time / 1000);
    // 显示的只有「百分比」和「秒级时间」。两者都没变就不写 @State，
    // 否则会白白触发整页重建（播放时正是滚动最容易卡的场景）。
    if (this.playbackPercent === clamped && this.lastPositionSecond === second) {
      return;
    }
    this.lastPositionSecond = second;
    this.playbackPercent = clamped;
    this.playbackPositionMs = time;
  }

  // ---------------------------------------------------------------- 菜单目标动作

  menuTitle(): string {
    return this.menuItem === undefined ? '' : this.menuItem!.title;
  }

  menuItemPlayed(): boolean {
    return this.menuItem !== undefined && this.menuItem!.isPlayed;
  }

  menuItemQueued(): boolean {
    return this.menuItem !== undefined && this.queueIds.includes(this.menuItem!.id);
  }

  menuItemFavorite(): boolean {
    return this.menuItem !== undefined && this.favoriteIds.includes(this.menuItem!.id);
  }

  menuDownloadLabel(): ResourceStr {
    if (this.menuItem === undefined) {
      return $r('app.string.episode_download');
    }
    const state: string = this.downloadState(this.menuItem!);
    if (state === 'DONE') {
      return $r('app.string.episode_delete_download');
    }
    if (state === 'RUNNING' || state === 'PAUSED') {
      return $r('app.string.episode_download_cancel');
    }
    return $r('app.string.episode_download');
  }

  playMenuItem(): void {
    if (this.menuItem !== undefined) {
      this.playItem(this.menuItem!);
    }
  }

  togglePlayedMenuItem(): void {
    if (this.menuItem !== undefined) {
      this.togglePlayed(this.menuItem!);
    }
  }

  toggleQueueMenuItem(): void {
    if (this.menuItem !== undefined) {
      this.addToQueue(this.menuItem!);
    }
  }

  toggleFavoriteMenuItem(): void {
    if (this.menuItem !== undefined) {
      this.toggleFavorite(this.menuItem!);
    }
  }

  downloadMenuItem(): void {
    if (this.menuItem !== undefined) {
      this.downloadAction(this.menuItem!);
    }
  }

  openRowMenu(item: FeedItem): void {
    this.menuItem = item;
    this.menuShown = true;
    this.menuOpenedAt = Date.now();
  }

  /**
   * 行 / 横滑卡片的单击 = 打开单集详情页（与收件箱一致）；
   * 长按刚打开菜单时不响应（`parallelGesture` 下同一次长按手势的 onClick 也会命中，见 `menuOpenedAt`）。
   * 播放仍走各行右侧的副操作钮（`secondaryAction`）。
   */
  onRowTap(item: FeedItem): void {
    if (this.menuShown && Date.now() - this.menuOpenedAt < 1000) {
      return;
    }
    openEpisodeDetail(item.id);
  }

  // ---------------------------------------------------------------- 动作

  /** 标记为已播放（左滑动作：幂等，不因当前状态反转） */
  async markPlayed(item: FeedItem): Promise<void> {
    try {
      await EpisodeRepository.markPlayed(item.id, true);
      const data: FeedItemUpdateData = { feedId: item.feedId, itemId: item.id };
      EventHub.publish(EventType.FEED_ITEM_UPDATE, data);
      await this.load();
    } catch (error) {
      this.message = (error as Error).message;
    }
  }

  async togglePlayed(item: FeedItem): Promise<void> {
    try {
      await EpisodeRepository.markPlayed(item.id, !item.isPlayed);
      const data: FeedItemUpdateData = { feedId: item.feedId, itemId: item.id };
      EventHub.publish(EventType.FEED_ITEM_UPDATE, data);
      await this.load();
    } catch (error) {
      this.message = (error as Error).message;
    }
  }

  /**
   * 加入 / 移出队列（上游 add to queue / remove from queue）。
   * 入队时清除「新」标记（read = -1 → 0），与收件箱页 `addToQueue` 和上游
   * `DBWriter.addQueueItem` 一致：从「看新内容」入队的单集会随之移出该区块。
   */
  async addToQueue(item: FeedItem): Promise<void> {
    try {
      if (this.queueIds.includes(item.id)) {
        await QueueEngine.remove(item.id);
      } else {
        await QueueEngine.add(item);
        if (item.isNew()) {
          await EpisodeRepository.setNewFlag(item.id, false);
        }
      }
      const data: FeedItemUpdateData = { feedId: item.feedId, itemId: item.id };
      EventHub.publish(EventType.FEED_ITEM_UPDATE, data);
      await this.load();
    } catch (error) {
      this.message = (error as Error).message;
    }
  }

  /** 加入 / 取消收藏 */
  async toggleFavorite(item: FeedItem): Promise<void> {
    try {
      if (this.favoriteIds.includes(item.id)) {
        await FavoritesRepository.remove(item.id);
      } else {
        await FavoritesRepository.add(item.id, item.feedId);
      }
      await this.load();
    } catch (error) {
      this.message = (error as Error).message;
    }
  }

  /**
   * 移出收件箱（对照上游 RemoveFromInboxSwipeAction）：清除「新」标记。
   * 与其它改动一样发 FEED_ITEM_UPDATE，让收件箱页同步刷新。
   */
  async removeFromInbox(item: FeedItem): Promise<void> {
    try {
      await EpisodeRepository.setNewFlag(item.id, false);
      const data: FeedItemUpdateData = { feedId: item.feedId, itemId: item.id };
      EventHub.publish(EventType.FEED_ITEM_UPDATE, data);
      await this.load();
    } catch (error) {
      this.message = (error as Error).message;
    }
  }

  /** 删除已下载文件（上游 delete file） */
  async deleteDownload(item: FeedItem): Promise<void> {
    try {
      if (item.media !== undefined) {
        await DownloadManager.deleteFile(item.media);
      }
      await this.load();
    } catch (error) {
      this.message = (error as Error).message;
    }
  }

  /**
   * 菜单里的下载动作（对照上游 ItemActionButton 的三种下载态）：
   * 未下载 → 开始下载；下载中/已暂停 → 取消下载（删掉半成品）；已下载 → 删除文件。
   */
  async downloadAction(item: FeedItem): Promise<void> {
    const media: FeedMedia | undefined = item.media;
    if (media === undefined || media.downloadUrl === '') {
      return;
    }
    try {
      const state: string = this.downloadState(item);
      if (state === 'DONE') {
        await DownloadManager.deleteFile(media);
      } else if (state === 'RUNNING' || state === 'PAUSED') {
        await DownloadManager.remove(media.id);
      } else {
        await DownloadManager.startDownload(media, item.title);
      }
      await this.load();
    } catch (error) {
      this.message = (error as Error).message;
    }
  }

  /**
   * 横滑卡片 / 列表行的副操作钮动作，逐条对照上游 `ItemActionButton.forItem`：
   * 无媒体 → 标记已播；正在播放 → 暂停；已下载 → 播放；
   * 下载中 → 取消下载；开了「流播优先」→ 流播；其余 → 下载。
   */
  async secondaryAction(item: FeedItem): Promise<void> {
    const media: FeedMedia | undefined = item.media;
    if (media === undefined) {
      await this.togglePlayed(item);
      return;
    }
    if (this.isPlaying(item.id)) {
      PlayerManager.pause();
      return;
    }
    if (media.fileUrl !== '') {
      await this.playItem(item);
      return;
    }
    const state: string = this.downloadState(item);
    if (state === 'RUNNING' || state === 'PAUSED') {
      await this.downloadAction(item);
      return;
    }
    if (UserPreferences.getStreamOverDownload()) {
      await this.playItem(item);
      return;
    }
    await this.downloadAction(item);
  }

  /** 副操作钮图标（与 `secondaryAction` 一一对应） */
  secondaryIcon(item: FeedItem): Resource {
    const media: FeedMedia | undefined = item.media;
    if (media === undefined) {
      return $r('sys.symbol.checkmark_circle');
    }
    if (this.isPlaying(item.id)) {
      return $r('sys.symbol.pause_fill');
    }
    if (media.fileUrl !== '') {
      return $r('sys.symbol.play_fill');
    }
    const state: string = this.downloadState(item);
    if (state === 'RUNNING' || state === 'PAUSED') {
      return $r('sys.symbol.xmark_circle');
    }
    if (UserPreferences.getStreamOverDownload()) {
      return $r('sys.symbol.play_fill');
    }
    return $r('sys.symbol.arrow_down_circle');
  }

  async playItem(item: FeedItem): Promise<void> {
    if (item.media === undefined) {
      return;
    }
    const playable: Playable | undefined = await QueueEngine.toPlayable(item);
    if (playable === undefined) {
      return;
    }
    await QueueEngine.ensureQueued(item);
    await PlayerManager.load(playable, item.media.position, true);
    router.pushUrl({ url: 'pages/PlayerPage' });
  }

  // ---------------------------------------------------------------- 状态查询

  /** 下载按钮状态：优先看数据库 file_url，再看会话内任务状态 */
  private downloadState(item: FeedItem): string {
    if (item.media === undefined) {
      return 'IDLE';
    }
    if (item.media.fileUrl !== '') {
      return 'DONE';
    }
    return DownloadManager.getStatus(item.media.id);
  }

  /** 列表行的下载进度环（-1 = 不画） */
  private downloadProgress(item: FeedItem): number {
    // 读一次下载版本号：见 cardDownloadProgress
    const tick: number = this.downloadTick;
    if (item.media === undefined || tick < 0) {
      return -1;
    }
    const state: string = this.downloadState(item);
    if (state !== 'RUNNING' && state !== 'PAUSED') {
      return -1;
    }
    return DownloadManager.getProgressPercent(item.media.id);
  }

  /**
   * 横滑卡片的下载进度环（上游 HorizontalItemViewHolder.bind）：
   * 下载中画进度，已下载画满（`setPercentage(1)`），未下载清零（只留圆钮底色）。
   */
  private cardDownloadProgress(item: FeedItem): number {
    // 读一次下载版本号：进度存在 DownloadManager 的静态表里，靠这个 @State 让卡片随进度事件重算
    const tick: number = this.downloadTick;
    if (item.media === undefined || tick < 0) {
      return -1;
    }
    const state: string = this.downloadState(item);
    if (state === 'DONE') {
      return 100;
    }
    if (state === 'RUNNING' || state === 'PAUSED') {
      const percent: number = DownloadManager.getProgressPercent(item.media.id);
      return percent < 0 ? 1 : percent;
    }
    return -1;
  }

  private downloadIndeterminate(item: FeedItem): boolean {
    if (item.media === undefined) {
      return false;
    }
    return DownloadManager.isProgressIndeterminate(item.media.id);
  }

  /** 当前播放中的项（上游 PlaybackStatus.isCurrentlyPlaying：当前媒体且状态为播放中） */
  isPlaying(feedItemId: number): boolean {
    return this.isCurrentlyPlaying(feedItemId) && PlayerManager.getStatus() === 'PLAYING';
  }

  /** 当前播放项（不看播放/暂停状态，上游 PlaybackStatus.isPlaying） */
  /**
   * 是否**正在播放**（当前项 + 播放器状态为 PLAYING）。
   *
   * 与 `isCurrentlyPlaying`（只判断「是不是当前项」，用于进度/剩余时间）区分开：
   * 暂停时卡片上的按钮应回到播放图标。
   */
  private isPlayingNow(feedItemId: number): boolean {
    const current: Playable | undefined = PlayerManager.getCurrent();
    return current !== undefined && current.feedItemId === feedItemId
      && PlayerManager.getStatus() === 'PLAYING';
  }

  private isCurrentlyPlaying(feedItemId: number): boolean {
    const current: Playable | undefined = PlayerManager.getCurrent();
    return current !== undefined && current.feedItemId === feedItemId;
  }

  itemImage(item: FeedItem): string {
    return item.imageUrl !== '' ? item.imageUrl : this.feedImage(item.feedId);
  }

  feedImage(feedId: number): string {
    return this.feedImages.get(feedId) ?? '';
  }

  dateText(timestamp: number): string {
    if (timestamp <= 0) {
      return '';
    }
    return new Date(timestamp).toLocaleDateString();
  }

  /** 行的进度值：当前播放项用实时进度（上游 notifyPlaybackPositionUpdated），其余用库里的 position */
  progressFor(item: FeedItem): number {
    if (this.isCurrentlyPlaying(item.id) && this.playbackPercent > 0) {
      return this.playbackPercent;
    }
    return this.itemProgress(item);
  }

  itemProgress(item: FeedItem): number {
    if (item.media === undefined || item.media.duration <= 0 || item.media.position <= 0) {
      return 0;
    }
    const percent: number = Math.floor(item.media.position * 100 / item.media.duration);
    return percent > 100 ? 100 : (percent < 5 ? 5 : percent);
  }

  /** 位置文本（上游 txtvPosition）：当前播放项显示实时位置 */
  positionText(item: FeedItem): string {
    if (this.isCurrentlyPlaying(item.id) && this.playbackPositionMs > 0) {
      return DurationUtils.format(this.playbackPositionMs);
    }
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
   * 剩余时长（卡片胶囊右侧显示）。
   * 当前播放项用实时进度算剩余，其余用库里已存的播放位置；
   * 没有媒体信息时退回总时长（而不是空串，避免胶囊里只剩一根进度条）。
   */
  /**
   * 卡片进度条右侧的「剩余时间」。
   *
   * 之前时长未知（RSS 里没有 <itunes:duration>，要等解析/播放后才有）时直接返回空串，
   * 看起来就像「数字有时不显示」。现在：
   *   - 时长未知 → 显示 `--:--`（占位，永远有内容）
   *   - 正在播放 → 用实时位置算剩余，随播放每秒递减
   *   - 未播放 → 用库里保存的进度算剩余（= 总时长）
   */
  remainingText(item: FeedItem): string {
    const media: FeedMedia | undefined = item.media;
    if (media === undefined || media.duration <= 0) {
      return '--:--';
    }
    let position: number = media.position > 0 ? media.position : 0;
    if (this.isCurrentlyPlaying(item.id)) {
      // 当前项优先用实时位置；刚起播时事件还没到就退回库里的进度
      const live: number = PlayerManager.getCurrentTime();
      position = live > 0 ? live : position;
    }
    const remaining: number = media.duration - Math.min(position, media.duration);
    return '-' + DurationUtils.format(remaining > 0 ? remaining : 0);
  }

  isVideo(item: FeedItem): boolean {
    const media: FeedMedia | undefined = item.media;
    return media !== undefined && media.getMediaType() === MediaType.VIDEO;
  }

  /** 状态行：发布日期 · 文件大小（上游 feeditemlist_item 的 pubDate · size） */
  metaText(item: FeedItem): string {
    const parts: string[] = [];
    if (item.pubDate > 0) {
      parts.push(this.dateText(item.pubDate));
    }
    if (item.media !== undefined && item.media.size > 0) {
      parts.push(this.sizeText(item.media.size));
    }
    return parts.join(' · ');
  }

  sizeText(bytes: number): string {
    if (bytes <= 0) {
      return '0 MB';
    }
    const mb: number = bytes / (1024 * 1024);
    return mb < 1 ? (bytes / 1024).toFixed(0) + ' KB' : mb.toFixed(1) + ' MB';
  }

  // ---------------------------------------------------------------- 区块顺序 / 显隐

  /** 当前完整区块顺序（未配置过时用默认顺序，并补齐后来新增的区块） */
  private fullOrder(): string[] {
    const order: string[] = this.sectionOrder.length > 0
      ? this.sectionOrder.slice() : HomePage.DEFAULT_SECTIONS.slice();
    for (const tag of HomePage.DEFAULT_SECTIONS) {
      if (!order.includes(tag)) {
        order.push(tag);
      }
    }
    return order;
  }

  /** 首页要渲染的区块顺序（上游 HomePreferences.getSortedSectionTags） */
  visibleSections(): string[] {
    const result: string[] = [];
    for (const tag of this.fullOrder()) {
      if (!this.hiddenSections.includes(tag)) {
        result.push(tag);
      }
    }
    return result;
  }

  /**
   * 编辑模式的行：`shown = true` 取「显示」组（`hidden === false`），`false` 取「隐藏」组。
   *
   * 注意这里的比较方向：`hidden === shown` 才是**要跳过**的行。
   * 第 40 轮验收把它写反过（保留 `hidden !== shown`），后果是「显示」组恒为空：
   * `sectionRows(true)` 返回的其实是隐藏组，于是「显示」标题所在的槽位什么都不渲染，
   * 5 个区块行全部来自隐藏组 —— 在界面上看起来就像「隐藏」标题被排到了行前面，
   * 一度被误判成 ArkUI 的兄弟节点重排（换了 6 种布局写法都"复现"，其实是同一个过滤条件写反）。
   */
  sectionRows(shown: boolean): HomeSectionRow[] {
    const rows: HomeSectionRow[] = [];
    for (const tag of this.fullOrder()) {
      const hidden: boolean = this.hiddenSections.includes(tag);
      if (hidden === shown) {
        continue;
      }
      rows.push({
        tag: tag,
        title: this.sectionTitle(tag),
        icon: this.sectionIcon(tag),
        hidden: hidden
      });
    }
    return rows;
  }

  private sectionTitle(tag: string): ResourceStr {
    if (tag === 'continue') {
      return $r('app.string.home_continue');
    }
    if (tag === 'new') {
      return $r('app.string.home_new');
    }
    if (tag === 'random') {
      return $r('app.string.home_random');
    }
    if (tag === 'top') {
      return $r('app.string.home_top');
    }
    if (tag === 'downloads') {
      return $r('app.string.home_downloads');
    }
    // 六个精选板块（curated_xxx）：此前落到兜底分支，编辑区块里全显示成「管理下载」
    if (tag.startsWith('curated_')) {
      return this.curatedTitle(tag.substring(8));
    }
    return $r('app.string.home_downloads');
  }

  private sectionIcon(tag: string): Resource {
    if (tag === 'continue') {
      return $r('sys.symbol.play_circle');
    }
    if (tag === 'new') {
      return $r('sys.symbol.inbox');
    }
    if (tag === 'random') {
      return $r('sys.symbol.shuffle');
    }
    if (tag === 'top') {
      return $r('sys.symbol.headphones');
    }
    if (tag === 'downloads') {
      return $r('sys.symbol.download_1');
    }
    // 六个精选板块：共用「星」图标，靠标题区分（不各自造一套符号）
    if (tag.startsWith('curated_')) {
      return $r('sys.symbol.star');
    }
    return $r('sys.symbol.download_1');
  }

  private moveSection(tag: string, delta: number): void {
    const order: string[] = this.fullOrder();
    const from: number = order.indexOf(tag);
    const to: number = from + delta;
    if (from < 0 || to < 0 || to >= order.length) {
      return;
    }
    const moved: string = order[from];
    order.splice(from, 1);
    order.splice(to, 0, moved);
    this.sectionOrder = order;
    UserPreferences.setHomeSectionOrder(order);
  }

  private setSectionHidden(tag: string, hidden: boolean): void {
    let hiddenList: string[] = this.hiddenSections.slice();
    if (hidden) {
      if (!hiddenList.includes(tag)) {
        hiddenList.push(tag);
      }
    } else {
      hiddenList = hiddenList.filter((entry: string) => entry !== tag);
    }
    this.hiddenSections = hiddenList;
    UserPreferences.setHiddenHomeSections(hiddenList);
  }
}