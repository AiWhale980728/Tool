# Security

## Status

Notch Relay is pre-release software. The deterministic Agent Harness and a bounded Completion Review
Shadow Runtime are `部分实现` toward the production AI Supervisor. The runtime includes an
OpenAI-compatible network client, but a request occurs only after the user explicitly enables the
feature, stores a key in macOS Keychain, reviews the bounded context, and clicks `发送并运行 AI 检查`.
The public source tree intentionally excludes the two product system prompts. They are injected from a
Git-ignored local Private Prompt Pack; when that pack is absent, Relay stops before networking and uses
the Harness-only fallback. API keys do not substitute for the missing pack.

The 2026-08-17 baseline passed 237 tests across 40 suites. That does not constitute production release,
online model-quality, provider-processing, accessibility, signing, or notarization acceptance.

The Label Studio annotation workflow is isolated under `Evaluation/LabelStudio/`, binds only to localhost,
uses an internal Docker network, and exports only anonymous case/category/boolean labels to OpenJudge. It
does not read Relay stores or ship in the App. The checked-in synthetic contract does not establish
container or consented production-data acceptance.

## Implemented deterministic boundary

- Relay binds no network port and has no Relay cloud account or remote database.
- Hook payloads are reduced through an explicit metadata allowlist.
- Canonical events do not contain prompts, transcripts, source code, file contents, raw commands, tool
  arguments, tool results, detailed errors, credentials, cookies, tokens, API keys, or environment
  content.
- Queue writes, state snapshots, daemon health, and installation receipts are atomic; a cross-process
  lease prevents multiple consumers from mutating state.
- Integration edits are preview-first, backed up, marked as Relay-owned, reversible, and fail-open.
- Optional Terminal automation reads only the exact matched tab's bounded custom title and TTY, not
  terminal body content, shell history, prompts, transcripts, unrelated tabs, or raw commands.
- Codex current-task reconciliation reads only actively held UUID writer-lock state, title-only
  session-index entries, and optional read-only desktop IPC ownership results. Lock files must be
  same-user regular files, reject symlinks and group/other writes, and retain the same device/inode after
  opening. It does not read Codex auth data, SQLite, previews, turns, transcripts, tool output, or
  account identity; it changes only the in-memory workbench presentation. Private IPC failure falls back
  to the validated local intersection. Identical normalized titles are deduplicated in presentation by
  bounded `updated_at`, keeping the newest session. Local-source failure retains the latest successful presentation
  for at most six seconds, then hides historical Codex rows and reports status unavailable; canonical
  Hook state is retained unchanged.
- Relay never executes Agent tools or approves permissions. The current approval path opens the exact
  source Agent so the human can decide there.
- A Codex `PermissionRequest` alone does not prove an unresolved human prompt. Connector checks whose
  tool name starts with `mcp__codex_apps__` remain running and do not trigger a human-approval claim;
  explicit supported permission requests retain the existing permission-needed path.

## Implemented Completion Review boundary

- Both OpenAI-compatible providers require an injected, non-empty private system prompt. The app loads
  those prompts only from its local resource bundle; missing or invalid prompt resources prevent any
  Supervisor or independent-Evaluator request from being constructed.
- The fixture policy accepts only synthetic L0/L1 fixtures. The separate live-shadow policy requires a
  current `Ready to review` task, exact task/session/event identity, expiry, L0/L1 data, the completion
  review purpose, and exact remote-provider authorization.
- The context builder sends only the user-confirmed goal, acceptance criteria, and structured evidence
  summaries. It does not send evidence references, transcripts, source code, raw commands, credentials,
  or unrestricted repository content.
- Goal, criteria, the optional result summary, evidence summaries, and model assessment text pass a
  high-confidence deterministic scanner for credential assignments, known token prefixes, private keys,
  credentialed connection strings, code fences, and common source declarations. Matching user text is
  rejected before persistence; builder, policy, and provider request construction repeat the check, and
  old matching review records are removed on load. This is `部分实现`: it does not prove arbitrary text
  is non-sensitive and users must still not paste secrets or source code.
- A user-entered result summary is marked partial human evidence and cannot alone satisfy
  `verified_ready`.
- The remote provider returns semantic fields only. Relay wraps trusted task, trace, model, and time
  identity, then runs deterministic grounding, criterion coverage, risk, action-allowlist, and expiry
  checks before showing a card.
- A versioned deterministic Evaluator safety gate separately checks that `verified_ready` has complete
  tool/system evidence covering every criterion, no evidence gap, bounded risk, and low uncertainty.
  Its task, trace, assessment, version, findings, timestamps, and expiry are validated before display.
  This gate remains the only evaluator that can affect deterministic policy.
