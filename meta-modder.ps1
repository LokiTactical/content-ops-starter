Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------
# Self-elevate (run as Administrator)
# -----------------------------
function Test-IsAdmin {
  try {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    return $false
  }
}

if (-not (Test-IsAdmin)) {
  Write-Host "Not running as Administrator. Relaunching elevated..." -ForegroundColor Yellow
  $pwsh = (Get-Command powershell.exe).Source
  $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', "`"$PSCommandPath`"") + $args
  try {
    Start-Process -FilePath $pwsh -ArgumentList $argList -Verb RunAs -WorkingDirectory $PSScriptRoot | Out-Null
  } catch {
    Write-Host "Elevation cancelled or failed." -ForegroundColor Red
  }
  exit
}

# -----------------------------
# NTFS owner override
# -----------------------------
# IMPORTANT:
# - The Windows "Owner" shown in file properties is an NTFS security owner (an existing account),
#   not a free-form metadata field.
# - You cannot set it to plain "DESKTOP" unless an account with that exact name exists on the PC.
# - Changing owner usually requires running PowerShell as Administrator.
#
# Set to an existing account, e.g.:
#   "BUILTIN\Administrators" (recommended default)
#   "NT AUTHORITY\SYSTEM"
#   "$env:USERDOMAIN\$env:USERNAME" (current user)
$NtfsOwnerOverride = "BUILTIN\Administrators"

# Cache SID translations (performance)
$script:OwnerSidCache = @{}


function Resolve-OwnerToSid {
  param([Parameter(Mandatory=$true)][string]$Owner)

  $key = $Owner.Trim()
  if ($script:OwnerSidCache.ContainsKey($key)) {
    return $script:OwnerSidCache[$key]
  }

  # Prefer translation via .NET (handles localized names), but also support common well-known SIDs.
  switch -Regex ($key) {
    '^BUILTIN\\Administrators$' { $script:OwnerSidCache[$key] = 'S-1-5-32-544'; return 'S-1-5-32-544' }
    '^Administrators$'           { $script:OwnerSidCache[$key] = 'S-1-5-32-544'; return 'S-1-5-32-544' }
    '^Rendszergazd[aá]k$'        { $script:OwnerSidCache[$key] = 'S-1-5-32-544'; return 'S-1-5-32-544' }
    '^NT AUTHORITY\\SYSTEM$'    { $script:OwnerSidCache[$key] = 'S-1-5-18';      return 'S-1-5-18' }
    '^SYSTEM$'                   { $script:OwnerSidCache[$key] = 'S-1-5-18';      return 'S-1-5-18' }
  }

  try {
    $nt  = New-Object System.Security.Principal.NTAccount($key)
    $sid = $nt.Translate([System.Security.Principal.SecurityIdentifier])
    $script:OwnerSidCache[$key] = $sid.Value
    return $sid.Value
  } catch {
    $script:OwnerSidCache[$key] = $null
    return $null
  }
}

function Set-NtfsOwner {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Owner
  )

  # Fast-path: if current owner already matches the requested owner, skip heavy operations
  try {
    $acl0 = Get-Acl -LiteralPath $Path
    if ($acl0 -and $acl0.Owner -and ($acl0.Owner -match [regex]::Escape($Owner))) {
      return $true
    }
  } catch { }

  # NOTE: "Owner" in Windows file properties is an NTFS security owner.
  # This often fails with Set-Acl if you don't currently have permission, even as admin.
  # Therefore we:
  #  1) Try Set-Acl first (fast)
  #  2) If it fails, take ownership (takeown) and set owner via icacls using SID (most reliable)

  try {
    $acl = Get-Acl -LiteralPath $Path
    $ntAccount = New-Object System.Security.Principal.NTAccount($Owner)
    $acl.SetOwner($ntAccount)
    Set-Acl -LiteralPath $Path -AclObject $acl
    return $true
  } catch {
    # fall through
  }

  # Fallback: use takeown + icacls (works better on locked-down ACLs; SID avoids localization issues)
  try {
    $sid = Resolve-OwnerToSid -Owner $Owner

    # First ensure we can change permissions by taking ownership as Administrators.
    # /A assigns ownership to the Administrators group.
    # NOTE: takeown.exe /D is only valid together with /R (recursive). For single files,
    #       using /D causes: "ERROR: /D should be specified only with /R.".
    if (Test-Path -LiteralPath $Path -PathType Container) {
      & takeown.exe /F "$Path" /A /R /D Y | Out-Null
    } else {
      & takeown.exe /F "$Path" /A | Out-Null
    }

    if ($sid) {
      # Use SID form to avoid language issues. icacls requires a leading * for SID.
      & icacls.exe "$Path" /setowner "*$sid" /C | Out-Null
    } else {
      # Fallback to the textual owner if SID couldn't be resolved.
      & icacls.exe "$Path" /setowner "$Owner" /C | Out-Null
    }

    # Verify (cheap-ish)
    try {
      $acl2 = Get-Acl -LiteralPath $Path
      $currentOwner = $acl2.Owner
      return ($currentOwner -match [regex]::Escape($Owner) -or ($sid -and ($currentOwner -match '\\Administrators$|\\Rendszergazd')))
    } catch {
      return $true
    }
  } catch {
    return $false
  }
}


Add-Type -AssemblyName System.IO.Compression.FileSystem

# -----------------------------
# UI (ASCII-only)
# -----------------------------
function Show-Header {
  Clear-Host

  # Fixed-width box, ASCII only
  $banner = @(
"",
"+----------------------------------------------------------------------------+",
"|                                                                            |",
"|        __  __      _            __  __           _     _                   |",
"|       |  \/  | ___| |_ __ _    |  \/  | ___   __| | __| | ___ _ __         |",
"|       | |\/| |/ _ \ __/ _`  |   | |\/| |/ _ \ / _`  |/ _`  |/ _ \ '__|        |",
"|       | |  | |  __/ || (_| |   | |  | | (_) | (_| | (_| |  __/ |           |",
"|       |_|  |_|\___|\__\__,_|   |_|  |_|\___/ \__,_|\__,_|\___|_|           |",
"|                                                                            |",
"|                        META     MODDER                                     |",
"|                                                                            |",
"|                                                                            |",
"|       Batch DOCX metadata editor (author/date/totalTime + filesystem)      |",
"|                                                                            |",
"|                                                                            |",
"|                                                           ver.3  by Noryt  |",
"+----------------------------------------------------------------------------+",
""
)

$banner | ForEach-Object { Write-Host $_ }

# --- WARNING lines in RED ---
Write-Host "          Before proceeding, please review the README.TXT file" -ForegroundColor Red
Write-Host "       for details about the program’s operation and proper usage." -ForegroundColor Red

Write-Host ""
Write-Host "                                                            /\\_/\\   "
Write-Host "                                                               ( o o ) "
Write-Host "                                                                > ^ <  "
Write-Host ""


}

