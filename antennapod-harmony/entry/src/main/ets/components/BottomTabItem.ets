import { DesignTokens } from '../common/DesignTokens';

/**
 * 原生 Tabs 的自定义页签内容；点击状态与 Tabs 双向同步，胶囊材质由 Tabs 承载。
 */
@Component
export struct BottomTabItem {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  @Prop label: Resource = $r('app.string.tab_home');
  @Prop icon: Resource = $r('sys.symbol.circle');
  @Prop iconActive: Resource = $r('sys.symbol.circle');
  @Prop selected: boolean = false;
  @Prop badge: number = -1;
  onTap: () => void = () => {
  };

  build() {
    Column({ space: 3 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        Stack() {
          SymbolGlyph(this.selected ? this.iconActive : this.icon)
            .fontSize(DesignTokens.ICON_XL)
            .fontColor([this.selected ? $r('app.color.primary') : $r('app.color.text_secondary')])
        }
        .width(56)
        .height(30)
        .borderRadius(15)
        .alignContent(Alignment.Center)

        if (this.badge > 0) {
          Text(this.badge > 99 ? '99+' : this.badge.toString()).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_OVERLINE)
            .fontColor(Color.White)
            .backgroundColor($r('app.color.badge_bg'))
            .borderRadius(8)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ top: -2, right: -4 })
        }
      }
      .width(56)
      .height(30)

      Text(this.label).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_NAV)
        .fontWeight(this.selected ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.selected ? $r('app.color.primary') : $r('app.color.text_secondary'))
        .maxLines(1)
    }
    .width('100%')
    .height(DesignTokens.HEIGHT_TAB_BAR - DesignTokens.SPACE_S)
    .justifyContent(FlexAlign.Center)
    .borderRadius(DesignTokens.RADIUS_SHEET)
    .backgroundColor(this.selected ? $r('app.color.nav_selected') : Color.Transparent)
    .animation({ duration: 180, curve: Curve.EaseOut })
    .accessibilityText(this.label)
    .accessibilitySelected(this.selected)
    .onClick(() => {
      this.onTap();
    })
  }
}
