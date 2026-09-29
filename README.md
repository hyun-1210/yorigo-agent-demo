# 요리고 (Yorigo) 🍳

**AI-Powered Recipe Management & Smart Shopping for Korean Home Cooking**

Yorigo transforms YouTube cooking videos into actionable recipes and helps you shop smarter by optimizing ingredient purchases and minimizing food waste.

---

## 🎯 Key Features

### 📹 AI Recipe Extraction
- **Parse any YouTube cooking video** into structured recipes
- **Smart content filter** detects and rejects non-cooking videos early (saves processing time & cost)
- Combines **speech recognition (Whisper ASR)** + **optical character recognition (EasyOCR)** + **GPT-4**
- Automatically extracts ingredients, quantities, steps, and nutritional information

### 🛒 Smart Shopping Cart
- **Intelligent ingredient aggregation** across multiple recipes
- **Optimal product search** via Coupang API to minimize food waste and cost
- Categorized shopping lists (protein, vegetables, grains, seasonings)
- Real-time price comparison and per-serving cost calculation

### 🤖 Personalized Recommendations
- **Q-Learning based recommendation system** that learns your preferences
- Suggests recipes that **reuse leftover ingredients** to reduce waste
- Calculates potential savings from adding recommended recipes
- Adapts to your cooking habits and taste profile over time

### 📅 Meal Planning
- Visual calendar for planning weekly meals
- Track servings and cooking days
- Sync shopping lists with planned meals
- One-tap deletion of meals and associated ingredients

---

## 🛠️ Tech Stack

### Frontend
- **Flutter (Dart)** - Cross-platform mobile & web app
- **Firebase Auth** - User authentication
- **Firebase Firestore** - Real-time database
- **Device Frame** - Mobile viewport simulation for web demo

### Backend
- **FastAPI (Python)** - High-performance REST API
- **yt-dlp** - Video content extraction
- **Whisper (faster-whisper)** - Speech-to-text transcription
- **EasyOCR** - On-screen text extraction
- **OpenAI GPT-4** - Recipe structuring and categorization
- **FFmpeg** - Video frame extraction for OCR

### AI & Machine Learning
- **Q-Learning** - Reinforcement learning for recipe recommendations
- **Multi-modal pipeline** - Audio (ASR) + Visual (OCR) + Language (LLM)
- **Epsilon-greedy exploration** - Balances personalization with discovery

### Infrastructure
- **Railway** - Backend hosting with Docker
- **Firebase Hosting** - Frontend web deployment
- **Coupang Partners API** - E-commerce product search

---

## 🚀 Value Propositions

1. **Save Time** - No more manual recipe transcription from videos
2. **Save Money** - Optimize purchases to reduce food waste and cost
3. **Reduce Waste** - Smart recommendations for leftover ingredients
4. **Personalized** - Learns your preferences to suggest recipes you'll love
5. **Convenient** - From video → recipe → shopping → cooking, all in one app

---

## 📱 Platform Support

- ✅ **iOS** (iPhone, iPad)
- ✅ **Android** (Phone, Tablet)
- ✅ **Web** (Desktop, Mobile browsers)

---

## 🎓 How It Works

### Recipe Parsing Pipeline
```
YouTube Video → Video Metadata Extraction
              ↓
         Content Filter (LLM) → Is Cooking Video?
              ↓                      ↓
         [YES Continue]         [NO Reject]
              ↓
         Audio + Video Extraction
              ↓
         ASR (Whisper) → Transcript
              ↓
         OCR (EasyOCR) → On-screen Text
              ↓
         LLM (GPT-4) → Structured Recipe
              ↓
         Nutrition Estimation
```

### Recommendation System
```
User Cart + Preferences → State Representation
              ↓
         Q-Learning Agent
              ↓
         Recipe Selection (ε-greedy)
              ↓
         User Feedback → Q-Table Update
```

---

## 🌟 Demo

**Web App**: [yorigo-f7408.web.app](https://yorigo-f7408.web.app)

**Backend API**: [yorigo-production.up.railway.app](https://yorigo-production.up.railway.app)

---

## 🔐 Flutter 키 주입 & 배포 명령

카카오 키는 하드코딩하지 않고 `yorigo-frontend/dart_define.local.json`에서 주입합니다.

- 로컬 키 파일: `yorigo-frontend/dart_define.local.json`
- 예시 템플릿(커밋됨): `yorigo-frontend/dart_define.example.json`
- git 추적 제외: `yorigo-frontend/.gitignore`

### 새 개발자 초기 설정

`yorigo-frontend`에서 1회 실행:

- `.\tool\init_local_keys.ps1`

그 다음 생성된 `dart_define.local.json`에서 placeholder를 실제 키로 교체하세요.

### Windows (PowerShell)

`yorigo-frontend`에서 아래 중 필요한 것만 실행하면 됩니다.

- Android 실행: `.\tool\run_android_with_keys.ps1`
- Chrome 실행(모바일 뷰): `.\tool\run_chrome_galaxy_s26.ps1`
- Android AAB 릴리즈(Play 업로드용): `.\tool\build_android_aab_release_with_keys.ps1`
- Android APK 릴리즈(직접 설치 테스트용): `.\tool\build_android_apk_release_with_keys.ps1`
- Web 릴리즈 빌드: `.\tool\build_web_release_with_keys.ps1`

### macOS (iOS 배포용)

`yorigo-frontend`에서:

- iOS 실행(시뮬레이터/기기): `bash ./tool/run_ios_with_keys.sh`
- iOS IPA 릴리즈: `bash ./tool/build_ios_ipa_release_with_keys.sh`
- iOS IPA (공유 dart_defines): `bash ./tool/build_ipa_release_dart_defines.sh`

> `USE_MACMINI_PARSING=true` — 파싱은 `parse.yorigo.kr`(맥미니), 그 외 API는 Railway/AWS.
> Android와 동일. Xcode Archive만 하면 dart-define이 빠질 수 있으므로 위 스크립트 사용 권장.
>
> 카카오: `Info.plist` URL 스킴(`kakao<NativeAppKey>`)과 `dart_define.local.json`의
> `KAKAO_NATIVE_APP_KEY`가 일치해야 로그인 콜백이 동작합니다.

---

## 📄 License

© 2025 Yorigo. All rights reserved.

---

## 👥 Team

Built with ❤️ by the Yorigo team for Korean home cooks who want to simplify meal planning and reduce food waste.