function Box-Print {
  param(
    [Parameter(Mandatory=$true)][string]$Title,
    [Parameter(Mandatory=$true)][string[]]$Lines
  )

  if (-not $Lines) { $Lines = @('') }

  # --- Prevent ultra-wide boxes that wrap the console into "striped" screens ---
  # Long paths in $Lines can make $max extremely large; then the border line becomes
  # thousands of '-' characters and wraps into many rows.
  $consoleWidth = 120
  try { $consoleWidth = $Host.UI.RawUI.WindowSize.Width } catch { }

  # Leave room for borders: "|  " + text + "  |" => +4, plus '+' borders.
  $maxAllowed = [math]::Max(20, $consoleWidth - 10)

  # If there are too many lines, don't flood the console
  $maxLines = 200
  $extraCount = 0
  if ($Lines.Count -gt $maxLines) {
    $extraCount = $Lines.Count - $maxLines
    $Lines = $Lines[0..($maxLines-1)] + @("... and $extraCount more")
  }

  $max = 0
  foreach ($l in $Lines) {
    if ($null -eq $l) { $l = '' }
    if ($l.Length -gt $max) { $max = $l.Length }
  }
  if ($Title.Length -gt $max) { $max = $Title.Length }

  # Clamp width to avoid wrapping
  if ($max -gt $maxAllowed) { $max = $maxAllowed }

  function _ClampLine([string]$s, [int]$w) {
    if ($null -eq $s) { return '' }
    if ($s.Length -le $w) { return $s }
    if ($w -le 3) { return $s.Substring(0, $w) }
    return ($s.Substring(0, $w-3) + '...')
  }

  $title2 = _ClampLine $Title $max
  $width = $max + 4

  $top = "+" + ("-" * $width) + "+"
  $mid = "|  " + $title2.PadRight($max) + "  |"
  $sep = "+" + ("-" * $width) + "+"

  Write-Host $top
  Write-Host $mid
  Write-Host $sep
  foreach ($l in $Lines) {
    $l2 = _ClampLine $l $max
    Write-Host ("|  " + $l2.PadRight($max) + "  |")
  }
  Write-Host $top
}

function Prompt-NonEmpty([string]$msg) {
  while ($true) {
    $v = Read-Host $msg
    if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
  }
}

function Prompt-Year([string]$msg) {
  while ($true) {
    $v = Read-Host $msg
    if ($v -match '^\d{4}$') {
      $y = [int]$v
      if ($y -ge 1900 -and $y -le 2100) { return $y }
    }
    Write-Host "Please enter a valid year (e.g. 2025)."
  }
}

# -----------------------------
# Helpers
# -----------------------------
function New-TempDirectory {
  $base = [System.IO.Path]::GetTempPath()
  $name = "docx_fix_" + [System.Guid]::NewGuid().ToString("N")
  $path = Join-Path $base $name
  [System.IO.Directory]::CreateDirectory($path) | Out-Null
  return $path
}

function Save-XmlUtf8NoBom {
  param(
    [Parameter(Mandatory=$true)] [xml]$Xml,
    [Parameter(Mandatory=$true)] [string]$Path
  )
  $settings = New-Object System.Xml.XmlWriterSettings
  $settings.Indent = $true
  $settings.OmitXmlDeclaration = $false
  $settings.Encoding = New-Object System.Text.UTF8Encoding($false)

  $writer = [System.Xml.XmlWriter]::Create($Path, $settings)
  $Xml.Save($writer)
  $writer.Close()
}

