/**
 * 应用内对外链接集中管理（关于页 / 合规页共用）。
 *
 * ⚠️ 上架前必须替换 `SOURCE_REPO` / `ISSUES` / `DOCS` 三个常量为**你自己的公开仓库**：
 * GPL-3.0 要求随二进制向接收者提供「对应源码」（或等价的书面要约），因此发布前请先把
 * 本仓库（含 LICENSE、NOTICE.md、Port of 注释）公开到 GitHub / Gitee，再把地址填到这里。
 *
 * 当前值指向本项目所基于的移植工程（TomoeMami/HomenaPod），仅作为占位与来源标注，
 * 不要把它当作你自己二开版本的源码地址对外发布。
 */
export class AppLinks {
  /** 上游原项目（AntennaPod，GPL-3.0） */
  static readonly UPSTREAM_REPO: string = 'https://github.com/AntennaPod/AntennaPod';
  /** 本项目所基于的鸿蒙移植工程（GPL-3.0） */
  static readonly BASE_REPO: string = 'https://github.com/TomoeMami/HomenaPod';
  /** TODO(上架前)：换成你自己的公开仓库地址 */
  static readonly SOURCE_REPO: string = 'https://github.com/zggnice/Podlune';
  /** TODO(上架前)：换成你自己仓库的 Issues 地址 */
  static readonly ISSUES: string = 'https://github.com/zggnice/Podlune/issues';
  /** TODO(上架前)：换成你自己仓库的 README 地址 */
  static readonly DOCS: string = 'https://github.com/zggnice/Podlune#readme';
  /** GPL-3.0 许可全文 */
  static readonly LICENSE: string = 'https://www.gnu.org/licenses/gpl-3.0.html';
}
