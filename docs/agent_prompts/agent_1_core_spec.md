# Agent 1 Prompt: Core Spec

You are working in the `minidev` repository.

Your task is to write a design document only. Do not write production code.

## Context

`minidev` is evolving toward a Shopify-like local development model with these fixed decisions:

- Nix-only dependency management
- `minidev` remains independent from `shadowenv`
- `shadowenv` is optional and complementary
- one MySQL server per git worktree
- global mutable runtime state with an optional project-local `.dev` pointer
- ports are dynamically reserved and then persisted

Read these files first:

- `README.md`
- `docs/architecture_nix_services.md`
- `docs/implementation_agents.md`
- relevant files under `lib/dev/`

## Task

Write `docs/internal/instance_model.md`.

Define:

- instance identity inputs
- instance identity output shape
- how `instance_id` is derived
- global state directory layout
- project-local `.dev` pointer format
- state file schema and versioning approach
- resolved env model for commands and services

Include:

- concrete example JSON or YAML shapes
- invariants and rules
- notes on when state is written, read, refreshed, and cleaned up

## Constraints

- do not write code
- do not design for non-Nix environments
- do not make `shadowenv` required
- do not add a plugin system
- keep the model reusable across projects

## Acceptance Criteria

Your document must make it clear:

- how `instance_id` is derived
- where ports, logs, pid files, sockets, and datadirs live
- what state is persisted and when

Your final response should summarize the doc and call out any open questions that should be resolved before implementation.
