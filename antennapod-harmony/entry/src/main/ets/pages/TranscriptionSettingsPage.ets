// AI 文字稿配置页：服务商 / 地址 / 密钥 / 模型 / 语言 / 生成策略 / 网络与费用 / 测试连接 / 缓存管理。
// 只有真实调用转写接口并拿到非空结果才会标记「配置成功」。
import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import { DesignTokens } from '../common/DesignTokens';
import { RowCard } from '../components/RowCard';
import { SelectRow } from '../components/SelectRow';
import {
  AutoTranscriptPolicy,
  ProviderTestState,
  TranscriptConfig,
  TranscriptKeyStore,
  TranscriptProviderKind,
  TranscriptSettings,
  TranscriptVendor,
  TranscriptVendors
} from '../prefs/TranscriptSettings';
import { TranscriptionErrorKind, TranscriptionOutcome, TranscriptionProvider } from '../services/transcript/TranscriptionProvider';
import { TranscriptRepository } from '../db/repositories/TranscriptRepository';

@Entry
@Component
export struct TranscriptionSettingsPage {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  @State config: TranscriptConfig = TranscriptSettings.load();
  /** 选项当前值单独用基本类型状态保存：对象整体赋值在本页不一定触发重绘 */
  @State providerSel: number = TranscriptSettings.load().provider;
  @State policySel: number = TranscriptSettings.load().policy;
  @State apiKeyInput: string = '';
  @State keyConfigured: boolean = false;
  @State showKey: boolean = false;
  @State testing: boolean = false;
  @State message: string = '';
  @State cacheCount: number = 0;
  @State cacheSize: string = '';

  aboutToAppear(): void {
    // 已保存过密钥：把内容读回输入框（默认密文显示），
    // 这样「保存密钥」之后/下次进入页面都能看到框里是有内容的。
    this.loadKeyIntoInput();
  }

  private async loadKeyIntoInput(): Promise<void> {
    const saved: string = await TranscriptKeyStore.load();
    if (saved !== '') {
      this.keyConfigured = true;
      this.apiKeyInput = saved;
    }
  }

