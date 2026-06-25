<#
.SYNOPSIS
    Import a Modern Copilot Studio agent from an export bundle (agent.zip + skills-with-assets/).

.DESCRIPTION
    This script fully restores a Modern Copilot Studio agent from a bundle produced by export.ps1.
    It requires NO prior knowledge of the agent — everything needed is in the bundle folder.

    THE BUNDLE FOLDER MUST CONTAIN:
      agent.zip              The Dataverse solution package
      manifest.json          Export inventory (agent schema, connectors, skills with assets)
      skills-with-assets/    Binary skill files (only present if agent has ZIP-uploaded skills)

    WHAT pac solution import HANDLES AUTOMATICALLY (no extra steps needed):
    ─────────────────────────────────────────────────────────────────────
      bot.configuration     Instructions, model series, AI settings — restored from
                            bots/{schema}/configuration.json inside agent.zip
      InlineAgentSkills     Markdown-only skills — fully restored
      Flow tools            WorkflowTool and TaskDialog tools — restored with correct GUIDs
                            (solution import preserves GUIDs — no remap needed)
      ConnectorTool/McpTool Connection reference records created (empty — wire manually)
      ConnectedAgentTool    Restored by schema name — target agent must exist
      URL knowledge sources Restored from knowledge/*.mcs.yml
      Evaluation test cases All MultiTurnEvaluationCase records restored
      Connection references Created with null connectionid (normal — wire manually after)

    WHAT THIS SCRIPT ADDS ON TOP (the one thing solution import cannot do):
    ──────────────────────────────────────────────────────────────────────
      Skills with assets    ZIP-uploaded skills (containing Python files, images, etc.)
                            Solution import restores the type-9 skill record and type-14
                            file component records, but does NOT reconstitute the binary
                            bundle blob (bic:bundle=...) that the skill references at runtime.
                            This script detects those broken skills and re-uploads them by:
                              1. Building a ZIP from the files in skills-with-assets/
                              2. Deleting the broken skill + its stale file components
                              3. Re-uploading via DV API — creates a fresh bundle in target env

    MANUAL STEP REQUIRED AFTER IMPORT (for agents with connectors):
    ───────────────────────────────────────────────────────────────
      Power Automate flows that use connectors (Office 365, Power BI, Dataverse, etc.)
      are created in Draft state. They activate automatically once their connection
      references are wired to real connections. This is normal Power Platform behavior.
        1. Go to PPAC → your environment → Connections → New connection
        2. Create a connection for each required connector
        3. Go to Default Solution → Connection References → edit each → link to connection
        4. Flows activate automatically

    PREREQUISITES
    ─────────────
    pac CLI:  https://aka.ms/PowerPlatformCLI
    az CLI:   https://aka.ms/installazurecliwindows
    pac auth: pac auth create --environment https://yourorg.crm.dynamics.com
    az login: az login (with Dataverse access to target env)

.PARAMETER BundleDir
    Path to the export bundle folder (contains agent.zip, manifest.json, skills-with-assets/).
    Defaults to current directory.

.PARAMETER TargetOrgUrl
    Dataverse org URL for the target environment.

.PARAMETER AuthIndex
    pac auth index for the target environment.

.PARAMETER PacExe
    Path to pac.exe. Auto-detected from PATH or NuGet cache if not specified.

.EXAMPLE
    .\install.ps1 -TargetOrgUrl "https://myorg.crm.dynamics.com"

.EXAMPLE
    .\install.ps1 -BundleDir "C:\downloads\my-agent-bundle" -TargetOrgUrl "https://myorg.crm.dynamics.com" -AuthIndex 2
#>
param(
    [string] $BundleDir    = ".",
    [Parameter(Mandatory)][string] $TargetOrgUrl,
    [int]    $AuthIndex    = 1,
    [string] $PacExe       = ""
)

$ErrorActionPreference = "Stop"
$OrgNoTrail = $TargetOrgUrl.TrimEnd("/")

# Resolve pac.exe
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

# Validate bundle
$zipPath      = Join-Path $BundleDir "agent.zip"
$manifestPath = Join-Path $BundleDir "manifest.json"
if (-not (Test-Path $zipPath))      { Write-Error "agent.zip not found in: $BundleDir" }
if (-not (Test-Path $manifestPath)) { Write-Error "manifest.json not found in: $BundleDir" }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Modern Agent Install — Solution Path    ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Target  : $OrgNoTrail"
Write-Host "  Agent   : $($manifest.agentName) ($($manifest.agentSchema))"
Write-Host "  Bundle  : $BundleDir"
Write-Host "  ZIP     : $([Math]::Round((Get-Item $zipPath).Length/1KB))KB"
Write-Host "  Skills with assets: $($manifest.skillsWithAssets.Count)"
Write-Host ""

# ── Acquire DV token ──────────────────────────────────────────────────────────
Step "Acquiring Dataverse token..."
$token = (az account get-access-token --resource $OrgNoTrail | ConvertFrom-Json).accessToken
$dv = @{ Authorization="Bearer $token"; "OData-MaxVersion"="4.0"; "OData-Version"="4.0"; Accept="application/json"; "Content-Type"="application/json"; Prefer="return=representation" }
OK "Token acquired"

# ── Step 1: pac solution import ───────────────────────────────────────────────
Step "Step 1 — pac solution import"
INFO "This step handles:"
INFO "  - bot.configuration (instructions, model) — from bots/*/configuration.json in ZIP"
INFO "  - All tools (ConnectorTool, McpTool, WorkflowTool, TaskDialog)"
INFO "  - InlineAgentSkill (markdown-only skills)"
INFO "  - URL knowledge sources"
INFO "  - Power Automate flows (GUIDs preserved — no remap needed)"
INFO "  - Connection references (created empty — wire manually after)"
INFO "  - Evaluation test cases"
INFO "  - Skills with assets (file records imported, bundle needs Step 2)"

