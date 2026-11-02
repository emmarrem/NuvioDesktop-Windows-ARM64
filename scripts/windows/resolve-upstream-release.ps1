#requires -Version 7.0
[CmdletBinding()]
param([string]$Tag = 'latest', [Parameter(Mandatory)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'Nuvio-Windows-ARM64-builder' }
if ($env:GH_TOKEN) { $headers.Authorization = "Bearer $env:GH_TOKEN" }
$endpoint = if ($Tag -eq 'latest') { 'latest' } else { 'tags/' + [Uri]::EscapeDataString($Tag) }
$release = Invoke-RestMethod "https://api.github.com/repos/NuvioMedia/NuvioDesktop/releases/$endpoint" -Headers $headers
if ($release.draft -or $release.tag_name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._+-]*$') { throw 'Invalid public release tag.' }
$installer = @($release.assets | Where-Object { $_.name -match '(?i)windows.*(?:x64|x86_64).*\.msi$|(?i)(?:x64|x86_64).*\.msi$' })
if ($installer.Count -ne 1) { throw 'The selected release must have exactly one official Windows x64 MSI for its public client configuration.' }
$checksums = @($release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' })
if ($checksums.Count -ne 1) { throw 'The selected release has no SHA256SUMS.txt. Refusing an unverified installer.' }
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$sums = (Invoke-WebRequest $checksums[0].browser_download_url).Content
if ($sums -is [byte[]]) { $sums = [Text.Encoding]::UTF8.GetString($sums) }
$hashPattern = '(?m)^([a-fA-F0-9]{64})\s+\*?' + [regex]::Escape($installer[0].name) + '\s*$'
$match = [regex]::Match($sums, $hashPattern)
if (-not $match.Success) { throw 'Installer checksum is missing from the official release.' }
$path = Join-Path $OutputDirectory 'official-windows.msi'
Invoke-WebRequest $installer[0].browser_download_url -OutFile $path
if ((Get-FileHash $path -Algorithm SHA256).Hash -ne $match.Groups[1].Value) { throw 'Official installer SHA256 mismatch.' }
@{ tag = $release.tag_name; installerSha256 = $match.Groups[1].Value; url = $release.html_url } | ConvertTo-Json | Set-Content "$OutputDirectory/release.json" -Encoding utf8NoBOM
if ($env:GITHUB_OUTPUT) { "tag=$($release.tag_name)" | Add-Content $env:GITHUB_OUTPUT }
Write-Output "Selected official release $($release.tag_name); installer checksum verified."
