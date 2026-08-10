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

        return @{
            BackupPath   = $(if ($backedUp) { $backup } else { $null })
            OriginalHash = $originalHash
            SteamId      = $id
            PlayerName   = $name
            Port         = $port
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
    }
}
