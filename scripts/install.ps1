<#
.SYNOPSIS
    Imports a Modern Copilot Studio agent (cliagent-1.0.0) into any target environment.

.DESCRIPTION
    pac copilot push alone cannot fully deploy a Modern Copilot Studio agent. This script
    performs five things that pac push either cannot do or does incorrectly:

    ─────────────────────────────────────────────────────────────────────────────────────
    GAP 1 — pac push requires the bot to already exist
    ─────────────────────────────────────────────────────────────────────────────────────
    pac copilot push errors with "Entity 'bot' Does Not Exist" if the agent has not
    been pre-created in the target environment. This script creates it first via the
    Dataverse API (POST /api/data/v9.2/bots), then clones the empty bot to get a valid
    workspace before pushing content into it.

    ─────────────────────────────────────────────────────────────────────────────────────
    GAP 2 — Instructions live in bot.configuration, not in YAML
    ─────────────────────────────────────────────────────────────────────────────────────
    When you edit an agent's instructions in the Copilot Studio UI, they are written to
    the bot.configuration field in Dataverse — NOT back to settings.mcs.yml. pac push
    only writes the YAML files; it does not touch bot.configuration. This means:
      - If instructions were edited in the UI after the last pac push, settings.mcs.yml
        is stale, and pac push will overwrite the current instructions with old ones.
      - export.ps1 captures the authoritative bot.configuration to sample/agent-config.json.
      - install.ps1 PATCHes bot.configuration after push to apply the correct instructions.

    ─────────────────────────────────────────────────────────────────────────────────────
    GAP 3 — Flow GUIDs are environment-specific
    ─────────────────────────────────────────────────────────────────────────────────────
    Modern Copilot Studio supports two kinds of flow-backed tools:

    A) WorkflowTool (Copilot Studio Workflows, newer)
       Defined in translations/<schema>.tool.<name>.mcs.yml with kind: WorkflowTool
       Contains: workflowId: <source-env-guid>
       Flow definition: workflows/<name>-<guid>/workflow.json

    B) TaskDialog / InvokeFlowTaskAction (Agent Flows / Power Automate, older)
       Defined in actions/<name>.mcs.yml with kind: TaskDialog
       Contains: flowId: <source-env-guid> (inside action.kind: InvokeFlowTaskAction)
       Flow definition: workflows/<name>-<guid>/workflow.json

    In both cases, pac push fails with "Entity 'Workflow' Does Not Exist" because the
    source GUIDs don't exist in the target environment. This script:
      1. Strips the source GUIDs from all WorkflowTool and TaskDialog YAML files
      2. Runs pac push (creates agent config + tool botcomponents, no flow links)
      3. Creates all flows in the target via POST /api/data/v9.2/workflows
      4. Patches the new GUIDs back into the YAML files
      5. Re-runs pac push to link each tool to its flow

    ─────────────────────────────────────────────────────────────────────────────────────
    GAP 4 — Connection references need a human to wire them
    ─────────────────────────────────────────────────────────────────────────────────────
    pac push creates connection reference records from connectionreferences.mcs.yml, but
    they have no actual connection attached. A human must sign in to PPAC and wire each
    connection reference to a real connection (e.g. Office 365, Power BI, Dataverse).
    Flows remain in Draft state until this is done. This is a one-time manual step per
    environment and is normal platform behavior — not a limitation of this toolkit.
    Documented in the summary output.

    ─────────────────────────────────────────────────────────────────────────────────────
    WHAT PAC PUSH HANDLES AUTOMATICALLY (no extra steps needed)
    ─────────────────────────────────────────────────────────────────────────────────────
    - ConnectorTool and McpTool definitions (in translations/*.mcs.yml)
    - InlineAgentSkill knowledge files (in translations/*.mcs.yml)
    - ConnectedAgentTool child agent references (by botSchemaName — target must have agent)
    - URL knowledge sources (in knowledge/*.mcs.yml)
    - Connection reference records (from connectionreferences.mcs.yml)

    ─────────────────────────────────────────────────────────────────────────────────────
    KNOWN LIMITATIONS (cannot be automated — documented in README)
    ─────────────────────────────────────────────────────────────────────────────────────
    - ConnectorTool / McpTool: the connector must exist and be DLP-allowed in target env
    - ConnectedAgentTool: the child agent must exist in target env (by same schema name)
    - Connection wiring: one-time manual step per env per connector

    ─────────────────────────────────────────────────────────────────────────────────────
    REQUIRED FILES (produced by export.ps1)
    ─────────────────────────────────────────────────────────────────────────────────────
    sample/<AgentName>/        All YAML from pac copilot clone
      agent.mcs.yml
      settings.mcs.yml
      connectionreferences.mcs.yml   (if agent uses ConnectorTool / McpTool)
      knowledge/*.mcs.yml            (URL knowledge sources)
      translations/*.mcs.yml         (all tool, skill, action definitions)
      workflows/<name>-<guid>/       (flow definitions — one folder per flow)
        metadata.yml
        workflow.json
      actions/*.mcs.yml              (Agent Flow tools — older pattern)
    sample/agent-config.json   Authoritative bot.configuration (instructions, model)

    ─────────────────────────────────────────────────────────────────────────────────────
    PREREQUISITES
    ─────────────────────────────────────────────────────────────────────────────────────
    - pac CLI   https://aka.ms/PowerPlatformCLI
    - az CLI    https://aka.ms/installazurecliwindows
    - pac auth profile for the target environment (pac auth create)
    - az login with an account that has Dataverse write access in the target environment

.PARAMETER PacExe
    Path to pac.exe.

.PARAMETER TargetOrgUrl
    Target Dataverse org URL, e.g. https://myorg.crm.dynamics.com

.PARAMETER AgentName
    Display name for the agent (must match the sample/ subfolder name).

.PARAMETER AgentSchemaName
    Dataverse schema name of the agent (from settings.mcs.yml → schemaName field).

.PARAMETER AuthIndex
    pac auth index for the target environment.

.EXAMPLE
    # Deploy Presentation Buddy to target env with defaults
    .\scripts\install.ps1

.EXAMPLE
    # Deploy to a custom environment
    .\scripts\install.ps1 `
      -TargetOrgUrl    "https://myorg.crm.dynamics.com" `
      -AgentName       "My Agent" `
      -AgentSchemaName "myprefix_MyAgent_xxxxx" `
      -AuthIndex       1
#>
param(
    [string]$PacExe          = "",   # auto-detected from PATH; override if needed
    [string]$TargetOrgUrl    = "https://org07697283.crm.dynamics.com",
    [string]$AgentName       = "Presentation Buddy",
    [string]$AgentSchemaName = "cr7a0_mytooltest_AsoY32",
    [int]   $AuthIndex       = 2
)

$ErrorActionPreference = "Stop"
$ScriptDir   = Split-Path $MyInvocation.MyCommand.Path -Parent
$RepoRoot    = Split-Path $ScriptDir -Parent
$SampleDir   = Join-Path $RepoRoot "sample\$AgentName"
$ConfigPath  = Join-Path $RepoRoot "sample\agent-config.json"
$OrgNoTrail  = $TargetOrgUrl.TrimEnd("/")
$WorkspaceDir = Join-Path $RepoRoot "_workspace_$(Get-Date -Format 'yyyyMMddHHmmss')"
$guidMap     = @{}   # sourceGuid → newGuid — populated in Step 6, read in summary

# Resolve pac.exe: use explicit path if provided, otherwise find on PATH
if (-not $PacExe) {
    $PacExe = (Get-Command "pac" -ErrorAction SilentlyContinue)?.Source
    if (-not $PacExe) {
        $nugetPath = Get-ChildItem "$env:USERPROFILE\.nuget\packages\microsoft.powerapps.cli" -Filter "pac.exe" -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
        $PacExe = $nugetPath
    }
    if (-not $PacExe) { Write-Error "pac CLI not found. Install from https://aka.ms/PowerPlatformCLI or pass -PacExe path" }
}

function Step([string]$msg) { Write-Host "`n>>> $msg" -ForegroundColor Cyan }
function OK([string]$msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }
function WARN([string]$msg) { Write-Host "    !   $msg" -ForegroundColor Yellow }
function INFO([string]$msg) { Write-Host "        $msg" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Modern Copilot Studio Agent — Install               ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Target : $OrgNoTrail"
Write-Host "  Agent  : $AgentName ($AgentSchemaName)"
Write-Host ""

# ─── Acquire Dataverse bearer token ──────────────────────────────────────────
Step "Acquiring Dataverse token via az CLI..."
$tokenJson = az account get-access-token --resource $OrgNoTrail 2>&1
if ($LASTEXITCODE -ne 0) { Write-Error "az account get-access-token failed. Run: az login" }
$token = ($tokenJson | ConvertFrom-Json).accessToken
$dv = @{
    Authorization      = "Bearer $token"
    "OData-MaxVersion" = "4.0"
    "OData-Version"    = "4.0"
    Accept             = "application/json"
    "Content-Type"     = "application/json"
    Prefer             = "return=representation"
}
OK "Token acquired"

# ─── Step 1: Create agent in target Dataverse ────────────────────────────────
Step "Step 1/7 — Create agent in target Dataverse"
$newBotId = $null
try {
    $ex = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots?`$filter=schemaname eq '$AgentSchemaName'&`$select=botid,name" -Headers $dv
    if ($ex.value.Count -gt 0) {
        $newBotId = $ex.value[0].botid
        WARN "Agent already exists: $newBotId — skipping creation"
    }
} catch {}

if (-not $newBotId) {
    $b = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots" -Method POST -Headers $dv -Body (@{
        name             = $AgentName
        schemaname       = $AgentSchemaName
        template         = "cliagent-1.0.0"
        language         = 1033
        authenticationmode = 1
    } | ConvertTo-Json)
    $newBotId = $b.botid
    OK "Agent created: $newBotId"
}

# ─── Step 2: pac auth + clone empty agent → workspace ────────────────────────
Step "Step 2/7 — Clone empty agent to get valid workspace"
& $PacExe auth select --index $AuthIndex | Out-Null
New-Item -ItemType Directory -Force -Path $WorkspaceDir | Out-Null
& $PacExe copilot clone --environment $OrgNoTrail --bot $newBotId --display-name $AgentName --output-dir $WorkspaceDir
if ($LASTEXITCODE -ne 0) { Write-Error "pac copilot clone failed" }
$ws = Join-Path $WorkspaceDir $AgentName
OK "Workspace: $ws"

# ─── Step 3: Copy source YAML into workspace ─────────────────────────────────
Step "Step 3/7 — Copy source YAML, strip env-specific flow GUIDs"
INFO "Copying top-level files..."
foreach ($f in @("agent.mcs.yml","settings.mcs.yml","connectionreferences.mcs.yml","icon.png")) {
    $src = Join-Path $SampleDir $f
    if (Test-Path $src) { Copy-Item $src "$ws\$f" -Force }
}

INFO "Copying knowledge/, translations/, workflows/..."
foreach ($d in @("knowledge","translations","workflows")) {
    $src = Join-Path $SampleDir $d
    if (Test-Path $src) {
        New-Item -ItemType Directory -Force -Path "$ws\$d" | Out-Null
        Copy-Item "$src\*" "$ws\$d\" -Recurse -Force
    }
}

INFO "Copying actions/ (Agent Flow tools)..."
$actionsDir = Join-Path $SampleDir "actions"
if (Test-Path $actionsDir) {
    New-Item -ItemType Directory -Force -Path "$ws\actions" | Out-Null
    Copy-Item "$actionsDir\*" "$ws\actions\" -Force
}

# Strip WorkflowTool GUIDs from translations/*.mcs.yml
$strippedWorkflowIds = @{}   # filename → sourceGuid (for remapping later)
INFO "Stripping WorkflowTool workflowIds from translations/..."
Get-ChildItem "$ws\translations" -Filter "*.mcs.yml" -ErrorAction SilentlyContinue | ForEach-Object {
    $content = Get-Content $_.FullName -Raw
    if ($content -match "kind: WorkflowTool") {
        if ($content -match "(?m)^workflowId: ([a-f0-9\-]{36})") {
            $strippedWorkflowIds[$_.Name] = $Matches[1]
            INFO "  WorkflowTool '$($_.BaseName)' — stripped workflowId $($Matches[1])"
        }
        $fixed = $content -replace "(?m)^workflowId: [a-f0-9\-]+\r?\n", ""
        Set-Content $_.FullName -Value $fixed -Encoding UTF8 -NoNewline
    }
}

# Strip TaskDialog/InvokeFlowTaskAction GUIDs from actions/*.mcs.yml (Agent Flows)
$strippedFlowIds = @{}   # filename → sourceGuid
INFO "Stripping TaskDialog flowIds from actions/..."
Get-ChildItem "$ws\actions" -Filter "*.mcs.yml" -ErrorAction SilentlyContinue | ForEach-Object {
    $content = Get-Content $_.FullName -Raw
    if ($content -match "kind: InvokeFlowTaskAction") {
        if ($content -match "(?m)^  flowId: ([a-f0-9\-]{36})") {
            $strippedFlowIds[$_.Name] = $Matches[1]
            INFO "  AgentFlow '$($_.BaseName)' — stripped flowId $($Matches[1])"
        }
        $fixed = $content -replace "(?m)^  flowId: [a-f0-9\-]+\r?\n", ""
        Set-Content $_.FullName -Value $fixed -Encoding UTF8 -NoNewline
    }
}

$totalStripped = $strippedWorkflowIds.Count + $strippedFlowIds.Count
OK "Stripped $totalStripped flow GUIDs ($($strippedWorkflowIds.Count) WorkflowTool, $($strippedFlowIds.Count) AgentFlow)"

# ─── Step 4: First pac push ──────────────────────────────────────────────────
Step "Step 4/7 — Initial pac push (agent config, tools, knowledge, connection refs)"
INFO "This creates: agent settings, tool botcomponents, URL knowledge, connection reference records"
INFO "It does NOT link tools to flows yet (flow GUIDs were stripped)"

# Pre-check: warn about any translation file whose schemaname exceeds 100 chars.
# DV enforces a 100-char limit on botcomponent.schemaname. If a tool has a very long
# display name, pac generates a schemaname that exceeds this limit and push fails.
Get-ChildItem "$ws\translations" -Filter "*.mcs.yml" -ErrorAction SilentlyContinue | ForEach-Object {
    $schemaLen = ($_.Name -replace '\.mcs\.yml$','').Length
    if ($schemaLen -gt 100) {
        WARN "Translation file schemaname is $schemaLen chars (>100): $($_.Name)"
        WARN "Dataverse enforces a 100-char limit. pac push will fail for this component."
        WARN "Fix: rename the tool to a shorter display name in the source agent and re-export."
    }
}

$pushOut = & $PacExe copilot push --project-dir $ws 2>&1
$pushOut | ForEach-Object { INFO $_ }
if ($LASTEXITCODE -ne 0) {
    WARN "pac push returned exit code $LASTEXITCODE"
    if ($pushOut -match "StringLengthTooLong") {
        WARN "A component schemaname exceeds Dataverse's 100-char limit."
        WARN "Identify the long-named tool above and rename it in the source agent, then re-export."
    }
} else {
    OK "First pac push succeeded"
}

# ─── Step 5: PATCH bot.configuration (instructions, model, AI settings) ──────
Step "Step 5/7 — Patch bot.configuration (authoritative instructions + model)"
# IMPORTANT: bot.configuration in Dataverse is stored as a plain STRING (nvarchar),
# not a JSON column. We must serialize the config JSON into a string value, then
# wrap it in the outer PATCH body. @{configuration=$cfg} | ConvertTo-Json does this
# correctly: it produces {"configuration": "<escaped json string>"}.
if (Test-Path $ConfigPath) {
    $cfg    = Get-Content $ConfigPath -Raw
    $body   = @{ configuration = $cfg } | ConvertTo-Json -Depth 1
    Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots($newBotId)" -Method PATCH -Headers $dv -Body $body | Out-Null
    $cfgObj = $cfg | ConvertFrom-Json
    OK "bot.configuration patched"
    INFO "  Model       : $($cfgObj.agentSettings.model.series)"
    INFO "  Instructions: $($cfgObj.agentSettings.instructions.segments[0].value.Length) chars"
} else {
    WARN "sample/agent-config.json not found — instructions not applied"
    WARN "Run export.ps1 on the source agent to capture bot.configuration"
}

# ─── Step 6: Create flows via Dataverse API + remap GUIDs ────────────────────
Step "Step 6/7 — Create flows in target env, remap GUIDs into tool YAMLs"

$wfDirs = Get-ChildItem (Join-Path $ws "workflows") -Directory -ErrorAction SilentlyContinue
if ($wfDirs.Count -eq 0) {
    INFO "No workflows found — skipping flow creation"
} else {
    INFO "$($wfDirs.Count) workflow(s) to create"

    # Build source→new GUID map by creating each flow in the target environment
    $guidMap = @{}   # sourceGuid → newGuid

    foreach ($wfDir in $wfDirs) {
        # Extract source GUID from folder name: {flowName}-{guid}
        $sourceGuid = if ($wfDir.Name -match "([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})$") {
            $Matches[1]
        } else { $null }

        if (-not $sourceGuid) { WARN "Could not extract GUID from folder: $($wfDir.Name)"; continue }

        $metaFile = Join-Path $wfDir.FullName "metadata.yml"
        $wfFile   = Join-Path $wfDir.FullName "workflow.json"
        if (-not (Test-Path $metaFile) -or -not (Test-Path $wfFile)) { WARN "Missing files in $($wfDir.Name)"; continue }

        $meta   = Get-Content $metaFile -Raw
        $wfJson = Get-Content $wfFile -Raw

        # Flow name from metadata.yml
        $flowName = if ($meta -match "(?m)^name: (.+)") { $Matches[1].Trim() } else { $wfDir.Name }

        $newGuid = [Guid]::NewGuid().ToString()

        $flowPayload = @{
            workflowid    = $newGuid
            name          = $flowName
            category      = 5
            type          = 1
            primaryentity = "none"
            statecode     = 0
            statuscode    = 1
            clientdata    = $wfJson
        } | ConvertTo-Json -Depth 3

        try {
            Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/workflows" -Method POST -Headers $dv -Body $flowPayload | Out-Null
            $guidMap[$sourceGuid] = $newGuid
            OK "Flow '$flowName': $sourceGuid → $newGuid"
        } catch {
            WARN "Failed to create flow '$flowName': $($_.Exception.Message)"
        }
    }

    if ($guidMap.Count -eq 0) {
        WARN "No flows were created — skipping GUID remap and re-push"
    } else {
        INFO ""
        INFO "Remapping GUIDs into tool YAML files..."

        # Remap WorkflowTool translations: workflowId
        foreach ($fileName in $strippedWorkflowIds.Keys) {
            $sourceGuid = $strippedWorkflowIds[$fileName]
            $newGuid    = $guidMap[$sourceGuid]
            if (-not $newGuid) { WARN "No new GUID found for WorkflowTool $fileName ($sourceGuid)"; continue }

            $filePath = Join-Path $ws "translations\$fileName"
            $content  = Get-Content $filePath -Raw
            # Insert workflowId line after "kind: WorkflowTool"
            $fixed = $content -replace "kind: WorkflowTool", "kind: WorkflowTool`nworkflowId: $newGuid"
            Set-Content $filePath -Value $fixed -Encoding UTF8 -NoNewline
            OK "  WorkflowTool '$fileName' → workflowId: $newGuid"
        }

        # Remap TaskDialog actions: flowId
        foreach ($fileName in $strippedFlowIds.Keys) {
            $sourceGuid = $strippedFlowIds[$fileName]
            $newGuid    = $guidMap[$sourceGuid]
            if (-not $newGuid) { WARN "No new GUID found for AgentFlow $fileName ($sourceGuid)"; continue }

            $filePath = Join-Path $ws "actions\$fileName"
            $content  = Get-Content $filePath -Raw
            $fixed = $content -replace "kind: InvokeFlowTaskAction", "kind: InvokeFlowTaskAction`n  flowId: $newGuid"
            Set-Content $filePath -Value $fixed -Encoding UTF8 -NoNewline
            OK "  AgentFlow '$fileName' → flowId: $newGuid"
        }

        # Second pac push — links tools to flows
        INFO ""
        INFO "Re-pushing with remapped flow GUIDs..."
        $push2Out = & $PacExe copilot push --project-dir $ws 2>&1
        $push2Out | ForEach-Object { INFO $_ }
        if ($LASTEXITCODE -ne 0) {
            WARN "Second pac push returned exit code $LASTEXITCODE"
        } else {
            OK "Second pac push succeeded — tools linked to flows"
        }
    }
}

# ─── Step 7: Summary ─────────────────────────────────────────────────────────
Step "Step 7/7 — Summary"
$envId = $OrgNoTrail -replace "https://","" -replace "\.crm\.dynamics\.com",""

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Install Complete                                     ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Bot ID : $newBotId"
Write-Host "  URL    : https://copilotstudio.preview.microsoft.com/environments/$envId/home" -ForegroundColor Cyan
Write-Host ""
Write-Host "  What was done:" -ForegroundColor White
Write-Host "    [x] Agent created in Dataverse"
Write-Host "    [x] Agent YAML pushed (settings, tools, knowledge, connection refs)"
Write-Host "    [x] bot.configuration patched (authoritative instructions + model)"
if ($guidMap.Count -gt 0) {
    Write-Host "    [x] $($guidMap.Count) flow(s) created and linked to tools"
} else {
    Write-Host "    [-] No flows (agent has no WorkflowTool or AgentFlow tools)"
}
Write-Host ""
Write-Host "  MANUAL STEP REQUIRED — wire connections (one-time per environment):" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Flows are in Draft state until their connection references are wired."
Write-Host "  For each connector used by this agent:"
Write-Host "    1. Go to PPAC → <your env> → Connections → New connection"
Write-Host "    2. Create a connection for the required connector (sign in)"
Write-Host "    3. Go to Default Solution → Connection References"
Write-Host "    4. Find each connection reference → Edit → link to the new connection"
Write-Host "    5. Flows activate automatically once all connections are wired"
Write-Host ""

# List the connectors that need wiring
$connRefFile = Join-Path $ws "connectionreferences.mcs.yml"
if (Test-Path $connRefFile) {
    Write-Host "  Connectors required by this agent:" -ForegroundColor White
    $connRefYaml = Get-Content $connRefFile -Raw
    $connRefYaml -split "`n" | Where-Object { $_ -match "connectorId:" } | ForEach-Object {
        Write-Host "    • $($_ -replace '\s*connectorId:\s*/providers/Microsoft.PowerApps/apis/','')" -ForegroundColor Cyan
    }
    Write-Host ""
}

Write-Host "  Workspace (for debugging): $WorkspaceDir"
Write-Host ""
