# Minidev Command UX And Introspection

## Status

Draft UX design for future instance-aware and service-aware commands. This document defines behavior only; it does not define production code.

## Scope

Commands covered here:

- `dev status`
- `dev logs [service]`
- `dev reset [service]`
- `dev env`
- improved `dev ps`
- stale-state cleanup behavior shared by these commands

Existing commands keep their current broad roles:

- `dev up` starts dependency services, runs setup, and starts serve processes.
- `dev server` starts the primary app server as a tracked process.
- `dev stop [service]` stops selected tracked services and preserves durable state.
- `dev down` stops the instance and cleans ephemeral runtime state, but does not reset durable data.

The new commands must not create overlapping semantics. They inspect, display logs/env, or perform explicit destructive reset.

## UX Principles

- Prefer short, stable, human-readable output.
- Always show which instance is being inspected when the command is instance-scoped.
- Always use service names from instance state or `dev.yml`; do not expose generated internal IDs unless no name exists.
- Refresh liveness before reporting process or service state.
- Preserve datadirs, allocations, and logs unless the user explicitly runs `dev reset` or a later log-retention command.
- Treat missing state as normal for a project that has not run `dev up` yet.
- Report stale and partial state clearly, then give the smallest useful recovery command.

## Common Instance Header

`dev status`, `dev env`, and multi-service `dev logs` output should include a concise instance header.

Example:

```text
Instance: shop:development
Project:  /Users/alice/src/github.com/example/shop
State:    /Users/alice/.local/state/minidev/instances/v1-6f5fc1a...
```

Rules:

- Use the human-readable instance label for display only.
- Truncate `instance_id` in human output when space matters, but show the full `state_root` path.
- Do not require `.dev/instance.json`; derive identity from current project/worktree/environment if the pointer is missing.

## Service States

Commands should present service state with a small vocabulary:

- `running`: recorded process exists and service readiness is satisfied or not applicable.
- `starting`: process exists, but readiness has not completed.
- `stopped`: service is configured or recorded, but no process is running.
- `failed`: last start or healthcheck failed and the service is not healthy.
- `stale`: persisted pid or runtime record points to a process that is gone or not owned by this instance.
- `partial`: state has enough information to identify the service, but required runtime files, pid, readiness marker, or allocation records are inconsistent.
- `unknown`: state cannot be trusted because the schema is unsupported or the record is malformed.

`process` services normally show readiness as `-` because pid liveness is the only health signal. Typed services such as `mysql` should show readiness as `ready`, `not ready`, or `unknown`.

## `dev status`

Purpose: answer "what instance am I in, what services are configured, and what is healthy?"

Semantics:

- Resolve the current project and instance.
- Load or create minimal instance state if needed to display identity.
- Refresh all recorded services and configured services referenced by `up.services`, `up.serve`, and top-level `services:`.
- Display configured services even if they have never been started.
- Display tracked compatibility process records until migration removes `.dev/pid.tmp` support.
- Do not start, stop, reset, or delete durable state.
- May remove stale pid files and stale liveness fields as part of refresh; see stale-state cleanup below.

Example healthy output:

```text
Instance: shop:development
Project:  /Users/alice/src/github.com/example/shop
State:    /Users/alice/.local/state/minidev/instances/v1-6f5fc1a...

SERVICE  TYPE     STATE    READY  PID    PORT   LOG
mysql    mysql    running  ready  12345  54321  logs/mysql.log
worker   process  running  -      12346  -      logs/worker.log
server   process  stopped  -      -      -      logs/server.log
```

Example no state yet:

```text
Instance: shop:development
Project:  /Users/alice/src/github.com/example/shop
State:    /Users/alice/.local/state/minidev/instances/v1-6f5fc1a...

No services have been started for this instance.
Run `dev up` to start configured services.
```

Example stale output:

```text
Instance: shop:development
Project:  /Users/alice/src/github.com/example/shop
State:    /Users/alice/.local/state/minidev/instances/v1-6f5fc1a...

SERVICE  TYPE     STATE    READY      PID    PORT   LOG
mysql    mysql    stopped  not ready  -      54321  logs/mysql.log
worker   process  stale    -          12346  -      logs/worker.log

Cleaned stale pid records: worker
Run `dev up` to restart required services.
```

