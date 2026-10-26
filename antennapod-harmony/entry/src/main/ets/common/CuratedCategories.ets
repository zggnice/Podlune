/**
 * 首页六个推荐板块的配置（首页与分类页共用，避免两处各写一份）。
 *
 * `id` 同时是首页区块标识（`curated_<id>`）与路由参数：**保持不变**，
 * 这样用户已有的显隐 / 排序配置在改名后仍然有效。
 * 显示名称走 `titleKey` 指向的字符串资源，改名只改资源、不动 id。
 */
export interface CuratedCategory {
  id: string;
  /** 标题资源（`$r()` 不接受变量，用 id 查表） */
  titleKey: string;
  /** 一行简介资源 */
  descKey: string;
  /**
   * 数据来源：
   * - `charts`：Apple 公开榜单（真实热度排序，仅「全球热门」使用）
   * - `search`：iTunes 主题检索 + 分类元数据过滤（其余五个板块）
   */
  source: string;
  /** 榜单市场（仅 source = charts 时使用） */
  markets: string[];
  /** 主题检索词（按优先级；分类页继续下滑时会依次使用） */
  searchTerms: string[];
  /** 允许的 Apple 分类名（主判据，大小写不敏感） */
  genres: string[];
  /** 辅助关键词：命中节目标题 / 作者时加分，或在分类缺失时兜底 */
  keywords: string[];
  /** 必须命中其一的关键词（如「语言学习」不能是普通外语访谈） */
  requiredAny: string[];
}

export class CuratedCategories {
  static readonly ALL: CuratedCategory[] = [
    {
      id: 'global',
      titleKey: 'home_curated_global',
      descKey: 'curated_desc_global',
      source: 'charts',
      // 四个主要英语市场：合并后按「跨市场表现」排序，单市场爆款权重自然降低
      markets: ['us', 'gb', 'ca', 'au'],
      searchTerms: ['top podcasts', 'best podcasts'],
      genres: [],
      keywords: [],
      requiredAny: []
    },
    {
      id: 'chinese',
      titleKey: 'home_curated_chinese',
      descKey: 'curated_desc_chinese',
      // 与「全球热门」同一套机制：合并 Apple 大中华区三个市场榜单，按跨市场表现排序
      source: 'charts',
      markets: ['cn', 'tw', 'hk'],
      searchTerms: ['中文播客', '華語播客', 'podcast 中文'],
      genres: [],
      keywords: [],
      requiredAny: []
    },
    {
      id: 'silicon',
      titleKey: 'home_curated_silicon',
      descKey: 'curated_desc_silicon',
      source: 'search',
      markets: [],
      searchTerms: ['technology', 'artificial intelligence', 'software engineering', 'startup'],
      genres: ['Technology', 'Tech News', 'Software Engineering', 'Artificial Intelligence', 'Gadgets'],
      keywords: ['technology', 'tech news', 'software', 'programming', 'developer', 'artificial intelligence',
        'machine learning', 'startup', 'silicon valley', 'gadget', 'semiconductor', 'ai'],
      requiredAny: []
    },
    {
      id: 'investor',
      titleKey: 'home_curated_investor',
      descKey: 'curated_desc_investor',
      source: 'search',
      markets: [],
      searchTerms: ['investing', 'business news', 'stock market', 'entrepreneurship'],
      genres: ['Business', 'Investing', 'Business News', 'Entrepreneurship', 'Management', 'Marketing'],
      keywords: ['invest', 'market', 'business', 'economy', 'finance', 'financial', 'stock', 'venture',
        'entrepreneur', 'company', 'trade', 'money'],
      requiredAny: []
    },
    {
      id: 'health',
      titleKey: 'home_curated_health',
      descKey: 'curated_desc_health',
      source: 'search',
      markets: [],
      searchTerms: ['health wellness', 'mental health', 'fitness', 'nutrition'],
      genres: ['Health & Fitness', 'Health', 'Fitness', 'Mental Health', 'Medicine', 'Nutrition', 'Alternative Health'],
      keywords: ['health', 'wellness', 'fitness', 'nutrition', 'mental', 'sleep', 'meditation', 'diet',
        'exercise', 'therapy', 'mindfulness', 'workout'],
      requiredAny: []
    },
    {
      id: 'women',
      titleKey: 'home_curated_women',
      descKey: 'curated_desc_women',
      source: 'search',
      markets: [],
      searchTerms: ['society culture', 'documentary', 'personal stories', 'philosophy'],
      genres: ['Society & Culture', 'Documentary', 'Personal Journals', 'Relationships', 'Philosophy', 'Places & Travel'],
      keywords: ['society', 'culture', 'story', 'stories', 'documentary', 'interview', 'philosophy',
        'relationship', 'people', 'history', 'conversation', 'life'],
      requiredAny: []
    },
    {
      id: 'language',
      titleKey: 'home_curated_language',
      descKey: 'curated_desc_language',
      source: 'search',
      markets: [],
      searchTerms: ['learn english', 'language learning', 'learn spanish', 'learn japanese'],
      genres: ['Education', 'Language Learning', 'Language Courses', 'Courses', 'Self-Improvement'],
      keywords: ['learn', 'learning', 'english', 'spanish', 'japanese', 'french', 'korean', 'german',
        'language', 'lesson', 'lessons', 'vocabulary', 'grammar', 'esl', 'toefl', 'ielts', 'pronunciation'],
      // 语言学习必须能看出「教学」定位：普通外语访谈不算
      requiredAny: ['learn', 'learning', 'language', 'english', 'spanish', 'japanese', 'french', 'korean',
        'german', 'lesson', 'lessons', 'vocabulary', 'grammar', 'esl', 'toefl', 'ielts', 'pronunciation']
    }
  ];

  static find(id: string): CuratedCategory {
    for (const item of CuratedCategories.ALL) {
      if (item.id === id) {
        return item;
      }
    }
    return CuratedCategories.ALL[0];
  }

  /** 首页预览条数（首页只做发现，不需要铺满） */
  static readonly PREVIEW_SIZE: number = 8;
}
