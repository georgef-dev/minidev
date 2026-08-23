# Minidev Implementation Plan

## Status

Planning document for turning the Nix and managed-services design docs into incremental coding milestones. This document does not add production code.

## Current Codebase Baseline

The current implementation is intentionally small:

- `Dev::Project` discovers `dev.yml`, loads YAML, merges top-level `env`, and resolves default/custom commands.
- `Dev::Commands::Up` normalizes `up`, starts `up.services` and `up.serve` through `ProcessManager`, and runs setup steps with `Project#env`.
- `Dev::ProcessManager` starts shell commands with `/bin/bash`, writes logs under `<project_root>/.dev`, tracks YAML records in `<project_root>/.dev/pid.tmp`, checks pids, and stops process groups.
- `Dev::Commands::Contextual` special-cases `server` as a tracked background process and `exec`s other project commands.
- `dev ps`, `dev stop`, and `dev down` are process-registry commands over `.dev/pid.tmp`.
- Tests currently cover command resolution, `up` normalization/resolution, process tracking, and basic command behavior with Minitest.

The plan below evolves these pieces rather than replacing them in one rewrite.

## Pre-Implementation Decision Points

These should be resolved before or during the named milestone, not guessed in code:

- M1 blocker: should `MINIDEV_STATE_HOME` or another override be supported immediately for tests and advanced setups?
- M1 blocker: what exact compatibility behavior should apply to existing `<project_root>/.dev/pid.tmp` records once global instance state exists?
- M1 blocker: should `dev down` remove `.dev/instance.json` or leave it as a cache pointer?
- M2 blocker: should command-oriented unnamed service names keep current generated names like `service-1`, or require stable labels before entering instance state?
- M3 blocker: should `up.serve` support managed service references in the first service-runtime implementation or remain command/process-only until later?
- M3 blocker: when `services.mysql` and `commands.mysql` both exist, should collisions warn immediately, warn only in `dev doctor`, or stay silent during migration?
- M5 blocker: what exact MySQL distribution and binary list are initially supported from Nix?
- M5 blocker: which MySQL initialization command is required for the selected distribution?
- M5 blocker: what defaults apply when `database`, `test_database`, or `username` are omitted?
- M5 blocker: what happens when `password_env` is configured but the named env var is unset?
- M5 blocker: should ordinary commands receive persisted MySQL env when MySQL is configured but stopped?
- M5 blocker: what readiness timeout and retry interval should MySQL use?
- M6 blocker: should `DATABASE_URL` include a password when `password_env` is set, and how should escaping work without persisting secrets?
- M7 blocker: should `dev reset` without a service be rejected or require an explicit all-services mode?
- Cross-cutting: should logs append forever, truncate on each start, or wait for later rotation policy?
- Cross-cutting: should command execution continue using `/bin/bash`, or should a Nix-provided bash become part of the contract?

## Milestone Dependency Graph

1. M1 Instance identity and state foundations.
2. M2 Instance-aware process storage behind existing behavior, depends on M1.
3. M3 Service config parsing and service resolver, depends on M1 and can start after M2 interfaces are stable.
4. M4 Service runtime for generic `process` services and env builder, depends on M1, M2, and M3.
5. M5 Nix contract verification skeleton and adapter binary checks, depends on M3 and M4; must land before MySQL runtime.
6. M6 MySQL adapter prepare/start/readiness/env, depends on M1 through M5.
7. M7 Service-aware stop/down/ps/status/logs/env/reset UX, depends on M4 and partially on M6 for MySQL-specific behavior.
8. M8 Documentation, examples, and migration cleanup, depends on the relevant features shipped in M1 through M7.

Foundations intentionally land before MySQL runtime work. MySQL should not start until instance state, persisted allocations, service resolution, process lifecycle integration, and basic environment verification exist.

## Milestones

### M1: Instance Identity And Global State Foundations

Goal: add the instance model without changing user-visible command behavior.

Likely files/modules:

- Add `lib/dev/instance.rb`.
- Add `lib/dev/instance_state.rb`.
- Possibly add small helpers under `lib/dev/paths.rb` or keep path logic in `Instance` if it stays compact.
- Update test helper support for temporary state root if a state-home override is selected.

Scope:

- Resolve canonical `project_root`, git `worktree_root`, `environment: development`, deterministic `instance_id`, label, and `state_root`.
- Create global state layout under `~/.local/state/minidev/instances/<instance_id>/` or the decided test override.
- Load/create `<state_root>/instance.json` with schema checks, identity, paths, empty allocations, empty services, and instance metadata env.
- Write optional `<project_root>/.dev/instance.json` pointer if the decision says to write it now.
- Add serialized state mutation using the reserved instance `lock` file.
- Keep existing `.dev/pid.tmp` process behavior untouched in this milestone.

