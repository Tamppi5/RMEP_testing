[CmdletBinding()]
param(
    [string]$FolderPath,
    [string]$FolderName,
    # Searched in order; the search stops at the first root that contains a match.
    [string[]]$SearchRoots = @(
        '%APPDATA%',
        '%LOCALAPPDATA%',
        '%USERPROFILE%\Desktop',
        '%USERPROFILE%\Documents',
        '%USERPROFILE%\Downloads',
        '%USERPROFILE%'
    ),
    [string]$OutputDirectory,
    [switch]$StartDocker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-TargetFolder {
    param(
        [string]$ExactPath,
        [string]$Name,
        [string[]]$Roots
    )

    $expandedExactPath = if ([string]::IsNullOrWhiteSpace($ExactPath)) {
        $null
    } else {
        [Environment]::ExpandEnvironmentVariables($ExactPath)
    }

    if (-not [string]::IsNullOrWhiteSpace($expandedExactPath)) {
        if (-not (Test-Path -LiteralPath $expandedExactPath -PathType Container)) {
            throw "Folder path not found: $ExactPath"
        }

        return (Resolve-Path -LiteralPath $expandedExactPath).Path
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw 'Provide either -FolderPath or -FolderName.'
    }

    # A name may include parent folders, e.g. "Canva\Cache", to tell apart folders that share a name.
    $suffix = '\' + $Name.Replace('/', '\').Trim('\')

    foreach ($root in $Roots) {
        $expandedRoot = [Environment]::ExpandEnvironmentVariables($root)

        if (-not (Test-Path -LiteralPath $expandedRoot)) {
            continue
        }

        Write-Host "Searching $expandedRoot ..."
        $found = @(
            Get-ChildItem -LiteralPath $expandedRoot -Directory -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase) } |
                Select-Object -ExpandProperty FullName -Unique
        )

        if ($found.Count -eq 0) {
            continue
        }

        # Prefer the match highest in the folder hierarchy (fewest path segments).
        $depthGroups = $found | Group-Object { $_.Split('\').Count } | Sort-Object { [int]$_.Name }
        $shallowest = @($depthGroups[0].Group)

        if ($shallowest.Count -eq 1) {
            if ($found.Count -gt 1) {
                Write-Host "Found $($found.Count) matches; using the one highest in the folder hierarchy."
            }
            return $shallowest[0]
        }

        throw "Found $($shallowest.Count) folders matching '$Name' at the same level under ${expandedRoot}:`n  $($shallowest -join "`n  ")`nAdd the parent folder to the name (for example 'Canva\Cache') or use -FolderPath."
    }

    $expandedRoots = $Roots | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) }
    throw "Folder '$Name' was not found under: $($expandedRoots -join ', '). Try -FolderPath with the exact path, or set -SearchRoots to the location where the folder is stored."
}

function New-ZipArchive {
    param(
        [string]$SourceFolder,
        [string]$DestinationDirectory
    )

    New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null

    $folderLeaf = Split-Path -Path $SourceFolder -Leaf
    $zipPath = Join-Path $DestinationDirectory "$folderLeaf.zip"
    $stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) "rmep-backup-$([Guid]::NewGuid().ToString('N'))"
    $stagingFolder = Join-Path $stagingRoot $folderLeaf

    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    try {
        New-Item -ItemType Directory -Path $stagingFolder -Force | Out-Null
        $skippedFiles = New-Object System.Collections.Generic.List[string]

        Get-ChildItem -LiteralPath $SourceFolder -Recurse -File -ErrorAction Stop |
            Where-Object { $_.Name -ne 'working' } |
            ForEach-Object {
                $relativePath = $_.FullName.Substring($SourceFolder.Length).TrimStart('\')
                $destinationPath = Join-Path $stagingFolder $relativePath
                $destinationParent = Split-Path -Path $destinationPath -Parent

                New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
                try {
                    Copy-Item -LiteralPath $_.FullName -Destination $destinationPath -Force -ErrorAction Stop
                }
                catch {
                    # Files held open by a running app: retry with a shared read, skip if still locked.
                    try {
                        $source = [System.IO.File]::Open($_.FullName, 'Open', 'Read', 'ReadWrite, Delete')
                        try {
                            $destination = [System.IO.File]::Create($destinationPath)
                            try { $source.CopyTo($destination) } finally { $destination.Dispose() }
                        }
                        finally {
                            $source.Dispose()
                        }
                    }
                    catch {
                        Remove-Item -LiteralPath $destinationPath -Force -ErrorAction SilentlyContinue
                        $skippedFiles.Add($relativePath)
                    }
                }
            }

        if ($skippedFiles.Count -gt 0) {
            Write-Warning "Skipped $($skippedFiles.Count) locked file(s) (close the app using them for a complete backup):`n  $($skippedFiles -join "`n  ")"
        }

        Compress-Archive -Path $stagingFolder -DestinationPath $zipPath -Force -ErrorAction Stop

        return $zipPath
    }
    catch {
        if (Test-Path -LiteralPath $zipPath) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        }

        throw
    }
    finally {
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Open-ArchiveLocation {
    param(
        [string]$ZipPath,
        [string]$DestinationDirectory
    )

    if (Get-Command explorer.exe -ErrorAction SilentlyContinue) {
        Start-Process explorer.exe -ArgumentList @($DestinationDirectory)
        return
    }

    Write-Host "Archive created in: $DestinationDirectory"
}

function Start-DockerCompose {
    Push-Location $PSScriptRoot
    try {
        $started = $false

        if (Get-Command docker -ErrorAction SilentlyContinue) {
            & docker compose up -d
            if ($LASTEXITCODE -eq 0) {
                $started = $true
            }
        }

        if (-not $started -and (Get-Command docker-compose -ErrorAction SilentlyContinue)) {
            & docker-compose up -d
            if ($LASTEXITCODE -eq 0) {
                $started = $true
            }
        }

        if (-not $started) {
            throw 'Docker Compose was not available or failed to start the stack.'
        }
    }
    finally {
        Pop-Location
    }
}

if ([string]::IsNullOrWhiteSpace($FolderPath) -and [string]::IsNullOrWhiteSpace($FolderName)) {
    throw 'Provide -FolderPath for an exact folder or -FolderName to search for a folder.'
}

# $PSScriptRoot can be empty inside param() defaults on Windows PowerShell 5.1, so resolve it here.
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = $PSScriptRoot
}

$resolvedFolder = Resolve-TargetFolder -ExactPath $FolderPath -Name $FolderName -Roots $SearchRoots
Write-Host "Backing up folder: $resolvedFolder"

try {
    $zipFile = New-ZipArchive -SourceFolder $resolvedFolder -DestinationDirectory $OutputDirectory
    Write-Host "Created archive: $zipFile"
}
catch {
    Write-Error "Backup failed: $($_.Exception.Message)"
    exit 1
}

Open-ArchiveLocation -ZipPath $zipFile -DestinationDirectory $OutputDirectory
Write-Host 'Archive location opened for manual Google Drive upload.'

if ($StartDocker) {
    Start-DockerCompose
    Write-Host 'Docker stack started.'
}