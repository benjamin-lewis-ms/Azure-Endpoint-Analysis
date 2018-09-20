param (
    [parameter(Mandatory=$true)]
    [string]$Organization,
    [parameter(Mandatory=$true)]
    [string]$StorageAccountName,
    [parameter(Mandatory=$true)]
    [string]$StorageResourceGroup,
    [parameter(Mandatory=$true)]
    [string]$TableName,
    [parameter(Mandatory=$true)]
    [string]$GithubUser,
    [parameter(Mandatory=$true)]
    [string]$GithubPAT,
    [int]$PageNum = 1,
    [int]$Count = -1,
    [string]$RunId = $null
)

####################################################
# ASSUMPTIONS
# - User must be logged into azure & have access
#   to the storage account key
# - AzureRmStorageTable PS Module is installed
####################################################

# Use TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

####################################################
# Helper Functions
####################################################

# Load the analysis functions 
. ".\RunAnalysis.ps1"

Function QueryGitHub($queryBody, $githubToken) {
    $apiParams = @{
        Uri     = "https://api.github.com/graphql"
        Method  = "POST"
        Body    = $queryBody
        Headers = @{
            'authorization' = "Bearer " + $githubToken
            "content-type" = "application/json"
        }
    }

    $response = Invoke-WebRequest @apiParams

    if($response.StatusCode -ne 200) {
        Write-Error "Invalid response from GitHub"
    }
    else {
        return ($response.Content | ConvertFrom-Json)
    }
}
Function GetPageCount($githubToken,$org) {
    $totalRepoCount = @'
{ "query":"query { organization(login: \"__ORG__\") { repositories { totalCount }}}" }
'@
    $totalRepoCount = $totalRepoCount.Replace("__ORG__", $org)
    $content = QueryGitHub $totalRepoCount $githubToken
    return $content.data.organization.repositories.totalCount
}
Function GetTableEntry($table, $runId, $projectName) {
    return Get-AzureStorageTableRowByCustomFilter `
    -table $table `
    -customFilter "(PartitionKey eq '$runId') and (RowKey eq '$projectName')"
}
Function SetTableEntry($table, $partitionKey, $rowKey, $propertyHashTable) {
    Add-StorageTableRow -table $table -partitionKey $partitionKey -rowKey $rowKey -property $propertyHashTable > $null
}
<#
Function UpdateTableEntry($table, $entry) {
    $entry | Update-AzureStorageTableRow -table $table > $null
}#>
Function GetLastQueryStateFromTable($table, $runId) {
    $state = @{}
    $rows = @(Get-AzureStorageTableRowByPartitionKey -table $table -partitionKey $runId | Sort-Object TableTimestamp -Descending)

    for($i=0;$i -lt $rows.Count; $i++) {
        if($null -ne $rows[$i].cursor) {
            $state.Add("cursor", $rows[$i].cursor)
            $state.Add("page", $rows[$i].page)
            break
        }
    }

    return $state
}

####################################################
# End Helpers
####################################################

# Connect to Table Storage
try {
    $key = Get-AzureRmStorageAccountKey -ResourceGroupName $StorageResourceGroup -AccountName $StorageAccountName -ErrorAction Stop

    # Create a storage account context
    $storageContext = New-AzureStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $key[0].Value -ErrorAction Stop
    $storageTable = Get-AzureStorageTable -Name $TableName -Context $storageContext -ErrorAction Stop
} catch {
    Write-Host _.Exception.Message
    Write-Error "Unable to connect to Azure. Please ensure you are logged in and the table exists."
    exit
}

# Init or restore state
if([string]::IsNullOrEmpty($RunId)) {
    $RunId = (Get-Date).ToString("dd.MMM.yyyy.HH:mm")

    #can't resume pagination without the runID to get the cursor
    $PageNum = 1
    $cursor = $null
}
else {
    $state = GetLastQueryStateFromTable $storageTable $RunId
    $PageNum = $state.page + 1
    $cursor = $state.cursor
}

