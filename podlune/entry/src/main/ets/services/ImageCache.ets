// Port of: ui/glide 图片加载 + 磁盘缓存（替换 Glide）
import fs from '@ohos.file.fs';
import common from '@ohos.app.ability.common';
import { HttpClient } from '../net/HttpClient';
import { Logger } from '../utils/Logger';

const TAG: string = 'ImageCache';
/** 磁盘缓存上限（MB）：单集封面常见 1~6MB（多为 PNG），50MB 十几张就会被清空 */
const MAX_CACHE_MB: number = 200;
/** 单张图最大尝试次数（首次 + 重试）：批量订阅后一屏十几张并发下载，偶发失败必须自愈 */
const MAX_ATTEMPTS: number = 3;
/** 同时进行的下载数：86 个订阅的封面同时发起请求容易被对端限流/超时，排队后失败率显著下降 */
const MAX_CONCURRENT: number = 4;
/** 淘汰时保护「刚写入」的文件（毫秒）：并发下载的兄弟请求可能把它当成最旧文件删掉 */
const EVICT_GRACE_MS: number = 120000;

/** 缓存文件条目（用于按写入时间淘汰） */
interface CacheFile {
  path: string;
  size: number;
  mtime: number;
}

/** 等待下载名额的排队项 */
interface Waiter {
  resolve: () => void;
}

export class ImageCache {
  private static active: number = 0;
  private static waiters: Waiter[] = [];
  /** 同一 URL 的并发请求合并：订阅瓦片与剧集行可能同时要同一张封面 */
  private static inflight: Map<string, Promise<string>> = new Map<string, Promise<string>>();

  /**
   * 取图（命中磁盘缓存直接返回 file://，否则下载后写盘）。
   * 失败返回 ''，调用方必须按「无封面」渲染占位块，不能留下空洞。
   */
  static async getImage(url: string, context: common.Context): Promise<string> {
    if (url === '') {
      return '';
    }
    const pending: Promise<string> | undefined = ImageCache.inflight.get(url);
    if (pending !== undefined) {
      return await pending;
    }
    const task: Promise<string> = ImageCache.load(url, context);
    ImageCache.inflight.set(url, task);
    try {
      return await task;
    } finally {
      ImageCache.inflight.delete(url);
    }
  }

  /**
   * 同步命中磁盘缓存：命中返回 `file://`，未命中返回 ''。
   *
   * 给**首帧**用（FeedCover.aboutToAppear）：节点第一次渲染就带上本地封面文件路径，
   * 于是不会再出现「先画占位块 → 异步取图后再换成封面」的闪动。
   * `getImage` 是异步的（即使命中缓存也要过一次 Promise），首帧必然落在占位块上——
   * 这正是「每次进入订阅页封面都要闪几下」的直接原因。
   */
  /**
   * `peek` 结果的进程内记忆表。
   *
   * `peek` 原本每次都 `fs.statSync` —— 同步文件系统调用跑在 UI 线程上。
   * 首页一屏就有几十张封面，滚动时每张都要 stat 一次，是滑动手感发涩的主要来源。
   * 这里把「命中」与「未命中」都记下来，重复查询不再触碰磁盘；
   * 新图落盘（load 成功）时用 `markReady` 把对应项改成命中。
   */
  private static peekMemo: Map<string, string> = new Map<string, string>();

  static peek(url: string, context: common.Context): string {
    if (url === '') {
      return '';
    }
    const memo: string | undefined = ImageCache.peekMemo.get(url);
    if (memo !== undefined) {
      return memo;
    }
    const filePath: string = context.filesDir + '/image_cache/' + ImageCache.hash(url) + '.img';
    const result: string = ImageCache.isUsable(filePath) ? 'file://' + filePath : '';
    ImageCache.peekMemo.set(url, result);
    return result;
  }

  /** 磁盘上已就绪：写入记忆表，后续 peek 不再 stat */
  private static markReady(url: string, filePath: string): void {
    if (url !== '') {
      ImageCache.peekMemo.set(url, 'file://' + filePath);
    }
  }

  /** 删除某个 file:// 缓存项（Image 解码失败时用来自愈：坏文件留在盘上会让封面永久空白） */
  static evict(cachedSrc: string): void {
    if (!cachedSrc.startsWith('file://')) {
      return;
    }
    ImageCache.removeQuietly(cachedSrc.substring('file://'.length));
    // 记忆表里所有指向这个文件（含同文件不同 url）的条目都要清掉，否则后续 peek 会返回已删除的路径
    const target: string = 'file://' + cachedSrc.substring('file://'.length);
    const stale: string[] = [];
    ImageCache.peekMemo.forEach((value: string, key: string) => {
      if (value === target) {
        stale.push(key);
      }
    });
    for (const key of stale) {
      ImageCache.peekMemo.delete(key);
    }
  }

  static clearCache(context: common.Context): void {
    ImageCache.peekMemo.clear();
    const dir: string = context.filesDir + '/image_cache';
    if (ImageCache.exists(dir)) {
      fs.rmdirSync(dir);
    }
  }

  static cacheSizeMb(context: common.Context): number {
    const dir: string = context.filesDir + '/image_cache';
    if (!ImageCache.exists(dir)) {
      return 0;
    }
    const files = fs.listFileSync(dir);
    let size = 0;
    for (const name of files) {
      try {
        const stat = fs.statSync(dir + '/' + name);
        size += stat.size;
      } catch (error) {
        // ignore
      }
    }
    return Math.round(size / 1024 / 1024);
  }

