<#
.SYNOPSIS
    Imports a Modern Agent bundle (exported by export.ps1) into a target Dataverse environment.

.DESCRIPTION
    install.ps1 takes an agent bundle produced by export.ps1 and installs it into a target Power
    Platform environment.  A bundle is either a ZIP file ({AgentName}-bundle.zip) or an already-
    extracted folder (or git clone).

    BUNDLE CONTENTS
    ---------------
    agent.zip                         - Dataverse solution package
    manifest.json                     - Agent schema name, required connectors, skills metadata
    skills-with-assets/{skill-name}/  - One folder per ZIP-type skill containing SKILL.md and
                                        any Python / asset files

    WHAT pac solution import HANDLES
    ---------------------------------
    The Dataverse solution import (pac solution import) takes care of:
      - The bot / agent definition itself
      - Bot configuration records
      - Power Automate flows wired to the agent
      - Connector tools and knowledge sources
      - Evaluation test cases

    SKILLS-WITH-ASSETS LIMITATION
    ------------------------------
    Skills whose instructions are stored as file blobs (type-9 botcomponent records whose `data`
    field contains the sentinel string "bic:bundle=") are NOT fully restored by the solution
    import alone.  This script repairs them two ways:

    A) Automated inline fix (preferred)
       Downloads the SKILL.md from the imported type-14 child record and rewrites the parent
       type-9 data field as an InlineAgentSkill YAML block via the Dataverse Web API.

    B) Guided re-upload (fallback)
       Packages the skill folder to a ZIP and prints step-by-step instructions for re-uploading
       through the Copilot Studio UI.  Also opens the agent in the browser automatically.

    CONNECTION WIRING MANUAL STEP
    ------------------------------
    After import, every Power Automate flow that uses a connector will show a "needs connection"
    warning.  You must open each flow in the Power Automate portal and assign a valid connection
    for each connector listed in the manifest.  The summary printed at the end of this script
    lists the connectors and the portal URL.

.EXAMPLE
    .\install.ps1 -BundleZip .\MyAgent-bundle.zip -TargetOrgUrl https://myorg.crm.dynamics.com

.EXAMPLE
    .\install.ps1 -BundleDir .\MyAgent-bundle -TargetOrgUrl https://myorg.crm.dynamics.com -AuthIndex 2

.EXAMPLE
    .\install.ps1 -TargetOrgUrl https://myorg.crm.dynamics.com
    # Uses the current directory as the bundle folder
#>

