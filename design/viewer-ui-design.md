# teams-record 로컬 뷰어 UI 디자인 스펙

> 작성: 2026-07-08 KST
> 출처: KnoxTeams 실제 화면 스크린샷(사용자 제공). 로컬 뷰어(방식 1)의 UI 레퍼런스.
> 대상 데이터: 평문 스냅샷 `teams-decrypted.db`(SQLite, 키 불필요). 회사PC 로컬 전용.

## 자산(assets/)

| 파일 | 내용 | 크기 |
|------|------|------|
| `assets/01-conversations-1on1-list.png` | 1:1 대화(Conversations) 좌측 목록 | 372x310 |
| `assets/02-workspace-channel-tree.png` | 워크스페이스-채널 트리 | 369x292 |
| `assets/03-message-emoji-reactions.png` | 메시지 이모지 반응 바(리액션 픽커) | 266x48 |

## 화면 구성 개요

뷰어는 상단에 두 개의 탭을 둔다.

- 탭 A: **워크스페이스-채널** (`02-workspace-channel-tree.png`)
- 탭 B: **1:1 대화** (`01-conversations-1on1-list.png`)

각 탭은 좌측 목록 + 우측 메시지 영역(2-pane) 레이아웃. 좌측에서 항목 선택 시 우측에 해당 대화의 메시지가 SentTime 오름차순으로 표시된다.

## 화면 A — 1:1 대화 (Conversations)

레퍼런스: `assets/01-conversations-1on1-list.png`

- 헤더: 좌측 타이틀 "대화", 우측에 북마크 아이콘 / + 아이콘 / 필터 아이콘.
- 서브 탭 행: "전체 / 읽지 않음 / 즐겨찾기" (현재 뷰어는 "전체"만 필수, 나머지는 후속).
- 목록 행(각 대화방 1행):
  - 좌측: 원형 아바타(그룹은 다인 아이콘, 1:1은 개인). 아바타 이미지가 없으면 이니셜/기본 아이콘.
  - 상단 줄: 상대/방 이름 + (즐겨찾기면 별표 뱃지). 예: "고필성 ★".
  - 하단 줄: 마지막 메시지 미리보기(1줄 말줄임).
  - 우측: 마지막 메시지 시각. 당일이면 HH:MM, 이전이면 MM-DD.
- 데이터 소스: TB_KmMessage + TB_Chatroom(Title) + TB_KmContact(LocalName). 방 정렬은 마지막 SentTime 내림차순.

## 화면 B — 워크스페이스-채널 (Workspace)

레퍼런스: `assets/02-workspace-channel-tree.png`

- 헤더: 좌측 타이틀 "워크스페이스", 우측에 북마크 아이콘 / + 아이콘.
- 서브 탭 행: "전체 / 읽지 않음 / 즐겨찾기".
- 뷰 토글: 그리드/리스트 보기 아이콘(현재 뷰어는 리스트만 필수).
- 트리 구조(2단계, 접기/펼치기):
  - 1단계: 워크스페이스 행. 좌측에 사각형 색상 뱃지(2글자 이니셜, 예: 녹색 "GW") + 워크스페이스명. 예: "GW GPU Workstation 지원".
  - 2단계: 하위 채널 목록. 예: "우리은행(Dell7960)", "Supermicro", "DGX Spark", "General(All)". 일부 채널은 "All" 뱃지.
- 데이터 소스: TB_KtMessage + TB_Channel(Title) + TB_Workspace + TB_KtContact(LocalName). 좌측 트리 Workspace→Channel, 우측 메시지 SentTime 오름차순.

## 메시지 이모지 반응 (필수 요구사항)

레퍼런스: `assets/03-message-emoji-reactions.png`

사용자가 개별 메시지에 이모지 반응을 붙일 수 있고, 이를 뷰어에서 제대로 표현해야 한다.

### 저장 위치 — 별도 테이블이 아니라 메시지 행의 컬럼

- 반응은 **메시지 행의 `ReactionInfo TEXT` 컬럼**에 인라인 저장된다. TB_KtMessage(채널)·TB_KmMessage(DM) 둘 다 이 컬럼 보유.
- 스티커/이모티콘 카탈로그는 별도로 TB_Emoticon(EmoticonId, EmoticonGroupId, Name, FileName, DownloadUrl) + TB_EmoticonGroup 에 존재. 단, 아래 ReactionInfo 의 `emoji` 정수코드는 이 스티커 카탈로그가 아니라 **퀵 리액션 이모지 세트**를 가리킨다(별개 매핑).

### ReactionInfo JSON 포맷 (실측)

```json
[
  {"emoji": 1, "count": 31, "users": "754107854600802305,913717628344209409,...", "isMine": false},
  {"emoji": 3, "count": 18, "users": "754107857199173633,...", "isMine": false}
]
```

- `emoji`: 반응 이모지 정수 코드. 실측 관측값 1, 3, 7, 8 등(최소 8종). 리액션 바 스크린샷의 좌→우 순서가 1-based 코드 순서일 가능성이 높다(빌드 시 확정 필요).
- `count`: 해당 이모지 반응 수.
- `users`: 반응한 사용자 UserID 콤마 구분 문자열. UserID → TB_KtContact/TB_KmContact.LocalName 으로 이름 매핑.
- `isMine`: 본인(754107854600802305) 반응 포함 여부.
- non-empty 표본: TB_KtMessage 76행, TB_KmMessage 30행(2026-07-08 스냅샷 기준).

### 렌더링 요구사항

- 각 메시지 하단에 반응 칩(chip)들을 표시: [이모지 글리프] [count]. 예: 👍 31.
- 칩 hover/클릭 시 반응자 이름 목록(LocalName) 노출.
- 본인이 누른 반응(isMine=true)은 강조 스타일.
- `emoji` 정수 → 글리프 매핑 테이블은 빌드 시 확정한다. 방법: 리액션 바 스크린샷 순서 대조 + 라이브 앱에서 특정 메시지 반응 육안 확인 + (필요 시) KnoxTeams 리소스 확인. 매핑 미확정 항목은 `#N` 폴백 표기.

## 공통 표시 규칙(데이터 매핑, teams-record-next.md 와 일관)

- 발신자명 = Sender → TB_KtContact/TB_KmContact.LocalName. 본인 UserID=754107854600802305 → '나' 표기·우측 정렬.
- SentTime = epoch ms → KST. 목록은 당일 HH:MM / 이전 MM-DD, 메시지 상세는 전체 일시.
- Content 의 `<!-- {"COMMAND":...} -->` 명령 프리픽스는 제거 후 표시.
- Recalled=1 / Deleted=1 행은 '(회수/삭제됨)' 뱃지.
- MessageType=0=텍스트. 기타 타입(파일/이미지/시스템)은 타입 라벨 우선(첨부 렌더는 후속).

## 참고

- 뷰어 서버는 127.0.0.1 바인딩 전용(외부 노출 금지). 회사PC 로컬·본인 계정·본인 대화 한정.
- teams-decrypted.db 는 실제 대화 본문이므로 절대 커밋 금지(.gitignore *.db).
