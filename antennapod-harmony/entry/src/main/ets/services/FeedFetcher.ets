// Port of: net/download/service/feed/remote/FeedParserTask.java + Downloader.java
import { HttpClient, HttpResponse, NetworkError } from '../net/HttpClient';
import { FeedParser, ParseResult, UnsupportedFeedException } from '../parser/FeedParser';
import { FeedSanitizer } from '../parser/FeedSanitizer';
import { Base64Utils } from '../utils/Base64Utils';
import { FeedValidators, FeedValidator } from './FeedValidators';

/** 304 未修改：调用方据此跳过「解析 + 入库」，避免无谓开销 */
export class FeedNotModifiedError extends Error {
  constructor() {
    super('feed not modified (HTTP 304)');
    this.name = 'FeedNotModifiedError';
  }
}

export class FeedFetcher {
  /**
   * 拉取并解析订阅源；username/password 非空时附加 HTTP Basic 认证头（私有 Feed）。
   * 认证头只随该订阅自己的 URL 发送，不会外泄到其他请求。
   */
  static async fetchFeed(url: string, username: string = '', password: string = '', timeoutMs: number = 0): Promise<ParseResult> {
    const headers: Record<string, string> = {};
    if (username !== '' || password !== '') {
      headers['Authorization'] = Base64Utils.basicAuth(username, password);
    }
    // timeoutMs = 0 时用 HttpClient 默认值（20s）；整库刷新传更短的值，避免个别慢源拖住整轮
    // 条件请求：带上上一次的 ETag / Last-Modified
    const validator: FeedValidator | undefined = FeedValidators.get(url);
    if (validator !== undefined) {
      if (validator.etag !== '') {
        headers['If-None-Match'] = validator.etag;
      }
      if (validator.lastModified !== '') {
        headers['If-Modified-Since'] = validator.lastModified;
      }
    }
    const response: HttpResponse = await HttpClient.get(url, headers, timeoutMs);
    if (response.status === 304) {
      throw new FeedNotModifiedError();
    }
    if (response.status >= 300) {
      throw new NetworkError(0, 'HTTP ' + response.status, response.status);
    }
    // 记下新的校验器，供下次条件请求使用（未返回则清空，避免带着过期值反复 304）
    const etag: string = FeedFetcher.headerOf(response, 'etag');
    const lastModified: string = FeedFetcher.headerOf(response, 'last-modified');
    if (etag !== '' || lastModified !== '') {
      FeedValidators.set(url, etag, lastModified);
    }
    FeedSanitizer.checkFeedContent(response.body);
    return FeedParser.parseFeed(response.body);
  }

  /** 大小写不敏感地取响应头 */
  private static headerOf(response: HttpResponse, name: string): string {
    const headers: Record<string, string> = response.headers;
    if (headers === undefined || headers === null) {
      return '';
    }
    const direct: string | undefined = headers[name];
    if (direct !== undefined) {
      return direct;
    }
    const lower: string = name.toLowerCase();
    for (const key of Object.keys(headers)) {
      if (key.toLowerCase() === lower) {
        return headers[key];
      }
    }
    return '';
  }

  static async fetchFeedFromHtml(html: string): Promise<ParseResult> {
    const match: RegExpMatchArray | null = html.match(
      /<link[^>]+(?:type=["']application\/rss\+xml["']|type=["']application\/atom\+xml["'])[^>]*href=["']([^"']+)["']/i
    );
    if (match === null || match[1] === undefined) {
      throw new UnsupportedFeedException('网页中未找到订阅源链接');
    }
    const feedUrl: string = match[1];
    return FeedFetcher.fetchFeed(feedUrl);
  }
}
