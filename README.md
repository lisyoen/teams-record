압축 풀고 루트의 `install.bat`를 실행하세요. Teams Viewer(바탕화면 바로가기 포함)와 명령줄 도구(CLI)가 함께 설치됩니다.

# teams-record

Knox Teams(삼성SDS 사내 메신저)의 짧은 로컬 대화 보관 기간을 보완하기 위해, 본인 대화를 로컬 SQLite 데이터베이스에 백업하고 웹 뷰어로 열람하는 개인용 도구입니다.

## 주요 기능

- 워크스페이스·채널과 1:1 대화 열람
- 카카오톡형 좌우 메시지 버블
- 이모지 반응과 반응자 표시
- 이미지 미디어 썸네일과 확대 보기
- 대화 Markdown 내보내기
- 전체 대화 검색
- 지원되는 대화의 읽음 상태 표시
- 버전 표시와 자동 업데이트

## Teams Record Lite (CLI 전용 경량판)

뷰어 없이 Knox Teams 대화 DB 만 읽어 누적 아카이브를 갱신하는 명령줄 도구입니다. 외부 에이전트가 호출하는 용도이며, 설치 패키지 `install.bat` 을 실행하면 Teams Viewer 와 함께 항상 설치되며 같은 아카이브를 공유합니다. CLI 만 담은 `teams-record-lite-v<버전>.zip` 도 Release 에 함께 올라가며 CLI 자동 업데이트에 쓰입니다. 자세한 내용은 [`lite/README.md`](lite/README.md), 에이전트 연동은 [`lite/AGENT.md`](lite/AGENT.md) 를 참고하세요.

## 구성

- `viewer/`: Python 표준 라이브러리 기반 로컬 웹 뷰어. `127.0.0.1:8799`에만 바인딩합니다.
- `electron/`: 웹 뷰어를 전용 창으로 실행하는 Electron 앱입니다.
- `publish/`: 루트 `install.bat`가 호출하는 설치 로직과 Linux/Windows 공용 ZIP 빌더를 담습니다.

Knox Teams의 기본 설치 위치는 `C:\mySingle\KnoxTeams`이며, 설치 패키지 옵션으로 다른 위치를 지정할 수 있습니다.

## 데이터와 로컬 실행

추출된 대화 본문, 복호화 키, 원본 저장소 파일, SQLite 데이터베이스와 미디어 캐시는 Git에 커밋하지 않습니다. 관련 경로와 파일 형식은 `.gitignore`에서 차단합니다.

뷰어는 로컬 전용으로 동작하며 외부 인터페이스에 서버를 노출하지 않습니다. 설치와 데이터 갱신 방법은 `publish/README.md`, 뷰어의 API와 데이터 매핑은 `viewer/README.md`를 참고하세요.

## 개발 성격

이 저장소는 개인용 로컬 백업·열람 도구의 소스와 문서를 제공합니다. 실제 계정 데이터와 키는 각 설치 환경에서 별도로 관리합니다.
