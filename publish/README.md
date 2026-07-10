# teams-record 개인 복구 패키지

## 개요

이 `publish/` 폴더는 개인 회사PC를 Windows 재설치 후 복구할 때 쓰는 teams-record 로컬 뷰어 비공개 패키지입니다. 조직 배포용 패키지가 아니며, 시크릿(키/DB/토큰/쿠키/회사데이터 원본)은 `publish`, git, zip 어디에도 포함하지 않습니다.

## 사전 조건

- Windows 재설치 후 Knox Teams 설치 및 정상 로그인 완료
- `publish\setup.bat` 실행을 위한 Windows 관리자 권한
- 키 캡처 시 Knox Teams가 현재 Windows 설치와 현재 로그인 환경에서 실행 가능해야 함

## 재설치 후 순서

1. Windows를 재설치하고 Knox Teams를 설치합니다.
2. Knox Teams에 정상 로그인합니다.
3. `publish\setup.bat`를 관리자 권한으로 실행합니다.
4. `publish\capture-key.bat`를 실행해 현재 Knox Teams 로그인 환경 기준으로 키를 새로 확보합니다.
5. 이후 로그온/재부팅 시 `TeamsRecordViewer` 작업 스케줄러가 refresh와 뷰어 서버를 자동 실행합니다. 수동으로 열 때는 바탕화면의 `Teams 뷰어` 바로가기를 사용합니다.

기존 `dbkey.secret`은 복원하지 않습니다. Windows 재설치 후 Knox Teams 로컬 키가 달라질 수 있으므로, 키는 현재 설치된 Knox Teams에서 재캡처하는 흐름이 정석입니다.

## 실행 방법

관리자 권한 PowerShell 또는 탐색기에서:

```bat
publish\setup.bat
```

점검만 수행하고 아무 것도 변경하지 않으려면:

```bat
publish\setup.bat -CheckOnly
```

재설치 전 백업한 복호화 이력 데이터를 함께 복원하려면:

```bat
publish\setup.bat -DataBackup C:\backup\teams-db
```

`-DataBackup` 폴더에는 `teams-archive.db`와 `thumbs\`가 있을 수 있습니다. 이 데이터는 이미 복호화된 로컬 뷰어 이력이며 키 복원과 무관합니다. 복원 소스는 사용자가 지정한 외부 백업 폴더만 사용하고, `publish\` 아래에서는 가져오지 않습니다.

키 재캡처:

```bat
publish\capture-key.bat
```

`capture-key.bat`는 Frida를 사용해 현재 Knox Teams 실행 환경에서 SQLCipher 키를 다시 캡처하고, 결과를 `C:\Users\lisyoen\teams-record-work\dbkey.secret`에만 기록합니다.

## 복구 후 확인 방법

1. `publish\setup.bat -CheckOnly` 결과에서 필수 파일, 대상 경로, 바로가기, 키 상태를 확인합니다.
2. 작업 스케줄러에서 `TeamsRecordViewer` 상태가 `Ready`인지 확인합니다.
3. 바탕화면에 `Teams 뷰어` 바로가기가 있는지 확인합니다.
4. `http://localhost:8799/`에 접속합니다.
5. 뷰어에서 워크스페이스/채널/1:1 대화가 로딩되는지 확인합니다.

## 제거/초기화 방법

관리자 권한 PowerShell에서:

```powershell
Unregister-ScheduledTask -TaskName TeamsRecordViewer -Confirm:$false
```

그 다음 바탕화면의 `Teams 뷰어` 바로가기를 삭제하고, 필요하면 아래 폴더를 삭제합니다.

- `D:\git\teams-db`
- `C:\Users\lisyoen\teams-record-work`

주의: `D:\git\teams-db`를 삭제하면 `teams-archive.db`와 `thumbs\` 이력도 함께 삭제됩니다.

## 재설치 전 백업 권장

Windows 재설치 전에 이력 보존이 필요하면 아래만 외부 백업 폴더에 복사합니다.

- `D:\git\teams-db\teams-archive.db`
- `D:\git\teams-db\thumbs\`

`dbkey.secret` 백업은 참고용일 뿐 재설치 후 유효하다는 보장이 없습니다. 재설치 후 키는 `publish\capture-key.bat`로 현재 Knox Teams 환경에서 재캡처합니다.

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