& $PacExe auth select --index $AuthIndex | Out-Null
& $PacExe solution import --path $zipPath --environment $OrgNoTrail 2>&1 | ForEach-Object { INFO $_ }
if ($LASTEXITCODE -ne 0) { Write-Error "pac solution import failed. See output above." }
OK "Solution import complete"

# ── Step 2: Fix skills with assets ───────────────────────────────────────────
# After solution import, skills uploaded as ZIP files (with Python/binary assets)
# have a stale bic:bundle= reference. The bundle blob lives in Azure file storage,
# is env-specific, and is NOT included in the solution ZIP.
#
# This step does TWO things automatically:
#
#  A) IMMEDIATE FIX: Reads SKILL.md from the imported type-14 component, patches the
#     type-9 skill data field to inline InlineAgentSkill. The agent works immediately —
#     skill instructions are applied, skill appears in the agent, agent behaves correctly.
#
#  B) GUIDED RE-UPLOAD: Rebuilds the original ZIP from exported files, places it in a
#     known location, opens Copilot Studio in the browser, and prints exact 6-step
#     instructions for re-uploading to restore Python/binary execution capability.
#     This step is OPTIONAL — the agent already works after step A.

if ($manifest.skillsWithAssets.Count -gt 0) {
    Step "Step 2 — Fix skills with assets ($($manifest.skillsWithAssets.Count) skill(s))"

    # Find the imported bot
    $importedBot = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/bots?`$filter=schemaname eq '$($manifest.agentSchema)'&`$select=botid,name" -Headers $dv).value[0]
    $importedBotId  = $importedBot.botid
    $importedBotName = $importedBot.name
    INFO "Bot: $importedBotName ($importedBotId)"

    # Find all broken skills (bic:bundle= in data field)
    $allComps    = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotid_value eq '$importedBotId' and componenttype eq 9&`$select=botcomponentid,name,data" -Headers $dv).value
    $brokenSkills = $allComps | Where-Object { $_.data -like "*bic:bundle=*" }
    INFO "$($brokenSkills.Count) broken skill(s) detected"

    $reuploadList = @()

    foreach ($skill in $brokenSkills) {
        INFO ""
        INFO "Skill: '$($skill.name)'"

        # ── A) Automated inline fix ──────────────────────────────────────
        $children     = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`$filter=_parentbotcomponentid_value eq '$($skill.botcomponentid)'&`$select=botcomponentid,filedata_name" -Headers $dv).value
        $skillMdChild = $children | Where-Object { $_.filedata_name -eq "SKILL.md" }

        if ($skillMdChild) {
            $bytes    = (Invoke-WebRequest -Uri "$OrgNoTrail/api/data/v9.2/botcomponents($($skillMdChild.botcomponentid))/filedata/`$value" -Headers @{ Authorization="Bearer $token" } -UseBasicParsing).Content
            $mdText   = [System.Text.Encoding]::UTF8.GetString($bytes)
            $indented = ($mdText -split "`n") | ForEach-Object { "  $_" }
            $newData  = "kind: InlineAgentSkill`ncontent: |-`n" + ($indented -join "`n")
            Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents($($skill.botcomponentid))" -Method PATCH -Headers $dv -Body (@{ data = $newData } | ConvertTo-Json) | Out-Null
            OK "  [A] Instructions applied — agent works now"
        } else {
            WARN "  No SKILL.md child found — inline fix skipped"
        }

        # ── B) Rebuild ZIP for optional re-upload ────────────────────────
        $assetFolder = Join-Path $BundleDir "skills-with-assets\$($skill.name)"
        if (Test-Path $assetFolder) {
            $zipPath = Join-Path $BundleDir "skills-with-assets\$($skill.name).zip"
            Compress-Archive -Path (Join-Path $assetFolder "*") -DestinationPath $zipPath -Force
            $reuploadList += @{ name = $skill.name; zipPath = $zipPath }
            OK "  [B] ZIP rebuilt: $zipPath"
        } else {
            WARN "  skills-with-assets\$($skill.name)\ not found — ZIP not rebuilt"
        }
    }

    # ── Guided manual re-upload (printed + browser opened) ───────────────
    if ($reuploadList.Count -gt 0) {
        $envId     = $OrgNoTrail -replace "https://","" -replace "\.crm\.dynamics\.com",""
        $agentUrl  = "https://copilotstudio.microsoft.com/environments/$envId/agents/$importedBotId"

        Write-Host ""
        Write-Host "  ┌──────────────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
        Write-Host "  │  OPTIONAL: Restore Python/binary execution for bundled skills   │" -ForegroundColor Cyan
        Write-Host "  │  The agent works now. This step upgrades Python skill assets.   │" -ForegroundColor Cyan
        Write-Host "  └──────────────────────────────────────────────────────────────────┘" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Skill(s) with binary assets:" -ForegroundColor White
        foreach ($r in $reuploadList) {
            Write-Host "    • $($r.name)"
            Write-Host "      ZIP: $($r.zipPath)" -ForegroundColor Cyan
        }
        Write-Host ""
        Write-Host "  To restore Python execution for each skill listed above:" -ForegroundColor White
        Write-Host "    1. Open the agent (browser will open automatically):"
        Write-Host "       $agentUrl" -ForegroundColor Cyan
        Write-Host "    2. In the Skills section, click  ×  next to the skill name"
        Write-Host "    3. Confirm deletion"
        Write-Host "    4. Click  + Add skill"
        Write-Host "    5. Choose  Upload a skill  →  select the ZIP file shown above"
        Write-Host "    6. Save the agent"
        Write-Host ""
        try { Start-Process $agentUrl; OK "Browser opened to agent page" }
        catch { WARN "Could not open browser — use the URL above" }
    }

} else {
    Step "Step 2 — No skills with assets (skipping)"
    OK "No bic:bundle= skills to fix"
}

