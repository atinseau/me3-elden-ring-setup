# ---------------------------------------------------------------------------- #
#  Boss Arena (Sandbox Mode) - arene de boss a la carte
#
#  Mod de type package : pas de DLL, uniquement des fichiers du DVDBND
#  (regulation.bin, map, menu, msg, event, script) que me3 projette a la racine
#  du jeu par son VFS. Rien n'est ecrit dans le dossier du jeu.
#
#  L'archive n'est distribuee que sur Nexus, qui exige un compte et interdit le
#  telechargement automatise. Elle est donc resservie depuis les releases de ce
#  depot : l'installation ne demande aucune etape manuelle. Voir le bloc
#  « Miroir d'archives » de l'en-tete.
# ---------------------------------------------------------------------------- #

# La version est dans le nom du fichier : une mise a jour du mod se fait en
# televersant une nouvelle archive et en changeant cette seule ligne.
$script:ArenaMirrorVersion = '3.9.5'
$script:ArenaMirror = New-MirrorDownload -File "BossArenaSandbox-$script:ArenaMirrorVersion.zip"

# Les modificateurs A/B/C de l'auteur sont des regulation.bin exclusifs entre
# eux. La cle est la valeur du reglage, la valeur le dossier dans l'archive.
# $null = on garde le regulation.bin livre par defaut.
$script:ArenaTuningDirs = [ordered]@{
    'defaut'    = $null
    'scadutree' = 'Restore Scadutree Blessing mechanics'
    'ngplus'    = 'Restore vanilla NG+ stats'
    'tout'      = 'Restore Scadutree Blessing mechanics and vanilla NG+ stats'
}

# Metadonnees du projet Smithbox (l'editeur avec lequel le mod est fabrique).
# 16 Mo d'outillage sans aucun effet en jeu : inutile de les projeter dans le
# VFS a chaque lancement.
$script:ArenaSkip = @('.smithbox', 'project.json')

function Get-ArenaModRoot {
    <#
        Localise le dossier 'mod' dans l'archive extraite. On le repere par son
        regulation.bin plutot que par un chemin en dur : le dossier racine porte
        le numero de version, qui changera.

        Les regulation.bin des modificateurs optionnels sont ecartes : leur
        dossier parent ne s'appelle pas 'mod'.
    #>
    param([Parameter(Mandatory)][string]$Extracted)

    $hit = Get-ChildItem $Extracted -Recurse -Filter 'regulation.bin' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -eq 'mod' } | Select-Object -First 1
    if (-not $hit) { Fail "dossier 'mod' introuvable dans l'archive Boss Arena (regulation.bin absent)" }
    return $hit.Directory
}

