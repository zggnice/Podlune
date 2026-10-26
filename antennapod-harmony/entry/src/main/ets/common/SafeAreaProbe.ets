import { window } from '@kit.ArkUI';

/**
 * 系统避让区（单位 vp）。
 *
 * 悬浮底栏、播放条都是叠在内容上的浮动层，必须自己让开手势条 / 三键导航，
 * 否则会压在手势条上（模拟器实测：底部避让 0 时胶囊会吃到手势条区域）。
 */
export class SafeAreaProbe {
  /**
   * 底部避让高度（vp）：手势条或三键导航栏。
   * 找不到窗口（预览器 / 早期生命周期）时返回 12vp 的保守间距，而不是 0。
   */
  static async bottomInset(): Promise<number> {
    try {
      const win: window.Window = await window.getLastWindow(getContext());
      const gesture: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM_GESTURE);
      const system: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const gestureHeight: number = px2vp(gesture.bottomRect.height);
      const systemHeight: number = px2vp(system.bottomRect.height);
      const height: number = Math.max(gestureHeight, systemHeight);
      return height > 0 ? height : 0;
    } catch (error) {
      return 0;
    }
  }
}
