#Requires -Version 7.4

# Patterns of credentials that must never leave the agent job: not in a committed test,
# not in the text that is posted to the pull request (the idea comes from the threat
# detection step of GitHub Agentic Workflows).

$script:SecretPatterns = [ordered]@{
    'Anthropic key'  = 'sk-ant-[A-Za-z0-9_-]{20,}'
    'GitHub token'   = '\b(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})'
    'AWS access key' = '\bAKIA[0-9A-Z]{16}\b'
    'Private key'    = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'Slack token'    = '\bxox[abprs]-[A-Za-z0-9-]{10,}'
}

function Find-SecretPattern {
    <#
    .SYNOPSIS
        Returns the names of the credential patterns found in the given text.
    .DESCRIPTION
        Only the names are returned, never the matched text, so a caller can report a
        finding without repeating the credential.
    .EXAMPLE
        Find-SecretPattern -Text 'token: ghp_...'   # GitHub token
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Text
    )

    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $script:SecretPatterns.Keys) {
        if ($Text | Where-Object { $_ -cmatch $script:SecretPatterns[$name] }) {
            $found.Add($name)
        }
    }
    return $found.ToArray()
}

Export-ModuleMember -Function Find-SecretPattern
