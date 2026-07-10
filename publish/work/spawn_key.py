import frida, time

LOG = r"C:\Users\lisyoen\teams-record-work\key_spawn.log"
EXE = r"C:\mySingle\KnoxTeams\KnoxTeams.exe"

def log(m):
    with open(LOG,'a',encoding='utf-8') as f: f.write(m+"\n")

JS = r"""
(function(){
  var hooked = false;
  function tryHook(){
    if(hooked) return true;
    var addr=null;
    try { addr = Module.findGlobalExportByName('napi_get_value_string_utf8'); } catch(e){}
    if(!addr) return false;
    hooked = true;
    send({t:'info', m:'hook @'+addr});
    Interceptor.attach(addr, {
      onEnter: function(a){ this.buf=a[2]; this.skip=this.buf.isNull(); this.sz=a[3].toInt32(); },
      onLeave: function(){
        if(this.skip || this.sz < 6) return;
        try {
          var b0 = this.buf.readU8();
          if(b0===0x50||b0===0x70){
            var s = this.buf.readUtf8String();
            if(s && /pragma\s+key/i.test(s)){ send({t:'KEY', m:s}); return; }
            if(s && /pragma/i.test(s)){ send({t:'pragma', m:s.slice(0,120)}); return; }
          }
        } catch(e){}
      }
    });
    return true;
  }
  if(!tryHook()){
    var n=0;
    var iv = setInterval(function(){ n++; if(tryHook() || n>300){ clearInterval(iv); if(!hooked) send({t:'err',m:'napi never found after '+n}); } }, 50);
  }
})();
"""

open(LOG,'w').close()
try:
    pid = frida.spawn([EXE])
    log('spawned pid %d %s' % (pid, time.strftime('%H:%M:%S')))
    s = frida.attach(pid)
    sc = s.create_script(JS)
    got = {'key': False}
    def on_msg(m,d):
        if m.get('type')=='send':
            p=m['payload']; t=p.get('t','?')
            log('['+t+'] '+str(p.get('m','')))
            if t=='KEY': got['key']=True
        else:
            log('[frida] '+str(m))
    sc.on('message', on_msg)
    sc.load()
    frida.resume(pid)
    log('resumed %s' % time.strftime('%H:%M:%S'))
    for _ in range(45):
        time.sleep(1)
        if got['key']:
            log('=== KEY captured, stop early %s ===' % time.strftime('%H:%M:%S'))
            break
    log('=== done %s key=%s ===' % (time.strftime('%H:%M:%S'), got['key']))
    try: s.detach()
    except: pass
except Exception as e:
    log('FATAL '+repr(e))
