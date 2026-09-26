[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("Install", "Uninstall", "Check")]
    [string]$Action = "Install",

    [string]$GameRoot,

    [string]$StateDirectory,

    [switch]$SkipProcessCheck
)

# Compatibility is decided by structural features (index anchors, required asar
# entries, hotkey-binding signatures, mod markers), never by whole-file hashes,
# so Chinese-patch or game updates do not invalidate the installer.

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$Script:ScriptPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
$Script:ModDirectory = Split-Path -Parent $Script:ScriptPath
$Script:ManifestPath = Join-Path $Script:ModDirectory "mod-manifest.json"
if ($StateDirectory) {
    $Script:StateDirectory = [IO.Path]::GetFullPath($StateDirectory)
}
else {
    if (-not $env:LOCALAPPDATA) { throw "LOCALAPPDATA is unavailable; pass -StateDirectory explicitly." }
    $Script:StateDirectory = Join-Path $env:LOCALAPPDATA "AntimatterDimensionsHoldKeysMod"
}
$Script:StatePath = Join-Path $Script:StateDirectory "state.json"
$Script:StateOriginalMainPath = Join-Path $Script:StateDirectory "original-main.js"
$Script:SafetyBackupPath = Join-Path $Script:StateDirectory "pre-install-app.asar.bak"
$Script:ProcessName = "Antimatter Dimensions"
$Script:Utf8 = New-Object Text.UTF8Encoding($false)
$Script:ModEntryPaths = @("AppFiles/js/hold-keys-main.js", "AppFiles/js/hold-keys.js", "AppFiles/stylesheets/hold-keys.css")

function Write-Step {
    param([string]$Message)
    Write-Host "[AD HoldKeys] $Message"
}

function Write-Warning-Step {
    param([string]$Message)
    Write-Host "[AD HoldKeys] WARNING: $Message" -ForegroundColor Yellow
}

function Write-Failure {
    param([string]$Message)
    Write-Host "[AD HoldKeys] ERROR: $Message" -ForegroundColor Red
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace("-", "")
    }
    finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Get-BytesSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace("-", "")
    }
    finally {
        $algorithm.Dispose()
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $encoding = New-Object Text.UTF8Encoding($false, $true)
    return ([IO.File]::ReadAllText($Path, $encoding) | ConvertFrom-Json)
}

function Write-JsonFileAtomic {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporary = Join-Path $directory (".{0}.{1}.tmp" -f (Split-Path -Leaf $Path), [Guid]::NewGuid().ToString("N"))
    try {
        $json = $Value | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                $rollback = Join-Path $directory (".state-rollback-{0}.json" -f [Guid]::NewGuid().ToString("N"))
                [IO.File]::Replace($temporary, $Path, $rollback, $true)
                if (Test-Path -LiteralPath $rollback -PathType Leaf) {
                    Remove-Item -LiteralPath $rollback -Force
                }
            }
            catch [IO.IOException] {
                if (-not (Test-Path -LiteralPath $temporary -PathType Leaf)) { throw }
                [IO.File]::Copy($temporary, $Path, $true)
            }
        }
        else {
            [IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-ExistingState {
    if (-not (Test-Path -LiteralPath $Script:StatePath -PathType Leaf)) { return $null }
    return Read-JsonFile -Path $Script:StatePath
}

function Get-NormalizedFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return ([IO.Path]::GetFullPath($Path)).TrimEnd([char[]]@('\', '/'))
}

function Resolve-GameRoot {
    param([string]$RequestedRoot)

    if (-not $RequestedRoot) {
        $RequestedRoot = Split-Path -Parent $Script:ModDirectory
    }

    $resolved = Get-NormalizedFullPath -Path $RequestedRoot
    if (Test-Path -LiteralPath $resolved -PathType Leaf) {
        if ((Split-Path -Leaf $resolved) -ieq "Antimatter Dimensions.exe") {
            $resolved = Split-Path -Parent $resolved
        }
        elseif ((Split-Path -Leaf $resolved) -ieq "app.asar") {
            $resolved = Split-Path -Parent (Split-Path -Parent $resolved)
        }
        else {
            throw "The selected file is not the game executable or resources/app.asar: $resolved"
        }
    }
    elseif (Test-Path -LiteralPath $resolved -PathType Container) {
        if ((Split-Path -Leaf $resolved) -ieq "resources") {
            $resolved = Split-Path -Parent $resolved
        }
    }
    else {
        throw "Game path does not exist: $resolved"
    }

    $exePath = Join-Path $resolved "Antimatter Dimensions.exe"
    $asarPath = Join-Path $resolved "resources\app.asar"
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $asarPath -PathType Leaf)) {
        throw "The selected directory is not a supported Antimatter Dimensions installation: $resolved"
    }
    return $resolved
}

function Assert-PayloadIntegrity {
    $items = @()
    foreach ($payload in @($Script:Manifest.payload)) { $items += $payload }
    if ($Script:Manifest.PSObject.Properties["originalFiles"]) {
        foreach ($original in @($Script:Manifest.originalFiles)) { $items += $original }
    }
    foreach ($item in $items) {
        $source = Join-Path $Script:ModDirectory ([string]$item.source)
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Mod payload is missing: $source"
        }
        $diskItem = Get-Item -LiteralPath $source
        if ([int64]$diskItem.Length -ne [int64]$item.size) {
            throw "Mod payload size failed verification: $($item.source)"
        }
        $actual = Get-Sha256 -Path $source
        if ($actual -ne ([string]$item.sha256).ToUpperInvariant()) {
            throw "Mod payload failed SHA-256 verification: $($item.source)"
        }
    }
}

