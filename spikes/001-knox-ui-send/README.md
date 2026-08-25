# KnoxTeams UI 송신 spike

## Verdict: INVALIDATED FOR UNATTENDED USE

Question: KnoxTeams의 저수준 `sendKtMessage`를 직접 호출하지 않고 실제 작성창 경로를 사용해 서버 송신, PC UI 표시, 로컬 DB 저장을 함께 수행할 수 있는가?

Evidence:

- 대상 채널: `203944618158328832` (`노숙진-이창연`)
- 실제 작성창에 Chromium `Input.insertText`로 입력한 뒤 활성화된 `전송` 버튼을 클릭
- 전송 직후 PC UI에서 문구 표시 확인
- `teams-record` 갱신 후 `TB_KtMessage`에서 MessageId `1787644886597458`, MessageKey `140069376879260000`, State `0`, Recalled `0`, Deleted `0` 확인
- 전송 직후에는 KnoxTeams 메인 프로세스와 렌더러가 실행 중이었으나, 사용자가 잠시 뒤 클라이언트 종료를 확인함

What worked: Electron main inspector에서 `webContents.debugger`를 통해 실제 렌더러에 키 입력을 전달하면 ToastUI/React 상태, KnoxTeams saga/dispatch, 서버 송신, 로컬 DB 저장이 모두 정상적으로 이어진다.

What failed or surprised us: `messageManager.sendKtMessage` 직접 호출은 서버와 모바일에는 전달되지만 발신 PC의 UI와 로컬 DB를 갱신하지 않는다. DOM의 `value`나 `innerText`만 바꾸는 방식도 React/ToastUI 상태를 갱신하지 못해 전송 버튼이 활성화되지 않는다.

Lifecycle limitation: 사용자 세션에 inspector 옵션으로 KnoxTeams를 다시 띄우는 임시 Scheduled Task 방식에서는 전송 직후 검사 때 프로세스가 살아 있었지만 이후 클라이언트가 종료되는 현상이 재현됐다. 따라서 송신 경로 자체는 검증됐지만, 평소 실행 중인 클라이언트에 무중단으로 연결하는 방식은 아직 검증되지 않았다. 프로세스 생존을 단기 조회만으로 성공 판정하지 않는다.

Focus safety failure: 세 번째 테스트에서 자동화가 화면의 현재 포커스 작성창에 키보드 입력을 주입했고 사용자가 이를 직접 발견했다. 사후 DB에는 의도한 `이창연 개인대화 > 노숙진-이창연` 채널로 저장됐지만, 입력 전에 화면상 선택된 워크스페이스·채널·작성창을 독립적으로 검증하지 못했으므로 오발송 방지 요건을 충족하지 않는다. URL ID 확인만으로 대상 채널을 확정하지 않는다.

Recommendation: production bridge는 저수준 worker 호출이 아니라 이 UI 입력 경로 또는 확인된 공식 saga action을 사용한다. 송신 성공은 ACK만 보지 말고 UI 표시와 `TB_KtMessage` 행을 함께 검증한다. 앱 실행·종료를 관리하는 임시 Scheduled Task는 production 경로에서 제외하고, 이미 실행 중인 사용자 클라이언트에 붙는 안정적인 브리지부터 별도로 검증한다.

현재 `send-via-ui.ps1`은 안전장치로 실행 즉시 중단되도록 비활성화했다. 화면상 워크스페이스 제목, 채널 제목, 채널 ID, 참여자 목록을 입력 전에 모두 대조하고 불일치 시 키 입력 전에 실패하는 fail-closed 검증이 구현되기 전에는 다시 활성화하지 않는다.

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
