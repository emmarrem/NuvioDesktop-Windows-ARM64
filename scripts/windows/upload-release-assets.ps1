#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][long]$ReleaseId,
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][string]$Directory
)
$ErrorActionPreference = 'Stop'
if ($Repository -notmatch '^[\w.-]+/[\w.-]+$' -or $ReleaseId -le 0) { throw 'Invalid release identity.' }
if (-not $env:GH_TOKEN) { throw 'GitHub release upload requires the workflow token.' }
$headers = @{ Authorization = "Bearer $env:GH_TOKEN"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
$release = Invoke-RestMethod "https://api.github.com/repos/$Repository/releases/$ReleaseId" -Headers $headers
if ($release.tag_name -ne $Tag -or $release.draft) { throw 'The published release no longer matches this build event.' }
$uploadUrl = $release.upload_url.Split('{')[0]
$uploadUri = [Uri]$uploadUrl
if ($uploadUri.Scheme -ne 'https' -or $uploadUri.Host -ne 'uploads.github.com') { throw 'Unexpected GitHub upload host.' }
$root = (Resolve-Path -LiteralPath $Directory).Path
$files = @(Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Name -match '^Nuvio-Windows-arm64-.+-portable\.zip(?:\.sha256)?$' -or $_.Name -eq 'build-info.json' })
if (@($files | Where-Object Name -Match '-portable\.zip$').Count -ne 1 -or $files.Count -ne 3) {
    throw 'Expected one portable ZIP, its SHA256 file, and build-info.json.'
}
foreach ($file in $files) {
    $digest = 'sha256:' + (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $existing = @($release.assets | Where-Object name -EQ $file.Name)
    if ($existing.Count) {
        if ($existing.Count -eq 1 -and $existing[0].digest -eq $digest -and $existing[0].size -eq $file.Length) {
            Write-Output "Already uploaded and verified: $($file.Name)"
            continue
        }
        throw "Release already has a different $($file.Name). Existing assets are never overwritten; use a new release tag."
    }
    $result = Invoke-RestMethod -Method Post -Uri ($uploadUrl + '?name=' + [Uri]::EscapeDataString($file.Name)) -Headers $headers -ContentType 'application/octet-stream' -InFile $file.FullName
    if ($result.size -ne $file.Length -or $result.digest -ne $digest) { throw "Uploaded asset verification failed: $($file.Name)" }
    Write-Output "Uploaded and verified: $($file.Name)"
}
if ($env:GITHUB_STEP_SUMMARY) { "ARM64 ZIP, checksum and build provenance attached to [$Tag]($($release.html_url))." | Add-Content $env:GITHUB_STEP_SUMMARY }
