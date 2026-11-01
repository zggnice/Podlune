import { curves, uiMaterial } from '@kit.ArkUI';
// HDS 沉浸光感材质（与参考项目 CustomMiniBarButton 同一套 systemMaterialEffect）
import { hdsEffect, hdsMaterial, HdsTabs } from '@kit.UIDesignKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { DesignTokens } from '../common/DesignTokens';
import { EmptyBuilder } from '../common/EmptyBuilder';
import { NAV_LIGHT_KEY } from '../prefs/UserPreferences';

/**
 * 自适应玻璃胶囊底（液态玻璃 / 沉浸光感的观感层）。
 *
 * 做法：对**背后的内容**做真正的背景模糊 + 提亮 + 极淡染色，而不是叠一层实心色块——
 * - 内容滚到底栏后方：封面 / 文字被柔和地模糊着透出来，形成「玻璃」层次；
 * - 纯色背景上：只多出一层 3% 的玻璃白与 24% 的描边，接近系统底部导航的淡玻璃；
 * - 短按 / 长按有轻微缩放与描边加深，手感向系统靠近。
 *
 * 用法：作为 Stack 的底层先画玻璃，再把内容叠在上面；子内容通过尾随闭包注入。
 */
@Component
export struct GlassSurface {
  /** 胶囊高度（vp）：必须显式给定，否则内部 Stack 会撑满父容器 */
  @Prop barHeight: number = DesignTokens.HEIGHT_FLOAT_NAV;
  @Prop radius: number = DesignTokens.HEIGHT_FLOAT_NAV / 2;
  /** 模糊半径（vp）：越大越像厚玻璃 */
  @Prop blurRadius: number = 6;
  /** 玻璃染色（浅色主题下用低透明度白，深色主题用低透明度黑，由资源限定符切换） */
  @Prop tint: ResourceColor = $r('app.color.glass_fill');
  /** 描边色（高光边） */
  @Prop stroke: ResourceColor = $r('app.color.glass_stroke');
  /** 是否加极轻阴影（仅导航栏用，避免与页面内容糊在一起） */
  @Prop softShadow: boolean = false;
  onTap: () => void = () => {
  };
  @BuilderParam content: () => void = EmptyBuilder;

  /** 是否启用「追光」按压点光源（照搬 yunshang-bili ImmersiveLightWrapper 的做法） */
  @Prop enableLight: boolean = true;
  /** 按压时目标光强（参考项目默认 2.5） */
  @Prop lightIntensityTarget: number = 2.5;
  /** 光源颜色 / 光源高度（vp） */
  @Prop lightColor: ResourceColor = Color.White;
  @Prop lightHeight: number = 100;

  @State private pressed: boolean = false;
  // 追光：当前光强与手指位置（相对胶囊左上角）
  @State private lightIntensity: number = 0;
  @State private fingerX: number = 0;
  @State private fingerY: number = 0;
  /** 根容器实测宽度（HdsTabs 的 barWidth 需要一个具体数值） */
  @State private measuredWidth: number = 0;
  /**
   * 沉浸光感档位（0 关 / 1 柔 / 2 均衡 / 3 通透）。
   * 用 @StorageLink 订阅 AppStorage：设置页改档位后所有玻璃面（迷你播放条、底部导航、
   * 悬浮顶栏）立即换材质，不需要重启页面。
   */
  @StorageLink(NAV_LIGHT_KEY) navLightLevel: number = 0;

  /** 是否使用系统沉浸光感材质（API 26+ 且档位 > 0） */
  private useMaterial(): boolean {
    return this.navLightLevel > 0 && deviceInfo.sdkApiVersion >= 26;
  }

  /** 档位 → 系统材质样式：柔=REGULAR、均衡=THIN、通透=ULTRA_THIN */
  private material(): SystemUiMaterial | undefined {
    if (!this.useMaterial() || !uiMaterial.isImmersiveMaterialSupported()) {
      // 系统不支持时返回 undefined：避免挂一层渲染为空的材质，白白多一次合成
      return undefined;
    }
    const style: uiMaterial.ImmersiveStyle = this.navLightLevel === 1
      ? uiMaterial.ImmersiveStyle.REGULAR
      : this.navLightLevel === 3 ? uiMaterial.ImmersiveStyle.ULTRA_THIN : uiMaterial.ImmersiveStyle.THIN;
    return new uiMaterial.ImmersiveMaterial({
      style: style,
      // 染色沿用主题里的玻璃色，深浅色自动切
      materialColor: this.tint,
      // 自动反色只对资源颜色生效，这里关掉以免与主题色冲突
      colorInvert: false,
      applyShadow: this.softShadow,
      // 均衡 / 通透档带按压形变与流光跟随
      interactive: this.navLightLevel >= 2,
      lightEffect: this.navLightLevel >= 2 ? { color: undefined } : null
    });
  }

  /** 追光光斑：1×1 的透明块，靠 pointLight 在它位置打一圈光，跟随手指 */
  @Builder
  lightTracker() {
    Stack() {
      Flex()
        .size(this.lightIntensity > 0 ? { width: 1, height: 1 } : { width: 0, height: 0 })
        .backgroundColor(Color.Transparent)
        .visualEffect(
          new hdsEffect.HdsEffectBuilder()
            .pointLight({
              options: {
                color: this.lightColor,
                intensity: this.lightIntensity,
                height: this.lightHeight
              }
            })
            .buildEffect()
        )
        .position({ x: this.fingerX, y: this.fingerY })
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  /** 按下点亮、移动追光、抬起熄灭（与参考项目 handleTouch 同参数） */
  private updateLight(event: TouchEvent): void {
    if (!this.enableLight || event.touches.length === 0) {
      return;
    }
    const x: number = event.touches[0].x;
    const y: number = event.touches[0].y;
    if (event.type === TouchType.Down) {
      this.fingerX = x;
      this.fingerY = y;
      this.getUIContext().animateTo({ duration: 100, curve: Curve.EaseIn }, () => {
        this.lightIntensity = this.lightIntensityTarget;
      });
    } else if (event.type === TouchType.Move) {
      this.getUIContext().animateTo({ curve: curves.responsiveSpringMotion(0.5, 0.5) }, () => {
        this.fingerX = x;
        this.fingerY = y;
      });
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseOut }, () => {
        this.lightIntensity = 0;
      });
    }
  }

