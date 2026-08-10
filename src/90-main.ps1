# ============================================================================ #
#  Point d'entree
# ============================================================================ #

function Show-ModuleList {
    Write-Host ''
    Write-Host "  me3-elden-ring-setup $($script:SetupVersion) - modules disponibles" -ForegroundColor Cyan
    Write-Host ''
    foreach ($m in Get-AllModules) {
        $flag = '     '
        if ($m.Default) { $flag = ' [x] ' }
        Write-Host ("{0}{1,-16} {2,-22} {3}" -f $flag, $m.Key, $m.Version, $m.Name) -ForegroundColor White
        Write-Host ("                     $($m.Summary)") -ForegroundColor Gray
        if ($m.Url) { Write-Host ("                     $($m.Url)") -ForegroundColor DarkGray }
        if ($m.TouchesGame) { Write-Host '                     ecrit dans le dossier du jeu' -ForegroundColor DarkYellow }
        if ($m.Requires.Count) { Write-Host ("                     requiert : $($m.Requires -join ', ')") -ForegroundColor DarkGray }
        foreach ($o in $m.Options) {
            $scope = 'different chez chacun'
            if ($o.Shared) { $scope = 'identique chez tous' }
            # Les reglages techniques ne sont pas montres par l'assistant, qui
            # les demande au moment utile : on le signale ici.
            if ($o.ContainsKey('Advanced') -and $o.Advanced) { $scope = 'avance, masque dans l''assistant' }
            Write-Host ("                       -Option @{{ {0} = ... }}  defaut '{1}'  ({2})" -f $o.Key, $o.Default, $scope) -ForegroundColor DarkGray
        }
        Write-Host ''
    }
    Write-Host '  [x] = selectionne par defaut' -ForegroundColor DarkGray
    Write-Host ''
}

if ($ListModules) {
    Show-ModuleList
    return
}

if (-not $Mode -and -not $NoGui) {
    Show-SetupWizard
    return
}

if (-not $Mode) { $Mode = 'Install' }

if ($Mode -eq 'Uninstall') {
    Invoke-Removal
    return
}

# --- selection des modules -------------------------------------------------- #
$prior = Get-State
$priorKeys = @()
$priorOptions = @{}
if ($prior) {
    if ($prior.PSObject.Properties['modules']) { $priorKeys = @((ConvertTo-Hashtable $prior.modules).Keys) }
    if ($prior.PSObject.Properties['options']) { $priorOptions = ConvertTo-Hashtable $prior.options }
}

# Les cles venant de l'etat sont filtrees : un module retire de l'installeur
# depuis la derniere fois ne doit pas faire echouer toute l'operation.
if ($AllModules) { $keys = @(Get-AllModules | ForEach-Object { $_.Key }) }
elseif ($Modules) { $keys = $Modules }
elseif ($priorKeys.Count) { $keys = Select-KnownModuleKeys $priorKeys }
else { $keys = Get-DefaultModuleKeys }

if (-not $keys.Count) { $keys = Get-DefaultModuleKeys }

$selected = @(Resolve-ModuleSelection $keys)

# --- dossier du jeu --------------------------------------------------------- #
$gameDir = $GamePath
if (-not (Test-GamePath $gameDir) -and $prior -and $prior.PSObject.Properties['gamePath']) {
    $gameDir = "$($prior.gamePath)"
}
if (-not (Test-GamePath $gameDir)) {
    Write-Log 'recherche du jeu...'
    $gameDir = Find-GamePath
}
if (-not (Test-GamePath $gameDir)) {
    Fail 'eldenring.exe introuvable. Relance avec -GamePath "X:\...\ELDEN RING\Game".'
}

$options = Resolve-Options -ModuleList $selected -Previous $priorOptions -Provided $Option

Invoke-Setup -RunMode $Mode -GameDir $gameDir -SelectedModules $selected -Options $options
