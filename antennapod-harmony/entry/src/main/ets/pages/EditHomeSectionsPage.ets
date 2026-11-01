import router from '@ohos.router';
import { DesignTokens } from '../common/DesignTokens';
import common from '@ohos.app.ability.common';
import { ImmersiveHost } from '../services/ImmersiveHost';
import { UserPreferences } from '../prefs/UserPreferences';
import { EventHub, EventType, HomeSectionsChangedData } from '../events/EventHub';

/**
 * 首页区块编辑页（独立二级页面）。
 *
 * 为什么做成独立页而不是首页里的一个分支：
 * 旧实现把编辑面板塞在首页 `Column` 里，高度被外层 TabBar 容器扣掉一截，
 * 内层 `Scroll` 的 `layoutWeight(1)` 又跟着被压缩 —— 于是「已隐藏」分组滚不出来。
 * 作为独立路由页后，页面自己占满全屏、只保留一条滚动轴，底部按安全区留白。
 *
 * 布局：固定导航（返回 / 编辑首页 / 完成）+ 单条 List 滚动 + 两个 iOS 风格分组卡片。
 * 数据：直接读写 `UserPreferences` 的同一份配置，不另建存储；每次改动即时落盘，
 * 返回首页时首页 `onPageShow` 重新读一遍即可生效。
 */

interface EditRow {
  tag: string;
  title: ResourceStr;
  hidden: boolean;
}

/** 全部区块（顺序以用户配置为准） */
const ALL_TAGS: string[] = [
  'new', 'continue', 'random', 'top',
  'curated_global', 'curated_chinese', 'curated_silicon', 'curated_investor',
  'curated_health', 'curated_women', 'curated_language',
  'downloads'
];

@Entry
@Component
struct EditHomeSectionsPage {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  @State order: string[] = [];
  @State hidden: string[] = [];
  /** 拖动中的区块 tag（用于给该行加抬起反馈） */
  @State draggingTag: string = '';
  /** 手指累计位移（vp） */
  @State dragY: number = 0;
  /** 已经因为「换位」被吃掉的位移：渲染位移 = dragY - dragConsumed */
  @State dragConsumed: number = 0;
  /** 被拖项当前所在下标（换位后会变） */
  @State dragIndex: number = -1;
  /** 每行实测高度，拖动换位时按它算落点 */
  private rowHeight: number = 56;
  /** 状态栏高度：顶栏内容要避开，但背景要一直铺到屏幕顶部 */
  @State statusInset: number = 0;

  aboutToAppear(): void {
    this.reload();
    ImmersiveHost.statusBarHeight(getContext(this) as common.UIAbilityContext).then((height: number) => {
      this.statusInset = height;
    });
  }

  /** 从偏好里读一次；缺失项按默认顺序补齐（不影响已保存的相对顺序） */
  private reload(): void {
    const saved: string[] = UserPreferences.getHomeSectionOrder();
    const merged: string[] = [];
    for (const tag of saved) {
      if (ALL_TAGS.includes(tag) && !merged.includes(tag)) {
        merged.push(tag);
      }
    }
    for (const tag of ALL_TAGS) {
      if (!merged.includes(tag)) {
        merged.push(tag);
      }
    }
    this.order = merged;
    this.hidden = UserPreferences.getHiddenHomeSections();
  }

  private titleOf(tag: string): ResourceStr {
    if (tag === 'continue') {
      return $r('app.string.home_continue');
    }
    if (tag === 'new') {
      return $r('app.string.home_new');
    }
    if (tag === 'random') {
      return $r('app.string.home_random');
    }
    if (tag === 'top') {
      return $r('app.string.home_top');
    }
    if (tag === 'downloads') {
      return $r('app.string.home_downloads');
    }
    if (tag === 'curated_chinese') {
      return $r('app.string.home_curated_chinese');
    }
    if (tag === 'curated_silicon') {
      return $r('app.string.home_curated_silicon');
    }
    if (tag === 'curated_investor') {
      return $r('app.string.home_curated_investor');
    }
    if (tag === 'curated_health') {
      return $r('app.string.home_curated_health');
    }
    if (tag === 'curated_women') {
      return $r('app.string.home_curated_women');
    }
    if (tag === 'curated_language') {
      return $r('app.string.home_curated_language');
    }
    return $r('app.string.home_curated_global');
  }

  private shownRows(): EditRow[] {
    const rows: EditRow[] = [];
    for (const tag of this.order) {
      if (!this.hidden.includes(tag)) {
        rows.push({ tag: tag, title: this.titleOf(tag), hidden: false });
      }
    }
    return rows;
  }

