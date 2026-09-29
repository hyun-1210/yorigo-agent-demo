import 'package:cloud_firestore/cloud_firestore.dart';
import 'api_service.dart';

// 단위 정의 (UNIT_STEPS) - 카테고리별 검색 단위
const Map<String, List<String>> UNIT_STEPS = {
  "GRAIN": ["500g", "1kg", "4kg", "10kg", "20kg"],
  "POWDER_SEASONING": ["100g", "200g", "500g", "1kg"],
  "NOODLE": ["500g", "1kg", "3kg", "5kg"],
  "VEG_WEIGHT": ["200g", "500g", "1kg", "2kg", "1박스"],
  "VEG_COUNT": ["1개", "3개", "5개", "10개", "1kg", "3kg"],
  "MEAT": ["300g", "600g", "1kg", "2kg"],
  "SEAFOOD": ["1kg", "3kg", "5개", "10개", "15개"],
  "LIQUID": ["250ml", "500ml", "900ml", "1.8L"],
  "PROCESSED_COUNT": ["1개", "3개", "1팩", "3팩", "1박스"],
  "EGG": ["10구", "15구", "30구", "60구"],
};

// 접두사 정의 (PREFIXES) - 카테고리별 검색 접두사
const Map<String, List<String>> PREFIXES = {
  "GRAIN": ["", "국산 ", "국내산 ", "유기농 ", "혼합 ", "세척 "],
  "POWDER_SEASONING": ["", "국산 ", "국내산 ", "무첨가 ", "대용량 "],
  "NOODLE": ["", "국산 ", "국내산 ", "유기농 "],
  "VEG_WEIGHT": ["", "국산 ", "국내산 ", "유기농 ", "손질 ", "세척 ", "대용량 "],
  "VEG_COUNT": ["", "국산 ", "국내산 ", "유기농 ", "손질 ", "세척 "],
  "MEAT": ["", "국산 ", "국내산 ", "수입 ", "냉동 ", "고급"],
  "SEAFOOD": ["", "국산 ", "국내산 ", "냉동 ", "손질 "],
  "LIQUID": ["", "국산 ", "국내산 "],
  "PROCESSED_COUNT": ["", "국산", "국내산"],
  "EGG": ["", "무항생제 ", "특란 ", "대란 "],
};