Tests:

- Deterministic `instance_id` for the same canonical paths and environment.
- Different worktree roots or project roots produce different ids.
- State directory paths are derived under the selected state root.
- `instance.json` load/create is idempotent and rejects unsupported newer schema.
- Pointer rewrite behavior matches the resolved decision.
- Locking/atomic write behavior is covered at unit level where practical.

Incremental shipping notes:

- This can ship without changing `dev up`, `dev ps`, `dev stop`, or `dev down` output.
- If a state-home override is added, keep it internal or clearly documented as a supported testing/advanced setup contract.

### M2: Instance-Aware Process Persistence Behind Existing Commands

Goal: move generic process records toward instance state while preserving current process UX.

Likely files/modules:

- Update `lib/dev/process_manager.rb` to accept explicit cwd, env, log path, pid path, and registry/state writer inputs.
- Add or extend `Dev::InstanceState` service-record helpers.
- Update `lib/dev/commands/contextual.rb`, `lib/dev/commands/up.rb`, `lib/dev/commands/ps.rb`, `lib/dev/commands/stop.rb`, and `lib/dev/commands/down.rb` only enough to resolve instance state for tracked process operations.
- Add compatibility reader/writer or migration shim if `.dev/pid.tmp` behavior is retained temporarily.

Scope:

- Store process logs under `<state_root>/logs/<name>.log` and pid files under `<state_root>/pids/<name>.pid` for new starts.
- Persist `services.<name>` records with `type: process`, `state`, `pid`, `command`, `pid_path`, `log_path`, timestamps, and `ready: null`.
- Preserve `ProcessManager` spawn, detach, process-group stop, shell wrapping, and pid liveness checks.
- Refresh stale pids by removing liveness fields and pid files while preserving logs.
- Keep existing command names and generated names unless M2 decision changes them.

Tests:

- Starting `server` records a `process` service in instance state and writes logs under global state.
- `ps` returns only live process records and removes stale liveness fields.
- `stop` stops named services and preserves logs/state root.
- `down` stops all tracked process services and preserves durable state according to decided cleanup behavior.
- Existing `up.services` command-only entries still start in the same order.
- Compatibility tests for `.dev/pid.tmp` if a migration layer is implemented.

Incremental shipping notes:

- This is the first user-visible storage migration. Keep command output as close as possible to current output.
- Do not introduce typed services or MySQL in this milestone.

Risky refactors:

- Moving process state from `.dev/pid.tmp` into `instance.json` touches every process-facing command.
- Stale-process cleanup must not delete logs, datadirs, allocations, or unknown state-root files.

### M3: `dev.yml` Services Schema And Resolver

Goal: parse and resolve top-level `services:` without starting typed services yet.

Likely files/modules:

- Update `lib/dev/project.rb` with `service_config`, `services_config`, and narrow validation helpers.
- Add `lib/dev/services/resolver.rb`.
- Add tests around `Dev::Commands::Up` step resolution or move resolution tests to the new resolver.

Scope:

- Support top-level `services:` as a map keyed by service name.
- Validate that service entries have supported `type` values, initially `process` and a recognized-but-not-started `mysql` if MySQL runtime is not yet enabled.
- Resolve `up.services` string items to top-level services before command/raw-shell compatibility.
- Support explicit hash form `{ service: name }`.
- Preserve current `{ command: name }`, `{ run: shell }`, string command, and raw string behavior.
- Keep `dev <name>` resolving project commands only.

Tests:

- `up.services: [mysql]` resolves to `services.mysql` when present.
- Command-only `up.services: [mysql]` still resolves to `commands.mysql` when no top-level service exists.
- `{ service: mysql }` resolves only configured services and errors for unknown services.
- `{ command: mysql }` still resolves project commands even if a service with the same name exists.
- Invalid `services:` shapes fail with direct errors.
- Direct contextual commands are unaffected by top-level service names.

Incremental shipping notes:

- This can ship with `process` services only if `mysql` config is recognized for validation/doctor but refused at runtime with an actionable “not implemented yet” error.
- Do not migrate examples to managed MySQL until M6 works.

Risky refactors:

- Name resolution in `up.services` changes precedence when both `services.<name>` and `commands.<name>` exist. Keep the behavior documented and covered by tests.

### M4: Service Runtime And Env Builder For Generic Processes

