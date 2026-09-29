# 프록시 적용 시 코드 수정 가이드 (TikTok / Instagram)

프록시를 적용할 때 **어디를 어떻게 수정하면 되는지**만 설명합니다. (실제 코드 삽입은 하지 않음.)

---

## 1. 환경 변수 설계

- **TikTok 전용**: `TIKTOK_PROXY_URL`  
  - 예: `http://user:pass@residential.example.com:8080` 또는 `https://...`
- **Instagram 전용** (선택): `INSTAGRAM_PROXY_URL`
- **둘 다 같은 프록시**를 쓸 경우: `SOCIAL_PROXY_URL` 하나만 두고, TikTok/Instagram 구분 없이 이걸 쓰게 할 수 있음.

프록시 URL은 **HTTP/HTTPS 통신에 그대로 쓰이는 문자열** 하나면 됨. (curl_cffi, yt-dlp 모두 단일 URL 지원.)

---

## 2. 프록시 값 읽기 / 공통 유틸

- **위치**: `youtube_service.py` 상단 또는 작은 `utils` 모듈.
- **역할**:
  - `os.getenv("TIKTOK_PROXY_URL")` 또는 `os.getenv("SOCIAL_PROXY_URL")` 로 문자열 읽기.
  - 값이 있으면 그대로 사용, 없으면 `None`.
- **curl_cffi에 넘길 형태**:
  - `proxies = {"http": proxy_url, "https": proxy_url}` (문자열 하나로 둘 다 채움).
- **yt-dlp에 넘길 형태**:
  - `ydl_opts["proxy"] = proxy_url` (문자열 그대로).

함수로 두면 재사용하기 좋음. 예: `get_tiktok_proxy_url() -> Optional[str]`, `get_instagram_proxy_url() -> Optional[str]`, 또는 `get_social_proxy_for(platform: str)`.

---

## 3. 수정할 파일·위치별 설명

### 3.1 `services/tiktok_service.py`

**역할**: 틱톡 페이지/리다이렉트 요청을 **curl_cffi**로 보냄.

- **수정 1 – `_resolve_url`**
  - `cf_requests.get(url, impersonate="chrome", ...)` 호출부.
  - 여기에 **`proxies=...`** 인자 추가.
  - 값: 위에서 만든 `get_tiktok_proxy_url()`(또는 SOCIAL)이 있으면 `{"http": url, "https": url}`, 없으면 넘기지 않거나 `None`.

- **수정 2 – `extract_info` 안의 페이지 GET**
  - `cf_requests.get(resolved_url, impersonate="chrome", headers=..., ...)` 호출부.
  - 동일하게 **`proxies=...`** 추가.

**정리**: TikTokService는 **HTTP 요청이 나가는 두 군데**에만 프록시를 넣으면 됨. 생성자에서 `proxy_url: Optional[str] = None` 받고, 인스턴스 변수로 들고 있다가 각 `get` 호출 시 `proxies`에 넣어도 됨.

---

### 3.2 `services/youtube_service.py`

여기서는 **세 가지** 경로에 프록시를 넣어야 함.

#### A) yt-dlp를 쓰는 모든 곳 (메타 추출 + 다운로드)

- **위치**:
  - **get_streaming_info**: `ydl_opts`를 만든 뒤, `is_tiktok` 또는 `is_instagram`일 때 `ydl_opts["proxy"] = get_tiktok_proxy_url() or get_instagram_proxy_url()` (또는 SOCIAL 하나).
  - **download_audio**:
    - 루프 **밖**에서 틱톡/인스타 전용으로 쓰는 `ydl_info_opts`로 `extract_info` 호출하는 블록 → 그 `ydl_info_opts`에 `proxy` 설정.
    - 루프 **안**에서 만드는 `ydl_opts` → 틱톡/인스타일 때만 `ydl_opts["proxy"] = ...` 추가.
  - **비디오 다운로드** 쪽 (예: `download_video` 또는 프레임 추출 전 `extract_info`): 동일하게 `ydl_opts` / `ydl_info_opts`에 `proxy` 설정.

- **규칙**: “이번 요청이 TikTok이면 TikTok 프록시, Instagram이면 Instagram 프록시, 둘 다 같은 SOCIAL_PROXY_URL이면 그걸 쓴다”고 한 번 정해 두고, 해당 플랫폼일 때만 `ydl_opts["proxy"]`를 세팅하면 됨.

