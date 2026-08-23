# Minidev Nix Contract

## Status

Draft internal design document for the Nix-backed environment contract and future `dev doctor` checks.

This document defines what `minidev` assumes from project environments. It does not define service adapter internals, MySQL startup details, or production code changes.

## Scope

This contract assumes:

- Nix is the only supported dependency source.
- Project commands run in the environment inherited by `minidev`, plus `dev.yml` env and future instance-resolved env.
- Required project and service binaries must already be available when `minidev` starts a command.
- `shadowenv` is optional and never required for core behavior.
- `minidev` verifies environment readiness but does not install non-Nix dependencies.

Out of scope:

- Supporting Bundler, npm, Homebrew, asdf, mise, rbenv, pyenv, or system packages as dependency managers.
- Automatically entering Nix shells unless a later implementation explicitly chooses a small mechanism for that.
- Requiring `shadowenv` for activation, instance state, or service lifecycle.
- Starting or stopping services from `shadowenv`.

## Contract Summary

`minidev` relies on one small rule:

> When a user runs `dev`, the current process environment must already expose the binaries needed by the selected `dev.yml` command and configured managed services.

For example, if `dev.yml` says `server: bin/rails server`, the inherited environment must make the command's interpreter and tools available. If a managed MySQL service is configured, the inherited environment must expose the MySQL server and client binaries expected by the MySQL adapter.

`minidev` is responsible for:

- Finding the project by walking up to `dev.yml`.
- Resolving command strings from `dev.yml`.
- Merging top-level `env` from `dev.yml` into the inherited environment.
- Adding future instance metadata such as `MINIDEV_INSTANCE_ID` and `MINIDEV_STATE_ROOT`.
- Adding future service-resolved environment such as `MYSQL_PORT` and `DATABASE_URL`.
- Starting, tracking, stopping, and inspecting project processes and managed services.
- Reporting missing or inconsistent environment requirements through `dev doctor`.

Nix is responsible for:

- Supplying executable dependencies on `PATH`.
- Supplying language runtimes and project tools used by commands in `dev.yml`.
- Supplying service binaries used by builtin service adapters.
- Keeping those tools reproducible for the project.

## Current Execution Behavior

Current command execution under `lib/dev/` is environment-pass-through:

- `Dev::Project.current` discovers the project by finding `dev.yml` in the current directory or an ancestor.
- `Dev::Project#env` returns `ENV.to_h.merge(config['env'] || {})`.
- Project commands execute through `/bin/bash -c` with `project.env`.
- `dev up` setup steps execute through `/bin/bash -c` with `project.env`.
- Tracked services and `dev server` use `Process.spawn(project.env, '/bin/bash', '-c', ...)`.
- Current process state lives under `<project_root>/.dev`; the target instance model moves runtime state to `~/.local/state/minidev/instances/<instance_id>/`.

The future Nix contract should preserve this simple boundary: `minidev` does not become a package manager. It executes commands inside the environment it was given and verifies that the environment satisfies the project contract.

## Project Requirements

A Nix-backed project should provide:

- A `dev.yml` file in the project root.
- A Nix expression or flake that exposes all binaries used by `dev.yml` commands.
- Any binaries required by configured managed services.
- Optional activation glue, such as `shadowenv`, `direnv`, shell aliases, or manual `nix develop`, as long as the final environment is Nix-backed.

Only the resulting environment matters to `minidev`. The user may enter that environment manually or automatically.

## Binary Exposure Rules

Projects should expose required tools by putting them on `PATH` through Nix.

Required binaries fall into three categories.

Project command binaries:

- The shell command named directly in `dev.yml`, such as `ruby`, `bundle`, `node`, `yarn`, `go`, `cargo`, or project scripts with shebangs that require those interpreters.
- Any tools invoked by project-local scripts such as `bin/setup`, `bin/rails`, or `script/test`.

`minidev` runtime binaries:

- Ruby must be available for `minidev` itself. The repository's `default.nix` packages `minidev` with `ruby` in `buildInputs`.
- `/bin/bash` is currently used by command execution. This is an implementation fact in current code. Whether target Nix-only behavior should use a Nix-provided bash instead is an open question.