Register-Me3Module @{
    Key     = 'boss-arena'
    Name    = 'Boss Arena (Sandbox Mode)'
    Version = "Sandbox $script:ArenaMirrorVersion"
    Summary = 'Arene ou tous les boss du jeu et du DLC sont invocables a la demande, avec stats et recompenses reequilibrees.'
    Url     = 'https://www.nexusmods.com/eldenring/mods/5645'

    # Refonte lourde du gameplay, et son archive doit etre recuperee a la main :
    # elle ne s'impose pas a quelqu'un qui installe l'assistant sans la demander.
    Default = $false
    Order   = 40

    # Tout passe par le VFS de me3 : le dossier du jeu reste intact.
    TouchesGame = $false

    Options = @(
        @{
            Key     = 'ArenaTuning'
            Label   = 'Equilibrage'
            Type    = 'string'
            Default = 'defaut'
            Shared  = $true
            Help    = 'defaut | scadutree (restaure les benedictions de l''Arbre d''ombre) | ngplus (restaure les stats NG+ d''origine) | tout (les deux). Remplace regulation.bin : un ecart entre joueurs donne des stats differentes en co-op.'
        }
        @{
            Key     = 'ArenaRandomizerFix'
            Label   = 'Correctifs Enemy Randomizer'
            Type    = 'int'
            Default = 0
            Shared  = $true
            Help    = '0 = non, 1 = oui. Corrige les combats de Gideon et Rykard quand un randomiseur d''ennemis est utilise. A appliquer AVANT de lancer la randomisation.'
        }
        # Les deux reglages suivants sont de la plomberie : ils permettent de
        # court-circuiter le miroir. L'assistant ne les affiche pas.
        @{
            Key      = 'ArenaUrl'
            Label    = 'URL directe (miroir)'
            Type     = 'string'
            Default  = ''
            Shared   = $true
            Advanced = $true
            Help     = 'URL d''une archive .zip a telecharger, par exemple ton propre miroir. Prioritaire sur le miroir de ce depot.'
        }
        @{
            Key      = 'ArenaArchive'
            Label    = 'Archive .zip locale'
            Type     = 'string'
            Default  = ''
            Shared   = $false
            Advanced = $true
            Help     = 'Chemin d''une archive deja telechargee sur CE PC. Prioritaire sur tout le reste.'
        }
    )

    Downloads = @{}

    # Rien a demander : l'archive est servie par le miroir de ce depot.
    Preflight = { param($options) return $null }

    Install = {
        param($ctx)

        $m = Get-Me3Module 'boss-arena'

        # Reglages valides avant de telecharger ou d'extraire 100 Mo pour rien.
        $tuning = "$($ctx.Options.ArenaTuning)".Trim().ToLower()
        if (-not $tuning) { $tuning = 'defaut' }
        if (-not $script:ArenaTuningDirs.Contains($tuning)) {
            Fail "equilibrage inconnu : '$tuning'. Valeurs acceptees : $(($script:ArenaTuningDirs.Keys) -join ', ')."
        }
        $fix = [int]$ctx.Options.ArenaRandomizerFix

        # Trois sources, par priorite decroissante : archive locale, miroir
        # personnel, miroir de ce depot.
        $archive = "$($ctx.Options.ArenaArchive)".Trim()
        $url = "$($ctx.Options.ArenaUrl)".Trim()

        if ($archive) {
            if (-not (Test-Path -LiteralPath $archive)) { Fail "archive Boss Arena introuvable : $archive" }
            Write-Log "archive locale fournie : $archive"
            $version = "archive locale ($(Split-Path $archive -Leaf))"
            $src = Expand-Download @{ Kind = 'zip'; File = (Split-Path $archive -Leaf) } $archive $m.Key
        }
        elseif ($url) {
            Write-Log "miroir personnel : $url"
            $name = [IO.Path]::GetFileName(([uri]$url).LocalPath)
            if (-not $name -or $name -notmatch '\.zip$') { $name = 'boss-arena-mirror.zip' }
            $dl = @{ Url = $url; File = $name; Kind = 'zip'; Sha256 = $null }
            $version = "miroir ($name)"
            $src = Expand-Download $dl (Get-Download $dl "$($m.Name) depuis un miroir personnel") $m.Key
        }
        else {
            $dl = $script:ArenaMirror
            $version = "Sandbox $script:ArenaMirrorVersion"
            $src = Expand-Download $dl (Get-Download $dl "$($m.Name) $version") $m.Key
        }

        $modDir = Get-ArenaModRoot $src
        # « Optional modifiers » est a cote du dossier 'mod', pas dedans.
        $optRoot = Join-Path $modDir.Parent.FullName 'Optional modifiers'

        # Table rase : sans cela, les fichiers d'une version precedente qui
        # n'existent plus dans la nouvelle resteraient projetes dans le VFS.
        $root = Join-Path $ctx.Me3Profiles 'eldenring-bossarena'
        Remove-IfPresent $root | Out-Null
        $dst = Join-Path $root 'mod'
        New-Item -ItemType Directory -Force $dst | Out-Null

        foreach ($item in (Get-ChildItem $modDir.FullName -Force)) {
            if ($script:ArenaSkip -contains $item.Name) { continue }
            Copy-Item $item.FullName $dst -Recurse -Force
        }

        # --- modificateurs de l'auteur ------------------------------------- #

        # A / B / C : remplacement du regulation.bin, exclusifs entre eux.
        $tuningDir = $script:ArenaTuningDirs[$tuning]
        if ($tuningDir) {
            $bin = Join-Path $optRoot "$tuningDir\regulation.bin"
            if (-not (Test-Path -LiteralPath $bin)) {
                Fail "modificateur '$tuning' absent de cette archive (attendu : Optional modifiers\$tuningDir\regulation.bin)"
            }
            Copy-Item $bin (Join-Path $dst 'regulation.bin') -Force
            Write-Log "equilibrage : $tuning" -Level Ok
        }
        else {
            Write-Log 'equilibrage : defaut (regulation.bin livre par le mod)' -Level Ok
        }

        # D : remplacement du dossier event, combinable avec A/B/C.
        if ($fix) {
            $ev = Join-Path $optRoot 'Enemy Randomizer compatibility fixes\event'
            if (-not (Test-Path -LiteralPath $ev)) {
                Fail "correctifs Enemy Randomizer absents de cette archive (attendu : Optional modifiers\Enemy Randomizer compatibility fixes\event)"
            }
            Copy-Tree $ev (Join-Path $dst 'event')
            Write-Log 'correctifs Enemy Randomizer appliques' -Level Ok
        }

        $mo = [math]::Round((Get-ChildItem $dst -Recurse -File | Measure-Object Length -Sum).Sum / 1MB, 1)
        Write-Log "$($m.Name) $version installe : $mo Mo deployes" -Level Ok

        return @{
            Dir           = $root
            Source        = $version
            ArenaTuning   = $tuning
            RandomizerFix = $fix
        }
    }

    Uninstall = {
        param($ctx, $st)
        Remove-IfPresent (Join-Path $ctx.Me3Profiles 'eldenring-bossarena') 'Boss Arena' | Out-Null
    }

    ProfileToml = {
        param($ctx)
        return @{
            Natives  = ''
            Packages = @"
# Boss Arena (Sandbox Mode). Package pur : regulation.bin et les dossiers du
# DVDBND sont projetes a la racine du jeu, en memoire, sans rien y ecrire.
# L'auteur livre son propre profil .me3 ; on n'en reprend que cette entree,
# le reste (native ersc.dll) etant deja gere par le module seamless-coop.
[[packages]]
id = "boss-arena"
enabled = true
path = "eldenring-bossarena/mod"
load_after = []
load_before = []
"@
        }
    }
}
