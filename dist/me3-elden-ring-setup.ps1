# =========================================================================== #
#  me3-elden-ring-setup 1.0.0
#
#  FICHIER GENERE - NE PAS EDITER
#  Produit par Build.ps1 a partir de src/. Toute modification directe sera
#  perdue a la prochaine compilation. Pour ajouter un mod, cree un fichier
#  dans src/modules/ puis relance Build.ps1.
#
#  https://github.com/atinseau/me3-elden-ring-setup
# =========================================================================== #
#region ---- 00-header.ps1 -----------------------------------------------
<#
.SYNOPSIS
    Installeur modulaire de mods Elden Ring, orchestres par me3.

.DESCRIPTION
    Deploie me3 puis les mods choisis, cree un raccourci de lancement, et sait
    tout retirer en restaurant les fichiers d'origine.

    L'installeur ne connait aucun mod en dur : chaque mod est un module qui
    declare ses telechargements, ses options, son installation, sa desinstallation
    et sa contribution au profil me3. Ajouter un mod = ajouter un fichier dans
    src/modules/ puis relancer Build.ps1.

    Trois modes :
      Install    deploie les modules selectionnes
      Repair     retelecharge et redeploie sans regenerer les identites locales
      Uninstall  retire ce que l'installeur a pose et restaure les originaux

    Sans parametre, une interface graphique s'ouvre. Avec -Mode ou -NoGui,
    l'installeur fonctionne en ligne de commande.

    Aucun binaire n'est redistribue : tout est telecharge depuis les depots
    officiels a l'execution.

.PARAMETER Mode
    Install, Repair ou Uninstall.

.PARAMETER Modules
    Cles des modules a installer, separees par des virgules.
    Sans valeur, les modules marques par defaut sont retenus.

.PARAMETER AllModules
    Selectionne tous les modules disponibles.

.PARAMETER ListModules
    Affiche les modules disponibles avec leurs options, puis quitte.

.PARAMETER GamePath
    Dossier contenant eldenring.exe. Auto-detecte si omis.

.PARAMETER Option
    Table d'options de modules, par exemple @{ Framerate = 144; Port = 47600 }.

.PARAMETER Force
    Reinstalle me3 meme s'il est deja present.

.EXAMPLE
    .\me3-elden-ring-setup.ps1
    Ouvre l'interface graphique.

.EXAMPLE
    .\me3-elden-ring-setup.ps1 -ListModules

.EXAMPLE
    .\me3-elden-ring-setup.ps1 -Mode Install -NoGui `
        -Modules unlock-fps,gbe-fork,seamless-coop `
        -Option @{ PlayerName = 'bob'; CoopPassword = 'hidetower'; Framerate = 144 }

.EXAMPLE
    .\me3-elden-ring-setup.ps1 -Mode Uninstall -NoGui
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Repair', 'Uninstall')]
    [string]$Mode,

    [string[]]$Modules,
    [switch]$AllModules,
    [switch]$ListModules,

    [string]$GamePath,
    [hashtable]$Option = @{},

    [switch]$NoGui,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Emplacements standard. me3 les utilise en dur, on s'y aligne.
$script:Me3ProgramDir = Join-Path $env:LOCALAPPDATA 'Programs\garyttierney\me3'
$script:Me3DataDir    = Join-Path $env:LOCALAPPDATA 'garyttierney\me3'
$script:Me3Profiles   = Join-Path $script:Me3DataDir 'config\profiles'
$script:StateDir      = Join-Path $env:LOCALAPPDATA 'Me3EldenRingSetup'
$script:StateFile     = Join-Path $script:StateDir 'state.json'
$script:WorkDir       = Join-Path $env:TEMP 'me3-elden-ring-setup'

$script:ProfileName   = 'eldenring'
$script:EldenRingAppId = 1245620

# Version de me3 deployee quand il est absent de la machine.
$script:Me3Version = 'v0.12.1'
$script:Me3Url     = 'https://github.com/garyttierney/me3/releases/download/v0.12.1/me3-windows-amd64.zip'
#endregion

$script:SetupVersion = '1.0.0'
$script:LauncherSkipSteam = 'false'


#region ---- 10-core.ps1 -------------------------------------------------
# ============================================================================ #
#  Noyau : journalisation, etat persistant, fichiers, telechargements
# ============================================================================ #

# Rempli par l'interface graphique pour rediriger le journal vers la fenetre.
$script:LogSink = $null

function Write-Log {
    param(
        # AllowEmptyString : les lignes vides aerent les resumes, et la sortie
        # de me3 en contient.
        [Parameter(Position = 0)][AllowEmptyString()][string]$Message = '',
        [ValidateSet('Info', 'Ok', 'Warn', 'Error', 'Step')][string]$Level = 'Info'
    )

    $prefix = @{ Info = '   '; Ok = ' [OK] '; Warn = ' [!]  '; Error = ' [X]  '; Step = "`n== " }[$Level]
    $line = "$prefix$Message"

    if ($script:LogSink) {
        $script:LogSink.Invoke($line)
    }
    else {
        $color = @{ Info = 'Gray'; Ok = 'Green'; Warn = 'Yellow'; Error = 'Red'; Step = 'Cyan' }[$Level]
        Write-Host $line -ForegroundColor $color
    }
}

function Fail {
    param([Parameter(Mandatory)][string]$Message)
    Write-Log $Message -Level Error
    throw $Message
}

# ---------------------------------------------------------------------------- #
#  Etat persistant
#
#  Sans ce fichier, une desinstallation ignorerait ce qui existait avant nous :
#  quels modules ont ete poses, et surtout si me3 etait deja la (auquel cas il
#  ne faut pas y toucher).
# ---------------------------------------------------------------------------- #

function Get-State {
    if (-not (Test-Path $script:StateFile)) { return $null }
    try { return Get-Content $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch {
        Write-Log "state.json illisible, ignore : $($_.Exception.Message)" -Level Warn
        return $null
    }
}

function Save-State {
    param([Parameter(Mandatory)][hashtable]$State)
    New-Item -ItemType Directory -Force $script:StateDir | Out-Null
    $State['setupVersion'] = $script:SetupVersion
    $State['savedAt'] = (Get-Date).ToString('o')
    $State | ConvertTo-Json -Depth 8 | Set-Content $script:StateFile -Encoding UTF8
}

# Convertit un PSCustomObject issu de ConvertFrom-Json en hashtable, pour
# pouvoir le remanier. ConvertFrom-Json -AsHashtable n'existe pas en PS 5.1.
function ConvertTo-Hashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return @{} }
    if ($InputObject -is [hashtable]) { return $InputObject }
    $h = @{}
    foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

# ---------------------------------------------------------------------------- #
#  Fichiers
# ---------------------------------------------------------------------------- #

# Windows PowerShell ecrit de l'UTF-8 AVEC BOM. Un BOM en tete d'un .ini casse
# la lecture de la premiere cle par la plupart des parseurs C/C++ (gbe_fork,
# Seamless Co-op). On ecrit donc sans BOM, explicitement.
function Write-TextFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [ValidateSet('Utf8NoBom', 'Ascii')][string]$As = 'Utf8NoBom'
    )
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }

    if ($As -eq 'Ascii') { $enc = New-Object System.Text.ASCIIEncoding }
    else { $enc = New-Object System.Text.UTF8Encoding($false) }

    [System.IO.File]::WriteAllText($Path, ($Content -replace "`r?`n", "`r`n"), $enc)
}

