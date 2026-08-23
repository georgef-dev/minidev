# Minidev Service Runtime

## Status

Draft internal design for adding a small service runtime on top of the existing command and process tracking code.

This document defines runtime concepts and Ruby object boundaries. It does not define production code and does not introduce a plugin framework.

## Scope

The runtime supports two initial service categories:

- Generic `process` services for long-running project commands or raw shell commands.
- Builtin typed services, initially `mysql`, for services that need managed state, resource allocation, readiness, and service-specific environment.

Fixed constraints:

- Nix is the only supported dependency source.
- `minidev` remains independent from `shadowenv`.
- One MySQL server is managed per worktree instance.
- Ports are dynamically reserved and persisted.
- MySQL is not represented as only a raw shell command.
- The design stays internal and small; no external service plugin API exists yet.

## Existing Runtime Today

Current code has three relevant pieces:

- `Dev::Project` discovers `dev.yml`, exposes top-level `env`, and resolves project command names to shell strings.
- `Dev::Commands::Up` normalizes `up`, runs setup steps with `system`, and starts `up.services` or `up.serve` entries through `ProcessManager`.
- `Dev::ProcessManager` starts background shell commands, writes logs under `<project_root>/.dev`, tracks YAML records in `<project_root>/.dev/pid.tmp`, checks pids, and stops process groups.

The service runtime should evolve this instead of replacing it immediately. The current `ProcessManager` behavior is already the right low-level primitive for generic process start/stop, but its storage and environment source need to move behind instance-aware services.

## Concepts And Boundaries

### Instance

An instance is the resolved project, environment, and worktree identity from `docs/internal/instance_model.md`.

Runtime services are always scoped to one instance. Service state, logs, pid files, sockets, data directories, and resolved env are read from or written to that instance state root.

### Service Definition

A service definition is the static config resolved from `dev.yml` plus defaults.

Common fields:

- `name`: project-local service name, such as `mysql` or `server`.
- `type`: `process`, `mysql`, or another future builtin type.
- `source`: where the definition came from, such as `up.services`, `up.serve`, top-level `services`, or a command reference.
- `config`: type-specific static config.

### Service Runtime Record

A service runtime record is persisted mutable state for one service inside `<state_root>/instance.json`.

Common fields:

- `name`
- `type`
- `state`
- `pid`
- `pid_path`
- `log_path`
- `ready`
- `started_at`
- `updated_at`
- `env`

Typed services can add fields such as `data_dir`, `socket_path`, and `ports`.

### Generic `process` Services

Generic process behavior ends at command execution and process lifecycle tracking.

A `process` service can:

- Resolve a shell command and arguments from `dev.yml` command config or a raw `run` step.
- Start the command in the project directory with resolved project env.
- Redirect stdout and stderr to the service log.
- Persist pid, command, log path, and timestamps.
- Stop the process group with the existing TERM-then-KILL strategy.
- Refresh liveness by checking the recorded pid.

A `process` service does not:

- Allocate ports.
- Create datadirs or sockets.
- Initialize service-specific state.
- Export service-specific env beyond any static command env that exists later.
- Define health beyond pid liveness unless a future explicit healthcheck field is added.

### Typed Services

Typed service behavior begins when `minidev` must understand the service semantics to prepare, start, inspect, expose env, stop, or reset it safely.

A typed service can:

- Allocate and persist resources before start.
- Prepare durable state directories.
- Start a managed daemon using Nix-provided binaries.
- Run service-specific readiness checks.
- Export resolved env derived from persisted allocations and config.
- Stop gracefully using service-specific behavior.
- Reset data through a type-specific reset strategy.

Typed services are builtin Ruby classes selected by `type`. This selection is internal dispatch, not a plugin framework.

### MySQL Boundary

MySQL-specific logic should live in a builtin MySQL service class under the service runtime namespace.

The MySQL class owns:

- Discovering required MySQL binaries from the current Nix-provided environment.
- Creating or reusing the instance-specific datadir.
- Allocating and reusing a persisted TCP port.
- Allocating and reusing a persisted socket path.
- Writing any minimal runtime config needed by `mysqld`.
- Starting `mysqld` with the resolved datadir, port, socket, and log paths.
- Waiting for MySQL readiness using MySQL-aware checks.
- Creating configured development and test databases if required by later MySQL design.
- Producing `MYSQL_*` and `DATABASE_URL` env values.
- Graceful shutdown and reset behavior.

Details of exact MySQL config fields, database creation, readiness checks, and failure recovery should be finalized in the MySQL adapter design document.

## Proposed Ruby Layout

Small internal layout:

```text
lib/dev/instance.rb
lib/dev/instance_state.rb
lib/dev/service_runtime.rb
lib/dev/services/base.rb
lib/dev/services/process.rb
lib/dev/services/mysql.rb
lib/dev/services/registry.rb
lib/dev/services/resolver.rb
lib/dev/services/env_builder.rb
```

