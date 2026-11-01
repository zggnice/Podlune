/** 导航外观偏好：0 关闭、1 柔和、2 均衡、3 通透。纯逻辑，不加载平台 UI 模块。 */
export class NavigationAppearance {
  static readonly DEFAULT_LEVEL: number = 2;

  static normalize(value: number): number {
    return Number.isFinite(value) ? Math.max(0, Math.min(3, Math.round(value))) : NavigationAppearance.DEFAULT_LEVEL;
  }
}
