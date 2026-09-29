import 'dart:async';

import 'package:flutter/material.dart';

import '../models/home_cms_models.dart';
import '../screens/home_poster_curation_screen.dart';
import '../services/analytics_service.dart';
import '../widgets/home_poster_carousel.dart';

/// 홈 포스터 클릭 시 열리는 큐레이션 기획.
/// 이미지(asset)는 사용자가 교체하고, 카피·칩·레시피 풀만 여기서 관리한다.
class HomePosterChip {
  const HomePosterChip({
    required this.label,
    this.sectionKey,
    this.matchKeywords = const <String>[],
  });

  final String label;

  /// 있으면 해당 home_section_index 풀을 우선 사용.
  final String? sectionKey;

  /// 제목·재료 텍스트 매칭 (부분 문자열, 소문자).
  final List<String> matchKeywords;
}

class HomePosterTip {
  const HomePosterTip({
    required this.title,
    required this.body,
    required this.icon,
  });

  final String title;
  final String body;
  final IconData icon;
}

/// 포스터 큐레이션용 기획 고정 상품 (마이노멀·알룰로스 등).
class HomePosterProduct {
  const HomePosterProduct({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.badge,
    this.imageUrl,
    this.priceLabel,
    this.searchQuery,
    this.productUrl,
    this.landingUrl,
    this.deeplinkUrl,
  });

  final String id;
  final String name;
  final String subtitle;

  /// 필터용 뱃지 — `마이노멀` | `알룰로스`
  final String badge;

  /// 네트워크 이미지. 비어 있으면 플레이스홀더.
  final String? imageUrl;
  final String? priceLabel;

  /// 쿠팡 검색어 (productUrl 없을 때 사용).
  final String? searchQuery;

  /// 직접 상품/제휴 URL이 있으면 우선 (BrandConnect affiliates 랜딩).
  final String? productUrl;

  /// 쿠팡 AFFSDP 랜딩. 있으면 단축 URL보다 먼저 연다.
  final String? landingUrl;

  /// 쿠팡 단축(deeplink) URL. 랜딩이 없을 때 폴백.
  final String? deeplinkUrl;
}

class HomePosterCuration {
  const HomePosterCuration({
    required this.id,
    required this.assetPath,
    required this.posterTitle,
    required this.subtitle,
    required this.pageTitle,
    required this.body,
    required this.chips,
    this.eyebrow = '요리고 큐레이션',
    this.poolSectionKeys = const <String>[],
    this.tips = const <HomePosterTip>[],
    this.tipsSectionTitle,
    this.products = const <HomePosterProduct>[],
    this.productsSectionTitle = '추천 상품',
    this.recipeSectionTitle = '레시피 고르기',
    this.showFridgeCta = false,
    this.fridgeCtaLabel,
    this.strictKeywordMatch = false,
    /// 포스터·상세 히어로 크롭 기준. 기본은 오른쪽 피사체 우선.
    this.imageAlignment = Alignment.centerRight,
    this.imageUrl,
  });

  final String id;
  final String assetPath;

  /// 포스터 카드 오버레이 (줄바꿈 가능).
  final String posterTitle;
  final String subtitle;

  /// 상세 페이지 큰 제목 (한 줄 권장, 줄바꿈 가능).
  final String pageTitle;
  final String body;
  final String eyebrow;
  final List<HomePosterChip> chips;

  /// 칩별 sectionKey 가 비었을 때 합쳐서 불러올 기본 풀.
  final List<String> poolSectionKeys;

  /// 커머스/스타터용 팁 카드.
  final List<HomePosterTip> tips;

  /// 팁 캐러셀 위 작은 섹션 제목 (없으면 숨김).
  final String? tipsSectionTitle;

  /// 기획 고정 상품 큐레이션 (비어 있으면 상품 섹션 숨김).
  final List<HomePosterProduct> products;
  final String productsSectionTitle;
  final String recipeSectionTitle;

  final bool showFridgeCta;
  final String? fridgeCtaLabel;

  /// true면 키워드 결과가 비어도 일반 레시피로 대체하지 않는다.
  final bool strictKeywordMatch;

