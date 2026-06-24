<#
.SYNOPSIS
    Standalone script to re-upload skill binary assets after pac solution import.

.DESCRIPTION
    Use this if you ran pac solution import manually (without install.ps1) and need to
    re-upload skills-with-assets separately.

    When a skill is uploaded as a ZIP (Python/binary assets), Copilot Studio stores a
    bundle reference token (bic:bundle=catskill_*_zip_*) in the botcomponent data field.
    pac solution export captures the record but NOT the binary blob. After import, the
    skill appears in the UI but fails to deliver its Python assets to the agent runtime.

    This script:
      - Reads skills-with-assets/manifest.json
      - For each skill: deletes the stale child file components in the target
      - Re-uploads the binary ZIP as a new type-14 botcomponent

.PARAMETER TargetOrgUrl
    Dataverse environment URL for the target (where import was run).

.PARAMETER BotId
    GUID of the bot in the target environment (find it in PPAC or via DV API).

.PARAMETER SkillsDir
    Path to skills-with-assets/ folder produced by path1-solution\export.ps1.

.EXAMPLE
    .\path1-solution\post-import-skills.ps1 `
      -TargetOrgUrl "https://targetorg.crm.dynamics.com" `
      -BotId        "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
      -SkillsDir    ".\skills-with-assets"
#>
param(
    [Parameter(Mandatory)][string]$TargetOrgUrl,
    [Parameter(Mandatory)][string]$BotId,
    [Parameter(Mandatory)][string]$SkillsDir
)

$ErrorActionPreference = "Stop"

function OK   { Write-Host "  OK  $args" -ForegroundColor Green }
function INFO { Write-Host "      $args" -ForegroundColor Gray }
function WARN { Write-Host "  !   $args" -ForegroundColor Yellow }
function ERR  { Write-Host "  ERR $args" -ForegroundColor Red; exit 1 }

$OrgNoTrail   = $TargetOrgUrl.TrimEnd("/")
$manifestPath = Join-Path $SkillsDir "manifest.json"

if (-not (Test-Path $manifestPath)) { ERR "manifest.json not found in: $SkillsDir" }

Write-Host ""
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Post-Import Skill Asset Re-Upload"         -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Target : $OrgNoTrail"
Write-Host "  Bot    : $BotId"
Write-Host "  Skills : $SkillsDir"
Write-Host ""

# Acquire token
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

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
INFO "Found $($manifest.Count) skill(s) in manifest"
Add-Type -AssemblyName System.IO.Compression.FileSystem

foreach ($skillMeta in $manifest) {
    Write-Host "`n  Processing: $($skillMeta.skillName)" -ForegroundColor Yellow

    # Locate the imported skill record by schema name
    $existing = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=schemaname eq '$($skillMeta.schemaName)' and componenttype eq 9&`$select=botcomponentid,name,data,_parentbotid_value" -Headers $headers).value

    if ($existing.Count -eq 0) {
        WARN "  Skill '$($skillMeta.skillName)' not found in target — import may have failed"
        continue
    }

    $skillRecord = $existing[0]
    $skillCompId = $skillRecord.botcomponentid
    $parentBotId = $skillRecord."_parentbotid_value"

    if ($skillRecord.data -notlike "*bic:bundle=*") {
        OK "  Skill '$($skillMeta.skillName)' appears healthy (no broken bundle ref)"
        continue
    }

    INFO "  Broken bundle ref detected — re-uploading..."

    # Rebuild ZIP from exported files
    $skillSrcDir = Join-Path $SkillsDir $skillMeta.skillName
    $rebuildZip  = Join-Path $SkillsDir "$($skillMeta.skillName)_rebuild.zip"
    if (Test-Path $rebuildZip) { Remove-Item $rebuildZip -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($skillSrcDir, $rebuildZip)
    INFO "  Rebuilt ZIP: $([math]::Round((Get-Item $rebuildZip).Length/1KB,1)) KB"

    # Delete stale child file components (type 14)
    $oldFiles = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotcomponentid_value eq '$skillCompId' and componenttype eq 14&`$select=botcomponentid" -Headers $headers).value
    foreach ($of in $oldFiles) {
        Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents($($of.botcomponentid))" -Method DELETE -Headers $headers | Out-Null
        INFO "  Deleted stale component: $($of.botcomponentid)"
    }

    # Upload new ZIP
    $zipBytes   = [System.IO.File]::ReadAllBytes($rebuildZip)
    $zipB64     = [System.Convert]::ToBase64String($zipBytes)
    $uploadBody = @{
        name                             = "$($skillMeta.skillName)_bundle"
        componenttype                    = 14
        "parentbotcomponentid@odata.bind" = "/botcomponents($skillCompId)"
        "parentbotid@odata.bind"         = "/bots($parentBotId)"
        filedata                         = $zipB64
        filedata_name                    = "$($skillMeta.skillName).zip"
    } | ConvertTo-Json -Depth 3

    $created = Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents" -Method POST -Headers $headers -Body $uploadBody
    OK "  '$($skillMeta.skillName)' re-uploaded — ID: $($created.botcomponentid)"

    Remove-Item $rebuildZip -Force
}

Write-Host ""
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Skill re-upload complete"                  -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
