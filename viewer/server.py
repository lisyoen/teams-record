#!/usr/bin/env python3
"""teams-record local viewer (MVP)
- Company-PC (lisyoen-desktop2) local only. Binds 127.0.0.1:8799 (no external exposure).
- Data source: viewer package root teams-archive.db, falling back to teams-decrypted.db.
- UI spec: teams-record repo design/viewer-ui-design.md (commit 6e2f93e) + assets/04 bubble layout.
"""
import base64, json, os, re, sqlite3, subprocess, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

# Prefer cumulative archive (retains messages aged out of live DB); fall back to
# the single-shot decrypted snapshot.
_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_ARCHIVE = os.path.join(_ROOT, 'teams-archive.db')
_SNAPSHOT = os.path.join(_ROOT, 'teams-decrypted.db')
DB = _ARCHIVE if os.path.exists(_ARCHIVE) else _SNAPSHOT
PORT = 8799
MY_ID = '754107854600802305'
REFRESH_BAT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'refresh_archive.bat')
_REFRESH_LOCK = threading.Lock()
THUMBS_DIR = os.path.join(_ROOT, 'thumbs')
CMD_RE = re.compile(r'^\s*<!--.*?-->\s*', re.S)
FAVICON_SVG = (
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">'
    '<rect width="32" height="32" rx="7" fill="#5b5fc7"/>'
    '<rect x="6" y="8" width="20" height="14" rx="3.5" fill="#fff"/>'
    '<path d="M11 22 L11 27 L16 22 Z" fill="#fff"/>'
    '<circle cx="12" cy="15" r="1.7" fill="#5b5fc7"/>'
    '<circle cx="16" cy="15" r="1.7" fill="#5b5fc7"/>'
    '<circle cx="20" cy="15" r="1.7" fill="#5b5fc7"/>'
    '</svg>'
)
FAVICON_ICO_B64 = (
    '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'
)

def db():
    con = sqlite3.connect('file:///' + DB.replace('\\', '/') + '?mode=ro', uri=True)
    con.row_factory = sqlite3.Row
    return con

def q(sql, args=()):
    con = db()
    try:
        return [dict(r) for r in con.execute(sql, args)]
    finally:
        con.close()

def load_contacts():
    c = {}
    for t in ('TB_KtContact', 'TB_KmContact'):
        try:
            rows = q('SELECT UserID,LocalName,Department,CompanyName,Position FROM ' + t)
        except Exception:
            rows = []
        for r in rows:
            uid = str(r['UserID'])
            cur = c.setdefault(uid, {})
            for k in ('LocalName', 'Department', 'CompanyName', 'Position'):
                v = r.get(k)
                if v and not cur.get(k):
                    cur[k] = v
    return c

def clean(txt):
    txt = CMD_RE.sub('', txt or '').strip()
    if not txt or txt[0] not in '[{':
        return txt
    try:
        data = json.loads(txt)
    except Exception:
        return txt
    vals = []

    def add(v):
        if isinstance(v, str) and v.strip():
            vals.append(CMD_RE.sub('', v).strip())

    if isinstance(data, dict):
        for k in ('text', 'message', 'plainText'):
            add(data.get(k))
        body = data.get('body')
        if isinstance(body, dict):
            for k in ('content', 'text', 'plainText'):
                add(body.get(k))
        content = data.get('content')
        if isinstance(content, dict):
            for k in ('text', 'plainText'):
                add(content.get(k))
        else:
            add(content)
    elif isinstance(data, list):
        for e in data:
            if isinstance(e, dict):
                for k in ('text', 'message', 'content'):
                    add(e.get(k))
            else:
                add(e)
    return '\n'.join(vals).strip()

def parse_reactions(ri):
    out = []
    if not ri:
        return out
    try:
        for e in json.loads(ri):
            out.append({'e': e.get('emoji'), 'c': e.get('count'),
                        'u': [u for u in (e.get('users') or '').split(',') if u],
                        'm': bool(e.get('isMine'))})
    except Exception:
        pass
    return out

def parse_media(content):
    """MessageType 13 = media/file attachment JSON (media.type file|image)."""
    if not content:
        return None
    try:
        m = json.loads(content).get('media') or {}
    except Exception:
        return None
    if not m.get('filename') and not m.get('url'):
        return None
    return {'kind': m.get('type'), 'ext': (m.get('extension') or '').lower(),
            'name': m.get('filename') or m.get('info') or '(파일)',
            'size': m.get('size'), 'url': m.get('url'), 'fid': m.get('espFileId')}


_NAME_CACHE = None


def _name_of(uid):
    """Resolve contact LocalName for a userId (lazy cached from TB_*Contact)."""
    global _NAME_CACHE
    if _NAME_CACHE is None:
        try:
            _NAME_CACHE = {k: (v.get('LocalName') or '') for k, v in load_contacts().items()}
        except Exception:
            _NAME_CACHE = {}
    return _NAME_CACHE.get(str(uid)) or ''


def _dn(uid, data1=None):
    """Display name for a system-event participant (contact name > data1 > userId)."""
    sid = '' if uid is None else str(uid)
    name = (_name_of(sid) or data1 or '').strip()
    if sid == MY_ID:
        return (name or '이창연') + ' (AI 서비스 에이전트)'
    return name or sid


def _room_title(row, cons):
    title = (row.get('t') or row.get('Title') or '').strip()
    rid = str(row.get('i') or row.get('ChatroomID') or row.get('ChatroomId') or '')
    if title:
        return title
    names = []
    for i in re.findall(r'\d{12,}', row.get('pi') or row.get('ParticipantInfos') or ''):
        if i != MY_ID:
            n = cons.get(i, {}).get('LocalName')
            if n and n not in names:
                names.append(n)
    return ', '.join(names[:4]) if names else ('(방 ' + rid[:8] + ')')


def _channel_title_map():
    out = {}
    try:
        rows = q('SELECT ChannelID i,Title t FROM TB_Channel')
    except Exception:
        return out
    for r in rows:
        out[str(r.get('i'))] = r.get('t') or str(r.get('i'))
    return out


def _room_title_map(cons=None):
    cons = cons if cons is not None else load_contacts()
    out = {}
    try:
        rows = q('SELECT ChatroomID i,Title t,ParticipantInfos pi FROM TB_Chatroom')
    except Exception:
        return out
    for r in rows:
        out[str(r.get('i'))] = _room_title(r, cons)
    return out


