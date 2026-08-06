# FrenchNet — Balises GPS (CC: Tweaked)

Balises fixes pour **AERONAUTICS WARFARE**. Chaque balise diffuse sa position X/Y/Z en continu par rednet (modem Ender, portée illimitée) et sert d'hôte GPS pour les avions.

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