# Copy-Item -Recurse vers un dossier existant imbrique la copie au lieu de la
# fusionner (dst\src\...). On force la fusion pour que Install et Repair restent
# rejouables sans accumuler de dossiers.
function Copy-Tree {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    New-Item -ItemType Directory -Force $Destination | Out-Null
    Copy-Item (Join-Path $Source '*') $Destination -Recurse -Force
}

function Remove-IfPresent {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path, [string]$Label)
    if (-not $Path) { return $false }
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
        if ($Label) { Write-Log "retire : $Label" -Level Ok }
        return $true
    }
    return $false
}

# ---------------------------------------------------------------------------- #
#  Telechargement et extraction
# ---------------------------------------------------------------------------- #

function Get-Download {
    <#
        $Download = @{ Url; File; Kind = 'zip'|'7z'; Sha256 = $null|'...' }
        Retourne le chemin de l'archive telechargee.
    #>
    param([Parameter(Mandatory)][hashtable]$Download, [Parameter(Mandatory)][string]$Label)

    New-Item -ItemType Directory -Force $script:WorkDir | Out-Null
    $dest = Join-Path $script:WorkDir $Download.File

    if (-not (Test-Path $dest)) {
        Write-Log "telechargement : $Label"
        $old = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest $Download.Url -OutFile $dest -UseBasicParsing }
        catch { Fail "echec du telechargement de $Label : $($_.Exception.Message)" }
        finally { $ProgressPreference = $old }
    }
    else {
        Write-Log "deja telecharge : $Label"
    }

    $hash = (Get-FileHash $dest -Algorithm SHA256).Hash
    if ($Download.Sha256) {
        if ($hash -ne $Download.Sha256.ToUpper()) {
            Remove-Item $dest -Force
            Fail "checksum invalide pour $Label. Attendu $($Download.Sha256), obtenu $hash"
        }
        Write-Log "checksum verifie : $Label" -Level Ok
    }
    else {
        Write-Log "sha256 $($hash.Substring(0, 16))... ($Label, pas de checksum publie)"
    }

    return $dest
}

function Expand-Download {
    <# Extrait l'archive dans un dossier de travail dedie et retourne son chemin. #>
    param(
        [Parameter(Mandatory)][hashtable]$Download,
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Key
    )

    $out = Join-Path $script:WorkDir "x-$Key"
    Remove-IfPresent $out | Out-Null
    New-Item -ItemType Directory -Force $out | Out-Null

    if ($Download.Kind -eq 'zip') {
        Expand-Archive $Archive -DestinationPath $out -Force
    }
    else {
        # bsdtar (tar.exe, livre avec Windows 10 1803+) sait lire le 7-Zip.
        if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
            Fail "tar.exe est introuvable : impossible d'extraire une archive .7z. Mets Windows a jour ou installe 7-Zip."
        }
        Push-Location $out
        try {
            & tar.exe -xf $Archive
            if ($LASTEXITCODE -ne 0) { Fail "tar a echoue sur $($Download.File) (code $LASTEXITCODE)" }
        }
        finally { Pop-Location }
    }
    return $out
}

# ---------------------------------------------------------------------------- #
#  Elevation ponctuelle
#
#  L'installeur s'execute sans droits administrateur. Certaines etapes en ont
#  pourtant besoin (les regles de pare-feu). Plutot que d'exiger une elevation
#  pour tout le script, on n'eleve que le fragment concerne, et seulement quand
#  c'est reellement necessaire.
# ---------------------------------------------------------------------------- #

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Elevated {
    <#
        Execute un fragment PowerShell avec les droits administrateur.
        Deja administrateur : execute sur place, sans invite UAC.
        Sinon : relance un PowerShell eleve. Un refus de l'invite UAC n'est pas
        une erreur fatale, l'appelant decide quoi en faire.

        Retourne $true si le fragment s'est execute et a rendu 0.
    #>
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$Purpose
    )

    if (Test-IsAdmin) {
        try {
            & ([scriptblock]::Create($Script))
            return $true
        }
        catch {
            Write-Log "$Purpose : $($_.Exception.Message)" -Level Warn
            return $false
        }
    }

    Write-Log "elevation demandee pour : $Purpose"
    Write-Log 'accepte l''invite Windows qui vient d''apparaitre.'

    # EncodedCommand : le fragment traverse la frontiere de processus sans etre
    # deforme par les regles de quoting de la ligne de commande.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    try {
        $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64"
        if ($p.ExitCode -eq 0) { return $true }
        Write-Log "$Purpose : le processus eleve a retourne $($p.ExitCode)" -Level Warn
        return $false
    }
    catch {
        # Cas courant : l'utilisateur a refuse l'invite UAC.
        Write-Log "$Purpose : elevation refusee ou impossible" -Level Warn
        return $false
    }
}

# ---------------------------------------------------------------------------- #
#  Resolution d'une release GitHub
#
#  Epingler une URL de telechargement condamne le module a se perimer. Les mods
#  qui refusent de demarrer quand une version plus recente existe (Seamless
#  Co-op le fait) doivent pouvoir suivre automatiquement.
# ---------------------------------------------------------------------------- #

function Get-GitHubReleaseAsset {
    <#
        Retourne @{ Url; File; Kind; Sha256; Version } pour une release GitHub.
        $Tag vaut 'latest' ou un tag precis.
    #>
    param(
        [Parameter(Mandatory)][string]$Repo,
        [string]$Tag = 'latest',
        [string]$Pattern = '\.zip$'
    )

    if ($Tag -eq 'latest') { $api = "https://api.github.com/repos/$Repo/releases/latest" }
    else { $api = "https://api.github.com/repos/$Repo/releases/tags/$Tag" }

    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $rel = Invoke-RestMethod $api -Headers @{ 'User-Agent' = 'me3-elden-ring-setup' }
    }
    catch {
        Fail "impossible d'interroger les releases de $Repo ($Tag) : $($_.Exception.Message)"
    }
    finally { $ProgressPreference = $old }

    $asset = @($rel.assets | Where-Object { $_.name -match $Pattern }) | Select-Object -First 1
    if (-not $asset) { Fail "aucune archive correspondant a '$Pattern' dans la release $($rel.tag_name) de $Repo" }

    return @{
        Url     = $asset.browser_download_url
        File    = $asset.name
        Kind    = 'zip'
        Sha256  = $null
        Version = $rel.tag_name
    }
}

# Execute un exe natif en capturant sa sortie sans utiliser de redirection.
# En Windows PowerShell 5.1, "2>$null" sur un exe natif emballe chaque ligne de
# stderr dans un ErrorRecord (NativeCommandError) et fait echouer l'appel, alors
# que me3 ecrit ses lignes INFO sur stderr en fonctionnement normal.
function Invoke-Native {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @())
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return (& $Exe @Arguments) }
    catch { return @() }
    finally { $ErrorActionPreference = $prev }
}
#endregion

#region ---- 20-detect.ps1 -----------------------------------------------
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
#endregion

#region ---- 30-me3.ps1 --------------------------------------------------
# ============================================================================ #
#  me3 : deploiement, lanceur
# ============================================================================ #

