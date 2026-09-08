# FrenchNet — Systèmes CC: Tweaked pour AERONAUTICS WARFARE

| Système | Rôle | Guide |
|---|---|---|
| **Balises GPS** | Constellation GPS fixe pour tout le serveur | [docs/guide-complet.md](docs/guide-complet.md) |
| **FrenchNet Command** | Défense aérienne autonome, identification ami-ennemi | [docs/frenchnet-command.md](docs/frenchnet-command.md) |

---

## Balises GPS

Balises fixes. Chaque balise diffuse sa position X/Y/Z en continu par rednet (modem Ender, portée illimitée) et sert d'hôte GPS pour les avions.

```
mkdir balise
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/balise/balise.lua balise/balise.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/balise/config_balise.lua balise/config_balise.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/balise/startup.lua startup.lua
edit balise/config_balise.lua
reboot
```

Deux lignes à changer sur **chaque** balise :

```lua
identifiant      = "BAL-01-NORD",                     -- unique sur le serveur
positionManuelle = { x = 1200, y = 210, z = -2600 },  -- F3, ligne "Block:"
```

4 balises minimum, **non alignées** et à **4 altitudes différentes**, chunks **forceload**.

---

## FrenchNet Command

Défense aérienne autonome installée au sol. **Command décide, il ne tire pas** : il détecte, classe, identifie ami-ennemi, choisit un palier d'escalade, désigne la plateforme qui doit réagir, puis transmet à **FrenchNet Fire Control**.

### Architecture — quatre types de machines

| Machine | Rôle | Combien |
|---|---|---|
| **Poste de commandement** | décide. Ne balaie pas, ne tire pas. | 1 |
| **Station radar** | balaie et transmet ses contacts au poste | 1 par radar |
| **Balise de lanceur** | annonce position, **munitions restantes** et tirs | 1 par plateforme |
| **Transpondeur** | émet le code IFF d'un véhicule | 1 par véhicule ami |

### Installation — poste de commandement

Advanced Computer + modem Ender, chunk **forceload**. Un moniteur avancé 3×2
change tout pour la carte tactique.

```
mkdir command
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/command/command.lua command/command.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/command/noyau.lua command/noyau.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/command/terrain.lua command/terrain.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/command/carte.lua command/carte.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/command/scanner.lua command/scanner.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/command/interface.lua command/interface.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/command/config_command.lua command/config_command.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/command/startup.lua startup.lua
edit command/config_command.lua
reboot
```

Trois champs avant la mise en service :

```lua
positionPoste = { x = 0, y = 80, z = 0 },   -- F3, ligne "Block:"
codeAllie     = "FN-ALLIE-0000",              -- code fixe, à changer
codeAccesMenu = "1234",                       -- code du menu protégé
```

### Installation — chaque station radar

Ordinateur + modem Ender + radar (Create Radars), chunk **forceload**.

```
mkdir radar
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/radar/radar.lua radar/radar.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/radar/config_radar.lua radar/config_radar.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/command/scanner.lua radar/scanner.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/radar/diagnostic.lua radar/diagnostic.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/radar/startup.lua startup.lua
edit radar/config_radar.lua
reboot
```

Deux champs par station : `identifiant` (unique) et `position` (F3, « Block »).

> ⚠ **Le radar doit toucher l'ordinateur par une face, ou être relié par un modem *filaire*** (câble + un modem collé à chaque bloc, les deux activés d'un clic droit). Un modem sans fil ou Ender ne transporte **pas** un périphérique.
>
> Si l'ordinateur ne trouve pas le radar : `diagnostic` liste tous les périphériques visibles, leurs types, leurs méthodes, et le format brut des échos. La détection FrenchNet se fait **par méthode et non par nom de type** — elle fonctionne quel que soit le nom que le mod donne à son périphérique.

### Installation — chaque plateforme de défense

Ordinateur + modem Ender + un coffre de munitions accolé (comptage réel).

```
mkdir lanceur
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/lanceur/lanceur.lua lanceur/lanceur.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/lanceur/config_lanceur.lua lanceur/config_lanceur.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/lanceur/startup.lua startup.lua
edit lanceur/config_lanceur.lua
reboot
```

