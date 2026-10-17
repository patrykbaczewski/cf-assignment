# What the test agent may do with its tools. The agent's instructions ask it to stay
# within these limits; this module enforces them, because an LLM can be wrong or be
# steered by text in the code it reads.

Import-Module "$PSScriptRoot/RepoPaths.psm1"

# The only shell command the agent may run. \z (end of text) instead of $ so that a
# trailing new line cannot carry a second command.
$script:TestCommandPattern = '^pwsh -File \.github/scripts/Invoke-TerraformTest\.ps1 -ModulePath (modules/[a-z0-9-]+)\z'

function New-PolicyDecision {
    # One decision of the policy: allowed or not, and why.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool] $Allowed,

        [Parameter(Mandatory = $true)]
        [string] $Reason
    )

    [pscustomobject]@{
        Allowed = $Allowed
        Reason  = $Reason
    }
}

function Test-SymbolicLinkOnPath {
    # True when the file or any folder between the repository root and it is a link.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RelativePath,

        [Parameter(Mandatory = $true)]
        [string] $RepoRoot
    )

    $current = $RepoRoot
    foreach ($part in $RelativePath -split '/') {
        $current = Join-Path $current $part
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item -and -not [System.String]::IsNullOrWhiteSpace($item.LinkType)) {
            return $true
        }
    }
    $false
}

function Test-AgentToolUse {
    <#
    .SYNOPSIS
        Decides whether the agent may use a tool with the given input.
    .DESCRIPTION
        Bash        only the sandboxed test command, for one module
        Write/Edit  only modules/<name>/tests/*.tftest.hcl, no symbolic links on the way
        Read        only inside the repository (not .git) or the input folder
        other tools allowed here; the permission settings decide about them
    .OUTPUTS
        An object with Allowed and Reason.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ToolName,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object] $ToolInput,

        [Parameter(Mandatory = $true)]
        [string] $RepoRoot,

        # When given, the agent may only test and write these modules (modules/<name>).
        [Parameter(Mandatory = $false)]
        [string[]] $AllowedModule,

        # A folder outside the repository the agent may read, for example the diff.
        [Parameter(Mandatory = $false)]
        [string] $InputDir
    )

    switch ($ToolName) {
        'Bash' {
            $command = "$($ToolInput.command)".Trim()
            if ($command -cnotmatch $script:TestCommandPattern) {
                return New-PolicyDecision -Allowed $false -Reason 'The only allowed command is: pwsh -File .github/scripts/Invoke-TerraformTest.ps1 -ModulePath modules/<name>'
            }
            if ($AllowedModule -and $Matches[1] -notin $AllowedModule) {
                return New-PolicyDecision -Allowed $false -Reason "Module '$($Matches[1])' is not part of this task."
            }
            return New-PolicyDecision -Allowed $true -Reason 'Sandboxed test command.'
        }

        { $_ -in 'Write', 'Edit' } {
            $relative = Resolve-RepoRelativePath -Path "$($ToolInput.file_path)" -RepoRoot $RepoRoot
            if ([System.String]::IsNullOrWhiteSpace($relative) -or -not (Test-AgentWritablePath -RelativePath $relative -AllowedModule $AllowedModule)) {
                return New-PolicyDecision -Allowed $false -Reason 'Writes are allowed only to modules/<name>/tests/*.tftest.hcl of the modules in this task.'
            }
            if (Test-SymbolicLinkOnPath -RelativePath $relative -RepoRoot $RepoRoot) {
                return New-PolicyDecision -Allowed $false -Reason "'$relative' goes through a symbolic link."
            }
            return New-PolicyDecision -Allowed $true -Reason 'Test file.'
        }

        'Read' {
            $path = "$($ToolInput.file_path)"
            $relative = Resolve-RepoRelativePath -Path $path -RepoRoot $RepoRoot
            if (-not [System.String]::IsNullOrWhiteSpace($relative) -and $relative -ne '.git' -and -not $relative.StartsWith('.git/')) {
                return New-PolicyDecision -Allowed $true -Reason 'Inside the repository.'
            }
            if (-not [System.String]::IsNullOrWhiteSpace($InputDir) -and -not [System.String]::IsNullOrWhiteSpace((Resolve-RepoRelativePath -Path $path -RepoRoot $InputDir))) {
                return New-PolicyDecision -Allowed $true -Reason 'Inside the input folder.'
            }
            return New-PolicyDecision -Allowed $false -Reason 'Reads are allowed only inside the repository (not .git) and the input folder.'
        }

        default {
            return New-PolicyDecision -Allowed $true -Reason 'Not restricted by this policy.'
        }
    }
}

Export-ModuleMember -Function Test-AgentToolUse
