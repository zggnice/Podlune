import router from '@ohos.router';
import { SubscriptionService } from '../services/SubscriptionService';
import { HttpClient, HttpResponse } from '../net/HttpClient';
import { EventHub, EventType, FeedUpdateData } from '../events/EventHub';
import { DesignTokens } from '../common/DesignTokens';
import { AppBar } from '../components/AppBar';
import { RowCard } from '../components/RowCard';

/**
 * Add podcast（对齐上游 `addfeed.xml`）：
 * 顶部圆角搜索卡片（圆角 28vp、48×48 图标按钮 + 上下 16vp 内边距的输入框、左右 16vp 外边距）
 * + 6 行 AddPodcastTextView（minHeight 48vp、上下 8vp、左右 16vp、图标与文字间距 8vp、标签 14sp）。
 */
@Entry
@Component
struct AddFeedPage {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  @State url: string = '';
  @State username: string = '';
  @State password: string = '';
  @State showAuth: boolean = false;
  @State message: string = '';
  @State loading: boolean = false;
  @State searchTerm: string = '';
  @State showUrlInput: boolean = true;

  build() {
    Column() {
      AppBar({ title: $r('app.string.more_add_feed'), showBack: true })

      Scroll() {
        Column() {
          // 3.1.1 搜索卡片：**只保留一层胶囊**（原先 Row 有底色 + TextInput 又有底色，
          // 图标外层还有个 48×48 的白色方块 → 出现「白胶囊 + 灰胶囊」叠层）。
          Row({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(20)
              .fontColor([$r('app.color.text_tertiary')])
              .margin({ left: DesignTokens.SPACE_M })

            TextInput({ placeholder: $r('app.string.search_podcast_hint'), text: this.searchTerm }).fontFamily(this.appFontFamily)
              .layoutWeight(1)
              .height(50)
              .padding({ left: 0, right: DesignTokens.SPACE_M, top: 0, bottom: 0 })
              .fontSize(16)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_tertiary'))
              // 关键：输入框自身必须透明，否则会在胶囊里再叠一层异色
              .backgroundColor(Color.Transparent)
              .borderRadius(0)
              .onChange((value: string) => {
                this.searchTerm = value;
              })
              .onSubmit(() => {
                this.performSearch();
              })
          }
          .width('100%')
          .height(50)
          .alignItems(VerticalAlign.Center)
          .backgroundColor($r('app.color.surface_secondary'))
          .borderRadius(25)
          .margin({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
          .padding({ right: DesignTokens.SPACE_XS })

          // 6.2 行 1：Add podcast by RSS address（保留既有 URL 输入 + 私有订阅认证）
          Column() {
            Row({ space: DesignTokens.SPACE_S }) {
              SymbolGlyph($r('sys.symbol.link'))
                .fontSize(DesignTokens.ICON_XL)
                .fontColor([$r('app.color.text_primary')])
              Text($r('app.string.add_podcast_by_url')).fontFamily(this.appFontFamily)
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
              SymbolGlyph(this.showUrlInput ? $r('sys.symbol.arrow_up') : $r('sys.symbol.arrow_down'))
                .fontSize(DesignTokens.ICON_S)
                .fontColor([$r('app.color.text_tertiary')])
            }
            .width('100%')
            .constraintSize({ minHeight: 48 })
            .padding({
              left: DesignTokens.PAGE_MARGIN,
              right: DesignTokens.PAGE_MARGIN,
              top: DesignTokens.SPACE_S,
              bottom: DesignTokens.SPACE_S
            })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.showUrlInput = !this.showUrlInput;
            })

            if (this.showUrlInput) {
              Column() {
                RowCard({ pad: DesignTokens.SPACE_L, radius: DesignTokens.RADIUS_CARD }) {
                  Column({ space: DesignTokens.SPACE_M }) {
                    Row({ space: DesignTokens.SPACE_S }) {
                      SymbolGlyph($r('sys.symbol.arrow_down_circle'))
                        .fontSize(DesignTokens.ICON_L)
                        .fontColor([$r('app.color.primary')])
                      TextInput({ placeholder: 'https://example.com/feed.xml', text: this.url }).fontFamily(this.appFontFamily)
                        .layoutWeight(1)
                        .height(DesignTokens.HEIGHT_BUTTON)
                        .fontSize(DesignTokens.FONT_PARAGRAPH)
                        .backgroundColor($r('app.color.surface_secondary'))
                        .onChange((value: string) => {
                          this.url = value;
                        })
                      if (this.url !== '') {
                        SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
                          .fontSize(DesignTokens.ICON_M)
                          .fontColor([$r('app.color.text_disabled')])
                          .onClick(() => {
                            this.url = '';
                            this.message = '';
                          })
                      }
                    }
                    .width('100%')

                    Row({ space: DesignTokens.SPACE_S }) {
                      SymbolGlyph($r('sys.symbol.lock'))
                        .fontSize(DesignTokens.ICON_L)
                        .fontColor([$r('app.color.text_secondary')])
                      Text($r('app.string.add_feed_auth')).fontFamily(this.appFontFamily)
                        .fontSize(DesignTokens.FONT_BODY)
                        .fontColor($r('app.color.text_primary'))
                        .layoutWeight(1)
                      Toggle({ type: ToggleType.Switch, isOn: this.showAuth })
                        .selectedColor($r('app.color.primary'))
                        .onChange((isOn: boolean) => {
                          this.showAuth = isOn;
                        })
                    }
                    .width('100%')

                    if (this.showAuth) {
                      TextInput({ text: this.username, placeholder: $r('app.string.setting_username') }).fontFamily(this.appFontFamily)
                        .width('100%')
                        .height(DesignTokens.HEIGHT_BUTTON)
                        .fontSize(DesignTokens.FONT_PARAGRAPH)
                        .backgroundColor($r('app.color.surface_secondary'))
                        .onChange((value: string) => {
                          this.username = value;
                        })
                      TextInput({ text: this.password, placeholder: $r('app.string.setting_password') }).fontFamily(this.appFontFamily)
                        .width('100%')
                        .height(DesignTokens.HEIGHT_BUTTON)
                        .fontSize(DesignTokens.FONT_PARAGRAPH)
                        .type(InputType.Password)
                        .backgroundColor($r('app.color.surface_secondary'))
                        .onChange((value: string) => {
                          this.password = value;
                        })
                    }

                    if (this.message !== '') {
                      Row({ space: DesignTokens.SPACE_XS }) {
                        SymbolGlyph($r('sys.symbol.warning'))
                          .fontSize(DesignTokens.ICON_S)
                          .fontColor([$r('app.color.error')])
                        Text(this.message).fontFamily(this.appFontFamily)
                          .fontSize(DesignTokens.FONT_FOOTNOTE)
                          .fontColor($r('app.color.error'))
                          .layoutWeight(1)
                      }
                      .width('100%')
                    }

                    Button(this.loading ? $r('app.string.loading') : $r('app.string.subscribe'))
                      .width('100%')
                      .height(DesignTokens.HEIGHT_BUTTON)
                      .fontSize(DesignTokens.FONT_PARAGRAPH)
                      .backgroundColor($r('app.color.primary'))
                      .fontColor($r('app.color.on_primary'))
                      .enabled(!this.loading)
                      .onClick(() => {
                        this.subscribe();
                      })
                  }
                  .width('100%')
                }
              }
              .width('100%')
              .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
            }

            Divider().color($r('app.color.divider'))
          }
          .width('100%')

          // 6.2 行 2：Add local folder（本端无本地文件夹订阅能力 → 置灰不可点）
          Column() {
            Row({ space: DesignTokens.SPACE_S }) {
              SymbolGlyph($r('sys.symbol.folder'))
                .fontSize(DesignTokens.ICON_XL)
                .fontColor([$r('app.color.text_disabled')])
              Text($r('app.string.add_local_folder')).fontFamily(this.appFontFamily)
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor($r('app.color.text_disabled'))
                .layoutWeight(1)
            }
            .width('100%')
            .constraintSize({ minHeight: 48 })
            .padding({
              left: DesignTokens.PAGE_MARGIN,
              right: DesignTokens.PAGE_MARGIN,
              top: DesignTokens.SPACE_S,
              bottom: DesignTokens.SPACE_S
            })
            .alignItems(VerticalAlign.Center)

            Divider().color($r('app.color.divider'))
          }
          .width('100%')

          // 6.2 行 3：Search Apple Podcasts（复用现有 iTunes 搜索页）
          Column() {
            Row({ space: DesignTokens.SPACE_S }) {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(DesignTokens.ICON_XL)
                .fontColor([$r('app.color.text_primary')])
              Text($r('app.string.search_itunes_label')).fontFamily(this.appFontFamily)
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
            }
            .width('100%')
            .constraintSize({ minHeight: 48 })
            .padding({
              left: DesignTokens.PAGE_MARGIN,
              right: DesignTokens.PAGE_MARGIN,
              top: DesignTokens.SPACE_S,
              bottom: DesignTokens.SPACE_S
            })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              router.pushUrl({ url: 'pages/SearchPage', params: { term: this.searchTerm } });
            })

            Divider().color($r('app.color.divider'))
          }
          .width('100%')

          // 6.2 行 4：Search fyyd（本端未接入 fyyd → 置灰不可点）
          Column() {
            Row({ space: DesignTokens.SPACE_S }) {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(DesignTokens.ICON_XL)
                .fontColor([$r('app.color.text_disabled')])
              Text($r('app.string.search_fyyd_label')).fontFamily(this.appFontFamily)
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor($r('app.color.text_disabled'))
                .layoutWeight(1)
            }
            .width('100%')
            .constraintSize({ minHeight: 48 })
            .padding({
              left: DesignTokens.PAGE_MARGIN,
              right: DesignTokens.PAGE_MARGIN,
              top: DesignTokens.SPACE_S,
              bottom: DesignTokens.SPACE_S
            })
            .alignItems(VerticalAlign.Center)

            Divider().color($r('app.color.divider'))
          }
          .width('100%')

          // 6.2 行 5：Search Podcast Index（本端未接入 Podcast Index → 置灰不可点）
          Column() {
            Row({ space: DesignTokens.SPACE_S }) {
              SymbolGlyph($r('sys.symbol.magnifyingglass'))
                .fontSize(DesignTokens.ICON_XL)
                .fontColor([$r('app.color.text_disabled')])
              Text($r('app.string.search_podcastindex_label')).fontFamily(this.appFontFamily)
                .fontSize(DesignTokens.FONT_BODY)
                .fontColor($r('app.color.text_disabled'))
                .layoutWeight(1)
            }
            .width('100%')
            .constraintSize({ minHeight: 48 })
            .padding({
              left: DesignTokens.PAGE_MARGIN,
              right: DesignTokens.PAGE_MARGIN,
              top: DesignTokens.SPACE_S,
              bottom: DesignTokens.SPACE_S
            })
            .alignItems(VerticalAlign.Center)

            Divider().color($r('app.color.divider'))
          }
          .width('100%')

          // 6.2 行 6：Import podcast list (OPML)（复用既有 OPML 页）
          Row({ space: DesignTokens.SPACE_S }) {
            SymbolGlyph($r('sys.symbol.download_1'))
              .fontSize(DesignTokens.ICON_XL)
              .fontColor([$r('app.color.text_primary')])
            Text($r('app.string.opml_add_podcast_label')).fontFamily(this.appFontFamily)
              .fontSize(DesignTokens.FONT_BODY)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1)
          }
          .width('100%')
          .constraintSize({ minHeight: 48 })
          .padding({
            left: DesignTokens.PAGE_MARGIN,
            right: DesignTokens.PAGE_MARGIN,
            top: DesignTokens.SPACE_S,
            bottom: DesignTokens.SPACE_S
          })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            router.pushUrl({ url: 'pages/OpmlPage' });
          })
        }
        .width('100%')
        .padding({ bottom: DesignTokens.SPACE_L })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    // 沉浸式：背景绘制区同时延伸到状态栏与底部手势区（内容仍避开安全区）
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 搜索卡片：URL 直接填入下方输入框，其余走既有在线搜索页 */
  performSearch(): void {
    const query: string = this.searchTerm.trim();
    if (query === '') {
      return;
    }
    if (AddFeedPage.isValidUrl(query)) {
      this.url = query;
      this.showUrlInput = true;
      this.message = '';
      return;
    }
    router.pushUrl({ url: 'pages/SearchPage', params: { term: query } });
  }

  async subscribe(): Promise<void> {
    const trimmed: string = this.url.trim();
    if (trimmed === '') {
      this.message = getContext(this).resourceManager.getStringSync($r('app.string.add_url_empty'));
      return;
    }
    if (!AddFeedPage.isValidUrl(trimmed)) {
      this.message = getContext(this).resourceManager.getStringSync($r('app.string.add_url_invalid'));
      return;
    }
    this.loading = true;
    this.message = '';
    try {
      const feed = await SubscriptionService.subscribe(trimmed, this.username.trim(), this.password);
      this.message = getContext(this).resourceManager.getStringSync($r('app.string.subscribe_success')) + feed.getTitle();
      const data: FeedUpdateData = { feedId: feed.id };
      EventHub.publish(EventType.FEED_LIST_UPDATE, data);
      router.back();
      return;
    } catch (error) {
      // 普通网页 URL：尝试从 HTML <link rel="alternate"> 自动发现订阅源（上游 FeedDiscoverer）
      const discovered: string = await this.discoverFeed(trimmed);
      if (discovered === '') {
        this.message = getContext(this).resourceManager.getStringSync($r('app.string.subscribe_failed'))
          + (error as Error).message;
        this.loading = false;
        return;
      }
      try {
        const feed = await SubscriptionService.subscribe(discovered, this.username.trim(), this.password);
        this.message = getContext(this).resourceManager.getStringSync($r('app.string.subscribe_success')) + feed.getTitle();
        const data: FeedUpdateData = { feedId: feed.id };
        EventHub.publish(EventType.FEED_LIST_UPDATE, data);
        router.back();
      } catch (retryError) {
        this.message = getContext(this).resourceManager.getStringSync($r('app.string.subscribe_failed'))
          + (retryError as Error).message;
      }
    } finally {
      this.loading = false;
    }
  }

  /** HTML 自动发现：抓网页 → 解析 <link rel="alternate" type="application/rss+xml"> */
  private async discoverFeed(pageUrl: string): Promise<string> {
    try {
      const response: HttpResponse = await HttpClient.get(pageUrl);
      const match: RegExpMatchArray | null = response.body.match(
        /<link[^>]+(?:application\/rss\+xml|application\/atom\+xml)[^>]*>/i
      );
      if (match === null) {
        return '';
      }
      const hrefMatch: RegExpMatchArray | null = match[0].match(/href=["']([^"']+)["']/i);
      if (hrefMatch === null || hrefMatch[1] === undefined) {
        return '';
      }
      const href: string = hrefMatch[1];
      if (href.startsWith('http')) {
        return href;
      }
      // 相对 URL：按页面地址补全（含协议相对 //host/path）
      const origin: string = pageUrl.replace(/^(https?:\/\/[^/]+).*$/i, '$1');
      return href.startsWith('//') ? 'https:' + href : origin + (href.startsWith('/') ? href : '/' + href);
    } catch (error) {
      return '';
    }
  }

  /** 订阅前校验：必须是 http(s) URL 且带主机名（与上游 URL 校验语义一致） */
  static isValidUrl(value: string): boolean {
    const pattern: RegExp = /^https?:\/\/[^\s/$.?#][^\s]*$/i;
    if (!pattern.test(value)) {
      return false;
    }
    const withoutScheme: string = value.replace(/^https?:\/\//i, '');
    const host: string = withoutScheme.split('/')[0];
    return host.length > 0 && host.indexOf('.') > 0;
  }
}
