<#
.SYNOPSIS
    Import a Modern Copilot Studio agent from a solution package.

.DESCRIPTION
    1. pac solution import — restores everything: bot.configuration (from configuration.json
       in the ZIP), InlineAgentSkills, ConnectorTool, McpTool, ConnectedAgentTool,
       WorkflowTool (flow tools), TaskDialog (agent flows), eval test cases, and
       connection reference stubs.

    2. Skills-with-assets re-upload — if a skills-with-assets/ folder exists alongside
       agent.zip, the script detects broken skill bundle references and re-uploads the
       binary skill ZIPs via the Dataverse API.

       WHY: Skills uploaded as ZIP files (Python/binary assets) cause pac solution export
       to capture the botcomponent RECORD but not the binary bundle blob. After import the
       skill appears in the UI but its Python assets are missing. Re-uploading fixes this.

    3. Prints connection wiring instructions for any connection references in the package.

.PARAMETER PacExe
    Path to pac.exe. Auto-detected from PATH or NuGet cache if omitted.

.PARAMETER TargetOrgUrl
    Dataverse environment URL for the target environment.

.PARAMETER ZipPath
    Path to agent.zip (the exported solution package).

.PARAMETER SkillsDir
    Path to skills-with-assets/ folder. Auto-detected if omitted (looks next to ZipPath).

.PARAMETER AuthIndex
    pac auth profile index (default: 1).

.EXAMPLE
    .\path1-solution\install.ps1 `
      -TargetOrgUrl "https://targetorg.crm.dynamics.com" `
      -ZipPath      ".\agent.zip"

