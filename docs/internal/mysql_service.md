# Minidev MySQL Service

## Status

Draft internal design for the builtin MySQL service adapter.

This document defines behavior only. It does not add production code.

## Scope

This design assumes:

- MySQL is managed by `minidev` as a builtin typed service, not as a raw shell command.
- MySQL binaries are supplied by the active Nix-backed environment and discovered through `PATH`.
- One MySQL server is managed per resolved instance.
- A resolved instance is one project, one logical environment, and one git worktree.
- Ports are dynamically reserved and persisted in instance state.
- Mutable MySQL state lives under the global instance state root, not in the git worktree.
- `shadowenv` may prepare the shell environment, but it does not start, stop, configure, or track MySQL.

Out of scope:

- Docker-based MySQL.
- A shared MySQL server across multiple worktrees.
- A broad external service plugin system.
- Non-Nix dependency management.
- Production database management.

## Service Config

Top-level `dev.yml` service shape:

```yaml
services:
  mysql:
    type: mysql
    database: shop_development
    test_database: shop_test
    username: shop
    password_env: MYSQL_PASSWORD
    env:
      MYSQLD_EXTRA_OPTION: value
```

Supported fields:

- `type`: required. Must be `mysql`.
- `database`: optional app database name. If present, the adapter creates it after startup if missing.
- `test_database`: optional test database name. If present, the adapter creates it after startup if missing.
- `username`: optional local MySQL user name used for application connections and database creation grants.
- `password_env`: optional environment variable name. If present, the adapter reads the password value from the environment inherited by `minidev`.
- `env`: optional static environment values for the MySQL daemon process only. These values do not become app connection env unless the adapter explicitly exposes matching resolved env.

Fields intentionally not supported in the initial service config:

- `port`: ports are dynamically reserved and persisted.
- `host`: the adapter binds to `127.0.0.1` for TCP connections.
- `data_dir`, `socket_path`, `pid_path`, `log_path`, or `config_path`: paths are derived from instance state.
- Lifecycle hooks such as `before_start` or `after_start`.
- Docker image, container, or compose fields.

Default values are intentionally limited. If `database`, `test_database`, or `username` are omitted, behavior remains an open question until defaults are finalized by implementation policy.

## Instance Ownership

The MySQL service belongs to exactly one resolved instance.

Instance identity comes from `docs/internal/instance_model.md`:

- `project_root`
- `worktree_root`
- `environment`
- identity schema version

The service name is project-local, usually `mysql`. The adapter does not search for or attach to a MySQL server from another worktree, even if the same project name or database name is used elsewhere.

All MySQL state is rooted under:

```text
<state_root>/
```

where `state_root` is the global instance state root:

```text
~/.local/state/minidev/instances/<instance_id>/
```

## Path Layout

For a service named `mysql`, the adapter uses these paths:

```text
<state_root>/data/mysql/                 # MySQL datadir
<state_root>/logs/mysql.log              # combined daemon log
<state_root>/pids/mysql.pid              # minidev pid file
<state_root>/sockets/mysql/mysql.sock     # Unix socket
<state_root>/run/mysql/my.cnf             # generated server config
<state_root>/run/mysql/mysqladmin.sock    # optional admin socket if implementation needs one
<state_root>/tmp/mysql/                   # temporary initialization files
```

The exact optional admin-socket usage is not required by this design. The application socket path is exactly:

```text
<state_root>/sockets/mysql/mysql.sock
```

The generated config path is exactly:

```text
<state_root>/run/mysql/my.cnf
```

The pid file path is exactly:

```text
<state_root>/pids/mysql.pid
```

The log path is exactly:

```text
<state_root>/logs/mysql.log
```

The datadir path is exactly:

```text
<state_root>/data/mysql
```

## Persisted State

The adapter persists MySQL state in `<state_root>/instance.json` under the instance lock.

Persisted allocation fields:

```json
{
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
      "mysql": "/Users/alice/.local/state/minidev/instances/<instance_id>/sockets/mysql/mysql.sock"
    }
  }
}
```

Persisted service record fields:

