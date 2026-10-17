#Requires -Version 7.4

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
    [Parameter(Mandatory = $true)]
    [string] $VerificationDir,

    [Parameter(Mandatory = $true)]
    [string] $ResultPath,

    [Parameter(Mandatory = $true)]
    [string] $PatchPath,

    # JSON from the agent job: model, turns, duration_s, blocked.
    [Parameter(Mandatory = $false)]
    [string] $AgentStatsPath,

    [Parameter(Mandatory = $true)]
    [string] $PullRequestDir,

    [Parameter(Mandatory = $true)]
    [int] $PullRequest,

    [Parameter(Mandatory = $true)]
    [string] $Branch,

    [Parameter(Mandatory = $true)]
    [string] $HeadSha,

    [Parameter(Mandatory = $false)]
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/lib/AgentPatch.psm1"
Import-Module "$PSScriptRoot/lib/PrComment.psm1"
Import-Module "$PSScriptRoot/lib/GitHubPr.psm1"

$verification = Get-Content -LiteralPath (Join-Path $VerificationDir 'verification.json') -Raw | ConvertFrom-Json

# The agent's text is shown only when the verify job accepted the result.
$agentResult = $null
if ($verification.agent_result.valid) {
    $agentResult = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json
}

$runUrl = $null
if (-not [System.String]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) {
    $runUrl = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
}
$runInfo = @{
    server_url = $env:GITHUB_SERVER_URL
    repository = $env:GITHUB_REPOSITORY
    commit     = $HeadSha
    run_url    = $runUrl
}
if (-not [System.String]::IsNullOrWhiteSpace($AgentStatsPath) -and (Test-Path -LiteralPath $AgentStatsPath)) {
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
        throw "The patch failed the check in the publish job: $([System.String]::Join('; ', @($patchCheck.Errors)))"
    }
    if ($DryRun) {
        Write-Host "Dry run: would commit $([System.String]::Join(', ', @($patchCheck.Files))) to $Branch"
    }
    else {
        # [skip ci]: GitHub creates no new run for this commit. It holds exactly the patch
        # the verify job checked; without it, every agent commit starts another run.
        $message = "test: add or update Terraform tests (test agent) [skip ci]`n`nVerified by workflow run $runUrl"
        $push = Publish-TestCommit -RepoRoot $PullRequestDir -PatchPath $PatchPath -File $patchCheck.Files -Branch $Branch -Message $message
        $commitSha = $push.CommitSha
        $pushError = $push.Error
    }
}

# --- Comment ----------------------------------------------------------------------

$body = New-PrCommentBody -Verification $verification -AgentResult $agentResult -RunInfo $runInfo -CommitSha $commitSha -PushError $pushError

if (-not [System.String]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
    $body | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8
}

if ($DryRun) {
    $body
}
else {
    $url = Set-PrComment -Repository $env:GITHUB_REPOSITORY -PullRequest $PullRequest -Body $body -Marker (Get-PrCommentMarker)
    Write-Host "Comment: $url"
}

if ($verification.verdict -ne 'verified' -or -not [System.String]::IsNullOrWhiteSpace($pushError)) {
    Write-Host "Verdict: $($verification.verdict)"
    exit 1
}
