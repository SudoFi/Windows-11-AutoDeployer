<#
.SYNOPSIS
    MASTER SCRIPT: Downloads ISO, Clones Drivers, Injects, Fixes Boot,
    and Automates USB Creation (handling >4GB WIM splitting).
.NOTES
    Run as Administrator. Zero external dependencies.
#>

# --- STEP 0: ADMIN CHECK ---
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host " [ERROR] Please run as Administrator!" -ForegroundColor Red; Pause; exit
}

# --- CONFIGURATION ---
$WorkingDir = "C:\Temp\Win11_Build"
$ExportedDriverDir = "$WorkingDir\Exported_Drivers"
$MediaDir = "$WorkingDir\Media"
$MountDir = "$WorkingDir\Mount"
$IsoPath = "$WorkingDir\Windows11_Latest.iso"

Clear-Host
Write-Host "=== Windows 11 Master Deployer (USB Edition) ===" -ForegroundColor Cyan

# --- STEP 1: PREP & CLEANUP ---
Write-Host "`n[1/8] Preparing Workspace..." -ForegroundColor Yellow
dism /Cleanup-Mountpoints | Out-Null
dism /Unmount-Image /MountDir:$MountDir /Discard 2>$null | Out-Null

if (Test-Path $WorkingDir) { Remove-Item $WorkingDir -Recurse -Force -ErrorAction SilentlyContinue }

# Explicitly create all required directories
New-Item -Path $WorkingDir -ItemType Directory -Force | Out-Null
New-Item -Path $MountDir -ItemType Directory -Force | Out-Null
New-Item -Path $MediaDir -ItemType Directory -Force | Out-Null
New-Item -Path $ExportedDriverDir -ItemType Directory -Force | Out-Null

# --- STEP 2: CLONE DRIVERS ---
Write-Host "`n[2/8] Cloning Host Drivers..." -ForegroundColor Yellow
try {
    Export-WindowsDriver -Online -Destination $ExportedDriverDir -ErrorAction Stop | Out-Null
    Write-Host "    Success: Drivers cloned from this machine." -ForegroundColor Green
} catch { Write-Error "Driver Export Failed."; Pause; exit }

# --- STEP 3: DOWNLOAD & EXTRACT (INLINE SCRAPER) ---
Write-Host "`n[3/8] Scraping Microsoft API for dynamic download link..." -ForegroundColor Yellow

try {
    # 1. Generate a random session ID to negotiate with Microsoft
    $SessionId = [guid]::NewGuid().ToString()
    $BaseUrl = "https://www.microsoft.com/en-us/software-download/windows11"
    
    Write-Host "    -> Negotiating Product ID..." -ForegroundColor Gray
    $MainPage = Invoke-WebRequest -Uri $BaseUrl -UseBasicParsing
    if ($MainPage.Content -match '<option value="(\d+)".*?Windows 11.*?</option>') {
        $ProductId = $matches[1]
    } else {
        throw "Could not parse Product ID from Microsoft website."
    }

    # 2. Query the hidden API for the English Language SKU
    Write-Host "    -> Negotiating Language SKU (English)..." -ForegroundColor Gray
    $LangUrl = "https://www.microsoft.com/en-US/api/controls/contentinclude/html?pageId=a8f8f489-4c7f-463a-9ca6-5d4a11a5bb98&host=www.microsoft.com&segments=software-download,windows11&query=&action=getskuinformationbyproductedition&sessionId=$SessionId&productEditionId=$ProductId"
    $LangPage = Invoke-WebRequest -Uri $LangUrl -UseBasicParsing
    
    $CleanLangContent = $LangPage.Content.Replace("&quot;", '"')
    if ($CleanLangContent -match '"id":"(\d+)","language":"English"') {
        $SkuId = $matches[1]
    } else {
        throw "Could not find English SKU."
    }

    # 3. Generate the 24-hour tokenized Download Link
    Write-Host "    -> Generating Tokenized Download Link..." -ForegroundColor Gray
    $DownloadUrlReq = "https://www.microsoft.com/en-US/api/controls/contentinclude/html?pageId=a8f8f489-4c7f-463a-9ca6-5d4a11a5bb98&host=www.microsoft.com&segments=software-download,windows11&query=&action=GetProductDownloadLinksBySku&sessionId=$SessionId&skuId=$SkuId&language=English&sdVersion=2"
    $DownloadPage = Invoke-WebRequest -Uri $DownloadUrlReq -UseBasicParsing
    
    $CleanDownloadContent = $DownloadPage.Content.Replace("&amp;", "&")
    if ($CleanDownloadContent -match 'href="(https?://[^"]+x64\.iso\?[^"]+)"') {
        $IsoWebLink = $matches[1]
        Write-Host "    Success: Dynamic Link Acquired!" -ForegroundColor Green
    } else {
        throw "Failed to extract final download URL."
    }

} catch {
    Write-Error "Inline scraping failed: $_"
    Write-Warning "If Microsoft recently redesigned their website, this block may need tweaking."
    Pause; exit
}

