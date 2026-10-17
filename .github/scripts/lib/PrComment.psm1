# Builds the pull request comment from the verification and the agent's result.
# Text written by the agent (an LLM) is untrusted: it is escaped before it is shown,
# so it cannot add HTML, links that look like ours, or mentions that notify people.

# Finds our comment again on the next run, so there is one comment that gets updated.
$script:Marker = '<!-- tf-test-agent -->'

# GitHub rejects comments longer than 65536 characters.
$script:MaxBodyLength = 60000

$script:SeverityOrder = @{
    high   = 0
    medium = 1
    low    = 2
    info   = 3
}
$script:SeverityIcon = @{
    high   = '🔴'
    medium = '🟠'
    low    = '🟡'
    info   = '🔵'
}
$script:StatusIcon = @{
    passed   = '✅'
    failed   = '❌'
    error    = '❌'
    no_tests = '⚪'
    not_run  = '⚪'
}

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
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text,

        [Parameter(Mandatory = $false)]
        [int] $MaxLength = 1000,

        [Parameter(Mandatory = $false)]
        [switch] $SingleLine
    )

    if ([System.String]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

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
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Code,

        [Parameter(Mandatory = $false)]
        [string] $Language = '',

        [Parameter(Mandatory = $false)]
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
    # The first line of the comment: what happened, in a few words.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Verification,

        [Parameter(Mandatory = $false)]
        [string] $CommitSha,

        [Parameter(Mandatory = $false)]
        [string] $PushError
    )

    if ($Verification.verdict -eq 'verified') {
        if (-not [System.String]::IsNullOrWhiteSpace($CommitSha)) {
            return "✅ Tests added or updated, verified and committed ($($CommitSha.Substring(0, 7)))"
        }
        if (-not [System.String]::IsNullOrWhiteSpace($PushError)) {
            return '⚠️ Tests verified, but the commit could not be pushed'
        }
        if ($Verification.patch.files) {
            return '✅ Tests added or updated and verified (not committed)'
        }
        return '✅ Verified: no test changes were needed, existing tests pass'
    }
    if ($Verification.verdict -eq 'tests_failed') {
        return '❌ Tests fail: nothing was committed'
    }
    if ($Verification.verdict -eq 'rejected') {
        return "🛑 The agent's output was rejected: nothing was committed"
    }
    '⚠️ Unknown result'
}

