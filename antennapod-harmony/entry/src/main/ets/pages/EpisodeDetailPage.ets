import router from '@ohos.router';
import { NetworkWarmup } from '../common/NetworkWarmup';
import pasteboard from '@ohos.pasteboard';
import { Feed } from '../model/Feed';
import { FeedItem } from '../model/FeedItem';
import { FeedMedia } from '../model/FeedMedia';
import { FeedRepository } from '../db/repositories/FeedRepository';
import { EpisodeRepository } from '../db/repositories/EpisodeRepository';
import { DownloadManager } from '../download/DownloadManager';
import { PlayerManager } from '../player/PlayerManager';
import { QueueEngine } from '../player/QueueEngine';
import { Playable } from '../model/Playable';
import { EventHub, EventType, EpisodeDownloadData, FeedItemUpdateData } from '../events/EventHub';
import { DurationUtils } from '../utils/DurationUtils';
import { ShownotesSegment, ShownotesText } from '../utils/ShownotesText';
import { DesignTokens } from '../common/DesignTokens';
import { AppBar } from '../components/AppBar';
import { AppIconButton } from '../components/AppIconButton';
import { OverflowButton } from '../components/OverflowButton';
import { FeedCover } from '../components/FeedCover';
import { ShownotesBody } from '../components/ShownotesBody';
import { MiniPlayer } from '../components/MiniPlayer';
import { menuIcon } from '../common/MenuIcons';

interface EpisodeDetailParams {
  itemId: number;
  /** 预览（未订阅）时的单集快照 JSON：有值时本页以只读+可播放方式渲染，不查库 */
  previewJson?: string;
}

/**
 * 单集详情页（对照上游 `feeditem_fragment.xml` + `ui/screen/episode/ItemFragment.java`）：
 *
 * 头部 = 56vp 封面 + 订阅名（点击进订阅详情）+ 单集标题（最多 5 行）+ 「时长 · 发布日期」；
 * 动作行 = 主操作（播放 / 暂停 / 在线播放）+ 次操作（下载 / 取消下载 / 删除文件，带下载进度环）；
 * 正文 = 节目详情（shownotes，纯文本但保留换行，落在时长内的时间码可点跳转）。
 *
 * 上游没有媒体时主操作是「标记为已播」、次操作是「访问网站」；本移植版把次操作换成分享
 * （无系统分享面板，与其它页面一致：复制链接到剪贴板）。
 *
 * 入口：收件箱列表单击（上游 `EpisodeItemListAdapter` 同样把单击接到单集详情页）；
 * 其它列表仍是「单击直接播放」（第 41 轮 parity 文档第 35 条的选择），故播放页仍保留同一个
 * 「节目详情」弹层。
 *
 * 开始播放后**留在本页**（与上游 ItemFragment 一致，正文可以边听边看）：上游靠常驻的迷你播放条
 * 回播放页，本移植版的详情页是路由页、没有迷你播放条，故在本集成为当前播放项后由标题栏给一个
 *「打开播放页」按钮。
 */
@Entry
@Component
struct EpisodeDetailPage {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  @State item: FeedItem | undefined = undefined;
  @State feed: Feed | undefined = undefined;
  @State segments: ShownotesSegment[] = [];
  @State status: string = 'IDLE';
  /**
   * 当前播放项的 media id（-1 = 无）。
   * `PlayerManager` 的内部状态不是 @State，标题栏「打开播放页」按钮的显隐必须依赖一个
   * @State 才会随播放状态刷新，故把当前播放项 id 也镜像到页面状态里。
   */
  @State currentMediaId: number = -1;
  /**
   * 当前播放项的 feedItemId。
   * 必须是 @State：ArkUI 只为 build 中**实际读过**的状态建立依赖，
   * 之前 isCurrentItem() 直接读 PlayerManager（非可观察对象）+ 短路求值，
   * 导致「播放开始后状态变了但页面不重绘」——按钮不变、底部播放条不出现。
   */
  @State currentItemId: number = -1;
  /** 预览态：单集还没入库（来自详情页的 RSS 预览），只读 + 可在线播放 */
  @State previewMode: boolean = false;
  @State message: string = '';
  /** 本集是否已在播放队列里（决定「加入队列」按钮的高亮与文案） */
  @State queued: boolean = false;
  /** 下载进度百分比；-1 = 不显示进度环（对照上游 `circularProgressBar`） */
  @State downloadProgress: number = -1;
  @State downloadIndeterminate: boolean = false;
  private itemId: number = 0;
  private messageTimerId: number = -1;
  private itemToken: number = -1;
  private playerToken: number = -1;
  private downloadToken: number = -1;

