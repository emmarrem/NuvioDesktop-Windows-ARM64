#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot/../..").Path
$metadata = Get-Content "$repo/ports/windows-arm64/base.json" -Raw | ConvertFrom-Json
# Include newly created source files. This only updates intent-to-add in the index.
& git -C $repo add -N -- composeApp
if ($LASTEXITCODE) { throw 'Cannot enumerate port source.' }
& git -C $repo -c core.autocrlf=true diff $metadata.baseCommit --full-index --binary --output=ports/windows-arm64/app.patch -- composeApp
if ($LASTEXITCODE) { throw 'Cannot generate versioned port patch.' }
Write-Output 'Updated ports/windows-arm64/app.patch. Validate it against the target release before publishing.'