  private static async load(url: string, context: common.Context): Promise<string> {
    const fileName: string = ImageCache.hash(url) + '.img';
    const dir: string = context.filesDir + '/image_cache';
    if (!ImageCache.exists(dir)) {
      fs.mkdirSync(dir);
    }
    const filePath: string = dir + '/' + fileName;
    if (ImageCache.isUsable(filePath)) {
      // 命中与未命中都返回 file:// 形式，避免 Image 组件对两种 scheme 处理不一致
      ImageCache.markReady(url, filePath);
      return 'file://' + filePath;
    }
    // 文件存在但不可用（0 字节 / 上次写入被中断 / 已损坏）→ 必须删掉重下
    ImageCache.removeQuietly(filePath);

    let lastError: string = 'unknown';
    for (let attempt: number = 1; attempt <= MAX_ATTEMPTS; attempt++) {
      try {
        const bytes: ArrayBuffer = await ImageCache.download(url);
        if (bytes.byteLength === 0) {
          lastError = 'empty body';
        } else {
          const file = fs.openSync(filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          try {
            fs.writeSync(file.fd, bytes);
          } finally {
            fs.closeSync(file.fd);
          }
          if (ImageCache.isUsable(filePath)) {
            ImageCache.markReady(url, filePath);
            ImageCache.cleanupIfNeeded(context, filePath);
            return 'file://' + filePath;
          }
          lastError = 'write failed';
        }
      } catch (error) {
        lastError = (error as Error).message;
      }
      if (attempt < MAX_ATTEMPTS) {
        await ImageCache.sleep(150 * attempt);
      }
    }
    Logger.warn(TAG, 'download image failed after ' + MAX_ATTEMPTS + ' tries: ' + url + ' (' + lastError + ')');
    ImageCache.removeQuietly(filePath);
    return '';
  }

  /** 带并发闸门的下载 */
  private static async download(url: string): Promise<ArrayBuffer> {
    await ImageCache.acquire();
    try {
      return await HttpClient.getBytes(url);
    } finally {
      ImageCache.release();
    }
  }

  private static acquire(): Promise<void> {
    if (ImageCache.active < MAX_CONCURRENT) {
      ImageCache.active++;
      return Promise.resolve();
    }
    return new Promise<void>((resolve: () => void) => {
      const waiter: Waiter = { resolve: resolve };
      ImageCache.waiters.push(waiter);
    });
  }

  private static release(): void {
    const next: Waiter | undefined = ImageCache.waiters.shift();
    if (next !== undefined) {
      // 名额直接转交，不先减再加，避免出现瞬时超额
      next.resolve();
      return;
    }
    ImageCache.active--;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /**
   * 超限时按「最早写入优先」淘汰到上限以内。
   * 旧实现超限就把整个目录删光，连刚写入、正要返回给调用方的文件一起删掉——
   * 于是那张图直接显示空白（下次再访问才会重新下载）。
   */
  private static cleanupIfNeeded(context: common.Context, keepPath: string): void {
    const dir: string = context.filesDir + '/image_cache';
    if (!ImageCache.exists(dir)) {
      return;
    }
    const now: number = Date.now();
    const files: CacheFile[] = [];
    let total: number = 0;
    for (const name of fs.listFileSync(dir)) {
      const path: string = dir + '/' + name;
      try {
        const stat = fs.statSync(path);
        total += stat.size;
        const entry: CacheFile = { path: path, size: stat.size, mtime: stat.mtime };
        files.push(entry);
      } catch (error) {
        // 读不到的文件跳过
      }
    }
    const limit: number = MAX_CACHE_MB * 1024 * 1024;
    if (total <= limit) {
      return;
    }
    // fs.Stat.mtime 精度只到秒，同秒写入的文件排序不稳定；用路径做次级键保证确定性
    files.sort((a: CacheFile, b: CacheFile) => a.mtime === b.mtime
      ? a.path.localeCompare(b.path)
      : a.mtime - b.mtime);
    for (const entry of files) {
      if (total <= limit) {
        break;
      }
      if (entry.path === keepPath) {
        continue;
      }
      // 刚写入的文件可能正被其它并发下载使用/正显示在界面上，保留
      if (now - entry.mtime * 1000 < EVICT_GRACE_MS) {
        continue;
      }
      try {
        fs.unlinkSync(entry.path);
        total -= entry.size;
      } catch (error) {
        // 删除失败不影响本次取图
      }
    }
  }

  /** 缓存文件可用性：存在、非空（0 字节文件是失败写入的残留，会让界面永久空白） */
  private static isUsable(path: string): boolean {
    try {
      return fs.statSync(path).size > 0;
    } catch (error) {
      return false;
    }
  }

  private static removeQuietly(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (error) {
      // ignore
    }
  }

  private static exists(path: string): boolean {
    try {
      fs.statSync(path);
      return true;
    } catch (error) {
      return false;
    }
  }

  private static hash(value: string): string {
    let h: number = 0;
    for (let i: number = 0; i < value.length; i++) {
      h = ((h << 5) - h + value.charCodeAt(i)) | 0;
    }
    return String(h >>> 0);
  }
}