def _snippet(text, term, radius=40):
    flat = re.sub(r'\s+', ' ', text or '').strip()
    needle = (term or '').casefold()
    pos = flat.casefold().find(needle)
    if pos < 0:
        return flat[:radius * 2]
    start = max(0, pos - radius)
    end = min(len(flat), pos + len(term) + radius)
    return ('…' if start else '') + flat[start:end] + ('…' if end < len(flat) else '')


def parse_system4(content, sender):
    """MessageType 4 = channel participation system events (ENTER/LEAVE/EXPELLED/TITLE/CUSTOM_NOTI)."""
    try:
        arr = json.loads(content or '[]')
    except Exception:
        return None, '[시스템 메시지]'
    if not isinstance(arr, list):
        return None, '[시스템 메시지]'

    def np(name):
        return name + '님'

    sender = '' if sender is None else str(sender)
    lines = []
    enters = []
    for e in arr:
        if not isinstance(e, dict):
            continue
        et = e.get('type')
        if et == 'ENTER':
            enters.append(e)
        elif et == 'LEAVE':
            lines.append(np(_dn(e.get('userId'), e.get('data1'))) + '이 나갔습니다.')
        elif et == 'EXPELLED':
            actor = _dn(e.get('data2'), e.get('data3'))
            target = _dn(e.get('userId'), e.get('data1'))
            lines.append(np(actor) + '이 ' + np(target) + '을 내보냈습니다.')
        elif et == 'CHATROOM_TITLE_UPDATED':
            actor = _dn(e.get('userId'), e.get('data1'))
            title = (e.get('data2') or '').strip()
            lines.append(np(actor) + "이 대화방 이름을 '" + title + "'(으)로 변경했습니다.")
        elif et == 'CUSTOM_NOTI':
            noti = (e.get('data3') or e.get('data2') or '').strip()
            if noti:
                lines.append(noti)
    if enters:
        invitees = []
        for e in enters:
            if str(e.get('userId')) == sender:
                continue
            name = _dn(e.get('userId'), e.get('data1'))
            if name and name not in invitees:
                invitees.append(name)
        inviter_data1 = None
        for e in enters:
            if str(e.get('userId')) == sender:
                inviter_data1 = e.get('data1')
                break
        inviter = _dn(sender, inviter_data1)
        if invitees:
            names = ', '.join(np(n) for n in invitees)
            enter_line = np(inviter) + '이 ' + names + '을 초대했습니다.'
        else:
            enter_line = np(inviter) + '이 참여했습니다.'
        lines.insert(0, enter_line)
    if not lines:
        return None, '[시스템 메시지]'
    return '\n'.join(lines), None


def load_room_horizons(cid):
    """For a chatroom, return (ends, others):
    ends   = {participant_uid: consumption_horizon_end_epoch_ms}
    others = [uid, ...] participants excluding me (the read-receipt audience).
    ParticipantInfos JSON shape: [[uid, {"start":..,"end":..}], ...].
    """
    ends, others = {}, []
    try:
        row = q('SELECT ParticipantInfos pi FROM TB_Chatroom WHERE ChatroomID=?', (cid,))
        pi = json.loads(row[0]['pi']) if row and row[0].get('pi') else []
        for uid, info in pi:
            uid = str(uid)
            e = info.get('end') if isinstance(info, dict) else None
            ends[uid] = e
            if uid != MY_ID:
                others.append(uid)
    except Exception:
        return {}, []
    return ends, others

def norm(r, kind, ends=None, others=None):
    m = {'id': r.get('MessageId'), 't': r.get('SentTime'), 's': str(r.get('Sender') or ''),
         'txt': clean(r.get('Content')), 're': parse_reactions(r.get('ReactionInfo')),
         'sys': None, 'label': None, 'media': None}
    # read receipts: for my own messages in 1:1/group rooms, count participants
    # (excluding me) whose consumption horizon (end) has passed this SentTime.
    if others and str(r.get('Sender') or '') == MY_ID and r.get('SentTime') is not None:
        st = r.get('SentTime')
        rd = sum(1 for u in others if ends.get(u) is not None and ends[u] >= st)
        m['rd'] = rd
        m['rt'] = len(others)
    if r.get('Recalled'):
        m['sys'] = '회수된 메시지입니다'
    if kind == 'kt' and r.get('Deleted'):
        m['sys'] = '삭제된 메시지입니다'
    if kind == 'km' and r.get('DeleteRequesterId'):
        m['sys'] = '삭제된 메시지입니다'
    mt = r.get('MessageType')
    if mt == 4:
        m['sys'], m['label'] = parse_system4(r.get('Content'), r.get('Sender'))
        m['txt'] = ''
    elif mt == 13:
        media = parse_media(r.get('Content'))
        if media:
            m['media'] = media
            m['txt'] = ''
        else:
            m['label'] = '[미디어]'
    elif mt not in (0, None):
        if r.get('FileName'):
            m['label'] = '[파일] ' + str(r['FileName'])
        else:
            m['label'] = '[유형 ' + str(mt) + ']'
    return m

def api_bootstrap():
    cons = load_contacts()
    ws = q('SELECT WorkspaceID w,Title t,WorkspaceColor c FROM TB_Workspace '
           'ORDER BY COALESCE(DisplayIndex,9999),Title')
    chs = q('SELECT ChannelID i,WorkspaceID w,Title t,IsDefault dflt,LastMsgTime lt '
            'FROM TB_Channel ORDER BY IsDefault DESC,Title')
    byws = {}
    for c in chs:
        byws.setdefault(c['w'], []).append(c)
    rooms = q('SELECT ChatroomID i,Title t,ParticipantInfos pi,LastMsgBody lb,LastMsgTime lt '
              'FROM TB_Chatroom ORDER BY COALESCE(LastMsgTime,0) DESC')
    for r in rooms:
        r['t'] = _room_title(r, cons)
        r['lb'] = clean(r.get('lb'))[:60]
        r.pop('pi', None)
    return {'my': MY_ID, 'ws': ws, 'channels': byws, 'rooms': rooms, 'contacts': cons}

