# dev.yml Managed Services

## Status

Draft internal design for evolving `dev.yml` from command-only orchestration to small, first-class managed service declarations.

This document is intentionally config-focused. It does not define service adapter internals, lifecycle implementation, or MySQL startup details beyond the fields needed to describe services in `dev.yml`.

## Goals

- Add top-level `services:` as a separate namespace from app commands.
- Let `up.services` reference named managed services before setup steps run.
- Preserve existing command-oriented app commands such as `build`, `server`, `console`, `test`, `style`, and `commands:`.
- Keep old command-only `up.services` configs working during migration.
- Keep the schema small enough to explain in one screen for common projects.
- Stay reusable across projects and avoid Relay-specific assumptions.

## Non-Goals

- Replacing `commands:` with services.
- Turning `dev.yml` into a general process supervisor DSL.
- Adding non-Nix dependency management options.
- Making `shadowenv` required.
- Defining a broad plugin system.
- Expressing every adapter-specific runtime detail in YAML.

## Current Model

Current `dev.yml` supports command definitions and `up` orchestration.

Example:

```yml
up:
  services:
    - mysql
  dependencies:
    - bundle install
  build:
    - build
  serve: worker

build: bin/setup
server: bin/rails server
test: bin/rails test

commands:
  mysql:
    run: bin/docker-db up
  worker:
    run: bundle exec sidekiq
```

In the current implementation:

- `Project#config` loads `dev.yml` as YAML.
- `Project#env` merges inherited process env with top-level `env`.
- `Project#command_config` resolves default commands and `commands.<name>`.
- `dev up` normalizes `up.services`, `up.dependencies`, `up.build`, `up.steps`, and `up.serve` into step lists.
- Step strings first try to resolve as commands; otherwise they run as raw shell.
- `up.services` and `up.serve` start tracked shell processes with generated names.
- There is no top-level service namespace yet.

This model is good for app commands and generic background processes. It is not enough for managed services like MySQL because MySQL needs instance state, dynamic ports, datadirs, sockets, health checks, and resolved env injection.

## Target Shape

Top-level `services:` defines managed dependency services. Top-level command entries and `commands:` continue to define app commands and useful workflows.

Example:

```yml
env:
  RAILS_ENV: development

services:
  mysql:
    type: mysql
    database: shop_development
    test_database: shop_test
    username: shop

up:
  services:
    - mysql
  dependencies:
    - bundle install
    - yarn install
  build:
    - build
  serve:
    - worker

build: bin/setup
server: bin/rails server
console: bin/rails console
test: bin/rails test

commands:
  worker:
    run: bundle exec sidekiq
```

Key rules:

- `services:` is a top-level map keyed by service name.
- Each service entry must declare `type`.
- `up.services` references top-level service names when a matching service exists.
- Existing command and raw-shell step resolution remains available for compatibility.
- Commands and services may share execution order in `dev up`, but they are separate config concepts.

## Top-Level `services:` Schema

Minimum common schema:

```yml
services:
  <name>:
    type: <service-type>
```

Common fields:

- `type`: required string selecting a built-in service adapter.
- `env`: optional map of static environment values for this service process only.
- `healthcheck`: optional adapter-supported readiness configuration for `process` services only if implemented.

Initial service types:

- `mysql`: built-in managed MySQL adapter.
- `process`: managed long-running shell process with service-state integration.

The `mysql` type should be built in, not represented as a shell command. It needs adapter-owned behavior for initialization, persisted dynamic ports, datadirs, sockets, readiness, shutdown, and resolved environment.

Minimum `mysql` config fields:

```yml
services:
  mysql:
    type: mysql
    database: shop_development
    test_database: shop_test
    username: shop
```

Supported `mysql` fields for this config layer:

- `type`: must be `mysql`.
- `database`: optional app database name. If absent, adapter defaults are an open question.
- `test_database`: optional test database name.
- `username`: optional local database username.
- `password_env`: optional environment variable name from which to read a password.
- `env`: optional static environment values for the MySQL process only.

Minimum `process` config fields:

```yml
services:
  worker:
    type: process
    command: worker
```

Supported `process` fields for this config layer:

- `type`: must be `process`.
- `command`: optional named command reference from default commands or `commands:`.
- `run`: optional raw shell command.
- `args`: optional list of string arguments.
- `env`: optional static environment values for this process only.

