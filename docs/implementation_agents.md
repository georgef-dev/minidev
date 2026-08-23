# Minidev Implementation Agents

This document breaks the Nix and managed-services architecture work into parallelizable design tasks.

These agents are intended to produce design and planning documents only. They should not write production code yet.

## Execution Order

1. Run Agent 1 first.
2. Run Agents 2, 3, and 4 after Agent 1 completes.
3. Run Agents 5 and 6 after the earlier design docs exist.
4. Run Agent 7 last.

## Shared Constraints

All agents should follow these constraints:

- do not write production code
- do not design for non-Nix dependency management
- do not make `shadowenv` required
- do not introduce a broad plugin system
- do not collapse MySQL into a generic shell-command-only model
- keep the design reusable across projects, not tailored to `relay`

## Agent 1: Core Spec

Purpose:

- lock the internal model before implementation starts

Scope:

- define instance identity inputs and output shape
- define global state directory layout
- define local `.dev` pointer format
- define state file schema and versioning
- define resolved env model

Deliverable:

- a short spec doc
- example instance state JSON or YAML shapes
- explicit invariants

Acceptance criteria:

- clear answer for how `instance_id` is derived
- clear answer for where ports, logs, pid files, sockets, and datadirs live
- clear answer for what state is persisted and when

Suggested output path:

- `docs/internal/instance_model.md`

Prompt file:

- `docs/agent_prompts/agent_1_core_spec.md`

## Agent 2: `dev.yml` Evolution

Purpose:

- design config changes without breaking current users

Scope:

- propose top-level `services:` schema
- define how `up.services` references named services
- define migration path from command-only service setups
- identify the minimum parser changes needed

Deliverable:

- config spec
- before and after examples
- migration notes

Acceptance criteria:

- old command-only configs still have a compatibility story
- new service-aware configs are simpler for managed services
- no unnecessary DSL growth

Suggested output path:

- `docs/internal/dev_yml_services.md`

Prompt file:

- `docs/agent_prompts/agent_2_dev_yml_evolution.md`

## Agent 3: Service Runtime Architecture

Purpose:

- define the internal Ruby objects and boundaries

Scope:

- design `Service`, `ServiceRegistry`, and state persistence boundaries
- define service lifecycle phases: resolve, prepare, start, healthcheck, stop, reset
- define generic `process` service behavior
- define how services expose resolved env to commands

Deliverable:

- implementation design
- proposed Ruby class or module layout
- lifecycle diagrams or step lists

Acceptance criteria:

- clear boundary between generic process management and typed services
- clear place for MySQL-specific logic
- no plugin system required yet

Suggested output path:

- `docs/internal/service_runtime.md`

Prompt file:

- `docs/agent_prompts/agent_3_service_runtime.md`

## Agent 4: Nix And Environment Contract

Purpose:

- define exactly what `minidev` assumes from Nix

Scope:

- define the Nix-only support contract
- define required binaries and discovery rules
- define optional `shadowenv` integration points
- define `dev doctor` checks

Deliverable:

- environment contract doc
- list of required checks for `dev doctor`
- examples for projects using Nix with and without `shadowenv`

Acceptance criteria:

- `minidev` works without `shadowenv`
- Nix expectations are explicit
- failure cases are documented clearly

Suggested output path:

- `docs/internal/nix_contract.md`

Prompt file:

- `docs/agent_prompts/agent_4_nix_contract.md`

## Agent 5: MySQL Adapter Detailed Design

Purpose:

- turn MySQL from concept into implementable behavior

Scope:

- define MySQL service config fields
- define datadir init flow
- define dynamic port reservation and persistence
- define socket, config, and log paths
- define readiness checks
- define shutdown and reset behavior
- define database creation flow for app and test DBs

Deliverable:

- detailed MySQL adapter spec
- startup and shutdown sequence
- failure and recovery behavior

Acceptance criteria:

- one MySQL server per worktree is fully specified
- all persisted state required by MySQL is enumerated
- env vars exposed to apps are defined exactly

Suggested output path:

- `docs/internal/mysql_service.md`

Prompt file:

- `docs/agent_prompts/agent_5_mysql_adapter.md`

## Agent 6: Command UX And Introspection

Purpose:

- specify the user-facing commands needed for operability

Scope:

- define behavior for `dev status`
- define behavior for `dev logs [service]`
- define behavior for `dev reset [service]`
- define behavior for `dev env`
- define improved `dev ps` output
- define stale-state cleanup behavior

Deliverable:

- command specs
- example CLI output
- error message guidelines

Acceptance criteria:

- a developer can inspect and recover a broken local instance
- command semantics are clear and non-overlapping
- outputs are instance-aware and service-aware

Suggested output path:

- `docs/internal/command_ux.md`

Prompt file:

- `docs/agent_prompts/agent_6_command_ux.md`

## Agent 7: Implementation Plan

Purpose:

- convert all design outputs into coding phases

Scope:

- break implementation into PR-sized milestones
- identify file-level changes likely needed in `lib/dev/**`
- identify risky refactors
- define test plan by milestone

Deliverable:

- execution plan
- milestone dependency graph
- test matrix

Acceptance criteria:

- each milestone is independently shippable
- foundation lands before MySQL runtime work
- test coverage expectations are explicit

Suggested output path:

- `docs/internal/implementation_plan.md`

Prompt file:

- `docs/agent_prompts/agent_7_implementation_plan.md`

## Suggested Parallelization

Run first:

- Agent 1

Then in parallel:

- Agent 2
- Agent 3
- Agent 4

Then:

- Agent 5
- Agent 6

Finally:

- Agent 7

## First Coding Milestone After Design

Once the design docs are complete, the first coding milestone should be:

1. add instance identity
2. add global instance state directory
3. add persisted allocations
4. preserve existing `dev up`, `dev down`, and `dev ps`
5. do not add the MySQL adapter yet
