import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { DesignTokens } from './DesignTokens';
import { NavigationAppearance } from '../utils/NavigationAppearance';

/** API 26 原生悬浮页签；算力等级由系统管理，应用仅选择材质与交互风格。 */
export class NavigationMaterial {
  static supportsFloating(): boolean {
    return deviceInfo.sdkApiVersion >= 26;
  }

  static supportsMaterial(): boolean {
    if (!NavigationMaterial.supportsFloating()) {
      return false;
    }
    return uiMaterial.isImmersiveMaterialSupported()
      && uiMaterial.getMaterialInfo().state !== uiMaterial.MaterialState.DISABLE;
  }

  static label(level: number): Resource {
    switch (NavigationAppearance.normalize(level)) {
      case 0: return $r('app.string.nav_light_off');
      case 1: return $r('app.string.nav_light_soft');
      case 3: return $r('app.string.nav_light_clear');
      default: return $r('app.string.nav_light_balanced');
    }
  }
}

/** 版本检查放在 modifier 内，API 14–25 不调用 API 26 的属性。 */
export class FloatingNavigationModifier implements AttributeModifier<TabsAttribute> {
  private level: number;
  private width: number;

  constructor(level: number, availableWidth: number = 360) {
    this.level = NavigationAppearance.normalize(level);
    this.width = Math.max(240, Math.min(480, availableWidth - DesignTokens.PAGE_MARGIN * 2));
  }

  applyNormalAttribute(instance: TabsAttribute): void {
    if (!NavigationMaterial.supportsFloating()) {
      instance.barOverlap(false).barBackgroundColor($r('app.color.surface'));
      return;
    }
    const enabled: boolean = this.level > 0 && NavigationMaterial.supportsMaterial();
    const options: uiMaterial.ImmersiveOptions = {
      style: this.level === 1 ? uiMaterial.ImmersiveStyle.REGULAR
        : this.level === 3 ? uiMaterial.ImmersiveStyle.ULTRA_THIN : uiMaterial.ImmersiveStyle.THIN,
      materialColor: $r('app.color.nav_glass_tint'),
      colorInvert: false,
      applyShadow: true,
      interactive: this.level >= 2,
      lightEffect: this.level >= 2 ? { color: $r('app.color.nav_glass_light') } : null
    };
    const style: FloatingTabBarStyle = {
      barWidth: { smallBarWidth: this.width, mediumBarWidth: this.width, largeBarWidth: this.width },
      barSideMargin: DesignTokens.PAGE_MARGIN,
      barBottomMargin: DesignTokens.NAV_BOTTOM_MARGIN,
      // 不叠加整块底部渐变，保留封面与内容穿过材质时的颜色。
      maskColor: Color.Transparent,
      maskHeight: 0,
      adaptToHandedness: false,
      systemMaterial: enabled ? new uiMaterial.ImmersiveMaterial(options) : uiMaterial.Material.empty
    };
    instance.barOverlap(true)
      .barBackgroundColor(enabled ? Color.Transparent : $r('app.color.surface'))
      .barFloatingStyle(style);
    instance.onContentWillChange((_current: number, next: number) => next !== 4);
  }
}
