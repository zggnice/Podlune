/**
 * 特殊订阅的「更新说明」。
 *
 * 有些播客的公开 RSS 长期不刷新，但平台内仍在更新（例如小宇宙的网页/客户端有
 * 184 期，而 `feed.xyzfm.space` 的公开源停在第 155 期）。这类情况在节目详情页
 * 明确提示用户「后面几期在哪里更新」，比让用户以为是 App 漏抓更有用。
 *
 * 这里按**订阅源地址**登记，避免用标题做匹配（标题会改，地址不会）。
 */
export class FeedNotices {
  /** 钱婧老师的会客厅：公开 RSS 停在 Vol.155，之后的期数只在小宇宙更新 */
  private static readonly XIAOYUZHOU_155: string = 'https://feed.xyzfm.space/9lgcqvwrheuj';

  /** 该订阅是否需要在详情页显示「小宇宙独家」提示 */
  static isXiaoyuzhouAfter155(downloadUrl: string): boolean {
    return downloadUrl.trim().toLowerCase() === FeedNotices.XIAOYUZHOU_155;
  }
}
