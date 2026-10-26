# 底部导航与浮层玻璃（API 26）

2026-10-20 改版：底栏与迷你播放条统一为「液态玻璃胶囊」。本文件是导航形态的唯一事实来源，
替代 `06-ui-design-spec.md` 中「贴边底栏 + 选中胶囊底」的旧约定。

## 首页「待播清单」大卡

- 区块名由「继续收听」改为 **待播清单**（`app.string.home_continue`：中文 `待播清单`，英文 `Up next`）。
  全局替换：首页区块标题、编辑区块列表、`EpisodesPage` 过滤项、注释、README、`docs/`。
  **历史页的「继续收听」（`history_continue`）保持不变**——那是播放历史的分区语义。
- 组件 `components/ContinueCard.ets`，严格对齐参考图：

  | 项 | 规格 |
  |---|---|
  | 卡片比例 | 宽 : 高 = 1 : 1.33（竖长） |
  | 上半段 | 单集封面，`layoutWeight(1)`，占约 67% 高度 |
  | 下半段 | 模糊信息区，占 33.5%：同一张封面放大 1.4× 后 `blur(30)` |
  | 衔接 | 上沿透明 `#00000000` → `#8F000000`，避免硬边（实测接缝亮度连续 112→88） |
  | 卡宽 | `(屏宽 − 44) / 1.5`，即整屏能放下**完整一张 + 下一张的左半边** |
  | 信息区 | 订阅小标签(26vp) → 日期(11fp) → 标题(14fp×2行) → 摘要(11fp×1行) → 底部胶囊 |
  | 底部胶囊 | 播放图标 + 进度条(44vp) + 剩余时长；右侧「更多」三点 |

- **两个必须避开的布局坑**（都实测踩过）：
  1. 信息区**不能用 `position()` 绝对定位**——不参与布局，内容会整个消失；
     必须在 `Column` 里用 `layoutWeight` + 固定高度顺序排列。
  2. 信息区高度不够时，底部胶囊会被挤出卡片（表现为「只剩日期和标题」）；
     标题压到 2 行、行高 17，`infoRatio ≥ 0.335` 才能稳定容纳胶囊行。
- 手势：`TapGesture` 打开详情、`LongPressGesture(500ms)` 打开菜单；不要用
  `onClick` + `parallelGesture`（长按会被判成单击）。
## 结构

- 外壳 `pages/Index.ets` 用 `Navigation` 提供根容器（`hideTitleBar(true)`），不渲染系统标题栏。
- 内容区 `Column` 铺满整屏；浮动层（迷你播放条 + 底栏）用 `Column` 叠在内容之上并留出底部安全区。
- 页签：**首页 / 收件箱 / 订阅**。其余入口在「更多」菜单：
  队列、单集、下载、播放历史、收藏、收听统计、添加播客、设置。
  队列改为子页面（`pages/QueuePage`）；首页「待播清单 → 队列」同样跳该页。
- 底栏右侧独立一项「搜索」，点击进 `pages/SearchPage`。

## 底栏形态

| 项 | 规格 |
|---|---|
| 胶囊高度 | `HEIGHT_FLOAT_NAV = 58vp`（原 76vp 偏高，已下调） |
| 图标 | `ICON_NAV = 22vp`（原 24vp 偏大） |
| 文案 | `FONT_NAV = 11fp`，图标在上、文案在下，整组水平居中 |
| 选中态 | **只改图标与文字颜色**（品牌色 + 填充图标），不再画胶囊 / 椭圆底标记 |
| 左右内缩 | `FLOAT_NAV_SIDE = 8vp`，与播放条、悬浮顶栏对齐 |
| 离屏底 | `NAV_BOTTOM_MARGIN = 12vp` + 系统底部安全区（手势条 / 三键导航） |

> 旧实现用 `Tabs.barFloatingStyle`，其材质底固定挂在条后，无法做出整条半透明玻璃，
> 且选中态是「图标 + 文字」胶囊（带椭圆底）。现改为自绘玻璃层 + 自定义内容层。

## 玻璃层（`components/GlassSurface.ets`）

