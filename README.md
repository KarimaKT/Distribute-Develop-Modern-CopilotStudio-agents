# Distribute-Develop-Modern-CopilotStudio-agents

A toolkit for **Modern Copilot Studio agents** (`cliagent-*` template — instructions + tools, no topics; covers both **CGO** `GenerativeAIRecognizer` and **NGO** `CLICopilotRecognizer`).

> **Why this exists (pac CLI gap, June 2026):** for `cliagent-*` agents, `pac copilot pack` crashes, `pac copilot pull` crashes, `pac copilot push` silently drops components, and `pac copilot publish` crashes. So this toolkit does **not** rely on any of them. It deploys with the mechanisms that *are* reliable: **Dataverse solution import** (structure) and **targeted Dataverse writes** (your edits). See [LEARNINGS.md](LEARNINGS.md) for the evidence.

Two workflows:
- **distribute/** — package an agent as a ZIP, share it, install it into any environment.
- **develop/** — clone an agent to editable files, change it in VS Code, redeploy reliably.

---

## Prerequisites

| Tool | Install |
|------|---------|
| pac CLI | https://aka.ms/PowerPlatformCLI |
| az CLI | https://aka.ms/installazurecliwindows |
| pac auth | `pac auth create --environment https://yourorg.crm.dynamics.com` |
| az login | `az login` (needs Dataverse access) |

The **develop/** path also benefits from the [Power Platform Tools for VS Code](https://marketplace.visualstudio.com/items?itemName=microsoft-IsvExpTools.powerplatform-vscode) extension for YAML schema hints.

---

## develop/ — what you can change in VS Code vs. what needs the Copilot Studio UI

This is the most important thing to understand before editing an agent. The boundary is **wording/behaviour vs. structure**, and the scripts state it at every step.

| You want to… | Where | How it deploys |
|---|---|---|
| Change the agent's **instructions** (system prompt, rules, persona) | ✅ **VS Code** — edit `sample/<Agent>.instructions.md` | `develop/install.ps1` → Dataverse `bot.configuration` |
| Change the **model** or **AI settings** (content moderation, model knowledge…) | ✅ **VS Code** — edit `sample/agent-config.json` | `develop/install.ps1` → Dataverse `bot.configuration` |
| Edit an **inline (markdown) skill's** content | ✅ **VS Code** — edit `sample/<Agent>/translations/*.skill.*.mcs.yml` | `develop/install.ps1` → component `data` patch |
| Reword a **tool / knowledge description** | ✅ **VS Code** — edit the matching `translations/` or `knowledge/` file | `develop/install.ps1` → component `data` patch |
| **Add / remove** a tool, connector, or flow | ⚠️ **Copilot Studio UI** (needs connection wiring / Power Automate) | Build it in CS, then re-run `develop/export.ps1` |
| **Add** a skill that runs Python / code | ⚠️ **Copilot Studio UI** (server-side code-bundle upload — no API) | Upload the skill ZIP in CS (the script hands you the ZIP) |
| **Add** file knowledge (PDF, DOCX) | ⚠️ **Copilot Studio UI** (binary upload gateway) | Upload in CS, then re-export |
| **Publish** changes to go live on channels | ⚠️ **Copilot Studio UI** — one click ( `pac copilot publish` crashes for cliagent-*) | Click **Publish**; the script opens the agent for you |

**Rule of thumb:** editing the *words and behaviour* of things that already exist → VS Code. Adding *new structure* or anything needing a connection or a binary upload → Copilot Studio UI, then re-export. Every deploy ends with a one-click **Publish**.

The cloned YAML in `sample/<Agent>/` is always useful for reading, diffing, and code review — even for the structural parts you can't push from the CLI.

---

## Component support matrix

| Component | distribute/ | develop/ | Notes |
|-----------|:-----------:|:--------:|-------|
| Agent instructions + model (bot.configuration) | ✅ | ✅ | Editable + deployed (develop/: from instructions.md / agent-config.json) |
| ConnectorTools (standard MS connectors) | ✅ | ✅ | Structure via solution import; connection wiring is one manual step per env |
| WorkflowTool / TaskDialog (Agent Flows) | ✅ | ✅ | Carried in the solution bundle (GUIDs preserved) |
| InlineAgentSkill (markdown skill) | ✅ | ✅ | Full round-trip; **content editable in VS Code** and deployed |
| Tool / knowledge descriptions | ✅ | ✅ | **Editable in VS Code** and deployed (component data patch) |
| Skill with Python/code assets | ⚠️ manual | ⚠️ manual | Re-upload the skill ZIP via the CS UI (one step per env) — see note below |
| URL knowledge sources | ✅ | ✅ | Full round-trip |
| File knowledge (PDF, DOCX) | ✅ | ✅ | Carried in the solution bundle (binary preserved) |
| Evaluation test cases | ✅ | ✅ | Carried in the solution bundle |
| ConnectedAgentTool | ✅ | ✅ | Child agent must exist in target by the same schema name |
| Add **new** tools / connectors / flows from local YAML | ❌ | ❌ | Build in the CS UI, then re-export (no reliable CLI push for cliagent-*) |
| **Custom connectors with inline code** | ❌ | ❌ | Azure Functions provisioning is unreliable — platform issue |
| **MCP server tools** | ⚠️ | ⚠️ | Tool definition transfers; server must be reachable at the same URL in target |
| Classic agents (default-2.x.x template) | ❌ | ❌ | Different architecture — use standard pac solution tooling |

> **Why skills with code require a manual upload step:**
> When you upload a skill ZIP through the Copilot Studio UI, CS runs a server-side process that stores the binary assets (Python scripts etc.) in Azure blob storage and generates an environment-specific bundle reference token. After import, the skill's `data` field is only a `bic:bundle=` pointer to the **source** environment's blob — so until you re-upload, the model can read **neither the instructions nor the code** (the pointer 404s in the target). There is no public API for the upload process — it happens inside CS's own backend. The install script detects the broken skill, rebuilds the ZIP, and points you to the exact place to upload it. This is a one-time step per environment.
>
> The scripts deliberately do **not** silently rewrite the skill to inline markdown. That would make the skill *look* fixed while it still cannot execute its code — a silent degradation. Honest-broken-until-uploaded is the chosen behavior.




## Get started

### Identify your agent

Both scripts require your agent's **BotId** — the GUID in the Copilot Studio URL:  
`https://copilotstudio.microsoft.com/environments/{envId}/agents/{BotId}`

Your agent must use the `cliagent-*` template (visible in PPAC → agent record). Classic agents (`default-2.x.x`) are not supported.

---

### distribute/ — Share an agent as a ZIP

**Export** (run once to produce a shareable bundle):
```powershell
.\distribute\export.ps1 `
  -SourceOrgUrl "https://yourorg.crm.dynamics.com" `
  -BotId        "your-bot-guid" `
  -SolutionName "MyAgentSample" `
  -PublisherName "YourPublisher"
# Produces: MyAgent-bundle.zip
```

**Install** (anyone can run this against their own environment):
```powershell
.\distribute\install.ps1 `
  -BundleZip    ".\MyAgent-bundle.zip" `
  -TargetOrgUrl "https://targetorg.crm.dynamics.com"
# Agent appears in Copilot Studio. Wire connections in PPAC when prompted.
```

After install: wire connections for any ConnectorTool flows in PPAC → Power Automate.

---

### develop/ — Clone an agent, edit in VS Code, redeploy

**Export** (clone to editable files + build a deployable bundle):
```powershell
.\develop\export.ps1 `
  -SourceOrgUrl  "https://yourorg.crm.dynamics.com" `
  -BotId         "your-bot-guid" `
  -AgentName     "My Agent" `
  -SolutionName  "MyAgentSample" `
  -PublisherName "myprefix"          # publisher unique name OR customization prefix
# Produces:
#   sample/My Agent/                 editable YAML (read / diff / review)
#   sample/My Agent.instructions.md  the instructions — edit this to change behaviour
#   sample/agent-config.json         model + AI settings
#   My Agent-bundle.zip              the deployable artifact
```

**Edit** (see the VS Code vs UI table above):
- `sample/My Agent.instructions.md` — instructions (deploys)
- `sample/agent-config.json` — model + AI settings (deploys)
- `sample/My Agent/translations/*.skill.*.mcs.yml` — inline skill content (deploys)

**Deploy** to any environment:
```powershell
.\develop\install.ps1 `
  -BundleZip     ".\My Agent-bundle.zip" `
  -TargetOrgUrl  "https://targetorg.crm.dynamics.com"
# Solution import (full structure) + applies your instruction/skill edits via Dataverse.
# No pac push. Ends by opening the agent for the one-click Publish.
```

After deploy: wire any connector flows in Power Automate (one-time per env), then **Publish** in Copilot Studio.

---

## Repo structure

```
distribute/
  export.ps1    ← export agent → {AgentName}-bundle.zip (surgical solution add + skill assets)
  install.ps1   ← pac solution import + skill re-upload guidance + connection wiring

develop/
  export.ps1    ← pac clone (editable YAML) + instructions.md + agent-config.json + deployable bundle
  install.ps1   ← pac solution import + apply instruction/skill edits via Dataverse + Publish guidance

LEARNINGS.md    ← tested findings, pac CLI gap analysis, known bugs, the component-type enum trap
CONTRIBUTING.md ← how to contribute
SECURITY.md / SUPPORT.md / CODE_OF_CONDUCT.md
```

---

See [LEARNINGS.md](LEARNINGS.md) for technical details: the reliable-vs-unreliable pac commands, the Default Solution membership problem, the solutioncomponent enum trap, and skills-with-assets.