function To-IsoUtcZ([datetime]$localDt) {
  $utc = $localDt.ToUniversalTime()
  return $utc.ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function To-ExifLocal([datetime]$localDt) {
  return $localDt.ToString("yyyy:MM:dd HH:mm:ss")
}

function Parse-MonthFromFolderName {
  param([string]$name)
  $m = [regex]::Match($name, '^\s*(\d{1,2})')
  if (-not $m.Success) { return $null }
  $month = [int]$m.Groups[1].Value
  if ($month -lt 1 -or $month -gt 12) { return $null }
  return $month
}

function Is-Workday([datetime]$dt) {
  return ($dt.DayOfWeek -ne [DayOfWeek]::Saturday -and $dt.DayOfWeek -ne [DayOfWeek]::Sunday)
}

function Next-Workday([datetime]$dt) {
  $x = $dt
  while (-not (Is-Workday $x)) { $x = $x.AddDays(1) }
  return $x
}

function Prev-Workday([datetime]$dt) {
  $x = $dt
  while (-not (Is-Workday $x)) { $x = $x.AddDays(-1) }
  return $x
}

function Set-RandomAfternoonTime([datetime]$dt) {
  # 11:00 .. 16:30
  $base = Get-Date -Year $dt.Year -Month $dt.Month -Day $dt.Day -Hour 11 -Minute 0 -Second 0
  $offsetMinutes = Get-Random -Minimum 0 -Maximum 331  # 0..330
  $second = Get-Random -Minimum 0 -Maximum 60
  return $base.AddMinutes($offsetMinutes).AddSeconds($second)
}

function Get-MonthWorkLimitDay {
  param([int]$Month)
  if ($Month -eq 12) { return 22 }
  return 31
}

function Get-RandomWorkdayInMonthAfternoon {
  param([int]$Year, [int]$Month, [int]$MaxDay)

  while ($true) {
    $daysInMonth = [DateTime]::DaysInMonth($Year, $Month)
    $upper = [math]::Min($daysInMonth, $MaxDay)
    if ($upper -lt 1) { $upper = 1 }

    $day = Get-Random -Minimum 1 -Maximum ($upper + 1)
    $dt = Get-Date -Year $Year -Month $Month -Day $day -Hour 11 -Minute 0 -Second 0
    $dt = Set-RandomAfternoonTime $dt

    if (Is-Workday $dt) { return $dt }
  }
}

function Clamp-To-MonthLimitWorkdayAfternoon {
  param(
    [Parameter(Mandatory=$true)][int]$Year,
    [Parameter(Mandatory=$true)][int]$Month,
    [Parameter(Mandatory=$true)][datetime]$dt
  )
  $limitDay = Get-MonthWorkLimitDay -Month $Month
  $daysInMonth = [DateTime]::DaysInMonth($Year, $Month)
  $limitDay = [math]::Min($limitDay, $daysInMonth)

  $limit = Get-Date -Year $Year -Month $Month -Day $limitDay -Hour $dt.Hour -Minute $dt.Minute -Second $dt.Second
  $limit = Set-RandomAfternoonTime $limit

  if ($dt.Year -ne $Year -or $dt.Month -ne $Month -or $dt -gt $limit) {
    $dt = $limit
  }

  # ensure workday (go backwards because no work after limit)
  $dt = Prev-Workday $dt
  $dt = Set-RandomAfternoonTime $dt
  return $dt
}

function Get-WorkTimeBeforeReference {
  param([Parameter(Mandatory=$true)][datetime]$Reference)

  $ref = $Reference
  if (-not (Is-Workday $ref)) { $ref = Prev-Workday $ref }

  $day = $ref.Date
  $earliest = Get-Date -Year $day.Year -Month $day.Month -Day $day.Day -Hour 11 -Minute 0 -Second 0
  $latest = Get-Date -Year $day.Year -Month $day.Month -Day $day.Day -Hour 16 -Minute 30 -Second 0

  $max = $ref.AddMinutes(-1)
  if ($max -lt $earliest) {
    $day = (Prev-Workday $day.AddDays(-1)).Date
    $earliest = Get-Date -Year $day.Year -Month $day.Month -Day $day.Day -Hour 11 -Minute 0 -Second 0
    $latest = Get-Date -Year $day.Year -Month $day.Month -Day $day.Day -Hour 16 -Minute 30 -Second 0
    $max = $latest
  }

  if ($max -gt $latest) { $max = $latest }

  $range = [int]($max - $earliest).TotalMinutes
  if ($range -lt 0) { $range = 0 }

  $offset = Get-Random -Minimum 0 -Maximum ($range + 1)
  $second = Get-Random -Minimum 0 -Maximum 60
  return $earliest.AddMinutes($offset).AddSeconds($second)
}

function Get-WorkTimeAfterReference {
  param([Parameter(Mandatory=$true)][datetime]$Reference)

  $ref = $Reference
  if (-not (Is-Workday $ref)) { $ref = Next-Workday $ref }

  $day = $ref.Date
  $earliest = Get-Date -Year $day.Year -Month $day.Month -Day $day.Day -Hour 11 -Minute 0 -Second 0
  $latest = Get-Date -Year $day.Year -Month $day.Month -Day $day.Day -Hour 16 -Minute 30 -Second 0

  $deltaHours = Get-Random -Minimum 2 -Maximum 6  # 2..5 hours later
  $min = $ref.AddHours($deltaHours)

  if ($min -lt $earliest) { $min = $earliest }
  if ($min -gt $latest) {
    $day = (Next-Workday $day.AddDays(1)).Date
    $earliest = Get-Date -Year $day.Year -Month $day.Month -Day $day.Day -Hour 11 -Minute 0 -Second 0
    $latest = Get-Date -Year $day.Year -Month $day.Month -Day $day.Day -Hour 16 -Minute 30 -Second 0
    $min = $earliest
  }

  $range = [int]($latest - $min).TotalMinutes
  if ($range -lt 0) { $range = 0 }

  $offset = Get-Random -Minimum 0 -Maximum ($range + 1)
  $second = Get-Random -Minimum 0 -Maximum 60
  return $min.AddMinutes($offset).AddSeconds($second)
}

function Get-FollowUpDates {
  param(
    [Parameter(Mandatory=$true)][int]$Year,
    [Parameter(Mandatory=$true)][int]$Month,
    [Parameter(Mandatory=$true)][datetime]$CreatedDt
  )

  $deltaSave = Get-Random -Minimum 5 -Maximum 11  # 5..10
  $modifiedDt = $CreatedDt.AddDays($deltaSave)
  $modifiedDt = Next-Workday $modifiedDt
  $modifiedDt = Set-RandomAfternoonTime $modifiedDt
  $modifiedDt = Clamp-To-MonthLimitWorkdayAfternoon -Year $Year -Month $Month -dt $modifiedDt

  if ($modifiedDt -le $CreatedDt) {
    $modifiedDt = Next-Workday ($CreatedDt.AddDays(1))
    $modifiedDt = Set-RandomAfternoonTime $modifiedDt
    $modifiedDt = Clamp-To-MonthLimitWorkdayAfternoon -Year $Year -Month $Month -dt $modifiedDt
  }

  $deltaPrint = Get-Random -Minimum 1 -Maximum 21 # 1..20
  $printedDt = $modifiedDt.AddDays($deltaPrint)
  $printedDt = Next-Workday $printedDt
  $printedDt = Set-RandomAfternoonTime $printedDt
  $printedDt = Clamp-To-MonthLimitWorkdayAfternoon -Year $Year -Month $Month -dt $printedDt

  if ($printedDt -le $modifiedDt) {
    $printedDt = Next-Workday ($modifiedDt.AddDays(1))
    $printedDt = Set-RandomAfternoonTime $printedDt
    $printedDt = Clamp-To-MonthLimitWorkdayAfternoon -Year $Year -Month $Month -dt $printedDt
  }

  return @{
    Modified = $modifiedDt
    Printed = $printedDt
  }
}

function Get-ExifToolPath {
  if ($script:ExifToolPath) { return $script:ExifToolPath }

  $cmd = Get-Command exiftool -ErrorAction SilentlyContinue
  if ($cmd) {
    $script:ExifToolPath = $cmd.Source
    return $script:ExifToolPath
  }

  $scriptDir = Split-Path -Parent $PSCommandPath
  if ($scriptDir) {
    $localExe = Join-Path $scriptDir "tools\exiftool.exe"
    if (Test-Path -LiteralPath $localExe) {
      $script:ExifToolPath = $localExe
      return $script:ExifToolPath
    }
  }

  return $null
}

function Set-FileSystemTimesAndOwner {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][datetime]$CreatedDt,
    [Parameter(Mandatory=$true)][datetime]$ModifiedDt,
    [Parameter(Mandatory=$true)][ref]$Skipped
  )

  try {
    $item2 = Get-Item -LiteralPath $Path
    $item2.CreationTime  = $CreatedDt
    $item2.LastWriteTime = $ModifiedDt
  } catch {
    $Skipped.Value += ("WARN (filesystem time set failed): " + $Path + " | " + $_.Exception.Message)
  }

  if ($NtfsOwnerOverride -and $NtfsOwnerOverride.Trim().Length -gt 0) {
    $okOwner = Set-NtfsOwner -Path $Path -Owner $NtfsOwnerOverride
    if (-not $okOwner) {
      $Skipped.Value += ("WARN (NTFS owner set failed): " + $Path + " | owner='" + $NtfsOwnerOverride + "' (run as Admin? NTFS only?)")
    }
  }
}