L'`identifiant` est **le nom repris dans les ordres de tir** : il doit
correspondre à ce que Fire Control connaît.

### Installation — chaque véhicule ami

```
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/command/transpondeur.lua transpondeur.lua
transpondeur FN-ALLIE-0000
```

**Sans transpondeur, un véhicule est classé INCONNU** — avec toutes les conséquences prévues par la doctrine de zone.

### Deux voies d'identification

| Voie | Question | Faille |
|---|---|---|
| **Transpondeur** | quel code porte-t-il ? | il se capture **avec** l'appareil |
| **Radar** | qu'est-ce que c'est, à qui est-il ? | champs facultatifs selon le mod |

**Sans code valide, la cible reste INCONNUE** — la voie radar ne délivre aucun laissez-passer. Elle peut seulement en **retirer** un :

- code allié valide + propriétaire hostile → **transpondeur capturé** : code écarté, cible déclassée INCONNUE, contrôleur alerté. Avec une seule voie, elle traversait une zone Alpha impunément.
- ami reconnu par le radar mais transpondeur muet → **émetteur en panne** : la cible reste INCONNUE (c'est la règle), mais le contrôleur est prévenu et peut la déclarer alliée d'un clic.

Les listes `nomsHostiles` / `nomsAllies` fonctionnent sans aucun mod tiers.

### Doctrine en un coup d'œil

| Zone | Mode | Code allié | Code général | Inconnu |
|---|---|---|---|---|
| **Charlie** | Paix | observation | libre passage sans suivi | scramble |
| **Charlie** | Guerre | observation | scramble seul | destruction |
| **Bravo** | Paix | observation | libre passage sans suivi | scramble |
| **Bravo** | Guerre | observation | destruction | destruction |
| **Alpha** | Paix / Guerre | observation | destruction + scramble | destruction + scramble |
| **Roméo** | Paix | observation | destruction totale + mobilisation | destruction totale + mobilisation |
| **Roméo** | Guerre | **scramble** | destruction totale + mobilisation | destruction totale + mobilisation |

- Zone non classifiée → **hors juridiction**, le système ne fait rien.
- Chevauchement → **la classe la plus stricte l'emporte** : Roméo > Alpha > Bravo > Charlie.
- Alerte maximale manuelle → régime **Roméo / Guerre** partout, en un clic.

### Carte tactique

Carte mouvante, zoomable de 2 à 1024 blocs par caractère, qui reste accrochée au
contact le plus dangereux pendant tout l'engagement.

**Le glyphe dit *ce que c'est*, la couleur dit *qui c'est*.**

| Glyphe | | Couleur | |
|---|---|---|---|
| `*` | missile ou projectile | 🟢 vert | code allié — libre passage |
| `^` | aéronef, navire volant | 🔵 bleu | code général |
| `o` | joueur en vol | 🟠 orange | inconnu, hors zone ou non engagé |
| `#` | véhicule au sol | 🔴 rouge | confirmé ennemi ou engagement en cours |
| `i` | infanterie | fond jaune | scramble AG en attente de validation |
| `R` `L` `+` | station radar, lanceur, poste | | |

Le fond de carte est colorié par classe de zone, et calculé par le **même
moteur** que les décisions : la carte ne peut pas mentir sur la doctrine.

**Clic gauche sur un contact** ouvre le panneau d'ordre : cases à cocher
**Scramble** (ou **Scramble AG**), **Attaque**, les deux, ou **Allié**.
Déclarer un contact allié interrompt immédiatement tout engagement en cours.

`+`/`−` zoom · flèches déplacer · `C` poste · `M` menace · `1`–`6` onglets

### Interface

- **Écran d'accueil, sans code** : bascule guerre / paix en **un clic** (raccourci `G`), alerte maximale, état opérationnel.
- **Menu protégé, avec code** : configuration des zones (rectangle à 4 coins ou cercle centre + rayon) et rotation du code général.

### Ordres transmis à Fire Control

```
SAM-Est Fire type Aerial
AirShip1 Scramble type Aerial
Appui-1 Scramble AG type GroundVehicle
```

Trois catégories seulement : `Aerial`, `GroundVehicle`, `Infantry`. Le choix de l'arme ne regarde pas Command.

> ⚠ Les verbes `Fire` et `Scramble` sont **distincts par défaut**. Un scramble de vérification n'est pas un ordre de tir : en zone Roméo en temps de guerre, un allié en scramble serait abattu par Fire Control si les deux verbes étaient confondus. `formatUniqueFire = true` revient à un verbe unique, en connaissance de cause.

> ⚠ **Le Scramble AG ne part jamais tout seul.** Quand la doctrine appelle un scramble sur de l'infanterie ou un véhicule, Command ne transmet rien : il désigne la plateforme, enregistre une **demande** et alerte le contrôleur, qui valide ou refuse depuis la carte. Les deux issues sont journalisées — un ordre non donné est une décision. Le feu, lui, reste automatique.

### Désignation du tireur

```
score =   1.5 × (1 − munitions / munitionsMax)     <- le stock pèse le plus lourd
        + 1.0 × (distance / distanceMax)
        + 0.5 × (tirs / tirsMax)
```

Une plateforme à **stock nul n'est jamais désignée** : envoyer l'ordre à une rampe vide, c'est perdre la cible au deuxième tir. La balise déduit les tirs des **baisses de stock** — aucune déclaration à faire.

### Terrain

Le système **apprend** le relief au lieu de le calculer : reconstituer la génération de Minecraft depuis la seed est hors de portée d'un ordinateur CC: Tweaked, et ignorerait de toute façon tout ce que les joueurs ont construit. Chaque station radar, chaque lanceur et chaque joueur qui marche est une sonde d'altitude. Le modèle survit aux redémarrages et devient plus fin avec le temps.

### Confirmation de destruction

Deux déclencheurs indépendants, l'un **ou** l'autre confirme :

1. **disparition du radar** — mais uniquement si le dernier point connu était dans l'**enveloppe fiable** (80 % de la portée). Au-delà, la cible a probablement fui : piste déclarée **perdue**, contrôleur alerté.
2. **signature de crash** — perte d'au moins 50 % de vitesse horizontale **et** d'environ 40 blocs d'altitude sur la **même fenêtre de 3 s**.

Sinon, réémission d'un ordre de tir, **3 tentatives maximum** avant alerte d'un contrôleur humain.

### Vérifier

```
lua5.4 tests/test_command.lua           -- 229 vérifications : doctrine, terrain, carte, IFF
lua5.4 tests/test_command_runtime.lua   -- 100 vérifications : la chaîne complète, réseau simulé
```

---

## En cas de problème

Le journal indique toujours l'étape exacte :

```
[ERREUR] [etape: emission de l'ordre vers Fire Control] erreur detectee a l'etape '...' : ...
```

Consultable à l'écran (onglet **Journal**) ou dans `balise/balise.log` / `command/command.log`.

---

## Fichiers

| Fichier | Rôle |
|---|---|
| `balise/balise.lua` | Programme de la balise |
| `balise/config_balise.lua` | Config balise (à éditer par balise) |
| `balise/recepteur.lua` | Moniteur de constellation |
| `command/command.lua` | Programme principal du poste de commandement |
| `command/noyau.lua` | Moteur de décision pur, testable hors du jeu |
| `command/terrain.lua` | Modèle de terrain observé, testable hors du jeu |
| `command/carte.lua` | Projection et symbologie de la carte, testable hors du jeu |
| `command/scanner.lua` | Adaptateur radar, partagé poste ↔ stations |
| `command/interface.lua` | Interface de contrôle et carte tactique |
| `command/config_command.lua` | Config du poste (à éditer) |
| `radar/radar.lua` | Station radar déportée |
| `radar/diagnostic.lua` | Diagnostic du périphérique radar |
| `lanceur/lanceur.lua` | Balise de lanceur (munitions, tirs) |
| `command/transpondeur.lua` | Émetteur de code, à poser sur chaque véhicule |
| `tests/test_command.lua` | Banc d'essai de la doctrine (noyau pur) |
| `tests/test_command_runtime.lua` | Banc d'essai de la chaîne complète (CraftOS émulé) |
