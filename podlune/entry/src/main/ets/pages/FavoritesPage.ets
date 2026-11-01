import router from '@ohos.router';
import { FeedItem } from '../model/FeedItem';
import { MediaType } from '../model/Enums';
import { FavoritesRepository } from '../db/repositories/FavoritesRepository';
import { LazyDataSource } from '../components/LazyDataSource';
import { DurationUtils } from '../utils/DurationUtils';
import { DesignTokens } from '../common/DesignTokens';
import { openEpisodeDetail } from '../common/EpisodeRoute';
import { AppBar } from '../components/AppBar';
import { AppIconButton } from '../components/AppIconButton';
import { EpisodeRow } from '../components/EpisodeRow';
import { EmptyState } from '../components/EmptyState';

/**
 * 收藏页（对齐上游 `episodes_list_fragment.xml` + `FavoritesFragment`）：
 * 56vp 标题栏（返回箭头 + 搜索动作），下方为共享 `EpisodeRow` 剧集列表
 * （上游 `feeditemlist_item.xml`：56vp 封面 + 状态行（含收藏星标）+ 两行标题 + 位置/时长进度行），
 * 右侧次级操作沿用原页面的「取消收藏」星标按钮。
 */
@Entry
@Component
struct FavoritesPage {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  private dataSource: LazyDataSource<FeedItem> = new LazyDataSource<FeedItem>();
  @State items: FeedItem[] = [];
  /** 页内搜索：只过滤本页收藏，不去底栏的全局搜索 */
  @State searchActive: boolean = false;
  @State searchTerm: string = '';
  @State loading: boolean = false;
  @State message: string = '';