function Is-ZipBasedDocx {
  param([string]$Path)
  try {
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $b1 = $fs.ReadByte()
    $b2 = $fs.ReadByte()
    $fs.Close()
    return ($b1 -eq 0x50 -and $b2 -eq 0x4B)
  } catch {
    return $false
  }
}

function Get-WordCountFromExtractedDocx {
  param([Parameter(Mandatory=$true)][string]$ExtractDir)

  # Fast path: Word often stores word count in docProps\app.xml
  $appXmlPath = Join-Path $ExtractDir "docProps\app.xml"
  if (Test-Path -LiteralPath $appXmlPath) {
    try {
      [xml]$appXml = Get-Content -LiteralPath $appXmlPath -Raw
      $nsApp = New-Object System.Xml.XmlNamespaceManager($appXml.NameTable)
      $nsApp.AddNamespace("ep", "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties")
      $wordsNode = $appXml.SelectSingleNode("//ep:Properties/ep:Words", $nsApp)
      if (-not $wordsNode) { $wordsNode = $appXml.SelectSingleNode("//*[local-name()='Words']") }
      if ($wordsNode -and $wordsNode.InnerText -match '^\d+$') { return [int]$wordsNode.InnerText }
    } catch { }
  }

  # Slow path: count words from word\document.xml, but without building a huge string
  $docXmlPath = Join-Path $ExtractDir "word\document.xml"
  if (Test-Path -LiteralPath $docXmlPath) {
    try {
      [xml]$docXml = Get-Content -LiteralPath $docXmlPath -Raw
      $texts = $docXml.SelectNodes("//*[local-name()='t']")
      if ($texts -and $texts.Count -gt 0) {
        $count = 0
        foreach ($t in $texts) {
          $s = $t.InnerText
          if ([string]::IsNullOrWhiteSpace($s)) { continue }
          $m = [regex]::Matches($s, '\\S+')
          $count += $m.Count
        }
        return $count
      }
    } catch { }
  }

  return 0
}

function Estimate-EditingMinutes {
  param(
    [Parameter(Mandatory=$true)][int]$WordCount,
    [Parameter(Mandatory=$true)][int]$MinMinutes,
    [Parameter(Mandatory=$true)][int]$MaxMinutes
  )

  $wpm = Get-Random -Minimum 15 -Maximum 36
  $over = Get-Random -Minimum 10 -Maximum 91

  $base = 0
  if ($WordCount -gt 0) { $base = [math]::Round($WordCount / $wpm) }
  $mins = [int]($base + $over)

  if ($mins -lt $MinMinutes) { $mins = $MinMinutes }
  if ($mins -gt $MaxMinutes) { $mins = $MaxMinutes }

  $mins = $mins + (Get-Random -Minimum 0 -Maximum 21)
  if ($mins -gt $MaxMinutes) { $mins = $MaxMinutes }

  return $mins
}

function Get-UniqueMinutes {
  param(
    [Parameter(Mandatory=$true)][hashtable]$Used,
    [Parameter(Mandatory=$true)][int]$Candidate,
    [Parameter(Mandatory=$true)][int]$MinMinutes,
    [Parameter(Mandatory=$true)][int]$MaxMinutes
  )

  $m = $Candidate
  while ($Used.ContainsKey($m)) {
    $m++
    if ($m -gt $MaxMinutes) { $m = $MinMinutes }
  }
  $Used[$m] = $true
  return $m
}

