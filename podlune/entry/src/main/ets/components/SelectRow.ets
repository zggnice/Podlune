// 单选行：用独立组件承载选择状态。
// 直接在页面里用 @Builder 传 boolean 时，勾选状态在状态变化后不一定重绘；
// 拆成带 @Prop 的组件后，@Prop 变化会稳定触发该行重建。
import { DesignTokens } from '../common/DesignTokens';

@Component
export struct SelectRow {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  @Prop label: ResourceStr = '';
  @Prop selected: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Row({ space: DesignTokens.SPACE_L }) {
      Text(this.label).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_BODY)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      if (this.selected) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(DesignTokens.ICON_L)
          .fontColor([$r('app.color.primary')])
      }
    }
    .width('100%')
    .padding({
      left: DesignTokens.SPACE_L,
      right: DesignTokens.SPACE_L,
      top: DesignTokens.SPACE_M,
      bottom: DesignTokens.SPACE_M
    })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.onTap();
    })
  }
}
