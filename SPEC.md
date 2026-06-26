# Specification — Distribute-Develop-Modern-CopilotStudio-agents

> This is the **source of truth** for the project. Update it **before** changing behavior or docs.
> It records what the tool does, why, what we assume, what we've proven, what we've decided, and
> what we still want to improve. Keep it accurate across versions so the tool stays reliable.
>
> **Spec version:** 1.0 · **Last updated:** 2026-06-26 · **Status of tool:** released (v1)

---

## 1. Purpose & audience

### 1.1 One-line purpose
Package a modern Copilot Studio agent into a single file and install it into any Power Platform
environment with one command.

### 1.2 Who it's for
**Low-code makers** — people who build agents in Copilot Studio and want to grab a working sample,
move an agent between environments, or share one for others to explore. **Not** primarily coders.
Many users won't know there are two kinds of Copilot Studio agent; the tool and its docs must not
assume that knowledge.

### 1.3 The problem it solves
Copilot Studio has two agent styles:
- **Modern** — built from instructions + tools + knowledge (most agents today).
- **Classic** — older, topic-based.

Microsoft's built-in solution export/import, the older Copilot Studio agent packaging commands, and
the VS Code Power Platform extension were designed around **classic** agents. They do not move a
**modern** agent cleanly between environments — components are dropped, GUIDs collide, or the deploy
crashes. This tool fills that gap so a modern agent travels in one piece.

### 1.4 Success criteria
1. A maker can package a modern agent with one command and install it elsewhere with one command.
2. The install never reports false success — if something didn't land, it says so and why.
3. After install, the user is told the **exact** finishing steps for **their** agent, in plain
   language, and only the steps that apply.
4. Works for **any** maker in **any** environment — no hardcoded tables, prefixes, or assumptions.

---

## 2. Audience & writing rules (for all user-facing docs)

1. **No jargon at the top.** Never use `CGO`, `NGO`, `cliagent-*`, `GenerativeAIRecognizer`,
   `CLICopilotRecognizer`, `WorkflowTool`, `InlineAgentSkill`, `bic:bundle=`, or component-type
   numbers in the README intro/quickstart. Those live in §8 and in `LEARNINGS.md` only.
2. **Plain agent-type words:** modern = instructions + tools + knowledge; classic = topic-based.
3. **Structure:** one-sentence purpose → short plain "why" → quickstart. Lead with **distribution**
   (share/install a sample), then **develop** (edit), then a short technical note linking to
   `LEARNINGS.md`. Emphasize **one command**.
4. **Voice:** warm, helpful, low-code. Use plain part names: "agent flows (Power Automate)",
   "skills", "skills with a code file", "knowledge web links", "knowledge files (PDF/Word)",
   "test cases".
5. **Keep tested accuracy**, but say it in maker language. Exact technical names belong in
   `LEARNINGS.md`.

---

## 3. Scope

### 3.1 In scope
- Export a modern Copilot Studio agent as a self-contained bundle (`distribute/`).
- Install that bundle into any environment, with honest post-install guidance (`distribute/`).
- Clone an agent to editable files, edit locally, and redeploy reliably (`develop/`).
- **Self-contained samples:** when an agent's flows depend on a **custom** Dataverse table, bundle
  the table definition + one seed row so install recreates a working sample automatically (§4.5).
- Detect and clearly report conditions the maker must resolve (other missing dependencies, skills
  with a code file, flows needing a connection, publish).

### 4.5 Self-contained table dependencies (custom Dataverse tables)
**Problem:** a flow that reads/writes a **custom** table (e.g. `cr1a2_orders`) makes the agent
depend on that table existing in the target. Without it, solution import fails.