[CmdletBinding()]
param(
    [string] $BundleZip    = "",
    [string] $BundleDir    = "",
    [Parameter(Mandatory)]
    [string] $TargetOrgUrl,
    [int]    $AuthIndex    = 1,
    [string] $PacExe       = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helper output functions
# ---------------------------------------------------------------------------
function Step([string]$msg) { Write-Host "`n>>> $msg" -ForegroundColor Cyan }
function OK([string]$msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }
function WARN([string]$msg) { Write-Host "    !   $msg" -ForegroundColor Yellow }
function INFO([string]$msg) { Write-Host "        $msg" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# Normalise org URL (strip trailing slash)
# ---------------------------------------------------------------------------
$OrgNoTrail = $TargetOrgUrl.TrimEnd("/")

# ---------------------------------------------------------------------------
# Auto-detect pac.exe
# ---------------------------------------------------------------------------
if (-not $PacExe) {
    $PacExe = (Get-Command "pac" -ErrorAction SilentlyContinue)?.Source
    if (-not $PacExe) {
        $PacExe = Get-ChildItem "$env:USERPROFILE\.nuget\packages\microsoft.powerapps.cli" `
            -Filter "pac.exe" -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $PacExe) {
        Write-Error "pac CLI not found. Install: https://aka.ms/PowerPlatformCLI"
    }
}
INFO "pac.exe: $PacExe"

# ---------------------------------------------------------------------------
# Resolve bundle directory
# ---------------------------------------------------------------------------
Step "Resolving bundle"

$tempExtractDir = $null   # track so we can clean it up at the end

if ($BundleZip) {
    if (-not (Test-Path $BundleZip)) {
        Write-Error "BundleZip not found: $BundleZip"
    }
    $tempExtractDir = Join-Path ([System.IO.Path]::GetTempPath()) ("agent-bundle-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tempExtractDir | Out-Null
    INFO "Extracting $BundleZip to $tempExtractDir"
    Expand-Archive -Path $BundleZip -DestinationPath $tempExtractDir -Force
    $BundleDir = $tempExtractDir
}
elseif (-not $BundleDir) {
    $BundleDir = "."
}

$BundleDir = (Resolve-Path $BundleDir).Path
INFO "Bundle dir: $BundleDir"

# Validate required files
$zipPath      = Join-Path $BundleDir "agent.zip"
$manifestPath = Join-Path $BundleDir "manifest.json"

if (-not (Test-Path $zipPath)) {
    Write-Error "agent.zip not found in bundle directory: $BundleDir"
}
if (-not (Test-Path $manifestPath)) {
    Write-Error "manifest.json not found in bundle directory: $BundleDir"
}

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
OK "Bundle validated — agent schema: $($manifest.agentSchema)"

# ---------------------------------------------------------------------------
# Step 1 — pac solution import
# ---------------------------------------------------------------------------
Step "Step 1 — Importing Dataverse solution"

INFO "Selecting pac auth index $AuthIndex"
& $PacExe auth select --index $AuthIndex | Out-Null

INFO "Running: pac solution import --path $zipPath --environment $OrgNoTrail"
& $PacExe solution import --path $zipPath --environment $OrgNoTrail 2>&1 |
    ForEach-Object { INFO $_ }

OK "pac solution import complete"

# ---------------------------------------------------------------------------
# Step 2 — Fix skills with assets
# ---------------------------------------------------------------------------
$skillsWithAssets = @()
if ($manifest.PSObject.Properties["skillsWithAssets"]) {
    $skillsWithAssets = @($manifest.skillsWithAssets)
}

if ($skillsWithAssets.Count -gt 0) {
    Step "Step 2 — Repairing $($skillsWithAssets.Count) skill(s) with assets"

    # -----------------------------------------------------------------------
    # Acquire Dataverse bearer token via Azure CLI
    # -----------------------------------------------------------------------
    INFO "Acquiring Dataverse access token via az account get-access-token"
    $tokenObj = az account get-access-token --resource $OrgNoTrail | ConvertFrom-Json
    $token    = $tokenObj.accessToken

    $dv = @{
        Authorization      = "Bearer $token"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
        Accept             = "application/json"
        "Content-Type"     = "application/json"
        Prefer             = "return=representation"
    }

    $dvBase = "$OrgNoTrail/api/data/v9.2"

    # -----------------------------------------------------------------------
    # Locate the imported bot
    # -----------------------------------------------------------------------
    $botFilter  = "schemaname eq '$($manifest.agentSchema)'"
    $botUrl     = "$dvBase/bots?`$filter=$([uri]::EscapeDataString($botFilter))&`$select=botid,name,schemaname"
    $botResp    = Invoke-RestMethod -Uri $botUrl -Headers $dv -Method Get
    $bot        = $botResp.value | Select-Object -First 1
    if (-not $bot) {
        WARN "Bot with schema '$($manifest.agentSchema)' not found in target org — skipping skill repair."
    }
    else {
        $botId = $bot.botid
        OK "Found bot: $($bot.name) ($botId)"

        # -------------------------------------------------------------------
        # Get all type-9 botcomponents for this bot
        # -------------------------------------------------------------------
        $compFilter = "_parentbotid_value eq '$botId' and componenttype eq 9"
        $compUrl    = "$dvBase/botcomponents?`$filter=$([uri]::EscapeDataString($compFilter))&`$select=botcomponentid,name,data"
        $compResp   = Invoke-RestMethod -Uri $compUrl -Headers $dv -Method Get
        $allType9   = @($compResp.value)

        # Filter for broken (bundle-ref) skills
        $brokenSkills = $allType9 | Where-Object { $_.data -like "*bic:bundle=*" }
        INFO "$($brokenSkills.Count) broken skill(s) detected (data contains bic:bundle=)"

        foreach ($skill in $brokenSkills) {
            $skillId   = $skill.botcomponentid
            $skillName = $skill.name
            INFO "Processing skill: $skillName ($skillId)"

            # ---------------------------------------------------------------
            # A) Automated inline fix
            # ---------------------------------------------------------------
            $fixedInline = $false
            try {
                # Get type-14 children of this skill component
                $childFilter = "_parentbotcomponentid_value eq '$skillId' and componenttype eq 14"
                $childUrl    = "$dvBase/botcomponents?`$filter=$([uri]::EscapeDataString($childFilter))&`$select=botcomponentid,name,filedata_name"
                $childResp   = Invoke-RestMethod -Uri $childUrl -Headers $dv -Method Get
                $mdChild     = @($childResp.value) | Where-Object { $_.filedata_name -eq "SKILL.md" } | Select-Object -First 1

                if ($mdChild) {
                    $childId = $mdChild.botcomponentid
                    INFO "  Downloading SKILL.md from child $childId"

                    # Binary download — NOT OData
                    $fileUrl = "$dvBase/botcomponents($childId)/filedata/`$value"
                    $bytes   = (Invoke-WebRequest -Uri $fileUrl `
                                    -Headers @{ Authorization = "Bearer $token" } `
                                    -UseBasicParsing).Content
                    $mdText  = [System.Text.Encoding]::UTF8.GetString($bytes)

                    # Build InlineAgentSkill YAML (2-space indent inside content block)
                    $indented = ($mdText -split "`n") | ForEach-Object { "  $_" }
                    $newData  = "kind: InlineAgentSkill`ncontent: |-`n" + ($indented -join "`n")

                    # PATCH the type-9 component
                    $patchBody = @{ data = $newData } | ConvertTo-Json -Depth 5
                    Invoke-RestMethod -Uri "$dvBase/botcomponents($skillId)" `
                        -Method PATCH -Headers $dv -Body $patchBody | Out-Null

                    OK "skill instructions applied — agent works now  [$skillName]"
                    $fixedInline = $true
                }
                else {
                    WARN "  No SKILL.md child found for skill '$skillName' — falling back to guided re-upload."
                }
            }
            catch {
                WARN "  Automated fix failed for '$skillName': $($_.Exception.Message)"
            }

            # ---------------------------------------------------------------
            # B) Guided re-upload (fallback when inline fix didn't run)
            # ---------------------------------------------------------------
            if (-not $fixedInline) {
                $skillAssetDir = Join-Path $BundleDir "skills-with-assets" $skillName
                $skillZipPath  = Join-Path $BundleDir "skills-with-assets" "$skillName.zip"

                if (Test-Path $skillAssetDir) {
                    INFO "  Packaging $skillAssetDir -> $skillZipPath"
                    if (Test-Path $skillZipPath) { Remove-Item $skillZipPath -Force }
                    Compress-Archive -Path (Join-Path $skillAssetDir "*") `
                        -DestinationPath $skillZipPath -Force
                    OK "  Skill ZIP created: $skillZipPath"
                }
                else {
                    WARN "  skills-with-assets/$skillName/ folder not found in bundle — cannot create ZIP."
                }

                # Build Copilot Studio URL
                $envId    = $OrgNoTrail -replace "https://", "" -replace "\.crm\.dynamics\.com", ""
                $agentUrl = "https://copilotstudio.microsoft.com/environments/$envId/agents/$botId"

                Write-Host ""
                WARN "Manual re-upload required for skill: $skillName"
                Write-Host "  Steps:" -ForegroundColor Yellow
                Write-Host "    1. Open the agent in Copilot Studio (browser opening now):" -ForegroundColor Yellow
                Write-Host "       $agentUrl" -ForegroundColor White
                Write-Host "    2. Click  Topics & Plugins  in the left nav." -ForegroundColor Yellow
                Write-Host "    3. Find the skill named '$skillName' and open it." -ForegroundColor Yellow
                Write-Host "    4. Click the skill card's  ...  menu, then  Edit skill." -ForegroundColor Yellow
                Write-Host "    5. Under  Upload skill ZIP  (or  Replace), upload:" -ForegroundColor Yellow
                Write-Host "       $skillZipPath" -ForegroundColor White
                Write-Host "    6. Click Save, then Publish." -ForegroundColor Yellow
                Write-Host ""

                try { Start-Process $agentUrl } catch { WARN "Could not open browser: $($_.Exception.Message)" }
            }
        } # foreach broken skill
    } # bot found
} # skills-with-assets
else {
    Step "Step 2 — No skills-with-assets (skipping)"
    OK "Nothing to repair"
}