function Get-ModuleEntry {
    # The agent's entry for one module, or $null.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object] $AgentResult,

        [Parameter(Mandatory = $true)]
        [string] $Module
    )

    if (-not $AgentResult) {
        return $null
    }
    $AgentResult.modules | Where-Object { $_.module -eq $Module } | Select-Object -First 1
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
        Facts about the run: server_url, repository, commit, run_url, model, turns,
        duration_s, blocked.
    .PARAMETER CommitSha
        The commit with the agent's tests, when one was pushed.
    .PARAMETER PushError
        Why the commit could not be pushed, if it could not.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Verification,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object] $AgentResult,

        [Parameter(Mandatory = $true)]
        [hashtable] $RunInfo,

        [Parameter(Mandatory = $false)]
        [string] $CommitSha,

        [Parameter(Mandatory = $false)]
        [string] $PushError
    )

    $lines = [System.Collections.Generic.List[string]]::new()

    $lines.Add($script:Marker)
    $lines.Add('## Terraform test agent')
    $lines.Add('')
    $lines.Add("**$(Get-Headline -Verification $Verification -CommitSha $CommitSha -PushError $PushError)**")
    $lines.Add('')

    if ($AgentResult) {
        $lines.Add("> 🤖 $(ConvertTo-SafeMarkdown -Text $AgentResult.summary -MaxLength 600 -SingleLine)")
        $lines.Add('')
    }

    # --- Problems found by the checks (our own text, still escaped) ------------
    $problems = @($Verification.agent_result.errors) + @($Verification.patch.errors) | Where-Object { -not [System.String]::IsNullOrWhiteSpace($_) }
    if ($problems) {
        $lines.Add('### Why the output was rejected')
        foreach ($problem in $problems) {
            $lines.Add("- $(ConvertTo-SafeMarkdown -Text $problem -MaxLength 300 -SingleLine)")
        }
        $lines.Add('')
    }
    if (-not [System.String]::IsNullOrWhiteSpace($PushError)) {
        $lines.Add("> ⚠️ $(ConvertTo-SafeMarkdown -Text $PushError -MaxLength 300 -SingleLine)")
        $lines.Add('')
    }

    # --- Modules ----------------------------------------------------------------
    $lines.Add('### Modules')
    $lines.Add('| Module | Agent decision | Tests (verified by the workflow) | Agent reported |')
    $lines.Add('|---|---|---|---|')
    foreach ($test in $Verification.tests) {
        $entry = Get-ModuleEntry -AgentResult $AgentResult -Module $test.module
        $decision = '—'
        $claimed = '—'
        if ($entry) {
            $decision = "``$($entry.decision)``"
            $claimed = "$($script:StatusIcon[$entry.final_test_status]) $($entry.final_test_status)"
        }
        $verified = "$($script:StatusIcon[$test.status]) $($test.status): $($test.summary.passed) passed, $($test.summary.failed) failed"
        $lines.Add("| ``$($test.module)`` | $decision | $verified | $claimed |")
    }
    $lines.Add('')

    foreach ($warning in $Verification.claim_warnings) {
        $lines.Add("> ⚠️ $(ConvertTo-SafeMarkdown -Text $warning -MaxLength 300 -SingleLine)")
    }
    if ($Verification.claim_warnings) {
        $lines.Add('')
    }

    foreach ($test in $Verification.tests) {
        $entry = Get-ModuleEntry -AgentResult $AgentResult -Module $test.module
        $lines.Add("<details><summary>Details: $($test.module)</summary>")
        $lines.Add('')
        if ($entry) {
            $lines.Add("**Why:** $(ConvertTo-SafeMarkdown -Text $entry.reason -MaxLength 500 -SingleLine)")
            $lines.Add('')
            if ($entry.covered_behaviours) {
                $lines.Add('**What the tests check:**')
                foreach ($behaviour in $entry.covered_behaviours) {
                    $lines.Add("- $(ConvertTo-SafeMarkdown -Text $behaviour -MaxLength 200 -SingleLine)")
                }
                $lines.Add('')
            }
        }
        $lines.Add('**Test runs (verify job):**')
        foreach ($run in $test.runs) {
            $icon = if ($run.status -eq 'pass') {
                $script:StatusIcon['passed']
            }
            else {
                $script:StatusIcon['failed']
            }
            $lines.Add("- $icon ``$($run.file)`` :: ``$($run.run)``")
        }
        # Terraform output can contain text from the pull request (error messages).
        foreach ($message in $test.errors) {
            $lines.Add("- ❌ $(ConvertTo-SafeMarkdown -Text $message -MaxLength 400 -SingleLine)")
        }
        $lines.Add('')
        $lines.Add('</details>')
        $lines.Add('')
    }

    # --- Findings -----------------------------------------------------------------
    $findings = @()
    if ($AgentResult) {
        $findings = @($AgentResult.findings | Sort-Object { $script:SeverityOrder[$_.severity] })
    }
    if ($findings) {
        $lines.Add('### Findings for reviewers')
        $lines.Add('_The agent reports these and does not change the infrastructure code. What to do about them is your decision._')
        $lines.Add('')
        $groups = @(
            @{
                Title = 'Introduced by this pull request'
                Items = @($findings | Where-Object { $_.introduced_by_change })
            }
            @{
                Title = 'Already in the code'
                Items = @($findings | Where-Object { -not $_.introduced_by_change })
            }
        )
        foreach ($group in $groups) {
            if (-not $group.Items) {
                continue
            }
            $lines.Add("#### $($group.Title)")
            foreach ($finding in $group.Items) {
                # file and line are checked by the schema (a path pattern and an integer).
                $link = "$($RunInfo.server_url)/$($RunInfo.repository)/blob/$($RunInfo.commit)/$($finding.file)#L$($finding.line)"
                $title = ConvertTo-SafeMarkdown -Text $finding.title -MaxLength 120 -SingleLine
                $lines.Add("- $($script:SeverityIcon[$finding.severity]) **$($finding.severity)** · $($finding.category) · [``$($finding.file):$($finding.line)``]($link): $title")
                $lines.Add('  <details><summary>Details</summary>')
                $lines.Add('')
                $lines.Add("  $(ConvertTo-SafeMarkdown -Text $finding.detail -MaxLength 800 -SingleLine)")
                $lines.Add('')
                $lines.Add("  **Recommendation:** $(ConvertTo-SafeMarkdown -Text $finding.recommendation -MaxLength 500 -SingleLine)")
                if (-not [System.String]::IsNullOrWhiteSpace($finding.suggested_test)) {
                    $lines.Add('')
                    $lines.Add('  **A test that fails on the current code:**')
                    $lines.Add('')
                    $lines.Add((ConvertTo-CodeBlock -Code $finding.suggested_test -Language 'hcl'))
                }
                $lines.Add('')
                $lines.Add('  </details>')
            }
            $lines.Add('')
        }
    }

    # --- Limits -------------------------------------------------------------------
    if ($AgentResult -and $AgentResult.limitations) {
        $lines.Add('### What these tests cannot show')
        foreach ($limitation in $AgentResult.limitations) {
            $lines.Add("- $(ConvertTo-SafeMarkdown -Text $limitation -MaxLength 300 -SingleLine)")
        }
        $lines.Add('')
    }

    # --- Run ----------------------------------------------------------------------
    $stats = @()
    if (-not [System.String]::IsNullOrWhiteSpace($RunInfo.model)) {
        $stats += "model ``$($RunInfo.model)``"
    }
    if ($RunInfo.turns) {
        $stats += "$($RunInfo.turns) turns"
    }
    if ($RunInfo.duration_s) {
        $stats += "$($RunInfo.duration_s) s"
    }
    if ($null -ne $RunInfo.blocked) {
        $stats += "$($RunInfo.blocked) tool uses blocked by policy"
    }
    if (-not [System.String]::IsNullOrWhiteSpace($RunInfo.run_url)) {
        $stats += "[workflow run]($($RunInfo.run_url))"
    }
    $commit = "$($RunInfo.commit)"
    $shortCommit = $commit.Substring(0, [Math]::Min(7, $commit.Length))
    $lines.Add('---')
    $lines.Add("<sub>Terraform test agent (Claude Code) · $([System.String]::Join(' · ', @($stats))) · commit ``$shortCommit``. The summary and findings are written by an AI; test results come from the workflow's own run.</sub>")

    $body = [System.String]::Join("`n", @($lines))
    if ($body.Length -gt $script:MaxBodyLength) {
        $body = $body.Substring(0, $script:MaxBodyLength) + "`n`n… The comment was cut; see the workflow run for everything."
    }
    $body
}

Export-ModuleMember -Function Get-PrCommentMarker, ConvertTo-SafeMarkdown, ConvertTo-CodeBlock, New-PrCommentBody
