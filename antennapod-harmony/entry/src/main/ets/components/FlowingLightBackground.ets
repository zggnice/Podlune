import { DesignTokens } from '../common/DesignTokens';
import common from '@ohos.app.ability.common';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { Configuration } from '@ohos.app.ability.Configuration';

/**
 * 播放器背景（华为音乐风格：模糊渐变）。
 *
 * 结构（Stack 自下而上绘制）：
 *   ① 底层：专辑封面 `Image` 铺满（objectFit Cover，降采样解码）
 *   ② 封面自身做模糊，不使用带主题染色的背景材质，避免深色模式再次压暗。
 *   ③ 顶层：`linearGradient` 渐变遮罩（上透、下暗），保证文字与控件可读
 *   ④ 内容：由 PlayerPage 叠在本组件之上
 *
 * 与旧版「流光溢彩」的区别：去掉两层带缩放/旋转动画的重模糊图（那套是流光风格），
 * 改为单图 + 系统厚模糊 + 渐变，观感更接近华为音乐，也更省电。
 */
@Component
export struct FlowingLightBackground {
  /** 封面地址（空串则只画渐变底） */
  @Prop imageUrl: string = '';
  /** 封面为空时的标题（保留参数以兼容调用方，不参与绘制） */
  @Prop fallbackTitle: string = '';
  /** 滚动头部由导航容器统一管理安全区；播放器沿用原有扩展方式。 */
  @Prop extendSafeArea: boolean = true;

  /** 封面是否已解码：未解码前先显示渐变底，避免首帧空白 */
  @State private imgLoaded: boolean = false;
  /** 深色模式：决定遮罩浓度（资源本身已按深浅分两套，这里仅用于兜底渐变） */
  @State private dark: boolean = false;

  aboutToAppear(): void {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const config: Configuration | undefined = ctx.config as Configuration;
      this.dark = config !== undefined
        && config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (error) {
      this.dark = false;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // ① 底层：封面铺满；`sourceSize` 降采样（背景是模糊的，不需要原图分辨率）
      if (this.imageUrl !== '') {
        Image(this.imageUrl)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .sourceSize({ width: 720, height: 720 })
          // 模糊半径加大（60 → 96）：节目详情页顶部 / 播放器的氛围背景更「化开」，
          // 封面细节不再隐约可辨；配 1.22 的放大避免模糊后边缘露出底色。
          .blur(96)
          .scale({ x: 1.22, y: 1.22 })
          .opacity(this.imgLoaded ? 1 : 0)
          .animation({ duration: 260, curve: Curve.EaseOut })
          .onComplete(() => {
            this.imgLoaded = true;
          })
          // 铺到状态栏 / 手势区：只在父 Stack 上扩安全区，百分比子层不会自动延伸
          .expandSafeArea(this.extendSafeArea ? [SafeAreaType.SYSTEM] : [], this.extendSafeArea ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM] : [])
      }

      // 兜底渐变：封面未就绪时也有背景，不会闪白/闪黑
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 160,
          colors: [
            [$r('app.color.player_toolbar_forced'), 0],
            [$r('app.color.player_bg_forced'), 1]
          ]
        })
        .opacity(this.imgLoaded ? 0 : 1)
        .expandSafeArea(this.extendSafeArea ? [SafeAreaType.SYSTEM] : [], this.extendSafeArea ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM] : [])

      // ②' 细化遮罩：模糊后的封面还需要一层均匀的暗色薄纱，否则高饱和封面
      //（如亮黄色的播客封面）在深色主题里仍会「发亮」，看起来像没压过色。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#33000000')
        .expandSafeArea(this.extendSafeArea ? [SafeAreaType.SYSTEM] : [], this.extendSafeArea ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM] : [])

      // ③ 顶层：渐变遮罩（上透明 → 中过渡 → 底部更暗）
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [
            [this.scrimTop(), 0],
            [this.scrimMid(), 0.42],
            [this.scrimBottom(), 1]
          ]
        })
        .expandSafeArea(this.extendSafeArea ? [SafeAreaType.SYSTEM] : [], this.extendSafeArea ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM] : [])
    }
    .width('100%')
    .height('100%')
    .clip(true)
    .backgroundColor($r('app.color.player_bg_forced'))
    .expandSafeArea(this.extendSafeArea ? [SafeAreaType.SYSTEM] : [], this.extendSafeArea ? [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM] : [])
  }

  /** 顶部：略压暗，保证状态栏/返回图标可读（深浅各一套资源） */
  private scrimTop(): ResourceColor {
    return $r('app.color.player_flow_scrim_top_forced');
  }

  /** 中段：过渡，不压掉封面颜色 */
  private scrimMid(): ResourceColor {
    return $r('app.color.player_flow_scrim_mid_forced');
  }

  /** 底部：最暗，让按钮与文字在渐变上稳定可读 */
  private scrimBottom(): ResourceColor {
    return $r('app.color.player_flow_scrim_bottom_forced');
  }
}
