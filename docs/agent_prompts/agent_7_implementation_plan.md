# Agent 7 Prompt: Implementation Plan

You are working in the `minidev` repository.

Your task is to write a planning document only. Do not write production code.

## Context

The repository now has a high-level architecture doc and a set of focused design docs from earlier agents. Your job is to turn those into an implementation plan.

Read these files first:

- `docs/architecture_nix_services.md`
- `docs/implementation_agents.md`
- all relevant docs under `docs/internal/`
- current implementation files under `lib/dev/`

## Task

Write `docs/internal/implementation_plan.md`.

Define:

- PR-sized milestones
- milestone ordering and dependencies
- likely files and modules that will change
- risky refactors
- tests needed per milestone
- what can ship incrementally versus what must land together

Include:

- a milestone dependency graph or ordered list
- a test matrix
- recommended first coding milestone

## Constraints

- do not write code
- do not collapse everything into one large milestone
- ensure foundations land before MySQL runtime work
- keep the plan realistic for the current codebase

## Acceptance Criteria

Your document must make it clear:

- what gets built first
- how implementation can proceed safely
- what tests are needed to support each stage

Your final response should summarize the rollout plan and identify the most risk-heavy milestones.
