# AGENTS

This file explains how an LLM should create a `dev.yml` file for a project that uses `minidev`.

## Goal

Produce a small, practical `dev.yml` in the project root.

The config should do two things well:

1. Define the project's common commands like `build`, `server`, `console`, and `test`.
2. Define `up` as a simple orchestration layer for setup instructions, dependency installation, build steps, and any required background services.

Prefer a minimal config that reflects how the project already works. Do not invent a complex DSL or extra abstractions.

## How `minidev` reads `dev.yml`

`minidev` supports these top-level patterns:

```yml
env:
  SOME_VAR: value

up:
  instructions:
    - Manual setup note
  services:
    - mysql
  dependencies:
    - bundle install
    - yarn install
  build:
    - build
  steps:
    - run: bin/rails db:prepare
  serve: worker

build: bin/setup
server: bin/rails server
test: bin/rails test

commands:
  mysql:
    run: bin/docker-db up
  worker:
    run: bundle exec sidekiq
  db:
    subcommands:
      reset:
        run: bin/rails db:reset
```

## Supported shapes

Top-level command entries:

- `build: <string>`
- `server: <string>`
- `console: <string>`
- `test: <string>`
- `style: <string>`
- `commands.<name>.run: <string>`
- `commands.<name>.subcommands.<subcommand>.run: <string>`

`up` supports:

- `up: <string>`
  - Treats the string as the final long-running command.
- `up: [ ... ]`
  - Runs all items except the last as setup steps.
  - Uses the last item as the final long-running command.
- `up: { ... }`
  - Preferred form for real projects.

Step values inside `up.services`, `up.dependencies`, `up.build`, `up.steps`, and `up.serve` can be:

- A raw shell command string like `bundle install`
- A named command like `build` or `server`
- A hash with:
  - `command`: reference to a named command
  - `run`: raw shell command
  - `args`: list of string arguments
  - `label`: optional human-readable description

## Authoring rules

1. Mirror the project's existing commands.
2. Prefer existing scripts over long inline shell.
3. Reuse named commands from `up` when possible.
4. Keep `up` readable in one screen.
5. Put manual prerequisites in `up.instructions`, not in failing shell commands.
6. Put shared environment variables in top-level `env`.
7. Use `commands:` for project-specific extras that are not one of the default names.
8. Do not add compatibility branches for multiple package managers unless the project clearly needs them.
9. Do not guess secret values. Only reference env vars by name.
10. If a process is long-running and required for local development, it usually belongs in `up.serve`, not in setup steps.

## How to infer the config from a repo

Inspect the project root and common files first:

- `README.md`
- `package.json`
- `Gemfile`
- `bin/`
- `script/`
- `Procfile`
- `docker-compose.yml`
- `compose.yml`
- `Makefile`
- language-specific manifests like `go.mod`, `Cargo.toml`, `pyproject.toml`

Then infer:

### Build

Choose the command developers use to prepare the app itself.

Good examples:

- `bin/setup`
- `make build`
- `npm run build`
- `cargo build`

### Server

Choose the primary local app server developers run directly.

Good examples:

- `bin/rails server`
- `npm run dev`
- `yarn dev`
- `go run ./cmd/web`

### Test

Choose the main test command.

Good examples:

- `bin/rails test`
- `bundle exec rspec`
- `npm test`
- `pytest`

### Console

Only add this if the project has a real interactive console.

Good examples:

- `bin/rails console`
- `python manage.py shell`

### Style

Only add this if there is an obvious formatter or lint command.

Good examples:

- `bundle exec rubocop`
- `npm run lint`
- `ruff check .`

### Custom commands

Use `commands:` for useful local workflows such as:

- `worker`
- `jobs`
- `db`
- `storybook`
- `typecheck`

## How to shape `up`

Prefer this order:

1. `instructions`
2. `services`
3. `dependencies`
4. `build`
5. `steps`
6. `serve`

Use each section like this:

### `instructions`

Use for manual prerequisites the CLI cannot or should not enforce.

Examples:

- Install PostgreSQL locally.
- Start Docker Desktop.
- Copy `.env.example` to `.env`.
- Authenticate with AWS or another external service.

### `services`

Use for tracked dependency services that must be started before setup or build runs.

Examples:

- `mysql`
- `redis`
- `run: docker compose up mysql`

### `dependencies`

Use for package installation and similar prerequisites.

Examples:

- `bundle install`
- `yarn install`
- `npm install`
- `go mod download`

### `build`

Use for app preparation steps.

Examples:

- `build`
- `bin/rails db:prepare`
- `npm run build`

### `steps`

Use sparingly for additional setup that is not quite dependencies or build.

Examples:

- `run: bin/rails db:seed`
- `command: db`
  `args: [reset]`

### `serve`

This should list additional tracked background services that should start after setup completes.

Usually these are things like:

- `worker`
- `redis-server`
- `bin/rails tailwindcss:watch`

## Recommended defaults by stack

### Rails

```yml
env:
  BUNDLE_WITHOUT: production

up:
  instructions:
    - Install PostgreSQL and Redis if required by the app.
  services:
    - redis
  dependencies:
    - bundle install
    - yarn install
  build:
    - build
  serve: worker

build: bin/setup
server: bin/rails server
console: bin/rails console
test: bin/rails test

commands:
  redis:
    run: redis-server
  worker:
    run: bundle exec sidekiq
```

### Node app

```yml
up:
  services:
    - run: docker compose up -d db
  dependencies:
    - npm install
  serve:
    - run: npm run vite -- --host

server: npm run dev
build: npm run build
test: npm test
style: npm run lint
```

### Python app

```yml
up:
  instructions:
    - Create and activate the expected virtualenv if the repo does not manage it automatically.
  services:
    - run: docker compose up -d postgres
  dependencies:
    - pip install -r requirements.txt
  serve:
    - run: celery -A app worker -l info

server: python manage.py runserver
test: pytest
style: ruff check .
```

## What to avoid

- Do not add every possible script from the repo.
- Do not inline large shell programs unless the project already uses them that way.
- Do not put secret values in `env`.
- Do not make `up` start background services unless the project actually needs them for development.
- Do not add comments explaining obvious YAML.
- Do not create a config that contradicts the README or existing scripts.

## Output expectations

When asked to create `dev.yml` for a project:

1. Inspect the repo.
2. Infer the smallest correct config.
3. Write `dev.yml` in the project root.
4. Prefer named commands that can also be run directly with `dev <command>`.
5. If something is ambiguous, choose the simpler option unless the repo clearly indicates otherwise.

The best `dev.yml` is short, unsurprising, and built from commands the project already documents or uses.
