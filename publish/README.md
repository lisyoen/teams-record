# teams-record 설치 방법

## 개요

이 패키지는 Knox Teams 로컬 메시지 DB를 누적 아카이브로 만들고, 브라우저에서 조회할 수 있는 Teams Record Viewer를 설치합니다. 시크릿(키/DB/토큰/쿠키/회사데이터 원본)은 `publish`, git, zip 어디에도 포함하지 않습니다.

## 사전 조건

- Knox Teams 설치 및 정상 로그인 완료
- `publish\setup.bat` 실행을 위한 Windows 관리자 권한
- 키 캡처 시 Knox Teams가 현재 Windows 설치와 현재 로그인 환경에서 실행 가능해야 함

## 경로 기준

- 설치 위치 기본값은 패키지가 시스템 드라이브에 있으면 `%LOCALAPPDATA%\teams-record`, 데이터 드라이브에 있으면 `<드라이브>:\teams-record`입니다. 예를 들어 시스템 드라이브가 `C:`이고 패키지가 `D:` 드라이브에 있으면 기본 설치 위치는 `D:\teams-record`입니다.
- 다른 위치에 설치하려면 `publish\setup.bat -InstallRoot <경로>`를 사용합니다. 기본값으로 개발자 PC 경로를 쓰지 않습니다.
- 작업 폴더는 현재 로그인한 Windows 계정의 `%USERPROFILE%\teams-record-work`입니다. 계정명은 고정하지 않고 `%USERNAME%`, `%USERPROFILE%`, `%LOCALAPPDATA%` 기준으로 계산합니다.
- 작업 스케줄러 `TeamsRecordViewer`도 현재 로그인한 Windows 사용자(`DOMAIN\user` 형식)를 기준으로 등록합니다.
- Knox Teams 기본 경로는 `C:\mySingle\KnoxTeams`입니다. 다른 경로에 설치했다면 setup에는 `-KnoxRoot <경로>`를 넘기고, refresh/capture 실행 시에는 `KNOX_ROOT` 환경변수로 지정할 수 있습니다.
- live DB는 `%APPDATA%\KnoxTeams\prd\` 아래의 메시지 DB를 자동탐지합니다.

## 설치 순서

1. zip 파일을 원하는 폴더에 압축 해제합니다.
2. Knox Teams가 설치되어 있고 정상 로그인되는지 확인합니다.
3. `publish\setup.bat`를 관리자 권한으로 실행합니다.
4. Knox Teams를 작업표시줄/트레이까지 완전히 종료합니다.
5. `publish\capture-key.bat`를 실행해 현재 Knox Teams 로그인 환경 기준으로 키를 확보합니다.
6. 바탕화면의 `Teams Viewer` 바로가기를 실행합니다.

`capture-key.bat`는 해당 PC에서 최초 설치 후 1회 실행하면 됩니다. 이후 로그온/재부팅 시 `TeamsRecordViewer` 작업 스케줄러가 refresh와 뷰어 서버를 자동 실행합니다. Knox Teams 재로그인, 재설치, DB 키 변경 등으로 복호화가 되지 않을 때만 다시 실행합니다.

## 실행 방법

관리자 권한 PowerShell 또는 탐색기에서:

```bat
publish\setup.bat
```

설치 위치 또는 Knox Teams 위치를 직접 지정하려면:

```bat
publish\setup.bat -InstallRoot E:\teams-record -KnoxRoot C:\mySingle\KnoxTeams
```

점검만 수행하고 아무 것도 변경하지 않으려면:

```bat
publish\setup.bat -CheckOnly
```

이전에 백업한 복호화 이력 데이터를 함께 복원하려면:

```bat
publish\setup.bat -DataBackup C:\backup\teams-db
```

`-DataBackup` 폴더에는 `teams-archive.db`와 `thumbs\`가 있을 수 있습니다. 이 데이터는 이미 복호화된 로컬 뷰어 이력이며 키 복원과 무관합니다. 복원 소스는 사용자가 지정한 외부 백업 폴더만 사용하고, `publish\` 아래에서는 가져오지 않습니다.

키 재캡처:

```bat
publish\capture-key.bat
```

`capture-key.bat`는 Frida를 사용해 현재 Knox Teams 실행 환경에서 SQLCipher 키를 다시 캡처하고, 결과를 `%USERPROFILE%\teams-record-work\dbkey.secret`에만 기록합니다.

## 설치 후 확인 방법

1. `publish\setup.bat -CheckOnly` 결과에서 필수 파일, 대상 경로, 바로가기, 키 상태를 확인합니다.
2. 작업 스케줄러에서 `TeamsRecordViewer` 상태가 `Ready`인지 확인합니다.
3. 바탕화면에 `Teams Viewer` 바로가기가 있는지 확인합니다.
4. `http://localhost:8799/`에 접속합니다.
5. 뷰어에서 워크스페이스/채널/1:1 대화가 로딩되는지 확인합니다.

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
