#Requires -Modules Microsoft.Graph.Applications, Microsoft.Graph.Identity.DirectoryManagement

<#
.SYNOPSIS
    Creates an Entra ID App Registration with the permissions required by ConductorOne.

.DESCRIPTION
    Runs in either Azure Cloud Shell or on a local workstation. It:
    1. Connects to Microsoft Graph (Cloud Shell: reuses Az token; local: interactive sign-in)
    2. Creates an App Registration named "ConductorOne Integration"
    3. Assigns read-only Microsoft Graph Application permissions by default
    4. Optionally assigns read-write permissions when -WriteAccess is specified
    5. Grants admin consent for all permissions
    6. Creates a 1-year client secret
    7. Outputs the tenant_id, client_id, and client_secret

.PARAMETER WriteAccess
    Switch to grant read-write permissions instead of read-only.

.PARAMETER TenantId
    Optional tenant ID (GUID or domain). Used only for local interactive sign-in
    when the signed-in user has access to multiple tenants.

.NOTES
    Prerequisites:
    - Cloud Shell: upload the script and run it.
    - Local: PowerShell 7+ with Microsoft.Graph modules installed
      (Install-Module Microsoft.Graph -Scope CurrentUser).
    - Must be run by a Global Administrator or Application Administrator.
#>

param(
    [string]$AppName = "C1 Integration",
    [ValidateSet(90, 180, 365, 730)]
    [int]$SecretExpiryDays = 365,
    [switch]$WriteAccess,
    [string]$TenantId
)

$ErrorActionPreference = "Stop"

Write-Host "`n=== ConductorOne Entra ID Setup ===" -ForegroundColor Cyan
Write-Host "This script creates a service principal for ConductorOne to manage your tenant.`n"

