import 'dart:math';

/// Result of a username suggestion: Korean display name + English userId.
class UsernameSuggestion {
  const UsernameSuggestion({
    required this.displayName,
    required this.userId,
  });

  final String displayName;
  final String userId;

  @override
  String toString() => 'UsernameSuggestion(displayName: $displayName, userId: $userId)';
}

/// Vocabulary and mappings for username suggestions.
/// Korean: cute adjective + food/ingredient noun.
/// English: clean, app-friendly handle (lowercase, underscore allowed).
class UsernameSuggestionVocabulary {
  UsernameSuggestionVocabulary._();

  /// Korean adjectives (귀여운, 맛있는, etc.)
  static const List<String> koreanAdjectives = [
    '귀여운',
    '맛있는',
    '따뜻한',
    '상큼한',
    '달콤한',
    '쿨한',
    '포근한',
    '알딸딸한',
    '빛나는',
    '즐거운',
    '푸짐한',
    '새콤한',
    '고소한',
    '부드러운',
    '쫀득한',
    '사랑스러운',
    '반짝이는',
    '행복한',
    '바삭한',
    '촉촉한',
    '화사한',
    '향긋한',
    '담백한',
    '진한',
    '싱싱한',
    '따스한',
    '산뜻한',
    '깔끔한',
    '풍성한',
    '쿰쿰한',
  ];

  /// Korean food/ingredient nouns
  static const List<String> koreanNouns = [
    '감자',
    '당근',
    '양파',
    '버섯',
    '치즈',
    '토마토',
    '바질',
    '올리브',
    '파스타',
    '마늘',
    '베이컨',
    '계란',
    '브로콜리',
    '아보카도',
    '파프리카',
    '고구마',
    '콩',
    '옥수수',
    '호박',
    '시금치',
    '김치',
    '두부',
    '라면',
    '우유',
    '커피',
    '참깨',
    '땅콩',
    '밤',
    '사과',
    '바나나',
    '딸기',
    '수박',
    '포도',
    '레몬',
    '쌀',
    '피망',
    '크림',
    '꿀',
    '초콜릿',
    '빵',
    '닭',
    '새우',
  ];

  /// English handle parts: [adjective, noun] matching index of Korean pairs.
  static const List<Map<String, String>> englishPairs = [
    {'adj': 'cute', 'noun': 'potato'},
    {'adj': 'tasty', 'noun': 'carrot'},
    {'adj': 'warm', 'noun': 'onion'},
    {'adj': 'fresh', 'noun': 'mushroom'},
    {'adj': 'sweet', 'noun': 'cheese'},
    {'adj': 'cool', 'noun': 'tomato'},
    {'adj': 'cozy', 'noun': 'basil'},
    {'adj': 'bouncy', 'noun': 'olive'},
    {'adj': 'happy', 'noun': 'pasta'},
    {'adj': 'garlic', 'noun': 'lover'},
    {'adj': 'crispy', 'noun': 'bacon'},
    {'adj': 'fluffy', 'noun': 'egg'},
    {'adj': 'green', 'noun': 'broccoli'},
    {'adj': 'creamy', 'noun': 'avocado'},
    {'adj': 'sunny', 'noun': 'pepper'},
    {'adj': 'golden', 'noun': 'sweet_potato'},
    {'adj': 'bean', 'noun': 'lover'},
    {'adj': 'buttery', 'noun': 'corn'},
    {'adj': 'squash', 'noun': 'lover'},
    {'adj': 'leafy', 'noun': 'spinach'},
  ];

  /// Get English pair for Korean index (adjective + noun).
  static String englishHandleForIndex(int adjIdx, int nounIdx) {
    final adj = koreanAdjectives[adjIdx.clamp(0, koreanAdjectives.length - 1)];
    final noun = koreanNouns[nounIdx.clamp(0, koreanNouns.length - 1)];
    final adjE = _koreanToEnglishAdj[adj] ?? 'cute';
    final nounE = _koreanToEnglishNoun[noun] ?? 'potato';
    return '${adjE}_$nounE';
  }

  static const Map<String, String> _koreanToEnglishAdj = {
    '귀여운': 'cute',
    '맛있는': 'tasty',
    '따뜻한': 'warm',
    '상큼한': 'fresh',
    '달콤한': 'sweet',
    '쿨한': 'cool',
    '포근한': 'cozy',
    '알딸딸한': 'bouncy',
    '빛나는': 'shiny',
    '즐거운': 'happy',
    '푸짐한': 'hearty',
    '새콤한': 'tangy',
    '고소한': 'nutty',
    '부드러운': 'soft',
    '쫀득한': 'chewy',
    '사랑스러운': 'lovely',
    '반짝이는': 'sparkly',
    '행복한': 'joyful',
    '바삭한': 'crunchy',
    '촉촉한': 'moist',
    '화사한': 'bright',
    '향긋한': 'aromatic',
    '담백한': 'mild',
    '진한': 'rich',
    '싱싱한': 'crisp',
    '따스한': 'toasty',
    '산뜻한': 'zesty',
    '깔끔한': 'clean',
    '풍성한': 'plentiful',
    '쿰쿰한': 'savory',
  };

