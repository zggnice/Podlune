import { AppBar } from '../components/AppBar';
import { AppLinks } from '../common/AppLinks';
import common from '@ohos.app.ability.common';
import { Want } from '@kit.AbilityKit';
import pasteboard from '@ohos.pasteboard';
import { promptAction } from '@kit.ArkUI';
import { RowCard } from '../components/RowCard';
import { DesignTokens } from '../common/DesignTokens';
import { AppFont } from '../services/AppFont';

/**
 * 隐私政策与开源声明（商店提审要求：应用内可查阅）。
 *
 * 内容与 `NOTICE.md` 保持一致：GPL-3.0 许可与源码获取方式、数据来源、隐私说明、权限用途。
 * 不收集任何个人信息，因此这里没有「同意/拒绝」流程，只做说明页。
 */
@Entry
@Component
struct LegalPage {
  /** 全工程统一读的字体族（导入自定义字体后本页也跟随） */
  @StorageProp('app_font_family') appFontFamily: string = AppFont.DEFAULT_FAMILY;

  build() {
    Column() {
      AppBar({ title: $r('app.string.setting_legal'), showBack: true })

      Scroll() {
        Column({ space: DesignTokens.SPACE_M }) {
          this.section($r('app.string.legal_license_title'), $r('app.string.legal_license_body'))
          this.section($r('app.string.legal_data_title'), $r('app.string.legal_data_body'))
          this.section($r('app.string.legal_privacy_title'), $r('app.string.legal_privacy_body'))
          this.section($r('app.string.legal_permission_title'), $r('app.string.legal_permission_body'))

          // 商店要求：应用内可跳转到公网隐私政策
          RowCard({ pad: 0, radius: 20 }) {
            Row({ space: DesignTokens.SPACE_XS }) {
              Text($r('app.string.legal_online_title')).fontFamily(this.appFontFamily)
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor($r('app.color.primary'))
                .layoutWeight(1)
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(DesignTokens.ICON_S)
                .fontColor([$r('app.color.text_tertiary')])
            }
            .width('100%')
            .padding(DesignTokens.SPACE_M)
            .onClick(() => {
              this.openPrivacyPolicy();
            })
          }
        }
        .width('100%')
        .padding({
          left: DesignTokens.PAGE_MARGIN,
          right: DesignTokens.PAGE_MARGIN,
          top: DesignTokens.SPACE_S,
          bottom: DesignTokens.SPACE_XXL + 56
        })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 打开在线隐私政策；系统没有浏览器时退回「复制链接」 */
  async openPrivacyPolicy(): Promise<void> {
    const url: string = AppLinks.PRIVACY_POLICY_URL;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: url
      };
      await context.startAbility(want);
    } catch (error) {
      try {
        const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
        await pasteboard.getSystemPasteboard().setData(data);
        promptAction.showToast({ message: $r('app.string.about_link_copied') });
      } catch (inner) {
        promptAction.showToast({ message: url });
      }
    }
  }

  @Builder
  section(title: Resource, body: Resource) {
    RowCard({ pad: 0, radius: 20 }) {
      Column({ space: DesignTokens.SPACE_S }) {
        Text(title).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text(body).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_PARAGRAPH)
          .fontColor($r('app.color.text_secondary'))
          .lineHeight(22)
          .width('100%')
      }
      .width('100%')
      .padding(DesignTokens.SPACE_M)
    }
  }
}