Goal: introduce the internal runtime boundary and route `up`/process commands through it for process services.

Likely files/modules:

- Add `lib/dev/service_runtime.rb`.
- Add `lib/dev/services/base.rb`.
- Add `lib/dev/services/process.rb`.
- Add `lib/dev/services/registry.rb`.
- Add `lib/dev/services/env_builder.rb`.
- Update `lib/dev/commands/up.rb`, `lib/dev/commands/contextual.rb`, `lib/dev/commands/ps.rb`, `lib/dev/commands/stop.rb`, and `lib/dev/commands/down.rb` to call runtime APIs.
- Keep `lib/dev/process_manager.rb` as low-level spawn/stop support.

Scope:

- Define internal lifecycle methods: resolve, prepare, start, healthcheck, stop, reset, env, refresh.
- Implement `process` services with minimal prepare/health/env behavior.
- Build command env from inherited env, top-level `dev.yml` env, instance metadata, and service-provided env.
- Run `dev up` setup steps with `EnvBuilder` instead of `Project#env` alone.
- Recompute and persist `resolved_env` after runtime refresh/start.
- Keep `server` behavior as a tracked process, either through service runtime now or behind a thin compatibility call.

Tests:

- Env precedence matches the instance model and all values passed to child processes are strings.
- `dev up` starts dependency process services, runs setup with instance env, then starts serve process services.
- `dev server`, `dev test`, `dev console`, and custom commands receive top-level env and instance metadata once routed through EnvBuilder. If not all are routed in this milestone, tests should define the staged behavior explicitly.
- Runtime refresh removes stale process liveness without deleting logs.
- `down` preserves allocations and durable service state while removing pids/runtime fields.

Incremental shipping notes:

- This is the right point to preserve behavior through broad regression tests before typed services are added.
- If routing every contextual command through EnvBuilder is too large, split into a small follow-up before MySQL env exposure is needed.

Risky refactors:

- Changing env construction affects every command execution path and can cause subtle precedence regressions.
- `dev up` orchestration becomes service-aware while retaining old raw shell behavior.

### M5: Nix Contract And `dev doctor` Skeleton

Goal: add environment verification before relying on Nix-provided MySQL binaries.

Likely files/modules:

- Add `lib/dev/commands/doctor.rb` and register it in `lib/dev/commands.rb`.
- Add a small verifier module, for example `lib/dev/doctor.rb` or `lib/dev/environment_check.rb`.
- Add adapter-level required-binary hooks in service registry/classes without implementing MySQL startup yet.
- Update help text as needed.

Scope:

- Verify project discovery and config parse.
- Check conservative Nix signals.
- Check simple command/script executables where static inspection is reliable.
- Check configured service references and supported service types.
- Check state-root parent writability.
- Check adapter-required binaries for configured managed services once the MySQL binary decision is made.
- Report `ok`, `warn`, `error`, and `unknown`; do not install dependencies, enter Nix, start services, or mutate state beyond safe readability/writability checks.

Tests:

- Missing `dev.yml`, malformed config, missing command, and missing service reference reports are actionable.
- Simple command binary/script detection works and complex shell reports `unknown` rather than false confidence.
- Nix signal detection warns or errors according to the resolved policy.
- Missing MySQL binaries are reported before MySQL runtime exists.
- Doctor does not start services or mutate instance service records.

Incremental shipping notes:

- This can ship before MySQL runtime as an inspection command.
- If exact MySQL binary requirements are unresolved, land doctor without MySQL hard checks and block M6 until the binary list is selected.

### M6: Builtin MySQL Adapter Runtime

Goal: implement managed MySQL as a typed service after foundations are stable.

Likely files/modules:

- Add `lib/dev/services/mysql.rb`.
- Extend `lib/dev/services/registry.rb` for `type: mysql`.
- Extend `lib/dev/services/env_builder.rb` for MySQL service env.
- Extend `lib/dev/instance_state.rb` with allocation helpers for ports and socket paths.
- Possibly add a small port allocator module if keeping it inside MySQL would become too large.
- Update `lib/dev/commands/up.rb` only through runtime APIs, not direct MySQL logic.

Scope:

- Resolve MySQL config and persisted allocations.
- Allocate dynamic TCP port on `127.0.0.1`, persist before startup, and reallocate on non-instance conflicts.
- Derive socket, pid, log, config, datadir, run, and tmp paths from instance state.
- Initialize datadir using the selected Nix-provided MySQL distribution and initialization command.
- Write generated `my.cnf` under `<state_root>/run/mysql/my.cnf`.
- Start `mysqld`, persist pid and `state: starting`, wait for readiness, then mark `running` and `ready: true`.
- Create configured app/test databases and configured user/grants according to resolved decisions.
- Expose `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_SOCKET`, optional database/user/password keys, and URL keys according to resolved decisions.
- Implement graceful MySQL shutdown with process-manager fallback.
- Preserve datadir, logs, socket allocation, and port allocation on `stop`/`down`.

