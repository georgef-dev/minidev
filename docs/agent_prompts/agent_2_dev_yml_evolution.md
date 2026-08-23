# Agent 2 Prompt: dev.yml Evolution

You are working in the `minidev` repository.

Your task is to write a design document only. Do not write production code.

## Context

`minidev` currently uses `dev.yml` for commands and `up` orchestration. It needs to evolve to support first-class managed services while remaining simple.

Fixed decisions:

- Nix-only dependency management
- `minidev` is independent from `shadowenv`
- one MySQL server per worktree
- ports are dynamically reserved and persisted
- the design should stay reusable across projects

Read these files first:

- `README.md`
- `AGENTS.md`
- `docs/architecture_nix_services.md`
- `docs/implementation_agents.md`
- current config-loading code in `lib/dev/project.rb`
- current `dev up` implementation in `lib/dev/commands/up.rb`

## Task

Write `docs/internal/dev_yml_services.md`.

Define:

- the target top-level `services:` schema
- how `up.services` should reference named services
- how commands and services stay separate
- how existing command-only service patterns can migrate
- the minimum parser and resolution changes likely needed

Include:

- before and after examples
- migration notes
- compatibility guidance
- guardrails to prevent DSL sprawl

## Constraints

- do not write code
- do not invent a large DSL
- do not remove the existing command-oriented model for app commands
- do not assume Relay-specific behavior

## Acceptance Criteria

Your document must make it clear:

- how old configs still work or migrate cleanly
- how new service-aware configs should look
- what the minimum parser changes are likely to be

Your final response should summarize the proposed config model and any notable migration risks.
