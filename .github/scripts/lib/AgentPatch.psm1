# The patch with the agent's changes: how it is made in the agent job, and how the
# verify job checks it before anything is committed. The patch is rejected as a whole
# when any rule is broken: an agent that broke a rule is not trusted with the rest.

Import-Module "$PSScriptRoot/RepoPaths.psm1"

$script:MaxPatchBytes = 200KB

# Patterns of credentials that must never appear in a committed test (the idea comes
# from the threat detection step of GitHub Agentic Workflows).
$script:SecretPatterns = [ordered]@{
    'Anthropic key'  = 'sk-ant-[A-Za-z0-9_-]{20,}'
    'GitHub token'   = '\b(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})'
    'AWS access key' = '\bAKIA[0-9A-Z]{16}\b'
    'Private key'    = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'Slack token'    = '\bxox[abprs]-[A-Za-z0-9-]{10,}'
}

function New-PatchCheck {
    # The result of Test-AgentPatch.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [bool] $IsValid,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Errors,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Files
    )

    [pscustomobject]@{
        IsValid = $IsValid
        Errors  = $Errors
        Files   = $Files
    }
}

function Save-WorkspaceBaseline {
    <#
    .SYNOPSIS
        Records the current state of the working tree, before the agent starts.
    .DESCRIPTION
        Returns a git tree ID: a snapshot of every file, without a commit. Changes the
        workflow made itself (for example restoring the agent configuration from the
        base branch) are part of the snapshot, so they never count as agent changes.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepoRoot
    )

    & git -C $RepoRoot add --all
    $tree = & git -C $RepoRoot write-tree
    if ($LASTEXITCODE -ne 0) {
        throw 'git write-tree failed.'
    }
    $tree.Trim()
}

function Export-AgentPatch {
    <#
    .SYNOPSIS
        Writes every change made since the baseline into a patch file.
    .DESCRIPTION
        All changes are exported, also those the agent was not allowed to make, so the
        verify job can see and report them. Renames are written as delete plus add.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepoRoot,

        [Parameter(Mandatory = $true)]
        [string] $Baseline,

        [Parameter(Mandatory = $true)]
        [string] $PatchPath
    )

    if ($Baseline -notmatch '^[0-9a-f]{40,64}$') {
        throw "'$Baseline' is not a git tree ID."
    }

    & git -C $RepoRoot add --all
    $patch = & git -C $RepoRoot diff --cached --binary --no-renames --no-color $Baseline
    if ($LASTEXITCODE -ne 0) {
        throw 'git diff failed.'
    }

    # Join with new lines ourselves: the output arrives as separate lines.
    $text = if ($patch) {
        [System.String]::Join("`n", @($patch)) + "`n"
    }
    else {
        ''
    }
    [System.IO.File]::WriteAllText($PatchPath, $text)
}

function Get-PatchChange {
    <#
    .SYNOPSIS
        Lists the files in a patch, what happens to each, and every added line.
    .OUTPUTS
        An object with Files (Path, Header, Kind, Mode, Binary) and AddedLines.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $PatchText
    )

    $files = [System.Collections.Generic.List[object]]::new()
    $added = [System.Collections.Generic.List[string]]::new()
    $current = $null

    foreach ($line in $PatchText -split "`n") {
        if ($line.StartsWith('diff --git ')) {
            # A path with spaces or special characters is quoted by git and does not
            # match; it is recorded as unreadable and rejected later.
            $path = $null
            if ($line -cmatch '^diff --git a/(\S+) b/(\S+)$') {
                $path = $Matches[2]
            }
            $current = [pscustomobject]@{
                Path   = $path
                Header = $line
                Kind   = 'modified'
                Mode   = '100644'
                Binary = $false
            }
            $files.Add($current)
            continue
        }
        if (-not $current) {
            continue
        }

        if ($line -match '^new file mode (\d+)') {
            $current.Kind = 'added'
            $current.Mode = $Matches[1]
        }
        elseif ($line -match '^deleted file mode (\d+)') {
            $current.Kind = 'deleted'
            $current.Mode = $Matches[1]
        }
        elseif ($line -match '^new mode (\d+)') {
            $current.Kind = 'mode-changed'
            $current.Mode = $Matches[1]
        }
        elseif ($line -match '^(GIT binary patch|Binary files )') {
            $current.Binary = $true
        }
        elseif ($line.StartsWith('+') -and -not $line.StartsWith('+++ ')) {
            $added.Add($line.Substring(1))
        }
    }

    [pscustomobject]@{
        Files      = $files.ToArray()
        AddedLines = $added.ToArray()
    }
}

