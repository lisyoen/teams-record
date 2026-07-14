// decrypt_db.js — 독립 실행형 SQLCipher 복호화 스크립트
//
// 암호화된 Knox Teams SQLite(SQLCipher, cipher_compatibility=4) 파일 하나를
// 평문 SQLite 파일로 복호화한다. refresh 흐름과 무관하게 임의의 암호화 db를 지정해 쓸 수 있다.
//
// 실행: KnoxTeams.exe 를 Node 런타임으로 사용(내장 SQLCipher 바인딩 재사용).
//   set ELECTRON_RUN_AS_NODE=1
//   "%KNOX_ROOT%\KnoxTeams.exe" decrypt_db.js <입력암호화db> [출력평문db] [--key <값|파일>]
//
// 인자:
//   <입력암호화db>  (필수) 복호화할 SQLCipher db 경로
//   [출력평문db]     (선택) 생략 시 "<입력>.plain.db"
//   --key <값|파일>  (선택) SQLCipher 키. 생략 시 %USERPROFILE%\teams-record-work\dbkey.secret 사용.
//                    값이 기존 파일 경로면 그 파일 내용을, 아니면 값 자체를 키로 사용.
//
// 주의: 산출된 평문 db 는 시크릿에 준하는 사내 데이터다. 외부 반출/zip 포함 금지.

const path = require('path');
const fs = require('fs');

function fail(msg, code) { console.log('ERROR: ' + msg); process.exit(code || 1); }

// ---- 인자 파싱 ----
const argv = process.argv.slice(2);
let SRC = null, OUT = null, keyArg = null;
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--key') { keyArg = argv[++i]; }
  else if (a === '-h' || a === '--help') {
    console.log('usage: KnoxTeams.exe decrypt_db.js <encrypted.db> [plaintext.db] [--key <value|file>]');
    process.exit(0);
  }
  else if (!SRC) { SRC = a; }
  else if (!OUT) { OUT = a; }
}
if (!SRC) { fail('input encrypted db path is required. usage: decrypt_db.js <encrypted.db> [plaintext.db] [--key <value|file>]', 2); }
SRC = path.resolve(SRC);
if (!fs.existsSync(SRC)) { fail('input db not found: ' + SRC, 2); }
if (!OUT) { OUT = SRC.replace(/\.db$/i, '') + '.plain.db'; }
OUT = path.resolve(OUT);
if (path.resolve(OUT) === path.resolve(SRC)) { fail('output path must differ from input', 2); }

// ---- 키 결정: --key(값 또는 파일) 우선, 없으면 work\dbkey.secret ----
const WORK = path.join(process.env.USERPROFILE || '', 'teams-record-work');
let key = null, keySource = null;
if (keyArg) {
  if (fs.existsSync(keyArg) && fs.statSync(keyArg).isFile()) {
    key = fs.readFileSync(keyArg, 'utf8').trim(); keySource = 'file:' + keyArg;
  } else {
    key = keyArg.trim(); keySource = 'inline-arg';
  }
} else {
  const secret = path.join(WORK, 'dbkey.secret');
  if (!fs.existsSync(secret)) {
    fail('no --key given and dbkey.secret not found at ' + secret + '. Run publish\\capture-key.bat after Knox login, or pass --key.', 3);
  }
  key = fs.readFileSync(secret, 'utf8').trim(); keySource = 'work/dbkey.secret';
}
if (!key) { fail('empty key', 3); }

// ---- sqlite3(SQLCipher) 바인딩 로드: work\sqlite3.js 재사용 ----
let sqlite3;
try {
  sqlite3 = require(path.join(WORK, 'sqlite3.js')).verbose();
} catch (e) {
  fail('failed to load sqlite3.js from ' + WORK + ' (' + e.message + '). Run this via KnoxTeams.exe with ELECTRON_RUN_AS_NODE=1.', 4);
}

const OUT_SQL = OUT.replace(/\\/g, '/');
try { fs.mkdirSync(path.dirname(OUT), { recursive: true }); } catch (e) {}
for (const suff of ['', '-wal', '-shm']) { try { fs.unlinkSync(OUT + suff); } catch (e) {} }

console.log('SRC   = ' + SRC);
console.log('OUT   = ' + OUT);
console.log('KEY   = ' + keySource);

const db = new sqlite3.Database(SRC, sqlite3.OPEN_READONLY, (err) => {
  if (err) { fail('OPEN_ERR ' + err.message, 5); }
});
db.serialize(() => {
  db.run("PRAGMA cipher_compatibility=4");
  db.run("PRAGMA key='" + key.replace(/'/g, "''") + "'");
  db.run("ATTACH DATABASE '" + OUT_SQL + "' AS plaintext KEY ''", (e) => { if (e) console.log('ATTACH_ERR ' + e.message); });
  db.get("SELECT sqlcipher_export('plaintext') AS r", (e) => {
    if (e) { console.log('EXPORT_ERR ' + e.message + ' (wrong key or not SQLCipher?)'); }
    else { console.log('EXPORT_OK'); }
    db.run("DETACH DATABASE plaintext", () => { db.close(() => { verify(!!e); }); });
  });
});

function verify(hadError) {
  const v = new sqlite3.Database(OUT, sqlite3.OPEN_READONLY, (err) => {
    if (err) { fail('VERIFY_OPEN_ERR (still encrypted? wrong key?) ' + err.message, 6); }
  });
  v.serialize(() => {
    v.all("SELECT type,name FROM sqlite_master WHERE type IN ('table','view') ORDER BY type,name", (e, rows) => {
      if (e) { console.log('VERIFY_ERR ' + e.message); return; }
      const tbls = rows.filter(r => r.type === 'table').map(r => r.name);
      console.log('PLAINTEXT_OPEN_OK (opened without key)');
      console.log('TABLES(' + tbls.length + ')');
    });
    v.get("SELECT count(*) c FROM TB_KtMessage", (e, r) => { if (!e) console.log('TB_KtMessage_rows=' + r.c); });
    v.get("SELECT count(*) c FROM TB_KmMessage", (e, r) => { if (!e) console.log('TB_KmMessage_rows=' + r.c); });
    v.close(() => {
      try { const st = fs.statSync(OUT); console.log('OUT_SIZE_BYTES=' + st.size); } catch (e) {}
      console.log(hadError ? 'DONE_WITH_ERRORS' : 'DONE');
      process.exit(hadError ? 7 : 0);
    });
  });
}