  build() {
    Column() {
      Row({ space: DesignTokens.SPACE_XS }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.chevron_backward'))
            .fontSize(DesignTokens.ICON_XL)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(DesignTokens.HIT_MIN)
        .height(DesignTokens.HIT_MIN)
        .alignContent(Alignment.Center)
        .onClick(() => {
          router.back();
        })
        Text($r('app.string.transcript_settings_title')).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_TITLE2)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
      }
      .width('100%')
      .height(DesignTokens.HEIGHT_APP_BAR)
      .padding({ left: DesignTokens.SPACE_S, right: DesignTokens.SPACE_S })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          // 反馈区：之前 this.message 只被赋值、从未渲染，
          // 于是「测试连接」点击后界面上完全看不到任何变化（像没反应）。
          if (this.message !== '') {
            Row({ space: DesignTokens.SPACE_XS }) {
              if (this.testing) {
                LoadingProgress()
                  .width(16)
                  .height(16)
                  .color($r('app.color.primary'))
              }
              Text(this.message).fontFamily(this.appFontFamily)
                .fontSize(DesignTokens.FONT_FOOTNOTE)
                .fontColor($r('app.color.text_secondary'))
                .layoutWeight(1)
            }
            .width('100%')
            .padding({
              left: DesignTokens.SPACE_M, right: DesignTokens.SPACE_M,
              top: DesignTokens.SPACE_XS, bottom: DesignTokens.SPACE_XS
            })
            .backgroundColor($r('app.color.surface'))
            .borderRadius(12)
            .margin({ top: DesignTokens.SPACE_S })
          }

          this.switchCard()
          this.providerCard()
          this.credentialCard()
          this.strategyCard()
          this.testCard()
          this.cacheCard()
          this.privacyNote()
        }
        .width('100%')
        .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN, bottom: DesignTokens.SPACE_XXL })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
    .onAppear(() => {
      this.refreshCacheStats();
    })
  }

  @Builder
  categoryTitle(label: ResourceStr) {
    Text(label).fontFamily(this.appFontFamily)
      .fontSize(DesignTokens.FONT_FOOTNOTE)
      .fontColor($r('app.color.text_tertiary'))
      .width('100%')
      .padding({ left: DesignTokens.SPACE_XS, top: DesignTokens.SPACE_L, bottom: DesignTokens.SPACE_XS })
  }

  @Builder
  switchCard() {
    this.categoryTitle($r('app.string.transcript_settings_section_general'))
    RowCard({ pad: 0, radius: 20 }) {
      Column() {
        Row({ space: DesignTokens.SPACE_L }) {
          SymbolGlyph($r('sys.symbol.wand_and_stars'))
            .fontSize(DesignTokens.ICON_XL)
            .fontColor([$r('app.color.text_secondary')])
          Column({ space: 2 }) {
            Text($r('app.string.transcript_settings_enable')).fontFamily(this.appFontFamily)
              .fontSize(DesignTokens.FONT_BODY)
              .fontColor($r('app.color.text_primary'))
            Text($r('app.string.transcript_settings_enable_hint')).fontFamily(this.appFontFamily)
              .fontSize(DesignTokens.FONT_FOOTNOTE)
              .fontColor($r('app.color.text_tertiary'))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Toggle({ type: ToggleType.Switch, isOn: this.config.enabled })
            .selectedColor($r('app.color.primary'))
            .onChange((isOn: boolean) => {
              this.commit((next: TranscriptConfig) => {
                next.enabled = isOn;
              }, false);
              if (isOn && !this.keyConfigured) {
                this.message = this.text($r('app.string.transcript_settings_need_config'));
              }
            })
        }
        .width('100%')
        .padding(DesignTokens.SPACE_L)
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
    }
  }

  @Builder
  providerCard() {
    this.categoryTitle($r('app.string.transcript_settings_section_provider'))
    // 不用 RowCard：自定义组件的 @BuilderParam 内容在 props 不变时不会重建，
    // 选项的勾选状态会停在旧值。这里用普通 Column 让父级状态变化直接重绘。
    Column() {
      this.providerOption($r('app.string.transcript_provider_general'), TranscriptProviderKind.OPENAI)
      this.rowDivider()
      this.providerOption($r('app.string.transcript_provider_custom'), TranscriptProviderKind.CUSTOM_OPENAI)
    }
    .width('100%')
    .backgroundColor($r('app.color.surface'))
    .borderRadius(20)

    if (this.config.provider === TranscriptProviderKind.OPENAI) {
      // 通用模型：国内厂商列表，选中后自动填充接口地址 + 默认模型
      this.categoryTitle($r('app.string.transcript_settings_vendor_section'))
      Column() {
        ForEach(TranscriptVendors.ALL, (vendor: TranscriptVendor, index: number) => {
          if (index > 0) {
            this.rowDivider()
          }
          this.vendorRow(vendor)
        }, (vendor: TranscriptVendor) => vendor.id)
      }
      .width('100%')
      .backgroundColor($r('app.color.surface'))
      .borderRadius(20)

      Text($r('app.string.transcript_vendor_hint')).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_FOOTNOTE)
        .fontColor($r('app.color.text_tertiary'))
        .padding({ left: DesignTokens.SPACE_M, right: DesignTokens.SPACE_M, top: DesignTokens.SPACE_XS })

      // 选中厂商后：接口地址自动填好（只读展示），模型名称仍需自己填。
      // 注意：这里**不用带参 @Builder**（传参时父级状态变化不会让它重新求值，
      // 表现就是「换了厂商，地址和模型名都不跟着变」），全部直接读 this.config。
      if (this.config.vendor !== '') {
        this.categoryTitle($r('app.string.transcript_settings_section_endpoint'))
        // 整块用 id 跟随厂商：换厂商时强制重建，地址/模型输入框才能立刻换上新值。
        // （ArkUI 的 TextInput 只在节点创建时读取 text，单纯改状态不会刷新框里的内容）
        Column() {
          RowCard({ pad: 0, radius: 20 }) {
            Column() {
              Column({ space: 4 }) {
                Text($r('app.string.transcript_settings_base_url')).fontFamily(this.appFontFamily)
                  .fontSize(DesignTokens.FONT_FOOTNOTE)
                  .fontColor($r('app.color.text_tertiary'))
                // 自动填充，但允许用户自行修改（各账号可能用代理地址）
                TextInput({
                  placeholder: $r('app.string.transcript_settings_base_url_hint'),
                  text: this.config.baseUrl
                }).fontFamily(this.appFontFamily)
                  .height(38)
                  .fontSize(DesignTokens.FONT_SUBTITLE)
                  .backgroundColor($r('app.color.surface_secondary'))
                  .borderRadius(10)
                  .onChange((value: string) => {
                    this.commit((next: TranscriptConfig) => {
                      next.baseUrl = value;
                    }, true);
                  })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding({
                left: DesignTokens.SPACE_L, right: DesignTokens.SPACE_L,
                top: DesignTokens.SPACE_S, bottom: DesignTokens.SPACE_S
              })

              this.rowDivider()

              Column({ space: 4 }) {
                Text($r('app.string.transcript_settings_model')).fontFamily(this.appFontFamily)
                  .fontSize(DesignTokens.FONT_FOOTNOTE)
                  .fontColor($r('app.color.text_tertiary'))
                TextInput({
                  placeholder: this.vendorModelHint(),
                  text: this.config.model
                }).fontFamily(this.appFontFamily)
                  .height(38)
                  .fontSize(DesignTokens.FONT_SUBTITLE)
                  .backgroundColor($r('app.color.surface_secondary'))
                  .borderRadius(10)
                  .onChange((value: string) => {
                    this.commit((next: TranscriptConfig) => {
                      next.model = value;
                    }, true);
                  })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding({
                left: DesignTokens.SPACE_L, right: DesignTokens.SPACE_L,
                top: DesignTokens.SPACE_S, bottom: DesignTokens.SPACE_S
              })
            }
            .width('100%')
          }
        }
        .id('transcript_endpoint_' + this.config.vendor)
      }

    } else {
      // 自定义 OpenAI 兼容服务：接口地址与模型名都手填
      this.categoryTitle($r('app.string.transcript_settings_section_endpoint'))
      RowCard({ pad: 0, radius: 20 }) {
        Column() {
          this.inputRow($r('app.string.transcript_settings_base_url'),
            this.config.baseUrl, $r('app.string.transcript_settings_base_url_custom_hint'),
            (value: string) => {
              this.commit((next: TranscriptConfig) => {
                next.baseUrl = value;
              }, true);
            })
          this.rowDivider()
          this.inputRow($r('app.string.transcript_settings_model'), this.config.model,
            $r('app.string.transcript_settings_model_hint'), (value: string) => {
              this.commit((next: TranscriptConfig) => {
                next.model = value;
              }, true);
            })
        }
        .width('100%')
      }
    }
  }

  /**
   * 服务商单选项：勾选状态只看 `this.config.provider`（唯一状态源），
   * 避免出现「已经切到自定义、对号还留在通用模型」的双状态不一致。
   */
  @Builder
  providerOption(label: ResourceStr, kind: number) {
    Row({ space: DesignTokens.SPACE_L }) {
      Text(label).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_BODY)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      // 单选圆点：空心 / 实心，状态一目了然
      Stack() {
        if (this.config.provider === kind) {
          Circle({ width: 10, height: 10 })
            .fill($r('app.color.primary'))
        }
      }
      .width(22)
      .height(22)
      .borderRadius(11)
      .border({ width: 1.5, color: this.config.provider === kind ? $r('app.color.primary') : $r('app.color.divider') })
      .alignContent(Alignment.Center)
    }
    .width('100%')
    .padding({ left: DesignTokens.SPACE_L, right: DesignTokens.SPACE_L, top: DesignTokens.SPACE_M, bottom: DesignTokens.SPACE_M })
    .onClick(() => {
      this.applyProvider(kind);
    })
  }

  /** 厂商行：选中后自动把接口地址与默认模型写进配置 */
  @Builder
  vendorRow(vendor: TranscriptVendor) {
    Row({ space: DesignTokens.SPACE_L }) {
      Column({ space: 2 }) {
        Text(vendor.name).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor($r('app.color.text_primary'))
        Text(vendor.note).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_FOOTNOTE)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.config.vendor === vendor.id) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(DesignTokens.ICON_L)
          .fontColor([$r('app.color.primary')])
      }
    }
    .width('100%')
    .padding({ left: DesignTokens.SPACE_L, right: DesignTokens.SPACE_L, top: DesignTokens.SPACE_S, bottom: DesignTokens.SPACE_S })
    .onClick(() => {
      this.applyVendor(vendor);
    })
  }

  @Builder
  credentialCard() {
    this.categoryTitle($r('app.string.transcript_settings_section_key'))
    RowCard({ pad: 0, radius: 20 }) {
      Column() {
        Row({ space: DesignTokens.SPACE_L }) {
          SymbolGlyph($r('sys.symbol.key'))
            .fontSize(DesignTokens.ICON_XL)
            .fontColor([$r('app.color.text_secondary')])
          Column({ space: 4 }) {
            Text($r('app.string.transcript_settings_key')).fontFamily(this.appFontFamily)
              .fontSize(DesignTokens.FONT_BODY)
              .fontColor($r('app.color.text_primary'))
            Text(this.keyConfigured ? $r('app.string.transcript_settings_key_saved')
              : $r('app.string.transcript_settings_key_empty')).fontFamily(this.appFontFamily)
              .fontSize(DesignTokens.FONT_FOOTNOTE)
              .fontColor($r('app.color.text_tertiary'))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ left: DesignTokens.SPACE_L, right: DesignTokens.SPACE_L, top: DesignTokens.SPACE_M })

        // 密钥输入框 + 右侧「显示 / 隐藏」按钮：
        // 保存后输入框保留已保存的内容（默认以圆点显示），由右侧按钮切换明文/密文。
        Row({ space: DesignTokens.SPACE_XS }) {
          TextInput({
            placeholder: $r('app.string.transcript_settings_key_placeholder'),
            text: this.apiKeyInput
          }).fontFamily(this.appFontFamily)
            .type(this.showKey ? InputType.Normal : InputType.Password)
            .showPasswordIcon(false)
            .layoutWeight(1)
            .height(40)
            .fontSize(DesignTokens.FONT_SUBTITLE)
            .backgroundColor(Color.Transparent)
            .borderRadius(10)
            .onChange((value: string) => {
              this.apiKeyInput = value;
            })

          Text(this.showKey ? $r('app.string.transcript_settings_hide')
            : $r('app.string.transcript_settings_show')).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_FOOTNOTE)
            .fontColor($r('app.color.primary'))
            .padding({ left: DesignTokens.SPACE_XS, right: DesignTokens.SPACE_XS })
            .onClick(() => {
              // 只在输入框已有内容时才有意义
              this.showKey = !this.showKey;
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .backgroundColor($r('app.color.surface_secondary'))
        .borderRadius(10)
        .width('100%')
        .padding({ left: DesignTokens.SPACE_L, right: DesignTokens.SPACE_L, top: DesignTokens.SPACE_S })

        Row({ space: DesignTokens.SPACE_M }) {
          Text($r('app.string.transcript_settings_save_key')).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_SUBTITLE)
            .fontColor($r('app.color.primary'))
            .onClick(() => {
              this.saveKey();
            })
          Text($r('app.string.transcript_settings_delete_key')).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_SUBTITLE)
            .fontColor($r('app.color.text_secondary'))
            .onClick(() => {
              this.deleteKey();
            })
        }
        .width('100%')
        .padding({ left: DesignTokens.SPACE_L, right: DesignTokens.SPACE_L, top: DesignTokens.SPACE_M, bottom: DesignTokens.SPACE_M })
      }
      .width('100%')
    }
  }

  @Builder
  strategyCard() {
    this.categoryTitle($r('app.string.transcript_settings_section_strategy'))
    Column() {
      Column() {
        Text($r('app.string.transcript_settings_policy')).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_FOOTNOTE)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .padding({ left: DesignTokens.SPACE_L, top: DesignTokens.SPACE_M })
        SelectRow({
          label: $r('app.string.transcript_policy_ask'),
          selected: this.policySel === AutoTranscriptPolicy.ASK,
          onTap: () => {
            this.setPolicy(AutoTranscriptPolicy.ASK);
          }
        })
        this.rowDivider()
        SelectRow({
          label: $r('app.string.transcript_policy_auto'),
          selected: this.policySel === AutoTranscriptPolicy.AUTO,
          onTap: () => {
            this.setPolicy(AutoTranscriptPolicy.AUTO);
          }
        })
        this.rowDivider()
        SelectRow({
          label: $r('app.string.transcript_policy_never'),
          selected: this.policySel === AutoTranscriptPolicy.NEVER,
          onTap: () => {
            this.setPolicy(AutoTranscriptPolicy.NEVER);
          }
        })
        this.rowDivider()
        this.switchRow($r('app.string.transcript_settings_wifi_only'), this.config.wifiOnly, (isOn: boolean) => {
          this.commit((next: TranscriptConfig) => {
            next.wifiOnly = isOn;
          }, false);
        })
        this.rowDivider()
        this.switchRow($r('app.string.transcript_settings_confirm_cost'), this.config.confirmCost, (isOn: boolean) => {
          this.commit((next: TranscriptConfig) => {
            next.confirmCost = isOn;
          }, false);
        })
        if (this.policySel === AutoTranscriptPolicy.AUTO) {
          Text($r('app.string.transcript_settings_auto_warning')).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_FOOTNOTE)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .padding({ left: DesignTokens.SPACE_L, right: DesignTokens.SPACE_L, bottom: DesignTokens.SPACE_M })
        }
      }
      .width('100%')
    }
    .width('100%')
    .backgroundColor($r('app.color.surface'))
    .borderRadius(20)
  }

  @Builder
  testCard() {
    this.categoryTitle($r('app.string.transcript_settings_section_test'))
    RowCard({ pad: 0, radius: 20 }) {
      Column({ space: DesignTokens.SPACE_M }) {
        Text(this.testStateText()).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_SUBTITLE)
          .fontColor(this.config.testState === ProviderTestState.TESTED_OK
            ? $r('app.color.primary') : $r('app.color.text_primary'))
          .width('100%')

        if (this.config.testedMessage !== '') {
          Text(this.config.testedMessage).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_FOOTNOTE)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }

        Row({ space: DesignTokens.SPACE_M }) {
          Button(this.testing ? $r('app.string.transcript_settings_testing')
            : $r('app.string.transcript_settings_test'))
            .fontSize(DesignTokens.FONT_SUBTITLE)
            .fontColor($r('app.color.on_primary'))
            .backgroundColor($r('app.color.primary'))
            .enabled(!this.testing)
            .onClick(() => {
              this.runTest();
            })
        }
        .width('100%')

        Text($r('app.string.transcript_settings_test_hint')).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_FOOTNOTE)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
      }
      .width('100%')
      .padding(DesignTokens.SPACE_L)
      .alignItems(HorizontalAlign.Start)
    }
  }

  @Builder
  cacheCard() {
    this.categoryTitle($r('app.string.transcript_settings_section_cache'))
    RowCard({ pad: 0, radius: 20 }) {
      Column() {
        Row({ space: DesignTokens.SPACE_L }) {
          SymbolGlyph($r('sys.symbol.externaldrive_fill'))
            .fontSize(DesignTokens.ICON_XL)
            .fontColor([$r('app.color.text_secondary')])
          Column({ space: 2 }) {
            Text(this.text($r('app.string.transcript_settings_cache_count')) + this.cacheCount.toString()).fontFamily(this.appFontFamily)
              .fontSize(DesignTokens.FONT_BODY)
              .fontColor($r('app.color.text_primary'))
            Text(this.text($r('app.string.transcript_settings_cache_size')) + this.cacheSize).fontFamily(this.appFontFamily)
              .fontSize(DesignTokens.FONT_FOOTNOTE)
              .fontColor($r('app.color.text_tertiary'))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding(DesignTokens.SPACE_L)

        this.rowDivider()
        Row({ space: DesignTokens.SPACE_L }) {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(DesignTokens.ICON_XL)
            .fontColor([$r('app.color.text_secondary')])
          Text($r('app.string.transcript_settings_clear_ai_cache')).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
        }
        .width('100%')
        .padding(DesignTokens.SPACE_L)
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.clearAiCache();
        })
      }
      .width('100%')
    }
  }

  @Builder
  privacyNote() {
    Text($r('app.string.transcript_settings_privacy')).fontFamily(this.appFontFamily)
      .fontSize(DesignTokens.FONT_FOOTNOTE)
      .fontColor($r('app.color.text_tertiary'))
      .width('100%')
      .padding({ left: DesignTokens.SPACE_XS, right: DesignTokens.SPACE_XS, top: DesignTokens.SPACE_L })
  }

  /**
   * 可选项行。点击不走 @Builder 的函数参数（按值传递时容易失效），
   * 改为直接按 id + 类型在内部派发。
   */
  @Builder
  optionRow(label: ResourceStr, selected: boolean, kind: number, isPolicy: boolean) {
    Row({ space: DesignTokens.SPACE_L }) {
      Text(label).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_BODY)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      if (selected) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(DesignTokens.ICON_L)
          .fontColor([$r('app.color.primary')])
      }
    }
    .width('100%')
    .padding({ left: DesignTokens.SPACE_L, right: DesignTokens.SPACE_L, top: DesignTokens.SPACE_M, bottom: DesignTokens.SPACE_M })
    .onClick(() => {
      if (isPolicy) {
        this.setPolicy(kind);
      } else {
        this.applyProvider(kind);
      }
    })
  }

  @Builder
  inputRow(label: ResourceStr, value: string, hint: ResourceStr, onChange: (value: string) => void) {
    Column({ space: 4 }) {
      Text(label).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_FOOTNOTE)
        .fontColor($r('app.color.text_tertiary'))
      TextInput({ placeholder: hint, text: value }).fontFamily(this.appFontFamily)
        .height(38)
        .fontSize(DesignTokens.FONT_SUBTITLE)
        .backgroundColor($r('app.color.surface_secondary'))
        .borderRadius(10)
        .onChange(onChange)
    }
    .width('100%')
    .padding({ left: DesignTokens.SPACE_L, right: DesignTokens.SPACE_L, top: DesignTokens.SPACE_S, bottom: DesignTokens.SPACE_S })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  switchRow(label: ResourceStr, isOn: boolean, onChange: (isOn: boolean) => void) {
    Row({ space: DesignTokens.SPACE_L }) {
      Text(label).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_BODY)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor($r('app.color.primary'))
        .onChange(onChange)
    }
    .width('100%')
    .padding({ left: DesignTokens.SPACE_L, right: DesignTokens.SPACE_L, top: DesignTokens.SPACE_S, bottom: DesignTokens.SPACE_S })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  rowDivider() {
    Divider()
      .strokeWidth(0.5)
      .color($r('app.color.divider'))
      .margin({ left: DesignTokens.SPACE_L, right: DesignTokens.SPACE_L })
  }

  private text(res: Resource): string {
    return getContext(this).resourceManager.getStringSync(res);
  }

  /**
   * 配置是普通接口对象，直接改字段不会触发 @State 刷新（ArkUI 只观察整体赋值），
   * 所以所有修改都走「拷贝 → 改副本 → 整体赋值」。
   */
  private commit(mutator: (next: TranscriptConfig) => void, resetTest: boolean): void {
    const next: TranscriptConfig = this.cloneConfig(this.config);
    mutator(next);
    if (resetTest) {
      next.testState = ProviderTestState.NOT_TESTED;
      next.testedAt = 0;
      next.testedMessage = '';
    }
    this.config = next;
    TranscriptSettings.save(next, resetTest);
  }

  private cloneConfig(source: TranscriptConfig): TranscriptConfig {
    return {
      enabled: source.enabled,
      provider: source.provider,
      vendor: source.vendor,
      protocol: source.protocol,
      baseUrl: source.baseUrl,
      model: source.model,
      language: source.language,
      policy: source.policy,
      wifiOnly: source.wifiOnly,
      confirmCost: source.confirmCost,
      testState: source.testState,
      testedAt: source.testedAt,
      testedMessage: source.testedMessage,
      supportsTimestamps: source.supportsTimestamps
    };
  }

  /** 选中厂商：自动填充接口地址与默认模型，并把服务商切到「通用模型」 */
  private applyVendor(vendor: TranscriptVendor): void {
    this.providerSel = TranscriptProviderKind.OPENAI;
    this.commit((next: TranscriptConfig) => {
      next.provider = TranscriptProviderKind.OPENAI;
      next.vendor = vendor.id;
      next.protocol = vendor.protocol;
      next.baseUrl = vendor.baseUrl;
      // 有官方默认模型就直接填（用户仍可改）；没有的留空待填
      next.model = vendor.defaultModel;
    }, true);
    this.message = vendor.protocol === 'unsupported'
      ? this.text($r('app.string.transcript_vendor_unsupported')) : vendor.note;
  }

  /** 当前厂商的模型名占位提示（示例名，仅提示不写入） */
  private vendorModelHint(): ResourceStr {
    const vendor: TranscriptVendor | undefined = TranscriptVendors.find(this.config.vendor);
    if (vendor === undefined) {
      return $r('app.string.transcript_settings_model_hint');
    }
    return vendor.modelHint + '（' + this.text($r('app.string.transcript_settings_model_hint')) + '）';
  }

  /** 关键字段变化：测试状态立即降级，必须重新测试 */
  private applyProvider(kind: number): void {
    this.providerSel = kind;
    this.message = '';
    this.commit((next: TranscriptConfig) => {
      next.provider = kind;
      // 切到自定义时清掉厂商选择，避免「通用模型」的残留配置被误用
      if (kind === TranscriptProviderKind.CUSTOM_OPENAI) {
        next.vendor = '';
      }
    }, true);
  }

  private setPolicy(policy: number): void {
    this.policySel = policy;
    this.commit((next: TranscriptConfig) => {
      next.policy = policy;
    }, false);
  }

  private markChanged(): void {
    this.commit((next: TranscriptConfig) => {
    }, true);
  }

  private async saveKey(): Promise<void> {
    const key: string = this.apiKeyInput.trim();
    if (key === '') {
      this.message = this.text($r('app.string.transcript_settings_key_required'));
      return;
    }
    const saved: boolean = await TranscriptKeyStore.save(key);
    this.keyConfigured = saved;
    // 保存成功后保留输入框内容（之前清空会让人以为没保存成功）
    this.message = saved ? this.text($r('app.string.transcript_settings_key_saved_ok'))
      : this.text($r('app.string.transcript_settings_key_save_failed'));
    if (saved) {
      this.markChanged();
    }
  }

  private async deleteKey(): Promise<void> {
    await TranscriptKeyStore.remove();
    this.keyConfigured = false;
    this.apiKeyInput = '';
    this.markChanged();
    this.message = this.text($r('app.string.transcript_settings_key_deleted'));
  }

  /** 真实测试：上传内置短音频，必须拿到非空转写结果 */
  private async runTest(): Promise<void> {
    this.testing = true;
    // 立刻给出可见反馈：否则用户点下去后界面毫无变化（网络慢时尤其像「没反应」）
    this.message = this.text($r('app.string.transcript_settings_testing'));
    try {
      const baseUrl: string = TranscriptSettings.effectiveBaseUrl(this.config);
      if (baseUrl === '') {
        this.message = this.text($r('app.string.transcript_settings_err_url'));
        return;
      }
      if (!TranscriptSettings.isHttps(baseUrl)) {
        this.message = this.text($r('app.string.transcript_settings_err_https'));
        return;
      }
      if (this.config.model.trim() === '') {
        this.message = this.text($r('app.string.transcript_settings_err_model'));
        return;
      }
      // 通用模型下选了「非 OpenAI 兼容音频接口」的厂商：不要发请求，
      // 否则服务端只会回 404，界面显示「地址错误」，用户会误以为是地址填错。
      if (this.config.provider === TranscriptProviderKind.OPENAI) {
        const vendor: TranscriptVendor | undefined = TranscriptVendors.find(this.config.vendor);
        if (vendor !== undefined && vendor.protocol === 'unsupported') {
          this.message = vendor.name + '：' + vendor.note;
          return;
        }
        // 短音频模型：测试音频几秒，但提前把限制讲清楚
        if (vendor !== undefined && vendor.maxSeconds > 0) {
          this.message = '';
        }
      }
      const apiKey: string = await TranscriptKeyStore.load();
      if (apiKey === '') {
        this.keyConfigured = false;
        this.message = this.text($r('app.string.transcript_settings_err_key'));
        return;
      }
      this.keyConfigured = true;
      const audio: Uint8Array = this.testAudio();
      if (audio.length === 0) {
        this.message = this.text($r('app.string.transcript_settings_err_testaudio'));
        return;
      }
      const vendor: TranscriptVendor | undefined = TranscriptVendors.find(this.config.vendor);
      const outcome: TranscriptionOutcome = await TranscriptionProvider.transcribe({
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: this.config.model.trim(),
        language: this.config.language,
        audio: audio,
        fileName: 'transcript_test.wav',
        mimeType: 'audio/wav',
        protocol: vendor === undefined ? 'auto' : vendor.protocol,
        // 测试连接最多等 45 秒：超时就报超时，避免一直「测试中…」
        readTimeoutMs: 45000
      });
      const testedAt: number = Date.now();
      const okMessage: string = this.text($r('app.string.transcript_settings_test_ok_prefix'))
        + (outcome.timed ? this.text($r('app.string.transcript_settings_timed_yes'))
          : this.text($r('app.string.transcript_settings_timed_no')));
      this.commit((next: TranscriptConfig) => {
        next.testedAt = testedAt;
        next.testState = outcome.ok ? ProviderTestState.TESTED_OK : ProviderTestState.TESTED_FAILED;
        next.supportsTimestamps = outcome.ok ? outcome.timed : false;
        next.testedMessage = outcome.ok ? okMessage : outcome.message;
      }, false);
    } finally {
      this.testing = false;
    }
  }

  /** 打包在 rawfile 里的 1 秒测试音频 */
  private testAudio(): Uint8Array {
    try {
      const context: common.Context = getContext(this) as common.Context;
      const bytes: Uint8Array = context.resourceManager.getRawFileContentSync('transcript_test.wav');
      return bytes;
    } catch (error) {
      return new Uint8Array(0);
    }
  }

  private testStateText(): Resource {
    if (this.config.testState === ProviderTestState.TESTED_OK) {
      return $r('app.string.transcript_settings_state_ok');
    }
    if (this.config.testState === ProviderTestState.TESTED_FAILED) {
      return $r('app.string.transcript_settings_state_failed');
    }
    if (this.config.testState === ProviderTestState.NOT_TESTED) {
      return $r('app.string.transcript_settings_state_not_tested');
    }
    return $r('app.string.transcript_settings_state_not_configured');
  }

  private async refreshCacheStats(): Promise<void> {
    this.keyConfigured = await TranscriptKeyStore.has();
    const stats: Map<string, number> = await TranscriptRepository.stats();
    this.cacheCount = stats.get('count') === undefined ? 0 : stats.get('count') as number;
    const bytes: number = stats.get('bytes') === undefined ? 0 : stats.get('bytes') as number;
    this.cacheSize = bytes < 1024 ? bytes.toString() + ' B'
      : (bytes < 1024 * 1024 ? (bytes / 1024).toFixed(1) + ' KB'
        : (bytes / (1024 * 1024)).toFixed(1) + ' MB');
  }

  private async clearAiCache(): Promise<void> {
    const count: number = this.cacheCount;
    if (count === 0) {
      return;
    }
    // 仅清理 AI 生成的文字稿，官方文字稿保留
    await TranscriptRepository.deleteAllAi();
    await this.refreshCacheStats();
    this.message = this.text($r('app.string.transcript_settings_cache_cleared'));
  }
}
