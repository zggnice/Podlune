import router from '@ohos.router';
import { EpisodeRepository, MonthlyStat, FeedStat } from '../db/repositories/EpisodeRepository';
import { FeedRepository } from '../db/repositories/FeedRepository';
import { Feed } from '../model/Feed';
import { UserPreferences } from '../prefs/UserPreferences';
import { FeedCover } from '../components/FeedCover';
import { EmptyState } from '../components/EmptyState';

/** 月份统计行（只统计当前自然年） */
interface MonthRow {
  month: string;
  label: string;
  totalMs: number;
}

/** 年份统计行（含月数、最高月份，让年份页签有信息量） */
interface YearRow {
  year: string;
  totalMs: number;
  monthCount: number;
  busiestMonth: string;
  busiestMs: number;
}

/**
 * 收听统计（参考图版式 + 鸿蒙 7 明暗双主题）。
 *
 * - 顶部大标题「共收听 X 小时 Y 分钟」+ 右侧关闭圆钮（= 返回 / 回首页）；
 * - 分段胶囊：订阅 / 月份 / 年份，**月份只统计当前自然年**；
 * - 每行「封面或月份徽标 + 名称 + 时长」，下面一条粗圆角比例条。
 *
 * 颜色全部走资源限定符（base 浅色 / dark 深色），随系统与应用内主题自动切换。
 */
@Entry
@Component
struct StatsPage {
  /** 全局字体族：导入自定义字体后 AppStorage 一变，本 struct 内所有 Text 一起重绘 */
  @StorageProp('app_font_family') appFontFamily: string = 'HarmonyOS Sans';
  @State months: MonthRow[] = [];
  @State feeds: FeedStat[] = [];
  @State years: YearRow[] = [];
  @State loading: boolean = true;
  @State totalMs: number = 0;
  @State activeTab: number = 0;
  @State includeMarked: boolean = false;
  @State message: string = '';
  /** 当前自然年：月份页只统计它 */
  private currentYear: number = new Date().getFullYear();
  private feedImages: Map<number, string> = new Map<number, string>();

  /**
   * 比例条配色：按行序做**色相旋转**生成，足够多（48 种）足以覆盖全部行而不重复。
   * 参考图里前几条是「黄 → 白 → 灰蓝 → 粉灰」，这里把这一节奏保留在高饱和段，
   * 后面继续沿色环旋转，保证任意两行颜色不同。
   * 浅色主题下自动降低明度、提高饱和度，避免淡色条在白底上看不清。
   */
  private static readonly GOLDEN_ANGLE: number = 137.508;

  /** 生成第 index 行的条色（HSL → HEX），保证 index 不同则颜色不同 */
  barColor(index: number): string {
    const light: boolean = this.isLightTheme();
    // 第一条固定为参考图里的品牌黄；浅色主题下压暗一档保证白底可读
    if (index === 0) {
      return light ? '#93771A' : '#FFC826';
    }
    // 色相：以参考图第一条的黄色为起点，按黄金角跳步，相邻两行对比明显
    const hue: number = (45 + index * StatsPage.GOLDEN_ANGLE) % 360;
    // 明度/饱和度：浅色主题 L=0.34 / S=0.72 —— 实测 24 个色相相对白底
    // 的 WCAG 对比度均 ≥ 3:1；深色主题用更亮的 L=0.62 保证在 #000 上通透
    const saturation: number = 0.72;
    const lightness: number = light ? 0.34 : 0.62;
    return StatsPage.hslToHex(hue, saturation, lightness);
  }

  /** 当前是否浅色主题（用页面背景色的相对亮度判断，无需额外监听） */
  private isLightTheme(): boolean {
    const bg: ResourceColor = $r('app.color.stats_bg');
    const num: number = Number(bg);
    if (isNaN(num)) {
      return true;
    }
    // 0xAARRGGBB：取 RGB 三通道求相对亮度
    const r: number = (num >> 16) & 0xFF;
    const g: number = (num >> 8) & 0xFF;
    const b: number = num & 0xFF;
    return (0.299 * r + 0.587 * g + 0.114 * b) > 128;
  }

