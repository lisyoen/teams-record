# teams-record 설치 방법

## 개요

이 패키지는 Knox Teams 로컬 메시지 DB를 누적 아카이브로 만들고, 브라우저에서 조회할 수 있는 Teams Record Viewer를 설치합니다. 뷰어는 순수 Python(server.py, 브라우저에서 `http://localhost:8799/` 접속)으로 동작하며 별도 Electron 앱이 아닙니다. 시크릿(키/DB/토큰/쿠키/회사데이터 원본)은 `publish`, git, zip 어디에도 포함하지 않습니다.

## 사전 조건

- Knox Teams 설치 및 정상 로그인 완료
- Windows 관리자 권한(설치 스크립트가 자동으로 권한 승격을 요청합니다)
- 키 캡처 시 Knox Teams가 현재 Windows 설치와 현재 로그인 환경에서 실행 가능해야 함
- 인터넷 접근(최초 1회 Python 3.11 및 frida 설치용)

## 빠른 설치 (권장) - 원클릭

1. zip 파일을 원하는 폴더에 압축 해제합니다.
2. Knox Teams가 설치되어 있고 정상 로그인되는지 확인합니다.
3. `publish\install.bat`를 실행합니다(관리자 권한은 자동 승격).

`install.bat`는 다음 순서로 진행합니다.

1. **의존성 우선 설치**: Python 3.11(없으면 설치), frida(키 캡처용)
2. **백엔드 + 바탕화면 바로가기 설치**: 뷰어/복호화 런타임 배치, `Teams Viewer` 바로가기 생성. 이어서 DB 키 캡처가 필요하면 **Knox Teams를 자동으로 종료한 뒤 새 인스턴스로 키를 캡처하고, 캡처 후 Knox Teams를 다시 실행**합니다.
3. **부팅 후 데이터 자동 업데이트 세팅**: 로그온 시 아카이브 갱신 + 뷰어 서버를 자동 실행하는 작업 스케줄러 `TeamsRecordViewer` 등록

설치가 끝나면 바탕화면의 `Teams Viewer` 바로가기로 `http://localhost:8799/`를 엽니다.

### install.bat 옵션

```bat
publish\install.bat -KnoxRoot C:\mySingle\KnoxTeams
publish\install.bat -InstallRoot D:\teams-record
publish\install.bat -DataBackup C:\backup\teams-db   (이전 이력 복원)
publish\install.bat -SkipKeyCapture                  (키 캡처는 나중에 수동)
publish\install.bat -SkipDeps                        (Python 3.11/frida 이미 있음)
```

## 수동 설치 (개별 단계)

원클릭 대신 단계별로 실행하려면 아래를 사용합니다.

1. `publish\setup.bat`를 관리자 권한으로 실행합니다(Python 3.11 설치, 파일 배치, 바로가기, 로그온 스케줄 등록).
2. Knox Teams를 작업표시줄/트레이까지 완전히 종료합니다.
3. `publish\capture-key.bat`를 실행해 현재 Knox Teams 로그인 환경 기준으로 키를 확보합니다.
4. 바탕화면의 `Teams Viewer` 바로가기를 실행합니다.

`capture-key.bat`는 해당 PC에서 최초 설치 후 1회 실행하면 됩니다. 이후 로그온/재부팅 시 `TeamsRecordViewer` 작업 스케줄러가 refresh와 뷰어 서버를 자동 실행합니다. Knox Teams 재로그인, 재설치, DB 키 변경 등으로 복호화가 되지 않을 때만 다시 실행합니다.

## 경로 기준

- 설치 위치 기본값은 패키지가 시스템 드라이브에 있으면 `%LOCALAPPDATA%\teams-record`, 데이터 드라이브에 있으면 `<드라이브>:\teams-record`입니다. 다른 위치는 `-InstallRoot <경로>`로 지정합니다.
- 작업 폴더는 현재 로그인한 Windows 계정의 `%USERPROFILE%\teams-record-work`입니다. 계정명은 고정하지 않고 `%USERNAME%`, `%USERPROFILE%`, `%LOCALAPPDATA%` 기준으로 계산하므로 **다른 Windows ID에서도 그대로 재설치**할 수 있습니다.
- 작업 스케줄러 `TeamsRecordViewer`도 현재 로그인한 Windows 사용자 기준으로 등록합니다.
- Knox Teams 기본 경로는 `C:\mySingle\KnoxTeams`입니다. 다른 경로면 `-KnoxRoot <경로>`(setup/install) 또는 `KNOX_ROOT` 환경변수(refresh/capture)로 지정합니다.
- live DB는 `%APPDATA%\KnoxTeams\prd\` 아래의 메시지 DB를 자동탐지합니다.

## 설치 후 확인 방법

1. `publish\setup.bat -CheckOnly` 결과에서 필수 파일, 대상 경로, 바로가기, 키 상태를 확인합니다.
2. 작업 스케줄러에서 `TeamsRecordViewer` 상태가 `Ready`인지 확인합니다.
3. 바탕화면에 `Teams Viewer` 바로가기가 있는지 확인합니다.
4. `http://localhost:8799/`에 접속합니다.
5. 뷰어에서 워크스페이스/채널/1:1 대화가 로딩되고, 상단 검색창으로 전체 대화 검색이 되는지 확인합니다.

## 제거/초기화 방법

관리자 권한 PowerShell에서:

```powershell
Unregister-ScheduledTask -TaskName TeamsRecordViewer -Confirm:$false
```

그 다음 바탕화면의 `Teams Viewer` 바로가기를 삭제하고, 필요하면 아래 폴더를 삭제합니다.

- 설치 위치(기본 `%LOCALAPPDATA%\teams-record` 또는 `<드라이브>:\teams-record`, 또는 `-InstallRoot`로 지정한 경로)
- `%USERPROFILE%\teams-record-work`

주의: 설치 위치를 삭제하면 `teams-archive.db`와 `thumbs\` 이력도 함께 삭제됩니다.

## 백업 권장

이력 보존이 필요하면 아래만 외부 백업 폴더에 복사합니다.

- `<설치위치>\teams-archive.db`
- `<설치위치>\thumbs\`

`dbkey.secret` 백업은 참고용일 뿐 다른 Windows 설치나 다른 로그인 환경에서 유효하다는 보장이 없습니다. 키는 `publish\capture-key.bat`로 현재 Knox Teams 환경에서 캡처합니다.

## publish에 포함하면 안 되는 파일 목록

아래 항목은 `publish`, git, zip 어디에도 포함하지 않습니다.

- `dbkey.secret` 및 모든 `*.secret`
- `*.db`, `*.db-wal`, `*.db-shm`, `*.sqlite*`
- 실제 Knox DB, `teams-archive.db`, `snap.db`, `wbtest.db`
- 인증 토큰, 쿠키, 세션 파일
- `*.store` 원본
- 회사 내부 데이터 원본
- `thumbs\` 실물
- 로그와 임시 추출물(`*.log`, `*.b64` 등)
