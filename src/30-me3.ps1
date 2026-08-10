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
