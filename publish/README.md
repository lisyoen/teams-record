# teams-record Windows 원클릭 설치

## 설치 유형 선택

ZIP 최상위 `install.bat` 을 실행하면 먼저 Teams Viewer 설치 여부를 묻습니다.

| 선택 | 설치 내용 | 관리자 권한 |
|---|---|---|
| 예 | Teams Viewer(아래 절차) + 명령줄 도구(CLI). CLI 는 Viewer 의 `teams-archive.db` 와 DB 키를 함께 사용 | 필요(UAC) |
| 아니오 | 명령줄 도구(CLI)만 `%LOCALAPPDATA%\teams-record-lite` 에 설치 (`lite/README.md`) | 불필요 |
| 취소 | 설치하지 않음 | - |

창 없이 지정하려면 `install.bat -Mode viewer` 또는 `install.bat -Mode cli -NoPopup` 을 사용합니다. CLI 위치는 `-CliInstallDir` 로 바꿀 수 있습니다. Viewer 만 단독으로 설치하려면 `publish\install.bat` 을 실행합니다.

## Teams Viewer 설치 절차

GitHub Release의 `teams-record-v<VERSION>-install.zip`을 일반 폴더에 압축 해제하고, ZIP 최상위의 `install.bat`를 한 번 실행한 뒤 UAC를 승인합니다. 설치 창은 완료될 때까지 단계별 상태를 표시하고 마지막에 결과를 요약한 뒤 대기합니다. 전체 로그는 `%USERPROFILE%\teams-record-work\logs\install-YYYYMMDD-HHMMSS.log`에 남습니다.

설치 프로그램은 8799 리스너, 선택된 설치 경로의 Electron, Knox Teams를 먼저 종료합니다. 기존 설치 위치는 다음 우선순위로 자동 선택됩니다.

1. 명시한 `-InstallRoot`
2. `%USERPROFILE%\teams-record-work\install-root.txt`
3. `TeamsRecordViewer` 예약 작업 실행 경로
4. 바탕화면 `Teams Viewer.lnk` 대상 경로
5. 패키지 드라이브 기준 기존 기본값

Python 3.11, Node.js/npm, Electron(`npm ci`), Frida는 설치 또는 검증됩니다. pip와 npm은 시스템·환경 프록시 설정을 그대로 사용하며 프록시 주소를 하드코딩하지 않습니다. `dbkey.secret`이 없을 때만 Frida spawn 캡처를 수행합니다.

`teams-archive.db`, `teams-decrypted.db`, `thumbs`, `dbkey.secret`, `my_id.txt` 등 기존 데이터는 재설치나 업그레이드에서 삭제하거나 덮어쓰지 않습니다. `-DataBackup` 복원도 대상에 없는 archive와 thumbnail만 채웁니다.

설치 성공 후 첫 refresh를 실행하고 Electron Teams Viewer를 열며 `/api/version`의 로컬 버전이 패키지 `VERSION`과 같은지 확인합니다. 성공하면 설치 경로 마커를 기록합니다. 성공·실패와 무관하게 마지막 `finally` 단계에서 Knox Teams를 다시 실행합니다.

옵션 예시는 `install.bat -InstallRoot D:\teams-record`, `install.bat -KnoxRoot C:\mySingle\KnoxTeams`, `install.bat -DataBackup D:\backup\teams-record`, `install.bat -SkipKeyCapture`, `install.bat -SkipDeps`입니다. `-SkipDeps`는 Python 3.11, Node.js 18 이상, npm, Frida가 이미 준비된 경우에만 사용합니다. Electron 무결성 검증을 위한 `npm ci`는 계속 실행됩니다.

## 패키지 빌드

PowerShell이 없는 Linux에서도 저장소 루트에서 `python3 publish/make_install_zip.py`로 빌드합니다. 결과는 `publish/dist/teams-record-v<VERSION>-install.zip`입니다. 빌더는 명시적 화이트리스트만 포함하고 DB, 시크릿, 키, 토큰, 쿠키, `node_modules`, 로그, 썸네일과 원본 데이터 경로를 거부합니다. 필수 항목에는 루트 `install.bat`, `VERSION`, `viewer/update-check.bat`, `electron/assets/icon.ico`가 포함됩니다.

## 제거

`publish\uninstall.bat`를 실행합니다. 기본 제거는 애플리케이션 파일과 등록 항목만 제거하며 데이터는 보존합니다. 데이터까지 영구 삭제하려는 경우에만 `publish\uninstall.bat -DeleteData`를 사용합니다.

Windows 전용 UAC, winget/MSI, Frida spawn, 예약 작업, 바로가기, 실제 Knox Teams 및 Electron GUI 동작은 설치 대상 PC에서 확인해야 합니다. Release 제작 과정에서는 회사 PC 라이브 배포를 수행하지 않습니다.