```json
{
  "services": {
    "mysql": {
      "name": "mysql",
      "type": "mysql",
      "state": "running",
      "pid": 12345,
      "pid_path": "/Users/alice/.local/state/minidev/instances/<instance_id>/pids/mysql.pid",
      "log_path": "/Users/alice/.local/state/minidev/instances/<instance_id>/logs/mysql.log",
      "data_dir": "/Users/alice/.local/state/minidev/instances/<instance_id>/data/mysql",
      "socket_path": "/Users/alice/.local/state/minidev/instances/<instance_id>/sockets/mysql/mysql.sock",
      "config_path": "/Users/alice/.local/state/minidev/instances/<instance_id>/run/mysql/my.cnf",
      "ports": {
        "mysql": 54321
      },
      "datadir_initialized": true,
      "ready": true,
      "env": {
        "MYSQL_HOST": "127.0.0.1",
        "MYSQL_PORT": "54321",
        "MYSQL_SOCKET": "/Users/alice/.local/state/minidev/instances/<instance_id>/sockets/mysql/mysql.sock",
        "MYSQL_DATABASE": "shop_development",
        "MYSQL_TEST_DATABASE": "shop_test",
        "MYSQL_USERNAME": "shop",
        "DATABASE_URL": "mysql2://shop@127.0.0.1:54321/shop_development",
        "TEST_DATABASE_URL": "mysql2://shop@127.0.0.1:54321/shop_test"
      },
      "started_at": "2026-06-05T18:45:05Z",
      "updated_at": "2026-06-05T18:45:07Z"
    }
  }
}
```

Persisted values:

- Allocated TCP port.
- TCP bind host, currently `127.0.0.1`.
- Socket path.
- Datadir path.
- Config path.
- Pid path.
- Log path.
- Current pid while running.
- Service lifecycle state.
- Datadir initialization marker.
- Readiness marker and timestamps.
- Resolved service env derived from config plus persisted allocations.

Recomputed values:

- Binary paths discovered from `PATH`.
- Whether the recorded pid is currently alive.
- Whether MySQL is currently accepting connections.
- Generated config contents.
- Effective command argv for `mysqld`.
- `DATABASE_URL` and `TEST_DATABASE_URL`, as long as recomputed values exactly match the persisted allocation and service config.

Values not persisted:

- Full inherited process environment.
- Nix store discovery caches.
- `shadowenv` activation state.
- Plaintext password values read through `password_env`, unless a future local-secret design explicitly changes this.

## Binary Contract

The adapter discovers required binaries through `PATH` in the environment inherited by `minidev`.

Required binary list is not fully resolved by existing docs. The implementation needs at least:

- `mysqld`, to initialize and start the server.
- a client or admin binary for readiness and SQL execution.

The exact binary list remains an open question because MySQL and MariaDB packages expose slightly different initialization and admin tools. The design should support a small explicit list once chosen by implementation, and `dev doctor` should verify that list for configured MySQL services.

## Generated Server Config

The adapter writes a minimal config file at:

```text
<state_root>/run/mysql/my.cnf
```

The config should include only values owned by `minidev`:

- datadir
- socket
- port
- bind address `127.0.0.1`
- pid file path
- log file path if supported by the selected server package
- any adapter-required local-only startup settings

The config is recomputed on prepare/start from persisted allocations and paths. If the existing config file differs, it can be overwritten because it is generated runtime state.

The config must not include secrets. If a password is used for the application user, it is passed only to client commands that need it or encoded in app env values. Persisting the plaintext password remains out of scope.

## Port Reservation

Port behavior follows the instance model:

1. Under the instance lock, read `allocations.ports.mysql`.
2. If no port is persisted, reserve a currently free TCP port on `127.0.0.1` and persist it before starting MySQL.
3. If a port is persisted and MySQL for this instance is already running on it, keep it.
4. If a port is persisted and free, reuse it.
5. If a port is persisted but occupied by a process that is not the recorded MySQL process for this instance, allocate a new free port and persist the replacement before starting.

The adapter must not derive the port from `instance_id`, database name, service name, or project path.

Port persistence survives `dev stop`, `dev down`, and ordinary stale-process cleanup. It is removed or replaced only by an explicit reset flow or by recovery from a conflict with a non-instance process.

