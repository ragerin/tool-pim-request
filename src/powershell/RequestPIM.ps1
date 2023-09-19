param (
    [switch]$Help,
    [string[]]$PIMRoles,
    [string]$Reason,
    [switch]$YesToAll
)

function DisplayHelp {
    Write-Host "Usage: .\RequestPIM.ps1 [-Help] [-PIMRoles <comma-separated role names>] [-Reason <string>] [-YesToAll]"
    Write-Host ""
    Write-Host "-Help           : Display this help message."
    Write-Host "-PIMRoles       : Supply a comma separated list of role-names."
    Write-Host "-Reason         : Supply the reason given for the PIM request."
    Write-Host "-YesToAll       : Suppress any Y/N prompts."
    Write-Host ""
    Write-Host "Example:"
    Write-Host ".\RequestPIM.ps1 -PIMRoles SEC-G-D-MyProject-Contributor, SEC-G-D-AnotherProject-Reader -Reason `"Developing XYZ feature`" -YesToAll"
    exit
}
if ($Help) {
    DisplayHelp
}


# Get username and object ID
$userName = az account show --query "user.name" -o tsv
$userObjectId = az ad user show --id $userName --query id -o tsv

# Get access token
$token = az account get-access-token --query "accessToken" -o tsv

# Get eligible PIM role assignments
$pimRoleAssignments = Invoke-RestMethod -Uri "https://api.azrbac.mspim.azure.com/api/v2/privilegedAccess/aadGroups/roleAssignments?`$expand=linkedEligibleRoleAssignment,subject,scopedResource,roleDefinition(`$expand=resource)&`$filter=(subject/id eq '$userObjectId') and (assignmentState eq 'Eligible')&`$count=true" -Headers @{"Authorization" = "Bearer $token"}
$eligibleRoles = $pimRoleAssignments.value `
    | Select-Object @{n='Name'; e={$_.roleDefinition.resource.displayName}}, @{n='Id'; e={$_.id}}

# Convert eligibleRoles into a dictionary where each key is the index
$eligibleRolesMap = @{}
for ($i = 0; $i -lt $eligibleRoles.Count; $i++) {
    $eligibleRolesMap.Add($i, $eligibleRoles[$i])
}


$selectedRoleIds = @()

# Get roles from commandline argument
if ($PIMRoles) {
    $roleNames = $PIMRoles -split "\s*,\s*"
    # Loop through the role names and match them with their ID's from eligibleRoles
    $roleNames | ForEach-Object {
        $currentRole = $_
        $id = $eligibleRolesMap.Values | Where-Object { $_.Name -eq $currentRole } | Select-Object -ExpandProperty Id
        $selectedRoleIds += $id
    }
}

# Interactively choose roles to request
else {
    Write-Host "Choose which roles you want to request access for:"
    Write-Host "(Multiple roles can be requested by separating them with a comma)"
    Write-Host "================================================================="


    # Display eligible roles with the index number besides it
    for ($i = 0; $i -lt $eligibleRolesMap.Count; $i++) {
        $role = $eligibleRolesMap[$i]
        Write-Host "[$i]   $($role.Name)"
    }

    Write-Host ""

    $userSelection = Read-Host "(e.g. 0,3,4)"

    # Verify the user input, and map to IDs
    foreach ($index in $userSelection.Split(',')) {
        $trimmedIndex = $index.Trim()

        # Attempt to cast the selection to an integer
        [int]$castedIndex = 0
        if ([int]::TryParse($trimmedIndex, [ref]$castedIndex)) {
            # Check if the selection is within the range of the dictionary indices
            if ($castedIndex -ge 0 -and $castedIndex -lt $eligibleRolesMap.Count) {
                $selectedRole = $eligibleRolesMap[$castedIndex]
                $selectedRoleIds += $selectedRole.Id
            } else {
                Write-Host "Selection out of range= $castedIndex"
            }
        } else {
            Write-Host "Invalid selection= $trimmedIndex"
        }
    }
}


Write-Host ""
Write-Host "================================================================="
Write-Host "You're requesting access for the following roles:"
Write-Host ""

$selectedRoleIds | ForEach-Object {
    $selectedRoleId = $_
    $matchingRole = $eligibleRolesMap.Values | Where-Object { $_.Id -eq $selectedRoleId }
    Write-Host "  -  $($matchingRole.Name)"
}

Write-Host ""
Write-Host "================================================================="


if (!$YesToAll) {
    Write-Host ""
    Write-Host "Is the above correct? (y/n)"
    $answer = Read-Host
    if ($answer -ne "y") {
        Write-Host "Exiting..."
        exit
    }
}


while (-not $Reason -or $Reason.Trim() -eq "") {
    Write-Host ""
    Write-Host "No reason provided from commandline argument."
    Write-Host "A reason is required to document why you are requesting access."
    $Reason = Read-Host "Please enter a reason"
}


if (!$YesToAll) {
    Write-Host ""
    Write-Host "Do you want to continue with the request? (y/n)"
    $answer = Read-Host
    if ($answer -ne "y") {
        Write-Host "Exiting..."
        exit
    }
}


$selectedRoleIds | ForEach-Object {
    $selectedRoleId = $_
    $roleAssignment = $pimRoleAssignments.value | Where-Object { $_.id -eq $selectedRoleId }
    $roleDefinitionId = $roleAssignment.roleDefinitionId
    $resourceId = $roleAssignment.resourceId
    $body = @{
        "roleDefinitionId" = "$roleDefinitionId"
        "resourceId" = "$resourceId"
        "subjectId" = "$userObjectId"
        "assignmentState" = "Active"
        "type"="UserAdd"
        "reason"="$Reason"
        "ticketNumber"=""
        "ticketSystem"=""
        "schedule"=@{
            "type"="Once"
            "startDateTime"=$null
            "endDateTime"=$null
            "duration"="PT480M"
        }
        "linkedEligibleRoleAssignmentId"="$selectedRoleId"
        "scopedResourceId"=""
    }

    try {
        Invoke-RestMethod `
            -Method POST `
            -Uri "https://api.azrbac.mspim.azure.com/api/v2/privilegedAccess/aadGroups/roleAssignmentRequests" `
            -Headers @{"Authorization" = "Bearer $token"; "Content-Type" = "application/json"} `
            -Body $($body | ConvertTo-Json -Compress)
    } catch {
        $errorObject = $_ | ConvertFrom-Json
        Write-Host ""
        Write-Host "$($errorObject.error.code): $($errorObject.error.message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "Exiting..." -ForegroundColor Red
        exit
    }

}

Write-Host ""
Write-Host "================================================================="
Write-Host "PIM access request submitted for the following roles:"
Write-Host ""
$selectedRoleIds | ForEach-Object {
    $selectedRoleId = $_
    $matchingRole = $eligibleRolesMap.Values | Where-Object { $_.Id -eq $selectedRoleId }
    Write-Host "  -  $($matchingRole.Name)"
}
Write-Host ""
Write-Host "================================================================="
