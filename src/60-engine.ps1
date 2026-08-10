# ============================================================================ #
#  Moteur : orchestration Install / Repair / Uninstall
# ============================================================================ #

function Build-Me3Profile {
    <#
        Assemble le fichier .me3 a partir des contributions des modules retenus.
        L'installeur ne connait aucun mod : il concatene ce que chacun declare.
    #>
    param([Parameter(Mandatory)][object[]]$ModuleList, [Parameter(Mandatory)][hashtable]$Context)

    $natives = New-Object System.Collections.Generic.List[string]
    $packages = New-Object System.Collections.Generic.List[string]

    foreach ($m in $ModuleList) {
        $frag = & $m.ProfileToml $Context
        if ($frag -and $frag.Natives) { $natives.Add($frag.Natives.TrimEnd()) }
        if ($frag -and $frag.Packages) { $packages.Add($frag.Packages.TrimEnd()) }
    }

    # Package d'assets toujours present : c'est le dossier ou l'utilisateur
    # depose ses propres mods de textures, cartes, etc.
    $packages.Add(@"
# Depose ici tes mods d'assets (un dossier par mod, hierarchie du DVDBND).
[[packages]]
enabled = true
path = "eldenring-mods"
load_after = []
load_before = []
"@)

    $nativesText = '# Aucun mod DLL selectionne.'
    if ($natives.Count) { $nativesText = ($natives -join "`n`n") }

    return @"
profileVersion = "v1"

# Genere par me3-elden-ring-setup $($script:SetupVersion)
# Modules : $(($ModuleList | ForEach-Object { $_.Key }) -join ', ')
#
# Ce fichier est REECRIT a chaque installation ou reparation. Pour ajouter un
# mod durablement, ecris un module dans src/modules/ plutot que d'editer ici.

[[supports]]
game = "eldenring"

# ---------------------------------------------------------------------------
# Native DLL mods. Chemins relatifs a CE fichier.
# ---------------------------------------------------------------------------

$nativesText

# ---------------------------------------------------------------------------
# Packages. Le hook CreateFileW de me3 retire le dossier du jeu du chemin
# demande puis cherche la cle parmi les fichiers des packages : un package sert
# donc n'importe quel fichier a la racine du jeu, sans rien y ecrire.
# ---------------------------------------------------------------------------

$($packages -join "`n`n")

[debug_properties]
"@
}

function Invoke-Setup {
    <# Installation ou reparation. #>
    param(
        [Parameter(Mandatory)][ValidateSet('Install', 'Repair')][string]$RunMode,
        [Parameter(Mandatory)][string]$GameDir,
        [Parameter(Mandatory)][object[]]$SelectedModules,
        [Parameter(Mandatory)][hashtable]$Options
    )

    $verb = 'Installation'
    if ($RunMode -eq 'Repair') { $verb = 'Reparation' }
    Write-Log "$verb - me3-elden-ring-setup $($script:SetupVersion)" -Level Step

    if (-not (Test-GamePath $GameDir)) {
        Fail "eldenring.exe introuvable dans : $GameDir"
    }
    if (Test-GameRunning) {
        Fail 'ELDEN RING tourne. Ferme le jeu avant de continuer.'
    }
    $gameExe = Join-Path $GameDir 'eldenring.exe'
    Write-Log "jeu : $gameExe" -Level Ok
    Write-Log "modules : $(($SelectedModules | ForEach-Object { $_.Key }) -join ', ')"

    $prior = Get-State
    $priorModules = @{}
    if ($prior -and $prior.PSObject.Properties['modules']) {
        $priorModules = ConvertTo-Hashtable $prior.modules
    }

    $ctx = New-ModuleContext -GameDir $GameDir -Options $Options -RunMode $RunMode -PreviousModuleState $priorModules

    # --- me3 ---------------------------------------------------------------- #
    Write-Log 'me3' -Level Step
    $me3Ours = Install-Me3
    if ($prior -and $prior.PSObject.Properties['me3InstalledByUs'] -and $prior.me3InstalledByUs) {
        $me3Ours = $true   # une reparation ne doit pas perdre cette information
    }

    # --- modules retires depuis la derniere fois ---------------------------- #
    $selectedKeys = @($SelectedModules | ForEach-Object { $_.Key })
    $dropped = @($priorModules.Keys | Where-Object { $selectedKeys -notcontains $_ })
    if ($dropped.Count) {
        Write-Log 'Modules retires' -Level Step
        foreach ($key in $dropped) {
            $m = Get-Me3Module $key
            if (-not $m) { Write-Log "module '$key' inconnu de cette version, ignore" -Level Warn; continue }
            Write-Log "retrait de $($m.Name)"
            try { & $m.Uninstall $ctx (ConvertTo-Hashtable $priorModules[$key]) }
            catch { Write-Log "echec du retrait de $($m.Name) : $($_.Exception.Message)" -Level Warn }
        }
    }

    # --- installation des modules ------------------------------------------- #
    Write-Log 'Modules' -Level Step
    $newModuleState = @{}
    foreach ($m in $SelectedModules) {
        $st = & $m.Install $ctx
        if ($null -eq $st) { $st = @{} }
        $newModuleState[$m.Key] = $st
    }

    # --- profil me3 --------------------------------------------------------- #
    Write-Log 'Profil me3' -Level Step
    New-Item -ItemType Directory -Force (Join-Path $script:Me3Profiles 'eldenring-mods') | Out-Null
    $profilePath = Join-Path $script:Me3Profiles "$($script:ProfileName).me3"
    Write-TextFile $profilePath (Build-Me3Profile -ModuleList $SelectedModules -Context $ctx)
    Write-Log "profil '$($script:ProfileName)' ecrit" -Level Ok

    # --- lanceur ------------------------------------------------------------ #
    Write-Log 'Lanceur' -Level Step
    # Un seul module suffit a imposer --skip-steam-init : gbe_fork remplace
    # l'API Steam, l'init du launcher me3 echouerait (require_steam, 0x8007007E).
    $skip = 'false'
    if ($SelectedModules | Where-Object { $_.SkipSteamInit }) { $skip = 'true' }
    $script:LauncherSkipSteam = $skip
    $launcher = Install-Launcher -GameExe $gameExe

    # --- etat --------------------------------------------------------------- #
    Save-State @{
        gamePath         = $GameDir
        me3InstalledByUs = [bool]$me3Ours
        modules          = $newModuleState
        options          = $Options
        batPath          = $launcher.Bat
        shortcutPath     = $launcher.Lnk
    }

    # --- verification -------------------------------------------------------- #
    Write-Log 'Verification' -Level Step
    $me3 = Get-Me3Exe
    if ($me3) {
        foreach ($line in (Invoke-Native $me3 @('profile', 'show', $script:ProfileName))) { Write-Log "$line" }
    }

    Write-ResultSummary -ModuleList $SelectedModules -Options $Options -ModuleState $newModuleState
    Write-Log "$verb terminee" -Level Step
}

function Write-ResultSummary {
    param([object[]]$ModuleList, [hashtable]$Options, [hashtable]$ModuleState)

    $shared = New-Object System.Collections.Generic.List[string]
    $local = New-Object System.Collections.Generic.List[string]

    foreach ($m in $ModuleList) {
        foreach ($o in $m.Options) {
            $value = $Options[$o.Key]
            # Une option laissee vide a pu etre calculee a l'installation
            # (SteamId genere) : on relit alors l'etat du module.
            if ((-not $value) -and $ModuleState.ContainsKey($m.Key)) {
                $st = ConvertTo-Hashtable $ModuleState[$m.Key]
                if ($st.ContainsKey($o.Key)) { $value = $st[$o.Key] }
            }
            $line = "   {0,-27} {1}" -f $o.Label, $value
            if ($o.Shared) { $shared.Add($line) } else { $local.Add($line) }
        }
    }

    Write-Log ''
    if ($shared.Count) {
        Write-Log 'A GARDER IDENTIQUE chez tous les joueurs :'
        foreach ($l in $shared) { Write-Log $l }
    }
    if ($local.Count) {
        Write-Log 'A GARDER DIFFERENT chez chacun :'
        foreach ($l in $local) { Write-Log $l }
    }
    if ($ModuleList | Where-Object { $_.SkipSteamInit }) {
        Write-Log ''
        Write-Log 'Pense a autoriser eldenring.exe dans le pare-feu, en UDP et en TCP.'
    }
    Write-Log ''
    Write-Log "Lance la partie avec le raccourci 'Elden Ring (me3)' sur le bureau."
}

function Invoke-Removal {
    Write-Log "Desinstallation - me3-elden-ring-setup $($script:SetupVersion)" -Level Step

    $state = Get-State
    if (-not $state) {
        Fail "aucune installation enregistree ($script:StateFile absent). Rien n'a ete touche."
    }
    if (Test-GameRunning) {
        Fail 'ELDEN RING tourne. Ferme le jeu avant de desinstaller.'
    }

    $gameDir = ''
    if ($state.PSObject.Properties['gamePath']) { $gameDir = "$($state.gamePath)" }
    $opts = @{}
    if ($state.PSObject.Properties['options']) { $opts = ConvertTo-Hashtable $state.options }
    $modState = @{}
    if ($state.PSObject.Properties['modules']) { $modState = ConvertTo-Hashtable $state.modules }

    $ctx = New-ModuleContext -GameDir $gameDir -Options $opts -RunMode 'Uninstall'

    # --- modules ------------------------------------------------------------ #
    Write-Log 'Modules' -Level Step
    if (-not $modState.Keys.Count) { Write-Log 'aucun module enregistre' }
    # Ordre inverse de l'installation : les dependances partent en dernier.
    $ordered = @(Get-AllModules | Where-Object { $modState.ContainsKey($_.Key) })
    [array]::Reverse($ordered)
    foreach ($m in $ordered) {
        Write-Log "retrait de $($m.Name)"
        try { & $m.Uninstall $ctx (ConvertTo-Hashtable $modState[$m.Key]) }
        catch { Write-Log "echec du retrait de $($m.Name) : $($_.Exception.Message)" -Level Warn }
    }
    foreach ($key in $modState.Keys) {
        if (-not (Get-Me3Module $key)) {
            Write-Log "module '$key' inconnu de cette version : rien retire pour lui" -Level Warn
        }
    }

    # --- lanceur ------------------------------------------------------------ #
    Write-Log 'Lanceur' -Level Step
    if ($state.PSObject.Properties['shortcutPath']) { Remove-IfPresent "$($state.shortcutPath)" 'raccourci bureau' | Out-Null }
    if ($state.PSObject.Properties['batPath']) { Remove-IfPresent "$($state.batPath)" 'script de lancement' | Out-Null }

    # --- profil ------------------------------------------------------------- #
    Write-Log 'Profil me3' -Level Step
    Remove-IfPresent (Join-Path $script:Me3Profiles "$($script:ProfileName).me3") "profil $($script:ProfileName).me3" | Out-Null

    # --- me3 : seulement si c'est nous qui l'avons pose --------------------- #
    Write-Log 'me3' -Level Step
    if ($state.PSObject.Properties['me3InstalledByUs'] -and $state.me3InstalledByUs) {
        Uninstall-Me3
    }
    else {
        Write-Log 'me3 etait deja present avant cet installeur : conserve, ainsi que tes autres profils' -Level Ok
    }

    Remove-IfPresent $script:WorkDir | Out-Null
    Remove-IfPresent $script:StateDir | Out-Null

    Write-Log 'Desinstallation terminee' -Level Step
}
