<#
.SYNOPSIS
    Prints, as JSON, which Terraform modules a branch changed compared with its base.

.DESCRIPTION
    Used by the detect job: when no module changed, the agent does not run at all.
    Output fields:
      modules       modules to analyze (folders that still exist)
      removed       modules the branch deleted
      out_of_scope  other changed Terraform files, for example in stacks/

.PARAMETER BaseRef
    The base branch or commit, for example origin/main.

.PARAMETER HeadRef
    The branch or commit to compare. Defaults to HEAD.

.PARAMETER Compress
    Print the JSON on one line (for $GITHUB_OUTPUT).

.EXAMPLE
    pwsh -File .github/scripts/Get-ChangedModules.ps1 -BaseRef origin/main
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $BaseRef,

    [Parameter(Mandatory = $false)]
    [string] $HeadRef = 'HEAD',

    [Parameter(Mandatory = $false)]
    [switch] $Compress
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/lib/RepoPaths.psm1"
Import-Module "$PSScriptRoot/lib/GitChanges.psm1"

$repoRoot = Get-RepoRoot
# @(...) keeps an empty result an empty list; without it PowerShell turns it into $null.
$files = @(Get-ChangedFile -RepoRoot $repoRoot -BaseRef $BaseRef -HeadRef $HeadRef)
$existing = @(Get-ModuleAtRef -RepoRoot $repoRoot -Ref $HeadRef)

Group-ChangedFile -Path $files -ExistingModule $existing | ConvertTo-Json -Depth 3 -Compress:$Compress