Managed service binaries:

- A `mysql` service requires the MySQL server and support tools from Nix. Exact binary names are left to the MySQL adapter spec, but likely include `mysqld` and client/admin tools needed for initialization and readiness checks.
- Future managed services should document their own exact required binaries.

Projects should avoid relying on globally installed tools that are not provided by the project Nix environment. If a command works only because a developer has a tool installed outside Nix, the project does not satisfy this contract.

## Discovery And Verification

`minidev` should discover tools by checking the active command environment, not by searching arbitrary Nix store paths.

Rules:

- Use `PATH` lookup for executable names needed by configured commands and services.
- Prefer verifying concrete configured commands and service requirements over broad language detection.
- Do not infer support for a tool from files like `package.json`, `Gemfile`, or `go.mod` unless the tool is referenced by `dev.yml` or a configured service.
- Do not run package managers to repair missing dependencies.
- Do not persist Nix store path discovery caches in instance state by default.
- Do not persist `shadowenv` activation state.

For raw shell commands, exact static binary extraction is not always reliable. `dev doctor` should perform shallow checks and avoid pretending it can fully parse shell.

Suggested shallow extraction:

- For a single-line command, check the first shell word when it is a simple executable name.
- For project scripts such as `bin/setup`, check that the script exists and is executable, then optionally inspect its shebang for a required interpreter.
- For multi-line shell commands or commands with shell builtins, variables, conditionals, pipes, or functions, report that static verification is limited.
- For named managed services, use the service adapter's explicit required binary list.

## Working Without Shadowenv

`minidev` works without `shadowenv` when the user enters the Nix environment before running `dev`.

Example project:

```yaml
up:
  services:
    - mysql
  dependencies:
    - build
  serve:
    - server

build: bin/setup
server: bin/rails server
test: bin/rails test

services:
  mysql:
    type: mysql
    database: shop_development
    test_database: shop_test
    username: shop
```

Example manual workflow:

```bash
nix develop
dev doctor
dev up
dev server
```

Expected result:

- `nix develop` puts Ruby, Bundler, MySQL, and any other project tools on `PATH`.
- `dev doctor` verifies that configured command and service binaries are available.
- `dev up` starts configured services, runs setup, and starts background serve steps.
- `dev server` receives top-level `dev.yml` env plus future instance and service env.

No `shadowenv` behavior is required in this flow.

## Optional Shadowenv Integration

`shadowenv` may be used to activate the Nix-backed environment automatically when the user enters the project directory.

Allowed responsibilities:

- Enter or approximate the project's Nix environment automatically.
- Put Nix-provided binaries on `PATH`.
- Export static project environment variables if the project chooses to keep them outside `dev.yml`.
- Export optional hints that help humans or tools identify the active environment.

Disallowed responsibilities:

- Starting, stopping, or resetting services.
- Allocating ports, sockets, datadirs, pid paths, or log paths.
- Writing `minidev` instance state.
- Being required for `dev up`, `dev server`, `dev test`, `dev ps`, `dev stop`, or `dev down`.
- Being treated as the source of truth for `MINIDEV_INSTANCE_ID`, `MINIDEV_STATE_ROOT`, or service connection env.

Example workflow with `shadowenv`:

```bash
cd ~/src/github.com/example/shop
shadowenv trust
dev doctor
dev up
```

Expected result:

- `shadowenv` activates the Nix-backed environment before `dev` runs.
- `dev doctor` sees the same binaries it would see after manual `nix develop`.
- `minidev` still owns service lifecycle and instance state.

Example `.shadowenv.d` behavior, expressed conceptually:

```bash
# Activate the project Nix environment.
# Export only static project env if needed.
# Do not start mysql, rails, workers, or any minidev-managed process.
```

## Environment Injection Boundary

The active environment passed to child processes is layered by `minidev`.

Current layers:

1. Inherited environment from the shell that launched `dev`.
2. Top-level `env` from `dev.yml`.

Target layers from the instance model:

1. Inherited environment from the shell that launched `dev`.
2. Top-level `env` from `dev.yml`.
3. Instance metadata exported by `minidev`.
4. Service-provided resolved env derived from persisted instance state.
5. Future command-specific env, if added later.

Nix activation belongs before layer 1. It prepares the environment that launches `dev`; it is not a separate runtime layer managed by `minidev`.

`shadowenv` also belongs before layer 1. It may shape the inherited environment, but it must not replace `minidev`'s instance or service env layers.

## `dev doctor` Checks

`dev doctor` should verify the active project environment and report actionable failures.

Required checks:

- Project discovery: confirm a `dev.yml` is found and report the project root.
- Config parse: confirm `dev.yml` can be parsed and has supported shapes for commands and `up`.
- Nix signal: confirm the environment appears Nix-backed.
- Command executables: check configured default commands and custom commands where a simple executable or script can be identified.
- `up` references: confirm named commands referenced by `up` exist, and raw steps have shallow executable checks when possible.
- Service references: confirm `up.services` references known commands or configured services according to the active config schema.
- Managed service binaries: for each configured managed service, check the adapter's required binaries on `PATH`.
- Project scripts: confirm referenced relative scripts exist and are executable.
- Script shebangs: when a referenced script has a shebang, confirm the interpreter is available when it is not an absolute system path.
- Instance state root: confirm the target state directory parent is writable, using the instance model's global state location.
- Existing state sanity: if instance state exists, confirm it matches the derived project/worktree/environment identity.
- Shadowenv status: if `shadowenv` appears active or configured, report it as informational only.

Nix signal checks should stay conservative. Acceptable evidence could include:

- `IN_NIX_SHELL` is present.
- `PATH` contains `/nix/store/` entries.
- A future explicit `MINIDEV_NIX_ENV=1` convention is present.
- A project flake or Nix expression exists and required binaries resolve to `/nix/store/` paths.

Failure to detect a Nix signal should be a warning when all required binaries resolve from `/nix/store/`, and an error when required binaries are missing or resolve only outside Nix.

Suggested output categories:

- `ok`: requirement is satisfied.
- `warn`: environment may work but violates or weakens the contract.
- `error`: command or service is expected to fail.
- `unknown`: static verification is not possible for a shell fragment.

`dev doctor` must not:

- Run `bundle install`, `npm install`, `yarn install`, `pip install`, or equivalent.
- Run `nix develop` implicitly.
- Require `shadowenv`.
- Start services.
- Delete or migrate state without an explicit user action.

## Failure Scenarios

### Not In A Nix Environment

Symptoms:

- `dev doctor` reports no Nix signal.
- Required tools are missing from `PATH`.
- Commands fail with `command not found`.

User action:

- Enter the project's Nix environment, for example with `nix develop`, or configure optional activation such as `shadowenv`.
- Re-run `dev doctor`.

### Tool Exists Only Outside Nix

Symptoms:

- `dev doctor` finds a required executable, but its resolved path is outside `/nix/store/`.
- The command may work on one developer's machine and fail on another.

User action:

- Add the tool to the project's Nix environment.
- Re-enter the environment and re-run `dev doctor`.

### Missing Service Binary

Symptoms:

- A configured `mysql` service exists, but `mysqld` or another adapter-required binary is missing.
- `dev up` cannot start the managed service.

User action:

- Add the service package to the project's Nix environment.
- Re-run `dev doctor` before `dev up`.

### Shadowenv Not Installed

Symptoms:

- A project has shadowenv files, but the user does not have `shadowenv` installed or trusted.
- `dev doctor` may report shadowenv as inactive.

User action:

- Either run `nix develop` manually or install/trust `shadowenv`.
- Do not change `dev.yml`; `shadowenv` is optional.

### Shadowenv Active But Incomplete

Symptoms:

- `shadowenv` is active, but required Nix-provided binaries are missing.
- `dev doctor` reports missing command or service tools.

User action:

- Fix the shadowenv/Nix activation script so it exposes the same tools as manual `nix develop`.
- Re-run `dev doctor`.