# 4. Download and Extract
Write-Host "    >>> Downloading ISO to $IsoPath <<<" -ForegroundColor Cyan
Write-Host "    (Please wait. BITS transfer in progress...)" -ForegroundColor Gray

Import-Module BitsTransfer
Start-BitsTransfer -Source $IsoWebLink -Destination $IsoPath

if (-not (Test-Path $IsoPath)) { 
    Write-Error "Download failed or file not found!"
    Pause; exit 
}
Write-Host "    >>> Download Complete! <<<" -ForegroundColor Green

Write-Host "    Extracting ISO to Media Directory..."
$IsoImage = Mount-DiskImage -ImagePath $IsoPath -StorageType ISO -PassThru
$IsoDrive = ($IsoImage | Get-Volume).DriveLetter

# Robocopy variables wrapped in quotes for safety
cmd /c "robocopy `"$($IsoDrive):\`" `"$MediaDir`" /E /NFL /NDL" | Out-Null
Dismount-DiskImage -ImagePath $IsoPath | Out-Null

# FIX READ-ONLY ATTRIBUTES (Critical for DISM injection later)
Get-ChildItem -Path $WorkingDir -Recurse | ForEach-Object { if ($_.IsReadOnly) { $_.IsReadOnly = $false } }

# --- STEP 4: SMART INDEX & CONVERT ---
Write-Host "`n[4/8] Processing Image..." -ForegroundColor Yellow
$WimFile = "$MediaDir\sources\install.wim"
$EsdFile = "$MediaDir\sources\install.esd"

if (Test-Path $EsdFile) {
    Write-Host "    Converting ESD to WIM..."
    $Info = dism /Get-WimInfo /WimFile:$EsdFile
    if (($Info | Select-String "Index : 2").Count -eq 0) { $Index = "1" } 
    else { $Info | Out-String | Write-Host; $Index = Read-Host "    Enter Index (Likely 1 or 6)" }
    
    dism /Export-Image /SourceImageFile:$EsdFile /SourceIndex:$Index /DestinationImageFile:$WimFile /Compress:max
    Remove-Item $EsdFile
    $Index = 1 
} else {
    $Info = dism /Get-WimInfo /WimFile:$WimFile
    if (($Info | Select-String "Index : 2").Count -eq 0) { $Index = "1" } 
    else { $Info | Out-String | Write-Host; $Index = Read-Host "    Enter Index (Likely 1 or 6)" }
}

# --- STEP 5: INJECT DRIVERS ---
Write-Host "`n[5/8] Injecting Drivers..." -ForegroundColor Yellow
dism /Mount-Image /ImageFile:$WimFile /Index:$Index /MountDir:$MountDir
dism /Image:$MountDir /Add-Driver /Driver:$ExportedDriverDir /Recurse /ForceUnsigned
dism /Unmount-Image /MountDir:$MountDir /Commit

