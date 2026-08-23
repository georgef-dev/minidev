# minidev

`minidev` is a *reeaaaaallly* limited public replacement for Shopify's internal `dev` tool.

Where most of `dev` is concerned with `dev up`, which provisions dependencies and various other
things, there's a little bit of accessory function that's pretty easy to replicate, which is what's
been done here.

## install

```bash
curl https://raw.githubusercontent.com/georgef-dev/minidev/master/install.sh | bash
```

this writes minidev to ~/.local/minidev and sources it from your  .profile

## notes

`minidev` implements:

* `dev cd`
* `dev clone`
* Project-local commands (`dev {build,style,console,server,test,etc.}`).
* A simple YAML-driven `dev up`.
* Tracked project processes and managed services via `dev up`, `dev server`, `dev ps`, `dev stop`, and `dev down`.
* Service inspection with `dev doctor`, `dev status`, `dev logs`, `dev env`, and `dev reset`.


`minidev` does not:

* have adequate help
* try very hard to prevent randomly crashing
* be good

Use `minidev` by adding `source /path/to/minidev/dev.sh` to your shell config.

Everything this does is far more limited than `dev`, including that it won't self-update.

If you want to use the same dotfiles at home and at work, you may enjoy something like:

```bash
if [ -f /opt/dev/dev.sh ]; then
  source /opt/dev/dev.sh
elif [ -f ~/src/github.com/georgef-dev/minidev/dev.sh ]; then
  source ~/src/github.com/georgef-dev/minidev/dev.sh
fi
```

You can config the default directory for `dev clone` and `dev cd` by calling `dev config set default.github_root <path to directory>`, otherwise it defaults to `~/src/github.com`.

## Dependencies And Nix

`minidev` expects project tools and managed-service binaries to come from the environment that launched `dev`. For supported managed services, that means a Nix-backed environment.

Typical workflow:

```bash
nix develop
dev doctor
dev up
```

`shadowenv` is optional. It can activate the same Nix-backed environment automatically, but `minidev` still owns service state, ports, logs, and process lifecycle. `shadowenv` should not start or stop minidev services.

Commands like `bundle install`, `yarn install`, or `bin/setup` can still appear in `dev.yml` as app setup steps. The executables they need should be available from the active Nix environment.

## `dev up`

`dev up` reads `dev.yml` from the project root. The simplest version is to keep most behavior in the
same commands you already expose individually, then have `up` orchestrate setup and any required
background services while `dev server` starts the main app server.

For the full config reference, see [`docs/dev_yml.md`](docs/dev_yml.md).

Command-only example:

```yml
env:
  BUNDLE_WITHOUT: production

up:
  instructions:
    - Install PostgreSQL and Redis if they are not already available.
  services:
    - mysql
  dependencies:
    - bundle install
    - yarn install
  build:
    - build

build: bin/setup
server: bin/rails server

commands:
  mysql:
    run: bin/docker-db up
  worker:
    run: bundle exec sidekiq
```

Managed MariaDB example:

```yml
env:
  BUNDLE_WITHOUT: production

services:
  mysql:
    type: mysql
    database: shop_development
    test_database: shop_test
    username: shop
  worker:
    type: process
    command: worker

up:
  services:
    - mysql
  dependencies:
    - bundle install
    - yarn install
  build:
    - build

build: bin/setup
server: bin/rails server
test: bin/rails test

commands:
  worker:
    run: bundle exec sidekiq
```

Behavior:

* `instructions` are printed for manual steps.
* `services` starts tracked dependency services before `dependencies`, `build`, and `steps` run.
* `dependencies`, `build`, and `steps` run in order.
* `serve` is accepted for config readability but is not started by `dev up`; start app processes with direct commands like `dev server` or `dev worker`.
* Step values can be raw shell commands, command names like `build` or `server`, or hashes with
  `service`, `command`, `run`, `args`, and optional `label`.

This keeps `dev up` simple: the YAML holds both the instructions and the command definitions, and
`up` mostly glues the setup and required services together.

## Services

Top-level `services:` is a separate namespace from project commands.

Supported service types:

* `process`: starts a long-running shell command and tracks it in minidev state.
* `mysql`: starts a managed MariaDB server for the current project instance.

Process service schema:

```yml
services:
  worker:
    type: process
    command: worker
    args: []
    env:
      WORKER_ENV: value

commands:
  worker:
    run: bundle exec sidekiq
```