Tests:

- Unit tests for port allocation persistence, reuse, and conflict replacement.
- Unit tests for path derivation and generated config contents.
- Unit tests for env construction with and without database/test database/username/password_env.
- Unit tests for missing binary failure before datadir mutation.
- Unit tests for stale pid, stale socket, missing config regeneration, partial datadir refusal, and failed startup state.
- Integration tests with a Nix-provided or test-fixture MySQL/MariaDB binary set, if available in CI/local test environment.
- Idempotency test: two `dev up` runs reuse datadir, port, socket path, and env when healthy.

Incremental shipping notes:

- Consider shipping MySQL behind documented config support only after real daemon integration tests pass.
- Do not add Redis/Postgres or plugin abstractions in this milestone.
- Keep MySQL logic inside the typed adapter; do not grow `ProcessManager` database semantics.

Risky refactors:

- MySQL combines process management, port allocation, datadir initialization, readiness, database creation, env injection, and graceful shutdown.
- Distribution differences between Oracle MySQL and MariaDB can invalidate initialization/readiness assumptions.
- Secret handling through `password_env` can leak if persisted or printed carelessly.

### M7: Service-Aware UX And Introspection

Goal: make instance state operable through explicit commands.

Likely files/modules:

- Update `lib/dev/commands/ps.rb`, `lib/dev/commands/stop.rb`, and `lib/dev/commands/down.rb` for service-aware output.
- Add `lib/dev/commands/status.rb`.
- Add `lib/dev/commands/logs.rb`.
- Add `lib/dev/commands/env.rb`.
- Add `lib/dev/commands/reset.rb`.
- Register new commands in `lib/dev/commands.rb`.
- Add shared formatting helpers only if repeated output logic becomes unwieldy.

Scope:

- `dev ps` remains process-focused and lists running service pids for the current instance.
- `dev status` shows instance header, configured/recorded services, state, readiness, pid, port, and log path.
- `dev logs` lists log paths or prints one service log without clearing/rotating logs.
- `dev env` prints minidev-controlled env only and redacts secret-like values.
- `dev reset <service>` performs explicit adapter reset and refuses unsafe partial-state cleanup.
- `dev stop` and `dev down` use service runtime stop semantics for both process and MySQL services.

Tests:

- Status output for no state, stopped configured services, running process services, running MySQL service, stale records, and partial state.
- `ps` omits stopped services and cleans stale pids.
- `logs` handles no argument, one known service, unknown service, missing log, and partial missing log path.
- `env` prints only top-level config env, instance metadata, and service env; redacts password-derived values.
- `reset` requires or rejects no-argument usage according to resolved policy, stops running service first, and preserves/refuses paths according to adapter safety.
- Error messages match the short actionable style from `command_ux.md`.

Incremental shipping notes:

- `status`, `logs`, and `env` can ship before `reset` if reset policy remains unresolved.
- Improved `ps` can ship before new commands if service runtime records are already stable.

Risky refactors:

- UX commands must refresh state without starting services or deleting durable data.
- Reset is destructive and should not ship until adapter-owned paths are provably scoped to the active instance.

### M8: Documentation, Examples, And Migration Cleanup

Goal: update user-facing docs once behavior is implemented and tested.

Likely files/modules:

- `README.md` and any existing usage docs.
- `docs/architecture_nix_services.md` status notes if needed.
- Example `dev.yml` files or init templates if the project has them later.
- Tests around generated examples if examples are executable.

Scope:

- Document Nix-only dependency expectations and optional shadowenv role.
- Document new `services:` schema and migration from command-only MySQL.
- Document state layout, `dev doctor`, `dev status`, `dev logs`, `dev env`, and `dev reset` behavior.
- Document known limitations and supported MySQL distribution.
- Remove or downgrade legacy `.dev/pid.tmp` compatibility only after a migration decision and release note exist.

Tests:

- Example configs parse and resolve correctly.
- Help output includes new commands.
- Migration examples preserve direct `dev <command>` semantics.

Incremental shipping notes:

- Docs should track shipped behavior, not future design. Do not publish managed MySQL examples as recommended defaults until M6 is stable.

## Test Matrix

