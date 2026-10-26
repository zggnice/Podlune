// 文字稿阅读页：深色沉浸式阅读（对照需求图 1 的版式）。
// 官方文字稿优先；有时间戳时跟随播放高亮、点按跳转；支持全文搜索。
import router from '@ohos.router';
import { UserPreferences } from '../prefs/UserPreferences';
import { DesignTokens } from '../common/DesignTokens';
import { EpisodeRepository } from '../db/repositories/EpisodeRepository';
import { TranscriptRepository } from '../db/repositories/TranscriptRepository';
import { FeedItem } from '../model/FeedItem';
import { FeedMedia } from '../model/FeedMedia';
import { TranscriptDocument, TranscriptSegment, TranscriptSourceType, Transcripts } from '../model/Transcript';
import { OfficialTranscriptProvider, OfficialTranscriptResult } from '../services/transcript/OfficialTranscriptProvider';
import { PlayerManager } from '../player/PlayerManager';
import { EventHub, EventType, PlaybackPositionData } from '../events/EventHub';
import { FeedCover } from '../components/FeedCover';
import { LazyDataSource } from '../components/LazyDataSource';
import fs from '@ohos.file.fs';
import { TranscriptConfig, TranscriptKeyStore, TranscriptSettings, TranscriptProviderKind } from '../prefs/TranscriptSettings';
import { TranscriptionOutcome, TranscriptionProvider } from '../services/transcript/TranscriptionProvider';

interface SearchHit {
  index: number;
  preview: string;
}

@Entry
@Component
export struct TranscriptPage {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  /** 单次上传上限（OpenAI 音频转写为 25MB）；超过即明确报错，不做假分段 */
  private static readonly AI_MAX_BYTES: number = 25 * 1024 * 1024;

  @State episodeId: number = 0;
  @State item: FeedItem | undefined = undefined;
  @State doc: TranscriptDocument | undefined = undefined;
  @State loading: boolean = true;
  @State message: string = '';
  @State activeIndex: number = -1;
  @State autoFollow: boolean = true;
  @State searchActive: boolean = false;
  @State searchTerm: string = '';
  @State aiConfig: TranscriptConfig = TranscriptSettings.load();
  @State generating: boolean = false;
  @State aiMessage: string = '';
  @State hits: SearchHit[] = [];
  /** 阅读字号（vp）：设置后立即重排正文并持久化 */
  @State fontSize: number = UserPreferences.getTranscriptFontSize();
  private positionToken: number = -1;
  private scroller: Scroller = new Scroller();
  private dataSource: LazyDataSource<TranscriptSegment> = new LazyDataSource<TranscriptSegment>();