## Datadir Initialization

Datadir path:

```text
<state_root>/data/mysql
```

Initialization flow:

1. Create parent directories for data, logs, pids, sockets, run, and tmp.
2. Check whether the datadir exists and appears initialized.
3. If initialized, skip initialization.
4. If missing or empty, create it and run the selected MySQL initialization command using Nix-provided binaries.
5. Write or update the generated server config.
6. Persist `datadir_initialized: true` only after initialization completes successfully.

The exact initialization command remains tied to the exact binary list. The adapter must select one supported initialization path during implementation and document it in `dev doctor` checks. Examples in upstream MySQL/MariaDB ecosystems include `mysqld --initialize-insecure` or package-specific install-db helpers, but this design does not choose between them.

Initialization must not create state in the project worktree. Temporary files may be written under `<state_root>/tmp/mysql/` and deleted after successful initialization.

## Normal Startup Sequence

`dev up` starts MySQL through the service runtime before dependency, build, and setup steps that need database env.

Sequence:

1. `Dev::Project.current` discovers `dev.yml`.
2. Instance identity is resolved from project root, worktree root, and logical environment.
3. `<state_root>/instance.json` is loaded or created under the instance lock.
4. `up.services` resolves `mysql` to top-level `services.mysql` when present.
5. The MySQL adapter resolves static config and persisted allocations.
6. Existing MySQL service state is refreshed.
7. If an already-running recorded MySQL process is healthy, no new daemon is started.
8. Missing directories are created.
9. Missing or conflicted port allocation is resolved and persisted.
10. Socket, pid, log, config, and datadir paths are resolved and persisted.
11. Datadir is initialized if needed.
12. Generated config is written.
13. `mysqld` is spawned in the project directory or state root, with stdout/stderr directed to `<state_root>/logs/mysql.log`.
14. The daemon pid is detached and persisted with `state: starting`.
15. Readiness checks run until success or timeout.
16. App and test databases are created if configured.
17. The configured app user is created or updated if `username` is configured and the selected MySQL initialization flow permits local admin access.
18. Resolved MySQL env is computed from persisted allocations and config.
19. The service record is persisted with `state: running` and `ready: true`.
20. `resolved_env` is recomputed for project commands.
21. `dev up` setup steps run with the resolved env.

Startup should be idempotent. Running `dev up` twice should reuse the same datadir, port, socket path, and app env when the service is healthy.

## Readiness Checks

Readiness means the MySQL server is alive and accepts a local connection for SQL execution.

The adapter should check readiness with a MySQL-aware command, not only pid liveness.

Readiness sequence:

1. Confirm recorded pid is alive.
2. Confirm the socket exists, or TCP port is reachable on `127.0.0.1`.
3. Execute a simple query such as `SELECT 1` through the selected client/admin binary.
4. Mark `ready: true` only after the query succeeds.

If readiness fails before timeout:

- Keep the service record as `state: starting` while retrying.
- Append daemon output to the MySQL log.
- After timeout, mark `state: failed`, `ready: false`, preserve logs and datadir, and return an actionable error.

The exact timeout and retry interval are open questions. They should be short enough for failed local startup to be obvious and long enough for first datadir startup on slower machines.

## Database Creation Flow

Database creation runs after MySQL readiness and before setup steps.

Flow:

1. Connect through the local socket or `127.0.0.1:<port>` using the local admin access established by initialization.
2. If `username` is configured, ensure the user exists for local connections.
3. If `password_env` is configured and set, use its value as the configured user's password.
4. If `database` is configured, create it if it does not already exist.
5. If `test_database` is configured, create it if it does not already exist.
6. Grant the configured user privileges on the configured app and test databases if a distinct user is configured.
7. Leave existing databases and tables intact.

Database creation must be idempotent and safe to run on every `dev up`.

If `database` is omitted, the adapter does not create an app database. If `test_database` is omitted, the adapter does not create a test database.

If `username` is omitted, user creation and grant behavior is an open question. The adapter may need to use a default local user, but that default is not specified by existing docs.