function Read-AsarHeader {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $reader = New-Object IO.BinaryReader($stream, (New-Object Text.UTF8Encoding($false)), $true)
    try {
        if ($stream.Length -lt 16) { throw "ASAR is too small to contain a valid header." }
        $pickleLength = $reader.ReadUInt32()
        $headerPayloadLength = $reader.ReadUInt32()
        $stringPayloadLength = $reader.ReadUInt32()
        $jsonLength = $reader.ReadUInt32()
        if ($pickleLength -ne 4 -or $jsonLength -lt 2 -or $jsonLength -gt 104857600) {
            throw "ASAR header fields are invalid."
        }
        $paddedJsonLength = [int](($jsonLength + 3) -band -4)
        $dataOffset = 16L + $paddedJsonLength
        if ($headerPayloadLength -ne (8 + $paddedJsonLength) -or
            $stringPayloadLength -ne (4 + $paddedJsonLength) -or
            $dataOffset -gt $stream.Length) {
            throw "ASAR pickle lengths are inconsistent."
        }
        $jsonBytes = $reader.ReadBytes([int]$jsonLength)
        if ($jsonBytes.Length -ne $jsonLength) { throw "ASAR header is truncated." }
        $json = (New-Object Text.UTF8Encoding($false)).GetString($jsonBytes)
        return [pscustomobject]@{
            Tree = $json | ConvertFrom-Json
            DataOffset = $dataOffset
            JsonLength = [int]$jsonLength
            ArchiveLength = $stream.Length
        }
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Get-AsarEntry {
    param(
        [Parameter(Mandatory = $true)][object]$Tree,
        [Parameter(Mandatory = $true)][string]$ArchivePath
    )
    $parts = @(@($ArchivePath -split '[\\/]') | Where-Object { $_ })
    $files = $Tree.files
    for ($index = 0; $index -lt $parts.Count; $index += 1) {
        $property = $files.PSObject.Properties[$parts[$index]]
        if (-not $property) { return $null }
        $entry = $property.Value
        if ($index -eq $parts.Count - 1) { return $entry }
        $childFiles = $entry.PSObject.Properties["files"]
        if (-not $childFiles) { return $null }
        $files = $childFiles.Value
    }
    return $null
}

function Set-AsarEntry {
    param(
        [Parameter(Mandatory = $true)][object]$Tree,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][object]$Entry
    )
    $parts = @(@($ArchivePath -split '[\\/]') | Where-Object { $_ })
    $files = $Tree.files
    for ($index = 0; $index -lt $parts.Count - 1; $index += 1) {
        $property = $files.PSObject.Properties[$parts[$index]]
        if (-not $property) {
            $directoryEntry = [pscustomobject]@{ files = [pscustomobject]@{} }
            $files | Add-Member -MemberType NoteProperty -Name $parts[$index] -Value $directoryEntry
            $property = $files.PSObject.Properties[$parts[$index]]
        }
        $childFiles = $property.Value.PSObject.Properties["files"]
        if (-not $childFiles) {
            throw "ASAR path collides with a file while adding $ArchivePath"
        }
        $files = $childFiles.Value
    }
    $leaf = $parts[$parts.Count - 1]
    $existing = $files.PSObject.Properties[$leaf]
    if ($existing) {
        $existing.Value = $Entry
    }
    else {
        $files | Add-Member -MemberType NoteProperty -Name $leaf -Value $Entry
    }
}

function Remove-AsarEntry {
    param(
        [Parameter(Mandatory = $true)][object]$Tree,
        [Parameter(Mandatory = $true)][string]$ArchivePath
    )
    $parts = @(@($ArchivePath -split '[\\/]') | Where-Object { $_ })
    $files = $Tree.files
    for ($index = 0; $index -lt $parts.Count - 1; $index += 1) {
        $property = $files.PSObject.Properties[$parts[$index]]
        if (-not $property) { return }
        $childFiles = $property.Value.PSObject.Properties["files"]
        if (-not $childFiles) { return }
        $files = $childFiles.Value
    }
    $leaf = $parts[$parts.Count - 1]
    $files.PSObject.Properties.Remove($leaf) | Out-Null
}

function Read-AsarFileBytes {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][object]$Header,
        [Parameter(Mandatory = $true)][string]$InternalPath
    )
    $entry = Get-AsarEntry -Tree $Header.Tree -ArchivePath $InternalPath
    if (-not $entry) { throw "Packed ASAR file was not found: $InternalPath" }
    $unpackedProperty = $entry.PSObject.Properties["unpacked"]
    $offsetProperty = $entry.PSObject.Properties["offset"]
    $sizeProperty = $entry.PSObject.Properties["size"]
    if (($unpackedProperty -and [bool]$unpackedProperty.Value) -or -not $offsetProperty -or -not $sizeProperty) {
        throw "Packed ASAR file was not found: $InternalPath"
    }
    $size = [int64]$sizeProperty.Value
    if ($size -gt [int]::MaxValue) { throw "ASAR entry is too large to read: $InternalPath" }
    $stream = [IO.File]::Open($ArchivePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $stream.Position = [int64]$Header.DataOffset + [int64]([string]$offsetProperty.Value)
        $bytes = New-Object byte[] ([int]$size)
        $read = 0
        while ($read -lt $bytes.Length) {
            $count = $stream.Read($bytes, $read, $bytes.Length - $read)
            if ($count -le 0) { throw "ASAR entry is truncated: $InternalPath" }
            $read += $count
        }
        return ,$bytes
    }
    finally {
        $stream.Dispose()
    }
}

function Read-AsarText {
    param(
        [Parameter(Mandatory = $true)][string]$AsarPath,
        [Parameter(Mandatory = $true)][object]$Header,
        [Parameter(Mandatory = $true)][string]$InternalPath
    )
    $bytes = Read-AsarFileBytes -ArchivePath $AsarPath -Header $Header -InternalPath $InternalPath
    return $Script:Utf8.GetString($bytes)
}

function Copy-StreamRange {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$SourceStream,
        [Parameter(Mandatory = $true)][IO.Stream]$DestinationStream,
        [Parameter(Mandatory = $true)][int64]$Count
    )
    $buffer = New-Object byte[] 1048576
    $remaining = $Count
    while ($remaining -gt 0) {
        $wanted = [int][Math]::Min($buffer.Length, $remaining)
        $read = $SourceStream.Read($buffer, 0, $wanted)
        if ($read -le 0) { throw "Unexpected end of ASAR data while copying." }
        $DestinationStream.Write($buffer, 0, $read)
        $remaining -= $read
    }
}

function Copy-FileBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $input = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $output = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $input.CopyTo($output)
    }
    finally {
        $output.Dispose()
        $input.Dispose()
    }
}

function Replace-FileAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Replacement,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $directory = Split-Path -Parent $Destination
    $rollback = Join-Path $directory (".ad-holdkeys-rollback-{0}.asar" -f [Guid]::NewGuid().ToString("N"))
    [IO.File]::Replace($Replacement, $Destination, $rollback, $true)
    if (Test-Path -LiteralPath $rollback -PathType Leaf) {
        Remove-Item -LiteralPath $rollback -Force
    }
}

function Assert-GameNotRunning {
    if ($SkipProcessCheck) { return }
    $running = @(Get-Process -Name $Script:ProcessName -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        throw "Antimatter Dimensions is running. Fully exit the game and run this action again."
    }
}

