# Plan: Crash diagnostics + first Sparkle update (1.0.1)

> Hand this file to a new Cursor chat. Do **not** re-litigate Sparkle/DMG setup unless something is broken.
> Implement in a **new chat**; this chat’s context is full.

## Objective

Ship **WindowLens 1.0.1 (build 2)** as the first real Sparkle update over **1.0.0**, adding local crash-report diagnostics (copy / reveal) and dSYM artifacts on GitHub Releases. No cloud crash upload.

## Context (already done on `main`)

- Sparkle 2 integrated; Settings → About has update status / check / auto-check
- Menubar update indicator + gentle reminders
- Ad-hoc release pipeline: `./scripts/release.sh --version X.Y.Z --build N`
- Feed URL: `https://github.com/FornaxChemica/WindowLens/releases/latest/download/appcast.xml`
- Public EdDSA key in `Info.plist` / `Sparkle/public_ed25519.key`
- Private key: `.secrets/sparkle_ed25519_private.key` (gitignored) — required for appcast signing
- v1.0.0 DMG + appcast may already be on GitHub Releases; keep `dist/release/WindowLens-1.0.0.dmg` when generating the 1.0.1 appcast so both versions appear

## Out of scope (this update)

- Sentry / Bugsnag / automatic upload
- PLCrashReporter
- MetricKit hang/CPU pipelines
- Paid Developer ID / notarization (stay on ad-hoc)

---

## Implementation plan

### 1. Crash report helper

**New file:** `WindowLens/Sources/Services/CrashReportStore.swift`

- Scan:
  - `~/Library/Logs/DiagnosticReports/`
  - `/Library/Logs/DiagnosticReports/` (if readable)
- Match filenames starting with `WindowLens` and ending in `.ips` or `.crash`
- Sort by modification date (newest first)
- API (suggested):
  - `latestReportURL() -> URL?`
  - `recentReportURLs(limit: Int) -> [URL]`
  - `latestReportSummary() -> String?` (filename + relative date for UI)
  - `copyLatestReportToPasteboard() throws` — copy **file text** (not just path) for GitHub issues
  - `revealLatestInFinder()` — reveal file, or open DiagnosticReports folder if none
- Register the file in `WindowLens.xcodeproj/project.pbxproj` (Services group + Sources build phase), same pattern as `SoftwareUpdateController.swift`

### 2. Settings UI

**Edit:** `WindowLens/Sources/UI/Settings/SettingsTabViews.swift` → `AboutView`

Add a **Diagnostics** section (no new sidebar tab):

| UI | Behavior |
| --- | --- |
| Status | “Latest: \<filename\> (relative time)” or “No crash reports found” |
| **Copy Latest Crash Report** | Calls store; show brief “Copied” confirmation |
| **Show in Finder** | Reveal latest or open reports folder |
| Caption | Reports stay on this Mac until the user shares them |

Match existing Form / grouped style. Keep Updates section as-is.

### 3. Release script: dSYMs

**Edit:** `scripts/release.sh`

- Pass `DEBUG_INFORMATION_FORMAT=dwarf-with-dsym` on Release `xcodebuild` (adhoc + developer-id paths)
- After build, locate `WindowLens.app.dSYM` under DerivedData products
- Zip to `dist/release/WindowLens-<version>.dSYM.zip`
- On `gh release create/upload`, attach **DMG + appcast.xml + dSYM.zip**
- **Do not** put the dSYM zip in the Sparkle appcast (DMGs only for `generate_appcast`)

### 4. Docs

- **README.md** — short “Crashed?” note under Install/Support: Settings → About → Copy Latest Crash Report → paste into GitHub issue
- **docs/RELEASING.md** — document dSYM artifact; remind appcast is DMG-only
- Optional: `.github/ISSUE_TEMPLATE/bug_report.md` with a Crash report section

### 5. Version + ship (human runs release; agent does not deploy per project rules)

| Step | Command / action |
| --- | --- |
| Implement + commit | Conventional commit, e.g. `feat: add crash report diagnostics` |
| Build release | `./scripts/release.sh --version 1.0.1 --build 2` |
| Verify | `dist/release/` has `WindowLens-1.0.1.dmg`, `appcast.xml` (items for 1.0.0 + 1.0.1), `WindowLens-1.0.1.dSYM.zip` |
| GitHub | Release `v1.0.1` with those three assets (script uploads if `gh` auth works) |
| Sparkle smoke test | Machine on **1.0.0** should see update available → install 1.0.1; prefs/shortcuts preserved |

If `dist/release/WindowLens-1.0.0.dmg` is missing locally, re-download it from the v1.0.0 GitHub Release before running `generate_appcast`, or appcast will only list 1.0.1.

### 6. Agent constraints (from repo rules)

- Agent edits **source only** — do not run `./dev-relaunch.sh`, `xcodebuild` for deploy, or install to `/Applications` unless the user explicitly asks in that message
- Do not commit `.secrets/` or `dist/`
- Prefer `feat:` / `fix:` conventional commits

---

## Acceptance criteria

- [ ] About → Diagnostics can copy latest WindowLens `.ips` text to clipboard when one exists
- [ ] About → Diagnostics can reveal report / folder in Finder
- [ ] Empty state is clear when no reports exist
- [ ] `release.sh` produces and uploads `.dSYM.zip` alongside DMG + appcast
- [ ] v1.0.1 published; 1.0.0 clients can update via Sparkle
- [ ] README tells users how to attach a crash report to an issue

## Suggested new-chat prompt

```text
Implement docs/PLAN-crash-diagnostics-1.0.1.md end to end (helper, About UI, release.sh dSYMs, docs).
Do not redeploy the app; I will run ./scripts/release.sh --version 1.0.1 --build 2 myself.
Follow .cursorrules (source-only).
```
