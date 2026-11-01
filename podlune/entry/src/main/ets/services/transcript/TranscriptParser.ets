// 官方文字稿解析：把 VTT / SRT / Podcasting 2.0 JSON / TXT / HTML
// 统一转换成 TranscriptDocument（时间统一毫秒）。
import { TranscriptDocument, TranscriptSegment, TranscriptSourceType } from '../../model/Transcript';

export enum ParsedFormat {
  VTT = 0,
  SRT = 1,
  JSON = 2,
  TXT = 3,
  HTML = 4,
  UNKNOWN = 9
}

/** 解析结果：要么得到有时间轴的文档，要么得到纯文本段落 */
export interface ParseResult {
  ok: boolean;
  format: ParsedFormat;
  doc: TranscriptDocument;
  /** 失败原因（ok=false 时用于页面提示） */
  message: string;
}

export class TranscriptParser {
  /**
   * @param body    文字稿正文
   * @param mime    RSS 里声明的 type（可能为空）
   * @param url     来源地址（用于按扩展名兜底判断）
   * @param episodeId 单集 id
   */
  static parse(body: string, mime: string, url: string, episodeId: number): ParseResult {
    const text: string = body === undefined || body === null ? '' : body;
    if (text.trim() === '') {
      return TranscriptParser.fail(ParsedFormat.UNKNOWN, episodeId, '文字稿内容为空');
    }
    const format: ParsedFormat = TranscriptParser.detect(text, mime, url);
    const doc: TranscriptDocument = TranscriptParser.emptyDoc(episodeId);
    if (format === ParsedFormat.VTT) {
      const segments: TranscriptSegment[] = TranscriptParser.parseCues(text, true);
      return TranscriptParser.finish(doc, ParsedFormat.VTT, segments, 'vtt');
    }
    if (format === ParsedFormat.SRT) {
      const segments: TranscriptSegment[] = TranscriptParser.parseCues(text, false);
      return TranscriptParser.finish(doc, ParsedFormat.SRT, segments, 'srt');
    }
    if (format === ParsedFormat.JSON) {
      const segments: TranscriptSegment[] = TranscriptParser.parseJson(text);
      return TranscriptParser.finish(doc, ParsedFormat.JSON, segments, 'json');
    }
    if (format === ParsedFormat.HTML) {
      const plain: string = TranscriptParser.htmlToText(text);
      const segments: TranscriptSegment[] = TranscriptParser.parsePlain(plain);
      return TranscriptParser.finish(doc, ParsedFormat.HTML, segments, 'html');
    }
    const segments: TranscriptSegment[] = TranscriptParser.parsePlain(text);
    return TranscriptParser.finish(doc, ParsedFormat.TXT, segments, 'txt');
  }

  private static emptyDoc(episodeId: number): TranscriptDocument {
    return {
      episodeId: episodeId,
      transcriptId: 0,
      sourceType: TranscriptSourceType.OFFICIAL,
      language: '',
      provider: 'rss',
      model: '',
      isTimed: false,
      isAiGenerated: false,
      createdAt: Date.now(),
      updatedAt: Date.now(),
      segments: []
    };
  }

  private static fail(format: ParsedFormat, episodeId: number, message: string): ParseResult {
    return {
      ok: false,
      format: format,
      doc: TranscriptParser.emptyDoc(episodeId),
      message: message
    };
  }

  /** 有时间戳才允许同步高亮；纯文本只做阅读与搜索 */
  private static finish(doc: TranscriptDocument, format: ParsedFormat,
                        segments: TranscriptSegment[], kind: string): ParseResult {
    if (segments.length === 0) {
      return TranscriptParser.fail(format, doc.episodeId, '未能从文字稿中解析出任何段落');
    }
    doc.segments = segments;
    doc.isTimed = segments[0].endMs > segments[0].startMs || segments.length > 1
      && segments[1].startMs >= segments[0].startMs && segments[segments.length - 1].endMs > 0;
    // 纯文本（TXT/HTML）一律视为无时间戳
    if (format === ParsedFormat.TXT || format === ParsedFormat.HTML) {
      doc.isTimed = false;
    }
    if (doc.isTimed) {
      doc.model = kind;
    }
    return { ok: true, format: format, doc: doc, message: '' };
  }

