function Get-GraphToken($tenantid, $scope, $AsApp, $AppID, $refreshToken, $ReturnRefresh) {
    if (!$scope) { $scope = 'https://graph.microsoft.com/.default' }

    $AuthBody = @{
        client_id     = $ENV:ApplicationId
        client_secret = $ENV:ApplicationSecret
        scope         = $Scope
        refresh_token = $ENV:RefreshToken
        grant_type    = "refresh_token"
                    
    }
    if ($asApp -eq $true) {
        $AuthBody = @{
            client_id     = $ENV:ApplicationId
            client_secret = $ENV:ApplicationSecret
            scope         = $Scope
            grant_type    = "client_credentials"
        }
    }

    if ($null -ne $AppID -and $null -ne $refreshToken) {
        $AuthBody = @{
            client_id     = $appid
            refresh_token = $RefreshToken
            scope         = $Scope
            grant_type    = "refresh_token"
        }
    }

    if (!$tenantid) { $tenantid = $env:tenantid }
    $AccessToken = (Invoke-RestMethod -Method post -Uri "https://login.microsoftonline.com/$($tenantid)/oauth2/v2.0/token" -Body $Authbody -ErrorAction Stop)
    if ($ReturnRefresh) { $header = $AccessToken } else { $header = @{ Authorization = "Bearer $($AccessToken.access_token)" } }

    return $header
}

function Log-Request ($message, $tenant, $API, $user, $sev) {
    $username = ([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($user)) | ConvertFrom-Json).userDetails
    $date = (Get-Date).ToString('s')
    $LogMutex = New-Object System.Threading.Mutex($false, "LogMutex")
    if (!$username) { $username = "CIPP" }
    if (!$tenant) { $tenant = "None" }
    $logdata = "$($date)|$($tenant)|$($API)|$($message)|$($username)|$($sev)"
    if ($LogMutex.WaitOne(1000)) {
        $logdata | Out-File -Append -path "$((Get-Date).ToString('MMyyyy')).log"
    }
    $LogMutex.ReleaseMutex()
}

function New-GraphGetRequest ($uri, $tenantid, $scope, $AsApp, $noPagination) {

    if ($scope -eq "ExchangeOnline") { 
        $Headers = Get-GraphToken -AppID 'a0c73c16-a7e3-4564-9a95-2bdf47383716' -RefreshToken $ENV:ExchangeRefreshToken -Scope 'https://outlook.office365.com/.default' -Tenantid $tenantid
    } else {
        $headers = Get-GraphToken -tenantid $tenantid -scope $scope -AsApp $asapp
    }
    Write-Verbose "Using $($uri) as url"
    $nextURL = $uri
    #not a fan of this, have to reconsider and change. Seperate function?
    if ((Get-AuthorisedRequest -Uri $uri -TenantID $tenantid)) {
        $ReturnedData = do {
            try {
                $Data = (Invoke-RestMethod -Uri $nextURL -Method GET -Headers $headers -ContentType "application/json; charset=utf-8")
                if ($data.value) { $data.value } else { ($Data) }
                if ($noPagination) { $nextURL = $null } else { $nextURL = $data.'@odata.nextLink' }                
            } catch {
                $Message = ($_.ErrorDetails.Message | ConvertFrom-Json).error.message
                if ($Message -eq $null) { $Message = $($_.Exception.Message) }
                throw $Message
            }
        } until ($null -eq $NextURL)
        return $ReturnedData   
    } else {
        Write-Error "Not allowed. You cannot manage your own tenant or tenants not under your scope" 
    }
}       

function New-GraphPOSTRequest ($uri, $tenantid, $body, $type, $scope, $AsApp) {

    $headers = Get-GraphToken -tenantid $tenantid -scope $scope -AsApp $asapp
    Write-Verbose "Using $($uri) as url"
    if (!$type) {
        $type = 'POST'
    }
    #not a fan of this, have to reconsider and change. Seperate function?
    if ((Get-AuthorisedRequest -Uri $uri -TenantID $tenantid)) {
        try {
            $ReturnedData = (Invoke-RestMethod -Uri $($uri) -Method $TYPE -Body $body -Headers $headers -ContentType "application/json; charset=utf-8")
        } catch {
            Write-Host ($_.ErrorDetails.Message | ConvertFrom-Json).error.message
            $Message = ($_.ErrorDetails.Message | ConvertFrom-Json).error.message
            if ($Message -eq $null) { $Message = $($_.Exception.Message) }
            throw $Message
        }
        return $ReturnedData 
    } else {
        Write-Error "Not allowed. You cannot manage your own tenant or tenants not under your scope" 
    }
}
function convert-skuname($skuname, $skuID) {
    $ConvertTable = Import-Csv Conversiontable.csv
    if ($skuname) { $ReturnedName = ($ConvertTable | Where-Object { $_.String_Id -eq $skuname } | Select-Object -Last 1).'Product_Display_Name' }
    if ($skuID) { $ReturnedName = ($ConvertTable | Where-Object { $_.guid -eq $skuid } | Select-Object -Last 1).'Product_Display_Name' }
    if ($ReturnedName) { return $ReturnedName } else { return $skuname, $skuID }
}

