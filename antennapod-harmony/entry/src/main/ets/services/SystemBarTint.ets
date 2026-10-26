import { window } from '@kit.ArkUI';
import common from '@ohos.app.ability.common';
import { Logger } from '../utils/Logger';

const TAG: string = 'SystemBarTint';

/**
 * 页面级系统栏颜色（只改**状态栏内容颜色**，背景始终透明）。
 *
 * 为什么要页面级：节目详情页的顶部背景来自封面，明暗差异极大；
 * 全局在 EntryAbility 里按主题写死 #E5FFFFFF 会在浅色封面上「白字白底」。
 *
 * 约束：
 *  - 只在页面进入（拿到封面主色）/ 离开（恢复主题默认）时各调用一次，**不在滚动中调用**；
 *  - 相同目标值不重复下发（避免异步时序互相覆盖）；
 *  - 只改 statusBarContentColor，不改窗口布局（`setWindowLayoutFullScreen` 不用），
 *    内容仍由系统安全区避让，其他页面不受影响。
 */
export class SystemBarTint {
  /** 上一次下发的「内容是否深色」；undefined = 未接管（主题默认） */
  private static lastDark: boolean | undefined = undefined;
  /** 页面级写入的去重键（pageId|status|content） */
  private static lastKey: string = '';

  /** 按封面亮度决定状态栏文字/图标用深色还是浅色 */
  static async applyForBrightness(context: common.UIAbilityContext, luminance: number,
                                  pageId: string = ''): Promise<void> {
    if (pageId !== '' && SystemBarTint.owner !== '' && SystemBarTint.owner !== pageId) {
      return;
    }
    if (pageId !== '') {
      SystemBarTint.owner = pageId;
    }
    // 阈值 + 滞回：>0.62 视为浅色背景（用深色字），否则用浅色字
    const wantDark: boolean = luminance > 0.62;
    if (SystemBarTint.lastDark === wantDark) {
      return;
    }
    await SystemBarTint.push(context, wantDark ? '#DD000000' : '#FFFFFFFF', wantDark);
  }

  /**
   * 页面级「只改内容色」申请：状态栏**底色始终透明**，由页面自己的背景透上来。
   * 这是修复「进入播放器时状态栏残留上一页底色」的关键——之前给 FeedDetail 写了
   * 不透明 statusBarColor，窗口级属性会一直留到播放器页，形成棕色横条。
   */
  static async claimPage(context: common.UIAbilityContext, pageId: string,
                         contentColor: string, statusColor: string = '#00000000'): Promise<void> {
    if (SystemBarTint.owner !== '' && SystemBarTint.owner !== pageId) {
      return;
    }
    SystemBarTint.owner = pageId;
    const key: string = pageId + '|' + contentColor + '|' + statusColor;
    if (SystemBarTint.lastKey === key) {
      return;
    }
    SystemBarTint.lastKey = key;
    try {
      const win: window.Window = await window.getLastWindow(context);
      await win.setWindowSystemBarProperties({
        statusBarColor: statusColor,
        statusBarContentColor: contentColor,
        navigationBarColor: SystemBarTint.pageBg(context),
        navigationBarContentColor: contentColor
      });
    } catch (error) {
      Logger.warn(TAG, 'claimPage failed: ' + error);
    }
  }

  /**
   * 页面级沉浸式布局开关（window 级能力，离开时必须恢复）。
   * 打开后窗口内容延伸到状态栏/手势区，页面自己按 `statusBarHeight` 给内容留白。
   */
  static async setFullScreen(context: common.UIAbilityContext, enable: boolean): Promise<void> {
    try {
      const win: window.Window = await window.getLastWindow(context);
      await win.setWindowLayoutFullScreen(enable);
      Logger.info(TAG, 'layout full screen -> ' + enable);
    } catch (error) {
      Logger.warn(TAG, 'setWindowLayoutFullScreen failed: ' + error);
    }
  }