**Behavior (tested mechanism — see §11):**
- **export** (both paths, in `distribute/export.ps1`):
  1. Detect custom-table references in each flow's `clientdata` — `"entityName":"<set or logical>"`
     and entity-set URL refs. Map each to its `EntityDefinitions` record; **keep only the maker's own
     tables: `IsCustomEntity = true` AND `IsManaged = false`** (Microsoft platform tables such as
     `msdyn_*`/AI Builder report `IsCustomEntity=true` but `IsManaged=true` and already exist in the
     target — never bundle those; system/standard tables are skipped too).
  2. Add each custom table's **Entity** to the solution: `AddSolutionComponent ComponentType=1
     AddRequiredComponents=$true` (pulls the table's columns + choice sets). Import will recreate it.
  3. Export **one** seed row per table to `seed-data/<logical>.json` — only the table's own custom
     columns (those starting with the table's publisher prefix), excluding the primary-id and all
     system/navigation fields. Record each table in `manifest.json` under `seedTables`
     (`logical`, `setName`, `primaryName`).
- **install** (both paths): after a verified solution import, for each `seedTables` entry, if the
  target table currently has **zero rows**, insert the one seed row. This is **best-effort and
  non-fatal** — a failed seed insert warns but never aborts (the table and agent still installed).

**Why one seed row:** enough for the agent to have realistic sample data to operate on, without
shipping someone else's full dataset. Makers can add their own data afterward.

**Assumptions:** A8 (below). **Decision:** D9 (below). **Backlog U1 is now resolved by this.**

### 4.6 (was 4.5) the rest of the path behaviors continue below


### 3.2 Out of scope (today)
- Classic (topic-based) agents — use standard Power Platform solution tooling.
- Creating agents from scratch.
- Adding **new** structural components (tools/flows/connectors/file-knowledge/code-skills) from
  local files — these are authored in Copilot Studio, then re-exported (platform limitation, §8).
- Automatic publishing (the platform's CLI publish is unreliable for modern agents — §8).

---

## 4. The two paths — required behavior

### 4.1 distribute/export.ps1 — package an agent into one bundle
**Interface:** `-SourceOrgUrl -BotId -SolutionName -PublisherName [-OutputDir=. -AuthIndex=1 -PacExe]`

**Must do, in order:**
1. Acquire a Dataverse token (az).
2. **Validate** the agent is modern (`template -like "cliagent-*"`); warn if no `agentSettings`;
   warn on custom topics. Reject classic with a clear message.
3. Find or create the distribution solution. **Resolve publisher by unique name OR customization
   prefix** (makers know the prefix).
4. **Surgically** add the agent's whole component graph to the solution: bot, all botcomponents
   (incl. file children of code-skills), flows, connection references — using a **candidate
   component-type list** per kind so it works across platform versions (§8.2). Never swallow the
   error silently.
5. **Verification net:** count solution components; abort if fewer than expected.
6. `pac solution export` the solution to `agent.zip`.
7. **ZIP sanity check:** the exported zip must contain `bots/*/bot.xml`; abort if not.
8. Download code-skill binary assets (the `.py`/`SKILL.md` files) to `skills-with-assets/`.
9. Write `manifest.json` (agent name, schema, template, `skillsWithAssets`, `connectorsRequired`).
10. Bundle `agent.zip` + `manifest.json` + `skills-with-assets/` into `{AgentName}-bundle.zip`
    using clean .NET zip (no Compress-Archive warnings); remove the loose files.

**Output:** a single `{AgentName}-bundle.zip`.

### 4.2 distribute/install.ps1 — install a bundle anywhere
**Interface:** `[-BundleZip] [-BundleDir] -TargetOrgUrl [-AuthIndex=1 -PacExe]`

**Must do, in order:**
1. Resolve and validate the bundle (`agent.zip` + `manifest.json` present).
2. `pac solution import`. **Do not trust pac's exit code** — it can print a FAILURE and still
   return 0 (§8.3). Capture output, scan for failure markers, **and verify the bot exists in
   Dataverse by schema name**. If either fails, stop loudly with the cause (e.g. a missing
   Dataverse table a flow needs) and how to fix it.
3. **Skills with a code file:** detect type-9 components whose data contains `bic:bundle=`; rebuild
   the upload `.zip` from `skills-with-assets/`; instruct a one-time CS UI re-upload. Never silently
   rewrite to inline (§8.4).
4. **Connections / flows:** read `connectorsRequired`; tell the user the flows imported already
   linked but arrive off with no connection — activate = add a connection + turn on.
5. **Resolve the real environment GUID** (via `pac env list`) for a working Copilot Studio link.
6. Summary that reflects only the steps that actually apply.

### 4.3 develop/export.ps1 — clone to editable files + build the bundle
**Interface:** `-SourceOrgUrl -BotId -AgentName -SolutionName -PublisherName [-OutputDir -AuthIndex=1 -PacExe]`

**Must do:**
1. Validate modern agent.
2. `pac copilot clone` → editable YAML under `sample/<AgentName>/` (for reading, diffing, review).
3. Call `distribute/export.ps1` to build the **deployable bundle** (the reliable artifact).
4. Write `sample/agent-config.json` (authoritative model + AI settings + instructions).
5. Write `sample/<AgentName>.instructions.md` (friendly editable instructions surface).
6. Summary states clearly what is editable-in-files-and-deploys vs what needs Copilot Studio.

### 4.4 develop/install.ps1 — install the bundle and apply file edits
**Interface:** `-BundleZip [-SampleDir] [-AgentName] -TargetOrgUrl [-AuthIndex=1 -PacExe]`

**Must do, in order:**
1. `pac solution import` with the **same failure detection** as 4.2 step 2.
2. Apply **instruction + model** edits via `bot.configuration` PATCH. Instructions from
   `instructions.md` are applied **only when the agent has a single static instruction segment**;
   multi/dynamic-segment agents fall back to `agent-config.json` (don't drop dynamic segments).
3. Apply **inline-skill content** edits (component `data` PATCH) and **tool/skill description**
   edits (component `description` column PATCH — descriptions are NOT in `data`, §8.5). Skip
   code-file skills (`bic:bundle=`) — those go through the re-upload path.
4. Code-file skills: rebuild zip + guide re-upload.
5. Flows: activate guidance. 6. Publish guidance (one-click; CLI publish crashes, §8).
**Never uses `pac copilot push`** (it silently drops components, §8.1).

---

## 5. What moves with an agent (component support)

Legend: ✅ transfers · ⚠️ transfers + one manual step · ❌ not supported ·
**T** tested in this project · **R** reasoned from platform behavior, not yet tested here.

| Part | Status | T/R | Notes |
|---|:---:|:---:|---|
| Instructions + model / AI settings | ✅ | T | Round-trip; editable in develop path |
| Tools (standard connectors) | ✅ | T | Flow needs a connection after install |
| Agent flows (Power Automate) | ✅ | T | Import linked + off; activate = connection + turn on |
| Skills — text / inline code | ✅ | T | Fully; content editable in develop path |
| Skills — with a code file (`.zip` of .py + SKILL.md) | ⚠️ | T | One-time CS re-upload; CS flags it |
| Tool / skill descriptions | ✅ | T | Editable in develop path (`description` column) |
| Knowledge — web links (+ description) | ✅ | T | Name, description, config all survive |
| Knowledge — files (PDF/Word) | ✅ | R | Binary travels in the bundle (tested in a prior session) |
| Test cases | ✅ | R | Carried in the bundle (prior session) |
| Child-agent tools | ✅ | R | Child agent must exist in target by same schema name |
| MCP tools — Microsoft-published (OOB) | ⚠️ | R | Behaves like a connector; wire a connection |
| MCP tools — custom (your own server) | ⚠️ | R | Server must be reachable at same URL; custom connector must exist in target |
| Custom connectors with inline code | ❌ | R | Azure Functions provisioning is unreliable — platform issue |
| Classic agents | ❌ | T | Different architecture — out of scope |

Any **R** row must be converted to **T** (or corrected) when a suitable test agent is available.

---

## 6. Assumptions (validate before relying on them)

- A1. Source and target are Dataverse environments the user can reach with `pac` + `az`.
- A2. The agent's `template` starts with `cliagent-` (modern). Verified at runtime.
- A3. The maker's publisher exists in the source env (resolved by prefix or unique name).
- A4. `bot.configuration` is a string field; PATCH bodies must string-encode it. (Tested.) An agent
  that was never configured/published has a **null** configuration — export must handle that without
  crashing (tested via a minimal agent; structure still transfers, no instructions/model to carry).
- A5. Local cloned YAML from `kind:` onward maps byte-for-byte to a component's `data` field;
  `mcs.metadata.description` maps to the `description` column. (Tested.)
- A6. The maker performs the one-click Publish themselves (no reliable CLI publish).
- A7. Dependencies an agent needs (custom tables, custom connectors) either exist in the target or
  are created by the maker — see UX backlog U1. **(Custom tables: now auto-bundled, §4.5.)**
- A8. Detecting table dependencies from flow `clientdata` is heuristic (string refs to entity set /
  logical names). We only act on tables confirmed `IsCustomEntity=true`; anything ambiguous is left
  to the existing missing-dependency detection (§4.2 step 2), which fails loudly with the name.

---

## 7. Decisions log (why the tool is built this way)

- D1. **Deploy via solution import, never `pac copilot push`.** Push is manifest-driven and dropped
  6 of 8 components in testing. (2026-06-26)
- D2. **Develop edits applied via targeted Dataverse writes** on top of solution import, not push.
- D3. **Skills with a code file are not silently inlined.** A silent rewrite would look fixed while
  the code can't run. We require an honest one-time re-upload.
- D4. **Install must verify, not trust.** pac import can return exit 0 on failure; we verify the bot
  exists in Dataverse and scan output for failure.
- D5. **Component-type enum is a candidate list, not a constant** (renumbered across platform
  versions); plus a post-add verification net and zip sanity check.
- D6. **Publisher accepts prefix or unique name** (makers know the prefix).
- D7. **Published on personal GitHub** as `Distribute-Develop-Modern-CopilotStudio-agents`.
- D8. **Docs are low-code-first**, jargon deferred to `LEARNINGS.md`.
- D9. **Self-contained samples auto-bundle custom table dependencies** (definition + 1 seed row) so
  a table-backed agent installs and works with one command. Only custom tables; system tables are
  never bundled. Seed insert is best-effort/non-fatal. (2026-06-26)

---

## 8. Known platform behavior we work around (detail in LEARNINGS.md)

- 8.1 `pac copilot push` — silently drops components for modern agents. Not used.
- 8.2 Solution component-type enum renumbered across platform versions (bot/botcomponent/connref).
- 8.3 `pac solution import` can print FAILURE yet return exit code 0. Must verify independently.
- 8.4 Code-file skills store their code in source-env blob storage (`bic:bundle=` pointer); it 404s
  in the target. Only a CS UI upload recreates it.
- 8.5 A tool/skill **description** lives in the `description` column, not in `data`.
- 8.6 `pac copilot publish` / `pack` / `pull` crash for modern agents. Publish is a UI step.

---

## 9. Reliability & versioning guarantees

- R1. No silent success: every deploy verifies the agent landed; failures stop with a cause.
- R2. No silent data loss: export verifies component counts and zip contents before shipping.
- R3. Cross-version safety: component-type handling uses candidate lists + count verification, so a
  future platform renumber fails loudly rather than shipping an empty bundle.
- R4. Idempotent installs: re-running install re-imports and re-applies edits safely.
- R5. When the platform changes, update §8 + LEARNINGS first, then code, then this spec's version.

---

## 10. UX backlog (improvements to make it more generic / easier)

- U1. ~~Self-contained samples for table-backed agents.~~ **RESOLVED (§4.5, D9):** export now
  auto-bundles each custom table's definition + 1 seed row; install recreates the table and seeds
  one row if empty. (System tables are never bundled; seed insert is best-effort.)
- U2. Auto-detect the agent id / offer a picker, so makers don't hunt for the GUID.
- U3. Optional `-WhatIf` dry run for both installs.
- U4. Multi-agent export (whole environment).
- U5. Convert all **R** rows in §5 to **T** with purpose-built test agents.

---

## 11. Test evidence (high-signal, reproducible)

- Distribute export/install round-trip across two environments; both old and new component-type
  enums; both recognizer styles (modern). All components landed; counts verified.
- Develop edit→deploy: instructions, an inline skill, and a tool description edited locally and
  confirmed persisted in Dataverse; all components present; single instruction segment preserved.
- Knowledge web link + description: injected, exported, imported to a second env, all fields
  survived.
- Failed-import detection: an agent whose flow needs a missing custom table aborts with the cause.
- **Self-contained tables (batch 1, 2026-06-26):** exported a table-backed agent (Presentation
  Buddy → custom `cr7a0_coffecoorders`); verified only the maker's own unmanaged table is bundled
  (a managed `msdyn_*` platform table is correctly skipped via `IsManaged=false`); installed to a
  clean env where the table did not exist → table recreated (unmanaged), 1 seed row inserted with
  all columns + choice value intact + fresh GUID, agent installed (this exact agent failed to
  install before the feature). Re-install is idempotent (existing data → no duplicate seed).

Keep this section updated as evidence is added or invalidated.

**Batch 2 (2026-06-26) — edge cases, 2 fixes:**
- No-table agent (Fabric Analyst): table logic is a clean no-op (seedTables=0, no seed-data, bundle
  unchanged). Develop path regression after the seed edits: full export+deploy clean.
- Minimal/empty agent (Clean Test Agent, **null `bot.configuration`**): **caught a crash** in both
  export scripts (`ConvertFrom-Json` on null) → fixed to handle null config with a clear warning;
  exports cleanly (bot.xml present, 0 components) and installs via `-BundleDir`.
- `-BundleDir` install path (extracted folder, not zip): verified end-to-end.
- Table+seed feature works through the **develop** path too (it reuses distribute export).