// 식재료 매핑 (INGREDIENT_MAPPING) - 재료명을 카테고리로 매핑
const Map<String, String> INGREDIENT_MAPPING = {
  // GRAIN (곡물 및 대용량 가루)
  "쌀": "GRAIN",
  "현미": "GRAIN",
  "밀가루": "GRAIN",
  "찹쌀": "GRAIN",
  "잡곡": "GRAIN",
  "오트밀": "GRAIN",
  
  // POWDER_SEASONING (조미료 및 소량 가루)
  "고추장": "POWDER_SEASONING",
  "된장": "POWDER_SEASONING",
  "쌈장": "POWDER_SEASONING",
  "설탕": "POWDER_SEASONING",
  "소금": "POWDER_SEASONING",
  "고춧가루": "POWDER_SEASONING",
  "후추": "POWDER_SEASONING",
  "다시다": "POWDER_SEASONING",
  "미원": "POWDER_SEASONING",
  "통깨": "POWDER_SEASONING",
  "파슬리": "POWDER_SEASONING",
  "카레가루": "POWDER_SEASONING",
  "전분": "POWDER_SEASONING",
  "빵가루": "POWDER_SEASONING",
  "계피가루": "POWDER_SEASONING",
  "이스트": "POWDER_SEASONING",
  "베이킹파우더": "POWDER_SEASONING",
  "코코아파우더": "POWDER_SEASONING",
  
  // NOODLE (면류)
  "소면": "NOODLE",
  "파스타면": "NOODLE",
  "당면": "NOODLE",
  "칼국수면": "NOODLE",
  "메밀면": "NOODLE",
  "쫄면": "NOODLE",
  "우동면": "NOODLE",
  
  // VEG_WEIGHT (중량 단위 채소 - 잎/뿌리)
  "대파": "VEG_WEIGHT",
  "다진 마늘": "VEG_WEIGHT",
  "마늘": "VEG_WEIGHT",
  "당근": "VEG_WEIGHT",
  "콩나물": "VEG_WEIGHT",
  "숙주": "VEG_WEIGHT",
  "시금치": "VEG_WEIGHT",
  "깻잎": "VEG_WEIGHT",
  "상추": "VEG_WEIGHT",
  "양파": "VEG_WEIGHT",
  "배추": "VEG_WEIGHT",
  "무": "VEG_WEIGHT",
  "감자": "VEG_WEIGHT",
  "양배추": "VEG_WEIGHT",
  "고구마": "VEG_WEIGHT",
  "연근": "VEG_WEIGHT",
  "우엉": "VEG_WEIGHT",
  "미나리": "VEG_WEIGHT",
  "부추": "VEG_WEIGHT",
  "쪽파": "VEG_WEIGHT",
  "청경채": "VEG_WEIGHT",
  "미역": "VEG_WEIGHT",
  "다시마": "VEG_WEIGHT",
  "생강": "VEG_WEIGHT",
  "바질": "VEG_WEIGHT",
  "로즈마리": "VEG_WEIGHT",
  "월계수잎": "VEG_WEIGHT",
  "봄동": "VEG_WEIGHT",
  
  // VEG_COUNT (개수 단위 채소 - 과채류)
  "애호박": "VEG_COUNT",
  "오이": "VEG_COUNT",
  "가지": "VEG_COUNT",
  "파프리카": "VEG_COUNT",
  "아보카도": "VEG_COUNT",
  "브로콜리": "VEG_COUNT",
  "단호박": "VEG_COUNT",
  "레몬": "VEG_COUNT",
  "토마토": "VEG_COUNT",
  "방울토마토": "VEG_COUNT",
  "팽이버섯": "VEG_COUNT",
  "표고버섯": "VEG_COUNT",
  "새송이버섯": "VEG_COUNT",
  "청양고추": "VEG_COUNT",
  "버섯": "VEG_COUNT",
  
  // MEAT (육류)
  "돼지고기 삼겹살": "MEAT",
  "돼지고기 목살": "MEAT",
  "돼지고기 앞다리살": "MEAT",
  "소고기 국거리": "MEAT",
  "소고기 구이용": "MEAT",
  "닭고기": "MEAT",
  "닭가슴살": "MEAT",
  "베이컨": "MEAT",
  
  // SEAFOOD (수산물)
  "고등어": "SEAFOOD",
  "갈치": "SEAFOOD",
  "오징어": "SEAFOOD",
  "낙지": "SEAFOOD",
  "쭈꾸미": "SEAFOOD",
  "꽃게": "SEAFOOD",
  "냉동새우": "SEAFOOD",
  "새우": "SEAFOOD",
  "바지락": "SEAFOOD",
  "홍합": "SEAFOOD",
  "전복": "SEAFOOD",
  "굴": "SEAFOOD",
  "멸치": "SEAFOOD",
  "명란젓": "SEAFOOD",
  
  // LIQUID (액체류)
  "진간장": "LIQUID",
  "국간장": "LIQUID",
  "식용유": "LIQUID",
  "참기름": "LIQUID",
  "올리브유": "LIQUID",
  "식초": "LIQUID",
  "맛술": "LIQUID",
  "케첩": "LIQUID",
  "마요네즈": "LIQUID",
  "우유": "LIQUID",
  "굴소스": "LIQUID",
  "액젓": "LIQUID",
  "올리고당": "LIQUID",
  "매실청": "LIQUID",
  "새우젓": "LIQUID",
  "생크림": "LIQUID",
  "휘핑크림": "LIQUID",
  "요거트": "LIQUID",
  "돈가스소스": "LIQUID",
  "데리야끼소스": "LIQUID",
  "칠리소스": "LIQUID",
  "머스터드": "LIQUID",
  "땅콩버터": "LIQUID",
  "바닐라익스트랙": "LIQUID",
  "마라소스": "LIQUID",
  "두반장": "LIQUID",
  "춘장": "LIQUID",
  "와사비": "LIQUID",
  
  // PROCESSED_COUNT (가공식품/개수)
  "두부": "PROCESSED_COUNT",
  "치즈": "PROCESSED_COUNT",
  "모짜렐라": "PROCESSED_COUNT",
  "체다": "PROCESSED_COUNT",
  "버터": "PROCESSED_COUNT",
  "김": "PROCESSED_COUNT",
  "참치캔": "PROCESSED_COUNT",
  "스팸": "PROCESSED_COUNT",
  "라면": "PROCESSED_COUNT",
  "냉동만두": "PROCESSED_COUNT",
  "어묵": "PROCESSED_COUNT",
  "비엔나소시지": "PROCESSED_COUNT",
  "프랑크소시지": "PROCESSED_COUNT",
  "맛살": "PROCESSED_COUNT",
  "베이크드빈": "PROCESSED_COUNT",
  "옥수수콘": "PROCESSED_COUNT",
  "순대": "PROCESSED_COUNT",
  "쌈무": "PROCESSED_COUNT",
  "김치": "PROCESSED_COUNT",
  "라이스페이퍼": "PROCESSED_COUNT",
  "시리얼": "PROCESSED_COUNT",
  "떡국떡": "PROCESSED_COUNT",
  "떡볶이떡": "PROCESSED_COUNT",
  "초콜릿": "PROCESSED_COUNT",
  
  // EGG (계란)
  "달걀": "EGG",
  "계란": "EGG",
};

