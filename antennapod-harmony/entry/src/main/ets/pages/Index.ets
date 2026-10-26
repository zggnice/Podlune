import router from '@ohos.router';
import { AppFont } from '../services/AppFont';
import { SubscriptionsPage } from './SubscriptionsPage';
import { EpisodesPage } from './EpisodesPage';
import { SearchPage } from './SearchPage';
import { HomePage } from './HomePage';
import { FloatingNavigation } from '../components/FloatingNavigation';
import { MiniPlayer } from '../components/MiniPlayer';
import { AmbientBackground } from '../components/AmbientBackground';
import { DesignTokens } from '../common/DesignTokens';
import { curves } from '@kit.ArkUI';
import { PlayerManager } from '../player/PlayerManager';
import { QueueEngine } from '../player/QueueEngine';
import { Playable } from '../model/Playable';
import { FeedItem } from '../model/FeedItem';
import { EventHub, EventType } from '../events/EventHub';
import { UserPreferences } from '../prefs/UserPreferences';
import { NavigationMaterial } from '../common/NavigationMaterial';
import { EpisodeRepository } from '../db/repositories/EpisodeRepository';
import { menuIcon } from '../common/MenuIcons';
import { SafeAreaProbe } from '../common/SafeAreaProbe';

/**
 * 应用外壳。
 *
 * 结构：Navigation 只提供根容器与转场，不渲染系统标题栏（页签页自带悬浮大标题区）。
 * 内容铺满整屏，悬浮播放条与沉浸光感底栏叠在内容之上——
 * 内容滚动时从它们后方穿过，由系统材质 / 半透明玻璃淡出。
 *
 * 底栏：首页 / 收件箱 / 订阅 / 更多 / 搜索 五项；
 * 队列并入「更多」菜单（作为子页面打开），页签内容里保留它的视图防抖。
 */
@Entry
@Component
struct Index {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  /** API 26 起使用沉浸光感悬浮底栏；更早的系统使用贴边实心底栏 */
  @State floating: boolean = NavigationMaterial.supportsFloating();
  @State currentTab: number = 0;
  /** 各页签是否已首次挂载：true 后不再销毁，避免切页签时重新查库 */
  @State homeVisited: boolean = true;
  @State episodesVisited: boolean = false;
  @State subscriptionsVisited: boolean = false;
  @State searchVisited: boolean = false;
  @State playerStatus: string = PlayerManager.getStatus();
  @State playerTitle: string = '';
  @State playerFeedTitle: string = '';
  /** 迷你播放条封面（当前播放对象的 imageUrl） */
  @State playerImage: string = '';
  @State playerProgress: number = 0;
  @State unreadCount: number = 0;
  @State lightLevel: number = UserPreferences.getNavigationLightLevel();
  /** 「更多」菜单是否展开（自绘浮层，与底栏按钮颜色严格同步） */
  @State moreOpen: boolean = false;
  /**
   * 底栏折叠态：上滑内容 → 收成「主页圆钮 + 紧凑播放条」；
   * 点主页圆钮或下滑 → 回到「播放条 + 导航栏」的完整形态。
   */
  /**
   * 折叠进度（0 = 完整 Dock，1 = 紧凑 Dock）。
   * 所有形变（播放条宽度/位置、导航栏宽度、图标透明度）都从这一个数字派生，
   * 由统一的 animateTo 驱动，保证「同一个 Dock 在变形」而不是两套 UI 切换。
   */
  @State barProgress: number = 0;
  /** 浮动层可用宽度（vp）：由 onAreaChange 实测，禁止写死像素 */
  @State barAvailWidth: number = 0;
  /** 累计滚动量（正 = 内容上滑）与最近一次有效方向 */
  private scrollAccum: number = 0;
  /** 最近一次折叠/展开的时间戳：防止一次滑动被判定两次（收起又立刻弹回） */
  private lastBarToggleAt: number = 0;
  /** 底部系统避让（手势条 / 三键导航）高度，浮动层压在它上面 */
  @State bottomSafe: number = 0;

  private static readonly TAB_HOME: number = 0;
  private static readonly TAB_EPISODES: number = 1;
  private static readonly TAB_SUBSCRIPTIONS: number = 2;
  private static readonly TAB_SEARCH: number = 3;
  /** 底栏第 4 项：搜索 */
  private static readonly NAV_SEARCH: number = 3;
  /** 底栏第 5 项：更多（只展开菜单，不切页签） */
  private static readonly NAV_MORE: number = 4;

