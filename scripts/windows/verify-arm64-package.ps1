[CmdletBinding()]
param([Parameter(Mandatory)][string]$AppDirectory)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-Arm64([byte[]]$Bytes, [string]$Label) {
    if ($Bytes.Length -lt 64 -or $Bytes[0] -ne 0x4d -or $Bytes[1] -ne 0x5a) {
        throw "Invalid PE binary: $Label"
    }
    $offset = [BitConverter]::ToInt32($Bytes, 60)
    if ($offset -lt 0 -or $offset -gt $Bytes.Length - 6 -or [BitConverter]::ToUInt32($Bytes, $offset) -ne 0x4550) {
        throw "Invalid PE header: $Label"
    }
    $machine = [BitConverter]::ToUInt16($Bytes, $offset + 4)
    if ($machine -ne 0xaa64) { throw ('Expected ARM64, found 0x{0:x4}: {1}' -f $machine, $Label) }
    Write-Output "ARM64 $Label"
}

$root = (Resolve-Path -LiteralPath $AppDirectory).Path
$launcher = Join-Path $root 'Nuvio.exe'
if (-not (Test-Path -LiteralPath $launcher)) { throw "Missing launcher: $launcher" }
Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in '.exe', '.dll' } | ForEach-Object {
    Assert-Arm64 ([IO.File]::ReadAllBytes($_.FullName)) ([IO.Path]::GetRelativePath($root, $_.FullName))
}

$jars = @(Get-ChildItem -LiteralPath (Join-Path $root 'app') -Recurse -Filter '*.jar')
$required = @{
    'native/windows/player_bridge.dll' = $false
    'native/windows/libmpv-2.dll' = $false
    'native/windows/WebView2Loader.dll' = $false
    'native/windows/nuvio_engine.dll' = $false
    'jni/windows_aarch64/libquickjs.dll' = $false
}
$skiko = $false
$jna = $false
foreach ($jar in $jars) {
    $zip = [IO.Compression.ZipFile]::OpenRead($jar.FullName)
    try {
        foreach ($entry in $zip.Entries) {
            $selected = $required.ContainsKey($entry.FullName) -or
                $entry.FullName -match '(^|/)skiko-windows-arm64\.dll$' -or
                $entry.FullName -match 'win32-aarch64/jnidispatch\.dll$'
            if (-not $selected) { continue }
            $stream = $entry.Open()
            $memory = [IO.MemoryStream]::new()
            try { $stream.CopyTo($memory); Assert-Arm64 ($memory.ToArray()) "$($jar.Name)!/$($entry.FullName)" }
            finally { $stream.Dispose(); $memory.Dispose() }
            if ($required.ContainsKey($entry.FullName)) { $required[$entry.FullName] = $true }
            if ($entry.FullName -match 'skiko-windows-arm64\.dll$') { $skiko = $true }
            if ($entry.FullName -match 'win32-aarch64/jnidispatch\.dll$') { $jna = $true }
        }
    } finally { $zip.Dispose() }
}
foreach ($name in $required.Keys) { if (-not $required[$name]) { throw "Missing native resource: $name" } }
if (-not $skiko) { throw 'Missing ARM64 Skiko rendering runtime' }
if (-not $jna) { throw 'Missing ARM64 JNA runtime' }
if (-not (Test-Path -LiteralPath (Join-Path $root 'runtime/bin/server/jvm.dll'))) { throw 'Missing bundled JVM' }
Write-Output 'PASS: launcher, JVM, graphics, JNI, player, JavaScript and torrent engine are ARM64.'
