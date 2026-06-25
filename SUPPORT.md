# Support

This project is a **community-maintained, best-effort** toolkit. It is not an official Microsoft
product and comes with no SLA.

## How to get help

- **Questions / usage help:** open a [GitHub Discussion](https://github.com/KarimaKT/Distribute-Develop-Modern-CopilotStudio-agents/discussions) or an issue with the `question` label.
- **Bugs in these scripts:** open a [GitHub Issue](https://github.com/KarimaKT/Distribute-Develop-Modern-CopilotStudio-agents/issues). Please include:
  - which script and parameters you ran,
  - the console output (redact org URLs / tokens),
  - your `pac` version (`pac help`) and whether the agent is `cliagent-*`.
- **Feature ideas / contributions:** see [CONTRIBUTING.md](CONTRIBUTING.md).

## What is NOT supported here

- Bugs in the Power Platform CLI (`pac`) or in Copilot Studio itself — report those to Microsoft.
- Classic agents (`default-2.x.x` template). This toolkit targets Modern (`cliagent-*`) agents only.

## Known platform limitations (by design, not bugs in this toolkit)

- `pac copilot push` / `publish` / `pack` / `pull` are unreliable for `cliagent-*` agents — this
  toolkit deliberately avoids them. See [LEARNINGS.md](LEARNINGS.md).
- Adding new tools/connectors/flows, skills with code, and file knowledge must be done in the
  Copilot Studio UI, then re-exported. See the README's VS Code vs UI table.
