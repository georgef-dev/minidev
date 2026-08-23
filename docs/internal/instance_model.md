# Minidev Instance Model

## Status

Draft internal spec for the first implementation milestone of the Nix and managed-services architecture.

This document defines instance identity, global runtime state, the project-local pointer, persisted state schema, and resolved environment behavior. It intentionally does not define service adapter internals beyond the state shape needed by later service designs.

## Scope

This model assumes:

- Nix is the only supported dependency source.
- `minidev` owns instance identity, runtime state, process lifecycle, and environment injection.
- `shadowenv` is optional and never required for core behavior.
- Mutable runtime state lives outside the git worktree by default.
- A project-local `.dev` directory may exist only as a pointer or compatibility cache.
- Ports are dynamically allocated, persisted, and reused when still valid.
- Each project, environment, and git worktree combination gets a distinct instance.

## Instance Identity Inputs

An instance identity is derived from local facts, not from mutable process state.

Required inputs:

- `project_root`: canonical absolute path to the directory containing `dev.yml`.
- `worktree_root`: canonical absolute path to the active git worktree root.
- `environment`: logical environment name, defaulting to `development`.
- `schema`: identity schema version, currently `1`.

Resolution rules:

- Paths must be resolved with symlinks removed before hashing.
- `project_root` must be the directory selected by the same project discovery rule used for `dev.yml`.
- `worktree_root` must be the git worktree root for the current checkout.
- For a normal repo, `project_root` and `worktree_root` are often the same path.
- For a monorepo subproject, `project_root` may be below `worktree_root`.
- `environment` is a short logical name used for local instance separation, not a Nix environment selector.
- The initial implementation should only use `development` unless a future config or CLI flag explicitly introduces another environment.

Identity input example:

```json
{
  "schema": 1,
  "project_root": "/Users/alice/src/github.com/example/shop",
  "worktree_root": "/Users/alice/src/github.com/example/shop",
  "environment": "development"
}
```

Monorepo identity input example:

```json
{
  "schema": 1,
  "project_root": "/Users/alice/src/github.com/example/mono/apps/web",
  "worktree_root": "/Users/alice/src/github.com/example/mono",
  "environment": "development"
}
```

## Instance Identity Output

The resolved identity object is the canonical description of the active instance.

Example:

```json
{
  "schema": 1,
  "instance_id": "v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa",
  "label": "shop:development",
  "project_root": "/Users/alice/src/github.com/example/shop",
  "worktree_root": "/Users/alice/src/github.com/example/shop",
  "environment": "development",
  "state_root": "/Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa"
}
```

Fields:

- `schema`: identity schema version.
- `instance_id`: deterministic, filename-safe identifier.
- `label`: human-readable label for status output only.
- `project_root`: canonical project root.
- `worktree_root`: canonical git worktree root.
- `environment`: resolved logical environment.
- `state_root`: absolute path to global mutable state for this instance.

`label` must not be used as an identifier. It can change if display rules change.

## `instance_id` Derivation

`instance_id` is derived from a canonical JSON identity payload.

Canonical payload rules:

- Include only `schema`, `project_root`, `worktree_root`, and `environment`.
- Sort keys lexicographically before serialization.
- Serialize as compact UTF-8 JSON without insignificant whitespace.
- Use canonical absolute paths.

Example canonical payload:

```json
{"environment":"development","project_root":"/Users/alice/src/github.com/example/shop","schema":1,"worktree_root":"/Users/alice/src/github.com/example/shop"}
```

Derivation:

1. Compute `SHA256` of the canonical payload bytes.
2. Encode the digest as lowercase hexadecimal.
3. Prefix with `v1-`.

Shape:

```text
v1-<64 lowercase hex characters>
```

Example:

```text
v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa
```

The version prefix belongs to the identity derivation algorithm, not the state file schema. If derivation changes later, use a new prefix such as `v2-` instead of changing the meaning of existing `v1-` identifiers.

