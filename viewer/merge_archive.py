#!/usr/bin/env python3
"""teams-record cumulative archive merger.
Reads a freshly-decrypted plaintext snapshot and UPSERTs every table into a
persistent cumulative archive DB, so messages beyond the live app's ~90-day
retention window are preserved forever.

Usage:
    python merge_archive.py <fresh_decrypted.db> <archive.db>

- <fresh_decrypted.db> : plaintext snapshot produced by decrypt_export.js (this run).
- <archive.db>         : cumulative archive (created on first run).

Merge policy:
- For every table present in the fresh snapshot, copy its schema into the
  archive on first sight, then INSERT OR REPLACE all rows keyed by PK.
- Rows that exist only in the archive (aged out of the live DB) are kept.
- Tables without a usable PK are merged by full-row identity (best effort).
"""
import sqlite3, sys, datetime


def table_info(con, tbl):
    cols = con.execute("PRAGMA table_info(%s)" % tbl).fetchall()
    names = [c[1] for c in cols]
    pk = [c[1] for c in cols if c[5]]  # c[5] = pk order (>0 if part of PK)
    return names, pk


def main():
    if len(sys.argv) < 3:
        print("usage: merge_archive.py <fresh_decrypted.db> <archive.db>")
        sys.exit(2)
    fresh_path, arc_path = sys.argv[1], sys.argv[2]

    src = sqlite3.connect(fresh_path)
    src.row_factory = sqlite3.Row
    arc = sqlite3.connect(arc_path)

    tables = [r[0] for r in src.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name")]

    summary = []
    for tbl in tables:
        create_sql = src.execute(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name=?",
            (tbl,)).fetchone()
        if not create_sql or not create_sql[0]:
            continue
        # ensure table exists in archive (identical schema)
        arc.execute(create_sql[0].replace("CREATE TABLE ", "CREATE TABLE IF NOT EXISTS ", 1))

        names, pk = table_info(src, tbl)
        collist = ",".join('"%s"' % n for n in names)
        ph = ",".join("?" for _ in names)
        rows = src.execute('SELECT %s FROM "%s"' % (collist, tbl)).fetchall()

        before = arc.execute('SELECT count(*) FROM "%s"' % tbl).fetchone()[0]
        if pk:
            stmt = 'INSERT OR REPLACE INTO "%s" (%s) VALUES (%s)' % (tbl, collist, ph)
        else:
            # no PK: INSERT OR IGNORE with a UNIQUE over all columns via temp check is costly;
            # fall back to plain INSERT of rows not already present (identity by all cols)
            stmt = 'INSERT INTO "%s" (%s) VALUES (%s)' % (tbl, collist, ph)
        for r in rows:
            vals = tuple(r[n] for n in names)
            if not pk:
                where = " AND ".join('"%s" IS ?' % n for n in names)
                exists = arc.execute(
                    'SELECT 1 FROM "%s" WHERE %s LIMIT 1' % (tbl, where), vals).fetchone()
                if exists:
                    continue
            arc.execute(stmt, vals)
        arc.commit()
        after = arc.execute('SELECT count(*) FROM "%s"' % tbl).fetchone()[0]
        summary.append((tbl, before, after, after - before))

    # bump a marker so we can see last merge time
    arc.execute("CREATE TABLE IF NOT EXISTS _archive_meta (k TEXT PRIMARY KEY, v TEXT)")
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    arc.execute("INSERT OR REPLACE INTO _archive_meta (k,v) VALUES ('last_merge',?)", (now,))
    arc.commit()

    kt = arc.execute("SELECT count(*) FROM TB_KtMessage").fetchone()[0] \
        if ("TB_KtMessage",) in [(t,) for t in tables] else 0
    km = arc.execute("SELECT count(*) FROM TB_KmMessage").fetchone()[0] \
        if ("TB_KmMessage",) in [(t,) for t in tables] else 0
    changed = [s for s in summary if s[3] != 0]
    print("MERGE_OK tables=%d changed=%d" % (len(summary), len(changed)))
    for t, b, a, d in changed:
        print("  +%-6d %-18s %d -> %d" % (d, t, b, a))
    print("ARCHIVE_TOTAL TB_KtMessage=%d TB_KmMessage=%d last_merge=%s" % (kt, km, now))
    src.close()
    arc.close()


if __name__ == "__main__":
    main()