function Install-Me3 {
    <#
        Deploie me3 s'il est absent. Retourne $true si c'est CE script qui vient
        de l'installer : la desinstallation s'en sert pour ne pas retirer un me3
        que l'utilisateur avait deja.
    #>
    $existing = Get-Me3Exe
    if ($existing -and -not $Force) {
        Write-Log "me3 deja present ($(Get-Me3Version)), conserve tel quel" -Level Ok
        return $false
    }

    $dl = @{
        Url    = $script:Me3Url
        File   = 'me3-windows-amd64.zip'
        Kind   = 'zip'
        Sha256 = $null
    }
    $src = Expand-Download $dl (Get-Download $dl "me3 $script:Me3Version") 'me3'

    Copy-Tree (Join-Path $src 'bin') (Join-Path $script:Me3ProgramDir 'bin')
    foreach ($f in @('LICENSE-MIT', 'LICENSE-APACHE')) {
        $p = Join-Path $src $f
        if (Test-Path $p) { Copy-Item $p $script:Me3ProgramDir -Force }
    }

    # me3 lit sa config ici ; un fichier vide suffit, les defauts s'appliquent.
    $cfg = Join-Path $script:Me3ProgramDir 'config\me3.toml'
    if (-not (Test-Path $cfg)) { Write-TextFile $cfg '' }

    New-Item -ItemType Directory -Force $script:Me3Profiles | Out-Null
    Write-Log "me3 $script:Me3Version deploye dans $script:Me3ProgramDir" -Level Ok
    return $true
}

function Uninstall-Me3 {
    Remove-IfPresent $script:Me3ProgramDir 'me3 (installe par cet installeur)' | Out-Null
    Remove-IfPresent $script:Me3DataDir 'donnees me3 (profils, logs, cache)' | Out-Null

    # Les deux dossiers 'garyttierney' qui contenaient me3 se retrouvent vides.
    # On ne laisse pas de coquille derriere nous, mais uniquement si le dossier
    # porte bien ce nom et ne contient plus rien : jamais son parent.
    foreach ($dir in @((Split-Path $script:Me3ProgramDir -Parent), (Split-Path $script:Me3DataDir -Parent))) {
        if ((Split-Path $dir -Leaf) -ne 'garyttierney') { continue }
        if (-not (Test-Path $dir)) { continue }
        if (Get-ChildItem $dir -Force -ErrorAction SilentlyContinue) { continue }
        Remove-Item $dir -Force -ErrorAction SilentlyContinue
        Write-Log "retire : dossier vide $dir" -Level Ok
    }
}

function Install-Launcher {
    <# Ecrit le .bat de lancement et le raccourci bureau. #>
    param([Parameter(Mandatory)][string]$GameExe)

    $bat = Join-Path $script:Me3DataDir 'Elden Ring (me3).bat'

    Write-TextFile $bat @"
@echo off
setlocal

REM Genere par me3-elden-ring-setup $($script:SetupVersion)
REM Les mods se configurent dans le profil, pas ici :
REM %LOCALAPPDATA%\garyttierney\me3\config\profiles\$($script:ProfileName).me3

set "ME3=%LOCALAPPDATA%\Programs\garyttierney\me3\bin\me3.exe"
set "GAME=$GameExe"
set "PROFILE=$($script:ProfileName)"

REM Quand un emulateur remplace l'API Steam, l'init Steam du launcher me3 n'a
REM plus lieu d'etre et echouerait (require_steam, 0x8007007E).
set "SKIPSTEAM=$($script:LauncherSkipSteam)"

REM En dessous de ce nombre de secondes, un retour de me3 est traite comme un
REM echec au lancement et non comme une fin de partie : la fenetre reste ouverte.
set "MINSESSION=30"

if not exist "%ME3%" (
    echo [ERREUR] me3 introuvable : "%ME3%"
    goto :fail
)
if not exist "%GAME%" (
    echo [ERREUR] eldenring.exe introuvable : "%GAME%"
    goto :fail
)

REM Elden Ring refuse une seconde instance : elle se termine immediatement et
REM sans crash dump, ce qui ressemble a un plantage de me3.
tasklist /fi "imagename eq eldenring.exe" 2>nul | find /i "eldenring.exe" >nul
if not errorlevel 1 (
    echo [ERREUR] ELDEN RING tourne deja.
    echo Ferme le jeu completement, puis relance ce script.
    goto :fail
)

echo Lancement d'ELDEN RING via me3 ^(profil : %PROFILE%^)...
echo Cette fenetre se fermera d'elle-meme a la fin de la partie.
echo.

REM me3 garde une monitor pipe ouverte : il ne rend la main qu'a la fermeture
REM du jeu. La duree d'execution distingue donc un echec d'une partie normale.
call :now T0
"%ME3%" launch --game eldenring --exe "%GAME%" --profile "%PROFILE%" --skip-steam-init %SKIPSTEAM%
set "RC=%errorlevel%"
call :now T1

set /a ELAPSED=T1-T0
if %ELAPSED% lss 0 set /a ELAPSED+=86400

if not "%RC%"=="0" (
    echo.
    echo [ERREUR] me3 a retourne le code %RC% apres %ELAPSED%s.
    goto :logs
)
if %ELAPSED% lss %MINSESSION% (
    echo.
    echo [ERREUR] me3 a rendu la main apres seulement %ELAPSED%s.
    echo Le jeu n'a probablement pas demarre.
    goto :logs
)

endlocal
exit /b 0

:logs
echo.
echo Dernier log me3 :
echo   %LOCALAPPDATA%\garyttierney\me3\data\logs\eldenring
goto :fail

:fail
echo.
pause
endlocal
exit /b 1

REM Secondes depuis minuit. Insensible au separateur decimal (virgule en
REM francais) et a l'heure sur un seul chiffre (" 9:05:03" -> "09:05:03").
:now
setlocal
set "H=%time: =0%"
set /a S=1%H:~0,2%*3600 + 1%H:~3,2%*60 + 1%H:~6,2% - 366100
endlocal & set "%~1=%S%"
goto :eof
"@ -As Ascii

    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Elden Ring (me3).lnk'
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($lnk)
    $s.TargetPath = $bat
    $s.WorkingDirectory = $script:Me3DataDir
    # eldenring.exe porte un groupe d'icones complet (16 a 256 px) : on y pointe
    # directement plutot que d'extraire un .ico.
    $s.IconLocation = "$GameExe,0"
    $s.Description = "Lance ELDEN RING via me3 (profil $($script:ProfileName))"
    $s.Save()

    Write-Log "lanceur : $bat" -Level Ok
    Write-Log "raccourci bureau : $lnk" -Level Ok

    return @{ Bat = $bat; Lnk = $lnk }
}
#endregion

#region ---- 40-modules.ps1 ----------------------------------------------
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
#endregion

#region ---- modules/gbe-fork.ps1 ----------------------------------------
# ---------------------------------------------------------------------------- #
#  gbe_fork - API Steam locale, decouverte des joueurs sur le LAN
#
#  Seul module a ecrire dans le dossier du jeu, et c'est structurel :
#  steam_api64.dll est un import statique de eldenring.exe. Le chargeur Windows
#  le resout et le mappe par section pendant l'initialisation du processus, sans
#  jamais passer par CreateFileW, et avant que me3 ne soit injecte. Or le VFS de
#  me3 fonctionne en interceptant CreateFileW / CreateDirectory / DeleteFile.
#  Aucun package ne peut donc servir cette DLL.
# ---------------------------------------------------------------------------- #