Error guidance:

- Outside a project: `No dev.yml found. Run this command inside a minidev project.`
- Unreadable state: `Could not read instance state: <path>. Fix permissions or remove the state directory if it is disposable.`
- Unsupported schema: `Instance state schema <n> is newer than this minidev. Upgrade minidev or remove local state after stopping services manually.`

## Improved `dev ps`

Purpose: answer "which tracked OS processes are currently running for this instance?"

Semantics:

- `dev ps` is process-focused, not full health/status.
- Resolve the current instance and refresh liveness.
- Show only services with currently running pids.
- Do not show configured-but-stopped services; `dev status` owns that view.
- Include service type, pid, uptime or start time, and command when known.
- Preserve compatibility with the current mental model: an empty result should be quiet and useful.

Example output:

```text
NAME    TYPE     PID    STARTED   COMMAND
mysql   mysql    12345  14:32:10  mysqld --defaults-file ...
worker  process  12346  14:33:01  bundle exec sidekiq
```

Example empty output:

```text
No tracked processes are running for shop:development.
```

Stale behavior:

- If stale records are found, remove stale pid files and liveness records during refresh.
- After cleanup, do not print stale records in the table.
- Print one concise notice only when cleanup changed state.

Example:

```text
Cleaned stale pid records: worker
No tracked processes are running for shop:development.
```

Compatibility note:

- Exact compatibility behavior for legacy `<project_root>/.dev/pid.tmp` is unresolved. Until decided, `dev ps` should not silently ignore legacy running processes if the migration layer can read them safely.

## `dev logs [service]`

Purpose: show where logs are and print recent log content for one service.

Semantics:

- With no argument, list known service log paths and their service states.
- With a service argument, print recent log content for that service.
- Do not start services.
- Do not clear or rotate logs.
- Refresh liveness first so stale services are labeled accurately.
- Prefer log paths relative to `state_root` in tables; print absolute paths when reporting errors or a single selected service.

Example no argument:

```text
Instance: shop:development

SERVICE  STATE    LOG
mysql    running  logs/mysql.log
worker   stopped  logs/worker.log
server   stopped  logs/server.log

Run `dev logs mysql` to print a service log.
```

Example service output:

```text
Log: /Users/alice/.local/state/minidev/instances/v1-6f5fc1a.../logs/mysql.log

2026-06-05T14:32:10 mysqld starting
2026-06-05T14:32:12 ready for connections
```

Missing or empty logs:

```text
No log file exists for mysql yet.
Run `dev up` to start the service.
```

Unknown service:

```text
Unknown service: redis
Known services: mysql, worker, server
```

Partial state:

- If a service record exists but `log_path` is missing, report partial state and suggest `dev status`.
- Do not invent a log path from the service name unless the state model defines one during refresh.

Example:

```text
Service mysql has partial state: missing log path.
Run `dev status` to refresh state, or `dev reset mysql` if the service cannot recover.
```

Open UX point:

- Tail/follow behavior is not specified here. If added later, prefer an explicit flag such as `dev logs mysql --follow` rather than a separate command.

## `dev reset [service]`

Purpose: recover from bad local state through explicit destructive cleanup.

Semantics:

- `dev reset <service>` resets one service using its service-specific reset strategy.
- `dev reset` without a service resets instance runtime state only if that behavior is explicitly confirmed by a later decision. For now, this document recommends requiring a service argument to avoid accidental broad data loss.
- Always stop the selected service before reset if it is running.
- For `process` services, reset means stop the process and clear runtime records; it does not delete unrelated project data.
- For `mysql`, reset may remove the instance-specific MySQL datadir, socket, pid, readiness markers, and service env derived from that datadir. Exact MySQL data behavior belongs to the MySQL adapter spec.
- Reset may keep or reallocate persisted ports depending on adapter rules. If a port is kept, state must be internally consistent after reset.
- Reset must not affect other worktree instances.
- Reset must not delete global state outside the active `state_root`.

Example process reset:

```text
Stopping worker (PID 12346)
Reset worker runtime state.
Log preserved: /Users/alice/.local/state/minidev/instances/v1-6f5fc1a.../logs/worker.log
```

Example MySQL reset:

