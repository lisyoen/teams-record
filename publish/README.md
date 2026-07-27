# teams-record Windows 설치 패키지

## 설치 결과

`publish\install.bat` 한 번으로 로컬 백엔드와 Electron 기본 뷰어를 설치합니다.
바탕화면의 `Teams Viewer` 바로가기는 브라우저가 아니라 설치된
`electron.exe`를 실행합니다. Electron은 `viewer\server.py`가 준비됐는지
확인하고, 필요하면 `pythonw.exe`로 콘솔창 없이 시작한 뒤 전용 창에서
`http://127.0.0.1:8799/`를 표시합니다. 브라우저 자동 실행은 없습니다.

시크릿, DB, 토큰, 쿠키, 로그, Knox Teams 원본 데이터는 설치 ZIP과 Git에
포함하지 않습니다.

## 사전 조건

- Windows 10/11 관리자 권한(스크립트가 UAC 승격 요청)
- Knox Teams 설치 및 현재 Windows 계정에서 로그인 가능
- 최초 의존성 설치와 Electron 다운로드를 위한 인터넷 접근
- 기본 Knox Teams 경로: `C:\mySingle\KnoxTeams`

## 설치

1. 설치 ZIP을 일반 폴더에 압축 해제합니다.
2. Knox Teams가 정상 로그인되는지 확인합니다.
3. `publish\install.bat`를 실행하고 UAC를 승인합니다.

설치 과정은 다음 순서입니다.

1. Python 3.11을 설치하거나 버전을 확인합니다.
2. Node.js LTS와 npm을 설치하거나 버전을 확인합니다.
3. viewer, Electron 소스, 복호화 런타임을 설치 위치에 배치합니다.
4. `package-lock.json` 기준 `npm ci --include=dev`로 Electron 의존성을 설치하고
   `electron.exe` 존재를 확인합니다.
5. Frida를 설치하거나 import를 확인합니다.
6. `dbkey.secret`이 없으면 Knox Teams를 종료하고 Frida spawn 방식으로 키를
   캡처한 뒤 Knox Teams를 다시 실행합니다. 키는
   `%USERPROFILE%\teams-record-work\dbkey.secret`에만 저장합니다.
7. 로그온 작업 `TeamsRecordViewer`를 등록합니다. 이 작업은 아카이브를
   갱신한 뒤 `pythonw.exe viewer\server.py`를 백그라운드로 실행합니다.
8. 바탕화면 `Teams Viewer` 바로가기를 설치된 Electron 실행 파일에 연결합니다.

기존 `teams-archive.db`, `teams-decrypted.db`, `thumbs`, `dbkey.secret`, 작업
스냅샷과 백업은 재설치 때 덮어쓰거나 지우지 않습니다. `-DataBackup`을 직접
지정한 경우에만 해당 외부 백업의 archive와 thumbs를 복원합니다.

### 옵션

```bat
publish\install.bat -KnoxRoot C:\mySingle\KnoxTeams
publish\install.bat -InstallRoot D:\teams-record
publish\install.bat -DataBackup C:\backup\teams-db
publish\install.bat -SkipKeyCapture
publish\install.bat -SkipDeps
```

`-SkipDeps`는 기존 Python 3.11, Node.js 18 이상, npm, Frida가 모두 준비된
경우에만 사용합니다. Electron 패키지는 설치 무결성을 위해 계속 `npm ci`로
검증합니다.

## 실행과 확인

- 평소에는 바탕화면 `Teams Viewer`를 실행합니다.
- 설치 상태 확인: `publish\setup.bat -CheckOnly`
- 키 캡처 재시도: Knox Teams 로그인 후 `publish\capture-key.bat`
- 설치 직후 데이터가 비어 있으면 `viewer\teams-viewer.bat`을 한 번 실행하여
  refresh 후 Electron을 엽니다.

`TeamsRecordViewer` 로그온 작업은 UI를 자동으로 띄우지 않습니다. 백엔드만
콘솔창 없이 준비하며, 사용자가 바로가기를 누를 때 Electron 창이 열립니다.

## 안전 제거

기본 제거:

```bat
publish\uninstall.bat
```

다른 설치 위치를 사용했다면 같은 값을 전달합니다.

```bat
publish\uninstall.bat -InstallRoot D:\teams-record
```

Python, Node.js, npm, Frida는 다른 프로그램에서도 사용할 수 있는 공유 의존성이므로 제거하지 않습니다.

기본 제거는 설치 프로그램이 만든 작업 스케줄러, 해당 설치를 가리키는
바탕화면 바로가기, viewer/Electron 코드, Electron `node_modules`, 작업 폴더의
복호화 런타임 파일만 제거합니다. 다음 데이터는 보존합니다.

- `<설치위치>\teams-archive.db` 및 SQLite 보조 파일
- `<설치위치>\teams-decrypted.db` 및 SQLite 보조 파일
- `<설치위치>\thumbs\`
- `%USERPROFILE%\teams-record-work\dbkey.secret`
- 작업 스냅샷, 출력 DB, 로그, 사용자가 둔 백업 데이터

데이터까지 영구 삭제하려는 경우에만 명시적으로 실행합니다.

```bat
publish\uninstall.bat -DeleteData
```

`-DeleteData`는 위 DB/archive/thumbs와 전체
`%USERPROFILE%\teams-record-work`를 삭제하므로 백업 여부를 먼저 확인해야
합니다. 이 옵션 없이 데이터 삭제는 수행하지 않습니다.

## 제거 후 재설치 검증

1. `publish\uninstall.bat` 실행
2. DB, archive, thumbs, `dbkey.secret`, 백업 데이터가 남아 있는지 확인
3. `publish\install.bat` 실행
4. `publish\setup.bat -CheckOnly` 실행
5. 바탕화면 `Teams Viewer` 실행
6. Electron 전용 창에서 기존 대화와 검색이 보이는지 확인

## 경로

- 설치 위치 기본값: 패키지가 시스템 드라이브에 있으면
  `%LOCALAPPDATA%\teams-record`, 다른 드라이브면 `<드라이브>:\teams-record`
- 작업 폴더: `%USERPROFILE%\teams-record-work`
- 라이브 DB 탐색: `%APPDATA%\KnoxTeams\prd\*.db`
- 서버: `127.0.0.1:8799` 전용 바인딩

## 패키지 생성 안전장치

`publish\make-install-zip.ps1`은 화이트리스트 파일만 staging하고 다음 항목이
Git 추적 파일, staging 또는 ZIP 엔트리에 있으면 실패합니다.

- `node_modules`
- `*.db`, WAL/SHM, `*.sqlite*`, SQLite 파일 헤더
- `dbkey.secret`, `*.secret`, 키 폴더
- 토큰, 쿠키, 세션 이름의 파일
- 로그, store, b64, thumbs
- data/dumps/attachments/pictures/prd 및 회사 원본 데이터 폴더

ZIP에는 `publish`, `viewer`, `electron`의 설치에 필요한 소스만 들어가며
Electron `node_modules`는 대상 Windows PC에서 `npm ci`로 설치합니다.

## 검증 범위

Linux에서 가능한 검증은 Python/JavaScript 구문, pytest, 패키지 잠금파일 설치,
화이트리스트 staging, ZIP 엔트리와 민감 파일 부재 검사입니다. UAC, winget/MSI,
Frida의 Knox Teams spawn, 작업 스케줄러, `pythonw.exe`, Windows 바로가기,
Electron GUI와 실제 제거/재설치는 Windows에서 확인해야 합니다.