Exactly one of `command` or `run` should be required for `process` services. A `process` service should not add a new command language; it should reuse the existing step command resolution rules where possible.

## `up.services` Resolution

`up.services` keeps its current role: start dependency services before dependencies, build, and setup steps run.

Resolution order for each `up.services` item should be:

1. If the item is a string matching `services.<name>`, resolve it as a managed service.
2. If the item is a string that does not match a service, resolve it with existing step behavior as a named command or raw shell command.
3. If the item is a hash with `service: <name>`, resolve `services.<name>` explicitly.
4. If the item is a hash with `command` or `run`, resolve it with existing step behavior.

Examples:

```yml
up:
  services:
    - mysql
```

Explicit service reference:

```yml
up:
  services:
    - service: mysql
```

Compatibility command service:

```yml
up:
  services:
    - redis

commands:
  redis:
    run: redis-server
```

Compatibility raw shell service:

```yml
up:
  services:
    - run: docker compose up db
```

The string resolution order means a top-level service name takes precedence over a command of the same name inside `up.services`. To avoid surprise, configs should not define both `services.mysql` and `commands.mysql` unless the command is intentionally separate and referenced with `{ command: mysql }` outside service startup.

## `up.serve` Resolution

`up.serve` should continue to start post-setup long-running processes.

For compatibility, `up.serve` should keep existing command/raw-shell step behavior. It may also accept managed service references by the same rules as `up.services`, but config authors should prefer:

- `up.services` for dependency services required before setup.
- `up.serve` for app-adjacent long-running processes such as workers, asset watchers, or the main server.

If `worker` is an app process and does not need managed service behavior, keep it as a command:

```yml
up:
  serve: worker

commands:
  worker:
    run: bundle exec sidekiq
```

If `worker` needs service-state integration, define it as a `process` service:

```yml
services:
  worker:
    type: process
    command: worker

up:
  serve:
    - worker

commands:
  worker:
    run: bundle exec sidekiq
```

## Commands And Services Stay Separate

Commands are user-facing project actions. Services are managed runtime dependencies or long-running processes tracked as part of an instance.

Commands belong in:

- `build`
- `server`
- `console`
- `test`
- `style`
- `commands:`

Services belong in:

- `services:`

`up` references both, but does not merge the namespaces.

Design rules:

- Do not remove existing command-oriented app commands.
- Do not require every background process to become a service.
- Do not put app commands like `test` or `console` under `services:`.
- Do not put built-in managed dependencies like MySQL under `commands:` in new configs.
- Keep `commands:` useful for direct `dev <command>` workflows.

Good split:

```yml
services:
  mysql:
    type: mysql
    database: shop_development

server: bin/rails server
test: bin/rails test

commands:
  worker:
    run: bundle exec sidekiq
```

Avoid:

```yml
commands:
  mysql:
    run: mysqld --datadir=.dev/mysql --port=3306
```

That command-only shape can still work during migration, but it should not be the target for managed MySQL.

## Before And After Examples

### MySQL Command To Managed Service

Before:

```yml
up:
  services:
    - mysql
  dependencies:
    - bundle install
  build:
    - build
  serve: server

build: bin/setup
server: bin/rails server
test: bin/rails test

commands:
  mysql:
    run: bin/docker-db up
```

After:

```yml
services:
  mysql:
    type: mysql
    database: app_development
    test_database: app_test
    username: app

up:
  services:
    - mysql
  dependencies:
    - bundle install
  build:
    - build
  serve: server

build: bin/setup
server: bin/rails server
test: bin/rails test
```

Notes:

- The app commands remain top-level commands.
- The MySQL shell command is removed only after the managed MySQL adapter can replace it.
- Connection env should come from resolved instance state, not hard-coded YAML.

### Redis Command Kept As Command

Before:

```yml
up:
  services:
    - redis

commands:
  redis:
    run: redis-server
```

After, if no Redis adapter exists yet:

```yml
up:
  services:
    - redis

commands:
  redis:
    run: redis-server
```

Notes:

- This remains valid compatibility behavior.
- Do not invent a generic Redis schema before a Redis adapter is designed.

### Process Service When State Integration Is Useful

Before:

```yml
up:
  serve:
    - worker

commands:
  worker:
    run: bundle exec sidekiq
```

After:

```yml
services:
  worker:
    type: process
    command: worker

up:
  serve:
    - worker

commands:
  worker:
    run: bundle exec sidekiq
```

Notes:

- The `worker` command remains directly runnable with `dev worker`.
- The service wrapper adds instance-state tracking without duplicating the shell command.

## Migration Notes

Migration should be additive and project-by-project.

Recommended path:

1. Keep existing command-only configs working unchanged.
2. Add top-level `services:` support without changing command resolution for normal commands.
3. Migrate MySQL-like dependencies from `commands:` to `services:` only when the adapter exists.
4. Keep app commands under top-level command keys or `commands:`.
5. Remove old command-only service entries only when no user workflow depends on `dev <service-name>`.

For projects that want a direct command for a managed service, add a future explicit UX command such as `dev services` or `dev status`; do not require every managed service to have a matching `commands:` entry.

If a config currently has `commands.mysql` and later adds `services.mysql`, `up.services: [mysql]` should resolve to the managed service. Existing direct `dev mysql` behavior may still resolve to the command. This overlap is allowed during migration but should be discouraged in new examples.

## Compatibility Guidance

Old configs should continue to work:

```yml
up:
  services:
    - mysql
commands:
  mysql:
    run: bin/docker-db up
```

Array and string `up` forms should continue to work:

```yml
up:
  - bundle install
  - server
```

```yml
up: server
```

Existing step hash forms should continue to work:

```yml
up:
  steps:
    - command: db
      args: [prepare]
    - run: npm run build
```

Compatibility rules:

- Do not make `services:` required.
- Do not reject command-only `up.services` entries.
- Do not reinterpret `commands:` entries as managed services outside `up.services` or `up.serve` resolution.
- Do not change direct command invocation semantics for `dev build`, `dev server`, `dev test`, or `dev <commands.name>`.
- Add warnings later for ambiguous service/command name collisions, but do not fail old configs initially unless ambiguity causes unsafe behavior.

## Minimum Parser And Resolution Changes

Likely minimal changes in config loading and `dev up` resolution:

- Add a `Project#service_config(name)` helper that reads `config.fetch('services', {})[name]`.
- Add validation for top-level `services:` being a map when present.
- Add validation that each service has a supported `type`.
- Extend `Up#resolve_step` or split service resolution so `up.services` can resolve string names against `services:` before command/raw-shell behavior.
- Support hash steps with `service: <name>` for explicit managed service references.
- Preserve current `command` and `run` hash behavior.
- Teach `start_service` to dispatch managed service references to the service runtime instead of `ProcessManager#start`.
- Keep command/raw-shell compatibility steps using the existing process manager until the service runtime replaces or wraps it.
- Ensure setup steps run with resolved instance env after dependency services start.

The parser should not need a general object model for all YAML entries. A small set of helpers is enough:

- command lookup
- service lookup
- up step normalization
- service-reference resolution

Validation should start narrow. Reject clearly malformed `services:` entries, but avoid broad schema enforcement that would make additive adapter fields difficult.

## Guardrails Against DSL Sprawl

- Prefer built-in service adapters over large YAML command recipes.
- Keep adapter-specific fields small and documented per adapter.
- Do not add conditionals, loops, interpolation, inheritance, templates, or package-manager branches to `dev.yml`.
- Do not add lifecycle hook arrays such as `before_start`, `after_start`, `before_stop`, or `after_stop` until a concrete repeated need exists.
- Do not expose internal paths like pid files, logs, sockets, or datadirs as required YAML fields; derive them from instance state.
- Do not add static port fields for managed MySQL in the base schema; ports are dynamically reserved and persisted.
- Do not make `services:` a plugin mechanism. Supported `type` values should be explicit built-ins for now.
- Do not duplicate app commands inside service definitions; use `command:` references for `process` services.
- Keep `up` readable in one screen.
- If a field is only needed by one future project and not by the adapter contract, leave it out until the adapter design requires it.

## Open Questions

- Should `up.serve` support managed service references immediately, or should that be delayed until the service runtime exists?
- What should the MySQL adapter default for `database`, `test_database`, and `username` when fields are omitted?
- Should service and command name collisions warn, fail, or silently prefer services only in `up.services`?
- Should `process` services support a `healthcheck` field in the first implementation, or should readiness remain adapter-only until there is a concrete need?
- How should `password_env` behave if the named environment variable is unset: fail during config validation, fail during service start, or run without a password when the adapter permits it?
- Should `dev <service-name>` ever dispatch to managed services, or should service interaction stay behind future commands such as `dev status`, `dev logs`, and `dev reset`?