function Test-AgentPatch {
    <#
    .SYNOPSIS
        Checks the agent's patch before it may be applied and committed.
    .DESCRIPTION
        The patch is rejected when it:
          - is larger than 200 KB,
          - touches a file the agent may not write (see Test-AgentWritablePath),
          - deletes a file, changes a file mode, adds a link or a binary file,
          - contains something that looks like a credential,
          - does not apply cleanly to the checked-out code.
        An empty patch (the agent changed nothing) is valid.
    .OUTPUTS
        An object with IsValid, Errors and Files (the paths in the patch).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $PatchPath,

        [Parameter(Mandatory = $true)]
        [string] $RepoRoot,

        # The modules of this run; the patch may only touch their tests.
        [Parameter(Mandatory = $false)]
        [string[]] $AllowedModule
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path -LiteralPath $PatchPath -PathType Leaf)) {
        return New-PatchCheck -IsValid $false -Errors @("Patch file '$PatchPath' does not exist.") -Files @()
    }

    $size = (Get-Item -LiteralPath $PatchPath).Length
    if ($size -eq 0) {
        return New-PatchCheck -IsValid $true -Errors @() -Files @()
    }
    if ($size -gt $script:MaxPatchBytes) {
        return New-PatchCheck -IsValid $false -Errors @("The patch is $size bytes; the limit is $script:MaxPatchBytes.") -Files @()
    }

    $changes = Get-PatchChange -PatchText (Get-Content -LiteralPath $PatchPath -Raw)

    foreach ($file in $changes.Files) {
        if ([System.String]::IsNullOrWhiteSpace($file.Path)) {
            $errors.Add("Unreadable file header: $($file.Header)")
            continue
        }
        if (-not (Test-AgentWritablePath -RelativePath $file.Path -AllowedModule $AllowedModule)) {
            $errors.Add("'$($file.Path)' is not a test file of a module in this run.")
        }
        if ($file.Kind -in 'deleted', 'mode-changed') {
            $errors.Add("'$($file.Path)' is $($file.Kind); the agent may only add or change test files.")
        }
        if ($file.Mode -ne '100644') {
            $errors.Add("'$($file.Path)' has file mode $($file.Mode); only regular files are allowed.")
        }
        if ($file.Binary) {
            $errors.Add("'$($file.Path)' is a binary file.")
        }
    }

    foreach ($name in $script:SecretPatterns.Keys) {
        if ($changes.AddedLines | Where-Object { $_ -cmatch $script:SecretPatterns[$name] }) {
            $errors.Add("An added line looks like a credential ($name).")
        }
    }

    $check = & git -C $RepoRoot apply --check $PatchPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        $errors.Add("The patch does not apply cleanly: $([System.String]::Join(' ', @($check)))")
    }

    $paths = @($changes.Files | Where-Object { -not [System.String]::IsNullOrWhiteSpace($_.Path) } | ForEach-Object { $_.Path })
    New-PatchCheck -IsValid ($errors.Count -eq 0) -Errors $errors.ToArray() -Files $paths
}

Export-ModuleMember -Function Save-WorkspaceBaseline, Export-AgentPatch, Get-PatchChange, Test-AgentPatch
