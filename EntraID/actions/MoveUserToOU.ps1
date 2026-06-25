# MoveUserToOU.ps1 baton-action script
# Script to move Active Directory user to disabled OU
# Uses pure ADSI/.NET - no Active Directory PowerShell module required
# Accepts user email address and moves user to specified OU

param(
    [Parameter(Mandatory=$true)]
    [string]$UserEmail,

    [Parameter(Mandatory=$true)]
    [string]$DisabledOU
)

$result = @{
    success = $false
    userMoved = $false
    errors = @()
}

# Helper function to get domain default naming context
function Get-DomainNamingContext {
    try {
        $rootDSE = [ADSI]"LDAP://RootDSE"
        return $rootDSE.defaultNamingContext.ToString()
    }
    catch {
        throw "Failed to connect to Active Directory: $($_.Exception.Message)"
    }
}

# Helper function to find user by email address (mail attribute)
function Get-UserByEmail {
    param([string]$Email)

    try {
        $namingContext = Get-DomainNamingContext

        $searcher = New-Object System.DirectoryServices.DirectorySearcher
        $searcher.SearchRoot = [ADSI]"LDAP://$namingContext"
        $searcher.Filter = "(&(objectClass=user)(mail=$Email))"
        $searcher.SearchScope = "Subtree"
        $searcher.PropertiesToLoad.AddRange(@(
            "sAMAccountName",
            "distinguishedName",
            "displayName",
            "cn",
            "mail"
        ))

        $searchResult = $searcher.FindOne()

        if (-not $searchResult) {
            throw "User not found with email: $Email"
        }

        # Get the DirectoryEntry for the found user
        $userEntry = $searchResult.GetDirectoryEntry()

        return @{
            Entry = $userEntry
            Properties = $searchResult.Properties
        }
    }
    catch {
        throw "Failed to find user by email: $($_.Exception.Message)"
    }
}

# Helper function to verify OU exists
function Test-OUExists {
    param([string]$OUPath)

    try {
        $ou = [ADSI]"LDAP://$OUPath"
        # Check if it actually exists and is an OU
        if ($ou.Properties["objectClass"] -contains "organizationalUnit") {
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

# Main script logic
try {
    # Test ADSI connection
    try {
        $namingContext = Get-DomainNamingContext
        Write-Output "Connected to Active Directory via ADSI"
        Write-Output "Domain: $namingContext"
    } catch {
        Write-Output "ERROR: Failed to connect to Active Directory via ADSI"
        Write-Output "Error details: $($_.Exception.Message)"
        $result.errors += "Failed to connect to Active Directory: $($_.Exception.Message)"
        exit 1
    }

    # Find the user by email address
    try {
        $userResult = Get-UserByEmail -Email $UserEmail
        $userEntry = $userResult.Entry

        $userName = $userResult.Properties["displayName"][0]
        $userDN = $userResult.Properties["distinguishedName"][0]
        $userSAM = $userResult.Properties["sAMAccountName"][0]

        Write-Output "Found user: $userName (DN: $userDN)"
        $result.userFound = $true
    } catch {
        Write-Output "ERROR: User not found with email: $UserEmail"
        Write-Output "Error details: $($_.Exception.Message)"
        $result.errors += "User not found with email: $UserEmail - $($_.Exception.Message)"
        exit 1
    }

    # Check if user is already in the disabled OU
    if ($userDN -like "*$DisabledOU") {
        Write-Output "User is already in the disabled OU: $DisabledOU"
        Write-Output "SUCCESS: No action needed - user already in correct location"
        $result.success = $true
        exit 0
    }

    # Verify the disabled OU exists
    if (-not (Test-OUExists -OUPath $DisabledOU)) {
        Write-Output "ERROR: Disabled OU does not exist: $DisabledOU"
        $result.errors += "Disabled OU does not exist: $DisabledOU"
        exit 1
    }
    Write-Output "Validated disabled OU exists: $DisabledOU"

    # Move the user to disabled OU
    try {
        $targetOU = [ADSI]"LDAP://$DisabledOU"
        $userEntry.MoveTo($targetOU)

        Write-Output "SUCCESS: User '$userName' moved to disabled OU: $DisabledOU"

        # Verify the move was successful by re-fetching the user
        $verifyResult = Get-UserByEmail -Email $UserEmail
        $newDN = $verifyResult.Properties["distinguishedName"][0]
        Write-Output "Verification: User new location: $newDN"

        $result.success = $true
        $result.userMoved = $true
        exit 0

    } catch {
        Write-Output "ERROR: Failed to move user to disabled OU"
        Write-Output "Error details: $($_.Exception.Message)"
        $result.errors += "Failed to move user to disabled OU: $($_.Exception.Message)"
        exit 1
    }

} catch {
    Write-Output "ERROR: Unexpected error occurred"
    Write-Output "Error details: $($_.Exception.Message)"
    $result.errors += "Operation failed: $($_.Exception.Message)"
    exit 1
}