function Get-VerifiedPayloadBytes {
    param([Parameter(Mandatory = $true)][string]$ArchivePath)
    foreach ($payload in @($Script:Manifest.payload)) {
        if ([string]$payload.archivePath -ne $ArchivePath) { continue }
        $source = Join-Path $Script:ModDirectory ([string]$payload.source)
        $bytes = [IO.File]::ReadAllBytes($source)
        if ($bytes.LongLength -ne [int64]$payload.size) {
            throw "Payload size failed verification: $($payload.source)"
        }
        if ((Get-BytesSha256 -Bytes $bytes) -ne ([string]$payload.sha256).ToUpperInvariant()) {
            throw "Payload failed SHA-256 verification: $($payload.source)"
        }
        return ,$bytes
    }
    throw "Manifest payload entry was not found: $ArchivePath"
}

function Get-VerifiedOriginalMainBytes {
    $original = $null
    foreach ($item in @($Script:Manifest.originalFiles)) {
        if ([string]$item.archivePath -eq "main.js") { $original = $item; break }
    }
    if (-not $original) { throw "Manifest has no original main.js copy to restore." }
    $source = Join-Path $Script:ModDirectory ([string]$original.source)
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Original main.js copy is missing: $source" }
    $bytes = [IO.File]::ReadAllBytes($source)
    if ($bytes.LongLength -ne [int64]$original.size) { throw "Original main.js copy failed size verification." }
    if ((Get-BytesSha256 -Bytes $bytes) -ne ([string]$original.sha256).ToUpperInvariant()) {
        throw "Original main.js copy failed SHA-256 verification."
    }
    return ,$bytes
}

function Test-HotkeySignatures {
    param([Parameter(Mandatory = $true)][string]$AppJsText)
    $missing = @()
    foreach ($signature in @($Script:Manifest.compat.hotkeySignatures)) {
        if (-not $AppJsText.Contains([string]$signature)) { $missing += [string]$signature }
    }
    return $missing
}

function Get-ModFingerprint {
    param([Parameter(Mandatory = $true)][string]$AsarPath)

    $header = Read-AsarHeader -Path $AsarPath
    $fingerprint = [pscustomobject]@{
        Header = $header
        Marker = $null
        GameVersion = $null
        ZhPatchPresent = $false
        MainJsModded = $false
        ModEntries = @()
        MissingRequired = @()
        MissingHotkeySignatures = @()
    }

    foreach ($required in @($Script:Manifest.compat.requiredEntries)) {
        if (-not (Get-AsarEntry -Tree $header.Tree -ArchivePath ([string]$required))) {
            $fingerprint.MissingRequired = @($fingerprint.MissingRequired + [string]$required)
        }
    }

    $indexEntry = Get-AsarEntry -Tree $header.Tree -ArchivePath "AppFiles/index.html"
    if ($indexEntry) {
        $indexText = Read-AsarText -AsarPath $AsarPath -Header $header -InternalPath "AppFiles/index.html"
        $markerMatch = [regex]::Match($indexText, "AD-HOLDKEYS-MOD:[0-9][0-9.]*")
        if ($markerMatch.Success) { $fingerprint.Marker = $markerMatch.Value }
        $fingerprint.ZhPatchPresent = $indexText.Contains("AD-ZH-CN-PATCH:")
    }

    $versionFile = [string]$Script:Manifest.game.versionFile
    if (Get-AsarEntry -Tree $header.Tree -ArchivePath $versionFile) {
        $versionText = (Read-AsarText -AsarPath $AsarPath -Header $header -InternalPath $versionFile).Trim()
        try {
            $versionJson = $versionText | ConvertFrom-Json
            if ($versionJson -and $versionJson.PSObject.Properties["version"]) {
                $versionText = [string]$versionJson.version
            }
        }
        catch {
            # version.txt is not JSON; use the raw text.
        }
        $fingerprint.GameVersion = $versionText
    }

    if (Get-AsarEntry -Tree $header.Tree -ArchivePath "main.js") {
        $mainText = Read-AsarText -AsarPath $AsarPath -Header $header -InternalPath "main.js"
        $fingerprint.MainJsModded = $mainText.Contains("hold-keys-main")
    }

    foreach ($entryPath in $Script:ModEntryPaths) {
        if (Get-AsarEntry -Tree $header.Tree -ArchivePath $entryPath) {
            $fingerprint.ModEntries = @($fingerprint.ModEntries + $entryPath)
        }
    }

    if ($fingerprint.MissingRequired.Count -eq 0) {
        $appJsText = Read-AsarText -AsarPath $AsarPath -Header $header -InternalPath "AppFiles/js/app.js"
        $fingerprint.MissingHotkeySignatures = @(Test-HotkeySignatures -AppJsText $appJsText)
    }

    return $fingerprint
}

function Get-PayloadMismatches {
    param(
        [Parameter(Mandatory = $true)][string]$AsarPath,
        [Parameter(Mandatory = $true)][object]$Header
    )
    $mismatches = @()
    foreach ($payload in @($Script:Manifest.payload)) {
        $entry = Get-AsarEntry -Tree $Header.Tree -ArchivePath ([string]$payload.archivePath)
        $ok = $entry -ne $null -and [int64]$entry.size -eq [int64]$payload.size
        if ($ok) {
            $bytes = Read-AsarFileBytes -ArchivePath $AsarPath -Header $Header -InternalPath ([string]$payload.archivePath)
            $ok = (Get-BytesSha256 -Bytes $bytes) -eq ([string]$payload.sha256).ToUpperInvariant()
        }
        if (-not $ok) { $mismatches = @($mismatches + [string]$payload.archivePath) }
    }
    return $mismatches
}

function ConvertTo-ModdedMainJsText {
    param([Parameter(Mandatory = $true)][string]$Text)
    if ($Text.Contains("hold-keys-main")) { throw "main.js already contains HoldKeys hooks." }

    if ($Text.Contains("`r`n")) { $nl = "`r`n" } else { $nl = "`n" }

    $requireAnchor = "const path = require('path')"
    $commentAnchor = "  // and load the index.html of the app."
    if (-not $Text.Contains($requireAnchor)) { throw "main.js anchor was not found: '$requireAnchor'." }
    if (-not $Text.Contains($commentAnchor)) { throw "main.js anchor was not found: '$commentAnchor'." }

    $hookBlock = "const holdKeysMain = require('./AppFiles/js/hold-keys-main')" + $nl +
        $nl +
        "app.commandLine.appendSwitch('disable-background-timer-throttling')" + $nl +
        "app.commandLine.appendSwitch('disable-renderer-backgrounding')" + $nl +
        "app.commandLine.appendSwitch('disable-backgrounding-occluded-windows')" + $nl +
        "holdKeysMain.install()" + $nl
    $attachBlock = "  holdKeysMain.attachWindow(mainWindow)" + $nl + $nl

    $Text = $Text.Replace($requireAnchor + $nl, $requireAnchor + $nl + $hookBlock)
    $Text = $Text.Replace($commentAnchor, $attachBlock + $commentAnchor)

    if (-not $Text.Contains("holdKeysMain.install()") -or
        -not $Text.Contains("holdKeysMain.attachWindow(mainWindow)")) {
        throw "main.js hook injection failed verification."
    }
    return $Text
}

