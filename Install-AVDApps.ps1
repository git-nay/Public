# ============================================================
# AVD Application Installation Script
#
# Applications:
#   - Google Chrome Enterprise 64-bit
#   - Adobe Acrobat Pro 64-bit
#
# Adobe:
#   - Roaming licensing enabled
#   - Roaming identity enabled
#   - Reduced mode registry configuration
#
# Designed for Azure VM Custom Script Extension
# ============================================================

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

$WorkDir = "C:\Windows\Temp\AVDApps"
$LogFile = "$WorkDir\Install.log"

$ChromeUrl = "https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi"

$AdobeUrl = "https://trials.adobe.com/AdobeProducts/APRO/Acrobat_HelpX/win32/Acrobat_DC_Web_x64_WWMUI.zip"

New-Item -Path $WorkDir -ItemType Directory -Force |
Out-Null

# ------------------------------------------------------------
# Logging
# ------------------------------------------------------------

function Write-Log {
    param(
        [string]$Message
    )

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Line = "$Timestamp - $Message"

    Add-Content -Path $LogFile -Value $Line
    Write-Output $Line
}

# ------------------------------------------------------------
# Download helper with retries
# ------------------------------------------------------------

function Save-Installer {
    param(
        [string]$Url,
        [string]$Destination
    )

    $MaxAttempts = 3

    for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {

        try {
            Write-Log "Downloading $Url (attempt $Attempt)"

            Invoke-WebRequest `
                -Uri $Url `
                -OutFile $Destination `
                -UseBasicParsing

            if (-not (Test-Path $Destination)) {
                throw "Downloaded file not found"
            }

            if ((Get-Item $Destination).Length -eq 0) {
                throw "Downloaded file is empty"
            }

            Write-Log "Download completed"
            return
        }
        catch {
            Write-Log "Download attempt failed: $_"

            if ($Attempt -eq $MaxAttempts) {
                throw
            }

            Start-Sleep -Seconds 10
        }
    }
}

# ------------------------------------------------------------
# Install Google Chrome Enterprise
# ------------------------------------------------------------

function Install-Chrome {

    Write-Log "Checking Google Chrome"

    $ChromePath = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"

    if (Test-Path $ChromePath) {
        Write-Log "Google Chrome already installed"
        return
    }

    $Installer = "$WorkDir\ChromeEnterprise64.msi"

    Save-Installer `
        -Url $ChromeUrl `
        -Destination $Installer

    Write-Log "Validating Chrome installer signature"

    $Signature = Get-AuthenticodeSignature -FilePath $Installer

    if ($Signature.Status -ne "Valid" -or
        $Signature.SignerCertificate.Subject -notmatch "Google LLC") {
        throw "Chrome installer signature validation failed"
    }

    Write-Log "Installing Google Chrome Enterprise"

    $Arguments = "/i `"$Installer`" /qn /norestart /L*v `"$WorkDir\Chrome-MSI.log`""

    $Process = Start-Process `
        -FilePath "msiexec.exe" `
        -ArgumentList $Arguments `
        -Wait `
        -PassThru

    if ($Process.ExitCode -notin @(0, 3010)) {
        throw "Chrome installation failed with exit code $($Process.ExitCode)"
    }

    if (-not (Test-Path $ChromePath)) {
        throw "Chrome executable not found after installation"
    }

    Write-Log "Google Chrome installed successfully"
}

# ------------------------------------------------------------
# Install Adobe Acrobat Pro
# ------------------------------------------------------------

function Install-Acrobat {

    Write-Log "Checking Adobe Acrobat"

    $AcrobatPath = "$env:ProgramFiles\Adobe\Acrobat DC\Acrobat\Acrobat.exe"

    if (Test-Path $AcrobatPath) {
        Write-Log "Adobe Acrobat already installed"
        return
    }

    $ZipPath = "$WorkDir\AcrobatPro.zip"
    $ExtractPath = "$WorkDir\Adobe"

    Save-Installer `
        -Url $AdobeUrl `
        -Destination $ZipPath

    Write-Log "Extracting Adobe Acrobat installer"

    New-Item -Path $ExtractPath `
        -ItemType Directory -Force | Out-Null

    Expand-Archive `
        -Path $ZipPath `
        -DestinationPath $ExtractPath `
        -Force

    # Locate the Adobe setup executable
    $Setup = Get-ChildItem `
        -Path $ExtractPath `
        -Filter "Setup.exe" `
        -Recurse `
        -File |
    Where-Object {
        $_.DirectoryName -match "[\\/]Adobe Acrobat([\\/]|$)"
    } |
    Select-Object -First 1

    if (-not $Setup) {
        # Fallback: locate an alternative Setup.exe
        $Setup = Get-ChildItem `
            -Path $ExtractPath `
            -Filter "Setup.exe" `
            -Recurse `
            -File |
        Select-Object -First 1
    }

    if (-not $Setup) {
        throw "Adobe Acrobat Setup.exe not found"
    }

    Write-Log "Adobe installer found: $($Setup.FullName)"

    $Signature = Get-AuthenticodeSignature -FilePath $Setup.FullName

    if ($Signature.Status -ne "Valid" -or
        $Signature.SignerCertificate.Subject -notmatch "Adobe") {
        throw "Adobe installer signature validation failed"
    }

    Write-Log "Installing Adobe Acrobat Pro"

    # Silent installation
    # Enable roaming identity and roaming licensing
    $Arguments = "/sAll /rs /rps /msi EULA_ACCEPT=YES ROAMIDENTITY=1 ROAMLICENSING=1"

    $Process = Start-Process `
        -FilePath $Setup.FullName `
        -ArgumentList $Arguments `
        -WorkingDirectory $Setup.DirectoryName `
        -Wait `
        -PassThru

    if ($Process.ExitCode -notin @(0, 3010)) {
        throw "Adobe installation failed with exit code $($Process.ExitCode)"
    }

    Write-Log "Adobe installer completed with exit code $($Process.ExitCode)"
}

# ------------------------------------------------------------
# Configure Adobe registry settings
# ------------------------------------------------------------

function Set-AdobeRegistrySettings {

    Write-Log "Applying Adobe Acrobat registry settings"

    $RegistrySettings = @(

        # Adobe unified installer reduced mode
        @{
            Path  = "HKLM:\SOFTWARE\Policies\Adobe\Adobe Acrobat\DC\FeatureLockDown"
            Name  = "bIsSCReducedModeEnforcedEx"
            Value = 1
            Type  = "DWord"
        },

        # Adobe user-specific licensing
        @{
            Path  = "HKLM:\SOFTWARE\Adobe\Licensing\UserSpecificLicensing"
            Name  = "Enabled"
            Value = "1"
            Type  = "String"
        },

        # Adobe user-specific identity
        @{
            Path  = "HKLM:\SOFTWARE\Adobe\Identity\UserSpecificIdentity"
            Name  = "Enabled"
            Value = "1"
            Type  = "String"
        }
    )

    foreach ($Setting in $RegistrySettings) {

        Write-Log "Configuring $($Setting.Path)\$($Setting.Name)"

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

        # Verify the registry value
        $Actual = Get-ItemPropertyValue `
            -Path $Setting.Path `
            -Name $Setting.Name

        if ("$Actual" -ne "$($Setting.Value)") {
            throw "Registry validation failed: $($Setting.Path)"
        }

        Write-Log "Registry setting verified successfully"
    }

    Write-Log "Adobe registry configuration complete"
}

# ------------------------------------------------------------
# Main execution
# ------------------------------------------------------------

try {

    Write-Log "======================================"
    Write-Log "Starting AVD Application Installation"
    Write-Log "======================================"

    # Ensure script runs in 64-bit PowerShell
    if (-not [Environment]::Is64BitProcess) {
        throw "This script must run in 64-bit PowerShell"
    }

    # Install Google Chrome
    Install-Chrome

    # Install Adobe Acrobat Pro
    Install-Acrobat

    # Apply Adobe VDI registry settings
    Set-AdobeRegistrySettings

    Write-Log "======================================"
    Write-Log "AVD Application Installation Completed"
    Write-Log "======================================"

    exit 0
}
catch {

    Write-Log "======================================"
    Write-Log "AVD APPLICATION INSTALLATION FAILED"
    Write-Log "ERROR: $_"
    Write-Log "======================================"

    exit 1
}

