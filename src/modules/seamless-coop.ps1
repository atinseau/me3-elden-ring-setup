# ---------------------------------------------------------------------------- #
#  Seamless Co-op - multijoueur sans serveurs FromSoftware
#
#  La DLL est declaree A LA FOIS en [[natives]] et en [[packages]] : me3
#  n'ajoute pas le dossier d'un native a son VFS, donc ersc.dll ne trouverait
#  pas son ersc_settings.ini avec la seule entree native. Le package projette le
#  dossier a la racine du jeu, en memoire, sans rien y ecrire.
#  Voir https://github.com/garyttierney/me3/discussions/435
# ---------------------------------------------------------------------------- #

Register-Me3Module @{
    Key     = 'seamless-coop'
    Name    = 'Seamless Co-op'
    Version = 'v1.9.8'
    Summary = 'Remplace le P2P du jeu : jusqu''a 6 joueurs, sans mur de brouillard ni deconnexion apres un boss. Session privee par mot de passe.'
    Url     = 'https://github.com/LukeYui/EldenRingSeamlessCoopRelease'
    Default = $true
    Order   = 30

    TouchesGame = $false

    Options = @(
        @{
            Key     = 'CoopPassword'
            Label   = 'Mot de passe de session'
            Type    = 'string'
            Default = 'eldenlan'
            Shared  = $true
            Help    = 'Decide qui rejoint quelle partie. Doit etre STRICTEMENT identique chez tous les joueurs.'
        }
    )

    Downloads = @{
        main = @{
            Url    = 'https://github.com/LukeYui/EldenRingSeamlessCoopRelease/releases/download/v1.9.8/Seamless.Co-op.v1.9.8-510-1-9-8-1776128433.zip'
            File   = 'SeamlessCoop-v1.9.8.zip'
            Kind   = 'zip'
            Sha256 = $null
        }
    }

    Install = {
        param($ctx)

        $m = Get-Me3Module 'seamless-coop'
        $src = Expand-Download $m.Downloads.main (Get-Download $m.Downloads.main "$($m.Name) $($m.Version)") $m.Key

        $root = Join-Path $ctx.Me3Profiles 'eldenring-ersc'
        Remove-IfPresent (Join-Path $root 'SeamlessCoop') | Out-Null
        New-Item -ItemType Directory -Force $root | Out-Null
        Copy-Item (Join-Path $src 'SeamlessCoop') $root -Recurse -Force

        $pass = $ctx.Options.CoopPassword
        $ini = Join-Path $root 'SeamlessCoop\ersc_settings.ini'
        $content = (Get-Content $ini -Raw) -replace '(?m)^\s*cooppassword\s*=.*$', "cooppassword = $pass"
        Write-TextFile $ini $content

        Write-Log "$($m.Name) $($m.Version) installe (mot de passe : $pass)" -Level Ok
        return @{ Dir = $root; Password = $pass }
    }

    Uninstall = {
        param($ctx, $st)
        Remove-IfPresent (Join-Path $ctx.Me3Profiles 'eldenring-ersc') 'Seamless Co-op' | Out-Null
    }

    ProfileToml = {
        param($ctx)
        return @{
            Natives  = @"
# Seamless Co-op. load_early : le mod doit s'installer avant l'initialisation
# reseau du jeu. Le package plus bas est indispensable pour que la DLL trouve
# son ersc_settings.ini. Voir https://github.com/garyttierney/me3/discussions/435
# Mot de passe : eldenring-ersc/SeamlessCoop/ersc_settings.ini
[[natives]]
enabled = true
load_early = true
path = "eldenring-ersc/SeamlessCoop/ersc.dll"
"@
            Packages = @"
# Contrepartie de l'entree [[natives]] : projette eldenring-ersc/SeamlessCoop/
# a la racine du jeu, en VFS uniquement, pour que la DLL trouve son .ini, sa
# locale et crashpad. Rien n'est ecrit sur le disque du jeu.
[[packages]]
id = "seamless-coop"
enabled = true
path = "eldenring-ersc"
load_after = []
load_before = []
"@
        }
    }
}
