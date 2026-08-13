# Security

## Current status

Notch Relay is in pre-validation. It has passed automated and isolated end-to-end checks, but it has
not yet completed live validation against real Codex and Claude user configurations.

Do not treat the current revision as production-ready.

## Security model

- The relay binds no network port and requires no cloud service.
- Hook payloads are reduced through an explicit metadata allowlist.
- Prompts, transcripts, model output, code, tool arguments, tool results, and detailed error text
  are not retained.
- Queue writes, state snapshots, daemon health, and installation receipts are written atomically.
- The processor uses a cross-process lease to prevent multiple consumers from mutating state.
- Integration edits are preview-first, backed up before mutation, and scoped by an ownership marker.
- Hook commands support fail-open behavior so relay failures do not block the coding agent.

## Local data

Runtime data is stored outside the source repository in the current user's application-support
directory. Run `relayctl paths` to inspect the resolved locations.

The store may contain session identifiers, project labels, timestamps, state snapshots, archives,
quarantine files, daemon metadata, logs, and configuration backups. Do not publish it.

## Reporting a vulnerability

Do not disclose secrets, private prompts, local paths, or exploit details in a public issue. Contact
the repository owner privately through GitHub and include only the minimum information required to
reproduce the issue safely.