# Regles de pare-feu : gbe_fork ecoute A L'INTERIEUR du processus eldenring.exe.
# Windows bloque par defaut les connexions entrantes vers un programme inconnu,
# et l'echec est SILENCIEUX : les autres joueurs ne te trouvent jamais, sans
# aucun message en jeu. On pose donc les regles nous-memes.
$script:GbeFirewallGroup = 'me3-elden-ring-setup'

function Test-GbeFirewallRule {
    <# Les regles existent-elles deja, sur le bon programme et le bon port ? #>
    param([string]$Exe, [int]$Port)

    $rules = @(Get-NetFirewallRule -Group $script:GbeFirewallGroup -ErrorAction SilentlyContinue)
    if ($rules.Count -lt 2) { return $false }

    foreach ($r in $rules) {
        try {
            if ("$($r.Enabled)" -ne 'True') { return $false }
            $app = $r | Get-NetFirewallApplicationFilter -ErrorAction Stop
            if ("$($app.Program)" -ne $Exe) { return $false }
            $prt = $r | Get-NetFirewallPortFilter -ErrorAction Stop
            if ("$($prt.LocalPort)" -ne "$Port") { return $false }
        }
        catch { return $false }
    }
    return $true
}

function Set-GbeFirewallRule {
    param([string]$Exe, [int]$Port)

    if (Test-GbeFirewallRule -Exe $Exe -Port $Port) {
        Write-Log 'regles de pare-feu deja en place' -Level Ok
        return $true
    }

    # Les apostrophes sont doublees : un chemin peut en contenir.
    $e = $Exe.Replace("'", "''")
    $g = $script:GbeFirewallGroup
    $body = @"
`$ErrorActionPreference = 'Stop'
try {
    Get-NetFirewallRule -Group '$g' -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName 'ELDEN RING (me3 LAN) - UDP' -Group '$g' -Direction Inbound ``
        -Program '$e' -Protocol UDP -LocalPort $Port -Action Allow -Profile Private,Domain | Out-Null
    New-NetFirewallRule -DisplayName 'ELDEN RING (me3 LAN) - TCP' -Group '$g' -Direction Inbound ``
        -Program '$e' -Protocol TCP -LocalPort $Port -Action Allow -Profile Private,Domain | Out-Null
    exit 0
} catch { exit 1 }
"@

    $ok = Invoke-Elevated -Script $body -Purpose "creation des regles de pare-feu (UDP et TCP $Port)"

    if ($ok -and (Test-GbeFirewallRule -Exe $Exe -Port $Port)) {
        Write-Log "pare-feu : eldenring.exe autorise en entrant, UDP et TCP $Port (profils prive et domaine)" -Level Ok
        return $true
    }

    # Un refus n'annule pas l'installation : le jeu marchera, mais personne ne
    # te trouvera tant que les regles n'existent pas.
    Write-Log 'regles de pare-feu NON creees.' -Level Warn
    Write-Log 'Sans elles, les autres joueurs ne te trouveront pas, et le jeu ne signalera rien.' -Level Warn
    Write-Log 'Soit tu acceptes la boite « Autoriser l''acces » au premier lancement (coche Reseaux prives),' -Level Warn
    Write-Log 'soit tu relances l''installeur en mode Reparer pour reessayer.' -Level Warn
    return $false
}

function Remove-GbeFirewallRule {
    if (-not (Get-NetFirewallRule -Group $script:GbeFirewallGroup -ErrorAction SilentlyContinue)) {
        return
    }
    $g = $script:GbeFirewallGroup
    $body = @"
`$ErrorActionPreference = 'SilentlyContinue'
Get-NetFirewallRule -Group '$g' | Remove-NetFirewallRule
exit 0
"@
    if (Invoke-Elevated -Script $body -Purpose 'suppression des regles de pare-feu') {
        Write-Log 'retire : regles de pare-feu' -Level Ok
    }
    else {
        Write-Log "les regles de pare-feu du groupe '$g' subsistent, a retirer a la main si besoin" -Level Warn
    }
}

