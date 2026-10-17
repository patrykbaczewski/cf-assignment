# PSScriptAnalyzer settings for the PowerShell automation in .github/scripts.
#
# The VS Code PowerShell extension reads this file by itself. On the command line:
#   Invoke-ScriptAnalyzer -Path .github/scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
#
# All default rules apply, plus the Stroustrup formatting rules (the opening brace on
# the line of its statement; else, catch and finally on a new line).
@{
    Severity     = @(
        'Error'
        'Warning'
        'Information'
    )

    ExcludeRules = @(
        # Write-Host only prints summaries for people. Since PowerShell 5 it writes to
        # the Information stream, so it can be captured; values are returned, never printed.
        'PSAvoidUsingWriteHost'

        # Every script requires PowerShell 7.4 (#Requires), which reads UTF-8 files
        # without a byte order mark. Only Windows PowerShell 5.1 needs the mark.
        'PSUseBOMForUnicodeEncodedFile'
    )

    Rules        = @{
        PSPlaceOpenBrace           = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }

        PSPlaceCloseBrace          = @{
            Enable             = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }

        PSUseConsistentIndentation = @{
            Enable              = $true
            Kind                = 'space'
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
            IndentationSize     = 4
        }

        PSUseConsistentWhitespace  = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $true
            CheckPipe                               = $true
            CheckPipeForRedundantWhitespace         = $false
            CheckSeparator                          = $true
            CheckParameter                          = $false
            IgnoreAssignmentOperatorInsideHashTable = $true
        }

        PSAlignAssignmentStatement = @{
            Enable         = $true
            CheckHashtable = $true
        }

        PSUseCorrectCasing         = @{
            Enable = $true
        }

        PSUseCompatibleSyntax      = @{
            Enable         = $true
            TargetVersions = @(
                '7.4'
            )
        }
    }
}
