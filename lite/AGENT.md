# Teams Record Lite — 에이전트 연동 안내

이 문서는 외부 에이전트(스킬)가 Teams Record Lite 를 호출해 Knox Teams 대화를 가져오는 방법을 설명합니다.

## 호출 경로

```
%LOCALAPPDATA%\teams-record-lite\teams-record-lite.bat <명령> [옵션]
```

- 비대화형입니다. 팝업·입력 대기가 없고 Knox Teams 를 종료하지 않습니다(`capture-key` 제외).
- **stdout** 에 UTF-8 JSON 한 덩어리를 출력합니다. 진행 로그는 stderr 로만 나갑니다.
- 설치 위치를 바꿨다면 그 폴더의 `teams-record-lite.bat` 을 호출합니다.

## 권장 사용 순서

1. `refresh` 로 아카이브를 갱신한다.
2. `ok` 가 `true` 이면 `archive_path` 의 SQLite DB 를 **읽기 전용**으로 열어 필요한 대화를 조회한다.
3. `error_code` 가 3 이면 사용자에게 `capture-key` 실행(또는 `install.bat` 재실행)을 안내한다. Knox Teams 가 재시작되므로 사용자 동의 없이 자동 실행하지 않는다.

## 명령

| 명령 | 옵션 | 설명 |
|---|---|---|
| `refresh` | `--timeout 180` (초), `--no-update` | 대화 갱신. 동시에 여러 번 호출되면 순서대로 처리하며 앞선 작업이 끝날 때까지 기다린다 |
| `status` | | 설치·아카이브 상태 |
| `version` | | 버전 |
| `update` | `--check`, `--rollback` | 새 버전 확인·내려받기(다음 실행부터 적용) |
| `capture-key` | `--timeout 120` | Knox Teams 재시작 + DB 키 캡처 (사용자 동의 후에만) |

## 종료 코드

| 코드 | 의미 |
|---|---|
| 0 | 성공 |
| 1 | 기타 오류 |
| 2 | 미설치 또는 Knox Teams·실행 환경을 찾지 못함 |
| 3 | DB 키 없음 또는 캡처 실패 |
| 4 | 갱신 실패(스냅샷·복호화·병합). 키가 바뀐 경우 `message` 에 안내 포함 |
| 5 | 시간 초과 |
| 6 | 업데이트 실패 |

JSON 에도 `error_code` 와 한국어 `message` 가 들어 있습니다. 실패 시 `detail` 에 원인 로그 일부가 포함될 수 있습니다.

## 출력 예시

`refresh` 성공:

```json
{
  "ok": true,
  "at": "2026-10-21T11:00:05+09:00",
  "changed": {"TB_KtMessage": 3, "TB_RelateMessage": 1},
  "totals": {"TB_KtMessage": 2018, "TB_KmMessage": 741},
  "last_merge": "2026-10-21 11:00:05",
  "schema_added": {},
  "archive_path": "C:\\Users\\<user>\\AppData\\Local\\teams-record-lite\\data\\teams-archive.db",
  "error_code": 0,
  "message": "대화 내용을 갱신했습니다.",
  "update": {"checked": false, "current": "1.1.0", "latest": null, "staged": false,
             "runtime_update_required": false, "skipped": "checked recently"}
}
```

`refresh` 실패:

```json
{"ok": false, "at": "2026-10-21T11:00:05+09:00", "error_code": 3,
 "message": "DB 키(dbkey.secret)가 없습니다. 'teams-record-lite capture-key' 를 실행해 주세요.", "detail": null}
```

`update.runtime_update_required` 가 `true` 이면 실행 환경(Python·frida)이 바뀐 버전이므로 최신 zip 의 `install.bat` 을 다시 실행하도록 사용자에게 안내합니다.

## 아카이브 DB

- 위치: `refresh`·`status` 결과의 `archive_path` 를 사용한다. 기본은 `%LOCALAPPDATA%\teams-record-lite\data\teams-archive.db` 이고, Teams Viewer 와 함께 설치된 PC 에서는 Viewer 설치 폴더의 `teams-archive.db` 다. 경로를 하드코딩하지 않는다.
- Knox Teams 로컬 DB 의 테이블 구조를 그대로 누적 보관한다. 앱에서 오래되어 지워진 메시지도 남는다.
- 읽기 전용 연결 권장: `sqlite3.connect("file:<경로>?mode=ro", uri=True)`
- 시각(`SentTime`, `LastMsgTime`)은 Unix epoch **밀리초**다.
- `MessageType` 4, 13 은 시스템성 메시지로 뷰어에서도 숨긴다.

| 테이블 | 내용 | 주요 컬럼 |
|---|---|---|
| `TB_KtMessage` | 워크스페이스 채널 메시지 | `MessageId`, `ChannelID`, `Content`, `MessageType`, `SentTime`, `Sender`, `Recalled`, `Deleted`, `ParentMsgId`(답글 부모), `ReplyTotalCount` |
| `TB_KmMessage` | 1:1·그룹 대화방 메시지 | `MessageId`, `ChatroomId`, `Content`, `MessageType`, `SentTime`, `Sender`, `Recalled`, `FileName` |
| `TB_Channel` | 채널 | `ChannelID`, `WorkspaceID`, `Title`, `LastMsgTime` |
| `TB_Chatroom` | 대화방 | `ChatroomID`, `Title`, `ParticipantInfos`, `LastMsgBody`, `LastMsgTime` |
| `TB_Workspace` | 워크스페이스 | `WorkspaceID`, `Title` |
| `TB_KtContact`, `TB_KmContact` | 연락처(발신자 이름 조회) | `UserID`, `LocalName`, `Department`, `CompanyName`, `Position` |
| `_archive_meta` | 아카이브 메타 | `k='last_merge'` |

`Content` 는 평문이거나 JSON 문자열(멘션·첨부 등)일 수 있으므로 JSON 이면 텍스트 값만 추려 쓴다.

예: 최근 하루 동안의 대화방 메시지

```sql
SELECT m.SentTime, m.Sender, c.Title, m.Content
FROM TB_KmMessage m LEFT JOIN TB_Chatroom c ON c.ChatroomID = m.ChatroomId
WHERE m.SentTime >= (strftime('%s','now') - 86400) * 1000 AND m.MessageType NOT IN (4, 13)
ORDER BY m.SentTime;
```

## 주의

- 아카이브는 평문 대화 기록입니다. 에이전트가 외부로 전송·저장할 때는 사용자 동의와 회사 보안 정책을 따르십시오.
- `work\dbkey.secret` 은 읽거나 전송하지 마십시오.
