# Agent 6 Prompt: Command UX And Introspection

You are working in the `minidev` repository.

Your task is to write a design document only. Do not write production code.

## Context

`minidev` needs user-facing commands for inspecting, debugging, and resetting managed services and instance state.

Fixed decisions:

- Nix-only dependency management
- `minidev` remains independent from `shadowenv`
- one MySQL server per worktree
- dynamic persisted allocations

Read these files first:

- `README.md`
- `docs/architecture_nix_services.md`
- `docs/implementation_agents.md`
- current command files under `lib/dev/commands/`
- any internal docs produced by earlier agents if present

## Task

Write `docs/internal/command_ux.md`.

Define behavior for:

- `dev status`
- `dev logs [service]`
- `dev reset [service]`
- `dev env`
- improved `dev ps`
- stale-state cleanup behavior

Include:

- example CLI output
- error message guidance
- how commands should behave when services are missing, stale, or partially started

## Constraints

- do not write code
- do not create overlapping command semantics
- keep outputs concise and useful
- keep the model instance-aware and service-aware

## Acceptance Criteria

Your document must make it clear:

- how a developer inspects the current instance
- how a developer finds logs and resolved env
- how a developer recovers from bad local state

Your final response should summarize the UX model and point out any command naming collisions or awkward areas.