If `password_env` is configured but the named environment variable is unset, behavior is an open question. The adapter must not guess a password or persist an empty secret without an explicit decision.

## Env Exposed To Applications

The MySQL adapter exposes service env to project commands through the resolved env model. All values are strings.

When `services.mysql` is configured, the adapter exposes these exact keys after allocations have been resolved:

```yaml
MYSQL_HOST: "127.0.0.1"
MYSQL_PORT: "54321"
MYSQL_SOCKET: "/Users/alice/.local/state/minidev/instances/<instance_id>/sockets/mysql/mysql.sock"
```

If `database` is configured, expose:

```yaml
MYSQL_DATABASE: "shop_development"
DATABASE_URL: "mysql2://shop@127.0.0.1:54321/shop_development"
```

If `test_database` is configured, expose:

```yaml
MYSQL_TEST_DATABASE: "shop_test"
TEST_DATABASE_URL: "mysql2://shop@127.0.0.1:54321/shop_test"
```

If `username` is configured, expose:

```yaml
MYSQL_USERNAME: "shop"
```

If `password_env` is configured and the named environment variable is set, expose:

```yaml
MYSQL_PASSWORD: "<value from password_env>"
```

The value of `MYSQL_PASSWORD` is read from the environment variable named by `password_env`; the exposed key is always `MYSQL_PASSWORD`.

URL construction rules:

- Scheme is `mysql2`.
- Host is `127.0.0.1`.
- Port is the persisted MySQL port.
- Path is the configured database name.
- Username is included only when `username` is configured.
- Password inclusion is an open question because it interacts with secret persistence and URL escaping. Until resolved, `DATABASE_URL` and `TEST_DATABASE_URL` should not include a password.

Example without password:

```text
mysql2://shop@127.0.0.1:54321/shop_development
```

The service env is derived from persisted allocations and static service config. It is available to:

- `dev up` setup steps after dependency services start.
- `dev server`.
- `dev console`.
- `dev test`.
- Project commands resolved from `dev.yml`.
- Managed processes started through `up.serve`.

If the configured MySQL service is stopped, exposing persisted env to ordinary commands remains an unresolved runtime policy from `service_runtime.md`. This MySQL design requires commands that need a live database to refresh or start the service first, but does not decide whether all commands should fail when MySQL is stopped.

## Shutdown Behavior

`dev stop mysql` and `dev down` should stop the MySQL daemon gracefully.

Shutdown sequence:

1. Resolve the instance and load state.
2. Refresh the MySQL pid record.
3. If no running pid exists, mark the service stopped or stale and remove the pid file.
4. If running, request graceful MySQL shutdown through the selected MySQL admin/client binary when available.
5. Wait for the pid to exit.
6. If graceful shutdown fails within the timeout, send `TERM` to the process group.
7. If the process still remains after the normal process-manager grace period, send `KILL` to the process group.
8. Remove `<state_root>/pids/mysql.pid` and ephemeral runtime liveness fields.
9. Persist `state: stopped`, `ready: false`, and updated timestamps.

Shutdown preserves:

- Datadir.
- Allocated port.
- Socket allocation path.
- Generated config path.
- Logs.
- Database contents.
- Resolved connection env values derived from persisted allocations, subject to the stopped-service env policy open question.

`dev down` must not delete MySQL databases or the datadir.

## Reset Behavior

MySQL reset is explicitly destructive and should only run through a future explicit reset command such as `dev reset mysql`.

Reset sequence:

1. Resolve the instance and load state under the instance lock.
2. Stop MySQL if it is running.
3. Remove the MySQL datadir at `<state_root>/data/mysql`.
4. Remove MySQL runtime files under `<state_root>/run/mysql` and `<state_root>/tmp/mysql`.
5. Remove the MySQL socket file if present.
6. Remove the MySQL pid file if present.
7. Preserve or remove the allocated port according to reset policy.
8. Clear `datadir_initialized`, pid, readiness, and lifecycle fields from the service record.
9. Recompute resolved env.

Port preservation during reset is ambiguous. Preserving the port keeps app env stable after a database reset. Removing the port gives a more complete resource reset. Existing docs say `dev down` preserves allocations and leave reset specifics to the adapter, so this remains an open question.

