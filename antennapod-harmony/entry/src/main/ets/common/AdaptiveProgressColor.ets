import image from '@ohos.multimedia.image';
import effectKit from '@ohos.effectKit';
import { HttpClient } from '../net/HttpClient';
import { Logger } from '../utils/Logger';

const TAG: string = 'PBarColor';

/** 进度条自适应配色（已播放 / 未播放轨道） */
export interface ProgressPalette {
  /** 已播放部分 */
  played: string;
  /** 未播放轨道（背景衍生的半透明色） */
  track: string;
}

/**
 * 播放器进度条的自适应配色。
 *
 * 为什么不再出现「黑白分割」：
 * 1. 在 **OKLab / OKLCH** 感知均匀空间里计算：只调整明度 L、压低彩度 C，
 *    **色相 H 完全跟随背景** → 已播放与未播放天然同色系，不可能一边黑一边白；
 * 2. 明度差按背景亮度连续给（深背景往上提、浅背景往下压），并夹在 `[0.30, 0.88]`，
 *    输出通道再夹到 `[8, 247]` —— 算法层面就产不出纯黑 `#000000` / 纯白 `#FFFFFF`；
 * 3. 未播放轨道带 70% 透明度（`#B3`），叠在模糊背景上只有「一点点」存在感；
 * 4. 明度差的保护方向永远让「已播放更明显」，对比不足时不会反过来。
 *
 * 能力边界：ArkUI 读不到控件背后真实渲染的像素，这里用**封面主色**作为模糊背景的代表色
 * （流光背景本身就是封面高斯模糊 + 遮罩的合成，色相一致）。
 */
export class AdaptiveProgressColor {
  /** 封面主色缓存：同一张封面只取样一次 */
  private static seeds: Map<string, string> = new Map<string, string>();
  /** 取色用的缩略解码尺寸：只为配色服务，不需要原图分辨率 */
  private static readonly SAMPLE_SIZE: number = 48;

  /** 取封面主色（'#RRGGBB'）；失败返回空串，由调用方回退默认配色 */
  static async seedOf(url: string): Promise<string> {
    if (url === '') {
      return '';
    }
    const cached: string | undefined = AdaptiveProgressColor.seeds.get(url);
    if (cached !== undefined && cached !== '') {
      return cached;
    }
    AdaptiveProgressColor.seeds.set(url, '');
    try {
      const data: ArrayBuffer = await HttpClient.getBytes(url);
      const source: image.ImageSource = image.createImageSource(data);
      const info: image.ImageInfo = await source.getImageInfo();
      const scale: number = Math.max(1, Math.floor(Math.min(info.size.width, info.size.height)
        / AdaptiveProgressColor.SAMPLE_SIZE));
      const options: image.DecodingOptions = {
        desiredSize: {
          width: Math.max(1, Math.floor(info.size.width / scale)),
          height: Math.max(1, Math.floor(info.size.height / scale))
        }
      };
      const pixelMap: image.PixelMap = await source.createPixelMap(options);
      const picker: effectKit.ColorPicker = await effectKit.createColorPicker(pixelMap);
      const color: effectKit.Color = picker.getMainColorSync();
      const hex: string = AdaptiveProgressColor.toHex(color.red, color.green, color.blue);
      pixelMap.release();
      source.release();
      AdaptiveProgressColor.seeds.set(url, hex);
      return hex;
    } catch (error) {
      Logger.warn(TAG, 'seed failed: ' + (error as Error).message);
      return '';
    }
  }

  /**
   * 由背景代表色推导进度条配色。
   *
   * @param seed 背景代表色 '#RRGGBB'；空串 → 与深浅模式协调的中性回退色
   * @param darkMode 深色模式（影响回退色与轨道透明度）
   */
  static palette(seed: string, darkMode: boolean = false): ProgressPalette {
    const rgb: number[] = AdaptiveProgressColor.toRgb(seed);
    if (rgb.length !== 3) {
      return darkMode
        ? { played: '#9AA0AA', track: '#6B7280' }
        : { played: '#5C6470', track: '#A7ADB8' };
    }
    const lab: number[] = AdaptiveProgressColor.rgbToOklab(rgb[0], rgb[1], rgb[2]);
    const lch: number[] = AdaptiveProgressColor.oklabToOklch(lab[0], lab[1], lab[2]);
    const bgL: number = lch[0];         // 背景感知明度
    const hue: number = lch[2];         // 背景色相（完全保留）
    // 彩度：背景越艳丽，压得越多，最终不超过 0.06（低饱和）
    const chroma: number = Math.min(lch[1] * 0.45, 0.06);

    // 已播放：深背景更亮、浅背景更深；差值随背景亮度连续变化（没有二选一）
    const delta: number = 0.18 + 0.10 * Math.abs(bgL - 0.5) * 2;
    let playedL: number = bgL < 0.5 ? bgL + delta : bgL - delta;
    playedL = AdaptiveProgressColor.clamp(playedL, 0.30, 0.74);

    // 轨道：几乎贴着背景亮度，只差一点点，存在感最低
    let trackL: number = bgL < 0.5 ? bgL + 0.11 : bgL - 0.11;
    trackL = AdaptiveProgressColor.clamp(trackL, 0.34, 0.84);

    // 对比保护：差 < 0.16 时补足，方向永远是「已播放更明显」
    if (Math.abs(playedL - trackL) < 0.16) {
      if (bgL < 0.5) {
        trackL = AdaptiveProgressColor.clamp(playedL - 0.18, 0.24, 0.80);
      } else {
        trackL = AdaptiveProgressColor.clamp(playedL + 0.18, 0.40, 0.88);
      }
    }
    const playedHex: string = AdaptiveProgressColor.oklchToHex(hue, chroma, playedL);
    const trackHex: string = AdaptiveProgressColor.oklchToHex(hue, chroma * 0.8, trackL);
    // 轨道 70% 不透明：与模糊背景叠加后只比背景略深/略浅
    const track: string = '#B3' + trackHex.substring(1);
    return { played: playedHex, track: track };
  }

