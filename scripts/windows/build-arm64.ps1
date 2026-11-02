#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$WorkDirectory,
    [string]$LocalProperties,
    [string]$SourceDirectory,
    [string]$OfficialInstaller,
    [switch]$RunTests
)
$ErrorActionPreference = 'Stop'
$supportRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$repo = if ($SourceDirectory) { (Resolve-Path -LiteralPath $SourceDirectory).Path } else { $supportRoot }
if (-not $WorkDirectory) { $WorkDirectory = Join-Path $repo 'build/windows-arm64' }
$work = [IO.Path]::GetFullPath($WorkDirectory)
New-Item -ItemType Directory -Force $work, "$work/toolchains", "$work/native-arm64", "$work/build-temp" | Out-Null
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'Arm64') {
    throw 'Run this script on Windows ARM64. It bundles a native ARM64 JVM; it is not an x64 cross-build.'
}
$gradleSource = Get-Content "$repo/composeApp/build.gradle.kts" -Raw
$versionCatalog = Get-Content "$repo/gradle/libs.versions.toml" -Raw
$engineMatch = [regex]::Match($gradleSource, 'nuvio-engine-jvm-(0\.1\.[456])\.jar')
if (-not $engineMatch.Success -or $versionCatalog -notmatch 'quickjsKt\s*=\s*"1\.0\.15"') {
    throw 'Upstream changed its native engine or QuickJS ABI. Update the pinned native sources in this port before building this release.'
}
$engineVersion = $engineMatch.Groups[1].Value
$engineCommit = if ($engineVersion -eq '0.1.4') { 'ddb383ba46bafb9970baf0bc23f51de786f58a4c' } elseif ($engineVersion -eq '0.1.5') { '99a18601fa12858cc8c62576dc72b87edbd81b9a' } else { '167f8541d2e07212a9cf7034b9ca4a0c3b6be4d3' }
$engineSuffix = if ($engineVersion -eq '0.1.5') { '' } else { "-$engineVersion" }
$engineSource = "$work/nuvio-engine$engineSuffix"
$engineBuild = "$work/engine-build$engineSuffix"
$torrentSource = "$work/libtorrent$engineSuffix"
Write-Output "Building matching native engine $engineVersion ($engineCommit)."

function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}
function Invoke-Logged([string]$Program, [string[]]$Arguments, [string]$LogPath) {
    Write-Output "Running $Program; full output: $LogPath"
    & $Program @Arguments *> $LogPath
    $commandExitCode = $LASTEXITCODE
    if ($commandExitCode -ne 0) {
        Get-Content -LiteralPath $LogPath -Tail 120
        throw "$Program failed with exit code $commandExitCode. Full output: $LogPath"
    }
    Get-Content -LiteralPath $LogPath -Tail 5
}
function Get-Download([string]$Name, [string]$Url, [string]$Sha256) {
    $path = Join-Path $work $Name
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "Downloading $Name from $([Uri]::new($Url).Host)"
        Invoke-WebRequest -Uri $Url -OutFile "$path.partial" -MaximumRetryCount 3 -RetryIntervalSec 5
        Move-Item -LiteralPath "$path.partial" -Destination $path -Force
    }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Sha256) {
        throw "SHA256 mismatch: $path"
    }
    return $path
}
function Expand-ZipOnce([string]$Archive, [string]$Destination, [string]$Marker) {
    if (-not (Test-Path -LiteralPath $Marker)) { Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force }
}
function Get-Source([string]$Path, [string]$Url, [string]$Commit) {
    if (-not (Test-Path -LiteralPath "$Path/.git")) {
        New-Item -ItemType Directory -Force $Path | Out-Null
        Invoke-Checked git @('-C', $Path, 'init')
        Invoke-Checked git @('-C', $Path, 'config', 'core.autocrlf', 'false')
        Invoke-Checked git @('-C', $Path, 'remote', 'add', 'origin', $Url)
        Invoke-Checked git @('-C', $Path, 'fetch', '--depth', '1', 'origin', $Commit)
        Invoke-Checked git @('-C', $Path, 'checkout', '--detach', 'FETCH_HEAD')
    }
    $head = & git -C $Path rev-parse HEAD
    if ($head -ne $Commit) { throw "Unexpected source revision at $Path. Use a fresh work directory." }
}