# Fetch & Output the total page count
$pageCount = GetPageCount $GithubPAT $Organization
if($Count -le 0) {
    $Count = $pageCount - $PageNum
}
Write-Host "Fetching $Count $Organization repositories..."

####################################################
# Begin processing of GitHub Repos
####################################################
# Define Query Strings
$pageAfterCursor = @'
{ "query":"query { organization(login: \"__ORG__\") { repositories(first: 1, after: \"__cursor__\") { nodes { name isPrivate resourcePath } edges { cursor } } } }" }
'@

$firstPage = @'
{ "query":"query { organization(login: \"__ORG__\") { repositories(first: 1) { nodes { name isPrivate resourcePath } edges { cursor } } } }" }
'@

While($Count -gt 0) {
    if($PageNum -eq 1) {
        $query = $firstPage.Replace("__ORG__", $Organization)
    }
    else {
        Write-Verbose "Using cursor '$cursor'"
        $query = $pageAfterCursor.Replace("__cursor__", $cursor).Replace("__ORG__", $Organization)
    }

    $content = QueryGitHub $query $GithubPAT
    
    
    if("errors" -in $content.PSobject.Properties.Name) {
        Write-Host "Query error"
        foreach($error in $content.errors) {
            Write-Error $error.message
        }
        exit
    }
    elseif($content.data.organization -eq $null) {
        Write-Error "Cannot find org data"
        exit
    }

    $cursor = $content.data.organization.repositories.edges.cursor
    $project = $content.data.organization.repositories.nodes.name

    # we shouldn't have an entry but lets check just to be safe
    $row = GetTableEntry $storageTable $RunId $project

    if($null -ne $row) {     
        Write-Host "Duplicate Table Entry: $RunId | $project. Ignoring Project." -ForegroundColor DarkRed -BackgroundColor White
    }
    else {
        # Start forming our table data
        $tableData = @{}
        $tableData.Add("url", $content.data.organization.repositories.nodes.resourcePath)
        $tableData.Add("cursor", $cursor)
        $tableData.Add("page", $PageNum)

        if($content.data.organization.repositories.nodes.isPrivate -eq $true) {
            Write-Host "Project $project is private, ignoring..." -NoNewline
            $tableData.Add("isPrivate", $true)
        }
        else {
            Write-Host "Analyzing $project..." -NoNewline

            $analysis = RunAnalysis -GitRepoUrl $("https://github.com{0}.git" -f $tableData.url) -GitUser $GithubUser -GitPass $GithubPAT
        
            $MAX_SIZE = 65536 
            $outOfBoundsValues = [System.Collections.ArrayList]@()
            foreach($endpoint in $analysis.Keys) {
                # Ensure we're not too fat for our column
                # $sizeOfColumn = ($analysis[$endpoint].Length * 2) + 4 + 8 + ($endpoint.Length*2)
                $availableColumnLength = ($MAX_SIZE - (4 + 8 + ($endpoint.Length*2))) / 2

                if($analysis[$endpoint].Length -gt $availableColumnLength) {
                    $outOfBoundsValues.Add($endpoint) > $null
                }
                else{
                    $tableData.Add($endpoint, $analysis[$endpoint]);
                }
            }

            foreach($value in $outOfBoundsValues) {
                $availableColumnLength = ($MAX_SIZE - (4 + 8 + ($value.Length*2))) / 2

                #not much we can do except truncate
                $tableData.Add($value, $analysis[$value].Substring(0,$availableColumnLength))

                Write-Host "Column length exceeded: $value. New Length = $availableColumnLength"
            }

            Write-Host "Finished!"
        }

        # we shouldn't have an entry but lets check just to be safe
        $row = GetTableEntry $storageTable $RunId $project

        #if($null -eq $row) {     
            SetTableEntry $storageTable $RunId $project $tableData
            Start-Sleep -s 1
        #}
        <#else {
            Write-Error "Duplicate Table Entry: $RunId | $project"
        }#>
    }

    $Count--
    $PageNum++
}