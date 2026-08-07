# Teams Record 원격 Viewer

기존 `viewer/server.py`의 `127.0.0.1:8799` 로컬 전용 경계는 그대로 두고, `remote_web/server.py`가 인증·계정별 DB 격리·안전한 업로드를 추가합니다.

## 보안 구조

- 로그인 비밀번호는 PBKDF2-SHA256 60만 회 해시만 서버 설정에 저장합니다.
- DB 업로드 토큰은 로그인 비밀번호와 분리하며 SHA-256 해시만 서버에 저장합니다.
- 로그인 세션은 무작위 토큰의 해시만 서버 SQLite에 저장하고, 쿠키는 `Secure`, `HttpOnly`, `SameSite=Strict`로 설정합니다.
- 로그인 실패는 IP·아이디 조합별로 제한하며, POST 로그아웃에는 서버 세션의 CSRF 토큰을 사용합니다.
- 각 사용자는 `<dataRoot>/<username>/teams-archive.db`만 열 수 있습니다. 사용자 이름은 안전한 고정 문자만 허용하고 요청 경로를 파일 경로로 사용하지 않습니다.
- 업로드는 크기·Content-Type·SQLite 헤더·`PRAGMA quick_check`·필수 테이블을 검사한 임시 파일만 원자적으로 교체합니다. 실패한 파일은 기존 DB를 덮지 않습니다.
- 원격 Viewer에서 로컬 갱신·자가 업데이트 API와 DB 다운로드는 차단합니다.

## 서버 준비

```bash
install -d -m 700 /home/lisyoen/.config/teams-record-remote
install -d -m 700 /home/lisyoen/.local/state/teams-record-remote
install -d -m 700 /home/lisyoen/.local/share/teams-record-remote/users
```

비밀번호와 업로드 토큰은 셸 인자나 이력에 넣지 않고 표준입력으로 해시합니다.

```bash
python3 remote_web/server.py hash-password --stdin
python3 remote_web/server.py hash-token --stdin
```

`config.example.json`을 참고해 `/home/lisyoen/.config/teams-record-remote/config.json`을 만들고 권한을 `0600`으로 설정합니다. 설정에는 평문 비밀번호나 평문 업로드 토큰을 넣지 않습니다.

```bash
python3 remote_web/server.py serve --config /home/lisyoen/.config/teams-record-remote/config.json
pm2 start remote_web/ecosystem.config.cjs
pm2 save
```

서비스는 기본적으로 `127.0.0.1:9240`에만 바인딩합니다. Cloudflare Tunnel origin만 접근하고 LAN이나 공인 인터페이스에는 직접 노출하지 않습니다.

## Cloudflare 연결

공유 Tunnel 설정의 최종 `http_status:404` 앞에 아래 ingress 한 개를 추가합니다.

```yaml
  - hostname: teams-record.craftbay.io
    service: http://127.0.0.1:9240
```

적용 전후에 다음을 확인합니다.

```bash
cloudflared tunnel ingress validate
cloudflared tunnel route dns 5bd2fd2c-665c-4d85-959d-54c3eca2a743 teams-record.craftbay.io
curl -fsS http://127.0.0.1:9240/healthz
curl -fsS https://teams-record.craftbay.io/healthz
```

공유 `cloudflared` 재시작은 다른 호스트명에도 순간 영향을 줄 수 있으므로 설정 백업·검증 후 운영자가 적용합니다. 롤백은 해당 ingress와 DNS route를 제거하고 새 `teams-record-remote` PM2 앱만 중지하는 방식이며 기존 로컬 Viewer에는 영향이 없습니다.

## 회사 PC 동기화

`sync_windows.ps1`은 기존 `viewer\update-db.bat`를 숨김 실행한 뒤 누적 `teams-archive.db`만 HTTPS 업로드합니다. 평문 업로드 토큰은 Git 밖의 `%LOCALAPPDATA%\teams-record\remote-upload.token`에 한 줄로 저장합니다.

리버스터널이나 서비스 실행 계정이 잘못된 `APPDATA` 값을 상속하는 경우를 막기 위해 스크립트는 `UserProfilePath` 기준으로 `USERPROFILE`·`APPDATA`·`LOCALAPPDATA`를 명시적으로 설정한 뒤 복호화 갱신을 실행합니다.

도메인과 서버 업로드 검증이 끝난 뒤에만 회사 PC에서 다음 순서로 설치합니다.

1. `remote-upload.token`을 만들고 현재 Windows 사용자와 SYSTEM만 읽도록 ACL을 제한합니다.
2. 수동 1회 실행으로 갱신·업로드 결과를 확인합니다.
3. `install_sync_task.ps1`로 숨김 예약작업을 등록합니다. 기본 주기는 10분이며 중복 실행은 무시합니다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\git\teams-record\remote_web\sync_windows.ps1 -Username lisyoen
powershell -NoProfile -ExecutionPolicy Bypass -File D:\git\teams-record\remote_web\install_sync_task.ps1 -Username lisyoen
```

## 두 번째 사용자 추가

두 번째 사용자는 다음 네 가지를 모두 별도로 만듭니다.

1. 로그인 비밀번호 해시
2. 무작위 업로드 토큰과 서버에 넣을 토큰 해시
3. 서버 `users[]` 항목
4. 해당 PC의 로컬 토큰 파일과 예약작업

서버는 로그인 사용자의 데이터 디렉터리만 모듈에 연결하고, 업로드도 `X-Teams-Record-User`와 그 사용자의 전용 업로드 토큰이 함께 맞아야 승인합니다. 따라서 노숙진 계정을 추가해도 `lisyoen` DB와 경로를 공유하지 않습니다.

## 테스트

```bash
python3 -m pytest -q tests/test_remote_web.py
python3 -m pytest -q
```
