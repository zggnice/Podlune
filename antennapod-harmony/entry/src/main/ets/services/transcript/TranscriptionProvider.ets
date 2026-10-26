// 语音转写服务适配层。
// 当前真实实现的协议：OpenAI /audio/transcriptions（含用户自建的同协议服务）。
// 未实现的服务商不会出现在设置页可选项中，也不会被标记为可用。
import http from '@ohos.net.http';
import util from '@ohos.util';
import { TranscriptSegment } from '../../model/Transcript';
import { Logger } from '../../utils/Logger';

const TAG: string = 'TranscriptionProvider';

/** 错误分类：测试与生成都据此给用户可区分的提示 */
export enum TranscriptionErrorKind {
  NONE = 0,
  INVALID_KEY = 1,
  BAD_ENDPOINT = 2,
  MODEL_NOT_FOUND = 3,
  MODEL_NOT_SUPPORTED = 4,
  QUOTA = 5,
  RATE_LIMIT = 6,
  TIMEOUT = 7,
  NETWORK = 8,
  SSL = 9,
  AUDIO_UNSUPPORTED = 10,
  BAD_RESPONSE = 11,
  EMPTY_RESULT = 12
}

export interface TranscriptionRequest {
  baseUrl: string;
  apiKey: string;
  model: string;
  /** 'auto' 或 ISO-639-1（zh / en / ja …） */
  language: string;
  audio: Uint8Array;
  fileName: string;
  mimeType: string;
  /** 'auto'（先转写再对话）/ 'transcriptions' / 'chat' */
  protocol?: string;
  /** 读取超时（毫秒）：测试连接用较短值，真实转写用默认 180s */
  readTimeoutMs?: number;
}

export interface TranscriptionOutcome {
  ok: boolean;
  /** 服务商是否返回了真实时间戳（决定能否播放同步） */
  timed: boolean;
  text: string;
  segments: TranscriptSegment[];
  errorKind: TranscriptionErrorKind;
  message: string;
  /** HTTP 状态码（0 = 未拿到响应，例如网络异常） */
  httpStatus?: number;
}

/** /chat/completions 请求体：ArkTS 要求对象字面量对应显式类型 */
interface ChatAudioPayload {
  data: string;
  format: string;
}

interface ChatAudioUrlPayload {
  url: string;
}

interface ChatTextPart {
  type: string;
  text: string;
}

interface ChatInputAudioPart {
  type: string;
  input_audio: ChatAudioPayload;
}

interface ChatAudioUrlPart {
  type: string;
  audio_url: ChatAudioUrlPayload;
}

interface ChatMessage {
  role: string;
  content: (ChatTextPart | ChatInputAudioPart | ChatAudioUrlPart)[];
}

interface ChatRequestBody {
  model: string;
  messages: ChatMessage[];
}

export class TranscriptionProvider {
  private static readonly CONNECT_TIMEOUT: number = 15000;
  private static readonly READ_TIMEOUT: number = 180000;

  /** 真实调用 /audio/transcriptions；只有拿到非空文本才算成功 */
  static async transcribe(request: TranscriptionRequest): Promise<TranscriptionOutcome> {
    if (!request.baseUrl.toLowerCase().startsWith('https://')) {
      return TranscriptionProvider.fail(TranscriptionErrorKind.BAD_ENDPOINT,
        'API 地址必须是 HTTPS');
    }
    if (request.apiKey === '') {
      return TranscriptionProvider.fail(TranscriptionErrorKind.INVALID_KEY, '尚未配置 API Key');
    }
    const protocol: string = request.protocol === undefined ? 'auto' : request.protocol;
    if (protocol === 'chat') {
      return TranscriptionProvider.transcribeViaChat(request);
    }
    const base: string = request.baseUrl.replace(/\/+$/, '');
    const url: string = base + '/audio/transcriptions';

    // 第一次：verbose_json（能拿到真实时间戳）。
    // 有些兼容实现只认 json / 不认 verbose_json，会回 400/415/422 —— 这时退一步重试。
    const first: TranscriptionOutcome = await TranscriptionProvider.postOnce(url, request, true);
    const retryable: boolean = first.errorKind === TranscriptionErrorKind.BAD_RESPONSE
      || first.errorKind === TranscriptionErrorKind.BAD_ENDPOINT;
    const isClientFormatError: boolean = first.httpStatus === 400 || first.httpStatus === 415
      || first.httpStatus === 422;
    if (first.ok || !retryable || !isClientFormatError) {
      return first;
    }
    const second: TranscriptionOutcome = await TranscriptionProvider.postOnce(url, request, false);
    if (second.ok) {
      return second;
    }
    // auto：转写接口不可用时，按「对话接口（chat/completions）」再试一次
    if (protocol === 'auto') {
      const chat: TranscriptionOutcome = await TranscriptionProvider.transcribeViaChat(request);
      if (chat.ok) {
        return chat;
      }
      chat.message = chat.message + '（/audio/transcriptions 与 /chat/completions 均失败）';
      return chat;
    }
    second.message = second.message + '（已按最小兼容参数重试仍失败；请求地址 ' + url + '）';
    return second;
  }