# --- STEP 6: SANITIZE BOOTLOADER ---
Write-Host "`n[6/8] Sanitizing Bootloader..." -ForegroundColor Yellow
$HostBoot = "C:\Windows\Boot\EFI\bootmgfw.efi"
if (Test-Path $HostBoot) {
    Copy-Item -Path $HostBoot -Destination "$MediaDir\efi\boot\bootx64.efi" -Force
    Copy-Item -Path $HostBoot -Destination "$MediaDir\efi\microsoft\boot\bootmgfw.efi" -Force
    Write-Host "    Success: Bootloaders transplanted." -ForegroundColor Green
} else { Write-Warning "Could not find host bootloader." }

# --- STEP 7: USB SELECTION ---
Write-Host "`n[7/8] Detecting USB Drives..." -ForegroundColor Yellow
$UsbDrives = Get-Disk | Where-Object { $_.BusType -eq 'USB' -or $_.BusType -eq 'Removable' }

if (-not $UsbDrives) {
    Write-Error "No USB drives detected. Please insert one and restart script."
    Pause; exit
}

Write-Host "    Available USB Drives:" -ForegroundColor Cyan
$UsbDrives | Format-Table -Property Number, FriendlyName, Size, TotalSize -AutoSize

$DiskNumber = Read-Host "    Enter the Disk Number to FORMAT and FLASH (e.g. 1)"
$SelectedDisk = $UsbDrives | Where-Object { $_.Number -eq $DiskNumber }

if (-not $SelectedDisk) { Write-Error "Invalid selection."; Pause; exit }

Write-Host "`n    WARNING: DISK $DiskNumber ($($SelectedDisk.FriendlyName)) WILL BE ERASED!" -ForegroundColor Red
$Confirm = Read-Host "    Type 'DESTROY' to confirm data loss and proceed"
if ($Confirm -ne 'DESTROY') { Write-Host "Aborted."; exit }

# --- STEP 8: FORMAT & FLASH ---
Write-Host "`n[8/8] Formatting and Flashing..." -ForegroundColor Yellow

# Clean and Format FAT32 (Required for UEFI)
Clear-Disk -Number $DiskNumber -RemoveData -Confirm:$false
New-Partition -DiskNumber $DiskNumber -UseMaximumSize -IsActive -AssignDriveLetter | Format-Volume -FileSystem FAT32 -NewFileSystemLabel "WIN11_SETUP" -Confirm:$false | Out-Null
$UsbVol = (Get-Partition -DiskNumber $DiskNumber | Where-Object { $_.DriveLetter }).DriveLetter
$UsbRoot = "$($UsbVol):\"

Write-Host "    Target Drive: $UsbRoot"
Write-Host "    Copying files (This will take time)..."

# Robocopy everything EXCEPT install.wim (because it might be >4GB)
cmd /c "robocopy `"$MediaDir`" `"$UsbRoot`" /E /XF install.wim /NFL /NDL" | Out-Null

# Handle WIM File
$SourceWim = "$MediaDir\sources\install.wim"
$DestWim   = "$UsbRoot\sources\install.wim"
$DestSwm   = "$UsbRoot\sources\install.swm"
$WimSize   = (Get-Item $SourceWim).Length

if ($WimSize -gt 4290000000) {
    Write-Host "    WIM is $([math]::Round($WimSize/1GB, 2))GB. FAT32 limit exceeded." -ForegroundColor Cyan
    Write-Host "    Splitting WIM into SWM chunks..."
    dism /Split-Image /ImageFile:$SourceWim /SWMFile:$DestSwm /FileSize:4000
} else {
    Write-Host "    WIM is under 4GB. Copying directly..."
    Copy-Item $SourceWim $DestWim
}

Write-Host "`n[SUCCESS] USB Boot Drive Created!" -ForegroundColor Green
Write-Host "    Drive: $UsbRoot"
Write-Host "    Boot Mode: UEFI (Secure Boot Supported)"
Pause
