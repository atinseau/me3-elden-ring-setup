# ---------------------------------------------------------------------------- #
#  Seamless Co-op - multijoueur sans serveurs FromSoftware
#
#  La DLL est declaree A LA FOIS en [[natives]] et en [[packages]] : me3
#  n'ajoute pas le dossier d'un native a son VFS, donc ersc.dll ne trouverait
#  pas son ersc_settings.ini avec la seule entree native. Le package projette le
#  dossier a la racine du jeu, en memoire, sans rien y ecrire.
#  Voir https://github.com/garyttierney/me3/discussions/435
# ---------------------------------------------------------------------------- #

# ---------------------------------------------------------------------------- #
#  Liste blanche des versions
#
#  L'auteur du mod maintient un fichier VERSION a la racine de son depot, que le
#  mod telecharge au lancement. Chaque ligne vaut "<version> <0|1>", 0 signifiant
#  que la version est refusee. Une version refusee affiche « This version of
#  Seamless Co-op is out of date » et le mod ne demarre pas.
#
#  On lit donc cette liste AVANT d'installer, pour choisir une version qui
#  fonctionnera, ou pour le dire clairement quand aucune n'est disponible.
# ---------------------------------------------------------------------------- #

$script:ErscVersionUrl = 'https://raw.githubusercontent.com/yuiamoroll/EldenRingSeamlessCoopRelease/main/VERSION'

# Miroir de secours servi par ce depot, parce que le miroir officiel n'a pas
# suivi Nexus et que Nexus interdit le telechargement automatise. Sa version est
# connue, donc elle reste soumise a la liste blanche comme les autres : le jour
# ou l'auteur la refusera, l'installeur le detectera au lieu de servir aveugle-
# ment une archive morte.
$script:ErscMirrorUrl = 'https://raw.githubusercontent.com/atinseau/me3-elden-ring-setup/main/vendor/SeamlessCoop-v1.9.9.zip'
$script:ErscMirrorVersion = 'v1.9.9'

function Get-ErscUsableSource {
    <#
        Choisit la source a utiliser, dans l'ordre : une release officielle
        encore autorisee, puis le miroir de ce depot si sa version l'est aussi.
        Retourne $null quand aucune ne convient.
    #>
    param($Policy)

    $m = Get-Me3Module 'seamless-coop'
    foreach ($r in (Get-GitHubReleaseList -Repo $m.Repo)) {
        if ((Test-ErscVersionAllowed $Policy $r.tag_name) -ne $false) {
            return @{ Kind = 'release'; Tag = $r.tag_name }
        }
    }
    if ((Test-ErscVersionAllowed $Policy $script:ErscMirrorVersion) -ne $false) {
        return @{ Kind = 'mirror'; Tag = $script:ErscMirrorVersion; Url = $script:ErscMirrorUrl }
    }
    return $null
}

function ConvertTo-ErscVersionKey {
    <# 'v1.9.8' -> '1.98', la forme utilisee dans le fichier VERSION. #>
    param([string]$Tag)
    $p = ($Tag -replace '^v', '') -split '\.'
    if ($p.Count -lt 3) { return ($Tag -replace '^v', '') }
    return "$($p[0]).$($p[1])$($p[2])"
}

