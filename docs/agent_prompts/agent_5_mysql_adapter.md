# Agent 5 Prompt: MySQL Adapter Detailed Design

You are working in the `minidev` repository.

Your task is to write a design document only. Do not write production code.

## Context

`minidev` will manage one MySQL server per git worktree using binaries provided by Nix.

Fixed decisions:

- Nix-only dependency management
- one MySQL server per worktree
- dynamically reserved and persisted ports
- global instance state with optional project-local pointer
- `minidev` is independent from `shadowenv`

Read these files first:

- `docs/architecture_nix_services.md`
- `docs/implementation_agents.md`
- any existing internal docs produced by Agents 1, 3, and 4 if present
- current process management code under `lib/dev/`

## Task

Write `docs/internal/mysql_service.md`.

Define:

- MySQL service config fields
- datadir initialization flow
- port reservation and persistence behavior
- socket, config, pid, and log path layout
- startup sequence
- readiness checks
- shutdown behavior
- reset behavior
- app and test database creation flow
- exact env vars exposed to applications

Include:

- normal startup sequence
- recovery paths for partial initialization or stale state
- notes on what should be persisted versus recomputed

## Constraints

- do not write code
- do not assume Docker
- do not design shared-MySQL-across-worktrees mode
- keep the design implementable in the current Ruby codebase

## Acceptance Criteria

Your document must make it clear:

- how one worktree gets one MySQL server
- what state MySQL needs in order to restart cleanly
- how ports are chosen and retained
- what environment the app receives

Your final response should summarize the adapter behavior and call out the highest-risk implementation details.