function ConvertTo-OriginalMainJsText {
    param([Parameter(Mandatory = $true)][string]$Text)
    $requireHook = "const holdKeysMain = require('./AppFiles/js/hold-keys-main')"
    if (-not $Text.Contains($requireHook) -or
        -not $Text.Contains("holdKeysMain.install()") -or
        -not $Text.Contains("holdKeysMain.attachWindow(mainWindow)")) {
        throw "main.js does not match the known HoldKeys hook pattern."
    }

    $requirePattern = [regex]::Escape($requireHook) +
        "\r?\n\r?\napp\.commandLine\.appendSwitch\('disable-background-timer-throttling'\)\r?\n" +
        "app\.commandLine\.appendSwitch\('disable-renderer-backgrounding'\)\r?\n" +
        "app\.commandLine\.appendSwitch\('disable-backgrounding-occluded-windows'\)\r?\n" +
        "holdKeysMain\.install\(\)\r?\n"
    $Text = [regex]::Replace($Text, $requirePattern, "")
    $Text = [regex]::Replace($Text, "[ \t]*holdKeysMain\.attachWindow\(mainWindow\)\r?\n\r?\n", "")

    if ($Text.Contains("hold-keys")) { throw "HoldKeys remnants remain in main.js after stripping." }
    if (-not $Text.Contains("function createWindow")) { throw "Stripped main.js failed a sanity check." }
    return $Text
}

function ConvertTo-PatchedIndexText {
    param([Parameter(Mandatory = $true)][string]$Html)
    if ($Html.Contains("AD-HOLDKEYS-MOD:")) { throw "index.html already contains a HoldKeys marker." }
    if ($Html.Contains("js/hold-keys.js") -or $Html.Contains("stylesheets/hold-keys.css")) {
        throw "index.html already references HoldKeys assets."
    }

    if ($Html.Contains("`r`n")) { $nl = "`r`n" } else { $nl = "`n" }
    $markerComment = "  <!-- " + [string]$Script:Manifest.indexMarker + " -->"
    $scriptAnchor = [string]$Script:Manifest.compat.scriptAnchor
    if (-not $Html.Contains($scriptAnchor)) {
        throw ("The game script anchor was not found in index.html: " + $scriptAnchor)
    }
    $Html = $Html.Replace($scriptAnchor, $scriptAnchor + $nl + $markerComment + $nl + "  " + [string]$Script:Manifest.compat.modScriptTag)

    $styleAnchor = [string]$Script:Manifest.compat.styleAnchor
    if (-not $Html.Contains($styleAnchor)) {
        throw ("The style anchor was not found in index.html: " + $styleAnchor)
    }
    $Html = $Html.Replace($styleAnchor, "  " + [string]$Script:Manifest.compat.modStyleTag + $nl + $styleAnchor)
    return $Html
}

function ConvertTo-UpgradedIndexText {
    param(
        [Parameter(Mandatory = $true)][string]$Html,
        [Parameter(Mandatory = $true)][string]$FromMarker
    )
    $oldComment = "<!-- " + $FromMarker + " -->"
    $newComment = "<!-- " + [string]$Script:Manifest.indexMarker + " -->"
    $count = [regex]::Matches($Html, [regex]::Escape($oldComment)).Count
    if ($count -ne 1) {
        throw ("Expected exactly one '{0}' comment in index.html, found {1}." -f $oldComment, $count)
    }
    return $Html.Replace($oldComment, $newComment)
}

function ConvertTo-StrippedIndexText {
    param([Parameter(Mandatory = $true)][string]$Html)
    $scriptPattern = '\r?\n[ \t]*<!-- AD-HOLDKEYS-MOD:[0-9.]+ -->\r?\n[ \t]*<script defer src="js/hold-keys\.js"></script>'
    $linkPattern = '[ \t]*<link rel="stylesheet" type="text/css" href="stylesheets/hold-keys\.css">\r?\n'
    $Html = [regex]::Replace($Html, $scriptPattern, "")
    $Html = [regex]::Replace($Html, $linkPattern, "")
    if ($Html.Contains("AD-HOLDKEYS-MOD:") -or $Html.Contains("hold-keys")) {
        throw "Unrecognized HoldKeys remnants remain in index.html; refusing to finish the uninstall."
    }
    return $Html
}

function Build-AsarVariant {
    param(
        [Parameter(Mandatory = $true)][string]$SourceAsar,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][byte[]]$IndexBytes,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$EntryUpdates
    )
    Assert-PayloadIntegrity
    $header = Read-AsarHeader -Path $SourceAsar
    $originalDataLength = [int64]$header.ArchiveLength - [int64]$header.DataOffset

    $appendItems = New-Object Collections.ArrayList
    [void]$appendItems.Add([pscustomobject]@{ ArchivePath = "AppFiles/index.html"; Bytes = $IndexBytes })
    foreach ($update in $EntryUpdates) {
        if ([bool]$update.Remove) {
            Remove-AsarEntry -Tree $header.Tree -ArchivePath ([string]$update.ArchivePath)
        }
        else {
            [void]$appendItems.Add([pscustomobject]@{
                ArchivePath = [string]$update.ArchivePath
                Bytes = [byte[]]$update.Bytes
            })
        }
    }

    $nextOffset = $originalDataLength
    foreach ($item in $appendItems) {
        $entry = [pscustomobject]@{
            size = [int64]$item.Bytes.LongLength
            offset = $nextOffset.ToString([Globalization.CultureInfo]::InvariantCulture)
        }
        Set-AsarEntry -Tree $header.Tree -ArchivePath $item.ArchivePath -Entry $entry
        $nextOffset += [int64]$item.Bytes.LongLength
    }

    $headerJson = $header.Tree | ConvertTo-Json -Depth 100 -Compress
    $headerBytes = $Script:Utf8.GetBytes($headerJson)
    $paddedLength = [int](($headerBytes.Length + 3) -band -4)

    $input = [IO.File]::Open($SourceAsar, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $output = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = New-Object IO.BinaryWriter($output, $Script:Utf8, $true)
    try {
        $writer.Write([uint32]4)
        $writer.Write([uint32](8 + $paddedLength))
        $writer.Write([uint32](4 + $paddedLength))
        $writer.Write([uint32]$headerBytes.Length)
        $writer.Write($headerBytes)
        if ($paddedLength -gt $headerBytes.Length) {
            $writer.Write((New-Object byte[] ($paddedLength - $headerBytes.Length)))
        }
        $writer.Flush()

        $input.Position = [int64]$header.DataOffset
        Copy-StreamRange -SourceStream $input -DestinationStream $output -Count $originalDataLength
        foreach ($item in $appendItems) {
            $output.Write($item.Bytes, 0, $item.Bytes.Length)
        }
        $output.Flush()
    }
    finally {
        $writer.Dispose()
        $output.Dispose()
        $input.Dispose()
    }
}

