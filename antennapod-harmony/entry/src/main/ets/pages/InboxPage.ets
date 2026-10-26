import { InboxView } from './InboxView';

/** Inbox 路由页（内容见 InboxView，同时被底部「收件箱」页签复用）。 */
@Entry
@Component
struct InboxPage {
  build() {
    Column() {
      InboxView({ asTab: false })
    }
    .width('100%')
    .height('100%')
    // 路由页外壳同样铺到状态栏/手势区，避免出现独立色块
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