  private static detect(body: string, mime: string, url: string): ParsedFormat {
    const head: string = body.substring(0, 400).trim();
    const lowerMime: string = (mime === undefined || mime === null ? '' : mime).toLowerCase();
    const lowerUrl: string = (url === undefined || url === null ? '' : url).toLowerCase();
    if (head.startsWith('WEBVTT') || lowerMime.indexOf('vtt') >= 0 || lowerUrl.endsWith('.vtt')) {
      return ParsedFormat.VTT;
    }
    if (head.startsWith('{') || head.startsWith('[')
      || lowerMime.indexOf('json') >= 0 || lowerUrl.endsWith('.json')) {
      return ParsedFormat.JSON;
    }
    // SRT：前若干行里出现 "00:00:01,000 --> 00:00:04,000"
    if (/^\d+\s*\r?\n\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}\s*-->/.test(head)) {
      return ParsedFormat.SRT;
    }
    if (lowerMime.indexOf('html') >= 0 || lowerUrl.endsWith('.html') || lowerUrl.endsWith('.htm')) {
      return ParsedFormat.HTML;
    }
    if (head.indexOf('<') >= 0 && head.indexOf('>') > 0) {
      return ParsedFormat.HTML;
    }
    if (/-->\s*\d{1,2}:\d{2}/.test(head)) {
      return ParsedFormat.SRT;
    }
    return ParsedFormat.TXT;
  }

  /** VTT / SRT 共用的时间轴解析 */
  private static parseCues(body: string, isVtt: boolean): TranscriptSegment[] {
    const segments: TranscriptSegment[] = [];
    const lines: string[] = body.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');
    let i: number = 0;
    let id: number = 0;
    while (i < lines.length) {
      const line: string = lines[i];
      const arrow: number = line.indexOf('-->');
      if (arrow < 0) {
        i++;
        continue;
      }
      const startMs: number = TranscriptParser.parseTimestamp(line.substring(0, arrow));
      const after: string = line.substring(arrow + 3).trim();
      const endToken: string = after.split(' ')[0];
      const endMs: number = TranscriptParser.parseTimestamp(endToken);
      i++;
      const chunks: string[] = [];
      while (i < lines.length && lines[i].trim() !== '') {
        const raw: string = lines[i].trim();
        // VTT 的 NOTE / STYLE 块、以及内嵌标签（<c>/<v Speaker>）都要处理
        if (!(isVtt && (raw.startsWith('NOTE') || raw.startsWith('STYLE')))) {
          chunks.push(TranscriptParser.stripCueTags(raw));
        }
        i++;
      }
      const text: string = chunks.join(' ').trim();
      if (text !== '' && endMs >= startMs) {
        segments.push({
          segmentId: id++,
          startMs: startMs,
          endMs: endMs,
          text: text,
          speaker: ''
        });
      }
    }
    return segments;
  }

  private static stripCueTags(raw: string): string {
    let out: string = raw.replace(/<[^>]*>/g, '');
    out = out.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
      .replace(/&nbsp;/g, ' ').replace(/&quot;/g, '"').replace(/&#39;/g, '\'');
    return out.trim();
  }

  /** 00:01:02.500 / 01:02,500 / 62.5 都转成毫秒 */
  private static parseTimestamp(raw: string): number {
    const value: string = (raw === undefined || raw === null ? '' : raw).trim();
    if (value === '') {
      return 0;
    }
    const parts: string[] = value.replace(',', '.').split(':');
    if (parts.length === 3) {
      const h: number = Number(parts[0]);
      const m: number = Number(parts[1]);
      const s: number = Number(parts[2]);
      return Math.round(((h * 60 + m) * 60 + s) * 1000);
    }
    if (parts.length === 2) {
      const m: number = Number(parts[0]);
      const s: number = Number(parts[1]);
      return Math.round((m * 60 + s) * 1000);
    }
    const seconds: number = Number(value);
    return isNaN(seconds) ? 0 : Math.round(seconds * 1000);
  }

  /** Podcasting 2.0 JSON：segments[].startTime / endTime 单位是**秒** */
  private static parseJson(body: string): TranscriptSegment[] {
    const segments: TranscriptSegment[] = [];
    let root: Record<string, Object>;
    try {
      root = JSON.parse(body) as Record<string, Object>;
    } catch (error) {
      return segments;
    }
    const raw: Object = root['segments'] !== undefined ? root['segments'] as Object : root['transcript'];
    if (raw === undefined) {
      return segments;
    }
    const list: Object[] = raw as Object[];
    if (list === undefined || list.length === undefined) {
      return segments;
    }
    let id: number = 0;
    for (const entry of list) {
      const item: Record<string, Object> = entry as Record<string, Object>;
      const text: string = TranscriptParser.jsonStr(item, 'body') !== '' ? TranscriptParser.jsonStr(item, 'body')
        : TranscriptParser.jsonStr(item, 'text');
      if (text.trim() === '') {
        continue;
      }
      const start: number = TranscriptParser.jsonNum(item, 'startTime', TranscriptParser.jsonNum(item, 'start', 0));
      const end: number = TranscriptParser.jsonNum(item, 'endTime', TranscriptParser.jsonNum(item, 'end', start));
      const speaker: string = TranscriptParser.jsonStr(item, 'speaker');
      segments.push({
        segmentId: id++,
        startMs: Math.round(start * 1000),
        endMs: Math.round(end * 1000),
        text: text.trim(),
        speaker: speaker
      });
    }
    return segments;
  }

  private static jsonStr(item: Record<string, Object>, key: string): string {
    const value: Object = item[key];
    return value === undefined || value === null ? '' : String(value);
  }

  private static jsonNum(item: Record<string, Object>, key: string, fallback: number): number {
    const value: Object = item[key];
    if (value === undefined || value === null) {
      return fallback;
    }
    const num: number = Number(value);
    return isNaN(num) ? fallback : num;
  }

  /** 纯文本：按空行 / 换行切段，全部无时间戳 */
  private static parsePlain(body: string): TranscriptSegment[] {
    const segments: TranscriptSegment[] = [];
    const normalized: string = body.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
    const blocks: string[] = normalized.split(/\n\s*\n/);
    let id: number = 0;
    for (const block of blocks) {
      const text: string = block.replace(/\s*\n\s*/g, ' ').trim();
      if (text === '') {
        continue;
      }
      segments.push({ segmentId: id++, startMs: 0, endMs: 0, text: text, speaker: '' });
    }
    return segments;
  }

  /** HTML 只提取可见文本，不执行脚本、不加载外部资源 */
  private static htmlToText(html: string): string {
    let out: string = html;
    out = out.replace(/<script[\s\S]*?<\/script>/gi, ' ');
    out = out.replace(/<style[\s\S]*?<\/style>/gi, ' ');
    out = out.replace(/<br\s*\/?>/gi, '\n');
    out = out.replace(/<\/(p|div|li|h[1-6]|tr)>/gi, '\n\n');
    out = out.replace(/<[^>]+>/g, '');
    out = out.replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, '\'').replace(/&mdash;/g, '—');
    return out;
  }
}
