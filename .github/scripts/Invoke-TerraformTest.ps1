<#
.SYNOPSIS
    Runs `terraform test` for one module inside a locked-down Docker container.

.DESCRIPTION
    This is the only way tests are run in this repository: by developers, by the
    test agent and by the CI verify job.

    Module code from a pull request is untrusted, so the tests run in two phases on
    a temporary copy of the module (see lib/TerraformSandbox.psm1):

      Phase 1  terraform init         network on   (downloads providers, runs no module code)
      Phase 2  terraform fmt + test   network off  (module code may run here)

    Exit code 0 means every test passed and the test files are formatted.

.PARAMETER ModulePath
    Module folder relative to the repository root, for example modules/key-vault.

.PARAMETER ResultPath
    Optional path of a JSON file that receives the result.

.EXAMPLE
    pwsh -File .github/scripts/Invoke-TerraformTest.ps1 -ModulePath modules/key-vault
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ModulePath,

    [Parameter(Mandatory = $false)]
    [string] $ResultPath
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/lib/RepoPaths.psm1"
Import-Module "$PSScriptRoot/lib/TerraformSandbox.psm1"
Import-Module "$PSScriptRoot/lib/TerraformTestReport.psm1"

# --- Validate the input -------------------------------------------------------

$ModulePath = ConvertTo-ModulePath -Path $ModulePath
$sourceDir = Join-Path (Get-RepoRoot) $ModulePath
if (-not (Test-Path -LiteralPath $sourceDir -PathType Container)) {
    throw "Module folder '$ModulePath' does not exist."
}
Assert-NoSymbolicLink -Path $sourceDir

$result = New-TestResult -ModulePath $ModulePath

if (-not (Test-Path -LiteralPath (Join-Path $sourceDir 'tests') -PathType Container)) {
    $result.status = 'no_tests'
    $result.errors = @("No tests folder in $ModulePath.")
    Write-TestResult -Result $result -Path $ResultPath
    exit 1
}

# --- Run the tests on a throw-away copy ---------------------------------------

$workDir = New-SandboxCopy -SourcePath $sourceDir
try {
    # Phase 1: init, with network.
    $init = Invoke-TerraformInSandbox -WorkDir $workDir -AllowNetwork -TerraformArgs @('init', '-backend=false', '-input=false', '-no-color')
    if ($init.ExitCode -ne 0) {
        $result.errors = @("terraform init failed:`n" + [System.String]::Join("`n", @($init.Output | Select-Object -Last 20)))
        Write-TestResult -Result $result -Path $ResultPath
        exit 1
    }

    # Phase 2: fmt and test, without network.
    # Only the tests are format-checked: they are what the agent writes.
    $fmt = Invoke-TerraformInSandbox -WorkDir $workDir -TerraformArgs @('fmt', '-check', '-recursive', '-no-color', 'tests')
    $result.formatting_ok = ($fmt.ExitCode -eq 0)
    $result.unformatted_files = @($fmt.Output | Where-Object { -not [System.String]::IsNullOrWhiteSpace($_) })

    $test = Invoke-TerraformInSandbox -WorkDir $workDir -TerraformArgs @('test', '-json', '-no-color')
    $parsed = ConvertFrom-TerraformTestJson -Line $test.Output

    $result.runs = $parsed.Runs
    $result.errors = $parsed.Errors
    $result.summary = $parsed.Summary
    $result.status = Get-TestStatus -RunCount $parsed.Runs.Count -ErrorCount $parsed.Errors.Count `
        -TestExitCode $test.ExitCode -FormattingOk $result.formatting_ok

    Write-TestResult -Result $result -Path $ResultPath
    if ($result.status -eq 'passed') {
        exit 0
    }
    exit 1
}
finally {
    Remove-SandboxCopy -Path $workDir
}
