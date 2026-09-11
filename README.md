# FrenchNet — AERONAUTICS WARFARE (CC: Tweaked)

Tous les systèmes informatiques du serveur **AERONAUTICS WARFARE**
(Create Aeronautics, Create Radars, Create Big Cannons, NeoForge 1.21.1),
réunis sur une seule branche.

| Système | Rôle | Guide |
|---|---|---|
| **Balises GPS** | Constellation de balises fixes, hôtes GPS pour tout le serveur | [guide](docs/guide-complet.md) |
| **Autopilote** | Bibliothèque de pilotage autonome — cascade, PID, repli zone morte | [guide](docs/guide-autopilote.md) |
| **FrenchNet Command** | Système de défense **au sol** : détection, classification, poste de commandement | [guide](docs/frenchnet-command.md) |
| **Navire intercepteur** | Système embarqué de scramble + système d'exploitation de bord | [guide](docs/intercepteur.md) |
| **Vaisseau doomsday** | Vaisseau lourd et son poste de contrôle | [guide](docs/doomsday-ship.md) |
| **ADS** | Contre-mesures embarquées : leurres et évasion sur détection de missile | [guide](docs/guide-ads.md) |
| **Mise à jour** | Diffusion des mises à jour à tous les postes du réseau | [guide](docs/mise-a-jour.md) |
| **Câblage** | Brancher un ordinateur sur un véhicule et le faire bouger | [guide](docs/guide-cablage.md) |
| **Installation** | Poser les fichiers sur les ordinateurs, et dépannage | [guide](docs/guide-installation.md) |

---

> ⚠️ **`wget` renvoie 404 ?** Le dépôt est **privé**, et CC: Tweaked ne peut pas s'authentifier sur GitHub : aucune adresse `raw.githubusercontent.com` ne répondra. Rendez le dépôt public, ou passez les fichiers par la sauvegarde du monde. Marche à suivre complète dans le **[guide d'installation](docs/guide-installation.md)**.

## Installation en une commande

Dépôt public requis. Sur chaque ordinateur :

```
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/doomsday-ship-system/installe.lua installe
installe balise        -- balise GPS fixe
installe vehicule      -- autopilote d'un véhicule
installe intercepteur  -- navire de scramble (autopilote + interception + OS)
installe satellite     -- ordinateur de sortie déporté
```

L'installateur crée les dossiers, vérifie chaque fichier téléchargé (une page d'erreur HTML enregistrée comme du Lua est détectée et refusée) et **préserve les configurations déjà réglées**.

---

## Qui parle à qui

Deux règles de conception traversent tout le dépôt, et expliquent la plupart des choix :

**Le sol classifie, le bord exécute.** FrenchNet Command connaît les zones et les classes Charlie / Bravo / Alpha / Roméo. Le navire intercepteur, lui, n'en sait **rien** : il reçoit deux ordres, `SCRAMBLE` et `FEU`, et rien d'autre. Un ordre qui contiendrait malgré tout un champ de zone ou de classe se le voit retirer, et le fait est journalisé — c'est le signe visible qu'un couplage se réintroduit.

**On appelle, on ne réécrit pas.** Le module d'autopilote est la seule loi de vol du dépôt. L'intercepteur, l'ADS et le vaisseau l'appellent ; aucun ne réimplémente d'asservissement.

---

## Systèmes au sol

### Balises GPS

Chaque balise diffuse sa position X/Y/Z en continu par rednet (modem Ender, portée illimitée) et sert d'hôte GPS pour tout le serveur.

4 balises minimum, **non alignées** et à **4 altitudes différentes** (sinon le GPS est faux), dans des chunks **maintenus chargés**.

```lua
identifiant      = "BAL-01-NORD",                     -- unique sur le serveur
positionManuelle = { x = 1200, y = 210, z = -2600 },  -- F3, ligne "Block:"
```

### FrenchNet Command

Le poste de commandement : radars au sol, transpondeurs, carte, scanner de terrain, classification des contacts et diffusion des ordres de scramble.

C'est **lui** qui décide qu'un contact est hostile et quel navire envoyer. Les navires ne font qu'obéir.

📖 [guide](docs/frenchnet-command.md)

---

## Systèmes embarqués

### Autopilote

Bibliothèque de pilotage installable sur n'importe quel véhicule aérien. Asservissement en **cascade** à deux étages (position → vitesse, puis vitesse → commande moteur), **PID** en contrôle principal sur quatre axes, et **repli automatique en zone morte** si un axe devient instable — la bascule étant journalisée.

Un seul fichier de réglage par véhicule : `autopilote/config_vehicule.lua`.