  onPageShow(): void {
    this.lightLevel = UserPreferences.getNavigationLightLevel();
    this.refreshPlayerTitle();
    this.playerStatus = PlayerManager.getStatus();
  }

  /** 内容需要让出的底部空间：底栏 + 播放条 + 间距 */
  private navigationInset(): number {
    const bar: number = this.floating ? DesignTokens.HEIGHT_FLOAT_NAV : DesignTokens.HEIGHT_TAB_BAR;
    const player: number = this.playerVisible() ? DesignTokens.HEIGHT_FLOAT_PLAYER + DesignTokens.SPACE_S : 0;
    return bar + player;
  }

  private playerVisible(): boolean {
    // 关键：加载中（INITIALIZING / PREPARING）也必须算「有播放项」。
    // 之前只认 PLAYING/PAUSED/PREPARED，于是「折叠态 + 点一个慢加载的单集」时
    // 播放条直接消失，而且要等真正开播才回来 —— 用户看到的就是「播放条丢失」。
    return this.playerStatus === 'PLAYING'
      || this.playerStatus === 'PAUSED'
      || this.playerStatus === 'PREPARED'
      || this.playerStatus === 'INITIALIZING'
      || this.playerStatus === 'PREPARING'
      || this.playerStatus === 'COMPLETED';
  }

  /** 正在加载（用于播放条上的 loading 态） */
  private playerLoading(): boolean {
    return this.playerStatus === 'INITIALIZING' || this.playerStatus === 'PREPARING';
  }