  static const Map<String, String> _koreanToEnglishNoun = {
    '감자': 'potato',
    '당근': 'carrot',
    '양파': 'onion',
    '버섯': 'mushroom',
    '치즈': 'cheese',
    '토마토': 'tomato',
    '바질': 'basil',
    '올리브': 'olive',
    '파스타': 'pasta',
    '마늘': 'garlic',
    '베이컨': 'bacon',
    '계란': 'egg',
    '브로콜리': 'broccoli',
    '아보카도': 'avocado',
    '파프리카': 'pepper',
    '고구마': 'sweet_potato',
    '콩': 'bean',
    '옥수수': 'corn',
    '호박': 'pumpkin',
    '시금치': 'spinach',
    '김치': 'kimchi',
    '두부': 'tofu',
    '라면': 'ramen',
    '우유': 'milk',
    '커피': 'coffee',
    '참깨': 'sesame',
    '땅콩': 'peanut',
    '밤': 'chestnut',
    '사과': 'apple',
    '바나나': 'banana',
    '딸기': 'strawberry',
    '수박': 'watermelon',
    '포도': 'grape',
    '레몬': 'lemon',
    '쌀': 'rice',
    '피망': 'bell_pepper',
    '크림': 'cream',
    '꿀': 'honey',
    '초콜릿': 'chocolate',
    '빵': 'bread',
    '닭': 'chicken',
    '새우': 'shrimp',
  };
}

/// Generates username suggestions: Korean displayName + English userId.
/// Format: adjective+noun (no space) + random 3-digit number.
/// Tracks used combos to avoid repeats in the same session.
class UsernameSuggestionGenerator {
  UsernameSuggestionGenerator({this.random}) : _random = random ?? Random();

  final Random? random;
  final Random _random;

  /// Used combo keys "adjIdx_nounIdx_num" to avoid overlaps
  final Set<String> _usedCombos = {};

  static const int _numbersPerPair = 1000; // 000-999

  /// Total possible combinations (pairs × 3-digit numbers)
  static int get totalCombinations =>
      UsernameSuggestionVocabulary.koreanAdjectives.length *
      UsernameSuggestionVocabulary.koreanNouns.length *
      _numbersPerPair;

  /// Total possible pairs (before adding numbers)
  static int get totalPairs =>
      UsernameSuggestionVocabulary.koreanAdjectives.length *
      UsernameSuggestionVocabulary.koreanNouns.length;

  /// Generate a new suggestion. Avoids duplicates within session.
  UsernameSuggestion generate() {
    final adjCount = UsernameSuggestionVocabulary.koreanAdjectives.length;
    final nounCount = UsernameSuggestionVocabulary.koreanNouns.length;

    if (_usedCombos.length >= totalCombinations) {
      _usedCombos.clear();
    }

    String comboKey;
    int adjIdx;
    int nounIdx;
    int num;

    int attempts = 0;
    do {
      adjIdx = _random.nextInt(adjCount);
      nounIdx = _random.nextInt(nounCount);
      num = _random.nextInt(_numbersPerPair); // 0-999
      comboKey = '${adjIdx}_${nounIdx}_$num';
      attempts++;
      if (attempts > 500) break;
    } while (_usedCombos.contains(comboKey));

    _usedCombos.add(comboKey);

    final adjK = UsernameSuggestionVocabulary.koreanAdjectives[adjIdx];
    final nounK = UsernameSuggestionVocabulary.koreanNouns[nounIdx];
    final numStr = num.toString().padLeft(3, '0');
    final displayName = '$adjK$nounK$numStr';
    final userId = _buildUserId(adjIdx, nounIdx, numStr);

    return UsernameSuggestion(displayName: displayName, userId: userId);
  }

  String _buildUserId(int adjIdx, int nounIdx, String numStr) {
    final adj = UsernameSuggestionVocabulary.koreanAdjectives[adjIdx];
    final noun = UsernameSuggestionVocabulary.koreanNouns[nounIdx];
    final adjE = UsernameSuggestionVocabulary._koreanToEnglishAdj[adj] ?? 'cute';
    final nounE = UsernameSuggestionVocabulary._koreanToEnglishNoun[noun] ?? 'potato';
    return normalizeUserId('${adjE}_$nounE$numStr');
  }

  /// Normalize userId: lowercase, underscores allowed, 3-24 chars, must start with letter.
  static String normalizeUserId(String raw) {
    String s = raw
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');

    if (s.isEmpty) s = 'cute_potato';
    if (!RegExp(r'^[a-z]').hasMatch(s)) s = 'u_$s';
    if (s.length < 3) s = s.padRight(3, '0');
    if (s.length > 24) s = s.substring(0, 24);

    return s;
  }

  /// Validate userId format: 3-24 chars, starts with letter, [a-z0-9_]
  static bool isValidUserId(String userId) {
    if (userId.isEmpty) return false;
    if (userId.length < 3 || userId.length > 24) return false;
    if (!RegExp(r'^[a-z]').hasMatch(userId)) return false;
    return RegExp(r'^[a-z0-9_]+$').hasMatch(userId);
  }

  /// Reset used combos (e.g. when starting new session)
  void resetSession() {
    _usedCombos.clear();
  }
}
