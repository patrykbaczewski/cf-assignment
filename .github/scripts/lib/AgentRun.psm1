# Starting the test agent (Claude Code) and reading what happened in its session.

Import-Module (Join-Path $PSScriptRoot 'RepoPaths.psm1')

function New-AgentTaskPrompt {
    <#
    .SYNOPSIS
        Builds the task message for the agent from the template in .github/agent/task-prompt.md.
    .DESCRIPTION
        The template is part of the repository, so the exact words the agent receives
        are reviewed like code. Lists the files of each module, because the agent cannot
        list folders itself (its shell is limited to the test command).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $TemplatePath,

        [Parameter(Mandatory)]
        [string] $RepoRoot,

        [Parameter(Mandatory)]
        [string[]] $Module,

        # File with the diff of the pull request, or empty when there is none.
        [string] $DiffPath
    )

    $files = foreach ($path in $Module) {
        $moduleDir = Join-Path $RepoRoot $path
        Get-ChildItem -LiteralPath $moduleDir -Recurse -File -Force |
            Where-Object { $_.FullName -notmatch '[\\/]\.terraform[\\/]' } |
            ForEach-Object { '- ' + (Resolve-RepoRelativePath -Path $_.FullName -RepoRoot $RepoRoot) }
    }

    $change = if ($DiffPath) {
        "The diff of this pull request against its base branch, limited to these modules, is in:`n$DiffPath`nRead it before you analyze the modules."
    }
    else {
        'There is no diff: analyze each module as a whole and add the tests it is missing.'
    }

    (Get-Content -LiteralPath $TemplatePath -Raw).
    Replace('{{MODULES}}', ($Module -join ', ')).
    Replace('{{FILES}}', ($files -join "`n")).
    Replace('{{CHANGE}}', $change)
}

function Read-AgentTranscript {
    <#
    .SYNOPSIS
        Reads the session transcript (stream-json) and returns the result and statistics.
    .OUTPUTS
        An object with Result (the structured output, or $null) and Stats (model, turns,
        duration_s, outcome, blocked: tool uses refused by permissions or by the hook).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $events = @()
    if (Test-Path -LiteralPath $Path) {
        $events = @(Get-Content -LiteralPath $Path | ForEach-Object {
                try { $_ | ConvertFrom-Json } catch { }
            })
    }

    $init = $events | Where-Object { $_.type -eq 'system' -and $_.subtype -eq 'init' } | Select-Object -First 1
    $final = $events | Where-Object { $_.type -eq 'result' } | Select-Object -Last 1

    # Refusals by the hook come back to the agent as tool results with our message;
    # Claude Code also lists refusals in the result. One tool use can be in both lists.
    $blockedIds = [System.Collections.Generic.HashSet[string]]::new()
    $events | Where-Object { $_.type -eq 'user' } | ForEach-Object { $_.message.content } |
        Where-Object { $_.type -eq 'tool_result' -and "$($_.content)" -match 'Blocked by the agent policy' } |
        ForEach-Object { [void] $blockedIds.Add($_.tool_use_id) }
    if ($final) { $final.permission_denials | ForEach-Object { [void] $blockedIds.Add($_.tool_use_id) } }

    [pscustomobject]@{
        Result = if ($final) { $final.structured_output } else { $null }
        Stats  = [ordered]@{
            model      = if ($init) { $init.model } else { $null }
            turns      = if ($final) { $final.num_turns } else { $null }
            duration_s = if ($final) { [int]($final.duration_ms / 1000) } else { $null }
            outcome    = if ($final) { $final.subtype } else { 'no_result' }
            blocked    = $blockedIds.Count
        }
    }
}

function Invoke-TestAgentSession {
    <#
    .SYNOPSIS
        Runs one headless Claude Code session as the terraform-test-engineer agent.
    .DESCRIPTION
        The session uses the agent's locked-down settings (permissions and the hook in
        .github/agent/agent-settings.json), no MCP servers, and must return JSON that
        matches the result schema. The hook reads TF_AGENT_MODULES and
        TF_AGENT_INPUT_DIR, which are set here for the session only.
    .OUTPUTS
        The exit code of claude.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot,

        [Parameter(Mandatory)]
        [string] $Prompt,

        [Parameter(Mandatory)]
        [string] $Model,

        [Parameter(Mandatory)]
        [string[]] $Module,

        [Parameter(Mandatory)]
        [string] $InputDir,

        [Parameter(Mandatory)]
        [string] $TranscriptPath
    )

    # One line, so it passes safely as a single argument.
    $schema = Get-Content -LiteralPath (Join-Path $RepoRoot '.github/agent/agent-result.schema.json') -Raw |
        ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress

    $arguments = @(
        '--print'
        '--agent', 'terraform-test-engineer'
        '--model', $Model
        '--settings', (Join-Path $RepoRoot '.github/agent/agent-settings.json')
        '--strict-mcp-config'                 # no MCP servers, whatever a file may say
        '--permission-mode', 'acceptEdits'    # edits are allowed; the hook decides where
        '--add-dir', $InputDir                # the diff lives outside the repository
        '--json-schema', $schema
        '--output-format', 'stream-json'
        '--verbose'
    )

    $env:TF_AGENT_MODULES = $Module -join ','
    $env:TF_AGENT_INPUT_DIR = $InputDir
    Push-Location $RepoRoot
    try {
        # The prompt goes through standard input, which also ends the input for claude.
        $Prompt | & claude @arguments > $TranscriptPath
        $LASTEXITCODE
    }
    finally {
        Pop-Location
        Remove-Item Env:TF_AGENT_MODULES, Env:TF_AGENT_INPUT_DIR -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function New-AgentTaskPrompt, Read-AgentTranscript, Invoke-TestAgentSession
