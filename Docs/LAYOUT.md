# Repository layout

## Layout

```
Sources/
  MemoirKit/          logic, no UI, unit-tested
    Capture/       accessibility reads (event-driven), triggers, sessions, idle
    Storage/       SQLite, FTS5, migrations, retention
    Memory/        extraction, entity reconciliation, context building
    Brain/         the four brains and the router
    Rules/         when the companion is allowed to speak
  MemoirApp/          the app
    Character/     the face, drawn in code
    Shell/         the notch band: panel, strip, chat, theme
    Panes/         the pane views shared by band and window
    Overlay/       hotkey + dictation drivers
    UI/            memory browser, settings, onboarding
  MemoirMCP/          the MCP server
Tests/MemoirKitTests/
Skills/memoir/       SKILL.md, also copied into the app bundle's Resources
Scripts/
  version.sh       the version number, in one place. Sourced by the three below
  build-app.sh     the dev driver: build, assemble, sign locally
  deploy.sh        build-app.sh, then install to /Applications
  release.sh       Developer ID, notarise, staple, DMG, .mcpb
  make-mcpb.sh     dist/memoir.mcpb on its own
  verify.sh        nine stages, one command
Packaging/
  Memoir.entitlements   hardened-runtime entitlements, release only
ARCHITECTURE.md    the interface contract
```

`ARCHITECTURE.md` is authoritative for public signatures.

---

