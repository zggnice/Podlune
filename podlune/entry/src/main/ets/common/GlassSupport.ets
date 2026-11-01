import { uiMaterial } from '@kit.ArkUI';
import { hdsMaterial } from '@kit.UIDesignKit';
import { NavigationAppearance } from '../utils/NavigationAppearance';

/** 沉浸系统材质与玻璃观感的统一判定（底栏 / 顶栏 / 播放条共用）。 */
export class GlassSupport {
  private static cachedImmersive: boolean | undefined = undefined;
  private static cachedSystemImmersive: boolean | undefined = undefined;

  /** 组件级 `systemMaterial` 能否生效（API 26 且系统未关闭沉浸材质） */
  static componentMaterial(): boolean {
    if (GlassSupport.cachedImmersive !== undefined) {
      return GlassSupport.cachedImmersive;
    }
    let ok: boolean = false;
    try {
      const info: uiMaterial.MaterialInfo = uiMaterial.getMaterialInfo();
      ok = uiMaterial.isImmersiveMaterialSupported() && info.state !== uiMaterial.MaterialState.DISABLE;
    } catch (error) {
      ok = false;
    }
    GlassSupport.cachedImmersive = ok;
    return ok;
  }

  /**
   * 系统级沉浸光感是否默认开启（`MaterialState.DEFAULT`）。
   * HDS 的 `materialType: ADAPTIVE` 是否真正出沉浸效果取决于它。
   */
  static systemImmersive(): boolean {
    if (GlassSupport.cachedSystemImmersive !== undefined) {
      return GlassSupport.cachedSystemImmersive;
    }
    let ok: boolean = false;
    try {
      const info: uiMaterial.MaterialInfo = uiMaterial.getMaterialInfo();
      // 参考 yunshang-bili 的 MaterialUtil.available()：HDS 能列出系统材质类型才算真机支持，
      // 否则只是 SDK 有 API、系统没开沉浸光感（材质量会渲染成空）。
      const hdsReady: boolean = hdsMaterial.getSystemMaterialTypes().length > 0;
      ok = hdsReady && (info.type === uiMaterial.MaterialType.IMMERSIVE
        || info.state === uiMaterial.MaterialState.ENABLE);
    } catch (error) {
      ok = false;
    }
    GlassSupport.cachedSystemImmersive = ok;
    return ok;
  }

  /** 玻璃内容层（导航栏 / 播放条胶囊）的背景色：材质生效时透明，否则半透明兜底 */
  static glassFill(level: number): ResourceColor {
    return GlassSupport.componentMaterial() && NavigationAppearance.normalize(level) > 0
      ? Color.Transparent : $r('app.color.glass_tint');
  }

  /**
   * HDS（`@kit.UIDesignKit` 的 HdsTabs）底栏材质是否可用。
   * 本机 API 26 SDK 已带 UIDesignKit；系统没有该组件时构建期就会失败，
   * 因此这里恒为 true，作为「是否走 HDS 材质层」的开关保留给后续降级需求。
   */
  static hdsAvailable(): boolean {
    return true;
  }
}
