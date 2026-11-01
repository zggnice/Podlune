import router from '@ohos.router';
import { DesignTokens } from '../common/DesignTokens';
import { FeedCover } from './FeedCover';
import { GlassSurface } from './GlassSurface';

/**
 * 悬浮迷你播放条（液态玻璃胶囊）。
 *
 * 一行三区：
 * - 左：封面（40vp，圆角 12）+ 两行文字（单集标题 Medium + 订阅名次要色单行）；
 * - 右：播放/暂停圆钮（40vp，浅色圆底 + 主色图标）+「打开播放页」圆钮；
 * - 底：3vp 进度条贴住胶囊下沿，读出「已听比例」。
 *
 * 胶囊与底栏同宽、同一套自适应玻璃（背景模糊 + 提亮 + 淡染色），高度与底栏一致（58vp）。
 */
@Component
export struct MiniPlayer {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  @Prop title: string = '';
  @Prop feedTitle: string = '';
  /** 当前播放单集封面（单集封面 / 播客封面，来自 Playable.imageUrl） */
  @Prop imageUrl: string = '';
  @Prop playing: boolean = false;
  /** 正在加载音频：图标位置显示菊花，避免「点了没反应」的观感 */
  @Prop loading: boolean = false;
  @Prop show: boolean = false;
  @Prop progress: number = 0;
  /** 低版本系统退回实色底（无玻璃） */
  @Prop floating: boolean = true;
  /** 条形高度：展开 44vp，折叠时与圆钮同高（58vp），由外壳按折叠进度传入 */
  @Prop barHeight: number = DesignTokens.HEIGHT_FLOAT_PLAYER;

  onToggle: () => void = () => {
  };

  build() {
    if (this.show) {
      if (this.floating) {
        // 与底部导航栏完全相同的玻璃参数（nav_bar_fill + blur 32），两者通透感一致
      GlassSurface({
        barHeight: this.barHeight,
        radius: this.barHeight / 2,
        blurRadius: 32,
        tint: $r('app.color.nav_bar_fill'),
        stroke: $r('app.color.nav_bar_stroke')
      }) {
          this.playerContent()
        }
      } else {
        Row() {
          this.playerContent()
        }
        .width('100%')
        .height(this.barHeight)
        .borderRadius(this.barHeight / 2)
        .backgroundColor($r('app.color.player_toolbar'))
      }
    }
  }

  @Builder
  playerContent() {
    Stack({ alignContent: Alignment.Bottom }) {
      Row({ space: DesignTokens.SPACE_M }) {
        FeedCover({
          imageUrl: this.imageUrl,
          coverSize: 32,
          radius: 10,
          placeholderColor: $r('app.color.cover_placeholder')
        })

        Column({ space: 2 }) {
          Text(this.title).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_SUBTITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.player_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.feedTitle).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_FOOTNOTE)
            .fontColor($r('app.color.player_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        // 播放 / 暂停：浅色圆底 + 主色图标（比实心大圆钮更轻、更接近系统）
        Stack() {
          if (this.loading) {
            // 加载中：菊花替换播放图标，避免「点了没反应」的观感
            LoadingProgress()
              .width(18)
              .height(18)
              .color($r('app.color.player_text'))
          } else {
            SymbolGlyph(this.playing ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
              .fontSize(18)
              .fontColor([$r('app.color.player_text')])
          }
        }
        .width(32)
        .height(32)
        .borderRadius(16)
        .backgroundColor($r('app.color.player_chip'))
        .onClick(() => {
          this.onToggle();
        })

        // 打开播放页
        Stack() {
          SymbolGlyph($r('sys.symbol.chevron_forward'))
            .fontSize(DesignTokens.ICON_M)
            .fontColor([$r('app.color.player_text')])
        }
        .width(30)
        .height(30)
        .borderRadius(15)
        .onClick(() => {
          router.pushUrl({ url: 'pages/PlayerPage' });
        })
      }
      .width('100%')
      .height(this.barHeight)
      .padding({ left: DesignTokens.SPACE_S, right: DesignTokens.SPACE_XS })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        router.pushUrl({ url: 'pages/PlayerPage' });
      })

    }
    .width('100%')
    .height(this.barHeight)
  }
}
