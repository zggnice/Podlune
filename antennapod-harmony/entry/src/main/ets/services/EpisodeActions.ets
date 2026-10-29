import pasteboard from '@ohos.pasteboard';
import { FeedItem } from '../model/FeedItem';
import { EpisodeRepository } from '../db/repositories/EpisodeRepository';
import { FavoritesRepository } from '../db/repositories/FavoritesRepository';
import { QueueEngine } from '../player/QueueEngine';
import { DownloadManager } from '../download/DownloadManager';
import { EventHub, EventType, FeedItemUpdateData } from '../events/EventHub';

/**
 * 单集「更多」菜单里的动作（收藏 / 已播 / 队列 / 分享 / 下载）。
 *
 * 所有单集列表页共用同一套实现，保证「卡片右下角更多」的行为完全一致；
 * 每个动作成功后广播 FEED_ITEM_UPDATE，让其它页面同步刷新。
 */
export class EpisodeActions {
  /** 是否已收藏 */
  static async isFavorite(item: FeedItem): Promise<boolean> {
    if (item.id <= 0) {
      return false;
    }
    return await FavoritesRepository.isFavorite(item.id);
  }

  /** 收藏 / 取消收藏，返回操作后的状态 */
  static async toggleFavorite(item: FeedItem): Promise<boolean> {
    if (item.id <= 0) {
      return false;
    }
    const favorited: boolean = await FavoritesRepository.isFavorite(item.id);
    if (favorited) {
      await FavoritesRepository.remove(item.id);
    } else {
      await FavoritesRepository.add(item.id, item.feedId);
    }
    EpisodeActions.publishUpdate(item);
    return !favorited;
  }

  /** 标记已播 / 未播 */
  static async togglePlayed(item: FeedItem): Promise<void> {
    const target: boolean = !item.isPlayed;
    await EpisodeRepository.markPlayed(item.id, target);
    item.isPlayed = target;
    EpisodeActions.publishUpdate(item);
  }

  /** 加入播放队列 */
  static async addToQueue(item: FeedItem): Promise<void> {
    await QueueEngine.add(item);
  }

  /** 下载单集（仅未下载时） */
  static async startDownload(item: FeedItem): Promise<void> {
    if (item.media === undefined) {
      throw new Error('no media');
    }
    await DownloadManager.startDownload(item.media, item.title);
  }

  /** 删除已下载文件 */
  static async deleteDownload(item: FeedItem): Promise<void> {
    if (item.media === undefined) {
      return;
    }
    await DownloadManager.deleteFile(item.media);
  }

  /** 是否已下载 */
  static isDownloaded(item: FeedItem): boolean {
    return item.media !== undefined && item.media.fileUrl !== '';
  }

  /**
   * 分享：复制单集链接到剪贴板（本 SDK 无系统分享面板 API）。
   *
   * @returns 是否成功复制（没有可用链接时返回 false）
   */
  static async shareLink(item: FeedItem, feedLink: string): Promise<boolean> {
    let link: string = item.link;
    if (link === '' && item.media !== undefined) {
      link = item.media.downloadUrl;
    }
    if (link === '' && feedLink !== '') {
      link = feedLink;
    }
    if (link === '') {
      return false;
    }
    const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, link);
    await pasteboard.getSystemPasteboard().setData(data);
    return true;
  }

  private static publishUpdate(item: FeedItem): void {
    const data: FeedItemUpdateData = { feedId: item.feedId, itemId: item.id };
    EventHub.publish(EventType.FEED_ITEM_UPDATE, data);
  }
}
