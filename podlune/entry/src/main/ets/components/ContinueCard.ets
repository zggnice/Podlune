import common from '@ohos.app.ability.common';
import { PressLight } from '../common/PressLight';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { Configuration } from '@ohos.app.ability.Configuration';
import { HtmlCleaner } from '../utils/HtmlCleaner';
import { FeedCover } from './FeedCover';

/**
 * 待播清单大卡（严格对齐参考图）。
 *
 * 卡片比例 ≈ 1 : 1.33（竖长），视觉上分两段：
 * - **上半段**：单集封面，占卡片高度约 74%；
 * - **下半段**：模糊信息区，占约 26%，底色取自同一张封面的模糊副本（放大裁切）、
 *   再压一层半透明的封面主色，因此和上方封面同色系、过渡自然；
 * - 信息区自上而下：订阅头像小标签 → 日期 → 标题（最多 3 行）→ 摘要（最多 1 行）→
 *   底部「播放图标 + 进度条 + 剩余时长」胶囊 + 「更多」三点。
 *
 * 手势：单击 = 单集详情；长按 = 操作菜单（同一手势族按按压时长裁决）。
 */
@Component
export struct ContinueCard {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  @Prop title: string = '';
  @Prop dateText: string = '';
  @Prop summaryText: string = '';
  /** 剩余时长文本 */
  @Prop remainingText: string = '';
  /** 播放进度 0–100 */
  @Prop progress: number = 0;
  @Prop imageUrl: string = '';
  /** 订阅封面（信息区左上角小标签用） */
  @Prop feedImageUrl: string = '';
  @Prop cardWidth: number = 220;
  @Prop playing: boolean = false;
  onTap: () => void = () => {
  };
  onMore: () => void = () => {
  };

  /** 卡片高宽比（参考图 614×817 ≈ 1.33） */
  private readonly aspect: number = 1.42;
  /** 模糊玻璃从卡片高度的哪个位置开始淡出（0.52 ≈ 封面中后段开始，到底部收实） */
  private readonly glassStart: number = 0.52;
  /** 玻璃层对背后封面的模糊半径 */
  /**
   * 毛玻璃模糊半径。原来是 24：整卡面积的 backdropBlur 在滚动时每帧都要重新采样背景，
   * 是首页横滑最贵的一笔开销。降到 10 后观感几乎不变（下方还有一层深色 alpha 渐变兜底），
   * 但每帧的采样代价明显下降。
   */
  private readonly glassBlur: number = 6;

  /**
   * 当前是否深色模式（深色沿用原来的整卡压暗，不改动）。
   * 应用内主题由 EntryAbility 通过 setColorMode 落地，这里读的是最终生效的配置。
   */
  private isDark(): boolean {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    // Configuration 由 @ohos.app.ability.Configuration 提供，从 ctx.config 读取当前生效的配色模式
    const config: Configuration | undefined = ctx.config as Configuration;
    return config !== undefined
      && config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  /** 摘要：去标签 + 压空白 + 截断 */
  static summaryOf(description: string, maxLength: number = 40): string {
    if (description === '') {
      return '';
    }
    const plain: string = HtmlCleaner.stripHtml(description).replace(/\s+/g, ' ').trim();
    return plain.length > maxLength ? plain.substring(0, maxLength) + '…' : plain;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ------------------------------------------------ 底层：单集封面铺满整张卡
      Column() {
        FeedCover({
          imageUrl: this.imageUrl,
          coverSize: this.cardWidth,
          radius: 0,
          placeholderColor: $r('app.color.cover_placeholder'),
          // 背景必须铺满整张 1.42 的卡片：1:1 封面按 Cover 等比裁切，不拉伸。
          // 模糊直接作用在图片上：静态内容模糊可复用，比 backdropBlur 每帧采样背景便宜得多。
          fillParent: true,
          contentBlur: this.isDark() ? this.glassBlur : this.glassBlur + 10
        })
      }
      .width('100%')
      .height('100%')

      // ------------------------------------------------ 中层：整卡统一虚化 + 压暗
      //
      // 1:1 的封面通过 FeedCover 的 ImageFit.Cover 铺满 1.42:1 的卡片（等比放大后居中裁切，
      // 不拉伸、不补白）；这一层对**整张背景**做一次均匀模糊，不切片、不分带，
      // 所以不会出现「中部模糊条」；底部只压暗、不掺白，颜色完全延续封面本身。
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: this.isDark()
            ? [
              ['#00000000', 0.0],
              ['#00000000', 0.36],
              ['#5C000000', 0.58],
              ['#A6000000', 0.80],
              ['#C4000000', 1.0]
            ]
            : [
              ['#00000000', 0.0],
              ['#00000000', 0.30],
              ['#1F000000', 0.52],
              ['#4D000000', 0.76],
              ['#85000000', 1.0]
            ]
        })
        .hitTestBehavior(HitTestMode.Transparent)