  build() {
    Navigation() {
      Stack({ alignContent: Alignment.Bottom }) {
        // 全局背景（纯色 page_bg，与各页面根容器同色）：位于所有页签内容与浮动层之下
        // 保留该层是为了让背景始终处在最底层，以后要加背景效果只改 AmbientBackground 即可。

        // 页签内容：Column 包一层，让悬浮层与内容处在同一绘制链上（材质才能取到背后内容）
        //
        // 三个页面都「首次访问后常驻」，切换只改 visibility：
        // 原来用 if/else 切换，切走即销毁、切回重建 → aboutToAppear 重新查库，
        // 表现就是「先空一下，再突然冒出内容」。常驻后切页签不再重新加载，
        // 只有下拉刷新（各页自己的 Refresh.onRefreshing）才会取新数据。
        Column() {
          if (this.homeVisited) {
            HomePage({ bottomInset: this.navigationInset(),
              onNavigate: (target: string) => this.navigate(target),
              onScrollDelta: (delta: number) => this.handleScrollDelta(delta) })
              .visibility(this.currentTab === Index.TAB_HOME ? Visibility.Visible : Visibility.None)
          }
          if (this.episodesVisited) {
            EpisodesPage({ asTab: true, bottomInset: this.navigationInset(),
              onScrollDelta: (delta: number) => this.handleScrollDelta(delta) })
              .visibility(this.currentTab === Index.TAB_EPISODES ? Visibility.Visible : Visibility.None)
          }
          if (this.subscriptionsVisited) {
            SubscriptionsPage({ bottomInset: this.navigationInset(),
              onScrollDelta: (delta: number) => this.handleScrollDelta(delta) })
              .visibility(this.currentTab === Index.TAB_SUBSCRIPTIONS ? Visibility.Visible : Visibility.None)
          }
          if (this.searchVisited) {
            SearchPage({ asTab: true, bottomInset: this.navigationInset(),
              onScrollDelta: (delta: number) => this.handleScrollDelta(delta) })
              .visibility(this.currentTab === Index.TAB_SEARCH ? Visibility.Visible : Visibility.None)
          }
        }
        .width('100%')
        .height('100%')
        // Dock：所有几何都从 barProgress 派生，播放条与导航栏在同一个 Stack 坐标系里连续变形。
        // 不再挂全局 PanGesture —— 折叠由首页主列表的真实滚动回调驱动，横向列表不受影响。
        Column() {
          Stack({ alignContent: Alignment.BottomStart }) {
            // ---- 迷你播放条：始终挂载（不随状态销毁），只改宽高与位置
            if (this.playerVisible()) {
              Row() {
                this.miniPlayerBar()
              }
              .width(this.playerWidth())
              .height(this.playerBarHeight())
              .position({
                x: (this.dockCircle() + DesignTokens.SPACE_S) * this.barProgress,
                y: this.dockHeight() - this.playerBarHeight() - this.playerBottomOffset()
              })
              // 极轻微的纵向压缩，形成「呼吸感」；静止时为 1
              .scale({ x: 1, y: 1 - 0.01 * this.barProgress })
            }

            // ---- 导航栏：同一条胶囊连续收缩成圆钮（当前 Tab 项占满宽度，其余收缩为 0）
            if (this.floating) {
              FloatingNavigation({
                currentIndex: this.currentTab,
                badge: this.unreadCount,
                progress: this.barProgress,
                availableWidth: this.navWidth(),
                onSwitch: (index: number) => {
                  this.handleNavClick(index);
                },
                onExpand: () => {
                  this.setBarProgress(0);
                }
              })
                .width(this.navWidth())
                .height(this.navBarHeight())
                .position({ x: 0, y: this.dockHeight() - this.navBarHeight() })
            } else {
              Row() {
                this.legacyNavigation()
              }
              .width(this.navWidth())
              .height(this.navBarHeight())
              .position({ x: 0, y: this.dockHeight() - this.navBarHeight() })
            }
          }
          .width('100%')
          .height(this.dockHeight())
          .onAreaChange((_old: Area, area: Area) => {
            // 只用来取容器宽度（vp），避免写死屏幕像素；高度由内容决定
            const width: number = Number(area.width);
            if (width > 0 && Math.abs(width - this.barAvailWidth) > 0.5) {
              this.barAvailWidth = width;
            }
          })
        }
        .width('100%')
        // 浮动模式下底栏与播放条共用这一层左右留白（两者宽度始终一致）
        .padding({
          left: this.floating ? DesignTokens.FLOAT_NAV_SIDE : 0,
          right: this.floating ? DesignTokens.FLOAT_NAV_SIDE : 0
        })
        .margin({ bottom: DesignTokens.NAV_BOTTOM_MARGIN + this.bottomSafe })

        // 「更多」菜单浮层：叠在底栏之上，开关状态同时驱动底栏按钮变色
        if (this.moreOpen && this.floating) {
          this.moreMenuOverlay()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      // 沉浸式状态栏：页面背景绘制区上延到状态栏下（恢复原始行为，底部不再外扩）
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    }
    .hideTitleBar(true)
    .hideToolBar(true)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
    // 根容器恢复为最初的纯色背景
    .backgroundColor($r('app.color.page_bg'))
  }

  // ================================================================ 页签切换

  /**
   * 底栏点击统一入口（由 FloatingNavigation.onSwitch 回调）。
   * - 0/1/2：切换页签，选中态停在该项；
   * - 3（搜索）：不切页签、不延时，立即推入搜索页。
   *   旧实现先 currentTab = 3 再延时 250ms 跳转，而 3 号内容会落到 else 分支渲染「订阅页」，
   *   于是点搜索会先闪一下订阅界面——该延时已移除。
   * - 4（更多）：不做任何事——它的选中色由菜单开关状态自行驱动（见 FloatingNavigation）。
   */
  /**
   * 统一的 Dock 控制器：滚动与点击都只改 barProgress，几何全部由它派生。
   * 没有播放条时不做折叠（保持完整导航）。
   */
  private setBarProgress(target: number): void {
    if (!this.playerVisible()) {
      return;
    }
    if (Math.abs(this.barProgress - target) < 0.01) {
      return;
    }
    // D2：按「最近一次滚动幅度」调整弹簧手感——快速甩动更干脆（响应更短、阻尼更小），
    // 缓慢拖动更绵（保留原来的 0.36 / 0.90），形变幅度不会突变，只是回弹节奏不同。
    const fling: number = Math.min(1, Math.abs(this.scrollAccum) / 48);
    this.scrollAccum = 0;
    const response: number = 0.36 - 0.10 * fling;
    const damping: number = 0.90 - 0.06 * fling;
    animateTo({
      duration: 360,
      curve: curves.springMotion(response, damping)
    }, () => {
      this.barProgress = target;
    });
  }

  /**
   * 滚动回调（由首页主列表上报真实滚动增量）。
   * 阈值 + 方向反转即清零 + 目标态比较，保证：小幅抖动不触发、同向连滚不重复触发、
   * 反向手势能立刻打断并反向过渡。
   */
  private handleScrollDelta(delta: number): void {
    if (!this.playerVisible() || Math.abs(delta) < 0.4) {
      return;
    }
    const goingDown: boolean = delta > 0;
    if ((this.scrollAccum > 0 && !goingDown) || (this.scrollAccum < 0 && goingDown)) {
      // 方向反转：重新累计，允许打断动画
      this.scrollAccum = 0;
    }
    this.scrollAccum += delta;
    // onScrollFrameBegin 每帧给的是小幅增量，累计到 6vp 即视为「明确的滑动意图」
    if (this.scrollAccum >= 6 && this.barProgress < 1) {
      this.setBarProgress(1);
    } else if (this.scrollAccum <= -6 && this.barProgress > 0) {
      this.setBarProgress(0);
    }
  }

  /** 播放条高度：展开 44vp，折叠时与圆钮同高（58vp）——两者顶底严格一致 */
  private playerBarHeight(): number {
    return DesignTokens.HEIGHT_FLOAT_PLAYER
      + (DesignTokens.HEIGHT_FLOAT_NAV - DesignTokens.HEIGHT_FLOAT_PLAYER) * this.barProgress;
  }
  /** 折叠态圆钮直径：取导航栏高度（58vp），与右侧播放条垂直居中 */
  private dockCircle(): number {
    return DesignTokens.HEIGHT_FLOAT_NAV;
  }

  /** 导航容器高度：恒为胶囊高度，折叠后即为正圆直径 */
  private navBarHeight(): number {
    return DesignTokens.HEIGHT_FLOAT_NAV;
  }

  /** 播放条宽度：展开 = 整条可用宽；折叠 = 可用宽 - 圆钮 - 间距 */
  private playerWidth(): number {
    const avail: number = this.barAvailWidth > 0 ? this.barAvailWidth : 360;
    return avail - (this.dockCircle() + DesignTokens.SPACE_S) * this.barProgress;
  }

  /**
   * 播放条纵向位置：
   * - 展开时在导航栏上方（导航高 + 间距）；
   * - 折叠时与左侧圆钮**同一水平线居中**（两者高度不同，要按差值的一半对齐）。
   */
  private playerBottomOffset(): number {
    const navHeight: number = DesignTokens.HEIGHT_FLOAT_NAV;
    const expandedLift: number = navHeight + DesignTokens.SPACE_S;
    // 折叠时播放条与圆钮等高，贴同一条底边即顶底对齐
    return expandedLift * (1 - this.barProgress);
  }

  /** Dock 容器总高：折叠时只剩一行 */
  private dockHeight(): number {
    const expanded: number = DesignTokens.HEIGHT_FLOAT_NAV + DesignTokens.SPACE_S
      + DesignTokens.HEIGHT_FLOAT_PLAYER;
    const compact: number = DesignTokens.HEIGHT_FLOAT_NAV;
    return this.playerVisible()
      ? compact + (expanded - compact) * (1 - this.barProgress)
      : DesignTokens.HEIGHT_FLOAT_NAV;
  }

  /** 导航栏宽度：展开 = 整条；折叠 = 圆钮直径 */
  private navWidth(): number {
    const avail: number = this.barAvailWidth > 0 ? this.barAvailWidth : 360;
    return avail - (avail - this.dockCircle()) * this.barProgress;
  }

  /** 迷你播放条（展开态与折叠态共用同一份构建逻辑） */
  @Builder
  miniPlayerBar() {
    MiniPlayer({
      barHeight: this.playerBarHeight(),
      title: this.playerTitle,
      feedTitle: this.playerFeedTitle,
      imageUrl: this.playerImage,
      progress: this.playerProgress,
      playing: this.playerStatus === 'PLAYING',
      loading: this.playerLoading(),
      show: true,
      floating: this.floating,
      onToggle: () => {
        if (this.playerStatus === 'PLAYING') {
          PlayerManager.pause();
        } else {
          PlayerManager.play();
        }
        this.playerStatus = PlayerManager.getStatus();
      }
    })
      .layoutWeight(1)
  }

  private handleNavClick(index: number): void {
    // 搜索已成为页签（3），只有「更多」(4) 由外壳自己处理菜单开关
    if (index === Index.NAV_MORE) {
      return;
    }
    this.switchTab(index);
  }

  private switchTab(index: number): void {
    if (index === this.currentTab) {
      return;
    }
    // 首次进入某个页签时才挂载它；之后一直常驻（见 build 里的 visibility 说明）
    if (index === Index.TAB_EPISODES) {
      this.episodesVisited = true;
    } else if (index === Index.TAB_SUBSCRIPTIONS) {
      this.subscriptionsVisited = true;
    } else if (index === Index.TAB_SEARCH) {
      this.searchVisited = true;
    }
    this.currentTab = index;
    this.refreshCounts();
    // 切页签时把 Dock 复位到展开态：否则从其它页带着「折叠」进来时，
    // 播放条看着像是消失了（实际只是被折叠到圆钮右侧）。
    if (this.barProgress > 0) {
      this.setBarProgress(0);
    }
  }

  // ================================================================ 「更多」菜单

  /**
   * 「更多」菜单浮层（自绘，不是系统 bindMenu）。
   *
   * 之所以自绘：`bindMenu` 展开时不回传开关状态（`bindMenu(isShow)` 在本工程的
   * ArkTS 版本上不支持 `$$` 双向绑定），底栏「更多」按钮因此无法在展开时变色。
   * 自绘后菜单开关由 `moreOpen` 单一状态源驱动，按钮颜色与菜单严格同步。
   *
   * 形态对齐系统菜单：圆角卡片 + 「图标 + 文案」行，贴底栏上方右对齐；
   * 点空白处或再次点「更多」收起。
   */
  @Builder
  moreMenuOverlay() {
    // 遮罩：点空白处收起（透明但参与命中测试）
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('#0A000000')
      .onClick(() => {
        this.moreOpen = false;
      })

    Column() {
      Column() {
        this.moreRow($r('sys.symbol.music_note_list'), $r('app.string.tab_queue'), 'pages/QueuePage')
        this.moreRow($r('sys.symbol.inbox'), $r('app.string.inbox_title'), 'pages/InboxPage')
        this.moreRow($r('sys.symbol.download_1'), $r('app.string.tab_downloads'), 'pages/DownloadsPage')
        this.moreRow($r('sys.symbol.histogram'), $r('app.string.more_statistics'), 'pages/StatsPage')
        this.moreRow($r('sys.symbol.plus'), $r('app.string.more_add_feed'), 'pages/AddFeedPage')
        this.moreRow($r('sys.symbol.gearshape'), $r('app.string.tab_settings'), 'pages/SettingsPage')
      }
      .padding(DesignTokens.SPACE_S)
      .backgroundColor($r('app.color.surface'))
      .borderRadius(DesignTokens.RADIUS_CARD)
      .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
      .animation({ duration: 180, curve: Curve.FastOutSlowIn })
    }
    .width('100%')
    .height('100%')
    .padding({ right: DesignTokens.PAGE_MARGIN, bottom: 0 })
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.End)
    .margin({
      bottom: this.bottomSafe + DesignTokens.NAV_BOTTOM_MARGIN + DesignTokens.HEIGHT_FLOAT_NAV + DesignTokens.SPACE_S
    })
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 与 moreRow 相同，但图标走 SVG 图片 */
  @Builder
  moreRowImage(icon: Resource, label: Resource, url: string) {
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
      this.moreOpen = false;
      router.pushUrl({ url: url });
    })
  }