function Update-OpenXmlMetadata {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [Parameter(Mandatory=$true)][string]$AuthorName,
    [Parameter(Mandatory=$true)][string]$CompanyName,
    [Parameter(Mandatory=$true)][datetime]$CreatedDt,
    [Parameter(Mandatory=$true)][datetime]$ModifiedDt,
    [Parameter(Mandatory=$true)][datetime]$PrintedDt,
    [Parameter(Mandatory=$true)][int]$TotalMinutes,
    [Parameter(Mandatory=$true)][ref]$Skipped
  )

  $tempRoot = New-TempDirectory
  $zipPath = Join-Path $tempRoot "work.zip"
  $extractDir = Join-Path $tempRoot "unzipped"
  [System.IO.Directory]::CreateDirectory($extractDir) | Out-Null

  try { Copy-Item -LiteralPath $FilePath -Destination $zipPath -Force }
  catch {
    $Skipped.Value += ("SKIP (copy failed): " + $FilePath + " | " + $_.Exception.Message)
    return $false
  }

  try { [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir) }
  catch {
    $Skipped.Value += ("SKIP (extract failed): " + $FilePath + " | " + $_.Exception.Message)
    return $false
  }

  $createdIso  = To-IsoUtcZ $CreatedDt
  $modifiedIso = To-IsoUtcZ $ModifiedDt
  $printedIso  = To-IsoUtcZ $PrintedDt

  $fileNameOnly = [System.IO.Path]::GetFileName($FilePath)

  # ---- core.xml ----
  $coreXmlPath = Join-Path $extractDir "docProps\core.xml"
  if (-not (Test-Path -LiteralPath $coreXmlPath)) {
    $Skipped.Value += ("SKIP (core.xml missing): " + $FilePath)
    return $false
  }

  try { [xml]$coreXml = Get-Content -LiteralPath $coreXmlPath -Raw }
  catch {
    $Skipped.Value += ("SKIP (core.xml read failed): " + $FilePath + " | " + $_.Exception.Message)
    return $false
  }

  $nsCore = New-Object System.Xml.XmlNamespaceManager($coreXml.NameTable)
  $nsCore.AddNamespace("cp", "http://schemas.openxmlformats.org/package/2006/metadata/core-properties")
  $nsCore.AddNamespace("dc", "http://purl.org/dc/elements/1.1/")
  $nsCore.AddNamespace("dcterms", "http://purl.org/dc/terms/")

  $creatorNode = $coreXml.SelectSingleNode("//dc:creator", $nsCore)
  $lastModByNode = $coreXml.SelectSingleNode("//cp:lastModifiedBy", $nsCore)
  if ($creatorNode)   { $creatorNode.InnerText = $AuthorName }
  if ($lastModByNode) { $lastModByNode.InnerText = $AuthorName }

  $titleNode = $coreXml.SelectSingleNode("//dc:title", $nsCore)
  if (-not $titleNode) {
    $coreProps = $coreXml.SelectSingleNode("/*[local-name()='coreProperties']")
    if ($coreProps) {
      $titleNode = $coreXml.CreateElement("dc", "title", "http://purl.org/dc/elements/1.1/")
      $coreProps.AppendChild($titleNode) | Out-Null
    }
  }
  if ($titleNode) { $titleNode.InnerText = $fileNameOnly }

  $createdNode  = $coreXml.SelectSingleNode("//dcterms:created", $nsCore)
  $modifiedNode = $coreXml.SelectSingleNode("//dcterms:modified", $nsCore)
  if ($createdNode)  { $createdNode.InnerText  = $createdIso }
  if ($modifiedNode) { $modifiedNode.InnerText = $modifiedIso }

  $lastPrintedNode = $coreXml.SelectSingleNode("//cp:lastPrinted", $nsCore)
  if (-not $lastPrintedNode) {
    $coreProps = $coreXml.SelectSingleNode("/*[local-name()='coreProperties']")
    if ($coreProps) {
      $lastPrintedNode = $coreXml.CreateElement("cp", "lastPrinted", "http://schemas.openxmlformats.org/package/2006/metadata/core-properties")
      $coreProps.AppendChild($lastPrintedNode) | Out-Null
    }
  }
  if ($lastPrintedNode) { $lastPrintedNode.InnerText = $printedIso }

  $totalTimeNodeCore = $coreXml.SelectSingleNode("//cp:totalTime", $nsCore)
  if ($totalTimeNodeCore) { $totalTimeNodeCore.InnerText = [string]$TotalMinutes }

  try { Save-XmlUtf8NoBom -Xml $coreXml -Path $coreXmlPath }
  catch {
    $Skipped.Value += ("SKIP (core.xml write failed): " + $FilePath + " | " + $_.Exception.Message)
    return $false
  }

  # ---- app.xml ----
  $appXmlPath = Join-Path $extractDir "docProps\app.xml"
  if (Test-Path -LiteralPath $appXmlPath) {
    try {
      [xml]$appXml = Get-Content -LiteralPath $appXmlPath -Raw
      $nsApp = New-Object System.Xml.XmlNamespaceManager($appXml.NameTable)
      $nsApp.AddNamespace("ep", "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties")

      $propsNode = $appXml.SelectSingleNode("//ep:Properties", $nsApp)
      if (-not $propsNode) { $propsNode = $appXml.SelectSingleNode("/*[local-name()='Properties']") }

      $companyNode = $appXml.SelectSingleNode("//ep:Properties/ep:Company", $nsApp)
      if (-not $companyNode) { $companyNode = $appXml.SelectSingleNode("//*[local-name()='Company']") }
      if (-not $companyNode -and $propsNode) {
        $companyNode = $appXml.CreateElement("Company", "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties")
        $propsNode.AppendChild($companyNode) | Out-Null
      }
      if ($companyNode) { $companyNode.InnerText = $CompanyName }

      $totalTimeNodeApp = $appXml.SelectSingleNode("//ep:Properties/ep:TotalTime", $nsApp)
      if (-not $totalTimeNodeApp) { $totalTimeNodeApp = $appXml.SelectSingleNode("//*[local-name()='TotalTime']") }
      if ($totalTimeNodeApp) { $totalTimeNodeApp.InnerText = [string]$TotalMinutes }

      Save-XmlUtf8NoBom -Xml $appXml -Path $appXmlPath
    } catch {
      $Skipped.Value += ("WARN (app.xml update failed): " + $FilePath + " | " + $_.Exception.Message)
    }
  }

  # ---- repack ----
  $tmpOut = Join-Path $tempRoot "out.file"
  try {
    if (Test-Path -LiteralPath $tmpOut) { Remove-Item -LiteralPath $tmpOut -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($extractDir, $tmpOut)
  } catch {
    $Skipped.Value += ("SKIP (repack failed): " + $FilePath + " | " + $_.Exception.Message)
    return $false
  }

  try { Copy-Item -LiteralPath $tmpOut -Destination $FilePath -Force }
  catch {
    $Skipped.Value += ("SKIP (overwrite failed): " + $FilePath + " | " + $_.Exception.Message)
    return $false
  }

  try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }

  return $true
}

function Update-ExiftoolMetadata {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [Parameter(Mandatory=$true)][string]$AuthorName,
    [Parameter(Mandatory=$true)][string]$CompanyName,
    [Parameter(Mandatory=$true)][datetime]$CreatedDt,
    [Parameter(Mandatory=$true)][datetime]$ModifiedDt,
    [Parameter(Mandatory=$true)][datetime]$PrintedDt,
    [Parameter(Mandatory=$true)][ref]$Skipped
  )

  $exiftool = Get-ExifToolPath
  if (-not $exiftool) {
    $Skipped.Value += ("SKIP (exiftool not found): " + $FilePath)
    return $false
  }

  $title = [System.IO.Path]::GetFileName($FilePath)
  $createdExif = To-ExifLocal $CreatedDt
  $modifiedExif = To-ExifLocal $ModifiedDt
  $printedExif = To-ExifLocal $PrintedDt

  $args = @(
    "-overwrite_original",
    "-q",
    "-q",
    "-Author=$AuthorName",
    "-Creator=$AuthorName",
    "-Company=$CompanyName",
    "-Title=$title",
    "-CreateDate=$createdExif",
    "-ModifyDate=$modifiedExif",
    "-MetadataDate=$modifiedExif",
    "-LastPrinted=$printedExif",
    $FilePath
  )

  try {
    & $exiftool @args | Out-Null
  } catch {
    $Skipped.Value += ("SKIP (exiftool failed): " + $FilePath + " | " + $_.Exception.Message)
    return $false
  }

  return $true
}

