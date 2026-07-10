const path=require('path'), fs=require('fs');
const WORK=path.join(process.env.USERPROFILE,'teams-record-work');
const sqlite3=require(path.join(WORK,'sqlite3.js')).verbose();
const key=fs.readFileSync(path.join(WORK,'dbkey.secret'),'utf8').trim();
const SRC=path.join(WORK,'snap.db');
const OUTDIR=process.env.TEAMS_DB_DIR;
if(!OUTDIR){ console.log('ERROR: TEAMS_DB_DIR is not set'); process.exit(1); }
const OUT=path.join(OUTDIR,'teams-decrypted.db');
const OUT_SQL=OUT.replace(/\\/g,'/');
try{fs.mkdirSync(OUTDIR,{recursive:true});}catch(e){}
try{fs.unlinkSync(OUT);}catch(e){}
try{fs.unlinkSync(OUT+'-wal');}catch(e){}
try{fs.unlinkSync(OUT+'-shm');}catch(e){}
const db=new sqlite3.Database(SRC, sqlite3.OPEN_READWRITE|sqlite3.OPEN_CREATE, (err)=>{if(err){console.log('OPEN_ERR '+err.message);process.exit(1);}});
db.serialize(()=>{
  db.run("PRAGMA cipher_compatibility=4");
  db.run("PRAGMA key='"+key+"'");
  db.run("ATTACH DATABASE '"+OUT_SQL+"' AS plaintext KEY ''",(e)=>{if(e)console.log('ATTACH_ERR '+e.message);});
  db.get("SELECT sqlcipher_export('plaintext') AS r",(e)=>{
    if(e){console.log('EXPORT_ERR '+e.message);}
    else{console.log('EXPORT_OK');}
    db.run("DETACH DATABASE plaintext",()=>{ db.close(()=>{ verify(); }); });
  });
});
function verify(){
  const v=new sqlite3.Database(OUT, sqlite3.OPEN_READONLY,(err)=>{if(err){console.log('VERIFY_OPEN_ERR(암호아직걸림?) '+err.message);process.exit(1);}});
  v.serialize(()=>{
    v.all("SELECT type,name FROM sqlite_master WHERE type IN ('table','view') ORDER BY type,name",(e,rows)=>{
      if(e){console.log('VERIFY_ERR '+e.message);return;}
      const tbls=rows.filter(r=>r.type==='table').map(r=>r.name);
      const views=rows.filter(r=>r.type==='view').map(r=>r.name);
      console.log('PLAINTEXT_OPEN_OK(키없이열림)');
      console.log('TABLES('+tbls.length+': '+tbls.join(', '));
      if(views.length)console.log('VIEWS('+views.length+'): '+views.join(', '));
    });
    v.all("SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type,name",(e,rows)=>{
      if(!e){ fs.writeFileSync(path.join(OUTDIR,'schema.sql'), rows.map(r=>r.sql+';').join('\n\n'),'utf8'); console.log('SCHEMA_SQL_WRITTEN objects='+rows.length); }
    });
    v.get("SELECT count(*) c FROM TB_KtMessage",(e,r)=>{ if(!e)console.log('TB_KtMessage_rows='+r.c); });
    v.close(()=>{ const st=fs.statSync(OUT); console.log('OUT_SIZE_BYTES='+st.size); console.log('DONE'); });
  });
}