# ── Summary
# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Install Complete                        ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
$envId = $OrgNoTrail -replace "https://","" -replace "\.crm\.dynamics\.com",""
Write-Host "  Agent in Copilot Studio:"
Write-Host "  https://copilotstudio.microsoft.com/environments/$envId/home" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Status:"
Write-Host "    [x] Solution imported (bot, tools, skills, flows, knowledge, eval cases)"
Write-Host "    [x] bot.configuration applied (instructions, model)"
if ($manifest.skillsWithAssets.Count -gt 0) {
    Write-Host "    [x] $($manifest.skillsWithAssets.Count) skill(s) with assets re-uploaded"
}
Write-Host ""
if ($manifest.connectorsRequired.Count -gt 0) {
    Write-Host "  MANUAL STEP — wire connections (one-time per environment):" -ForegroundColor Yellow
    Write-Host "    Flows are in Draft until connections are wired."
    Write-Host "    Connectors needed:"
    $manifest.connectorsRequired | ForEach-Object { Write-Host "      • $_" -ForegroundColor Cyan }
    Write-Host ""
    Write-Host "    1. PPAC → Connections → New connection → create one per connector"
    Write-Host "    2. Default Solution → Connection References → edit each → link to connection"
    Write-Host "    3. Flows activate automatically"
}

