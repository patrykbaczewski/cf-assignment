# Builds the pull request comment from the verification and the agent's result.
# Text written by the agent (an LLM) is untrusted: it is escaped before it is shown,
# so it cannot add HTML, links that look like ours, or mentions that notify people.

# Finds our comment again on the next run, so there is one comment that gets updated.
$script:Marker = '<!-- tf-test-agent -->'

# GitHub rejects comments longer than 65536 characters.
$script:MaxBodyLength = 60000

$script:SeverityOrder = @{ high = 0; medium = 1; low = 2; info = 3 }
$script:SeverityIcon = @{ high = '🔴'; medium = '🟠'; low = '🟡'; info = '🔵' }
$script:StatusIcon = @{ passed = '✅'; failed = '❌'; error = '❌'; no_tests = '⚪'; not_run = '⚪' }

function Get-PrCommentMarker {
    <#
    .SYNOPSIS
        Returns the hidden marker that identifies the agent's comment.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $script:Marker
}

function ConvertTo-SafeMarkdown {
    <#
    .SYNOPSIS
        Makes untrusted text safe to show in a comment.
    .DESCRIPTION
        - HTML characters are escaped, so the text cannot add tags or hidden content.
        - Square brackets are escaped, so the text cannot add links or images.
        - @ before a name gets an invisible space, so nobody is notified.
        - With -SingleLine, line breaks become spaces and | is escaped (for tables).
        - Text longer than -MaxLength is cut.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text,

        [int] $MaxLength = 1000,

        [switch] $SingleLine
    )

    if (-not $Text) { return '' }

    $safe = $Text
    if ($safe.Length -gt $MaxLength) {
        $safe = $safe.Substring(0, $MaxLength) + ' …'
    }
    $safe = $safe.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
    $safe = $safe.Replace('[', '\[').Replace(']', '\]')
    $safe = $safe -replace '@(?=[A-Za-z0-9])', "@$([char]0x200B)"

    if ($SingleLine) {
        $safe = ($safe -replace '\s*\r?\n\s*', ' ').Replace('|', '\|')
    }
    $safe
}

function ConvertTo-CodeBlock {
    <#
    .SYNOPSIS
        Puts untrusted text in a fenced code block that the text cannot close.
    .DESCRIPTION
        The fence is one backtick longer than the longest run of backticks in the text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Code,

        [string] $Language = '',

        [int] $MaxLength = 3000
    )

    if ($Code.Length -gt $MaxLength) {
        $Code = $Code.Substring(0, $MaxLength) + "`n# … cut"
    }
    $longest = ([regex]::Matches($Code, '`+') | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    $fence = '`' * [Math]::Max(3, [int]$longest + 1)
    "$fence$Language`n$Code`n$fence"
}

function Get-Headline {
    param([object] $Verification, [string] $CommitSha, [string] $PushError)

    switch ($Verification.verdict) {
        'verified' {
            if ($CommitSha) { return "✅ Tests added or updated, verified and committed ($($CommitSha.Substring(0, 7)))" }
            if ($PushError) { return '⚠️ Tests verified, but the commit could not be pushed' }
            if ($Verification.patch.files) { return '✅ Tests added or updated and verified (not committed)' }
            return '✅ Verified: no test changes were needed, existing tests pass'
        }
        'tests_failed' { return '❌ Tests fail: nothing was committed' }
        'rejected' { return "🛑 The agent's output was rejected: nothing was committed" }
        default { return '⚠️ Unknown result' }
    }
}

