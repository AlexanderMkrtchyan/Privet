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