  /** 空 tabBar：避免 HdsTabs 画出自己的选中态高亮块 */
  @Builder
  emptyTabBar() {
    Row()
      .width(0)
      .height(0)
      .backgroundColor(Color.Transparent)
  }

  /** 沉浸光感档位 > 0 且系统支持材质时才叠 HDS 层 */
  private useHds(): boolean {
    return this.navLightLevel > 0 && deviceInfo.sdkApiVersion >= 26;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 玻璃底：背景模糊 + 提亮 + 染色
      Column()
        .width('100%')
        .height('100%')
        // 玻璃底：优先用系统「内容自适应玻璃」BlurStyle.COMPONENT_THICK
        // （参考 yunshang-bili 的 ImmersiveLightWrapper：这是官方在内容区唯一推荐的
        //   材质降级配方——亮内容上出浅玻璃、暗内容上出深玻璃，省掉手调 brightness/saturation）。
        // 挂了 HDS 沉浸光感材质时必须置为 NONE，否则材质与背景模糊叠加会把玻璃压死。
        .backgroundBlurStyle(this.useMaterial() ? BlurStyle.NONE : BlurStyle.COMPONENT_THICK)
        // 极淡的主题染色：让深浅色主题下的玻璃底色仍落在本工程色板内
        .backgroundColor(this.useMaterial() ? Color.Transparent : this.tint)
        .borderRadius(this.radius)
        // 有系统材质时由材质接管底色 / 模糊 / 阴影 / 描边；否则回落到自绘玻璃
        .systemMaterial(this.material())
        .border({ width: this.useMaterial() ? 0 : 0.8, color: this.stroke })
        .shadow(this.softShadow
          ? { radius: 18, color: '#14000000', offsetY: 4 }
          : { radius: 0, color: Color.Transparent })
        // 本体点光源：BORDER_CONTENT = 边框与内容一起被照亮（参考项目同款取值）
        .visualEffect(this.enableLight
          ? new hdsEffect.HdsEffectBuilder().pointLight({
            illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT
          }).buildEffect()
          : undefined)
        .overlay(this.enableLight ? this.lightTracker() : undefined)
        .scale({ x: this.pressed ? 0.985 : 1, y: this.pressed ? 0.985 : 1 })
        .animation({ duration: 160, curve: Curve.FastOutSlowIn })
        .onTouch((event: TouchEvent) => {
          this.updateLight(event);
          if (event.type === TouchType.Down) {
            animateTo({ duration: 160, curve: Curve.FastOutSlowIn }, () => {
              this.pressed = true;
            });
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            animateTo({ duration: 220, curve: Curve.FastOutSlowIn }, () => {
              this.pressed = false;
            });
          }
        })

      // HDS 沉浸光感材质：与参考项目 CustomMiniBarButton 完全同一套
      // `HdsTabs.barFloatingStyle.systemMaterialEffect(IMMERSIVE, EXQUISITE)`。
      // 用一个**空 tabBar** 的 HdsTabs 只取材质层，尺寸/圆角跟随本胶囊，
      // 前景内容与业务事件仍由上面的 content() 承担，交互不变。
      if (this.useHds() && this.measuredWidth > 0) {
        HdsTabs() {
          TabContent()
            .tabBar(this.emptyTabBar())
        }
        .barWidth(this.measuredWidth)
        .barHeight(this.barHeight)
        .barPosition(BarPosition.End)
        .barOverlap(true)
        .barFloatingStyle({
          gradientMask: {
            maskColor: Color.Transparent
          },
          barBottomMargin: 0,
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.EXQUISITE
          }
        })
        .borderRadius(this.radius)
        .clip(true)
        .width('100%')
        .height(this.barHeight)
        .hitTestBehavior(HitTestMode.Transparent)
      }

      // 液态玻璃的「镜面高光」：上缘一道很淡的白，向下 45% 渐隐。
      // 参考实现的 shader 里这一步是 specular highlight；ArkUI 没有可编程取样，
      // 用线性渐变近似——只取它最容易被眼睛识别的那一层。
      if (!this.useMaterial()) {
        Column()
          .width('100%')
          .height('100%')
          .borderRadius(this.radius)
          .linearGradient({
            angle: 180,
            colors: [
              ['#2EFFFFFF', 0],
              ['#14FFFFFF', 0.28],
              ['#00FFFFFF', 0.55],
              ['#00000000', 1]
            ]
          })
          .hitTestBehavior(HitTestMode.None)
      }

      this.content()
    }
    // 固定高度：Stack 无尺寸约束时会撑满父容器（实测会盖住整页）
    .width('100%')
    .height(this.barHeight)
    .onAreaChange((_old: Area, next: Area) => {
      const w: Length = next.width;
      if (typeof w === 'number' && w > 0 && Math.abs(w - this.measuredWidth) > 0.5) {
        this.measuredWidth = w;
      }
    })
  }
}
