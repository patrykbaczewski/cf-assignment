#Requires -Version 7.4

<#
.SYNOPSIS
    The verify job: checks the agent's result and patch, then runs the tests itself.

.DESCRIPTION
    Runs without an LLM and without secrets, on a fresh checkout of the pull request.
    Nothing the agent says is taken on trust:

      1. The result must match the schema and its rules  (Test-AgentResult)
      2. The patch may only add or change allowed tests  (Test-AgentPatch)
      3. A valid patch is applied
      4. The tests of every module run in the sandbox    (Invoke-TerraformTest.ps1)
      5. The agent's claims are compared with the facts  (Compare-AgentClaim)

    Writes verification.json and one test result per module to -OutputDir. The verdict:
      verified      result and patch valid, every module's tests pass (or it has none)
      tests_failed  result and patch valid, but some tests fail
      rejected      the result or the patch broke a rule; the patch is not applied

    The exit code is 0 whenever the checks ran; the verdict is in the file, so the
    publish job can always report it.

.PARAMETER Modules
    Comma-separated modules of this run, for example modules/a,modules/b.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ResultPath,

    [Parameter(Mandatory = $true)]
    [string] $PatchPath,

    [Parameter(Mandatory = $true)]
    [string] $Modules,

    [Parameter(Mandatory = $true)]
    [string] $OutputDir
)

$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/lib/RepoPaths.psm1"
Import-Module "$PSScriptRoot/lib/AgentResult.psm1"
Import-Module "$PSScriptRoot/lib/AgentPatch.psm1"

$repoRoot = Get-RepoRoot
$moduleList = @($Modules -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [System.String]::IsNullOrWhiteSpace($_) } | ForEach-Object { ConvertTo-ModulePath -Path $_ })
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# --- 1 and 2: the agent's result and patch -------------------------------------

$resultCheck = Test-AgentResult -Path $ResultPath -AllowedModule $moduleList
$patchCheck = Test-AgentPatch -PatchPath $PatchPath -RepoRoot $repoRoot -AllowedModule $moduleList

# --- 3: apply the patch only when both are valid --------------------------------

$patchApplied = $false
if ($resultCheck.IsValid -and $patchCheck.IsValid -and $patchCheck.Files.Count -gt 0) {
    & git -C $repoRoot apply $PatchPath
    if ($LASTEXITCODE -ne 0) {
        throw 'git apply failed after git apply --check passed.'
    }
    $patchApplied = $true
}

# --- 4: run the tests ourselves ------------------------------------------------
# Also when the patch was rejected: then the pull request's own tests are reported.

$tests = foreach ($module in $moduleList) {
    $resultFile = Join-Path $OutputDir ("test-result-" + ($module -replace '/', '-') + '.json')
    & pwsh -NoProfile -File "$PSScriptRoot/Invoke-TerraformTest.ps1" -ModulePath $module -ResultPath $resultFile | Out-Host
    Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
}
$tests = @($tests)

# --- 5: compare claims with facts ----------------------------------------------
# Only meaningful when the patch was accepted: a rejected patch was not applied, so its
# tests could not have run.

$warnings = @()
if ($resultCheck.IsValid -and $patchCheck.IsValid) {
    $verifiedStatus = @{}
    foreach ($test in $tests) {
        $verifiedStatus[$test.module] = $test.status
    }
    $warnings = @(Compare-AgentClaim -Result $resultCheck.Result -VerifiedStatus $verifiedStatus -PatchFile $patchCheck.Files)
}

# --- Verdict -------------------------------------------------------------------

$testsOk = -not ($tests | Where-Object { $_.status -notin 'passed', 'no_tests' })
$verdict = if (-not $resultCheck.IsValid -or -not $patchCheck.IsValid) {
    'rejected'
}
elseif ($testsOk) {
    'verified'
}
else {
    'tests_failed'
}

$verification = [ordered]@{
    verdict        = $verdict
    can_commit     = ($verdict -eq 'verified' -and $patchApplied)
    modules        = $moduleList
    agent_result   = [ordered]@{
        valid  = $resultCheck.IsValid
        errors = @($resultCheck.Errors)
    }
    patch          = [ordered]@{
        valid   = $patchCheck.IsValid
        errors  = @($patchCheck.Errors)
        files   = @($patchCheck.Files)
        applied = $patchApplied
    }
    tests          = $tests
    claim_warnings = $warnings
}
$verification | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDir 'verification.json') -Encoding utf8

Write-Host @"

Verdict: $verdict (can commit: $($verification.can_commit))
"@
foreach ($message in @($resultCheck.Errors) + @($patchCheck.Errors) + $warnings) {
    Write-Host "  - $message"
}