class IngredientPriceService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // In-memory price cache to avoid redundant Firestore reads within same session
  static final Map<String, _CachedPrice> _priceCache = {};
  static const _cacheTtl = Duration(minutes: 30);

  /// g/ml/개 등 정량 단위가 있는 재료만 가격 요청 대상.
  /// qty가 없거나, unit이 비어있거나, 단위를 파싱할 수 없으면 false.
  static bool canRequestPrice(double? qty, String? unit) {
    if (qty == null || qty <= 0) return false;
    final u = unit?.trim() ?? '';
    if (u.isEmpty) return false;
    final s = '$qty$u';
    final regex = RegExp(
      r'(\d+(?:\.\d+)?)\s*(g|kg|ml|L|리터|그램|킬로그램|밀리리터|개|구|묶음|박스|봉지|팩|큰술|한\s*큰술|작은술|티스푼|tsp|tbsp|스푼|숟가락)',
      caseSensitive: false,
    );
    final match = regex.firstMatch(s);
    if (match == null) return false;
    final value = double.tryParse(match.group(1) ?? '0') ?? 0;
    return value > 0;
  }

  /// 재료 가격 조회 (Firebase의 평균 단위 가격 사용)
  /// 
  /// [ingredientName] 재료 이름 (예: "감자")
  /// [neededQty] 필요량 (예: 300.0)
  /// [neededUnit] 필요 단위 (예: "g")
  /// 
  /// Returns: 계산된 가격 (원 단위), 없으면 null
  Future<int?> getIngredientPrice(
    String ingredientName,
    double neededQty,
    String neededUnit,
  ) async {
    // Check in-memory cache first
    final cacheKey = '$ingredientName|$neededQty|$neededUnit';
    final cached = _priceCache[cacheKey];
    if (cached != null && !cached.isExpired) {
      return cached.price;
    }

    print('[IngredientPrice] 시작: 재료명="$ingredientName", 필요량=$neededQty$neededUnit');
    int? result;
    try {
      // 1) 요청 단위(baseUnitKey)별 문서가 있으면 우선 사용
      final docId = _sanitizeIngredientDocId(ingredientName);
      final unitKey = _normalizeBaseUnitKey(neededUnit);
      if (unitKey.isNotEmpty) {
        print('[IngredientPrice] 🔍 요청 단위 키($unitKey) 기반 조회 시도...');
        final unitDoc = await _firestore
            .collection('ingredient_unit_prices')
            .doc(docId)
            .collection('units')
            .doc(unitKey)
            .get();

        if (unitDoc.exists && unitDoc.data() != null) {
          final unitPrice = (unitDoc.data()!['unitPrice'] as num?)?.toDouble();
          if (unitPrice != null) {
            result = (unitPrice * neededQty).round();
            print('[IngredientPrice] ✅ unitPrice 찾음: $unitPrice원/$unitKey × $neededQty = $result원');
            _priceCache[cacheKey] = _CachedPrice(result);
            return result;
          }
        }
      }

      // 2) 기존 스키마(ingredient_unit_prices/{ingredient}) 폴백
      print('[IngredientPrice] 🔍 Firebase에서 기존 평균 단위 가격 조회 중...');
      final priceDoc = await _firestore
          .collection('ingredient_unit_prices')
          .doc(docId)
          .get();

      if (!priceDoc.exists || priceDoc.data() == null) {
        print('[IngredientPrice] ❌ 가격 데이터 없음: "$ingredientName"');
        if (unitKey.isEmpty) {
          _priceCache[cacheKey] = _CachedPrice(null);
          return null;
        }
        print('[IngredientPrice] 🧠 기본 문서가 없어도 요청 단위 가격을 on-demand로 요청합니다...');
        final requestedUnitPrice = await ApiService.requestIngredientUnitPrice(
          ingredientName: ingredientName,
          requestedBaseUnit: unitKey,
        );
        if (requestedUnitPrice == null) {
          _priceCache[cacheKey] = _CachedPrice(null);
          return null;
        }
        result = (requestedUnitPrice * neededQty).round();
        print('[IngredientPrice] ✅ on-demand 가격 적용: $requestedUnitPrice원/$unitKey × $neededQty = $result원');
        _priceCache[cacheKey] = _CachedPrice(result);
        return result;
      }

      final priceData = priceDoc.data()!;
      final unitPrice = (priceData['unitPrice'] as num?)?.toDouble();
      final baseUnit = priceData['baseUnit'] as String?;

      if (unitPrice == null || baseUnit == null) {
        print('[IngredientPrice] ❌ 가격 데이터 형식 오류');
        if (unitKey.isEmpty) {
          _priceCache[cacheKey] = _CachedPrice(null);
          return null;
        }
        print('[IngredientPrice] 🧠 가격 데이터 형식 오류 → 요청 단위 가격 on-demand 재시도...');
        final requestedUnitPrice = await ApiService.requestIngredientUnitPrice(
          ingredientName: ingredientName,
          requestedBaseUnit: unitKey,
        );
        if (requestedUnitPrice == null) {
          _priceCache[cacheKey] = _CachedPrice(null);
          return null;
        }
        result = (requestedUnitPrice * neededQty).round();
        print('[IngredientPrice] ✅ on-demand 가격 적용: $requestedUnitPrice원/$unitKey × $neededQty = $result원');
        _priceCache[cacheKey] = _CachedPrice(result);
        return result;
      }

      print('[IngredientPrice] ✅ 평균 단위 가격: $unitPrice원/$baseUnit');

      // 요구 단위와 저장된 단위가 같으면 그대로 사용
      final neededUnitLower = neededUnit.toLowerCase().trim();
      final baseUnitLower = baseUnit.toLowerCase().trim();

      double? finalQty;

      if (neededUnitLower == baseUnitLower ||
          (neededUnitLower == 'g' && baseUnitLower == '그램') ||
          (neededUnitLower == 'ml' && baseUnitLower == '밀리리터') ||
          (neededUnitLower == '개' && baseUnitLower == '개')) {
        finalQty = neededQty;
        print('[IngredientPrice] 단위 일치: $neededQty$neededUnit = $neededQty$baseUnit');
      } else {
        finalQty = _convertUnit(neededQty, neededUnit, baseUnit);
        if (finalQty == null) {
          print('[IngredientPrice] ❌ 단위 변환 실패: $neededQty$neededUnit → $baseUnit');
          finalQty = null;
        } else {
          print('[IngredientPrice] 단위 변환: $neededQty$neededUnit → $finalQty$baseUnit');
        }
      }

      if (finalQty != null) {
        result = (unitPrice * finalQty).round();
        print('[IngredientPrice] ✅ 최종 가격: $unitPrice원/$baseUnit × $finalQty$baseUnit = $result원');
        _priceCache[cacheKey] = _CachedPrice(result);
        return result;
      }

      // 3) 여기까지 오면: 요청 단위 문서가 없고, 기존 변환 로직으로도 계산 불가
      if (unitKey.isEmpty) {
        _priceCache[cacheKey] = _CachedPrice(null);
        return null;
      }

      print('[IngredientPrice] 🧠 요청 단위 가격이 없어 백엔드에 on-demand 요청...');
      final requestedUnitPrice = await ApiService.requestIngredientUnitPrice(
        ingredientName: ingredientName,
        requestedBaseUnit: unitKey,
      );
      if (requestedUnitPrice == null) {
        print('[IngredientPrice] ❌ 백엔드 요청 실패/응답 없음');
        _priceCache[cacheKey] = _CachedPrice(null);
        return null;
      }

      result = (requestedUnitPrice * neededQty).round();
      print('[IngredientPrice] ✅ on-demand 가격 적용: $requestedUnitPrice원/$unitKey × $neededQty = $result원');
      _priceCache[cacheKey] = _CachedPrice(result);
      return result;
      
    } catch (e, stackTrace) {
      print('[IngredientPrice] ❌ 예외 발생: $e');
      print('[IngredientPrice] 스택 트레이스: $stackTrace');
      _priceCache[cacheKey] = _CachedPrice(null);
      return null;
    }
  }

  /// 단위 변환 (요구 단위 → 저장된 단위)
  /// 예: g → ml, ml → g, 개 → g, g → 개 등
  double? _convertUnit(double qty, String fromUnit, String toUnit) {
    final fromLower = fromUnit.toLowerCase().trim();
    final toLower = toUnit.toLowerCase().trim();
    
    // g ↔ ml (1g = 1ml 가정)
    if ((fromLower == 'g' || fromLower == '그램') && 
        (toLower == 'ml' || toLower == '밀리리터')) {
      return qty;
    }
    if ((fromLower == 'ml' || fromLower == '밀리리터') && 
        (toLower == 'g' || toLower == '그램')) {
      return qty;
    }
    
    // kg → g
    if ((fromLower == 'kg' || fromLower == '킬로그램') && 
        (toLower == 'g' || toLower == '그램')) {
      return qty * 1000;
    }
    
    // g → kg
    if ((fromLower == 'g' || fromLower == '그램') && 
        (toLower == 'kg' || toLower == '킬로그램')) {
      return qty / 1000;
    }
    
    // L → ml
    if ((fromLower == 'l' || fromLower == '리터') && 
        (toLower == 'ml' || toLower == '밀리리터')) {
      return qty * 1000;
    }
    
    // ml → L
    if ((fromLower == 'ml' || fromLower == '밀리리터') && 
        (toLower == 'l' || toLower == '리터')) {
      return qty / 1000;
    }
    
    // 개수 단위 변환은 복잡하므로 null 반환 (변환 불가)
    // 개 → g, g → 개 등은 가정 중량이 필요하므로 변환하지 않음
    if (fromLower == '개' || toLower == '개') {
      return null;
    }
    
    return null;
  }

  /// Firestore 문서 ID에 사용할 수 있도록 재료명에서 '/'를 '_'로 치환.
  /// Firestore는 '/'를 경로 구분자로 해석하므로 그대로 쓰면
  /// 'A document must have an even number of path elements' 에러가 발생합니다.
  String _sanitizeIngredientDocId(String name) => name.replaceAll('/', '_');

  /// Firestore doc id로 쓰기 위한 단위 키 정규화
  /// - g <-> 그램
  /// - ml <-> 밀리리터
  /// - 개 <-> 구
  /// 나머지는 공백을 '_'로 치환하고 소문자 처리합니다.
  String _normalizeBaseUnitKey(String unit) {
    final s0 = unit.trim();
    if (s0.isEmpty) return '';
    final lower = s0.toLowerCase();

    String mapped;
    if (lower == '그램' || lower == 'g') {
      mapped = 'g';
    } else if (lower == '밀리리터' || lower == 'ml') {
      mapped = 'ml';
    } else if (lower == '구' || lower == '개') {
      mapped = '개';
    } else {
      mapped = s0;
    }

    final safe = mapped
        .replaceAll('/', '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .trim();

    return safe.toLowerCase();
  }
}

class _CachedPrice {
  final int? price;
  final DateTime cachedAt;
  _CachedPrice(this.price) : cachedAt = DateTime.now();
  bool get isExpired =>
      DateTime.now().difference(cachedAt) > IngredientPriceService._cacheTtl;
}
