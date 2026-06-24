<#
.SYNOPSIS
    Export a Modern Copilot Studio agent as a distributable solution package.

.DESCRIPTION
    Produces two artifacts:
      agent.zip                — full solution package (pac solution export)
      skills-with-assets/      — binary skill bundles not included in the ZIP
      agent-config.json        — bot.configuration snapshot (documentation/verify)

    pac solution import handles almost everything: bot.configuration, InlineAgentSkills,
    ConnectorTool, McpTool, ConnectedAgentTool, WorkflowTool, TaskDialog, eval cases, and
    connection reference stubs. The one gap: skills uploaded as ZIP files (Python/binary
    assets) store a bundle reference token (bic:bundle=...) that pac solution export does
    NOT capture. This script exports those binary blobs separately so install.ps1 can
    re-upload them post-import.

.PARAMETER PacExe
    Path to pac.exe. Auto-detected from PATH or NuGet cache if omitted.

.PARAMETER SourceOrgUrl
    Dataverse environment URL, e.g. https://myorg.crm.dynamics.com

.PARAMETER AgentName
    Display name of the agent to export.

.PARAMETER BotId
    GUID of the bot record in Dataverse.

.PARAMETER SolutionName
    Optional. Name of an existing named solution that already contains the bot.
    If omitted, the script creates a new distribution solution and adds the bot with
    AddRequiredComponents=true (required to include botcomponents).

.PARAMETER PublisherPrefix
    Publisher prefix for the new distribution solution (default: "cr7a0").

.PARAMETER AuthIndex
    pac auth profile index (default: 1).

.PARAMETER OutputDir
    Output directory for agent.zip and skills-with-assets/. Default: current directory.

.EXAMPLE
    .\path1-solution\export.ps1 `
      -SourceOrgUrl "https://myorg.crm.dynamics.com" `
      -AgentName    "Fabric Analyst" `
      -BotId        "d01d7579-bf47-4da7-b751-22a419ade844"

.EXAMPLE
    .\path1-solution\export.ps1 `
      -SourceOrgUrl  "https://myorg.crm.dynamics.com" `
      -AgentName     "Fabric Analyst" `
      -BotId         "d01d7579-bf47-4da7-b751-22a419ade844" `
      -SolutionName  "FabricAnalystSample" `
      -OutputDir     "C:\releases\v1.0"
#>
param(
    [string]$PacExe         = "",
    [Parameter(Mandatory)][string]$SourceOrgUrl,
    [Parameter(Mandatory)][string]$AgentName,
    [Parameter(Mandatory)][string]$BotId,
    [string]$SolutionName   = "",
    [string]$PublisherPrefix = "cr7a0",
    [int]   $AuthIndex      = 1,
    [string]$OutputDir      = (Get-Location).Path
)

$ErrorActionPreference = "Stop"

# ── Helper functions ──────────────────────────────────────────────────────────
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

$OrgNoTrail = $SourceOrgUrl.TrimEnd("/")
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

Write-Host ""
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Modern Agent Export — Solution Path"       -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Source : $OrgNoTrail"
Write-Host "  Agent  : $AgentName ($BotId)"
Write-Host "  Output : $OutputDir"

# ── Step 1: Validate agent + acquire DV token ─────────────────────────────────
Step "[1/7] Validating agent and acquiring Dataverse token..."

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
    ERR "This toolkit only supports Modern agents (template: cliagent-1.0.0). Classic agents use pac copilot clone/push directly."
}
OK "Template: cliagent-1.0.0 (Modern)"
INFO "Schema: $($bot.schemaname)"

# ── Step 2: Locate or create distribution solution ────────────────────────────
Step "[2/7] Preparing distribution solution..."

& $PacExe auth select --index $AuthIndex | Out-Null

