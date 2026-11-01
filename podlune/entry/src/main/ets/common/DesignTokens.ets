/**
 * Podlune 设计令牌（HarmonyOS 官方设计规范落地）：
 * 间距 8vp 网格、字阶（fp）、圆角、组件尺寸集中在此；颜色走资源（base/dark 自适应）。
 * 参考：HarmonyOS 设计指南《视觉风格》《应用布局》《字阶》规范。
 */
export class DesignTokens {
  /** 页面左右安全边距（手机 16vp） */
  static readonly PAGE_MARGIN: number = 16;
  /** 卡片圆角：列表行 12，大卡 16，弹层顶角 24 */
  static readonly RADIUS_ROW: number = 12;
  static readonly RADIUS_CARD: number = 16;
  static readonly RADIUS_SHEET: number = 24;
  static readonly RADIUS_BUTTON: number = 22;
  static readonly RADIUS_CHIP: number = 16;
  /** 首页横滑单集卡片：比列表行更柔和，同时保持鸿蒙卡片的克制圆角。 */
  static readonly RADIUS_EPISODE_CARD: number = 18;
  /** 高度（上游 AntennaPod：标题栏 56dp、底部导航 64dp、按钮 40dp） */
  static readonly HEIGHT_APP_BAR: number = 56;
  static readonly HEIGHT_TAB_BAR: number = 64;
  static readonly HEIGHT_TAB_BAR_SAFE: number = 68;
  /** 悬浮底栏（胶囊）与悬浮播放条 */
  static readonly HEIGHT_FLOAT_NAV: number = 58;
  // 播放条比底栏矮一截（约 3/4 高度），视觉上不再显得「胖」
  static readonly HEIGHT_FLOAT_PLAYER: number = 44;
  /** 底栏图标（图标在上、文案在下，与系统底部导航一致） */
  static readonly ICON_NAV: number = 25;
  /** 底栏左右内边距：播放条、底栏、悬浮顶栏共用，保证三条胶囊左右对齐 */
  // 底栏 / 播放条距离屏幕两侧的留白（原来 8 太贴边）
  static readonly FLOAT_NAV_SIDE: number = 20;
  /** 底栏选中项「图标 + 文字」胶囊高度（当前选中态已改为只变色，保留令牌供旧系统降级使用） */
  static readonly NAV_PILL_HEIGHT: number = 48;
  /** 悬浮顶栏（页签页大标题区与子页面标题栏共用） */
  static readonly HEIGHT_FLOAT_TOP_BAR: number = 56;
  /** 悬浮顶栏与状态栏之间、顶栏左右的安全间距 */
  static readonly FLOAT_TOP_MARGIN: number = 6;
  /** 内容让出悬浮顶栏后的起始偏移（顶栏 56 + 上 6 + 下 8） */
  static readonly FLOAT_TOP_INSET: number = 70;
  /** 悬浮顶栏内大标题的字号（页签页）：22fp Bold */
  static readonly FONT_FLOAT_TITLE: number = 22;
  /** 悬浮顶栏右侧主操作圆钮直径 */
  static readonly TOP_ACTION_SIZE: number = 40;
  /**
   * 播放条进度条两端的内缩量（vp）。
   * 胶囊半径是 29vp，但实测「可见轨道距胶囊边缘」≈ 1.68 × 该内缩量
   * （`Progress` 内部按宽度再留白），所以要贴合直线段起点需要 17vp 而不是 29vp。
   * 标定值：10vp → 距边 33px（伸进圆角），29vp → 97px（短一截），17vp → ≈58px（正好）。
   */
  static readonly PLAYER_PROGRESS_INSET: number = 17;
  /**
   * 底栏 / 播放条距屏幕底部的额外留白。
   * 系统手势条的安全区由 `bottomSafe` 单独承担，这里只保留极小的视觉呼吸（2vp）——
   * 之前 12vp 叠加安全区后整体偏上，用户反馈「显高」。
   */
  static readonly NAV_BOTTOM_MARGIN: number = 2;
  static readonly NAV_CONTENT_INSET: number = 88;
  static readonly HEIGHT_BUTTON: number = 40;
  static readonly HEIGHT_BUTTON_SM: number = 32;
  static readonly HEIGHT_ROW: number = 72;
  /** 封面尺寸（对齐上游：首页横滑卡片 128dp、订阅瓦片 96dp、列表行 56dp、详情头图 124dp） */
  static readonly COVER_HOME_CARD: number = 128;
  static readonly COVER_FEED_TILE: number = 96;
  static readonly COVER_LIST: number = 56;
  static readonly COVER_DETAIL: number = 124;
  /** 首页横滑卡片的宽度（128 封面 + 左右各 4 内边距） */
  static readonly WIDTH_HOME_CARD: number = 136;
  /** 间距 */
  static readonly SPACE_XS: number = 4;
  static readonly SPACE_S: number = 8;
  static readonly SPACE_M: number = 12;
  static readonly SPACE_L: number = 16;
  static readonly SPACE_XL: number = 20;
  static readonly SPACE_XXL: number = 24;
  /** 图标尺寸 */
  static readonly ICON_XXL: number = 28;
  static readonly ICON_XL: number = 24;
  static readonly ICON_L: number = 22;
  static readonly ICON_M: number = 20;
  static readonly ICON_S: number = 18;
  static readonly ICON_XS: number = 16;
  /** 触控热区 */
  static readonly HIT_MIN: number = 44;
  /** 字阶（fp，HarmonyOS 系统字体 HarmonyOS Sans） */
  static readonly FONT_DISPLAY: number = 28;
  static readonly FONT_TITLE1: number = 24;
  static readonly FONT_TITLE2: number = 22;
  static readonly FONT_TITLE3: number = 20;
  static readonly FONT_HEADLINE: number = 17;
  static readonly FONT_SECTION: number = 16;
  static readonly FONT_BODY: number = 16;
  static readonly FONT_SUBTITLE: number = 15;
  static readonly FONT_PARAGRAPH: number = 14;
  static readonly FONT_FOOTNOTE: number = 12;
  static readonly FONT_CAPTION: number = 11;
  static readonly FONT_OVERLINE: number = 10;
  /** 底部导航文字（上游 TextBottomNav = 11sp） */
  static readonly FONT_NAV: number = 11;
}
