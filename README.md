# Privet

Messenger for web, Linux, and Windows.

## Production

| What | URL |
|------|-----|
| App (HTTPS) | https://messenger.banderdog.com/ |
| Install | https://messenger.banderdog.com/install/ |

Demo: `alex / privet` · one-click join available.

Backend listens on `127.0.0.1:7777`; nginx terminates TLS for `messenger.banderdog.com`.

## Desktop builds

```bash
# Native Linux GTK → .tar.gz + .deb + ~/Apps/privet
./scripts/build-linux.sh

# Linux packages (Windows installer requires Windows / GitHub Actions)
./scripts/package-desktop.sh

# On Windows (or CI): native Flutter + Inno Setup installer
./scripts/build-windows.sh
```

Artifacts land in `server/public/downloads/`:

- `privet-linux-amd64.deb` / `privet_<ver>_amd64.deb`
- `privet-linux-x64.tar.gz`
- `Privet-Setup.exe` / `Privet-Setup-<ver>.exe` (from Windows CI)

Default API for desktop clients: `https://messenger.banderdog.com`.

### Releases

Push a version tag to publish GitHub Release assets:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Windows SmartScreen may warn until Authenticode signing is added (More info → Run anyway).

## AI in chat

In any chat, type `#` commands (only you see the reply):

- `# summarize` / `# summarize unread` — catch up on unread
- `# summarize 40` — last 40 messages
- `# help` — list commands
- `# <question>` — ask about this chat

Server AI: OpenAI-compatible first (`DEEPSEEK_API_KEY` / `OPENAI_COMPAT_*`), then **Gemini** fallback (`GEMINI_API_KEY`). In Profile, users set key + base URL + model for any OpenAI-compatible provider. See `server/.env.example`. Prod deploy uploads local `server/.env` when present.