Register-Me3Module @{
    Key     = 'gbe-fork'
    Name    = 'gbe_fork (emulateur Steam LAN)'
    Version = 'release-2026_07_19'
    Summary = 'Remplace l''API Steam par une implementation locale : plus besoin de Steam ni d''Internet, les joueurs se decouvrent sur le reseau local.'
    Url     = 'https://github.com/Detanup01/gbe_fork'
    Default = $true
    Order   = 20

    TouchesGame   = $true
    SkipSteamInit = $true

    Options = @(
        @{
            Key     = 'PlayerName'
            Label   = 'Pseudo'
            Type    = 'string'
            Default = $env:USERNAME
            Shared  = $false
            Help    = 'Nom affiche aux autres joueurs. Doit etre DIFFERENT chez chacun.'
        }
        @{
            Key     = 'Port'
            Label   = 'Port reseau'
            Type    = 'int'
            Default = 47584
            Shared  = $true
            Help    = 'Port UDP et TCP d''ecoute. Tout le monde doit utiliser le meme, sinon les joueurs ne se trouvent pas. A autoriser dans le pare-feu.'
        }
        @{
            Key     = 'SteamId'
            Label   = 'SteamID64 (vide = genere)'
            Type    = 'string'
            Default = ''
            Shared  = $false
            Help    = 'Identifiant unique sur le LAN. Doit etre DIFFERENT chez chacun. Laisse vide pour en generer un.'
        }
    )

    Downloads = @{
        main = @{
            Url    = 'https://github.com/Detanup01/gbe_fork/releases/download/release-2026_07_19/emu-win-release.7z'
            File   = 'emu-win-release.7z'
            Kind   = '7z'
            Sha256 = $null
        }
    }

    Install = {
        param($ctx)

        $m = Get-Me3Module 'gbe-fork'
        $src = Expand-Download $m.Downloads.main (Get-Download $m.Downloads.main "$($m.Name) $($m.Version)") $m.Key

        # Build "regular" : le drop-in standard. Le build "experimental" ajoute
        # overlay et support des cracks CPY, dont on n'a pas besoin ici.
        $emu = Join-Path $src 'release\regular\x64\steam_api64.dll'
        if (-not (Test-Path $emu)) { Fail "steam_api64.dll introuvable dans l'archive gbe_fork" }

        $target = Join-Path $ctx.GamePath 'steam_api64.dll'
        $backup = Join-Path $ctx.GamePath 'steam_api64.dll.valve-original'

        # Sauvegarde : seulement si la DLL en place est bien celle de Valve, et
        # seulement s'il n'y en a pas deja une (sinon une reinstallation
        # ecraserait l'original avec l'emulateur).
        $backedUp = $false
        $originalHash = $null
        if (Test-Path $target) {
            if (Test-Path $backup) {
                # On note quand meme le hash : sans lui, la desinstallation ne
                # pourrait pas verifier ce qu'elle restaure.
                $originalHash = (Get-FileHash $backup -Algorithm SHA256).Hash
                Write-Log 'sauvegarde de steam_api64.dll deja presente, laissee intacte'
                $backedUp = $true
            }
            else {
                $company = (Get-Item $target).VersionInfo.CompanyName
                if ($company -and $company -like '*Valve*') {
                    $originalHash = (Get-FileHash $target -Algorithm SHA256).Hash
                    Copy-Item $target $backup -Force
                    Write-Log 'steam_api64.dll de Valve sauvegarde -> steam_api64.dll.valve-original' -Level Ok
                    $backedUp = $true
                }
                else {
                    Write-Log "steam_api64.dll en place n'est pas celui de Valve (deja un emulateur ?) : aucune sauvegarde creee" -Level Warn
                }
            }
        }

        Copy-Item $emu $target -Force
        Write-Log "$($m.Name) $($m.Version) installe" -Level Ok

        # gbe_fork cherche l'appid a la racine ET dans steam_settings.
        $settings = Join-Path $ctx.GamePath 'steam_settings'
        New-Item -ItemType Directory -Force $settings | Out-Null
        Write-TextFile (Join-Path $ctx.GamePath 'steam_appid.txt') "$($ctx.AppId)"
        Write-TextFile (Join-Path $settings 'steam_appid.txt') "$($ctx.AppId)"

        $port = $ctx.Options.Port
        Write-TextFile (Join-Path $settings 'configs.main.ini') @"
# Genere par me3-elden-ring-setup
# A GARDER IDENTIQUE chez tous les joueurs.

[main::connectivity]

# 0 = trafic confine au reseau local (decouverte UDP en broadcast, puis TCP).
disable_lan_only=0

# 0 = interfaces reseau Steam actives. Indispensable des qu'un mod reseau passe
#     par ISteamNetworkingMessages, ce qui est le cas de Seamless Co-op.
disable_networking=0

# Port d'ecoute. Tout le monde doit utiliser le meme, sinon les joueurs ne se
# trouvent pas. A autoriser dans le pare-feu, en UDP et en TCP.
listen_port=$port

offline=0
"@

        # Identite locale : doit differer sur chaque machine, et surtout rester
        # STABLE dans le temps. Un SteamID regenere a chaque passage ferait de
        # cette machine un nouveau joueur aux yeux des autres.
        #
        # Regle : on ne genere un identifiant que s'il n'en existe aucun. Une
        # valeur fournie explicitement l'emporte ; sinon on relit le fichier en
        # place. En reparation, le pseudo aussi est conserve tel quel.
        $userIni = Join-Path $settings 'configs.user.ini'
        $id = "$($ctx.Options.SteamId)"
        $name = $ctx.Options.PlayerName
        $reused = $false

        if (Test-Path $userIni) {
            $existing = Get-Content $userIni -Raw
            if (-not $id) {
                $mid = [regex]::Match($existing, '(?m)^\s*account_steamid\s*=\s*(\d+)')
                if ($mid.Success) { $id = $mid.Groups[1].Value; $reused = $true }
            }
            if ($ctx.IsRepair) {
                $mnm = [regex]::Match($existing, '(?m)^\s*account_name\s*=\s*(.+?)\s*$')
                if ($mnm.Success) { $name = $mnm.Groups[1].Value }
            }
        }

        if ($ctx.IsRepair -and (Test-Path $userIni)) {
            Write-Log "identite locale conservee : $name / $id" -Level Ok
        }
        else {
            if (-not $id) { $id = "$(76561198000000000 + (Get-Random -Minimum 100000 -Maximum 9999999))" }
            if ($reused) { Write-Log "identite locale : $name / $id (identifiant existant conserve)" -Level Ok }
            else { Write-Log "identite locale : $name / $id (nouvel identifiant)" -Level Ok }
            Write-TextFile $userIni @"
# Genere par me3-elden-ring-setup
# Identite locale de CE PC.
#
# IMPORTANT : chaque joueur doit avoir un account_name ET un account_steamid
# DIFFERENTS, sinon les pairs ne se distinguent pas sur le LAN.

[user::general]

account_name=$name
account_steamid=$id

language=french
ip_country=FR
"@
        }

        # Pare-feu : seule etape necessitant une elevation, et uniquement si les
        # regles ne sont pas deja correctes. Une reparation ne redemande donc
        # rien tant que le port et le chemin du jeu n'ont pas change.
        $fw = Set-GbeFirewallRule -Exe $ctx.GameExe -Port $port

        return @{
            BackupPath   = $(if ($backedUp) { $backup } else { $null })
            OriginalHash = $originalHash
            SteamId      = $id
            PlayerName   = $name
            Port         = $port
            FirewallOk   = [bool]$fw
        }
    }

    Uninstall = {
        param($ctx, $st)

        $target = Join-Path $ctx.GamePath 'steam_api64.dll'
        $backup = $null
        if ($st -and $st.BackupPath) { $backup = "$($st.BackupPath)" }
        if (-not $backup) { $backup = Join-Path $ctx.GamePath 'steam_api64.dll.valve-original' }

        if (Test-Path $backup) {
            Move-Item $backup $target -Force
            $h = (Get-FileHash $target -Algorithm SHA256).Hash
            if ($st -and $st.OriginalHash -and $h -ne $st.OriginalHash) {
                Write-Log 'steam_api64.dll restaure, mais son hash differe de celui note a l''installation' -Level Warn
            }
            else {
                Write-Log 'steam_api64.dll de Valve restaure' -Level Ok
            }
        }
        else {
            # Sans sauvegarde, retirer l'emulateur laisserait le jeu sans API
            # Steam du tout : on prefere le laisser en place et le signaler.
            Write-Log 'aucune sauvegarde de steam_api64.dll : l''emulateur est LAISSE EN PLACE.' -Level Warn
            Write-Log 'Verifie l''integrite des fichiers via Steam pour retrouver l''original.' -Level Warn
        }

        Remove-IfPresent (Join-Path $ctx.GamePath 'steam_settings') 'steam_settings\' | Out-Null
        Remove-IfPresent (Join-Path $ctx.GamePath 'steam_appid.txt') 'steam_appid.txt' | Out-Null

        Remove-GbeFirewallRule
    }
}
#endregion

#region ---- modules/seamless-coop.ps1 -----------------------------------
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
#endregion

#region ---- modules/unlock-fps.ps1 --------------------------------------
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

        # Le dossier est vide avant deploiement : sans cela, les fichiers d'une
        # version precedente qui n'existent plus dans la nouvelle resteraient en
        # place. Le .ini est reecrit juste apres, rien d'utile n'est perdu.
        $dst = Join-Path $ctx.Me3Profiles 'eldenring-natives\UnlockTheFps'
        Remove-IfPresent $dst | Out-Null
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
#endregion