$jdkZip = Get-Download 'jdk-arm64.zip' 'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/OpenJDK21U-jdk_aarch64_windows_hotspot_21.0.12.1_1.zip' 'ccf2e51f527d542a70ba5794a600d3aac04b4e967950e227834c7566cb1bec7b'
$llvmZip = Get-Download 'llvm-mingw.zip' 'https://github.com/mstorsjo/llvm-mingw/releases/download/20261006/llvm-mingw-20261006-ucrt-aarch64.zip' '9a835d5179c9f3a5a783c11a7f14062a249b4765dd11add64a66786864e82ab2'
$cmakeZip = Get-Download 'cmake.zip' 'https://github.com/Kitware/CMake/releases/download/v4.4.4/cmake-4.4.4-windows-arm64.zip' 'ed673bbc4eb7c1e59b0407fd52f1680fc0ae3229a46b9b7b3ea9133764f07f67'
$ninjaZip = Get-Download 'ninja.zip' 'https://github.com/ninja-build/ninja/releases/download/v1.13.2/ninja-winarm64.zip' 'e52f0bdef9dfb1003229dbd6508a508c4073fd017247002adc66e5e806cb0391'
$webviewZip = Get-Download 'webview2.zip' 'https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/1.0.4078.44/microsoft.web.webview2.1.0.4078.44.nupkg' 'dc4d1d9168df26b830398303e50210b6e1729f6ce5a7ac69d2c766852f489962'
$mpvArchive = Get-Download 'mpv-arm64.7z' 'https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20261016/mpv-dev-aarch64-20261016-git-a2cd83c56d.7z' '1955bd9b25d92087e7de2eafa69e326f8180ab2a4041a2c6141451152c8d82a7'
$opensslArchive = Get-Download 'openssl-arm64.pkg.tar.zst' 'https://repo.msys2.org/mingw/clangarm64/mingw-w64-clang-aarch64-openssl-3.6.5-1-any.pkg.tar.zst' '40978ba522b2e2d663029d6a5df7ad6e0e408d334a3590930229167bbc5a5edb'
$sevenInstaller = Get-Download '7zip.exe' 'https://www.7-zip.org/a/7z2601-arm64.exe' '1fecf4e3407950939c8ffcc3e42e3039821997dea155301c75369474e5f15175'
$sevenReduced = Get-Download 'toolchains/7zr.exe' 'https://www.7-zip.org/a/7zr.exe' '256feca8e274e5da655e2a284fabafd9f554365eb164862089dacd4e8276d282'
$mpvGpl = Get-Download 'mpv-GPL.txt' 'https://raw.githubusercontent.com/mpv-player/mpv/a2cd83c56d/LICENSE.GPL' 'edaef632cbb643e4e7a221717a6c441a4c1a7c918e6e4d56debc3d8739b233f6'
$mpvLgpl = Get-Download 'mpv-LGPL.txt' 'https://raw.githubusercontent.com/mpv-player/mpv/a2cd83c56d/LICENSE.LGPL' '72b672113d642cbb8ef5dcc76938db801983c56e50b1400ab930f1a64d6dc8d9'
$mpvCopyright = Get-Download 'mpv-Copyright.txt' 'https://raw.githubusercontent.com/mpv-player/mpv/a2cd83c56d/Copyright' 'bfe9ee4cceabcb8ecbfadf208d04156f73d801e6a57369a5606bb8341e204a23'

$jdk = "$work/toolchains/jdk-21.0.12.1+1"
$llvm = "$work/toolchains/llvm-mingw-20261006-ucrt-aarch64"
$cmake = "$work/toolchains/cmake-4.4.4-windows-arm64/bin/cmake.exe"
$ninja = "$work/toolchains/ninja"
$webview = "$work/toolchains/webview2"
Expand-ZipOnce $jdkZip "$work/toolchains" "$jdk/bin/java.exe"
Expand-ZipOnce $llvmZip "$work/toolchains" "$llvm/bin/aarch64-w64-mingw32-clang.exe"
Expand-ZipOnce $cmakeZip "$work/toolchains" $cmake
Expand-ZipOnce $ninjaZip $ninja "$ninja/ninja.exe"
Expand-ZipOnce $webviewZip $webview "$webview/build/native/arm64/WebView2Loader.dll"
$seven = "$work/toolchains/7zip/7z.exe"
if (-not (Test-Path -LiteralPath $seven)) {
    # Extract the installer as an archive; nothing is installed system-wide.
    Invoke-Checked $sevenReduced @('x', $sevenInstaller, "-o$work/toolchains/7zip", '-y')
}
if (-not (Test-Path -LiteralPath "$work/native-arm64/mpv/libmpv-2.dll")) {
    Invoke-Checked $seven @('x', $mpvArchive, "-o$work/native-arm64/mpv", '-y')
}
if (-not (Test-Path -LiteralPath "$work/toolchains/openssl/clangarm64/lib/libssl.a")) {
    Invoke-Checked $seven @('x', $opensslArchive, "-o$work/toolchains/openssl", '-y')
    $tar = Get-ChildItem "$work/toolchains/openssl" -Filter '*.tar' | Select-Object -First 1
    Invoke-Checked $seven @('x', $tar.FullName, "-o$work/toolchains/openssl", '-y')
}