  final Alignment imageAlignment;

  /// Storage/네트워크 이미지. 비어 있으면 [assetPath] 사용.
  final String? imageUrl;

  factory HomePosterCuration.fromCms(Map<String, dynamic> json) {
    List<String> strList(dynamic raw) {
      if (raw is! List) return const <String>[];
      return [
        for (final item in raw)
          if (item != null && item.toString().trim().isNotEmpty)
            item.toString().trim(),
      ];
    }

    final chipsRaw = json['chips'];
    final chips = <HomePosterChip>[
      if (chipsRaw is List)
        for (final item in chipsRaw)
          if (item is Map)
            HomePosterChip(
              label: item['label']?.toString() ?? '',
              sectionKey: (item['sectionKey']?.toString().trim().isNotEmpty == true)
                  ? item['sectionKey'].toString()
                  : null,
              matchKeywords: strList(item['matchKeywords']),
            ),
    ].where((c) => c.label.isNotEmpty).toList(growable: false);

    final tipsRaw = json['tips'];
    final tips = <HomePosterTip>[
      if (tipsRaw is List)
        for (final item in tipsRaw)
          if (item is Map)
            HomePosterTip(
              title: item['title']?.toString() ?? '',
              body: item['body']?.toString() ?? '',
              icon: homeCmsTipIcon(item['icon']?.toString()),
            ),
    ];

    final productsRaw = json['products'];
    final products = <HomePosterProduct>[
      if (productsRaw is List)
        for (final item in productsRaw)
          if (item is Map && (item['id']?.toString().isNotEmpty ?? false))
            HomePosterProduct(
              id: item['id'].toString(),
              name: item['name']?.toString() ?? '',
              subtitle: item['subtitle']?.toString() ?? '',
              badge: item['badge']?.toString() ?? '',
              imageUrl: item['imageUrl']?.toString(),
              priceLabel: item['priceLabel']?.toString(),
              searchQuery: item['searchQuery']?.toString(),
              productUrl: item['productUrl']?.toString(),
              landingUrl: item['landingUrl']?.toString(),
              deeplinkUrl: item['deeplinkUrl']?.toString(),
            ),
    ];

    final id = json['id']?.toString() ?? '';
    if (id.isEmpty || chips.isEmpty) {
      throw FormatException('invalid cms poster');
    }
    return HomePosterCuration(
      id: id,
      assetPath: json['assetPath']?.toString() ?? '',
      imageUrl: json['imageUrl']?.toString(),
      posterTitle: json['posterTitle']?.toString() ?? '',
      subtitle: json['subtitle']?.toString() ?? '',
      pageTitle: json['pageTitle']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      eyebrow: json['eyebrow']?.toString() ?? '요리고 큐레이션',
      chips: chips,
      poolSectionKeys: strList(json['poolSectionKeys']),
      tips: tips,
      tipsSectionTitle: json['tipsSectionTitle']?.toString(),
      products: products,
      productsSectionTitle:
          json['productsSectionTitle']?.toString() ?? '추천 상품',
      recipeSectionTitle: json['recipeSectionTitle']?.toString() ?? '레시피 고르기',
      showFridgeCta: json['showFridgeCta'] == true,
      fridgeCtaLabel: json['fridgeCtaLabel']?.toString(),
      strictKeywordMatch: json['strictKeywordMatch'] == true,
      imageAlignment: homeCmsAlignment(json['imageAlignment']?.toString()),
    );
  }
}

class HomePosterCurations {
  HomePosterCurations._();

  static const List<String> _lowSugarAllKeywords = [
    '알룰로스',
    '저당',
    '무설탕',
    '제로슈거',
    '제로 슈거',
    '마이노멀',
    '설탕없이',
    '설탕 없이',
    '당질오프',
    '저칼로리',
  ];

