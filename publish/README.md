# teams-record publish installer

This folder is the reinstall package for the local Knox Teams archive viewer.

## Reinstall steps

1. Install KnoxTeams and sign in once.
2. Copy this repository folder, or a zip of it, to the Windows PC.
3. Run `publish\setup.bat` as Administrator.
4. Restore the SQLCipher key by either:
   - placing `dbkey.secret` at `publish\secrets\dbkey.secret` before setup,
   - passing `-KeyBackup C:\path\to\dbkey.secret`, or
   - running `publish\capture-key.bat` after KnoxTeams login.
5. The scheduled task `TeamsRecordViewer` refreshes data on Windows logon. Use the desktop shortcut `Teams 뷰어` to refresh, start the server, and open Chrome manually.

## Recommended backup before reinstall

Copy these items before wiping Windows if you need history older than KnoxTeams' live retention window:

- `D:\git\teams-db\teams-archive.db`
- `D:\git\teams-db\thumbs\`
- `C:\Users\lisyoen\teams-record-work\dbkey.secret`

Then run:

```bat
publish\setup.bat -KeyBackup C:\backup\dbkey.secret -DataBackup C:\backup\teams-db
```

Without `-DataBackup`, the first refresh recreates the archive from the current live KnoxTeams DB, normally the recent retention window only.