- The optional independent AI evaluator runs only after the deterministic gate has allowed a shadow
  assessment. Per-call consent must disclose its exact remote Provider/model, and its model must differ
  from the Supervisor model. It receives the same bounded input plus the structured assessment. Result
  identity, score bounds, evidence/criterion references, expiry, sensitive text, Provider identity, and
  exact prompt-version receipt are validated; failure stores a bounded fallback and, only after an
  actual remote attempt, a bounded failure receipt. Its verdict cannot
  change policy, complete a task, write canonical state, or approve permissions.
- Model output cannot write canonical state or complete a task. Only a human decision bound to the
  latest review event can use the local confirmation path.
- Missing keys, timeout, network failure, invalid output, stale identity, or policy rejection fall back
  to the Harness without retaining raw provider responses or detailed provider errors.
- A shared in-process execution coordinator rejects a concurrent review for the same task or trace,
  limits each exact provider to two active calls and ten starts in 60 seconds, and opens a 60-second
  circuit after three consecutive provider failures. Guard rejection returns a bounded Harness-only
  code; it grants no canonical-state or permission authority and persists no task or provider content.
- A successful OpenAI-compatible response may produce a validated receipt containing only Provider ID,
  requested and returned model IDs, an exact Relay prompt version, bounded token counts, bounded latency,
  and completion time. It is stored with the task-deletable review; raw responses, prompts, evidence,
  request headers, account data, and detailed errors are not receipt fields.
- An actual OpenAI-compatible Supervisor or independent-Evaluator request attempt that fails produces
  a separate validated receipt containing only Provider ID, requested model ID, exact Relay prompt
  version, a bounded failure kind, latency capped at 120 seconds, and attempt time. Preflight,
  missing-key, duplicate, concurrency, rate-limit, and circuit-open rejection never produce a failure
  receipt. The receipt is task-deletable and has no request/response body, header, detailed error, task
  text, credential, account, path, or environment field.
- Drafts, structured reviews, deterministic/independent evaluator results and receipts, policy results,
  fallbacks, and human
  decisions are stored separately from canonical events and can be deleted per task. The API key is
  stored only in macOS Keychain.
- A bounded outcome audit links a HumanDecision to a later canonical event ID/status without copying the
  event summary. It is idempotent per decision/event, limited to 512 records and 24 hours, and deleted
  with the task. It records subsequent state only and does not label model quality as correct or wrong.
- The opt-in local Swift verification preset executes project test code only after the user enables the
  per-task toggle and clicks the preparation action. It uses fixed `/usr/bin/xcrun swift test` arguments,
  disables automatic dependency resolution, isolates HOME/build/cache in a temporary directory, limits
  execution to 180 seconds and output to 512 KiB, and discards raw output. Evidence is complete only when
  a non-zero passing test count is parsed and the workspace remains the same clean Git commit.
- The opt-in local Python verification preset similarly requires a regular `tests` directory plus a
  regular `pyproject.toml`, `setup.cfg`, or `setup.py`. It runs fixed system Python `unittest discover`
  arguments with isolated HOME/cache, no `PYTHONPATH`, a 180-second/512-KiB bound, and discarded raw
  stdout/stderr. Only a non-zero pass count bound before and after to the same clean Git commit is complete.
- The separate opt-in pytest preset requires a regular `tests` directory plus a bounded regular
  `pytest.ini` or a `pyproject.toml` with `[tool.pytest.ini_options]`. It invokes only
  `/usr/bin/python3 -I -B -m pytest`, replaces project configuration with a Relay-owned temporary
  config, disables third-party plugin autoload and cacheprovider, isolates HOME/cache, and requests
  pytest's built-in bounded JUnit XML. Raw stdout/stderr and JUnit content are discarded after local
  parsing; only a non-zero passing count bound to the same clean commit is complete. Notch Relay does
  not install pytest or resolve Python packages; real-project coverage depends on a separately installed,
  compatible pytest environment.
- The opt-in Jest preset accepts only a regular project root and regular, non-symlinked project-local
  Jest 30.4.2 package/CLI. It invokes Node only from `/opt/homebrew/bin`, `/usr/local/bin`, or `/usr/bin`
  with fixed JSON/CI/serial/no-cache/no-watch arguments, isolated HOME/cache, a 180-second limit, and
  separate 512-KiB process/report bounds. Raw output and the JSON report are discarded after structured
  count validation; only a non-zero passing count bound to the same clean commit is complete. Relay does
  not call `npx`, install packages, resolve dependencies, or search arbitrary PATH entries. Project tests
  execute project code only after explicit per-task opt-in.
