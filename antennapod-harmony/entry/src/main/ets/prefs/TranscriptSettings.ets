// AI 文字稿配置：非敏感项存 Preferences，API Key 只进 HarmonyOS Asset Store（安全存储）。
// 密钥不落普通配置文件、不进日志、不出现在错误信息里。
import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import util from '@ohos.util';
import { asset } from '@kit.AssetStoreKit';
import { Logger } from '../utils/Logger';

const TAG: string = 'TranscriptSettings';
const PREF_NAME: string = 'transcript_settings';

/** 服务商：当前只有真正实现了协议的两个选项 */
export enum TranscriptProviderKind {
  OPENAI = 0,
  CUSTOM_OPENAI = 1
}

/** 测试状态（只有 TESTED_OK 才允许自动生成） */
export enum ProviderTestState {
  NOT_CONFIGURED = 0,
  NOT_TESTED = 1,
  TESTING = 2,
  TESTED_OK = 3,
  TESTED_FAILED = 4
}

/** 官方文字稿不可用时的策略 */
export enum AutoTranscriptPolicy {
  ASK = 0,
  AUTO = 1,
  NEVER = 2
}

export interface TranscriptConfig {
  enabled: boolean;
  provider: number;
  /** 通用模型模式下选中的厂商 id（空 = 还没选） */
  vendor: string;
  /** 实际调用协议：openai / chat / unsupported（由厂商决定） */
  protocol: string;
  baseUrl: string;
  model: string;
  language: string;
  policy: number;
  wifiOnly: boolean;
  confirmCost: boolean;
  testState: number;
  testedAt: number;
  testedMessage: string;
  /** 服务商是否支持返回真实时间戳（由测试结果决定） */
  supportsTimestamps: boolean;
}

const DEFAULT_BASE_OPENAI: string = 'https://api.openai.com/v1';


/**
 * 通用模型模式下的厂商预设。
 *
 * `protocol` 决定实际调用方式，**不再把所有人都当成 OpenAI 转写接口**：
 * - 'openai'  ：POST {baseUrl}/audio/transcriptions（multipart），OpenAI 兼容
 * - 'chat'    ：POST {baseUrl}/chat/completions（多模态音频消息）
 * - 'unsupported'：该厂商只有私有异步协议（需要 SecretKey 签名或后端代理），暂不实现
 *
 * `maxSeconds` / `maxMB` 来自各厂商官方文档，用于在提交前就给出可操作的提示。
 */
export interface TranscriptVendor {
  id: string;
  name: string;
  protocol: string;
  baseUrl: string;
  defaultModel: string;
  modelHint: string;
  maxSeconds: number;
  maxMB: number;
  /** 一句话说明：协议/限制，直接展示给用户 */
  note: string;
}

