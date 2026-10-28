import router from '@ohos.router';
import { AdaptiveProgressColor, ProgressPalette } from '../common/AdaptiveProgressColor';
import { Configuration } from '@ohos.app.ability.Configuration';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { BookmarkStore, EpisodeBookmark } from '../services/BookmarkStore';
import { FlowingLightBackground } from '../components/FlowingLightBackground';
import common from '@ohos.app.ability.common';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import display from '@ohos.display';
import { PlayerManager } from '../player/PlayerManager';
import { ProgressPersister } from '../player/ProgressPersister';
import { Playable } from '../model/Playable';
import { SleepTimer } from '../player/SleepTimer';
import { ShakeDetector } from '../player/ShakeDetector';
import { ChapterRepository } from '../db/repositories/ChapterRepository';
import { Chapter } from '../model/Chapter';
import { QueueEngine } from '../player/QueueEngine';
import { FeedItem } from '../model/FeedItem';
import { EpisodeRepository } from '../db/repositories/EpisodeRepository';
import { FavoritesRepository } from '../db/repositories/FavoritesRepository';
import { UserPreferences } from '../prefs/UserPreferences';
import { EventHub, EventType, SleepTimerData } from '../events/EventHub';
import { DurationUtils } from '../utils/DurationUtils';
import { ShownotesSegment, ShownotesText } from '../utils/ShownotesText';
import { DesignTokens } from '../common/DesignTokens';
import { PressLightSurface } from '../common/PressLight';
import { openEpisodeDetail } from '../common/EpisodeRoute';
import { FeedCover } from '../components/FeedCover';
import { ShownotesBody } from '../components/ShownotesBody';

/**
 * 播放页（对齐上游 audioplayer_fragment.xml + cover_fragment.xml）：
 * 顶部下箭头工具栏（收藏 / 睡眠定时 / 分享）→ 方形封面 → 订阅名 + 单集标题 →
 * 「节目详情 / 章节」描边按钮 → 进度条（左右时间）→ 五个控件的播放控制行（倍速·快退·播放·快进·下一集）。
 */