$env:JAVA_HOME = $jdk
$env:GRADLE_USER_HOME = "$work/gradle-home"
$env:TEMP = "$work/build-temp"
$env:TMP = $env:TEMP
$env:PATH = "$llvm/bin;$ninja;$([IO.Path]::GetDirectoryName($cmake));$env:PATH"
$clang = "$llvm/bin/aarch64-w64-mingw32-clang.exe"
$clangxx = "$llvm/bin/aarch64-w64-mingw32-clang++.exe"

Get-Source $engineSource 'https://github.com/NuvioMedia/nuvio-engine.git' $engineCommit
Get-Source $torrentSource 'https://github.com/arvidn/libtorrent.git' '740a0b9aeabe00e762cc0efe4a0f27593db2550b'
Get-Source "$torrentSource/deps/try_signal" 'https://github.com/arvidn/try_signal.git' '105cce59972f925a33aa6b1c3109e4cd3caf583d'
Get-Source "$work/quickjs-kt" 'https://github.com/dokar3/quickjs-kt.git' 'a081755bcdb18ee6afa7ffee25b8fa976f06d31f'
Get-Source "$work/quickjs-source" 'https://github.com/bellard/quickjs.git' '04be246001599f5995fa2f2d8c91a0f198d3f34c'
Get-Source "$work/c-vector" 'https://github.com/eteran/c-vector.git' '774773d4cb1e66dd736e90e7f482d4f22af464c6'