# Detect Cloud Shell: $env:AZUREPS_HOST_ENVIRONMENT is "cloud-shell/<ver>" there.
$inCloudShell = $env:AZUREPS_HOST_ENVIRONMENT -like "cloud-shell/*"

Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Yellow
if ($inCloudShell) {
    # Reuse the existing Cloud Shell Azure token — no extra prompt.
    $token = (Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com" -AsSecureString).Token
    Connect-MgGraph -AccessToken $token -NoWelcome
} else {
    # Local: interactive sign-in with the delegated scopes needed to create the
    # app, grant admin consent, and add a client secret.
    $connectParams = @{
        Scopes     = @("Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All", "Directory.ReadWrite.All")
        NoWelcome  = $true
    }
    if ($TenantId) { $connectParams.TenantId = $TenantId }
    Connect-MgGraph @connectParams
}

$tenantId = (Get-MgContext).TenantId
Write-Host "Connected to tenant: $tenantId" -ForegroundColor Green

# Define Microsoft Graph Application permissions based on access level
$graphAppId = "00000003-0000-0000-c000-000000000000"

if ($WriteAccess) {
    Write-Host "Access level: Read-Write" -ForegroundColor Yellow
    $requiredPermissions = @(
        "Application.ReadWrite.All",
        "AppRoleAssignment.ReadWrite.All",
        "AuditLog.Read.All",
        "Directory.ReadWrite.All",
        "Group.ReadWrite.All",
        "GroupMember.ReadWrite.All",
        "MailboxSettings.ReadWrite",
        "RoleAssignmentSchedule.Read.Directory",
        "RoleEligibilitySchedule.Read.Directory",
        "RoleManagement.Read.All",
        "RoleManagement.ReadWrite.Directory",
        "RoleManagementAlert.Read.Directory",
        "RoleManagementPolicy.Read.AzureADGroup",
        "RoleManagementPolicy.Read.Directory",
        "ServicePrincipalEndpoint.ReadWrite.All",
        "Synchronization.ReadWrite.All",
        "User.ReadWrite.All",
        "User.ReadBasic.All",
        "User.EnableDisableAccount.All"
    )
} else {
    Write-Host "Access level: Read-Only" -ForegroundColor Yellow
    $requiredPermissions = @(
        "Application.Read.All",
        "AuditLog.Read.All",
        "Directory.Read.All",
        "Group.Read.All",
        "GroupMember.Read.All",
        "MailboxSettings.Read",
        "RoleAssignmentSchedule.Read.Directory",
        "RoleEligibilitySchedule.Read.Directory",
        "RoleManagement.Read.All",
        "RoleManagement.Read.Directory",
        "RoleManagementAlert.Read.Directory",
        "RoleManagementPolicy.Read.AzureADGroup",
        "RoleManagementPolicy.Read.Directory",
        "ServicePrincipalEndpoint.Read.All",
        "User.Read.All",
        "User.ReadBasic.All"
    )
}

# Get Microsoft Graph service principal to look up role IDs
$graphSP = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"
if (-not $graphSP) {
    Write-Error "Could not find Microsoft Graph service principal in tenant."
    exit 1
}

# Build the required resource access list
$resourceAccess = @()
foreach ($permName in $requiredPermissions) {
    $role = $graphSP.AppRoles | Where-Object { $_.Value -eq $permName }
    if (-not $role) {
        Write-Warning "Permission '$permName' not found in Microsoft Graph app roles. Skipping."
        continue
    }
    $resourceAccess += @{
        Id   = $role.Id
        Type = "Role"    # Application permission (not delegated)
    }
}

# Check if app already exists
$existingApp = Get-MgApplication -Filter "displayName eq '$AppName'" -Top 1
if ($existingApp) {
    Write-Host "App Registration '$AppName' already exists (appId: $($existingApp.AppId)). Reusing." -ForegroundColor Yellow
    $app = $existingApp
} else {
    # Create the App Registration
    Write-Host "Creating App Registration: $AppName" -ForegroundColor Yellow
    $app = New-MgApplication -DisplayName $AppName -RequiredResourceAccess @(
        @{
            ResourceAppId  = $graphAppId
            ResourceAccess = $resourceAccess
        }
    )
    Write-Host "App Registration created: $($app.AppId)" -ForegroundColor Green
}

# Ensure a Service Principal exists for the app
$appSP = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'" -Top 1
if (-not $appSP) {
    $appSP = New-MgServicePrincipal -AppId $app.AppId
    Write-Host "Service Principal created: $($appSP.Id)" -ForegroundColor Green
} else {
    Write-Host "Service Principal already exists: $($appSP.Id)" -ForegroundColor Yellow
}

# Grant admin consent (app role assignments)
Write-Host "Granting admin consent for permissions..." -ForegroundColor Yellow
foreach ($access in $resourceAccess) {
    try {
        New-MgServicePrincipalAppRoleAssignment `
            -ServicePrincipalId $appSP.Id `
            -PrincipalId $appSP.Id `
            -ResourceId $graphSP.Id `
            -AppRoleId $access.Id | Out-Null
    } catch {
        if ($_.Exception.Message -match "already exists") {
            # Already granted
        } else {
            Write-Warning "Failed to grant permission $($access.Id): $_"
        }
    }
}
Write-Host "Admin consent granted." -ForegroundColor Green

# Create a client secret
Write-Host "Creating client secret (expires in $SecretExpiryDays days)..." -ForegroundColor Yellow
$secretParams = @{
    PasswordCredential = @{
        DisplayName = "ConductorOne Integration Secret"
        EndDateTime = (Get-Date).AddDays($SecretExpiryDays)
    }
}
$secret = Add-MgApplicationPassword -ApplicationId $app.Id -BodyParameter $secretParams

# Output credentials
Write-Host "`n=== ConductorOne Credentials ===" -ForegroundColor Cyan
Write-Host "Copy these values into ConductorOne:`n" -ForegroundColor Yellow
Write-Host "  Tenant ID:     $tenantId"
Write-Host "  Client ID:     $($app.AppId)"
Write-Host "  Client Secret: $($secret.SecretText)"
Write-Host ""
Write-Host "WARNING: The client secret is shown only once. Save it now!" -ForegroundColor Red
Write-Host ""

Disconnect-MgGraph | Out-Null
Write-Host "Done. You can now submit these credentials to ConductorOne." -ForegroundColor Green