### Raw Shell Cannot Be Fully Verified

Symptoms:

- `dev.yml` contains complex shell in a command or `up` step.
- `dev doctor` reports `unknown` for static verification.

User action:

- Prefer moving complex setup into a project script exposed by Nix-backed interpreters.
- Keep `dev.yml` command entries small and direct.

### Instance State Is Not Writable

Symptoms:

- `dev doctor` cannot create or write under the target state root parent.
- Future `dev up` cannot persist ports, pids, logs, sockets, or datadirs.

User action:

- Fix permissions on the state directory parent.
- If a future state-root override is added, point it at a writable location.

### State Env Disagrees With Current Project

Symptoms:

- Existing `.dev/instance.json` or global state points at a different project root, worktree root, or environment.
- Commands might use stale service env if state is trusted blindly.

User action:

- Let `minidev` re-derive identity from current local facts.
- Use future reset or cleanup commands if stale state remains problematic.

## Recommended Project Setup Examples

### Flake Without Shadowenv

Project intent:

- Developers explicitly run `nix develop`.
- `dev.yml` contains commands only, not dependency installation alternatives.

```yaml
env:
  RAILS_ENV: development

up:
  services:
    - mysql
  build:
    - build
  serve:
    - server

build: bin/setup
server: bin/rails server
test: bin/rails test

services:
  mysql:
    type: mysql
    database: shop_development
    test_database: shop_test
    username: shop
```

Workflow:

```bash
nix develop
dev doctor
dev up
```

### Flake With Shadowenv

Project intent:

- `shadowenv` automatically activates the same Nix environment a user would enter manually.
- `minidev` remains responsible for orchestration.

```yaml
up:
  services:
    - mysql
  build:
    - build
  serve:
    - worker

build: bin/setup
server: bin/rails server
test: bin/rails test

commands:
  worker:
    run: bundle exec sidekiq

services:
  mysql:
    type: mysql
    database: shop_development
    username: shop
```

Workflow:

```bash
cd ~/src/github.com/example/shop
dev doctor
dev up
dev server
```

Shadowenv may make `bundle`, `ruby`, `mysqld`, and other tools available before `dev` starts. It must not start `mysql` or `worker` itself.

### Command-Only Current Config

Current `minidev` supports command-oriented services before typed services exist.

```yaml
up:
  services:
    - mysql
  dependencies:
    - build
  serve:
    - worker

build: bin/setup
server: bin/rails server
test: bin/rails test

commands:
  mysql:
    run: mysqld --defaults-file=config/mysql.cnf
  worker:
    run: bundle exec sidekiq
```

Contract:

- Nix must expose `mysqld`, `ruby`, `bundle`, and any script interpreters.
- `dev doctor` can check simple command names but cannot understand all MySQL runtime requirements from a raw shell command.
- Typed services should replace raw service shell where builtin service management is needed.

## Open Questions

- Should future command execution replace `/bin/bash` with a Nix-provided bash path, and how should that path be discovered?
- What exact evidence should make `dev doctor` treat an environment as definitively Nix-backed instead of warning-only?
- Should projects declare required command binaries explicitly in `dev.yml`, or is shallow command/script inspection enough for the first implementation?
- What exact binary list should the MySQL adapter require?
- Should `dev doctor` fail when a required binary resolves outside `/nix/store/`, or warn if the rest of the environment appears Nix-backed?
- Should a future `MINIDEV_STATE_HOME` override be part of the supported contract for tests and advanced local setups?
- How should `dev doctor` represent checks that are skipped because a future typed service schema is not yet implemented?

## Invariants

- Nix is the only supported dependency source.
- `shadowenv` is optional.
- Core commands must work without `shadowenv` when the active shell is already in the Nix-backed environment.
- `minidev` does not install dependencies as part of environment verification.
- Service lifecycle and instance state belong to `minidev`, not Nix activation hooks.
- Project commands receive inherited env plus `dev.yml` env and future instance/service env.
- `dev doctor` verifies and reports; it does not mutate project dependencies or start services.
