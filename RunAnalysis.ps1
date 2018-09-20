
function SearchForEndpoint($path, $endpoint) {
    if($null -eq $path -or $null -eq $endpoint) {
        Write-Error "All  params must be valid"
        return
    }  
    
    $returnValues = @{}

    # ENDPOINT ORDER MATTERS - the first endpoint is assumed to be the commercial one 
    if($endpoint.uris[0].Name -ne "AzureCloud") {
        throw "The first cloud environment in the endpoint should be AzureCloud (commercial)"
    }

    # Select the path of any file that contains the commercial uri
    $filesWithCommercialEndpoint = @(Get-ChildItem -Path $path -Recurse | Select-String $($endpoint.uris[0].uri) -List | Select-Object Path)

    if($filesWithCommercialEndpoint.Count -gt 0) {
        $govFiles = [System.Collections.ArrayList]@()
        for($i = 1; $i -lt $endpoint.uris.Length; $i++) {
            $govFiles.Clear()

            foreach($file in $filesWithCommercialEndpoint) {

                if((Get-Content -Path $file.Path -Raw).Contains($endpoint.uris[$i].uri)) {
                    $govFiles.Add($file.Path) > $null
                }
            }
            if($govFiles.Count -gt 0) {
                # shorten the file names for reporting purposes
                for($x = 0; $x -lt $govFiles.Count; $x++) {
                    $govFiles[$x] = $govFiles[$x].Replace($path, '')
                }


                $returnValues.Add($endpoint.uris[$i].Name, $govFiles -join ",")
            }
        }

        #shorten the commercial file names
        for($i = 0; $i -lt $filesWithCommercialEndpoint.Length; $i++) {
            $filesWithCommercialEndpoint[$i] = $filesWithCommercialEndpoint[$i].Path.Replace($path, '')
        }

        $returnValues.Add($endpoint.uris[0].Name, $filesWithCommercialEndpoint -join ",")
    }

    return $returnValues
}

function RunAnalysis {
    param (
    [parameter(Mandatory=$true)]
    [string]$GitRepoUrl,
    [parameter(Mandatory=$true)]
    [string]$GitUser,
    [parameter(Mandatory=$true)]
    [string]$GitPass
    )

    # Github requires TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # FIXME: The command to get these URLs is Get-AzureRmEnvironment. Unfortunately it doesn't
    # return the Service Bus prefix and it contains garbage fwlink nonsense like 
    # 'http://go.microsoft.com/fwlink/?LinkId=301902' for the AzureChinaCloud management portal
    $endpoints = (Get-Content '.\endpoints.json' -Raw | ConvertFrom-Json).endpoints

    Write-Debug "Searching for the following strings:"
    foreach($endpoint in $endpoints)
    {
        Write-Debug "$($endpoint.Name):"
        foreach($uri in $endpoint.uris) {
            Write-Debug ("`t" + $uri.Name+": "+$uri.uri)
        }
    }
   
    # set up temp directory
    while($true) {
        $tempDir = ( Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetFilenameWithoutExtension([System.IO.Path]::GetRandomFileName())))

        if(!(Test-Path -path $tempDir)) {
            break
        }
    }

    New-Item -ItemType Directory -Path $tempDir > $null
    Write-Verbose "Temp Dir: $tempDir"

    # Start forming our table data
    $tableData = @{}

    try {
        # clone repo
        $uri = [System.Uri]$GitRepoUrl
        $cloneCmd = "clone https://{0}:{1}@github.com{2} --depth 1 -q {3}" -f $GitUser, $GitPass, $uri.LocalPath, $tempDir

        Write-Debug "cloning repo: $cloneCmd"
        $proc = Start-Process -FilePath "git.exe" -ArgumentList $cloneCmd -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue -RedirectStandardError stderr.txt

        # keep track of timeout event
        $didTimeOut = $null
        $maxSeconds = 300

        # wait for normal termination
        $proc | Wait-Process -Timeout $maxSeconds -ea 0 -ev didTimeOut

        if ($didTimeOut)
        {
            # terminate the process
            $proc | Stop-Process 
        }

        #check for error
        Write-Debug "Checking for Error"
        $gitError = Get-Content stderr.txt -Raw
        if(![string]::IsNullOrEmpty($gitError) -or $didTimeOut) {
            if($didTimeOut) {
                $gitError = "Failed to complete in $maxSeconds seconds. " + $gitError
            }

            Write-Debug "Error: $gitError"
            $tableData.Add("Exception", $gitError)
        }
        else {
            Write-Debug "No Errors"
        }

        # search for strings
        foreach($endpoint in $endpoints)
        {
            Write-Verbose "Searching for $($endpoint.name)..."

            $filesFound = SearchForEndpoint $tempDir $endpoint

            foreach($env in $filesFound.Keys) {
                Write-Host "Found $env endpoint"
                $tableData.Add("$($endpoint.name)_$env", $filesFound[$env])
            }
        }
    }
    catch {
        Write-Debug "Catch!"
        # Not entirely sure how big the error file might get so cap at 60KB-ish
        $errorMsg = $_.Exception.Message
        if($errorMsg.Length -gt 30000) {
            $errorMsg = $errorMsg.subString(0,30000)
        }

        $tableData.Add("Exception", $errorMsg)
    }

    # Clean up!
    Remove-item -Path $tempDir -Recurse -Force > $null

    return $tableData
}