.EXAMPLE
    .\path1-solution\install.ps1 `
      -TargetOrgUrl "https://targetorg.crm.dynamics.com" `
      -ZipPath      "C:\releases\v1.0\agent.zip" `
      -SkillsDir    "C:\releases\v1.0\skills-with-assets"
#>
param(
    [string]$PacExe       = "",
    [Parameter(Mandatory)][string]$TargetOrgUrl,
    [Parameter(Mandatory)][string]$ZipPath,
    [string]$SkillsDir    = "",
    [int]   $AuthIndex    = 1
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

$OrgNoTrail = $TargetOrgUrl.TrimEnd("/")
$ZipPath    = Resolve-Path $ZipPath | Select-Object -ExpandProperty Path

if (-not $SkillsDir) {
    $SkillsDir = Join-Path (Split-Path $ZipPath -Parent) "skills-with-assets"
}

Write-Host ""
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Modern Agent Install — Solution Path"      -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Target : $OrgNoTrail"
Write-Host "  ZIP    : $ZipPath"
Write-Host "  Skills : $(if (Test-Path $SkillsDir) { $SkillsDir } else { '(none)' })"

# ── Step 1: pac solution import ───────────────────────────────────────────────
Step "[1/4] Importing solution package (pac solution import)..."

& $PacExe auth select --index $AuthIndex | Out-Null
$importOut = & $PacExe solution import --path $ZipPath --environment $OrgNoTrail --activate-plugins --force-overwrite 2>&1
$importOut | ForEach-Object { INFO $_ }
if ($LASTEXITCODE -ne 0) { ERR "pac solution import failed (exit $LASTEXITCODE)" }
OK "Solution imported successfully"
INFO "Imported: bot.configuration, tools, skills, flows, eval cases, connection ref stubs"

# ── Step 2: Acquire DV token ──────────────────────────────────────────────────
Step "[2/4] Acquiring Dataverse token..."

$tokenJson = az account get-access-token --resource $OrgNoTrail 2>&1
if ($LASTEXITCODE -ne 0) { ERR "az account get-access-token failed. Run: az login" }
$token   = ($tokenJson | ConvertFrom-Json).accessToken
$headers = @{
    Authorization      = "Bearer $token"
    "OData-MaxVersion" = "4.0"
    "OData-Version"    = "4.0"
    Accept             = "application/json"
    "Content-Type"     = "application/json"
}
OK "DV token acquired"

# ── Step 3: Re-upload skills-with-assets ─────────────────────────────────────
Step "[3/4] Checking for skills-with-assets..."

if (-not (Test-Path $SkillsDir)) {
    OK "No skills-with-assets folder found — skipping (no binary skill re-upload needed)"
} else {
    $manifestPath = Join-Path $SkillsDir "manifest.json"
    if (-not (Test-Path $manifestPath)) {
        WARN "skills-with-assets/ folder exists but manifest.json is missing — skipping re-upload"
        WARN "Run path1-solution\export.ps1 again to regenerate skills-with-assets/manifest.json"
    } else {
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

        foreach ($skillMeta in $manifest) {
            WARN "Re-uploading skill: $($skillMeta.skillName)"

            # Find the imported botcomponent (broken bundle ref)
            $existing = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=schemaname eq '$($skillMeta.schemaName)' and componenttype eq 9&`$select=botcomponentid,name,data,_parentbotid_value" -Headers $headers).value

            if ($existing.Count -eq 0) {
                WARN "  Skill '$($skillMeta.skillName)' not found in target after import — skipping"
                continue
            }

            $skillRecord   = $existing[0]
            $skillCompId   = $skillRecord.botcomponentid
            $parentBotId   = $skillRecord."_parentbotid_value"

            # Build fresh ZIP from exported files
            $skillSrcDir  = Join-Path $SkillsDir $skillMeta.skillName
            $rebuildZip   = Join-Path $SkillsDir "$($skillMeta.skillName)_rebuild.zip"
            if (Test-Path $rebuildZip) { Remove-Item $rebuildZip -Force }

            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::CreateFromDirectory($skillSrcDir, $rebuildZip)
            INFO "  Rebuilt ZIP: $rebuildZip ($([math]::Round((Get-Item $rebuildZip).Length/1KB,1)) KB)"

            # Delete existing broken child file components (type 14)
            $oldFiles = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotcomponentid_value eq '$skillCompId' and componenttype eq 14&`$select=botcomponentid" -Headers $headers).value
            foreach ($of in $oldFiles) {
                Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents($($of.botcomponentid))" -Method DELETE -Headers $headers | Out-Null
                INFO "  Deleted stale file component: $($of.botcomponentid)"
            }

            # Re-upload the ZIP as a new type-14 file component
            $zipBytes  = [System.IO.File]::ReadAllBytes($rebuildZip)
            $zipB64    = [System.Convert]::ToBase64String($zipBytes)
            $uploadBody = @{
                name                        = "$($skillMeta.skillName)_bundle"
                componenttype               = 14
                "parentbotcomponentid@odata.bind" = "/botcomponents($skillCompId)"
                "parentbotid@odata.bind"    = "/bots($parentBotId)"
                filedata                    = $zipB64
                filedata_name               = "$($skillMeta.skillName).zip"
            } | ConvertTo-Json -Depth 3

            $created = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents" -Method POST -Headers $headers -Body $uploadBody
            OK "  Skill '$($skillMeta.skillName)' re-uploaded successfully"
            INFO "  New component ID: $($created.botcomponentid)"

            # Clean up rebuild ZIP
            Remove-Item $rebuildZip -Force
        }
    }
}

# ── Step 4: Connection wiring instructions ────────────────────────────────────
Step "[4/4] Connection wiring (manual step required)..."

$connRefs = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/connectionreferences?`$select=connectionreferencelogicalname,customconnectorid" -Headers $headers -ErrorAction SilentlyContinue).value
if ($null -eq $connRefs) { $connRefs = @() }

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Install Complete"                          -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  What was done:"
Write-Host "    [x] Solution imported (bot.configuration, tools, skills, flows, eval cases)"
if (Test-Path $manifestPath -ErrorAction SilentlyContinue) {
    Write-Host "    [x] Skill assets re-uploaded" -ForegroundColor Green
} else {
    Write-Host "    [-] Skills-with-assets: none found or skipped"
}
Write-Host ""
Write-Host "  MANUAL STEP: Wire connection references (one-time per environment)" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Flows remain in Draft state until their connection references are wired."
Write-Host "  Steps:"
Write-Host "    1. Go to PPAC → <your env> → Connections → New connection"
Write-Host "    2. Create a connection for each required connector"
Write-Host "    3. Go to Solutions → <solution> → Connection References"
Write-Host "    4. Edit each connection reference → link to the new connection"
Write-Host "    5. Flows activate automatically once all connections are wired"
Write-Host ""
Write-Host "  Connection references in this environment:"
if ($connRefs.Count -eq 0) {
    Write-Host "    (none detected — may be in the imported solution, check in PPAC)"
} else {
    foreach ($cr in $connRefs) {
        Write-Host "    • $($cr.connectionreferencelogicalname)"
    }
}
Write-Host ""
Write-Host "  Open the agent: https://copilotstudio.microsoft.com"
Write-Host ""