  build() {
    Column() {
      if (this.searchActive) {
        this.searchBar()
      } else {
        AppBar({ title: $r('app.string.favorites_title'), showBack: true }) {
          AppIconButton({
            symbol: $r('sys.symbol.magnifyingglass'),
            onTap: () => {
              this.searchActive = true;
            }
          })
        }
      }

      if (this.message !== '') {
        Text(this.message).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_FOOTNOTE)
          .fontColor($r('app.color.primary'))
          .width('100%')
          .padding({ left: DesignTokens.PAGE_MARGIN, bottom: DesignTokens.SPACE_S })
      }

      if (this.loading) {
        Text($r('app.string.loading')).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_PARAGRAPH)
          .fontColor($r('app.color.text_tertiary'))
          .layoutWeight(1)
      } else if (this.items.length === 0) {
        Column() {
          EmptyState({
            icon: $r('sys.symbol.star'),
            title: $r('app.string.favorites_empty'),
            sub: $r('app.string.favorites_empty_hint')
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: DesignTokens.SPACE_XS }) {
          LazyForEach(this.dataSource, (item: FeedItem) => {
            ListItem() {
              this.favoriteRow(item)
            }
          }, (item: FeedItem) => item.id.toString())
        }
        .layoutWeight(1)
        .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN, bottom: DesignTokens.SPACE_M })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    // 沉浸式状态栏：把页面背景的绘制区延伸到状态栏下（不改布局，内容仍避开状态栏）
    // 底部也沉浸：让页面背景延伸到手势条下方，避免底部出现一条系统色带
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  favoriteRow(item: FeedItem) {
    EpisodeRow({
      rowItem: item,
      showMore: true,
      reference: true,
      title: item.title,
      imageUrl: item.imageUrl,
      metaText: this.metaText(item),
      positionText: this.positionText(item),
      durationText: this.durationText(item),
      progress: this.progress(item),
      isPlayed: item.isPlayed,
      isNew: item.isNew(),
      isFavorite: true,
      isVideo: item.media !== undefined && item.media.getMediaType() === MediaType.VIDEO,
      actionIcon: $r('sys.symbol.star_fill'),
      actionTint: $r('app.color.star'),
      onTap: () => {
        // 单击 = 打开单集详情页（与收件箱一致）；取消收藏仍走右侧星标钮
        openEpisodeDetail(item.id);
      },
      onAction: () => {
        this.remove(item);
      }
    })
  }

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    try {
      const items: FeedItem[] = await FavoritesRepository.list();
      this.items = items;
      this.applySearch();
    } catch (error) {
      this.items = [];
      this.dataSource.setData([]);
      this.message = (error as Error).message;
    } finally {
      this.loading = false;
    }
  }

  /**
   * 页内搜索栏：与单集页同一套版式（左右 16vp 边距 + 放大镜胶囊 + 取消）。
   * 搜的是「本页收藏」，不是底栏那个全局搜索。
   */
  @Builder
  searchBar() {
    Row({ space: DesignTokens.SPACE_S }) {
      Row({ space: DesignTokens.SPACE_S }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(DesignTokens.ICON_M)
          .fontColor([$r('app.color.text_tertiary')])
        TextInput({ placeholder: $r('app.string.favorites_search_hint'), text: this.searchTerm }).fontFamily(this.appFontFamily)
          .layoutWeight(1)
          .height(40)
          .padding(0)
          .fontSize(DesignTokens.FONT_SUBTITLE)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .caretColor($r('app.color.primary'))
          .backgroundColor(Color.Transparent)
          .onChange((value: string) => {
            this.searchTerm = value;
            this.applySearch();
          })
      }
      .layoutWeight(1)
      .height(40)
      .padding({ left: DesignTokens.SPACE_M, right: DesignTokens.SPACE_M })
      .borderRadius(DesignTokens.RADIUS_BUTTON)
      .backgroundColor($r('app.color.surface_secondary'))
      .alignItems(VerticalAlign.Center)

      Text($r('app.string.cancel_label')).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_SUBTITLE)
        .fontColor($r('app.color.primary'))
        .onClick(() => {
          this.searchActive = false;
          this.searchTerm = '';
          this.applySearch();
        })
    }
    .width('100%')
    .padding({
      left: DesignTokens.PAGE_MARGIN,
      right: DesignTokens.PAGE_MARGIN,
      top: DesignTokens.SPACE_S,
      bottom: DesignTokens.SPACE_S
    })
    .alignItems(VerticalAlign.Center)
  }

  /** 按关键字过滤标题（空串＝不过滤），结果写回列表数据源 */
  private applySearch(): void {
    const term: string = this.searchTerm.trim().toLowerCase();
    const list: FeedItem[] = term === ''
      ? this.items
      : this.items.filter((item: FeedItem) => item.title.toLowerCase().includes(term));
    this.dataSource.setData(list);
  }
  async remove(item: FeedItem): Promise<void> {
    try {
      await FavoritesRepository.remove(item.id);
      await this.load();
    } catch (error) {
      this.message = (error as Error).message;
    }
  }

  /** 状态行：发布日期 · 文件大小（上游 feeditemlist_item.xml 的 txtvPubDate + size） */
  metaText(item: FeedItem): string {
    const parts: string[] = [];
    if (item.pubDate > 0) {
      parts.push(new Date(item.pubDate).toLocaleDateString());
    }
    if (item.media !== undefined && item.media.size > 0) {
      const mb: number = item.media.size / (1024 * 1024);
      parts.push(mb < 1 ? (item.media.size / 1024).toFixed(0) + ' KB' : mb.toFixed(1) + ' MB');
    }
    return parts.join(' · ');
  }

  positionText(item: FeedItem): string {
    if (item.media === undefined || item.media.position <= 0) {
      return '';
    }
    return DurationUtils.format(item.media.position);
  }

  durationText(item: FeedItem): string {
    if (item.media === undefined || item.media.duration <= 0) {
      return '';
    }
    return DurationUtils.format(item.media.duration);
  }

  progress(item: FeedItem): number {
    if (item.media === undefined || item.media.duration <= 0 || item.media.position <= 0) {
      return 0;
    }
    const percent: number = Math.floor(item.media.position * 100 / item.media.duration);
    return percent > 100 ? 100 : (percent < 5 ? 5 : percent);
  }
}