  /** 当前占用状态栏的页面标识（谁最后申请谁拥有，退出时只有拥有者能恢复） */
  private static owner: string = '';

  /**
   * 页面级状态栏配色（沉浸式用）：进入页面后按当前顶部背景设置，
   * `statusColor` 用不透明色即可——系统状态栏本身就是最顶上那条背景，
   * 这样不需要 `setWindowLayoutFullScreen` 也能让「状态栏背景 = 页面顶部背景」，
   * 避免页面跳转期间反复切换窗口布局导致的错位/重影。
   * 只有拥有者可以写入；同值不重复下发。
   */
  static async applyPageTint(context: common.UIAbilityContext, pageId: string,
                             statusColor: string, contentColor: string): Promise<void> {
    if (SystemBarTint.owner !== '' && SystemBarTint.owner !== pageId) {
      return;
    }
    const key: string = pageId + '|' + statusColor + '|' + contentColor;
    if (SystemBarTint.lastKey === key) {
      return;
    }
    SystemBarTint.owner = pageId;
    SystemBarTint.lastKey = key;
    try {
      const win: window.Window = await window.getLastWindow(context);
      await win.setWindowSystemBarProperties({
        statusBarColor: statusColor,
        statusBarContentColor: contentColor
      });
    } catch (error) {
      Logger.warn(TAG, 'applyPageTint failed: ' + error);
    }
  }

  /** 释放页面所有权（只有拥有者能释放，避免已退出页面覆盖当前页面） */
  static async releasePage(context: common.UIAbilityContext, pageId: string): Promise<void> {
    if (SystemBarTint.owner !== pageId) {
      return;
    }
    SystemBarTint.owner = '';
    SystemBarTint.lastKey = '';
    await SystemBarTint.restore(context);
  }

  /** 状态栏高度（vp）：immersion 场景下的避让参考 */
  static async statusBarHeight(context: common.UIAbilityContext): Promise<number> {
    try {
      const win: window.Window = await window.getLastWindow(context);
      const avoid: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      return px2vp(avoid.topRect.height);
    } catch (error) {
      return 0;
    }
  }

  /** 恢复主题默认（离开页面、或拿到封面颜色失败时） */
  static async restore(context: common.UIAbilityContext): Promise<void> {
    let color: string = '#DD000000';
    try {
      const argb: number = context.resourceManager.getColorByNameSync('text_primary') >>> 0;
      color = '#' + argb.toString(16).padStart(8, '0');
    } catch (error) {
      // 解析失败就用主题常见的深色值
    }
    SystemBarTint.lastDark = undefined;
    await SystemBarTint.push(context, color, undefined);
  }

  /** 当前主题的页面底色（浅灰 / 深黑）：底部导航条用它，避免出现白带 */
  static pageBg(context: common.UIAbilityContext): string {
    try {
      const argb: number = context.resourceManager.getColorByNameSync('page_bg') >>> 0;
      return '#' + argb.toString(16).padStart(8, '0');
    } catch (error) {
      return '#F1F3F5';
    }
  }

  private static async push(context: common.UIAbilityContext, contentColor: string,
                            dark: boolean | undefined): Promise<void> {
    try {
      const win: window.Window = await window.getLastWindow(context);
      // ⚠️ 只写 statusBar* 会让 navigationBar* 回到系统默认（浅色模式下即纯白，
      // 页面底部因此出现一条白带）。这里必须把导航条颜色一起写上。
      const props: window.SystemBarProperties = {
        statusBarColor: '#00000000',
        statusBarContentColor: contentColor,
        navigationBarColor: SystemBarTint.pageBg(context),
        navigationBarContentColor: contentColor
      };
      await win.setWindowSystemBarProperties(props);
      SystemBarTint.lastDark = dark;
      Logger.info(TAG, 'status bar content -> ' + contentColor);
    } catch (error) {
      Logger.warn(TAG, 'setWindowSystemBarProperties failed: ' + error);
    }
  }
}
