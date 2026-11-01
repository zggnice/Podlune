# NOTICE · 来源、许可与合规声明

## 一、项目身份

| 项 | 值 |
|---|---|
| 产品名称 | **Podlune** |
| bundleName | `com.podlune.app` |
| 平台 | HarmonyOS NEXT（ArkTS / ArkUI） |
| 版本 | 见 `AppScope/app.json5`（当前 1.0.00 / 1000000） |

## 二、上游来源

来源链条：**AntennaPod → HomenaPod（鸿蒙移植工程）→ Podlune（本项目）**。

本项目是开源播客应用 **AntennaPod** 的鸿蒙移植实现，在其移植工程 HomenaPod 的基础上二次开发：

- 上游项目：<https://github.com/AntennaPod/AntennaPod>（GNU GPL-3.0）
- 移植工程：[TomoeMami/HomenaPod](https://github.com/TomoeMami/HomenaPod)（GNU GPL-3.0）
- 移植方式：按上游模块语义用 ArkTS/ArkUI 重新实现；源码文件头部以 `// Port of: <上游相对路径>` 标注对应关系，便于逐项比对与回归。

## 三、许可（GPL-3.0）

- 本项目遵循 **GNU GPL-3.0**（与上游一致）；`entry/oh-package.json5` 声明 `"license": "GPL-3.0-only"`，仓库根目录 `LICENSE` 为许可全文。
- **源码获取**：本项目的公开仓库地址（以上架页面与「关于 → 隐私政策与开源声明」内展示的地址为准）。
- 分发与再发布时必须保留：本声明、上游来源标注、全部 `Port of:` 注释、`LICENSE` 全文，并允许接收者再分发与修改。
- 本应用不含闭源第三方 SDK、不含广告 SDK。

## 四、商标与品牌

- **Podlune** 为本项目自有名称；不使用 AntennaPod 的名称、图标或品牌标识作为产品标识（应用名、图标、包名、通知、UA 均已替换）。
- AntennaPod 的名称与标识归其项目方所有；本项目仅在「来源与许可」语境中作事实性引用，不暗示上游对本项目的背书。

## 五、数据来源

| 功能 | 来源 | 说明 |
|---|---|---|
| 播客订阅与播放 | 用户自行添加的 RSS / Atom 地址 | 内容版权归各播客方所有，本应用仅做订阅、缓存与播放 |
| 中文播客榜 | [xyzrank.com](https://xyzrank.com) 公开接口 | 仅作发现入口，每日更新缓存，不存储、不分发原始数据 |
| 苹果播客榜 | Apple 公开榜单接口与公开榜单页 | 同上；若上游调整，该栏目可能暂时为空 |
| 搜索发现 | iTunes Search 等公开接口 | 仅在用户主动搜索时发起请求 |

## 六、隐私相关

- 不收集、不上传任何个人身份信息；无账号体系、无统计 SDK、无广告。
- 订阅、播放进度、队列、下载、书签等数据仅保存在**本机沙箱**（`relationalStore` + `preferences`）。
- 网络请求仅用于：抓取你订阅的播客源、获取榜单与搜索结果、下载音频，以及（默认关闭、需手动开启的）从第三方播客网页补全停更节目条目。
- 权限用途：

| 权限 | 用途 |
|---|---|
| `ohos.permission.INTERNET` / `GET_NETWORK_INFO` | 抓取订阅、榜单、下载音频 |
| `ohos.permission.KEEP_BACKGROUND_RUNNING` | 后台音频播放、定时刷新 |
| `ohos.permission.VIBRATE` | 睡眠定时器到时震动提醒 |
| `ohos.permission.ACCELEROMETER` | 睡眠定时期间「摇一摇」重置倒计时 |

## 七、生成方式声明

本项目的代码、资源与文档主要由 **DeepSeek** 在 **DeepSeek Harness（DSH）** 智能体框架下，通过自然语言对话迭代产出；人的角色是提出需求、逐屏验收与取舍。
