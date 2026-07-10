import frida, time

LOG = r"C:\Users\lisyoen\teams-record-work\key_capture.log"
OBS_SEC = 30

def log(msg):
    with open(LOG,'a',encoding='utf-8') as f: f.write(msg+"\n")

JS = r"""
(function(){
  var addr = null;
  try { addr = Module.findGlobalExportByName('napi_get_value_string_utf8'); } catch(e){ send({t:'err',m:'g1 '+e}); }
  if(!addr){ try { addr = Module.getGlobalExportByName('napi_get_value_string_utf8'); } catch(e){} }
  if(!addr){ send({t:'err', m:'napi export not found'}); return; }
  send({t:'info', m:'hook @'+addr});
  var seenSql = 0;
  Interceptor.attach(addr, {
    onEnter: function(a){ this.buf=a[2]; this.skip=this.buf.isNull(); this.sz=a[3].toInt32(); },
    onLeave: function(){
      if(this.skip || this.sz < 6) return;
      try {
        var b0 = this.buf.readU8();
        if(b0===0x50||b0===0x70){
          var s = this.buf.readUtf8String();
          if(s && /pragma\s+key/i.test(s)){ send({t:'KEY', m:s}); return; }
          if(s && /pragma/i.test(s)){ send({t:'pragma', m:s.slice(0,90)}); return; }
        } else if(seenSql<4 && (b0===0x53||b0===0x73||b0===0x49||b0===0x69||b0===0x55||b0===0x75||b0===0x44||b0===0x64)){
          var s2 = this.buf.readUtf8String();
          if(s2 && /^\s*(select|insert|update|delete|create|replace)/i.test(s2)){ seenSql++; send({t:'sql', m:s2.slice(0,70)}); }
        }
      } catch(e){}
    }
  });
})();
"""

open(LOG,'w').close()
try:
    s = frida.attach(3324)
    sc = s.create_script(JS)
    sc.on('message', lambda m,d: log('['+m['payload'].get('t','?')+'] '+str(m['payload'].get('m','')) if m.get('type')=='send' else '[frida] '+str(m)))
    sc.load()
    log('=== observing %ds attach pid 3324 %s ===' % (OBS_SEC, time.strftime('%H:%M:%S')))
    time.sleep(OBS_SEC)
    log('=== done %s ===' % time.strftime('%H:%M:%S'))
    try: sc.unload()
    except: pass
    s.detach()
except Exception as e:
    log('FATAL '+repr(e))
