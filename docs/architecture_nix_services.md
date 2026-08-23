# Minidev Nix And Service Architecture

## Status

Draft design document for evolving `minidev` toward a Shopify-like local development model.

## Goals

- Use Nix as the only supported dependency management system.
- Keep `minidev` independent from `shadowenv` while remaining compatible with it.
- Make `minidev` the orchestrator for project commands, long-running services, and instance state.
- Give each app, environment, and git worktree combination its own isolated runtime state.
- Support one MySQL server per worktree.
- Keep the design reusable across projects, not tailored to `relay`.

## Non-Goals

- Supporting non-Nix dependency management systems.
- Making `shadowenv` required.
- Turning `minidev` into a general package manager.
- Building a broad plugin system before the first managed services work well.
- Sharing a single MySQL server across worktrees in the initial design.

## Core Model

Responsibilities are split cleanly:

- Nix provides toolchains and executable dependencies.
- `shadowenv` may activate the environment automatically, but is optional.
- `minidev` owns project orchestration, service lifecycle, instance identity, and runtime state.

This means `minidev` should know:

- which project is active
- which git worktree is active
- which services the project requires
- where instance state lives
- how to start, stop, inspect, and reset services
- how to inject resolved runtime environment into project commands

## Developer Workflow

Expected workflow inside a repo worktree:

1. `cd` into the worktree.
2. Nix tools become available, typically via `shadowenv`, but `minidev` does not require it.
3. Run `dev up`.
4. Run `dev ps` or `dev status` to inspect services.
5. Run `dev down` to stop the worktree instance.

Expected results:

- the correct project toolchain is available
- a worktree-specific MySQL server is started when required
- the app receives worktree-specific connection env vars
- logs, pids, ports, sockets, and data directories are isolated per instance

## Instance Identity

`minidev` needs a first-class instance identity to support per-worktree isolation.

An instance is defined by:

- project
- environment
- git worktree

The resolved instance should have:

- `instance_id`
- human-readable label
- state root path
- allocated resource set

Identity should be derived from stable local facts such as:

- canonical project root
- canonical git worktree path
- environment name

The derived `instance_id` should be deterministic and safe for file names, but ports should not be deterministic. Ports should be dynamically reserved and then persisted in instance state.

## State Model

Mutable runtime state should live outside the repo by default.

Recommended layout:

- `~/.local/state/minidev/instances/<instance_id>/`

Optional project-local compatibility pointer:

- `<project_root>/.dev/instance.json`

Instance state should contain:

- process registry
- service definitions resolved for this instance
- allocated ports
- socket paths
- log paths
- data directory paths
- env snapshot or derived env values
- readiness markers
- schema version

The local `.dev` directory can remain as a pointer or cache, but heavy mutable state should stay outside the worktree.

## Service Model

`minidev` should grow from tracked commands into a small service-aware orchestrator.

Services should be explicit entities with fields such as:

- `name`
- `type`
- `command` or builtin adapter
- `env`
- `data_dir`
- `log_path`
- `pid`
- `ports`
- `healthcheck`
- `stop_strategy`
- `reset_strategy`

Initial service types:

- `process`
- `mysql`

`mysql` should be a builtin adapter rather than a plain shell command because it needs initialization, health checks, data directories, sockets, and graceful shutdown behavior.

## MySQL Model

The initial service strategy is one MySQL server per worktree instance.

This gives:

- strong isolation between worktrees
- straightforward cleanup
- fewer hidden interactions between app instances

The MySQL adapter should handle:

- locating `mysqld` and related binaries from Nix
- creating or reusing a worktree-specific datadir
- dynamically reserving a free port and persisting it
- allocating a socket path and persisting it
- writing minimal server config if needed
- starting the server
- waiting for readiness
- creating configured databases if needed
- exporting resolved connection env vars
- graceful shutdown
- reset and cleanup flows

## Configuration Model

`dev.yml` should stay small and additive.

Projects should define commands separately from services.

Target direction:

```yml
env:
  RAILS_ENV: development

services:
  mysql:
    type: mysql
    database: relay_development
    test_database: relay_test
    username: relay
    password_env: MYSQL_PASSWORD

up:
  services:
    - mysql
  dependencies:
    - bundle install
  build:
    - build
  serve:
    - server

build: bin/setup
server: bin/rails server
test: bin/test
```

Design rules:

- keep top-level `services:` separate from `commands:`
- let `up.services` reference named services
- preserve the existing command-oriented workflow for project commands
- preserve the current `up` execution order

## Environment Injection

`minidev` should inject resolved instance-specific environment into project commands.

Examples:

- `MYSQL_HOST`
- `MYSQL_PORT`
- `MYSQL_SOCKET`
- `MYSQL_DATABASE`
- `MYSQL_USERNAME`
- `MYSQL_PASSWORD`
- `DATABASE_URL`

This environment should be derived from instance state, not only from static config.

That same injected environment should be available to:

- `dev server`
- `dev console`
- `dev test`
- setup steps run by `dev up`
- future commands such as `dev env`

## Nix And Shadowenv

Nix is the only supported dependency source.

`minidev` should assume the project environment exposes the required binaries, while also providing commands such as `dev doctor` to verify that contract.

`shadowenv` is optional and complementary:

- it can activate the Nix-backed environment automatically
- it can export helpful instance-related variables
- it should not be responsible for starting or stopping services

Because `minidev` must remain independent, all core workflows should work without `shadowenv`.

## Resource Allocation

Ports should be dynamically reserved and then persisted in instance state.

This supports:

- better flexibility when ports are already taken
- stability across restarts once a port has been assigned
- isolation between multiple worktrees and projects

Resource allocation should cover:

- TCP ports
- Unix sockets
- data directories
- log paths
- pid and registry files

## Commands To Add

Likely future commands:

- `dev env`
- `dev status`
- `dev logs [service]`
- `dev reset [service]`
- `dev doctor`
- `dev services`

These should come after the core identity, state, and service model exists.

## Phased Rollout

### Phase 1: Foundations

- define instance identity rules
- define global state layout and local pointer format
- define resolved env model
- add internal service abstraction
- preserve existing tracked process behavior

### Phase 2: Nix Environment Contract

- document the Nix contract for projects
- define optional `shadowenv` integration points
- add environment verification such as `dev doctor`

### Phase 3: MySQL Adapter

- add builtin `mysql` service support
- implement datadir init, start, stop, health, and reset
- implement dynamic port reservation with persistence
- inject MySQL env into project commands

### Phase 4: Config Evolution

- add top-level `services:` support to `dev.yml`
- keep migration path from command-only service setup
- update examples and init flow

### Phase 5: UX And Introspection

- add `dev status`
- add `dev logs`
- add `dev reset`
- improve stale-state cleanup and error reporting

### Phase 6: Additional Services

- add more builtin managed services such as Redis or Postgres
- improve monorepo and multi-service ergonomics as needed

## Decisions Made

- global state with optional project-local pointer
- dynamically reserved and persisted ports
- one MySQL server per worktree
- `minidev` remains independent from `shadowenv`
- Nix-only dependency management
