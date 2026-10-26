import { ImageCache } from '../services/ImageCache';
import common from '@ohos.app.ability.common';
import { DesignTokens } from '../common/DesignTokens';

/**
 * 订阅/剧集封面：圆角方形封面，无图时显示占位底。
 * - 传 `fallbackTitle` 时按上游 `fallbackTitleLabel` 的做法：深色半透明底 + 居中白字标题；
 * - 否则显示品牌色容器底 + 音乐图标；
 * - `fill` 为 true 时宽度撑满父容器并保持 1:1（订阅网格瓦片用）。
 *
 * 「不出现空洞」是硬约束：封面未就绪（下载中 / 下载失败 / 缓存文件损坏）时一律渲染上面两种占位块。
 * 旧实现在此时渲染 `Image(远端 URL)`，而 Image 的背景色是 13% 透明度的灰（#22777777）——
 * 远端图取不到时整块瓦片看上去就是「图标凭空消失了」；批量订阅 86 个播客后一屏十几张并发下载，
 * 排在后面的那一行最容易整行变空白。
 */
@Component
export struct FeedCover {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  @Prop @Watch('onImageUrlChange') imageUrl: string = '';
  @Prop coverSize: number = 56;
  @Prop radius: number = DesignTokens.RADIUS_ROW;
  @Prop fallbackTitle: string = '';
  @Prop placeholderColor: ResourceColor = $r('app.color.primary_container');
  @Prop fill: boolean = false;
  /**
   * true = 铺满父容器（宽高都 100%，不再强制 1:1）。
   * 待播清单卡片背景需要把 1:1 封面按 1.42 的卡片比例做 Cover 裁切，
   * 之前用 `fill` 时内部是 `aspectRatio(1)`，只盖住卡片上半部分，
   * 下半部分因此只剩下压暗层 —— 看起来就是「上图下板」。
   */
  @Prop fillParent: boolean = false;
  /**
   * 图片自身模糊半径（vp）。0 = 不模糊。
   * 卡片背景用它代替 `backdropBlur`：模糊的是静态图片内容，不随滚动每帧重新采样背景。
   */
  @Prop contentBlur: number = 0;
  @State src: string = '';
  /** 已成功取到的地址（同一地址不重复下载；地址变化时才重取） */
  private loadedUrl: string = '';
  /** 正在取图的地址：同一地址不重复发起（按地址而不是全局布尔，地址中途变化时不会被卡住） */
  private pendingUrl: string = '';
  /** 已用掉一次「解码失败 → 删缓存重取」的自愈机会，防止坏文件导致死循环 */
  private healed: boolean = false;

  /**
   * 地址变化时重新取图。
   * 关键：Image 的 onAppear 只在节点首次挂载时触发，仅靠它会导致
   * 复用同一个 FeedCover 的地方（订阅瓦片 / 订阅详情头图）一直显示旧封面。
   *
   * 不清空 `src`：新封面就绪前继续显示旧封面，比先退回占位块再换图少一次闪动；
   * 新地址已在磁盘缓存里时 `paintFromCache()` 会同步换掉。
   */
  onImageUrlChange(): void {
    this.healed = false;
    this.loadedUrl = '';
    this.paintFromCache();
    this.load();
  }

  aboutToAppear(): void {
    // 取图入口放在这里而不是 Image.onAppear：未就绪时渲染的是占位块（没有 Image 节点），
    // 只靠 Image.onAppear 会让这类瓦片永远停在占位状态。
    // 先同步命中磁盘缓存：首帧直接是封面，没有任何「占位 → 封面」的闪动。
    this.paintFromCache();
    this.load();
  }

  build() {
    if (this.fillParent) {
      Column() {
        this.coverContent()
      }
      .width('100%')
      .height('100%')
      .borderRadius(this.radius)
      .border({ width: 0.5, color: $r('app.color.cover_edge') })
      .clip(true)
    } else if (this.fill) {
      Column() {
        this.coverContent()
      }
      .width('100%')
      .aspectRatio(1)
      .borderRadius(this.radius)
      // 极细描边：浅色模式下白封面 / 深色模式下黑封面都能与背景分离
      .border({ width: 0.5, color: $r('app.color.cover_edge') })
      .clip(true)
    } else {
      Column() {
        this.coverContent()
      }
      .width(this.coverSize)
      .height(this.coverSize)
      .borderRadius(this.radius)
      .border({ width: 0.5, color: $r('app.color.cover_edge') })
      .clip(true)
    }
  }

  @Builder
  coverContent() {
    if (this.src !== '') {
      Image(this.src)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .blur(this.contentBlur)
        // 按控件尺寸解码（默认 false 会按原图解码再缩放到 116vp，滚动时解码开销大、内存高）
        .autoResize(true)
        .interpolation(ImageInterpolation.Medium)
        .backgroundColor($r('app.color.cover_placeholder'))
        .onError(() => {
          this.onDecodeError();
        })
    } else {
      this.placeholder()
    }
  }

  /** 无封面 / 封面未就绪时的占位块（与「这个播客本来就没有封面」的观感一致） */
  @Builder
  placeholder() {
    if (this.fallbackTitle !== '') {
      Text(this.fallbackTitle).fontFamily(this.appFontFamily)
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.cover_text_bg'))
        .fontSize(this.fill ? DesignTokens.FONT_SUBTITLE : DesignTokens.FONT_FOOTNOTE)
        .fontColor(Color.White)
        .textAlign(TextAlign.Center)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding(6)
    } else {
      Column() {
        SymbolGlyph($r('sys.symbol.music'))
          .fontSize(this.fill ? DesignTokens.ICON_XXL : this.coverSize * 0.5)
          .fontColor([$r('app.color.primary')])
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.placeholderColor)
      .justifyContent(FlexAlign.Center)
    }
  }

  /**
   * 解码失败（缓存文件损坏 / 被清理 / 写入不完整）：删掉这份缓存并重取一次，
   * 否则该封面会一直空白——这正是「一行图标全部消失」里最难自愈的那部分。
   */
  onDecodeError(): void {
    const failedSrc: string = this.src;
    this.src = '';
    if (!this.healed && failedSrc.startsWith('file://')) {
      this.healed = true;
      ImageCache.evict(failedSrc);
      this.loadedUrl = '';
      this.load();
    }
  }

  /** 同步命中磁盘缓存时立即出图（首帧就带封面，避免「占位块闪一下再变封面」） */
  private paintFromCache(): void {
    const url: string = this.imageUrl;
    if (url === '' || url === this.loadedUrl) {
      return;
    }
    const cached: string = ImageCache.peek(url, getContext(this) as common.Context);
    if (cached !== '') {
      this.loadedUrl = url;
      this.src = cached;
    }
  }

  async load(): Promise<void> {
    const url: string = this.imageUrl;
    if (url === '' || url === this.loadedUrl || url === this.pendingUrl) {
      return;
    }
    this.pendingUrl = url;
    try {
      const context = getContext(this) as common.Context;
      const cached: string = await ImageCache.getImage(url, context);
      if (this.imageUrl !== url) {
        // 取图期间地址已变化，丢弃过期结果
        return;
      }
      if (cached !== '') {
        this.loadedUrl = url;
        this.src = cached;
      }
      // cached === '' 时保持占位块：不再回落到远端 URL（那正是「图标消失」的观感来源）
    } catch (error) {
      // 异常同样保持占位块
    } finally {
      if (this.pendingUrl === url) {
        this.pendingUrl = '';
      }
    }
  }
}
