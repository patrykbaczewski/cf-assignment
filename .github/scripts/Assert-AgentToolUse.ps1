<#
.SYNOPSIS
    PreToolUse hook of the test agent: allows or blocks each tool use.

.DESCRIPTION
    Claude Code runs this script before every tool use of an agent session started with
    --settings .github/agent/agent-settings.json. It reads the tool use as JSON from
    standard input and applies the rules in lib/AgentPolicy.psm1.

      exit 0  the tool use goes ahead
      exit 2  the tool use is blocked; the message on standard error goes back to the agent

    The script fails closed: if anything goes wrong, the tool use is blocked.
    That is also why it has no #Requires line: a failed #Requires ends a script with
    exit code 1, which Claude Code treats as a non-blocking error. The modules it
    imports require PowerShell 7.4 instead; that failure is caught below and blocks.

    Claude Code lets the tool use go ahead for any exit code other than 2, also when
    pwsh cannot start at all. The hook command in agent-settings.json therefore ends
    with "|| exit 2". A hook that times out (30 s) is let through by Claude Code; this
    script takes about a second.

    Optional environment variables, set by the workflow:
      TF_AGENT_MODULES    comma-separated modules of this task, for example modules/a,modules/b
      TF_AGENT_INPUT_DIR  a folder outside the repository the agent may read
#>
$ErrorActionPreference = 'Stop'

try {
    Import-Module "$PSScriptRoot/lib/RepoPaths.psm1"
    Import-Module "$PSScriptRoot/lib/AgentPolicy.psm1"

    $toolUse = [Console]::In.ReadToEnd() | ConvertFrom-Json

    $allowedModule = @()
    if (Test-Path -Path env:TF_AGENT_MODULES) {
        $allowedModule = @($env:TF_AGENT_MODULES -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [System.String]::IsNullOrWhiteSpace($_) })
    }

    $decision = Test-AgentToolUse -ToolName $toolUse.tool_name -ToolInput $toolUse.tool_input `
        -RepoRoot (Get-RepoRoot) -AllowedModule $allowedModule -InputDir $env:TF_AGENT_INPUT_DIR

    if ($decision.Allowed) {
        exit 0
    }
    [Console]::Error.WriteLine("Blocked by the agent policy: $($decision.Reason)")
    exit 2
}
catch {
    [Console]::Error.WriteLine("Blocked: the agent policy check failed ($($_.Exception.Message)), so this tool use is denied.")
    exit 2
}
