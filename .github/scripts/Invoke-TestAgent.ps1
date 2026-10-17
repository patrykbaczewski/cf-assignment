<#
.SYNOPSIS
    The agent job: runs the test agent on the given modules and collects its output.

.DESCRIPTION
    1. Writes the agent's input outside the repository: the diff of the modules.
    2. Builds the task message from .github/agent/task-prompt.md.
    3. Records the working tree (baseline), so only the agent's changes count.
    4. Runs Claude Code as the terraform-test-engineer agent, locked down.
    5. Writes to -OutputDir:
         agent-result.json      the agent's result, when it returned one
         agent.patch            every change since the baseline
         agent-stats.json       model, turns, duration, blocked tool uses
         agent-transcript.jsonl the whole session, for audit

    A failing agent does not fail this script: the verify job reports what is missing.

    Note: the baseline stages all files in the git index. Run this in CI or in a
    scratch checkout, not in a working tree with changes you care about.

.PARAMETER Modules
    Comma-separated modules, for example modules/a,modules/b.

.PARAMETER BaseRef
    The base branch, for example origin/main. Without it the agent gets no diff and
    covers the modules as a whole.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Modules,

    [string] $BaseRef,

    [string] $Model = 'claude-opus-5-5',

    [Parameter(Mandatory)]
    [string] $OutputDir
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/RepoPaths.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/GitChanges.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/AgentPatch.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/AgentRun.psm1')

$repoRoot = Get-RepoRoot
$moduleList = @($Modules -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { ConvertTo-ModulePath -Path $_ })
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# --- 1. Input, outside the repository ------------------------------------------
$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$inputDir = Join-Path $tempRoot 'agent-input'
New-Item -ItemType Directory -Path $inputDir -Force | Out-Null

$diffPath = $null
if ($BaseRef) {
    $diffPath = Join-Path $inputDir 'changes.diff'
    Export-ModuleDiff -RepoRoot $repoRoot -BaseRef $BaseRef -Module $moduleList -Path $diffPath
}

# --- 2. Task message -----------------------------------------------------------
$prompt = New-AgentTaskPrompt -TemplatePath (Join-Path $repoRoot '.github/agent/task-prompt.md') `
    -RepoRoot $repoRoot -Module $moduleList -DiffPath $diffPath
$prompt | Set-Content -LiteralPath (Join-Path $OutputDir 'agent-task.md') -Encoding utf8

# --- 3 and 4. Baseline, then the agent -----------------------------------------
$baseline = Save-WorkspaceBaseline -RepoRoot $repoRoot
$transcript = Join-Path $OutputDir 'agent-transcript.jsonl'

Write-Host "Running the agent ($Model) on: $($moduleList -join ', ')"
$exitCode = Invoke-TestAgentSession -RepoRoot $repoRoot -Prompt $prompt -Model $Model `
    -Module $moduleList -InputDir $inputDir -TranscriptPath $transcript

# --- 5. Output -----------------------------------------------------------------
$session = Read-AgentTranscript -Path $transcript
$session.Stats.exit_code = $exitCode
$session.Stats | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDir 'agent-stats.json') -Encoding utf8

if ($session.Result) {
    $session.Result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $OutputDir 'agent-result.json') -Encoding utf8
}

Export-AgentPatch -RepoRoot $repoRoot -Baseline $baseline -PatchPath (Join-Path $OutputDir 'agent.patch')

Write-Host ''
Write-Host "Agent finished: outcome=$($session.Stats.outcome) exit=$exitCode turns=$($session.Stats.turns) duration=$($session.Stats.duration_s)s blocked=$($session.Stats.blocked) result=$([bool]$session.Result)"
