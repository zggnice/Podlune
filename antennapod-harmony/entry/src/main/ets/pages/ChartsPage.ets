import router from '@ohos.router';
import { ChartEpisodeResolver } from '../services/ChartEpisodeResolver';
import { ChartService, RankItem, XyzList } from '../services/ChartService';
import { DesignTokens } from '../common/DesignTokens';
import { FeedCover } from '../components/FeedCover';

/**
 * 榜单页：两个大 Tab
 *   中文播客榜：热门节目 / 热门播客 / 新锐节目 / 新锐播客（xyzrank.com）
 *   苹果播客榜：热门播客（Apple cn 官方榜单）/ 热门节目（Apple 榜单节目的最新一集）
 *
 * 数据每天 08:00 换一次（见 ChartService.chartDay）。
 */
@Entry
@Component
struct ChartsPage {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  private static readonly TAB_CN: number = 0;
  private static readonly TAB_APPLE: number = 1;

  @State tab: number = 0;
  /** 中文榜子项：0 热门节目 1 热门播客 2 新锐节目 3 新锐播客 */
  @State sub: number = 0;
  /** 苹果榜子项：0 热门播客 1 热门节目 */
  @State appleSub: number = 0;
  @State loading: boolean = true;
  @State message: string = '';
  @State items: RankItem[] = [];
  /** 单集解析进行中（点卡片后要跑两次网络请求） */
  @State busy: boolean = false;
  private messageTimer: number = -1;

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    if (this.messageTimer >= 0) {
      clearTimeout(this.messageTimer);
      this.messageTimer = -1;
    }
  }

  async load(): Promise<void> {
    this.loading = true;
    this.message = '';
    this.items = [];
    try {
      if (this.tab === ChartsPage.TAB_CN) {
        const list: XyzList = this.sub === 0 ? XyzList.HOT_EPISODES
          : (this.sub === 1 ? XyzList.HOT_PODCASTS
            : (this.sub === 2 ? XyzList.NEW_EPISODES : XyzList.NEW_PODCASTS));
        this.items = await ChartService.xyz(list);
      } else if (this.appleSub === 0) {
        this.items = await ChartService.applePodcasts();
      } else {
        this.items = await ChartService.appleHotEpisodes();
      }
      if (this.items.length === 0) {
        this.message = '暂时拿不到榜单数据，点这里重试';
      }
    } catch (error) {
      this.message = (error as Error).message;
    } finally {
      this.loading = false;
    }
  }

  private switchMain(next: number): void {
    if (this.tab === next) {
      return;
    }
    this.tab = next;
    this.load();
  }

  private switchSub(next: number): void {
    if (this.sub === next) {
      return;
    }
    this.sub = next;
    this.load();
  }

  private switchAppleSub(next: number): void {
    if (this.appleSub === next) {
      return;
    }
    this.appleSub = next;
    this.load();
  }

  /**
   * 点卡片：
   * - 节目条目（热门节目/新锐节目/热门单集）：按「播客名 + 单集标题」反查 RSS，
   *   生成单集快照后进入**单集详情页**（可只读浏览 + 在线播放）；
   * - 播客条目：有 feedUrl 直接进播客详情；缺 feedUrl 时用名字反查后再进。
   */
  private async openItem(item: RankItem): Promise<void> {
    if (!item.isEpisode) {
      // 播客条目：有 feedUrl 直接进；没有就按名字反查
      if (item.feedUrl !== '') {
        this.pushFeed(item.feedUrl, item.title, item.subtitle, item.imageUrl);
        return;
      }
      this.busy = true;
      const feedUrl: string = await ChartEpisodeResolver.feedUrlByName(item.title);
      this.busy = false;
      if (feedUrl !== '') {
        this.pushFeed(feedUrl, item.title, item.subtitle, item.imageUrl);
      } else {
        this.notify('找不到该播客的订阅源，试试搜索节目名');
      }
      return;
    }
    // 单集条目：解析出快照后进单集详情
    this.busy = true;
    this.notify('');
    const resolved = await ChartEpisodeResolver.resolve(item.podcastName, item.title, item.imageUrl,
      item.feedUrl);
    this.busy = false;
    if (resolved.previewJson !== '') {
      router.pushUrl({
        url: 'pages/EpisodeDetailPage',
        params: { itemId: 0, previewJson: resolved.previewJson }
      });
      return;
    }
    this.notify('没能在节目源里匹配到这一集，可先进入播客查看最新单集');
  }

  /** 轻提示（顶部消息条，2.5 秒后消失） */
  private notify(text: string): void {
    this.message = text;
    if (this.messageTimer >= 0) {
      clearTimeout(this.messageTimer);
      this.messageTimer = -1;
    }
    if (text === '') {
      return;
    }
    this.messageTimer = setTimeout(() => {
      this.message = '';
      this.messageTimer = -1;
    }, 2500);
  }

  private pushFeed(feedUrl: string, title: string, author: string, imageUrl: string): void {
    router.pushUrl({
      url: 'pages/FeedDetailPage',
      params: {
        feedUrl: feedUrl,
        previewTitle: title,
        previewAuthor: author,
        previewImageUrl: imageUrl
      }
    });
  }

  build() {
    Column() {
      // 顶栏
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

        Text($r('app.string.charts_title')).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_FLOAT_TITLE)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Text($r('app.string.charts_daily_note')).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_CAPTION)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      .height(DesignTokens.HEIGHT_FLOAT_TOP_BAR)
      .padding({ left: DesignTokens.SPACE_S, right: DesignTokens.PAGE_MARGIN })
      .alignItems(VerticalAlign.Center)

      // 消息条 / 解析中
      if (this.message !== '' || this.busy) {
        Row({ space: DesignTokens.SPACE_XS }) {
          if (this.busy) {
            LoadingProgress().width(16).height(16).color($r('app.color.text_secondary'))
          }
          Text(this.busy ? '正在查找该单集…' : this.message).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_FOOTNOTE)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
            .maxLines(2)
        }
        .width('100%')
        .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN,
          top: DesignTokens.SPACE_XS, bottom: DesignTokens.SPACE_XS })
      }

      // 主 Tab
      Row({ space: DesignTokens.SPACE_XS }) {
        this.mainTab($r('app.string.charts_tab_cn'), ChartsPage.TAB_CN)
        this.mainTab($r('app.string.charts_tab_apple'), ChartsPage.TAB_APPLE)
      }
      .width('100%')
      .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })

      // 子 Tab
      Row({ space: DesignTokens.SPACE_XS }) {
        if (this.tab === ChartsPage.TAB_CN) {
          this.subTab($r('app.string.charts_sub_hot_episodes'), 0)
          this.subTab($r('app.string.charts_sub_hot_podcasts'), 1)
          this.subTab($r('app.string.charts_sub_new_episodes'), 2)
          this.subTab($r('app.string.charts_sub_new_podcasts'), 3)
        } else {
          this.subTab($r('app.string.charts_sub_apple_shows'), 0)
          this.subTab($r('app.string.charts_sub_apple_episodes'), 1)
        }
      }
      .width('100%')
      .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN,
        top: DesignTokens.SPACE_S, bottom: DesignTokens.SPACE_S })

      if (this.loading) {
        Column() {
          LoadingProgress().width(40).height(40).color($r('app.color.text_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.items.length === 0) {
        Column() {
          Text(this.message === '' ? $r('app.string.charts_empty') : this.message).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_BODY)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.load();
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: DesignTokens.SPACE_M }) {
          ForEach(this.items, (item: RankItem) => {
            ListItem() {
              this.rankRow(item)
            }
          }, (item: RankItem) => item.rank.toString() + '|' + item.title)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
        .contentEndOffset(DesignTokens.SPACE_XXL)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder
  mainTab(label: ResourceStr, index: number) {
    Text(label).fontFamily(this.appFontFamily)
      .fontSize(DesignTokens.FONT_SUBTITLE)
      .fontWeight(this.tab === index ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.tab === index ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
      .padding({ right: DesignTokens.SPACE_L, top: DesignTokens.SPACE_XS, bottom: DesignTokens.SPACE_XS })
      .onClick(() => {
        this.switchMain(index);
      })
  }

  @Builder
  subTab(label: ResourceStr, index: number) {
    Text(label).fontFamily(this.appFontFamily)
      .fontSize(DesignTokens.FONT_FOOTNOTE)
      .fontColor(this.tab === ChartsPage.TAB_CN
        ? (this.sub === index ? $r('app.color.on_primary') : $r('app.color.text_secondary'))
        : (this.appleSub === index ? $r('app.color.on_primary') : $r('app.color.text_secondary')))
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(14)
      .backgroundColor(this.tab === ChartsPage.TAB_CN
        ? (this.sub === index ? $r('app.color.primary') : $r('app.color.player_chip'))
        : (this.appleSub === index ? $r('app.color.primary') : $r('app.color.player_chip')))
      .onClick(() => {
        if (this.tab === ChartsPage.TAB_CN) {
          this.switchSub(index);
        } else {
          this.switchAppleSub(index);
        }
      })
  }

  @Builder
  rankRow(item: RankItem) {
    Row({ space: DesignTokens.SPACE_M }) {
      Text(item.rank.toString()).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_FOOTNOTE)
        .fontWeight(FontWeight.Medium)
        .fontColor(item.rank <= 3 ? $r('app.color.primary') : $r('app.color.text_tertiary'))
        .width(26)
        .textAlign(TextAlign.Center)

      FeedCover({ imageUrl: item.imageUrl, coverSize: 56, radius: 12 })

      Column({ space: 4 }) {
        Text(item.title).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_BODY)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.metaText(item)).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_FOOTNOTE)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(DesignTokens.SPACE_M)
    .borderRadius(22)
    .backgroundColor($r('app.color.search_card_bg'))
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.openItem(item);
    })
  }

  private metaText(item: RankItem): string {
    let text: string = item.subtitle;
    if (item.playCount > 0) {
      text += (text === '' ? '' : ' · ') + this.shortCount(item.playCount) + ' 播放';
    }
    if (item.durationMin > 0) {
      text += ' · ' + item.durationMin + ' 分钟';
    }
    return text;
  }

  private shortCount(value: number): string {
    if (value >= 10000) {
      return (value / 10000).toFixed(1) + '万';
    }
    return value.toString();
  }
}