$openssl = "$work/toolchains/openssl/clangarm64".Replace('\', '/')
Invoke-Checked $cmake @(
    '-S', $engineSource, '-B', $engineBuild, '-G', 'Ninja',
    "-DCMAKE_C_COMPILER=$clang", "-DCMAKE_CXX_COMPILER=$clangxx", '-DCMAKE_BUILD_TYPE=Release',
    '-DNUVIO_ENGINE_BUILD_SHARED=ON', '-DNUVIO_ENGINE_ENABLE_LIBTORRENT=ON', '-DNUVIO_ENGINE_BUILD_TESTS=ON',
    '-DCMAKE_SHARED_LINKER_FLAGS=-static -lws2_32 -lcrypt32 -lbcrypt',
    "-DOPENSSL_ROOT_DIR=$openssl", '-DOPENSSL_USE_STATIC_LIBS=TRUE',
    "-DFETCHCONTENT_SOURCE_DIR_NUVIO_LIBTORRENT=$($torrentSource.Replace('\','/'))"
)
Invoke-Logged $cmake @('--build', $engineBuild, '--parallel', '4') "$work/native-engine-build.log"
$env:PATH = "$engineBuild;$llvm/aarch64-w64-mingw32/bin;$env:PATH"
Invoke-Checked "$engineBuild/tests/nuvio_engine_c_api_smoke.exe" @()

$native = "$work/quickjs-kt/quickjs/native"
$quick = "$work/quickjs-source"
$version = (Get-Content "$quick/VERSION" -Raw).Trim()
$sources = @('cutils.c', 'dtoa.c', 'libregexp.c', 'libunicode.c', 'quickjs.c') | ForEach-Object { "$quick/$_" }
$sources += Get-ChildItem "$native/common/*.c", "$native/jni/*.c", "$native/jni/mapping/*.c" | ForEach-Object FullName
Invoke-Checked $clang (@(
    '-shared', '-O2', '-static', '-DCONFIG_WIN32', '-DCONFIG_BIGNUM', "-DCONFIG_VERSION=`"$version`"",
    "-I$jdk/include", "-I$jdk/include/win32", "-I$quick", "-I$work/c-vector",
    "-I$native/common", "-I$native/jni", "-I$native/jni/mapping"
) + $sources + @("$native/quickjs.def", '-lwinpthread', '-o', "$work/native-arm64/libquickjs.dll"))

Invoke-Checked $clangxx @(
    '-std=c++17', '-static', "-I$webview/build/native/include", "-I$repo/composeApp/src/desktopMain/native/windows",
    "$PSScriptRoot/tests/com-callback-test.cpp", '-lole32', '-luuid', '-o', "$work/native-arm64/com-callback-test.exe"
)
Invoke-Checked "$work/native-arm64/com-callback-test.exe" @()

if ($LocalProperties) {
    Copy-Item -LiteralPath $LocalProperties -Destination "$repo/local.properties" -Force
} elseif ($OfficialInstaller) {
    & "$PSScriptRoot/export-public-client-config.ps1" -SevenZip $seven -JavaHome $jdk -Installer $OfficialInstaller -Destination "$repo/local.properties" -WorkDirectory "$work/client-config"
} elseif (-not (Test-Path -LiteralPath "$repo/local.properties")) {
    throw 'Supply -LocalProperties with your Nuvio backend/API configuration (see docs/windows-arm64.md).'
}
Push-Location $repo
try {
    $testTasks = if ($RunTests) {
        @(':composeApp:desktopTest', '--tests', '*WindowsScrollSettingsTest', '--tests', '*WindowActivityTest', '--tests', '*Arm64UpdateAssetTest', '--tests', '*PluginRuntimeDesktopTest', '--tests', '*WindowsPluginRuntimeTest', '--tests', '*DesktopEngineTest.bundledLibraryLoadsAndCreatesEngine*')
    } else { @() }
    $gradleArguments = @(
        ':composeApp:stageWindowsArm64Portable',
        "-Pnuvio.windows.clang.path=$clangxx", "-Pnuvio.webview2.dir=$webview",
        "-Pnuvio.windows.libmpv.runtimeDir=$work/native-arm64/mpv",
        "-Pnuvio.windows.engine.dll=$engineBuild/nuvio_engine.dll",
        "-Pnuvio.windows.quickjs.dll=$work/native-arm64/libquickjs.dll",
        '-Pcompose.desktop.packaging.checkJdkVendor=false', '-Pkotlin.compiler.execution.strategy=in-process',
        '-Dorg.gradle.jvmargs=-Xmx4g -Dfile.encoding=UTF-8', '--max-workers=4', '--no-configuration-cache', '--no-daemon'
    ) + $testTasks
    Invoke-Logged "$repo/gradlew.bat" $gradleArguments "$work/gradle-build.log"
} finally { Pop-Location }
$destination = "$repo/composeApp/build/compose/binaries/main-release/app"
$app = "$repo/composeApp/build/compose/binaries/main-release/app/Nuvio"
if (Test-Path -LiteralPath $app) {
    $resolved = (Resolve-Path -LiteralPath $app).Path
    $expected = [IO.Path]::GetFullPath($app)
    if ($resolved -ne $expected -or -not $resolved.StartsWith([IO.Path]::GetFullPath("$repo/composeApp/build/"), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to replace unexpected build output: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
New-Item -ItemType Directory -Force $destination | Out-Null
$versionProperties = ConvertFrom-StringData (Get-Content "$repo/composeApp/Configuration/DesktopVersion.properties" -Raw)
$packageNumbers = @($versionProperties.VERSION_NAME.Split('-')[0].Split('+')[0].Split('.') | ForEach-Object { [int]$_ })
while ($packageNumbers.Count -lt 3) { $packageNumbers += 0 }
$packageNumbers[0] = [Math]::Max(1, $packageNumbers[0])
$packageVersion = $packageNumbers -join '.'
# Assemble the standard jpackage layout from its ARM64 launcher template. This
# avoids jpackage's generic directory-access probe, which rejects writable
# workspace directories under some Windows application sandboxes.
Add-Type -AssemblyName System.IO.Compression.FileSystem
New-Item -ItemType Directory -Force "$app/app", "$app/runtime" | Out-Null
$moduleBytes = [IO.File]::ReadAllBytes("$jdk/jmods/jdk.jpackage.jmod")
$moduleZip = "$work/toolchains/jpackage-module.zip"
$moduleOutput = [IO.File]::Open($moduleZip, [IO.FileMode]::Create)
try { $moduleOutput.Write($moduleBytes, 4, $moduleBytes.Length - 4) } finally { $moduleOutput.Dispose() }
$module = [IO.Compression.ZipFile]::OpenRead($moduleZip)
try {
    $entry = $module.GetEntry('classes/jdk/jpackage/internal/resources/jpackageapplauncherw.exe')
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, "$app/Nuvio.exe", $true)
} finally { $module.Dispose() }
& "$PSScriptRoot/set-launcher-icon.ps1" -Executable "$app/Nuvio.exe" -Icon "$repo/composeApp/src/desktopMain/resources/icons/nuvio-app-icon-transparent.ico"
Copy-Item "$repo/composeApp/build/windows-arm64/input/*" "$app/app" -Recurse -Force
Copy-Item "$repo/composeApp/build/compose/tmp/main/runtime/*" "$app/runtime" -Recurse -Force
@(
    '[Application]',
    'app.classpath=$APPDIR\nuvio-launcher.jar',
    'app.mainclass=com.nuvio.app.MainKt',
    '',
    '[JavaOptions]',
    "java-options=-Djpackage.app-version=$packageVersion",
    'java-options=-Dcompose.application.configure.swing.globals=true',
    'java-options=-Dcompose.application.resources.dir=$APPDIR\resources',
    'java-options=--add-opens=java.desktop/java.awt=ALL-UNNAMED',
    'java-options=--add-opens=java.desktop/sun.awt.windows=ALL-UNNAMED'
) | Set-Content -LiteralPath "$app/app/Nuvio.cfg" -Encoding utf8NoBOM
& "$PSScriptRoot/verify-arm64-package.ps1" -AppDirectory $app
$licenses = "$app/licenses"
New-Item -ItemType Directory -Force $licenses | Out-Null
$licenseFiles = @{
    "$repo/LICENSE" = 'Nuvio-GPL-3.txt'
    "$engineSource/LICENSE" = 'Nuvio-Engine-GPL-3.txt'
    "$engineSource/THIRD_PARTY_NOTICES.md" = 'Nuvio-Engine-Third-Party.md'
    "$torrentSource/LICENSE" = 'libtorrent-LICENSE.txt'
    "$work/quickjs-kt/LICENSE.txt" = 'QuickJS-Kotlin-Apache-2.txt'
    "$work/quickjs-source/LICENSE" = 'QuickJS-MIT.txt'
    "$work/c-vector/LICENSE" = 'c-vector-MIT.txt'
    "$work/toolchains/openssl/clangarm64/share/licenses/openssl/LICENSE" = 'OpenSSL-Apache-2.txt'
    "$llvm/LICENSE.TXT" = 'LLVM-MinGW-LICENSE.txt'
    $mpvGpl = 'mpv-GPL.txt'
    $mpvLgpl = 'mpv-LGPL.txt'
    $mpvCopyright = 'mpv-Copyright.txt'
}
foreach ($source in $licenseFiles.Keys) { Copy-Item -LiteralPath $source -Destination "$licenses/$($licenseFiles[$source])" }
Copy-Item -LiteralPath "$supportRoot/docs/windows-arm64.md" -Destination "$app/BUILD-NOTES.md"
@"
Nuvio Windows ARM64 $($versionProperties.VERSION_NAME) - unofficial, unsigned build

Extract the entire ZIP and run Nuvio.exe. Java is included.
Windows ARM64 and the ARM64 WebView2 Evergreen Runtime are required.
Source and build information: BUILD-NOTES.md and the accompanying source archive.
"@ | Set-Content -LiteralPath "$app/README.txt" -Encoding utf8
$zip = "$work/Nuvio-Windows-arm64-$($versionProperties.VERSION_NAME)-portable.zip"
Compress-Archive -LiteralPath $app -DestinationPath $zip -Force
Get-FileHash -LiteralPath $zip -Algorithm SHA256
"$((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant())  $([IO.Path]::GetFileName($zip))" | Set-Content "$zip.sha256" -Encoding utf8NoBOM
Write-Output "Built $zip"
