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

### Installation — poste de commandement

Advanced Computer + modem Ender + radar (Create Radars), chunk **forceload**.

```
mkdir command
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/command/command.lua command/command.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/command/noyau.lua command/noyau.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/command/interface.lua command/interface.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/command/config_command.lua command/config_command.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/command/startup.lua startup.lua
edit command/config_command.lua
reboot
```

Trois champs avant la mise en service :

```lua
positionRadar = { x = 0, y = 80, z = 0 },   -- F3, ligne "Block:"
codeAllie     = "FN-ALLIE-0000",             -- code fixe, à changer
codeAccesMenu = "1234",                      -- code du menu protégé
```

### Installation — chaque véhicule ami

```
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/frenchnet-command-defense-xm41dc/command/transpondeur.lua transpondeur.lua
transpondeur FN-ALLIE-0000
```

**Sans transpondeur, un véhicule est classé INCONNU** — avec toutes les conséquences prévues par la doctrine de zone.

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

### Interface

- **Écran d'accueil, sans code** : bascule guerre / paix en **un clic** (raccourci `G`), alerte maximale, état opérationnel.
- **Menu protégé, avec code** : configuration des zones (rectangle à 4 coins ou cercle centre + rayon) et rotation du code général.

### Ordres transmis à Fire Control

```
AirShip1 Fire type Aerial
AirShip1 Scramble type Aerial
```

Trois catégories seulement : `Aerial`, `GroundVehicle`, `Infantry`. Le choix de l'arme ne regarde pas Command.

> ⚠ Les verbes `Fire` et `Scramble` sont **distincts par défaut**. Un scramble de vérification n'est pas un ordre de tir : en zone Roméo en temps de guerre, un allié en scramble serait abattu par Fire Control si les deux verbes étaient confondus. `formatUniqueFire = true` revient à un verbe unique, en connaissance de cause.

### Confirmation de destruction

Deux déclencheurs indépendants, l'un **ou** l'autre confirme :

1. **disparition du radar** — mais uniquement si le dernier point connu était dans l'**enveloppe fiable** (80 % de la portée). Au-delà, la cible a probablement fui : piste déclarée **perdue**, contrôleur alerté.
2. **signature de crash** — perte d'au moins 50 % de vitesse horizontale **et** d'environ 40 blocs d'altitude sur la **même fenêtre de 3 s**.

Sinon, réémission d'un ordre de tir, **3 tentatives maximum** avant alerte d'un contrôleur humain.

### Vérifier

```
lua5.4 tests/test_command.lua           -- 133 vérifications : la doctrine d'engagement
lua5.4 tests/test_command_runtime.lua   --  55 vérifications : la chaîne complète, radar simulé
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
| `command/interface.lua` | Interface de contrôle |
| `command/config_command.lua` | Config du poste (à éditer) |
| `command/transpondeur.lua` | Émetteur de code, à poser sur chaque véhicule |
| `tests/test_command.lua` | Banc d'essai de la doctrine (noyau pur) |
| `tests/test_command_runtime.lua` | Banc d'essai de la chaîne complète (CraftOS émulé) |
