# dev.yml Guide

`dev.yml` is the project-local config file that tells `minidev` which commands exist, which services can be managed, and what `dev up` should orchestrate.

Put it at the root of the project you want `dev` to operate on. In a monorepo, each app can have its own `dev.yml` in its app directory.

## Minimal Example

```yml
up:
  build:
    - build

build: bin/setup
server: bin/rails server
test: bin/rails test
```

This gives you:

- `dev build`
- `dev server`
- `dev test`
- `dev up`

Project commands execute in the foreground. Use Ctrl+C to stop `dev server`.

## Top-Level Shape

Supported top-level keys:

```yml
env:
  KEY: value

services:
  name:
    type: process

up:
  instructions: []
  services: []
  dependencies: []
  build: []
  steps: []
  serve: []

build: command string or command config
server: command string or command config
console: command string or command config
test: command string or command config
style: command string or command config

commands:
  name:
    run: command string
```

## Environment

Top-level `env` values are added to commands run by `minidev`.

```yml
env:
  RAILS_ENV: development
  BUNDLE_WITHOUT: production
```

Values should be plain strings or values that can safely become strings. Do not put secrets directly in `dev.yml`; reference them through normal shell environment variables instead.

## Project Commands

The common commands can be defined at the top level:

```yml
build: bin/setup
server: bin/rails server
test: bin/rails test
console: bin/rails console
style: bundle exec rubocop
```

These become direct commands:

```bash
dev build
dev server
dev test
dev console
dev style
```

You can also define custom commands under `commands:`:

```yml
commands:
  worker:
    run: bundle exec sidekiq
  db:
    subcommands:
      reset:
        run: bin/rails db:reset
```

These become:

```bash
dev worker
dev db reset
```

Command configs support these shapes:

```yml
test: bin/rails test

build:
  run: bin/setup

commands:
  worker:
    run: bundle exec sidekiq
  db:
    subcommands:
      reset:
        run: bin/rails db:reset
```

## `dev up`

`up` describes startup orchestration. The preferred real-project shape is a map:

```yml
up:
  instructions:
    - Copy .env.example to .env if needed.
  services:
    - mysql
  dependencies:
    - bundle install
  build:
    - build
  steps:
    - run: bin/rails db:prepare
```

Execution order:

1. Print `instructions`.
2. Start `services` as tracked long-running services.
3. Run `dependencies`.
4. Run `build`.
5. Run `steps`.

`dependencies`, `build`, and `steps` are foreground setup steps. `services` are long-running tracked processes or managed services. `serve` is accepted for config readability but is not started by `dev up`; start app processes with direct commands like `dev server` or `dev worker`.

### Step Values

Each `up` step can be one of these:

```yml
# Named command or service, depending on section and config
- build

# Raw shell command
- bundle install

# Explicit project command
- command: build
  args: [--fast]

# Explicit managed service
- service: mysql

# Explicit raw command
- run: bin/rails db:prepare
  args: []
  label: Prepare database
```

Resolution in `up.services`:

1. A string matching `services.<name>` resolves as a service.
2. Otherwise a string matching a project command resolves as a command.
3. Otherwise it is treated as raw shell.

Use `{ command: name }` when you need to force command resolution. Use `{ service: name }` when you need to force service resolution.

## Services

Top-level `services:` is separate from `commands:`. A service does not automatically create a `dev <name>` command.

Supported service types:

- `process`
- `mysql`
- `postgres`

### Process Services

A `process` service is a long-running command tracked by `minidev`.

```yml
services:
  worker:
    type: process
    command: worker
    env:
      QUEUE: default

commands:
  worker:
    run: bundle exec sidekiq

up:
  services:
    - worker
```

Use exactly one of `command` or `run`:

```yml
services:
  vite:
    type: process
    run: pnpm dev --host 0.0.0.0
```

Supported fields for `process`:

- `type: process`
- `command`: project command name
- `run`: raw shell command
- `args`: list of string arguments
- `label`: optional display label
- `env`: environment variables for that service process

### Managed MariaDB Service

`type: mysql` starts a MariaDB server owned by the current project instance.

```yml
services:
  mysql:
    type: mysql
    database: shop_development
    test_database: shop_test
    username: shop
    password_env: MYSQL_PASSWORD

up:
  services:
    - mysql
```

Supported fields for `mysql`:

