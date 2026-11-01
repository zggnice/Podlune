import { font } from '@kit.ArkUI';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import common from '@ohos.app.ability.common';
import { UserPreferences } from '../prefs/UserPreferences';
import { Logger } from '../utils/Logger';

const TAG: string = 'AppFont';

/** AppStorage 键：全工程每个 Text 的 fontFamily 都读它（也是重绘依赖） */
export const APP_FONT_FAMILY_KEY: string = 'app_font_family';

/** 导入结果：取消与失败必须分开（用户点取消不能弹「失败」） */
export class FontImportResult {
  ok: boolean = false;
  cancelled: boolean = false;
  error: string = '';
}

/**
 * 全局自定义字体（.ttf / .otf / .ttc）。
 *
 * 平台前提：ArkUI 没有「全局默认字体」API（CustomTheme 只支持颜色，UIContext 也没有
 * setDefaultFontFamily），所以只能**逐个 Text 用 .fontFamily()** 应用。
 * 本工程的做法：各处挂 `@StorageProp('app_font_family')`，Text 写
 * `.fontFamily(this.appFontFamily)`；写入口只有本类（导入 / restore / clear）。
 *
 * 关键坑（照搬成熟实现的经验）：
 *  - `font.registerFont()` 的效果**不跨进程**：重启后键仍指向自定义族名，但系统字体管理器里
 *    已经没有这个名字 → 静默回落系统默认，所以启动必须 `restore()` 重新注册；
 *  - `familySrc` 必须带 `file://` 前缀；
 *  - 族名固定为 `PodluneCustom`，改动一次 = 已保存字体失效一次。
 */
export class AppFont {
  /** 注册进系统字体管理器的族名（固定） */
  static readonly FAMILY: string = 'PodluneCustom';
  /** 系统默认族名（显式写等于不写，但空串行为无保证） */
  static readonly DEFAULT_FAMILY: string = 'HarmonyOS Sans';

  private static readonly FONT_DIR: string = 'fonts';
  private static readonly FONT_BASE: string = 'custom';

  /** 当前是否有自定义字体（以沙箱里存在字体文件且路径非空为准） */
  static family(): string {
    return UserPreferences.getAppFontPath() === '' ? AppFont.DEFAULT_FAMILY : AppFont.FAMILY;
  }

  /** 把当前族名灌进 AppStorage（启动 / 导入 / 清除后调用） */
  static publish(): void {
    AppStorage.setOrCreate(APP_FONT_FAMILY_KEY, AppFont.family());
  }

  /** 字体文件在沙箱里的绝对路径（空串 = 未导入） */
  static fontFilePath(context: common.Context): string {
    const path: string = UserPreferences.getAppFontPath();
    if (path !== '') {
      return path;
    }
    const suffix: string = UserPreferences.getAppFontSuffix();
    return `${context.filesDir}/${AppFont.FONT_DIR}/${AppFont.FONT_BASE}${suffix}`;
  }

  /**
   * 启动时重注册（必须每次启动都调，且要在 UserPreferences.init 之后）。
   * 文件不在了 → 自动清除，避免 UI 显示一个其实没生效的字体名。
   */
  static restore(context: common.Context): void {
    const path: string = UserPreferences.getAppFontPath();
    if (path === '') {
      AppFont.publish();
      return;
    }
    try {
      if (!fs.accessSync(path)) {
        Logger.warn(TAG, 'font file missing, reset to system default');
        AppFont.clear();
        return;
      }
      font.registerFont({ familyName: AppFont.FAMILY, familySrc: 'file://' + path });
      Logger.info(TAG, 'font restored: ' + path);
    } catch (error) {
      Logger.warn(TAG, 'restore failed: ' + error);
      AppFont.clear();
      return;
    }
    AppFont.publish();
  }

