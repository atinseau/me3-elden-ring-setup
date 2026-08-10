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

# ---------------------------------------------------------------------------- #
#  Miroir d'archives
#
#  Certains mods ne sont distribues que sur Nexus, qui exige un compte et
#  interdit le telechargement automatise. Leur archive est alors reservie depuis
#  une release de ce depot, pour que l'installation ne demande aucune etape
#  manuelle.
#
#  Une release plutot que le depot lui-meme : GitHub refuse tout fichier de plus
#  de 100 Mo au push, la ou un asset de release monte a 2 Go. Et un binaire
#  commite reste dans l'historique pour toujours, a la charge de chaque clone.
#
#  Le tag est fixe, jamais lie a la version de l'installeur : les URL doivent
#  rester stables quand l'installeur, lui, evolue.
# ---------------------------------------------------------------------------- #
$script:MirrorRepo = 'atinseau/me3-elden-ring-setup'
$script:MirrorTag  = 'vendor'

# Version de me3 deployee quand il est absent de la machine.
$script:Me3Version = 'v0.12.1'
$script:Me3Url     = 'https://github.com/garyttierney/me3/releases/download/v0.12.1/me3-windows-amd64.zip'