```text
Stopping mysql (PID 12345)
Reset mysql data for shop:development.
Removed: data/mysql, sockets/mysql, pids/mysql.pid
Preserved: logs/mysql.log
Run `dev up` to initialize mysql again.
```

Unknown service:

```text
Unknown service: redis
Known services: mysql, worker, server
```

Missing state:

```text
No state exists for mysql in shop:development.
Nothing to reset.
```

Partial state:

- Reset is allowed for partial service state if the service adapter can identify owned paths safely.
- If owned paths cannot be proven, refuse destructive cleanup and print the state root for manual inspection.

Example refusal:

```text
Cannot safely reset mysql: state is missing data_dir.
State root: /Users/alice/.local/state/minidev/instances/v1-6f5fc1a...
No files were removed.
```

Confirmation:

- This design does not require an interactive confirmation for `dev reset <service>` because the service argument is explicit.
- If `dev reset` later supports resetting all services or deleting the whole instance state root, it should require an explicit `--all` or similarly clear argument.

## `dev env`

Purpose: show the resolved environment that `minidev` would inject into project commands.

Semantics:

- Resolve the current instance.
- Refresh service state enough to keep service-provided env consistent with persisted allocations.
- Print only env values added or overridden by `minidev`: top-level `dev.yml` env, instance metadata, and service-provided env.
- Do not print the full inherited shell environment by default.
- Do not start services.
- Do not print secret values when the source is secret-like or comes from `password_env`; redact them.

Default output should be shell-compatible `KEY=value` lines:

```text
RAILS_ENV=development
MYSQL_HOST=127.0.0.1
MYSQL_PORT=54321
MYSQL_SOCKET=/Users/alice/.local/state/minidev/instances/v1-6f5fc1a.../sockets/mysql/mysql.sock
MYSQL_DATABASE=shop_development
MYSQL_USERNAME=shop
MYSQL_PASSWORD=<redacted>
DATABASE_URL=mysql2://shop@127.0.0.1:54321/shop_development
MINIDEV_INSTANCE_ID=v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa
MINIDEV_STATE_ROOT=/Users/alice/.local/state/minidev/instances/v1-6f5fc1a...
MINIDEV_PROJECT_ROOT=/Users/alice/src/github.com/example/shop
MINIDEV_WORKTREE_ROOT=/Users/alice/src/github.com/example/shop
MINIDEV_ENVIRONMENT=development
```

Missing service state:

```text
RAILS_ENV=development
MINIDEV_INSTANCE_ID=v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa
MINIDEV_STATE_ROOT=/Users/alice/.local/state/minidev/instances/v1-6f5fc1a...

# mysql is configured but has not been prepared; service env is not available yet.
# Run `dev up` to allocate mysql resources.
```

Rules for stopped typed services:

- If persisted allocations exist and are internally consistent, `dev env` may print the last resolved service env even when the service is stopped.
- If env depends on missing or partial allocations, omit those keys and print a concise comment explaining why.
- Commands that require service liveness should use `dev status` or `dev up`; `dev env` is an inspection command, not a readiness check.

Open UX point:

- Whether `dev env` should include inherited environment values behind a flag is unresolved. Default output should stay scoped to minidev-controlled values to avoid leaking secrets and producing noisy output.

## Missing, Stale, And Partial Service Behavior

Missing configured service:

- A service named in `dev.yml` but absent from state should appear as `stopped` in `dev status`.
- `dev ps` should omit it.
- `dev logs <service>` should say no log exists yet unless a known log path exists.
- `dev reset <service>` should say there is nothing to reset unless durable state exists.
- `dev env` should omit service env until resources have been allocated.

Stale service:

- A stale pid is not a running service.
- Refresh should remove stale pid files and clear pid/liveness fields.
- `dev status` may report that stale records were cleaned and show the service as `stopped` or `failed` depending on adapter state.
- `dev ps` should not show stale services after cleanup.
- Logs and datadirs must be preserved.

Partial service:

- Partial state means `minidev` cannot trust the record enough to report a normal state.
- `dev status` should show `partial` and include a one-line reason when possible.
- `dev logs` should work only if a trusted log path exists.
- `dev env` should omit env values derived from missing allocations.
- `dev reset <service>` may clean only paths the adapter can prove belong to the active instance.

Example partial status:

