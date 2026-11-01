import { DesignTokens } from '../common/DesignTokens';
import { AppIconButton } from './AppIconButton';

/**
 * 页签页顶栏：大标题 + 右侧动作区。
 *
 * 形态：
 * - 大标题 22fp Bold，**顶格**（从页面左边距 0 开始，前面不加任何缩进）；
 * - 右侧至多一个动作「更多」锚点，菜单由调用方用尾随闭包注入。
 *
 * 注意：本组件**不绘制任何背景**（不挂底色、不挂玻璃层、不挂描边），
 * 直接透出页面底色；也不叠在内容之上，而是作为正常布局块参与排列。
 * 早先与玻璃胶囊相关的 `glass` 等参数已移除，调用方不再需要传样式。
 */
@Component
export struct FloatingTopBar {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  @Prop title: ResourceStr = '';
  /** 「更多」锚点图标 */
  @Prop secondaryIcon: Resource = $r('sys.symbol.ellipsis_circle');
  /** 是否渲染右侧动作区。首页没有任何「更多」动作后置 false，整块按钮不再占位。 */
  @Prop showSecondary: boolean = true;
  @BuilderParam secondary: () => void = this.defaultSecondary;

  @Builder
  defaultSecondary() {
    AppIconButton({ symbol: this.secondaryIcon })
  }

  build() {
    Row() {
      // 大标题顶格：无左内边距、无缩进
      Text(this.title).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_FLOAT_TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      if (this.showSecondary) {
        this.secondary()
      }
    }
    .width('100%')
    .height(DesignTokens.HEIGHT_FLOAT_TOP_BAR)
    .padding({ right: DesignTokens.SPACE_XS })
    .alignItems(VerticalAlign.Center)
  }
}
