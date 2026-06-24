<#
.SYNOPSIS
    Deploy a Modern Copilot Studio agent to a target environment via pac copilot push.

.DESCRIPTION
    pac copilot push alone cannot fully deploy a Modern agent. This script fills five gaps:

    GAP 1 — bot pre-creation required
        pac push errors with "Entity 'bot' Does Not Exist" if the agent doesn't exist yet.
        This script creates it first via Dataverse API (POST /bots), then clones the empty
        bot to get a valid pac workspace, then copies the source YAML in.

    GAP 2 — bot.configuration not written by pac push
        Instructions edited in the Copilot Studio UI live in bot.configuration in DV, not
        in settings.mcs.yml. This script PATCHes bot.configuration from agent-config.json
        after push to apply the authoritative instructions and model.

    GAP 3 — Flow GUIDs are env-specific
        WorkflowTool (translations/*.mcs.yml) embeds workflowId: <source-guid>.
        TaskDialog/InvokeFlowTaskAction (actions/*.mcs.yml) embeds flowId: <source-guid>.
        These GUIDs don't exist in the target. This script:
          1. Strips GUIDs → first pac push (creates tools without flow links)
          2. Creates flows in target via POST /workflows (new GUIDs)
          3. Patches new GUIDs back into YAML
          4. Second pac push (links tools to flows)

    GAP 4 — Connection references need manual wiring
        pac push creates connection reference records but doesn't attach connections.
        Flows stay in Draft until a human wires each connection in PPAC (one-time per env).

    WHAT PAC PUSH HANDLES AUTOMATICALLY:
        ConnectorTool, McpTool, InlineAgentSkill, ConnectedAgentTool, URL knowledge,
        connection reference stubs — all from YAML.

.PARAMETER PacExe
    Path to pac.exe. Auto-detected from PATH or NuGet cache if omitted.

.PARAMETER TargetOrgUrl
    Target Dataverse environment URL, e.g. https://myorg.crm.dynamics.com

.PARAMETER AgentName
    Display name of the agent. Must match the sample/ subfolder name.

.PARAMETER AgentSchemaName
    Dataverse schema name of the agent (from settings.mcs.yml → schemaName).

.PARAMETER SampleDir
    Path to the sample/<AgentName> directory containing YAML files.
    Default: auto-detected from repo root relative to script location.

.PARAMETER ConfigPath
    Path to agent-config.json. Default: sample/agent-config.json relative to repo root.

.PARAMETER AuthIndex
    pac auth profile index (default: 1).

.EXAMPLE
    .\path2-vscode\install.ps1 `
      -TargetOrgUrl    "https://myorg.crm.dynamics.com" `
      -AgentName       "Fabric Analyst" `
      -AgentSchemaName "cr7a0_FabricAnalyst_dQTqzr"

.EXAMPLE
    .\path2-vscode\install.ps1 `
      -TargetOrgUrl    "https://myorg.crm.dynamics.com" `
      -AgentName       "Fabric Analyst" `
      -AgentSchemaName "cr7a0_FabricAnalyst_dQTqzr" `
      -AuthIndex       2
#>
param(
    [string]$PacExe          = "",
    [Parameter(Mandatory)][string]$TargetOrgUrl,
    [Parameter(Mandatory)][string]$AgentName,
    [Parameter(Mandatory)][string]$AgentSchemaName,
    [string]$SampleDir       = "",
    [string]$ConfigPath      = "",
    [int]   $AuthIndex       = 1
)

$ErrorActionPreference = "Stop"

function Step  { Write-Host "`n$args" -ForegroundColor Cyan }
function OK    { Write-Host "  OK  $args" -ForegroundColor Green }
function INFO  { Write-Host "      $args" -ForegroundColor Gray }
function WARN  { Write-Host "  !   $args" -ForegroundColor Yellow }
function ERR   { Write-Host "  ERR $args" -ForegroundColor Red; exit 1 }

# ── Locate pac.exe ─────────────────────────────────────────────────────────────
if (-not $PacExe) {
    $PacExe = (Get-Command "pac" -ErrorAction SilentlyContinue)?.Source
    if (-not $PacExe) {
        $PacExe = Get-ChildItem "$env:USERPROFILE\.nuget\packages\microsoft.powerapps.cli" -Filter "pac.exe" -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $PacExe) { ERR "pac CLI not found. Install: https://aka.ms/PowerPlatformCLI" }
}

$ScriptDir    = Split-Path $MyInvocation.MyCommand.Path -Parent
$RepoRoot     = Split-Path $ScriptDir -Parent
if (-not $SampleDir)  { $SampleDir  = Join-Path $RepoRoot "sample\$AgentName" }
if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot "sample\agent-config.json" }
$OrgNoTrail   = $TargetOrgUrl.TrimEnd("/")
$WorkspaceDir = Join-Path $RepoRoot "_workspace_$(Get-Date -Format 'yyyyMMddHHmmss')"
$guidMap      = @{}

Write-Host ""
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Modern Agent Install — VS Code Path"       -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Target     : $OrgNoTrail"
Write-Host "  Agent      : $AgentName ($AgentSchemaName)"
Write-Host "  Sample dir : $SampleDir"
Write-Host "  Workspace  : $WorkspaceDir"

if (-not (Test-Path $SampleDir)) { ERR "Sample directory not found: $SampleDir. Run export.ps1 first." }

# ── Acquire DV token ──────────────────────────────────────────────────────────
Step "Acquiring Dataverse bearer token..."

$tokenJson = az account get-access-token --resource $OrgNoTrail 2>&1
if ($LASTEXITCODE -ne 0) { ERR "az account get-access-token failed. Run: az login" }
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

# ── Step 1: Create agent in target Dataverse ──────────────────────────────────
Step "[1/7] Creating agent in target Dataverse..."

$newBotId = $null
try {
    $ex = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots?`$filter=schemaname eq '$AgentSchemaName'&`$select=botid,name" -Headers $dv
    if ($ex.value.Count -gt 0) {
        $newBotId = $ex.value[0].botid
        WARN "Agent already exists: $newBotId — skipping creation, will push into existing record"
    }
} catch { WARN "Could not check for existing agent: $($_.Exception.Message)" }

if (-not $newBotId) {
    $b = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots" -Method POST -Headers $dv -Body (@{
        name               = $AgentName
        schemaname         = $AgentSchemaName
        template           = "cliagent-1.0.0"
        language           = 1033
        authenticationmode = 1
    } | ConvertTo-Json)
    $newBotId = $b.botid
    OK "Agent created: $newBotId"
}

# ── Step 2: Clone empty agent → get valid pac workspace ───────────────────────
Step "[2/7] Cloning empty agent to create pac workspace..."

& $PacExe auth select --index $AuthIndex | Out-Null
New-Item -ItemType Directory -Force -Path $WorkspaceDir | Out-Null
& $PacExe copilot clone --environment $OrgNoTrail --bot $newBotId --display-name $AgentName --output-dir $WorkspaceDir 2>&1 | ForEach-Object { INFO $_ }
if ($LASTEXITCODE -ne 0) { ERR "pac copilot clone failed (exit $LASTEXITCODE)" }
$ws = Join-Path $WorkspaceDir $AgentName
OK "Workspace: $ws"

# ── Step 3: Copy source YAML into workspace + strip flow GUIDs ────────────────
Step "[3/7] Copying source YAML into workspace, stripping env-specific flow GUIDs..."

# Top-level files
foreach ($f in @("agent.mcs.yml","settings.mcs.yml","connectionreferences.mcs.yml","icon.png")) {
    $src = Join-Path $SampleDir $f
    if (Test-Path $src) { Copy-Item $src "$ws\$f" -Force }
}

# Subdirectories
foreach ($d in @("knowledge","translations","workflows","actions")) {
    $src = Join-Path $SampleDir $d
    if (Test-Path $src) {
        New-Item -ItemType Directory -Force -Path "$ws\$d" | Out-Null
        Copy-Item "$src\*" "$ws\$d\" -Recurse -Force
    }
}

# Strip WorkflowTool GUIDs (translations/*.mcs.yml: workflowId: <guid>)
$strippedWorkflowIds = @{}
Get-ChildItem "$ws\translations" -Filter "*.mcs.yml" -ErrorAction SilentlyContinue | ForEach-Object {
    $yml = Get-Content $_.FullName -Raw
    if ($yml -match "kind: WorkflowTool") {
        if ($yml -match "(?m)^workflowId: ([a-f0-9\-]{36})") {
            $strippedWorkflowIds[$_.Name] = $Matches[1]
            INFO "WorkflowTool '$($_.BaseName)' — stripped workflowId $($Matches[1])"
        }
        $fixed = $yml -replace "(?m)^workflowId: [a-f0-9\-]+\r?\n", ""
        Set-Content $_.FullName -Value $fixed -Encoding UTF8 -NoNewline
    }
}

# Strip TaskDialog/AgentFlow GUIDs (actions/*.mcs.yml: "  flowId: <guid>")
$strippedFlowIds = @{}
Get-ChildItem "$ws\actions" -Filter "*.mcs.yml" -ErrorAction SilentlyContinue | ForEach-Object {
    $yml = Get-Content $_.FullName -Raw
    if ($yml -match "kind: InvokeFlowTaskAction") {
        if ($yml -match "(?m)^  flowId: ([a-f0-9\-]{36})") {
            $strippedFlowIds[$_.Name] = $Matches[1]
            INFO "AgentFlow '$($_.BaseName)' — stripped flowId $($Matches[1])"
        }
        $fixed = $yml -replace "(?m)^  flowId: [a-f0-9\-]+\r?\n", ""
        Set-Content $_.FullName -Value $fixed -Encoding UTF8 -NoNewline
    }
}

$totalStripped = $strippedWorkflowIds.Count + $strippedFlowIds.Count
OK "Stripped $totalStripped flow GUID(s) ($($strippedWorkflowIds.Count) WorkflowTool, $($strippedFlowIds.Count) AgentFlow)"

# ── Step 4: First pac push ────────────────────────────────────────────────────
Step "[4/7] First pac push (creates agent config, tools, knowledge, connection refs)..."
INFO "Flow tools are created without GUID links — that is intentional here"

# Warn on schema names exceeding Dataverse's 100-char limit
Get-ChildItem "$ws\translations" -Filter "*.mcs.yml" -ErrorAction SilentlyContinue | ForEach-Object {
    $schemaLen = ($_.Name -replace '\.mcs\.yml$','').Length
    if ($schemaLen -gt 100) {
        WARN "Translation schema name is $schemaLen chars (>100): $($_.Name)"
        WARN "Dataverse enforces 100-char limit — pac push will fail for this component."
        WARN "Fix: rename the tool to a shorter display name in the source, then re-export."
    }
}

$push1Out = & $PacExe copilot push --project-dir $ws 2>&1
$push1Out | ForEach-Object { INFO $_ }
if ($LASTEXITCODE -ne 0) {
    WARN "pac push returned exit code $LASTEXITCODE"
    if ($push1Out -match "StringLengthTooLong") {
        WARN "A component schema name exceeds the 100-char DV limit (see warning above)."
    }
} else {
    OK "First pac push succeeded"
}

# ── Step 5: PATCH bot.configuration ──────────────────────────────────────────
Step "[5/7] Patching bot.configuration (authoritative instructions + model)..."

# IMPORTANT: bot.configuration is stored as a plain STRING in DV, not a JSON column.
# @{configuration=$cfg} | ConvertTo-Json -Depth 1 correctly string-encodes the JSON
# value, producing: {"configuration": "<escaped json string>"}
if (Test-Path $ConfigPath) {
    $cfg  = Get-Content $ConfigPath -Raw
    $body = @{ configuration = $cfg } | ConvertTo-Json -Depth 1
    Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots($newBotId)" -Method PATCH -Headers $dv -Body $body | Out-Null
    try {
        $cfgObj = $cfg | ConvertFrom-Json
        OK "bot.configuration patched"
        INFO "Model       : $($cfgObj.agentSettings.model.series)"
        INFO "Instructions: $($cfgObj.agentSettings.instructions.segments[0].value.Length) chars"
    } catch {
        OK "bot.configuration patched (could not parse for preview)"
    }
} else {
    WARN "agent-config.json not found at $ConfigPath — instructions not applied"
    WARN "Run export.ps1 on the source environment to capture bot.configuration"
}

# ── Step 6: Create flows + remap GUIDs + second push ──────────────────────────
Step "[6/7] Creating flows in target, remapping GUIDs, second pac push..."

$wfDirs = Get-ChildItem (Join-Path $ws "workflows") -Directory -ErrorAction SilentlyContinue
if ((-not $wfDirs) -or $wfDirs.Count -eq 0) {
    OK "No workflows found — skipping flow creation and second push"
} else {
    INFO "$($wfDirs.Count) workflow(s) to create in target"

    foreach ($wfDir in $wfDirs) {
        # Extract source GUID from folder name: {flowName}-{guid}
        $sourceGuid = if ($wfDir.Name -match "([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})$") {
            $Matches[1] } else { $null }
        if (-not $sourceGuid) { WARN "Cannot extract GUID from: $($wfDir.Name)"; continue }

        $metaFile = Join-Path $wfDir.FullName "metadata.yml"
        $wfFile   = Join-Path $wfDir.FullName "workflow.json"
        if (-not (Test-Path $metaFile) -or -not (Test-Path $wfFile)) {
            WARN "Missing metadata.yml or workflow.json in: $($wfDir.Name)"; continue
        }

        $meta     = Get-Content $metaFile -Raw
        $wfJson   = Get-Content $wfFile -Raw
        $flowName = if ($meta -match "(?m)^name: (.+)") { $Matches[1].Trim() } else { $wfDir.Name }
        $newGuid  = [Guid]::NewGuid().ToString()

        $payload = @{
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
            Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/workflows" -Method POST -Headers $dv -Body $payload | Out-Null
            $guidMap[$sourceGuid] = $newGuid
            OK "Flow '$flowName': $sourceGuid → $newGuid"
        } catch {
            WARN "Failed to create flow '$flowName': $($_.Exception.Message)"
        }
    }

    if ($guidMap.Count -eq 0) {
        WARN "No flows created — skipping GUID remap and second push"
    } else {
        INFO "Patching new GUIDs into tool YAML files..."

        # WorkflowTool: insert workflowId after "kind: WorkflowTool"
        foreach ($fileName in $strippedWorkflowIds.Keys) {
            $newGuid = $guidMap[$strippedWorkflowIds[$fileName]]
            if (-not $newGuid) { WARN "No target GUID for WorkflowTool: $fileName"; continue }
            $filePath = Join-Path $ws "translations\$fileName"
            $yml = Get-Content $filePath -Raw
            $fixed = $yml -replace "kind: WorkflowTool", "kind: WorkflowTool`nworkflowId: $newGuid"
            Set-Content $filePath -Value $fixed -Encoding UTF8 -NoNewline
            OK "WorkflowTool '$fileName' → workflowId: $newGuid"
        }

        # TaskDialog/AgentFlow: insert "  flowId:" after "kind: InvokeFlowTaskAction"
        foreach ($fileName in $strippedFlowIds.Keys) {
            $newGuid = $guidMap[$strippedFlowIds[$fileName]]
            if (-not $newGuid) { WARN "No target GUID for AgentFlow: $fileName"; continue }
            $filePath = Join-Path $ws "actions\$fileName"
            $yml = Get-Content $filePath -Raw
            $fixed = $yml -replace "kind: InvokeFlowTaskAction", "kind: InvokeFlowTaskAction`n  flowId: $newGuid"
            Set-Content $filePath -Value $fixed -Encoding UTF8 -NoNewline
            OK "AgentFlow '$fileName' → flowId: $newGuid"
        }

        INFO "Second pac push — linking tools to flows..."
        $push2Out = & $PacExe copilot push --project-dir $ws 2>&1
        $push2Out | ForEach-Object { INFO $_ }
        if ($LASTEXITCODE -ne 0) {
            WARN "Second pac push returned exit code $LASTEXITCODE"
        } else {
            OK "Second pac push succeeded — tools linked to flows"
        }
    }
}

# ── Step 7: Summary ───────────────────────────────────────────────────────────
Step "[7/7] Summary"
$envId = $OrgNoTrail -replace "https://","" -replace "\.crm\.dynamics\.com",""

Write-Host ""
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Install Complete"                          -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Bot ID : $newBotId"
Write-Host "  URL    : https://copilotstudio.microsoft.com/environments/$envId/home" -ForegroundColor Cyan
Write-Host ""
Write-Host "  What was done:"
Write-Host "    [x] Agent created / found in Dataverse"
Write-Host "    [x] Agent YAML pushed (settings, tools, skills, knowledge, connection refs)"
Write-Host "    [x] bot.configuration patched (instructions + model)"
if ($guidMap.Count -gt 0) {
    Write-Host "    [x] $($guidMap.Count) flow(s) created and linked to tools"
} else {
    Write-Host "    [-] No flows (agent has no WorkflowTool or AgentFlow tools)"
}
Write-Host ""
Write-Host "  MANUAL STEP REQUIRED — wire connection references (one-time per environment):" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Flows remain in Draft until their connection references are wired."
Write-Host "    1. PPAC → <env> → Connections → New connection (create each required connector)"
Write-Host "    2. Default Solution → Connection References → Edit → link each to a connection"
Write-Host "    3. Flows activate automatically once all connections are wired"
Write-Host ""

# List connectors from connectionreferences.mcs.yml
$connRefFile = Join-Path $ws "connectionreferences.mcs.yml"
if (Test-Path $connRefFile) {
    $connRefYaml = Get-Content $connRefFile -Raw
    $connectors  = @($connRefYaml -split "`n" | Where-Object { $_ -match "connectorId:" } |
        ForEach-Object { ($_ -replace '\s*connectorId:\s*/providers/Microsoft.PowerApps/apis/','').Trim() })
    if ($connectors.Count -gt 0) {
        Write-Host "  Connectors required:" -ForegroundColor White
        $connectors | ForEach-Object { Write-Host "    • $_" -ForegroundColor Cyan }
        Write-Host ""
    }
}

Write-Host "  Workspace (keep for debugging, safe to delete): $WorkspaceDir"
Write-Host ""
