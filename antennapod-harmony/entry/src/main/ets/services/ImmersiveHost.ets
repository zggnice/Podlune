import { window } from '@kit.ArkUI';
import common from '@ohos.app.ability.common';
import { Logger } from '../utils/Logger';

const TAG: string = 'ImmersiveHost';

/**
 * 窗口级沉浸式布局的**唯一**开关处（引用计数）。
 *
 * 背景：之前节目详情页在 `aboutToAppear/aboutToDisappear` 里各自
 * `setWindowLayoutFullScreen(true/false)`，而播放器页也在同一窗口内渲染。
 * 跳转时「新页进场 / 旧页退场」两个生命周期交错触发，窗口布局在转场动画**中途**
 * 被翻转一次 → 新旧页面按不同的安全区排版 → 出现页面错位、状态栏重影。
 *
 * 现在改为引用计数：
 *  - 需要全屏的页面 `acquire()`，只有第一个 acquire 才真正打开；
 *  - 离开时 `release()`，只有最后一个 release 才真正关闭；
 *  - 详情页 → 播放器（两者都需要全屏）之间切换时，计数从 1→2→1，**窗口布局完全不动**，
 *    转场期间不会再有布局翻转。
 */
export class ImmersiveHost {
  private static owners: Set<string> = new Set<string>();
  private static enabled: boolean = false;

  /** 申请全屏布局（幂等） */
  static acquire(context: common.UIAbilityContext, pageId: string): void {
    ImmersiveHost.owners.add(pageId);
    if (ImmersiveHost.enabled) {
      return;
    }
    ImmersiveHost.enabled = true;
    ImmersiveHost.apply(context, true);
  }

  /** 释放全屏布局：全部页面都释放后才真正关闭 */
  static release(context: common.UIAbilityContext, pageId: string): void {
    ImmersiveHost.owners.delete(pageId);
    if (ImmersiveHost.owners.size > 0 || !ImmersiveHost.enabled) {
      return;
    }
    ImmersiveHost.enabled = false;
    ImmersiveHost.apply(context, false);
  }

  /** 状态栏高度（vp）：全屏布局下页面自己避让 */
  static async statusBarHeight(context: common.UIAbilityContext): Promise<number> {
    try {
      const win: window.Window = await window.getLastWindow(context);
      const avoid: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      return px2vp(avoid.topRect.height);
    } catch (error) {
      return 0;
    }
  }

  private static apply(context: common.UIAbilityContext, enable: boolean): void {
    window.getLastWindow(context).then((win: window.Window) => {
      win.setWindowLayoutFullScreen(enable).then(() => {
        Logger.info(TAG, 'layout full screen -> ' + enable);
      }).catch((error: Error) => {
        Logger.warn(TAG, 'setWindowLayoutFullScreen failed: ' + error.message);
      });
    }).catch((error: Error) => {
      Logger.warn(TAG, 'getLastWindow failed: ' + error.message);
    });
  }
}
