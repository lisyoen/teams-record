# Teams Record Lite

Knox Teams 메신저의 로컬 대화 DB 를 읽어 누적 보관용 SQLite 아카이브(`teams-archive.db`)를 갱신하는 경량 도구입니다. 뷰어 화면 없이 명령줄(CLI)로만 동작하며, 외부 에이전트가 필요할 때 호출해 최신 대화를 가져가는 용도로 만들었습니다.

## 설치

기본 설치 방법은 전체 설치 패키지(`teams-record-v<버전>-install.zip`)의 `install.bat` 입니다. Teams Viewer 와 함께 항상 설치되며, CLI 는 Viewer 의 대화 아카이브와 DB 키를 그대로 사용합니다. 아래는 CLI 만 담은 zip(자동 업데이트용)으로 단독 설치하는 방법입니다.

1. `teams-record-lite-v<버전>.zip` 을 내려받아 압축을 풉니다.
2. `install.bat` 을 실행합니다.
3. 안내 창의 [확인]을 누르면 설치가 끝까지 자동으로 진행되고, 완료 창이 표시됩니다.

- 관리자 권한(UAC)은 필요하지 않습니다. 설치 위치는 `%LOCALAPPDATA%\teams-record-lite` 입니다.
- Python 은 설치 폴더 안에 전용으로 내려받으므로 PC 에 Python 이 없어도 되고, 시스템 설정을 바꾸지 않습니다. Node.js·Electron 도 필요 없습니다.
- DB 키가 아직 없으면 설치 중 Knox Teams 메신저가 잠시 종료되었다가 자동으로 다시 실행됩니다. 같은 PC 에 Teams Record(뷰어 포함 버전)가 이미 설치돼 있으면 그 키를 재사용합니다.
- 인터넷 연결이 필요하며, 회사망 프록시는 Windows 시스템 설정을 그대로 사용합니다.
- 옵션: `install.bat -NoPopup`(안내 창 없이 설치), `install.bat -InstallDir D:\tr-lite`(설치 위치 변경)
- 다시 설치하거나 새 zip 으로 덮어 설치해도 대화 아카이브·DB 키·설정은 유지됩니다.

## 사용

```bat
"%LOCALAPPDATA%\teams-record-lite\teams-record-lite.bat" refresh
```

| 명령 | 설명 |
|---|---|
| `refresh` | Knox Teams 대화를 다시 읽어 아카이브를 갱신 |
| `status` | 버전, 설치 위치, 아카이브 건수, 마지막 갱신 시각 |
| `update` / `update --check` | 새 버전 내려받기 / 확인만 |
| `update --rollback` | 다음 실행 시 이전 버전으로 되돌리기 |
| `capture-key` | Knox Teams 를 재시작하며 DB 키 다시 캡처 (로그인 계정이 바뀐 경우 등) |
| `version` | 버전 출력 |

결과는 모두 JSON 으로 출력됩니다. 자세한 형식은 `AGENT.md` 를 참고하세요.

## 자동 업데이트

`refresh` 실행 시 24시간마다 새 버전을 확인합니다. 새 버전이 있으면 내려받아 SHA256 을 검증한 뒤, 다음 실행부터 자동으로 적용합니다. 업데이트 확인이 실패해도 대화 갱신은 정상 진행됩니다. 설정은 `%LOCALAPPDATA%\teams-record-lite\config.json` 에서 바꿀 수 있습니다.

| 항목 | 기본값 | 설명 |
|---|---|---|
| `update_url` | GitHub Release 최신 매니페스트 | 사내 HTTP 서버 주소로 바꿀 수 있음 (http/https) |
| `auto_update` | `true` | `false` 면 자동 확인 안 함 |
| `update_interval_hours` | `24` | 자동 확인 주기 |
| `knox_root` | (자동 탐지) | Knox Teams 설치 폴더 |
| `archive_path` | (비어 있음 = `data\teams-archive.db`) | Viewer 와 함께 설치하면 Viewer 아카이브 경로가 들어감 |

매니페스트 형식 (`teams-record-lite-latest.json`):

```json
{"version": "1.1.0", "url": "teams-record-lite-v1.1.0.zip", "sha256": "<zip SHA256>", "runtime": "py3.11.9-embed+frida", "notes": ""}
```

`url` 은 절대 주소 또는 매니페스트 기준 상대 경로입니다. 사내 HTTP 서버에 올릴 때는 `python lite/build_lite_zip.py --base-url http://<서버>/<경로>/` 로 만든 zip 과 매니페스트를 같은 폴더에 두면 됩니다.

## DB 키 (1.3.0)

- `capture-key` 로 캡처한 키는 설치 폴더 밖 보관함에도 저장됩니다. 설치 폴더의 키가 없어지면 보관함에서 복원합니다.
- `refresh` 가 복호화에 실패하면 새 스냅샷으로 한 번 더 시도하고(Knox Teams 가 DB 를 쓰는 순간 복사된 경우), 그래도 안 되면 보관함의 이전 키와 Teams Viewer 의 키를 차례로 시도합니다. 모두 실패할 때만 `error_code` 4 와 함께 다시 캡처하라고 안내합니다.
- 캡처 후 Knox Teams 는 탐색기(Explorer)로 다시 실행해 바탕화면에서 직접 실행한 것과 같은 방식으로 시작합니다. 키를 기다리는 시간은 90초입니다(환경 변수 `TEAMS_RECORD_KEY_WAIT`).

## 제거

설치 폴더의 `uninstall.bat` 을 실행합니다. 대화 아카이브와 DB 키를 남길지 선택할 수 있습니다.

## 데이터 위치

| 경로 | 내용 |
|---|---|
| `data\teams-archive.db` | 누적 대화 아카이브 (평문 SQLite, 외부 반출 주의) |
| `work\dbkey.secret` | Knox Teams DB 키 (외부 반출 금지) |
| `%LOCALAPPDATA%\teams-record-keys\keys.json` | 캡처한 DB 키 보관함 (1.3.0, Windows DPAPI 로 현재 사용자만 복호화, 최근 10개). 업데이트·재설치해도 남아 다시 캡처하지 않아도 됩니다 |
| `logs\` | 설치·갱신·업데이트 로그 |