function Get-ClassicAPIToken($tenantID, $Resource) {
    $uri = "https://login.microsoftonline.com/$($TenantID)/oauth2/token"
    $body = "resource=$Resource&grant_type=refresh_token&refresh_token=$($ENV:ExchangeRefreshToken)"
    try {
        $token = Invoke-RestMethod $uri -Body $body -ContentType "application/x-www-form-urlencoded" -ErrorAction SilentlyContinue -Method post
        return $token
    } catch {
        Write-Error "Failed to obtain Classic API Token for $Tenant - $_"        
    }
}

function New-ClassicAPIGetRequest($TenantID, $Uri, $Method = 'GET', $Resource = 'https://admin.microsoft.com') {
    $token = Get-ClassicAPIToken -Tenant $tenantID -Resource $Resource

    $NextURL = $Uri

    $ReturnedData = do {
        try {
            $Data = Invoke-RestMethod -ContentType "application/json;charset=UTF-8" -Uri $NextURL -Method $Method -Headers @{
                Authorization            = "Bearer $($token.access_token)";
                "x-ms-client-request-id" = [guid]::NewGuid().ToString();
                "x-ms-client-session-id" = [guid]::NewGuid().ToString()
                'x-ms-correlation-id'    = [guid]::NewGuid()
                'X-Requested-With'       = 'XMLHttpRequest' 
            } 
            $Data
            if ($noPagination) { $nextURL = $null } else { $nextURL = $data.NextLink }            
        } catch {
            throw "Failed to make Classic Get Request $_"
        }
    } until ($null -eq $NextURL)
    return $ReturnedData

}

function Get-AuthorisedRequest($TenantID, $Uri) {
    if ($uri -like "https://graph.microsoft.com/beta/contracts?`$top=999" -or $uri -like "*/customers/*") {
        return $true
    }
    if ($TenantID -in (Get-Tenants).defaultdomainname) {
        return $true
    } else {
        return $false
    }

}

function Get-Tenants {
    param (
        [Parameter( ParameterSetName = 'Skip', Mandatory = $True )]
        [switch]$SkipList,
        [Parameter( ParameterSetName = 'Standard')]
        [switch]$IncludeAll
        
    )

    $cachefile = 'tenants.cache.json'
    
    if ((!$Script:SkipListCache -and !$Script:SkipListCacheEmpty) -or !$Script:IncludedTenantsCache) {
        Write-Host "Read File System"
        $Script:SkipListCache = Get-Content "ExcludedTenants" | ConvertFrom-Csv -Delimiter "|" -Header "Name", "User", "Date"
        if ($null -eq $Script:SkipListCache) {
            Write-Host "Setting Empty Var"
            $Script:SkipListCacheEmpty = $true
        }

        # Load or refresh the cache if older than 24 hours
        $Testfile = Get-Item $cachefile -ErrorAction SilentlyContinue | Where-Object -Property LastWriteTime -GT (Get-Date).Addhours(-24)
        if ($Testfile) {
            Write-Host "Reading Cache"
            $Script:IncludedTenantsCache = Get-Content $cachefile  -ErrorAction SilentlyContinue | ConvertFrom-Json
        } else {
            Write-Host "Updating Cache"
            $Script:IncludedTenantsCache = (New-GraphGetRequest -uri "https://graph.microsoft.com/beta/contracts?`$top=999" -tenantid $ENV:Tenantid) | Select-Object CustomerID, DefaultdomainName, DisplayName, domains | Where-Object -Property DefaultdomainName -NotIn $Script:SkipListCache.name
            if ($Script:IncludedTenantsCache) {
                $Script:IncludedTenantsCache | ConvertTo-Json | Out-File $cachefile
            }
        }    
    }
    if ($SkipList) {
        Write-Host "Returning Skip List"
        return $Script:SkipListCache
    }
    if ($IncludeAll) {
        Write-Host "Returning All"
        return (New-GraphGetRequest -uri "https://graph.microsoft.com/beta/contracts?`$top=999" -tenantid $ENV:Tenantid) | Select-Object CustomerID, DefaultdomainName, DisplayName, domains
    } else {
        Write-Host "Returnning Filtered"
        return $Script:IncludedTenantsCache
    }
}