  @Builder
  moreRow(icon: Resource, label: Resource, url: string) {
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
      this.moreOpen = false;
      router.pushUrl({ url: url });
    })
  }

  // ================================================================ 旧系统（API 14–25）贴边底栏

  @Builder
  legacyNavigation() {
    Row() {
      Column() {
        this.legacyTabItem(Index.TAB_HOME, $r('app.string.tab_home'), $r('sys.symbol.house'),
          $r('sys.symbol.house_fill'))
      }.layoutWeight(1)
      Column() {
        this.legacyTabItem(Index.TAB_EPISODES, $r('app.string.episodes_label'), $r('sys.symbol.rectangle_stack'),
          $r('sys.symbol.rectangle_stack'))
      }.layoutWeight(1)
      Column() {
        this.legacyTabItem(Index.TAB_SUBSCRIPTIONS, $r('app.string.tab_subscriptions'), $r('sys.symbol.dot_radiowaves_left_and_right'),
          $r('sys.symbol.dot_radiowaves_left_and_right'))
      }.layoutWeight(1)
      Column() {
        Column({ space: 2 }) {
          SymbolGlyph($r('sys.symbol.more'))
            .fontSize(DesignTokens.ICON_NAV)
            .fontColor([$r('app.color.text_primary')])
          Text($r('app.string.tab_more')).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_NAV)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
        }
        .width('100%')
        .height(DesignTokens.HEIGHT_TAB_BAR)
        .justifyContent(FlexAlign.Center)
        .bindMenu(this.legacyMoreMenu)
      }.layoutWeight(1)
    }
    .width('100%')
    .backgroundColor($r('app.color.surface'))
  }

  @Builder
  legacyTabItem(index: number, label: Resource, icon: Resource, activeIcon: Resource) {
    Column({ space: 2 }) {
      SymbolGlyph(this.currentTab === index ? activeIcon : icon)
        .fontSize(DesignTokens.ICON_NAV)
        .fontColor([this.currentTab === index ? $r('app.color.primary') : $r('app.color.text_primary')])
      Text(label).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_NAV)
        .fontColor(this.currentTab === index ? $r('app.color.primary') : $r('app.color.text_secondary'))
        .maxLines(1)
    }
    .width('100%')
    .height(DesignTokens.HEIGHT_TAB_BAR)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.switchTab(index);
    })
  }

  @Builder
  legacyMoreMenu() {
    Menu() {
      MenuItem({ symbolStartIcon: menuIcon($r('sys.symbol.music_note_list')),
        content: $r('app.string.tab_queue') })
        .onClick(() => {
          router.pushUrl({ url: 'pages/QueuePage' });
        })
      MenuItem({ symbolStartIcon: menuIcon($r('sys.symbol.inbox')),
        content: $r('app.string.inbox_title') })
        .onClick(() => {
          router.pushUrl({ url: 'pages/InboxPage' });
        })
      MenuItem({ symbolStartIcon: menuIcon($r('sys.symbol.download_1')),
        content: $r('app.string.tab_downloads') })
        .onClick(() => {
          router.pushUrl({ url: 'pages/DownloadsPage' });
        })

      MenuItem({ symbolStartIcon: menuIcon($r('sys.symbol.histogram')),
        content: $r('app.string.more_statistics') })
        .onClick(() => {
          router.pushUrl({ url: 'pages/StatsPage' });
        })
      MenuItem({ symbolStartIcon: menuIcon($r('sys.symbol.plus')), content: $r('app.string.more_add_feed') })
        .onClick(() => {
          router.pushUrl({ url: 'pages/AddFeedPage' });
        })
      MenuItem({ symbolStartIcon: menuIcon($r('sys.symbol.gearshape')), content: $r('app.string.tab_settings') })
        .onClick(() => {
          router.pushUrl({ url: 'pages/SettingsPage' });
        })
    }
  }

  // ================================================================ 跳转

  /** 首页区块「更多」跳转：页签直接切换，子页面走路由 */
  navigate(target: string): void {
    if (target === 'queue') {
      router.pushUrl({ url: 'pages/QueuePage' });
      return;
    }
    if (target === 'inbox') {
      // 收件箱已从底栏移到「更多」：以路由页打开（页面本身支持带返回箭头的独立形态）
      router.pushUrl({ url: 'pages/InboxPage' });
      return;
    }
    if (target === 'subscriptions') {
      this.switchTab(Index.TAB_SUBSCRIPTIONS);
      return;
    }
    if (target === 'downloads') {
      router.pushUrl({ url: 'pages/DownloadsPage' });
      return;
    }
    if (target === 'episodes') {
      // 单集已成为底栏页签：直接切页签，保持底栏可见
      this.switchTab(Index.TAB_EPISODES);
      return;
    }
    if (target === 'search') {
      // 搜索已成为底栏页签：切页签而不是推页面，底栏保持可见
      this.switchTab(Index.TAB_SEARCH);
      return;
    }
  }

  // ================================================================ 生命周期与事件

  aboutToAppear(): void {
    // 自定义字体：等 UI 上下文就绪再注册（Ability.onCreate 阶段注册不生效）
    AppFont.attachUi(this.getUIContext());
    SafeAreaProbe.bottomInset().then((inset: number) => {
      this.bottomSafe = inset;
    });
    EventHub.subscribe(EventType.PLAYER_STATUS, (data: object) => {
      const record = data as Record<string, string>;
      const status: string | undefined = record['status'];
      const previous: string = this.playerStatus;
      if (status !== undefined) {
        this.playerStatus = status;
      }
      this.refreshPlayerTitle();
      // 开始加载一个新单集时把 Dock 展开：折叠态下用户看不到任何反馈，
      // 会以为「播放条丢了」；展开后至少能看到播放条 + 加载指示。
      const startedLoading: boolean = (status === 'INITIALIZING' || status === 'PREPARING')
        && previous !== 'INITIALIZING' && previous !== 'PREPARING';
      if (startedLoading && this.barProgress > 0) {
        this.setBarProgress(0);
      }
    });
    // 上面 PLAYER_STATUS 订阅就绪后再恢复，否则恢复时发布的状态事件会丢
    this.restoreLastPlayed();
    EventHub.subscribe(EventType.QUEUE, (data: object) => {
      this.refreshCounts();
    });
    EventHub.subscribe(EventType.EPISODE_DOWNLOAD, (data: object) => {
      this.refreshCounts();
    });
    EventHub.subscribe(EventType.FEED_ITEM_UPDATE, (data: object) => {
      this.refreshCounts();
    });
    EventHub.subscribe(EventType.FEED_LIST_UPDATE, (data: object) => {
      this.refreshCounts();
    });
    EventHub.subscribe(EventType.PLAYBACK_POSITION, (data: object) => {
      this.refreshPlayerProgress();
    });
    this.refreshCounts();
    this.refreshPlayerTitle();
  }

  /** 迷你播放条标题/订阅名/封面（PlayerManager 保存当前播放对象） */
  /**
   * 冷启动恢复「上次播放的单集」：只让迷你播放器重新出现，不自动发声。
   *
   * 之前杀掉进程再进来，PlayerManager.current 为空、状态是 IDLE，
   * 而迷你播放器按状态判断显隐 → 直接消失。这里从偏好取上次的 FeedMedia id，
   * 回查单集并转成 Playable 交回 PlayerManager（它内部会发 PAUSED 状态事件）。
   */
  private async restoreLastPlayed(): Promise<void> {
    const mediaId: number = UserPreferences.getLastPlayedFeedMediaId();
    if (mediaId <= 0) {
      return;
    }
    // DbManager.init() 在 EntryAbility 里是异步且不 await 的，这里执行时数据库可能还没就绪。
    // 查不到就隔一会儿重试，最多约 3 秒；仍失败就安静放弃（不影响正常使用）。
    for (let attempt: number = 0; attempt < 10; attempt++) {
      try {
        const item: FeedItem | undefined = await EpisodeRepository.getByMediaId(mediaId);
        if (item !== undefined) {
          // getByMediaId 只查了单集表，media 是空的；必须再补一条媒体记录，
          // 否则 QueueEngine.toPlayable 会因为 item.media === undefined 直接返回 undefined。
          if (item.media === undefined) {
            item.media = await EpisodeRepository.getMediaByFeedItem(item.id);
          }
          const playable: Playable | undefined = await QueueEngine.toPlayable(item);
          if (playable !== undefined) {
            // 位置以库里的 FeedMedia.position 为准（toPlayable 有时拿到的是内存里的旧对象）
            if (item.media !== undefined && item.media.position > 0 && playable.position <= 0) {
              playable.position = item.media.position;
            }
            PlayerManager.restoreLastPlayed(playable);
            return;
          }
        }
      } catch (error) {
      }
      await new Promise<void>((resolve: () => void) => {
        setTimeout(() => resolve(), 300);
      });
    }
  }
  refreshPlayerTitle(): void {
    const current: Playable | undefined = PlayerManager.getCurrent();
    this.playerTitle = current === undefined ? '' : current.title;
    this.playerFeedTitle = current === undefined ? '' : current.feedTitle;
    this.playerImage = current === undefined ? '' : current.imageUrl;
    this.refreshPlayerProgress();
  }

  /** 迷你播放条进度 */
  refreshPlayerProgress(): void {
    const duration: number = PlayerManager.getDuration();
    if (duration <= 0) {
      this.playerProgress = 0;
      return;
    }
    const percent: number = Math.floor(PlayerManager.getCurrentTime() * 100 / duration);
    const clamped: number = percent > 100 ? 100 : percent;
    // 与 HomePage 同理：值没变就不写状态，避免整棵页签树被重建
    if (this.playerProgress === clamped) {
      return;
    }
    this.playerProgress = clamped;
  }

  /** 刷新底栏角标：收件箱显示新单集数（read = -1） */
  async refreshCounts(): Promise<void> {
    try {
      this.unreadCount = await EpisodeRepository.countNew();
    } catch (error) {
      this.unreadCount = 0;
    }
  }
}
