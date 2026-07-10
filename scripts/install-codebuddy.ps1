#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Sync upstream mattpocock/skills and auto-install adapted skills to CodeBuddy user-level directory.

.DESCRIPTION
    This script:
    1. Syncs the fork with upstream (mattpocock/skills main branch)
    2. Auto-converts selected upstream skills into CodeBuddy format
    3. Applies local patches (from .codebuddy/patches/) if any exist
    4. Installs the result to CodeBuddy's user-level skill directory

    The upstream skills/ directory is the SINGLE SOURCE OF TRUTH.
    No manual editing of adapted skills is needed — this script handles
    all Claude-to-CodeBuddy translation automatically on each run.

.PARAMETER SkipSync
    Skip the upstream sync step (useful when offline).

.PARAMETER SkillsDir
    Override the CodeBuddy user skills directory.

.EXAMPLE
    ./scripts/install-codebuddy.ps1
    ./scripts/install-codebuddy.ps1 -SkipSync
#>

param(
    [switch]$SkipSync,
    [string]$SkillsDir
)

$ErrorActionPreference = "Stop"

# --- Configuration ---
$UPSTREAM_REMOTE = "upstream"
$UPSTREAM_URL = "https://github.com/mattpocock/skills.git"
$UPSTREAM_BRANCH = "main"

# Mapping: CodeBuddy skill name => upstream path (relative to repo root)
# Key = output skill name, Value = source skill directory
$SKILL_MAP = [ordered]@{
    "grill-with-docs" = "skills/engineering/grill-with-docs"
    "to-prd"          = "skills/engineering/to-spec"
    "to-issues"       = "skills/engineering/to-tickets"
    "implement"       = "skills/engineering/implement"
    "code-review"     = "skills/engineering/code-review"
}

# Skills that are "shell" skills — their content is just "Run a /X session",
# so we need to inline the referenced skill's content.
# Format: shell-skill-path => referenced-skill-path
$SHELL_SKILLS = @{
    "skills/engineering/grill-with-docs" = @("skills/productivity/grilling", "skills/engineering/domain-modeling")
}

# --- Resolve paths ---
$REPO_ROOT = Resolve-Path (Join-Path $PSScriptRoot "..")
$PATCHES_DIR = Join-Path $REPO_ROOT ".codebuddy" "patches"

if (-not $SkillsDir) {
    if ($IsWindows -or ($env:OS -and $env:OS -match "Windows")) {
        $SkillsDir = Join-Path $env:USERPROFILE ".codebuddy" "skills"
    } else {
        $SkillsDir = Join-Path $HOME ".codebuddy" "skills"
    }
}

# --- Functions ---
function Write-Step($msg) {
    Write-Host "`n==> $msg" -ForegroundColor Cyan
}

function Write-Ok($msg) {
    Write-Host "  [OK] $msg" -ForegroundColor Green
}

function Write-Warn($msg) {
    Write-Host "  [!!] $msg" -ForegroundColor Yellow
}

function Convert-SkillForCodeBuddy {
    <#
    .SYNOPSIS
        Convert an upstream SKILL.md to CodeBuddy format.
    #>
    param(
        [string]$SourcePath,
        [string]$OutputName,
        [string]$RepoRoot
    )

    $skillFile = Join-Path $RepoRoot $SourcePath "SKILL.md"
    if (-not (Test-Path $skillFile)) {
        Write-Warn "Source not found: $skillFile"
        return $null
    }

    $content = Get-Content $skillFile -Raw -Encoding UTF8

    # --- Transform 1: Remove disable-model-invocation (CodeBuddy doesn't use it) ---
    $content = $content -replace "(?m)^disable-model-invocation:\s*(true|false)\s*\r?\n", ""

    # --- Transform 2: Replace /skill-name references with descriptive text ---
    # Pattern: "Run a /skill-name session." or "use /skill-name" etc.
    # For shell skills, we'll handle them specially below.
    # For inline references, just remove the slash prefix for clarity.
    $content = $content -replace '`/([a-z-]+)`', '`$1` 技能'
    $content = $content -replace ' /([a-z-]+)([^a-z-])', ' `$1` 技能$2'

    # --- Transform 3: Handle shell skills (inline referenced content) ---
    if ($SHELL_SKILLS.ContainsKey($SourcePath)) {
        $refs = $SHELL_SKILLS[$SourcePath]
        # Check if content is a thin shell (< 5 meaningful lines after frontmatter)
        $bodyLines = ($content -split "---\s*\r?\n", 3)
        if ($bodyLines.Count -ge 3) {
            $body = $bodyLines[2].Trim()
            $meaningfulLines = ($body -split "`n" | Where-Object { $_.Trim() -ne "" }).Count
            if ($meaningfulLines -le 3) {
                # It's a shell skill — build content from referenced skills
                $frontmatter = "---`n" + $bodyLines[1] + "---`n`n"
                $inlinedBody = ""
                foreach ($ref in $refs) {
                    $refFile = Join-Path $RepoRoot $ref "SKILL.md"
                    if (Test-Path $refFile) {
                        $refContent = Get-Content $refFile -Raw -Encoding UTF8
                        # Extract body (after second ---)
                        $refParts = ($refContent -split "---\s*\r?\n", 3)
                        if ($refParts.Count -ge 3) {
                            $refBody = $refParts[2]
                            # Clean up /skill references in the inlined content too
                            $refBody = $refBody -replace '`/([a-z-]+)`', '`$1` 技能'
                            $refBody = $refBody -replace ' /([a-z-]+)([^a-z-])', ' `$1` 技能$2'
                            $inlinedBody += $refBody + "`n`n"
                        }
                    }
                }
                $content = $frontmatter + $inlinedBody.TrimEnd()
            }
        }
    }

    # --- Transform 4: Rename skill if output name differs ---
    if ($OutputName -and $content -match "(?m)^name:\s*.+") {
        $content = $content -replace "(?m)^name:\s*.+", "name: $OutputName"
    }

    # --- Transform 5: Remove setup-matt-pocock-skills references ---
    $content = $content -replace "(?m)^.*run\s+`setup-matt-pocock-skills`.*\r?\n?", ""
    $content = $content -replace "(?m)^.*`/setup-matt-pocock-skills`.*\r?\n?", ""

    return $content
}

