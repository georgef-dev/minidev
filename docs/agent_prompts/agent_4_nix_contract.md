# Agent 4 Prompt: Nix And Environment Contract

You are working in the `minidev` repository.

Your task is to write a design document only. Do not write production code.

## Context

`minidev` is becoming Nix-only. It should remain independent from `shadowenv`, but support it cleanly.

Read these files first:

- `README.md`
- `default.nix`
- `docs/architecture_nix_services.md`
- `docs/implementation_agents.md`
- relevant startup and command execution code under `lib/dev/`

## Task

Write `docs/internal/nix_contract.md`.

Define:

- what `minidev` assumes from a Nix-backed environment
- how projects should expose required binaries
- how `minidev` should discover or verify tool availability
- what optional `shadowenv` integration should look like
- what `dev doctor` should check

Include:

- examples of expected project setup
- examples with and without `shadowenv`
- failure scenarios and what users should do

## Constraints

- do not write code
- do not support non-Nix dependency management
- do not make `shadowenv` required
- keep the contract explicit and small

## Acceptance Criteria

Your document must make it clear:

- what binaries or environment guarantees `minidev` needs
- how `minidev` works without `shadowenv`
- what `dev doctor` should verify

Your final response should summarize the environment contract and the most important failure modes.