  /**
   * UI 上下文就绪后再注册一次。
   * 背景：`@ohos.font.registerFont` 在 `Ability.onCreate` 阶段调用**不会报错**，但真机实测字体
   * 没进 UI 字体表（页面仍渲染系统字体）。用 `UIContext.getFont().registerFont()` 在窗口
   * 加载后注册才真正生效；注册成功后重发一次 AppStorage，让已构建的页面重新解析字体族。
   */
  static async attachUi(uiContext: UIContext): Promise<void> {
    if (UserPreferences.getAppFontPath() === '') {
      return;
    }
    const path: string = UserPreferences.getAppFontPath();
    try {
      if (!fs.accessSync(path)) {
        AppFont.clear();
        return;
      }
      uiContext.getFont().registerFont({ familyName: AppFont.FAMILY, familySrc: 'file://' + path });
      // 先回落默认再设回自定义：仅靠 setOrCreate 同值不会触发重绘
      AppStorage.setOrCreate(APP_FONT_FAMILY_KEY, AppFont.DEFAULT_FAMILY);
      AppStorage.setOrCreate(APP_FONT_FAMILY_KEY, AppFont.FAMILY);
      Logger.info(TAG, 'font registered on ui context');
    } catch (error) {
      Logger.warn(TAG, 'ui register failed: ' + error);
    }
  }

  /** 恢复系统字体：三处状态一起复位（文件留在沙箱，不再被引用） */
  static clear(): void {
    UserPreferences.setAppFont('', '', '');
    AppStorage.setOrCreate(APP_FONT_FAMILY_KEY, AppFont.DEFAULT_FAMILY);
  }

  /**
   * 导入字体：选文件 → 拷沙箱（fixed name `custom.<ext>`）→ 注册 → 写状态。
   * 同一时刻只保留一份自定义字体，再次导入直接覆盖。
   */
  static async importFont(context: common.UIAbilityContext): Promise<FontImportResult> {
    const result: FontImportResult = new FontImportResult();
    let uri: string = '';
    try {
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      // 格式必须是「描述|.后缀」，竖线两边不能有空格，否则过滤器失效
      options.fileSuffixFilters = ['字体文件|.ttf,.otf,.ttc'];
      const selected: string[] = await documentPicker.select(options);
      if (selected === undefined || selected === null || selected.length === 0) {
        result.cancelled = true;
        return result;
      }
      uri = selected[0];
    } catch (error) {
      Logger.warn(TAG, 'picker failed: ' + error);
      result.error = 'font_picker_failed';
      return result;
    }

    const suffix: string = AppFont.suffixOf(uri);
    if (suffix === '') {
      result.error = 'font_read_failed';
      return result;
    }
    const dir: string = `${context.filesDir}/${AppFont.FONT_DIR}`;
    const dest: string = `${dir}/${AppFont.FONT_BASE}${suffix}`;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      if (fs.accessSync(dest)) {
        fs.unlinkSync(dest);
      }
      const srcFile: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      fs.copyFileSync(srcFile.fd, dest);
      fs.closeSync(srcFile);
    } catch (error) {
      Logger.warn(TAG, 'copy failed: ' + error);
      result.error = 'font_read_failed';
      return result;
    }

    try {
      font.registerFont({ familyName: AppFont.FAMILY, familySrc: 'file://' + dest });
    } catch (error) {
      Logger.warn(TAG, 'register failed: ' + error);
      result.error = 'font_register_failed';
      return result;
    }

    UserPreferences.setAppFont(dest, AppFont.nameOf(uri), suffix);
    AppStorage.setOrCreate(APP_FONT_FAMILY_KEY, AppFont.FAMILY);
    result.ok = true;
    Logger.info(TAG, 'font imported: ' + dest);
    return result;
  }

  /** 取文件后缀（小写，带点）；不支持的后缀返回空串 */
  private static suffixOf(uri: string): string {
    const lower: string = uri.toLowerCase();
    if (lower.endsWith('.ttf')) {
      return '.ttf';
    }
    if (lower.endsWith('.otf')) {
      return '.otf';
    }
    if (lower.endsWith('.ttc')) {
      return '.ttc';
    }
    return '';
  }

  /** 取展示用文件名（decoded 后的最后一段） */
  private static nameOf(uri: string): string {
    const clean: string = decodeURIComponent(uri);
    const parts: string[] = clean.split('/');
    return parts.length > 0 ? parts[parts.length - 1] : clean;
  }
}
