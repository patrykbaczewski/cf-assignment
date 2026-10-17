# Writes to the pull request: the comment and the commit with verified tests.
# Only the publish job uses these functions. It has write access, runs no LLM and no
# code from the pull request.

Import-Module (Join-Path $PSScriptRoot 'RepoPaths.psm1')

# The identity GitHub uses for commits made with the workflow token.
$script:BotName = 'github-actions[bot]'
$script:BotEmail = '41898282+github-actions[bot]@users.noreply.github.com'

function Assert-PullRequestTarget {
    param([string] $Repository, [int] $PullRequest)

    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "'$Repository' is not owner/name." }
    if ($PullRequest -lt 1) { throw "'$PullRequest' is not a pull request number." }
}

function Set-PrComment {
    <#
    .SYNOPSIS
        Updates the agent's comment on a pull request, or creates it on the first run.
    .DESCRIPTION
        The comment is found by its hidden marker, and only among comments written by
        the workflow's bot, so the job never edits a comment written by a person.
        Uses the GitHub CLI (gh) with the token in GH_TOKEN.
    .OUTPUTS
        The URL of the comment.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Repository,

        [Parameter(Mandatory)]
        [int] $PullRequest,

        [Parameter(Mandatory)]
        [string] $Body,

        [Parameter(Mandatory)]
        [string] $Marker
    )

    Assert-PullRequestTarget -Repository $Repository -PullRequest $PullRequest

    $comments = & gh api --paginate "repos/$Repository/issues/$PullRequest/comments" | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'Could not list the pull request comments.' }
    $existing = @($comments) | Where-Object { $_.user.login -eq $script:BotName -and $_.body.Contains($Marker) } | Select-Object -Last 1

    # The body goes through a file, so no part of it is read as a command-line option.
    $bodyFile = New-TemporaryFile
    try {
        @{ body = $Body } | ConvertTo-Json | Set-Content -LiteralPath $bodyFile -Encoding utf8
        $response = if ($existing) {
            & gh api --method PATCH "repos/$Repository/issues/comments/$($existing.id)" --input $bodyFile
        }
        else {
            & gh api --method POST "repos/$Repository/issues/$PullRequest/comments" --input $bodyFile
        }
        if ($LASTEXITCODE -ne 0) { throw 'Could not write the pull request comment.' }
        ($response | ConvertFrom-Json).html_url
    }
    finally {
        Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
    }
}

function Publish-TestCommit {
    <#
    .SYNOPSIS
        Commits the verified test files to the pull request branch and pushes them.
    .DESCRIPTION
        Applies the patch in a checkout of the pull request branch, commits only the
        given files as github-actions[bot] and pushes. When someone pushed to the branch
        in the meantime, the push fails and nothing is overwritten.
    .OUTPUTS
        An object with CommitSha (or $null) and Error (or $null).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot,

        [Parameter(Mandatory)]
        [string] $PatchPath,

        # The test files to commit (from the verified patch).
        [Parameter(Mandatory)]
        [string[]] $File,

        [Parameter(Mandatory)]
        [string] $Branch,

        [Parameter(Mandatory)]
        [string] $Message
    )

    if ($Branch -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') { throw "'$Branch' is not an allowed branch name." }
    foreach ($path in $File) {
        if (-not (Test-AgentWritablePath -RelativePath $path)) { throw "'$path' is not a test file." }
    }

    & git -C $RepoRoot apply $PatchPath
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ CommitSha = $null; Error = 'The verified patch does not apply to the pull request branch any more.' } }

    & git -C $RepoRoot add -- $File
    & git -C $RepoRoot -c "user.name=$script:BotName" -c "user.email=$script:BotEmail" commit --quiet -m $Message -- $File
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed.' }
    $sha = (& git -C $RepoRoot rev-parse HEAD).Trim()

    & git -C $RepoRoot push --quiet origin "HEAD:refs/heads/$Branch"
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{ CommitSha = $null; Error = 'The push was rejected, probably because the branch changed during the run. Push again to re-run the agent.' }
    }
    [pscustomobject]@{ CommitSha = $sha; Error = $null }
}

Export-ModuleMember -Function Set-PrComment, Publish-TestCommit
