#Requires -Version 5.1
<#
=====================================================================
 scripts/deploy-iis.ps1  --  runs ON the Windows/IIS server

 Invoked over SSH by templates/steps/deploy/iis.yml, which runs on a
 self-hosted UBUNTU agent. No Azure Pipelines agent is installed on
 this machine.

 Runs under Windows PowerShell 5.1 (powershell.exe), NOT pwsh 7:
 WebAdministration loads under 7 via WinCompat but the IIS:\ PSDrive
 provider does not proxy reliably, so Get-WebAppPoolState and friends
 fail in ways that are painful to debug.

 ALL configuration arrives in a JSON file that the agent scp's next to
 this script. That is deliberate -- passing a dozen arguments through
 ssh -> cmd.exe -> powershell.exe means three layers of quoting rules
 and paths with spaces do not survive. One file argument has none of
 that. To re-run a deployment by hand, edit the JSON and call:

     powershell.exe -NoProfile -ExecutionPolicy Bypass `
         -File C:\DeployStaging\<proj>_<build>\deploy-iis.ps1 `
         -ConfigFile C:\DeployStaging\<proj>_<build>\deploy-config.json

 Contract with the caller: this script prints an Azure DevOps logging
 command on stdout, exactly once:

   ##vso[task.setvariable variable=ROLLBACK_PERFORMED;isOutput=true]true|false

 The SSH@0 task has no way to hand its stdout back as a variable, but
 the agent parses logging commands out of a task's output stream
 whatever produced them -- so the remote script sets the variable on
 the calling step directly. That step must be named 'healthGate' for
 the downstream reference to resolve.

 HTTPS: config keys Protocol ('http'|'https'), CertificateName and
 HostHeader. With Protocol=https the site's binding on Port becomes
 https with the named certificate (looked up in LocalMachine\My and
 \WebHosting by friendly name, subject CN or thumbprint); an existing
 http binding on that port is replaced. The cert is checked BEFORE the
 live site is touched. A config with no Protocol key deploys over http,
 as before.

 Exit codes: 0 = deployed and healthy
             1 = failed (either rolled back, or unrecoverable)
=====================================================================
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ConfigFile
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------
# Emit the rollback sentinel exactly once, however we exit. The agent
# treats a missing sentinel as "SSH died mid-deploy", which is a
# different (and worse) situation than a clean failure.
# ---------------------------------------------------------------------
$script:SentinelWritten = $false
function Write-Sentinel {
    param([bool] $RolledBack)
    if (-not $script:SentinelWritten) {
        $value = $RolledBack.ToString().ToLower()
        # Must start at the beginning of the line or the agent ignores it.
        Write-Host "##vso[task.setvariable variable=ROLLBACK_PERFORMED;isOutput=true]$value"
        Write-Host "Rollback performed: $value"
        $script:SentinelWritten = $true
    }
}

# Windows PowerShell 5.1's ConvertFrom-Json emits a JSON array as ONE
# object instead of enumerating it, so @(... | ConvertFrom-Json) yields
# a one-element array whose only item is the real array. $history[0]
# is then the whole history, and $history[0].backupPath is a list of
# every backup path (including nulls) -- which breaks Test-Path and the
# status updates as soon as the manifest has two or more entries.
# This flattens it, and also repairs a manifest an earlier run wrote
# with nested arrays.
function Read-History {
    param([string] $Path)
    if (!(Test-Path $Path)) { return ,@() }
    $flat = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push((Get-Content $Path -Raw | ConvertFrom-Json))
    while ($stack.Count -gt 0) {
        $item = $stack.Pop()
        if ($item -is [array]) {
            for ($k = $item.Count - 1; $k -ge 0; $k--) { $stack.Push($item[$k]) }
        } elseif ($null -ne $item) {
            [void]$flat.Add($item)
        }
    }
    return ,$flat.ToArray()
}

# Write-Error is terminating under ErrorActionPreference=Stop and lands
# in the outer catch as 'UNHANDLED ERROR'. Report expected failures as
# an ADO error instead, then exit.
function Write-DeployError {
    param([string] $Message)
    Write-Host "##vso[task.logissue type=error]$Message"
    Write-Host "ERROR: $Message"
}

