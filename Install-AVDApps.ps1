#requires -Version 5.1
# AVD application and data disk setup (Custom Script Extension / LocalSystem)
# Expected Terraform attachment: one dedicated 128-GiB managed data disk.
# Safeguard: never format disks with existing partitions/data.
# Keep the script private if installer URLs or configuration are confidential.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Persistent logs and temporary installer storage are intentionally separate.
$LogDir  = 'C:\ProgramData\AVD\Logs'
$WorkDir = 'C:\Windows\Temp\AVDApps'
$LogFile = Join-Path $LogDir 'Install-AVDApps.log'
$PageFileSizeMB = 120 * 1024 # 120 GiB, leaves headroom on a 128-GiB disk

$ChromeUrl = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
$AdobeUrl = 'https://trials.adobe.com/AdobeProducts/APRO/Acrobat_HelpX/win32/Acrobat_DC_Web_x64_WWMUI.zip'
$MimecastUrl = 'https://601905.app.netsuite.com/core/media/media.nl?id=138573912&c=601905&h=cpHZsyktFe1XO9dka6shNzIUxxqxHqdXpXUsd35C5HrG47b_&_xt=.zip'

# Create logging first; if this fails we want the extension to fail immediately.
New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
New-Item -Path $WorkDir -ItemType Directory -Force -ErrorAction Stop | Out-Null

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)
    $line = '{0} - {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $LogFile -Value $line -ErrorAction Stop
    Write-Output $line
}

function Write-DiskInventory {
    Write-Log 'Disk inventory (read-only):'
    foreach ($disk in @(Get-Disk)) {
        Write-Log ('Disk {0}: SizeGiB={1:N2}, Location="{2}", BusType={3}, Style={4}, Offline={5}, Boot={6}, System={7}' -f `
            $disk.Number, ($disk.Size / 1GB), $disk.Location, $disk.BusType, `
            $disk.PartitionStyle, $disk.IsOffline, $disk.IsBoot, $disk.IsSystem)
    }
}

function Set-AVDTempDisk {
    Write-Log 'Starting data disk and page file stage'
    Write-DiskInventory

    $DriveLetter = 'F'
    $VolumeLabel = 'TEMP'
    $PageFilePath = 'F:\pagefile.sys'

    # Windows Get-Disk.Location is not a dependable representation of Azure LUN.
    # Match EXACTLY ONE 128-GiB non-OS disk; abort on zero or ambiguity.
    # Ensure Terraform attaches only one such disk, intended as LUN 0.
    $candidates = @(
        Get-Disk | Where-Object {
            -not $_.IsBoot -and -not $_.IsSystem -and
            $_.Size -ge (127 * 1GB) -and $_.Size -le (129 * 1GB)
        }
    )
    if ($candidates.Count -ne 1) {
        throw "Expected exactly one non-OS 128-GiB data disk; found $($candidates.Count). No disk changes made."
    }
    $disk = $candidates[0]
    Write-Log "Selected disk number $($disk.Number); confirm it is the Terraform data disk attached at LUN 0."

    $existingF = Get-Partition -DriveLetter $DriveLetter -ErrorAction SilentlyContinue
    if ($existingF -and $existingF.DiskNumber -ne $disk.Number) {
        throw 'F: is already assigned to another disk; no changes made.'
    }

    if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
    if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }
    $disk = Get-Disk -Number $disk.Number

    if ($disk.PartitionStyle -eq 'RAW') {
        Write-Log "Initialising new RAW data disk $($disk.Number) and creating F:"
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction Stop
        $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $DriveLetter -ErrorAction Stop
        Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel $VolumeLabel -Confirm:$false -Force -ErrorAction Stop | Out-Null
    } else {
        Write-Log 'Data disk already initialised; existing data will not be formatted'
        $partitions = @(
            Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -eq 'Basic' }
        )
        if ($partitions.Count -ne 1) {
            throw 'Existing disk partition layout is ambiguous; no formatting performed.'
        }
        $partition = $partitions[0]
        if ($partition.DriveLetter -ne $DriveLetter) {
            Set-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -NewDriveLetter $DriveLetter -ErrorAction Stop
        }
        $vol = Get-Volume -DriveLetter $DriveLetter -ErrorAction Stop
        if ($vol.FileSystem -ne 'NTFS') { throw 'Existing data disk is not NTFS; refusing to format.' }
        Set-Volume -DriveLetter $DriveLetter -NewFileSystemLabel $VolumeLabel -ErrorAction Stop
    }

    $vol = Get-Volume -DriveLetter $DriveLetter -ErrorAction Stop
    if ($vol.FileSystem -ne 'NTFS' -or $vol.FileSystemLabel -ne $VolumeLabel) {
        throw 'F: volume verification failed.'
    }
    Write-Log ('F: ready: SizeGiB={0:N2}, FreeGiB={1:N2}' -f ($vol.Size/1GB), ($vol.SizeRemaining/1GB))
    if ($vol.SizeRemaining -lt ($PageFileSizeMB * 1MB)) {
        throw "F: has insufficient space for $PageFileSizeMB MB page file."
    }

    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if ($computer.AutomaticManagedPagefile) {
        Set-CimInstance -InputObject $computer -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop
        Write-Log 'Disabled automatic page file management'
    }

    $existing = Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction Stop |
        Where-Object { $_.Name -ieq $PageFilePath }
    if ($existing) {
        Set-CimInstance -InputObject $existing -Property @{
            InitialSize = $PageFileSizeMB
            MaximumSize = $PageFileSizeMB
        } -ErrorAction Stop
    } else {
        New-CimInstance -ClassName Win32_PageFileSetting -Property @{
            Name = $PageFilePath
            InitialSize = $PageFileSizeMB
            MaximumSize = $PageFileSizeMB
        } -ErrorAction Stop | Out-Null
    }

    $saved = Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction Stop |
        Where-Object { $_.Name -ieq $PageFilePath }
    if (-not $saved -or $saved.InitialSize -ne $PageFileSizeMB -or $saved.MaximumSize -ne $PageFileSizeMB) {
        throw 'Saved F: page file settings did not verify.'
    }

    # Deliberately retain any existing C: page file for now (crash dumps/recovery).
    # The active pagefile will not change until Windows is rebooted.
    Write-Log "F: pagefile configured to $PageFileSizeMB MB (fixed); reboot required."
    Write-Log 'Existing C: pagefile settings retained if present.'
}

