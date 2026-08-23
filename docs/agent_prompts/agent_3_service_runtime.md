# Agent 3 Prompt: Service Runtime Architecture

You are working in the `minidev` repository.

Your task is to write a design document only. Do not write production code.

## Context

`minidev` already has command execution and tracked process management. It now needs a small internal service runtime architecture that can support generic processes and typed services like MySQL.

Fixed decisions:

- Nix-only dependency management
- `minidev` remains independent from `shadowenv`
- one MySQL server per worktree
- ports are dynamically reserved and persisted
- no broad plugin system yet

Read these files first:

- `README.md`
- `docs/architecture_nix_services.md`
- `docs/implementation_agents.md`
- `lib/dev/process_manager.rb`
- `lib/dev/commands/up.rb`
- `lib/dev/project.rb`

## Task

Write `docs/internal/service_runtime.md`.

Define:

- the internal service concepts and boundaries
- how generic `process` services differ from typed services
- proposed Ruby class or module responsibilities
- service lifecycle phases: resolve, prepare, start, healthcheck, stop, reset
- how service state is persisted
- how resolved service env is exposed to project commands

Include:

- proposed class and module layout
- lifecycle step lists or diagrams
- notes on how current process tracking can evolve rather than be replaced

## Constraints

- do not write code
- do not design a plugin framework
- do not collapse MySQL into raw shell commands
- keep the design small and implementable

## Acceptance Criteria

Your document must make it clear:

- where generic process behavior ends
- where typed service behavior begins
- where MySQL-specific logic should live
- how service env reaches project commands

Your final response should summarize the proposed runtime architecture and any risky refactors.