# Windows paths travel through the JSON as forward slashes so the agent
# never has to escape backslashes. Normalise them back here.
function ConvertTo-WindowsPath {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    return ($Path -replace '/', '\')
}

# ---------------------------------------------------------------------
# Find the TLS certificate for the https binding.
#
# $Name matches, in this order of convenience:
#   - the Friendly Name  (what IIS Manager shows under Server Certificates)
#   - the Subject CN     (e.g. CN=webdev)
#   - the thumbprint     (spaces ignored)
# Searches LocalMachine\My and LocalMachine\WebHosting. Only certs that
# are currently valid AND have a private key qualify -- http.sys cannot
# serve a cert without one. If several match (e.g. an old and a renewed
# 'webdev'), the one that expires last wins.
# ---------------------------------------------------------------------
function Find-SiteCertificate {
    param([string] $Name)
    $now      = Get-Date
    $thumbArg = ($Name -replace '\s', '').ToUpper()
    $found = @()
    foreach ($store in @('My', 'WebHosting')) {
        $storePath = "Cert:\LocalMachine\$store"
        if (!(Test-Path $storePath)) { continue }
        $found += @(Get-ChildItem $storePath | Where-Object {
            $_.HasPrivateKey -and $_.NotBefore -le $now -and $_.NotAfter -gt $now -and (
                $_.FriendlyName -eq $Name -or
                $_.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -eq $Name -or
                $_.Thumbprint -eq $thumbArg
            )
        } | ForEach-Object { [pscustomobject]@{ Certificate = $_; Store = $store } })
    }
    return ($found | Sort-Object { $_.Certificate.NotAfter } -Descending | Select-Object -First 1)
}

# ---------------------------------------------------------------------
# Make the site's binding on $Port match $Protocol, and for https attach
# the certificate. Safe to run on every deploy (idempotent):
#   - a binding of the OTHER protocol on the same port is removed; one
#     port cannot speak both http and https, and this is exactly the
#     binding an earlier http-only deploy left behind
#   - the binding is created if it is missing
#   - the certificate is (re)attached only if a different one, or none,
#     is bound -- so renewing 'webdev' is picked up on the next deploy
# ---------------------------------------------------------------------
function Set-SiteBinding {
    param(
        [string] $SiteName,
        [int]    $Port,
        [string] $Protocol,
        [string] $HostHeader,
        $CertInfo
    )

    # bindingInformation is 'ip:port:host'
    $onPort = {
        param($b)
        $parts = $b.bindingInformation -split ':', 3
        $parts[1] -eq "$Port"
    }

    $other = if ($Protocol -eq 'https') { 'http' } else { 'https' }
    foreach ($b in @(Get-WebBinding -Name $SiteName -Protocol $other | Where-Object { & $onPort $_ })) {
        Write-Host "Removing $other binding '$($b.bindingInformation)' from '$SiteName' (port $Port is now $Protocol)."
        Remove-WebBinding -Name $SiteName -Protocol $other -BindingInformation $b.bindingInformation
    }

    $findBinding = {
        @(Get-WebBinding -Name $SiteName -Protocol $Protocol | Where-Object {
            (& $onPort $_) -and (($_.bindingInformation -split ':', 3)[2] -eq $HostHeader)
        }) | Select-Object -First 1
    }

    $binding = & $findBinding
    if (-not $binding) {
        $bindArgs = @{ Name = $SiteName; Protocol = $Protocol; Port = $Port; IPAddress = '*' }
        if ($HostHeader) { $bindArgs.HostHeader = $HostHeader }
        if ($Protocol -eq 'https' -and $HostHeader) { $bindArgs.SslFlags = 1 }   # 1 = SNI
        New-WebBinding @bindArgs
        Write-Host "Added $Protocol binding on port $Port$(if ($HostHeader) { " for host '$HostHeader'" })."
        $binding = & $findBinding
    }

    if ($Protocol -ne 'https') { return }

    $thumb = $CertInfo.Certificate.Thumbprint
    # http.sys keys SNI bindings by host name, non-SNI ones by IP:port.
    $sslPath = if ($HostHeader) { "IIS:\SslBindings\!$Port!$HostHeader" } else { "IIS:\SslBindings\0.0.0.0!$Port" }

    if (Test-Path $sslPath) {
        $current = Get-Item $sslPath
        if ($current.Thumbprint -eq $thumb) {
            Write-Host "Certificate $thumb already bound to port $Port."
            return
        }
        Write-Host "Replacing certificate $($current.Thumbprint) on port $Port."
        Remove-Item $sslPath -Force   # removes the http.sys cert mapping only, not the IIS binding
    }

    $binding.AddSslCertificate($thumb, $CertInfo.Store)
    Write-Host "Bound certificate '$($CertInfo.Certificate.Subject)' ($thumb, LocalMachine\$($CertInfo.Store)) to port $Port."
}

try {
    if (!(Test-Path $ConfigFile)) {
        Write-Sentinel $false
        Write-DeployError "Config file not found: $ConfigFile"
        exit 1
    }

    $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json

    $StagingPath  = ConvertTo-WindowsPath $cfg.StagingPath
    $DeployPath   = ConvertTo-WindowsPath $cfg.DeployPath
    $BackupRoot   = ConvertTo-WindowsPath $cfg.BackupRoot
    $ProjectName  = [string] $cfg.ProjectName
    $Port         = [int]    $cfg.Port
    $BuildId      = [string] $cfg.BuildId
    $BuildNumber  = [string] $cfg.BuildNumber
    $AppType      = [string] $cfg.AppType
    $ManagedRuntimeVersion          = [string] $cfg.ManagedRuntimeVersion
    $CustomSubFolderForArtifact     = [string] $cfg.CustomSubFolderForArtifact
    $CustomDestinationFolder        = [string] $cfg.CustomDestinationFolder
    $BackupsToKeep                  = [int]    $cfg.BackupsToKeep
    $HealthCheckPath                = [string] $cfg.HealthCheckPath
    $HealthCheckRetries             = [int]    $cfg.HealthCheckRetries
    $HealthCheckDelaySeconds        = [int]    $cfg.HealthCheckDelaySeconds
    $HealthCheckInitialDelaySeconds = [int]    $cfg.HealthCheckInitialDelaySeconds

    # HTTPS settings. A config written by an older pipeline has none of
    # these keys, so an absent Protocol keeps the old behaviour (http).
    $Protocol        = if ([string]::IsNullOrWhiteSpace($cfg.Protocol)) { 'http' } else { ([string] $cfg.Protocol).Trim().ToLower() }
    $CertificateName = [string] $cfg.CertificateName
    $HostHeader      = if ($null -eq $cfg.HostHeader) { '' } else { ([string] $cfg.HostHeader).Trim() }

    if ($Protocol -notin @('http', 'https')) {
        Write-Sentinel $false
        Write-DeployError "Protocol must be 'http' or 'https', got '$Protocol'."
        exit 1
    }

    Import-Module WebAdministration

    $backupDir = Join-Path $BackupRoot "$($ProjectName)_$BuildId"
    $manifest  = Join-Path $BackupRoot "$ProjectName-deployment-history.json"

    # With a host header the https binding is SNI-only, so the probe has
    # to ask for that name -- 'localhost' would get no certificate back.
    $probeHost = if ($HostHeader) { $HostHeader } else { 'localhost' }
    $url       = "$($Protocol)://$($probeHost):$Port$HealthCheckPath"

    if (!(Test-Path $BackupRoot)) {
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    }

    # =================================================================
    # 1. Validate what the agent uploaded, BEFORE disturbing the site
    # =================================================================
    if (!(Test-Path $StagingPath) -or ((Get-ChildItem $StagingPath -Recurse -File).Count -eq 0)) {
        Write-Sentinel $false
        Write-DeployError "Staged artifact at '$StagingPath' is missing or empty. Aborting before touching the live site."
        exit 1
    }
    Write-Host "Staged artifact validated: $((Get-ChildItem $StagingPath -Recurse -File).Count) file(s) in $StagingPath."

    # Resolve the certificate now: finding out it is missing AFTER the
    # old version has been moved to backup would mean an outage.
    $certInfo = $null
    if ($Protocol -eq 'https') {
        if ([string]::IsNullOrWhiteSpace($CertificateName)) {
            Write-Sentinel $false
            Write-DeployError "Protocol is https but no CertificateName was given. Aborting before touching the live site."
            exit 1
        }
        $certInfo = Find-SiteCertificate $CertificateName
        if (-not $certInfo) {
            Write-Sentinel $false
            Write-DeployError "No valid certificate with a private key matching '$CertificateName' (friendly name, subject CN or thumbprint) in LocalMachine\My or LocalMachine\WebHosting. Aborting before touching the live site."
            exit 1
        }
        Write-Host "Using certificate '$($certInfo.Certificate.Subject)' (friendly name '$($certInfo.Certificate.FriendlyName)', thumbprint $($certInfo.Certificate.Thumbprint), expires $($certInfo.Certificate.NotAfter.ToString('yyyy-MM-dd')))."
    }

    # =================================================================
    # 2. Stop app pool, back up, deploy, record manifest
    # =================================================================
    # Stopping matters for BOTH app types: backends lock DLLs outright,
    # and even static files can be held open by IIS output caching.
    if (Test-Path "IIS:\AppPools\$ProjectName") {
        if ((Get-WebAppPoolState -Name $ProjectName).Value -ne 'Stopped') {
            Write-Host "Stopping app pool '$ProjectName'..."
            Stop-WebAppPool -Name $ProjectName
            $tries = 0
            while ((Get-WebAppPoolState -Name $ProjectName).Value -ne 'Stopped' -and $tries -lt 30) {
                Start-Sleep -Seconds 1; $tries++
            }
        }
    }

    $hadPreviousVersion = $false
    if (!(Test-Path $DeployPath)) {
        New-Item -ItemType Directory -Path $DeployPath -Force | Out-Null
    } elseif ((Get-ChildItem $DeployPath).Count -gt 0) {
        Write-Host "Backing up current site to: $backupDir"
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        Move-Item -Path "$DeployPath\*" -Destination $backupDir -Force
        $hadPreviousVersion = $true
    }

    $zipFiles = @(Get-ChildItem -Path "$StagingPath\*.zip" -ErrorAction SilentlyContinue)
    if ($zipFiles.Count -gt 0) {
        foreach ($zip in $zipFiles) {
            Write-Host "Extracting $($zip.Name) to $DeployPath..."
            Expand-Archive -Path $zip.FullName -DestinationPath $DeployPath -Force
        }
    } else {
        Write-Host "No zip files found, performing standard copy."
        Copy-Item -Path "$StagingPath\*" -Destination $DeployPath -Recurse -Force
    }

    # Optional subfolder flatten/rename.
    # frontend: e.g. 'browser' (Angular 17+); backend: the '<ProjectName>'
    # folder that a dotnet publish zip nests everything under.
    if (-not [string]::IsNullOrWhiteSpace($CustomSubFolderForArtifact) -and
        -not [string]::IsNullOrWhiteSpace($CustomDestinationFolder)) {
        $nestedDir = Join-Path $DeployPath $CustomSubFolderForArtifact
        if (Test-Path $nestedDir) {
            Rename-Item -Path $nestedDir -NewName $CustomDestinationFolder -Force
            Write-Host "Renamed '$CustomSubFolderForArtifact' -> '$CustomDestinationFolder'."
        } else {
            Write-Warning "Configured subfolder '$CustomSubFolderForArtifact' was not found inside $DeployPath."
        }
    }

    if ($AppType -eq 'backend' -and !(Test-Path (Join-Path $DeployPath 'web.config'))) {
        Write-Warning "appType=backend but no web.config at $DeployPath root. IIS cannot host the app; check zip structure / subfolder flattening."
    }

    $history = Read-History $manifest
    $entry = [pscustomobject]@{
        buildId     = $BuildId
        buildNumber = $BuildNumber
        deployedAt  = (Get-Date).ToString('o')
        backupPath  = if ($hadPreviousVersion) { $backupDir } else { $null }
        deployPath  = $DeployPath
        appType     = $AppType
        status      = 'deployed'
    }
    $history = @($entry) + $history
    ConvertTo-Json -InputObject @($history) -Depth 4 | Set-Content $manifest -Encoding UTF8
    Write-Host "Manifest updated: $manifest"

    Get-ChildItem -Path $BackupRoot -Directory -Filter "$($ProjectName)_*" |
        Sort-Object CreationTime -Descending |
        Select-Object -Skip $BackupsToKeep |
        ForEach-Object {
            Write-Host "Pruning old backup: $($_.FullName)"
            Remove-Item $_.FullName -Recurse -Force
        }

    # =================================================================
    # 3. Create/update the IIS site + app pool runtime, then start
    # =================================================================
    if (!(Test-Path "IIS:\AppPools\$ProjectName")) { New-WebAppPool -Name $ProjectName | Out-Null }

    # '' (No Managed Code) is correct for SPAs AND for ASP.NET Core,
    # which runs out-of-process via ANCM. 'v4.0' only for classic
    # ASP.NET Framework apps.
    Set-ItemProperty "IIS:\AppPools\$ProjectName" -Name managedRuntimeVersion -Value $ManagedRuntimeVersion
    Write-Host "App pool runtime set to '$(if ($ManagedRuntimeVersion) { $ManagedRuntimeVersion } else { 'No Managed Code' })'."

    if (!(Test-Path "IIS:\Sites\$ProjectName")) {
        # Create with the right protocol from the start, so the site is
        # never briefly listening on plain http.
        $siteArgs = @{ Name = $ProjectName; PhysicalPath = $DeployPath; Port = $Port; ApplicationPool = $ProjectName }
        if ($Protocol -eq 'https') { $siteArgs.Ssl = $true }
        if ($HostHeader) { $siteArgs.HostHeader = $HostHeader }
        if ($Protocol -eq 'https' -and $HostHeader) { $siteArgs.SslFlags = 1 }   # 1 = SNI
        New-Website @siteArgs | Out-Null
        Write-Host "Site $ProjectName created on $Protocol port $Port."
    } else {
        Set-ItemProperty "IIS:\Sites\$ProjectName" -Name physicalPath -Value $DeployPath
        Write-Host "Site $ProjectName updated."
    }

    # For an existing site this also converts the http binding an
    # earlier deploy created into https.
    Set-SiteBinding -SiteName $ProjectName -Port $Port -Protocol $Protocol -HostHeader $HostHeader -CertInfo $certInfo

    if ((Get-WebAppPoolState -Name $ProjectName).Value -ne 'Started') { Start-WebAppPool -Name $ProjectName }
    Start-Website -Name $ProjectName -ErrorAction SilentlyContinue
    Write-Host "App pool and site started."

    # =================================================================
    # 4. Health check -- probed from THIS machine over loopback.
    #    Probing from the Ubuntu agent instead would let a firewall
    #    rule between the two boxes masquerade as an unhealthy app and
    #    roll back a perfectly good build.
    # =================================================================
    if ($Protocol -eq 'https') {
        # PowerShell 5.1 may not offer TLS 1.2 by default; many servers
        # have TLS 1.0/1.1 disabled.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        # The probe goes to 'localhost', but the cert is issued to
        # 'webdev' (or similar), and may come from an internal CA -- so
        # normal validation would fail every probe and roll back a
        # healthy build. Instead of turning validation off, pin it: the
        # only certificate accepted is the exact one bound above. That
        # also catches the case where the binding did not take.
        # Scoped to this powershell.exe process, which exits afterwards.
        $script:ExpectedThumbprint = $certInfo.Certificate.Thumbprint
        [Net.ServicePointManager]::ServerCertificateValidationCallback = {
            param($requestSender, $certificate, $chain, $sslPolicyErrors)
            return ($null -ne $certificate -and $certificate.GetCertHashString() -eq $script:ExpectedThumbprint)
        }
    }
    Write-Host "Health check URL: $url"

    if ($HealthCheckInitialDelaySeconds -gt 0) {
        Write-Host "Waiting $($HealthCheckInitialDelaySeconds)s before first probe (app warm-up)..."
        Start-Sleep -Seconds $HealthCheckInitialDelaySeconds
    }

    $healthy = $false
    for ($i = 1; $i -le $HealthCheckRetries; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) {
                Write-Host "Health check passed (HTTP $($resp.StatusCode)) on attempt $i."
                $healthy = $true
                break
            }
        } catch {
            Write-Host "Attempt $i/$($HealthCheckRetries): not healthy yet ($($_.Exception.Message))"
        }
        Start-Sleep -Seconds $HealthCheckDelaySeconds
    }

    if ($healthy) {
        $history = Read-History $manifest
        $history[0].status = 'healthy'
        ConvertTo-Json -InputObject @($history) -Depth 4 | Set-Content $manifest -Encoding UTF8
        Write-Sentinel $false
        exit 0
    }

    # ----------------------- AUTO-ROLLBACK ---------------------------
    Write-Warning "Health check FAILED. Rolling back to previous version..."

    $history = Read-History $manifest
    $current = $history[0]

    if (-not $current.backupPath -or !(Test-Path $current.backupPath)) {
        Write-Sentinel $false
        Write-DeployError "No backup available to roll back to. Site left as-is; manual intervention required."
        exit 1
    }

    Stop-WebAppPool -Name $ProjectName
    $tries = 0
    while ((Get-WebAppPoolState -Name $ProjectName).Value -ne 'Stopped' -and $tries -lt 30) {
        Start-Sleep -Seconds 1; $tries++
    }

    Remove-Item -Path "$DeployPath\*" -Recurse -Force
    Copy-Item -Path "$($current.backupPath)\*" -Destination $DeployPath -Recurse -Force

    Start-WebAppPool -Name $ProjectName

    $history[0].status = 'rolled-back'
    ConvertTo-Json -InputObject @($history) -Depth 4 | Set-Content $manifest -Encoding UTF8
    Write-Sentinel $true

    Start-Sleep -Seconds $HealthCheckDelaySeconds
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15
        Write-Host "Rollback verified (HTTP $($resp.StatusCode)). Failing the run to flag the bad deploy."
    } catch {
        Write-Warning "Rollback completed but site still unhealthy: $($_.Exception.Message)"
    }
    exit 1   # always fail the run so the bad build is flagged
}
catch {
    # Any terminating error above lands here. Without this the agent
    # sees a bare exit code and no sentinel, and cannot tell a failed
    # deploy from a dropped SSH session.
    Write-Sentinel $false
    Write-Host "UNHANDLED ERROR: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    exit 1
}