      // ------------------------------------------------ 上层：内容（信息区贴底，标签在信息区上方）
      Column() {
        Blank()
          .layoutWeight(1)

        this.infoContent()
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width(this.cardWidth)
    .height(this.cardWidth * this.aspect)
    .borderRadius(20)
    .visualEffect(PressLight.ambient())
    .clip(true)
    .backgroundColor($r('app.color.surface_container'))
    .gesture(
      TapGesture({ count: 1 }).onAction(() => {
        this.onTap();
      })
    )
    .gesture(
      LongPressGesture({ repeat: false, duration: 500 }).onAction(() => {
        this.onMore();
      })
    )
  }
  /** 信息区内容：标签 / 日期 / 标题 / 摘要，底部固定一行胶囊（不参与 flex 压缩） */
  @Builder
  infoContent() {
    Column({ space: 2 }) {
      // 订阅头像标签：放在信息区最上方，尺寸放大到 52vp
      if (this.feedImageUrl !== '') {
        FeedCover({
          imageUrl: this.feedImageUrl,
          coverSize: 46,
          radius: 12,
          placeholderColor: $r('app.color.cover_text_bg')
        })
      }

      Text(this.dateText).fontFamily(this.appFontFamily)
        .fontSize(11)
        .fontColor($r('app.color.card_on_scrim_secondary'))
        .maxLines(1)
        .margin({ top: 2 })

      Text(this.title).fontFamily(this.appFontFamily)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.card_on_scrim_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(17)

      if (this.summaryText !== '') {
        Text(this.summaryText).fontFamily(this.appFontFamily)
          .fontSize(11)
          .fontColor($r('app.color.card_on_scrim_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      // 底部一行：固定高度，保证一定露出
      Row() {
        Row({ space: 6 }) {
          // 进度条左侧的播放/暂停：跟着「本卡片是否正在播放」切换
          SymbolGlyph(this.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
            .fontSize(10)
            .fontColor([$r('app.color.card_pill_fg')])
          Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
            .width(40)
            .height(3)
            .color($r('app.color.card_pill_fg'))
            .backgroundColor($r('app.color.card_pill_bg'))
          Text(this.remainingText).fontFamily(this.appFontFamily)
            .fontSize(11)
            .fontColor($r('app.color.card_pill_fg'))
            .maxLines(1)
            // 固定宽度 + 等宽数字：秒数跳动时不推挤进度条
            .width(44)
            .textAlign(TextAlign.Center)
        }
        .height(24)
        .padding({ left: 8, right: 10 })
        .borderRadius(12)
        .backgroundColor($r('app.color.card_pill_bg'))
        .alignItems(VerticalAlign.Center)

        Blank()

        SymbolGlyph($r('sys.symbol.ellipsis_circle'))
          .fontSize(17)
          .fontColor([$r('app.color.card_pill_fg')])
          .onClick(() => {
            this.onMore();
          })
      }
      .width('100%')
      .height(24)
      .margin({ top: 4 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: 14, right: 12, bottom: 14 })
    .alignItems(HorizontalAlign.Start)
  }
}