def api_search(term):
    term = (term or '').strip()
    empty = {'q': '', 'count': 0, 'truncated': False, 'results': []}
    if not term:
        return empty
    needle = term.casefold()
    channel_titles = _channel_title_map()
    contacts = load_contacts()
    room_titles = _room_title_map(contacts)
    rows = []
    like = '%' + term + '%'
    try:
        for r in q('SELECT MessageId,ChannelID,Content,MessageType,SentTime,Sender,Recalled,Deleted,'
                   'ReactionInfo FROM TB_KtMessage WHERE Content LIKE ? ORDER BY SentTime DESC', (like,)):
            if r.get('MessageType') in (4, 13):
                continue
            text = clean(r.get('Content'))
            if needle not in text.casefold():
                continue
            cid = str(r.get('ChannelID') or '')
            sid = str(r.get('Sender') or '')
            rows.append({'kind': 'kt', 'id': cid, 'title': channel_titles.get(cid) or ('# ' + cid),
                         's': sid, 'sname': _name_of(sid), 't': r.get('SentTime'),
                         'mid': r.get('MessageId'), 'snippet': _snippet(text, term)})
    except Exception:
        pass
    try:
        for r in q('SELECT MessageId,ChatroomId,Content,MessageType,SentTime,Sender,Recalled,'
                   'DeleteRequesterId,ReactionInfo,FileName FROM TB_KmMessage '
                   'WHERE Content LIKE ? ORDER BY SentTime DESC', (like,)):
            if r.get('MessageType') in (4, 13):
                continue
            text = clean(r.get('Content'))
            if needle not in text.casefold():
                continue
            rid = str(r.get('ChatroomId') or '')
            sid = str(r.get('Sender') or '')
            rows.append({'kind': 'km', 'id': rid, 'title': room_titles.get(rid) or ('(방 ' + rid[:8] + ')'),
                         's': sid, 'sname': _name_of(sid), 't': r.get('SentTime'),
                         'mid': r.get('MessageId'), 'snippet': _snippet(text, term)})
    except Exception:
        pass
    rows.sort(key=lambda r: r.get('t') or 0, reverse=True)
    truncated = len(rows) > 300
    results = rows[:300]
    return {'q': term, 'count': len(results), 'truncated': truncated, 'results': results}

def api_messages(kind, cid):
    if kind == 'kt':
        rows = q('SELECT MessageId,Content,MessageType,SentTime,Sender,Recalled,Deleted,'
                 'ReactionInfo FROM TB_KtMessage WHERE ChannelID=? ORDER BY SentTime', (cid,))
    else:
        rows = q('SELECT MessageId,Content,MessageType,SentTime,Sender,Recalled,'
                 'DeleteRequesterId,ReactionInfo,FileName FROM TB_KmMessage '
                 'WHERE ChatroomId=? ORDER BY SentTime', (cid,))
        ends, others = load_room_horizons(cid)
        return [norm(r, kind, ends, others) for r in rows]
    return [norm(r, kind) for r in rows]

def read_thumb(fid):
    """Return (bytes, content_type) for a locally-cached thumbnail, or (None, None)."""
    if not fid or not re.match(r'^[0-9A-Za-z_-]{1,64}$', fid):
        return None, None
    path = os.path.join(THUMBS_DIR, fid)
    if not os.path.isfile(path):
        return None, None
    try:
        with open(path, 'rb') as f:
            data = f.read()
    except Exception:
        return None, None
    if data[:3] == b'\xff\xd8\xff':
        ctype = 'image/jpeg'
    elif data[:4] == b'\x89PNG':
        ctype = 'image/png'
    elif data[:3] == b'GIF':
        ctype = 'image/gif'
    elif data[:4] == b'RIFF' and data[8:12] == b'WEBP':
        ctype = 'image/webp'
    else:
        ctype = 'application/octet-stream'
    return data, ctype


