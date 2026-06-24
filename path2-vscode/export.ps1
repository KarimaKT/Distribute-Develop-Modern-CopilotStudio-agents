<#
.SYNOPSIS
    Export a Modern Copilot Studio agent for VS Code developer iteration.

.DESCRIPTION
    'pac copilot clone' alone misses three things for Modern agents. This script fills them:

    GAP 1 — Instructions live in bot.configuration, not YAML
        settings.mcs.yml reflects what was last pushed via pac CLI. Edits made in the
        Copilot Studio UI go to bot.configuration in Dataverse (always authoritative).
        This script exports it to sample/agent-config.json.

    GAP 2 — InlineAgentSkill content is in YAML (pac clone captures it)
        Exported in translations/*.mcs.yml — no extra work needed.

    GAP 3 — Flow GUIDs are env-specific
        Every WorkflowTool (translations/*.mcs.yml) and TaskDialog/AgentFlow
        (actions/*.mcs.yml) embeds a source-env GUID that doesn't exist in the target.
        install.ps1 handles the remap. Just export cleanly here.

.PARAMETER PacExe
    Path to pac.exe. Auto-detected from PATH or NuGet cache if omitted.

.PARAMETER SourceOrgUrl
    Dataverse environment URL, e.g. https://myorg.crm.dynamics.com

.PARAMETER AgentName
    Display name of the agent (used as the output folder name under sample/).

.PARAMETER BotId
    GUID of the bot record in Dataverse.

.PARAMETER AuthIndex
    pac auth profile index (default: 1).

.PARAMETER OutputDir
    Parent directory for the sample/ folder. Default: repo root (auto-detected from
    script location).

.EXAMPLE
    .\path2-vscode\export.ps1 `
      -SourceOrgUrl "https://myorg.crm.dynamics.com" `
      -AgentName    "Fabric Analyst" `
      -BotId        "d01d7579-bf47-4da7-b751-22a419ade844"

.EXAMPLE
    .\path2-vscode\export.ps1 `
      -SourceOrgUrl "https://myorg.crm.dynamics.com" `
      -AgentName    "Fabric Analyst" `
      -BotId        "d01d7579-bf47-4da7-b751-22a419ade844" `
      -AuthIndex    2
#>
param(
    [string]$PacExe       = "",
    [Parameter(Mandatory)][string]$SourceOrgUrl,
    [Parameter(Mandatory)][string]$AgentName,
    [Parameter(Mandatory)][string]$BotId,
    [int]   $AuthIndex    = 1,
    [string]$OutputDir    = ""
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

$ScriptDir  = Split-Path $MyInvocation.MyCommand.Path -Parent
$RepoRoot   = Split-Path $ScriptDir -Parent
if (-not $OutputDir) { $OutputDir = $RepoRoot }
$OrgNoTrail = $SourceOrgUrl.TrimEnd("/")

Write-Host ""
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Modern Agent Export — VS Code Path"        -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Source : $OrgNoTrail"
Write-Host "  Agent  : $AgentName ($BotId)"
Write-Host "  Output : $OutputDir"

# ── Step 1: Validate agent is Modern via DV API ───────────────────────────────
Step "[1/6] Validating agent (cliagent-1.0.0 check)..."

$tokenJson = az account get-access-token --resource $OrgNoTrail 2>&1
if ($LASTEXITCODE -ne 0) { ERR "az account get-access-token failed. Run: az login" }
$token   = ($tokenJson | ConvertFrom-Json).accessToken
$headers = @{
    Authorization      = "Bearer $token"
    "OData-MaxVersion" = "4.0"
    "OData-Version"    = "4.0"
    Accept             = "application/json"
}

$bot = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots($BotId)?`$select=botid,name,schemaname,template,configuration" -Headers $headers

if ($bot.template -ne "cliagent-1.0.0") {
    WARN "Template: $($bot.template)"
    ERR "This toolkit only supports Modern agents (template: cliagent-1.0.0). Use pac copilot clone/push directly for Classic agents."
}
OK "Template: cliagent-1.0.0 (Modern)"
INFO "Schema: $($bot.schemaname)"

# ── Step 2: pac copilot clone ─────────────────────────────────────────────────
Step "[2/6] Cloning agent YAML (pac copilot clone)..."

& $PacExe auth select --index $AuthIndex | Out-Null
$sampleDir = Join-Path $OutputDir "sample"
New-Item -ItemType Directory -Force -Path $sampleDir | Out-Null

& $PacExe copilot clone --environment $OrgNoTrail --agent $AgentName --output-dir $sampleDir 2>&1 | ForEach-Object { INFO $_ }
if ($LASTEXITCODE -ne 0) { ERR "pac copilot clone failed (exit $LASTEXITCODE)" }
$agentDir = Join-Path $sampleDir $AgentName
OK "Cloned to: $agentDir"

# ── Step 3: Validate no custom topics ────────────────────────────────────────
Step "[3/6] Checking for Classic custom topics (not expected in Modern agents)..."

$topicsDir = Join-Path $agentDir "topics"
if (Test-Path $topicsDir) {
    $systemTopics = @("Greeting","Goodbye","Escalate","EndofConversation","Fallback","OnError","MultipleTopicsMatched","ResetConversation","StartOver","ThankYou","Signin","Search")
    $customTopics = Get-ChildItem $topicsDir -Filter "*.mcs.yml" |
        Where-Object { $systemTopics -notcontains ($_.BaseName -replace '\.mcs$', '') }
    if ($customTopics.Count -gt 0) {
        WARN "$($customTopics.Count) custom topic(s) found — agent may be Classic or hybrid:"
        $customTopics | ForEach-Object { WARN "  - $($_.Name)" }
        WARN "install.ps1 may not handle Classic topics correctly."
    } else {
        OK "No custom topics (system-only topics are expected)"
    }
} else {
    OK "No topics directory — confirmed Modern agent"
}

# ── Step 4: Export bot.configuration ─────────────────────────────────────────
Step "[4/6] Exporting authoritative bot.configuration..."

$configJson = $bot.configuration
if ($configJson -and $configJson.Length -gt 10) {
    $configJson | Set-Content (Join-Path $sampleDir "agent-config.json") -Encoding UTF8
    try {
        $cfgObj   = $configJson | ConvertFrom-Json
        $instrLen = $cfgObj.agentSettings.instructions.segments[0].value.Length
        $model    = $cfgObj.agentSettings.model.series
        OK "sample\agent-config.json saved"
        INFO "Model       : $model"
        INFO "Instructions: $instrLen chars"

        # Stale YAML check
        $settingsPath = Join-Path $agentDir "settings.mcs.yml"
        if (Test-Path $settingsPath) {
            $yamlRaw  = Get-Content $settingsPath -Raw
            $cfgStart = $cfgObj.agentSettings.instructions.segments[0].value.Substring(0, [Math]::Min(50,$instrLen))
            if ($yamlRaw -notlike "*$cfgStart*") {
                WARN "settings.mcs.yml instructions differ from bot.configuration."
                WARN "The UI was used to edit instructions after the last pac push."
                WARN "agent-config.json is authoritative — install.ps1 will PATCH it."
            }
        }
    } catch {
        OK "sample\agent-config.json saved (could not parse for preview)"
    }
} else {
    WARN "bot.configuration is empty — agent-config.json not saved"
}

# ── Step 5: Inventory botcomponents and flag gaps ─────────────────────────────
Step "[5/6] Inventorying botcomponents..."

$comps = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotid_value eq '$BotId'&`$select=botcomponentid,name,componenttype,data" -Headers $headers).value
$warnings = @()

foreach ($c in $comps) {
    switch ($c.componenttype) {
        9 {
            if ($c.data -like "*InlineAgentSkill*") {
                OK "InlineAgentSkill : $($c.name) (in translations/*.mcs.yml)"
            } elseif ($c.data -like "*bic:bundle=*") {
                WARN "Skill-with-assets: $($c.name) — bundle blob NOT in YAML, needs post-install re-upload"
                $warnings += "Skill '$($c.name)' has binary assets. Use path1-solution export/install for reliable transfer."
            } elseif ($c.data -like "*TaskDialog*") {
                INFO "Flow tool (TaskDialog): $($c.name)"
            } elseif ($c.data -like "*ConnectorTool*" -or $c.data -like "*McpTool*") {
                INFO "Connector/MCP tool: $($c.name)"
            } elseif ($c.data -like "*ConnectedAgentTool*" -or $c.data -like "*childAgentId*") {
                WARN "Connected agent: $($c.name) — target env must have child agent by same schema name"
                $warnings += "Connected agent '$($c.name)' requires the child agent to exist in the target environment."
            }
        }
        16 { INFO "URL knowledge: $($c.name)" }
        19 { INFO "Eval test case: $($c.name)" }
    }
}

# ── Step 6: Inventory flow GUIDs ──────────────────────────────────────────────
Step "[6/6] Inventorying flow GUIDs (env-specific, install.ps1 will remap)..."

$wfCount = 0
Get-ChildItem (Join-Path $agentDir "translations") -Filter "*.mcs.yml" -ErrorAction SilentlyContinue | ForEach-Object {
    $yml = Get-Content $_.FullName -Raw
    if ($yml -match "kind: WorkflowTool" -and $yml -match "workflowId: ([a-f0-9\-]{36})") {
        INFO "WorkflowTool '$($_.BaseName)' — workflowId: $($Matches[1]) (will be remapped)"
        $wfCount++
    }
}
Get-ChildItem (Join-Path $agentDir "actions") -Filter "*.mcs.yml" -ErrorAction SilentlyContinue | ForEach-Object {
    $yml = Get-Content $_.FullName -Raw
    if ($yml -match "kind: InvokeFlowTaskAction" -and $yml -match "flowId: ([a-f0-9\-]{36})") {
        INFO "AgentFlow '$($_.BaseName)' — flowId: $($Matches[1]) (will be remapped)"
        $wfCount++
    }
}
if ($wfCount -eq 0) { OK "No flow GUIDs found — agent has no flow-backed tools" }
else { OK "$wfCount flow tool(s) found — install.ps1 strips GUIDs before push and remaps after" }

# ── Summary ───────────────────────────────────────────────────────────────────
$yamlCount = (Get-ChildItem $agentDir -Filter "*.mcs.yml" -Recurse -ErrorAction SilentlyContinue).Count
Write-Host ""
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Export Complete"                           -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  YAML files         : $yamlCount"
Write-Host "  agent-config.json  : $(if ((Test-Path (Join-Path $sampleDir 'agent-config.json'))) {'saved'} else {'MISSING'})"
Write-Host "  Flow tools         : $wfCount (GUIDs captured, install.ps1 remaps them)"

if ($warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "  Warnings:" -ForegroundColor Yellow
    $warnings | ForEach-Object { Write-Host "  ! $_" -ForegroundColor Yellow }
}

Write-Host ""
Write-Host "  Edit YAML in VS Code, then run: path2-vscode\install.ps1"
Write-Host ""
