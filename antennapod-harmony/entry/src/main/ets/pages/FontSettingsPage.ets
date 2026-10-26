import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import { promptAction } from '@kit.ArkUI';
import { AppBar } from '../components/AppBar';
import { RowCard } from '../components/RowCard';
import { DesignTokens } from '../common/DesignTokens';
import { AppFont, APP_FONT_FAMILY_KEY, FontImportResult } from '../services/AppFont';
import { UserPreferences } from '../prefs/UserPreferences';

/**
 * 字体设置页：导入本机字体文件（.ttf / .otf / .ttc），改变整个软件的字体。
 *
 * 平台前提见 `services/AppFont.ets`：ArkUI 没有全局字体的 API，只能每个 Text 挂
 * `.fontFamily(this.appFontFamily)`。本页的预览块是最有价值的部分——导入完**当场**就能看到效果
 * （靠 `@StorageProp` 的重绘依赖，不能用 `AppStorage.get`）。
 */
@Entry
@Component
struct FontSettingsPage {
  /** 全工程统一读的字体族（导入 / 清除时 AppStorage 一变，这里连同所有 Text 一起重绘） */
  @StorageProp(APP_FONT_FAMILY_KEY) appFontFamily: string = AppFont.DEFAULT_FAMILY;

  @State private fontName: string = '';
  @State private fontBusy: boolean = false;

  aboutToAppear(): void {
    this.fontName = UserPreferences.getAppFontName();
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        AppBar({ title: $r('app.string.setting_font'), showBack: true })

        Scroll() {
          Column({ space: DesignTokens.SPACE_M }) {
            // 当前字体
            RowCard({ pad: 0, radius: 20 }) {
              Column() {
                Row({ space: DesignTokens.SPACE_L }) {
                  SymbolGlyph($r('sys.symbol.textformat'))
                    .fontSize(DesignTokens.ICON_XL)
                    .fontColor([$r('app.color.text_secondary')])
                  Text($r('app.string.font_current')).fontFamily(this.appFontFamily)
                    .fontSize(DesignTokens.FONT_BODY)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.text_primary'))
                    .layoutWeight(1)
                    .fontFamily(this.appFontFamily)
                  Text(this.fontName === ''
                    ? $r('app.string.font_system_default') : this.fontName).fontFamily(this.appFontFamily)
                    .fontSize(DesignTokens.FONT_PARAGRAPH)
                    .fontColor($r('app.color.text_tertiary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .fontFamily(this.appFontFamily)
                }
                .width('100%')
                .height(56)
                .padding({ left: DesignTokens.SPACE_M, right: DesignTokens.SPACE_M })
              }
              .width('100%')
            }

            // 预览：三种字号 + 一个字重 + 中英数字混排
            RowCard({ pad: 0, radius: 20 }) {
              Column({ space: DesignTokens.SPACE_S }) {
                Text($r('app.string.font_preview')).fontFamily(this.appFontFamily)
                  .fontSize(DesignTokens.FONT_FOOTNOTE)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
                  .fontFamily(this.appFontFamily)
                Text('永字八法 Aa Bb 0123').fontFamily(this.appFontFamily)
                  .fontSize(28)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontFamily(this.appFontFamily)
                Text('播客是一门关于时间与声音的手艺。').fontFamily(this.appFontFamily)
                  .fontSize(17)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                  .fontFamily(this.appFontFamily)
                Text('The quick brown fox jumps over the lazy dog.').fontFamily(this.appFontFamily)
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
                  .fontFamily(this.appFontFamily)
              }
              .width('100%')
              .padding(DesignTokens.SPACE_M)
            }

            // 导入 / 恢复
            RowCard({ pad: 0, radius: 20 }) {
              Column() {
                Row({ space: DesignTokens.SPACE_L }) {
                  SymbolGlyph($r('sys.symbol.square_and_arrow_down'))
                    .fontSize(DesignTokens.ICON_XL)
                    .fontColor([$r('app.color.text_secondary')])
                  Column({ space: 2 }) {
                    Text($r('app.string.font_import')).fontFamily(this.appFontFamily)
                      .fontSize(DesignTokens.FONT_BODY)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('app.color.text_primary'))
                      .fontFamily(this.appFontFamily)
                    Text($r('app.string.font_import_desc')).fontFamily(this.appFontFamily)
                      .fontSize(DesignTokens.FONT_FOOTNOTE)
                      .fontColor($r('app.color.text_tertiary'))
                      .fontFamily(this.appFontFamily)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                }
                .width('100%')
                .padding({ left: DesignTokens.SPACE_M, right: DesignTokens.SPACE_M, top: 14, bottom: 14 })
                .opacity(this.fontBusy ? 0.45 : 1)
                .onClick(() => {
                  // 选择器是异步的：这里再判一次，避免连点开两个选择器、拷两次文件
                  if (this.fontBusy) {
                    return;
                  }
                  this.importFont();
                })

                if (this.fontName !== '') {
                  Divider()
                    .color($r('app.color.divider'))
                    .strokeWidth(0.5)
                    .margin({ left: DesignTokens.SPACE_M })
                  Row({ space: DesignTokens.SPACE_L }) {
                    SymbolGlyph($r('sys.symbol.arrow_counterclockwise'))
                      .fontSize(DesignTokens.ICON_XL)
                      .fontColor([$r('app.color.text_secondary')])
                    Column({ space: 2 }) {
                      Text($r('app.string.font_reset')).fontFamily(this.appFontFamily)
                        .fontSize(DesignTokens.FONT_BODY)
                        .fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.text_primary'))
                        .fontFamily(this.appFontFamily)
                      Text($r('app.string.font_reset_desc')).fontFamily(this.appFontFamily)
                        .fontSize(DesignTokens.FONT_FOOTNOTE)
                        .fontColor($r('app.color.text_tertiary'))
                        .fontFamily(this.appFontFamily)
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                  }
                  .width('100%')
                  .padding({ left: DesignTokens.SPACE_M, right: DesignTokens.SPACE_M, top: 14, bottom: 14 })
                  .onClick(() => {
                    AppFont.clear();
                    this.fontName = '';
                    this.toast($r('app.string.font_reset_done'));
                  })
                }
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding({
            left: DesignTokens.PAGE_MARGIN,
            right: DesignTokens.PAGE_MARGIN,
            top: DesignTokens.SPACE_S,
            bottom: DesignTokens.SPACE_XXL
          })
        }
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .width('100%')
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  private async importFont(): Promise<void> {
    this.fontBusy = true;
    try {
      const context: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const result: FontImportResult = await AppFont.importFont(context);
      if (result.cancelled) {
        // 用户取消：静默返回，不弹「失败」也不弹「已导入」
        return;
      }
      if (!result.ok) {
        this.toast($r('app.string.font_import_failed') + ' ' + this.errorText(result.error));
        return;
      }
      this.fontName = UserPreferences.getAppFontName();
      this.toast($r('app.string.font_imported'));
    } finally {
      this.fontBusy = false;
    }
  }

  private errorText(code: string): string {
    if (code === 'font_picker_failed') {
      return this.text($r('app.string.font_picker_failed'));
    }
    if (code === 'font_register_failed') {
      return this.text($r('app.string.font_register_failed'));
    }
    return this.text($r('app.string.font_read_failed'));
  }

  private text(value: Resource): string {
    try {
      return getContext(this).resourceManager.getStringSync(value.id);
    } catch (error) {
      return '';
    }
  }

  private toast(message: ResourceStr): void {
    try {
      promptAction.showToast({ message: message, duration: 1800 });
    } catch (error) {
      // toast 失败不影响主流程
    }
  }
}
