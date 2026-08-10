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
    Version = 'derniere publiee'
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
        @{
            Key     = 'ErscVersion'
            Label   = 'Version'
            Type    = 'string'
            Default = 'latest'
            Shared  = $true
            Help    = '"latest" prend la derniere version publiee sur le miroir officiel. Mets un tag precis (par exemple v1.9.0) si ta version du jeu demande une version plus ancienne. Tous les joueurs doivent avoir la meme.'
        }
        @{
            Key     = 'ErscArchive'
            Label   = 'Archive .zip (secours)'
            Type    = 'string'
            Default = ''
            Shared  = $true
            Help    = 'Chemin d''une archive telechargee a la main depuis Nexus. Utile seulement si le miroir GitHub prend du retard sur Nexus. Laisse vide dans tous les autres cas.'
        }
    )

    # Le depot officiel du mod, sous le nom actuel du compte de son auteur
    # (anciennement LukeYui). La version n'est pas epinglee : elle est resolue
    # a l'execution, sinon le module se perimerait a chaque publication.
    Repo = 'yuiamoroll/EldenRingSeamlessCoopRelease'

    Downloads = @{}

    Install = {
        param($ctx)

        $m = Get-Me3Module 'seamless-coop'

        # ERSC embarque un controle de version et refuse de demarrer en se
        # declarant perime des qu'une version plus recente existe. La version
        # est donc resolue a l'execution, jamais epinglee dans le code.
        $archive = "$($ctx.Options.ErscArchive)".Trim()
        $wanted = "$($ctx.Options.ErscVersion)".Trim()
        if (-not $wanted) { $wanted = 'latest' }

        if ($archive) {
            if (-not (Test-Path -LiteralPath $archive)) { Fail "archive Seamless Co-op introuvable : $archive" }
            Write-Log "archive fournie : $archive"
            $version = "archive locale ($(Split-Path $archive -Leaf))"
            $src = Expand-Download @{ Kind = 'zip'; File = (Split-Path $archive -Leaf) } $archive $m.Key
        }
        else {
            $dl = Get-GitHubReleaseAsset -Repo $m.Repo -Tag $wanted
            $version = $dl.Version
            if ($wanted -eq 'latest') { Write-Log "derniere version publiee : $version" }
            $src = Expand-Download $dl (Get-Download $dl "$($m.Name) $version") $m.Key
        }

        # L'arborescence varie selon la provenance de l'archive : on localise le
        # dossier par la DLL plutot que de supposer un chemin.
        $dll = Get-ChildItem $src -Recurse -Filter 'ersc.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $dll) { Fail "ersc.dll introuvable dans l'archive Seamless Co-op" }
        $coopDir = $dll.Directory

        $root = Join-Path $ctx.Me3Profiles 'eldenring-ersc'
        Remove-IfPresent (Join-Path $root 'SeamlessCoop') | Out-Null
        New-Item -ItemType Directory -Force $root | Out-Null
        Copy-Tree $coopDir.FullName (Join-Path $root 'SeamlessCoop')

        $pass = $ctx.Options.CoopPassword
        $ini = Join-Path $root 'SeamlessCoop\ersc_settings.ini'
        $content = (Get-Content $ini -Raw) -replace '(?m)^\s*cooppassword\s*=.*$', "cooppassword = $pass"
        Write-TextFile $ini $content

        Write-Log "$($m.Name) $version installe (mot de passe : $pass)" -Level Ok
        return @{ Dir = $root; Password = $pass; Source = $version }
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