# -----------------------------
# Core operation (one docx)
# -----------------------------
function Update-DocxMetadata {
  param(
    [Parameter(Mandatory=$true)][string]$DocxPath,
    [Parameter(Mandatory=$true)][string]$AuthorName,
    [Parameter(Mandatory=$true)][string]$CompanyName,
    [Parameter(Mandatory=$true)][int]$Year,
    [Parameter(Mandatory=$true)][int]$Month,
    [Parameter(Mandatory=$true)][hashtable]$UsedMinutesInThisMonthFolder,
    [Parameter(Mandatory=$true)][ref]$Skipped,
    [Parameter(Mandatory=$true)][ref]$CreatedDates
  )

  if (-not (Test-Path -LiteralPath $DocxPath)) {
    $Skipped.Value += ("MISSING: " + $DocxPath)
    return $false
  }

  if (-not (Is-ZipBasedDocx -Path $DocxPath)) {
    $Skipped.Value += ("SKIP (not zip docx / maybe encrypted/corrupt): " + $DocxPath)
    return $false
  }

  $tempRoot = New-TempDirectory
  $zipPath = Join-Path $tempRoot "work.zip"
  $extractDir = Join-Path $tempRoot "unzipped"
  [System.IO.Directory]::CreateDirectory($extractDir) | Out-Null

  try { Copy-Item -LiteralPath $DocxPath -Destination $zipPath -Force }
  catch {
    $Skipped.Value += ("SKIP (copy failed): " + $DocxPath + " | " + $_.Exception.Message)
    return $false
  }

  try { [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir) }
  catch {
    $Skipped.Value += ("SKIP (extract failed): " + $DocxPath + " | " + $_.Exception.Message)
    return $false
  }

  # ---- Dates (Workday hours) with December limit (no work after Dec 22) ----
  $daysInMonth = [DateTime]::DaysInMonth($Year, $Month)
  $workLimitDay = [math]::Min((Get-MonthWorkLimitDay -Month $Month), $daysInMonth)

  # created must allow +10 days and still stay <= workLimitDay
  $maxCreatedDay = $workLimitDay - 10
  if ($maxCreatedDay -lt 1) { $maxCreatedDay = 1 }

  $createdDt = Get-RandomWorkdayInMonthAfternoon -Year $Year -Month $Month -MaxDay $maxCreatedDay

  $followUp = Get-FollowUpDates -Year $Year -Month $Month -CreatedDt $createdDt
  $modifiedDt = $followUp.Modified
  $printedDt = $followUp.Printed

  $createdIso  = To-IsoUtcZ $createdDt
  $modifiedIso = To-IsoUtcZ $modifiedDt
  $printedIso  = To-IsoUtcZ $printedDt

  # ---- TotalTime proportional to length ----
  $wordCount = Get-WordCountFromExtractedDocx -ExtractDir $extractDir
  $candMin = Estimate-EditingMinutes -WordCount $wordCount -MinMinutes 150 -MaxMinutes 500
  $totalMinutes = Get-UniqueMinutes -Used $UsedMinutesInThisMonthFolder -Candidate $candMin -MinMinutes 150 -MaxMinutes 500

  $fileNameOnly = [System.IO.Path]::GetFileName($DocxPath)

  # ---- core.xml ----
  $coreXmlPath = Join-Path $extractDir "docProps\core.xml"
  if (-not (Test-Path -LiteralPath $coreXmlPath)) {
    $Skipped.Value += ("SKIP (core.xml missing): " + $DocxPath)
    return $false
  }

  try { [xml]$coreXml = Get-Content -LiteralPath $coreXmlPath -Raw }
  catch {
    $Skipped.Value += ("SKIP (core.xml read failed): " + $DocxPath + " | " + $_.Exception.Message)
    return $false
  }

  $nsCore = New-Object System.Xml.XmlNamespaceManager($coreXml.NameTable)
  $nsCore.AddNamespace("cp", "http://schemas.openxmlformats.org/package/2006/metadata/core-properties")
  $nsCore.AddNamespace("dc", "http://purl.org/dc/elements/1.1/")
  $nsCore.AddNamespace("dcterms", "http://purl.org/dc/terms/")

  $creatorNode = $coreXml.SelectSingleNode("//dc:creator", $nsCore)
  $lastModByNode = $coreXml.SelectSingleNode("//cp:lastModifiedBy", $nsCore)
  if ($creatorNode)   { $creatorNode.InnerText = $AuthorName }
  if ($lastModByNode) { $lastModByNode.InnerText = $AuthorName }

  $titleNode = $coreXml.SelectSingleNode("//dc:title", $nsCore)
  if (-not $titleNode) {
    $coreProps = $coreXml.SelectSingleNode("/*[local-name()='coreProperties']")
    if ($coreProps) {
      $titleNode = $coreXml.CreateElement("dc", "title", "http://purl.org/dc/elements/1.1/")
      $coreProps.AppendChild($titleNode) | Out-Null
    }
  }
  if ($titleNode) { $titleNode.InnerText = $fileNameOnly }

  $createdNode  = $coreXml.SelectSingleNode("//dcterms:created", $nsCore)
  $modifiedNode = $coreXml.SelectSingleNode("//dcterms:modified", $nsCore)
  if ($createdNode)  { $createdNode.InnerText  = $createdIso }
  if ($modifiedNode) { $modifiedNode.InnerText = $modifiedIso }

  $lastPrintedNode = $coreXml.SelectSingleNode("//cp:lastPrinted", $nsCore)
  if (-not $lastPrintedNode) {
    $coreProps = $coreXml.SelectSingleNode("/*[local-name()='coreProperties']")
    if ($coreProps) {
      $lastPrintedNode = $coreXml.CreateElement("cp", "lastPrinted", "http://schemas.openxmlformats.org/package/2006/metadata/core-properties")
      $coreProps.AppendChild($lastPrintedNode) | Out-Null
    }
  }
  if ($lastPrintedNode) { $lastPrintedNode.InnerText = $printedIso }

  $totalTimeNodeCore = $coreXml.SelectSingleNode("//cp:totalTime", $nsCore)
  if ($totalTimeNodeCore) { $totalTimeNodeCore.InnerText = [string]$totalMinutes }

  try { Save-XmlUtf8NoBom -Xml $coreXml -Path $coreXmlPath }
  catch {
    $Skipped.Value += ("SKIP (core.xml write failed): " + $DocxPath + " | " + $_.Exception.Message)
    return $false
  }

  # ---- app.xml ----
  $appXmlPath = Join-Path $extractDir "docProps\app.xml"
  if (Test-Path -LiteralPath $appXmlPath) {
    try {
      [xml]$appXml = Get-Content -LiteralPath $appXmlPath -Raw
      $nsApp = New-Object System.Xml.XmlNamespaceManager($appXml.NameTable)
      $nsApp.AddNamespace("ep", "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties")

      $propsNode = $appXml.SelectSingleNode("//ep:Properties", $nsApp)
      if (-not $propsNode) { $propsNode = $appXml.SelectSingleNode("/*[local-name()='Properties']") }

      $companyNode = $appXml.SelectSingleNode("//ep:Properties/ep:Company", $nsApp)
      if (-not $companyNode) { $companyNode = $appXml.SelectSingleNode("//*[local-name()='Company']") }
      if (-not $companyNode -and $propsNode) {
        $companyNode = $appXml.CreateElement("Company", "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties")
        $propsNode.AppendChild($companyNode) | Out-Null
      }
      if ($companyNode) { $companyNode.InnerText = $CompanyName }

      $totalTimeNodeApp = $appXml.SelectSingleNode("//ep:Properties/ep:TotalTime", $nsApp)
      if (-not $totalTimeNodeApp) { $totalTimeNodeApp = $appXml.SelectSingleNode("//*[local-name()='TotalTime']") }
      if ($totalTimeNodeApp) { $totalTimeNodeApp.InnerText = [string]$totalMinutes }

      Save-XmlUtf8NoBom -Xml $appXml -Path $appXmlPath
    } catch {
      $Skipped.Value += ("WARN (app.xml update failed): " + $DocxPath + " | " + $_.Exception.Message)
    }
  }

  # ---- repack ----
  $tmpOut = Join-Path $tempRoot "out.docx"
  try {
    if (Test-Path -LiteralPath $tmpOut) { Remove-Item -LiteralPath $tmpOut -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($extractDir, $tmpOut)
  } catch {
    $Skipped.Value += ("SKIP (repack failed): " + $DocxPath + " | " + $_.Exception.Message)
    return $false
  }

  try { Copy-Item -LiteralPath $tmpOut -Destination $DocxPath -Force }
  catch {
    $Skipped.Value += ("SKIP (overwrite failed): " + $DocxPath + " | " + $_.Exception.Message)
    return $false
  }

  Set-FileSystemTimesAndOwner -Path $DocxPath -CreatedDt $createdDt -ModifiedDt $modifiedDt -Skipped $Skipped

  $CreatedDates.Value.Add($createdDt) | Out-Null

  $dispPath = $DocxPath
  try {
    $rp = [System.IO.Path]::GetFullPath($script:RootPath).TrimEnd('\\','/')
    $fp = [System.IO.Path]::GetFullPath($DocxPath)
    $prefix = $rp + "\\"
    if ($fp.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      $rel = $fp.Substring($prefix.Length)
      $dispPath = $script:RootDrive + "\\...\\" + $rel
    }
  } catch { }

  Write-Host ("OK: " + $dispPath +
              " | created=" + $createdDt +
              " | modified=" + $modifiedDt +
              " | printed=" + $printedDt +
              " | words=" + $wordCount +
              " | totalMin=" + $totalMinutes)

  try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }

  return $true
}

