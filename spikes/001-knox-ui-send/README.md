# KnoxTeams UI 송신 spike

## Verdict: VALIDATED

Question: KnoxTeams의 저수준 `sendKtMessage`를 직접 호출하지 않고 실제 작성창 경로를 사용해 서버 송신, PC UI 표시, 로컬 DB 저장을 함께 수행할 수 있는가?

Evidence:

- 대상 채널: `203944618158328832` (`노숙진-이창연`)
- 실제 작성창에 Chromium `Input.insertText`로 입력한 뒤 활성화된 `전송` 버튼을 클릭
- 전송 직후 PC UI에서 문구 표시 확인
- `teams-record` 갱신 후 `TB_KtMessage`에서 MessageId `1787644886597458`, MessageKey `140069376879260000`, State `0`, Recalled `0`, Deleted `0` 확인
- 전송 뒤 KnoxTeams 메인 프로세스와 렌더러가 계속 실행됨

What worked: Electron main inspector에서 `webContents.debugger`를 통해 실제 렌더러에 키 입력을 전달하면 ToastUI/React 상태, KnoxTeams saga/dispatch, 서버 송신, 로컬 DB 저장이 모두 정상적으로 이어진다.

What failed or surprised us: `messageManager.sendKtMessage` 직접 호출은 서버와 모바일에는 전달되지만 발신 PC의 UI와 로컬 DB를 갱신하지 않는다. DOM의 `value`나 `innerText`만 바꾸는 방식도 React/ToastUI 상태를 갱신하지 못해 전송 버튼이 활성화되지 않는다.

Recommendation: production bridge는 저수준 worker 호출이 아니라 이 UI 입력 경로 또는 확인된 공식 saga action을 사용한다. 송신 성공은 ACK만 보지 말고 UI 표시와 `TB_KtMessage` 행을 함께 검증한다.

## 실행 전제

- KnoxTeams가 로그인된 Windows 사용자 세션에서 실행 중이어야 한다.
- KnoxTeams 메인 프로세스를 `--inspect=127.0.0.1:9229`로 실행한다.
- inspector는 외부 주소에 바인딩하지 않는다.

## 예시

```powershell
powershell -ExecutionPolicy Bypass -File .\send-via-ui.ps1 `
  -ChannelId 203944618158328832 `
  -Message '클로🐾> 테스트 메시지입니다.'
```

이 파일은 feasibility spike이며 production 코드로 바로 배포하지 않는다.