# --- Step 1: Sync upstream ---
if (-not $SkipSync) {
    Write-Step "Syncing with upstream ($UPSTREAM_URL)"

    Push-Location $REPO_ROOT
    try {
        # Ensure upstream remote exists
        $remotes = git remote 2>&1
        if ($remotes -notcontains $UPSTREAM_REMOTE) {
            git remote add $UPSTREAM_REMOTE $UPSTREAM_URL
            Write-Ok "Added remote '$UPSTREAM_REMOTE'"
        }

        # Fetch upstream
        git fetch $UPSTREAM_REMOTE $UPSTREAM_BRANCH 2>&1 | Out-Null
        Write-Ok "Fetched $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"

        # Merge if on main
        $currentBranch = git branch --show-current
        if ($currentBranch -eq "main") {
            $mergeOutput = git merge "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH" --no-edit 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "Merge conflict! Resolve manually, then re-run."
                Write-Host $mergeOutput
                Pop-Location
                exit 1
            }
            Write-Ok "Merged upstream/main"
        } else {
            Write-Warn "Not on main (current: $currentBranch), skipping merge"
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Step "Skipping upstream sync (-SkipSync)"
}

# --- Step 2: Convert and install ---
Write-Step "Converting and installing skills"

if (-not (Test-Path $SkillsDir)) {
    New-Item -ItemType Directory -Path $SkillsDir -Force | Out-Null
}

$installed = 0

foreach ($entry in $SKILL_MAP.GetEnumerator()) {
    $outputName = $entry.Key
    $sourcePath = $entry.Value
    $destDir = Join-Path $SkillsDir $outputName

    # Convert
    $converted = Convert-SkillForCodeBuddy -SourcePath $sourcePath -OutputName $outputName -RepoRoot $REPO_ROOT

    if (-not $converted) {
        Write-Warn "$outputName — conversion failed, skipping"
        continue
    }

    # Apply patch if exists
    $patchFile = Join-Path $PATCHES_DIR "$outputName.patch.md"
    if (Test-Path $patchFile) {
        $patch = Get-Content $patchFile -Raw -Encoding UTF8
        $converted += "`n`n" + $patch
        Write-Host "    (applied patch)" -ForegroundColor DarkGray
    }

    # Write to destination
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    $converted | Set-Content (Join-Path $destDir "SKILL.md") -Encoding UTF8 -NoNewline

    # Copy bundled resources (scripts/, references/, assets/) if any
    $srcFullPath = Join-Path $REPO_ROOT $sourcePath
    foreach ($subdir in @("scripts", "references", "assets")) {
        $srcSub = Join-Path $srcFullPath $subdir
        if (Test-Path $srcSub) {
            $destSub = Join-Path $destDir $subdir
            if (Test-Path $destSub) { Remove-Item -Recurse -Force $destSub }
            Copy-Item -Recurse -Force $srcSub $destSub
        }
    }

    Write-Ok "$outputName (from $sourcePath)"
    $installed++
}

# --- Summary ---
Write-Step "Done! Installed $installed skills to $SkillsDir"
Write-Host ""
Write-Host "  Workflow:" -ForegroundColor White
Write-Host "    1. /grill-with-docs  — 把想法磨清楚 + 构建领域模型"
Write-Host "    2. /to-prd           — 把对话合成一份PRD"
Write-Host "    3. /to-issues        — 把PRD切成独立issue"
Write-Host "    4. /implement        — 每个issue实现"
Write-Host "    5. /code-review      — 写完收尾评审"
Write-Host ""
Write-Host "  Re-run this script anytime to pick up upstream changes." -ForegroundColor Gray
Write-Host ""