function Update-XlsxMetadata {
  param(
    [Parameter(Mandatory=$true)][string]$XlsxPath,
    [Parameter(Mandatory=$true)][string]$AuthorName,
    [Parameter(Mandatory=$true)][string]$CompanyName,
    [Parameter(Mandatory=$true)][int]$Year,
    [Parameter(Mandatory=$true)][int]$Month,
    [Parameter(Mandatory=$true)][datetime]$ReferenceCreated,
    [Parameter(Mandatory=$true)][hashtable]$UsedMinutesInThisMonthFolder,
    [Parameter(Mandatory=$true)][ref]$Skipped
  )

  if (-not (Test-Path -LiteralPath $XlsxPath)) {
    $Skipped.Value += ("MISSING: " + $XlsxPath)
    return $false
  }

  if (-not (Is-ZipBasedDocx -Path $XlsxPath)) {
    $Skipped.Value += ("SKIP (not zip xlsx / maybe encrypted/corrupt): " + $XlsxPath)
    return $false
  }

  $createdDt = Get-WorkTimeBeforeReference -Reference $ReferenceCreated
  $followUp = Get-FollowUpDates -Year $Year -Month $Month -CreatedDt $createdDt
  $modifiedDt = $followUp.Modified
  $printedDt = $followUp.Printed

  $candMin = Estimate-EditingMinutes -WordCount 0 -MinMinutes 150 -MaxMinutes 500
  $totalMinutes = Get-UniqueMinutes -Used $UsedMinutesInThisMonthFolder -Candidate $candMin -MinMinutes 150 -MaxMinutes 500

  $ok = Update-OpenXmlMetadata -FilePath $XlsxPath -AuthorName $AuthorName -CompanyName $CompanyName -CreatedDt $createdDt -ModifiedDt $modifiedDt -PrintedDt $printedDt -TotalMinutes $totalMinutes -Skipped $Skipped
  if (-not $ok) { return $false }

  Set-FileSystemTimesAndOwner -Path $XlsxPath -CreatedDt $createdDt -ModifiedDt $modifiedDt -Skipped $Skipped

  $dispPath = $XlsxPath
  try {
    $rp = [System.IO.Path]::GetFullPath($script:RootPath).TrimEnd('\\','/')
    $fp = [System.IO.Path]::GetFullPath($XlsxPath)
    $prefix = $rp + "\\"
    if ($fp.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      $rel = $fp.Substring($prefix.Length)
      $dispPath = $script:RootDrive + "\\...\\" + $rel
    }
  } catch { }

  Write-Host ("OK: " + $dispPath +
              " | created=" + $createdDt +
              " | modified=" + $modifiedDt +
              " | printed=" + $printedDt +
              " | totalMin=" + $totalMinutes)

  return $true
}

function Update-ExiftoolFile {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [Parameter(Mandatory=$true)][string]$AuthorName,
    [Parameter(Mandatory=$true)][string]$CompanyName,
    [Parameter(Mandatory=$true)][int]$Year,
    [Parameter(Mandatory=$true)][int]$Month,
    [Parameter(Mandatory=$true)][datetime]$CreatedDt,
    [Parameter(Mandatory=$true)][ref]$Skipped
  )

  $followUp = Get-FollowUpDates -Year $Year -Month $Month -CreatedDt $CreatedDt
  $modifiedDt = $followUp.Modified
  $printedDt = $followUp.Printed

  $ok = Update-ExiftoolMetadata -FilePath $FilePath -AuthorName $AuthorName -CompanyName $CompanyName -CreatedDt $CreatedDt -ModifiedDt $modifiedDt -PrintedDt $printedDt -Skipped $Skipped
  if (-not $ok) { return $false }

  Set-FileSystemTimesAndOwner -Path $FilePath -CreatedDt $CreatedDt -ModifiedDt $modifiedDt -Skipped $Skipped

  $dispPath = $FilePath
  try {
    $rp = [System.IO.Path]::GetFullPath($script:RootPath).TrimEnd('\\','/')
    $fp = [System.IO.Path]::GetFullPath($FilePath)
    $prefix = $rp + "\\"
    if ($fp.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      $rel = $fp.Substring($prefix.Length)
      $dispPath = $script:RootDrive + "\\...\\" + $rel
    }
  } catch { }

  Write-Host ("OK: " + $dispPath +
              " | created=" + $CreatedDt +
              " | modified=" + $modifiedDt +
              " | printed=" + $printedDt)

  return $true
}