#region ---- 60-engine.ps1 -----------------------------------------------
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
            # Une option restee vide n'apprend rien au lecteur : on la tait.
            if (-not "$value") { continue }
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
    # Les regles de pare-feu sont posees automatiquement. On ne rappelle donc
    # le sujet que si un module signale qu'il n'a pas pu les creer.
    foreach ($key in $ModuleState.Keys) {
        $st = ConvertTo-Hashtable $ModuleState[$key]
        if ($st.ContainsKey('FirewallOk') -and -not $st['FirewallOk']) {
            Write-Log ''
            Write-Log 'ATTENTION : les regles de pare-feu n''ont pas pu etre creees.'
            Write-Log 'Relance en mode Reparer et accepte l''invite, sinon personne ne te trouvera.'
        }
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
#endregion

#region ---- 70-gui.ps1 --------------------------------------------------
# ============================================================================ #
#  Assistant graphique
#
#  Etape 1 : dossier du jeu (auto-detecte). L'installeur y lit aussi s'il
#            existe deja une installation, et enchaine sur l'etape Action.
#  Etape 2 : Action (uniquement si une installation est detectee)
#  Etape 3 : Mods
#  Etape 4 : Options des mods retenus
#  Etape 5 : Resume
#  Etape 6 : Progression, puis Terminer
# ============================================================================ #

function Show-SetupWizard {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $W = 720; $H = 560
    $BodyTop = 74
    $BodyHeight = $H - $BodyTop - 108

    # ---------------------------------------------------------------- fenetre #
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "me3 - Elden Ring  ($($script:SetupVersion))"
    $form.ClientSize = New-Object System.Drawing.Size($W, $H)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    # bandeau de titre
    $header = New-Object System.Windows.Forms.Panel
    $header.Location = New-Object System.Drawing.Point(0, 0)
    $header.Size = New-Object System.Drawing.Size($W, ($BodyTop - 12))
    $header.BackColor = [System.Drawing.Color]::White
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Location = New-Object System.Drawing.Point(18, 12)
    $lblTitle.Size = New-Object System.Drawing.Size(($W - 36), 22)
    $lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Location = New-Object System.Drawing.Point(18, 36)
    $lblSub.Size = New-Object System.Drawing.Size(($W - 36), 20)
    $lblSub.ForeColor = [System.Drawing.Color]::DimGray
    $header.Controls.AddRange(@($lblTitle, $lblSub))

    $sep = New-Object System.Windows.Forms.Label
    $sep.Location = New-Object System.Drawing.Point(0, ($BodyTop - 12))
    $sep.Size = New-Object System.Drawing.Size($W, 1)
    $sep.BorderStyle = 'Fixed3D'

    # zone des pages
    $body = New-Object System.Windows.Forms.Panel
    $body.Location = New-Object System.Drawing.Point(0, $BodyTop)
    $body.Size = New-Object System.Drawing.Size($W, $BodyHeight)

    # boutons
    $btnBack = New-Object System.Windows.Forms.Button
    $btnBack.Text = '< Precedent'
    $btnBack.Size = New-Object System.Drawing.Size(110, 30)
    $btnBack.Location = New-Object System.Drawing.Point(($W - 360), ($H - 48))

    $btnNext = New-Object System.Windows.Forms.Button
    $btnNext.Text = 'Suivant >'
    $btnNext.Size = New-Object System.Drawing.Size(110, 30)
    $btnNext.Location = New-Object System.Drawing.Point(($W - 244), ($H - 48))

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Annuler'
    $btnCancel.Size = New-Object System.Drawing.Size(110, 30)
    $btnCancel.Location = New-Object System.Drawing.Point(($W - 128), ($H - 48))

    $form.Controls.AddRange(@($header, $sep, $body, $btnBack, $btnNext, $btnCancel))

    # ------------------------------------------------------------ etat commun #
    $st = @{
        State      = (Get-State)
        GameDir    = ''
        Action     = 'Install'    # Install | Repair | Uninstall
        Selection  = @()          # cles de modules
        Options    = @{}
        OptControls = @{}
        Page       = 0
        Done       = $false
        Running    = $false
    }

    $detected = $GamePath
    if (-not $detected -and $st.State -and $st.State.PSObject.Properties['gamePath']) { $detected = "$($st.State.gamePath)" }
    if (-not (Test-GamePath $detected)) { $detected = Find-GamePath }
    $st.GameDir = "$detected"

    # Filtre : l'etat peut mentionner un module retire de l'installeur depuis.
    $priorKeys = @()
    if ($st.State -and $st.State.PSObject.Properties['modules']) {
        $priorKeys = @(Select-KnownModuleKeys @((ConvertTo-Hashtable $st.State.modules).Keys))
    }
    $priorOptions = @{}
    if ($st.State -and $st.State.PSObject.Properties['options']) {
        $priorOptions = ConvertTo-Hashtable $st.State.options
    }

    if ($priorKeys.Count) { $st.Selection = $priorKeys }
    else { $st.Selection = Get-DefaultModuleKeys }

    # --------------------------------------------------------------- helpers #
    function New-Lbl($text, $x, $y, $w, $h) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text
        $l.Location = New-Object System.Drawing.Point($x, $y)
        $l.Size = New-Object System.Drawing.Size($w, $h)
        return $l
    }

    # Ordre des pages, recalcule a chaque navigation : la page Action n'existe
    # que si une installation est deja presente, et les pages Mods/Options
    # disparaissent pour une reparation ou une desinstallation.
    function Get-PageFlow {
        $flow = @('game')
        if ($st.State) { $flow += 'action' }
        if ($st.Action -eq 'Install') { $flow += @('mods', 'options') }
        $flow += @('summary', 'run')
        return $flow
    }

    # ----------------------------------------------------------------- pages #

    function Show-PageGame {
        $lblTitle.Text = 'Dossier du jeu'
        $lblSub.Text = 'Indique le dossier contenant eldenring.exe.'

        $body.Controls.Add((New-Lbl 'Dossier du jeu' 18 14 200 20))

        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Text = $st.GameDir
        $txt.Location = New-Object System.Drawing.Point(18, 36)
        $txt.Size = New-Object System.Drawing.Size(($W - 150), 22)
        $txt.Name = 'gamePath'

        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = 'Parcourir'
        $btn.Location = New-Object System.Drawing.Point(($W - 126), 35)
        $btn.Size = New-Object System.Drawing.Size(100, 24)

        $status = New-Lbl '' 18 74 ($W - 40) 40

        $refresh = {
            if (Test-GamePath $txt.Text.Trim()) {
                $status.ForeColor = [System.Drawing.Color]::DarkGreen
                $status.Text = "eldenring.exe trouve."
            }
            elseif ($txt.Text.Trim()) {
                $status.ForeColor = [System.Drawing.Color]::Firebrick
                $status.Text = "eldenring.exe est introuvable dans ce dossier."
            }
            else {
                $status.ForeColor = [System.Drawing.Color]::Firebrick
                $status.Text = "Jeu non detecte : indique le dossier manuellement."
            }
            $btnNext.Enabled = (Test-GamePath $txt.Text.Trim())
        }

        $btn.Add_Click({
                $d = New-Object System.Windows.Forms.FolderBrowserDialog
                $d.Description = 'Selectionne le dossier contenant eldenring.exe'
                if ($d.ShowDialog() -eq 'OK') { $txt.Text = $d.SelectedPath; & $refresh }
            }.GetNewClosure())
        $txt.Add_TextChanged($refresh)

        # etat de l'installation existante
        $info = New-Lbl '' 18 124 ($W - 40) 90
        if ($st.State) {
            $info.ForeColor = [System.Drawing.Color]::DarkGreen
            $names = @()
            foreach ($k in $priorKeys) {
                $m = Get-Me3Module $k
                if ($m) { $names += $m.Name } else { $names += $k }
            }
            $info.Text = "Une installation existe deja sur cette machine.`r`n" +
            "Mods installes : $($names -join ', ')`r`n`r`n" +
            "L'etape suivante te proposera de la reparer, de la modifier ou de la retirer."
        }
        else {
            $info.ForeColor = [System.Drawing.Color]::DimGray
            $info.Text = "Aucune installation detectee sur cette machine.`r`n" +
            "L'assistant va poser me3 puis les mods que tu choisiras.`r`n`r`n" +
            "Rien n'est ecrit avant l'ecran de resume."
        }

        $body.Controls.AddRange(@($txt, $btn, $status, $info))
        & $refresh
    }

    function Save-PageGame {
        $txt = $body.Controls['gamePath']
        $st.GameDir = $txt.Text.Trim()
        return (Test-GamePath $st.GameDir)
    }

    function Show-PageAction {
        $lblTitle.Text = 'Que veux-tu faire ?'
        $lblSub.Text = 'Une installation existe deja sur cette machine.'

        $y = 16
        $group = New-Object System.Windows.Forms.Panel
        $group.Location = New-Object System.Drawing.Point(0, 0)
        $group.Size = New-Object System.Drawing.Size($W, $BodyHeight)
        $group.Name = 'actions'

        $defs = @(
            @{ V = 'Repair'; T = 'Reparer'; D = 'Retelecharge et redeploie les memes mods. Les identites locales et le mot de passe sont conserves.' }
            @{ V = 'Install'; T = 'Modifier les mods'; D = 'Choisis a nouveau les mods et leurs reglages. Les mods decoches seront retires proprement.' }
            @{ V = 'Uninstall'; T = 'Desinstaller'; D = 'Retire les mods, restaure les fichiers d''origine du jeu et supprime le raccourci.' }
        )
        foreach ($d in $defs) {
            $r = New-Object System.Windows.Forms.RadioButton
            $r.Text = $d.T
            $r.Tag = $d.V
            $r.Location = New-Object System.Drawing.Point(24, $y)
            $r.Size = New-Object System.Drawing.Size(400, 22)
            $r.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
            $r.Checked = ($st.Action -eq $d.V)
            $group.Controls.Add($r)
            $y += 24
            $lbl = New-Lbl $d.D 44 $y ($W - 90) 36
            $lbl.ForeColor = [System.Drawing.Color]::DimGray
            $group.Controls.Add($lbl)
            $y += 46
        }
        # Aucun bouton coche (etat improbable) : on retombe sur Reparer.
        if (-not ($group.Controls | Where-Object { $_ -is [System.Windows.Forms.RadioButton] -and $_.Checked })) {
            ($group.Controls | Where-Object { $_ -is [System.Windows.Forms.RadioButton] })[0].Checked = $true
        }
        $body.Controls.Add($group)
    }

    function Save-PageAction {
        $group = $body.Controls['actions']
        foreach ($c in $group.Controls) {
            if ($c -is [System.Windows.Forms.RadioButton] -and $c.Checked) { $st.Action = "$($c.Tag)" }
        }
        return $true
    }

    function Show-PageMods {
        $lblTitle.Text = 'Mods'
        $lblSub.Text = 'Coche les mods a installer. Les dependances sont ajoutees automatiquement.'

        $panel = New-Object System.Windows.Forms.Panel
        $panel.Location = New-Object System.Drawing.Point(0, 0)
        $panel.Size = New-Object System.Drawing.Size($W, ($BodyHeight - 4))
        $panel.AutoScroll = $true
        $panel.Name = 'mods'

        $y = 10
        foreach ($m in Get-AllModules) {
            $cb = New-Object System.Windows.Forms.CheckBox
            $cb.Text = "$($m.Name)   $($m.Version)"
            $cb.Tag = $m.Key
            $cb.Checked = ($st.Selection -contains $m.Key)
            $cb.Location = New-Object System.Drawing.Point(20, $y)
            $cb.Size = New-Object System.Drawing.Size(($W - 70), 22)
            $cb.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
            $panel.Controls.Add($cb)
            $y += 22

            $desc = New-Lbl $m.Summary 40 $y ($W - 90) 34
            $desc.ForeColor = [System.Drawing.Color]::DimGray
            $panel.Controls.Add($desc)
            $y += 34

            if ($m.TouchesGame) {
                $warn = New-Lbl 'Ecrit dans le dossier du jeu (sauvegarde et restauration assurees).' 40 $y ($W - 90) 18
                $warn.ForeColor = [System.Drawing.Color]::DarkGoldenrod
                $panel.Controls.Add($warn)
                $y += 18
            }
            $y += 8
        }
        $body.Controls.Add($panel)
    }

    function Save-PageMods {
        $panel = $body.Controls['mods']
        $keys = @()
        foreach ($c in $panel.Controls) {
            if ($c -is [System.Windows.Forms.CheckBox] -and $c.Checked) { $keys += "$($c.Tag)" }
        }
        if (-not $keys.Count) {
            [System.Windows.Forms.MessageBox]::Show('Selectionne au moins un mod.', 'Mods', 'OK', 'Warning') | Out-Null
            return $false
        }
        $st.Selection = @(Resolve-ModuleSelection $keys | ForEach-Object { $_.Key })
        return $true
    }

    function Show-PageOptions {
        $lblTitle.Text = 'Reglages'
        $lblSub.Text = 'Les reglages marques « identique » doivent correspondre chez tous les joueurs.'

        $panel = New-Object System.Windows.Forms.Panel
        $panel.Location = New-Object System.Drawing.Point(0, 0)
        $panel.Size = New-Object System.Drawing.Size($W, ($BodyHeight - 4))
        $panel.AutoScroll = $true
        $panel.Name = 'options'

        $mods = @(Resolve-ModuleSelection $st.Selection)
        $defaults = Resolve-Options -ModuleList $mods -Previous $priorOptions -Provided $st.Options
        $st.OptControls = @{}

        $y = 8
        foreach ($m in $mods) {
            if (-not $m.Options.Count) { continue }

            $h = New-Lbl $m.Name 18 $y ($W - 60) 20
            $h.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
            $panel.Controls.Add($h)
            $y += 24

            foreach ($o in $m.Options) {
                $tag = 'different chez chacun'
                if ($o.Shared) { $tag = 'identique chez tous' }
                $panel.Controls.Add((New-Lbl "$($o.Label)  ($tag)" 36 $y 380 18))

                $tb = New-Object System.Windows.Forms.TextBox
                $tb.Text = "$($defaults[$o.Key])"
                $tb.Location = New-Object System.Drawing.Point(420, ($y - 2))
                $tb.Size = New-Object System.Drawing.Size(240, 22)
                $panel.Controls.Add($tb)
                $st.OptControls[$o.Key] = $tb
                $y += 24

                if ($o.Help) {
                    $hl = New-Lbl $o.Help 36 $y (($W - 80)) 32
                    $hl.ForeColor = [System.Drawing.Color]::DimGray
                    $panel.Controls.Add($hl)
                    $y += 34
                }
                $y += 4
            }
            $y += 10
        }
        $body.Controls.Add($panel)
    }

    function Save-PageOptions {
        $vals = @{}
        foreach ($k in $st.OptControls.Keys) { $vals[$k] = $st.OptControls[$k].Text.Trim() }
        try {
            # Valide le typage tout de suite plutot qu'en pleine installation.
            [void](Resolve-Options -ModuleList (Resolve-ModuleSelection $st.Selection) -Previous $priorOptions -Provided $vals)
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Reglage invalide', 'OK', 'Warning') | Out-Null
            return $false
        }
        $st.Options = $vals
        return $true
    }

    function Show-PageSummary {
        $lblTitle.Text = 'Resume'
        $lblSub.Text = 'Rien n''a encore ete modifie. Verifie, puis lance.'

        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Vertical'
        $tb.Location = New-Object System.Drawing.Point(18, 10)
        $tb.Size = New-Object System.Drawing.Size(($W - 40), ($BodyHeight - 24))
        $tb.Font = New-Object System.Drawing.Font('Consolas', 9)
        $tb.BackColor = [System.Drawing.Color]::White

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("Dossier du jeu")
        [void]$sb.AppendLine("   $($st.GameDir)")
        [void]$sb.AppendLine()

        if ($st.Action -eq 'Uninstall') {
            [void]$sb.AppendLine('Action : DESINSTALLATION')
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('Seront retires :')
            foreach ($k in $priorKeys) {
                $m = Get-Me3Module $k
                $n = $k
                if ($m) { $n = $m.Name }
                [void]$sb.AppendLine("   - $n")
            }
            [void]$sb.AppendLine('   - le profil me3 et le raccourci bureau')
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('Les fichiers d''origine du jeu seront restaures depuis leur sauvegarde.')
            if ($st.State -and $st.State.PSObject.Properties['me3InstalledByUs'] -and $st.State.me3InstalledByUs) {
                [void]$sb.AppendLine('me3 sera retire : c''est cet installeur qui l''avait pose.')
            }
            else {
                [void]$sb.AppendLine('me3 sera conserve : il etait deja present avant cet installeur.')
            }
            $btnNext.Text = 'Desinstaller'
        }
        else {
            $mods = @(Resolve-ModuleSelection $st.Selection)
            $verb = 'INSTALLATION'
            if ($st.Action -eq 'Repair') { $verb = 'REPARATION' }
            [void]$sb.AppendLine("Action : $verb")
            [void]$sb.AppendLine()

            $me3v = Get-Me3Version
            if ($me3v) { [void]$sb.AppendLine("me3 : deja present ($me3v), conserve") }
            else { [void]$sb.AppendLine("me3 : $($script:Me3Version) sera telecharge et installe") }
            [void]$sb.AppendLine()

            [void]$sb.AppendLine('Mods :')
            foreach ($m in $mods) {
                [void]$sb.AppendLine(("   {0,-26} {1}" -f $m.Name, $m.Version))
            }
            $touchers = @($mods | Where-Object { $_.TouchesGame })
            if ($touchers.Count) {
                [void]$sb.AppendLine()
                [void]$sb.AppendLine('Ecrivent dans le dossier du jeu (avec sauvegarde) :')
                foreach ($m in $touchers) { [void]$sb.AppendLine("   - $($m.Name)") }
            }

            if ($st.Action -eq 'Install') {
                $opts = Resolve-Options -ModuleList $mods -Previous $priorOptions -Provided $st.Options
                [void]$sb.AppendLine()
                [void]$sb.AppendLine('Reglages :')
                foreach ($m in $mods) {
                    foreach ($o in $m.Options) {
                        $v = $opts[$o.Key]
                        if (-not $v) { $v = '(genere)' }
                        [void]$sb.AppendLine(("   {0,-26} {1}" -f $o.Label, $v))
                    }
                }
                $dropped = @($priorKeys | Where-Object { $st.Selection -notcontains $_ })
                if ($dropped.Count) {
                    [void]$sb.AppendLine()
                    [void]$sb.AppendLine('Seront retires (decoches) :')
                    foreach ($k in $dropped) {
                        $m = Get-Me3Module $k
                        $n = $k
                        if ($m) { $n = $m.Name }
                        [void]$sb.AppendLine("   - $n")
                    }
                }
            }
            else {
                [void]$sb.AppendLine()
                [void]$sb.AppendLine('Les reglages et les identites locales sont conserves.')
            }

            $btnNext.Text = 'Installer'
            if ($st.Action -eq 'Repair') { $btnNext.Text = 'Reparer' }
        }

        $tb.Text = $sb.ToString()
        $body.Controls.Add($tb)
    }

    function Show-PageRun {
        $lblTitle.Text = 'Progression'
        $lblSub.Text = 'Ne ferme pas cette fenetre.'

        $log = New-Object System.Windows.Forms.TextBox
        $log.Multiline = $true; $log.ReadOnly = $true; $log.ScrollBars = 'Vertical'
        $log.Location = New-Object System.Drawing.Point(18, 10)
        $log.Size = New-Object System.Drawing.Size(($W - 40), ($BodyHeight - 24))
        $log.Font = New-Object System.Drawing.Font('Consolas', 9)
        $log.BackColor = [System.Drawing.Color]::White
        $body.Controls.Add($log)

        $btnBack.Enabled = $false
        $btnNext.Enabled = $false
        $btnCancel.Enabled = $false
        $st.Running = $true

        $script:LogSink = {
            param($line)
            $log.AppendText("$line`r`n")
            $log.SelectionStart = $log.TextLength
            $log.ScrollToCaret()
            [System.Windows.Forms.Application]::DoEvents()
        }

        $ok = $true
        try {
            if ($st.Action -eq 'Uninstall') {
                Invoke-Removal
            }
            else {
                $mods = @(Resolve-ModuleSelection $st.Selection)
                $opts = Resolve-Options -ModuleList $mods -Previous $priorOptions -Provided $st.Options
                Invoke-Setup -RunMode $st.Action -GameDir $st.GameDir -SelectedModules $mods -Options $opts
            }
        }
        catch {
            $ok = $false
            Write-Log $_.Exception.Message -Level Error
        }
        finally {
            $script:LogSink = $null
            $st.Running = $false
        }

        if ($ok) {
            $lblSub.Text = 'Termine.'
            $lblSub.ForeColor = [System.Drawing.Color]::DarkGreen
        }
        else {
            $lblSub.Text = 'Echec. Lis le journal ci-dessus.'
            $lblSub.ForeColor = [System.Drawing.Color]::Firebrick
        }
        $st.Done = $true
        $btnNext.Text = 'Terminer'
        $btnNext.Enabled = $true
        $btnCancel.Enabled = $true
        $btnCancel.Text = 'Fermer'
    }

    # ------------------------------------------------------------ navigation #

    $render = {
        $body.Controls.Clear()
        $lblSub.ForeColor = [System.Drawing.Color]::DimGray
        $flow = Get-PageFlow
        $page = $flow[$st.Page]

        $btnBack.Enabled = ($st.Page -gt 0)
        $btnNext.Text = 'Suivant >'
        $btnNext.Enabled = $true

        switch ($page) {
            'game' { Show-PageGame }
            'action' { Show-PageAction }
            'mods' { Show-PageMods }
            'options' { Show-PageOptions }
            'summary' { Show-PageSummary }
            'run' { Show-PageRun }
        }
    }

    $btnNext.Add_Click({
            if ($st.Done) { $form.Close(); return }
            $flow = Get-PageFlow
            $page = $flow[$st.Page]

            $ok = $true
            switch ($page) {
                'game' { $ok = Save-PageGame }
                'action' { $ok = Save-PageAction }
                'mods' { $ok = Save-PageMods }
                'options' { $ok = Save-PageOptions }
            }
            if (-not $ok) { return }

            # Le flux depend de l'action choisie : on le relit apres coup.
            $flow = Get-PageFlow
            if ($st.Page -lt ($flow.Count - 1)) {
                $st.Page++
                & $render
            }
        })

    $btnBack.Add_Click({
            if ($st.Page -gt 0) { $st.Page--; & $render }
        })

    $btnCancel.Add_Click({ $form.Close() })

    $form.Add_FormClosing({
            param($s, $e)
            if ($st.Running) { $e.Cancel = $true }
        })

    & $render
    [void]$form.ShowDialog()
    $script:LogSink = $null
}
#endregion

#region ---- 90-main.ps1 -------------------------------------------------
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
#endregion