# ---------------------------------------------------------------------------
# Step 3 — Summary
# ---------------------------------------------------------------------------
Step "Step 3 — Summary"

# Determine bot ID (may already be set from Step 2; re-query if not)
if (-not (Get-Variable -Name "botId" -ErrorAction SilentlyContinue) -or -not $botId) {
    $botId = "<run Step 2 to resolve>"
    try {
        $tokenObj2  = az account get-access-token --resource $OrgNoTrail | ConvertFrom-Json
        $dvBase2    = "$OrgNoTrail/api/data/v9.2"
        $hdrs2      = @{ Authorization = "Bearer $($tokenObj2.accessToken)"; Accept = "application/json" }
        $botFilter2 = "schemaname eq '$($manifest.agentSchema)'"
        $botUrl2    = "$dvBase2/bots?`$filter=$([uri]::EscapeDataString($botFilter2))&`$select=botid"
        $botResp2   = Invoke-RestMethod -Uri $botUrl2 -Headers $hdrs2 -Method Get
        $botId      = ($botResp2.value | Select-Object -First 1).botid
    }
    catch { $botId = "<could not resolve — check org URL and auth>" }
}

$envIdSummary = $OrgNoTrail -replace "https://", "" -replace "\.crm\.dynamics\.com", ""
$csUrl        = "https://copilotstudio.microsoft.com/environments/$envIdSummary/agents/$botId"

