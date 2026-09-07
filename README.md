# FrenchNet — CC: Tweaked pour AERONAUTICS WARFARE

Deux systèmes indépendants :

| Système | Rôle | Documentation |
|---|---|---|
| **Balises GPS** | Constellation GPS du serveur, position X/Y/Z diffusée en continu | [guide complet](docs/guide-complet.md) |
| **Navire intercepteur** | Système embarqué de scramble : interception prédictive, arc arrière, tir, évasion, retour base | [guide complet](docs/intercepteur.md) |

---

# 1. Balises GPS

Balises fixes. Chaque balise diffuse sa position X/Y/Z en continu par rednet (modem Ender, portée illimitée) et sert d'hôte GPS pour les avions.

## Installation

Sur chaque ordinateur balise (1 ordinateur + 1 modem Ender collé) :

```
mkdir balise
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-gps-beacons-gv3cs5/balise/balise.lua balise/balise.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-gps-beacons-gv3cs5/balise/config_balise.lua balise/config_balise.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-gps-beacons-gv3cs5/balise/startup.lua startup.lua
edit balise/config_balise.lua
reboot
```

## Configuration

Deux lignes à changer sur **chaque** balise :

```lua
identifiant      = "BAL-01-NORD",                     -- unique sur le serveur
positionManuelle = { x = 1200, y = 210, z = -2600 },  -- F3, ligne "Block:"
```

C'est tout : la balise démarre, diffuse toutes les 5 s et redémarre seule en cas d'erreur.

## Déploiement

4 balises minimum, **non alignées** et à **4 altitudes différentes** (sinon le GPS est faux) :

| Identifiant | X | Y | Z |
|---|---|---|---|
| `BAL-01-NORD` | 1200 | 210 | -2600 |
| `BAL-02-EST` | 4300 | 95 | 500 |
| `BAL-03-SUD` | -800 | 140 | 3300 |
| `BAL-04-OUEST` | -3500 | 60 | -400 |

Les chunks des balises doivent rester **chargés** (`forceload`), sinon elles cessent d'émettre.

## Vérifier

```
recepteur      -- liste les balises actives et leur distance
gps locate     -- teste le GPS depuis n'importe quelle machine
```

## En cas de problème

Le journal indique toujours l'étape exacte :

```
[ERREUR] [etape: envoi rednet (broadcast)] erreur detectee a l'etape 'envoi rednet (broadcast)' : ...
```

Consultable à l'écran ou dans `balise/balise.log`.

## Fichiers

| Fichier | Rôle |
|---|---|
| `balise/balise.lua` | Programme de la balise |
| `balise/config_balise.lua` | Config (à éditer par balise) |
| `balise/startup.lua` | Démarrage automatique |
| `balise/recepteur.lua` | Moniteur de contrôle |

📖 **[Guide complet](docs/guide-complet.md)** — toutes les options, format des messages, table de diagnostic, intégration côté avion.

---

# 2. Navire intercepteur de scramble

Système **embarqué**, indépendant du système de défense au sol. Il ne connaît ni les zones, ni les classes Charlie / Bravo / Alpha / Roméo, et n'accepte que **deux ordres** : `SCRAMBLE` (intercepter la cible désignée) et `FEU` (ouvrir le feu sur cette même cible).

Mods : Create Aeronautics, Create Radars, Create Big Cannons, CC: Tweaked.

## Ce qu'il fait

- **Interception prédictive** — il résout le temps de vol et vise la position *future* de la cible, pas sa position actuelle.
- **Arc arrière 4 h – 8 h, 300 à 400 blocs** — jamais de face. Hors de l'arc, il contourne par le flanc.
- **Orbite ou zigzag** une fois en position, avec vitesse asservie sur celle de la cible (ni trop vite, ni trop lentement, sans percuter).
- **Évasion prioritaire** sur détection de dégât, en break alterné, puis reprise de la position d'attaque.
- **Retour base automatique** sur destruction confirmée, via des points de retour configurables. Le réarmement reste **manuel**.
- **Journal détaillé** à chaque étape critique, pour tracer tout comportement anormal après coup.

## ⚠️ Le module d'autopilote n'est pas dans ce dépôt

Ce système **n'écrit aucune loi de vol** : `intercepteur/autopilote.lua` est un *adaptateur* qui charge votre module d'autopilote standardisé, normalise son API et lui transmet la configuration véhicule. L'asservissement en cascade, le PID et le repli dead-band restent chez lui.

Si le module est introuvable, **le navire refuse de décoller** — c'est délibéré.

Les critères de dégât et les points de retour n'existant pas non plus dans ce dépôt, ils sont définis explicitement dans `intercepteur/config_intercepteur.lua`, en un seul endroit. Voir [§1 du guide](docs/intercepteur.md).

## Installation

```
mkdir intercepteur
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/interceptor-ship-onboard-system-uca5no/intercepteur/intercepteur.lua        intercepteur/intercepteur.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/interceptor-ship-onboard-system-uca5no/intercepteur/config_intercepteur.lua intercepteur/config_intercepteur.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/interceptor-ship-onboard-system-uca5no/intercepteur/noyau.lua               intercepteur/noyau.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/interceptor-ship-onboard-system-uca5no/intercepteur/interception.lua        intercepteur/interception.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/interceptor-ship-onboard-system-uca5no/intercepteur/autopilote.lua          intercepteur/autopilote.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/interceptor-ship-onboard-system-uca5no/intercepteur/radar.lua               intercepteur/radar.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/interceptor-ship-onboard-system-uca5no/intercepteur/armement.lua            intercepteur/armement.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/interceptor-ship-onboard-system-uca5no/intercepteur/liaison.lua             intercepteur/liaison.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/interceptor-ship-onboard-system-uca5no/intercepteur/startup.lua             startup.lua
edit intercepteur/config_intercepteur.lua
reboot
```

## Configuration minimale

```lua
identifiant      = "INT-01",                      -- unique sur le serveur
cheminAutopilote = "/autopilote/autopilote.lua",  -- votre module standardisé
retour = {
  pointsRetour = {                                -- le dernier point est la base
    { x = 1500, y = 220, z = -2400, nom = "point de degagement" },
    { x = 1200, y = 150, z = -2600, nom = "base" },
  },
},
```

## Tests

```
lua5.4 tests/test_interception.lua    # 87/87 — maths d'interception, hors CraftOS
lua5.4 tests/test_intercepteur.lua    # 86/86 — mission complète simulée
lua5.4 tests/test_balise.lua          # 49/49 — non-régression des balises
```

## Fichiers

| Fichier | Rôle |
|---|---|
| `intercepteur/intercepteur.lua` | Machine à états et superviseur |
| `intercepteur/config_intercepteur.lua` | **Config par véhicule**, partagée avec l'autopilote |
| `intercepteur/interception.lua` | Prédiction, arc arrière, critères de dégât, solution de tir |
| `intercepteur/autopilote.lua` | Adaptateur vers le module d'autopilote standardisé |
| `intercepteur/radar.lua` | Radar embarqué et pistage (Create Radars) |
| `intercepteur/armement.lua` | Affût et cadence de tir (Create Big Cannons) |
| `intercepteur/liaison.lua` | Ordres du sol — SCRAMBLE et FEU uniquement |
| `intercepteur/noyau.lua` | Journal, étapes, exécution protégée, géométrie |

📖 **[Guide complet](docs/intercepteur.md)** — contrat d'interface autopilote, géométrie de l'arc arrière, critères de dégât, déploiement et réglages à mesurer avant le premier vol armé.