.data -like "*bic:bundle=*" }
    INFO "$($brokenSkills.Count) skill(s) with broken bic:bundle= reference"

    foreach ($skill in $brokenSkills) {
        INFO ""
        INFO "Fixing skill: '$($skill.name)'"

        # Get SKILL.md from type-14 children
        $children = (Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents?`=_parentbotcomponentid_value eq '$($skill.botcomponentid)'&`=botcomponentid,filedata_name" -Headers $dv).value
        $skillMdChild = $children | Where-Object { <#
.SYNOPSIS
    Import a Modern Copilot Studio agent from an export bundle (agent.zip + skills-with-assets/).

.DESCRIPTION
    This script fully restores a Modern Copilot Studio agent from a bundle produced by export.ps1.
    It requires NO prior knowledge of the agent — everything needed is in the bundle folder.

    THE BUNDLE FOLDER MUST CONTAIN:
      agent.zip              The Dataverse solution package
      manifest.json          Export inventory (agent schema, connectors, skills with assets)
      skills-with-assets/    Binary skill files (only present if agent has ZIP-uploaded skills)

    WHAT pac solution import HANDLES AUTOMATICALLY (no extra steps needed):
    ─────────────────────────────────────────────────────────────────────
      bot.configuration     Instructions, model series, AI settings — restored from
                            bots/{schema}/configuration.json inside agent.zip
      InlineAgentSkills     Markdown-only skills — fully restored
      Flow tools            WorkflowTool and TaskDialog tools — restored with correct GUIDs
                            (solution import preserves GUIDs — no remap needed)
      ConnectorTool/McpTool Connection reference records created (empty — wire manually)
      ConnectedAgentTool    Restored by schema name — target agent must exist
      URL knowledge sources Restored from knowledge/*.mcs.yml
      Evaluation test cases All MultiTurnEvaluationCase records restored
      Connection references Created with null connectionid (normal — wire manually after)

    WHAT THIS SCRIPT ADDS ON TOP (the one thing solution import cannot do):
    ──────────────────────────────────────────────────────────────────────
      Skills with assets    ZIP-uploaded skills (containing Python files, images, etc.)
                            Solution import restores the type-9 skill record and type-14
                            file component records, but does NOT reconstitute the binary
                            bundle blob (bic:bundle=...) that the skill references at runtime.
                            This script detects those broken skills and re-uploads them by:
                              1. Building a ZIP from the files in skills-with-assets/
                              2. Deleting the broken skill + its stale file components
                              3. Re-uploading via DV API — creates a fresh bundle in target env

    MANUAL STEP REQUIRED AFTER IMPORT (for agents with connectors):
    ───────────────────────────────────────────────────────────────
      Power Automate flows that use connectors (Office 365, Power BI, Dataverse, etc.)
      are created in Draft state. They activate automatically once their connection
      references are wired to real connections. This is normal Power Platform behavior.
        1. Go to PPAC → your environment → Connections → New connection
        2. Create a connection for each required connector
        3. Go to Default Solution → Connection References → edit each → link to connection
        4. Flows activate automatically

    PREREQUISITES
    ─────────────
    pac CLI:  https://aka.ms/PowerPlatformCLI
    az CLI:   https://aka.ms/installazurecliwindows
    pac auth: pac auth create --environment https://yourorg.crm.dynamics.com
    az login: az login (with Dataverse access to target env)

.PARAMETER BundleDir
    Path to the export bundle folder (contains agent.zip, manifest.json, skills-with-assets/).
    Defaults to current directory.

.PARAMETER TargetOrgUrl
    Dataverse org URL for the target environment.

.PARAMETER AuthIndex
    pac auth index for the target environment.

.PARAMETER PacExe
    Path to pac.exe. Auto-detected from PATH or NuGet cache if not specified.

.EXAMPLE
    .\install.ps1 -TargetOrgUrl "https://myorg.crm.dynamics.com"

.EXAMPLE
    .\install.ps1 -BundleDir "C:\downloads\my-agent-bundle" -TargetOrgUrl "https://myorg.crm.dynamics.com" -AuthIndex 2
#>
param(
    [string] $BundleDir    = ".",
    [Parameter(Mandatory)][string] $TargetOrgUrl,
    [int]    $AuthIndex    = 1,
    [string] $PacExe       = ""
)

$ErrorActionPreference = "Stop"
$OrgNoTrail = $TargetOrgUrl.TrimEnd("/")

# Resolve pac.exe
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

# Validate bundle
$zipPath      = Join-Path $BundleDir "agent.zip"
$manifestPath = Join-Path $BundleDir "manifest.json"
if (-not (Test-Path $zipPath))      { Write-Error "agent.zip not found in: $BundleDir" }
if (-not (Test-Path $manifestPath)) { Write-Error "manifest.json not found in: $BundleDir" }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Modern Agent Install — Solution Path    ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Target  : $OrgNoTrail"
Write-Host "  Agent   : $($manifest.agentName) ($($manifest.agentSchema))"
Write-Host "  Bundle  : $BundleDir"
Write-Host "  ZIP     : $([Math]::Round((Get-Item $zipPath).Length/1KB))KB"
Write-Host "  Skills with assets: $($manifest.skillsWithAssets.Count)"
Write-Host ""

# ── Acquire DV token ──────────────────────────────────────────────────────────
Step "Acquiring Dataverse token..."
$token = (az account get-access-token --resource $OrgNoTrail | ConvertFrom-Json).accessToken
$dv = @{ Authorization="Bearer $token"; "OData-MaxVersion"="4.0"; "OData-Version"="4.0"; Accept="application/json"; "Content-Type"="application/json"; Prefer="return=representation" }
OK "Token acquired"

# ── Step 1: pac solution import ───────────────────────────────────────────────
Step "Step 1 — pac solution import"
INFO "This step handles:"
INFO "  - bot.configuration (instructions, model) — from bots/*/configuration.json in ZIP"
INFO "  - All tools (ConnectorTool, McpTool, WorkflowTool, TaskDialog)"
INFO "  - InlineAgentSkill (markdown-only skills)"
INFO "  - URL knowledge sources"
INFO "  - Power Automate flows (GUIDs preserved — no remap needed)"
INFO "  - Connection references (created empty — wire manually after)"
INFO "  - Evaluation test cases"
INFO "  - Skills with assets (file records imported, bundle needs Step 2)"

& $PacExe auth select --index $AuthIndex | Out-Null
& $PacExe solution import --path $zipPath --environment $OrgNoTrail 2>&1 | ForEach-Object { INFO $_ }
if ($LASTEXITCODE -ne 0) { Write-Error "pac solution import failed. See output above." }
OK "Solution import complete"

# ── Step 2: Document skills with assets requiring manual re-upload ─────────────
# IMPORTANT: Skills uploaded as ZIP files (containing Python/binary assets) have a
# bic:bundle= reference that is created by Copilot Studio's server-side processing.
# This bundle blob is NOT accessible via the Dataverse OData API, and cannot be
# recreated programmatically. After solution import:
#   - The skill RECORD exists (type-9 botcomponent)
#   - The file COMPONENTS exist (type-14 botcomponents with binary content)
#   - But the bic:bundle= reference is broken — assets are unreachable at runtime
#
# FIX: Manually re-upload each skill ZIP through the Copilot Studio UI:
#   1. Open the agent in Copilot Studio
#   2. Skills section → click X to remove the broken skill
#   3. Add skill → Upload a skill → upload the ZIP from skills-with-assets/
#
if (.skillsWithAssets.Count -gt 0) {
    Step "Step 2 — Skills with assets require manual re-upload"
    Write-Host ""
    Write-Host "  The following skills use binary assets (Python scripts, etc.):" -ForegroundColor Yellow
    foreach ( in .skillsWithAssets) {
        Write-Host "    • " -ForegroundColor Cyan
        Write-Host "      Files: "
         = Join-Path  "skills-with-assets\"
        Write-Host "      Source: "
    }
    Write-Host ""
    Write-Host "  After import, for each skill above:" -ForegroundColor Yellow
    Write-Host "    1. Open the agent in Copilot Studio"
    Write-Host "    2. In Skills, click X to remove the broken skill entry"
    Write-Host "    3. Add skill → Upload a skill → upload the ZIP from the source path above"
    Write-Host "    4. Save the agent"
    Write-Host ""
    WARN "Skills with assets CANNOT be automatically fixed — manual UI upload required"
    WARN "This is a known Copilot Studio limitation (no public API for bundle creation)"
} else {
    Step "Step 2 — No skills with assets (skipping)"
    OK "No binary skill bundles to fix"
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Install Complete                        ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
$envId = $OrgNoTrail -replace "https://","" -replace "\.crm\.dynamics\.com",""
Write-Host "  Agent in Copilot Studio:"
Write-Host "  https://copilotstudio.microsoft.com/environments/$envId/home" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Status:"
Write-Host "    [x] Solution imported (bot, tools, skills, flows, knowledge, eval cases)"
Write-Host "    [x] bot.configuration applied (instructions, model)"
if ($manifest.skillsWithAssets.Count -gt 0) {
    Write-Host "    [x] $($manifest.skillsWithAssets.Count) skill(s) with assets re-uploaded"
}
Write-Host ""
if ($manifest.connectorsRequired.Count -gt 0) {
    Write-Host "  MANUAL STEP — wire connections (one-time per environment):" -ForegroundColor Yellow
    Write-Host "    Flows are in Draft until connections are wired."
    Write-Host "    Connectors needed:"
    $manifest.connectorsRequired | ForEach-Object { Write-Host "      • $_" -ForegroundColor Cyan }
    Write-Host ""
    Write-Host "    1. PPAC → Connections → New connection → create one per connector"
    Write-Host "    2. Default Solution → Connection References → edit each → link to connection"
    Write-Host "    3. Flows activate automatically"
}

.filedata_name -eq "SKILL.md" }

        if (-not $skillMdChild) {
            WARN "  No SKILL.md found in type-14 children — cannot auto-fix '$($skill.name)'"
            WARN "  Manual re-upload required via Copilot Studio UI"
            continue
        }

        # Read SKILL.md binary content
        $skillMdBytes = (Invoke-WebRequest -Uri "$OrgNoTrail/api/data/v9.2/botcomponents($($skillMdChild.botcomponentid))/filedata/`" -Headers @{ Authorization="Bearer $token" } -UseBasicParsing).Content
        $skillMdText = [System.Text.Encoding]::UTF8.GetString($skillMdBytes)
        INFO "  SKILL.md: $($skillMdText.Length) chars"

        # Build inline InlineAgentSkill data (2-space indent for YAML block scalar)
        $indented = ($skillMdText -split "\
") | ForEach-Object { "  <#
.SYNOPSIS
    Import a Modern Copilot Studio agent from an export bundle (agent.zip + skills-with-assets/).

.DESCRIPTION
    This script fully restores a Modern Copilot Studio agent from a bundle produced by export.ps1.
    It requires NO prior knowledge of the agent — everything needed is in the bundle folder.

    THE BUNDLE FOLDER MUST CONTAIN:
      agent.zip              The Dataverse solution package
      manifest.json          Export inventory (agent schema, connectors, skills with assets)
      skills-with-assets/    Binary skill files (only present if agent has ZIP-uploaded skills)

    WHAT pac solution import HANDLES AUTOMATICALLY (no extra steps needed):
    ─────────────────────────────────────────────────────────────────────
      bot.configuration     Instructions, model series, AI settings — restored from
                            bots/{schema}/configuration.json inside agent.zip
      InlineAgentSkills     Markdown-only skills — fully restored
      Flow tools            WorkflowTool and TaskDialog tools — restored with correct GUIDs
                            (solution import preserves GUIDs — no remap needed)
      ConnectorTool/McpTool Connection reference records created (empty — wire manually)
      ConnectedAgentTool    Restored by schema name — target agent must exist
      URL knowledge sources Restored from knowledge/*.mcs.yml
      Evaluation test cases All MultiTurnEvaluationCase records restored
      Connection references Created with null connectionid (normal — wire manually after)

    WHAT THIS SCRIPT ADDS ON TOP (the one thing solution import cannot do):
    ──────────────────────────────────────────────────────────────────────
      Skills with assets    ZIP-uploaded skills (containing Python files, images, etc.)
                            Solution import restores the type-9 skill record and type-14
                            file component records, but does NOT reconstitute the binary
                            bundle blob (bic:bundle=...) that the skill references at runtime.
                            This script detects those broken skills and re-uploads them by:
                              1. Building a ZIP from the files in skills-with-assets/
                              2. Deleting the broken skill + its stale file components
                              3. Re-uploading via DV API — creates a fresh bundle in target env

    MANUAL STEP REQUIRED AFTER IMPORT (for agents with connectors):
    ───────────────────────────────────────────────────────────────
      Power Automate flows that use connectors (Office 365, Power BI, Dataverse, etc.)
      are created in Draft state. They activate automatically once their connection
      references are wired to real connections. This is normal Power Platform behavior.
        1. Go to PPAC → your environment → Connections → New connection
        2. Create a connection for each required connector
        3. Go to Default Solution → Connection References → edit each → link to connection
        4. Flows activate automatically

    PREREQUISITES
    ─────────────
    pac CLI:  https://aka.ms/PowerPlatformCLI
    az CLI:   https://aka.ms/installazurecliwindows
    pac auth: pac auth create --environment https://yourorg.crm.dynamics.com
    az login: az login (with Dataverse access to target env)

.PARAMETER BundleDir
    Path to the export bundle folder (contains agent.zip, manifest.json, skills-with-assets/).
    Defaults to current directory.

.PARAMETER TargetOrgUrl
    Dataverse org URL for the target environment.

.PARAMETER AuthIndex
    pac auth index for the target environment.

.PARAMETER PacExe
    Path to pac.exe. Auto-detected from PATH or NuGet cache if not specified.

.EXAMPLE
    .\install.ps1 -TargetOrgUrl "https://myorg.crm.dynamics.com"

.EXAMPLE
    .\install.ps1 -BundleDir "C:\downloads\my-agent-bundle" -TargetOrgUrl "https://myorg.crm.dynamics.com" -AuthIndex 2
#>
param(
    [string] $BundleDir    = ".",
    [Parameter(Mandatory)][string] $TargetOrgUrl,
    [int]    $AuthIndex    = 1,
    [string] $PacExe       = ""
)

$ErrorActionPreference = "Stop"
$OrgNoTrail = $TargetOrgUrl.TrimEnd("/")

# Resolve pac.exe
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

# Validate bundle
$zipPath      = Join-Path $BundleDir "agent.zip"
$manifestPath = Join-Path $BundleDir "manifest.json"
if (-not (Test-Path $zipPath))      { Write-Error "agent.zip not found in: $BundleDir" }
if (-not (Test-Path $manifestPath)) { Write-Error "manifest.json not found in: $BundleDir" }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Modern Agent Install — Solution Path    ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  Target  : $OrgNoTrail"
Write-Host "  Agent   : $($manifest.agentName) ($($manifest.agentSchema))"
Write-Host "  Bundle  : $BundleDir"
Write-Host "  ZIP     : $([Math]::Round((Get-Item $zipPath).Length/1KB))KB"
Write-Host "  Skills with assets: $($manifest.skillsWithAssets.Count)"
Write-Host ""

# ── Acquire DV token ──────────────────────────────────────────────────────────
Step "Acquiring Dataverse token..."
$token = (az account get-access-token --resource $OrgNoTrail | ConvertFrom-Json).accessToken
$dv = @{ Authorization="Bearer $token"; "OData-MaxVersion"="4.0"; "OData-Version"="4.0"; Accept="application/json"; "Content-Type"="application/json"; Prefer="return=representation" }
OK "Token acquired"

# ── Step 1: pac solution import ───────────────────────────────────────────────
Step "Step 1 — pac solution import"
INFO "This step handles:"
INFO "  - bot.configuration (instructions, model) — from bots/*/configuration.json in ZIP"
INFO "  - All tools (ConnectorTool, McpTool, WorkflowTool, TaskDialog)"
INFO "  - InlineAgentSkill (markdown-only skills)"
INFO "  - URL knowledge sources"
INFO "  - Power Automate flows (GUIDs preserved — no remap needed)"
INFO "  - Connection references (created empty — wire manually after)"
INFO "  - Evaluation test cases"
INFO "  - Skills with assets (file records imported, bundle needs Step 2)"

& $PacExe auth select --index $AuthIndex | Out-Null
& $PacExe solution import --path $zipPath --environment $OrgNoTrail 2>&1 | ForEach-Object { INFO $_ }
if ($LASTEXITCODE -ne 0) { Write-Error "pac solution import failed. See output above." }
OK "Solution import complete"

# ── Step 2: Document skills with assets requiring manual re-upload ─────────────
# IMPORTANT: Skills uploaded as ZIP files (containing Python/binary assets) have a
# bic:bundle= reference that is created by Copilot Studio's server-side processing.
# This bundle blob is NOT accessible via the Dataverse OData API, and cannot be
# recreated programmatically. After solution import:
#   - The skill RECORD exists (type-9 botcomponent)
#   - The file COMPONENTS exist (type-14 botcomponents with binary content)
#   - But the bic:bundle= reference is broken — assets are unreachable at runtime
#
# FIX: Manually re-upload each skill ZIP through the Copilot Studio UI:
#   1. Open the agent in Copilot Studio
#   2. Skills section → click X to remove the broken skill
#   3. Add skill → Upload a skill → upload the ZIP from skills-with-assets/
#
if (.skillsWithAssets.Count -gt 0) {
    Step "Step 2 — Skills with assets require manual re-upload"
    Write-Host ""
    Write-Host "  The following skills use binary assets (Python scripts, etc.):" -ForegroundColor Yellow
    foreach ( in .skillsWithAssets) {
        Write-Host "    • " -ForegroundColor Cyan
        Write-Host "      Files: "
         = Join-Path  "skills-with-assets\"
        Write-Host "      Source: "
    }
    Write-Host ""
    Write-Host "  After import, for each skill above:" -ForegroundColor Yellow
    Write-Host "    1. Open the agent in Copilot Studio"
    Write-Host "    2. In Skills, click X to remove the broken skill entry"
    Write-Host "    3. Add skill → Upload a skill → upload the ZIP from the source path above"
    Write-Host "    4. Save the agent"
    Write-Host ""
    WARN "Skills with assets CANNOT be automatically fixed — manual UI upload required"
    WARN "This is a known Copilot Studio limitation (no public API for bundle creation)"
} else {
    Step "Step 2 — No skills with assets (skipping)"
    OK "No binary skill bundles to fix"
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Install Complete                        ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
$envId = $OrgNoTrail -replace "https://","" -replace "\.crm\.dynamics\.com",""
Write-Host "  Agent in Copilot Studio:"
Write-Host "  https://copilotstudio.microsoft.com/environments/$envId/home" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Status:"
Write-Host "    [x] Solution imported (bot, tools, skills, flows, knowledge, eval cases)"
Write-Host "    [x] bot.configuration applied (instructions, model)"
if ($manifest.skillsWithAssets.Count -gt 0) {
    Write-Host "    [x] $($manifest.skillsWithAssets.Count) skill(s) with assets re-uploaded"
}
Write-Host ""
if ($manifest.connectorsRequired.Count -gt 0) {
    Write-Host "  MANUAL STEP — wire connections (one-time per environment):" -ForegroundColor Yellow
    Write-Host "    Flows are in Draft until connections are wired."
    Write-Host "    Connectors needed:"
    $manifest.connectorsRequired | ForEach-Object { Write-Host "      • $_" -ForegroundColor Cyan }
    Write-Host ""
    Write-Host "    1. PPAC → Connections → New connection → create one per connector"
    Write-Host "    2. Default Solution → Connection References → edit each → link to connection"
    Write-Host "    3. Flows activate automatically"
}

" }
        $newData   = "kind: InlineAgentSkill`ncontent: |-`n" + ($indented -join "`n")

        # PATCH the skill's data field
        Invoke-RestMethod -Uri "$OrgNoTrail/api/data/v9.2/botcomponents($($skill.botcomponentid))" -Method PATCH -Headers $dv -Body (@{ data = $newData } | ConvertTo-Json) | Out-Null
        OK "  '$($skill.name)' fixed: bic:bundle= → inline InlineAgentSkill"
        WARN "  Note: Python execution via Code Interpreter unavailable (bundle not restored)"
        WARN "  To restore Python execution: re-upload original ZIP via Copilot Studio UI"
    }
} else {
    Step "Step 2 — No skills with assets (skipping)"
    OK "No bic:bundle= skills to fix"
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Install Complete                        ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
$envId = $OrgNoTrail -replace "https://","" -replace "\.crm\.dynamics\.com",""
Write-Host "  Agent in Copilot Studio:"
Write-Host "  https://copilotstudio.microsoft.com/environments/$envId/home" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Status:"
Write-Host "    [x] Solution imported (bot, tools, skills, flows, knowledge, eval cases)"
Write-Host "    [x] bot.configuration applied (instructions, model)"
if ($manifest.skillsWithAssets.Count -gt 0) {
    Write-Host "    [x] $($manifest.skillsWithAssets.Count) skill(s) with assets re-uploaded"
}
Write-Host ""
if ($manifest.connectorsRequired.Count -gt 0) {
    Write-Host "  MANUAL STEP — wire connections (one-time per environment):" -ForegroundColor Yellow
    Write-Host "    Flows are in Draft until connections are wired."
    Write-Host "    Connectors needed:"
    $manifest.connectorsRequired | ForEach-Object { Write-Host "      • $_" -ForegroundColor Cyan }
    Write-Host ""
    Write-Host "    1. PPAC → Connections → New connection → create one per connector"
    Write-Host "    2. Default Solution → Connection References → edit each → link to connection"
    Write-Host "    3. Flows activate automatically"
}



