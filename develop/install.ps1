<#
.SYNOPSIS
    Deploy a Modern Copilot Studio agent and apply your VS Code edits, reliably.

.DESCRIPTION
    Takes the output of develop/export.ps1 — a deployable bundle ZIP plus the editable files in
    sample/ — and deploys it to a target environment WITHOUT pac copilot push (which is unreliable
    for cliagent-* agents). Deployment uses Dataverse solution import for structure, then applies
    your local edits via targeted Dataverse writes.

    ─────────────────────────────────────────────────────────────────────────────
    WHAT YOU CAN EDIT IN VS CODE (and this script deploys)
    ─────────────────────────────────────────────────────────────────────────────
      • Agent instructions      sample/<Agent>.instructions.md   (the system prompt / behaviour)
      • Model + AI settings      sample/agent-config.json         (model series, content moderation…)
      • Inline skill content     sample/<Agent>/translations/*.skill.*.mcs.yml  (markdown skills)
      • Tool / knowledge wording sample/<Agent>/translations/*, knowledge/*      (descriptions)

      These are applied to existing components via reliable Dataverse writes.

    ─────────────────────────────────────────────────────────────────────────────
    WHAT YOU MUST DO IN THE COPILOT STUDIO UI (then re-run develop/export.ps1)
    ─────────────────────────────────────────────────────────────────────────────
      • ADD or REMOVE a tool, connector, or flow   (needs connection wiring / Power Automate)
      • ADD a skill that runs Python / code         (needs the server-side bundle upload)
      • ADD file knowledge (PDF, DOCX)              (needs the binary upload gateway)

      These change the agent's STRUCTURE. There is no reliable CLI path to push new structural
      components for cliagent-* agents, so build them once in Copilot Studio, then re-export to
      bring the new structure into your bundle and local files.

    ─────────────────────────────────────────────────────────────────────────────
    THE ONE RUNTIME STEP THAT ALWAYS APPLIES: PUBLISH
    ─────────────────────────────────────────────────────────────────────────────
      Dataverse writes update the agent's authoring (draft) copy. To make changes live on
      channels you must PUBLISH. pac copilot publish crashes for cliagent-* agents, so this is a
      one-click step in Copilot Studio. This script opens the agent and tells you exactly where.

    PREREQUISITES
    ─────────────
    pac CLI / az CLI, pac auth + az login with access to the target environment.

.PARAMETER BundleZip      Path to the <Agent>-bundle.zip produced by develop/export.ps1.
.PARAMETER SampleDir      Path to the sample/ folder with your edited files. Defaults to repo sample/.
.PARAMETER AgentName      Display name (the sample/<AgentName>/ subfolder). Auto-detected if omitted.
.PARAMETER TargetOrgUrl   Dataverse org URL for the target environment.
.PARAMETER AuthIndex      pac auth index for the target environment.
.PARAMETER PacExe         Path to pac.exe. Auto-detected if not specified.

.EXAMPLE
    .\install.ps1 -BundleZip ..\My-Agent-bundle.zip -TargetOrgUrl https://target.crm.dynamics.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $BundleZip,
    [string] $SampleDir    = "",
    [string] $AgentName    = "",
    [Parameter(Mandatory)][string] $TargetOrgUrl,
    [int]    $AuthIndex    = 1,
    [string] $PacExe       = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir  = Split-Path $MyInvocation.MyCommand.Path -Parent
$RepoRoot   = Split-Path $ScriptDir -Parent
$SampleDir  = if ($SampleDir) { $SampleDir } else { Join-Path $RepoRoot "sample" }
$OrgNoTrail = $TargetOrgUrl.TrimEnd("/")

if (-not $PacExe) {
    $PacExe = (Get-Command "pac" -ErrorAction SilentlyContinue)?.Source
    if (-not $PacExe) {
        $PacExe = Get-ChildItem "$env:USERPROFILE\.nuget\packages\microsoft.powerapps.cli" -Filter "pac.exe" -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $PacExe) { Write-Error "pac CLI not found. Install: https://aka.ms/PowerPlatformCLI" }
}

function Step([string]$msg) { Write-Host "`n>>> $msg" -ForegroundColor Cyan }
function OK([string]$msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }
function WARN([string]$msg) { Write-Host "    !   $msg" -ForegroundColor Yellow }
function INFO([string]$msg) { Write-Host "        $msg" -ForegroundColor DarkGray }

# Resolve the Power Platform environment GUID for an org URL (for a working Copilot Studio link).
function Resolve-EnvId {
    param([string]$OrgUrl, [string]$PacExePath, [int]$AuthIdx)
    try {
        & $PacExePath auth select --index $AuthIdx | Out-Null
        $orgHost = ([Uri]$OrgUrl).Host
        foreach ($ln in (& $PacExePath env list 2>$null)) {
            if ($ln -match [regex]::Escape($orgHost) -and
                $ln -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { return $Matches[1] }
        }
    } catch {}
    return $null
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Modern Agent Deploy -- Develop (edit) Path" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Target : $OrgNoTrail"
Write-Host ""

# ── Resolve bundle ────────────────────────────────────────────────────────────
Step "Resolving bundle + edited files"
if (-not (Test-Path $BundleZip)) { Write-Error "BundleZip not found: $BundleZip" }
$tempExtractDir = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-bundle-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempExtractDir | Out-Null
Expand-Archive -Path $BundleZip -DestinationPath $tempExtractDir -Force
$zipPath      = Join-Path $tempExtractDir "agent.zip"
$manifestPath = Join-Path $tempExtractDir "manifest.json"
if (-not (Test-Path $zipPath))      { Write-Error "agent.zip not found in bundle" }
if (-not (Test-Path $manifestPath)) { Write-Error "manifest.json not found in bundle" }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$agentSchema = $manifest.agentSchema
if (-not $AgentName) { $AgentName = $manifest.agentName }
$agentDir = Join-Path $SampleDir $AgentName
OK "Agent: $AgentName  (schema: $agentSchema)"
if (Test-Path $agentDir) { OK "Edited files: sample\$AgentName\" } else { WARN "sample\$AgentName\ not found -- will deploy bundle as-is (no local edits applied)" }

# ── DV token ──────────────────────────────────────────────────────────────────
$token = (az account get-access-token --resource $OrgNoTrail | ConvertFrom-Json).accessToken
$dv = @{ Authorization="Bearer $token"; "OData-MaxVersion"="4.0"; "OData-Version"="4.0"; Accept="application/json"; "Content-Type"="application/json"; Prefer="return=representation" }
$dvBase = "$OrgNoTrail/api/data/v9.2"

# ── Step 1: Solution import (reliable structure) ─────────────────────────────
Step "Step 1 -- Import agent structure (pac solution import)"
INFO "Reliable path: imports bot, all tools/skills/flows/knowledge/eval cases. No pac push."
& $PacExe auth select --index $AuthIndex | Out-Null
& $PacExe solution import --path $zipPath --environment $OrgNoTrail 2>&1 | ForEach-Object { INFO $_ }
if ($LASTEXITCODE -ne 0) { Write-Error "pac solution import failed" }
OK "Solution imported"

# Locate the imported bot
$bot = (Invoke-RestMethod -Uri "$dvBase/bots?`$filter=schemaname eq '$agentSchema'&`$select=botid,name" -Headers $dv).value | Select-Object -First 1
if (-not $bot) { Write-Error "Imported bot not found (schema $agentSchema)" }
$botId = $bot.botid
OK "Bot: $($bot.name) ($botId)"

# ── Step 2: Apply instruction / model / AI-settings edits (bot.configuration) ─
Step "Step 2 -- Apply your instruction + model edits (bot.configuration)"
$configPath = Join-Path $SampleDir "agent-config.json"
$instrPath  = Join-Path $SampleDir "$AgentName.instructions.md"
if (Test-Path $configPath) {
    $cfgJson = Get-Content $configPath -Raw
    $cfgObj  = $cfgJson | ConvertFrom-Json
    # instructions.md is the friendly edit surface — if present, it wins over agent-config.json.
    if (Test-Path $instrPath) {
        $md = (Get-Content $instrPath -Raw) -replace '(?m)^\s*<!--.*?-->\s*$', ''   # drop helper comment lines
        $md = $md.Trim()
        if ($md -and $cfgObj.agentSettings.instructions.segments.Count -gt 0) {
            $cfgObj.agentSettings.instructions.segments[0].value = $md
            $cfgJson = $cfgObj | ConvertTo-Json -Depth 50
            INFO "Instructions taken from $AgentName.instructions.md ($($md.Length) chars)"
        }
    }
    # bot.configuration is a STRING field in Dataverse — ConvertTo-Json -Depth 1 string-encodes it.
    $body = @{ configuration = $cfgJson } | ConvertTo-Json -Depth 1
    Invoke-RestMethod -Uri "$dvBase/bots($botId)" -Method PATCH -Headers $dv -Body $body | Out-Null
    OK "bot.configuration applied (model: $($cfgObj.agentSettings.model.series))"
} else {
    INFO "No agent-config.json -- keeping instructions/model from the imported bundle"
}

# ── Step 3: Apply inline-skill + description edits (existing component data) ──
Step "Step 3 -- Apply your skill / description edits (component data)"
$translDir = Join-Path $agentDir "translations"
$patched = 0; $skippedAssets = 0
if (Test-Path $translDir) {
    # Map target components by name for matching.
    $targetComps = (Invoke-RestMethod -Uri "$dvBase/botcomponents?`$filter=_parentbotid_value eq '$botId' and componenttype eq 9&`$select=botcomponentid,name,data" -Headers $dv).value
    foreach ($file in (Get-ChildItem $translDir -Filter "*.mcs.yml")) {
        $raw = Get-Content $file.FullName -Raw
        $name = if ($raw -match "(?m)^\s*componentName:\s*(.+)$") { $Matches[1].Trim().Trim('"') } else { $null }
        $idx  = $raw.IndexOf("kind:")
        if (-not $name -or $idx -lt 0) { continue }
        $localData = $raw.Substring($idx).TrimEnd()
        # Skills with code assets carry a bic:bundle= pointer — those are handled by manual upload
        # (Step 4), not by a data patch. Skip them here.
        if ($localData -match "bic:bundle=") { $skippedAssets++; continue }
        $tc = $targetComps | Where-Object { $_.name -eq $name } | Select-Object -First 1
        if (-not $tc) { continue }
        if (($tc.data ?? "").TrimEnd() -eq $localData) { continue }   # unchanged — no write
        Invoke-RestMethod -Uri "$dvBase/botcomponents($($tc.botcomponentid))" -Method PATCH -Headers $dv -Body (@{ data = $localData } | ConvertTo-Json -Depth 1) | Out-Null
        OK "  Updated '$name'"
        $patched++
    }
}
if ($patched -eq 0) { INFO "No inline component edits to apply (everything matches the bundle)" }
if ($skippedAssets -gt 0) { INFO "$skippedAssets code-asset skill(s) handled in Step 4, not here" }

# ── Step 4: Skills with code assets — manual re-upload ───────────────────────
$skillsWithAssets = @()
if ($manifest.PSObject.Properties["skillsWithAssets"]) { $skillsWithAssets = @($manifest.skillsWithAssets) }
$envId = Resolve-EnvId -OrgUrl $OrgNoTrail -PacExePath $PacExe -AuthIdx $AuthIndex
if (-not $envId) { $envId = $OrgNoTrail -replace "https://","" -replace "\.crm\.dynamics\.com","" }
$agentUrl = "https://copilotstudio.microsoft.com/environments/$envId/agents/$botId"

if ($skillsWithAssets.Count -gt 0) {
    Step "Step 4 -- Skills with code assets need a one-time manual upload ($($skillsWithAssets.Count))"
    $skillSrcRoot = Join-Path $tempExtractDir "skills-with-assets"
    $reupload = @()
    foreach ($s in $skillsWithAssets) {
        $sName = if ($s.PSObject.Properties["skill"]) { $s.skill } else { $s }
        $sDir  = Join-Path $skillSrcRoot $sName
        if (Test-Path $sDir) {
            $zp = Join-Path (Split-Path (Resolve-Path $BundleZip).Path -Parent) "$sName-skill.zip"
            if (Test-Path $zp) { Remove-Item $zp -Force }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $z = [System.IO.Compression.ZipFile]::Open($zp,'Create')
            try { Get-ChildItem $sDir -File | ForEach-Object { [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z,$_.FullName,$_.Name)|Out-Null } } finally { $z.Dispose() }
            $reupload += @{ name=$sName; zip=$zp }
            OK "  Ready to upload: $zp"
        }
    }
    Write-Host ""
    Write-Host "  These skills run Python/code. The code bundle is created only by uploading the" -ForegroundColor Yellow
    Write-Host "  ZIP through the Copilot Studio UI (no API exists). Until then the skill is empty." -ForegroundColor Yellow
    Write-Host "  For each skill: open the agent > click the skill > three-dot menu > Replace/Edit > upload the ZIP > Save." -ForegroundColor White
}

# ── Step 5: Connection wiring (if connectors present) ────────────────────────
$connectors = @()
if ($manifest.PSObject.Properties["connectorsRequired"] -and $manifest.connectorsRequired) { $connectors = @($manifest.connectorsRequired) }
if ($connectors.Count -gt 0) {
    Step "Step 5 -- Wire connections (one-time per environment)"
    Write-Host "    Connector(s) used by this agent's flows:" -ForegroundColor Yellow
    $connectors | ForEach-Object { Write-Host "      - $_" -ForegroundColor White }
    Write-Host "    In https://make.powerautomate.com (your target env): open each flow, assign a" -ForegroundColor White
    Write-Host "    connection per connector, save and turn it on." -ForegroundColor White
}

# ── Step 6: PUBLISH (the one runtime step that always applies) ────────────────
Step "Step 6 -- Publish to make your changes live (one click)"
Write-Host "  Your edits are saved to the agent's authoring copy. To go live you must PUBLISH." -ForegroundColor Yellow
Write-Host "  (pac copilot publish crashes for cliagent-* agents, so this is a one-click UI step.)" -ForegroundColor DarkGray
Write-Host "    1. Open: $agentUrl" -ForegroundColor White
Write-Host "    2. Click 'Publish' (top-right) and confirm." -ForegroundColor White
try { Start-Process $agentUrl; INFO "Opening agent in browser..." } catch { WARN "Open manually: $agentUrl" }

# ── Cleanup + summary ─────────────────────────────────────────────────────────
if (Test-Path $tempExtractDir) { Remove-Item $tempExtractDir -Recurse -Force }

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Deploy Complete" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "  Agent : $($bot.name) ($botId)"
Write-Host "  URL   : $agentUrl" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Applied:"
Write-Host "    [x] Structure imported (tools, skills, flows, knowledge, eval cases)"
Write-Host "    [x] Instructions + model/AI settings"
if ($patched -gt 0) { Write-Host "    [x] $patched inline component edit(s)" } else { Write-Host "    [-] No inline component edits" }
if ($skillsWithAssets.Count -gt 0) { Write-Host "    [!] $($skillsWithAssets.Count) code-asset skill(s): upload ZIP in CS (Step 4)" -ForegroundColor Yellow }
if ($connectors.Count -gt 0)       { Write-Host "    [!] Wire connection(s) in Power Automate (Step 5)" -ForegroundColor Yellow }
Write-Host "    [>] PUBLISH in Copilot Studio to go live (Step 6)" -ForegroundColor Yellow
