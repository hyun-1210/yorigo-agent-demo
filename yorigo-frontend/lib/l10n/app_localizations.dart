import 'package:flutter/material.dart';

class AppLocalizations {
  final Locale locale;

  AppLocalizations(this.locale);

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  static final Map<String, Map<String, String>> _localizedValues = {
    'ko': {
      // App Name
      'appName': '요리고',

      // Navigation
      'home': '홈',
      'recipes': '레시피',
      'feed': '피드',
      'cart': '장바구니',
      'settings': '설정',

      // Auth
      'login': '로그인',
      'logout': '로그아웃',
      'signup': '계정 만들기',
      'continueUsing': '계속 이용하기',
      'joinYorigo': 'Join 요리고',
      'joinDescription': '레시피를 저장하고 장바구니에 담아보세요',

      // Login
      'email': '이메일',
      'password': '비밀번호',
      'rememberMe': '로그인 정보 기억하기',
      'emailPlaceholder': 'your@email.com',
      'passwordPlaceholder': '••••••••',

      // Signup
      'name': '성함',
      'confirmPassword': '비밀번호 확인',
      'namePlaceholder': 'Your name',
      'alreadyHaveAccount': '계정이 이미 있으신가요? ',
      'loginHere': '로그인하기',

      // Settings
      'user': '사용자',
      'language': '언어',
      'logoutConfirm': '정말 로그아웃 하시겠습니까?',
      'cancel': '취소',
      'logoutError': '로그아웃 중 오류가 발생했습니다: {error}',

      // Home
      'enterYouTubeUrl': '유튜브 URL을 입력해주세요',
      'youtubeUrlPlaceholder': '유튜브 또는 인스타그램 영상 링크',
      'analyze': '레시피 분석하기',
      'analyzing': '분석중...',
      'recipeTitle': '레시피 영상 제목',
      'recipeDescription': '레시피 설명이 여기에 표시됩니다.',
      'recipeDescriptionLabel': '레시피 설명:',
      'savedRecipe': '저장된 레시피:',
      'homeSubtitle': '유튜브 쇼츠 요리 영상을 공유하고\n재료·조리법을 자동으로 분석하세요',

      // Auth Messages
      'loginSuccess': '로그인되었습니다!',
      'signupSuccess': '계정이 생성되었습니다!',
      'emailPasswordRequired': '이메일과 비밀번호를 입력해주세요.',
      'allFieldsRequired': '모든 필드를 입력해주세요.',
      'passwordMismatch': '비밀번호가 일치하지 않습니다.',
      'passwordTooShort': '비밀번호는 최소 6자 이상이어야 합니다.',

      // Common
      'loading': '로딩 중...',
      'error': '오류',
      'success': '성공',
    },
    'en': {
      // App Name
      'appName': 'Yorigo',

      // Navigation
      'home': 'Home',
      'recipes': 'Recipes',
      'feed': 'Feed',
      'cart': 'Cart',
      'settings': 'Settings',

      // Auth
      'login': 'Login',
      'logout': 'Logout',
      'signup': 'Create Account',
      'continueUsing': 'Continue Using',
      'joinYorigo': 'Join Yorigo',
      'joinDescription': 'Save recipes and add them to your cart',

      // Login
      'email': 'Email',
      'password': 'Password',
      'rememberMe': 'Remember me',
      'emailPlaceholder': 'your@email.com',
      'passwordPlaceholder': '••••••••',

      // Signup
      'name': 'Name',
      'confirmPassword': 'Confirm Password',
      'namePlaceholder': 'Your name',
      'alreadyHaveAccount': 'Already have an account? ',
      'loginHere': 'Login',

      // Settings
      'user': 'User',
      'language': 'Language',
      'logoutConfirm': 'Are you sure you want to logout?',
      'cancel': 'Cancel',
      'logoutError': 'An error occurred during logout: {error}',

      // Home
      'enterYouTubeUrl': 'Please enter a YouTube URL',
      'youtubeUrlPlaceholder': 'YouTube or Instagram video link',
      'analyze': 'Analyze Recipe',
      'analyzing': 'Analyzing...',
      'recipeTitle': 'Recipe Video Title',
      'recipeDescription': 'Recipe description will be displayed here.',
      'recipeDescriptionLabel': 'Recipe Description:',
      'savedRecipe': 'Saved Recipe:',
      'homeSubtitle':
          'Share YouTube Shorts cooking videos\nand automatically analyze ingredients and methods',

      // Auth Messages
      'loginSuccess': 'Logged in successfully!',
      'signupSuccess': 'Account created successfully!',
      'emailPasswordRequired': 'Please enter email and password.',
      'allFieldsRequired': 'Please fill in all fields.',
      'passwordMismatch': 'Passwords do not match.',
      'passwordTooShort': 'Password must be at least 6 characters.',

      // Common
      'loading': 'Loading...',
      'error': 'Error',
      'success': 'Success',
    },
  };

  String translate(String key, {Map<String, String>? params}) {
    String? value = _localizedValues[locale.languageCode]?[key];
    value ??= _localizedValues['en']?[key] ?? key;

    // At this point, value is guaranteed to be non-null (either from locale or fallback)
    String result = value;

    // Replace parameters
    if (params != null) {
      params.forEach((paramKey, paramValue) {
        result = result.replaceAll('{$paramKey}', paramValue);
      });
    }

    return result;
  }

  // Convenience getters
  String get appName => translate('appName');
  String get home => translate('home');
  String get recipes => translate('recipes');
  String get feed => translate('feed');
  String get cart => translate('cart');
  String get settings => translate('settings');
  String get login => translate('login');
  String get logout => translate('logout');
  String get signup => translate('signup');
  String get continueUsing => translate('continueUsing');
  String get joinYorigo => translate('joinYorigo');
  String get joinDescription => translate('joinDescription');
  String get email => translate('email');
  String get password => translate('password');
  String get rememberMe => translate('rememberMe');
  String get emailPlaceholder => translate('emailPlaceholder');
  String get passwordPlaceholder => translate('passwordPlaceholder');
  String get name => translate('name');
  String get confirmPassword => translate('confirmPassword');
  String get namePlaceholder => translate('namePlaceholder');
  String get alreadyHaveAccount => translate('alreadyHaveAccount');
  String get loginHere => translate('loginHere');
  String get user => translate('user');
  String get language => translate('language');
  String get logoutConfirm => translate('logoutConfirm');
  String get cancel => translate('cancel');
  String get enterYouTubeUrl => translate('enterYouTubeUrl');
  String get youtubeUrlPlaceholder => translate('youtubeUrlPlaceholder');
  String get analyze => translate('analyze');
  String get analyzing => translate('analyzing');
  String get recipeTitle => translate('recipeTitle');
  String get recipeDescription => translate('recipeDescription');
  String get recipeDescriptionLabel => translate('recipeDescriptionLabel');
  String get savedRecipe => translate('savedRecipe');
  String get homeSubtitle => translate('homeSubtitle');
  String get loading => translate('loading');
  String get error => translate('error');
  String get success => translate('success');
  String get loginSuccess => translate('loginSuccess');
  String get signupSuccess => translate('signupSuccess');
  String get emailPasswordRequired => translate('emailPasswordRequired');
  String get allFieldsRequired => translate('allFieldsRequired');
  String get passwordMismatch => translate('passwordMismatch');
  String get passwordTooShort => translate('passwordTooShort');

  String logoutError(String error) =>
      translate('logoutError', params: {'error': error});
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => ['ko', 'en'].contains(locale.languageCode);

  @override
  Future<AppLocalizations> load(Locale locale) async {
    return AppLocalizations(locale);
  }

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
