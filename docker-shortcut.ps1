# Dot-source this file from your PowerShell profile to enable:
#   docker compose up -<FolderName>
# which finds the folder, zips it to the repository root and starts the stack.
# Docker's own short flags (-d, -V, -t, -y, -w and combinations like -dV)
# and everything else are passed through to the real docker.exe unchanged.

$script:RmepRepoRoot = $PSScriptRoot

function docker {
    $dockerExe = (Get-Command docker -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source

    if ($args.Count -ge 3 -and $args[0] -eq 'compose' -and $args[1] -eq 'up') {
        $folderArg = $args | Select-Object -Skip 2 |
            Where-Object { $_ -match '^-[^-]' -and $_ -cnotmatch '^-[dVtyw]+$' } |
            Select-Object -First 1

        if ($folderArg) {
            $folderName = $folderArg.Substring(1)
            & (Join-Path $script:RmepRepoRoot 'backup-and-start.ps1') -FolderName $folderName -StartDocker
            return
        }
    }

    & $dockerExe @args
}
