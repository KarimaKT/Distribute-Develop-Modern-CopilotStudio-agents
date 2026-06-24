<#
.SYNOPSIS
    Exports a Modern Copilot Studio agent (cliagent-1.0.0) from any environment.

.DESCRIPTION
    'pac copilot clone' alone is insufficient for Modern Copilot Studio agents. It misses:

      GAP 1 — Instructions out of sync
        settings.mcs.yml contains whatever was last pushed via pac CLI.
        Edits made in the Copilot Studio UI go to bot.configuration in Dataverse.
        These two can diverge. bot.configuration is always authoritative.
        This script exports it to sample/agent-config.json.

      GAP 2 — Skill knowledge not in YAML
        InlineAgentSkill botcomponents (type 9) are stored only in Dataverse.
        pac clone does not include them. This script exports them to skills/*.md.

      GAP 3 — Flow IDs are env-specific
        Every action/*.mcs.yml embeds a flowId that is a GUID in the source env.
        Those GUIDs do not exist in the target env. install.ps1 handles the remap.

    VALIDATION:
      Before exporting, this script checks:
        - The agent uses the cliagent-1.0.0 template (Modern Copilot Studio)
        - The cloned output has no topics/ directory (topics = Classic, not supported)
      It also reports component types it cannot fully capture (URL knowledge sources,
      connected child agents) so you know what manual steps are needed after import.

    OUTPUT:
      sample/<AgentName>/    — YAML (agent.mcs.yml, settings.mcs.yml, actions/, workflows/)
      sample/agent-config.json — authoritative bot configuration (instructions, model, AI)
      skills/*.md            — exported InlineAgentSkill knowledge files

    PREREQUISITES:
      - pac CLI  https://aka.ms/PowerPlatformCLI
      - az CLI   https://aka.ms/installazurecliwindows
      - pac auth profile for the source environment (pac auth create)
      - az login to a user with Dataverse read access on the source environment

.EXAMPLE
    .\scripts\export.ps1

.EXAMPLE
    .\scripts\export.ps1 `
      -SourceOrgUrl "https://myorg.crm.dynamics.com" `
      -AgentName    "My Agent" `
      -BotId        "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
      -AuthIndex    1
#>
param(
    [string]$PacExe       = "C:\Users\kkanjitajdin\.nuget\packages\microsoft.powerapps.cli\2.8.1\tools\pac.exe",
    [string]$SourceOrgUrl = "https://orgea8005ed.crm.dynamics.com",
    [string]$AgentName    = "Fabric Analyst",
    [string]$BotId        = "d01d7579-bf47-4da7-b751-22a419ade844",
    [int]   $AuthIndex    = 2
)

$ErrorActionPreference = "Stop"

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
$ScriptDir  = Split-Path $MyInvocation.MyCommand.Path -Parent
$RepoRoot   = Split-Path $ScriptDir -Parent
$OrgNoTrail = $SourceOrgUrl.TrimEnd("/")

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Modern Agent Export" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Source : $OrgNoTrail"
Write-Host "Agent  : $AgentName ($BotId)"
Write-Host ""

# ── Step 1: Validate agent is Modern via DV API ───────────────────────────────
Write-Host "[1/6] Validating agent is Modern Copilot Studio (cliagent-1.0.0)..." -ForegroundColor Yellow
$tokenJson = az account get-access-token --resource $OrgNoTrail 2>&1
if ($LASTEXITCODE -ne 0) { Write-Error "az account get-access-token failed. Run: az login" }
$token   = ($tokenJson | ConvertFrom-Json).accessToken
$headers = @{
    Authorization      = "Bearer $token"
    "OData-MaxVersion" = "4.0"
    "OData-Version"    = "4.0"
    Accept             = "application/json"
}

$botResult = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots($BotId)?`$select=botid,name,schemaname,template,configuration" -Headers $headers

if ($botResult.template -ne "cliagent-1.0.0") {
    Write-Host ""
    Write-Host "  ERROR: This agent uses template '$($botResult.template)'." -ForegroundColor Red
    Write-Host "  This toolkit only supports Modern Copilot Studio agents (template: cliagent-1.0.0)." -ForegroundColor Red
    Write-Host "  Classic agents (GenerativeAIRecognizer / default-2.1.0) use a different deployment model." -ForegroundColor Red
    Write-Host "  Use pac copilot clone / push directly for Classic agents." -ForegroundColor Red
    exit 1
}
Write-Host "  -> Template: cliagent-1.0.0 (Modern) ✓" -ForegroundColor Green
Write-Host "  -> Schema  : $($botResult.schemaname)"

# ── Step 2: pac auth + clone ─────────────────────────────────────────────────
Write-Host "[2/6] Cloning agent YAML via pac copilot clone..." -ForegroundColor Yellow
& $PacExe auth select --index $AuthIndex | Out-Null
$sampleDir = Join-Path $RepoRoot "sample"
& $PacExe copilot clone --environment $OrgNoTrail --agent $AgentName --output-dir $sampleDir
if ($LASTEXITCODE -ne 0) { Write-Error "pac copilot clone failed ($LASTEXITCODE)" }
$agentDir = Join-Path $sampleDir $AgentName

# ── Step 3: Validate no topics (Classic indicator) ───────────────────────────
Write-Host "[3/6] Checking for Classic topics (not supported in Modern agents)..." -ForegroundColor Yellow
$topicsDir = Join-Path $agentDir "topics"
if (Test-Path $topicsDir) {
    $topicFiles = Get-ChildItem $topicsDir -Filter "*.mcs.yml"
    # System topics are OK; custom topics indicate a Classic/hybrid agent
    $customTopics = $topicFiles | Where-Object { $_.Name -notmatch "^(Greeting|Goodbye|Escalate|EndofConversation|Fallback|OnError|MultipleTopicsMatched|ResetConversation|StartOver|ThankYou|Signin|Search)\.mcs\.yml$" }
    if ($customTopics.Count -gt 0) {
        Write-Host "  WARNING: $($customTopics.Count) custom topic(s) found:" -ForegroundColor DarkYellow
        $customTopics | ForEach-Object { Write-Host "    - $($_.Name)" -ForegroundColor DarkYellow }
        Write-Host "  Modern Copilot Studio agents do not use topics for orchestration." -ForegroundColor DarkYellow
        Write-Host "  This agent may be a hybrid or Classic agent. Export continues but import may behave unexpectedly." -ForegroundColor DarkYellow
    } else {
        Write-Host "  -> No custom topics found ✓" -ForegroundColor Green
    }
} else {
    Write-Host "  -> No topics directory ✓" -ForegroundColor Green
}

# ── Step 4: Export authoritative bot.configuration ───────────────────────────
Write-Host "[4/6] Exporting bot.configuration (authoritative instructions + model)..." -ForegroundColor Yellow
$configJson = $botResult.configuration
if ($configJson.Length -gt 0) {
    $configJson | Set-Content (Join-Path $sampleDir "agent-config.json") -Encoding UTF8
    # Parse and show what's inside
    $configObj = $configJson | ConvertFrom-Json
    $instrLen  = $configObj.agentSettings.instructions.segments[0].value.Length
    $model     = $configObj.agentSettings.model.series
    Write-Host "  -> sample\agent-config.json saved" -ForegroundColor Green
    Write-Host "     Model       : $model"
    Write-Host "     Instructions: $instrLen chars"

    # Warn if YAML instructions differ (stale check)
    $settingsPath = Join-Path $agentDir "settings.mcs.yml"
    if (Test-Path $settingsPath) {
        $yamlContent  = Get-Content $settingsPath -Raw
        $configInstr  = $configObj.agentSettings.instructions.segments[0].value.Substring(0, [Math]::Min(80, $instrLen))
        if ($yamlContent -notlike "*$($configInstr.Substring(0,50))*") {
            Write-Host "  WARNING: settings.mcs.yml instructions differ from bot.configuration." -ForegroundColor DarkYellow
            Write-Host "  The Copilot Studio UI was used to edit instructions after last pac push." -ForegroundColor DarkYellow
            Write-Host "  agent-config.json is the authoritative source — install.ps1 will use it." -ForegroundColor DarkYellow
        }
    }
} else {
    Write-Warning "  bot.configuration is empty — instructions will not be exported."
}

# ── Step 5: Inventory all botcomponents and export skills ────────────────────
Write-Host "[5/6] Inventorying and exporting all botcomponents..." -ForegroundColor Yellow
$comps = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotid_value eq '$BotId'&`$select=botcomponentid,name,componenttype,data,content,msdyn_referenceresource" -Headers $headers).value

$skillsDir = Join-Path $RepoRoot "skills"
New-Item -ItemType Directory -Force -Path $skillsDir | Out-Null

$skillCount  = 0
$warnings    = @()

foreach ($c in $comps) {
    switch ($c.componenttype) {
        9 {
            # Could be: TaskDialog (flow tool), InlineAgentSkill (knowledge), ConnectorTool, or child agent ref
            if ($c.data -like "*InlineAgentSkill*") {
                # Extract .md content from YAML data block
                $content = if ($c.data -match "(?s)content:\s*\|-\s*\n(.*?)(?:\n[^\s]|\z)") {
                    $Matches[1] -replace "(?m)^  ", ""
                } else { $c.data }
                $safeName = ($c.name -replace '[\\/:*?"<>|]', '-').Trim()
                $content | Set-Content (Join-Path $skillsDir "$safeName.md") -Encoding UTF8
                Write-Host "  -> Skill exported : $safeName.md" -ForegroundColor Green
                $skillCount++
            } elseif ($c.data -like "*TaskDialog*") {
                Write-Host "  -> Tool (flow)    : $($c.name) — captured in actions/*.mcs.yml" -ForegroundColor DarkGray
            } elseif ($c.data -like "*ConnectorTool*" -or $c.data -like "*ManagedConnectorTool*") {
                Write-Host "  -> Tool (connector): $($c.name) — NOTE: connector must exist in target env" -ForegroundColor DarkYellow
                $warnings += "Connector tool '$($c.name)' requires the same connector to be available and DLP-allowed in the target environment."
            } elseif ($c.data -like "*childAgentId*" -or $c.data -like "*AgentReference*") {
                Write-Host "  -> Connected agent: $($c.name) — WARNING: env-specific, requires manual re-link" -ForegroundColor DarkYellow
                $warnings += "Connected agent '$($c.name)' has an env-specific bot ID. You must manually re-connect it in the target environment after import."
            } else {
                Write-Host "  -> Type 9 other   : $($c.name)" -ForegroundColor DarkGray
            }
        }
        16 {
            # URL knowledge source — just a URL, no content to export
            Write-Host "  -> URL knowledge  : $($c.name) — NOTE: URL only, must be accessible from target env" -ForegroundColor DarkYellow
            $warnings += "URL knowledge source '$($c.name)' will be re-created in target env. Ensure the URL is publicly accessible or accessible from that tenant."
        }
        19 {
            Write-Host "  -> Eval test case : $($c.name)" -ForegroundColor DarkGray
        }
        15 {
            Write-Host "  -> GPT config     : (captured in YAML)" -ForegroundColor DarkGray
        }
        default {
            Write-Host "  -> Type $($c.componenttype): $($c.name) — not specifically handled" -ForegroundColor DarkGray
        }
    }
}

# ── Step 6: Export connection references from workflow files ─────────────────
Write-Host "[6/6] Documenting connector requirements from workflow definitions..." -ForegroundColor Yellow
$connectors = @{}
Get-ChildItem (Join-Path $agentDir "workflows") -Filter "workflow.json" -Recurse | ForEach-Object {
    $wf = Get-Content $_.FullName -Raw | ConvertFrom-Json
    $wf.properties.connectionReferences.PSObject.Properties | ForEach-Object {
        $apiName = $_.Value.api.name
        $connRef = $_.Value.connection.connectionReferenceLogicalName
        if (-not $connectors.ContainsKey($apiName)) {
            $connectors[$apiName] = $connRef
            Write-Host "  -> Connector required: $apiName (source connRef: $connRef)" -ForegroundColor Cyan
        }
    }
}
# Save connector map for install.ps1
$connectors | ConvertTo-Json | Set-Content (Join-Path $sampleDir "connectors.json") -Encoding UTF8
Write-Host "  -> sample\connectors.json saved ($($connectors.Count) connector(s))" -ForegroundColor Green

# ── Summary ───────────────────────────────────────────────────────────────────
$yamlCount = (Get-ChildItem $agentDir -Filter "*.mcs.yml" -Recurse).Count
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Export Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  YAML files         : $yamlCount"
Write-Host "  agent-config.json  : $(if ($configJson.Length -gt 0) {'saved (authoritative)'} else {'MISSING'})"
Write-Host "  connectors.json    : $($connectors.Count) connector(s) required"
Write-Host "  Skill files        : $skillCount"

if ($warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "Manual steps required after import:" -ForegroundColor Yellow
    $warnings | ForEach-Object { Write-Host "  ! $_" -ForegroundColor Yellow }
}

Write-Host ""
Write-Host "Commit this repo. Importers run: scripts\install.ps1"


