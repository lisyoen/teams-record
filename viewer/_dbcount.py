import sqlite3, sys, os
for p in sys.argv[1:]:
    label = os.path.basename(p)
    if not os.path.exists(p):
        print("   %s : (missing)" % label); continue
    try:
        c = sqlite3.connect(p); q = c.cursor()
        kt = q.execute("select count(*) from TB_KtMessage").fetchone()[0]
        km = q.execute("select count(*) from TB_KmMessage").fetchone()[0]
        c.close()
        print("   %s : channel(TB_KtMessage)=%d  dm/group(TB_KmMessage)=%d" % (label, kt, km))
    except Exception as e:
        print("   %s : (count failed: %s)" % (label, str(e)[:40]))