if ($SolutionName) {
    # Verify provided solution exists
    $solCheck = & $PacExe solution list --environment $OrgNoTrail 2>&1
    if ($solCheck -notmatch $SolutionName) {
        ERR "Solution '$SolutionName' not found in $OrgNoTrail. Verify the name or omit -SolutionName to create one."
    }
    OK "Using existing solution: $SolutionName"
} else {
    # Build a safe solution name from agent name
    $SolutionName = ($AgentName -replace '[^A-Za-z0-9]', '') + "Sample"
    INFO "Creating solution: $SolutionName"

    # Check if publisher exists
    $pubs = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/publishers?`$filter=customizationprefix eq '$PublisherPrefix'&`$select=publisherid,uniquename" -Headers $headers).value
    if ($pubs.Count -eq 0) {
        ERR "Publisher with prefix '$PublisherPrefix' not found. Create it in PPAC or pass -PublisherPrefix with an existing prefix."
    }
    $publisherUniqueName = $pubs[0].uniquename
    INFO "Publisher: $publisherUniqueName (prefix: $PublisherPrefix)"

    # Create solution
    & $PacExe solution create --display-name $SolutionName --name $SolutionName --publisher-name $publisherUniqueName --environment $OrgNoTrail 2>&1 | ForEach-Object { INFO $_ }
    if ($LASTEXITCODE -ne 0) {
        WARN "Solution creation may have failed or already exists — continuing"
    } else {
        OK "Solution '$SolutionName' created"
    }

    # Add bot with AddRequiredComponents=true (CRITICAL: includes botcomponents)
    INFO "Adding bot to solution (AddRequiredComponents=true)..."
    $addBody = @{
        ComponentId           = $BotId
        ComponentType         = 380
        SolutionUniqueName    = $SolutionName
        AddRequiredComponents = $true
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/AddSolutionComponent" -Method POST -Headers ($headers + @{"Content-Type"="application/json"}) -Body $addBody | Out-Null
    OK "Bot added to solution with all required components"
}

# ── Step 3: pac solution export ───────────────────────────────────────────────
Step "[3/7] Exporting solution package (pac solution export)..."

$zipPath = Join-Path $OutputDir "agent.zip"
& $PacExe solution export --path $zipPath --name $SolutionName --environment $OrgNoTrail --overwrite 2>&1 | ForEach-Object { INFO $_ }
if ($LASTEXITCODE -ne 0) { ERR "pac solution export failed (exit $LASTEXITCODE)" }
$zipSize = (Get-Item $zipPath).Length / 1KB
OK "agent.zip saved ($([math]::Round($zipSize,1)) KB)"

# ── Step 4: Verify ZIP contents ───────────────────────────────────────────────
Step "[4/7] Verifying ZIP contents..."

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip     = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
$entries = $zip.Entries | Select-Object -ExpandProperty FullName
$zip.Dispose()

$botFiles    = @($entries | Where-Object { $_ -like "*/bot/*" -or $_ -like "*/bots/*" })
$configEntry = @($entries | Where-Object { $_ -like "*configuration.json*" })
$compEntries = @($entries | Where-Object { $_ -like "*botcomponent*" })

INFO "Total ZIP entries    : $($entries.Count)"
INFO "Bot records          : $($botFiles.Count)"
INFO "configuration.json   : $(if ($configEntry.Count -gt 0) {'PRESENT ✓'} else {'MISSING ✗'})"
INFO "Botcomponents        : $($compEntries.Count)"

if ($configEntry.Count -eq 0) {
    WARN "configuration.json not found in ZIP. bot.configuration may not be included."
    WARN "Ensure the bot was added with AddRequiredComponents=true."
}
if ($compEntries.Count -eq 0) {
    WARN "No botcomponent records in ZIP. AddRequiredComponents may not have worked."
}

# ── Step 5: Export skills-with-assets ────────────────────────────────────────
Step "[5/7] Checking for skills with binary assets (bic:bundle= tokens)..."

$comps = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotid_value eq '$BotId' and componenttype eq 9&`$select=botcomponentid,name,schemaname,data" -Headers $headers).value
$skillsWithAssets = @($comps | Where-Object { $_.data -like "*bic:bundle=*" })

if ($skillsWithAssets.Count -eq 0) {
    OK "No skills-with-assets found (no binary bundle re-upload needed)"
} else {
    WARN "$($skillsWithAssets.Count) skill(s) with binary assets found — exporting blobs..."
    $skillsDir = Join-Path $OutputDir "skills-with-assets"
    New-Item -ItemType Directory -Force -Path $skillsDir | Out-Null

    $manifest = @()
    $dlHeaders = @{} + $headers + @{ Accept = "application/octet-stream" }

    foreach ($skill in $skillsWithAssets) {
        INFO "Skill: $($skill.name)"
        $skillDir = Join-Path $skillsDir $skill.name
        New-Item -ItemType Directory -Force -Path $skillDir | Out-Null

        # Get child file components (type 14)
        $files = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotcomponentid_value eq '$($skill.botcomponentid)' and componenttype eq 14&`$select=botcomponentid,name,filedata_name" -Headers $headers).value

        $exportedFiles = @()
        foreach ($file in $files) {
            $fileName = if ($file.filedata_name) { $file.filedata_name } else { "$($file.name).bin" }
            $destPath = Join-Path $skillDir $fileName
            try {
                $bytes = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents($($file.botcomponentid))/filedata" -Headers $dlHeaders
                if ($bytes -is [string]) {
                    # Some environments return base64-encoded content
                    $rawBytes = [System.Convert]::FromBase64String($bytes)
                    [System.IO.File]::WriteAllBytes($destPath, $rawBytes)
                } else {
                    [System.IO.File]::WriteAllBytes($destPath, $bytes)
                }
                $fileSizeKB = [math]::Round((Get-Item $destPath).Length / 1KB, 1)
                OK "    $fileName ($fileSizeKB KB)"
                $exportedFiles += $fileName
            } catch {
                WARN "    Failed to download $fileName : $_"
            }
        }

        $manifest += @{
            skillName       = $skill.name
            schemaName      = $skill.schemaname
            botComponentId  = $skill.botcomponentid
            files           = $exportedFiles
            dataSnippet     = ($skill.data | Select-Object -First 1).Substring(0, [Math]::Min(200, $skill.data.Length))
        }
    }

    $manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $skillsDir "manifest.json") -Encoding UTF8
    OK "skills-with-assets\manifest.json saved ($($skillsWithAssets.Count) skill(s))"
    WARN "Add skills-with-assets/ folder alongside agent.zip when distributing"
}

