# Contributing

This toolkit is a starting point for the community. Contributions welcome!

## How to Contribute

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-improvement`)
3. Make your changes
4. Run the scripts against a test environment
5. Submit a pull request

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