- `type: mysql`
- `database`: app database name
- `test_database`: test database name
- `username`: database user
- `password_env`: environment variable containing the password
- `env`: extra environment values for the MariaDB process

If `database`, `test_database`, or `username` are omitted, `minidev` derives defaults from the project directory name:

- `<project>_development`
- `<project>_test`
- `<project>`

Managed MySQL currently means MariaDB. These binaries must be available from the active environment:

- `mariadbd`
- `mariadb`
- `mariadb-admin`
- `mariadb-install-db`

Run `dev doctor` to check this.

Password values are never persisted in instance state. If `password_env` is configured, that environment variable must be set before MariaDB is prepared.

### Managed PostgreSQL Service

`type: postgres` starts a PostgreSQL server owned by the current project instance.

```yml
services:
  postgres:
    type: postgres
    database: shop_development
    test_database: shop_test
    username: shop
    password_env: POSTGRES_PASSWORD

up:
  services:
    - postgres
```

Supported fields for `postgres`:

- `type: postgres`
- `database`: app database name
- `test_database`: test database name
- `username`: database user
- `password_env`: environment variable containing the password
- `env`: extra environment values for the PostgreSQL process

If `database`, `test_database`, or `username` are omitted, `minidev` derives defaults from the project directory name:

- `<project>_development`
- `<project>_test`
- `<project>`

These binaries must be available from the active environment:

- `postgres`
- `initdb`
- `psql`
- `pg_isready`
- `pg_ctl`

Run `dev doctor` to check this.

Password values are never persisted in instance state. If `password_env` is configured, that environment variable must be set before PostgreSQL is prepared.

A `dev.yml` cannot define both a `mysql` service and a `postgres` service. Both export `DATABASE_URL`, so `minidev` rejects a config with both, and loading it fails.

## Command And Service Name Collisions

Commands and services can share a name, but be explicit when they do.

```yml
services:
  mysql:
    type: mysql

commands:
  mysql:
    run: bin/docker-db up
```

In `up.services`, this resolves to the service:

```yml
up:
  services:
    - mysql
```

To run the command instead:

```yml
up:
  services:
    - command: mysql
```

Direct `dev mysql` still means the project command, not the service.

## Common Configs

### Rails With Managed MariaDB

```yml
env:
  BUNDLE_WITHOUT: production

services:
  mysql:
    type: mysql
  worker:
    type: process
    command: worker

up:
  services:
    - mysql
  dependencies:
    - bundle install
  build:
    - build
  steps:
    - run: bin/rails db:prepare

build: bin/setup
server: bin/rails server
test: bin/rails test
console: bin/rails console

commands:
  worker:
    run: bundle exec sidekiq
```

### Frontend App

```yml
up:
  dependencies:
    - pnpm install
  build:
    - build

server: pnpm dev
build: pnpm build
test: pnpm test
style: pnpm lint
```

### Command-Only Services

Use this when a project already has scripts that manage dependencies externally:

```yml
up:
  services:
    - mysql
  build:
    - build

build: bin/setup
server: bin/rails server

commands:
  mysql:
    run: bin/docker-db up
```

This keeps the old command-oriented workflow. You can migrate to `services.mysql.type: mysql` later.

## Generated State

`dev.yml` stays in your project. Runtime state lives outside the repo by default:

```text
~/.local/state/minidev/instances/<instance_id>/
```

`minidev` may also write `<project_root>/.dev/instance.json` as a pointer to the active instance state. Do not put runtime state or secrets in `dev.yml`.

Managed MariaDB uses a short Unix socket path under `/tmp/minidev/` so it stays below MariaDB's macOS socket path limit. The socket path is still persisted in instance state and exported as `MYSQL_SOCKET`.

## Validation And Debugging

Useful commands:

```bash
dev help
dev doctor
dev status
dev logs
dev env
```

Use `dev doctor` after changing `dev.yml`; it checks config shape, command references, service references, state-root writability, and MariaDB binaries for configured MySQL services.

## Rules Of Thumb

- Prefer existing scripts over long inline shell.
- Put direct app commands at the top level when they are common (`build`, `server`, `test`).
- Put project-specific commands under `commands:`.
- Put long-running managed dependencies under `services:`.
- Put manual setup notes under `up.instructions`.
- Do not store secrets in `dev.yml`.
- Use `{ command: name }` or `{ service: name }` when names collide.
