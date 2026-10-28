import { DesignTokens } from '../common/DesignTokens';
import { PressLight } from '../common/PressLight';
import { FeedCover } from './FeedCover';
import { EventHub, EventType } from '../events/EventHub';
import { PlayerManager } from '../player/PlayerManager';

/**
 * 首页横滑卡片（对齐上游 `horizontal_itemlist_item.xml`）：
 * 128vp 方形封面 + 封面底部 4vp 进度条 + 两行标题 + 日期。
 * 卡片 128vp 宽、圆角 18vp、底色 `surface_container`（播放中为 `surface_container_playing`），四周 4vp 外边距。
 */
@Component
export struct EpisodeCard {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  @Prop title: string = '';
  @Prop dateText: string = '';
  @Prop imageUrl: string = '';
  @Prop progress: number = 0;
  /**
   * 单集 id：传入后若本卡就是当前播放项，卡片会自己订阅播放进度事件，
   * 只重绘进度条而不重建整卡（重建会重新解码封面 → 表现为闪烁）。
   */
  @Prop feedItemId: number = 0;
  /** 由播放事件驱动的实时百分比（仅当前播放项有效） */
  @State liveProgress: number = -1;
  private positionToken: number = -1;
  @Prop playing: boolean = false;
  @Prop actionIcon: Resource = $r('sys.symbol.play_fill');
  /**
   * 下载进度百分比（0–100）；-1 表示当前没有下载任务，不画进度环。
   * 对照上游 `horizontal_itemlist_item.xml` 的 `circularProgressBar`
   * （48dp、`foregroundColor=?attr/colorOnPrimary`，叠在 48dp 播放圆钮上）：
   * `HorizontalItemViewHolder.bind` 在下载中画进度、已下载画满、未下载清零。
   */
  @Prop downloadProgress: number = -1;
  /** 总大小未知（服务端没给 Content-Length）时的等待态：环走旋转动画 */
  @Prop downloadIndeterminate: boolean = false;
  onTap: () => void = () => {
  };
  onAction: () => void = () => {
  };
  /** 长按打开单集操作菜单（上游 HorizontalItemListAdapter 也注册了上下文菜单） */
  onLongPress: () => void = () => {
  };

  aboutToAppear(): void {
    // 只订阅、不重建：播放位置事件到达时更新 @State，进度条平滑前进，封面不重新解码
    this.positionToken = EventHub.subscribe(EventType.PLAYBACK_POSITION, (data: object) => {
      this.onPosition(data);
    });
  }

  aboutToDisappear(): void {
    if (this.positionToken >= 0) {
      EventHub.unsubscribeToken(this.positionToken);
      this.positionToken = -1;
    }
  }

  private onPosition(data: object): void {
    const current = PlayerManager.getCurrent();
    if (current === undefined || this.feedItemId <= 0 || current.feedItemId !== this.feedItemId) {
      // 不是本卡对应的单集：清掉实时值，回落到外部传入的静态进度
      if (this.liveProgress !== -1) {
        this.liveProgress = -1;
      }
      return;
    }
    const payload: Record<string, number> = data as Record<string, number>;
    const time: number = payload['time'];
    const duration: number = payload['duration'];
    if (duration <= 0) {
      return;
    }
    const percent: number = Math.floor(time * 100 / duration);
    this.liveProgress = percent > 100 ? 100 : (percent < 5 ? 5 : percent);
  }

  /** 进度条取值：当前播放项用实时值，其余用外部传入值 */
  effectiveProgress(): number {
    return this.liveProgress >= 0 ? this.liveProgress : this.progress;
  }
  /** 按压光感（HDS point light） */
  @State private lightPressed: boolean = false;

  build() {
    Column() {
      // 封面 + 叠在封面内部底边的进度条（圆角裁切，进度条不超出封面）
      Stack({ alignContent: Alignment.Bottom }) {
        FeedCover({
          imageUrl: this.imageUrl,
          coverSize: DesignTokens.COVER_HOME_CARD,
          radius: DesignTokens.RADIUS_EPISODE_CARD,
          fallbackTitle: this.title,
          placeholderColor: $r('app.color.cover_placeholder')
        })

        // 进度条：贴在封面底部内侧，宽度撑满封面
        if (this.effectiveProgress() > 0) {
          Progress({ value: this.effectiveProgress(), total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(4)
            .color($r('app.color.primary'))
            .backgroundColor($r('app.color.scrubber_track'))
        }
      }
      .width(DesignTokens.COVER_HOME_CARD)
      .height(DesignTokens.COVER_HOME_CARD)
      .borderRadius(DesignTokens.RADIUS_EPISODE_CARD)
      .clip(true)

      Text(this.title).fontFamily(this.appFontFamily)
        .width('100%')
        .fontSize(DesignTokens.FONT_SUBTITLE)
        .fontColor($r('app.color.text_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        // 封面与标题之间 8vp
        .margin({ top: DesignTokens.SPACE_S })

      Text(this.dateText).fontFamily(this.appFontFamily)
        .width('100%')
        .fontSize(DesignTokens.FONT_FOOTNOTE)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        // 标题与日期之间 4vp
        .margin({ top: DesignTokens.SPACE_XS })
    }
    .width(DesignTokens.COVER_HOME_CARD)
    // 不再有卡片底色 / 圆角 / 外框：封面 + 标题 + 日期直接落在页面背景上
    .alignItems(HorizontalAlign.Start)
    .visualEffect(PressLight.effect(this.lightPressed))
    .animation({ duration: 150, curve: Curve.EaseOut })
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down) {
        this.lightPressed = true;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.lightPressed = false;
      }
    })
    .onClick(() => {
      this.onTap();
    })
    // 与 EpisodeRow 一致：必须用 parallelGesture，否则普通 tap 会被手势竞争吞掉
    .parallelGesture(LongPressGesture().onAction(() => {
      this.onLongPress();
    }))
  }
}