```text
SERVICE  TYPE   STATE    READY    PID  PORT   LOG
mysql    mysql  partial  unknown  -    54321  -

mysql: missing log_path and data_dir in instance state.
Run `dev reset mysql` if the service cannot recover.
```

## Stale-State Cleanup Behavior

Refresh should be safe, narrow, and automatic for introspection commands.

Automatic cleanup may remove:

- Stale pid files for processes that no longer exist.
- Runtime liveness fields such as `pid`, `ready`, `state=running`, and process-group metadata when the process is gone.
- Temporary files under `<state_root>/tmp` that are known to be owned by minidev.
- Project-local `.dev/instance.json` when it disagrees with freshly derived identity, after rewriting the correct pointer.

Automatic cleanup must not remove:

- Service datadirs.
- Logs.
- Persisted port allocations, unless the adapter determines the allocation is unusable and safely writes a replacement.
- Socket directories for stopped typed services unless the adapter reset or start flow owns that cleanup.
- Unknown files in the state root.
- State for any other instance.

Port cleanup rules:

- Persisted ports should be kept when free or owned by the active service.
- If a persisted port is occupied by another process not owned by the instance, mark the service `failed` or `partial` and let the next start/prepare flow reallocate according to adapter rules.
- `dev status` should report the conflict; it should not kill the other process.

Example port conflict:

```text
SERVICE  TYPE   STATE   READY      PID  PORT   LOG
mysql    mysql  failed  not ready  -    54321  logs/mysql.log

mysql: port 54321 is in use by another process.
Run `dev up` to reallocate if the adapter supports it, or stop the conflicting process.
```

## Error Message Guidance

Errors should be direct and actionable.

Use this shape:

```text
<problem>.
<next action>.
```

Examples:

```text
No dev.yml found.
Run this command inside a minidev project.
```

```text
Unknown service: redis
Known services: mysql, worker, server
```

```text
Cannot read instance state: /Users/alice/.local/state/minidev/instances/v1-.../instance.json
Fix permissions or remove the state directory if it is disposable.
```

```text
Cannot safely reset mysql: state is missing data_dir.
No files were removed.
```

Avoid:

- Large stack traces for expected local-state problems.
- Vague messages such as `failed` without a reason.
- Suggesting `dev down` when the user needs data reset.
- Suggesting `dev reset` when stale pid cleanup was already enough.

## Command Naming Collisions And Awkward Areas

Service and command names live in separate config namespaces, but some UX commands accept service names. To avoid overlapping command semantics:

- `dev <name>` should continue to resolve project commands only.
- `dev status`, `dev logs`, and `dev reset` should resolve `<service>` against configured or recorded services only.
- `up.services: [name]` may prefer `services.name` over `commands.name` as defined in `dev_yml_services.md`.
- When both `services.mysql` and `commands.mysql` exist, `dev mysql` means the command and `dev logs mysql` means the service.
- New examples should avoid using the same name for a command and service unless migration requires it.

Awkward but acceptable migration case:

```yml
services:
  mysql:
    type: mysql

commands:
  mysql:
    run: bin/old-mysql-wrapper
```

Expected behavior:

- `dev mysql` runs `bin/old-mysql-wrapper`.
- `dev up` resolves `up.services: [mysql]` to the managed service.
- `dev status mysql` is not specified in this document; use `dev status` for all services.
- `dev logs mysql` and `dev reset mysql` target the managed service.

## Open Questions

- Should `dev reset` without a service be rejected, or should it reset all services with an explicit confirmation or `--all`?
- What exact compatibility behavior should improved `dev ps` use for legacy `<project_root>/.dev/pid.tmp` after global instance state lands?
- Should logs be appended indefinitely, truncated on service start, or rotated by a future retention policy?
- Should `dev env` expose inherited shell environment behind an explicit flag, or remain limited to minidev-controlled env only?
- Should `dev status <service>` be added later, or is the all-service status table enough for now?
- Should service/command name collisions warn every time, warn only in `dev doctor`, or remain silent during migration?
- For typed services that are stopped but have valid persisted allocations, which project commands should receive service env by default and which should require liveness?
- Should `dev logs` print recent content by default, only paths by default, or require a flag for content? This document recommends paths for all services and content for one selected service, but the exact line count is unspecified.