export class TranscriptVendors {
  static readonly ALL: TranscriptVendor[] = [
    {
      id: 'siliconflow',
      name: '硅基流动 SiliconFlow',
      protocol: 'openai',
      baseUrl: 'https://api.siliconflow.cn/v1',
      defaultModel: 'FunAudioLLM/SenseVoiceSmall',
      modelHint: 'FunAudioLLM/SenseVoiceSmall',
      maxSeconds: 3600,
      maxMB: 50,
      note: 'OpenAI 兼容转写接口，单次最长 1 小时 / 50MB'
    },
    {
      id: 'zhipu',
      name: '智谱 GLM-ASR',
      protocol: 'openai',
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      defaultModel: 'glm-asr-2512',
      modelHint: 'glm-asr-2512',
      maxSeconds: 30,
      maxMB: 25,
      note: 'GLM-ASR 转写接口，单次最长 30 秒 / 25MB，无逐句时间戳'
    },
    {
      id: 'qwen',
      name: '阿里云百炼（通义千问）',
      protocol: 'unsupported',
      baseUrl: 'https://dashscope.aliyuncs.com/api/v1',
      defaultModel: '',
      modelHint: 'paraformer-v2',
      maxSeconds: 7200,
      maxMB: 1000,
      note: 'DashScope 异步文件转写：需提交任务并轮询，且要 x-dashscope-async 头，当前版本未接入'
    },
    {
      id: 'doubao',
      name: '火山引擎（豆包）',
      protocol: 'unsupported',
      baseUrl: 'https://openspeech.bytedance.com/api/v1',
      defaultModel: '',
      modelHint: 'bigmodel',
      maxSeconds: 10800,
      maxMB: 2048,
      note: '录音文件识别 HTTP 异步接口：需 AppID + Access Token 双重鉴权，当前版本未接入'
    },
    {
      id: 'hunyuan',
      name: '腾讯云 ASR',
      protocol: 'unsupported',
      baseUrl: 'https://asr.tencentcloudapi.com',
      defaultModel: '',
      modelHint: '',
      maxSeconds: 10800,
      maxMB: 2048,
      note: '录音文件识别：需 TC3-HMAC-SHA256 签名（SecretId + SecretKey），App 内不内置密钥，当前版本未接入'
    },
    {
      id: 'spark',
      name: '讯飞开放平台',
      protocol: 'unsupported',
      baseUrl: 'https://raasr.xfyun.cn/api/v3',
      defaultModel: '',
      modelHint: '',
      maxSeconds: 18000,
      maxMB: 2048,
      note: '录音文件转写 REST：需 HMAC 签名，当前版本未接入'
    },
    {
      id: 'wenxin',
      name: '百度智能云（文心）',
      protocol: 'unsupported',
      baseUrl: 'https://aip.baidubce.com',
      defaultModel: '',
      modelHint: '',
      maxSeconds: 18000,
      maxMB: 2048,
      note: '音频文件转写：先换取 access_token 再提交任务，当前版本未接入'
    }
  ];

  static find(id: string): TranscriptVendor | undefined {
    for (const item of TranscriptVendors.ALL) {
      if (item.id === id) {
        return item;
      }
    }
    return undefined;
  }
}

export class TranscriptSettings {
  private static instance: preferences.Preferences | undefined = undefined;

  static init(context: common.Context): void {
    if (TranscriptSettings.instance !== undefined) {
      return;
    }
    const options: preferences.Options = { name: PREF_NAME };
    TranscriptSettings.instance = preferences.getPreferencesSync(context, options);
  }

  private static prefs(): preferences.Preferences | undefined {
    return TranscriptSettings.instance;
  }

  static load(): TranscriptConfig {
    const prefs: preferences.Preferences | undefined = TranscriptSettings.prefs();
    const config: TranscriptConfig = {
      enabled: false,
      provider: TranscriptProviderKind.OPENAI,
      vendor: '',
      protocol: 'openai',
      baseUrl: '',
      model: '',
      language: 'auto',
      policy: AutoTranscriptPolicy.ASK,
      wifiOnly: true,
      confirmCost: true,
      testState: ProviderTestState.NOT_CONFIGURED,
      testedAt: 0,
      testedMessage: '',
      supportsTimestamps: false
    };
    if (prefs === undefined) {
      return config;
    }
    config.enabled = prefs.getSync('enabled', false) as boolean;
    config.provider = prefs.getSync('provider', TranscriptProviderKind.OPENAI) as number;
    config.vendor = prefs.getSync('vendor', '') as string;
    config.protocol = prefs.getSync('protocol', 'openai') as string;
    config.baseUrl = prefs.getSync('baseUrl', '') as string;
    config.model = prefs.getSync('model', '') as string;
    config.language = prefs.getSync('language', 'auto') as string;
    config.policy = prefs.getSync('policy', AutoTranscriptPolicy.ASK) as number;
    config.wifiOnly = prefs.getSync('wifiOnly', true) as boolean;
    config.confirmCost = prefs.getSync('confirmCost', true) as boolean;
    config.testState = prefs.getSync('testState', ProviderTestState.NOT_CONFIGURED) as number;
    config.testedAt = prefs.getSync('testedAt', 0) as number;
    config.testedMessage = prefs.getSync('testedMessage', '') as string;
    config.supportsTimestamps = prefs.getSync('supportsTimestamps', false) as boolean;
    return config;
  }

