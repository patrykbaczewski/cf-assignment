#Requires -Version 7.4

# Finds what a pull request changed and sorts the changed files into groups the
# workflow acts on. No LLM is involved: the same diff always gives the same answer.

Import-Module "$PSScriptRoot/RepoPaths.psm1"

function Assert-GitRef {
    <#
    .SYNOPSIS
        Fails unless the value is a plain git ref (branch, tag, SHA or origin/<branch>).
    .DESCRIPTION
        A ref that starts with "-" would be read by git as an option, so only letters,
        digits and . _ / - are allowed, and the first character must be a letter or digit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Ref
    )

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
        [Parameter(Mandatory = $true)]
        [string] $RepoRoot,

        [Parameter(Mandatory = $true)]
        [string] $BaseRef,

        [Parameter(Mandatory = $false)]
        [string] $HeadRef = 'HEAD'
    )

    Assert-GitRef -Ref $BaseRef
    Assert-GitRef -Ref $HeadRef

    $files = & git -C $RepoRoot diff --name-only --no-renames "$BaseRef...$HeadRef"
    if ($LASTEXITCODE -ne 0) {
        throw "git diff $BaseRef...$HeadRef failed. Is the base branch fetched (fetch-depth: 0)?"
    }
    return [string[]] @($files | Where-Object { -not [System.String]::IsNullOrWhiteSpace($_) })
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
        [Parameter(Mandatory = $true)]
        [string] $RepoRoot,

        [Parameter(Mandatory = $false)]
        [string] $Ref = 'HEAD'
    )

    Assert-GitRef -Ref $Ref

    $entries = & git -C $RepoRoot ls-tree -d --name-only $Ref 'modules/'
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-tree $Ref failed."
    }
    return [string[]] @($entries | Where-Object { -not [System.String]::IsNullOrWhiteSpace($_) })
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
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Path,

        # Module folders that exist in the compared commit (see Get-ModuleAtRef).
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $ExistingModule
    )

    $modules = [System.Collections.Generic.SortedSet[string]]::new()
    $removed = [System.Collections.Generic.SortedSet[string]]::new()
    $outOfScope = [System.Collections.Generic.SortedSet[string]]::new()

    foreach ($file in $Path) {
        if ([System.String]::IsNullOrWhiteSpace($file)) {
            continue
        }
        $module = Get-ModulePathFromFile -FilePath $file
        if (-not [System.String]::IsNullOrWhiteSpace($module)) {
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

    return [ordered]@{
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
        [Parameter(Mandatory = $true)]
        [string] $RepoRoot,

        [Parameter(Mandatory = $true)]
        [string] $BaseRef,

        [Parameter(Mandatory = $false)]
        [string] $HeadRef = 'HEAD',

        [Parameter(Mandatory = $true)]
        [string[]] $Module,

        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    Assert-GitRef -Ref $BaseRef
    Assert-GitRef -Ref $HeadRef
    $paths = $Module | ForEach-Object { ConvertTo-ModulePath -Path $_ }

    $diff = & git -C $RepoRoot diff --no-color "$BaseRef...$HeadRef" -- $paths
    if ($LASTEXITCODE -ne 0) {
        throw "git diff $BaseRef...$HeadRef failed."
    }
    $text = if ($diff) {
        [System.String]::Join("`n", @($diff)) + "`n"
    }
    else {
        ''
    }
    [System.IO.File]::WriteAllText($Path, $text)
}

Export-ModuleMember -Function Get-ChangedFile, Get-ModuleAtRef, Group-ChangedFile, Export-ModuleDiff
