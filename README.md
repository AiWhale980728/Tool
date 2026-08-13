# Notch Relay

Notch Relay is a local-first macOS companion for people who use several AI coding agents at the
same time. Its goal is simple: show what is still working, what needs your attention, and what is
ready for review without making you check every terminal window.

## Important: current status

This repository contains the tested background foundation, not the finished desktop product.

There is currently **no clickable notch interface**, menu-bar workbench, visual agent character,
sound, or one-click approval screen. Building or installing the background component will not make
the Mac notch respond to clicks.

The consumer-facing macOS app is still under development. This repository is most useful today to
developers who want to inspect or contribute to the local event relay.

## What works today

- Reads supported lifecycle events from Codex and Claude Code.
- Tracks multiple concurrent agent sessions locally.
- Distinguishes `Working`, `Needs input`, `Needs permission`, `Ready to review`, verified
  `Completed`, `Failed`, `Cancelled`, and `Ended` states.
- Treats a stopped agent as `Ready to review`, not automatically `Completed`.
- Shows a percentage only when a source supplies a trustworthy completed/total pair.
- Keeps terminal presentation records for 24 hours and warns before local cleanup.
- Uses an atomic local queue, crash-safe replay, duplicate protection, and malformed-event
  quarantine.
- Provides preview-first Codex and Claude integration with backups and precise uninstall behavior.
- Runs without a cloud account, remote database, or listening network port.

## Privacy

Notch Relay uses an explicit allowlist. It does not retain prompts, transcripts, model responses,
source code, file contents, raw commands, tool arguments, detailed errors, API keys, cookies,
credentials, or environment variables as task metadata.

The public repository intentionally excludes internal product plans, design research, visual source
material, private validation logs, real agent configuration, runtime state, backups, and personal
computer paths.

See [SECURITY.md](SECURITY.md) for the security model.

## For developers

Requirements:

- macOS 13 or later
- A Swift 6.0-compatible toolchain

Build and run the complete verification suite:

```bash
swift build
./scripts/verify.sh
```

The Swift package has no third-party package dependencies. The public snapshot contains 45
automated tests across 7 suites.

Do not install live agent Hooks unless you understand the configuration preview and have a rollback
plan. Cloning or building this repository does not install anything automatically.

## License

This project is source-available under the
[PolyForm Noncommercial License 1.0.0](LICENSE).

Personal, educational, research, hobby, and other qualifying noncommercial uses are permitted under
the license. Commercial use is not permitted. This is not an OSI-approved open-source license.
