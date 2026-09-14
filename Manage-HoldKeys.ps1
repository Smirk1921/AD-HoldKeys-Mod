[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("Install", "Uninstall", "Check")]
    [string]$Action = "Install",

    [string]$GameRoot,

    [string]$StateDirectory,

    [switch]$SkipProcessCheck
)

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
$Script:ProcessName = "Antimatter Dimensions"

function Write-Step {
    param([string]$Message)
    Write-Host "[AD HoldKeys] $Message"
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
    foreach ($payload in $Script:Manifest.payload) {
        $source = Join-Path $Script:ModDirectory ([string]$payload.source)
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Mod payload is missing: $source"
        }
        $item = Get-Item -LiteralPath $source
        if ([int64]$item.Length -ne [int64]$payload.size) {
            throw "Mod payload size failed verification: $($payload.source)"
        }
        $actual = Get-Sha256 -Path $source
        if ($actual -ne ([string]$payload.sha256).ToUpperInvariant()) {
            throw "Mod payload failed SHA-256 verification: $($payload.source)"
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

function Build-PatchedIndex {
    param([Parameter(Mandatory = $true)][byte[]]$OriginalBytes)
    $encoding = New-Object Text.UTF8Encoding($false)
    $html = $encoding.GetString($OriginalBytes)
    if ($html.Contains([string]$Script:Manifest.indexMarker)) {
        throw "The source index already contains this mod marker."
    }
    $scriptAnchor = '<script defer src="js/zh-cn-runtime.js"></script>'
    if (-not $html.Contains($scriptAnchor)) {
        throw "The supported Chinese-patch script anchor was not found in index.html."
    }
    $scriptBlock = $scriptAnchor + "`n" +
        '  <!-- ' + [string]$Script:Manifest.indexMarker + ' -->' + "`n" +
        '  <script defer src="js/hold-keys.js"></script>'
    $html = $html.Replace($scriptAnchor, $scriptBlock)

    $styleAnchor = '<link rel="stylesheet" type="text/css" href="stylesheets/zh-cn.css">'
    if (-not $html.Contains($styleAnchor)) {
        throw "The supported Chinese-patch stylesheet anchor was not found in index.html."
    }
    $styleBlock = $styleAnchor + "`n" +
        '  <link rel="stylesheet" type="text/css" href="stylesheets/hold-keys.css">'
    $html = $html.Replace($styleAnchor, $styleBlock)
    return ,$encoding.GetBytes($html)
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

function Build-PatchedAsar {
    param(
        [Parameter(Mandatory = $true)][string]$OriginalPath,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )
    Assert-PayloadIntegrity
    $header = Read-AsarHeader -Path $OriginalPath
    $originalDataLength = [int64]$header.ArchiveLength - [int64]$header.DataOffset
    $indexBytes = Read-AsarFileBytes -ArchivePath $OriginalPath -Header $header -InternalPath "AppFiles/index.html"
    $patchedIndex = Build-PatchedIndex -OriginalBytes $indexBytes

    $appendItems = New-Object Collections.ArrayList
    [void]$appendItems.Add([pscustomobject]@{
        ArchivePath = "AppFiles/index.html"
        Bytes = $patchedIndex
    })
    foreach ($payload in $Script:Manifest.payload) {
        $source = Join-Path $Script:ModDirectory ([string]$payload.source)
        [void]$appendItems.Add([pscustomobject]@{
            ArchivePath = [string]$payload.archivePath
            Bytes = [IO.File]::ReadAllBytes($source)
        })
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
    $encoding = New-Object Text.UTF8Encoding($false)
    $headerBytes = $encoding.GetBytes($headerJson)
    $paddedLength = [int](($headerBytes.Length + 3) -band -4)

    $input = [IO.File]::Open($OriginalPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $output = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = New-Object IO.BinaryWriter($output, $encoding, $true)
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

function Assert-PatchedAsar {
    param([Parameter(Mandatory = $true)][string]$Path)
    $header = Read-AsarHeader -Path $Path
    foreach ($required in @("package.json", "main.js", "AppFiles/index.html", "AppFiles/js/app.js", "AppFiles/js/zh-cn-runtime.js")) {
        if (-not (Get-AsarEntry -Tree $header.Tree -ArchivePath $required)) {
            throw "Generated ASAR is missing a required game file: $required"
        }
    }
    foreach ($payload in $Script:Manifest.payload) {
        $entry = Get-AsarEntry -Tree $header.Tree -ArchivePath ([string]$payload.archivePath)
        if (-not $entry -or [int64]$entry.size -ne [int64]$payload.size) {
            throw "Generated ASAR has an invalid payload entry: $($payload.archivePath)"
        }
        $payloadBytes = Read-AsarFileBytes -ArchivePath $Path -Header $header -InternalPath ([string]$payload.archivePath)
        if ((Get-BytesSha256 -Bytes $payloadBytes) -ne ([string]$payload.sha256).ToUpperInvariant()) {
            throw "Generated ASAR failed payload verification: $($payload.archivePath)"
        }
    }
    $indexBytes = Read-AsarFileBytes -ArchivePath $Path -Header $header -InternalPath "AppFiles/index.html"
    $indexText = (New-Object Text.UTF8Encoding($false)).GetString($indexBytes)
    if (-not $indexText.Contains([string]$Script:Manifest.indexMarker)) {
        throw "Generated ASAR does not contain the mod marker."
    }
}

function Assert-GameNotRunning {
    if ($SkipProcessCheck) { return }
    $running = @(Get-Process -Name $Script:ProcessName -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        throw "Antimatter Dimensions is running. Fully exit the game and run this action again."
    }
}

function Assert-CompatibleBase {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "ASAR does not exist: $Path" }
    $item = Get-Item -LiteralPath $Path
    if ([int64]$item.Length -ne [int64]$Script:Manifest.game.baseAsarSize) {
        throw "Unsupported app.asar size. Expected the current game build plus Chinese patch 0.3.2."
    }
    $actual = Get-Sha256 -Path $Path
    if ($actual -ne ([string]$Script:Manifest.game.baseAsarSha256).ToUpperInvariant()) {
        throw "Unsupported app.asar hash. This mod currently supports only game 11.5 + Chinese patch 0.3.2."
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

function Ensure-BaseBackup {
    param([Parameter(Mandatory = $true)][string]$SourceAsar)
    $expected = ([string]$Script:Manifest.game.baseAsarSha256).ToUpperInvariant()
    $backupPath = Join-Path $Script:StateDirectory "pre-holdkeys-app.asar"

    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        if ((Get-Sha256 -Path $backupPath) -ne $expected) {
            throw "The existing backup is not the supported base app.asar: $backupPath"
        }
        return $backupPath
    }

    if (-not (Test-Path -LiteralPath $Script:StateDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $Script:StateDirectory -Force | Out-Null
    }
    $temporary = Join-Path $Script:StateDirectory (".pre-holdkeys-app.{0}.tmp" -f [Guid]::NewGuid().ToString("N"))
    try {
        Copy-FileBytes -Source $SourceAsar -Destination $temporary
        if ((Get-Sha256 -Path $temporary) -ne $expected) {
            throw "Backup copy failed SHA-256 verification."
        }
        [IO.File]::Move($temporary, $backupPath)
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
    return $backupPath
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

function New-StateObject {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedGameRoot,
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [Parameter(Mandatory = $true)][string]$PatchedSha256,
        [Parameter(Mandatory = $true)][string]$Status
    )
    return [pscustomobject]@{
        schemaVersion = 1
        modVersion = [string]$Script:Manifest.modVersion
        gameRoot = $ResolvedGameRoot
        asarPath = Join-Path $ResolvedGameRoot "resources\app.asar"
        backupPath = $BackupPath
        baseSha256 = [string]$Script:Manifest.game.baseAsarSha256
        patchedSha256 = $PatchedSha256
        status = $Status
        updatedAt = [DateTime]::UtcNow.ToString("o")
    }
}

function Install-HoldKeys {
    param([Parameter(Mandatory = $true)][string]$ResolvedGameRoot)
    Assert-GameNotRunning

    $asarPath = Join-Path $ResolvedGameRoot "resources\app.asar"
    $resources = Split-Path -Parent $asarPath
    $baseHash = ([string]$Script:Manifest.game.baseAsarSha256).ToUpperInvariant()
    $currentHash = Get-Sha256 -Path $asarPath
    $state = Get-ExistingState

    if ($currentHash -ne $baseHash) {
        if ($state -and [string]$state.patchedSha256 -and $currentHash -eq ([string]$state.patchedSha256).ToUpperInvariant()) {
            if ([string]$state.modVersion -ne [string]$Script:Manifest.modVersion) {
                throw "Another HoldKeys version is installed. Run the old uninstaller before installing $($Script:Manifest.modVersion)."
            }
            Write-Step "The HoldKeys mod is already installed."
            $state.status = "installed"
            $state.updatedAt = [DateTime]::UtcNow.ToString("o")
            Write-JsonFileAtomic -Value $state -Path $Script:StatePath
            return
        }
        throw "Current app.asar is not the supported base. Steam may have updated the game or the Chinese patch changed."
    }

    Assert-CompatibleBase -Path $asarPath
    $backupPath = Ensure-BaseBackup -SourceAsar $asarPath
    $temporary = Join-Path $resources (".app.asar.holdkeys.{0}.tmp" -f [Guid]::NewGuid().ToString("N"))
    try {
        Write-Step "Building a patched app.asar..."
        Build-PatchedAsar -OriginalPath $asarPath -OutputPath $temporary
        Assert-PatchedAsar -Path $temporary
        $patchedHash = Get-Sha256 -Path $temporary
        $installingState = New-StateObject -ResolvedGameRoot $ResolvedGameRoot -BackupPath $backupPath -PatchedSha256 $patchedHash -Status "installing"
        Write-JsonFileAtomic -Value $installingState -Path $Script:StatePath

        Write-Step "Installing the patched app.asar..."
        Replace-FileAtomically -Replacement $temporary -Destination $asarPath
        if ((Get-Sha256 -Path $asarPath) -ne $patchedHash) {
            throw "Installed app.asar failed final SHA-256 verification."
        }
        $installedState = New-StateObject -ResolvedGameRoot $ResolvedGameRoot -BackupPath $backupPath -PatchedSha256 $patchedHash -Status "installed"
        Write-JsonFileAtomic -Value $installedState -Path $Script:StatePath
        Write-Step "Installed successfully. Start the game and use F6/F7/F8/F9, or the on-screen panel."
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Uninstall-HoldKeys {
    param([Parameter(Mandatory = $true)][string]$ResolvedGameRoot)
    $asarPath = Join-Path $ResolvedGameRoot "resources\app.asar"
    $resources = Split-Path -Parent $asarPath
    $baseHash = ([string]$Script:Manifest.game.baseAsarSha256).ToUpperInvariant()
    $currentHash = Get-Sha256 -Path $asarPath
    $state = Get-ExistingState

    if (-not $state) {
        if ($currentHash -eq $baseHash) {
            Write-Step "The base app.asar is already active; nothing needs to be removed."
            return
        }
        throw "HoldKeys state was not found. Refusing to overwrite the current app.asar."
    }

    if ($currentHash -eq $baseHash) {
        $state.status = "uninstalled"
        $state.updatedAt = [DateTime]::UtcNow.ToString("o")
        Write-JsonFileAtomic -Value $state -Path $Script:StatePath
        Write-Step "The base app.asar is already active."
        return
    }

    $patchedHash = ([string]$state.patchedSha256).ToUpperInvariant()
    if (-not $patchedHash -or $currentHash -ne $patchedHash) {
        throw "Current app.asar does not match the archive installed by this mod. Refusing to overwrite it."
    }

    $backupPath = [string]$state.backupPath
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf) -or (Get-Sha256 -Path $backupPath) -ne $baseHash) {
        throw "The verified base app.asar backup is unavailable: $backupPath"
    }

    Assert-GameNotRunning
    $temporary = Join-Path $resources (".app.asar.holdkeys-restore.{0}.tmp" -f [Guid]::NewGuid().ToString("N"))
    try {
        Copy-FileBytes -Source $backupPath -Destination $temporary
        if ((Get-Sha256 -Path $temporary) -ne $baseHash) {
            throw "Restore copy failed SHA-256 verification."
        }
        $state.status = "uninstalling"
        $state.updatedAt = [DateTime]::UtcNow.ToString("o")
        Write-JsonFileAtomic -Value $state -Path $Script:StatePath

        Replace-FileAtomically -Replacement $temporary -Destination $asarPath
        if ((Get-Sha256 -Path $asarPath) -ne $baseHash) {
            throw "Restored app.asar failed final SHA-256 verification."
        }
        $state.status = "uninstalled"
        $state.updatedAt = [DateTime]::UtcNow.ToString("o")
        Write-JsonFileAtomic -Value $state -Path $Script:StatePath
        Write-Step "HoldKeys was removed and the base app.asar was restored."
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
    $baseHash = ([string]$Script:Manifest.game.baseAsarSha256).ToUpperInvariant()
    $currentHash = Get-Sha256 -Path $asarPath
    $state = Get-ExistingState
    $header = Read-AsarHeader -Path $asarPath
    $indexBytes = Read-AsarFileBytes -ArchivePath $asarPath -Header $header -InternalPath "AppFiles/index.html"
    $indexText = (New-Object Text.UTF8Encoding($false)).GetString($indexBytes)
    $markerFound = $indexText.Contains([string]$Script:Manifest.indexMarker)

    Write-Host "Game root: $ResolvedGameRoot"
    Write-Host "ASAR: $asarPath"
    Write-Host "Current SHA-256: $currentHash"
    Write-Host "Base SHA-256:    $baseHash"
    if ($state) {
        Write-Host "State: $Script:StatePath"
        Write-Host "Recorded status: $($state.status)"
        if ($state.patchedSha256) { Write-Host "Patched SHA-256: $([string]$state.patchedSha256)" }
        if ($state.backupPath) { Write-Host "Backup: $([string]$state.backupPath)" }
    }
    else {
        Write-Host "State: not found"
    }

    if ($currentHash -eq $baseHash -and -not $markerFound) {
        Write-Host "Result: HoldKeys is NOT installed."
    }
    elseif ($state -and $state.patchedSha256 -and $currentHash -eq ([string]$state.patchedSha256).ToUpperInvariant() -and $markerFound) {
        Write-Host "Result: HoldKeys is installed and matches the recorded archive."
    }
    elseif ($markerFound) {
        Write-Host "Result: HoldKeys marker was found, but the archive does not match the recorded installation." -ForegroundColor Yellow
    }
    else {
        Write-Host "Result: app.asar is not a supported base or the recorded HoldKeys archive." -ForegroundColor Yellow
    }
}

try {
    $Script:Manifest = Read-JsonFile -Path $Script:ManifestPath
    if ([string]$Script:Manifest.modVersion -ne "1.1.1") {
        throw "Unsupported mod manifest version."
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