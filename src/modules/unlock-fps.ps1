# ---------------------------------------------------------------------------- #
#  UnlockTheFps - deverrouillage du framerate
# ---------------------------------------------------------------------------- #

Register-Me3Module @{
    Key     = 'unlock-fps'
    Name    = 'UnlockTheFps'
    Version = 'v0.4.1'
    Summary = 'Deverrouille la limite de 60 fps, y compris en plein ecran exclusif.'
    Url     = 'https://github.com/a492219408/EldenRing-UnlockTheFps'
    Default = $true
    Order   = 10

    TouchesGame = $false

    Options = @(
        @{
            Key     = 'Framerate'
            Label   = 'Framerate maximum'
            Type    = 'int'
            Default = 120
            Shared  = $true
            Help    = 'De 10 a 1000. La physique du jeu depend du framerate : un ecart entre joueurs desynchronise une session co-op.'
        }
    )

    Downloads = @{
        main = @{
            Url    = 'https://github.com/a492219408/EldenRing-UnlockTheFps/releases/download/v0.4.1/UnlockTheFps-v0.4.1-win64.zip'
            File   = 'UnlockTheFps-v0.4.1-win64.zip'
            Kind   = 'zip'
            Sha256 = '0c99b98451602fa8f9dcad55955e30b37a1d41e5d455c1fb97d5495558e8173d'
        }
    }

    Install = {
        param($ctx)

        $m = Get-Me3Module 'unlock-fps'
        $src = Expand-Download $m.Downloads.main (Get-Download $m.Downloads.main "$($m.Name) $($m.Version)") $m.Key

        $dst = Join-Path $ctx.Me3Profiles 'eldenring-natives\UnlockTheFps'
        New-Item -ItemType Directory -Force $dst | Out-Null
        foreach ($f in @('UnlockTheFps.dll', 'LICENSE.md', 'THIRD_PARTY_NOTICES.md', 'RELEASE_NOTES.md')) {
            $p = Join-Path $src $f
            if (Test-Path $p) { Copy-Item $p $dst -Force }
        }

        $fps = $ctx.Options.Framerate
        Write-TextFile (Join-Path $dst 'UnlockTheFps.ini') @"
[FRAMERATE]

; Limite de framerate. Entier de 10 a 1000.
; A GARDER IDENTIQUE chez tous les joueurs : la physique d'Elden Ring depend du
; framerate, un ecart entre joueurs desynchronise la session.
target_framerate = $fps

; Supprime la constante 60 Hz forcee par le mode plein ecran.
unlock_refresh_rate = 1

; Synchronise la presentation plein ecran exclusif sur le mode selectionne.
fullscreen_vsync = 1

; 0 = utilise target_framerate comme frequence d'affichage demandee.
fullscreen_refresh_rate = 0
"@

        Write-Log "$($m.Name) $($m.Version) installe ($fps fps)" -Level Ok
        return @{ Dir = $dst; Framerate = $fps }
    }

    Uninstall = {
        param($ctx, $st)
        Remove-IfPresent (Join-Path $ctx.Me3Profiles 'eldenring-natives\UnlockTheFps') 'UnlockTheFps' | Out-Null
        # Le dossier parent n'est retire que s'il ne reste plus rien dedans.
        $parent = Join-Path $ctx.Me3Profiles 'eldenring-natives'
        if ((Test-Path $parent) -and -not (Get-ChildItem $parent -Force)) {
            Remove-Item $parent -Force
        }
    }

    ProfileToml = {
        param($ctx)
        return @{
            Natives  = @"
# UnlockTheFps : load_early + initializer sont requis pour le plein ecran
# exclusif. Les patchs doivent s'appliquer en before_game_main, et me3 attend la
# fin du worker avant de laisser le jeu demarrer.
# Reglages : eldenring-natives/UnlockTheFps/UnlockTheFps.ini
[[natives]]
enabled = true
load_early = true
initializer = { function = "unlock_the_fps_init" }
path = "eldenring-natives/UnlockTheFps/UnlockTheFps.dll"
"@
            Packages = ''
        }
    }
}