Responsibilities:

- `Dev::Instance`: resolves project root, worktree root, environment, `instance_id`, and state paths.
- `Dev::InstanceState`: loads, locks, mutates, and writes `<state_root>/instance.json`; owns schema checks and atomic persistence.
- `Dev::ServiceRuntime`: high-level coordinator used by commands such as `up`, `server`, `stop`, `down`, and future `reset`.
- `Dev::Services::Base`: small abstract interface for lifecycle methods; shared helper methods only when genuinely common.
- `Dev::Services::Process`: adapter for generic long-running shell commands; delegates low-level spawn/stop mechanics to evolved process tracking.
- `Dev::Services::MySQL`: builtin typed adapter for MySQL lifecycle and env.
- `Dev::Services::Registry`: maps resolved service definitions to builtin service classes by `type`.
- `Dev::Services::Resolver`: turns `dev.yml` service references and current command-oriented `up` steps into service definitions.
- `Dev::Services::EnvBuilder`: builds command env from inherited env, `dev.yml` env, instance metadata, and service-provided env.

Existing classes should be adjusted rather than bypassed:

- `Dev::Project` remains responsible for finding `dev.yml` and resolving project commands.
- `Dev::Commands::Up` should become orchestration code that asks `ServiceRuntime` to start services and build env for setup steps.
- `Dev::ProcessManager` should become or back the low-level process tracker for `process` services.

## Service Interface

Each service class should expose the same small internal lifecycle surface:

```text
resolve
prepare
start
healthcheck
stop
reset
env
refresh
```

Method meanings:

- `resolve`: merge static config, instance paths, persisted allocations, and defaults into an executable runtime plan.
- `prepare`: create directories, allocate resources, initialize durable state, and persist any required pre-start state.
- `start`: launch the service if not already running and persist process state.
- `healthcheck`: determine readiness using the best available service-specific check.
- `stop`: terminate the service and update liveness state while preserving durable allocations and datadirs.
- `reset`: perform destructive service-specific cleanup requested by the user; never implicit during ordinary `down`.
- `env`: return string key/value pairs exposed by this service.
- `refresh`: reconcile persisted runtime state with current machine reality.

`Base` should not force every service to implement complex behavior. For `process`, `prepare`, `healthcheck`, `reset`, and `env` are intentionally minimal.

## Lifecycle

### `dev up` Lifecycle

```text
Project.current
  -> Instance.resolve
  -> InstanceState.load_or_create
  -> ServiceResolver.resolve up.services
  -> ServiceRuntime.resolve services
  -> ServiceRuntime.refresh services
  -> ServiceRuntime.prepare services
  -> ServiceRuntime.start services
  -> ServiceRuntime.healthcheck services
  -> EnvBuilder.command_env
  -> run dependencies/build/steps with resolved env
  -> ServiceResolver.resolve up.serve
  -> ServiceRuntime.prepare serve services
  -> ServiceRuntime.start serve services
```

Step list:

1. Discover the project with existing `Dev::Project.current`.
2. Resolve the instance identity and ensure the global state root exists.
3. Load current state under the instance lock for mutations.
4. Resolve named services from top-level `services` when available.
5. Treat current command-oriented `up.services` and `up.serve` entries as `process` services unless they reference a typed service definition.
6. Refresh existing service records and remove stale pid records.
7. Prepare services, including persisted resource allocation for typed services.
8. Start services that are not running.
9. Run healthchecks for services that define readiness.
10. Recompute and persist resolved env.
11. Run setup steps with resolved env.
12. Start post-setup serve processes with the same resolved env.

### Generic Process Start

```text
resolve command/run step
  -> compute log_path and pid_path
  -> build command env
  -> spawn shell in project dir
  -> detach pid
  -> persist service record
```

For `process`, readiness is `null` unless later config explicitly adds a healthcheck. Liveness is based on pid existence.

### Typed MySQL Start

```text
resolve mysql config
  -> read persisted port/socket/datadir paths
  -> allocate missing resources and persist them
  -> initialize datadir if needed
  -> start mysqld
  -> persist pid and state=starting
  -> wait for MySQL readiness
  -> create/update service env
  -> persist state=running and ready=true
```

This flow is intentionally MySQL-aware. It must not be represented as a generic `run: mysqld ...` command in project config.

### Stop Lifecycle

```text
resolve instance
  -> load state
  -> select services
  -> refresh liveness
  -> stop selected services
  -> remove pid/runtime liveness fields
  -> persist state
```

Rules:

- `process` services use the current process-group stop strategy.
- MySQL should use a MySQL-aware graceful shutdown path, then fall back only if necessary.
- Stop preserves datadirs, allocated ports, sockets, and logs unless later UX design says otherwise.

### Reset Lifecycle

```text
resolve instance
  -> load state
  -> select service
  -> stop service if running
  -> run service-specific reset
  -> remove or rewrite service state
  -> recompute resolved env
```

