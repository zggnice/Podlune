import { DesignTokens } from '../common/DesignTokens';
import { PressLight } from '../common/PressLight';

/**
 * 通用卡片容器（HarmonyOS 卡片规范）：圆角 12vp、白/深色表面、
 * 默认 12vp 内边距；内容通过 @BuilderParam 注入，可配点击。
 */
@Component
export struct RowCard {
  @Prop bg: ResourceColor = $r('app.color.surface');
  @Prop pad: number = DesignTokens.SPACE_M;
  @Prop radius: number = DesignTokens.RADIUS_ROW;
  @Prop chevron: boolean = false;
  onTap: (() => void) | undefined = undefined;
  @BuilderParam content: () => void = this.defaultContent;

  /** 按压光感（HDS point light） */
  @State private lightPressed: boolean = false;

  @Builder
  defaultContent() {
  }

  build() {
    Row() {
      Column() {
        this.content()
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.chevron) {
        SymbolGlyph($r('sys.symbol.chevron_forward'))
          .fontSize(DesignTokens.ICON_M)
          .fontColor([$r('app.color.text_disabled')])
          .margin({ left: DesignTokens.SPACE_S })
      }
    }
    .width('100%')
    .padding(this.pad)
    .backgroundColor(this.bg)
    .borderRadius(this.radius)
    .alignItems(VerticalAlign.Top)
    .visualEffect(PressLight.effect(this.onTap !== undefined && this.lightPressed))
    .animation({ duration: 150, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent): void => {
      if (this.onTap === undefined) {
        return;
      }
      if (event.type === TouchType.Down) {
        this.lightPressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.lightPressed = false;
      }
    })
    .onClick(() => {
      if (this.onTap !== undefined) {
        this.onTap();
      }
    })
  }
}
