import router from '@ohos.router';
import { DesignTokens } from '../common/DesignTokens';

/**
 * 页面标题栏（HarmonyOS 导航栏规范）：高 56vp、返回箭头、标题 20fp、
 * 右侧可挂载动作区（通过 @BuilderParam 注入）。
 */
@Component
export struct AppBar {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  @Prop title: ResourceStr = '';
  @Prop showBack: boolean = true;
  /** 导航条底色：默认全局 page_bg；白底页面（播放器/单集详情）传入自己的底色以避免出现色带 */
  @Prop bgColor: ResourceColor = $r('app.color.page_bg');
  onBack: () => void = () => {
    router.back();
  };
  @BuilderParam trailing: () => void = this.defaultTrailing;

  @Builder
  defaultTrailing() {
  }

  build() {
    Row({ space: DesignTokens.SPACE_S }) {
      if (this.showBack) {
        Stack() {
          SymbolGlyph($r('sys.symbol.chevron_backward'))
            .fontSize(DesignTokens.ICON_XL)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(DesignTokens.HIT_MIN)
        .height(DesignTokens.HIT_MIN)
        .alignContent(Alignment.Center)
        .onClick(() => {
          this.onBack();
        })
      }

      Text(this.title).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_TITLE3)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      this.trailing()
    }
    .width('100%')
    .height(DesignTokens.HEIGHT_APP_BAR)
    .padding({ left: DesignTokens.SPACE_S, right: DesignTokens.PAGE_MARGIN })
    .backgroundColor(this.bgColor)
  }
}
