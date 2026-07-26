# Windows packaging

Native Flutter Windows app + Inno Setup 6 installer.

## Local (Windows)

```bat
flutter config --enable-windows-desktop
scripts\build-windows.sh
```

Or after `flutter build windows --release`:

```bat
"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" packaging\windows\privet.iss
```

Outputs:

- `server/public/downloads/Privet-Setup-<version>.exe`
- `server/public/downloads/Privet-Setup.exe` (stable name)

The installer is **unsigned**; Windows SmartScreen may show a warning until Authenticode signing is configured.

CI builds this on `windows-latest` via `.github/workflows/release.yml`.

## In-app updates

The Windows app checks `/version.json` on the API host. If a newer version is
published, Profile → **Update available** downloads `Privet-Setup.exe` and runs:

```
Privet-Setup.exe /VERYSILENT /NORESTART /SUPPRESSMSGBOXES /FORCECLOSEAPPLICATIONS
```

Inno Setup replaces the install (same `AppId`), then relaunches Privet. Keep
`server/public/version.json` in sync via `scripts/write-version-json.sh` (run by
desktop build scripts).