## Global State Directory Layout

The default global state root is:

```text
~/.local/state/minidev
```

Instance state lives under:

```text
~/.local/state/minidev/instances/<instance_id>/
```

Recommended layout:

```text
~/.local/state/minidev/
  instances/
    <instance_id>/
      instance.json
      lock
      logs/
        <service>.log
      pids/
        <service>.pid
      sockets/
        <service>/
      data/
        <service>/
      run/
        <service>/
      tmp/
```

Path responsibilities:

- Ports are persisted in `instance.json` under `allocations.ports`.
- Logs live in `logs/<service>.log` by default.
- Pid files live in `pids/<service>.pid`.
- Unix sockets live under `sockets/<service>/`.
- Service datadirs live under `data/<service>/`.
- Runtime files that are neither sockets nor pids live under `run/<service>/`.
- Temporary files live under `tmp/` and may be deleted during refresh or cleanup.
- `lock` is reserved for serializing state writes and resource allocation.

No heavy mutable runtime state should be written into the git worktree.

## Project-Local `.dev` Pointer

The project-local `.dev` directory is optional. When present, it points to global state and may keep compatibility files during migration.

Pointer path:

```text
<project_root>/.dev/instance.json
```

Pointer example:

```json
{
  "schema": 1,
  "instance_id": "v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa",
  "state_root": "/Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa",
  "project_root": "/Users/alice/src/github.com/example/shop",
  "worktree_root": "/Users/alice/src/github.com/example/shop",
  "environment": "development",
  "written_at": "2026-06-05T18:45:00Z"
}
```

Rules:

- The pointer is a cache, not the source of truth.
- If the pointer is missing, `minidev` must derive identity from current local facts.
- If the pointer disagrees with freshly derived identity, the derived identity wins and the pointer should be rewritten.
- The pointer should not contain ports, process records, env snapshots, logs, sockets, or datadir paths except for `state_root`.
- Current `.dev/pid.tmp` behavior is project-local and should be treated as migration-era compatibility state, not the target model.

## State File Schema

The canonical state file for an instance is:

```text
<state_root>/instance.json
```

Schema versioning rules:

- `schema` is required.
- The initial state schema is `1`.
- Readers must reject state files with a higher major schema they do not understand.
- Additive fields may be introduced under schema `1` when old readers can ignore them safely.
- Destructive or incompatible changes require a new schema and migration plan.

Example `instance.json`:

```json
{
  "schema": 1,
  "identity": {
    "instance_id": "v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa",
    "label": "shop:development",
    "project_root": "/Users/alice/src/github.com/example/shop",
    "worktree_root": "/Users/alice/src/github.com/example/shop",
    "environment": "development"
  },
  "paths": {
    "state_root": "/Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa",
    "logs_dir": "/Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa/logs",
    "pids_dir": "/Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa/pids",
    "sockets_dir": "/Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa/sockets",
    "data_dir": "/Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa/data",
    "run_dir": "/Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa/run",
    "tmp_dir": "/Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa/tmp"
  },
  "allocations": {
    "ports": {
      "mysql": {
        "name": "mysql",
        "port": 54321,
        "protocol": "tcp",
        "host": "127.0.0.1",
        "allocated_at": "2026-06-05T18:45:02Z"
      }
    },
    "sockets": {
      "mysql": "/Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa/sockets/mysql/mysql.sock"
    }
  },
  "services": {
    "mysql": {
      "name": "mysql",
      "type": "mysql",
      "state": "running",
      "pid": 12345,
      "pid_path": "/Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa/pids/mysql.pid",
      "log_path": "/Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa/logs/mysql.log",
      "data_dir": "/Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa/data/mysql",
      "socket_path": "/Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa/sockets/mysql/mysql.sock",
      "ports": {
        "mysql": 54321
      },
      "env": {
        "MYSQL_HOST": "127.0.0.1",
        "MYSQL_PORT": "54321",
        "MYSQL_SOCKET": "/Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa/sockets/mysql/mysql.sock",
        "MYSQL_DATABASE": "shop_development",
        "MYSQL_USERNAME": "shop",
        "DATABASE_URL": "mysql2://shop@127.0.0.1:54321/shop_development"
      },
      "ready": true,
      "started_at": "2026-06-05T18:45:05Z",
      "updated_at": "2026-06-05T18:45:07Z"
    },
    "server": {
      "name": "server",
      "type": "process",
      "state": "running",
      "pid": 12346,
      "command": "bin/rails server",
      "pid_path": "/Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa/pids/server.pid",
      "log_path": "/Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa/logs/server.log",
      "ready": null,
      "started_at": "2026-06-05T18:46:00Z",
      "updated_at": "2026-06-05T18:46:00Z"
    }
  },
  "resolved_env": {
    "MYSQL_HOST": "127.0.0.1",
    "MYSQL_PORT": "54321",
    "MYSQL_SOCKET": "/Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa/sockets/mysql/mysql.sock",
    "MYSQL_DATABASE": "shop_development",
    "MYSQL_USERNAME": "shop",
    "DATABASE_URL": "mysql2://shop@127.0.0.1:54321/shop_development",
    "MINIDEV_INSTANCE_ID": "v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa",
    "MINIDEV_STATE_ROOT": "/Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa"
  },
  "created_at": "2026-06-05T18:45:00Z",
  "updated_at": "2026-06-05T18:46:00Z"
}
```