  private hiddenRows(): EditRow[] {
    const rows: EditRow[] = [];
    for (const tag of this.order) {
      if (this.hidden.includes(tag)) {
        rows.push({ tag: tag, title: this.titleOf(tag), hidden: true });
      }
    }
    return rows;
  }

  /** 显隐切换：即时落盘，首页返回时立刻生效 */
  private setHidden(tag: string, hide: boolean): void {
    const next: string[] = this.hidden.filter((t: string) => t !== tag);
    if (hide) {
      next.push(tag);
    }
    this.hidden = next;
    UserPreferences.setHiddenHomeSections(next);
    // 首页此刻仍挂载在编辑页下面：广播一下让它立即重读配置，不必重启 App
    const payloadHidden: HomeSectionsChangedData = { source: 'hidden' };
    EventHub.publish(EventType.HOME_SECTIONS_CHANGED, payloadHidden);
  }

  /** 移动区块：from/to 都是「已显示分组」内的下标 */
  private moveShown(fromIndex: number, toIndex: number): void {
    const shown: string[] = this.shownRows().map((r: EditRow) => r.tag);
    if (fromIndex < 0 || fromIndex >= shown.length) {
      return;
    }
    const clamped: number = Math.max(0, Math.min(toIndex, shown.length - 1));
    if (clamped === fromIndex) {
      return;
    }
    const moving: string = shown[fromIndex];
    // 在完整顺序里把该区块挪到「目标区块」的位置，隐藏区块的相对位置不受影响
    const full: string[] = this.order.slice();
    const from: number = full.indexOf(moving);
    if (from < 0) {
      return;
    }
    full.splice(from, 1);
    const anchor: string = shown[clamped];
    const to: number = full.indexOf(anchor);
    full.splice(to < 0 ? full.length : to + (clamped > fromIndex ? 1 : 0), 0, moving);
    this.order = full;
    UserPreferences.setHomeSectionOrder(full);
    const payloadOrder: HomeSectionsChangedData = { source: 'order' };
    EventHub.publish(EventType.HOME_SECTIONS_CHANGED, payloadOrder);
  }

