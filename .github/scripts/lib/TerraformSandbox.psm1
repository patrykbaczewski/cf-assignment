# Runs Terraform inside a locked-down Docker container.
#
# Module code from a pull request is untrusted: a module can run local programs
# while it is tested (for example a `data "external"` source). Terraform therefore
# never runs on the host and never sees the real checkout, only a throw-away copy.

# Pinned by digest, so the image cannot change under us.
$script:TerraformImage = 'hashicorp/terraform:1.16.4@sha256:985cdc6c1d9b0a65b83377f666efd2f740b47f02ac55be1ced3d18f7d3b0e829'

# Every sandbox copy gets this name prefix, so cleanup can never delete anything else.
$script:WorkDirPrefix = 'tf-test-'

function New-SandboxCopy {
    <#
    .SYNOPSIS
        Copies a module to a new temporary folder and returns that folder's path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourcePath
    )

    $tempRoot = if (-not [System.String]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
        $env:RUNNER_TEMP
    }
    else {
        [System.IO.Path]::GetTempPath()
    }
    $workDir = Join-Path $tempRoot "$script:WorkDirPrefix$([guid]::NewGuid().ToString('N'))"

    Copy-Item -LiteralPath $SourcePath -Destination $workDir -Recurse
    # Leftovers from a local `terraform init` must not leak into the run.
    Remove-Item -LiteralPath (Join-Path $workDir '.terraform') -Recurse -Force -ErrorAction SilentlyContinue

    $workDir
}

function Remove-SandboxCopy {
    <#
    .SYNOPSIS
        Deletes a folder created by New-SandboxCopy, and refuses any other folder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if ((Split-Path -Leaf $Path) -notlike "$script:WorkDirPrefix*") {
        throw "Refusing to delete '$Path': it is not a sandbox copy."
    }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function Invoke-TerraformInSandbox {
    <#
    .SYNOPSIS
        Runs one terraform command in a container on a sandbox copy.
    .DESCRIPTION
        The container gets no secrets, runs as the current non-root user, cannot
        change its own file system and has memory and process limits. It has no
        network unless -AllowNetwork is given, which is meant only for
        `terraform init` (downloads providers, runs no module code).
    .OUTPUTS
        An object with ExitCode and Output (all output lines as strings).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $WorkDir,

        [Parameter(Mandatory = $true)]
        [string[]] $TerraformArgs,

        [Parameter(Mandatory = $false)]
        [switch] $AllowNetwork
    )

    $userId = (& id -u).Trim()
    $groupId = (& id -g).Trim()

    $dockerArgs = @(
        'run', '--rm'
        '--user', "${userId}:${groupId}"     # not root
        '--env', 'HOME=/tmp'
        '--env', 'TF_IN_AUTOMATION=1'
        '--read-only'                        # the container cannot change its own file system
        '--tmpfs', '/tmp'                    # ...except a scratch /tmp in memory
        '--cap-drop', 'ALL'                  # no Linux capabilities
        '--security-opt', 'no-new-privileges'
        '--memory', '1g'
        '--pids-limit', '256'
        '--volume', "${WorkDir}:/work"
        '--workdir', '/work'
    )
    if (-not $AllowNetwork) {
        $dockerArgs += @('--network', 'none')
    }
    $dockerArgs += $script:TerraformImage
    $dockerArgs += $TerraformArgs

    $output = & docker @dockerArgs 2>&1 | ForEach-Object { "$_" }
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = @($output)
    }
}

Export-ModuleMember -Function New-SandboxCopy, Remove-SandboxCopy, Invoke-TerraformInSandbox