function New-PrCommentBody {
    <#
    .SYNOPSIS
        Builds the Markdown body of the pull request comment.
    .PARAMETER Verification
        The content of verification.json (from Invoke-AgentVerification.ps1).
    .PARAMETER AgentResult
        The agent's result, or $null when it was missing or invalid.
    .PARAMETER RunInfo
        Facts about the run: repository, commit, run_url, model, turns, duration_s.
    .PARAMETER CommitSha
        The commit with the agent's tests, when one was pushed.
    .PARAMETER PushError
        Why the commit could not be pushed, if it could not.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Verification,

        [AllowNull()]
        [object] $AgentResult,

        [Parameter(Mandatory)]
        [hashtable] $RunInfo,

        [string] $CommitSha,

        [string] $PushError
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $add = { param($text) $lines.Add($text) }

    & $add $script:Marker
    & $add "## Terraform test agent"
    & $add ''
    & $add "**$(Get-Headline -Verification $Verification -CommitSha $CommitSha -PushError $PushError)**"
    & $add ''

    if ($AgentResult) {
        & $add "> 🤖 $(ConvertTo-SafeMarkdown $AgentResult.summary -MaxLength 600 -SingleLine)"
        & $add ''
    }

    # --- Problems found by the checks (our own text, still escaped) ------------
    $problems = @($Verification.agent_result.errors) + @($Verification.patch.errors) | Where-Object { $_ }
    if ($problems) {
        & $add '### Why the output was rejected'
        foreach ($problem in $problems) { & $add "- $(ConvertTo-SafeMarkdown $problem -MaxLength 300 -SingleLine)" }
        & $add ''
    }
    if ($PushError) {
        & $add "> ⚠️ $(ConvertTo-SafeMarkdown $PushError -MaxLength 300 -SingleLine)"
        & $add ''
    }

    # --- Modules ----------------------------------------------------------------
    & $add '### Modules'
    & $add '| Module | Agent decision | Tests (verified by the workflow) | Agent reported |'
    & $add '|---|---|---|---|'
    foreach ($test in $Verification.tests) {
        $entry = if ($AgentResult) { $AgentResult.modules | Where-Object { $_.module -eq $test.module } | Select-Object -First 1 }
        $decision = if ($entry) { "``$($entry.decision)``" } else { '—' }
        $claimed = if ($entry) { "$($script:StatusIcon[$entry.final_test_status]) $($entry.final_test_status)" } else { '—' }
        $verified = "$($script:StatusIcon[$test.status]) $($test.status): $($test.summary.passed) passed, $($test.summary.failed) failed"
        & $add "| ``$($test.module)`` | $decision | $verified | $claimed |"
    }
    & $add ''

    foreach ($warning in $Verification.claim_warnings) {
        & $add "> ⚠️ $(ConvertTo-SafeMarkdown $warning -MaxLength 300 -SingleLine)"
    }
    if ($Verification.claim_warnings) { & $add '' }

    foreach ($test in $Verification.tests) {
        $entry = if ($AgentResult) { $AgentResult.modules | Where-Object { $_.module -eq $test.module } | Select-Object -First 1 }
        & $add "<details><summary>Details: $($test.module)</summary>"
        & $add ''
        if ($entry) {
            & $add "**Why:** $(ConvertTo-SafeMarkdown $entry.reason -MaxLength 500 -SingleLine)"
            & $add ''
            if ($entry.covered_behaviours) {
                & $add '**What the tests check:**'
                foreach ($behaviour in $entry.covered_behaviours) { & $add "- $(ConvertTo-SafeMarkdown $behaviour -MaxLength 200 -SingleLine)" }
                & $add ''
            }
        }
        & $add '**Test runs (verify job):**'
        foreach ($run in $test.runs) { & $add "- $($script:StatusIcon[$(if ($run.status -eq 'pass') { 'passed' } else { 'failed' })]) ``$($run.file)`` :: ``$($run.run)``" }
        # Terraform output can contain text from the pull request (error messages).
        foreach ($message in $test.errors) { & $add "- ❌ $(ConvertTo-SafeMarkdown $message -MaxLength 400 -SingleLine)" }
        & $add ''
        & $add '</details>'
        & $add ''
    }

    # --- Findings -----------------------------------------------------------------
    $findings = if ($AgentResult) { @($AgentResult.findings | Sort-Object { $script:SeverityOrder[$_.severity] }) } else { @() }
    if ($findings) {
        & $add '### Findings for reviewers'
        & $add '_The agent reports these and does not change the infrastructure code. What to do about them is your decision._'
        & $add ''
        foreach ($group in @(
                @{ Title = 'Introduced by this pull request'; Items = @($findings | Where-Object { $_.introduced_by_change }) },
                @{ Title = 'Already in the code'; Items = @($findings | Where-Object { -not $_.introduced_by_change }) })) {
            if (-not $group.Items) { continue }
            & $add "#### $($group.Title)"
            foreach ($finding in $group.Items) {
                # file and line are checked by the schema (a path pattern and an integer).
                $link = "$($RunInfo.server_url)/$($RunInfo.repository)/blob/$($RunInfo.commit)/$($finding.file)#L$($finding.line)"
                & $add "- $($script:SeverityIcon[$finding.severity]) **$($finding.severity)** · $($finding.category) · [``$($finding.file):$($finding.line)``]($link): $(ConvertTo-SafeMarkdown $finding.title -MaxLength 120 -SingleLine)"
                & $add '  <details><summary>Details</summary>'
                & $add ''
                & $add "  $(ConvertTo-SafeMarkdown $finding.detail -MaxLength 800 -SingleLine)"
                & $add ''
                & $add "  **Recommendation:** $(ConvertTo-SafeMarkdown $finding.recommendation -MaxLength 500 -SingleLine)"
                if ($finding.suggested_test) {
                    & $add ''
                    & $add '  **A test that fails on the current code:**'
                    & $add ''
                    & $add (ConvertTo-CodeBlock -Code $finding.suggested_test -Language 'hcl')
                }
                & $add ''
                & $add '  </details>'
            }
            & $add ''
        }
    }

    # --- Limits -------------------------------------------------------------------
    if ($AgentResult -and $AgentResult.limitations) {
        & $add '### What these tests cannot show'
        foreach ($limitation in $AgentResult.limitations) { & $add "- $(ConvertTo-SafeMarkdown $limitation -MaxLength 300 -SingleLine)" }
        & $add ''
    }

    # --- Run ----------------------------------------------------------------------
    $stats = @()
    if ($RunInfo.model) { $stats += "model ``$($RunInfo.model)``" }
    if ($RunInfo.turns) { $stats += "$($RunInfo.turns) turns" }
    if ($RunInfo.duration_s) { $stats += "$($RunInfo.duration_s) s" }
    if ($null -ne $RunInfo.blocked) { $stats += "$($RunInfo.blocked) tool uses blocked by policy" }
    if ($RunInfo.run_url) { $stats += "[workflow run]($($RunInfo.run_url))" }
    & $add '---'
    & $add "<sub>Terraform test agent (Claude Code) · $($stats -join ' · ') · commit ``$("$($RunInfo.commit)".Substring(0, [Math]::Min(7, "$($RunInfo.commit)".Length)))``. The summary and findings are written by an AI; test results come from the workflow's own run.</sub>"

    $body = $lines -join "`n"
    if ($body.Length -gt $script:MaxBodyLength) {
        $body = $body.Substring(0, $script:MaxBodyLength) + "`n`n… The comment was cut; see the workflow run for everything."
    }
    $body
}

Export-ModuleMember -Function Get-PrCommentMarker, ConvertTo-SafeMarkdown, ConvertTo-CodeBlock, New-PrCommentBody