- 对**背后内容**做 `backgroundEffect`：`radius 28vp` 模糊 + `brightness 1.12` + `saturation 1.15`
  + 极淡染色 `glass_fill`（浅色 `#0AFFFFFF` / 深色 `#14FFFFFF`），外加 0.8vp 高光描边 `glass_stroke`。
- 短按 / 长按有 0.985 倍缩放回落（160/220ms，`FastOutSlowIn`），向系统手感靠近。
- 高度必须由调用方显式给定（`barHeight`）。**组件内部 Stack 不加尺寸约束会撑满父容器**，
  实测会盖住整页，这是本轮踩到的坑。

### 为什么不用 HDS `HdsTabs` / `systemMaterial`

- `HdsTabs`（`@kit.UIDesignKit`）在本机可正常渲染悬浮胶囊（`barFloatingStyle` + `systemMaterialEffect`），
  但 `.tabBar()` 只接受字符串，给不了「图标 + 文案」的自定义样式，因此仅作技术验证，未采用。
- 组件级 `systemMaterial(ImmersiveMaterial)` 可用且 API 26 已核验，但在浅色主题 + 浅色内容下
  底面会被渲染成近纯白，观感与「实色底」无异，玻璃层次反而更弱。
- 因此最终选择「自适应玻璃层」：纯色背景上是淡玻璃胶囊，内容滚到后方时透出模糊，两层都成立。

## 底栏选中态与「更多」菜单

- 选中态统一规则：**只改图标与文字颜色**（强调色 + 填充图标），不画胶囊 / 椭圆底标记。
- 首页 / 收件箱 / 订阅 / 搜索按 `currentIndex` 参与选中；**「更多」不对应内容页，
  它的选中态由菜单展开状态 `moreOpen` 驱动**（点开即变色，收起即恢复）。
- 图标「选中即实心」对照（`FloatingNavigation` 的 `navItem(..., activeIcon, ...)`）：

  | 项 | 未选中 | 选中 |
  |---|---|---|
  | 首页 | `house` | `house_fill` |
  | 收件箱 | `inbox` | `inbox_fill` |
  | 订阅 | `folder` | `folder_fill` |
  | 搜索 | `magnifyingglass` | 同字形 + `FontWeight.Bold` + 强调色（见下） |
  | 更多 | `more` | `more_fill` |

- **搜索项的已知限制**：系统符号库（`toolchains/id_defined.json`）里**没有实心放大镜**，
  只有 `magnifyingglass` / `magnifyingglass_circle` / `plus_magnifyingglass` 等描边版
  （已逐名核验，`magnifyingglass_fill`、`magnifyingglass_circle_fill` 均不存在）。
  因此选中态用「加粗 + 强调色」模拟实心：实测图标着色像素 1117，而描边常约 300 级，
  实心 `inbox_fill` 为 1531，观感与其它项的实心分量相当。若后续要严格实心，需自绘 SVG 资源。
- 搜索点击：先把该项置为选中（250ms，肉眼可辨）再进入搜索页；返回时恢复原页签高亮，
  避免底栏停在一个没有内容页的选中项上。

## 顶栏搜索入口（页内搜索，与底栏全局搜索分工）

- 首页顶栏只有「更多」——搜索已在底栏常驻，避免重复。
- **收件箱、订阅的顶栏搜索是「本页内容搜索」**，不跳全局搜索页（底栏那个才是跨源检索）：
  - 点搜索图标后顶栏原地变成 `TextInput`（右侧「取消」退出），标题暂时让位；
  - 收件箱：关键词进 SQL（`EpisodeRepository.listInboxPage` 新增 `keyword` 参数，
    匹配 `title` / `description`），仍走游标分页，结果完整而非只过滤已加载页；
  - 订阅：关键词并入 `SubscriptionsPage.applyFilter()`，匹配订阅 `title` / `author`，
    与标签、全局过滤器叠加生效。
  - 退出搜索会清空关键词并重新加载/过滤回全量。
- 订阅页顶栏原有「刷新」按钮收进「更多」菜单首位，不放回顶栏（顶栏保持「搜索 + 更多」两枚）。
- 菜单浮层实现见下节。