function Get-ErscVersionPolicy {
    <# @{ Exact = @{cle=$bool}; Above = @(@{Ver;Ok}) }, ou $null si indisponible. #>
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $raw = (Invoke-WebRequest $script:ErscVersionUrl -UseBasicParsing `
                -Headers @{ 'User-Agent' = 'me3-elden-ring-setup' }).Content
    }
    catch {
        # Liste inaccessible : on n'empeche pas l'installation pour autant.
        Write-Log 'liste des versions autorisees inaccessible, controle ignore' -Level Warn
        return $null
    }
    finally { $ProgressPreference = $old }

    $exact = @{}
    $above = New-Object System.Collections.Generic.List[hashtable]
    foreach ($line in ($raw -split "`r?`n")) {
        $t = $line.Trim()
        if (-not $t) { continue }
        $p = $t -split '\s+'
        if ($p.Count -lt 2) { continue }
        $ok = ($p[1] -eq '1')
        if ($p[0].StartsWith('>')) {
            # InvariantCulture : en francais, [double]'1.99' donnerait 199.
            $n = 0.0
            if ([double]::TryParse($p[0].Substring(1), [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
                $above.Add(@{ Ver = $n; Ok = $ok })
            }
        }
        else { $exact[$p[0]] = $ok }
    }
    return @{ Exact = $exact; Above = @($above) }
}

function Test-ErscVersionAllowed {
    <# $true / $false, ou $null quand la liste ne tranche pas. #>
    param($Policy, [string]$Tag)
    if (-not $Policy) { return $null }

    $key = ConvertTo-ErscVersionKey $Tag
    if ($Policy.Exact.ContainsKey($key)) { return $Policy.Exact[$key] }

    $n = 0.0
    if (-not [double]::TryParse($key, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $null }
    foreach ($r in $Policy.Above) { if ($n -gt $r.Ver) { return $r.Ok } }
    return $null
}

function Get-ErscMinimumAllowed {
    <# Seuil au-dessus duquel les versions sont acceptees, pour le message. #>
    param($Policy)
    if (-not $Policy) { return $null }
    $ok = @($Policy.Above | Where-Object { $_.Ok })
    if (-not $ok.Count) { return $null }
    return ($ok | Sort-Object { $_.Ver } | Select-Object -First 1).Ver
}

Register-Me3Module @{
    Key     = 'seamless-coop'
    Name    = 'Seamless Co-op'
    Version = 'derniere publiee'
    Summary = 'Remplace le P2P du jeu : jusqu''a 6 joueurs, sans mur de brouillard ni deconnexion apres un boss. Session privee par mot de passe.'
    Url     = 'https://github.com/yuiamoroll/EldenRingSeamlessCoopRelease'
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
            Key     = 'ModLanguage'
            Label   = 'Langue du mod'
            Type    = 'string'
            Default = 'english'
            Shared  = $false
            Help    = 'Langue des messages du mod, pas du jeu. Les versions recentes ne livrent que l''anglais : laisser vide ferait afficher un avertissement « french not found » a chaque lancement. Mets le nom d''une locale livree avec le mod pour en changer.'
        }
        # Les deux reglages suivants sont de la plomberie : ils contournent le
        # fait que Nexus interdit le telechargement automatise. L'assistant ne
        # les affiche pas, il demande le fichier au moment ou il en a besoin.
        # Ils restent accessibles en ligne de commande.
        @{
            Key      = 'ErscUrl'
            Label    = 'URL directe (miroir)'
            Type     = 'string'
            Default  = ''
            Shared   = $true
            Advanced = $true
            Help     = 'URL d''une archive .zip a telecharger, par exemple ton propre miroir. Prioritaire sur le reglage Version.'
        }
        @{
            Key      = 'ErscArchive'
            Label    = 'Archive .zip locale'
            Type     = 'string'
            Default  = ''
            Shared   = $true
            Advanced = $true
            Help     = 'Chemin d''une archive deja telechargee sur ce PC. Prioritaire sur tout le reste.'
        }
    )

    Preflight = {
        param($options)

        # Deja resolu par l'utilisateur ou par la CLI : rien a demander.
        if ("$($options.ErscArchive)".Trim() -or "$($options.ErscUrl)".Trim()) { return $null }

        $wanted = "$($options.ErscVersion)".Trim()
        if ($wanted -and $wanted -ne 'latest') { return $null }

        $policy = Get-ErscVersionPolicy
        if (-not $policy) { return $null }

        # Une source utilisable existe, miroir de ce depot compris : rien a
        # demander a l'utilisateur.
        if (Get-ErscUsableSource $policy) { return $null }

        $min = Get-ErscMinimumAllowed $policy
        $seuil = 'plus recente'
        if ($min) { $seuil = "superieure a $min" }

        return @{
            Title     = 'Seamless Co-op : telechargement manuel'
            Message   = @"
L'auteur de Seamless Co-op refuse desormais toutes les versions publiees sur son
miroir GitHub : le mod se declarerait perime et ne demarrerait pas.

Il faut une version $seuil, disponible uniquement sur Nexus Mods, qui exige un
compte et interdit le telechargement automatise. C'est la seule etape que
l'installeur ne peut pas faire a ta place.

  1. Ouvre la page ci-dessous, onglet FILES
  2. Bouton MANUAL DOWNLOAD sur la derniere version
  3. Indique ici le fichier .zip telecharge

Tu peux aussi continuer sans : les autres mods s'installeront normalement, mais
Seamless Co-op ne fonctionnera pas.
"@
            LinkUrl   = 'https://www.nexusmods.com/eldenring/mods/510?tab=files'
            LinkLabel = 'Ouvrir la page Nexus'
            OptionKey = 'ErscArchive'
            Filter    = 'Archive Seamless Co-op|*.zip|Tous les fichiers|*.*'
        }
    }

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
        # $null tant qu'on ne sait pas : une archive fournie a la main n'est pas
        # verifiable, son numero de version nous echappe.
        $allowed = $null

        $url = "$($ctx.Options.ErscUrl)".Trim()

        if ($archive) {
            if (-not (Test-Path -LiteralPath $archive)) { Fail "archive Seamless Co-op introuvable : $archive" }
            Write-Log "archive locale fournie : $archive"
            $version = "archive locale ($(Split-Path $archive -Leaf))"
            $src = Expand-Download @{ Kind = 'zip'; File = (Split-Path $archive -Leaf) } $archive $m.Key
        }
        elseif ($url) {
            # Miroir personnel : la version n'est pas deductible de l'URL, donc
            # pas de controle contre la liste blanche. C'est assume, celui qui
            # heberge sait ce qu'il publie.
            Write-Log "miroir personnel : $url"
            $name = [IO.Path]::GetFileName(([uri]$url).LocalPath)
            if (-not $name -or $name -notmatch '\.zip$') { $name = 'ersc-mirror.zip' }
            $dl = @{ Url = $url; File = $name; Kind = 'zip'; Sha256 = $null }
            $version = "miroir ($name)"
            $src = Expand-Download $dl (Get-Download $dl "$($m.Name) depuis un miroir personnel") $m.Key
        }
        else {
            $policy = Get-ErscVersionPolicy

            if ($wanted -eq 'latest') {
                # On ne prend pas betement la plus recente : on prend la plus
                # recente que l'auteur autorise encore, miroir de ce depot
                # compris.
                $source = Get-ErscUsableSource $policy

                if ($source -and $source.Kind -eq 'mirror') {
                    Write-Log "aucune release officielle autorisee, miroir de ce depot retenu : $($source.Tag)"
                    $dl = @{ Url = $source.Url; File = "SeamlessCoop-$($source.Tag).zip"; Kind = 'zip'; Sha256 = $null }
                    $version = $source.Tag
                    $allowed = Test-ErscVersionAllowed $policy $version
                    $src = Expand-Download $dl (Get-Download $dl "$($m.Name) $version (miroir)") $m.Key
                    $useResolved = $false
                }
                elseif ($source) {
                    $wanted = $source.Tag
                    Write-Log "version retenue : $wanted"
                    $useResolved = $true
                }
                else {
                    $wanted = (Get-GitHubReleaseList -Repo $m.Repo)[0].tag_name
                    $min = Get-ErscMinimumAllowed $policy
                    Write-Log 'AUCUNE source disponible n''est autorisee par l''auteur du mod.' -Level Warn
                    if ($min) { Write-Log "il faut une version superieure a $min." -Level Warn }
                    Write-Log 'Le mod refusera de demarrer avec le message « out of date ».' -Level Warn
                    Write-Log 'Recupere l''archive sur https://www.nexusmods.com/eldenring/mods/510?tab=files (Manual Download).' -Level Warn
                    $useResolved = $true
                }
            }
            else {
                $useResolved = $true
                if ((Test-ErscVersionAllowed $policy $wanted) -eq $false) {
                    Write-Log "la version $wanted est refusee par l'auteur du mod : elle ne demarrera pas." -Level Warn
                    $min = Get-ErscMinimumAllowed $policy
                    if ($min) { Write-Log "il faut une version superieure a $min." -Level Warn }
                }
            }

            if ($useResolved) {
                $dl = Get-GitHubReleaseAsset -Repo $m.Repo -Tag $wanted
                $version = $dl.Version
                $allowed = Test-ErscVersionAllowed $policy $version
                $src = Expand-Download $dl (Get-Download $dl "$($m.Name) $version") $m.Key
            }
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
        $lang = "$($ctx.Options.ModLanguage)".Trim()
        $ini = Join-Path $root 'SeamlessCoop\ersc_settings.ini'
        $content = (Get-Content $ini -Raw) -replace '(?m)^\s*cooppassword\s*=.*$', "cooppassword = $pass"

        # Sans valeur explicite, le mod suit la langue du jeu et avertit quand
        # la traduction correspondante n'est pas livree, ce qui est le cas de
        # toutes sauf l'anglais depuis la v1.9.x.
        $content = $content -replace '(?m)^\s*mod_language_override\s*=.*$', "mod_language_override = $lang"
        Write-TextFile $ini $content

        $locales = @(Get-ChildItem (Join-Path $root 'SeamlessCoop\locale') -Filter '*.json' -ErrorAction SilentlyContinue |
                ForEach-Object { $_.BaseName })
        if ($lang -and $locales.Count -and ($locales -notcontains $lang)) {
            Write-Log "la langue '$lang' n'est pas livree par cette version (disponibles : $($locales -join ', '))" -Level Warn
        }

        Write-Log "$($m.Name) $version installe (mot de passe : $pass)" -Level Ok
        if ($allowed -eq $false) {
            Write-Log 'mais cette version est refusee par l''auteur : le jeu affichera « out of date ».' -Level Warn
        }
        return @{ Dir = $root; Password = $pass; Source = $version; VersionAllowed = $allowed }
    }

    Uninstall = {
        param($ctx, $st)
        Remove-IfPresent (Join-Path $ctx.Me3Profiles 'eldenring-ersc') 'Seamless Co-op' | Out-Null

        # A l'execution, crashpad cree <jeu>\SeamlessCoop\crashdumps\ : ce chemin
        # n'est pas dans le package, il tombe donc sur le disque reel. On nettoie,
        # mais jamais une installation manuelle de l'utilisateur : la presence
        # d'ersc.dll signale que ce dossier ne nous appartient pas.
        $stray = Join-Path $ctx.GamePath 'SeamlessCoop'
        if ((Test-Path $stray) -and -not (Get-ChildItem $stray -Recurse -Filter 'ersc.dll' -ErrorAction SilentlyContinue)) {
            Remove-IfPresent $stray 'SeamlessCoop\ (crashdumps generes a l''execution)' | Out-Null
        }
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