  build() {
    Column() {
      // ---- 顶部导航：固定结构，不随播放状态变化
      // AppBar 自带 page_bg(#F1F3F5) 底色，与本页 player_bg(#FFF) 不一致，
      // 因此外面包一层同色容器盖住它，让整页（含状态栏）是同一个白。
      Column() {
        AppBar({
          title: $r('app.string.episode_detail_title'),
          showBack: true,
          // 与本页白色底一致，避免导航条出现一条灰色色带
          bgColor: $r('app.color.player_bg')
        })
      }
      .width('100%')
      .height(DesignTokens.HEIGHT_APP_BAR)
      // 只覆盖导航条高度：AppBar 内部仍画 page_bg，但外层同高白底会先垫住，
      // 并把导航条之外的空间留给下方内容
      .backgroundColor($r('app.color.player_bg'))
      .clip(true)

      if (this.message !== '') {
        Text(this.message).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_FOOTNOTE)
          .fontColor($r('app.color.player_text_secondary'))
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
      }

      if (this.item === undefined) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color($r('app.color.player_text'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        this.content()
      }

      // ---- 底部迷你播放器：本集在播放队列里就显示（含暂停态），复用全局组件
      if (this.isCurrentItem()) {
        Divider()
          .color($r('app.color.player_divider'))
          .strokeWidth(0.5)
        Row() {
          MiniPlayer({
            title: this.itemTitle(),
            feedTitle: this.feedTitle(),
            imageUrl: this.itemImage(),
            playing: this.isCurrentPlaying(),
            show: true,
            progress: this.playProgress(),
            floating: false,
            onToggle: () => {
              if (this.isCurrentPlaying()) {
                PlayerManager.pause();
              } else {
                PlayerManager.play();
              }
            }
          })
        }
        .width('100%')
        .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN, top: DesignTokens.SPACE_S, bottom: DesignTokens.SPACE_S })
        .backgroundColor($r('app.color.player_bg'))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.player_bg'))
    // 背景延伸到状态栏与底部手势区
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  content() {
    Scroll() {
      Column({ space: DesignTokens.SPACE_L }) {
        this.header()
        this.actionRow()

        if (this.media() === undefined) {
          Text($r('app.string.no_media_label')).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_FOOTNOTE)
            .fontColor($r('app.color.player_text_tertiary'))
            .width('100%')
        }

        // 操作区与正文之间的轻薄分隔线
        Divider()
          .color($r('app.color.player_divider'))
          .strokeWidth(0.5)

        if (this.segments.length === 0) {
          Text($r('app.string.no_shownotes_label')).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_PARAGRAPH)
            .fontColor($r('app.color.player_text_secondary'))
            .width('100%')
        } else {
          ShownotesBody({
            segments: this.segments,
            onTimecode: (timeMs: number) => {
              this.seekToTimecode(timeMs);
            }
          })
        }
      }
      .width('100%')
      .padding({
        left: DesignTokens.PAGE_MARGIN,
        right: DesignTokens.PAGE_MARGIN,
        top: DesignTokens.SPACE_M,
        bottom: DesignTokens.SPACE_XXL
      })
    }
    .layoutWeight(1)
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
  }

  /**
   * 头部信息：左 104vp 封面（只展示）+ 右「节目名 ›」/ 标题（最多 3 行）/ 时长 · 日期。
   * 只有节目名可点进节目主页，封面不再承载隐式跳转。
   */
  @Builder
  header() {
    Row({ space: DesignTokens.SPACE_L }) {
      FeedCover({
        imageUrl: this.itemImage(),
        coverSize: 104,
        radius: 14,
        fallbackTitle: this.feedTitle(),
        placeholderColor: $r('app.color.player_chip')
      })

      Column({ space: 6 }) {
        // 节目名 + 右箭头：点击进入节目主页
        Row({ space: 2 }) {
          Text(this.feedTitle()).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_FOOTNOTE)
            .fontColor($r('app.color.player_text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(DesignTokens.ICON_XS)
            .fontColor([$r('app.color.player_text_tertiary')])
        }
        .width('100%')
        .onClick(() => {
          this.openFeed();
        })

        Text(this.itemTitle()).fontFamily(this.appFontFamily)
          .fontSize(DesignTokens.FONT_SUBTITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.player_text'))
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(23)
          .width('100%')

        Row({ space: DesignTokens.SPACE_XS }) {
          Text(this.durationText()).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor($r('app.color.player_text_tertiary'))
          if (this.durationText() !== '' && this.pubDateText() !== '') {
            Text('·').fontFamily(this.appFontFamily)
              .fontSize(DesignTokens.FONT_CAPTION)
              .fontColor($r('app.color.player_text_tertiary'))
          }
          Text(this.pubDateText()).fontFamily(this.appFontFamily)
            .fontSize(DesignTokens.FONT_CAPTION)
            .fontColor($r('app.color.player_text_tertiary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  /**
   * 动作行：「播放本集」（黑色主按钮）+「下载」（浅灰次按钮），等宽对称。
   * 两个按钮都是无参 @Builder，图标与文案在内部读 @State，才能随播放状态刷新。
   */
  @Builder
  actionRow() {
    Row({ space: DesignTokens.SPACE_M }) {
      this.primaryButton()
      this.secondaryButton()
      // 加入队列：图标胶囊，已在队列时用品牌紫高亮，再点一次移出
      Stack() {
        SymbolGlyph($r('sys.symbol.music_note_list'))
          .fontSize(DesignTokens.ICON_L)
          .fontColor([this.queued ? $r('app.color.primary') : $r('app.color.player_text')])
      }
      .width(46)
      .height(46)
      .borderRadius(23)
      .backgroundColor($r('app.color.player_chip'))
      .alignContent(Alignment.Center)
      .accessibilityText(this.queued ? $r('app.string.queue_remove') : $r('app.string.episode_add_queue'))
      .onClick(() => {
        this.toggleQueue();
      })
    }
    .width('100%')
  }

  /**
   * 主操作：与「下载」完全同一套胶囊样式（同底色 chip、同文字色 text）。
   *
   * 之前主操作反相填充（深色模式是近白胶囊），与右侧深灰的次操作并排时
   * 像两个不同组件，观感突兀。这里统一到同一个 chip 视觉，
   * 只靠图标与文案区分主次。
   */
  @Builder
  primaryButton() {
    Row({ space: DesignTokens.SPACE_S }) {
      SymbolGlyph(this.primaryIcon())
        .fontSize(DesignTokens.ICON_L)
        .fontColor([$r('app.color.player_text')])
      Text(this.primaryLabel()).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_PARAGRAPH)
        .fontColor($r('app.color.player_text'))
        .maxLines(1)
    }
    .layoutWeight(1)
    .height(46)
    .justifyContent(FlexAlign.Center)
    .borderRadius(23)
    .backgroundColor($r('app.color.player_chip'))
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.primaryAction();
    })
  }

  /** 次操作：浅灰底 + 黑色线性图标与文字；下载中在外圈画进度环 */
  @Builder
  secondaryButton() {
    Row({ space: DesignTokens.SPACE_S }) {
      Stack() {
        if (this.downloadProgress >= 0) {
          Progress({ value: this.downloadProgress, total: 100, type: ProgressType.Ring })
            .width(24)
            .height(24)
            .color($r('app.color.player_text'))
            .backgroundColor($r('app.color.player_track'))
            .style({
              strokeWidth: 2,
              status: this.downloadIndeterminate ? ProgressStatus.LOADING : ProgressStatus.PROGRESSING,
              enableSmoothEffect: !this.downloadIndeterminate
            })
        }
        SymbolGlyph(this.secondaryIcon())
          .fontSize(DesignTokens.ICON_L)
          .fontColor([$r('app.color.player_text')])
      }
      .width(24)
      .height(24)
      .alignContent(Alignment.Center)

      Text(this.secondaryLabel()).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_PARAGRAPH)
        .fontColor($r('app.color.player_text'))
        .maxLines(1)
    }
    .layoutWeight(1)
    .height(46)
    .justifyContent(FlexAlign.Center)
    .borderRadius(23)
    .backgroundColor($r('app.color.player_chip'))
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.secondaryAction();
    })
  }
  aboutToAppear(): void {
    const params: EpisodeDetailParams = router.getParams() as EpisodeDetailParams;
    this.itemId = params === undefined || params === null ? 0 : params.itemId;
    if (params !== undefined && params !== null && params.previewJson !== undefined && params.previewJson !== '') {
      // 预览：直接从快照渲染，不查库（单集尚未入库）
      this.previewMode = true;
      this.loadPreview(params.previewJson);
    } else {
      this.load();
    }
    // 别处改了这一集（播放页听完自动标已播、订阅详情移出收件箱…）→ 本页同步
    this.itemToken = EventHub.subscribe(EventType.FEED_ITEM_UPDATE, (data: object) => {
      this.onFeedItemUpdate(data);
    });
    // 播放状态变化：主操作在「播放 / 暂停」之间切换
    this.playerToken = EventHub.subscribe(EventType.PLAYER_STATUS, (data: object) => {
      this.syncPlayerState();
    this.syncQueueState();
    });
    // 下载进度：只改本页的进度环与次操作
    this.downloadToken = EventHub.subscribe(EventType.EPISODE_DOWNLOAD, (data: object) => {
      this.onDownloadEvent(data);
    });
  }

  /** 从播放页返回时重读一次（上游 ItemFragment.onResume → updateAppearance） */
  onPageShow(): void {
    this.refreshState();
    this.syncQueueState();
  }

  aboutToDisappear(): void {
    const tokens: number[] = [this.itemToken, this.playerToken, this.downloadToken];
    for (const token of tokens) {
      if (token >= 0) {
        EventHub.unsubscribeToken(token);
      }
    }
    this.itemToken = -1;
    this.playerToken = -1;
    this.downloadToken = -1;
    if (this.messageTimerId >= 0) {
      clearTimeout(this.messageTimerId);
      this.messageTimerId = -1;
    }
  }

  // ---------------------------------------------------------------- 数据

  async load(): Promise<void> {
    try {
      const fresh: FeedItem | undefined = await EpisodeRepository.getById(this.itemId);
      if (fresh === undefined) {
        this.item = undefined;
        return;
      }
      this.item = fresh;
      this.feed = await FeedRepository.getById(fresh.feedId);
      // 正文只在换集时重算，返回本页不重排（避免阅读位置跳动）
      this.segments = ShownotesText.segments(fresh.description, EpisodeDetailPage.durationOf(fresh));
    } catch (error) {
      this.showMessage((error as Error).message);
    }
    this.refreshState();
  }

  /** 从预览快照恢复单集（只读展示 + 可在线播放） */
  private loadPreview(json: string): void {
    try {
      const payload: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
      const media: FeedMedia = new FeedMedia({
        id: Number(payload['mediaId']),
        duration: Number(payload['duration']),
        fileUrl: '',
        downloadUrl: String(payload['audioUrl']),
        downloadDate: 0,
        position: 0,
        size: 0,
        mimeType: String(payload['mimeType']),
        lastPlayedTimeHistory: 0,
        feedItemId: Number(payload['id']),
        playedDuration: 0,
        hasEmbeddedPicture: false,
        lastPlayedTimeStatistics: 0
      });
      const item: FeedItem = new FeedItem({
        id: Number(payload['id']),
        title: String(payload['title']),
        pubDate: Number(payload['pubDate']),
        isPlayed: false,
        playState: FeedItem.UNPLAYED,
        link: String(payload['link']),
        description: String(payload['description']),
        paymentLink: '',
        media: media,
        feedId: Number(payload['feedId']),
        hasChapters: false,
        itemIdentifier: String(payload['itemIdentifier']),
        imageUrl: String(payload['imageUrl']),
        autoDownloadEnabled: false,
        podcastIndexChapterUrl: '',
        podcastIndexTranscriptType: String(payload['transcriptType']),
        podcastIndexTranscriptUrl: String(payload['transcriptUrl']),
        socialInteractUrl: ''
      });
      item.feedTitle = String(payload['feedTitle']);
      item.feedImage = String(payload['feedImage']);
      this.item = item;
      this.segments = ShownotesText.segments(item.description, EpisodeDetailPage.durationOf(item));
      this.syncPlayerState();
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }
  /** 重读单集与播放/下载状态（返回本页 / 下载完成 / 播放状态变化时用） */
  async refreshState(): Promise<void> {
    if (this.itemId > 0) {
      try {
        const fresh: FeedItem | undefined = await EpisodeRepository.getById(this.itemId);
        if (fresh !== undefined) {
          this.item = fresh;
        }
      } catch (error) {
        this.message = (error as Error).message;
      }
    }
    this.syncPlayerState();
    // getProgressPercent / isProgressIndeterminate 只在 RUNNING / PAUSED 时给有效值，其余返回 -1 / false
    const media: FeedMedia | undefined = this.media();
    this.downloadProgress = media === undefined ? -1 : DownloadManager.getProgressPercent(media.id);
    this.downloadIndeterminate = media !== undefined && DownloadManager.isProgressIndeterminate(media.id);
  }

  /** 把播放器状态镜像到页面 @State（播放状态 / 当前播放项都要，见 `currentMediaId` 的说明） */
  private syncPlayerState(): void {
    this.status = PlayerManager.getStatus();
    const current: Playable | undefined = PlayerManager.getCurrent();
    this.currentMediaId = current === undefined ? -1 : current.id;
    this.currentItemId = current === undefined ? -1 : current.feedItemId;
  }

  private onFeedItemUpdate(data: object): void {
    const payload: FeedItemUpdateData = data as FeedItemUpdateData;
    if (payload.itemId === 0 || payload.itemId === this.itemId) {
      this.refreshState();
    }
  }

  private onDownloadEvent(data: object): void {
    const payload: EpisodeDownloadData = data as EpisodeDownloadData;
    const media: FeedMedia | undefined = this.media();
    if (media === undefined || payload.mediaId !== media.id) {
      return;
    }
    if (payload.state === 'DONE' || payload.state === 'REMOVED') {
      // file_url 变了：重查库让主/次操作切到「播放 / 删除文件」
      this.refreshState();
      return;
    }
    this.downloadProgress = DownloadManager.getProgressPercent(media.id);
    this.downloadIndeterminate = DownloadManager.isProgressIndeterminate(media.id);
  }

  // ---------------------------------------------------------------- 动作

  /**
   * 主操作（对照上游 `updateButtons` 的 actionButton1）：
   * 无媒体 → 标记已播 / 未播；正在播放 → 暂停；其余 → 播放（未下载时即在线播放）。
   */
  async primaryAction(): Promise<void> {
    const item: FeedItem | undefined = this.item;
    if (item === undefined) {
      return;
    }
    const media: FeedMedia | undefined = item.media;
    if (media === undefined) {
      await this.togglePlayed(item);
      return;
    }
    if (this.isCurrentPlaying()) {
      PlayerManager.pause();
      return;
    }
    // 点播放前先预热连接（DNS/TLS），跨境源的首包时间能省几秒
    if (media.downloadUrl !== '') {
      NetworkWarmup.warm(media.downloadUrl);
    }
    try {
      if (this.previewMode) {
        // 预览：直接用 RSS 里的音频地址构造播放对象，不入库、不入队
        const preview: Playable = new Playable(
          media.id, item.id, item.title, item.feedTitle, media.downloadUrl, '',
          media.duration, 0, media.getMediaType(), 1.0, 0, 0, 0,
          item.imageUrl !== '' ? item.imageUrl : item.feedImage);
        await PlayerManager.load(preview, 0, true);
        // load 内部已 await ensurePlaying；这里再兜一次，保证音频真的起来了
        await PlayerManager.ensurePlaying();
        this.syncPlayerState();
        return;
      }
      const playable: Playable | undefined = await QueueEngine.toPlayable(item);
      if (playable === undefined) {
        return;
      }
      await QueueEngine.ensureQueued(item);
      await PlayerManager.load(playable, media.position, true);
      await PlayerManager.ensurePlaying();
      // 与上游 ItemFragment 一致：留在本页（正文可以边听边看），由标题栏的
      //「打开播放页」按钮进播放页；播放页里同样有「节目详情」弹层
      this.syncPlayerState();
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }

  /** 同步「是否已在队列」：队列是内存快照，页面出现时刷一次即可 */
  private syncQueueState(): void {
    if (this.itemId <= 0) {
      this.queued = false;
      return;
    }
    const items: FeedItem[] = QueueEngine.getItems();
    const next: boolean = items.some((entry: FeedItem) => entry.id === this.itemId);
    if (next !== this.queued) {
      this.queued = next;
    }
  }

  /** 加入队列 / 移出队列 */
  private async toggleQueue(): Promise<void> {
    const item: FeedItem | undefined = this.item;
    if (item === undefined || this.itemId <= 0) {
      return;
    }
    try {
      if (this.queued) {
        await QueueEngine.remove(this.itemId);
        this.queued = false;
        this.showMessageBriefly(getContext(this).resourceManager.getStringSync($r('app.string.queue_removed_toast')));
      } else {
        await QueueEngine.add(item);
        this.queued = true;
        this.showMessageBriefly(getContext(this).resourceManager.getStringSync($r('app.string.queue_added_toast')));
      }
    } catch (error) {
      this.message = (error as Error).message;
    }
  }

  /** 次操作（对照上游 `updateButtons` 的 actionButton2）：下载中 → 取消；已下载 → 删除文件；否则 → 下载 */
  async secondaryAction(): Promise<void> {
    const item: FeedItem | undefined = this.item;
    if (item === undefined) {
      return;
    }
    if (this.previewMode) {
      // 预览不写库，下载与删除文件都不适用；次操作退化为分享链接
      await this.share(item);
      return;
    }
    const media: FeedMedia | undefined = item.media;
    if (media === undefined) {
      await this.share(item);
      return;
    }
    const state: string = this.downloadState(media);
    if (state === 'RUNNING' || state === 'PAUSED') {
      await this.cancelDownload(media);
      return;
    }
    if (media.fileUrl !== '') {
      await this.deleteFile(media);
      return;
    }
    await this.startDownload(item, media);
  }

  private async startDownload(item: FeedItem, media: FeedMedia): Promise<void> {
    if (media.downloadUrl === '') {
      return;
    }
    try {
      await DownloadManager.startDownload(media, item.title);
      this.showMessage(getContext(this).resourceManager.getStringSync($r('app.string.episode_downloading')));
      await this.refreshState();
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }

  private async cancelDownload(media: FeedMedia): Promise<void> {
    try {
      await DownloadManager.remove(media.id);
      await this.refreshState();
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }

  private async deleteFile(media: FeedMedia): Promise<void> {
    try {
      await DownloadManager.deleteFile(media);
      await this.refreshState();
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }

  /** 无媒体的单集：标记已播 / 未播（上游 MarkAsPlayedActionButton） */
  private async togglePlayed(item: FeedItem): Promise<void> {
    if (this.previewMode) {
      this.showMessage(getContext(this).resourceManager.getStringSync($r('app.string.feed_preview_subscribe_hint')));
      return;
    }
    try {
      await EpisodeRepository.markPlayed(item.id, !item.isPlayed);
      const data: FeedItemUpdateData = { feedId: item.feedId, itemId: item.id };
      EventHub.publish(EventType.FEED_ITEM_UPDATE, data);
      this.showMessage(getContext(this).resourceManager.getStringSync(
        item.isPlayed ? $r('app.string.marked_unplayed_message') : $r('app.string.marked_played_message')));
      await this.refreshState();
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }

  /** 无媒体单集的次操作 / 分享：复制单集链接到剪贴板（与其它页面口径一致） */
  private async share(item: FeedItem): Promise<void> {
    let link: string = item.link;
    if (link === '' && item.media !== undefined) {
      link = item.media.downloadUrl;
    }
    if (link === '') {
      this.showMessage(getContext(this).resourceManager.getStringSync($r('app.string.share_no_link')));
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, link);
      await pasteboard.getSystemPasteboard().setData(data);
      this.showMessage(getContext(this).resourceManager.getStringSync($r('app.string.share_copied')));
    } catch (error) {
      this.showMessage((error as Error).message);
    }
  }

  /**
   * 点按正文里的时间码（上游 `ShownotesWebView.setTimecodeSelectedListener`）：
   * 只有这一集就是当前播放项时才跳转，否则提示先播放这一集。
   */
  private seekToTimecode(timeMs: number): void {
    const media: FeedMedia | undefined = this.media();
    const current: Playable | undefined = PlayerManager.getCurrent();
    if (media === undefined || current === undefined || current.id !== media.id) {
      this.showMessage(getContext(this).resourceManager
        .getStringSync($r('app.string.play_this_to_seek_position_message')));
      return;
    }
    PlayerManager.seek(timeMs);
  }

  private openFeed(): void {
    const feedId: number = this.item === undefined ? 0 : this.item.feedId;
    if (feedId <= 0) {
      return;
    }
    router.pushUrl({ url: 'pages/FeedDetailPage', params: { feedId: feedId } });
  }

  // ---------------------------------------------------------------- 展示

  private media(): FeedMedia | undefined {
    return this.item === undefined ? undefined : this.item.media;
  }

  private downloadState(media: FeedMedia): string {
    if (media.fileUrl !== '') {
      return 'DONE';
    }
    return DownloadManager.getStatus(media.id);
  }

  /** 当前播放项就是这一集且正在播放（上游 `PlaybackStatus.isPlaying`） */
  isCurrentPlaying(): boolean {
    // 同样先读两种状态再判断：短路会让 build 只依赖到第一个条件
    const sameItem: boolean = this.isCurrentItem();
    const status: string = this.status;
    return sameItem && status === 'PLAYING';
  }

  /**
   * 当前播放项就是这一集（不要求正在播放；上游 `PlaybackStatus.isCurrentlyPlaying(media)`）。
   *
   * 必须用 **feedItemId** 比对：media.id 在未入库 / 预览 / 冷启动恢复出来的播放项上
   * 可能是 0 或 -1，两份不同的单集都会命中同一个值 —— 这正是「播了 A 之后，
   * 打开任意单集详情页都显示暂停按钮」的原因。
   */
  isCurrentItem(): boolean {
    // 先无条件读两个 @State，避免短路求值让 build 漏掉依赖（漏掉就不会重绘）
    const pageId: number = this.itemId;
    const currentId: number = this.currentItemId;
    if (pageId > 0 && currentId > 0) {
      return pageId === currentId;
    }
    const mediaId: number = this.currentMediaId;
    const media: FeedMedia | undefined = this.media();
    // 兜底：双方 id 都有效时才比较，避免 0 === 0 误判
    return media !== undefined && media.id > 0 && mediaId === media.id;
  }

  /** 主操作的图标与文案（与 `primaryAction` 一一对应） */
  primaryIcon(): Resource {
    const media: FeedMedia | undefined = this.media();
    if (media === undefined) {
      const played: boolean = this.item !== undefined && this.item.isPlayed;
      return played ? $r('sys.symbol.circle') : $r('sys.symbol.checkmark_circle');
    }
    return this.isCurrentPlaying() ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill');
  }

  primaryLabel(): ResourceStr {
    const media: FeedMedia | undefined = this.media();
    if (media === undefined) {
      const played: boolean = this.item !== undefined && this.item.isPlayed;
      return played ? $r('app.string.episode_mark_unplayed') : $r('app.string.episode_mark_played');
    }
    if (this.isCurrentPlaying()) {
      return $r('app.string.player_pause');
    }
    // 未下载 = 在线播放（上游 StreamActionButton）
    return media.fileUrl === '' && media.downloadUrl !== ''
      ? $r('app.string.episode_stream')
      : $r('app.string.episode_play');
  }

  secondaryIcon(): Resource {
    const media: FeedMedia | undefined = this.media();
    if (media === undefined) {
      return $r('sys.symbol.share');
    }
    const state: string = this.downloadState(media);
    if (state === 'RUNNING' || state === 'PAUSED') {
      return $r('sys.symbol.xmark_circle');
    }
    return media.fileUrl !== '' ? $r('sys.symbol.trash') : $r('sys.symbol.arrow_down_circle');
  }

  secondaryLabel(): ResourceStr {
    const media: FeedMedia | undefined = this.media();
    if (media === undefined) {
      return $r('app.string.episode_share');
    }
    const state: string = this.downloadState(media);
    if (state === 'RUNNING' || state === 'PAUSED') {
      return $r('app.string.episode_download_cancel');
    }
    return media.fileUrl !== '' ? $r('app.string.episode_delete_download') : $r('app.string.episode_download');
  }

  private itemImage(): string {
    if (this.item === undefined) {
      return '';
    }
    return this.item.imageUrl !== '' ? this.item.imageUrl : this.feedImage();
  }

  private itemTitle(): string {
    return this.item === undefined ? '' : this.item.title;
  }

  private feedImage(): string {
    return this.feed === undefined ? '' : this.feed.imageUrl;
  }

  private feedTitle(): string {
    return this.feed === undefined ? '' : this.feed.getTitle();
  }

  private durationText(): string {
    const media: FeedMedia | undefined = this.media();
    return media === undefined ? '' : DurationUtils.format(media.duration);
  }

  private pubDateText(): string {
    const pubDate: number = this.item === undefined ? 0 : this.item.pubDate;
    return pubDate > 0 ? new Date(pubDate).toLocaleDateString() : '';
  }

  /** 更多菜单：分享 / 收藏 / 打开节目主页（顶部固定入口，不随播放状态变化） */
  @Builder
  showEpisodeMenu() {
    Menu() {
      MenuItem({ symbolStartIcon: menuIcon($r('sys.symbol.share')), content: $r('app.string.player_share') })
        .onClick(() => {
          if (this.item !== undefined) {
            this.share(this.item);
          }
        })
      MenuItem({ symbolStartIcon: menuIcon($r('sys.symbol.chevron_right')), content: $r('app.string.feed_open_home') })
        .onClick(() => {
          this.openFeed();
        })
    }
  }
  /** 当前集播放进度百分比（喂给底部迷你播放器的进度线） */
  playProgress(): number {
    const media: FeedMedia | undefined = this.media();
    if (media === undefined || media.duration <= 0 || media.position <= 0) {
      return 0;
    }
    const percent: number = media.position * 100 / media.duration;
    return percent > 100 ? 100 : Math.floor(percent);
  }

  /** 顶部提示（4 秒自动消失） */
  /** 轻提示：只显示 1 秒（队列操作这类即时反馈用） */
  private showMessageBriefly(text: string): void {
    this.message = text;
    if (this.messageTimerId >= 0) {
      clearTimeout(this.messageTimerId);
    }
    this.messageTimerId = setTimeout(() => {
      this.message = '';
      this.messageTimerId = -1;
    }, 1000);
  }

  private showMessage(text: string): void {
    this.message = text;
    if (this.messageTimerId >= 0) {
      clearTimeout(this.messageTimerId);
    }
    this.messageTimerId = setTimeout(() => {
      this.message = '';
      this.messageTimerId = -1;
    }, 4000);
  }

  /** 时间码判定的时长口径：无媒体时按「未知」处理（上游传 `Integer.MAX_VALUE`） */
  private static durationOf(item: FeedItem): number {
    return item.media === undefined ? 0 : item.media.duration;
  }
}