function Save-Installer {
    param(
        [string]$Url,
        [string]$Destination
    )

    for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
        try {
            Write-Log "Downloading installer (attempt $Attempt)"

            if (Test-Path $Destination) {
                Remove-Item $Destination -Force
            }

            Invoke-WebRequest `
                -Uri $Url `
                -OutFile $Destination `
                -UseBasicParsing

            if (-not (Test-Path $Destination)) {
                throw "Downloaded installer not found"
            }

            if ((Get-Item $Destination).Length -eq 0) {
                throw "Downloaded installer is empty"
            }

            Write-Log "Download completed"
            return
        }
        catch {
            Write-Log "Download failed: $_"

            if ($Attempt -eq 3) {
                throw
            }

            Start-Sleep -Seconds 10
        }
    }
}

function Test-InstallerSignature {
    param(
        [string]$Path,
        [string]$Publisher
    )

    $Signature = Get-AuthenticodeSignature -FilePath $Path

    if ($Signature.Status -ne "Valid") {
        throw "Invalid installer signature: $Path"
    }

    if ($Signature.SignerCertificate.Subject -notmatch $Publisher) {
        throw "Unexpected installer publisher: $Path"
    }

    Write-Log "Installer signature verified: $Path"
}

function Install-Chrome {

    Write-Log "Checking Google Chrome"

    $ChromePath = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"

    if (Test-Path $ChromePath) {
        Write-Log "Chrome already installed"
        return
    }

    $Installer = Join-Path $WorkDir "ChromeEnterprise64.msi"

    Save-Installer `
        -Url $ChromeUrl `
        -Destination $Installer

    Test-InstallerSignature `
        -Path $Installer `
        -Publisher "Google"

    Write-Log "Installing Google Chrome Enterprise"

    $MsiLog = Join-Path $WorkDir "Chrome-MSI.log"

    $Arguments = "/i `"$Installer`" /qn /norestart /L*v `"$MsiLog`""

    $Process = Start-Process `
        -FilePath "msiexec.exe" `
        -ArgumentList $Arguments `
        -Wait -PassThru

    if ($Process.ExitCode -notin @(0, 3010)) {
        throw "Chrome installation failed: $($Process.ExitCode)"
    }

    if (-not (Test-Path $ChromePath)) {
        throw "Chrome executable not found after installation"
    }

    Write-Log "Chrome installed successfully"
}

function Install-Acrobat {

    Write-Log "Checking Adobe Acrobat"

    $AcrobatPath = "$env:ProgramFiles\Adobe\Acrobat DC\Acrobat\Acrobat.exe"

    if (Test-Path $AcrobatPath) {
        Write-Log "Adobe Acrobat already installed"
        return
    }

    $ZipPath = Join-Path $WorkDir "AcrobatPro.zip"
    $ExtractPath = Join-Path $WorkDir "Adobe"

    Save-Installer `
        -Url $AdobeUrl `
        -Destination $ZipPath

    Write-Log "Extracting Adobe installer"

    Expand-Archive `
        -Path $ZipPath `
        -DestinationPath $ExtractPath `
        -Force

    $SetupFiles = @(
        Get-ChildItem `
            -Path $ExtractPath `
            -Filter "Setup.exe" `
            -Recurse -File
    )

    if ($SetupFiles.Count -eq 0) {
        throw "Adobe Setup.exe not found"
    }

    $Setup = $SetupFiles |
        Where-Object {
            $_.DirectoryName -match "Adobe Acrobat"
        } |
        Select-Object -First 1

    if (-not $Setup) {
        $Setup = $SetupFiles | Select-Object -First 1
    }

    Test-InstallerSignature `
        -Path $Setup.FullName `
        -Publisher "Adobe"

    Write-Log "Installing Adobe Acrobat Pro"

    $Arguments = "/sAll /rs /rps /msi EULA_ACCEPT=YES ROAMIDENTITY=1 ROAMLICENSING=1"

    $Process = Start-Process `
        -FilePath $Setup.FullName `
        -ArgumentList $Arguments `
        -WorkingDirectory $Setup.DirectoryName `
        -Wait -PassThru

    if ($Process.ExitCode -notin @(0, 3010)) {
        throw "Adobe installation failed: $($Process.ExitCode)"
    }

    if (-not (Test-Path $AcrobatPath)) {
        throw "Adobe executable not found after installation"
    }

    Write-Log "Adobe Acrobat installed successfully"
}

function Set-AdobeRegistrySettings {

    Write-Log "Configuring Adobe registry settings"

    $Settings = @(
        @{
            Path = "HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown"
            Name = "bIsSCReducedModeEnforcedEx"
            Value = 1
            Type = "DWord"
        },
        @{
            Path = "HKLM:\SOFTWARE\Adobe\Licensing\UserSpecificLicensing"
            Name = "Enabled"
            Value = "1"
            Type = "String"
        },
        @{
            Path = "HKLM:\SOFTWARE\Adobe\Identity\UserSpecificIdentity"
            Name = "Enabled"
            Value = "1"
            Type = "String"
        }
    )

    foreach ($Setting in $Settings) {

        if (-not (Test-Path $Setting.Path)) {
            New-Item `
                -Path $Setting.Path `
                -Force | Out-Null
        }

        New-ItemProperty `
            -Path $Setting.Path `
            -Name $Setting.Name `
            -Value $Setting.Value `
            -PropertyType $Setting.Type `
            -Force | Out-Null

        $Actual = Get-ItemPropertyValue `
            -Path $Setting.Path `
            -Name $Setting.Name

        if ("$Actual" -ne "$($Setting.Value)") {
            throw "Adobe registry verification failed: $($Setting.Name)"
        }

        Write-Log "Verified Adobe setting: $($Setting.Name)"
    }

    Write-Log "Adobe registry configuration completed"
}

function Install-Mimecast {

    Write-Log "Checking Mimecast for Outlook"

    $UninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $Installed = Get-ItemProperty `
        -Path $UninstallPaths `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -like "Mimecast for Outlook*"
        } |
        Select-Object -First 1

    if ($Installed) {
        Write-Log "Mimecast already installed - skipping"
        return
    }

    $ZipPath = Join-Path $WorkDir "Mimecast.zip"
    $ExtractPath = Join-Path $WorkDir "Mimecast"

    Save-Installer `
        -Url $MimecastUrl `
        -Destination $ZipPath

    Write-Log "Extracting Mimecast package"

    Expand-Archive `
        -Path $ZipPath `
        -DestinationPath $ExtractPath `
        -Force

    $MsiFiles = @(
        Get-ChildItem `
            -Path $ExtractPath `
            -Filter "*.msi" `
            -Recurse -File |
        Where-Object {
            $_.Name -match "Mimecast.*Outlook"
        }
    )

    if ($MsiFiles.Count -ne 1) {
        throw "Expected one Mimecast Outlook MSI, found $($MsiFiles.Count)"
    }

    $Installer = $MsiFiles[0]

    Test-InstallerSignature `
        -Path $Installer.FullName `
        -Publisher "Mimecast"

    Write-Log "Installing Mimecast in multi-user mode"

    $MsiLog = Join-Path $WorkDir "Mimecast-MSI.log"

    $Arguments = "/i `"$($Installer.FullName)`" /qn /norestart ENABLE_MULTIUSER_MODE=`"1`" /L*v `"$MsiLog`""

    $Process = Start-Process `
        -FilePath "msiexec.exe" `
        -ArgumentList $Arguments `
        -Wait -PassThru

    if ($Process.ExitCode -notin @(0, 3010)) {
        throw "Mimecast installation failed: $($Process.ExitCode)"
    }

    # Confirm it registered as installed; MSI return code alone is insufficient.
    $After = Get-ItemProperty -Path $UninstallPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like 'Mimecast for Outlook*' } |
        Select-Object -First 1
    if (-not $After) {
        throw 'Mimecast MSI exited successfully, but product was not found in uninstall registry keys. Review Mimecast-MSI.log.'
    }
    Write-Log "Mimecast multi-user installation completed: $($After.DisplayName)"
}

function Set-OfficeDesktopShortcuts {

    Write-Log "Creating Microsoft Office shortcuts"

    $PublicDesktop = [Environment]::GetFolderPath(
        "CommonDesktopDirectory"
    )

    if (-not (Test-Path $PublicDesktop)) {
        New-Item `
            -Path $PublicDesktop `
            -ItemType Directory `
            -Force | Out-Null
    }

    $OfficeApps = @(
        @{
            Name = "Microsoft Outlook"
            Exe = "OUTLOOK.EXE"
        },
        @{
            Name = "Microsoft Excel"
            Exe = "EXCEL.EXE"
        },
        @{
            Name = "Microsoft Word"
            Exe = "WINWORD.EXE"
        },
        @{
            Name = "Microsoft PowerPoint"
            Exe = "POWERPNT.EXE"
        }
    )

    $OfficePaths = @(
        "$env:ProgramFiles\Microsoft Office\root\Office16",
        "${env:ProgramFiles(x86)}\Microsoft Office\root\Office16",
        "$env:ProgramFiles\Microsoft Office\Office16",
        "${env:ProgramFiles(x86)}\Microsoft Office\Office16"
    )

    $Shell = New-Object -ComObject WScript.Shell

    try {

        foreach ($App in $OfficeApps) {

            $ExePath = $null

            foreach ($Folder in $OfficePaths) {

                $Candidate = Join-Path $Folder $App.Exe

                if (Test-Path $Candidate) {
                    $ExePath = $Candidate
                    break
                }
            }

            if (-not $ExePath) {
                Write-Log "WARNING: $($App.Name) not found"
                continue
            }

            $ShortcutPath = Join-Path `
                $PublicDesktop "$($App.Name).lnk"

            $Shortcut = $Shell.CreateShortcut($ShortcutPath)

            $Shortcut.TargetPath = $ExePath
            $Shortcut.WorkingDirectory = Split-Path $ExePath
            $Shortcut.IconLocation = "$ExePath,0"
            $Shortcut.Description = "Launch $($App.Name)"

            $Shortcut.Save()

            Write-Log "Created shortcut: $ShortcutPath"
        }
    }
    finally {

        if ($Shell) {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($Shell)
        }
    }

    Write-Log "Office shortcuts completed"
}

# Each stage logs its own failures; later stages still execute.
# The extension returns failure if any mandatory stage fails.
$FailedStages = New-Object 'System.Collections.Generic.List[string]'
function Invoke-Stage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    Write-Log "===== START $Name ====="
    try {
        & $Action
        Write-Log "===== SUCCESS $Name ====="
    } catch {
        $FailedStages.Add($Name)
        Write-Log "===== FAILED $Name ====="
        Write-Log ("Reason: " + $_.Exception.Message)
        Write-Log ("Position: " + $_.InvocationInfo.PositionMessage)
    }
}

try {
    Write-Log 'Starting AVD deployment'
    Write-Log "Computer: $env:COMPUTERNAME; Identity: $(whoami); 64-bit: $([Environment]::Is64BitProcess)"
    if (-not [Environment]::Is64BitProcess) { throw 'Requires 64-bit PowerShell' }

    Invoke-Stage 'TEMP disk and page file' { Set-AVDTempDisk }
    Invoke-Stage 'Google Chrome Enterprise' { Install-Chrome }
    Invoke-Stage 'Adobe Acrobat Pro' { Install-Acrobat }
    Invoke-Stage 'Adobe registry settings' { Set-AdobeRegistrySettings }
    Invoke-Stage 'Mimecast for Outlook' { Install-Mimecast }
    Invoke-Stage 'Office desktop shortcuts' { Set-OfficeDesktopShortcuts }

    if ($FailedStages.Count -gt 0) {
        Write-Log "Deployment FAILED stages: $($FailedStages -join ', ')"
        exit 1
    }
    Write-Log 'All stages completed successfully. Reboot required for page file changes.'
    exit 0
} catch {
    Write-Log ("FATAL: " + $_.Exception.Message)
    Write-Log ("Position: " + $_.InvocationInfo.PositionMessage)
    exit 1
}