@Entry
@Component
struct PlayerPage {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  @State title: string = '';
  @State feedTitle: string = '';
  /**
   * 节目详情正文（已切段：普通文本 + 可点时间码）。
   * 旧实现存的是 `plainText()` 压过空白的**单段纯文本**，`<br>`/`<p>` 与真实换行
   * 全被压成空格（「节目详情没有换行」的根因）。
   */
  @State notesSegments: ShownotesSegment[] = [];
  @State status: string = 'IDLE';
  @State playPosition: number = 0;
  /**
   * 拖动后的「乐观位置」保护期（时间戳）。
   * 暂停状态下 AVPlayer 回传的 currentTime 可能滞后，若不保护，
   * 每秒一次的 refresh() 会把用户刚拖到的位置又改回去，表现为「暂停时拖不动」。
   */
  private optimisticUntil: number = 0;
  @State duration: number = 0;
  @State chapters: Chapter[] = [];
  @State sleepRemainingText: string = '';
  /** 倒计时剩余毫秒（每秒刷新：驱动进度条 / 预设高亮 / 倒计时文本） */
  @State sleepRemainingMs: number = 0;
  /** 六个预设时长（分钟） */
  private static readonly SLEEP_PRESETS: number[] = [5, 10, 15, 30, 45, 60];
  @State speed: number = 1.0;
  @State showSpeedSheet: boolean = false;
  @State repeatMode: number = 0;
  @State showSleepSheet: boolean = false;
  /** 书签面板：列出当前单集的时间点标记 */
  @State showBookmarks: boolean = false;
  /** 是否深色模式：流光背景偏亮偏暖，深色下给文字加一层极淡阴影提高可读性 */
  @State private dark: boolean = false;
  /** 进度条自适应配色（空 = 用资源里的固定色，即原配色） */
  @State private pbarPlayed: string = '';
  @State private pbarTrack: string = '';
  /** 已取色的封面地址：同一张封面不重复取色 */
  private pbarSeedUrl: string = '';
  /** 封面左上角的标记提示文字（1 秒后自动消失） */
  @State markToast: string = '';
  /** 当前位置（±3s）是否已有标记：直接驱动图标空心/实心 */
  @State markedHere: boolean = false;
  @State showChaptersSheet: boolean = false;
  @State showNotesSheet: boolean = false;
  @State customMinutes: string = '';
  @State chapterEndToggle: boolean = false;
  @State fadeToggle: boolean = false;
  /** 摇一摇重置倒计时（上游 SleepTimerDialog「Shake to reset」，默认开） */
  @State shakeToResetToggle: boolean = true;
  /** 结束前震动提醒（上游 SleepTimerDialog「Vibrate shortly before end」，默认关） */
  @State vibrateToggle: boolean = false;
  @State favorite: boolean = false;
  @State coverSize: number = 0;
  /** 封面地址（单集封面 / 播客封面，来自当前播放对象） */
  @State coverUrl: string = '';
  @State message: string = '';
  /** 顶部分段标签：0 当前播放 / 1 节目介绍 / 2 评论 */
  @State activeTab: number = 0;
  /** 正在拖动进度条（决定是否显示 4vp 竖条指示器） */
  @State dragging: boolean = false;
  /** 拖动/点击时手指在轨道上的横向位置（vp） */
  @State dragX: number = 0;
  /** 轨道实测宽度（vp），用于把手势坐标换算成进度 */
  @State trackWidth: number = 0;
  private timerId: number = -1;
  private sleepToken: number = -1;
  private feedItemId: number = 0;
  /** 封面与进度条共用的左右边距（保证两者左右边缘严格对齐） */
  private static readonly SIDE_MARGIN: number = 20;
  /** 封面边长：由 onAreaChange 实测内容宽度减去左右边距得出，与进度条严格等宽 */
  @State contentWidth: number = 0;

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // ================= 背景（华为音乐风格：封面 + 系统厚模糊 + 渐变） =================
      // 结构（自下而上）：① 封面铺满 → ② 官方 backgroundBlurStyle 高斯厚模糊
      //                 → ③ 渐变遮罩（底部更暗）→ ④ 播放器内容（下面的 Column）
      Stack() {
        // ① 底层：专辑封面铺满全屏，`objectFit(Cover)`
        if (this.coverUrl !== '') {
          Image(this.coverUrl)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            // 背景是糊的，不需要原图分辨率：降采样省解码内存
            .sourceSize({ width: 720, height: 720 })
            // 稍微放大，避免模糊后边缘露出底色
            .scale({ x: 1.2, y: 1.2 })
            .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        }

        // 封面未就绪时的兜底底色（避免首帧闪白/闪黑）
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.player_bg_forced'))
          .opacity(this.coverUrl === '' ? 1 : 0)
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

        // ② 中层：官方厚模糊（模糊其下方的封面；系统合成，比逐帧 blur 便宜）
        Column()
          .width('100%')
          .height('100%')
          .backgroundBlurStyle(BlurStyle.BACKGROUND_THICK, {
            // 播放器固定深色观感：模糊底统一压成深色玻璃
            colorMode: ThemeColorMode.DARK
          })
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

        // ③ 顶层：渐变遮罩（自上而下渐暗，底部最暗以突出进度条与工具栏）
        Column()
          .width('100%')
          .height('100%')
          .linearGradient({
            angle: 180,
            colors: [
              // 顶部略压暗保证状态栏可读，底部只做「收口」而不是压成纯黑：
              // 原值 20/30/60/85% → 现在 12/20/40/62%
              ['#1F000000', 0],
              ['#33000000', 0.34],
              ['#66000000', 0.72],
              ['#9E000000', 1]
            ]
          })
          .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
      .width('100%')
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        // ============================================ 顶部：收起 + 分段标签 + 文字稿
        Row({ space: DesignTokens.SPACE_XS }) {
          Stack() {
            SymbolGlyph($r('sys.symbol.chevron_down'))
              .fontSize(DesignTokens.ICON_L)
              .fontColor([$r('app.color.player_text_forced')])
          }
          .width(DesignTokens.HIT_MIN)
          .height(DesignTokens.HIT_MIN)
          .alignContent(Alignment.Center)
          .onClick(() => {
            ProgressPersister.save(true);
            router.back();
          })

          Row({ space: DesignTokens.SPACE_L }) {
            this.tabItem(0, $r('app.string.player_tab_now'))
            this.tabItem(1, $r('app.string.player_tab_episode'))
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Start)

          // 分享入口：纯图标（圆形回转箭头 SVG，浅色/深色各一份资源，随主题自动切换）
          Stack({ alignContent: Alignment.Center }) {
            Image($r('app.media.ic_share_forced'))
              .width(22)
              .height(22)
              .objectFit(ImageFit.Contain)
          }
          // 只要图标：不画圆圈、不加底色/描边，直接落在页面背景上（点击热区仍是 36vp）
          .width(36)
          .height(36)
          .onClick(() => {
            this.shareCurrentEpisode();
          })
        }
        .width('100%')
        .height(DesignTokens.HEIGHT_APP_BAR)
        .padding({ left: DesignTokens.SPACE_S, right: DesignTokens.SPACE_M })
        .alignItems(VerticalAlign.Center)

        if (this.message !== '') {
          Text(this.message).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_FOOTNOTE)
            .fontColor($r('app.color.player_text_forced'))
            .width('100%')
            .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN, bottom: 4 })
        }

        // ============================================ 主体（随标签切换）
        // 「单集详情」标签会直接跳转详情页，这里只剩「当前播放」一种内容
        this.nowPlayingTab()
      }
      .width('100%')
      .height('100%')

      if (this.showSpeedSheet) {
        this.speedSheet()
      }
      if (this.showSleepSheet) {
        this.sleepSheet()
      }
      if (this.showBookmarks) {
        this.bookmarksSheet()
      }
      if (this.showChaptersSheet) {
        this.chaptersSheet()
      }
      if (this.showNotesSheet) {
        this.notesSheet()
      }
    }
    .width('100%')
    .height('100%')
    // 内容层必须**透明**：背景（封面模糊 + 渐变）已经在它下面铺满整屏，
    // 这里再垫一层实色 player_bg 就会在状态栏 / 手势区出现一条与渐变不连续的色块。
    .backgroundColor(Color.Transparent)
    // 实测可用宽度：封面边长 = 该宽度 - 左右边距，保证与进度条严格等宽
    .onAreaChange((_o: Area, n: Area) => {
      const w: Length = n.width;
      if (typeof w === 'number' && w > 0) {
        this.contentWidth = w;
        this.coverSize = w - PlayerPage.SIDE_MARGIN * 2;
      }
    })
    // 背景延伸到状态栏与底部手势区，避免出现独立的系统栏色块
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 顶部轻量分段标签：选中项加粗 + 下方短下划线 */
  @Builder
  tabItem(index: number, label: Resource) {
    Column({ space: 4 }) {
      Text(label).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_PARAGRAPH)
        // 「单集详情」不是「未选中的页签」，而是一个动作入口（点它跳详情页），
        // 所以永远按选中态显示；否则它一直是次级灰、比「当前播放」浅一档。
        .fontWeight(this.activeTab === index || index === 1 ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.activeTab === index || index === 1
          ? $r('app.color.player_text_forced') : $r('app.color.player_text_secondary_forced'))
        .maxLines(1)
      // 下划线已按需求去掉；保留 2vp 占位，避免选中/未选中切换时文字上下跳动
      Column()
        .width(20)
        .height(2)
        .borderRadius(1)
        .backgroundColor(Color.Transparent)
    }
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      // 「单集详情」标签：打开**当前正在播放**那一集的详情页。
      // 不直接读 this.feedItemId：它要等 refresh() 从 PlayerManager 同步过来，
      // 刚换集/自动连播的瞬间可能还是上一集，点进去就成了旧单集。
      if (index === 1) {
        ProgressPersister.save(true);
        const current: Playable | undefined = PlayerManager.getCurrent();
        const targetId: number = current !== undefined && current.feedItemId > 0
          ? current.feedItemId : this.feedItemId;
        if (targetId > 0) {
          // 带上时间戳：确保每次都是新参数，router 不会复用旧页面实例
          router.pushUrl({
            url: 'pages/EpisodeDetailPage',
            params: { itemId: targetId, ts: Date.now() }
          });
        }
        return;
      }
      this.activeTab = index;
    })
  }

  /** 「当前播放」标签页：图 2 的主体结构 */
  @Builder
  nowPlayingTab() {
    Column() {
      // ---- 大封面：边长 = 进度条宽度（内容宽度 - 左右边距），严格 1:1 正方形
      Row() {
        Stack({ alignContent: Alignment.TopStart }) {
          FeedCover({
            imageUrl: this.coverUrl,
            coverSize: this.coverSize,
            radius: 22,
            placeholderColor: $r('app.color.player_chip_forced')
          })
          // 标记提示：出现在封面左上角，1 秒后自动消失
          if (this.markToast !== '') {
            Text(this.markToast).fontFamily(this.appFontFamily)
              .fontSize(DesignTokens.FONT_FOOTNOTE)
              .fontColor(Color.White)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .backgroundColor('#66000000')
              .borderRadius(10)
              .margin({ left: 10, top: 10 })
              .maxLines(1)
              .transition(TransitionEffect.OPACITY.animation({ duration: 160 }))
          }
        }
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .padding({ left: PlayerPage.SIDE_MARGIN, right: PlayerPage.SIDE_MARGIN, top: DesignTokens.SPACE_M })

      // ---- 单集标题（主） + 节目名（次）：黑白层级
      Column({ space: 8 }) {
        Text(this.title === '' ? $r('app.string.player_no_playback') : this.title).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_TITLE3)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.player_text_forced'))
          .textShadow(this.dark ? { radius: 8, color: '#73000000', offsetX: 0, offsetY: 1 } : { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 })
          .textAlign(TextAlign.Center)
          .maxLines(2)
          .lineHeight(30)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.feedTitle !== '') {
          // 点击节目名 → 该播客的详情页（需要 feedId，从当前单集反查）
          Text(this.feedTitle).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_PARAGRAPH)
            .fontColor($r('app.color.player_text_secondary_forced'))
            .textShadow(this.dark ? { radius: 8, color: '#73000000', offsetX: 0, offsetY: 1 } : { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 })
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .onClick(() => {
              this.openFeedDetail();
            })
        }
      }
      .width('100%')
      .padding({ left: PlayerPage.SIDE_MARGIN, right: PlayerPage.SIDE_MARGIN, top: DesignTokens.SPACE_M })

      // ---- 进度条（华为音乐风格）：细轨道 + 白色内嵌滑块 + 下方左右时间
      // 高度严格取原进度条块高（36vp）：Slider 默认约 40vp 且带上下留白，
      // 不显式压高会让整条看起来「变粗一倍」，并把下面的控制区往下挤。
      Column({ space: 4 }) {
        Slider({
          value: this.playPosition,
          min: 0,
          max: this.duration > 0 ? this.duration : 1,
          style: SliderStyle.InSet
        })
          .trackThickness(6)
          .trackColor('#66FFFFFF')
          .selectedColor(Color.White)
          .blockColor(Color.White)
          .blockSize({ width: 12, height: 12 })
          .width('100%')
          .height(36)
          .padding({ left: 0, right: 0, top: 0, bottom: 0 })
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
              // 跟手：实时写 currentTime，并挂「乐观位置保护」防止刷新把滑块拽回去
              this.dragging = true;
              this.playPosition = value;
              this.optimisticUntil = Date.now() + 4000;
              return;
            }
            this.dragging = false;
            this.playPosition = value;
            this.optimisticUntil = Date.now() + 3000;
            PlayerManager.seek(value);
          })

        Row() {
          // 两端时间用固定文案：format() 在 0/未知时返回空串（表现为「数字消失」），
          // 这里改成 0:00 / --:-- 占位，宽度也固定，避免数字出现时把布局挤动。
          Text(this.clockText(this.playPosition, '0:00')).fontFamily(this.appFontFamily)
            .fontSize(12)
            .fontColor('#A5B4B1')
            .width(56)
          Blank()
          Text(this.clockText(this.duration, '--:--')).fontFamily(this.appFontFamily)
            .fontSize(12)
            .fontColor('#A5B4B1')
            .width(56)
            .textAlign(TextAlign.End)
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: PlayerPage.SIDE_MARGIN, right: PlayerPage.SIDE_MARGIN, top: DesignTokens.SPACE_M })
      // ---- 主控制区：后退时间 · 播放/暂停 · 前进时间（图 2 的三大按钮）
      // 左右按钮与中间播放键的间距：Row 的 space 对两侧**同时生效**，
      // 因此无论调多大，左右距离始终相等（20 → 40，视觉上更透气）。
      Row({ space: 40 }) {
        this.roundControl($r('sys.symbol.gobackward_10'), '', () => {
          PlayerManager.seekBy(-UserPreferences.getRewindSecs() * 1000);
        })

        // 播放/暂停：纯白图标、无背景、无圆角（华为音乐风格，图标比左右按钮更大）
        // 播放/暂停：系统符号 + ReplaceSymbolEffect（切换时图标平滑替换，非硬切）
        PressLightSurface({ radius: 40 }) {
          SymbolGlyph(this.status === 'PLAYING'
            ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
            .fontSize(48)
          .fontColor([Color.White])
          .symbolEffect(new ReplaceSymbolEffect(EffectScope.WHOLE), true)
            .accessibilityText(this.status === 'PLAYING'
              ? $r('app.string.player_pause') : $r('app.string.player_play'))
          .onClick(() => {
            if (this.status === 'PLAYING') {
              PlayerManager.pause();
            } else {
              // 与单集详情页同一入口：确保真的播起来（含竞态重试）
              PlayerManager.ensurePlaying();
            }
          })
        }

        this.roundControl($r('sys.symbol.goforward_30'), '', () => {
          PlayerManager.seekBy(UserPreferences.getFastForwardSecs() * 1000);
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .margin({ top: DesignTokens.SPACE_L, bottom: DesignTokens.SPACE_S })

      // 固定间距：Blank() 在高度受限时会把工具条推出屏幕（实测工具栏落在 y=2750 被截断）
      Column().height(DesignTokens.SPACE_M)

      // ---- 底部功能条：一条浅色圆角容器承载低频功能
      Row() {
        this.toolButton($r('sys.symbol.timer'), this.speed.toFixed(2), () => {
          this.openSpeedSheet();
        })
        // 播放模式（列表循环）：在 builder 内部读 @State，才能随点击实时刷新文案与高亮
        this.repeatToolButton()
        // 收藏：图标与颜色都在 builder 内部读 @State，点击后立刻切换
        this.favoriteToolButton()
        this.toolButton($r('sys.symbol.moon'), $r('app.string.player_sleep'), () => {
          this.openSleepSheet();
        }, SleepTimer.isActive())
        // 「标记」：点击在当前时间点加书签；长按查看/删除本集书签
        this.bookmarkToolButton()
        // 「队列」：进入队列页后可继续调整顺序 / 换集；换集返回时本页会自动刷新为新单集
        this.toolButton($r('sys.symbol.music_note_list'), $r('app.string.tab_queue'), () => {
          router.pushUrl({ url: 'pages/QueuePage', params: { fromPlayer: true } });
        })
      }
      // 宽度 = 内容宽度 - 左右边距，与封面/进度条严格等宽（width:'100%' + margin 会按父级算宽，比进度条宽）
      .width(this.contentWidth > 0 ? this.contentWidth - PlayerPage.SIDE_MARGIN * 2 : '100%')
      .height(60)
      .padding({ left: 4, right: 4 })
      .margin({ top: DesignTokens.SPACE_M, bottom: DesignTokens.SPACE_M })
      // 胶囊底色已去掉：按钮图标直接显示在流光背景上
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /** 「节目介绍」标签页：完整 shownotes（原「节目详情」弹层的内容复用到这里） */
  /** 主控制区两侧的圆形按钮：图标 + 秒数 */
  @Builder
  roundControl(icon: Resource, label: string, onTap: () => void) {
    Column({ space: 2 }) {
      PressLightSurface({ radius: 24 }) {
        Stack() {
          SymbolGlyph(icon)
            .fontSize(34)
            .fontColor([$r('app.color.player_text_forced')])
        }
        .width(48)
        .height(48)
        .alignContent(Alignment.Center)
        .onClick(() => {
          onTap();
        })
      }
      if (label !== '') {
        Text(label).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_FOOTNOTE)
          .fontColor($r('app.color.player_text_secondary_forced'))
          .maxLines(1)
      }
    }
    .alignItems(HorizontalAlign.Center)
  }

  /** 「标记」按钮：点击加书签，长按打开书签列表 */
  @Builder
  bookmarkToolButton() {
    Column({ space: 2 }) {
      // 小旗子：当前位置已标记 = 实心，未标记 = 空心
      // 与相邻 SymbolGlyph（睡眠/收藏，ICON_M=20）视觉重量对齐：
      // SVG 内几何只占 24 网格的一部分，所以尺寸取 21 并加大描边，避免看起来「更浅更小」
      // 系统旗标符号（与睡眠/收藏同尺寸、同字重）
      SymbolGlyph(this.markedHere ? $r('sys.symbol.flag_fill') : $r('sys.symbol.flag'))
        .fontSize(DesignTokens.ICON_M)
        .fontColor([$r('app.color.player_text_secondary_forced')])
      Text($r('app.string.player_bookmark')).fontFamily(this.appFontFamily)
        .fontSize(9)
        .fontColor($r('app.color.player_text_secondary_forced'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.addBookmarkAtCurrent();
    })
    .parallelGesture(LongPressGesture().onAction(() => {
      if (BookmarkStore.list(this.feedItemId).length === 0) {
        this.message = getContext(this).resourceManager.getStringSync($r('app.string.player_bookmark_empty'));
        return;
      }
      this.showBookmarks = true;
    }))
  }

  /** 点击「标记」：未标记 → 在当前位置标记；已标记（±2.5s 内）→ 取消标记 */
  private addBookmarkAtCurrent(): void {
    if (this.feedItemId <= 0) {
      return;
    }
    const position: number = this.playPosition;
    if (this.markedHere) {
      BookmarkStore.removeNear(this.feedItemId, position);
      this.markedHere = false;
      this.showMarkToast(getContext(this).resourceManager.getStringSync($r('app.string.player_bookmark_removed')));
      return;
    }
    BookmarkStore.add(this.feedItemId, position);
    this.markedHere = true;
    this.showMarkToast(getContext(this).resourceManager.getStringSync($r('app.string.player_bookmark_added'))
      + ' ' + this.shareTimeText(position));
  }

  /**
   * 进度条自适应配色：封面（= 流光背景的来源）换了一集就重新取主色。
   * 同一张封面只取一次；偏好关闭时清空颜色，回落资源里的固定配色。
   */
  private syncProgressPalette(coverUrl: string): void {
    if (!UserPreferences.getAdaptiveProgressColor()) {
      if (this.pbarPlayed !== '') {
        this.pbarPlayed = '';
        this.pbarTrack = '';
        this.pbarSeedUrl = '';
      }
      return;
    }
    if (coverUrl === '' || coverUrl === this.pbarSeedUrl) {
      return;
    }
    this.pbarSeedUrl = coverUrl;
    const target: string = coverUrl;
    AdaptiveProgressColor.seedOf(target).then((seed: string) => {
      // 期间又换集了就丢弃这次结果，避免「上一集的颜色」闪一下
      if (this.pbarSeedUrl !== target) {
        return;
      }
      const palette: ProgressPalette = AdaptiveProgressColor.palette(seed, this.dark);
      this.pbarPlayed = palette.played;
      this.pbarTrack = palette.track;
    }).catch(() => {
    });
  }

  /** 播放位置变化时同步「当前位置是否已标记」 */
  private refreshMarkedState(): void {
    if (this.feedItemId <= 0) {
      this.markedHere = false;
      return;
    }
    const next: boolean = BookmarkStore.hasNear(this.feedItemId, this.playPosition, 3000);
    if (next !== this.markedHere) {
      this.markedHere = next;
    }
  }

  /** 封面左上角的短提示：显示 1 秒后自动消失 */
  private showMarkToast(text: string): void {
    this.markToast = text;
    if (this.markToastTimerId >= 0) {
      clearTimeout(this.markToastTimerId);
      this.markToastTimerId = -1;
    }
    this.markToastTimerId = setTimeout(() => {
      this.markToast = '';
      this.markToastTimerId = -1;
    }, 1000);
  }

  /** 书签面板：点条目跳转，右侧删除 */
  @Builder
  bookmarksSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.showBookmarks = false;
        })

      Column({ space: DesignTokens.SPACE_S }) {
        Row() {
          Text($r('app.string.player_bookmarks_title')).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_SUBTITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.player_text_forced'))
            .layoutWeight(1)
          Text($r('app.string.dialog_cancel')).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_SUBTITLE)
            .fontColor($r('app.color.player_text_secondary_forced'))
            .onClick(() => {
              this.showBookmarks = false;
            })
        }
        .width('100%')
        .padding({ bottom: DesignTokens.SPACE_S })

        ForEach(BookmarkStore.list(this.feedItemId), (item: EpisodeBookmark) => {
          Row({ space: DesignTokens.SPACE_M }) {
            Text(this.shareTimeText(item.positionMs)).fontFamily(this.appFontFamily)
              .fontSize(DesignTokens.FONT_SUBTITLE)
              .fontColor($r('app.color.primary'))
            Text(item.note === '' ? this.shareTimeText(item.positionMs) : item.note).fontFamily(this.appFontFamily)
              .fontSize(DesignTokens.FONT_FOOTNOTE)
              .fontColor($r('app.color.player_text_secondary_forced'))
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            SymbolGlyph($r('sys.symbol.trash'))
              .fontSize(DesignTokens.ICON_S)
              .fontColor([$r('app.color.player_text_tertiary_forced')])
              .onClick(() => {
                BookmarkStore.remove(this.feedItemId, item.positionMs);
                this.showBookmarks = BookmarkStore.list(this.feedItemId).length > 0;
              })
          }
          .width('100%')
          .padding({ top: DesignTokens.SPACE_S, bottom: DesignTokens.SPACE_S })
          .onClick(() => {
            PlayerManager.seek(item.positionMs);
            this.showBookmarks = false;
          })
        }, (item: EpisodeBookmark) => item.positionMs.toString())
      }
      .width('100%')
      .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN,
        top: DesignTokens.SPACE_L, bottom: DesignTokens.SPACE_L })
      .backgroundColor($r('app.color.surface'))
      .borderRadius({ topLeft: DesignTokens.RADIUS_SHEET, topRight: DesignTokens.RADIUS_SHEET })
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
  }

  /** 底部功能条里的图标（线性、无独立底色；激活态用品牌紫） */
  @Builder
  toolButton(icon: Resource, label: ResourceStr, onTap: () => void, active: boolean = false) {
    // 外层 Column 只负责在工具栏里均分宽度；光感容器不要直接链属性（ArkTS 不允许
    // 自定义组件后紧跟 .layoutWeight），所以把它放在内层。
    Column() {
      PressLightSurface({ radius: 14 }) {
        Column({ space: 2 }) {
          SymbolGlyph(icon)
            .fontSize(DesignTokens.ICON_M)
            .fontColor([active ? $r('app.color.player_text_forced') : $r('app.color.player_text_secondary_forced')])
          Text(label).fontFamily(this.appFontFamily)
            .fontSize(9)
            .fontColor(active ? $r('app.color.player_text_forced') : $r('app.color.player_text_secondary_forced'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .justifyContent(FlexAlign.Center)
        .padding({ top: 4, bottom: 4 })
        .onClick(() => {
          onTap();
        })
      }
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }
  /**
   * 播放模式按钮（工具栏第二项）。
   * `@Builder` 的参数按值传入不会随状态重绘，所以文案与高亮都必须在 builder **内部**读 @State，
   * 否则点一次界面还停在旧值（看起来像「按钮没反应」）。
   */
  /**
   * 收藏按钮：与「播放模式」同一写法 —— 图标与颜色在 builder 内部读 @State。
   * 之前把 active / icon 作为 @Builder 参数传入，参数按值传递不随状态重绘，
   * 所以点了不变色（看起来像没收藏成功）。
   */
  @Builder
  favoriteToolButton() {
    Column({ space: 2 }) {
      SymbolGlyph(this.favorite ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'))
        .fontSize(DesignTokens.ICON_M)
        .fontColor([this.favorite ? $r('app.color.primary') : $r('app.color.player_text_secondary_forced')])
      Text($r('app.string.player_favorite')).fontFamily(this.appFontFamily)
        .fontSize(9)
        .fontColor(this.favorite ? $r('app.color.primary') : $r('app.color.player_text_secondary_forced'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.toggleFavorite();
    })
  }
  @Builder
  repeatToolButton() {
    Column({ space: 2 }) {
      // 图标必须随模式切换：不循环 / 单曲循环(repeat_1) / 列表循环(repeat)
      SymbolGlyph(this.repeatIcon())
        .fontSize(DesignTokens.ICON_M)
        .fontColor([this.repeatMode !== 0 ? $r('app.color.player_text_forced') : $r('app.color.player_text_secondary_forced')])
      Text(this.repeatLabel()).fontFamily(this.appFontFamily)
        .fontSize(9)
        .fontColor(this.repeatMode !== 0 ? $r('app.color.player_text_forced') : $r('app.color.player_text_secondary_forced'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.cycleRepeat();
    })
  }
  /**
   * 倍速按钮。
   *
   * 数值标签必须在 builder **内部**读 @State：ArkUI 的 `@Builder` 按值传参时不会随状态重绘，
   * 旧写法 `controlButton(..., this.speed.toFixed(2), ...)` 会出现「原生已经改到 1.50x、
   * 界面还停在 1.00」的假象（用户会以为倍速自己变了；第 40 轮设置页「排序方式」踩过同一个坑）。
   */
  @Builder
  speedButton() {
    Column() {
      Stack() {
        SymbolGlyph($r('sys.symbol.timer'))
          .fontSize(DesignTokens.ICON_XL)
          .fontColor([$r('app.color.player_text_forced')])
      }
      .width(48)
      .height(48)
      .alignContent(Alignment.Center)
      .onClick(() => {
        this.openSpeedSheet();
      })

      Text(this.speed.toFixed(2)).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_FOOTNOTE)
        .fontColor($r('app.color.player_text_secondary_forced'))
        .maxLines(1)
        .height(16)
    }
    .alignItems(HorizontalAlign.Center)
  }

  /** 播放控制行的单个按钮：48vp 图标按钮 + 下方 12fp 数值标签 */
  @Builder
  controlButton(icon: Resource, label: string, onTap: () => void) {
    Column() {
      Stack() {
        SymbolGlyph(icon)
          .fontSize(34)
          .fontColor([$r('app.color.player_text_forced')])
      }
      .width(48)
      .height(48)
      .alignContent(Alignment.Center)
      .onClick(() => {
        onTap();
      })

      Text(label).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_FOOTNOTE)
        .fontColor($r('app.color.player_text_secondary_forced'))
        .maxLines(1)
        .height(16)
    }
    .alignItems(HorizontalAlign.Center)
  }

  /** 描边胶囊按钮（上游 grey_border：8vp 圆角 + 1vp 描边，minWidth 150dp） */
  @Builder
  detailButton(icon: Resource, label: ResourceStr, onTap: () => void) {
    Row({ space: DesignTokens.SPACE_XS }) {
      SymbolGlyph(icon)
        .fontSize(DesignTokens.ICON_M)
        .fontColor([$r('app.color.player_text_secondary_forced')])
      Text(label).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_PARAGRAPH)
        .fontColor($r('app.color.player_text_secondary_forced'))
        .maxLines(1)
    }
    .height(36)
    .constraintSize({ minWidth: 130 })
    .justifyContent(FlexAlign.Center)
    .padding({ left: DesignTokens.SPACE_S, right: DesignTokens.SPACE_S })
    .borderRadius(8)
    .border({ width: 1, color: $r('app.color.divider') })
    .onClick(() => {
      onTap();
    })
  }

  /** 次级操作：图标 + 文本的胶囊按钮 */
  @Builder
  secondaryAction(icon: Resource, label: ResourceStr, onTap: () => void) {
    Row({ space: DesignTokens.SPACE_XS }) {
      SymbolGlyph(icon)
        .fontSize(DesignTokens.ICON_S)
        .fontColor([$r('app.color.player_text_forced')])
      Text(label).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_CAPTION)
        .fontColor($r('app.color.player_text_forced'))
    }
    .height(DesignTokens.HEIGHT_BUTTON_SM)
    .padding({ left: DesignTokens.SPACE_M, right: DesignTokens.SPACE_M })
    .backgroundColor($r('app.color.player_mode_bg_forced'))
    .borderRadius(DesignTokens.RADIUS_CHIP)
    .onClick(() => {
      onTap();
    })
  }

  /** 章节弹层（上游 chapters 对话框） */
  @Builder
  chaptersSheet() {
    Column({ space: DesignTokens.SPACE_S }) {
      Text($r('app.string.player_chapters')).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.player_text_forced'))
        .width('100%')
        .padding({ top: DesignTokens.SPACE_L })

      List({ space: DesignTokens.SPACE_XS }) {
        ForEach(this.chapters, (chapter: Chapter) => {
          ListItem() {
            Row({ space: DesignTokens.SPACE_M }) {
              SymbolGlyph($r('sys.symbol.list_bullet'))
                .fontSize(DesignTokens.ICON_M)
                .fontColor([$r('app.color.player_text_tertiary_forced')])
              Text(chapter.title).fontFamily(this.appFontFamily)
                .fontSize(DesignTokens.FONT_PARAGRAPH)
                .fontColor($r('app.color.player_text_forced'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(DurationUtils.format(chapter.start)).fontFamily(this.appFontFamily)
                .fontSize(DesignTokens.FONT_CAPTION)
                .fontColor($r('app.color.player_text_tertiary_forced'))
            }
            .width('100%')
            .padding(DesignTokens.SPACE_M)
            .backgroundColor($r('app.color.surface_secondary'))
            .borderRadius(DesignTokens.RADIUS_ROW)
            .onClick(() => {
              PlayerManager.seek(chapter.start);
              this.showChaptersSheet = false;
            })
          }
        }, (chapter: Chapter) => chapter.id.toString())
      }
      .height(320)
      .width('100%')
      .scrollBar(BarState.Off)

      Button($r('app.string.dialog_cancel'))
        .width('100%')
        .height(DesignTokens.HEIGHT_BUTTON)
        .fontSize(DesignTokens.FONT_PARAGRAPH)
        .backgroundColor($r('app.color.surface_secondary'))
        .fontColor($r('app.color.player_text_forced'))
        .margin({ bottom: DesignTokens.SPACE_L })
        .onClick(() => {
          this.showChaptersSheet = false;
        })
    }
    .width('100%')
    .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
    .backgroundColor($r('app.color.surface'))
    .borderRadius({ topLeft: DesignTokens.RADIUS_SHEET, topRight: DesignTokens.RADIUS_SHEET })
  }

  /** 节目详情弹层（上游 ItemDescriptionFragment） */
  @Builder
  notesSheet() {
    Column({ space: DesignTokens.SPACE_M }) {
      Text($r('app.string.player_show_notes')).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.player_text_forced'))
        .width('100%')
        .padding({ top: DesignTokens.SPACE_L })

      Scroll() {
        if (this.notesSegments.length === 0) {
          Text($r('app.string.no_shownotes_label')).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_PARAGRAPH)
            .fontColor($r('app.color.player_text_secondary_forced'))
            .width('100%')
        } else {
          // 与单集详情页共用同一段落渲染：保留换行 + 时长内的时间码可点跳转
          ShownotesBody({
            segments: this.notesSegments,
            onTimecode: (timeMs: number) => {
              this.seekToTimecode(timeMs);
            }
          })
        }
      }
      .height(320)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)

      Button($r('app.string.dialog_cancel'))
        .width('100%')
        .height(DesignTokens.HEIGHT_BUTTON)
        .fontSize(DesignTokens.FONT_PARAGRAPH)
        .backgroundColor($r('app.color.surface_secondary'))
        .fontColor($r('app.color.player_text_forced'))
        .margin({ bottom: DesignTokens.SPACE_L })
        .onClick(() => {
          this.showNotesSheet = false;
        })
    }
    .width('100%')
    .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
    .backgroundColor($r('app.color.surface'))
    .borderRadius({ topLeft: DesignTokens.RADIUS_SHEET, topRight: DesignTokens.RADIUS_SHEET })
  }

  /**
   * 倍速弹层（对照上游 VariableSpeedDialog）：显式选择一档，不再「点一次循环一档」。
   *
   * 旧交互的隐患：倍速按钮就在快退左边，误触一次就把当前倍速和**全局默认倍速**一起改掉，
   * 而且档位列表是循环的（2.00x 再点一次绕回 0.50x）——「过一阵自己变慢」有它一份。
   */
  @Builder
  speedSheet() {
    Column({ space: DesignTokens.SPACE_XS }) {
      Text($r('app.string.setting_playback_speed')).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.player_text_forced'))
        .width('100%')
        .padding({ top: DesignTokens.SPACE_L, bottom: DesignTokens.SPACE_S })

      ForEach(PlayerManager.SPEED_PRESETS, (preset: number) => {
        Row({ space: DesignTokens.SPACE_S }) {
          SymbolGlyph(this.isCurrentSpeed(preset)
            ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
            .fontSize(DesignTokens.ICON_L)
            .fontColor([this.isCurrentSpeed(preset)
              ? $r('app.color.player_text_forced') : $r('app.color.player_text_tertiary_forced')])
          Text(preset.toFixed(2) + 'x').fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_SUBTITLE)
            .fontColor($r('app.color.player_text_forced'))
            .layoutWeight(1)
        }
        .width('100%')
        .constraintSize({ minHeight: 48 })
        .onClick(() => {
          this.applySpeed(preset);
        })
      }, (preset: number) => 'speed-' + preset)

      Text(getContext(this).resourceManager.getStringSync($r('app.string.setting_speed'))
        + ' ' + UserPreferences.getDefaultPlaybackSpeed().toFixed(2) + 'x').fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_FOOTNOTE)
        .fontColor($r('app.color.player_text_secondary_forced'))
        .width('100%')
        .padding({ top: DesignTokens.SPACE_S, bottom: DesignTokens.SPACE_S })

      Button($r('app.string.dialog_cancel'))
        .width('100%')
        .height(DesignTokens.HEIGHT_BUTTON)
        .fontSize(DesignTokens.FONT_PARAGRAPH)
        .backgroundColor($r('app.color.surface_secondary'))
        .fontColor($r('app.color.player_text_forced'))
        .margin({ bottom: DesignTokens.SPACE_L })
        .onClick(() => {
          this.showSpeedSheet = false;
        })
    }
    .width('100%')
    .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
    .backgroundColor($r('app.color.surface'))
    .borderRadius({ topLeft: DesignTokens.RADIUS_SHEET, topRight: DesignTokens.RADIUS_SHEET })
  }

  @Builder
  sleepSheet() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 空白区：点击面板以外的区域关闭（不拦截面板自身的点击）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.showSleepSheet = false;
        })

      Column({ space: DesignTokens.SPACE_M }) {
      // 拖拽指示条（系统半模态的视觉语言）
      Row()
        .width(36)
        .height(4)
        .borderRadius(2)
        .backgroundColor($r('app.color.divider'))
        .margin({ top: DesignTokens.SPACE_S })

      // 标题 + 当前倒计时
      Row({ space: DesignTokens.SPACE_S }) {
        SymbolGlyph($r('sys.symbol.moon_fill'))
          .fontSize(DesignTokens.ICON_M)
          .fontColor([$r('app.color.text_secondary')])
        Text($r('app.string.sleep_timer_title')).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        if (this.sleepRemainingMs > 0) {
          Text(this.countdownText()).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_SUBTITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.player_text_forced'))
            .accessibilityText($r('app.string.sleep_timer_remaining'))
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 倒计时进度条：只在计时进行中显示
      if (this.sleepRemainingMs > 0) {
        Progress({
          value: Math.max(0, SleepTimer.getTotalMs() - this.sleepRemainingMs),
          total: Math.max(1, SleepTimer.getTotalMs()),
          type: ProgressType.Linear
        })
          // 长度回到整行宽度；高度为上一次（12vp）的两倍
          .width('100%')
          .height(24)
          // 只用黑白：进度走主文字色（浅色近黑 / 深色近白），轨道走弱化灰
          .color($r('app.color.player_text_forced'))
          .backgroundColor($r('app.color.player_track_forced'))
          .borderRadius(12)
      }

      // 六个预设时长：3 列两行胶囊
      Grid() {
        ForEach(PlayerPage.SLEEP_PRESETS, (minutes: number) => {
          GridItem() {
            this.sleepPreset(minutes)
          }
        }, (minutes: number) => minutes.toString())
      }
      .columnsTemplate('1fr 1fr 1fr')
      .columnsGap(DesignTokens.SPACE_S)
      .rowsGap(DesignTokens.SPACE_S)
      .width('100%')
      .height(2 * DesignTokens.HEIGHT_BUTTON + DesignTokens.SPACE_S + 12)

      // 自定义分钟 + 开始
      Row({ space: DesignTokens.SPACE_S }) {
        TextInput({ text: this.customMinutes, placeholder: $r('app.string.sleep_timer_custom_hint') }).fontFamily(this.appFontFamily)
          .layoutWeight(1)
          .height(DesignTokens.HEIGHT_BUTTON)
          .fontSize(DesignTokens.FONT_PARAGRAPH)
          .type(InputType.Number)
          .backgroundColor($r('app.color.surface_secondary'))
          .borderRadius(DesignTokens.RADIUS_CHIP)
          .padding({ left: DesignTokens.SPACE_M, right: DesignTokens.SPACE_M })
          .onChange((value: string) => {
            this.customMinutes = value;
          })
        Button($r('app.string.sleep_timer_start'))
          .height(DesignTokens.HEIGHT_BUTTON)
          .fontSize(DesignTokens.FONT_PARAGRAPH)
          .backgroundColor($r('app.color.player_text_forced'))
          .fontColor($r('app.color.player_bg_forced'))
          .borderRadius(DesignTokens.RADIUS_CHIP)
          .padding({ left: DesignTokens.SPACE_L, right: DesignTokens.SPACE_L })
          .onClick(() => {
            const minutes: number = Number(this.customMinutes.trim());
            if (Number.isFinite(minutes) && minutes > 0) {
              this.startSleepTimer(minutes);
            }
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 四个开关放进一张圆角卡，用分隔线分开（避免一长串裸行）
      Column() {
        this.sleepToggleRow($r('app.string.sleep_timer_chapter_end'), this.chapterEndToggle, (isOn: boolean) => {
          this.chapterEndToggle = isOn;
        })
        Divider().color($r('app.color.divider')).strokeWidth(0.5)
        this.sleepToggleRow($r('app.string.sleep_timer_fade'), this.fadeToggle, (isOn: boolean) => {
          this.fadeToggle = isOn;
        })
        Divider().color($r('app.color.divider')).strokeWidth(0.5)
        this.sleepToggleRow($r('app.string.sleep_timer_shake_to_reset'), this.shakeToResetToggle, (isOn: boolean) => {
          this.shakeToResetToggle = isOn;
          UserPreferences.setSleepShakeToReset(isOn);
          this.syncShakeListener();
        })
        Divider().color($r('app.color.divider')).strokeWidth(0.5)
        this.sleepToggleRow($r('app.string.sleep_timer_vibrate'), this.vibrateToggle, (isOn: boolean) => {
          this.vibrateToggle = isOn;
          UserPreferences.setSleepVibrate(isOn);
        })
      }
      .width('100%')
      .backgroundColor($r('app.color.surface_secondary'))
      .borderRadius(DesignTokens.RADIUS_ROW)
      .clip(true)

      // 底部动作：停止（破坏性）/ 取消
      Row({ space: DesignTokens.SPACE_M }) {
        Button($r('app.string.sleep_timer_stop'))
          .layoutWeight(1)
          .height(DesignTokens.HEIGHT_BUTTON)
          .fontSize(DesignTokens.FONT_PARAGRAPH)
          .backgroundColor($r('app.color.error_container'))
          .fontColor($r('app.color.error'))
          .borderRadius(DesignTokens.RADIUS_CHIP)
          .enabled(this.sleepRemainingMs > 0)
          .opacity(this.sleepRemainingMs > 0 ? 1 : 0.45)
          .onClick(() => {
            SleepTimer.stop();
            ShakeDetector.stop();
            this.sleepRemainingMs = 0;
            this.sleepRemainingText = '';
            this.showSleepSheet = false;
          })
        Button($r('app.string.dialog_cancel'))
          .layoutWeight(1)
          .height(DesignTokens.HEIGHT_BUTTON)
          .fontSize(DesignTokens.FONT_PARAGRAPH)
          .backgroundColor($r('app.color.surface_secondary'))
          .fontColor($r('app.color.text_primary'))
          .borderRadius(DesignTokens.RADIUS_CHIP)
          .onClick(() => {
            this.showSleepSheet = false;
          })
      }
      .width('100%')
      .margin({ top: DesignTokens.SPACE_XS, bottom: DesignTokens.SPACE_L })
    }
    .width('100%')
      .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN, bottom: DesignTokens.SPACE_L })
      .backgroundColor($r('app.color.surface'))
      .borderRadius({ topLeft: DesignTokens.RADIUS_SHEET, topRight: DesignTokens.RADIUS_SHEET })
      // 吞掉面板内的点击：否则点击会穿透到下面的遮罩，导致一按预设就关闭面板
      .onClick(() => {
      })
      // 左滑 / 右滑关闭（与系统半模态手势一致）
      .gesture(
        PanGesture({ direction: PanDirection.Horizontal, distance: 24 })
          .onActionEnd((event: GestureEvent) => {
            if (Math.abs(event.offsetX) > 60) {
              this.showSleepSheet = false;
            }
          })
      )
    }
    .width('100%')
    .height('100%')
  }

  /** 开关行：标题 + 右侧 Switch，整行可点 */
  @Builder
  sleepToggleRow(label: ResourceStr, isOn: boolean, onChange: (isOn: boolean) => void) {
    Row({ space: DesignTokens.SPACE_S }) {
      Text(label).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_PARAGRAPH)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor($r('app.color.player_text_forced'))
        .onChange((value: boolean) => {
          onChange(value);
        })
    }
    .width('100%')
    .height(52)
    .padding({ left: DesignTokens.SPACE_M, right: DesignTokens.SPACE_M })
  }

  @Builder
  sleepPreset(minutes: number) {
    Text(minutes.toString() + 'm').fontFamily(this.appFontFamily)
      .fontSize(DesignTokens.FONT_PARAGRAPH)
      .fontWeight(this.isActivePreset(minutes) ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.isActivePreset(minutes) ? $r('app.color.player_bg_forced') : $r('app.color.text_primary'))
      .textAlign(TextAlign.Center)
      .width('100%')
      .height(DesignTokens.HEIGHT_BUTTON)
      .backgroundColor(this.isActivePreset(minutes) ? $r('app.color.player_text_forced') : $r('app.color.surface_secondary'))
      .borderRadius(DesignTokens.RADIUS_CHIP)
      .onClick(() => {
        this.startSleepTimer(minutes);
      })
  }

  /** 当前计时是否正好等于这个预设（用于高亮） */
  private isActivePreset(minutes: number): boolean {
    const remaining: number = this.sleepRemainingMs;
    if (remaining <= 0) {
      return false;
    }
    // 允许 1s 误差：倒计时每秒递减，用区间判断避免高亮闪烁
    return remaining > (minutes * 60 * 1000 - 1500) && remaining <= minutes * 60 * 1000;
  }

  /** mm:ss / h:mm:ss */
  private countdownText(): string {
    const totalSeconds: number = Math.max(0, Math.ceil(this.sleepRemainingMs / 1000));
    const hours: number = Math.floor(totalSeconds / 3600);
    const minutes: number = Math.floor((totalSeconds % 3600) / 60);
    const seconds: number = totalSeconds % 60;
    const mm: string = minutes < 10 ? '0' + minutes : minutes.toString();
    const ss: string = seconds < 10 ? '0' + seconds : seconds.toString();
    return hours > 0 ? hours.toString() + ':' + mm + ':' + ss : mm + ':' + ss;
  }

  /**
   * 从队列页返回时强制刷新一次：用户可能在队列里换了正在播放的单集，
   * 回到播放器必须立即显示新的封面 / 标题 / 简介，而不是靠 1 秒定时器慢慢追上。
   */
  onPageShow(): void {
    this.refresh();
  }

  aboutToAppear(): void {

    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const config: Configuration | undefined = ctx.config as Configuration;
      this.dark = config !== undefined
        && config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (error) {
      this.dark = false;
    }
    this.speed = PlayerManager.getSpeed();
    this.repeatMode = UserPreferences.getRepeatMode();
    this.chapterEndToggle = UserPreferences.getSleepStopAtChapterEnd();
    this.fadeToggle = UserPreferences.getSleepFadeOut();
    this.shakeToResetToggle = UserPreferences.getSleepShakeToReset();
    this.vibrateToggle = UserPreferences.getSleepVibrate();
    try {
      const info: display.Display = display.getDefaultDisplaySync();
      const width: number = px2vp(info.width) - 64;
      this.coverSize = width > 280 ? 280 : (width < 160 ? 160 : width);
    } catch (error) {
      this.coverSize = 240;
    }
    this.refresh();
    // 订阅播放位置（播放器每 500ms 发布一次）：进度条按真实位置刷新，
    // 只靠 1s 定时器采样会出现「0 秒直接跳到 2 秒」这种跳秒。
    this.positionToken = EventHub.subscribe(EventType.PLAYBACK_POSITION, (data: object) => {
      const payload: Record<string, number> = data as Record<string, number>;
      const time: number | undefined = payload['time'];
      if (time === undefined || time < 0) {
        return;
      }
      // 拖动后的保护窗口内以用户拖到的位置为准
      if (Date.now() < this.optimisticUntil) {
        return;
      }
      this.playPosition = time;
      this.lastPositionEventAt = Date.now();
      this.refreshMarkedState();
      const duration: number | undefined = payload['duration'];
      if (duration !== undefined && duration > 0) {
        this.duration = duration;
      }
    });
    // 订阅睡眠定时器剩余时间，给用户可见反馈
    this.sleepToken = EventHub.subscribe(EventType.SLEEP_TIMER_UPDATED, (data: object) => {
      const remaining: number | undefined = (data as Record<string, number>)['remainingMs'];
      this.sleepRemainingMs = remaining === undefined ? 0 : Math.max(0, remaining);
      if (remaining === undefined || remaining <= 0) {
        this.sleepRemainingText = SleepTimer.isPendingChapterEnd()
          ? getContext(this).resourceManager.getStringSync($r('app.string.sleep_timer_waiting_chapter'))
          : '';
        return;
      }
      const minutes: number = Math.floor(remaining / 60000);
      const seconds: number = Math.floor((remaining % 60000) / 1000);
      this.sleepRemainingText = getContext(this).resourceManager.getStringSync($r('app.string.sleep_timer_remaining'))
        + ' ' + minutes + 'm ' + seconds + 's';
    });
    if (this.timerId < 0) {
      this.timerId = setInterval(() => {
        this.refresh();
        // 进度落盘（内部 5s 节流），支持强杀后恢复播放位置
        ProgressPersister.save();
        this.checkChapterEndSleep();
      }, 1000);
    }
    // 摇一摇重置倒计时：只在「开关打开 且 定时器活跃」时订阅加速度计（见 syncShakeListener）
    this.syncShakeListener();
  }

  aboutToDisappear(): void {

    if (this.markToastTimerId >= 0) {
      clearTimeout(this.markToastTimerId);
      this.markToastTimerId = -1;
    }
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    if (this.sleepToken >= 0) {
      EventHub.unsubscribeToken(this.sleepToken);
      this.sleepToken = -1;
    }
    if (this.positionToken >= 0) {
      EventHub.unsubscribeToken(this.positionToken);
      this.positionToken = -1;
    }
    ShakeDetector.stop();
    // 离开播放页时强制保存一次进度
    ProgressPersister.save(true);
  }

  /** 已加载章节的 feedItemId：避免每秒一次的 tick 反复查库 */
  private chaptersForItemId: number = -1;
  /** 播放位置事件订阅 token */
  private positionToken: number = -1;
  /** 标记提示的自动消失定时器 */
  private markToastTimerId: number = -1;
  /** 最近一次播放位置事件的到达时间：1s 定时器不再覆盖事件给的值，避免两路数据打架 */
  private lastPositionEventAt: number = 0;
  /** 防重入：refresh 里有 await，1s tick 可能在上一轮未完成时再次进来 */
  private refreshing: boolean = false;

  async refresh(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    try {
      await this.refreshInner();
    } finally {
      this.refreshing = false;
    }
  }

  private async refreshInner(): Promise<void> {
    // 睡眠定时倒计时：每秒同步一次剩余毫秒（进度条 / 高亮 / 文本都依赖它）
    this.syncSleepCountdown();
    const playable: Playable | undefined = PlayerManager.getCurrent();
    if (playable !== undefined) {
      this.title = playable.title;
      this.feedTitle = playable.feedTitle;
      this.coverUrl = playable.imageUrl;
      if (playable.feedItemId > 0) {
        // 章节只在换集时读一次：这条路径原本挂在 1s 定时器上，
        // 等于播放器页常驻时每秒一次数据库查询（明显的性能缺陷）。
        if (this.chaptersForItemId !== playable.feedItemId) {
          this.chaptersForItemId = playable.feedItemId;
          try {
            this.chapters = await ChapterRepository.listByFeedItem(playable.feedItemId);
          } catch (error) {
            this.chapters = [];
          }
        }
        if (this.feedItemId !== playable.feedItemId) {
          this.feedItemId = playable.feedItemId;
          await this.loadItem(playable.feedItemId);
        }
      } else {
        this.chapters = [];
        this.chaptersForItemId = -1;
      }
    }
    this.status = PlayerManager.getStatus();
    // 位置事件的优先级更高：500ms 事件刚刚到过时，1s 定时器不再写 playPosition，
    // 否则「事件给真实值、定时器给 getCurrentTime()（可能还是旧 pending）」会互相打架。
    const eventFresh: boolean = Date.now() - this.lastPositionEventAt < 800;
    const livePosition: number = PlayerManager.getCurrentTime();
    // 拖动后的 3 秒内，如果播放器上报的位置与用户拖到的位置仍有明显差距，保留乐观值
    const protecting: boolean = Date.now() < this.optimisticUntil
      && Math.abs(livePosition - this.playPosition) > 800;
    // 拖动中（含暂停态拖到一半）绝不覆盖，否则手指还按着就被拽回去
    if (!this.dragging && !protecting && !eventFresh) {
      this.playPosition = livePosition;
    }
    const liveDuration: number = PlayerManager.getDuration();
    if (liveDuration > 0) {
      this.duration = liveDuration;
    }
    this.speed = PlayerManager.getSpeed();
  }

  /** 载入单集描述与收藏状态（节目详情弹层 / 工具栏星标） */
  async loadItem(feedItemId: number): Promise<void> {
    try {
      const item: FeedItem | undefined = await EpisodeRepository.getById(feedItemId);
      const description: string = item === undefined ? '' : item.description;
      const duration: number = item === undefined || item.media === undefined ? 0 : item.media.duration;
      this.notesSegments = ShownotesText.segments(description, duration);
      // 播放器还没就绪（未 prepare）时 getDuration() 是 0 —— 此时用库里的时长兜底，
      // 否则 duration=0 会让进度条直接拒绝拖动（暂停态尤其明显）。
      if (this.duration <= 0 && duration > 0) {
        this.duration = duration;
      }
      this.favorite = await FavoritesRepository.isFavorite(feedItemId);
      // 兜底：播放对象未带封面时（旧播放路径）用库里的单集封面
      if (this.coverUrl === '' && item !== undefined && item.imageUrl !== '') {
        this.coverUrl = item.imageUrl;
      }
    } catch (error) {
      this.notesSegments = [];
      this.favorite = false;
    }
  }

  /**
   * 点按正文里的时间码（上游 `ShownotesWebView.setTimecodeSelectedListener`）：
   * 播放页上的正文永远属于当前播放项，直接 seek；播放器空载时不响应。
   */
  seekToTimecode(timeMs: number): void {
    if (PlayerManager.getCurrent() === undefined) {
      this.message = getContext(this).resourceManager
        .getStringSync($r('app.string.play_this_to_seek_position_message'));
      return;
    }
    PlayerManager.seek(timeMs);
  }

  async toggleFavorite(): Promise<void> {
    if (this.feedItemId <= 0) {
      return;
    }
    try {
      if (this.favorite) {
        await FavoritesRepository.remove(this.feedItemId);
      } else {
        const item: FeedItem | undefined = await EpisodeRepository.getById(this.feedItemId);
        await FavoritesRepository.add(this.feedItemId, item === undefined ? 0 : item.feedId);
      }
      this.favorite = !this.favorite;
      // 不再在封面上方弹「已保存」：状态由图标颜色表达，避免突兀的提示条
    } catch (error) {
      this.message = (error as Error).message;
    }
  }


  /** 下一集：从队列取当前项之后的条目（上游 butSkip） */
  async skipToNext(): Promise<void> {
    try {
      await QueueEngine.load();
      const next: FeedItem | undefined = QueueEngine.nextItem();
      if (next === undefined || next.media === undefined) {
        this.message = getContext(this).resourceManager.getStringSync($r('app.string.placeholder_queue'));
        return;
      }
      const playable: Playable | undefined = await QueueEngine.toPlayable(next);
      if (playable === undefined) {
        return;
      }
      await PlayerManager.load(playable, next.media.position, true);
    } catch (error) {
      this.message = (error as Error).message;
    }
  }

  /** 计时到点且勾选"本章结束停止"时，在章节边界暂停 */
  checkChapterEndSleep(): void {
    if (!SleepTimer.isPendingChapterEnd()) {
      return;
    }
    const end: number = this.currentChapterEnd();
    if (end < 0 || this.playPosition >= end) {
      SleepTimer.expireNow();
    }
  }

  /** 当前所在章节的结束时间；无章节返回 -1，最后一章返回音频结尾 */
  currentChapterEnd(): number {
    if (this.chapters.length === 0) {
      return -1;
    }
    for (let i: number = 0; i < this.chapters.length; i++) {
      const start: number = this.chapters[i].start;
      const nextStart: number = i + 1 < this.chapters.length ? this.chapters[i + 1].start : this.duration;
      if (this.playPosition >= start && this.playPosition < nextStart) {
        return nextStart;
      }
    }
    return this.duration;
  }

  openSleepSheet(): void {
    this.customMinutes = UserPreferences.getSleepTimerMinutes().toString();
    this.showSleepSheet = true;
  }

  /** 每秒把睡眠定时的剩余毫秒同步到界面（事件节流时也能秒级跳动） */
  private syncSleepCountdown(): void {
    const remaining: number = SleepTimer.getRemainingMs();
    if (remaining !== this.sleepRemainingMs) {
      this.sleepRemainingMs = remaining;
    }
  }

  /** 分享用的时间文本：mm:ss 或 h:mm:ss */
  private shareTimeText(ms: number): string {
    const total: number = Math.max(0, Math.floor(ms / 1000));
    const h: number = Math.floor(total / 3600);
    const m: number = Math.floor((total % 3600) / 60);
    const s: number = total % 60;
    const mm: string = m < 10 ? '0' + m : m.toString();
    const ss: string = s < 10 ? '0' + s : s.toString();
    return h > 0 ? h.toString() + ':' + mm + ':' + ss : m.toString() + ':' + ss;
  }

  /**
   * 分享当前单集：调起系统分享面板（ShareKit）。
   * 只分享文本（标题 + 播客名 + 音频链接），不读取权限、不上传本地文件。
   */
  private shareCurrentEpisode(): void {
    const playable: Playable | undefined = PlayerManager.getCurrent();
    if (playable === undefined || playable.title === '') {
      this.message = getContext(this).resourceManager.getStringSync($r('app.string.player_share_empty'));
      return;
    }
    const link: string = playable.downloadUrl !== '' ? playable.downloadUrl : playable.localFileUrl;
    let content: string = playable.title;
    if (playable.feedTitle !== '') {
      content += ' · ' + playable.feedTitle;
    }
    // ① 片段分享：带上当前播放位置，方便对方从同一处开始听
    const positionSec: number = Math.max(0, Math.floor(this.playPosition / 1000));
    if (link !== '') {
      content += '\n' + link;
    }
    if (positionSec > 0) {
      content += '\n从 ' + this.shareTimeText(this.playPosition) + ' 开始听';
      if (link !== '') {
        // 常见客户端认识的片段参数；不改变原链接本身，只是拼在末尾供识别
        content += '\n' + link + (link.indexOf('#') >= 0 ? '' : '#t=' + positionSec.toString());
      }
    }
    try {
      const data: systemShare.SharedData = new systemShare.SharedData({
        utd: utd.UniformDataType.PLAIN_TEXT,
        content: content
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      controller.show(getContext(this) as common.UIAbilityContext, {
        previewMode: systemShare.SharePreviewMode.DETAIL,
        selectionMode: systemShare.SelectionMode.SINGLE
      });
    } catch (error) {
      this.message = getContext(this).resourceManager.getStringSync($r('app.string.player_share_failed'))
        + (error as Error).message;
    }
  }

  startSleepTimer(minutes: number): void {
    if (minutes <= 0) {
      return;
    }
    UserPreferences.setSleepTimerMinutes(minutes);
    UserPreferences.setSleepStopAtChapterEnd(this.chapterEndToggle);
    UserPreferences.setSleepFadeOut(this.fadeToggle);
    // 不自动关闭面板：用户要能直接看到倒计时开始跳动
    SleepTimer.start(minutes, () => {
      this.onSleepTimerExpire();
    }, this.chapterEndToggle, this.fadeToggle);
    // 摇一摇重置倒计时（仅在开关打开且定时器活跃时监听加速度计）
    this.syncShakeListener();
  }

  /** 摇一摇：按上次选择的时长重新计时 */
  restartSleepTimer(): void {
    const minutes: number = UserPreferences.getSleepTimerMinutes();
    SleepTimer.start(minutes, () => {
      this.onSleepTimerExpire();
    }, this.chapterEndToggle, this.fadeToggle);
    this.sleepRemainingText = getContext(this).resourceManager.getStringSync($r('app.string.sleep_timer_reset'));
  }

  /**
   * 睡眠定时到点：**先停摇一摇监听再暂停播放**。
   *
   * 定时器自然到点后页面不会重建，若不在这里停掉，加速度计会一直订阅到用户手动点「停止睡眠定时」
   * 或离开播放页 —— 白耗电，也与「只在定时活跃期间监听」的语义不符。
   */
  private onSleepTimerExpire(): void {
    ShakeDetector.stop();
    PlayerManager.pause();
  }

  /** 按「摇一摇重置」开关 + 定时器状态，同步加速度计订阅（开关关掉时立即释放传感器） */
  private syncShakeListener(): void {
    if (this.shakeToResetToggle && SleepTimer.isActive()) {
      ShakeDetector.start(() => {
        this.restartSleepTimer();
      });
      return;
    }
    ShakeDetector.stop();
  }

  /** 播放位置文本：DurationUtils.format 对 0 返回空串，这里补成 0:00，避免出现 "PAUSED   / 0:05" */
  positionText(): string {
    const text: string = DurationUtils.format(this.playPosition);
    return text === '' ? '0:00' : text;
  }

  /** 打开倍速弹层：先同步一次真实生效值，避免弹层里勾选项与播放器不一致 */
  openSpeedSheet(): void {
    this.speed = PlayerManager.getSpeed();
    this.showSpeedSheet = true;
  }

  /**
   * 选择倍速：立即作用于当前播放，并写入全局默认倍速（与上游 VariableSpeedDialog 一致，
   * 「播放页选过就记住」；改默认值的显式入口仍在设置页，弹层里会显示当前默认值）。
   */
  applySpeed(speed: number): void {
    PlayerManager.setSpeed(speed, 'player-page');
    UserPreferences.setDefaultPlaybackSpeed(speed);
    this.speed = speed;
    this.showSpeedSheet = false;
  }

  /** 是否当前档位（都是同一份 SPEED_PRESETS 里的值，浮点比较留一点余量） */
  isCurrentSpeed(preset: number): boolean {
    return Math.abs(this.speed - preset) < 0.001;
  }

  /** 已播放进度的百分比（0–100）：三种状态下都用同一个值驱动同一条进度条 */
  progressPercent(): number {
    if (this.duration <= 0 || this.playPosition <= 0) {
      return 0;
    }
    const percent: number = this.playPosition * 100 / this.duration;
    return percent > 100 ? 100 : percent;
  }

  /** 拖动指示器的位置百分比（限制在轨道内） */
  dragPercent(): number {
    if (this.trackWidth <= 0) {
      return 0;
    }
    const percent: number = this.dragX * 100 / this.trackWidth;
    return Math.max(0, Math.min(100, percent));
  }

  /** 拖动时左下角显示预览时间（不改变真实播放进度，松手才 seek） */
  dragTimeText(): string {
    if (this.trackWidth <= 0 || this.duration <= 0) {
      return this.positionText();
    }
    const ratio: number = Math.max(0, Math.min(1, this.dragX / this.trackWidth));
    return DurationUtils.format(Math.round(ratio * this.duration));
  }

  /** 按横向位置跳转播放进度 */
  /** 时间文案：0/未知时用占位，避免 DurationUtils.format 返回空串导致文字「消失」 */
  private clockText(ms: number, fallback: string): string {
    if (ms === undefined || ms === null || !Number.isFinite(ms) || ms <= 0) {
      return fallback;
    }
    const text: string = DurationUtils.format(ms);
    return text === '' ? fallback : text;
  }

  seekByRatio(x: number): void {
    if (this.trackWidth <= 0) {
      return;
    }
    if (this.duration <= 0) {
      // 时长未知（播放器未 prepare 且库里没有时长）：无法换算，保持不跳转
      return;
    }
    const ratio: number = Math.max(0, Math.min(1, x / this.trackWidth));
    const target: number = Math.round(ratio * this.duration);
    // 先更新本地状态：暂停时也立刻看到进度条与时间变化
    this.playPosition = target;
    this.optimisticUntil = Date.now() + 3000;
    PlayerManager.seek(target);
  }
  /** 打开当前单集所属播客的详情页（播放器只持有单集，需反查 feedId） */
  async openFeedDetail(): Promise<void> {
    if (this.feedItemId <= 0) {
      return;
    }
    try {
      const item: FeedItem | undefined = await EpisodeRepository.getById(this.feedItemId);
      if (item === undefined || item.feedId <= 0) {
        return;
      }
      ProgressPersister.save(true);
      router.pushUrl({ url: 'pages/FeedDetailPage', params: { feedId: item.feedId } });
    } catch (error) {
      this.message = (error as Error).message;
    }
  }
  cycleRepeat(): void {
    this.repeatMode = (this.repeatMode + 1) % 3;
    UserPreferences.setRepeatMode(this.repeatMode);
  }

  /**
   * 播放模式对应的图标（三种模式视觉上必须能区分）：
   * 0 不循环 = repeat_slash（带斜杠）/ 1 单曲循环 = repeat_1 / 2 列表循环 = repeat
   * 图标在 builder 内部经此方法求值，点击后随 @State 重绘。
   */
  repeatIcon(): Resource {
    if (this.repeatMode === 1) {
      return $r('sys.symbol.repeat_1');
    }
    if (this.repeatMode === 2) {
      return $r('sys.symbol.repeat');
    }
    return $r('sys.symbol.repeat_slash');
  }
  repeatLabel(): ResourceStr {
    if (this.repeatMode === 1) {
      return $r('app.string.repeat_one');
    }
    if (this.repeatMode === 2) {
      return $r('app.string.repeat_all');
    }
    return $r('app.string.repeat_off');
  }
}