# ── Step 6: Export bot.configuration snapshot ────────────────────────────────
Step "[6/7] Exporting bot.configuration snapshot..."

$cfg = $bot.configuration
if ($cfg -and $cfg.Length -gt 10) {
    $cfg | Set-Content (Join-Path $OutputDir "agent-config.json") -Encoding UTF8
    try {
        $cfgObj   = $cfg | ConvertFrom-Json
        $instrLen = $cfgObj.agentSettings.instructions.segments[0].value.Length
        $model    = $cfgObj.agentSettings.model.series
        OK "agent-config.json saved"
        INFO "Model       : $model"
        INFO "Instructions: $instrLen chars"
    } catch {
        OK "agent-config.json saved (could not parse for preview)"
    }
} else {
    WARN "bot.configuration is empty — agent-config.json not saved"
}

# ── Step 7: List connection references needing manual wiring ─────────────────
Step "[7/7] Identifying connection references (require manual wiring)..."

$connRefs = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/connectionreferences?`$filter=_botid_value eq '$BotId'&`$select=connectionreferenceid,connectionreferencelogicalname,customconnectorid" -Headers $headers -ErrorAction SilentlyContinue).value
if ($null -eq $connRefs) { $connRefs = @() }

if ($connRefs.Count -gt 0) {
    INFO "$($connRefs.Count) connection reference(s) — recipient must wire these manually:"
    foreach ($cr in $connRefs) {
        INFO "  • $($cr.connectionreferencelogicalname)"
    }
} else {
    OK "No connection references detected via API (check connectionreferences.mcs.yml if present)"
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Export Complete"                           -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Files produced:"
Write-Host "    agent.zip            — solution package ($([math]::Round($zipSize,1)) KB)"
Write-Host "    agent-config.json    — bot.configuration snapshot"
if ($skillsWithAssets.Count -gt 0) {
    Write-Host "    skills-with-assets/  — $($skillsWithAssets.Count) skill bundle(s)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  DISTRIBUTE: agent.zip + agent-config.json + skills-with-assets/" -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "  DISTRIBUTE: agent.zip + agent-config.json" -ForegroundColor Green
}
Write-Host ""
Write-Host "  Recipients run: path1-solution\install.ps1"
Write-Host ""
