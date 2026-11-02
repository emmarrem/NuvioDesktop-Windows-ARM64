#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SevenZip,
    [Parameter(Mandatory)][string]$JavaHome,
    [Parameter(Mandatory)][string]$Installer,
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][string]$WorkDirectory
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
New-Item -ItemType Directory -Force $WorkDirectory | Out-Null
# MSI entries have file IDs rather than original JAR names. Search ZIP entries,
# then read only constants already distributed in the official public client.
& $SevenZip x $Installer "-o$WorkDirectory/msi" -y | Out-Null
if ($LASTEXITCODE) { throw 'Cannot extract the verified official client.' }
$appJar = $null
foreach ($file in Get-ChildItem "$WorkDirectory/msi" -File -Recurse) {
    if ($file.Length -lt 100000 -or $file.Length -gt 200000000) { continue }
    $zip = $null
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($file.FullName)
        if ($zip.GetEntry('com/nuvio/app/core/network/SupabaseConfig.class')) { $appJar = $file.FullName; break }
    } catch [IO.InvalidDataException] { continue }
    finally { if ($zip) { $zip.Dispose() } }
}
if (-not $appJar) { throw 'No supported client configuration found in this official release.' }
$classes = [ordered]@{
    'com.nuvio.app.core.network.SupabaseConfig' = @{ URL='NUVIO_SUPABASE_URL'; ANON_KEY='NUVIO_SUPABASE_ANON_KEY'; FALLBACK_URL='NUVIO_SUPABASE_FALLBACK_URL' }
    'com.nuvio.app.features.tmdb.TmdbConfig' = @{ API_KEY='TMDB_API_KEY' }
    'com.nuvio.app.features.trakt.TraktConfig' = @{ CLIENT_ID='TRAKT_CLIENT_ID'; CLIENT_SECRET='TRAKT_CLIENT_SECRET'; REDIRECT_URI='TRAKT_REDIRECT_URI' }
    'com.nuvio.app.features.simkl.SimklConfig' = @{ CLIENT_ID='SIMKL_CLIENT_ID'; REDIRECT_URI='SIMKL_REDIRECT_URI'; APP_NAME='SIMKL_APP_NAME' }
    'com.nuvio.app.features.mdblist.MdbListConfig' = @{ CLIENT_ID='MDBLIST_CLIENT_ID' }
    'com.nuvio.app.features.player.skip.IntroDbConfig' = @{ URL='INTRODB_API_URL' }
    'com.nuvio.app.features.details.ImdbEpisodeRatingsConfig' = @{ IMDB_RATINGS_API_BASE_URL='IMDB_RATINGS_API_BASE_URL'; IMDB_TAPFRAME_API_BASE_URL='IMDB_TAPFRAME_API_BASE_URL' }
    'com.nuvio.app.features.debrid.PremiumizeConfig' = @{ CLIENT_ID='PREMIUMIZE_CLIENT_ID' }
    'com.nuvio.app.features.settings.CommunityConfig' = @{ CONTRIBUTIONS_URL='CONTRIBUTIONS_URL'; SUPPORTERS_WALL_URL='SUPPORTERS_WALL_URL'; DONATIONS_BASE_URL='DONATIONS_BASE_URL'; DONATIONS_DONATE_URL='DONATIONS_DONATE_URL' }
}
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('# Public client constants from the matching official Nuvio desktop release.')
foreach ($class in $classes.Keys) {
    $constants = (& "$JavaHome/bin/javap.exe" -classpath $appJar -constants $class 2>$null) -join "`n"
    if ($LASTEXITCODE) { continue }
    foreach ($field in $classes[$class].Keys) {
        $match = [regex]::Match($constants, '\b' + [regex]::Escape($field) + ' = "(.*?)";')
        if ($match.Success) {
            $value = $match.Groups[1].Value.Replace('\', '\\')
            $lines.Add("$($classes[$class][$field])=$value")
        }
    }
}
foreach ($required in 'NUVIO_SUPABASE_URL', 'NUVIO_SUPABASE_ANON_KEY', 'TMDB_API_KEY') {
    if (-not ($lines | Where-Object { $_.StartsWith("$required=") -and $_.Length -gt $required.Length + 1 })) {
        throw "Official client format changed: missing $required. Supply custom configuration or update this extractor."
    }
}
[IO.File]::WriteAllLines([IO.Path]::GetFullPath($Destination), $lines, [Text.UTF8Encoding]::new($false))
Write-Output "Preserved $($lines.Count - 1) published client fields; values withheld from logs."