Logs may be preserved by reset for diagnosis unless a future log-retention policy says otherwise.

## Recovery Paths

### Stale Pid

If state records a pid but the process no longer exists:

- Mark the service `state: stopped` or `state: stale`.
- Remove the pid file.
- Keep datadir, allocations, logs, and resolved env.
- On the next start, reuse the persisted port if it is free.

### Stale Socket

If the socket file exists but no MySQL process is running:

- Remove the stale socket file during prepare/start.
- Keep the persisted socket path.
- Start MySQL normally.

### Port Conflict

If the persisted port is occupied by a process that is not this instance's MySQL process:

- Allocate a new free port under the instance lock.
- Persist the replacement before starting MySQL.
- Recompute `DATABASE_URL`, `TEST_DATABASE_URL`, and `MYSQL_PORT`.
- Preserve the datadir.

### Partial Datadir Initialization

If the datadir exists but `datadir_initialized` is false or missing:

- If the directory is empty, rerun initialization.
- If the directory is non-empty and does not look like a valid MySQL datadir, mark startup failed and report that the user should run an explicit reset or remove the directory manually.
- Do not delete a non-empty datadir automatically during ordinary startup.

The exact files used to decide whether a datadir is valid are open because they may differ by MySQL distribution.

### Missing Generated Config

If `my.cnf` is missing:

- Recompute it from persisted paths and allocations.
- Write it before start.
- Do not change the persisted port unless conflict detection requires it.

### Corrupt Generated Config

If `my.cnf` exists but differs from the adapter-generated content:

- Overwrite it during prepare/start.
- Generated config is runtime state, not user-owned config.

### Failed Startup

If `mysqld` exits before readiness:

- Mark `state: failed` and `ready: false`.
- Preserve datadir, port allocation, socket path, logs, and generated config.
- Remove stale pid files if the process is gone.
- Leave enough state for `dev status` and `dev logs mysql` to explain the failure.

### Missing Binary

If required MySQL binaries are absent from `PATH`:

- Fail before datadir initialization or startup.
- Do not mutate datadir.
- Do not allocate a replacement port just because binaries are missing.
- Report the missing binary and advise entering the Nix-backed environment or fixing the project's Nix expression.

## Current Ruby Implementation Fit

The current code has `Dev::Project`, `Dev::Commands::Up`, and `Dev::ProcessManager`.

This adapter should fit the service runtime design by adding MySQL-specific behavior behind a typed service class, likely `Dev::Services::MySQL`, rather than extending `Dev::ProcessManager` with database semantics.

Implementation boundaries:

- `Dev::Project` continues to find `dev.yml`, expose top-level env, and resolve command strings.
- `Dev::Commands::Up` continues to preserve `up` execution order, but delegates managed service startup to the service runtime.
- `Dev::ProcessManager` or an evolved lower-level process tracker can still handle spawn, detach, pid liveness, logs, and TERM-then-KILL fallback.
- The MySQL adapter owns datadir initialization, generated config, readiness checks, database creation, env construction, graceful shutdown, and reset semantics.

The design is implementable in the current Ruby codebase because it relies on small object boundaries, filesystem state, `Process.spawn`, and explicit service lifecycle methods rather than external orchestration systems.

## Open Questions

- What exact defaults should apply when `database`, `test_database`, or `username` are omitted?
- What should happen when `password_env` is configured but the named environment variable is unset?
- Should service env be exposed to ordinary commands when MySQL is configured but stopped?
- What exact required binary list should the adapter and `dev doctor` verify?
- Which MySQL distribution is the initial target from Nix: Oracle MySQL, MariaDB, or either when compatible?
- Which initialization command should be required for the chosen distribution?
- What files should be used to determine that a non-empty datadir is valid?
- What readiness timeout and retry interval should be used?
- Should `DATABASE_URL` include a password when `password_env` is set, and if so how should escaping be handled without persisting secrets?
- During `dev reset mysql`, should the persisted port allocation be preserved or removed?
- Should reset preserve or truncate MySQL logs?
- Should the daemon run with cwd set to the project root or the service run directory?