  static const List<HomePosterCuration> all = [
    // ── 1. 여름 시원한 메뉴 ───────────────────────────────────────
    // 레시피는 일회성 스크립트(analytics/build_poster_static_indexes.py)가
    // 만든 home_section_index/poster_summer_* 만 사용 (클라 키워드 재필터 없음).
    HomePosterCuration(
      id: 'first_main_for_two',
      assetPath: 'assets/images/home_poster_1.png',
      posterTitle: '더위야,\n물러가라',
      subtitle: '더운 날 둘이 먹기 좋은 시원한 메뉴',
      eyebrow: '여름 메뉴 큐레이션',
      pageTitle: '더위야, 물러가라',
      body: '불 앞에 오래 서지 않아도 괜찮아요.\n더위를 식혀 줄 시원한 메뉴만 골랐어요.',
      chips: [
        HomePosterChip(
          label: '전체',
          sectionKey: 'poster_summer_all',
        ),
        HomePosterChip(
          label: '냉면·밀면',
          sectionKey: 'poster_summer_cold_noodle',
        ),
        HomePosterChip(
          label: '국수·소바',
          sectionKey: 'poster_summer_guksu',
        ),
        HomePosterChip(
          label: '냉국·묵',
          sectionKey: 'poster_summer_cold_soup',
        ),
        HomePosterChip(
          label: '냉채·샐러드',
          sectionKey: 'poster_summer_salad',
        ),
      ],
    ),

    // ── 2. 마이노멀 저당 저녁 ─────────────────────────────────────
    HomePosterCuration(
      id: 'mynormal_low_sugar',
      assetPath: 'assets/images/home_poster_2.png',
      posterTitle: '설탕은 빼고,\n맛은 그대로',
      subtitle: '마이노멀로 완성하는 저당 저녁',
      eyebrow: '마이노멀 저당 큐레이션',
      pageTitle: '설탕은 빼고, 맛은 그대로',
      body:
          '마이노멀은 저당 식품을 만드는 브랜드예요.\n'
          '아래에서 가장 잘 나가는 베스트 제품을 먼저 보고, '
          '그다음 어울리는 저당 레시피를 골라보세요.',
      poolSectionKeys: ['ingredients_5', 'quick_10min', 'moment_dinner'],
      strictKeywordMatch: true,
      productsSectionTitle: '마이노멀 베스트',
      recipeSectionTitle: '저당 레시피 고르기',
      tips: [
        HomePosterTip(
          title: '알룰로스가 뭔가요?',
          body: '설탕과 비슷한 단맛이지만 칼로리·혈당 부담이 적은 대체당이에요. '
              '마이노멀 알룰로스(분말·대용량)로 양념·디저트에 바로 쓸 수 있어요.',
          icon: Icons.science_outlined,
        ),
        HomePosterTip(
          title: '마이노멀로 바꾸는 법',
          body: '평소 쓰는 마요네즈·잼·고추장·땅콩버터만 마이노멀로 바꿔도 '
              '저녁 한 상이 훨씬 가벼워져요.',
          icon: Icons.swap_horiz_rounded,
        ),
        HomePosterTip(
          title: '저당 저녁 팁',
          body: '단맛이 필요한 소스·드레싱·디저트에만 쓰고, '
              '짠맛·감칠맛은 간장·마늘로 잡으면 실패가 줄어요. '
              '처음부터 전부 바꾸지 말고, 오늘 한 가지만 바꿔 보세요.',
          icon: Icons.restaurant_outlined,
        ),
      ],
      // BrandConnect 랜딩(2026-09-01): naver.me 대신 affiliates URL.
      // CMS 번들이 naver.me를 줘도 클릭 시 redirect를 풀어 동일 랜딩으로 연다.
      products: [
        HomePosterProduct(
          id: 'mn_mayo',
          name: '엑스트라버진 올리브오일 마요네즈',
          subtitle: '260g · 샐러드·샌드위치에 바로',
          badge: '마요네즈',
          priceLabel: '10,900원',
          imageUrl:
              'https://shop-phinf.pstatic.net/20260121_257/1768973950609ouoXs_JPEG/96008292651474770_326431765.jpg',
          productUrl:
              'https://brandconnect.naver.com/affiliates/982169532354240?channelProductNo=5865138229',
          searchQuery: '마이노멀 올리브오일 마요네즈',
        ),
        HomePosterProduct(
          id: 'mn_dressing',
          name: '저당 유자 드레싱',
          subtitle: '샐러드용 저당 소스',
          badge: '드레싱',
          priceLabel: '7,980원',
          imageUrl:
              'https://shop-phinf.pstatic.net/20241113_67/1731459529295r9Np8_JPEG/16416114346796182_1574435118.jpg',
          productUrl:
              'https://brandconnect.naver.com/affiliates/982170359852704?channelProductNo=11126506309',
          searchQuery: '마이노멀 저당 드레싱',
        ),
        HomePosterProduct(
          id: 'mn_peanut_butter',
          name: '무가당 땅콩버터 100%',
          subtitle: '크런치·크리미 선택',
          badge: '땅콩버터',
          priceLabel: '11,900원',
          imageUrl:
              'https://shop-phinf.pstatic.net/20260123_248/17691465198310Lclx_JPEG/98508137355100628_669714175.jpg',
          productUrl:
              'https://brandconnect.naver.com/affiliates/982171017219456?channelProductNo=11437982470',
          searchQuery: '마이노멀 무가당 땅콩버터',
        ),
        HomePosterProduct(
          id: 'mn_strawberry_jam',
          name: '저당 저칼로리 딸기잼 320g',
          subtitle: '토스트·요거트용 베스트',
          badge: '딸기잼',
          priceLabel: '12,900원',
          imageUrl:
              'https://shop-phinf.pstatic.net/20230202_74/1675327151659RIn30_JPEG/76462935375317573_16105138.jpg',
          productUrl:
              'https://brandconnect.naver.com/affiliates/982169712737952?channelProductNo=8017030753',
          searchQuery: '마이노멀 저당 딸기잼',
        ),
        HomePosterProduct(
          id: 'mn_allulose_907',
          name: '대용량 알룰로스 1.2kg',
          subtitle: '설탕 대신 쓰는 대용량',
          badge: '알룰로스',
          priceLabel: '15,800원',
          imageUrl:
              'https://shop-phinf.pstatic.net/20250723_26/1753261731153R55Ji_PNG/16506502958274265_1674444752.png',
          productUrl:
              'https://brandconnect.naver.com/affiliates/982169764941664?channelProductNo=12144877070',
          searchQuery: '마이노멀 알룰로스 1.2kg',
        ),
        HomePosterProduct(
          id: 'mn_choco_ball',
          name: '알룰로스 다크 초코볼 아몬드',
          subtitle: '1박스 저당 간식',
          badge: '간식',
          priceLabel: '13,900원',
          imageUrl:
              'https://shop-phinf.pstatic.net/20250212_70/17393269554309ilAW_PNG/580310508758859_194431172.png',
          productUrl:
              'https://brandconnect.naver.com/affiliates/982170574131456?channelProductNo=9902026260',
          searchQuery: '마이노멀 다크초코볼 아몬드',
        ),
        HomePosterProduct(
          id: 'mn_allulose_500',
          name: '알룰로스 500g',
          subtitle: '소스·양념용 기본 사이즈',
          badge: '알룰로스',
          priceLabel: '8,900원',
          imageUrl:
              'https://shop-phinf.pstatic.net/20260119_42/1768802351028jY8sp_JPEG/102935116116486702_279542202.jpg',
          productUrl:
              'https://brandconnect.naver.com/affiliates/982169875415168?channelProductNo=4768208316',
          searchQuery: '마이노멀 알룰로스 500g',
        ),
        HomePosterProduct(
          id: 'mn_allulose_powder',
          name: '알룰로스 분말 350g',
          subtitle: '베이킹·계량에 편한 분말형',
          badge: '알룰로스',
          priceLabel: '9,800원',
          imageUrl:
              'https://shop-phinf.pstatic.net/20220216_207/1645005934610u84Wg_JPEG/46141718319502985_300817403.jpg',
          productUrl:
              'https://brandconnect.naver.com/affiliates/982169926356448?channelProductNo=6100073221',
          searchQuery: '마이노멀 가루 알룰로스',
        ),
        HomePosterProduct(
          id: 'mn_peanut_stick',
          name: '무가당 땅콩버터 스틱',
          subtitle: '휴대용 20g×10개',
          badge: '땅콩버터',
          priceLabel: '9,900원',
          imageUrl:
              'https://shop-phinf.pstatic.net/20250919_157/1758272672090zQita_JPEG/19055535188992216_1894129923.jpg',
          productUrl:
              'https://brandconnect.naver.com/affiliates/982169983824032?channelProductNo=12422703808',
          searchQuery: '마이노멀 땅콩버터 스틱',
        ),
        HomePosterProduct(
          id: 'mn_gochujang',
          name: '국산 저당 태양초 고추장',
          subtitle: '230g · 볶음·비빔용',
          badge: '고추장',
          priceLabel: '12,900원',
          imageUrl:
              'https://shop-phinf.pstatic.net/20241112_279/1731374434612foMbR_JPEG/62096963489895494_1725665745.jpg',
          productUrl:
              'https://brandconnect.naver.com/affiliates/982170628628704?channelProductNo=10337537172',
          searchQuery: '마이노멀 저당 고추장',
        ),
      ],
      chips: [
        HomePosterChip(
          label: '전체',
          matchKeywords: _lowSugarAllKeywords,
        ),
        HomePosterChip(
          label: '알룰로스',
          matchKeywords: ['알룰로스', 'allulose', '저당', '무설탕', '제로슈거'],
        ),
        HomePosterChip(
          label: '마요네즈',
          matchKeywords: [
            '마요',
            '마요네즈',
            '감자샐러드',
            '에그샐러드',
            '튜나샐러드',
            '콜슬로',
            '샌드위치',
            '샐러드',
          ],
        ),
        HomePosterChip(
          label: '드레싱',
          matchKeywords: [
            '드레싱',
            '샐러드',
            '오리엔탈',
            '시저',
            '유자',
            '흑임자',
            '참깨',
          ],
        ),
        HomePosterChip(
          label: '고추장',
          matchKeywords: [
            '고추장',
            '제육',
            '비빔밥',
            '비빔면',
            '닭볶음',
            '떡볶이',
            '고추장볶음',
            '고추장찌개',
          ],
        ),
        HomePosterChip(
          label: '땅콩버터',
          matchKeywords: [
            '땅콩버터',
            '피넛버터',
            '땅콩',
            '피넛',
            '토스트',
            '스무디',
          ],
        ),
        HomePosterChip(
          label: '딸기잼',
          matchKeywords: [
            '딸기잼',
            '잼',
            '토스트',
            '팬케이크',
            '와플',
            '요거트',
            '딸기',
          ],
        ),
        HomePosterChip(
          label: '간식',
          matchKeywords: [
            '초콜릿',
            '초코',
            '아몬드',
            '쿠키',
            '에너지볼',
            '저당',
            '무설탕',
            '디저트',
          ],
        ),
      ],
    ),

    // ── 3. 초보 쉬운 저녁 ─────────────────────────────────────────
    HomePosterCuration(
      id: 'newlywed_kitchen_starter',
      assetPath: 'assets/images/home_poster_3.png',
      posterTitle: '서툴러도 괜찮아,\n오늘도 한 그릇 완성',
      subtitle: '요리가 처음인 우리를 위한 쉬운 저녁',
      eyebrow: '초보 키친 가이드',
      pageTitle: '서툴러도 괜찮아, 오늘도 한 그릇 완성',
      body: '완벽한 요리보다, 오늘 한 그릇이면 충분해요.\n실패 적은 쉬운 저녁만 골랐어요.',
      poolSectionKeys: [],
      tips: [
        HomePosterTip(
          title: '재료는 5개 안쪽',
          body: '재료가 적을수록 실패도 줄어요. '
              '장보기 전에 집에 있는 것부터 세어보고, '
              '오늘 쓸 재료만 꺼내 두면 훨씬 편해져요.',
          icon: Icons.shopping_basket_outlined,
        ),
        HomePosterTip(
          title: '팬 하나만 쓰기',
          body: '볶음·구이·계란 요리까지. '
              '중형 프라이팬 하나면 대부분 집밥이 가능하니, '
              '오늘은 그 하나로만 끝내 보세요.',
          icon: Icons.soup_kitchen_outlined,
        ),
        HomePosterTip(
          title: '양념은 계량부터',
          body: '눈대중보다 스푼 계량이 더 안전해요. '
              '간장·기름·고춧가루 비율만 맞춰도 '
              '초보도 맛이 훨씬 안정돼요.',
          icon: Icons.scale_outlined,
        ),
      ],
      recipeSectionTitle: '쉬운 저녁 고르기',
      // 10분·한그릇은 정적 poster_* 인덱스. 전체/재료적게/계란은 기존 섹션(+필요 시 키워드).
      chips: [
        HomePosterChip(
          label: '전체',
          sectionKey: 'poster_beginner_10min',
        ),
        HomePosterChip(
          label: '10분',
          sectionKey: 'poster_beginner_10min',
        ),
        HomePosterChip(
          label: '재료 적게',
          sectionKey: 'ingredients_5',
        ),
        HomePosterChip(
          label: '한 그릇',
          sectionKey: 'poster_beginner_one_bowl',
        ),
        HomePosterChip(
          label: '계란부터',
          sectionKey: 'quick_10min',
          matchKeywords: [
            '계란',
            '달걀',
            '스크램블',
            '오므라이스',
            '계란말이',
            '계란볶음밥',
            '프라이',
          ],
        ),
      ],
    ),
  ];