## 播放条与底栏的定位

- `NAV_BOTTOM_MARGIN` 由 12vp 降到 **2vp**：安全区仍由 `bottomSafe`（手势条实测高度）承担，
  这里只留极小呼吸量。实测底栏文字从 y=2562 下移到 y=2596（约 17vp），
  播放条与底栏的相对间距不变（同一个浮动 Column 内的 `SPACE_S`）。
- **播放条进度条两端内缩 17vp**（`PLAYER_PROGRESS_INSET`），让它只落在胶囊的直线段上。
  注意不是简单取半径 29vp：`Progress` 内部会按宽度再留白，实测「可见轨道距胶囊边缘」
  ≈ 1.68 × 内缩量，标定三档：10vp→33px（伸进圆角）、29vp→97px（短一截）、
  **17vp→57px**（胶囊半径 58px，正好贴合弯曲处，实测进度条 `[84,2444]-[1140,2454]`）。

- 「更多」菜单是**自绘浮层**（`Index.moreMenuOverlay()`），不是系统 `bindMenu`。
  原因：`bindMenu` 展开时不回传开关状态，而本工程 ArkTS 版本不支持 `bindMenu(isShow)` 的
  `$$` 双向绑定（编译报 `Cannot find name '$$this'`），按钮因此无法在展开时变色。
  自绘后菜单开关由单一状态源驱动，按钮颜色与菜单严格同步；点空白处收起、点条目先关菜单再跳转。
- 搜索：点击时先把该项置为选中（可见地变强调色），160ms 后进入搜索页，返回时恢复原页签高亮，
  避免底栏停在一个没有内容页的选中项上。

## 子页面队列

- 队列从底栏移入「更多」菜单后成为**子页面**：已在 `main_pages.json` 注册 `pages/QueuePage`，
  并加 `@Entry`。此前未注册时点击报 `can't find this page pages/QueuePage`（这正是「队列点了没反应」的根因）。
- 标题栏常驻返回箭头（`Number(router.getLength()) > 1` 时显示，栈底不显示）。

## 设置

入口：设置 → 用户界面 → 沉浸光感强度（`prefNavigationLightLevel`）。
当前底栏观感不随该档位变化（玻璃层统一为均衡档），保留偏好以免影响既有设置项与文案；
后续若要开放「通透 / 厚」四档，只需把档位传给 `GlassSurface.blurRadius` / `tint`。

## 向后兼容

- API 14–25 无 `backgroundEffect` 之外的依赖问题，但底栏降级为贴边实色栏（`legacyNavigation`），
  页签同为 首页 / 收件箱 / 订阅 + 更多菜单。
- 深浅色沿用资源限定符（`base` / `dark` 的 `glass_fill`、`glass_stroke`、`nav_selected`）。
- 强调色已由蓝 `#0A59F7` 改为紫 `#7B4DFF`（深色 `#A98BFF`），`primary_container`、`nav_selected`、
  播放页阴影同步更新。

## 验收（2026-10-20，真机 MIA-AL00 / HarmonyOS 7.0.0.109 / API 26）

1. hvigor `assembleHap`（debug）编译通过，签名安装成功后逐项操作截图。
2. 底栏五项、图标在上文案在下、选中只变色：通过。
3. 点「更多」：菜单展开且按钮变强调色（像素采样：展开时 292 个紫色像素，收起时 0 个 / 163 个深灰像素）：通过。
4. 菜单「队列」跳转成功（`pushUrl pages/QueuePage`，页面显示队列信息条）：通过。
5. 点「搜索」：先变强调色（295 个紫色像素）再进搜索页，返回后恢复首页高亮（253/0/0）：通过。
6. 首页 / 收件箱 / 订阅三页顶栏统一：标题均为 bounds x=54px、22fp、顶格，右侧仅「更多」：通过。
7. 首页滚动时卡片 / 封面从底栏与播放条后方透出、玻璃模糊可见：通过。
8. 播放条 + 底栏同屏时两者间距 8vp、播放条与底栏同宽同高：通过。