  // ---------------------------------------------------------------- 颜色工具
  private static clamp(value: number, min: number, max: number): number {
    return Math.max(min, Math.min(max, value));
  }

  private static toHex(r: number, g: number, b: number): string {
    const parts: string[] = [];
    const channels: number[] = [r, g, b];
    for (let i: number = 0; i < channels.length; i++) {
      // 8..247：从算法层面就排除纯黑 / 纯白
      const clamped: number = AdaptiveProgressColor.clamp(Math.round(channels[i]), 8, 247);
      parts.push(clamped.toString(16).padStart(2, '0'));
    }
    return '#' + parts.join('').toUpperCase();
  }

  private static toRgb(hex: string): number[] {
    const text: string = hex.trim().toUpperCase();
    if (text.length !== 7 || text[0] !== '#') {
      return [];
    }
    const r: number = parseInt(text.substring(1, 3), 16);
    const g: number = parseInt(text.substring(3, 5), 16);
    const b: number = parseInt(text.substring(5, 7), 16);
    if (isNaN(r) || isNaN(g) || isNaN(b)) {
      return [];
    }
    return [r, g, b];
  }

  /** sRGB → 线性 → OKLab */
  private static rgbToOklab(r: number, g: number, b: number): number[] {
    const lin = (c: number): number => {
      const v: number = c / 255;
      return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    };
    const lr: number = lin(r);
    const lg: number = lin(g);
    const lb: number = lin(b);
    const l: number = 0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb;
    const m: number = 0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb;
    const s: number = 0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb;
    const l3: number = Math.cbrt(l);
    const m3: number = Math.cbrt(m);
    const s3: number = Math.cbrt(s);
    return [
      0.2104542553 * l3 + 0.7936177850 * m3 - 0.0040720468 * s3,
      1.9779984951 * l3 - 2.4285922050 * m3 + 0.4505937099 * s3,
      0.0259040371 * l3 + 0.7827717662 * m3 - 0.8086757660 * s3
    ];
  }

  private static oklabToOklch(L: number, a: number, b: number): number[] {
    const c: number = Math.sqrt(a * a + b * b);
    let h: number = Math.atan2(b, a) * 180 / Math.PI;
    if (h < 0) {
      h += 360;
    }
    return [L, c, h];
  }

  /** OKLCH → sRGB hex（超色域时逐次收敛彩度） */
  private static oklchToHex(h: number, c: number, L: number): string {
    let chroma: number = Math.max(0, c);
    for (let i: number = 0; i < 8; i++) {
      const rgb: number[] = AdaptiveProgressColor.oklchToRgb(L, chroma, h);
      const inRange: boolean = rgb[0] >= 0 && rgb[0] <= 255 && rgb[1] >= 0 && rgb[1] <= 255
        && rgb[2] >= 0 && rgb[2] <= 255;
      if (inRange) {
        return AdaptiveProgressColor.toHex(rgb[0], rgb[1], rgb[2]);
      }
      chroma *= 0.7;
    }
    const fallback: number[] = AdaptiveProgressColor.oklchToRgb(L, 0, h);
    return AdaptiveProgressColor.toHex(fallback[0], fallback[1], fallback[2]);
  }

  private static oklchToRgb(L: number, c: number, h: number): number[] {
    const rad: number = h * Math.PI / 180;
    const a: number = Math.cos(rad) * c;
    const b: number = Math.sin(rad) * c;
    const l3: number = L + 0.3963377774 * a + 0.2158037573 * b;
    const m3: number = L - 0.1055613458 * a - 0.0638541728 * b;
    const s3: number = L - 0.0894841775 * a - 1.2914855480 * b;
    const l: number = l3 * l3 * l3;
    const m: number = m3 * m3 * m3;
    const s: number = s3 * s3 * s3;
    const lr: number = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
    const lg: number = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
    const lb: number = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;
    const enc = (v: number): number => {
      const clamped: number = Math.max(0, Math.min(1, v));
      const srgb: number = clamped <= 0.0031308 ? clamped * 12.92
        : 1.055 * Math.pow(clamped, 1 / 2.4) - 0.055;
      return srgb * 255;
    };
    return [enc(lr), enc(lg), enc(lb)];
  }
}