Persisted state categories:

- Identity and state paths.
- Allocated ports and socket paths.
- Service runtime records: type, state, pid, pid path, log path, data dir, readiness, timestamps.
- Resolved env values derived from static config plus runtime allocations.

Values that should not be persisted:

- Full inherited shell environment.
- Secret values unless a future service design explicitly requires a local generated secret.
- Nix store path discovery caches unless a later Nix contract document requires them.
- `shadowenv` activation state.

## Resolved Env Model

Every project command and service process receives an environment assembled in this order:

1. The current process environment inherited by `minidev`.
2. Top-level `env` from `dev.yml`.
3. Instance metadata exported by `minidev`.
4. Service-provided resolved env derived from instance state.
5. Command-specific env, if a future config schema adds it.

Later layers override earlier layers.

Required instance metadata:

```yaml
MINIDEV_INSTANCE_ID: v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa
MINIDEV_STATE_ROOT: /Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa
MINIDEV_PROJECT_ROOT: /Users/alice/src/github.com/example/shop
MINIDEV_WORKTREE_ROOT: /Users/alice/src/github.com/example/shop
MINIDEV_ENVIRONMENT: development
```

Example resolved command env after MySQL is running:

```yaml
RAILS_ENV: development
MYSQL_HOST: 127.0.0.1
MYSQL_PORT: "54321"
MYSQL_SOCKET: /Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa/sockets/mysql/mysql.sock
MYSQL_DATABASE: shop_development
MYSQL_USERNAME: shop
DATABASE_URL: mysql2://shop@127.0.0.1:54321/shop_development
MINIDEV_INSTANCE_ID: v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa
MINIDEV_STATE_ROOT: /Users/alice/.local/state/minidev/instances/v1-6f5fc1a7db3c8e1f9c3e0d7b8c62a4b901e62d85d5c40cb308ea3c4d1b02f0aa
```

Resolved env rules:

- Service env must be derived from persisted allocations and service config, not freshly guessed each command run.
- All values exported to child processes must be strings.
- `resolved_env` may be recomputed on read, but persisted values must match the active state after refresh.
- Service-specific env keys should only be present when the service is configured for the project.
- A command must not require `shadowenv` to receive instance env.

Commands that should receive resolved env:

- `dev up` setup steps.
- `dev server`.
- `dev console`.
- `dev test`.
- Any project-local command resolved from `dev.yml`.
- Managed services started by `dev up` or future service commands.

## State Lifecycle

### Writes

