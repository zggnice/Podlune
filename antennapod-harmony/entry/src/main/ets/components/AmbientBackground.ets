/**
 * 全局背景（纯色）。
 *
 * 历史：本组件曾实现过冰蓝紫渐变（多矩形径向渐变 → 单层纵向渐变），
 * 但用户最终选择回到最初的**纯色背景**，因此这里只保留一个铺满窗口的纯色层。
 * 颜色走资源限定符（`page_bg`：浅色 #F1F3F5 / 深色 #000000），随主题自动切换。
 *
 * 保留该组件而不是删除，是为了让 Index 的结构不变（背景始终是最底层），
 * 后续若要再叠任何背景效果，只改这里即可。
 */
@Component
export struct AmbientBackground {
  build() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg'))
      // 背景层不参与命中测试，避免遮挡页面交互
      .hitTestBehavior(HitTestMode.Transparent)
  }
}
