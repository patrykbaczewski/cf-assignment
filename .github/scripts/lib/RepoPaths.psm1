# Knowledge about the layout of this repository: where things live and which
# paths are allowed. Path rules are defined here once, so every script and hook
# that checks a path applies the same rule.

function Get-RepoRoot {
    <#
    .SYNOPSIS
        Returns the absolute path of the repository root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # This file lives in .github/scripts/lib.
    (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
}

function ConvertTo-ModulePath {
    <#
    .SYNOPSIS
        Normalizes a module path and checks that it points at modules/<name>.
    .EXAMPLE
        ConvertTo-ModulePath -Path './modules/key-vault/'   # returns modules/key-vault
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    # Accept "./modules/x/" or "modules\x", but nothing outside modules/<name>.
    $normalized = ($Path -replace '\\', '/').Trim().TrimEnd('/') -replace '^\./', ''
    if ($normalized -notmatch '^modules/[a-z0-9-]+$') {
        throw "A module path must look like modules/<name>, got '$Path'."
    }
    $normalized
}

function Get-ModulePathFromFile {
    <#
    .SYNOPSIS
        Returns modules/<name> for a file inside a module, or $null for any other file.
    .EXAMPLE
        Get-ModulePathFromFile -FilePath 'modules/network/tests/main.tftest.hcl'   # returns modules/network
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $FilePath
    )

    if ($FilePath -match '^modules/([a-z0-9-]+)/') {
        "modules/$($Matches[1])"
    }
    else {
        $null
    }
}

function Assert-NoSymbolicLink {
    <#
    .SYNOPSIS
        Fails when a folder contains a symbolic link.
    .DESCRIPTION
        A link could point at a file outside the folder (for example a credentials
        file), and copying the folder would copy that file's content.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $links = Get-ChildItem -LiteralPath $Path -Recurse -Force | Where-Object { $_.LinkType }
    if ($links) {
        throw "'$Path' contains symbolic links, which are not allowed: $($links.FullName -join ', ')"
    }
}

function Resolve-RepoRelativePath {
    <#
    .SYNOPSIS
        Returns a path relative to the repository root (with / separators), or $null
        when the path is outside the repository.
    .DESCRIPTION
        The path is made absolute and normalized first, so "modules/x/../../../etc"
        is recognized as outside the repository.
    .EXAMPLE
        Resolve-RepoRelativePath -Path '/repo/modules/x/tests/a.tftest.hcl' -RepoRoot '/repo'   # modules/x/tests/a.tftest.hcl
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $RepoRoot
    )

    $root = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('/', '\') + '/'
    $full = if ([System.IO.Path]::IsPathRooted($Path)) {
        [System.IO.Path]::GetFullPath($Path)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $root $Path))
    }

    if (-not $full.StartsWith($root, [System.StringComparison]::Ordinal)) {
        return $null
    }
    $full.Substring($root.Length) -replace '\\', '/'
}

function Test-AgentWritablePath {
    <#
    .SYNOPSIS
        Tells whether the test agent may write a file: only modules/<name>/tests/<file>.tftest.hcl.
    .DESCRIPTION
        This is the one definition of where the agent may write. The tool hook and the
        verify job both use it, so they cannot disagree.
    .EXAMPLE
        Test-AgentWritablePath -RelativePath 'modules/network/tests/main.tftest.hcl'   # True
        Test-AgentWritablePath -RelativePath 'modules/network/main.tf'                 # False
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $RelativePath,

        # When given, only these modules (modules/<name>) may be written.
        [string[]] $AllowedModule
    )

    if ($RelativePath -cnotmatch '^(modules/[a-z0-9-]+)/tests/[a-z0-9_-]+\.tftest\.hcl\z') {
        return $false
    }
    if ($AllowedModule -and $Matches[1] -notin $AllowedModule) {
        return $false
    }
    $true
}

Export-ModuleMember -Function Get-RepoRoot, ConvertTo-ModulePath, Get-ModulePathFromFile, Assert-NoSymbolicLink, Resolve-RepoRelativePath, Test-AgentWritablePath
