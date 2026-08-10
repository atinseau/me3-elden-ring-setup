# ============================================================================ #
#  Detection du jeu et de me3
# ============================================================================ #

function Find-GamePath {
    <# Retourne le premier dossier contenant eldenring.exe, ou $null. #>
    $candidates = New-Object System.Collections.Generic.List[string]

    # Bibliotheques Steam declarees
    try {
        $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath
        if ($steam) {
            $steam = $steam -replace '/', '\'
            $candidates.Add((Join-Path $steam 'steamapps\common\ELDEN RING\Game'))
            $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
            if (Test-Path $vdf) {
                foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                    $lib = $m.Groups[1].Value -replace '\\\\', '\'
                    $candidates.Add((Join-Path $lib 'steamapps\common\ELDEN RING\Game'))
                }
            }
        }
    }
    catch { }

    # Emplacements manuels frequents, sur chaque disque fixe
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($null -eq $drive.Free) { continue }
        foreach ($sub in @(
                'Games\ELDEN RING\Game',
                'ELDEN RING\Game',
                'SteamLibrary\steamapps\common\ELDEN RING\Game',
                'Steam\steamapps\common\ELDEN RING\Game')) {
            $candidates.Add((Join-Path $drive.Root $sub))
        }
    }

    foreach ($c in $candidates) {
        try { if (Test-Path (Join-Path $c 'eldenring.exe')) { return $c } } catch { }
    }
    return $null
}

function Test-GamePath {
    param([AllowEmptyString()][string]$Path)
    if (-not $Path) { return $false }
    return (Test-Path (Join-Path $Path 'eldenring.exe'))
}

function Get-Me3Exe {
    $p = Join-Path $script:Me3ProgramDir 'bin\me3.exe'
    if (Test-Path $p) { return $p }
    $cmd = Get-Command me3 -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-Me3Version {
    $exe = Get-Me3Exe
    if (-not $exe) { return $null }
    $out = Invoke-Native $exe @('--version')
    if ($out) { return ($out | Select-Object -First 1) }
    return 'version inconnue'
}

function Test-GameRunning {
    return [bool](Get-Process eldenring -ErrorAction SilentlyContinue)
}
