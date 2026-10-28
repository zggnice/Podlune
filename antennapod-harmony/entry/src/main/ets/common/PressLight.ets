import { hdsEffect } from '@kit.UIDesignKit';

/**
 * 沉浸光感（HDS point light）。
 *
 * 参考 HarmonyX 的 HdsButton / TweetCard 用法：把 `hdsEffect` 的点光源挂到目标节点的
 * `visualEffect` 上，按压时点亮边框与内容（BORDER_CONTENT），松手熄灭。
 *
 * 能力缺失时（老设备 / 未开 HDS）`hdsEffect` 调用会退化为无效果，不会影响布局与点击，
 * 因此调用方不需要做额外兜底。
 */
export class PressLight {
  /**
   * 系统托管的沉浸光感：只声明「照亮边框与内容」，何时点亮交给系统
   * （按住时自动点亮，与 HarmonyX 的 TweetCard / PostDetail / Index 用法一致）。
   * 这是本项目大多数控件的默认选择：无需维护按压状态。
   */
  static ambient(): VisualEffect {
    return new hdsEffect.HdsEffectBuilder()
      .pointLight({
        illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT
      })
      .buildEffect();
  }

  /** 手动按压态效果：lit=true 时点亮 */
  static effect(lit: boolean): VisualEffect {
    return new hdsEffect.HdsEffectBuilder()
      .pointLight({
        sourceType: lit ? hdsEffect.PointLightSourceType.BRIGHT : hdsEffect.PointLightSourceType.NONE,
        illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT
      })
      .buildEffect();
  }
}

/**
 * 给任意内容加一层「按压发光」的容器。
 *
 * 只负责光感与触摸态，不改动内部布局：内容按原样渲染在 Stack 里，
 * 圆角与裁切由调用方通过 radius/clip 控制。
 */
@Component
export struct PressLightSurface {
  @Prop radius: number = 0;
  @Prop clipContent: boolean = false;
  /** 常亮（用于「已选中 / 正在播放」这类持续高亮） */
  @Prop lit: boolean = false;
  @BuilderParam content: () => void = this.emptyContent;

  @State private pressed: boolean = false;

  @Builder
  emptyContent() {
  }

  build() {
    Stack() {
      this.content()
    }
    .borderRadius(this.radius)
    .clip(this.clipContent)
    .visualEffect(PressLight.effect(this.lit || this.pressed))
    .animation({ duration: 150, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.pressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressed = false;
      }
    })
  }
}
