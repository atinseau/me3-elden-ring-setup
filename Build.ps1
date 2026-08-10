<#
.SYNOPSIS
    Compile les sources de src/ en un fichier unique distribuable.

.DESCRIPTION
    Concatene les fichiers de src/ dans un ordre explicite, injecte les modules
    de src/modules/ entre le registre et le moteur, puis valide la syntaxe du
    resultat avec l'analyseur PowerShell.

    Le fichier produit est autonome : c'est le seul a publier.

.PARAMETER Version
    Version estampillee dans l'artefact. Par defaut, celle de VERSION.

.PARAMETER OutFile
    Chemin de sortie. Par defaut dist/me3-elden-ring-setup.ps1.

.EXAMPLE
    .\Build.ps1
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$src = Join-Path $root 'src'

if (-not $Version) {
    $vf = Join-Path $root 'VERSION'
    if (Test-Path $vf) { $Version = (Get-Content $vf -Raw).Trim() }
    else { $Version = '0.0.0' }
}
if (-not $OutFile) { $OutFile = Join-Path $root 'dist\me3-elden-ring-setup.ps1' }

# L'ordre est explicite plutot que deduit du tri des noms : il est le contrat
# de construction du script, il doit se lire.
$order = @(
    '00-header.ps1'
    '10-core.ps1'
    '20-detect.ps1'
    '30-me3.ps1'
    '40-modules.ps1'
    '<modules>'      # tous les fichiers de src/modules, par ordre alphabetique
    '60-engine.ps1'
    '70-gui.ps1'
    '90-main.ps1'
)

Write-Host ''
Write-Host "  Compilation de me3-elden-ring-setup $Version" -ForegroundColor Cyan
Write-Host ''

$parts = New-Object System.Collections.Generic.List[string]
$count = 0

function Add-Part {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path $Path)) { throw "source manquante : $Path" }

    # Validation individuelle : une erreur pointe le bon fichier plutot qu'une
    # ligne du fichier concatene.
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) {
        foreach ($e in $errs) { Write-Host "    ligne $($e.Extent.StartLineNumber) : $($e.Message)" -ForegroundColor Red }
        throw "erreur de syntaxe dans $Label"
    }

    # -Encoding UTF8 est indispensable : sans lui, PowerShell 5.1 lit un fichier
    # UTF-8 sans BOM comme de l'ANSI, et les caracteres accentues ressortent
    # doublement encodes dans l'artefact compile.
    $text = Get-Content $Path -Raw -Encoding UTF8
    $parts.Add("#region ---- $Label " + ('-' * [Math]::Max(1, 60 - $Label.Length)))
    $parts.Add($text.TrimEnd())
    $parts.Add("#endregion`n")

    $lines = ($text -split "`n").Count
    Write-Host ("    {0,-34} {1,5} lignes" -f $Label, $lines) -ForegroundColor Gray
    return $lines
}

foreach ($entry in $order) {
    if ($entry -eq '<modules>') {
        $modDir = Join-Path $src 'modules'
        $mods = @(Get-ChildItem $modDir -Filter '*.ps1' | Sort-Object Name)
        if (-not $mods.Count) { throw "aucun module dans $modDir" }
        foreach ($m in $mods) {
            $count += Add-Part $m.FullName "modules/$($m.Name)"
        }
    }
    else {
        $count += Add-Part (Join-Path $src $entry) $entry
    }
}

$banner = @"
# =========================================================================== #
#  me3-elden-ring-setup $Version
#
#  FICHIER GENERE - NE PAS EDITER
#  Produit par Build.ps1 a partir de src/. Toute modification directe sera
#  perdue a la prochaine compilation. Pour ajouter un mod, cree un fichier
#  dans src/modules/ puis relance Build.ps1.
#
#  https://github.com/atinseau/me3-elden-ring-setup
# =========================================================================== #

"@

# La version est injectee ici, apres le bloc param() du header : elle vient de
# la compilation, pas des sources.
$versionStamp = @"

`$script:SetupVersion = '$Version'
`$script:LauncherSkipSteam = 'false'

"@

$body = $parts -join "`n"

# Le bloc param() doit rester la premiere instruction du script : on insere la
# version juste apres la fin du header, reperee par son marqueur de region.
$marker = '#endregion'
$idx = $body.IndexOf($marker)
if ($idx -lt 0) { throw 'marqueur de fin du header introuvable' }
$insertAt = $idx + $marker.Length
$body = $body.Substring(0, $insertAt) + "`n" + $versionStamp + $body.Substring($insertAt)

$final = $banner + $body + "`n"

$outDir = Split-Path $OutFile -Parent
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force $outDir | Out-Null }

# UTF-8 avec BOM : PowerShell 5.1 lit un .ps1 sans BOM comme de l'ANSI, ce qui
# abime les accents des messages.
[System.IO.File]::WriteAllText($OutFile, ($final -replace "`r?`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))

# Validation du resultat compile
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($OutFile, [ref]$null, [ref]$errs)
if ($errs) {
    foreach ($e in $errs) { Write-Host "    ligne $($e.Extent.StartLineNumber) : $($e.Message)" -ForegroundColor Red }
    throw 'le fichier compile ne passe pas l''analyseur'
}

$size = [math]::Round((Get-Item $OutFile).Length / 1KB, 1)
Write-Host ''
Write-Host "  OK  $OutFile" -ForegroundColor Green
Write-Host "      $count lignes de source, $size KB, syntaxe validee" -ForegroundColor Gray
Write-Host ''