  /**
   * 拖动中实时换位：手指越过「半行」就与相邻项互换，并把这段位移记入 dragConsumed，
   * 因此被拖行的渲染位移始终 = dragY - dragConsumed（跟随手指，不会越拖越偏）。
   * 与队列页 applyDragReorder 同一套逻辑，只是这里行高固定。
   */
  private reorderByOffset(): void {
    const step: number = this.rowHeight > 0 ? this.rowHeight : 56;
    const shownCount: number = this.shownRows().length;
    while (true) {
      const visual: number = this.dragY - this.dragConsumed;
      if (this.dragIndex >= 0 && this.dragIndex < shownCount - 1 && visual >= step / 2) {
        const from: number = this.dragIndex;
        animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
          this.moveShown(from, from + 1);
        });
        this.dragConsumed += step;
        this.dragIndex += 1;
        continue;
      }
      if (this.dragIndex > 0 && visual <= -step / 2) {
        const from: number = this.dragIndex;
        animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
          this.moveShown(from, from - 1);
        });
        this.dragConsumed -= step;
        this.dragIndex -= 1;
        continue;
      }
      break;
    }
  }

  private finish(): void {
    router.back();
  }

  /** 分组标题 */
  @Builder
  groupTitle(text: Resource) {
    Text(text).fontFamily(this.appFontFamily)
      .width('100%')
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_secondary'))
      .padding({ left: 4, right: 4, bottom: 6 })
  }

  /** 已显示的一行：手柄 + 名称 + 开关 */
  @Builder
  shownRow(row: EditRow, index: number) {
    Row({ space: 12 }) {
      // 拖动手柄：只认长按拖动，点击不触发任何跳转
      Row() {
        SymbolGlyph($r('sys.symbol.line_3_horizontal'))
          .fontSize(20)
          .fontColor([$r('app.color.text_tertiary')])
      }
      .width(32)
      .height(44)
      .justifyContent(FlexAlign.Center)
      .gesture(
        PanGesture({ fingers: 1, distance: 1 })
          .onActionStart(() => {
            // 与队列页一致：按下即进入拖拽态，记录起始下标
            this.draggingTag = row.tag;
            this.dragY = 0;
            this.dragConsumed = 0;
            this.dragIndex = index;
          })
          .onActionUpdate((event: GestureEvent) => {
            this.dragY = event.offsetY;
            this.reorderByOffset();
          })
          .onActionEnd(() => {
            // 顺序在拖动过程中已经实时改好并落库，这里只需复位视觉状态
            this.draggingTag = '';
            this.dragY = 0;
            this.dragConsumed = 0;
            this.dragIndex = -1;
          })
      )

      Text(row.title).fontFamily(this.appFontFamily)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: true })
        .selectedColor($r('app.color.primary'))
        .onChange((isOn: boolean) => {
          if (!isOn) {
            this.setHidden(row.tag, true);
          }
        })
    }
    .width('100%')
    .height(56)
    .padding({ left: 12, right: 14 })
    // 拖动中的行：跟随手指（位移扣除已换位消耗的量）、提到最上层、加淡阴影与实色底
    .translate({ y: this.draggingTag === row.tag ? this.dragY - this.dragConsumed : 0 })
    .zIndex(this.draggingTag === row.tag ? 10 : 0)
    .shadow(this.draggingTag === row.tag
      ? { radius: 16, color: '#26000000', offsetX: 0, offsetY: 6 }
      : { radius: 0, color: Color.Transparent })
    .borderRadius(this.draggingTag === row.tag ? 14 : 0)
    .backgroundColor(this.draggingTag === row.tag
      ? $r('app.color.surface') : Color.Transparent)
    .onAreaChange((_o: Area, n: Area) => {
      const h: number = Number(n.height);
      if (h > 0) {
        this.rowHeight = h;
      }
    })
  }

  /** 已隐藏的一行：只有名称 + 关闭态开关 */
  @Builder
  hiddenRow(row: EditRow) {
    Row({ space: 12 }) {
      Text(row.title).fontFamily(this.appFontFamily)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Toggle({ type: ToggleType.Switch, isOn: false })
        .selectedColor($r('app.color.primary'))
        .onChange((isOn: boolean) => {
          if (isOn) {
            this.setHidden(row.tag, false);
          }
        })
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 14 })
  }

  @Builder
  divider(inset: number) {
    Divider()
      .color($r('app.color.divider'))
      .strokeWidth(0.5)
      .margin({ left: inset })
  }

  build() {
    Column() {
      // ---- 固定导航：返回 / 编辑首页 / 完成
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(22)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(44)
        .height(44)
        .justifyContent(FlexAlign.Start)
        .onClick(() => this.finish())

        Text($r('app.string.home_edit_title')).fontFamily(this.appFontFamily)
          .fontSize(21)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)

        Row() {
          Text($r('app.string.home_edit_done')).fontFamily(this.appFontFamily)
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
        }
        .width(44)
        .height(44)
        .justifyContent(FlexAlign.End)
        .onClick(() => this.finish())
      }
      .width('100%')
      .height(52)
      .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
      .margin({ top: this.statusInset })

      // ---- 唯一滚动区：说明 + 已显示分组 + 已隐藏分组
      List({ space: 0 }) {
        ListItem() {
          Text($r('app.string.home_edit_hint')).fontFamily(this.appFontFamily)
            .width('100%')
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
            .padding({ left: 4, right: 4, top: 4, bottom: 12 })
        }

        // 已显示
        ListItem() {
          this.groupTitle($r('app.string.home_section_shown'))
        }
        ListItem() {
          Column() {
            if (this.shownRows().length === 0) {
              Text($r('app.string.home_edit_all_hidden')).fontFamily(this.appFontFamily)
                .fontSize(14)
                .fontColor($r('app.color.text_tertiary'))
                .padding({ left: 16, top: 16, bottom: 16 })
            } else {
              ForEach(this.shownRows(), (row: EditRow, index: number) => {
                this.shownRow(row, index)
                if (index < this.shownRows().length - 1) {
                  this.divider(56)
                }
              }, (row: EditRow) => 's-' + row.tag)
            }
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(18)
        }

        // 已隐藏
        ListItem() {
          Column() {
            Row()
              .height(24)
            this.groupTitle($r('app.string.home_section_hidden'))
          }
          .width('100%')
        }
        ListItem() {
          Column() {
            if (this.hiddenRows().length === 0) {
              Text($r('app.string.home_edit_none_hidden')).fontFamily(this.appFontFamily)
                .fontSize(14)
                .fontColor($r('app.color.text_tertiary'))
                .padding({ left: 16, top: 16, bottom: 16 })
            } else {
              ForEach(this.hiddenRows(), (row: EditRow, index: number) => {
                this.hiddenRow(row)
                if (index < this.hiddenRows().length - 1) {
                  this.divider(16)
                }
              }, (row: EditRow) => 'h-' + row.tag)
            }
          }
          .width('100%')
          .backgroundColor($r('app.color.surface'))
          .borderRadius(18)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: DesignTokens.PAGE_MARGIN, right: DesignTokens.PAGE_MARGIN })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      // 底部留白：内容之后 + 系统手势区，最后一行不会被导航条压住
      .contentEndOffset(24)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
    // 背景铺到状态栏与手势区（沉浸），内容用 padding 让开状态栏高度
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
