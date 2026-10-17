#Requires -Version 7.4

<#
.SYNOPSIS
    Replaces the agent tooling in a pull request checkout with the base branch version.

.DESCRIPTION
    A pull request may change the agent, its rules or the scripts that check it. Its
    changes take effect after review and merge; until then the base branch versions run.

      1. Deletes .github, .claude and CLAUDE.md from the checkout and restores them from
         the base branch.
      2. Deletes files Claude Code loads by itself, wherever they are: nested CLAUDE.md,
         CLAUDE.local.md, .mcp.json (MCP servers are programs started with the agent)
         and nested .claude folders.

    Run it in the root of the pull request checkout, fetched with history
    (fetch-depth: 0), so origin/<BaseRef> exists. In the workflow it runs through the
    action .github/actions/use-base-tooling, from the base branch copy of this file.

.PARAMETER BaseRef
    The base branch, for example main.

.EXAMPLE
    pwsh -File .github/scripts/Restore-BaseTooling.ps1 -BaseRef main
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $BaseRef
)

$ErrorActionPreference = 'Stop'

# A ref that starts with "-" would be read by git as an option.
if ($BaseRef -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') {
    throw "'$BaseRef' is not an allowed branch name."
}

$root = (Get-Location).Path

# --- 1. The agent tooling from the base branch ----------------------------------
# Deleted first, so files the pull request added next to them do not stay behind.
Remove-Item -LiteralPath (Join-Path $root '.github'), (Join-Path $root '.claude'), (Join-Path $root 'CLAUDE.md') `
    -Recurse -Force -ErrorAction SilentlyContinue
& git -C $root checkout "origin/$BaseRef" -- .github .claude CLAUDE.md
if ($LASTEXITCODE -ne 0) {
    throw "The base branch '$BaseRef' has no agent tooling yet."
}

# --- 2. Files Claude Code would load by itself ----------------------------------
$rootClaudeMd = Join-Path $root 'CLAUDE.md'
$rootClaudeDir = Join-Path $root '.claude'

$files = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File -Include CLAUDE.md, CLAUDE.local.md, .mcp.json |
        Where-Object { $_.FullName -ne $rootClaudeMd })
$folders = @(Get-ChildItem -LiteralPath $root -Recurse -Force -Directory -Filter .claude |
        Where-Object { $_.FullName -ne $rootClaudeDir })

foreach ($item in $files + $folders) {
    # A folder can be gone already, when it was inside another removed folder.
    if (Test-Path -LiteralPath $item.FullName) {
        Write-Host "Removed $([System.IO.Path]::GetRelativePath($root, $item.FullName))"
        Remove-Item -LiteralPath $item.FullName -Recurse -Force
    }
}
Write-Host "The agent tooling comes from origin/$BaseRef."