  /** 保存非敏感配置；任何关键字段变化都会把测试状态降级为「未测试」 */
  static save(config: TranscriptConfig, resetTest: boolean): void {
    const prefs: preferences.Preferences | undefined = TranscriptSettings.prefs();
    if (prefs === undefined) {
      return;
    }
    prefs.putSync('enabled', config.enabled);
    prefs.putSync('provider', config.provider);
    prefs.putSync('vendor', config.vendor);
    prefs.putSync('protocol', config.protocol);
    prefs.putSync('baseUrl', config.baseUrl);
    prefs.putSync('model', config.model);
    prefs.putSync('language', config.language);
    prefs.putSync('policy', config.policy);
    prefs.putSync('wifiOnly', config.wifiOnly);
    prefs.putSync('confirmCost', config.confirmCost);
    prefs.putSync('supportsTimestamps', config.supportsTimestamps);
    if (resetTest) {
      prefs.putSync('testState', ProviderTestState.NOT_TESTED);
      prefs.putSync('testedAt', 0);
      prefs.putSync('testedMessage', '');
    } else {
      prefs.putSync('testState', config.testState);
      prefs.putSync('testedAt', config.testedAt);
      prefs.putSync('testedMessage', config.testedMessage);
    }
    prefs.flush();
  }

  /** 内置服务商的官方端点；自定义服务用用户填写的地址 */
  static effectiveBaseUrl(config: TranscriptConfig): string {
    const raw: string = config.baseUrl.trim();
    if (config.provider === TranscriptProviderKind.OPENAI) {
      return raw === '' ? DEFAULT_BASE_OPENAI : raw;
    }
    return raw;
  }

  static isHttps(url: string): boolean {
    return url.toLowerCase().startsWith('https://');
  }

  /** 已完成真实测试且配置完整，才允许生成 */
  static isUsable(config: TranscriptConfig): boolean {
    return config.enabled
      && config.testState === ProviderTestState.TESTED_OK
      && config.model.trim() !== ''
      && TranscriptSettings.isHttps(TranscriptSettings.effectiveBaseUrl(config));
  }
}

/**
 * API Key 安全存储：HarmonyOS Asset Store Kit。
 * - 只按固定 ALIAS 存一条「ACCESS_TOKEN」类型密钥；
 * - 读取失败 / 平台不支持时返回空串，并由调用方给出「未配置」提示，
 *   绝不退回明文 Preferences。
 */
export class TranscriptKeyStore {
  private static readonly ALIAS: string = 'homenapod.transcript.api_key';

  private static aliasBytes(): Uint8Array {
    return new util.TextEncoder().encodeInto(TranscriptKeyStore.ALIAS);
  }

  private static baseAttrs(): asset.AssetMap {
    const attr: asset.AssetMap = new Map();
    attr.set(asset.Tag.ALIAS, TranscriptKeyStore.aliasBytes());
    return attr;
  }

  /** 写入密钥（已存在则替换）。失败返回 false，由调用方提示「无法安全保存」 */
  static async save(apiKey: string): Promise<boolean> {
    const attr: asset.AssetMap = TranscriptKeyStore.baseAttrs();
    attr.set(asset.Tag.SECRET, new util.TextEncoder().encodeInto(apiKey));
    attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    try {
      await asset.add(attr);
      return true;
    } catch (error) {
      // 同别名已存在：删掉再写（Asset Store 不允许重复 add）
      try {
        await TranscriptKeyStore.remove();
        await asset.add(attr);
        return true;
      } catch (error2) {
        Logger.error(TAG, 'save api key failed', new Error((error2 as Error).message));
        return false;
      }
    }
  }

  static async load(): Promise<string> {
    const query: asset.AssetMap = TranscriptKeyStore.baseAttrs();
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const list: Array<asset.AssetMap> = await asset.query(query);
      if (list === undefined || list.length === 0) {
        return '';
      }
      const secret: asset.Value | undefined = list[0].get(asset.Tag.SECRET);
      if (secret === undefined) {
        return '';
      }
      return util.TextDecoder.create('utf-8').decodeToString(secret as Uint8Array);
    } catch (error) {
      return '';
    }
  }

  static async has(): Promise<boolean> {
    const key: string = await TranscriptKeyStore.load();
    return key !== '';
  }

  static async remove(): Promise<void> {
    const query: asset.AssetMap = TranscriptKeyStore.baseAttrs();
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      await asset.remove(query);
    } catch (error) {
      Logger.warn(TAG, 'remove api key failed');
    }
  }
}