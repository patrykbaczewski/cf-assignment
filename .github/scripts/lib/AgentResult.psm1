# Everything about the result the test agent returns. The agent is an LLM, so its
# result is checked like any other untrusted input before the pipeline uses it.

Import-Module (Join-Path $PSScriptRoot 'RepoPaths.psm1')

function Test-AgentResult {
    <#
    .SYNOPSIS
        Checks an agent result file against the schema and against rules the schema cannot express.
    .DESCRIPTION
        The schema checks the shape: fields, types, allowed values, lengths.
        This function also checks the meaning:
          - every test file belongs to the module it is listed under,
          - every finding points at a file of its own module,
          - no module is listed twice,
          - with -AllowedModule, the agent only reports on the modules it was given.
    .OUTPUTS
        An object with IsValid, Errors (messages) and Result (the parsed result, or $null).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [string] $SchemaPath = (Join-Path (Get-RepoRoot) '.github/agent/agent-result.schema.json'),

        # The modules the agent was asked to look at (from the detect job).
        [string[]] $AllowedModule
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ IsValid = $false; Errors = @("Result file '$Path' does not exist."); Result = $null }
    }
    $json = Get-Content -LiteralPath $Path -Raw

    # --- Shape: the schema ----------------------------------------------------
    $schemaErrors = $null
    $matchesSchema = Test-Json -Json $json -SchemaFile $SchemaPath -ErrorVariable schemaErrors -ErrorAction SilentlyContinue
    if (-not $matchesSchema) {
        foreach ($schemaError in $schemaErrors) {
            $errors.Add("Schema: $($schemaError.Exception.Message)")
        }
        return [pscustomobject]@{ IsValid = $false; Errors = $errors.ToArray(); Result = $null }
    }

    $result = $json | ConvertFrom-Json

    # --- Meaning: rules the schema cannot express ------------------------------
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($entry in $result.modules) {
        if (-not $seen.Add($entry.module)) {
            $errors.Add("Module '$($entry.module)' is listed more than once.")
        }
        if ($AllowedModule -and $entry.module -notin $AllowedModule) {
            $errors.Add("Module '$($entry.module)' was not part of this run.")
        }
        foreach ($file in $entry.test_files) {
            if (-not $file.StartsWith("$($entry.module)/tests/")) {
                $errors.Add("Test file '$file' does not belong to module '$($entry.module)'.")
            }
        }
    }

    foreach ($finding in $result.findings) {
        if (-not $finding.file.StartsWith("$($finding.module)/")) {
            $errors.Add("Finding '$($finding.title)' points at '$($finding.file)', outside module '$($finding.module)'.")
        }
    }

    [pscustomobject]@{
        IsValid = ($errors.Count -eq 0)
        Errors  = $errors.ToArray()
        Result  = $result
    }
}

function Compare-AgentClaim {
    <#
    .SYNOPSIS
        Compares what the agent says it did with what the verify job found.
    .DESCRIPTION
        The agent's result is a claim. The patch and the verify job's own test runs are
        facts. Every difference is returned as a warning for the pull request comment.
    .OUTPUTS
        Warning messages (strings).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [object] $Result,

        # Test status per module from the verify job, for example @{ 'modules/x' = 'passed' }.
        [Parameter(Mandatory)]
        [hashtable] $VerifiedStatus,

        # Files in the agent's patch.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $PatchFile
    )

    $warnings = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $Result.modules) {
        $verified = $VerifiedStatus[$entry.module]
        if ($verified -and $entry.final_test_status -ne 'not_run' -and $entry.final_test_status -ne $verified) {
            $warnings.Add("$($entry.module): the agent reported '$($entry.final_test_status)', the verify job found '$verified'.")
        }
    }

    $claimedFiles = @($Result.modules | ForEach-Object { $_.test_files } | Where-Object { $_ })
    foreach ($file in $PatchFile) {
        if ($file -notin $claimedFiles) {
            $warnings.Add("'$file' was changed but the agent did not report it.")
        }
    }
    foreach ($file in $claimedFiles) {
        if ($file -notin $PatchFile) {
            $warnings.Add("The agent reported changing '$file', but the patch does not change it.")
        }
    }

    $warnings.ToArray()
}

Export-ModuleMember -Function Test-AgentResult, Compare-AgentClaim
