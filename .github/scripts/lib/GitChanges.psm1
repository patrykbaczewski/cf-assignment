# Finds what a pull request changed and sorts the changed files into groups the
# workflow acts on. No LLM is involved: the same diff always gives the same answer.

Import-Module (Join-Path $PSScriptRoot 'RepoPaths.psm1')

function Assert-GitRef {
    # A ref that starts with "-" would be read by git as an option.
    param([string] $Ref)

    if ($Ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') {
        throw "'$Ref' is not an allowed git ref."
    }
}

function Get-ChangedFile {
    <#
    .SYNOPSIS
        Lists the files a branch changed since it left the base branch.
    .DESCRIPTION
        Uses `git diff base...head` (three dots): only the changes made on the head
        side since the common ancestor, not the changes made on the base meanwhile.
        Renames are listed as a deletion plus an addition, so both folders show up.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot,

        [Parameter(Mandatory)]
        [string] $BaseRef,

        [string] $HeadRef = 'HEAD'
    )

    Assert-GitRef $BaseRef
    Assert-GitRef $HeadRef

    $files = & git -C $RepoRoot diff --name-only --no-renames "$BaseRef...$HeadRef"
    if ($LASTEXITCODE -ne 0) {
        throw "git diff $BaseRef...$HeadRef failed. Is the base branch fetched (fetch-depth: 0)?"
    }
    @($files | Where-Object { $_ })
}

function Get-ModuleAtRef {
    <#
    .SYNOPSIS
        Lists the module folders (modules/<name>) that exist in a given commit.
    .DESCRIPTION
        Asks git, not the disk, so the answer matches the commit being compared
        even when a different commit is checked out.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot,

        [string] $Ref = 'HEAD'
    )

    Assert-GitRef $Ref

    $entries = & git -C $RepoRoot ls-tree -d --name-only $Ref 'modules/'
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-tree $Ref failed."
    }
    @($entries | Where-Object { $_ })
}

function Group-ChangedFile {
    <#
    .SYNOPSIS
        Sorts changed files into: modules to analyze, removed modules, and Terraform
        changes outside the agent's scope. Other files are ignored.
    .DESCRIPTION
        Works only on the lists it is given (no git, no disk), so it is easy to test.
    .EXAMPLE
        Group-ChangedFile -Path 'modules/network/main.tf', 'modules/old/main.tf', 'stacks/data-platform/main.tf', 'README.md' -ExistingModule 'modules/network'
        # modules = modules/network; removed = modules/old; out_of_scope = stacks/data-platform/main.tf
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Path,

        # Module folders that exist in the compared commit (see Get-ModuleAtRef).
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $ExistingModule
    )

    $modules = [System.Collections.Generic.SortedSet[string]]::new()
    $removed = [System.Collections.Generic.SortedSet[string]]::new()
    $outOfScope = [System.Collections.Generic.SortedSet[string]]::new()

    foreach ($file in $Path) {
        $module = Get-ModulePathFromFile -FilePath $file
        if ($module) {
            # The folder is gone when the pull request deleted the whole module.
            if ($module -in $ExistingModule) {
                [void] $modules.Add($module)
            }
            else {
                [void] $removed.Add($module)
            }
        }
        elseif ($file -like 'modules/*' -or $file -like 'stacks/*') {
            # Terraform code the agent does not handle (yet), for example the stack.
            [void] $outOfScope.Add($file)
        }
    }

    [ordered]@{
        modules      = @($modules)
        removed      = @($removed)
        out_of_scope = @($outOfScope)
    }
}

function Export-ModuleDiff {
    <#
    .SYNOPSIS
        Writes the diff of the given modules (base...head) to a file, as input for the agent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot,

        [Parameter(Mandatory)]
        [string] $BaseRef,

        [string] $HeadRef = 'HEAD',

        [Parameter(Mandatory)]
        [string[]] $Module,

        [Parameter(Mandatory)]
        [string] $Path
    )

    Assert-GitRef $BaseRef
    Assert-GitRef $HeadRef
    $paths = $Module | ForEach-Object { ConvertTo-ModulePath -Path $_ }

    $diff = & git -C $RepoRoot diff --no-color "$BaseRef...$HeadRef" -- $paths
    if ($LASTEXITCODE -ne 0) { throw "git diff $BaseRef...$HeadRef failed." }
    $text = if ($diff) { ($diff -join "`n") + "`n" } else { '' }
    [System.IO.File]::WriteAllText($Path, $text)
}

Export-ModuleMember -Function Get-ChangedFile, Get-ModuleAtRef, Group-ChangedFile, Export-ModuleDiff
