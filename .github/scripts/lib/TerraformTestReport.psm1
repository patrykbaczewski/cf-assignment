# Turns `terraform test -json` output into a result object, decides the result
# status and prints or saves the result. The functions here only work on data
# (no Docker, no git), so they are easy to test.

function New-TestResult {
    <#
    .SYNOPSIS
        Returns an empty result for one module. Every field of the result JSON is defined here.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $ModulePath
    )

    [ordered]@{
        module            = $ModulePath
        status            = 'error'   # passed | failed | error | no_tests
        formatting_ok     = $null     # $null = not checked
        unformatted_files = @()
        summary           = [ordered]@{
            passed  = 0
            failed  = 0
            errored = 0
            skipped = 0
        }
        runs              = @()
        errors            = @()
    }
}

function ConvertFrom-TerraformTestJson {
    <#
    .SYNOPSIS
        Reads the lines printed by `terraform test -json`.
    .OUTPUTS
        An object with Runs (file, run, status), Errors (messages) and Summary (counts).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Line
    )

    $runs = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $summary = [ordered]@{
        passed  = 0
        failed  = 0
        errored = 0
        skipped = 0
    }

    foreach ($text in $Line) {
        try {
            $entry = $text | ConvertFrom-Json
        }
        catch {
            # Not every line is JSON, for example a crash message.
            if (-not [System.String]::IsNullOrWhiteSpace($text)) {
                $errors.Add($text)
            }
            continue
        }

        switch ($entry.type) {
            'test_run' {
                if ($entry.test_run.progress -eq 'complete') {
                    $runs.Add([ordered]@{
                            file   = $entry.test_run.path
                            run    = $entry.test_run.run
                            status = $entry.test_run.status
                        })
                }
            }
            'diagnostic' {
                if ($entry.diagnostic.severity -eq 'error') {
                    $where = [System.String]::Join(' :: ', @(@($entry.'@testfile', $entry.'@testrun') | Where-Object { -not [System.String]::IsNullOrWhiteSpace($_) }))
                    $message = "$($entry.diagnostic.summary). $($entry.diagnostic.detail)".Trim()
                    if (-not [System.String]::IsNullOrWhiteSpace($where)) {
                        $errors.Add("[$where] $message")
                    }
                    else {
                        $errors.Add($message)
                    }
                }
            }
            'test_summary' {
                $summary.passed = $entry.test_summary.passed
                $summary.failed = $entry.test_summary.failed
                $summary.errored = $entry.test_summary.errored
                $summary.skipped = $entry.test_summary.skipped
            }
        }
    }

    # A Terraform crash prints a long stack trace; the first lines say what happened.
    $maxErrors = 20
    $errorList = $errors.ToArray()
    if ($errorList.Count -gt $maxErrors) {
        $errorList = @($errorList[0..($maxErrors - 1)]) + "... $($errorList.Count - $maxErrors) more lines cut."
    }

    [pscustomobject]@{
        Runs    = $runs.ToArray()
        Errors  = $errorList
        Summary = $summary
    }
}

function Get-TestStatus {
    <#
    .SYNOPSIS
        Decides the status of a test run: passed, failed, error or no_tests.
    .DESCRIPTION
        Terraform reports "0 passed, 0 failed" as success. Here it is no_tests,
        because a module without tests has proved nothing. When Terraform fails without
        running anything, the status is error, never no_tests.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [int] $RunCount,

        [Parameter(Mandatory = $true)]
        [int] $ErrorCount,

        [Parameter(Mandatory = $true)]
        [int] $TestExitCode,

        [Parameter(Mandatory = $true)]
        [bool] $FormattingOk
    )

    if ($RunCount -eq 0 -and $ErrorCount -eq 0 -and $TestExitCode -eq 0) {
        return 'no_tests'
    }
    if ($TestExitCode -eq 0 -and $FormattingOk) {
        return 'passed'
    }
    if ($RunCount -gt 0) {
        return 'failed'
    }
    'error'
}

function Write-TestResult {
    <#
    .SYNOPSIS
        Prints a short summary of a result and, with -Path, saves the result as JSON.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Result,

        [Parameter(Mandatory = $false)]
        [string] $Path
    )

    $formatting = if ($Result.formatting_ok -eq $true) {
        'ok'
    }
    elseif ($Result.formatting_ok -eq $false) {
        'NOT OK: ' + [System.String]::Join(', ', @($Result.unformatted_files))
    }
    else {
        'not checked'
    }

    Write-Host ''
    Write-Host "Module:     $($Result.module)"
    Write-Host "Status:     $($Result.status)"
    Write-Host "Formatting: $formatting"
    Write-Host "Summary:    $($Result.summary.passed) passed, $($Result.summary.failed) failed, $($Result.summary.errored) errored, $($Result.summary.skipped) skipped"
    foreach ($run in $Result.runs) {
        # PadRight keeps the run names in one column: [pass ], [fail ], [error].
        Write-Host "  [$($run.status.PadRight(5))] $($run.file) :: $($run.run)"
    }
    foreach ($message in $Result.errors) {
        Write-Host "  ERROR: $message"
    }

    if (-not [System.String]::IsNullOrWhiteSpace($Path)) {
        $Result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding utf8
    }
}

Export-ModuleMember -Function New-TestResult, ConvertFrom-TerraformTestJson, Get-TestStatus, Write-TestResult