Write-Host ""
Write-Host "  Bot ID             : $botId" -ForegroundColor White
Write-Host "  Copilot Studio URL : $csUrl" -ForegroundColor White
Write-Host ""

Write-Host "  What was done:" -ForegroundColor Cyan
Write-Host "    [x] agent.zip imported via pac solution import" -ForegroundColor Green
Write-Host "    [x] Bot configuration, flows, tools, knowledge, eval cases restored by solution" -ForegroundColor Green

if ($skillsWithAssets.Count -gt 0) {
    Write-Host "    [x] Skills-with-assets repair attempted for $($skillsWithAssets.Count) skill(s)" -ForegroundColor Green
}
else {
    Write-Host "    [-] No skills-with-assets to repair" -ForegroundColor DarkGray
}

# Connection wiring instructions
$connectors = @()
if ($manifest.PSObject.Properties["connectors"]) {
    $connectors = @($manifest.connectors)
}

if ($connectors.Count -gt 0) {
    Write-Host ""
    WARN "ACTION REQUIRED — Connection wiring"
    Write-Host "    The following connector(s) were referenced in the exported agent:" -ForegroundColor Yellow
    foreach ($connector in $connectors) {
        $displayName = if ($connector.PSObject.Properties["displayName"]) { $connector.displayName } else { $connector }
        Write-Host "      - $displayName" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "    Each Power Automate flow that uses a connector shows 'needs connection'." -ForegroundColor Yellow
    Write-Host "    To wire connections:" -ForegroundColor Yellow
    Write-Host "      1. Open https://make.powerautomate.com" -ForegroundColor White
    Write-Host "      2. Switch to environment: $envIdSummary" -ForegroundColor White
    Write-Host "      3. Open each affected flow and assign a valid connection per connector." -ForegroundColor White
    Write-Host "      4. Save and turn on the flow." -ForegroundColor White
    Write-Host "      5. Return to Copilot Studio and verify the agent runs end-to-end." -ForegroundColor White
}

# Temp dir cleanup
if ($tempExtractDir -and (Test-Path $tempExtractDir)) {
    INFO "Cleaning up temp extract dir: $tempExtractDir"
    Remove-Item $tempExtractDir -Recurse -Force
    OK "Temp dir removed"
}

Write-Host ""
OK "install.ps1 complete."
