# ============================================================================ #
#  Registre des modules
#
#  Un module decrit un mod de bout en bout. L'installeur n'en connait aucun en
#  dur : il parcourt ce registre.
#
#  Contrat d'un module :
#
#    Key           identifiant court, en minuscules, utilise en CLI et en etat
#    Name          nom affiche
#    Version       version epinglee, affichee dans les resumes
#    Summary       une ligne de description
#    Url           page du projet, pour la documentation
#    Default       selectionne par defaut ?
#    Order         ordre d'installation et d'affichage (croissant)
#    Requires      cles d'autres modules necessaires
#    TouchesGame   ecrit-il dans le dossier du jeu ? (affiche un avertissement)
#    SkipSteamInit impose --skip-steam-init true au lanceur
#    Options       reglages exposes a l'utilisateur, voir plus bas
#    Downloads     table de descripteurs @{ Url; File; Kind; Sha256 }
#    Install       scriptblock($ctx) -> hashtable d'etat propre au module
#    Uninstall     scriptblock($ctx, $moduleState)
#    ProfileToml   scriptblock($ctx) -> @{ Natives = '...'; Packages = '...' }
#
#  Une option :
#    @{ Key; Label; Type = 'string'|'int'|'password'; Default; Shared; Help }
#    Shared = $true signale un reglage qui doit etre IDENTIQUE chez tous les
#    joueurs ; l'installeur le met en avant dans le resume final.
# ============================================================================ #

$script:ModuleRegistry = [ordered]@{}

function Register-Me3Module {
    param([Parameter(Mandatory)][hashtable]$Module)

    foreach ($required in @('Key', 'Name', 'Version', 'Summary', 'Install')) {
        if (-not $Module.ContainsKey($required)) {
            throw "module invalide : champ '$required' manquant"
        }
    }

    # Valeurs par defaut, pour que le reste du code n'ait jamais a tester
    # l'existence d'une cle.
    foreach ($kv in @{
            Url           = ''
            Default       = $false
            Order         = 100
            Requires      = @()
            TouchesGame   = $false
            SkipSteamInit = $false
            Options       = @()
            Downloads     = @{}
            Uninstall     = { param($ctx, $st) }
            ProfileToml   = { param($ctx) return @{ Natives = ''; Packages = '' } }
        }.GetEnumerator()) {
        if (-not $Module.ContainsKey($kv.Key)) { $Module[$kv.Key] = $kv.Value }
    }

    $script:ModuleRegistry[$Module.Key] = $Module
}

function Get-AllModules {
    return @($script:ModuleRegistry.Values | Sort-Object { $_.Order }, { $_.Name })
}

function Get-Me3Module {
    param([Parameter(Mandatory)][string]$Key)
    if ($script:ModuleRegistry.Contains($Key)) { return $script:ModuleRegistry[$Key] }
    return $null
}

function Get-DefaultModuleKeys {
    return @(Get-AllModules | Where-Object { $_.Default } | ForEach-Object { $_.Key })
}

function Resolve-ModuleSelection {
    <#
        Complete une selection avec les dependances declarees, puis la trie dans
        l'ordre d'installation. Signale les cles inconnues.
    #>
    param([string[]]$Keys)

    $wanted = New-Object System.Collections.Generic.HashSet[string]
    foreach ($k in @($Keys)) {
        if (-not $k) { continue }
        $key = $k.Trim().ToLower()
        if (-not (Get-Me3Module $key)) { Fail "module inconnu : '$key'. Utilise -ListModules pour la liste." }
        [void]$wanted.Add($key)
    }

    # Fermeture transitive des dependances
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($key in @($wanted)) {
            foreach ($dep in (Get-Me3Module $key).Requires) {
                if (-not $wanted.Contains($dep)) {
                    if (-not (Get-Me3Module $dep)) { Fail "le module '$key' depend de '$dep', qui n'existe pas" }
                    [void]$wanted.Add($dep)
                    Write-Log "'$dep' ajoute : requis par '$key'"
                    $changed = $true
                }
            }
        }
    }

    return @(Get-AllModules | Where-Object { $wanted.Contains($_.Key) })
}

function Select-KnownModuleKeys {
    <#
        Filtre des cles venant de l'etat enregistre, qui peut mentionner un
        module retire de l'installeur depuis. Un module disparu ne doit pas
        empecher de reparer les autres : on l'ignore en le signalant.

        A ne pas utiliser pour les cles saisies par l'utilisateur : la, une cle
        inconnue est une faute de frappe et doit echouer franchement.
    #>
    param([string[]]$Keys, [string]$Context = "l'etat enregistre")

    $known = New-Object System.Collections.Generic.List[string]
    foreach ($k in @($Keys)) {
        if (-not $k) { continue }
        $key = $k.Trim().ToLower()
        if (Get-Me3Module $key) {
            $known.Add($key)
        }
        else {
            Write-Log "module '$key' present dans $Context mais inconnu de cette version : ignore" -Level Warn
            Write-Log "ses fichiers ne seront pas touches ; installe une version de l'installeur qui le connait pour le retirer proprement." -Level Warn
        }
    }
    return @($known)
}

function Get-ModuleOptionDefaults {
    <# Fusionne les valeurs par defaut de tous les modules donnes. #>
    param([object[]]$ModuleList)
    $opts = @{}
    foreach ($m in $ModuleList) {
        foreach ($o in $m.Options) { $opts[$o.Key] = $o.Default }
    }
    return $opts
}

function Resolve-Options {
    <#
        Defauts des modules, puis valeurs de l'etat precedent, puis valeurs
        fournies par l'utilisateur : la derniere source l'emporte.
    #>
    param([object[]]$ModuleList, [hashtable]$Previous = @{}, [hashtable]$Provided = @{})

    $opts = Get-ModuleOptionDefaults $ModuleList

    foreach ($k in @($opts.Keys)) {
        if ($Previous.ContainsKey($k) -and $null -ne $Previous[$k] -and "$($Previous[$k])" -ne '') {
            $opts[$k] = $Previous[$k]
        }
    }
    foreach ($k in $Provided.Keys) {
        $opts[$k] = $Provided[$k]
    }

    # Typage : les champs texte de l'interface et la CLI livrent des chaines.
    foreach ($m in $ModuleList) {
        foreach ($o in $m.Options) {
            if ($o.Type -eq 'int' -and $null -ne $opts[$o.Key]) {
                $parsed = 0
                if ([int]::TryParse("$($opts[$o.Key])", [ref]$parsed)) { $opts[$o.Key] = $parsed }
                else { Fail "l'option '$($o.Label)' attend un entier, recu '$($opts[$o.Key])'" }
            }
        }
    }

    return $opts
}

function New-ModuleContext {
    param(
        [Parameter(Mandatory)][string]$GameDir,
        [Parameter(Mandatory)][hashtable]$Options,
        [Parameter(Mandatory)][string]$RunMode,
        [hashtable]$PreviousModuleState = @{}
    )
    return @{
        GamePath      = $GameDir
        GameExe       = (Join-Path $GameDir 'eldenring.exe')
        Me3Profiles   = $script:Me3Profiles
        Me3DataDir    = $script:Me3DataDir
        WorkDir       = $script:WorkDir
        AppId         = $script:EldenRingAppId
        Options       = $Options
        Mode          = $RunMode
        IsRepair      = ($RunMode -eq 'Repair')
        ModuleState   = $PreviousModuleState
    }
}