| Area | M1 | M2 | M3 | M4 | M5 | M6 | M7 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Project discovery/config loading | Regression | Regression | Service schema validation | Regression | Doctor checks | Regression | Regression |
| Instance identity/state paths | Unit | Integration with process state | Resolver uses instance where needed | Runtime integration | Doctor state-root checks | MySQL allocations | UX headers |
| State schema/locking | Unit | Process record writes | Service definitions persisted if needed | Runtime writes/refresh | Read-only sanity | Allocation/service writes | Refresh/reset safety |
| Command resolution | Regression | Regression | Service-vs-command precedence | Runtime step execution | Doctor reference checks | MySQL service refs | UX service-name lookup |
| Process lifecycle | Existing plus state migration | Unit/integration | Compatibility unchanged | Runtime process adapter | No mutation by doctor | Fallback stop for MySQL | ps/stop/down/status |
| Env injection | Instance metadata only if introduced | Process env regression | No change or planned | Full EnvBuilder tests | Doctor no secret leaks | MySQL env tests | `dev env` redaction |
| Nix verification | None | None | Supported type metadata | Adapter hooks | Doctor behavior | Missing binary preflight | Status/logs failure display |
| MySQL runtime | None | None | Config recognized only | Refused/not implemented | Binary checks | Unit and integration | Stop/reset/status/logs/env |
| Stale/partial state | Schema errors | Stale pid cleanup | Malformed service refs | Runtime refresh | Doctor sanity | MySQL recovery cases | UX output and reset refusal |
| Backward compatibility | No behavior change | `.dev` migration policy | Command-only services | Existing `up` shapes | Doctor for old configs | Old configs unaffected unless migrated | `dev <name>` remains command-only |

## Incremental Shipping Strategy

- Ship M1 alone if it has no user-visible behavior change and tests prove deterministic identity/state creation.
- Ship M2 only after existing process tests pass with instance storage and migration behavior is explicit.
- Ship M3 with service schema support but no MySQL runtime; fail typed-service startup clearly if necessary.
- Ship M4 after broad regression coverage for `dev up`, `dev server`, `dev ps`, `dev stop`, `dev down`, and env precedence.
- Ship M5 before MySQL so users can diagnose missing Nix tools.
- Ship M6 only after real MySQL lifecycle tests are available or the feature is clearly marked experimental in documentation.
- Ship M7 in slices: improved `ps`/`status`, then `logs`/`env`, then destructive `reset` after safety checks are strong.
- Ship M8 continuously with each feature, but keep future-looking design docs separate from user-facing claims.

## Recommended First Coding Milestone

Start with M1: Instance Identity And Global State Foundations.

Reasons:

- It is the smallest foundation that unlocks every later service feature.
- It can ship without changing current `dev up`, process tracking, or command behavior.
- It creates the state-root and schema boundaries needed before process migration, service runtime, or MySQL allocations.
- It lets tests establish deterministic identity, schema validation, and state-home behavior before more risky lifecycle code depends on it.

Do not start MySQL runtime work until M1 through M5 are complete or consciously scoped with equivalent foundations.

## Highest-Risk Milestones

- M2 is risky because process persistence moves from project-local `.dev/pid.tmp` into global instance state and affects `up`, `server`, `ps`, `stop`, and `down`.
- M4 is risky because env construction and `dev up` orchestration change across command execution paths.
- M6 is the highest-risk runtime milestone because MySQL needs correct Nix binary selection, durable datadir handling, dynamic persisted ports, readiness checks, database/user setup, env exposure, and graceful shutdown.
- M7 `reset` is risky because it is destructive and must prove paths belong to the active instance before deleting anything.

## Conflicts And Tensions Noted

- The architecture says Nix is the only supported dependency source, while existing `dev.yml` examples and current `up.dependencies` still run commands like `bundle install` or `yarn install`. The implementation should preserve current command execution but `dev doctor` and docs should frame Nix as the source of executable tools, not as a replacement for app-level setup scripts unless product direction changes.
- Current code uses `/bin/bash`; the Nix contract leaves Nix-provided bash as an open question. Do not change shell selection incidentally during service work.
- Current `dev down` deletes `.dev` state, while target behavior preserves datadirs and allocations in global state. Output and tests need to change deliberately when M2 lands.
- Top-level `services.mysql` taking precedence over `commands.mysql` only inside `up.services` is intentional but potentially surprising. Tests and migration notes must cover it.
- `dev env` wants to inspect env without starting services, while application commands may need live services. The stopped typed-service env policy must be decided before MySQL env is used broadly.