  /** HSL → #RRGGBB */
  private static hslToHex(hue: number, saturation: number, lightness: number): string {
    const c: number = (1 - Math.abs(2 * lightness - 1)) * saturation;
    const hp: number = hue / 60;
    const x: number = c * (1 - Math.abs(hp % 2 - 1));
    let r1: number = 0;
    let g1: number = 0;
    let b1: number = 0;
    if (hp < 1) {
      r1 = c; g1 = x;
    } else if (hp < 2) {
      r1 = x; g1 = c;
    } else if (hp < 3) {
      g1 = c; b1 = x;
    } else if (hp < 4) {
      g1 = x; b1 = c;
    } else if (hp < 5) {
      r1 = x; b1 = c;
    } else {
      r1 = c; b1 = x;
    }
    const m: number = lightness - c / 2;
    const toHex = (v: number): string => {
      const n: number = Math.round(Math.max(0, Math.min(255, (v + m) * 255)));
      const s: string = n.toString(16);
      return s.length === 1 ? '0' + s : s;
    };
    return '#' + toHex(r1) + toHex(g1) + toHex(b1);
  }

  build() {
    Column() {
      // ------------------------------------------------ 顶部：汇总 + 关闭
      Row() {
        Column({ space: 6 }) {
          Text(this.summaryText()).fontFamily(this.appFontFamily)
            .fontSize(26)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(2)
          Text(this.subtitleText()).fontFamily(this.appFontFamily)
            .fontSize(13)
            .fontColor($r('app.color.stats_muted'))
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Stack() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(15)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width(32)
        .height(32)
        .borderRadius(16)
        .backgroundColor($r('app.color.stats_chip'))
        .alignContent(Alignment.Center)
        .onClick(() => {
          this.close();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 24, right: 20, top: 16, bottom: 12 })

      // ------------------------------------------------ 分段胶囊
      Row() {
        this.segment(0, '订阅')
        this.segment(1, '月份')
        this.segment(2, '年份')
      }
      .width('100%')
      .height(32)
      .padding(2)
      .margin({ left: 20, right: 20, bottom: 12 })
      .borderRadius(16)
      .backgroundColor($r('app.color.stats_chip'))

      if (this.message !== '') {
        Text(this.message).fontFamily(this.appFontFamily)
          .fontSize(12)
          .fontColor($r('app.color.error'))
          .width('100%')
          .padding({ left: 24, right: 24, bottom: 4 })
      }

      if (this.loading) {
        Column() {
          Text($r('app.string.loading')).fontFamily(this.appFontFamily)
            .fontSize(14)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          if (this.activeTab === 0) {
            if (this.feeds.length === 0) {
              ListItem() {
                this.emptyBlock($r('app.string.stats_empty'))
              }
            }
            ForEach(this.feeds, (stat: FeedStat, index: number) => {
              ListItem() {
                this.barRow(stat.title, this.humanDuration(stat.totalMs), stat.totalMs,
                  this.maxFeedMs(), index, this.feedImage(stat.feedId))
              }
            }, (stat: FeedStat) => 'f-' + stat.feedId.toString())
          } else if (this.activeTab === 1) {
            if (this.months.length === 0) {
              ListItem() {
                this.emptyBlock($r('app.string.stats_empty'))
              }
            }
            ForEach(this.months, (row: MonthRow, index: number) => {
              ListItem() {
                this.monthCard(row, index)
              }
            }, (row: MonthRow) => 'm-' + row.month)
          } else {
            if (this.years.length === 0) {
              ListItem() {
                this.emptyBlock($r('app.string.stats_empty'))
              }
            }
            ForEach(this.years, (row: YearRow, index: number) => {
              ListItem() {
                this.yearCard(row, index)
              }
            }, (row: YearRow) => 'y-' + row.year)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .padding({ left: 20, right: 20, bottom: 24 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.stats_bg'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  /** 分段控件的一项 */
  @Builder
  segment(index: number, label: string) {
    Text(label).fontFamily(this.appFontFamily)
      .fontSize(13)
      .fontWeight(this.activeTab === index ? FontWeight.Medium : FontWeight.Regular)
      .fontColor(this.activeTab === index ? $r('app.color.stats_segment_on') : $r('app.color.text_secondary'))
      .textAlign(TextAlign.Center)
      .height(28)
      .borderRadius(14)
      .backgroundColor(this.activeTab === index ? $r('app.color.stats_segment_on_bg') : Color.Transparent)
      .layoutWeight(1)
      .onClick(() => {
        this.activeTab = index;
      })
  }

  /** 月份统计卡片：月份 + 时长 / 辅助信息 / 进度条 */
  @Builder
  monthCard(row: MonthRow, index: number) {
    Column({ space: 10 }) {
      Row() {
        Text(row.label).fontFamily(this.appFontFamily)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text(this.humanDuration(row.totalMs)).fontFamily(this.appFontFamily)
          .fontSize(15)
          .fontColor($r('app.color.stats_muted'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.monthMeta(row)).fontFamily(this.appFontFamily)
        .fontSize(12)
        .fontColor($r('app.color.stats_muted'))
        .maxLines(1)
        .width('100%')

      // 与「订阅」页完全相同的比例条：同一套 bar()、同一颜色规则、同一比例算法
      this.bar(row.totalMs, this.maxMonthMs(), index)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor($r('app.color.stats_card'))
    .borderRadius(16)
  }

  /** 年份统计卡片：年份 + 时长 / 月数 / 最高月 / 进度条 */
  @Builder
  yearCard(row: YearRow, index: number) {
    Column({ space: 10 }) {
      Row() {
        Text(row.year + ' 年').fontFamily(this.appFontFamily)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text(this.humanDuration(row.totalMs)).fontFamily(this.appFontFamily)
          .fontSize(15)
          .fontColor($r('app.color.stats_muted'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.yearMonthsLine(row)).fontFamily(this.appFontFamily)
        .fontSize(12)
        .fontColor($r('app.color.stats_muted'))
        .width('100%')

      Text(this.yearTopLine(row)).fontFamily(this.appFontFamily)
        .fontSize(12)
        .fontColor($r('app.color.stats_muted'))
        .width('100%')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      // 与「订阅」页完全相同的比例条
      this.bar(row.totalMs, this.maxYearMs(), index)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor($r('app.color.stats_card'))
    .borderRadius(16)
  }

  /** 通用比例条行：封面（可选）+ 名称 + 时长 + 粗圆角比例条 */
  @Builder
  barRow(title: string, valueText: string, value: number, max: number, index: number, imageUrl: string) {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        if (imageUrl !== '') {
          FeedCover({
            imageUrl: imageUrl,
            coverSize: 40,
            radius: 8,
            fallbackTitle: title,
            placeholderColor: $r('app.color.cover_placeholder')
          })
        } else {
          // 月份行没有封面：用同尺寸圆角徽标占位，保证左列对齐
          Stack() {
            Text(title.replace('月', '')).fontFamily(this.appFontFamily)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
          }
          .width(40)
          .height(40)
          .borderRadius(8)
          .backgroundColor($r('app.color.stats_chip'))
          .alignContent(Alignment.Center)
        }

        Text(title).fontFamily(this.appFontFamily)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Text(valueText).fontFamily(this.appFontFamily)
          .fontSize(13)
          .fontColor($r('app.color.stats_muted'))
          .maxLines(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      this.bar(value, max, index)
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }

  /** 年份行：年份徽标 + 年份 + 月数/最高月 + 总时长 + 比例条 */
  @Builder
  yearRow(row: YearRow, index: number) {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        Stack() {
          Text(row.year.substring(2)).fontFamily(this.appFontFamily)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(index === 0 ? $r('app.color.stats_badge_on') : $r('app.color.text_secondary'))
        }
        .width(44)
        .height(40)
        .borderRadius(8)
        .backgroundColor(index === 0 ? $r('app.color.stats_badge_on_bg') : $r('app.color.stats_chip'))
        .alignContent(Alignment.Center)

        Column({ space: 2 }) {
          Text(row.year + ' 年').fontFamily(this.appFontFamily)
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
          Text(this.monthSummary(row)).fontFamily(this.appFontFamily)
            .fontSize(12)
            .fontColor($r('app.color.stats_muted'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(this.humanDuration(row.totalMs)).fontFamily(this.appFontFamily)
          .fontSize(13)
          .fontColor($r('app.color.stats_muted'))
          .maxLines(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      this.bar(row.totalMs, this.maxYearMs(), index)
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }

  /** 粗圆角比例条（自绘，避免 Progress 内缩与动画干扰版式） */
  @Builder
  bar(value: number, max: number, index: number) {
    Stack({ alignContent: Alignment.Start }) {
      Row()
        .width('100%')
        .height(14)
        .borderRadius(7)
        .backgroundColor($r('app.color.stats_track'))

      Row()
        .width(Math.max(4, Math.min(100, max <= 0 ? 0 : value * 100 / max)) + '%')
        .height(14)
        .borderRadius(7)
        .backgroundColor(this.barColor(index))
    }
    .width('100%')
    .height(14)
  }

  @Builder
  emptyBlock(title: ResourceStr) {
    Column() {
      EmptyState({ icon: $r('sys.symbol.histogram'), title: title })
    }
    .width('100%')
    .padding({ top: 60 })
  }

  /** 年份行副标题：「3 个月 · 最高 12月 2 小时」 */
  monthSummary(row: YearRow): string {
    if (row.busiestMs <= 0) {
      return row.monthCount.toString() + ' 个月有收听';
    }
    return row.monthCount.toString() + ' 个月 · 最高 ' + row.busiestMonth + ' '
      + this.humanDuration(row.busiestMs);
  }

  /** 关闭：栈内有上一页就返回；否则回首页（避免点了没反应） */
  close(): void {
    try {
      if (Number(router.getLength()) > 1) {
        router.back();
        return;
      }
    } catch (error) {
      // 落到下面的兜底
    }
    router.replaceUrl({ url: 'pages/Index' });
  }

  /** 顶部汇总：「共收听 62 小时 12 分钟」 */
  summaryText(): string {
    const totalMinutes: number = Math.floor(this.totalMs / 60000);
    const hours: number = Math.floor(totalMinutes / 60);
    const minutes: number = totalMinutes % 60;
    if (hours <= 0) {
      return '共收听 ' + minutes.toString() + ' 分钟';
    }
    return '共收听 ' + hours.toString() + ' 小时 ' + minutes.toString() + ' 分钟';
  }

  /** 顶部副标题：当前页签口径（自然文案，不再是「N 个订阅」这种干巴巴的计数） */
  subtitleText(): string {
    if (this.activeTab === 0) {
      return '共 ' + this.feeds.length.toString() + ' 个订阅有收听';
    }
    if (this.activeTab === 1) {
      return this.currentYear.toString() + ' 年 · 共 ' + this.months.length.toString() + ' 个月有收听';
    }
    return '共有 ' + this.years.length.toString() + ' 年的收听记录';
  }

  /** 月份卡片副标题：本年共 N 个月收听 · 占比 X% */
  monthMeta(row: MonthRow): string {
    const count: number = this.months.length;
    const max: number = this.maxMonthMs();
    const share: number = max <= 0 ? 0 : Math.round(row.totalMs * 100 / max);
    return '本年共 ' + count.toString() + ' 个月收听 · 占比 ' + share.toString() + '%';
  }

  /** 年份卡片第二行 */
  yearMonthsLine(row: YearRow): string {
    return '共有 ' + row.monthCount.toString() + ' 个月收听';
  }

  /** 年份卡片第三行 */
  yearTopLine(row: YearRow): string {
    if (row.busiestMs <= 0 || row.busiestMonth === '') {
      return '暂无最集中的月份';
    }
    return '收听最多：' + row.busiestMonth + ' · ' + this.humanDuration(row.busiestMs);
  }

  /** 行内时长 */
  humanDuration(ms: number): string {
    const totalMinutes: number = Math.floor(ms / 60000);
    const hours: number = Math.floor(totalMinutes / 60);
    const minutes: number = totalMinutes % 60;
    if (hours <= 0) {
      return minutes.toString() + ' 分钟';
    }
    return hours.toString() + ' 小时 ' + minutes.toString() + ' 分钟';
  }

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    try {
      const feeds: Feed[] = await FeedRepository.listSubscribed();
      const images: Map<number, string> = new Map<number, string>();
      for (const feed of feeds) {
        images.set(feed.id, feed.imageUrl);
      }
      this.feedImages = images;

      const allMonths: MonthlyStat[] = await EpisodeRepository.listStatsByMonth();
      this.includeMarked = UserPreferences.getStatisticsIncludeMarked();
      this.feeds = await EpisodeRepository.listStatsByFeed(this.includeMarked);

      let total: number = 0;
      for (const stat of this.feeds) {
        total += stat.totalMs;
      }
      this.totalMs = total;

      this.months = this.buildCurrentYearMonths(allMonths);
      this.years = this.buildYears(allMonths);
    } catch (error) {
      this.months = [];
      this.feeds = [];
      this.years = [];
      this.message = (error as Error).message;
    } finally {
      this.loading = false;
    }
  }

  /** 月份统计：只取当前自然年，按 1→12 月升序；无收听月份不展示 */
  buildCurrentYearMonths(all: MonthlyStat[]): MonthRow[] {
    const prefix: string = this.currentYear.toString() + '-';
    const rows: MonthRow[] = [];
    for (const stat of all) {
      if (!stat.month.startsWith(prefix) || stat.totalMs <= 0) {
        continue;
      }
      const monthNumber: number = Number(stat.month.substring(5, 7));
      rows.push({ month: stat.month, label: monthNumber.toString() + '月', totalMs: stat.totalMs });
    }
    rows.sort((left: MonthRow, right: MonthRow) => left.month.localeCompare(right.month));
    return rows;
  }

  /** 年份统计：总值 + 有收听月数 + 最高月份 */
  buildYears(all: MonthlyStat[]): YearRow[] {
    const totals: Map<string, number> = new Map<string, number>();
    const counts: Map<string, number> = new Map<string, number>();
    const busiest: Map<string, MonthlyStat> = new Map<string, MonthlyStat>();
    for (const stat of all) {
      if (stat.totalMs <= 0 || stat.month.length < 4) {
        continue;
      }
      const year: string = stat.month.substring(0, 4);
      const current: number | undefined = totals.get(year);
      totals.set(year, (current === undefined ? 0 : current) + stat.totalMs);
      const count: number | undefined = counts.get(year);
      counts.set(year, (count === undefined ? 0 : count) + 1);
      const best: MonthlyStat | undefined = busiest.get(year);
      if (best === undefined || stat.totalMs > best.totalMs) {
        busiest.set(year, stat);
      }
    }
    const rows: YearRow[] = [];
    totals.forEach((totalMs: number, year: string) => {
      const best: MonthlyStat | undefined = busiest.get(year);
      const bestMonth: string = best === undefined ? '' : Number(best.month.substring(5, 7)).toString() + '月';
      rows.push({
        year: year,
        totalMs: totalMs,
        monthCount: counts.get(year) ?? 0,
        busiestMonth: bestMonth,
        busiestMs: best === undefined ? 0 : best.totalMs
      });
    });
    rows.sort((left: YearRow, right: YearRow) => right.year.localeCompare(left.year));
    return rows;
  }

  feedImage(feedId: number): string {
    const image: string | undefined = this.feedImages.get(feedId);
    return image === undefined ? '' : image;
  }

  maxFeedMs(): number {
    let max: number = 1;
    for (const stat of this.feeds) {
      if (stat.totalMs > max) {
        max = stat.totalMs;
      }
    }
    return max;
  }

  maxMonthMs(): number {
    let max: number = 1;
    for (const row of this.months) {
      if (row.totalMs > max) {
        max = row.totalMs;
      }
    }
    return max;
  }

  maxYearMs(): number {
    let max: number = 1;
    for (const row of this.years) {
      if (row.totalMs > max) {
        max = row.totalMs;
      }
    }
    return max;
  }
}
