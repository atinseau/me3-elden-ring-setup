# me3-elden-ring-setup

Installeur modulaire de mods Elden Ring, orchestrés par [me3](https://github.com/garyttierney/me3).

Un assistant graphique en PowerShell, un fichier unique, aucune dépendance.
Il pose me3, installe les mods choisis, crée un raccourci de lancement — et sait
tout retirer en restaurant les fichiers d'origine du jeu.

Les mods livrés par défaut forment une stack **multijoueur LAN pur** : aucun
serveur FromSoftware, aucun client Steam, aucun accès Internet.

```powershell
# Assistant graphique
.\me3-elden-ring-setup.ps1

# Ligne de commande
.\me3-elden-ring-setup.ps1 -ListModules
.\me3-elden-ring-setup.ps1 -Mode Install -NoGui -Modules unlock-fps,gbe-fork,seamless-coop `
    -Option @{ PlayerName = 'bob'; CoopPassword = 'hidetower'; Framerate = 144 }
.\me3-elden-ring-setup.ps1 -Mode Uninstall -NoGui
```

Si Windows bloque l'exécution :
`powershell -ExecutionPolicy Bypass -File .\me3-elden-ring-setup.ps1`

## L'assistant

Étape 1, le dossier du jeu — auto-détecté via les bibliothèques Steam et les
emplacements courants. L'installeur y repère aussi une installation existante et
enchaîne alors sur un écran **Réparer / Modifier / Désinstaller**. Sinon il passe
directement au choix des mods, puis à leurs réglages, puis à un résumé.

Rien n'est écrit avant l'écran de résumé.

## Modules livrés

| Clé | Mod | Version | Écrit dans le jeu |
|---|---|---|---|
| `unlock-fps` | [UnlockTheFps](https://github.com/a492219408/EldenRing-UnlockTheFps) | v0.4.1 | non |
| `gbe-fork` | [gbe_fork](https://github.com/Detanup01/gbe_fork) | 2026_07_19 | **oui** |
| `seamless-coop` | [Seamless Co-op](https://github.com/LukeYui/EldenRingSeamlessCoopRelease) | v1.9.8 | non |

Le script **ne redistribue aucun binaire** : tout est téléchargé depuis les
dépôts officiels à l'exécution, avec vérification du checksum quand l'éditeur en
publie un, et journalisation du SHA-256 constaté sinon.

Si me3 est déjà installé, il est conservé — et la désinstallation n'y touche pas
non plus, ni à tes autres profils.

## Ajouter un mod

Un module décrit un mod de bout en bout : ses téléchargements, ses options, son
installation, sa désinstallation, et sa contribution au profil `.me3`.
L'installeur n'en connaît aucun en dur, il parcourt le registre.

Crée un fichier dans `src/modules/`, puis recompile :

```powershell
Register-Me3Module @{
    Key       = 'mon-mod'
    Name      = 'Mon Mod'
    Version   = 'v1.0'
    Summary   = 'Ce que fait le mod, en une ligne.'
    Default   = $false
    Order     = 40

    Options   = @(
        @{ Key = 'MonReglage'; Label = 'Mon reglage'; Type = 'int'
           Default = 42; Shared = $true; Help = 'Explication affichee dans l''assistant.' }
    )

    Downloads = @{
        main = @{ Url = 'https://...'; File = 'mon-mod.zip'; Kind = 'zip'; Sha256 = $null }
    }

    Install = {
        param($ctx)
        $m = Get-Me3Module 'mon-mod'
        $src = Expand-Download $m.Downloads.main (Get-Download $m.Downloads.main $m.Name) $m.Key
        # ... deployer dans $ctx.Me3Profiles ...
        return @{ }          # etat conserve pour la desinstallation
    }

    Uninstall = { param($ctx, $st) Remove-IfPresent (Join-Path $ctx.Me3Profiles 'mon-mod') | Out-Null }

    ProfileToml = {
        param($ctx)
        return @{ Natives = '[[natives]]...' ; Packages = '' }
    }
}
```

`Shared = $true` marque un réglage qui doit être identique chez tous les joueurs :
l'assistant et le résumé final le signalent.

```powershell
.\Build.ps1
```

## Compilation

Les sources vivent dans `src/`. `Build.ps1` les concatène dans un ordre explicite,
injecte les modules entre le registre et le moteur, estampille la version, et
valide la syntaxe — fichier par fichier d'abord, pour que l'erreur pointe la bonne
source, puis sur le résultat compilé.

L'artefact `dist/me3-elden-ring-setup.ps1` est autonome. C'est le seul à publier.

```
src/00-header.ps1      aide, parametres, chemins
src/10-core.ps1        journal, etat, fichiers, telechargements
src/20-detect.ps1      detection du jeu et de me3
src/30-me3.ps1         deploiement de me3, lanceur
src/40-modules.ps1     registre, dependances, options
src/modules/*.ps1      les mods
src/60-engine.ps1      orchestration, assemblage du profil
src/70-gui.ps1         assistant
src/90-main.ps1        dispatch CLI
```

## Le profil me3 est généré

`eldenring.me3` est **réécrit** à chaque installation ou réparation, à partir des
fragments déclarés par les modules retenus. Ne l'édite pas à la main : écris un
module. Le package `eldenring-mods/` reste à ta disposition pour tes mods
d'assets, il n'est jamais touché.

## Pourquoi un mod écrit dans le dossier du jeu

Presque tout vit du côté de me3, sans rien écrire dans le jeu. Une exception,
structurelle : `steam_api64.dll`, apporté par `gbe-fork`.

C'est un **import statique** de `eldenring.exe`. Le chargeur Windows le résout et
le mappe par section pendant l'initialisation du processus — sans jamais passer
par `CreateFileW`, et avant que me3 ne soit injecté. Or le VFS de me3 fonctionne
en interceptant `CreateFileW` / `CreateDirectory` / `DeleteFile`. Aucun package ne
peut donc servir cette DLL : elle doit être physiquement à côté de l'exécutable.

Seamless Co-op, lui, est entièrement côté me3 : le hook `CreateFileW` retire le
dossier du jeu du chemin demandé puis cherche cette clé parmi les fichiers des
packages, si bien qu'un package sert n'importe quel fichier à la racine du jeu.
Sa DLL est déclarée **à la fois** en `[[natives]]` (pour être chargée) et en
`[[packages]]` (pour que son `ersc_settings.ini` soit trouvé) — voir
[me3#435](https://github.com/garyttierney/me3/discussions/435).

## Jouer en LAN

Chaque joueur lance le raccourci **Elden Ring (me3)** créé sur son bureau.

Doivent être **identiques** chez tous : le mot de passe de session, le port, et le
framerate. Ce dernier compte autant que les autres : la physique d'Elden Ring
dépend du framerate, un écart entre joueurs désynchronise la session.

Doivent être **différents** chez chacun : le pseudo et le SteamID64. L'installeur
génère un identifiant unique à la première installation et le **conserve** ensuite,
y compris quand tu modifies la liste des mods.

Il faut aussi la même version du jeu partout, et autoriser `eldenring.exe` dans le
pare-feu en **UDP et TCP** : gbe_fork découvre les pairs par broadcast UDP puis
ouvre du TCP pour les données.

### Ce que ça ne fait pas revenir

Les signes d'invocation, les invasions aléatoires, les messages et les traces de
sang sont des fonctions **serveur** : le jeu interroge les serveurs FromSoftware
pour les découvrir. Sans eux il n'y a rien à découvrir, et aucun émulateur de
serveur FromSoft public n'existe pour Elden Ring. Seamless Co-op ne les restaure
pas : il remplace le matchmaking par une session privée à mot de passe. Tu y
gagnes le co-op et le PvP **au sein de ta session**.

## Ce que fait le raccourci

1. Vérifie que `me3.exe` et `eldenring.exe` existent
2. Refuse de démarrer si le jeu tourne déjà — une seconde instance se termine
   sans crash dump, ce qui ressemble à un plantage de me3
3. Lance `me3 launch --game eldenring --exe <jeu> --profile eldenring --skip-steam-init true`
4. me3 reste attaché toute la partie ; au retour, le script mesure la durée
5. Moins de 30 s → échec au lancement : la fenêtre reste ouverte avec le chemin
   des logs. Sinon → fermeture silencieuse

## Désinstaller

Les modules sont retirés dans l'ordre inverse de l'installation, en s'appuyant sur
l'état enregistré dans `%LOCALAPPDATA%\Me3EldenRingSetup\state.json` : ce qui a été
posé, le hash du `steam_api64.dll` sauvegardé, et si me3 existait déjà.

La restauration vérifie le hash de la DLL rendue. Si aucune sauvegarde n'est
trouvée, l'émulateur est **laissé en place** plutôt que supprimé — retirer la DLL
laisserait le jeu sans API Steam du tout.

## Prérequis

- Windows 10 1803+ ou Windows 11 (`tar.exe` est requis pour les archives `.7z`)
- Windows PowerShell 5.1 (livré avec Windows) ou PowerShell 7+
- Elden Ring installé
- Chaque joueur doit posséder le jeu

## Licence

MIT. Les composants téléchargés restent sous leurs licences respectives.
