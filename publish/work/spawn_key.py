import os, sys, time, threading
try:
    import frida
except Exception as e:  # 1.3.2: report a broken runtime instead of failing silently
    sys.stderr.write('frida import failed: %r\n' % (e,)); raise

WORK = os.environ.get('TEAMS_RECORD_WORK') or os.path.join(os.path.expanduser('~'), 'teams-record-work')
LOG = os.path.join(WORK, 'key_spawn.log')
EXE = os.path.join(os.environ.get('KNOX_ROOT', r'C:\mySingle\KnoxTeams'), 'KnoxTeams.exe')

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

# 1.3.2: watch the spawned Knox Teams windows. When this script runs under a hidden agent (Skipper Mate),
# the spawned window can start hidden, so the user signs in to nothing and the key never appears.
# Log what windows exist and show a titled main window that stays hidden.
def watch_windows(pid, stop):
    if os.name != 'nt':
        return
    try:
        import ctypes
        from ctypes import wintypes
        user32 = ctypes.windll.user32
        EnumProc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    except Exception as e:
        log('[win] watcher unavailable %r' % (e,)); return
    show_hidden = (os.environ.get('TEAMS_RECORD_SHOW_HIDDEN') or '1') != '0'
    shown, last, started = set(), None, time.time()
    while not stop.is_set():
        wins = []
        def cb(h, _):
            p = wintypes.DWORD(); user32.GetWindowThreadProcessId(h, ctypes.byref(p))
            if p.value == pid:
                cls = ctypes.create_unicode_buffer(128); user32.GetClassNameW(h, cls, 128)
                n = user32.GetWindowTextLengthW(h); title = ctypes.create_unicode_buffer(n + 1); user32.GetWindowTextW(h, title, n + 1)
                wins.append((int(h or 0), cls.value, title.value, bool(user32.IsWindowVisible(h))))
            return True
        try:
            user32.EnumWindows(EnumProc(cb), 0)
        except Exception as e:
            log('[win] enum failed %r' % (e,)); return
        titled = [w for w in wins if w[2]]
        snap = tuple((w[1], w[2], w[3]) for w in titled)
        if snap != last:
            log('[win] %s %d windows, titled: %s' % (time.strftime('%H:%M:%S'), len(wins), '; '.join('%s "%s" %s' % (c, t[:40], 'visible' if v else 'hidden') for c, t, v in snap) or '-'))
            last = snap
        if show_hidden and time.time() - started > 8 and not any(w[3] for w in titled):
            for h, c, t, v in titled:
                if c.startswith('Chrome_WidgetWin') and h not in shown:
                    user32.ShowWindow(h, 1); user32.SetForegroundWindow(h); shown.add(h)
                    log('[win] showed hidden window "%s"' % t[:40])
        stop.wait(2)

open(LOG,'w').close()
log('session %s pid=%d' % (os.environ.get('USERNAME', '?'), os.getpid()))
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
    stop = threading.Event(); threading.Thread(target=watch_windows, args=(pid, stop), daemon=True).start()
    for _ in range(int(os.environ.get('TEAMS_RECORD_KEY_WAIT') or 90)):   # 1.3.1: 45 s was too short when sign-in is slow
        time.sleep(1)
        if got['key']:
            log('=== KEY captured, stop early %s ===' % time.strftime('%H:%M:%S'))
            break
    stop.set()
    log('=== done %s key=%s ===' % (time.strftime('%H:%M:%S'), got['key']))
    try: s.detach()
    except: pass
except Exception as e:
    log('FATAL '+repr(e))