function Assert-InstalledAsar {
    param([Parameter(Mandatory = $true)][string]$Path)
    $header = Read-AsarHeader -Path $Path
    $requiredList = @(@($Script:Manifest.compat.requiredEntries) + $Script:ModEntryPaths)
    foreach ($required in $requiredList) {
        if (-not (Get-AsarEntry -Tree $header.Tree -ArchivePath ([string]$required))) {
            throw "Generated ASAR is missing a required game file: $required"
        }
    }
    $indexText = Read-AsarText -AsarPath $Path -Header $header -InternalPath "AppFiles/index.html"
    if (-not $indexText.Contains([string]$Script:Manifest.indexMarker)) {
        throw "Generated ASAR does not contain the mod marker."
    }
    if (-not $indexText.Contains("js/hold-keys.js") -or -not $indexText.Contains("stylesheets/hold-keys.css")) {
        throw "Generated ASAR index does not reference the mod assets."
    }
    foreach ($payload in @($Script:Manifest.payload)) {
        $entry = Get-AsarEntry -Tree $header.Tree -ArchivePath ([string]$payload.archivePath)
        if (-not $entry -or [int64]$entry.size -ne [int64]$payload.size) {
            throw "Generated ASAR has an invalid payload entry: $($payload.archivePath)"
        }
        $bytes = Read-AsarFileBytes -ArchivePath $Path -Header $header -InternalPath ([string]$payload.archivePath)
        if ((Get-BytesSha256 -Bytes $bytes) -ne ([string]$payload.sha256).ToUpperInvariant()) {
            throw "Generated ASAR failed payload verification: $($payload.archivePath)"
        }
    }
    $mainText = Read-AsarText -AsarPath $Path -Header $header -InternalPath "main.js"
    if (-not $mainText.Contains("holdKeysMain.install()") -or
        -not $mainText.Contains("holdKeysMain.attachWindow(mainWindow)")) {
        throw "Generated ASAR main.js does not contain the HoldKeys hooks."
    }
}

function Assert-StrippedAsar {
    param([Parameter(Mandatory = $true)][string]$Path)
    $header = Read-AsarHeader -Path $Path
    foreach ($required in @($Script:Manifest.compat.requiredEntries)) {
        if (-not (Get-AsarEntry -Tree $header.Tree -ArchivePath ([string]$required))) {
            throw "Stripped ASAR is missing a required game file: $required"
        }
    }
    foreach ($entryPath in $Script:ModEntryPaths) {
        if (Get-AsarEntry -Tree $header.Tree -ArchivePath $entryPath) {
            throw "Stripped ASAR still contains a mod entry: $entryPath"
        }
    }
    $indexText = Read-AsarText -AsarPath $Path -Header $header -InternalPath "AppFiles/index.html"
    if ($indexText.Contains("AD-HOLDKEYS-MOD:") -or $indexText.Contains("hold-keys")) {
        throw "Stripped ASAR still contains HoldKeys references in index.html."
    }
    $mainText = Read-AsarText -AsarPath $Path -Header $header -InternalPath "main.js"
    if ($mainText.Contains("hold-keys")) {
        throw "Stripped ASAR still contains HoldKeys hooks in main.js."
    }
}

function New-SafetyBackup {
    param([Parameter(Mandatory = $true)][string]$AsarPath)
    if (Test-Path -LiteralPath $Script:SafetyBackupPath -PathType Leaf) {
        Write-Step "A safety backup of a previous app.asar already exists: $Script:SafetyBackupPath"
        return
    }
    if (-not (Test-Path -LiteralPath $Script:StateDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $Script:StateDirectory -Force | Out-Null
    }
    Write-Step "Creating a one-time full backup of the current app.asar..."
    $sourceHash = Get-Sha256 -Path $AsarPath
    Copy-FileBytes -Source $AsarPath -Destination $Script:SafetyBackupPath
    if ((Get-Sha256 -Path $Script:SafetyBackupPath) -ne $sourceHash) {
        throw "Safety backup failed SHA-256 verification."
    }
}

function Write-StateOriginalMain {
    param([Parameter(Mandatory = $true)][string]$OriginalText)
    if ($OriginalText.Contains("hold-keys")) {
        throw "Refusing to store a main.js copy that still contains HoldKeys hooks."
    }
    if (-not (Test-Path -LiteralPath $Script:StateDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $Script:StateDirectory -Force | Out-Null
    }
    [IO.File]::WriteAllText($Script:StateOriginalMainPath, $OriginalText, $Script:Utf8)
    return (Get-Sha256 -Path $Script:StateOriginalMainPath)
}

function Write-ModState {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedGameRoot,
        [Parameter(Mandatory = $true)][string]$AsarPath,
        [Parameter(Mandatory = $true)][string]$IndexStyle,
        [AllowNull()][string]$OriginalMainSha256,
        [Parameter(Mandatory = $true)][string]$Status
    )
    $existing = Get-ExistingState
    $installedAt = [DateTime]::UtcNow.ToString("o")
    if ($existing -and $existing.PSObject.Properties["installedAt"] -and $existing.installedAt) {
        $installedAt = [string]$existing.installedAt
    }
    $state = [pscustomobject]@{
        schemaVersion = 2
        modVersion = [string]$Script:Manifest.modVersion
        gameRoot = $ResolvedGameRoot
        asarPath = $AsarPath
        indexMarker = [string]$Script:Manifest.indexMarker
        indexStyle = $IndexStyle
        originalMainSha256 = $OriginalMainSha256
        status = $Status
        installedAt = $installedAt
        updatedAt = [DateTime]::UtcNow.ToString("o")
    }
    Write-JsonFileAtomic -Value $state -Path $Script:StatePath
    return $state
}

function Install-AlreadyCurrent {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedGameRoot,
        [Parameter(Mandatory = $true)][string]$AsarPath,
        [Parameter(Mandatory = $true)][object]$Fingerprint
    )
    $mismatches = @(Get-PayloadMismatches -AsarPath $AsarPath -Header $Fingerprint.Header)
    if ($mismatches.Count -gt 0) {
        throw ("This HoldKeys version is installed, but these entries do not match the manifest: " +
            ($mismatches -join ", ") + ". Run the uninstaller first.")
    }
    if (-not $Fingerprint.MainJsModded) {
        throw "index.html has the current marker, but main.js is missing the HoldKeys hooks. Run the uninstaller first."
    }
    $existing = Get-ExistingState
    $indexStyle = "unknown"
    if ($existing -and $existing.PSObject.Properties["indexStyle"] -and $existing.indexStyle) {
        $indexStyle = [string]$existing.indexStyle
    }
    $originalMainSha = $null
    if ((Test-Path -LiteralPath $Script:StateOriginalMainPath -PathType Leaf) -and
        $existing -and $existing.PSObject.Properties["originalMainSha256"] -and $existing.originalMainSha256) {
        if ((Get-Sha256 -Path $Script:StateOriginalMainPath) -eq ([string]$existing.originalMainSha256).ToUpperInvariant()) {
            $originalMainSha = [string]$existing.originalMainSha256
        }
    }
    Write-ModState -ResolvedGameRoot $ResolvedGameRoot -AsarPath $AsarPath -IndexStyle $indexStyle -OriginalMainSha256 $originalMainSha -Status "installed"
    Write-Step "The HoldKeys mod is already installed at this version."
}