- The opt-in Cargo nextest preset requires bounded regular `Cargo.toml` and `Cargo.lock` files plus
  installed Cargo and cargo-nextest binaries from the user's `.cargo/bin` or fixed standard installation
  paths. It accepts only cargo-nextest 0.9.143, supplies a Relay-owned temporary config, and runs with
  locked/offline/serial/no-retry/no-fail-fast arguments, isolated HOME/Cargo home/target directories, a
  180-second limit, and separate 512-KiB process/JUnit bounds. Raw output and JUnit content are discarded;
  only a non-zero passing count bound to the same clean commit is complete. Relay does not install Rust,
  Cargo, cargo-nextest, or dependencies. Project tests execute code only after explicit per-task opt-in.
- Artifact selection is explicit and task-scoped. Relay accepts at most 8 regular PDF, PNG, JPEG, JSON,
  or ZIP files of at most 32 MiB each, only within the task workspace; it rejects symlinks, path escape,
  unsupported/mismatched formats, mutation during reading, and unreadable files. PDF and image content
  use platform parsers, JSON uses structured parsing, and ZIP uses bounded directory checks.
- Artifact URLs remain in workbench memory and expire when the task event changes or local review data is
  deleted. Persisted evidence contains only format, size bucket, and a local SHA-256 reference. The remote
  request excludes the reference, file name, path, and content. Complete integrity proves only existence
  and basic format validity, never content quality, correctness, signing, or suitability.

Real provider responses, latency, cost, model quality, and provider-side handling have not been accepted
as production evidence even though the bounded network code path is `已实现`.

## Quota and telemetry boundary

- Codex quota uses a fixed-argument, read-only, untrusted local Codex App/CLI app-server subprocess with an
  8-second deadline, 256 KiB output limit, and child-process cleanup.
- Only the primary `codex` rate-limit bucket is presented. Named special buckets under
  `rateLimitsByLimitId` are not interpreted as the active task model. The active model label comes only
  from exact Hook metadata.
- The same bounded session may request `account/usage/read`; Relay keeps only validated latest-day and
  lifetime Token totals in memory and discards daily history and raw responses.
- Relay does not read Codex auth files, browser cookies, credential tokens, or account email. Raw stdout/stderr is
  discarded; normalized quota and Token summary values exist only in memory for the workbench. Missing ChatGPT subscription
  authentication is classified as sign-in required and never triggers browser-cookie or auth-file fallback.
- Local product telemetry has no free-form field. Its schema can represent only a fixed event name,
  surface, outcome, duration bucket, timestamp, and random event ID.
- Telemetry cannot represent task names, session IDs, account identity, quota/balance values, plan,
  prompts, code, paths, keys, or raw responses. It is limited to 30 days or 10,000 events and has a
  delete control.

## Not implemented

The following remain `未开发` and must not be inferred from schemas, mock providers, or target docs:

- general cross-Loop EvidenceStore, other independent frameworks beyond the current
  Swift/Python/Jest/Cargo nextest paths, and CI
  providers beyond GitHub;
- production gold set, approved regression thresholds, independent AI Evaluator calibration, objective
  outcome labels/quality feedback, and cost/quality gates;
- automatic Completion Review triggering;
- persistent retry scheduling, cross-process provider quotas, and cost receipts; the
  implemented execution coordinator is intentionally process-local;
- comprehensive semantic DLP beyond the implemented high-confidence deterministic scanner;
- ContextPackage export/import, revocation, and cross-Agent access control;
- AI permission explanation or Relay-side `Allow once`, deny, or answer response channels;
- automatic permission approval or unrestricted model tool use;
- Developer ID signing, notarization, production updater, and complete accessibility/security matrix.

Any future evidence or tool capability requires separate purpose-bound consent, minimum necessary data,
provenance and freshness, deterministic redaction, audit, expiry, deletion, and Harness-only fallback.
Model output may recommend an action but cannot bypass identity, authorization, expiry, policy, or human
approval checks.

## Local data

Runtime data is stored outside the source repository in the current user's application-support
directory. Run `relayctl paths` to inspect resolved locations. The store may include bounded project
labels, session identifiers, timestamps, canonical events, state snapshots, archives, quarantine,
daemon metadata, logs, local priority, integration backups, Completion Review drafts/results/decisions,
and privacy-bounded telemetry. Do not publish it.

## Reporting a vulnerability

Do not disclose secrets, private prompts, local paths, or exploit details in a public issue. Contact the
repository owner privately through GitHub and include only the minimum information required to reproduce
the issue safely.
