import { FeedItem } from '../model/FeedItem';
import { NavigationGlass } from '../common/NavigationGlass';
import { NAV_LIGHT_KEY } from '../prefs/UserPreferences';
import { EpisodeActions } from '../services/EpisodeActions';
import { DesignTokens } from '../common/DesignTokens';
import { AppFont } from '../services/AppFont';

/**
 * 单集「更多」操作面板（全工程共用）。
 *
 * 内容与行为在**所有单集列表页**保持一致：标记已播/未播、加入队列、收藏/取消收藏、
 * 分享链接、下载/删除下载，最后是「取消」。
 *
 * 使用方式（页面里）：
 * ```
 * if (this.moreItem !== undefined) {
 *   EpisodeActionsSheet({
 *     item: this.moreItem,
 *     isFavorite: this.moreFavorite,
 *     feedLink: this.feedLinkOf(this.moreItem),
 *     onClose: () => { this.moreItem = undefined; },
 *     onMessage: (text: string) => { this.showMessage(text); },
 *     onChanged: () => { this.reload(); }
 *   })
 * }
 * ```
 */
@Component
export struct EpisodeActionsSheet {
  /** 沉浸光感档位（弹层材质与系统菜单保持一致） */
  @StorageLink(NAV_LIGHT_KEY) navLightLevel: number = 0;
  @StorageProp('app_font_family') appFontFamily: string = AppFont.DEFAULT_FAMILY;
  @Prop item: FeedItem;
  /** 打开面板时的收藏状态（由页面查询后传入） */
  @Prop isFavorite: boolean = false;
  /** 订阅的链接：单集没有链接时作为分享兜底 */
  @Prop feedLink: string = '';
  /** 面板底部安全区（手势条高度） */
  @Prop bottomSafe: number = 0;

  onClose: () => void = () => {
  };
  onMessage: (text: string) => void = () => {
  };
  onChanged: () => void = () => {
  };

  @State private favorite: boolean = false;
  @State private playing: boolean = false;

  aboutToAppear(): void {
    this.favorite = this.isFavorite;
    this.playing = false;
  }

  build() {
    Column({ space: 2 }) {
      Text(this.item.title).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_FOOTNOTE)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding(DesignTokens.SPACE_L)

      this.actionRow($r('sys.symbol.checkmark_circle'),
        this.item.isPlayed ? $r('app.string.episode_mark_unplayed') : $r('app.string.episode_mark_played'),
        async (): Promise<void> => {
          try {
            await EpisodeActions.togglePlayed(this.item);
            this.onChanged();
          } catch (error) {
            this.onMessage((error as Error).message);
          }
        })

      this.actionRow($r('sys.symbol.music_note_list'), $r('app.string.episode_add_queue'),
        async (): Promise<void> => {
          try {
            await EpisodeActions.addToQueue(this.item);
            this.onMessage(this.text($r('app.string.queue_added')));
            this.onChanged();
          } catch (error) {
            this.onMessage((error as Error).message);
          }
        })

      this.actionRow(this.favorite ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'),
        this.favorite ? $r('app.string.favorites_remove') : $r('app.string.favorites_button'),
        async (): Promise<void> => {
          try {
            this.favorite = await EpisodeActions.toggleFavorite(this.item);
            this.onChanged();
          } catch (error) {
            this.onMessage((error as Error).message);
          }
        })

      this.actionRow($r('sys.symbol.share'), $r('app.string.episode_share'),
        async (): Promise<void> => {
          try {
            const ok: boolean = await EpisodeActions.shareLink(this.item, this.feedLink);
            this.onMessage(this.text(ok ? $r('app.string.share_copied') : $r('app.string.share_no_link')));
          } catch (error) {
            this.onMessage((error as Error).message);
          }
        })

      if (this.item.media !== undefined) {
        this.actionRow(EpisodeActions.isDownloaded(this.item) ? $r('sys.symbol.trash') : $r('sys.symbol.arrow_down_circle'),
          EpisodeActions.isDownloaded(this.item) ? $r('app.string.episode_delete_download') : $r('app.string.episode_download'),
          async (): Promise<void> => {
            try {
              if (EpisodeActions.isDownloaded(this.item)) {
                await EpisodeActions.deleteDownload(this.item);
              } else {
                await EpisodeActions.startDownload(this.item);
              }
              this.onChanged();
            } catch (error) {
              this.onMessage((error as Error).message);
            }
          })
      }

      Button($r('app.string.dialog_cancel'))
        .width('100%')
        .height(DesignTokens.HEIGHT_BUTTON)
        .backgroundColor($r('app.color.surface_secondary'))
        .fontColor($r('app.color.text_primary'))
        .fontSize(DesignTokens.FONT_PARAGRAPH)
        .margin({ top: DesignTokens.SPACE_M, bottom: DesignTokens.SPACE_M })
        .onClick(() => {
          this.onClose();
        })
    }
    .width('100%')
    // 与「单集页顶栏更多」的系统菜单同款材质：档位 > 0 时挂系统沉浸材质，
    // 关闭档位时退回原来的实心表面色，保证任何设备都有可读背景。
    .backgroundColor(NavigationGlass.supported() ? Color.Transparent : $r('app.color.surface'))
    .systemMaterial(NavigationGlass.sheetMaterial(this.navLightLevel))
    .borderRadius({ topLeft: DesignTokens.RADIUS_SHEET, topRight: DesignTokens.RADIUS_SHEET })
    .padding({
      left: DesignTokens.PAGE_MARGIN,
      right: DesignTokens.PAGE_MARGIN,
      bottom: this.bottomSafe
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder
  actionRow(icon: Resource, label: ResourceStr, onTap: () => Promise<void>) {
    Row({ space: DesignTokens.SPACE_M }) {
      SymbolGlyph(icon)
        .fontSize(DesignTokens.ICON_L)
        .fontColor([$r('app.color.text_secondary')])
      Text(label).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_SUBTITLE)
        .fontColor($r('app.color.text_primary'))
    }
    .width('100%')
    .padding({
      left: DesignTokens.SPACE_S,
      top: DesignTokens.SPACE_M,
      bottom: DesignTokens.SPACE_M
    })
    .onClick(() => {
      // 先收起面板，再执行动作；失败提示由页面 toast 承担
      this.onClose();
      onTap().catch((error: Error) => {
        this.onMessage(error.message);
      });
    })
  }

  private text(resource: Resource): string {
    return getContext(this).resourceManager.getStringSync(resource);
  }
}