#### B) `_download_audio_from_direct_url`

- **위치**: 인스턴스 메서드 `_download_audio_from_direct_url(self, direct_video_url, outdir, referer=...)` 안의 **`cf_requests.get(direct_video_url, ...)`**.
- **수정**: 이 메서드가 **TikTok/Instagram 전용**으로 쓰이므로, 호출하는 쪽에서 “지금 플랫폼이 TikTok인지 Instagram인지” 알 수 있음.  
  - 방법 1: 인자로 `proxy_url: Optional[str] = None` 추가 → 호출부(`download_audio` 등)에서 `get_tiktok_proxy_url()` 또는 `get_instagram_proxy_url()` 넘김.  
  - 방법 2: 메서드 안에서 `get_tiktok_proxy_url()`와 `get_instagram_proxy_url()`를 둘 다 확인해서 하나라도 있으면 사용 (또는 SOCIAL 하나만 써도 됨).
- **적용**: `cf_requests.get(..., proxies={"http": proxy_url, "https": proxy_url})` 형태로 추가. `proxy_url`이 있을 때만.

#### C) `_extract_frames_from_direct_url`

- **위치**: 같은 파일 안의 **`cf_requests.get(direct_video_url, ...)`** (비디오 다운로드 후 프레임 추출용).
- **수정**: `_download_audio_from_direct_url`와 동일한 방식으로 **`proxies=...`** 추가.  
  - direct URL이 TikTok/Instagram CDN이므로, 같은 SOCIAL/TikTok/Instagram 프록시 URL을 쓰면 됨.

---

### 3.3 Instagram 전용 HTTP 요청이 있는 경우

- **파일**: `services/instagram_service.py`
- **내용**: 만약 여기서 **instaloader가 아닌** `requests`나 `cf_requests.get` 등으로 직접 HTTP 요청을 보내는 부분이 있다면, 그 호출에도 **동일하게 `proxies=...`** 추가.
- Instaloader만 쓰고 있다면, Instaloader 쪽에서 프록시 설정을 지원하는지 문서를 보고, 지원하면 세션/컨텍스트 생성 시 proxy 옵션을 넘기는 방식으로 적용하면 됨.

---

## 4. 적용 순서 요약

| 대상 | 파일 | 수정 내용 |
|------|------|-----------|
| 프록시 URL 읽기 | `youtube_service` 또는 유틸 | env에서 `TIKTOK_PROXY_URL` / `INSTAGRAM_PROXY_URL` / `SOCIAL_PROXY_URL` 읽는 함수 또는 변수 |
| 틱톡 페이지 요청 | `tiktok_service.py` | `_resolve_url`, `extract_info` 내부 `cf_requests.get` 두 곳에 `proxies=` 추가 |
| 틱톡/인스타 메타·다운로드 | `youtube_service.py` | `get_streaming_info`의 `ydl_opts`, `download_audio`의 `ydl_info_opts`·`ydl_opts`, 비디오 쪽 `ydl_opts`에 `proxy` 설정 |
| 직접 URL 다운로드 | `youtube_service.py` | `_download_audio_from_direct_url`, `_extract_frames_from_direct_url`의 `cf_requests.get`에 `proxies=` 추가 |
| 인스타 직접 요청 | `instagram_service.py` | 있다면 `requests`/`cf_requests` 호출에 `proxies=` 추가; instaloader는 해당 옵션 있으면 설정 |

---

## 5. 주의사항

- **YouTube**에는 프록시를 넣지 않아도 됨 (기존 쿠키 풀만 사용). TikTok/Instagram일 때만 프록시를 쓰도록 분기.
- 프록시 URL이 **비어 있거나 None**이면 `proxies`/`proxy`를 아예 넘기지 않아야 함. (빈 문자열을 넘기면 오동작할 수 있음.)
- **타임아웃**: 프록시 경유 시 지연이 커질 수 있으므로, 필요하면 `timeout`을 25→40초처럼 약간만 늘려도 됨.

이렇게 적용하면 “TikTok/Instagram만 Residential(또는 공용) 프록시를 타고, 나머지(YouTube 등)는 기존처럼 동작”하는 구조로 맞출 수 있습니다.
