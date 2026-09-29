# `app_feedback` 컬렉션 (인앱 피드백)

설정 → **의견 보내기** 시트에서 전송할 때 `CloudFirestore`의 **`app_feedback`** 컬렉션에 문서가 추가됩니다.

구현: `lib/widgets/profile_feedback_sheet.dart` 의 `_submit()`.

## 필드 스키마

| 필드 | 타입 | 필수 | 설명 |
|------|------|------|------|
| `createdAt` | `Timestamp` | 예 | `FieldValue.serverTimestamp()` |
| `userId` | `string` | 예 | 현재 로그인 사용자 UID (`FirebaseAuth.instance.currentUser.uid`) |
| `categories` | `array<string>` | 예 | 선택한 카테고리 칩 라벨 (1개 이상). 예: `["레시피 기능", "UI · 디자인"]` |
| `detail` | `string` | 예 | 상세 의견. 클라이언트에서 최대 300자 제한 |
| `liked` | `string` | 예 | 👍 좋았던 점 (없으면 빈 문자열) |
| `disliked` | `string` | 예 | 👎 아쉬웠던 점 (없으면 빈 문자열) |
| `platform` | `string` | 예 | `defaultTargetPlatform.name` (예: `android`, `iOS`) |

## 예시 문서

아래는 콘솔/에뮬레이터에서 참고용 예시입니다. 실제 `createdAt`·`userId`는 앱이 채웁니다.

```json
{
  "createdAt": "<서버 Timestamp>",
  "userId": "firebaseUidExample123",
  "categories": ["앱 전반", "속도 · 성능"],
  "detail": "앱이 전반적으로 빠르게 느껴졌어요.",
  "liked": "레시피 카드 디자인",
  "disliked": "",
  "platform": "android"
}
```

## 보안 규칙

`firestore.rules` 에서 다음을 적용합니다.

- **create**: 로그인 사용자만, `userId` 가 본인 UID와 일치할 때만 허용. 필드 키는 위 스키마만 허용.
- **read / list**: 관리자(`isAdminUser()`)만.
- **update / delete**: 불가 (관리자가 필요하면 Admin SDK 또는 규칙 확장).

규칙 배포: Firebase CLI 또는 콘솔에서 `firestore.rules` 배포 후 반영됩니다.

## 운영 시 참고

- 피드백 조회·대시보드는 Firestore 콘솔에서 `app_feedback` 컬렉션을 조회하거나, 관리자 앱에서 Admin SDK로 조회하면 됩니다.
- 카카오/메일 문의는 이 컬렉션이 아니라 외부 링크·`mailto` 로 처리됩니다.