```lua
local autopilote = dofile("/autopilote/autopilote.lua")
local ap = autopilote.nouveau()
ap.allerA({ x = 1200, y = 210, z = -2600 })
parallel.waitForAny(ap.executer, mission)
```

📖 [guide](docs/guide-autopilote.md) · [câblage](docs/guide-cablage.md)

### Navire intercepteur de scramble

**Interception prédictive** — il résout le temps de vol et vise la position *future* de la cible, pas sa position actuelle.

**Arc arrière 4 h – 8 h, 300 à 400 blocs** — jamais de face. Hors de l'arc, il contourne par le flanc. Une fois en position, orbite ou zigzag, avec vitesse asservie sur celle de la cible.

**L'ordre de tir prime sur la position** — sous ordre de feu, il engage dès qu'il a une solution, même hors de son arc ; il y revient progressivement, par corrections bornées, sans cesser de tirer.

**Arsenal configurable** — plusieurs armes, chacune avec sa portée, son utilité (anti-aérien, anti-sol, défensif, polyvalent) et sa balistique. Le navire choisit l'arme adaptée à la distance et à la nature de la cible.

**Évasion prioritaire** sur détection de dégât. **Retour base automatique** sur destruction confirmée, confié au système de points de passage de l'autopilote. Le réarmement reste **manuel**.

Avec un **système d'exploitation de bord** (`systeme/`) : noyau multitâche, l'interface et l'interception tournent côte à côte, chacune dans sa fenêtre. Sept pages, dont **Armement** pour déclarer les armes et leurs portées, avec détection des trous de couverture.

📖 [guide](docs/intercepteur.md)

### ADS — contre-mesures

Sur **chaque navire**. Le radar de bord est surveillé en continu ; dès qu'un **missile** converge, l'ADS déclenche simultanément le largage de leurres et une manœuvre d'évasion prioritaire, puis rend la main une fois la menace passée. Un contact qui corrige sa trajectoire est reconnu comme autoguidage, marqué `GUIDE` dans le journal, et engagé plus vite.

📖 [guide](docs/guide-ads.md)

### Vaisseau doomsday

Vaisseau lourd et son poste de contrôle : HAL matériel, soutes, diagnostic, avertisseur sonore.

📖 [guide](docs/doomsday-ship.md)

---

## Mise à jour du réseau

`maj/` diffuse les nouvelles versions à tous les postes depuis un serveur, en s'appuyant sur `manifeste.lua`. Un poste vérifie, télécharge, valide puis bascule — et sait revenir en arrière.

📖 [guide](docs/mise-a-jour.md)

---

## Tests

Tout se vérifie hors du jeu, sur un interpréteur Lua 5.4, via l'émulateur CraftOS `tests/craftos.lua` et le simulateur de vol `tests/banc_vol.lua`.

```
lua5.4 tests/test_balise.lua             #  49
lua5.4 tests/test_autopilote.lua         # 180
lua5.4 tests/test_command.lua            # 246
lua5.4 tests/test_command_runtime.lua    # 128
lua5.4 tests/test_vaisseau.lua           # 176
lua5.4 tests/test_vaisseau_runtime.lua   #  30
lua5.4 tests/test_ads.lua                # 136
lua5.4 tests/test_interception.lua       # 101
lua5.4 tests/test_intercepteur.lua       #  63
lua5.4 tests/test_armement.lua           #  49
lua5.4 tests/test_systeme.lua            #  25
lua5.4 tests/test_maj.lua                #  72
```

**1255 vérifications, toutes vertes** sur la branche consolidée.

Les bancs ne se contentent pas de vérifier des messages de journal : `test_intercepteur.lua` fait tourner le **vrai** module d'autopilote sur le simulateur de vol, en boucle fermée — ordre du sol → radar → maths d'interception → autopilote → sorties moteur → modèle physique → GPS bruité → retour.

---

## Arborescence

| Dossier | Rôle |
|---|---|
| `balise/` | balises GPS fixes |
| `autopilote/` | module de pilotage, interface de réglage, câblage, satellite |
| `command/` | poste de commandement au sol, carte, scanner, transpondeur |
| `radar/` | radars au sol |
| `intercepteur/` | système embarqué de scramble |
| `systeme/` | système d'exploitation de bord de l'intercepteur |
| `ads/` | contre-mesures embarquées |
| `vaisseau/` | vaisseau doomsday |
| `lanceur/` | lanceurs |
| `maj/`, `outils/`, `manifeste.lua` | mise à jour du réseau |
| `tests/` | émulateur CraftOS, simulateur de vol, bancs d'essai |
| `docs/` | guides détaillés |