PAGE = '''<!doctype html>
<html lang="ko"><head><meta charset="utf-8"><title>Teams Record Viewer</title><link rel="icon" type="image/x-icon" href="/favicon.ico">
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<style>
*{box-sizing:border-box}
body{margin:0;font-family:'Malgun Gothic','Segoe UI',sans-serif;height:100vh;display:flex;flex-direction:column;color:#222}
header{display:flex;align-items:center;gap:20px;padding:6px 16px;border-bottom:1px solid #ddd;background:#fff}
header h1{font-size:15px;margin:0;color:#334}
.refbtn{margin-left:auto;border:1px solid #cdd6e4;background:#f2f6fc;color:#1a73e8;border-radius:6px;padding:6px 12px;font-size:13px;font-weight:600;cursor:pointer}
.refbtn:hover{background:#e6eefb}
.refbtn:disabled{opacity:.55;cursor:default}
.rstat{font-size:12px;color:#889;white-space:nowrap}
nav button{border:0;background:none;padding:9px 12px;font-size:14px;cursor:pointer;color:#888;border-bottom:2px solid transparent}
nav button.on{color:#1a73e8;border-bottom-color:#1a73e8;font-weight:bold}
.searchbar{display:flex;align-items:center;gap:4px;margin-left:4px}
.searchbar input{width:220px;border:1px solid #cdd6e4;border-radius:6px;padding:6px 9px;font-size:13px}
.searchbar button{border:1px solid #cdd6e4;background:#fff;color:#56657a;border-radius:6px;width:31px;height:31px;cursor:pointer;font-size:14px}
.searchbar button:hover{background:#f2f6fc}
main{flex:1;display:flex;min-height:0}
#list{width:320px;border-right:1px solid #ddd;overflow-y:auto;background:#fafafa}
#msgs{flex:1;display:flex;flex-direction:column;min-width:0}
#msgHead{padding:10px 16px;border-bottom:1px solid #ddd;font-weight:bold;background:#fff;min-height:41px;font-size:14px;display:flex;align-items:center;justify-content:space-between;gap:8px}
#msgTitle{min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#btnDlMd{flex:none}
#btnDlMd[hidden]{display:none}
#msgBody{flex:1;overflow-y:auto;padding:12px 16px;background:#f4f5f7}
.wrow{display:flex;align-items:center;gap:8px;padding:9px 12px;cursor:pointer;font-weight:600;font-size:14px}
.wrow:hover{background:#eef2f8}
.wbadge{width:26px;height:26px;border-radius:6px;background:#6c8ae4;color:#fff;display:inline-flex;align-items:center;justify-content:center;font-size:11px;flex:none}
.chrow{padding:6px 12px 6px 46px;cursor:pointer;display:flex;gap:6px;align-items:center;font-size:13px;color:#445}
.chrow:hover,.rrow:hover{background:#eef2f8}
.chrow.sel,.rrow.sel{background:#e3ecfb}
.allb{font-size:10px;background:#e8eefc;color:#3b6fd4;border-radius:3px;padding:1px 4px;flex:none}
.rrow{display:flex;gap:10px;padding:9px 12px;cursor:pointer;align-items:center}
.rav{width:36px;height:36px;border-radius:50%;background:#9db3c8;color:#fff;display:flex;align-items:center;justify-content:center;flex:none;font-size:14px}
.rmain{flex:1;min-width:0}
.rtitle{font-size:14px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.rprev{font-size:12px;color:#889;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:2px}
.rtime{font-size:11px;color:#aab;flex:none;align-self:flex-start;margin-top:3px}
.sinfo{padding:8px 12px;color:#7d8898;font-size:12px;border-bottom:1px solid #e8ecf2;background:#fff}
.srow{padding:10px 12px;border-bottom:1px solid #eceff4;cursor:pointer;background:#fff}
.srow:hover{background:#eef2f8}
.srow.sel{background:#e3ecfb}
.stitle{font-size:13px;font-weight:700;color:#27364a;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.smeta{font-size:11px;color:#8a96a8;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ssnip{font-size:12px;color:#4e5968;margin-top:5px;line-height:1.35;word-break:break-word}
.ssnip mark{background:#fff1a8;color:inherit;padding:0 1px;border-radius:2px}
.dsep{text-align:center;color:#66788a;font-size:12px;margin:16px 0 10px}
.sysline{text-align:center;color:#98a2ad;font-size:12px;margin:8px 0}
.mrow{display:flex;margin:2px 0;align-items:flex-start}
.mrow.mine{justify-content:flex-end}
.av{width:34px;height:34px;border-radius:50%;background:#8fa6bd;color:#fff;display:flex;align-items:center;justify-content:center;flex:none;margin-right:8px;font-size:13px}
.av.ghost{background:transparent;color:transparent}
.mcol{max-width:70%;display:flex;flex-direction:column}
.mrow.mine .bout{max-width:70%}
.sname{font-size:12px;color:#556;margin:6px 0 3px}
.bout{display:flex;flex-direction:column;align-items:flex-start}
.mrow.mine .bout{align-items:flex-end}
.rdbadge{font-size:11px;color:#8a8f98;margin:0 2px;white-space:nowrap;user-select:none}
.rdbadge.allread{color:#3a8a4a}
.bmeta{display:flex;flex-direction:column;align-items:flex-end;justify-content:flex-end;gap:1px}
.bwrap{display:flex;align-items:flex-end;gap:6px;max-width:100%}
.bubble{background:#fff;border:1px solid #e3e6ea;border-radius:12px;padding:8px 12px;font-size:14px;white-space:pre-wrap;word-break:break-word;max-width:520px;line-height:1.45}
.bubble.me{background:#d3e9ff;border-color:#bcd8f5}
.mrow.hit .bubble,.mrow.hit .mediacard,.mrow.hit .imgcard .thumb,.mrow.hit .imgcard .thumbimg{box-shadow:0 0 0 3px #ffe28a;background:#fff7d0}
.mtime{font-size:11px;color:#9aa5b0;flex:none;padding-bottom:2px}
.reacts{display:flex;gap:4px;margin:3px 2px 2px;flex-wrap:wrap}
.reacts.r{justify-content:flex-end}
.chip{background:#fff;border:1px solid #dfe3e8;border-radius:12px;padding:1px 8px;font-size:12px;cursor:pointer;user-select:none}
.chip.mymark{border-color:#1a73e8;background:#e8f1fd}
.mediacard{display:flex;align-items:center;gap:10px;background:#fff;border:1px solid #e3e6ea;border-radius:12px;padding:9px 12px;max-width:340px;cursor:default;text-decoration:none;color:#223}
.bubble.me + .mediacard,.mrow.mine .mediacard{background:#d3e9ff;border-color:#bcd8f5}
.mediacard .fico{width:38px;height:38px;border-radius:8px;background:#eef1f6;color:#5a6b86;display:flex;align-items:center;justify-content:center;font-size:11px;font-weight:700;flex:none;text-transform:uppercase}
.mediacard .fmeta{min-width:0}
.mediacard .fname{font-size:13px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:250px}
.mediacard .fsize{font-size:11px;color:#8a94a3;margin-top:2px}
.imgcard{max-width:340px}
.imgcard .thumb{width:100%;max-width:340px;border-radius:12px;border:1px solid #e3e6ea;background:#eef1f6;min-height:120px;display:flex;flex-direction:column;align-items:center;justify-content:center;color:#7a879a;gap:6px;padding:20px 12px;text-align:center}
.imgcard .thumb .ig{font-size:26px}
.imgcard .thumb .in{font-size:12px;word-break:break-word}
.imgcard .thumbimg{width:100%;max-width:340px;border-radius:12px;border:1px solid #e3e6ea;display:block;cursor:pointer}
#lightbox{position:fixed;inset:0;z-index:100;background:rgba(0,0,0,.82);display:flex;align-items:center;justify-content:center;cursor:zoom-out}
#lightbox[hidden]{display:none}
#lightbox img{width:94vw;height:92vh;object-fit:contain;cursor:default;filter:drop-shadow(0 8px 40px rgba(0,0,0,.5))}
#lightbox .lbclose{position:absolute;top:18px;right:24px;color:#fff;font-size:30px;line-height:1;cursor:pointer;opacity:.85;user-select:none}
#lightbox .lbclose:hover{opacity:1}
.remenu{position:absolute;background:#2b2f36;color:#fff;border-radius:8px;padding:8px 10px;font-size:12px;z-index:20;max-width:240px;box-shadow:0 4px 14px rgba(0,0,0,.25);pointer-events:none}
.remenu .rh{font-size:11px;color:#b9c2cf;margin-bottom:5px;display:flex;align-items:center;gap:6px}
.remenu .rn{padding:2px 0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#pop{position:absolute;background:#333;color:#fff;padding:8px 10px;border-radius:6px;font-size:12px;max-width:260px;z-index:9;white-space:pre-wrap}
.empty{color:#99a;text-align:center;margin-top:40px;font-size:13px}
</style></head><body>
<header><h1>Teams Record Viewer</h1>
<nav><button id="tabKt" class="on">워크스페이스-채널</button><button id="tabKm">1:1 대화</button></nav><div class="searchbar"><input id="searchQ" placeholder="대화 검색" autocomplete="off"><button id="btnSearch" title="검색">⌕</button></div><span id="rstat" class="rstat"></span><button id="btnRefresh" class="refbtn" title="라이브 DB를 스냅샷·복호화해 누적 아카이브에 최신 내용을 append합니다">↻ 새로고침</button>
</header>
<main><aside id="list"></aside>
<section id="msgs"><div id="msgHead"><span id="msgTitle"></span><button id="btnDlMd" class="refbtn" title="현재 대화를 Markdown 으로 저장" hidden>⬇ 다운로드</button></div><div id="msgBody"><div class="empty">좌측에서 채널 또는 대화를 선택하세요</div></div></section>
</main>
<div id="pop" hidden></div>
<div id="remenu" class="remenu" hidden></div>
<div id="lightbox" hidden><span class="lbclose" title="닫기 (ESC)">&times;</span><img id="lbimg" src="" alt=""></div>
<script>
let B=null,MY='',selEl=null,CUR=null,SEARCH=null;
const $=s=>document.querySelector(s);
const EMOJI={1:'\\uD83D\\uDC4D',2:'\\u2764\\uFE0F',3:'\\uD83D\\uDE04',4:'\\uD83D\\uDE2E',5:'\\uD83D\\uDE22',6:'\\uD83D\\uDE4F',7:'\\u2705',8:'\\uD83D\\uDC4F'};
function div(c){const d=document.createElement('div');d.className=c;return d;}
function divT(c,t){const d=div(c);d.textContent=t;return d;}
function nm(id){const c=(B.contacts||{})[id]||{};return c.LocalName||id;}
function sub(id){const c=(B.contacts||{})[id]||{};const p=[];if(c.Department)p.push(c.Department);if(c.CompanyName)p.push(c.CompanyName);return p.join(' / ');}
function p2(n){return String(n).padStart(2,'0');}
function fmtT(ms){const d=new Date(ms);return p2(d.getHours())+':'+p2(d.getMinutes());}
function fmtListT(ms){if(!ms)return'';const d=new Date(ms),n=new Date();if(d.toDateString()===n.toDateString())return fmtT(ms);return p2(d.getMonth()+1)+'-'+p2(d.getDate());}
function fmtSearchT(ms){if(!ms)return'';const d=new Date(ms);return d.getFullYear()+'-'+p2(d.getMonth()+1)+'-'+p2(d.getDate())+' '+p2(d.getHours())+':'+p2(d.getMinutes());}
const WD=['일','월','화','수','목','금','토'];
function fmtD(ms){const d=new Date(ms);return d.getFullYear()+'-'+p2(d.getMonth()+1)+'-'+p2(d.getDate())+' ('+WD[d.getDay()]+')';}
function sameMin(a,b){const x=new Date(a),y=new Date(b);return x.getFullYear()===y.getFullYear()&&x.getMonth()===y.getMonth()&&x.getDate()===y.getDate()&&x.getHours()===y.getHours()&&x.getMinutes()===y.getMinutes();}
function setMsgHead(title,canDownload){
  $('#msgTitle').textContent=title||'';
  $('#btnDlMd').hidden=!canDownload;
}
function mark(el){if(selEl)selEl.classList.remove('sel');selEl=el;el.classList.add('sel');}
function clearSearchMode(){
  SEARCH=null;
  const q=$('#searchQ');if(q)q.value='';
}
function escHtml(s){
  return String(s||'').replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
}
function markSnippet(text,term){
  const src=String(text||''),needle=String(term||'');
  if(!needle)return escHtml(src);
  const idx=src.toLocaleLowerCase().indexOf(needle.toLocaleLowerCase());
  if(idx<0)return escHtml(src);
  return escHtml(src.slice(0,idx))+'<mark>'+escHtml(src.slice(idx,idx+needle.length))+'</mark>'+escHtml(src.slice(idx+needle.length));
}
async function doSearch(){
  const term=$('#searchQ').value.trim();
  if(!term){
    SEARCH=null;
    if(CURTAB==='kt')renderKt();else renderKm();
    return;
  }
  const L=$('#list');
  L.innerHTML='<div class="empty">검색 중...</div>';
  const res=await (await fetch('/api/search?q='+encodeURIComponent(term))).json();
  SEARCH=res;
  renderSearchResults(res);
}
function renderSearchResults(res){
  const L=$('#list');L.innerHTML='';
  const info=div('sinfo');
  info.textContent='검색 결과 '+(res.count||0)+'건'+(res.truncated?' · 상위 300건만 표시':'');
  L.appendChild(info);
  if(!res.results||!res.results.length){
    L.appendChild(divT('empty','검색 결과 없음'));
    return;
  }
  for(const r of res.results){
    const row=div('srow');
    row.appendChild(divT('stitle',r.title||r.id));
    row.appendChild(divT('smeta',(r.sname||r.s||'')+' · '+fmtSearchT(r.t)));
    const sn=div('ssnip');
    sn.innerHTML=markSnippet(r.snippet,res.q);
    row.appendChild(sn);
    row.onclick=async()=>{mark(row);await openConv(r.kind,r.id,r.title);highlightMessage(r.mid);};
    L.appendChild(row);
  }
}
function renderKt(){
  const L=$('#list');L.innerHTML='';
  for(const w of B.ws){
    const wr=div('wrow');
    const b=div('wbadge');b.textContent=(w.t||'??').slice(0,2);
    if(w.c&&/^#?[0-9a-fA-F]{6}$/.test(w.c))b.style.background=(w.c[0]==='#'?w.c:'#'+w.c);
    wr.appendChild(b);wr.appendChild(divT('',w.t||w.w));
    const chs=div('chs');
    for(const c of (B.channels[w.w]||[])){
      const cr=div('chrow');cr.appendChild(divT('','# '+(c.t||c.i)));
      if(c.dflt){const ab=document.createElement('span');ab.className='allb';ab.textContent='All';cr.appendChild(ab);}
      cr.onclick=e=>{e.stopPropagation();mark(cr);openConv('kt',c.i,(w.t||'')+' > '+(c.t||c.i));};
      chs.appendChild(cr);
    }
    wr.onclick=()=>{chs.style.display=chs.style.display==='none'?'':'none';};
    L.appendChild(wr);L.appendChild(chs);
  }
  if(!B.ws.length)L.appendChild(divT('empty','워크스페이스 없음'));
}
function renderKm(){
  const L=$('#list');L.innerHTML='';
  for(const r of B.rooms){
    const row=div('rrow');
    const av=div('rav');av.textContent=(r.t||'?').slice(0,1);
    const m=div('rmain');m.appendChild(divT('rtitle',r.t));m.appendChild(divT('rprev',r.lb||''));
    row.appendChild(av);row.appendChild(m);row.appendChild(divT('rtime',fmtListT(r.lt)));
    row.onclick=()=>{mark(row);openConv('km',r.i,r.t);};
    L.appendChild(row);
  }
  if(!B.rooms.length)L.appendChild(divT('empty','대화 없음'));
}
async function openConv(kind,id,title){
  CUR=null;
  setMsgHead(title,false);
  $('#msgBody').innerHTML='<div class="empty">불러오는 중...</div>';
  try{
    const ms=await (await fetch('/api/messages?kind='+kind+'&id='+encodeURIComponent(id))).json();
    CUR={kind:kind,id:id,title:title,ms:ms};
    setMsgHead(title,true);
    renderMsgs(ms);
  }catch(e){
    CUR=null;
    setMsgHead(title,false);
    $('#msgBody').innerHTML='<div class="empty">불러오기 실패: '+e+'</div>';
  }
}
function fmtSize(n){
  if(!n&&n!==0)return'';
  if(n<1024)return n+' B';
  if(n<1048576)return (n/1024).toFixed(0)+' KB';
  return (n/1048576).toFixed(1)+' MB';
}
function imgFallback(md){
  const th=div('thumb');
  const ig=div('ig');ig.textContent=String.fromCodePoint(0x1F5BC);
  const inm=div('in');inm.textContent=md.name;
  const sz=div('fsize');sz.textContent=fmtSize(md.size);
  th.appendChild(ig);th.appendChild(inm);if(sz.textContent)th.appendChild(sz);
  return th;
}
function mediaCard(md,mine){
  if(md.kind==='image'){
    const c=div('imgcard');
    if(md.fid){
      const img=document.createElement('img');
      img.className='thumbimg';img.src='/thumb/'+encodeURIComponent(md.fid);
      img.alt=md.name||'';img.loading='lazy';
      img.onclick=()=>openLightbox(img.src);
      img.onerror=()=>{img.remove();c.appendChild(imgFallback(md));};
      c.appendChild(img);
    }else{
      c.appendChild(imgFallback(md));
    }
    return c;
  }
  const c=div('mediacard');
  const ic=div('fico');ic.textContent=(md.ext||'file').slice(0,4);
  const meta=div('fmeta');
  meta.appendChild(divT('fname',md.name));
  const sz=fmtSize(md.size);if(sz)meta.appendChild(divT('fsize',sz));
  c.appendChild(ic);c.appendChild(meta);
  return c;
}
function readBadge(rd,rt){
  // rt = number of other participants (audience). rd = how many have read.
  if(!rt)return null;
  const b=div('rdbadge');
  if(rt===1){                       // 1:1 chat
    if(rd>=1){b.textContent='읽음';b.classList.add('allread');return b;}
    b.textContent='안읽음';return b;
  }
  // group chat
  if(rd>=rt){b.textContent='모두 읽음 '+rt;b.classList.add('allread');return b;}
  b.textContent='읽음 '+rd+'/'+rt;
  return b;
}
function bubbleWrap(m,next,mine){
  const out=div('bout');
  const wrap=div('bwrap');
  let contentEl;
  if(m.media){
    contentEl=mediaCard(m.media,mine);
  }else{
    contentEl=div('bubble'+(mine?' me':''));
    contentEl.textContent=(m.label?m.label+(m.txt?'\\n':''):'')+(m.txt||'')||'(내용 없음)';
  }
  let showT=true;
  if(next&&!next.sys&&next.s===m.s&&m.t&&next.t&&sameMin(m.t,next.t))showT=false;
  const t=div('mtime');t.textContent=(showT&&m.t)?fmtT(m.t):'';
  const meta=div('bmeta');
  if(mine&&m.rt){
    const rb=readBadge(m.rd||0,m.rt);
    if(rb)meta.appendChild(rb);
  }
  meta.appendChild(t);
  if(mine){wrap.appendChild(meta);wrap.appendChild(contentEl);}else{wrap.appendChild(contentEl);wrap.appendChild(t);}
  out.appendChild(wrap);
  if(m.re&&m.re.length){
    const rc=div('reacts'+(mine?' r':''));
    for(const r of m.re){
      const chip=document.createElement('span');
      chip.className='chip'+(r.m?' mymark':'');
      const glyph=EMOJI[r.e]||('#'+r.e);
      chip.textContent=glyph+' '+r.c;
      const names=(r.u||[]).map(nm);
      chip.onmouseenter=ev=>showReMenu(ev,glyph,names);
      chip.onmousemove=ev=>positionReMenu(ev);
      chip.onmouseleave=()=>hideReMenu();
      chip.onclick=ev=>{ev.stopPropagation();showReMenu(ev,glyph,names);};
      rc.appendChild(chip);
    }
    out.appendChild(rc);
  }
  return out;
}
function renderMsgs(ms){
  const box=$('#msgBody');box.innerHTML='';
  if(!ms.length){box.appendChild(divT('empty','메시지 없음'));return;}
  let prevDate='',prevSender=null;
  for(let i=0;i<ms.length;i++){
    const m=ms[i];
    const d=m.t?fmtD(m.t):'';
    if(d&&d!==prevDate){box.appendChild(divT('dsep',d));prevDate=d;prevSender=null;}
    if(m.sys){box.appendChild(divT('sysline',m.sys));prevSender=null;continue;}
    const mine=m.s===MY;
    const row=div('mrow'+(mine?' mine':''));
    row.dataset.mid=m.id;
    if(!mine){
      const showHead=m.s!==prevSender;
      const av=div('av'+(showHead?'':' ghost'));
      av.textContent=showHead?(nm(m.s)||'?').slice(0,1):'';
      row.appendChild(av);
      const col=div('mcol');
      if(showHead){const s=sub(m.s);col.appendChild(divT('sname',nm(m.s)+(s?' \\u00B7 '+s:'')));}
      col.appendChild(bubbleWrap(m,ms[i+1],false));
      row.appendChild(col);
    }else{
      row.appendChild(bubbleWrap(m,ms[i+1],true));
    }
    box.appendChild(row);
    prevSender=m.s;
  }
  box.scrollTop=box.scrollHeight;
}
function highlightMessage(mid){
  if(mid===undefined||mid===null)return;
  requestAnimationFrame(()=>requestAnimationFrame(()=>{
    const el=document.querySelector('[data-mid="'+CSS.escape(String(mid))+'"]');
    if(!el)return;
    el.scrollIntoView({block:'center'});
    el.classList.add('hit');
    setTimeout(()=>el.classList.remove('hit'),1800);
  }));
}
function fmtExportTime(ms){
  const d=new Date(ms);
  return d.getFullYear()+'-'+p2(d.getMonth()+1)+'-'+p2(d.getDate())+' '+p2(d.getHours())+':'+p2(d.getMinutes());
}
function fmtFileTime(ms){
  const d=new Date(ms);
  return d.getFullYear()+p2(d.getMonth()+1)+p2(d.getDate())+'-'+p2(d.getHours())+p2(d.getMinutes());
}
function safeFileTitle(title){
  const s=(title||'conversation').replace(/[\\\\/:*?"<>|]+/g,'_').replace(/\\s+/g,'_').replace(/^_+|_+$/g,'');
  return (s||'conversation').slice(0,80);
}
function mediaMd(md){
  const tag=md.kind==='image'?'[이미지]':'[파일]';
  const name=md.name||'(파일명 없음)';
  const sz=fmtSize(md.size);
  return tag+' '+name+(sz?' ('+sz+')':'');
}
function reactionMd(re){
  if(!re||!re.length)return'';
  return '반응: '+re.map(r=>(EMOJI[r.e]||('#'+r.e))+' '+r.c).join(' · ');
}
function buildMd(cur){
  const ms=cur.ms||[],now=Date.now(),lines=[];
  lines.push('# '+(cur.title||'대화'));
  lines.push('> 내보낸 시각: '+fmtExportTime(now)+' · 메시지 '+ms.length+'건');
  lines.push('');
  let prevDate='';
  for(const m of ms){
    const d=m.t?fmtD(m.t):'';
    if(d&&d!==prevDate){
      lines.push('## '+d);
      lines.push('');
      prevDate=d;
    }
    if(m.sys){
      lines.push('_'+m.sys+'_');
    }else{
      lines.push('**'+nm(m.s)+'** ('+(m.t?fmtT(m.t):'')+')');
      let body='';
      if(m.media){
        body=mediaMd(m.media);
      }else{
        body=(m.label?m.label+(m.txt?'\\n':''):'')+(m.txt||'');
      }
      if(body)lines.push(body);
      const reacts=reactionMd(m.re);
      if(reacts)lines.push(reacts);
    }
    lines.push('');
  }
  return lines.join('\\n').replace(/\\s+$/,'')+'\\n';
}
function downloadMd(){
  if(!CUR)return;
  const md=buildMd(CUR);
  const a=document.createElement('a');
  a.href=URL.createObjectURL(new Blob([md],{type:'text/markdown;charset=utf-8'}));
  a.download=safeFileTitle(CUR.title)+'_'+fmtFileTime(Date.now())+'.md';
  document.body.appendChild(a);
  a.click();
  URL.revokeObjectURL(a.href);
  a.remove();
}
function showPop(ev,text){
  const p=$('#pop');p.hidden=false;p.textContent=text;
  p.style.left=Math.min(ev.pageX,window.innerWidth-280)+'px';
  p.style.top=(ev.pageY+8)+'px';
}
function showReMenu(ev,glyph,names){
  const el=$('#remenu');
  el.innerHTML='';
  const h=div('rh');
  h.textContent=glyph+' '+names.length+'\uBA85';
  el.appendChild(h);
  if(names.length){
    for(const n of names){el.appendChild(divT('rn',n));}
  }else{
    el.appendChild(divT('rn','(\uBC18\uC751\uC790 \uC815\uBCF4 \uC5C6\uC74C)'));
  }
  el.hidden=false;
  positionReMenu(ev);
}
function positionReMenu(ev){
  const el=$('#remenu');
  if(el.hidden)return;
  const w=el.offsetWidth||200,h=el.offsetHeight||60;
  let x=ev.pageX+12,y=ev.pageY+12;
  if(x+w>window.innerWidth-8)x=ev.pageX-w-12;
  if(y+h>window.innerHeight-8)y=ev.pageY-h-12;
  el.style.left=Math.max(8,x)+'px';
  el.style.top=Math.max(8,y)+'px';
}
function hideReMenu(){$('#remenu').hidden=true;}
document.addEventListener('click',()=>{$('#pop').hidden=true;hideReMenu();});
function setTab(k){
  clearSearchMode();
  $('#tabKt').classList.toggle('on',k==='kt');
  $('#tabKm').classList.toggle('on',k==='km');
  selEl=null;CURTAB=k;
  if(k==='kt')renderKt();else renderKm();
  CUR=null;
  setMsgHead('',false);
  $('#msgBody').innerHTML='<div class="empty">좌측에서 채널 또는 대화를 선택하세요</div>';
}
$('#tabKt').onclick=()=>setTab('kt');
$('#tabKm').onclick=()=>setTab('km');
let CURTAB='kt';
async function doRefresh(){
  const btn=$('#btnRefresh'),st=$('#rstat');
  btn.disabled=true;st.textContent='갱신 중… (복호화·병합, 수십초 소요)';
  try{
    const r=await fetch('/api/refresh',{method:'POST'});
    const j=await r.json();
    if(j.ok){
      B=await (await fetch('/api/bootstrap')).json();MY=B.my;
      if(CURTAB==='kt')renderKt();else renderKm();
      st.textContent='갱신 완료 '+(j.at||'');
    }else{st.textContent='실패: '+(j.error||'unknown');}
  }catch(e){st.textContent='오류: '+e;}
  btn.disabled=false;
  setTimeout(()=>{if(!btn.disabled)st.textContent='';},8000);
}
function openLightbox(src){const lb=$('#lightbox'),im=$('#lbimg');im.src=src;lb.hidden=false;document.body.style.overflow='hidden';}
function closeLightbox(){const lb=$('#lightbox');lb.hidden=true;$('#lbimg').src='';document.body.style.overflow='';}
$('#lightbox').onclick=e=>{if(e.target.id!=='lbimg')closeLightbox();};
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!$('#lightbox').hidden)closeLightbox();});
$('#btnDlMd').onclick=downloadMd;
$('#btnSearch').onclick=doSearch;
$('#searchQ').addEventListener('keydown',e=>{if(e.key==='Enter')doSearch();});
$('#searchQ').addEventListener('input',e=>{if(!e.target.value.trim()&&SEARCH){SEARCH=null;if(CURTAB==='kt')renderKt();else renderKm();}});
$('#btnRefresh').onclick=doRefresh;
(async()=>{B=await (await fetch('/api/bootstrap')).json();MY=B.my;renderKt();})();
</script></body></html>'''

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, body, ctype):
        self.send_response(200)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate')
        self.send_header('Pragma', 'no-cache')
        self.end_headers()
        self.wfile.write(body)

    def _send_favicon(self, body, ctype, include_body=True):
        self.send_response(200)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'public, max-age=604800')
        self.end_headers()
        if include_body:
            self.wfile.write(body)

    def do_HEAD(self):
        u = urlparse(self.path)
        if u.path == '/':
            body = PAGE.encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate')
            self.send_header('Pragma', 'no-cache')
            self.end_headers()
        elif u.path == '/favicon.ico':
            self._send_favicon(base64.b64decode(FAVICON_ICO_B64), 'image/x-icon', include_body=False)
        elif u.path == '/favicon.svg':
            self._send_favicon(FAVICON_SVG.encode('utf-8'), 'image/svg+xml', include_body=False)
        else:
            self.send_error(404)

    def do_POST(self):
        u = urlparse(self.path)
        if u.path == '/api/refresh':
            if not _REFRESH_LOCK.acquire(blocking=False):
                self._send(json.dumps({'ok': False, 'error': '\uc774\ubbf8 \uac31\uc2e0 \uc911\uc785\ub2c8\ub2e4'}).encode('utf-8'),
                           'application/json; charset=utf-8')
                return
            try:
                proc = subprocess.run(['cmd', '/c', REFRESH_BAT], capture_output=True,
                                      text=True, encoding='utf-8', errors='replace',
                                      env={**os.environ, 'PYTHONUTF8': '1', 'PYTHONIOENCODING': 'utf-8'},
                                      timeout=600, cwd=os.path.dirname(REFRESH_BAT))
                ok = proc.returncode == 0
                import datetime as _dt
                at = _dt.datetime.now().strftime('%H:%M:%S')
                tail = (proc.stdout or '').strip().replace('\n', ' ')[-200:]
                err = None if ok else ('exit %d: %s' % (proc.returncode, tail))
                self._send(json.dumps({'ok': ok, 'at': at, 'error': err}).encode('utf-8'),
                           'application/json; charset=utf-8')
            except subprocess.TimeoutExpired:
                self._send(json.dumps({'ok': False, 'error': '\uc2dc\uac04 \ucd08\uacfc(600s)'}).encode('utf-8'),
                           'application/json; charset=utf-8')
            except Exception as e:
                self._send(json.dumps({'ok': False, 'error': str(e)[:200]}).encode('utf-8'),
                           'application/json; charset=utf-8')
            finally:
                _REFRESH_LOCK.release()
        else:
            self.send_error(404)

    def do_GET(self):
        try:
            u = urlparse(self.path)
            if u.path == '/':
                self._send(PAGE.encode('utf-8'), 'text/html; charset=utf-8')
            elif u.path == '/api/bootstrap':
                self._send(json.dumps(api_bootstrap(), ensure_ascii=False).encode('utf-8'),
                           'application/json; charset=utf-8')
            elif u.path == '/api/messages':
                qs = parse_qs(u.query)
                kind = (qs.get('kind') or ['kt'])[0]
                cid = (qs.get('id') or [''])[0]
                if kind not in ('kt', 'km'):
                    kind = 'kt'
                self._send(json.dumps(api_messages(kind, cid), ensure_ascii=False).encode('utf-8'),
                           'application/json; charset=utf-8')
            elif u.path == '/api/search':
                qs = parse_qs(u.query)
                term = (qs.get('q') or [''])[0].strip()
                self._send(json.dumps(api_search(term), ensure_ascii=False).encode('utf-8'),
                           'application/json; charset=utf-8')
            elif u.path == '/favicon.ico':
                ico = base64.b64decode(FAVICON_ICO_B64)
                self._send_favicon(ico, 'image/x-icon')
            elif u.path == '/favicon.svg':
                svg = FAVICON_SVG.encode('utf-8')
                self._send_favicon(svg, 'image/svg+xml')
            elif u.path.startswith('/thumb/'):
                fid = u.path[len('/thumb/'):]
                data, ctype = read_thumb(fid)
                if data is None:
                    self.send_error(404)
                else:
                    self.send_response(200)
                    self.send_header('Content-Type', ctype)
                    self.send_header('Content-Length', str(len(data)))
                    self.send_header('Cache-Control', 'public, max-age=86400')
                    self.end_headers()
                    self.wfile.write(data)
            else:
                self.send_error(404)
        except Exception as e:
            try:
                self.send_error(500, str(e).replace('\n', ' ')[:200])
            except Exception:
                pass

def main():
    try:
        srv = ThreadingHTTPServer(('127.0.0.1', PORT), H)
    except OSError:
        print('port %d in use; viewer seems already running' % PORT)
        return
    print('teams-record viewer: http://127.0.0.1:%d/' % PORT)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass

if __name__ == '__main__':
    main()
