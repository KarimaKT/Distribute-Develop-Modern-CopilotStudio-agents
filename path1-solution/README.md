# Path 1 — Solution ZIP Distribution

Export and import a Modern Copilot Studio agent as a **distributable solution package**.

This is the recommended path for sharing agents across orgs, provisioning environments,
or distributing samples.

---

## What pac solution import handles (tested and verified)

| Component | Handled by solution import? |
|-----------|----------------------------|
| `bot.configuration` (instructions + model) | ✅ Yes — via `configuration.json` in ZIP |
| InlineAgentSkill (markdown knowledge) | ✅ Yes |
| ConnectorTool / McpTool | ✅ Yes |
| ConnectedAgentTool | ✅ Yes (child agent must exist by schema name) |
| WorkflowTool (Copilot Studio Workflows) | ✅ Yes — flow GUIDs preserved by solution import |
| TaskDialog / InvokeFlowTaskAction (Agent Flows) | ✅ Yes |
| Evaluation test cases | ✅ Yes |
| Connection reference stubs | ✅ Yes (created empty — user wires manually, normal behavior) |
| **Skills with binary assets (ZIP+Python)** | ❌ No — bundle blob not in ZIP; `install.ps1` handles it |

> **Key finding**: `AddRequiredComponents = $true` is **required** when adding a bot to a
> solution. Without it, botcomponents (tools, skills) are not included in the export.

---

## Prerequisites

- [pac CLI](https://aka.ms/PowerPlatformCLI)
- [az CLI](https://aka.ms/installazurecliwindows)
- `pac auth create` profile for source and target environments
- `az login` to a user with Dataverse access

---

## Export

```powershell
.\path1-solution\export.ps1 `
  -SourceOrgUrl "https://myorg.crm.dynamics.com" `
  -AgentName    "Fabric Analyst" `
  -BotId        "d01d7579-bf47-4da7-b751-22a419ade844"
```

**If the bot is already in a named solution:**
```powershell
.\path1-solution\export.ps1 `
  -SourceOrgUrl "https://myorg.crm.dynamics.com" `
  -AgentName    "Fabric Analyst" `
  -BotId        "d01d7579-bf47-4da7-b751-22a419ade844" `
  -SolutionName "FabricAnalystSample"
```

**Output:**
```
agent.zip             ← commit this
agent-config.json     ← commit this (documentation/verification)
skills-with-assets/   ← commit this IF present (binary skill bundles)
  manifest.json
  <skill-name>/
    <skill-name>.zip  ← the binary blob
```

---

## Install

```powershell
.\path1-solution\install.ps1 `
  -TargetOrgUrl "https://targetorg.crm.dynamics.com" `
  -ZipPath      ".\agent.zip"
```

The script auto-detects `skills-with-assets/` next to `agent.zip`.

---

## Post-import only (skip if using install.ps1)

If you ran `pac solution import` manually and only need to fix skill assets:

```powershell
.\path1-solution\post-import-skills.ps1 `
  -TargetOrgUrl "https://targetorg.crm.dynamics.com" `
  -BotId        "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -SkillsDir    ".\skills-with-assets"
```

---

## Manual step after install: Wire connections

Flows are in **Draft** state until connection references are wired. This is normal
Power Platform behavior — it is not a limitation of this toolkit.

1. PPAC → `<your env>` → Connections → New connection → create each required connector
2. Solutions → `<solution>` → Connection References → edit each → link to the connection
3. Flows activate automatically once all connections are wired

---

## Skills with assets — why the extra step?

When you upload a skill as a ZIP file (Python code, binary assets), Copilot Studio:
1. Stores a **bundle reference token** in the botcomponent `data` field: `bic:bundle=catskill_*_zip_*`
2. Stores the **binary blob** in a separate storage location — NOT in the Dataverse botcomponent record

`pac solution export` captures the botcomponent record but not the blob. After import,
the skill appears in the UI but its Python assets are missing. `install.ps1` (and
`post-import-skills.ps1`) fix this by re-uploading the blob as a type-14 child component.
