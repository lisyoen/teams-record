# Teams Viewer Electron

로컬 Teams Record 백엔드(`127.0.0.1:8799`)를 전용 창에 표시하는 기본
클라이언트입니다. `publish\install.bat`가 Node.js/npm을 확인하고
`package-lock.json` 기준 Electron 의존성을 설치한 뒤 바탕화면 바로가기를 이
앱에 연결합니다.

앱은 `..\viewer\server.py` 준비 상태를 확인하고, 필요하면 `pythonw.exe`로
콘솔창 없이 시작한 뒤 최대 30초 동안 기다립니다. 브라우저는 자동으로 열지
않습니다.

개발 확인:

```text
npm ci --include=dev
npm run check
npm start
```
