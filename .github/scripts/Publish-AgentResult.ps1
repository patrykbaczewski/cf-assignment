<#
.SYNOPSIS
    The publish job: commits verified tests to the pull request and updates the comment.

.DESCRIPTION
    The only job with write access. It runs no LLM, and these scripts come from the base
    branch, not from the pull request. The pull request branch is checked out separately
    in -PullRequestDir and only used as the place to commit.

      1. Read verification.json from the verify job (and the agent's result, if valid).
      2. When the verify job allows a commit: check the patch again here, then commit
         and push the test files.
      3. Create or update the one pull request comment, and the job summary.

    Exits 1 when the verdict is not "verified", so the check shows red. The comment is
    written first, so the reason is always visible in the pull request.

    With -DryRun nothing is committed or posted; the comment is printed instead.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $VerificationDir,

    [Parameter(Mandatory)]
    [string] $ResultPath,

    [Parameter(Mandatory)]
    [string] $PatchPath,

    # Optional JSON from the agent job: model, turns, duration_s.
    [string] $AgentStatsPath,

    [Parameter(Mandatory)]
    [string] $PullRequestDir,

    [Parameter(Mandatory)]
    [int] $PullRequest,

    [Parameter(Mandatory)]
    [string] $Branch,

    [Parameter(Mandatory)]
    [string] $HeadSha,

    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/AgentPatch.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/PrComment.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib/GitHubPr.psm1')

$verification = Get-Content -LiteralPath (Join-Path $VerificationDir 'verification.json') -Raw | ConvertFrom-Json

# The agent's text is shown only when the verify job accepted the result.
$agentResult = $null
if ($verification.agent_result.valid) {
    $agentResult = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json
}

$runInfo = @{
    server_url = $env:GITHUB_SERVER_URL
    repository = $env:GITHUB_REPOSITORY
    commit     = $HeadSha
    run_url    = if ($env:GITHUB_RUN_ID) { "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID" }
}
if ($AgentStatsPath -and (Test-Path -LiteralPath $AgentStatsPath)) {
    $stats = Get-Content -LiteralPath $AgentStatsPath -Raw | ConvertFrom-Json
    $runInfo.model = $stats.model
    $runInfo.turns = $stats.turns
    $runInfo.duration_s = $stats.duration_s
    $runInfo.blocked = $stats.blocked
}

# --- Commit the verified tests --------------------------------------------------

$commitSha = $null
$pushError = $null
if ($verification.can_commit) {
    # Check again here instead of trusting the artifact from the verify job.
    $patchCheck = Test-AgentPatch -PatchPath $PatchPath -RepoRoot $PullRequestDir -AllowedModule @($verification.modules)
    if (-not $patchCheck.IsValid) {
        throw "The patch failed the check in the publish job: $($patchCheck.Errors -join '; ')"
    }
    if ($DryRun) {
        Write-Host "Dry run: would commit $($patchCheck.Files -join ', ') to $Branch"
    }
    else {
        $message = "test: add or update Terraform tests (test agent)`n`nVerified by workflow run $($runInfo.run_url)"
        $push = Publish-TestCommit -RepoRoot $PullRequestDir -PatchPath $PatchPath -File $patchCheck.Files -Branch $Branch -Message $message
        $commitSha = $push.CommitSha
        $pushError = $push.Error
    }
}

# --- Comment ----------------------------------------------------------------------

$body = New-PrCommentBody -Verification $verification -AgentResult $agentResult -RunInfo $runInfo -CommitSha $commitSha -PushError $pushError

if ($env:GITHUB_STEP_SUMMARY) {
    $body | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8
}

if ($DryRun) {
    $body
}
else {
    $url = Set-PrComment -Repository $env:GITHUB_REPOSITORY -PullRequest $PullRequest -Body $body -Marker (Get-PrCommentMarker)
    Write-Host "Comment: $url"
}

if ($verification.verdict -ne 'verified' -or $pushError) {
    Write-Host "Verdict: $($verification.verdict)"
    exit 1
}
