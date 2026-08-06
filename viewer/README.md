# teams-record local viewer

Knox Teams 평문 스냅샷(`teams-decrypted.db`) 또는 누적 아카이브(`teams-archive.db`)를 로컬에서 열람하는 단일 파일 웹 뷰어입니다.

## 실행 위치·보안 경계

- 설치 대상 Windows PC에서 로컬 전용으로 실행합니다. 서버는 `127.0.0.1:8799`에만 바인딩합니다.
- `teams-decrypted.db`와 `teams-archive.db`에는 실제 대화 본문이 들어 있으므로 커밋하지 않습니다(`.gitignore *.db`).
- 기본 설치 위치는 패키지가 시스템 드라이브에 있으면 `%LOCALAPPDATA%\teams-record`, 다른 드라이브에 있으면 `<드라이브>:\teams-record`입니다. `setup.ps1 -InstallRoot`로 변경할 수 있습니다.

## 구성과 실행

- `server.py`: Python 3.11 표준 라이브러리(`http.server` + `sqlite3`)만 사용하는 서버입니다. 데이터베이스를 read-only로 조회합니다.
- 데이터 소스: 뷰어 루트의 `teams-archive.db`, 없으면 `teams-decrypted.db`를 사용합니다.
- 기본 UI: 설치 위치의 Electron 앱입니다. 바탕화면 `Teams Viewer` 바로가기가 Electron을 열고, Electron이 `server.py`를 `pythonw.exe`로 시작한 뒤 준비를 기다립니다. 브라우저는 자동으로 열지 않습니다.

본인 메시지 판별 ID는 환경변수 `TEAMS_RECORD_MY_ID`를 우선 사용합니다. 환경변수가 없으면 `viewer/my_id.txt`의 첫 값을 읽습니다. 두 설정이 모두 없으면 본인 판별을 비활성화하여 모든 메시지를 좌측 버블로 표시합니다. `my_id.txt`는 로컬 설정이며 Git에 커밋하지 않습니다.

## 화면

- 상단 2탭: 워크스페이스·채널 / 1:1 대화
- 좌측 대화 목록과 우측 메시지의 2-pane 구성
- 카카오톡형 버블: 상대는 좌측, 설정된 본인 계정은 우측
- 발신자명·소속, 연속 발신자 그룹핑, 시각 그룹핑과 날짜 구분선
- 회수·삭제 및 참여 이벤트 시스템 라인
- 이모지 반응 칩과 반응자 이름, 본인 반응 강조
- 이미지 썸네일과 확대 보기, 대화 Markdown 내보내기, 전체 검색
- 1:1·그룹 대화에서 데이터가 제공되는 경우 읽음 상태 표시
- 버전 확인과 자동 업데이트

UI 정본 스펙은 `../design/viewer-ui-design.md`에 있습니다.

## API

- `GET /`: 뷰어 페이지
- `GET /api/bootstrap`: 워크스페이스, 채널, 방, 연락처 부트스트랩
- `GET /api/messages?kind=kt|km&id=<채널ID|방ID>`: 대화 메시지 목록
- `GET /api/search?q=<검색어>`: 전체 대화 검색
- `GET /api/download?kind=kt|km&id=<채널ID|방ID>`: 대화 Markdown 다운로드
- `POST /api/refresh`: 로컬 데이터 갱신
- `GET /api/version`: 로컬·최신 버전 정보
- `POST /api/update`: 최신 뷰어 업데이트

## 데이터 매핑

- 워크스페이스·채널(`kt`): `TB_KtMessage` + `TB_Channel` + `TB_Workspace` + `TB_KtContact`
- 1:1·그룹 대화(`km`): `TB_KmMessage` + `TB_Chatroom` + `TB_KmContact`
- 발신자: `Sender`를 연락처 테이블의 `LocalName`으로 매핑합니다. 설정된 본인 계정은 우측 버블로 표시합니다.
- 시각: `SentTime` epoch ms를 KST로 표시합니다.
- 본문: `Content`의 `<!-- {COMMAND} -->` 프리픽스를 제거합니다.
- 시스템 표시: `Recalled`·`Deleted`, `MessageType=4` 참여·이탈 이벤트를 중앙 시스템 라인으로 표시합니다.
- 미디어: `MessageType=13` 첨부 정보를 카드로 표시하고 로컬 썸네일 캐시를 사용합니다.
- 반응: `ReactionInfo`의 이모지 코드, 수, 사용자 목록과 `isMine`을 사용합니다. 미확정 코드는 `#N`으로 표시합니다.
- 읽음: `TB_Chatroom.ParticipantInfos`의 소비 지점을 이용하며, 원천 데이터가 없는 채널 대화에서는 표시하지 않습니다.
