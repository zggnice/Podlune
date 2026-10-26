// 文字稿统一模型：官方（RSS podcast:transcript）与 AI 生成共用同一结构。
// 时间统一使用毫秒，避免不同服务商秒 / 毫秒混用导致同步错位。

export enum TranscriptSourceType {
  OFFICIAL = 0,
  AI = 1
}

export interface TranscriptSegment {
  segmentId: number;
  startMs: number;
  endMs: number;
  text: string;
  speaker: string;
}

export interface TranscriptDocument {
  episodeId: number;
  transcriptId: number;
  sourceType: number;
  language: string;
  provider: string;
  model: string;
  isTimed: boolean;
  isAiGenerated: boolean;
  createdAt: number;
  updatedAt: number;
  segments: TranscriptSegment[];
}

/** 官方文字稿获取失败的分类（页面据此给出可区分的提示与重试） */
export enum TranscriptFailure {
  NONE = 0,
  /** RSS 里根本没有文字稿 */
  NOT_PROVIDED = 1,
  /** 链接失效（404 / 410） */
  LINK_EXPIRED = 2,
  /** 请求超时 */
  TIMEOUT = 3,
  /** 格式不支持 */
  UNSUPPORTED_FORMAT = 4,
  /** 解析失败 */
  PARSE_FAILED = 5,
  /** 需要认证但拿不到 */
  UNAUTHORIZED = 6,
  /** 网络不可用 */
  NETWORK = 7
}

export class Transcripts {
  /** 段落按时间拼成正文；纯文本通常只有一段 */
  static joinText(doc: TranscriptDocument): string {
    const parts: string[] = [];
    for (const seg of doc.segments) {
      if (seg.text !== '') {
        parts.push(seg.text);
      }
    }
    return parts.join('\n');
  }

  /** 二分查找当前位置应高亮的段落下标；无时间戳时返回 -1 */
  static indexAt(doc: TranscriptDocument, positionMs: number): number {
    if (!doc.isTimed || doc.segments.length === 0) {
      return -1;
    }
    let low: number = 0;
    let high: number = doc.segments.length - 1;
    let found: number = -1;
    while (low <= high) {
      const mid: number = Math.floor((low + high) / 2);
      if (doc.segments[mid].startMs <= positionMs) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return found;
  }
}
