# Contributing

This toolkit is a starting point for the community. Contributions welcome!

## Read the spec first

[`SPEC.md`](SPEC.md) is the **source of truth** — purpose, audience, required behavior, assumptions,
decisions, known platform quirks, reliability guarantees, and the UX backlog. Two rules keep the
tool reliable across versions:

1. **Spec before big changes.** For any rewrite, redesign, or new path, update `SPEC.md` first
   (goal, the must-keep tested facts, what's out of scope), then change the code/docs to match, then
   verify the result against the spec.
2. **Critique the UX in every review.** Beyond "is it correct?", ask whether the tool can do a manual
   step *for* the user, work for *any* environment (no hardcoded tables/prefixes), and stay a
   one-command experience. Record UX ideas in `SPEC.md` §10 even if not built now.

## How to Contribute

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-improvement`)
3. Update `SPEC.md` if behavior changes
4. Make your changes
5. Run the scripts against a test environment
6. Submit a pull request

## Areas for Contribution

- Support for additional botcomponent types (e.g. richer knowledge-source editing)
- A VS Code task/extension wrapper that calls these scripts
- Multi-agent export (export all agents from an environment)
- CI/CD pipeline integration (GitHub Actions using `pac solution import`)
- Dry-run mode (`-WhatIf`) for all scripts
- An automated publish path (if/when a reliable cliagent publish API becomes available — today
  `pac copilot publish` crashes, so publish is a one-click CS UI step)

## Testing

Before submitting, verify your changes against a trial or developer Power Platform environment.
Both paths deploy via `pac solution import` plus Dataverse Web API writes — never `pac copilot
push` (it silently drops components for `cliagent-*` agents). See [LEARNINGS.md](LEARNINGS.md) §0.
After deploying, confirm in Dataverse (or the CS UI) that every expected component landed.
