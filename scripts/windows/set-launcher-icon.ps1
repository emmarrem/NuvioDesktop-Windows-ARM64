[CmdletBinding()]
param([Parameter(Mandatory)][string]$Executable, [Parameter(Mandatory)][string]$Icon)
$ErrorActionPreference = 'Stop'
if (-not ('NuvioIconResource' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NuvioIconResource {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr BeginUpdateResourceW(string path, bool deleteExisting);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool UpdateResourceW(IntPtr update, IntPtr type, IntPtr name, ushort language, byte[] data, uint size);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool EndUpdateResourceW(IntPtr update, bool discard);
}
'@
}
$exe = (Resolve-Path -LiteralPath $Executable).Path
$bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Icon).Path)
if ($bytes.Length -lt 6 -or [BitConverter]::ToUInt16($bytes, 2) -ne 1) { throw 'Invalid ICO file' }
$count = [BitConverter]::ToUInt16($bytes, 4)
if ($bytes.Length -lt 6 + 16 * $count) { throw 'Truncated ICO directory' }
$group = [byte[]]::new(6 + 14 * $count)
[Buffer]::BlockCopy($bytes, 0, $group, 0, 6)
$update = [NuvioIconResource]::BeginUpdateResourceW($exe, $false)
if ($update -eq [IntPtr]::Zero) { throw [ComponentModel.Win32Exception]::new() }
$committed = $false
try {
    for ($i = 0; $i -lt $count; $i++) {
        $entry = 6 + 16 * $i
        $size = [BitConverter]::ToUInt32($bytes, $entry + 8)
        $offset = [BitConverter]::ToUInt32($bytes, $entry + 12)
        if ([long]$offset + $size -gt $bytes.Length) { throw 'Truncated ICO image' }
        $image = [byte[]]::new($size)
        [Buffer]::BlockCopy($bytes, $offset, $image, 0, $size)
        if (-not [NuvioIconResource]::UpdateResourceW($update, [IntPtr]3, [IntPtr]($i + 1), 0, $image, $size)) {
            throw [ComponentModel.Win32Exception]::new()
        }
        [Buffer]::BlockCopy($bytes, $entry, $group, 6 + 14 * $i, 12)
        [Buffer]::BlockCopy([BitConverter]::GetBytes([uint16]($i + 1)), 0, $group, 18 + 14 * $i, 2)
    }
    if (-not [NuvioIconResource]::UpdateResourceW($update, [IntPtr]14, [IntPtr]1, 0, $group, $group.Length)) {
        throw [ComponentModel.Win32Exception]::new()
    }
    $committed = [NuvioIconResource]::EndUpdateResourceW($update, $false)
    $update = [IntPtr]::Zero
    if (-not $committed) { throw [ComponentModel.Win32Exception]::new() }
} finally {
    if ($update -ne [IntPtr]::Zero) { [void][NuvioIconResource]::EndUpdateResourceW($update, $true) }
}
