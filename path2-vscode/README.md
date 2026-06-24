# Path 2 — VS Code Developer Workflow

Clone a Modern Copilot Studio agent to YAML, edit it in VS Code, and deploy changes
back to any environment.

---

## What pac push handles vs. what this scripts fix

| Capability | pac push alone | install.ps1 |
|------------|---------------|-------------|
| ConnectorTool / McpTool | ✅ | ✅ |
| InlineAgentSkill (markdown) | ✅ | ✅ |
| ConnectedAgentTool | ✅ (by schema name) | ✅ |
| URL knowledge sources | ✅ | ✅ |
| Connection reference stubs | ✅ | ✅ |
| **Bot pre-creation** | ❌ (fails if bot doesn't exist) | ✅ creates it |
| **bot.configuration** (instructions + model) | ❌ not written by pac push | ✅ PATCHed after push |
| **WorkflowTool flow GUIDs** | ❌ source GUIDs don't exist in target | ✅ strips + remaps |
| **TaskDialog/AgentFlow GUIDs** | ❌ same problem | ✅ strips + remaps |

---

## Prerequisites

- [pac CLI](https://aka.ms/PowerPlatformCLI)
- [az CLI](https://aka.ms/installazurecliwindows)
- `pac auth create` profile for source and target environments
- `az login` to a user with Dataverse write access
- VS Code with [Power Platform Tools](https://marketplace.visualstudio.com/items?itemName=microsoft-IsvExpTools.powerplatform-vscode)

---

## Export (clone to source control)

```powershell
.\path2-vscode\export.ps1 `
  -SourceOrgUrl "https://myorg.crm.dynamics.com" `
  -AgentName    "Fabric Analyst" `
  -BotId        "d01d7579-bf47-4da7-b751-22a419ade844"
```

**Output:**
```
sample/
  Fabric Analyst/
    agent.mcs.yml
    settings.mcs.yml
    connectionreferences.mcs.yml
    translations/           ← ConnectorTool, McpTool, WorkflowTool, InlineAgentSkill
    actions/                ← TaskDialog / InvokeFlowTaskAction (Agent Flows)
    workflows/              ← Flow definitions (one folder per flow)
    knowledge/              ← URL knowledge sources
  agent-config.json         ← Authoritative bot.configuration (instructions + model)
```

---

## Edit in VS Code

All agent YAML is plain text. VS Code with the Power Platform Tools extension gives you:
- Syntax highlighting on `*.mcs.yml` files
- Schema validation (configured in `.vscode/settings.json`)
- pac CLI integration (auth, push, clone)

**Key files to edit:**

| File | What it controls |
|------|-----------------|
| `settings.mcs.yml` | Agent name, description, language |
| `translations/*.tool.*.mcs.yml` | Tool definitions (ConnectorTool, WorkflowTool, McpTool) |
| `translations/*.skill.*.mcs.yml` | InlineAgentSkill knowledge content |
| `actions/*.mcs.yml` | Agent Flow (TaskDialog) tool actions |
| `knowledge/*.mcs.yml` | URL knowledge sources |
| `sample/agent-config.json` | Instructions text, AI model — edit here for install.ps1 to pick up |

> **Instructions**: Edit `agent-config.json` (not `settings.mcs.yml`). `install.ps1`
> PATCHes `bot.configuration` from this file, which is what Copilot Studio reads.

---

## Install (push to target environment)

```powershell
.\path2-vscode\install.ps1 `
  -TargetOrgUrl    "https://targetorg.crm.dynamics.com" `
  -AgentName       "Fabric Analyst" `
  -AgentSchemaName "cr7a0_FabricAnalyst_dQTqzr"
```

Find `AgentSchemaName` in `settings.mcs.yml` → `schemaName:` field.

---

## Understanding flow tool YAML

### WorkflowTool (Copilot Studio Workflows)
File: `translations/<schema>.tool.<name>.mcs.yml`

```yaml
kind: WorkflowTool
workflowId: d01d7579-bf47-4da7-b751-22a419ade844   ← source-env GUID, stripped before push
name: My Workflow Tool
...
```

### TaskDialog / InvokeFlowTaskAction (Agent Flows)
File: `actions/<name>.mcs.yml`

```yaml
kind: TaskDialog
action:
  kind: InvokeFlowTaskAction
  flowId: e12a4b89-...                             ← source-env GUID, stripped before push
```

`install.ps1` strips these GUIDs, does a first push, creates the flows in the target
via `POST /api/data/v9.2/workflows`, patches the new GUIDs back in, then pushes again.

---

## Manual step after install: Wire connections

```
1. PPAC → <your env> → Connections → New connection → sign in for each connector
2. Default Solution → Connection References → Edit each → link to the new connection
3. Flows activate automatically once all connections are wired
```

This is standard Power Platform behavior, not a limitation of this toolkit.

---

## Workspace files

`install.ps1` creates `_workspace_<timestamp>/` during deployment. These are gitignored.
Safe to delete after confirming the install succeeded.
