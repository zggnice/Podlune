import { DesignTokens } from '../common/DesignTokens';
import { GlassSurface } from './GlassSurface';

/**
 * 底部导航栏（按设计规范重构）。
 *
 * 五项固定为：首页 / 收件箱 / 订阅 / 搜索 / 更多，顺序与功能不变。
 * 视觉约定：
 * - 整条栏是**一枚半透明胶囊**（GlassSurface 提供材质与极轻阴影），两端全圆角；
 * - 图标在上、文字在下，整体居中；五项等宽，尺寸与视觉重心一致；
 * - 未选中：中性灰（`nav_item_idle`）；选中：统一品牌紫（`nav_brand`）；
 * - 选中**只改颜色**，并按图标类型在有实心变体时切换线性 / 实心；
 * - **禁止**任何单项的背景块：没有圆圈、胶囊、玻璃底板、光晕、下划线或指示条，
 *   也不做放大与位移。这里刻意不写 `.animation()`，避免出现缩放类动画。
 */
@Component
export struct FloatingNavigation {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  /** 当前选中项 0..4（首页 / 收件箱 / 订阅 / 搜索 / 更多） */
  @Prop currentIndex: number = 0;
  /** 收件箱未读数（>0 才画角标） */
  @Prop badge: number = -1;
  /** 折叠进度：0 = 完整导航栏，1 = 只留当前 Tab 的圆形按钮（由外壳统一驱动） */
  @Prop progress: number = 0;
  /** 外壳测得的可用宽度（vp），用于把每项宽度算成可插值的数值 */
  @Prop availableWidth: number = 0;
  /** 折叠态下点击圆钮：展开导航（而不是切换页面） */
  onExpand: () => void = () => {
  };
  /** 「更多」菜单是否展开：仅用于让该项在菜单打开时也呈现品牌色 */
  onSwitch: (index: number) => void = () => {
  };
  /** 点击「更多」：由外壳展开 / 收起自绘菜单 */

  /** 图标与文字间距（展开态）：需求建议 5–7vp */
  private static readonly ITEM_GAP: number = 6;
  /** 导航文字行高：折叠时收到 0，让图标居中 */
  private static readonly LABEL_HEIGHT: number = 14;

  private static readonly HOME: number = 0;
  private static readonly INBOX: number = 1;
  private static readonly SUBSCRIPTIONS: number = 2;
  private static readonly SEARCH: number = 3;
  private static readonly MORE: number = 4;

  /** 当前高度：展开 56vp → 折叠 44vp（与播放条等高，圆钮为正圆） */
  private barHeight(): number {
    // 导航栏整体高度保持 58（圆钮为正圆）；只有内部项宽度与文字参与折叠
    return DesignTokens.HEIGHT_FLOAT_NAV;
  }

  build() {
    Row() {
      // 整条胶囊：材质由 GlassSurface 统一提供（背景模糊 + 淡染色 + 细描边）
      GlassSurface({
        barHeight: this.barHeight(),
        radius: this.barHeight() / 2,
        blurRadius: 32,
        tint: $r('app.color.nav_bar_fill'),
        stroke: $r('app.color.nav_bar_stroke')
      }) {
        Row() {
          // 首页：房屋 → 实心房屋
          this.navItem(FloatingNavigation.HOME, $r('app.string.tab_home'),
            $r('sys.symbol.house'), $r('sys.symbol.house_fill'), -1)
          // 单集：列表 → 列表（系统符号无实心列表，选中仅变色）
          this.navItem(FloatingNavigation.INBOX, $r('app.string.episodes_label'),
            $r('sys.symbol.rectangle_stack'), $r('sys.symbol.rectangle_stack'), -1)
          // 订阅：书签 → 实心书签
          this.navItem(FloatingNavigation.SUBSCRIPTIONS, $r('app.string.tab_subscriptions'),
            $r('sys.symbol.dot_radiowaves_left_and_right'),
            $r('sys.symbol.dot_radiowaves_left_and_right'), -1)
          // 搜索：放大镜（系统无实心放大镜，选中仅变色，保持清晰造型）
          this.navItem(FloatingNavigation.SEARCH, $r('app.string.discover_search'),
            $r('sys.symbol.magnifyingglass'), $r('sys.symbol.magnifyingglass'), -1)
        }
        .width('100%')
        .height('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    .width('100%')
    .height(this.barHeight())
    // 左右留白由外壳 Index 统一提供，这里不再重复内缩（否则播放条与底栏宽度不等）
  }

  /**
   * 导航项：图标在上、文字在下。
   * `idleIcon` 与 `activeIcon` 相同表示该图标没有实心变体，选中只变色。
   */
  /**
   * 导航项。宽度由 `progress` 连续插值：
   * 展开时四项均分整条胶囊；折叠时只有当前项占满、其余收缩为 0，
   * 因此「整条导航栏凝聚成一个圆」是同一条组件在变形，而不是两个组件切换。
   */
  @Builder
  navItem(index: number, label: Resource, idleIcon: Resource, activeIcon: Resource, itemBadge: number) {
    // 间距随折叠收敛到 0：折叠时容器里只剩图标，自然严格居中；不再用固定偏移去「凑」位置
    Column({ space: FloatingNavigation.ITEM_GAP * (1 - this.progress) }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        SymbolGlyph(this.currentIndex === index ? activeIcon : idleIcon)
          .fontSize(DesignTokens.ICON_NAV)
          .fontColor([this.currentIndex === index ? $r('app.color.nav_brand') : $r('app.color.nav_item_idle')])
          .opacity(this.currentIndex === index ? 1 : 1 - this.progress)
          .scale({ x: this.currentIndex === index ? 1 : 1 - 0.25 * this.progress,
            y: this.currentIndex === index ? 1 : 1 - 0.25 * this.progress })
        if (itemBadge > 0) {
          Text(itemBadge > 99 ? '99+' : itemBadge.toString()).fontFamily(this.appFontFamily)
            .fontSize(9)
            .fontColor(Color.White)
            .backgroundColor($r('app.color.badge_bg'))
            .borderRadius(7)
            .padding({ left: 3, right: 3, top: 1, bottom: 1 })
            .margin({ top: -4, right: -10 })
        }
      }
      .height(DesignTokens.ICON_NAV)

      // 文字高度随折叠收到 0：布局上让出占位，图标因此回到圆心（不是靠偏移量掩盖）
      Text(label).fontFamily(this.appFontFamily)
        .fontSize(DesignTokens.FONT_NAV)
        .fontColor(this.currentIndex === index ? $r('app.color.nav_brand') : $r('app.color.nav_item_idle'))
        .maxLines(1)
        .height(FloatingNavigation.LABEL_HEIGHT * (1 - this.progress))
        .opacity(1 - this.progress)
        .clip(true)
    }
    .width(this.itemWidth(index))
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .clip(true)
    .accessibilityText(label)
    .accessibilitySelected(this.currentIndex === index)
    .onClick(() => {
      if (this.progress > 0.5) {
        // 折叠态：整条已收成圆钮，点击只负责展开，不切换页面
        this.onExpand();
        return;
      }
      this.onSwitch(index);
    })
  }

  /** 单项宽度：展开态均分整条宽度，折叠态只剩当前项（宽度 = 整条宽度，即圆钮直径） */
  private itemWidth(index: number): number {
    const total: number = this.availableWidth > 0 ? this.availableWidth : 360;
    const expanded: number = total / 4;
    const collapsed: number = this.currentIndex === index ? total : 0;
    return expanded * (1 - this.progress) + collapsed * this.progress;
  }


}