# -----------------------------
# MAIN
# -----------------------------
Show-Header

Write-Host ""
Write-Host "Please provide the following information:" -ForegroundColor Cyan
Write-Host "-----------------------------------------------------------------------------"
$root = Prompt-NonEmpty "Enter ROOT folder path"

$script:RootPath  = $root
$script:RootDrive = (Split-Path -Path $root -Qualifier)

$year = Prompt-Year "Enter YEAR (e.g. 2025)"
$company = Prompt-NonEmpty "Enter COMPANY name"

if (-not (Test-Path -LiteralPath $root)) {
  Box-Print -Title "ERROR" -Lines @("Root folder not found:", $root)
  Read-Host "Press ENTER to exit"
  exit 1
}

Write-Host ""
Write-Host ""
Write-Host ""
Write-Host "Working with your parameters..." -ForegroundColor Cyan
Write-Host "-----------------------------------------------------------------------------"
Write-Host ("Root   : " + $root)
Write-Host ("Year   : " + $year)
Write-Host ("Company: " + $company)
Write-Host "-----------------------------------------------------------------------------"
Write-Host ""
Write-Host ""
Write-Host ""
Write-Host "Ok, now I scan for files and modify them based on the specified parameters..." -ForegroundColor Cyan
Write-Host "-----------------------------------------------------------------------------"

$skipped = @()
$okCount = 0

$mainFolders = @(Get-ChildItem -LiteralPath $root -Directory)
if ($mainFolders.Count -eq 0) {
  Box-Print -Title "INFO" -Lines @("No folders found under root.", "Nothing to do.")
  Read-Host "Press ENTER to exit"
  exit 0
}

foreach ($main in $mainFolders) {
  $author = $main.Name

  $monthFolders = @(Get-ChildItem -LiteralPath $main.FullName -Directory |
    Where-Object { (Parse-MonthFromFolderName $_.Name) -ne $null } |
    Sort-Object Name)

  if ($monthFolders.Count -eq 0) {
    Write-Host ("Skip main folder (no month folders): " + $main.FullName)
    continue
  }

  foreach ($mf in $monthFolders) {
    $month = Parse-MonthFromFolderName $mf.Name

    $docxFiles = @(Get-ChildItem -LiteralPath $mf.FullName -File -Filter "*.docx" |
      Where-Object { $_.Name -notlike "~$*" })

    if ($docxFiles.Count -eq 0) {
      Write-Host ("Skip month folder (no docx): " + $mf.FullName)
      continue
    }

    $usedMinutes = @{}
    $createdDates = New-Object System.Collections.Generic.List[datetime]

    foreach ($file in $docxFiles) {
      $ok = Update-DocxMetadata -DocxPath $file.FullName -AuthorName $author -CompanyName $company -Year $year -Month $month -UsedMinutesInThisMonthFolder $usedMinutes -Skipped ([ref]$skipped) -CreatedDates ([ref]$createdDates)
      if ($ok) { $okCount++ }
    }

    if ($createdDates.Count -eq 0) {
      $skipped += ("WARN (no successful docx dates in folder): " + $mf.FullName)
      continue
    }

    $refCreated = ($createdDates | Sort-Object)[0]

    $xlsxFiles = @(Get-ChildItem -LiteralPath $mf.FullName -File -Filter "*.xlsx" |
      Where-Object { $_.Name -notlike "~$*" })

    foreach ($file in $xlsxFiles) {
      $ok = Update-XlsxMetadata -XlsxPath $file.FullName -AuthorName $author -CompanyName $company -Year $year -Month $month -ReferenceCreated $refCreated -UsedMinutesInThisMonthFolder $usedMinutes -Skipped ([ref]$skipped)
      if ($ok) { $okCount++ }
    }

    $xlsFiles = @(Get-ChildItem -LiteralPath $mf.FullName -File -Filter "*.xls" |
      Where-Object { $_.Name -notlike "~$*" })

    foreach ($file in $xlsFiles) {
      $createdDt = Get-WorkTimeBeforeReference -Reference $refCreated
      $ok = Update-ExiftoolFile -FilePath $file.FullName -AuthorName $author -CompanyName $company -Year $year -Month $month -CreatedDt $createdDt -Skipped ([ref]$skipped)
      if ($ok) { $okCount++ }
    }

    $pdfFiles = @(Get-ChildItem -LiteralPath $mf.FullName -File -Filter "*.pdf")

    foreach ($file in $pdfFiles) {
      $createdDt = Get-WorkTimeAfterReference -Reference $refCreated
      $ok = Update-ExiftoolFile -FilePath $file.FullName -AuthorName $author -CompanyName $company -Year $year -Month $month -CreatedDt $createdDt -Skipped ([ref]$skipped)
      if ($ok) { $okCount++ }
    }

    $odfFiles = @(Get-ChildItem -LiteralPath $mf.FullName -File |
      Where-Object { $_.Extension -in @(".odt", ".ods", ".odp") })

    foreach ($file in $odfFiles) {
      $createdDt = Get-WorkTimeBeforeReference -Reference $refCreated
      $ok = Update-ExiftoolFile -FilePath $file.FullName -AuthorName $author -CompanyName $company -Year $year -Month $month -CreatedDt $createdDt -Skipped ([ref]$skipped)
      if ($ok) { $okCount++ }
    }
  }
}

Write-Host ""
Write-Host ""
Write-Host ""
Write-Host "============================================="
Write-Host "RESULTS"
Write-Host "============================================="
Write-Host ("DONE. OK files: " + $okCount + " | Skipped/Warn entries: " + (@($skipped).Count))
Write-Host "============================================="
Write-Host ""

if (@($skipped).Count -gt 0) {
  Box-Print -Title "SKIPPED / WARN FILES (review these)" -Lines $skipped
} else {
  Box-Print -Title "SKIPPED / WARN FILES" -Lines @("None. All files processed successfully.")
}

Write-Host ""
Read-Host "Press ENTER to exit"
