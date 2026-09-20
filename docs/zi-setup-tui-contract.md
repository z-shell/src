# Zi Setup TUI contract

## Status and purpose

This document defines the engine contract and next terminal-interface milestone after the guided setup planner shipped in `src` pull request 221. It refines the broader Zi Setup product proposal into a bounded terminal interface that delegates all installation and configuration changes to `public/sh/setup.sh`.

The terminal interface is a client of the setup engine. It does not resolve Zi paths independently, generate startup files, edit `.zshrc`, install recipes, or reinterpret a plan. Normal shell startup remains independent of the interface.

[Issue 222](https://github.com/z-shell/src/issues/222) records the interface trigger required by [ADR-0025](https://github.com/z-shell/.github/blob/main/decisions/0025-guided-setup-planner-first.md): the planner's manual commands and artifact layout require installer knowledge that blocks the intended guided onboarding experience.

## Revised implementation brief

Build a local Zi Setup TUI pilot that guides a user through discovery, profile selection, review, apply, and results. Use the existing `src` planner as the only authority for resolved paths, generated Zsh, preconditions, file content, checkout operations, and receipts.

The pilot supports two selectable profiles:

- `loader`, presented as **Zi only**.
- `annex`, presented as **Zi with annexes**.

The `zunit` profile is not a user-facing setup choice. The engine keeps support for it so existing installer output can be migrated without data loss. When discovery or planning retains a legacy `zunit` configuration, the interface identifies it as preserved compatibility content and does not recommend it to new users.

The pilot must complete one real flow in a disposable home:

`Discover -> Choose -> Review -> Apply -> Result`

The Review screen shows the exact plan identity, checkout operation, target paths, generated Zsh, file diffs, deferred first-start work, warnings, and manual steps. Apply invokes the engine with the reviewed plan hash. Reopening the interface against the resulting home must report no content changes. The new plan hash may differ because current-file preconditions are part of the artifact.

Use Go with Bubble Tea v2, Lip Gloss v2, and only the Bubbles components needed by the pilot. The interface must remain usable at 80x24, support keyboard-only navigation, restore the terminal after errors and signals, honor `NO_COLOR`, and provide a linear `--plain` presentation. Rich previews use deterministic sample data and are clearly labelled as simulations.

The pilot does not include arbitrary plugin selection, a marketplace, prompt replacement, removal of another manager, system package installation, font changes, `chsh`, a background service, current-shell mutation, or automatic migration of unknown Zsh configuration.

## Ownership

`src` owns the setup engine, versioned interface artifacts, profile mapping, generated Zsh, plan validation, application, and receipts. The eventual `zi-setup` package owns terminal interaction, presentation state, synthetic previews, accessibility modes, and process orchestration.

The interface may display engine output for diagnostics, but it must not parse human-readable stdout or stderr to make decisions. It consumes only documented interface artifacts and exit statuses.

## Engine interface

### Design rules

The interface uses directory artifacts rather than JSON written by portable shell. Each field has a fixed relative path and contains raw bytes or one restricted token. This avoids shell-level JSON escaping and keeps paths with spaces unambiguous. Artifact directories are private temporary directories chosen by the caller.

Each new artifact begins with a `format` file containing its exact schema identifier. The existing plan artifact keeps its `format` key in `plan.meta`. Consumers reject unknown major versions. The output, plan, and result destinations must not exist, and their immediate parents must already exist and be writable. Writers publish each artifact by creating a private staging directory beside the destination and renaming the completed directory into place.

The engine owns validation of all user-controlled values. The client passes arguments as an argument array and never evaluates engine output.

### Commands

The existing `plan` and `apply` commands remain the mutation boundary. The engine exposes these machine-facing artifacts:

```text
setup.sh describe --output DIR [--zi-home DIR] [--zi-bin-dir NAME]
                  [--config-home DIR] [--zshrc FILE] [--profiles FILE]
                  [--skip-zshrc]
setup.sh plan --plan DIR [existing options]
setup.sh apply --plan DIR --phase checkout|files [--expect SHA256]
               [--result DIR] [--events DIR]
```

`describe` performs bounded read-only discovery. It does not source `.zshrc`, `init.zsh`, Zi, or plugins. It still publishes a describe artifact when all profiles are blocked, then exits with status 3. `plan` remains deterministic for the same filesystem inputs and selected options. `apply` continues to validate the complete plan and relevant preconditions before mutation. When `--result` is present, it publishes a result for validation failures, completed phases, operation failures, and cancellation. When `--events` is present, it publishes machine-readable streaming events for active operations into a private directory. Omitting `--result` and `--events` preserves the existing shell interface.

Human-readable stdout and stderr remain available for direct shell use. Their wording is not part of the interface contract.

### Describe artifact

`zi-setup-describe-v1` contains:

```text
format
facts/order
facts/<id>/value
facts/<id>/source
facts/<id>/confidence
profiles/order
profiles/<id>/selectable
profiles/<id>/reason
profiles/<id>/title
```

Fact IDs and profile IDs use lowercase ASCII letters, digits, and hyphens. `source` is one of `observed`, `inferred`, `confirmed`, or `unknown`. `confidence` is one of `certain`, `likely`, or `unknown`. `selectable` is `yes` or `no`.

Version 1 writes facts in this order: `config-home`, `zi-home`, `checkout-path`, `zi-home-state`, `zshrc-path`, `zshrc-state`, `git`, `zsh`, `tty`, and `existing-profile`. `zi-home-state` is `selected` or `ambiguous`. `zshrc-state` is `skipped`, `symlink`, `file`, `other`, or `missing`. The `git` and `zsh` values are `available` or `missing`, `tty` is `yes` or `no`, and `existing-profile` is `none`, `loader`, `annex`, or `zunit`. `zi-home` and `checkout-path` contain `unknown` when both supported Zi homes exist without one safe identity.

Version 1 lists `loader` and `annex` in that order. They are selectable when the Zi home is unambiguous and both Git and Zsh are available. If an exact legacy `zunit` block or a `zunit` receipt is detected, `zunit` appears with `selectable=no` and a reason explaining its compatibility-only status. The interface must not synthesize choices absent from this artifact.

### Plan artifact

The shipped `zi-setup-plan-v1` directory is a documented read contract for the fields below. Existing content and precondition files remain engine-owned.

```text
plan.id
plan.meta
checkout/kind
checkout/head
checkout/current-ref
checkout/origin
checkout/requested-ref
targets/order
targets/<id>/path
targets/<id>/kind
targets/<id>/expected
targets/<id>/mode
targets/<id>/content
targets/<id>/block-hash        # only when applicable
operations/order
operations/<id>/phase
operations/<id>/kind
operations/<id>/summary
operations/<id>/interruptible
warnings/order
warnings/<id>/severity
warnings/<id>/summary
warnings/<id>/remediation
```

`plan.meta` remains restricted `key=value` data whose values cannot contain newline or tab. Version 1 writes `format`, `profile`, `ref`, `config_home`, `checkout_path`, `receipt_path`, and `skip_zshrc`. Other files contain raw bytes unless their values are explicitly restricted tokens.

Version 1 always lists `checkout-sync` and `write-files` operations. `checkout-sync` has phase `checkout`, kind `clone` or `fast-forward`, and `interruptible=no`. `write-files` has phase `files`, kind `write-files`, and `interruptible=no`. Warning severity is one of `info`, `warning`, or `critical`. The current conditional warning IDs are `deferred-first-start`, `legacy-zunit`, and `zshrc-skipped`.

Operation summaries and warnings are display text. The client treats them as untrusted terminal content and strips or visibly escapes control sequences. Decisions use IDs and restricted fields, never summary text.

The plan hash covers every artifact file except `plan.id`, as it does today. Any field change produces a new plan identity. The TUI stores the reviewed `plan.id` and always passes it through `--expect` for both phases.

### Apply result artifact

`zi-setup-result-v1` contains:

```text
format
plan.id
phase
status
operations/order
operations/<id>/status
operations/<id>/detail
error/code                         # present on failure
error/operation                    # present when attributable
error/detail                       # present on failure
receipt/path                       # present after successful files phase
```

`status` and operation status are restricted tokens: `pending`, `running`, `succeeded`, `failed`, `cancelled`, or `unknown`. A completed version 1 artifact uses `succeeded`, `failed`, or `cancelled`. Error codes are stable ASCII identifiers including `unsupported-version`, `plan-changed`, `target-drift`, `checkout-drift`, `lock-held`, `network-failed`, `checkout-failed`, `write-failed`, and `cancelled`.

`operations/order` contains the phase operation when execution reached or completed that operation, and is empty for a global failure. `error/operation` is omitted when the failure is not attributable to an operation, including unsupported versions, changed plan content, and a lock already held before the operation begins.

When `--events` is omitted, the engine publishes results only at phase completion or failure. When `--events DIR` is provided, the engine additionally publishes machine-readable streaming events for each active operation as described below.

### Streaming event artifact

`zi-setup-event-v1` defines the streaming event directory contract published under `setup.sh apply ... --events DIR`:

```text
format
phase
operation
status
detail
```

- `DIR` is created by the engine with mode `0700`. The path must be absolute, must not already exist, must not be a symlink, and must have a writable parent directory. Event initialization or invalid path failures are refused with exit status 2 before apply begins, whereas publication failures after an operation has started exit with status 5. No root-level files are written to `DIR`.
- Each event is published atomically as a directory under `DIR` named with a six-digit sequence (`000001`, `000002`, ...). Each event is staged under a hidden temporary directory (`.tmp-event.*`) inside `DIR`, all fields are written, and the completed directory is renamed into place.
- All event files are restricted single-line text ending in a newline:
  - `format`: `zi-setup-event-v1`
  - `phase`: `checkout` or `files`
  - `operation`: the current stable plan operation ID (`checkout-sync` or `write-files`)
  - `status`: `started`, `succeeded`, or `failed`
  - `detail`: bounded static display text safe under artifact rules (no newlines, tabs, or control characters).
- Lifecycle:
  - `started` is published immediately before executing the selected operation.
  - `succeeded` is published only after that operation completes.
  - `failed` is published from the existing error path when an event operation is active.
  - Ordinary cancellation after an operation has `started` publishes `failed`, removes staging directories, and exits 6. In the narrow limit where a signal interrupts event publication itself, the terminal event may be omitted while cleanup and exit 6 remain.
  - Duplicate terminal events (`succeeded` or `failed`) are prevented.
  - If a failure occurs before an operation begins (e.g. invalid arguments, unsupported version, plan hash mismatch, or a held lock), no event operation is active and no event directories are published.
- Events are observational only: they do not change plan IDs, result contracts, exit codes, stdout, stderr, mutation order, or rollback behavior.

### Exit status contract

- `0`: requested operation succeeded; its result artifact is complete when `--result` was requested.
- `2`: invocation, unsupported interface version, or event directory initialization/path refusal.
- `3`: discovery or planning cannot produce an actionable artifact.
- `4`: a plan, checkout, or file precondition changed.
- `5`: an apply operation began but did not complete, or event publication failed after start.
- `6`: the user or supervising process cancelled the operation.

The result artifact carries the specific reason. The exit status only selects the broad recovery path.

## TUI states

The TUI owns presentation state and maps it to engine actions as follows:

| State          | Engine interaction       | Required presentation                                                                            |
| -------------- | ------------------------ | ------------------------------------------------------------------------------------------------ |
| Discover       | `describe`               | Observed paths, Zsh availability, existing Zi evidence, uncertainties, and blockers              |
| Choose         | None                     | Zi only and Zi with annexes; preserve a detected legacy choice                                   |
| Review         | `plan`                   | Plan hash, checkout operation, exact paths, generated Zsh, diffs, warnings, and first-start work |
| Apply checkout | `apply --phase checkout` | Named operation, cancellation boundary, sanitized details, and result                            |
| Apply files    | `apply --phase files`    | Named operation, changed targets, receipt path, and result                                       |
| Result         | Optional new `plan`      | Completed work, deferred first-start work, manual steps, and no-content-change verification      |

Going backward discards the old plan and creates a new one after choices change. A plan is never edited in place. Resizing and theme changes preserve the selected profile and current review position.

## Acceptance matrix

| Scenario                           | Expected engine result                                    | Expected TUI behavior                                                                    |
| ---------------------------------- | --------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Fresh home, Zi only                | `loader` plan with missing checkout and new managed files | Review all paths, apply both phases, show receipt, then reopen with no content changes   |
| Fresh home, annexes                | `annex` plan with deferred first-start recipes            | Explain deferred work before approval and repeat it on the result screen                 |
| Exact legacy loader block          | Safe migration plan                                       | Show removed legacy block and new managed block in the diff                              |
| Exact legacy `zunit` block         | Compatibility migration retains `zunit`                   | Identify preserved legacy content; do not present `zunit` as a selectable recommendation |
| Unknown Zi integration             | No actionable plan                                        | Preserve files and offer engine-produced remediation or patch guidance                   |
| Symlinked `.zshrc`                 | Files phase refuses with patch guidance                   | Show manual action; never imply partial success                                          |
| Target changes after review        | Files phase reports `target-drift`                        | Return to Review and require a new plan                                                  |
| Checkout HEAD changes after review | Checkout phase reports `checkout-drift`                   | Preserve checkout and require a new plan                                                 |
| Plan content changes               | Apply reports `plan-changed`                              | Refuse apply and discard the plan                                                        |
| Network failure during checkout    | Checkout result is failed; files phase has not run        | Show the failed operation and safe retry path                                            |
| Checkout succeeds, files fail      | Separate phase results expose partial application         | Report checkout success and file failure without claiming rollback                       |
| No TTY or `--plain`                | Same choices and plan identity as TUI                     | Render a linear review and require explicit apply input                                  |
| 80x24 terminal                     | Same model and choices as wide layout                     | Use one pane with switchable preview sections                                            |
| `NO_COLOR` set                     | Same content and navigation                               | Disable color while retaining readable focus markers                                     |
| Interrupt before apply             | No mutation                                               | Restore the terminal and retain or discard the plan according to the user's choice       |

## Verification required for the milestone

- Contract tests for every documented artifact path, restricted token, plan hash input, and exit status.
- Golden fixtures for fresh `loader`, fresh `annex`, retained legacy `zunit`, safe migration, ambiguous integration, symlink refusal, and drift failures.
- Proof that TUI and plain mode produce the same planner arguments and approve the same plan hash.
- Pseudo-terminal tests for navigation, resize, signals, terminal restoration, monochrome mode, and control-sequence sanitization.
- Disposable-home integration tests that apply both phases, inspect the receipt, start the generated configuration with the supported Zsh, and reopen with no content changes.
- Existing `sh tests/installers.sh` coverage on Linux and macOS, plus the current Windows installer checks.

## Delivery sequence

1. Record the ADR-0025 interface trigger on [issue 222](https://github.com/z-shell/src/issues/222).
2. Implement and test the versioned engine artifacts in `src` without adding TUI code.
3. Create the local Go package and implement Discover, Choose, and Review against fixtures and the engine contract.
4. Add checkout and files application with exact plan-hash approval and result handling.
5. Validate the full flow in disposable homes, then decide whether streaming events or additional capabilities have earned their maintenance cost.

No push, pull request, release, or distribution bootstrap is part of this milestone unless separately authorized.
