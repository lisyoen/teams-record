# teams-record local viewer

KnoxTeams 평문 스냅샷(`teams-decrypted.db`)을 로컬에서 열람하는 단일 파일 웹 뷰어(MVP).

## 실행 위치·보안 경계

- 회사PC(lisyoen-desktop2) 로컬 전용. 서버는 `127.0.0.1:8799` 만 바인딩(외부 노출 금지).
- 본인 계정·본인 대화 한정. `teams-decrypted.db` 는 실제 대화 본문이므로 커밋 금지(`.gitignore *.db`).

## 구성

- `server.py` : Python 3.11 표준 라이브러리(`http.server` + `sqlite3`) 단일 서버. 외부 패키지 의존 없음. read-only 로 DB 조회.
- 데이터 소스: `D:\git\teams-db\teams-decrypted.db` (평문 SQLite, 키 불필요).
- 실행 바로가기: `D:\git\teams-db\teams-viewer.bat` (server.py 백그라운드 기동 → 크롬으로 `http://localhost:8799/` 오픈).

## 화면

- 상단 2탭: 워크스페이스-채널 / 1:1 대화.
- 각 탭 좌측 목록 + 우측 메시지(2-pane). 우측은 카카오톡형 버블 레이아웃(상대=좌/회색, 본인=우/강조색), 발신자명·소속 라벨(연속 발신자 그룹핑), 버블 옆 HH:MM(같은 분 그룹핑)·날짜 구분선, 회수/삭제=중앙 시스템 라인.
- 이모지 반응: 각 버블 하단 반응 칩[글리프+count], 칩 클릭 시 반응자 이름 표시, 본인 반응 강조.

UI 정본 스펙은 `../design/viewer-ui-design.md`.

## API

- `GET /` : 뷰어 페이지(HTML).
- `GET /api/bootstrap` : 워크스페이스/채널/방/연락처 부트스트랩.
- `GET /api/messages?kind=kt|km&id=<채널ID|방ID>` : 해당 대화 메시지 목록.

## 데이터 매핑

- 워크스페이스-채널(kt): TB_KtMessage + TB_Channel(Title) + TB_Workspace + TB_KtContact(LocalName).
- 1:1 대화(km): TB_KmMessage + TB_Chatroom(Title) + TB_KmContact(LocalName).
- 발신자 = Sender → TB_KtContact/TB_KmContact.LocalName. 본인 UserID=754107854600802305 → 우측 버블.
- SentTime = epoch ms → KST. Content 의 `<!-- {COMMAND} -->` 프리픽스 제거. Recalled/Deleted → 시스템 라인.
- MessageType=4 참여/이탈 시스템 이벤트(초대/퇴장/강퇴/방제변경/커스텀 알림) → 중앙 시스템 라인.
- 이모지 글리프 매핑(`emoji` 정수 → 글리프)은 server.py 상단 `EMOJI` 테이블 잠정값. 미확정 코드는 `#N` 폴백. 라이브 앱 대조로 확정 예정.

## 진행 이력

- 2026-07-09: MessageType=4 시스템 이벤트(초대/퇴장/강퇴/방제변경/커스텀 알림)를 중앙 시스템 라인으로 렌더링.