Rules:

- `reset` is explicitly destructive and should require a user command.
- `process` reset has no data cleanup beyond stopping and clearing runtime records.
- MySQL reset may remove the datadir and database-specific state, but exact behavior belongs in the MySQL adapter spec.

## State Persistence

The canonical state file remains `<state_root>/instance.json` from the instance model.

Service runtime writes:

- Resolved service records under `services.<name>`.
- Allocations under `allocations`, such as MySQL ports and socket paths.
- Service logs and pid paths in each service record.
- `resolved_env` after service env changes.
- Timestamps for start, readiness, stop, stale cleanup, and reset.

Persistence rules:

- Mutations happen under the instance lock.
- Allocations are persisted before a service uses them.
- State writes should be atomic from the perspective of later commands.
- Refresh can mark records stale or stopped, but must not delete datadirs.
- `dev down` should stop services and clean ephemeral runtime records, not reset durable data.

## Environment Exposure

Project commands receive env through `Dev::Services::EnvBuilder`.

Build order:

1. Current process environment inherited by `minidev`.
2. Top-level `env` from `dev.yml` through `Dev::Project`.
3. Instance metadata such as `MINIDEV_INSTANCE_ID` and `MINIDEV_STATE_ROOT`.
4. Service env returned by resolved services and persisted in instance state.
5. Future command-specific env, if that config is later added.

Commands that should use this env:

- Setup steps run by `dev up`.
- `dev server` and command-oriented serve processes.
- `dev console`.
- `dev test`.
- Any project-local command resolved from `dev.yml`.
- Managed services that need instance metadata or service-to-service env.

Env rules:

- Values passed to child processes are strings.
- Service env is derived from persisted allocations and static service config.
- Commands should not require `shadowenv` to receive instance env.
- If a configured typed service is stopped, its last resolved env can still be available if it points to persisted resources, but commands that require liveness should trigger refresh or healthcheck first.

## Evolving Current Process Tracking

The current `ProcessManager` can evolve in phases:

1. Keep its spawn, detach, pid liveness check, process-group stop, and shell wrapping behavior.
2. Change storage from `<project_root>/.dev/pid.tmp` to instance state records and `<state_root>/pids`/`<state_root>/logs`.
3. Let `ProcessManager` accept an explicit env, cwd, log path, pid path, and state writer instead of reading only from `Project`.
4. Use `Dev::Services::Process` as the service adapter that calls the evolved process manager.
5. Keep `.dev/pid.tmp` as migration-era compatibility only if a later implementation plan requires it.

This avoids a risky rewrite of low-level process behavior while making process tracking instance-aware.

## Integration Points

### `Dev::Commands::Up`

`Up` should continue to own `up` execution order, but delegate service lifecycle and env building:

- Normalize existing `up` shapes.
- Print manual instructions.
- Ask `ServiceResolver` to convert `up.services` and `up.serve` to service definitions.
- Ask `ServiceRuntime` to prepare/start/healthcheck service definitions.
- Run setup steps with `EnvBuilder.command_env` instead of `Project#env` alone.

### `Dev::Project`

`Project` should remain small:

- Locate the project root.
- Load `dev.yml`.
- Return top-level static env.
- Resolve command names.

It should not own service state, port allocation, or readiness.

### Stop, Down, Ps, And Future Commands

Existing process-facing commands should move toward `ServiceRuntime`:

- `ps` can display service records and use adapter refresh for liveness.
- `stop` can stop selected services by name.
- `down` can stop all services for the instance and clean ephemeral runtime state.
- Future `status`, `logs`, `reset`, and `env` commands can read the same state model.

## Ambiguities And Open Questions

- How should `up.services: [mysql]` be resolved during migration if both `commands.mysql` and top-level `services.mysql` exist?
- Should command-oriented `up.services` entries keep their current generated names like `service-1`, or should the resolver require stable labels for unnamed process services before they enter instance state?
- Should `dev server` become a `process` service named `server` immediately, or should only `dev up` use the service runtime in the first implementation milestone?
- If a typed service is configured but stopped, should ordinary commands receive its persisted env or fail until the service is started?
- What exact compatibility behavior should read or ignore existing `<project_root>/.dev/pid.tmp` records after instance state lands?
- Should process logs be appended forever, truncated on every start, or managed by a later log-retention policy?
- Should the service runtime expose service env only for services listed in `up.services`, or for every top-level configured service?

## Risky Refactors

- Moving process state from project-local YAML to global instance JSON touches `ps`, `stop`, `down`, `server`, and `up` behavior at once.
- Changing env construction from `Project#env` to `EnvBuilder` affects every command execution path and can cause subtle precedence regressions.
- Making `dev up` service-aware while preserving command-oriented configs requires careful resolution rules for names that exist in both `commands` and `services`.
- MySQL startup mixes process management, port allocation, persistent datadirs, readiness checks, and env injection; it should land after instance state and generic process services are stable.
