// 官方文字稿（RSS podcast:transcript）获取：先读缓存 → 再下载解析。
// 失败按类型区分，页面据此给出可区分的提示与重试入口。
import { HttpClient, HttpResponse, NetworkError, NetworkErrorType } from '../../net/HttpClient';
import { FeedItem } from '../../model/FeedItem';
import { TranscriptDocument, TranscriptFailure, TranscriptSourceType } from '../../model/Transcript';
import { TranscriptParser, ParseResult } from './TranscriptParser';
import { TranscriptRepository } from '../../db/repositories/TranscriptRepository';
import { Logger } from '../../utils/Logger';

const TAG: string = 'OfficialTranscript';

/** 官方文字稿的获取结果 */
export interface OfficialTranscriptResult {
  ok: boolean;
  cached: boolean;
  failure: TranscriptFailure;
  doc: TranscriptDocument | undefined;
  /** 面向用户的说明（已经在失败分类基础上具体化） */
  message: string;
}

export class OfficialTranscriptProvider {
  private static readonly TIMEOUT_MS: number = 20000;

  static async load(item: FeedItem): Promise<OfficialTranscriptResult> {
    // 1) 缓存优先：同一来源直接复用，不重复下载
    const cached: TranscriptDocument | undefined =
      await TranscriptRepository.findBySource(item.id, TranscriptSourceType.OFFICIAL);
    if (cached !== undefined && cached.segments.length > 0) {
      return {
        ok: true, cached: true, failure: TranscriptFailure.NONE, doc: cached, message: ''
      };
    }
    // 2) RSS 没提供
    const url: string = item.podcastIndexTranscriptUrl;
    if (url === undefined || url === null || url.trim() === '') {
      return {
        ok: false, cached: false, failure: TranscriptFailure.NOT_PROVIDED, doc: undefined,
        message: '本集暂未提供官方文字稿'
      };
    }
    // 3) 下载
    let response: HttpResponse;
    try {
      response = await HttpClient.get(url, { 'Accept': '*/*' }, OfficialTranscriptProvider.TIMEOUT_MS);
    } catch (error) {
      const mapped: OfficialTranscriptResult =
        OfficialTranscriptProvider.mapError(error as Error, item);
      Logger.warn(TAG, 'download failed (' + mapped.failure + '): ' + mapped.message);
      return mapped;
    }
    // 4) 解析
    const parsed: ParseResult = TranscriptParser.parse(
      response.body, item.podcastIndexTranscriptType, url, item.id);
    if (!parsed.ok) {
      return {
        ok: false, cached: false, failure: TranscriptFailure.PARSE_FAILED, doc: undefined,
        message: parsed.message
      };
    }
    // 5) 落库（语言未知时留空，之后可按语言再存多份）
    parsed.doc.language = '';
    const saved: TranscriptDocument = await TranscriptRepository.save(parsed.doc);
    return { ok: true, cached: false, failure: TranscriptFailure.NONE, doc: saved, message: '' };
  }

  private static mapError(error: Error, item: FeedItem): OfficialTranscriptResult {
    const failed = (failure: TranscriptFailure, message: string): OfficialTranscriptResult => {
      return { ok: false, cached: false, failure: failure, doc: undefined, message: message };
    };
    if (error instanceof NetworkError) {
      const net: NetworkError = error as NetworkError;
      if (net.type === NetworkErrorType.TIMEOUT) {
        return failed(TranscriptFailure.TIMEOUT, '下载官方文字稿超时，可稍后重试');
      }
      if (net.type === NetworkErrorType.NETWORK) {
        return failed(TranscriptFailure.NETWORK, '当前网络不可用，无法获取官方文字稿');
      }
      if (net.status === 401 || net.status === 403) {
        return failed(TranscriptFailure.UNAUTHORIZED, '官方文字稿需要登录授权，当前无法获取');
      }
      if (net.status === 404 || net.status === 410) {
        return failed(TranscriptFailure.LINK_EXPIRED, '官方文字稿链接已失效');
      }
      return failed(TranscriptFailure.NETWORK, '获取官方文字稿失败（HTTP ' + net.status + '）');
    }
    return failed(TranscriptFailure.NETWORK, '获取官方文字稿失败：' + error.message);
  }
}