  static HomePosterCuration? byId(String id) {
    final resolved =
        id == 'fridge_three_ingredients' ? 'mynormal_low_sugar' : id;
    for (final c in all) {
      if (c.id == resolved) return c;
    }
    return null;
  }

  /// 캐러셀에 넣을 아이템 (탭 → 큐레이션 화면).
  static List<HomePosterItem> carouselItems(BuildContext context) {
    return carouselItemsFor(context, all);
  }

  static List<HomePosterItem> carouselItemsFor(
    BuildContext context,
    List<HomePosterCuration> curations, {
    String? cmsUpdatedAt,
  }) {
    return [
      for (var i = 0; i < curations.length; i++)
        HomePosterItem(
          id: curations[i].id,
          assetPath: curations[i].assetPath,
          imageUrl: curations[i].imageUrl,
          title: curations[i].posterTitle,
          subtitle: curations[i].subtitle,
          imageAlignment: curations[i].imageAlignment,
          onTap: () => openCuration(
            context,
            curations[i],
            position: i,
            cmsUpdatedAt: cmsUpdatedAt,
          ),
        ),
    ];
  }

  /// 포스터 더블탭으로 라우트가 두 장 쌓이는 것만 막는다.
  /// 글로벌 [NavGuard] 는 쓰지 않는다 — await push 는 내부 레시피 탭을 막고,
  /// unawaited + 즉시 해제는 더블오픈 윈도우가 생긴다.
  static DateTime? _openCooldownUntil;
  static const Duration openCooldown = Duration(milliseconds: 700);

  /// 쿨다운을 소비할 수 있으면 true. 테스트에서도 동일 로직을 검증한다.
  static bool tryConsumeOpenCooldown({DateTime? now}) {
    final t = now ?? DateTime.now();
    if (_openCooldownUntil != null && t.isBefore(_openCooldownUntil!)) {
      return false;
    }
    _openCooldownUntil = t.add(openCooldown);
    return true;
  }

  static void open(BuildContext context, String curationId) {
    final curation = byId(curationId);
    if (curation == null) return;
    openCuration(context, curation);
  }

  static void openCuration(
    BuildContext context,
    HomePosterCuration curation, {
    int? position,
    String? cmsUpdatedAt,
  }) {
    if (!context.mounted) return;
    if (!tryConsumeOpenCooldown()) return;
    unawaited(
      AnalyticsService().trackHomePosterEvent(
        eventType: 'click',
        posterId: curation.id,
        posterTitle: curation.posterTitle,
        position: position,
        cmsUpdatedAt: cmsUpdatedAt,
      ),
    );
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => HomePosterCurationScreen(curation: curation),
        ),
      ),
    );
  }

  /// 테스트용 쿨다운 초기화.
  static void debugResetOpenCooldown() {
    _openCooldownUntil = null;
  }
}
