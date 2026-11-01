import { uiMaterial } from '@kit.ArkUI';
import { NavigationAppearance } from '../utils/NavigationAppearance';

/**
 * 悬浮玻璃材质（API 26 沉浸光感）。
 *
 * `systemMaterial` 是 API 26 的通用属性，任何组件都能挂；这里按「沉浸光感强度」
 * 档位把同一种材质给所有浮动层（底栏、迷你播放条、悬浮顶栏）复用，保证观感一致。
 *
 * 档位与材质映射：
 * - 0 关闭   → 不挂材质（容器只保留模糊降级底，实色感）
 * - 1 柔和   → REGULAR（无形变、无点光源）
 * - 2 均衡   → THIN（原生交互形变 + 点光源，默认）
 * - 3 通透   → ULTRA_THIN（最通透）
 *
 * 兜底底色统一走 `nav_fallback`（半透明），材质不可用时由它 + 模糊承担玻璃观感；
 * 材质可用时系统接管背景，此色不参与绘制。
 */
export class NavigationGlass {
  private static cachedSupported: boolean | undefined = undefined;
  /** 材质实例按「档位」缓存：每帧 new 一个 ImmersiveMaterial 会白白消耗绘制资源 */
  private static readonly cache: Map<number, uiMaterial.Material> = new Map<number, uiMaterial.Material>();

  /** 当前设备是否支持沉浸材质（结果缓存，避免每帧查询系统） */
  static supported(): boolean {
    if (NavigationGlass.cachedSupported !== undefined) {
      return NavigationGlass.cachedSupported;
    }
    let ok: boolean = false;
    try {
      ok = uiMaterial.isImmersiveMaterialSupported()
        && uiMaterial.getMaterialInfo().state !== uiMaterial.MaterialState.DISABLE;
    } catch (error) {
      ok = false;
    }
    NavigationGlass.cachedSupported = ok;
    return ok;
  }

  /** 按档位取材质；档位 0 或系统不支持返回 undefined */
  static materialFor(level: number): SystemUiMaterial | undefined {
    const normalized: number = NavigationAppearance.normalize(level);
    if (normalized <= 0 || !NavigationGlass.supported()) {
      return undefined;
    }
    const cached: uiMaterial.Material | undefined = NavigationGlass.cache.get(normalized);
    if (cached !== undefined) {
      return cached;
    }
    const options: uiMaterial.ImmersiveOptions = {
      style: normalized === 1 ? uiMaterial.ImmersiveStyle.REGULAR
        : normalized === 3 ? uiMaterial.ImmersiveStyle.ULTRA_THIN : uiMaterial.ImmersiveStyle.THIN,
      materialColor: $r('app.color.nav_glass_tint'),
      colorInvert: false,
      applyShadow: true,
      interactive: normalized >= 2,
      lightEffect: normalized >= 2 ? { color: $r('app.color.nav_glass_light') } : null
    };
    const material: uiMaterial.Material = new uiMaterial.ImmersiveMaterial(options);
    NavigationGlass.cache.set(normalized, material);
    return material;
  }

  /**
   * 浮动层背景亮度自适应：背景越亮，文字自动加深。
   * 与 systemMaterial 一起用时只影响前景可读性，不改变材质本身。
   */
  static adaptiveBrightness(): BackgroundBrightnessOptions {
    return { rate: 0.6, lightUpDegree: 0 };
  }

  /** HDS 用的材质参数（与组件级材质保持同一档位语义） */
  static levelOf(level: number): number {
    return NavigationAppearance.normalize(level);
  }
}
