#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$VersionName,
    [Parameter(Mandatory)][ValidateRange(1,19)][int]$Revision,
    [switch]$SmokeTest
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$app = (Resolve-Path -LiteralPath $AppDirectory).Path
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
if (-not (Test-Path -LiteralPath "$app/Nuvio.exe" -PathType Leaf)) { throw 'ARM64 launcher missing.' }
$version = [regex]::Match($VersionName, '^[vV]?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$')
if (-not $version.Success) { throw 'Unsupported MSI version name.' }
$major, $minor, $patch = $version.Groups[1..3].Value | ForEach-Object { [int]$_ }
# Map both the upstream version and fork rebuild number into the three fields Windows Installer compares.
$stage = switch -Regex ($version.Groups[4].Value) {
    '^$' { 60; break }
    '^rc(?:[.-]|$)' { 40; break }
    '^beta(?:[.-]|$)' { 20; break }
    default { 0 }
}
$build = $patch * 100 + $stage + $Revision
if ($major -gt 255 -or $minor -gt 255 -or $build -gt 65535) { throw 'Version exceeds Windows Installer limits.' }
$msiVersion = "$major.$minor.$build"
$displayVersion = $VersionName.TrimStart([char[]]'vV')
$msi = Join-Path $output "Nuvio-Windows-arm64-$displayVersion.msi"
$tools = Join-Path $output wix-tools
$wixVersion = '6.0.2'
$extension = "WixToolset.UI.wixext/$wixVersion"
$env:DOTNET_ROLL_FORWARD = 'Major'
dotnet tool install wix --version $wixVersion --tool-path $tools
$wix = Join-Path $tools wix.exe
& $wix extension add --global $extension
& $wix build -arch arm64 -ext $extension -d "AppDirectory=$app" -d "MsiVersion=$msiVersion" -d "LicensePath=$PSScriptRoot/windows-arm64-license.rtf" -out $msi "$PSScriptRoot/windows-arm64-installer.wxs"
$hash = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  $([IO.Path]::GetFileName($msi))" | Set-Content -LiteralPath "$msi.sha256" -Encoding utf8NoBOM

if ($SmokeTest) {
    $installed = Join-Path $env:ProgramFiles 'Nuvio Windows ARM64'
    if (Test-Path -LiteralPath $installed) { throw 'MSI smoke test requires a fresh runner.' }
    $msiexec = Join-Path $env:SystemRoot 'System32/msiexec.exe'
    try {
        $proc = Start-Process -FilePath $msiexec -ArgumentList "/i `"$msi`" /qn /norestart /l*v `"$output/msi-install.log`"" -WindowStyle Hidden -Wait -PassThru
        if ($proc.ExitCode -notin 0,3010) { throw "MSI install failed: $($proc.ExitCode)" }
        & "$PSScriptRoot/verify-arm64-package.ps1" -AppDirectory $installed
        $expectedRevision = "java-options=-Dnuvio.arm64.releaseRevision=$Revision"
        if ($expectedRevision -notin (Get-Content -LiteralPath "$installed/app/Nuvio.cfg")) {
            throw 'The installed launcher does not identify its ARM64 release revision.'
        }
    } finally {
        $proc = Start-Process -FilePath $msiexec -ArgumentList "/x `"$msi`" /qn /norestart /l*v `"$output/msi-uninstall.log`"" -WindowStyle Hidden -Wait -PassThru
        if ($proc.ExitCode -notin 0,1605,3010) { throw "MSI uninstall failed: $($proc.ExitCode)" }
    }
    if (Test-Path -LiteralPath "$installed/Nuvio.exe") { throw 'MSI uninstall left the launcher installed.' }
}