Use exactly one of `command` or `run` for a `process` service. `args`, `label`, and `env` are optional. Service `env` values are for that service process.

MariaDB service schema:

```yml
services:
  mysql:
    type: mysql
    database: shop_development
    test_database: shop_test
    username: shop
    password_env: MYSQL_PASSWORD
```

`database`, `test_database`, `username`, `password_env`, and `env` are optional. If database names or username are omitted, minidev derives local defaults from the project directory name. `password_env` names an environment variable; if configured, that variable must be set before MariaDB state is prepared. Password values are not persisted in instance state.

`up.services` resolves string items as services first, then commands, then raw shell. If both `services.mysql` and `commands.mysql` exist, `mysql` inside `up.services` means the service and minidev prints a warning when loading config. Use `{ command: mysql }` to reference the command explicitly.

Migration from command-only MySQL:

```yml
# Before
up:
  services:
    - mysql

commands:
  mysql:
    run: bin/docker-db up
```

```yml
# After
services:
  mysql:
    type: mysql

up:
  services:
    - mysql
```

Direct `dev mysql` only works for project commands. A top-level service does not create a `dev mysql` command. Keep a separate command if you still need direct command semantics, and reference it from `up` with `{ command: mysql }` when a same-named service exists.

## Process Management

`dev server` starts the top-level `server` command in the foreground. Use Ctrl+C to stop it.

`dev up` tracks anything started from `up.services` in the same instance state. New process logs are appended under the instance `logs/` directory.

Related commands:

* `dev ps` lists tracked running processes for the current project.
* `dev stop` stops tracked processes. Pass names like `server` to stop a specific one.
* `dev down` stops all tracked processes and leaves durable instance state in place.

Legacy `<project_root>/.dev/pid.tmp` records are still read when live, but new starts use global instance state.

## State And Introspection

Each project/worktree/environment gets a deterministic instance id. The default global state layout is:

```text
~/.local/state/minidev/instances/<instance_id>/
  instance.json
  lock
  logs/
  pids/
  sockets/
  data/
  run/
  tmp/
```

The project-local `<project_root>/.dev/instance.json` file is a pointer to global state. It is a cache, not the source of truth. If it is missing, minidev derives the current instance from the project path, git worktree root, and `development` environment.

Introspection commands:

* `dev doctor` checks project discovery, `dev.yml` parsing, Nix environment signals, configured commands, service references, state-root writability, and MariaDB binaries. It does not start services or mutate service records.
* `dev status` shows the current instance and known configured or recorded services. It refreshes liveness but does not start services.
* `dev logs` lists known service log paths. `dev logs <service>` prints that service log if it exists.
* `dev env` prints minidev-controlled environment values: top-level `env`, instance metadata, and resolved service env. Inherited shell env is not printed. Secret-looking keys are redacted.
* `dev reset <service>` stops and resets one service. `dev reset --all` resets all known services. `dev reset` without a service or `--all` is rejected.

Process reset removes that process record, pid file, and log. MariaDB reset removes the owned datadir, socket, pid, generated config, run dir, and tmp dir, while preserving the MariaDB log file.

## Known Limitations

* Managed `mysql` means MariaDB only. The required binaries are `mariadbd`, `mariadb`, `mariadb-admin`, and `mariadb-install-db`.
* Real MariaDB integration requires those binaries in the active Nix environment or on `PATH`. Unit tests use fake binaries; `dev doctor` reports missing real binaries as errors for configured MySQL services.
* Command execution uses a Nix `bash` only when `bash` on `PATH` is under `/nix/store`. Otherwise minidev warns and falls back to `/bin/bash`.
* Managed MariaDB uses a short socket path under `/tmp/minidev/` to stay below MariaDB's macOS Unix socket path limit.
* Logs append for now. There is no log rotation or truncation policy.
* `dev reset` requires a service name or `--all`.
* `dev ps` is process-focused. Use `dev status` for configured-but-stopped services and service readiness.

For now this is intentionally simple and instance-local.

## contributing

Are you ex-Shopify? Feel free to send patches to implement the thing the way you
remember it working.

Are you current Shopify? There's really very little I could point to in `dev`
itself that couldn't be made open source. You can pretty much feel free to copy
code directly over here, just try not to introduce a whole lot of complexity.

In general we don't want minidev to do _different_ things than `dev`, except to
the extent necesary for simplicity or a bit less Shopify-specificness.
