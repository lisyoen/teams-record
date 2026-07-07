# teams-record

회사 업무용 개인 PC(lisyoen-desktop2)의 Knox Teams 대화 기록을 **로컬에 보관**하고 **로컬 뷰어**로 조회하는 도구. 추출·저장·조회 전부 회사PC 로컬 전용, 외부 반출 없음.

> 이 레포는 **기록용(private)**. 실제 추출된 메시지 데이터·복호화 키·`.store` 원본·DB 스냅샷은 커밋하지 않음(.gitignore 참조). 방법/코드/문서만 보관.

## 성격 및 보안 관점
- 사내 보안규정 우회가 아니라, Knox Teams에 없는 대화 내보내기/백업 기능을 로컬에서 보완하는 작업.
- 본인 계정의 본인 대화 기록을 회사PC 로컬에만 보관·조회. 외부 반출·타인 열람 없음. 접근 권한 범위는 기존과 동일(본인만). 신규 권한 획득이나 보안 통제 무력화 아님.

## 대상 분석 (2026-07-07)
- Knox Teams = 삼성SDS mySingle 계보, Electron. 설치 `C:\mySingle\KnoxTeams`.
- 메시징: 네이티브 RAW TCP(nq_tcpmodule) + Protobuf over TLS, 포트 5223 (REST 아님). 443은 보조.
- 메시지 DB: `%APPDATA%\KnoxTeams\prd\<dbhash>.db` (SQLite WAL). 헤더 고엔트로피 → SQLCipher(@journeyapps/sqlcipher 추정, Signal 동일 스택). DB 소유 프로세스가 node_sqlite3.node 로드.
- 설정: `commonConfig.store` / `prd\config_<dbhash>.store` = CryptoJS AES(OpenSSL "Salted__"). DB별 SQLCipher 키가 config.store 안 추정.

## 복호화 체인
```
app.asar(JS)          → CryptoJS 패스프레이즈 P
config_<dbhash>.store → CryptoJS.AES.decrypt(store, P) → SQLCipher 키 K
<dbhash>.db           → SQLCipher(PRAGMA key=K) → 평문 메시지
```

## 접근법
- 정적 우선: app.asar 패스프레이즈 → config.store 복호 → SQLCipher 키 → DB open.
- 폴백: Frida 런타임 후킹 (Frida 17.15.3 회사PC 설치, DB 소유 프로세스 attach 성공 확인).

## 구성(예정)
- `extractor/` : 회사PC 로컬 Python 추출기 (DB 스냅샷 → 복호 → 정규화 → 로컬 아카이브)
- `viewer/` : 로컬 뷰어 (localhost 바인딩)

## 상태
기획중 — 키 회수 PoC 예정. 상세 기획/현황은 spark-home craftbay-docs `proposals/teams-record.md`, `settings/projects/teams-record.md`.