function Install-Upgrade {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedGameRoot,
        [Parameter(Mandatory = $true)][string]$AsarPath,
        [Parameter(Mandatory = $true)][object]$Fingerprint
    )
    Write-Step ("Upgrading in place from {0} to {1}..." -f $Fingerprint.Marker, $Script:Manifest.indexMarker)

    foreach ($entryPath in $Script:ModEntryPaths) {
        if (-not (Get-AsarEntry -Tree $Fingerprint.Header.Tree -ArchivePath $entryPath)) {
            throw "Cannot upgrade: existing mod entry is missing: $entryPath"
        }
    }
    if (-not $Fingerprint.MainJsModded) {
        throw "Cannot upgrade: main.js is missing the HoldKeys hooks."
    }

    New-SafetyBackup -AsarPath $AsarPath

    $indexText = Read-AsarText -AsarPath $AsarPath -Header $Fingerprint.Header -InternalPath "AppFiles/index.html"
    $upgradedIndexText = ConvertTo-UpgradedIndexText -Html $indexText -FromMarker ([string]$Fingerprint.Marker)

    $mainText = Read-AsarText -AsarPath $AsarPath -Header $Fingerprint.Header -InternalPath "main.js"
    $originalMainSha = $null
    try {
        if ($mainText.Contains("hold-keys-main")) {
            $originalMainText = ConvertTo-OriginalMainJsText -Text $mainText
        }
        else {
            $originalMainText = $mainText
        }
        $originalMainSha = Write-StateOriginalMain -OriginalText $originalMainText
    }
    catch {
        Write-Warning-Step ("Could not pre-compute an original main.js copy for future uninstalls: {0}" -f $_.Exception.Message)
    }

    $updates = @(
        [pscustomobject]@{ ArchivePath = "AppFiles/js/hold-keys.js"; Bytes = (Get-VerifiedPayloadBytes -ArchivePath "AppFiles/js/hold-keys.js"); Remove = $false },
        [pscustomobject]@{ ArchivePath = "AppFiles/stylesheets/hold-keys.css"; Bytes = (Get-VerifiedPayloadBytes -ArchivePath "AppFiles/stylesheets/hold-keys.css"); Remove = $false }
    )

    $resources = Split-Path -Parent $AsarPath
    $temporary = Join-Path $resources (".app.asar.holdkeys.{0}.tmp" -f [Guid]::NewGuid().ToString("N"))
    try {
        Write-Step "Building the upgraded app.asar..."
        Build-AsarVariant -SourceAsar $AsarPath -OutputPath $temporary -IndexBytes $Script:Utf8.GetBytes($upgradedIndexText) -EntryUpdates $updates
        Assert-InstalledAsar -Path $temporary
        $patchedHash = Get-Sha256 -Path $temporary
        [void](Write-ModState -ResolvedGameRoot $ResolvedGameRoot -AsarPath $AsarPath -IndexStyle "upgraded" -OriginalMainSha256 $originalMainSha -Status "installing")

        Write-Step "Installing the upgraded app.asar..."
        Replace-FileAtomically -Replacement $temporary -Destination $AsarPath
        if ((Get-Sha256 -Path $AsarPath) -ne $patchedHash) {
            throw "Installed app.asar failed final SHA-256 verification."
        }
        [void](Write-ModState -ResolvedGameRoot $ResolvedGameRoot -AsarPath $AsarPath -IndexStyle "upgraded" -OriginalMainSha256 $originalMainSha -Status "installed")
        Write-Step ("Upgrade complete. Start the game and use F6/F7/F8/F9/F11/F12, or the on-screen panel.")
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Install-Fresh {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedGameRoot,
        [Parameter(Mandatory = $true)][string]$AsarPath,
        [Parameter(Mandatory = $true)][object]$Fingerprint
    )
    Write-Step "Installing fresh (feature-based compatibility check)..."

    if ($Fingerprint.MissingHotkeySignatures.Count -gt 0) {
        throw ("This game build does not expose the required hotkey bindings " +
                "(missing in AppFiles/js/app.js: " + ($Fingerprint.MissingHotkeySignatures -join ", ") + ").")
    }
    $expectedVersion = [string]$Script:Manifest.game.expectedVersion
    if ($Fingerprint.GameVersion -and $Fingerprint.GameVersion -ne $expectedVersion) {
        Write-Warning-Step ("Game version {0} differs from the tested version {1}; continuing because all structural checks passed." -f $Fingerprint.GameVersion, $expectedVersion)
    }

    New-SafetyBackup -AsarPath $AsarPath

    $mainText = Read-AsarText -AsarPath $AsarPath -Header $Fingerprint.Header -InternalPath "main.js"
    if ($mainText.Contains("hold-keys-main")) {
        throw "main.js already contains HoldKeys hooks. Run the uninstaller first."
    }
    $moddedMainText = ConvertTo-ModdedMainJsText -Text $mainText

    $indexText = Read-AsarText -AsarPath $AsarPath -Header $Fingerprint.Header -InternalPath "AppFiles/index.html"
    if ($indexText.Contains("js/hold-keys.js") -or $indexText.Contains("stylesheets/hold-keys.css")) {
        throw "index.html already references HoldKeys assets. Run the uninstaller first."
    }
    $patchedIndexText = ConvertTo-PatchedIndexText -Html $indexText

    $originalMainSha = Write-StateOriginalMain -OriginalText $mainText

    $updates = @(
        [pscustomobject]@{ ArchivePath = "main.js"; Bytes = $Script:Utf8.GetBytes($moddedMainText); Remove = $false },
        [pscustomobject]@{ ArchivePath = "AppFiles/js/hold-keys-main.js"; Bytes = (Get-VerifiedPayloadBytes -ArchivePath "AppFiles/js/hold-keys-main.js"); Remove = $false },
        [pscustomobject]@{ ArchivePath = "AppFiles/js/hold-keys.js"; Bytes = (Get-VerifiedPayloadBytes -ArchivePath "AppFiles/js/hold-keys.js"); Remove = $false },
        [pscustomobject]@{ ArchivePath = "AppFiles/stylesheets/hold-keys.css"; Bytes = (Get-VerifiedPayloadBytes -ArchivePath "AppFiles/stylesheets/hold-keys.css"); Remove = $false }
    )

    $resources = Split-Path -Parent $AsarPath
    $temporary = Join-Path $resources (".app.asar.holdkeys.{0}.tmp" -f [Guid]::NewGuid().ToString("N"))
    try {
        Write-Step "Building the patched app.asar..."
        Build-AsarVariant -SourceAsar $AsarPath -OutputPath $temporary -IndexBytes $Script:Utf8.GetBytes($patchedIndexText) -EntryUpdates $updates
        Assert-InstalledAsar -Path $temporary
        $patchedHash = Get-Sha256 -Path $temporary
        [void](Write-ModState -ResolvedGameRoot $ResolvedGameRoot -AsarPath $AsarPath -IndexStyle "anchor" -OriginalMainSha256 $originalMainSha -Status "installing")

        Write-Step "Installing the patched app.asar..."
        Replace-FileAtomically -Replacement $temporary -Destination $AsarPath
        if ((Get-Sha256 -Path $AsarPath) -ne $patchedHash) {
            throw "Installed app.asar failed final SHA-256 verification."
        }
        [void](Write-ModState -ResolvedGameRoot $ResolvedGameRoot -AsarPath $AsarPath -IndexStyle "anchor" -OriginalMainSha256 $originalMainSha -Status "installed")
        Write-Step ("Installed successfully. Start the game and use F6/F7/F8/F9/F11/F12, or the on-screen panel.")
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Install-HoldKeys {
    param([Parameter(Mandatory = $true)][string]$ResolvedGameRoot)
    Assert-GameNotRunning

    $asarPath = Join-Path $ResolvedGameRoot "resources\app.asar"
    $fingerprint = Get-ModFingerprint -AsarPath $asarPath

    $patchState = "with the Chinese patch"
    if (-not $fingerprint.ZhPatchPresent) { $patchState = "without the Chinese patch" }
    $versionText = "?"
    if ($fingerprint.GameVersion) { $versionText = $fingerprint.GameVersion }
    Write-Step ("Detected game version {0} ({1}); mod marker '{2}'." -f $versionText, $patchState, $(if ($fingerprint.Marker) { $fingerprint.Marker } else { "none" }))

    if ($fingerprint.MissingRequired.Count -gt 0) {
        throw ("This does not look like a supported Antimatter Dimensions installation. Missing: " +
            ($fingerprint.MissingRequired -join ", "))
    }

    if ($fingerprint.Marker -eq [string]$Script:Manifest.indexMarker) {
        Install-AlreadyCurrent -ResolvedGameRoot $ResolvedGameRoot -AsarPath $asarPath -Fingerprint $fingerprint
        return
    }

    if ($fingerprint.Marker) {
        if (@($Script:Manifest.upgrade.knownMarkers) -notcontains [string]$fingerprint.Marker) {
            throw ("Detected an unrecognized HoldKeys installation ({0}). Run its own uninstaller first." -f $fingerprint.Marker)
        }
        Install-Upgrade -ResolvedGameRoot $ResolvedGameRoot -AsarPath $asarPath -Fingerprint $fingerprint
        return
    }

    if ($fingerprint.ModEntries.Count -gt 0 -or $fingerprint.MainJsModded) {
        throw "HoldKeys remnants were found without an index marker. Run Uninstall-HoldKeys.cmd to clean up first."
    }

    Install-Fresh -ResolvedGameRoot $ResolvedGameRoot -AsarPath $asarPath -Fingerprint $fingerprint
}

function Uninstall-HoldKeys {
    param([Parameter(Mandatory = $true)][string]$ResolvedGameRoot)
    $asarPath = Join-Path $ResolvedGameRoot "resources\app.asar"
    $fingerprint = Get-ModFingerprint -AsarPath $asarPath

    if ($fingerprint.MissingRequired.Count -gt 0) {
        throw ("Refusing to operate on an unrecognized installation. Missing: " +
            ($fingerprint.MissingRequired -join ", "))
    }

    if (-not $fingerprint.Marker -and $fingerprint.ModEntries.Count -eq 0 -and -not $fingerprint.MainJsModded) {
        Write-Step "HoldKeys is not installed; nothing needs to be removed."
        $state = Get-ExistingState
        if ($state) {
            $previousStyle = "unknown"
            if ($state.PSObject.Properties["indexStyle"] -and $state.indexStyle) { $previousStyle = [string]$state.indexStyle }
            $previousMainSha = $null
            if ($state.PSObject.Properties["originalMainSha256"] -and $state.originalMainSha256) { $previousMainSha = [string]$state.originalMainSha256 }
            [void](Write-ModState -ResolvedGameRoot $ResolvedGameRoot -AsarPath $asarPath -IndexStyle $previousStyle -OriginalMainSha256 $previousMainSha -Status "uninstalled")
        }
        return
    }

    Assert-GameNotRunning
    Write-Step "Removing HoldKeys (surgical uninstall)..."

    $indexText = Read-AsarText -AsarPath $asarPath -Header $Fingerprint.Header -InternalPath "AppFiles/index.html"
    $strippedIndexText = ConvertTo-StrippedIndexText -Html $indexText

    $mainBytes = $null
    if ($fingerprint.MainJsModded) {
        $restoredBytes = $null
        $state = Get-ExistingState
        if ((Test-Path -LiteralPath $Script:StateOriginalMainPath -PathType Leaf) -and
            $state -and $state.PSObject.Properties["originalMainSha256"] -and $state.originalMainSha256) {
            if ((Get-Sha256 -Path $Script:StateOriginalMainPath) -eq ([string]$state.originalMainSha256).ToUpperInvariant()) {
                $restoredBytes = [IO.File]::ReadAllBytes($Script:StateOriginalMainPath)
                Write-Step "Restoring main.js from the state backup."
            }
            else {
                Write-Warning-Step "The state main.js backup failed verification; falling back to pattern stripping."
            }
        }
        if (-not $restoredBytes) {
            try {
                $mainText = Read-AsarText -AsarPath $asarPath -Header $Fingerprint.Header -InternalPath "main.js"
                $restoredBytes = $Script:Utf8.GetBytes((ConvertTo-OriginalMainJsText -Text $mainText))
                Write-Step "Restoring main.js by stripping the HoldKeys hooks."
            }
            catch {
                Write-Warning-Step ("Pattern stripping failed ({0}); using the bundled original main.js." -f $_.Exception.Message)
            }
        }
        if (-not $restoredBytes) {
            $restoredBytes = Get-VerifiedOriginalMainBytes
        }
        $mainBytes = $restoredBytes
    }
    else {
        $mainBytes = Read-AsarFileBytes -ArchivePath $asarPath -Header $Fingerprint.Header -InternalPath "main.js"
    }

    $updates = @(
        [pscustomobject]@{ ArchivePath = "main.js"; Bytes = $mainBytes; Remove = $false },
        [pscustomobject]@{ ArchivePath = "AppFiles/js/hold-keys-main.js"; Bytes = $null; Remove = $true },
        [pscustomobject]@{ ArchivePath = "AppFiles/js/hold-keys.js"; Bytes = $null; Remove = $true },
        [pscustomobject]@{ ArchivePath = "AppFiles/stylesheets/hold-keys.css"; Bytes = $null; Remove = $true }
    )

    $resources = Split-Path -Parent $asarPath
    $temporary = Join-Path $resources (".app.asar.holdkeys-restore.{0}.tmp" -f [Guid]::NewGuid().ToString("N"))
    try {
        Write-Step "Building the cleaned app.asar..."
        Build-AsarVariant -SourceAsar $asarPath -OutputPath $temporary -IndexBytes $Script:Utf8.GetBytes($strippedIndexText) -EntryUpdates $updates
        Assert-StrippedAsar -Path $temporary
        $cleanHash = Get-Sha256 -Path $temporary
        [void](Write-ModState -ResolvedGameRoot $ResolvedGameRoot -AsarPath $asarPath -IndexStyle "stripped" -OriginalMainSha256 $null -Status "uninstalling")

        Write-Step "Installing the cleaned app.asar..."
        Replace-FileAtomically -Replacement $temporary -Destination $asarPath
        if ((Get-Sha256 -Path $asarPath) -ne $cleanHash) {
            throw "Restored app.asar failed final SHA-256 verification."
        }
        [void](Write-ModState -ResolvedGameRoot $ResolvedGameRoot -AsarPath $asarPath -IndexStyle "stripped" -OriginalMainSha256 $null -Status "uninstalled")
        Write-Step "HoldKeys was removed completely."
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Show-Status {
    param([Parameter(Mandatory = $true)][string]$ResolvedGameRoot)
    $asarPath = Join-Path $ResolvedGameRoot "resources\app.asar"
    $fingerprint = Get-ModFingerprint -AsarPath $asarPath
    $state = Get-ExistingState

    Write-Host "Game root: $ResolvedGameRoot"
    Write-Host "ASAR: $asarPath"
    $versionText = "?"
    if ($fingerprint.GameVersion) { $versionText = $fingerprint.GameVersion }
    Write-Host ("Game version (version.txt): {0} (mod tested against {1})" -f $versionText, $Script:Manifest.game.expectedVersion)
    $patchText = "not detected"
    if ($fingerprint.ZhPatchPresent) { $patchText = "detected" }
    Write-Host "Chinese patch (index marker): $patchText"
    $markerText = "none"
    if ($fingerprint.Marker) { $markerText = $fingerprint.Marker }
    Write-Host "HoldKeys marker: $markerText"
    Write-Host ("HoldKeys entries: {0}/3 present" -f $fingerprint.ModEntries.Count)
    $hookText = "original"
    if ($fingerprint.MainJsModded) { $hookText = "injected" }
    Write-Host "main.js hooks: $hookText"
    if ($fingerprint.MissingHotkeySignatures.Count -gt 0) {
        Write-Host ("Hotkey signatures missing: " + ($fingerprint.MissingHotkeySignatures -join ", ")) -ForegroundColor Yellow
    }
    if ($state) {
        Write-Host "State: $Script:StatePath"
        $statusText = "unknown"
        if ($state.PSObject.Properties["status"] -and $state.status) { $statusText = [string]$state.status }
        $modVersionText = "?"
        if ($state.PSObject.Properties["modVersion"] -and $state.modVersion) { $modVersionText = [string]$state.modVersion }
        Write-Host ("Recorded status: {0} (mod {1})" -f $statusText, $modVersionText)
    }
    else {
        Write-Host "State: not found"
    }

    if ($fingerprint.Marker -eq [string]$Script:Manifest.indexMarker) {
        $mismatches = @(Get-PayloadMismatches -AsarPath $asarPath -Header $fingerprint.Header)
        if ($mismatches.Count -eq 0 -and $fingerprint.MainJsModded -and $fingerprint.ModEntries.Count -eq 3) {
            Write-Host ("Result: HoldKeys {0} is installed and intact." -f $Script:Manifest.modVersion)
        }
        else {
            Write-Host ("Result: HoldKeys marker matches this version, but these entries do not: " +
                ($mismatches -join ", ") + ". Run Uninstall, then Install.") -ForegroundColor Yellow
        }
    }
    elseif ($fingerprint.Marker) {
        Write-Host ("Result: HoldKeys {0} is installed; run Install to upgrade to {1}." -f $fingerprint.Marker, $Script:Manifest.modVersion)
    }
    elseif ($fingerprint.ModEntries.Count -gt 0 -or $fingerprint.MainJsModded) {
        Write-Host "Result: HoldKeys remnants were found without a marker. Run Uninstall to clean up." -ForegroundColor Yellow
    }
    else {
        Write-Host "Result: HoldKeys is NOT installed."
    }
}

try {
    $Script:Manifest = Read-JsonFile -Path $Script:ManifestPath
    if ([int]$Script:Manifest.schemaVersion -ne 2) {
        throw "Unsupported mod manifest schema (expected 2)."
    }
    if (-not $Script:Manifest.modVersion) {
        throw "Mod manifest is missing modVersion."
    }
    $resolvedGameRoot = Resolve-GameRoot -RequestedRoot $GameRoot
    switch ($Action) {
        "Install" { Install-HoldKeys -ResolvedGameRoot $resolvedGameRoot }
        "Uninstall" { Uninstall-HoldKeys -ResolvedGameRoot $resolvedGameRoot }
        "Check" { Show-Status -ResolvedGameRoot $resolvedGameRoot }
    }
    exit 0
}
catch {
    Write-Failure -Message $_.Exception.Message
    if ($env:AD_HOLDKEYS_DEBUG -eq "1") {
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    exit 1
}
