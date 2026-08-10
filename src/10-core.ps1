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

function Get-GitHubReleaseList {
    <# Releases d'un depot, de la plus recente a la plus ancienne. #>
    param([Parameter(Mandatory)][string]$Repo, [int]$Count = 20)

    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        return @(Invoke-RestMethod "https://api.github.com/repos/$Repo/releases?per_page=$Count" `
                -Headers @{ 'User-Agent' = 'me3-elden-ring-setup' })
    }
    catch { Fail "impossible de lister les releases de $Repo : $($_.Exception.Message)" }
    finally { $ProgressPreference = $old }
}

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
