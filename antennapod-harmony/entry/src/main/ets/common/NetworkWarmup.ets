import http from '@ohos.net.http';
import { Logger } from '../utils/Logger';

const TAG: string = 'NetworkWarmup';

/**
 * 网络预热：对即将用到的音频 / RSS 地址做一次轻量 HEAD 探测。
 *
 * 目的很有限，但对中国大陆访问境外源有效：
 * - 提前完成 DNS 解析与 TLS 握手（系统会缓存一段时间），
 * - 让后续 AVPlayer / RSS 拉取的首包时间明显缩短。
 *
 * 只用 HEAD + 4s 超时，失败静默忽略；同一地址 10 分钟内只预热一次。
 */
export class NetworkWarmup {
  private static warmed: Map<string, number> = new Map<string, number>();
  private static readonly TTL_MS: number = 10 * 60 * 1000;
  private static readonly TIMEOUT_MS: number = 4000;

  /** 预热一个 URL（不阻塞调用方，异常全部吞掉） */
  static warm(url: string): void {
    if (url === '' || !url.toLowerCase().startsWith('https://')) {
      return;
    }
    const last: number | undefined = NetworkWarmup.warmed.get(url);
    if (last !== undefined && Date.now() - last < NetworkWarmup.TTL_MS) {
      return;
    }
    NetworkWarmup.warmed.set(url, Date.now());
    NetworkWarmup.doWarm(url);
  }

  private static async doWarm(url: string): Promise<void> {
    const client: http.HttpRequest = http.createHttp();
    try {
      await client.request(url, {
        method: http.RequestMethod.HEAD,
        connectTimeout: NetworkWarmup.TIMEOUT_MS,
        readTimeout: NetworkWarmup.TIMEOUT_MS,
        usingCache: true
      });
      Logger.info(TAG, 'warmed ' + NetworkWarmup.hostOf(url));
    } catch (error) {
      // 预热失败无所谓：真正加载时会自己重试
      Logger.info(TAG, 'warm failed ' + NetworkWarmup.hostOf(url));
    } finally {
      client.destroy();
    }
  }

  private static hostOf(url: string): string {
    const start: number = url.indexOf('://');
    if (start < 0) {
      return url;
    }
    const rest: string = url.substring(start + 3);
    const slash: number = rest.indexOf('/');
    return slash < 0 ? rest : rest.substring(0, slash);
  }
}