  /**
   * 通过「对话接口」转写：把音频以 base64 放进多模态消息里发给 /chat/completions。
   * 这是很多兼容实现（含 gpt-4o-audio、qwen-audio、glm-4-voice 等）唯一支持的路径。
   * 先试 OpenAI 标准的 input_audio，失败再试 audio_url（部分国内实现用这种写法）。
   */
  private static async transcribeViaChat(request: TranscriptionRequest): Promise<TranscriptionOutcome> {
    const url: string = request.baseUrl.replace(/\/+$/, '') + '/chat/completions';
    const first: TranscriptionOutcome = await TranscriptionProvider.postChat(url, request, false);
    if (first.ok) {
      return first;
    }
    const second: TranscriptionOutcome = await TranscriptionProvider.postChat(url, request, true);
    if (second.ok) {
      return second;
    }
    second.message = second.message + '（请求地址 ' + url + '）';
    return second;
  }

  private static async postChat(url: string, request: TranscriptionRequest,
    useAudioUrl: boolean): Promise<TranscriptionOutcome> {
    const base64: string = new util.Base64Helper()
      .encodeToStringSync(request.audio);
    const format: string = request.fileName.toLowerCase().endsWith('.mp3') ? 'mp3' : 'wav';
    const textPart: ChatTextPart = {
      type: 'text',
      text: '请把这段音频逐字转写成文字，只输出转写结果本身，不要总结、不要解释、不要加任何说明。'
    };
    const audioPart: ChatInputAudioPart | ChatAudioUrlPart = useAudioUrl
      ? { type: 'audio_url', audio_url: { url: 'data:audio/' + format + ';base64,' + base64 } }
      : { type: 'input_audio', input_audio: { data: base64, format: format } };
    const message: ChatMessage = {
      role: 'user',
      content: [textPart, audioPart]
    };
    const body: ChatRequestBody = {
      model: request.model,
      messages: [message]
    };
    const client: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await client.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ' + request.apiKey,
          'Accept': 'application/json'
        },
        extraData: JSON.stringify(body),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: TranscriptionProvider.CONNECT_TIMEOUT,
        readTimeout: request.readTimeoutMs === undefined
          ? TranscriptionProvider.READ_TIMEOUT : request.readTimeoutMs
      });
      const status: number = response.responseCode;
      const payload: string = response.result === undefined ? '' : String(response.result);
      if (status < 200 || status >= 300) {
        const outcome: TranscriptionOutcome = TranscriptionProvider.mapHttpError(status, payload);
        outcome.httpStatus = status;
        return outcome;
      }
      return TranscriptionProvider.parseChatResponse(payload);
    } catch (error) {
      return TranscriptionProvider.mapException(error as Error);
    } finally {
      client.destroy();
    }
  }

  /** 解析 /chat/completions 的返回：取 choices[0].message.content 作为正文（无时间戳） */
  private static parseChatResponse(payload: string): TranscriptionOutcome {
    let root: Record<string, Object>;
    try {
      root = JSON.parse(payload) as Record<string, Object>;
    } catch (error) {
      return TranscriptionProvider.fail(TranscriptionErrorKind.BAD_RESPONSE,
        '对话接口返回的不是 JSON，无法解析转写结果');
    }
    const choices: Object[] = root['choices'] as Object[];
    if (choices === undefined || choices === null || choices.length === 0) {
      return TranscriptionProvider.fail(TranscriptionErrorKind.BAD_RESPONSE,
        '对话接口没有返回 choices 字段');
    }
    const first: Record<string, Object> = choices[0] as Record<string, Object>;
    const message: Record<string, Object> = first['message'] as Record<string, Object>;
    if (message === undefined || message === null) {
      return TranscriptionProvider.fail(TranscriptionErrorKind.BAD_RESPONSE,
        '对话接口没有返回 message 字段');
    }
    const content: Object = message['content'];
    let text: string = '';
    if (typeof content === 'string') {
      text = content as string;
    } else if (content !== undefined && content !== null) {
      // 少数实现把 content 返回成 [{type:'text', text:'...'}]
      const parts: Object[] = content as Object[];
      const pieces: string[] = [];
      for (const part of parts) {
        const obj: Record<string, Object> = part as Record<string, Object>;
        const piece: Object = obj['text'];
        if (piece !== undefined && piece !== null) {
          pieces.push(String(piece));
        }
      }
      text = pieces.join('\n');
    }
    const trimmed: string = text.trim();
    if (trimmed === '') {
      return TranscriptionProvider.fail(TranscriptionErrorKind.EMPTY_RESULT,
        '对话接口返回了空内容');
    }
    // 对话接口没有时间戳：按段落切开，仅用于阅读（timed = false）
    const segments: TranscriptSegment[] = [];
    const lines: string[] = trimmed.split(/\n+/);
    let id: number = 0;
    for (const line of lines) {
      const value: string = line.trim();
      if (value === '') {
        continue;
      }
      segments.push({ segmentId: id++, startMs: 0, endMs: 0, text: value, speaker: '' });
    }
    return {
      ok: true,
      timed: false,
      text: trimmed,
      segments: segments,
      errorKind: TranscriptionErrorKind.NONE,
      message: '',
      httpStatus: 200
    };
  }

  /** 发送一次转写请求；`verbose` 控制是否带 verbose_json 与语言字段 */
  private static async postOnce(url: string, request: TranscriptionRequest,
    verbose: boolean): Promise<TranscriptionOutcome> {
    const boundary: string = '----PodluneBoundary' + Date.now().toString();
    const body: Uint8Array = TranscriptionProvider.buildMultipart(boundary, request, verbose);
    const client: http.HttpRequest = http.createHttp();
    try {
      const response: http.HttpResponse = await client.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'multipart/form-data; boundary=' + boundary,
          'Authorization': 'Bearer ' + request.apiKey,
          'Accept': 'application/json'
        },
        extraData: body.buffer,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: TranscriptionProvider.CONNECT_TIMEOUT,
        readTimeout: request.readTimeoutMs === undefined
          ? TranscriptionProvider.READ_TIMEOUT : request.readTimeoutMs
      });
      const status: number = response.responseCode;
      const payload: string = response.result === undefined ? '' : String(response.result);
      if (status < 200 || status >= 300) {
        const outcome: TranscriptionOutcome = TranscriptionProvider.mapHttpError(status, payload);
        outcome.httpStatus = status;
        outcome.message = outcome.message + '（请求地址 ' + url + '）';
        return outcome;
      }
      return TranscriptionProvider.parseResponse(payload);
    } catch (error) {
      return TranscriptionProvider.mapException(error as Error);
    } finally {
      client.destroy();
    }
  }

  /** multipart/form-data 主体：模型字段 + 语言 + verbose_json + 音频文件 */
  private static buildMultipart(boundary: string, request: TranscriptionRequest,
    verbose: boolean): Uint8Array {
    const encoder: util.TextEncoder = new util.TextEncoder();
    const parts: Uint8Array[] = [];
    const pushField = (name: string, value: string): void => {
      parts.push(encoder.encodeInto('--' + boundary + '\r\n'
        + 'Content-Disposition: form-data; name="' + name + '"\r\n\r\n' + value + '\r\n'));
    };
    // verbose_json 才能在支持时拿回真实 segments 时间戳；不兼容时第二次重试用 json
    pushField('response_format', verbose ? 'verbose_json' : 'json');
    pushField('model', request.model);
    // 语言字段同样只在首次尝试里带：部分实现不认这个字段会直接 400
    if (verbose && request.language !== '' && request.language !== 'auto') {
      pushField('language', request.language);
    }
    parts.push(encoder.encodeInto('--' + boundary + '\r\n'
      + 'Content-Disposition: form-data; name="file"; filename="' + request.fileName + '"\r\n'
      + 'Content-Type: ' + request.mimeType + '\r\n\r\n'));
    parts.push(request.audio);
    parts.push(encoder.encodeInto('\r\n--' + boundary + '--\r\n'));

    let total: number = 0;
    for (const part of parts) {
      total += part.length;
    }
    const merged: Uint8Array = new Uint8Array(total);
    let offset: number = 0;
    for (const part of parts) {
      merged.set(part, offset);
      offset += part.length;
    }
    return merged;
  }

  private static parseResponse(payload: string): TranscriptionOutcome {
    let root: Record<string, Object>;
    try {
      root = JSON.parse(payload) as Record<string, Object>;
    } catch (error) {
      return TranscriptionProvider.fail(TranscriptionErrorKind.BAD_RESPONSE,
        '服务商返回的不是 JSON，无法解析转写结果');
    }
    const segments: TranscriptSegment[] = [];
    let id: number = 0;
    const rawSegments: Object = root['segments'] as Object;
    if (rawSegments !== undefined && rawSegments !== null) {
      const list: Object[] = rawSegments as Object[];
      for (const entry of list) {
        const item: Record<string, Object> = entry as Record<string, Object>;
        const text: string = item['text'] === undefined ? '' : String(item['text']);
        if (text.trim() === '') {
          continue;
        }
        const start: number = Number(item['start']);
        const end: number = Number(item['end']);
        segments.push({
          segmentId: id++,
          startMs: isNaN(start) ? 0 : Math.round(start * 1000),
          endMs: isNaN(end) ? 0 : Math.round(end * 1000),
          text: text.trim(),
          speaker: item['speaker'] === undefined ? '' : String(item['speaker'])
        });
      }
    }
    const text: string = root['text'] !== undefined ? String(root['text']) : '';
    if (segments.length === 0 && text.trim() === '') {
      return TranscriptionProvider.fail(TranscriptionErrorKind.EMPTY_RESULT,
        '服务商返回的转写结果为空文本');
    }
    if (segments.length === 0) {
      // 只有纯文本：如实标记为不可同步
      segments.push({ segmentId: 0, startMs: 0, endMs: 0, text: text.trim(), speaker: '' });
      return {
        ok: true, timed: false, text: text.trim(), segments: segments,
        errorKind: TranscriptionErrorKind.NONE, message: ''
      };
    }
    const merged: string = segments.map((seg: TranscriptSegment) => seg.text).join(' ');
    return {
      ok: true,
      timed: segments[segments.length - 1].endMs > 0,
      text: text !== '' ? text : merged,
      segments: segments,
      errorKind: TranscriptionErrorKind.NONE,
      message: ''
    };
  }

  private static mapHttpError(status: number, payload: string): TranscriptionOutcome {
    const detail: string = TranscriptionProvider.errorMessageOf(payload);
    if (status === 401 || status === 403) {
      return TranscriptionProvider.fail(TranscriptionErrorKind.INVALID_KEY,
        'API Key 无效或没有该模型的权限' + detail);
    }
    if (status === 404) {
      if (detail.indexOf('model') >= 0) {
        return TranscriptionProvider.fail(TranscriptionErrorKind.MODEL_NOT_FOUND,
          '模型不存在或不可用' + detail);
      }
      return TranscriptionProvider.fail(TranscriptionErrorKind.BAD_ENDPOINT,
        '该地址没有语音转写接口（HTTP 404）：请确认厂商是否提供 OpenAI 兼容的 /audio/transcriptions' + detail);
    }
    if (status === 402 || detail.indexOf('quota') >= 0) {
      return TranscriptionProvider.fail(TranscriptionErrorKind.QUOTA, '账户额度不足' + detail);
    }
    if (status === 429) {
      return TranscriptionProvider.fail(TranscriptionErrorKind.RATE_LIMIT, '请求过于频繁，请稍后再试' + detail);
    }
    if (status === 413) {
      return TranscriptionProvider.fail(TranscriptionErrorKind.AUDIO_UNSUPPORTED,
        '音频文件超过该接口的大小限制' + detail);
    }
    return TranscriptionProvider.fail(TranscriptionErrorKind.BAD_RESPONSE,
      '服务商返回错误（HTTP ' + status + '）' + detail);
  }

  private static errorMessageOf(payload: string): string {
    try {
      const root: Record<string, Object> = JSON.parse(payload) as Record<string, Object>;
      const err: Object = root['error'];
      if (err !== undefined && err !== null) {
        const obj: Record<string, Object> = err as Record<string, Object>;
        const msg: Object = obj['message'];
        if (msg !== undefined) {
          // 只回传服务商的错误描述，绝不拼接 API Key
          return '：' + String(msg);
        }
      }
    } catch (error) {
      // 非 JSON 错误体，忽略
    }
    return '';
  }

  private static mapException(error: Error): TranscriptionOutcome {
    const message: string = error.message === undefined ? '' : error.message.toLowerCase();
    if (message.indexOf('timeout') >= 0) {
      return TranscriptionProvider.fail(TranscriptionErrorKind.TIMEOUT, '请求超时，请检查网络后重试');
    }
    if (message.indexOf('ssl') >= 0 || message.indexOf('certificate') >= 0) {
      return TranscriptionProvider.fail(TranscriptionErrorKind.SSL, 'TLS 证书校验失败，请确认端点地址');
    }
    if (message.indexOf('resolve') >= 0 || message.indexOf('connect') >= 0
      || message.indexOf('network') >= 0) {
      return TranscriptionProvider.fail(TranscriptionErrorKind.NETWORK, '网络不可用或无法连接该服务商');
    }
    return TranscriptionProvider.fail(TranscriptionErrorKind.NETWORK, '请求失败：' + error.message);
  }

  private static fail(kind: TranscriptionErrorKind, message: string): TranscriptionOutcome {
    Logger.warn(TAG, 'transcription failed (' + kind + '): ' + message);
    return {
      ok: false, timed: false, text: '', segments: [],
      errorKind: kind, message: message
    };
  }
}

