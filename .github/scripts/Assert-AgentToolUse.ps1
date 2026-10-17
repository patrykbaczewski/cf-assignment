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
    if (-not [System.String]::IsNullOrWhiteSpace($env:TF_AGENT_MODULES)) {
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