State is written when:

- An instance is first resolved by a command that needs runtime state.
- `dev up` starts services or runs setup that requires resolved service env.
- A port, socket path, log path, pid path, or datadir path is allocated.
- A process or service starts, stops, becomes ready, fails, or is found stale.
- `dev down` stops services and records cleanup results before removing ephemeral records.
- The project-local pointer is missing or disagrees with derived identity.

Port allocation must be persisted before starting the service that will bind the port. If startup fails before the service binds, the allocation remains in state and can be reused or refreshed on the next start attempt.

### Reads

State is read when:

- A command needs resolved env.
- `dev ps`, `dev status`, `dev logs`, `dev stop`, `dev down`, or `dev reset` inspects services.
- `dev up` determines whether a required service is already running.
- A service adapter needs existing allocations, datadirs, sockets, or readiness markers.

The project-local pointer may speed up discovery, but commands must be able to derive the same instance without it.

### Refresh

Refresh means reconciling persisted state with current machine reality.

Refresh should happen before commands that depend on liveness or resolved env:

- Check recorded pids and remove stale process records.
- Check service readiness where a service adapter defines a healthcheck.
- Keep persisted ports when the owning service is running or when the port is free for reuse.
- Reallocate and persist a new port if the old port is unavailable and not owned by the instance.
- Recompute `resolved_env` after allocations or service state change.
- Remove stale pid files when the process is gone.

Refresh must not delete datadirs by default.

### Cleanup

Cleanup behavior differs by command:

- `dev stop [service]` stops processes and removes runtime liveness records for selected services, but preserves allocations and datadirs.
- `dev down` stops all instance processes and services, removes pid files and ephemeral runtime files, and may remove the project-local pointer. It preserves datadirs and persisted allocations unless a later reset design says otherwise.
- `dev reset [service]` is reserved for future service-specific data cleanup and is not defined here.
- Stale process cleanup removes stale pid files and process records, not logs or datadirs.
- Manual deletion of `<state_root>` is allowed as a last-resort reset for local state.

## Invariants

- One `instance_id` maps to exactly one canonical tuple of `project_root`, `worktree_root`, and `environment` for identity schema `1`.
- `instance_id` must be deterministic and safe as a directory name.
- Ports are never derived from `instance_id`.
- Allocated ports must be persisted before service startup uses them.
- The global state directory is the source of truth for mutable runtime state.
- The project-local `.dev/instance.json` pointer is optional and may be regenerated.
- No service datadir may live directly in the git worktree by default.
- Commands must work without `shadowenv` if the Nix-provided binaries are already available in the command environment.
- Resolved env values passed to child processes must be strings.
- State writes that mutate allocations or service records must be serialized with the instance lock.
- `dev down` must not delete service datadirs unless the user requested a reset behavior defined by a later spec.
- A monorepo subproject and the worktree root are both part of identity, so two subprojects in one worktree do not accidentally share runtime state unless a future design explicitly introduces sharing.

## Compatibility With Current Code

Current code stores tracked processes in:

```text
<project_root>/.dev/pid.tmp
```

Current process logs are written to:

```text
<project_root>/.dev/<name>.log
```

Target behavior moves these into global instance state:

```text
<state_root>/pids/<service>.pid
<state_root>/logs/<service>.log
```

This is a planned architecture change. The current `.dev` files should not be treated as target state schema.

## Open Questions

- How should users select non-`development` environments: CLI flag, `dev.yml`, environment variable, or some combination?
- Should `MINIDEV_STATE_HOME` or another env var override `~/.local/state/minidev` for tests and advanced local setups?
- What exact migration behavior should exist for existing `.dev/pid.tmp` records after global state lands?
- Should `dev down` remove `.dev/instance.json` by default, or leave it as a harmless pointer for faster subsequent discovery?
- How should generated local secrets be represented if a future managed service needs them?
- Should logs be retained indefinitely, truncated on service start, or rotated?