  build() {
    Column() {
      // 顶部导航（左返回 / 中间标题 / 右侧搜索与更多）
      Row({ space: DesignTokens.SPACE_XS }) {
        Stack() {
          SymbolGlyph($r('sys.symbol.chevron_backward'))
            .fontSize(DesignTokens.ICON_XL)
            .fontColor([$r('app.color.player_text')])
        }
        .width(DesignTokens.HIT_MIN)
        .height(DesignTokens.HIT_MIN)
        .alignContent(Alignment.Center)
        .onClick(() => {
          router.back();
        })

        Text($r('app.string.player_transcript')).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_TITLE2)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.player_text'))
          .layoutWeight(1)

        Stack() {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(DesignTokens.ICON_L)
            .fontColor([$r('app.color.player_text')])
        }
        .width(DesignTokens.HIT_MIN)
        .height(DesignTokens.HIT_MIN)
        .alignContent(Alignment.Center)
        .onClick(() => {
          this.searchActive = !this.searchActive;
          this.searchTerm = '';
          this.hits = [];
        })

        Stack() {
          SymbolGlyph($r('sys.symbol.ellipsis_circle'))
            .fontSize(DesignTokens.ICON_L)
            .fontColor([$r('app.color.player_text')])
        }
        .width(DesignTokens.HIT_MIN)
        .height(DesignTokens.HIT_MIN)
        .alignContent(Alignment.Center)
        .bindMenu([
          {
            value: $r('app.string.transcript_refetch'),
            action: () => {
              this.reload(true);
            }
          },
          {
            value: $r('app.string.transcript_font_larger'),
            action: () => {
              this.changeFontSize(2);
            }
          },
          {
            value: $r('app.string.transcript_font_smaller'),
            action: () => {
              this.changeFontSize(-2);
            }
          },
          {
            value: $r('app.string.transcript_clear_cache'),
            action: () => {
              this.clearCache();
            }
          }
        ])
      }
      .width('100%')
      .padding({ left: DesignTokens.SPACE_S, right: DesignTokens.SPACE_XS })
      .height(DesignTokens.HEIGHT_APP_BAR)

      if (this.searchActive) {
        this.searchBar()
      }

      if (this.item !== undefined) {
        this.episodeHeader(this.item as FeedItem)
      }

      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(36)
            .height(36)
            .color($r('app.color.player_text'))
          Text($r('app.string.transcript_loading')).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_SUBTITLE)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: DesignTokens.SPACE_M })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.doc === undefined) {
        this.emptyState()
      } else {
        this.body()
      }
    }
    .width('100%')
    .height('100%')
    // 深色阅读底色（与需求图一致的青黑渐变）
    // 背景与播放器一致：浅色为白、深色为黑，文字用主题正文色保证可读性
    .backgroundColor($r('app.color.player_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 进入页面：取单集 id、加载文字稿、订阅播放位置 */
  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params !== undefined && params['episodeId'] !== undefined) {
      this.episodeId = Number(params['episodeId']);
    }
    this.load();
    this.positionToken = EventHub.subscribe(EventType.PLAYBACK_POSITION, (data: object) => {
      this.onPosition(data as PlaybackPositionData);
    });
  }

  aboutToDisappear(): void {
    if (this.positionToken >= 0) {
      EventHub.unsubscribeToken(this.positionToken);
      this.positionToken = -1;
    }
  }

  @Builder
  episodeHeader(item: FeedItem) {
    Row({ space: DesignTokens.SPACE_M }) {
      // 封面可能本身就是白底图：给一个浅色底 + 细描边，浅色模式下也能看清边界
      Stack() {
        FeedCover({
          imageUrl: item.imageUrl !== '' ? item.imageUrl : item.feedImage,
          coverSize: 52,
          radius: 8,
          placeholderColor: $r('app.color.cover_placeholder')
        })
      }
      .width(52)
      .height(52)
      .borderRadius(8)
      .backgroundColor($r('app.color.surface_secondary'))
      .border({ width: 0.5, color: $r('app.color.divider') })
      .alignContent(Alignment.Center)

      Column({ space: 4 }) {
        Text(item.title).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.player_text'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: DesignTokens.SPACE_S }) {
          Text(item.feedTitle).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_FOOTNOTE)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .layoutWeight(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.doc !== undefined) {
            Text(this.doc?.isAiGenerated ? $r('app.string.transcript_source_ai')
              : $r('app.string.transcript_source_official')).fontFamily(this.appFontFamily)
              .fontSize(DesignTokens.FONT_FOOTNOTE)
              .fontColor($r('app.color.text_secondary'))
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .borderRadius(6)
              .backgroundColor($r('app.color.surface_secondary'))
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN, bottom: DesignTokens.SPACE_M })
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  searchBar() {
    Row({ space: DesignTokens.SPACE_S }) {
      Row({ space: DesignTokens.SPACE_S }) {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(DesignTokens.ICON_M)
          .fontColor([$r('app.color.text_secondary')])
        TextInput({ placeholder: $r('app.string.transcript_search_hint'), text: this.searchTerm }).fontFamily(this.appFontFamily)
          .layoutWeight(1)
          .height(36)
          .padding(0)
          .fontSize(DesignTokens.FONT_SUBTITLE)
          .fontColor($r('app.color.player_text'))
          .placeholderColor($r('app.color.text_tertiary'))
          .caretColor($r('app.color.player_text'))
          .backgroundColor(Color.Transparent)
          .onChange((value: string) => {
            this.searchTerm = value;
            this.runSearch();
          })
      }
      .layoutWeight(1)
      .height(36)
      .padding({ left: DesignTokens.SPACE_M, right: DesignTokens.SPACE_M })
      .borderRadius(18)
      .backgroundColor($r('app.color.surface_secondary'))
      .alignItems(VerticalAlign.Center)

      if (this.searchTerm !== '') {
        Text(this.hits.length.toString()).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_FOOTNOTE)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .width('100%')
    .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN, bottom: DesignTokens.SPACE_S })
  }

  @Builder
  body() {
    Stack({ alignContent: Alignment.Bottom }) {
      List({ space: DesignTokens.SPACE_M, scroller: this.scroller }) {
        LazyForEach(this.dataSource, (seg: TranscriptSegment) => {
          ListItem() {
            this.segmentText(seg)
          }
        }, (seg: TranscriptSegment) => seg.segmentId.toString())
      }
      .width('100%')
      .height('100%')
      .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
      .scrollBar(BarState.Off)
      .onScrollStart(() => {
        // 用户手动滑动：暂停自动跟随，避免和手指抢滚动位置
        this.autoFollow = false;
      })

      if (!this.autoFollow && this.activeIndex >= 0) {
        Row({ space: DesignTokens.SPACE_XS }) {
          SymbolGlyph($r('sys.symbol.arrow_down'))
            .fontSize(DesignTokens.ICON_S)
            .fontColor([$r('app.color.player_text')])
          Text($r('app.string.transcript_back_to_current')).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_FOOTNOTE)
            .fontColor($r('app.color.player_text'))
        }
        .padding({ left: DesignTokens.SPACE_M, right: DesignTokens.SPACE_M, top: 8, bottom: 8 })
        .borderRadius(18)
        .backgroundColor($r('app.color.surface_secondary'))
        .margin({ bottom: DesignTokens.SPACE_L })
        .onClick(() => {
          this.autoFollow = true;
          this.scrollToActive();
        })
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  @Builder
  segmentText(seg: TranscriptSegment) {
    Text(seg.text).fontFamily(this.appFontFamily)
      .width('100%')
      .fontSize(this.fontSize)
      .lineHeight(Math.round(this.fontSize * 1.65))
      .fontColor(this.activeIndex === seg.segmentId ? $r('app.color.player_text') : $r('app.color.text_secondary'))
      .padding({ top: 4, bottom: 4 })
      .textAlign(TextAlign.Start)
      .copyOption(CopyOptions.LocalDevice)
      .onClick(() => {
        this.seekTo(seg);
      })
  }

  @Builder
  emptyState() {
    Column({ space: DesignTokens.SPACE_M }) {
      Text(this.message !== '' ? this.message : $r('app.string.player_transcript_empty')).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_BODY)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .padding({ left: DesignTokens.SPACE_XXL, right: DesignTokens.SPACE_XXL })

      if (this.aiMessage !== '') {
        Text(this.aiMessage).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_FOOTNOTE)
          .fontColor($r('app.color.text_tertiary'))
          .textAlign(TextAlign.Center)
          .padding({ left: DesignTokens.SPACE_XXL, right: DesignTokens.SPACE_XXL })
      }

      // 已配置且测试通过：提供真实的 AI 生成入口
      if (TranscriptSettings.isUsable(this.aiConfig)) {
        Text($r('app.string.transcript_ai_generate_hint')).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_FOOTNOTE)
          .fontColor($r('app.color.text_tertiary'))
          .textAlign(TextAlign.Center)
          .padding({ left: DesignTokens.SPACE_XXL, right: DesignTokens.SPACE_XXL })

        Row({ space: DesignTokens.SPACE_XS }) {
          if (this.generating) {
            LoadingProgress()
              .width(18)
              .height(18)
              .color($r('app.color.player_text'))
          }
          Text(this.generating ? $r('app.string.transcript_ai_generating')
            : $r('app.string.transcript_ai_generate')).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_SUBTITLE)
            .fontColor($r('app.color.player_text'))
        }
        .padding({ left: DesignTokens.SPACE_L, right: DesignTokens.SPACE_L, top: 10, bottom: 10 })
        .borderRadius(20)
        .backgroundColor($r('app.color.surface_secondary'))
        .enabled(!this.generating)
        .onClick(() => {
          this.generateWithAi();
        })
      } else {
        Text($r('app.string.transcript_ai_not_configured')).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_FOOTNOTE)
          .fontColor($r('app.color.text_tertiary'))
          .textAlign(TextAlign.Center)
          .padding({ left: DesignTokens.SPACE_XXL, right: DesignTokens.SPACE_XXL })

        Text($r('app.string.transcript_go_settings')).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_SUBTITLE)
          .fontColor($r('app.color.player_text'))
          .padding({ left: DesignTokens.SPACE_L, right: DesignTokens.SPACE_L, top: 10, bottom: 10 })
          .borderRadius(20)
          .backgroundColor($r('app.color.surface_secondary'))
          .onClick(() => {
            router.pushUrl({ url: 'pages/TranscriptionSettingsPage' });
          })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  /**
   * 真实的 AI 生成：读本地音频 → 调服务商 → 保存 → 展示。
   * 不下载音频、不伪造进度；超限或未下载都给出明确原因。
   */
  private async generateWithAi(): Promise<void> {
    const item: FeedItem | undefined = this.item;
    if (item === undefined || this.generating) {
      return;
    }
    this.aiConfig = TranscriptSettings.load();
    if (!TranscriptSettings.isUsable(this.aiConfig)) {
      this.aiMessage = getContext(this).resourceManager.getStringSync($r('app.string.transcript_ai_not_configured'));
      return;
    }
    const media: FeedMedia | undefined = item.media;
    if (media === undefined || media.fileUrl === '') {
      this.aiMessage = getContext(this).resourceManager.getStringSync($r('app.string.transcript_ai_need_download'));
      return;
    }
    let audio: Uint8Array;
    try {
      const stat: fs.Stat = fs.statSync(media.fileUrl);
      if (stat.size > TranscriptPage.AI_MAX_BYTES) {
        this.aiMessage = getContext(this).resourceManager.getStringSync($r('app.string.transcript_ai_too_large'));
        return;
      }
      const file: fs.File = fs.openSync(media.fileUrl, fs.OpenMode.READ_ONLY);
      try {
        const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
        fs.readSync(file.fd, buffer);
        audio = new Uint8Array(buffer);
      } finally {
        fs.closeSync(file);
      }
    } catch (error) {
      this.aiMessage = getContext(this).resourceManager.getStringSync($r('app.string.transcript_ai_failed'))
        + (error as Error).message;
      return;
    }
    const apiKey: string = await TranscriptKeyStore.load();
    if (apiKey === '') {
      this.aiMessage = getContext(this).resourceManager.getStringSync($r('app.string.transcript_settings_err_key'));
      return;
    }
    this.generating = true;
    this.aiMessage = '';
    try {
      const outcome: TranscriptionOutcome = await TranscriptionProvider.transcribe({
        baseUrl: TranscriptSettings.effectiveBaseUrl(this.aiConfig),
        apiKey: apiKey,
        model: this.aiConfig.model,
        language: this.aiConfig.language,
        audio: audio,
        fileName: 'episode' + this.episodeId.toString() + '.mp3',
        mimeType: media.mimeType === '' ? 'audio/mpeg' : media.mimeType,
        protocol: this.aiConfig.protocol === '' ? 'auto' : this.aiConfig.protocol
      });
      if (!outcome.ok) {
        this.aiMessage = getContext(this).resourceManager.getStringSync($r('app.string.transcript_ai_failed'))
          + outcome.message;
        return;
      }
      const doc: TranscriptDocument = {
        episodeId: this.episodeId,
        transcriptId: 0,
        sourceType: TranscriptSourceType.AI,
        language: this.aiConfig.language === 'auto' ? '' : this.aiConfig.language,
        provider: this.aiConfig.provider === TranscriptProviderKind.OPENAI ? 'openai' : 'custom',
        model: this.aiConfig.model,
        isTimed: outcome.timed,
        isAiGenerated: true,
        createdAt: Date.now(),
        updatedAt: Date.now(),
        segments: outcome.segments
      };
      const saved: TranscriptDocument = await TranscriptRepository.save(doc);
      this.doc = saved;
      this.dataSource.setData(saved.segments);
      this.aiMessage = '';
      this.syncActive(true);
    } finally {
      this.generating = false;
    }
  }

  private async load(): Promise<void> {
    this.loading = true;
    try {
      this.item = await EpisodeRepository.getById(this.episodeId);
      if (this.item === undefined) {
        this.message = '找不到这一集';
        return;
      }
      this.message = '';
      await this.reload(false);
    } finally {
      this.loading = false;
    }
  }

  /** force=true 时跳过缓存重新下载官方文字稿 */
  private async reload(force: boolean): Promise<void> {
    if (this.item === undefined) {
      return;
    }
    if (force) {
      await TranscriptRepository.deleteByEpisode(this.episodeId, false);
    }
    const result: OfficialTranscriptResult = await OfficialTranscriptProvider.load(this.item as FeedItem);
    if (result.ok && result.doc !== undefined) {
      this.doc = result.doc;
      this.dataSource.setData(result.doc.segments);
      this.message = '';
      this.syncActive(true);
      return;
    }
    this.doc = undefined;
    this.dataSource.setData([]);
    this.message = result.message;
  }

  private async clearCache(): Promise<void> {
    await TranscriptRepository.deleteByEpisode(this.episodeId, false);
    this.doc = undefined;
    this.dataSource.setData([]);
    this.message = '';
    this.loading = false;
  }

  private onPosition(data: PlaybackPositionData): void {
    if (this.doc === undefined || !this.doc.isTimed) {
      return;
    }
    const index: number = Transcripts.indexAt(this.doc, data.time);
    if (index === this.activeIndex) {
      return;
    }
    this.activeIndex = index;
    if (this.autoFollow) {
      this.scrollToActive();
    }
  }

  private syncActive(scroll: boolean): void {
    if (this.doc === undefined || !this.doc.isTimed) {
      this.activeIndex = -1;
      return;
    }
    const index: number = Transcripts.indexAt(this.doc, PlayerManager.getCurrentTime());
    this.activeIndex = index;
    if (scroll) {
      this.autoFollow = true;
      this.scrollToActive();
    }
  }

  private scrollToActive(): void {
    if (this.activeIndex < 0) {
      return;
    }
    try {
      this.scroller.scrollToIndex(this.activeIndex, false, ScrollAlign.CENTER);
    } catch (error) {
      // 列表尚未完成布局时忽略
    }
  }

  /** 点按段落：跳转到该段真实起始时间（不创建第二个播放器实例） */
  private seekTo(seg: TranscriptSegment): void {
    if (this.doc === undefined || !this.doc.isTimed) {
      return;
    }
    PlayerManager.seek(seg.startMs);
    this.activeIndex = seg.segmentId;
    this.autoFollow = true;
  }

  /** 调整阅读字号：14–22vp，立即生效并写盘 */
  private changeFontSize(delta: number): void {
    const next: number = Math.max(14, Math.min(22, this.fontSize + delta));
    if (next === this.fontSize) {
      return;
    }
    this.fontSize = next;
    UserPreferences.setTranscriptFontSize(next);
  }

  private runSearch(): void {
    const hits: SearchHit[] = [];
    if (this.doc === undefined || this.searchTerm.trim() === '') {
      this.hits = hits;
      return;
    }
    const term: string = this.searchTerm.trim().toLowerCase();
    const segments: TranscriptSegment[] = this.doc.segments;
    for (let i = 0; i < segments.length; i++) {
      if (segments[i].text.toLowerCase().indexOf(term) >= 0) {
        hits.push({ index: i, preview: segments[i].text });
      }
      if (hits.length >= 100) {
        break;
      }
    }
    this.hits = hits;
  }

  private jumpToHit(hit: SearchHit): void {
    this.autoFollow = false;
    try {
      this.scroller.scrollToIndex(hit.index, false, ScrollAlign.CENTER);
    } catch (error) {
      // 忽略
    }
    if (this.doc !== undefined && this.doc.isTimed) {
      const seg: TranscriptSegment = this.doc.segments[hit.index];
      PlayerManager.seek(seg.startMs);
    }
  }
}
