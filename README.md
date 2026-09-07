# FrenchNet — AERONAUTICS WARFARE (CC: Tweaked)

Deux systèmes autonomes pour le serveur **AERONAUTICS WARFARE**, écrits pour CC: Tweaked et prévus pour tourner sans intervention humaine.

| Système | Rôle | Guide |
|---|---|---|
| **Balises GPS** | Réseau de balises fixes diffusant leur position et servant d'hôtes GPS | [docs/guide-complet.md](docs/guide-complet.md) |
| **ADS** | Contre-mesures embarquées : détection de projectile entrant, leurres, évasion, reprise de tâche | [docs/guide-ads.md](docs/guide-ads.md) |

---

## Balises GPS

Chaque balise diffuse sa position X/Y/Z en continu par rednet (modem Ender, portée illimitée) et sert d'hôte GPS pour les avions.

### Installation

Sur chaque ordinateur balise (1 ordinateur + 1 modem Ender collé) :

```
mkdir balise
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-gps-beacons-gv3cs5/balise/balise.lua balise/balise.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-gps-beacons-gv3cs5/balise/config_balise.lua balise/config_balise.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-gps-beacons-gv3cs5/balise/startup.lua startup.lua
edit balise/config_balise.lua
reboot
```

Deux lignes à changer sur **chaque** balise :

```lua
identifiant      = "BAL-01-NORD",                     -- unique sur le serveur
positionManuelle = { x = 1200, y = 210, z = -2600 },  -- F3, ligne "Block:"
```

4 balises minimum, **non alignées** et à **4 altitudes différentes** (sinon le GPS est faux), dans des chunks **maintenus chargés**.

```
recepteur      -- liste les balises actives et leur distance
gps locate     -- teste le GPS depuis n'importe quelle machine
```

---

## ADS — contre-mesures embarquées

Sur **chaque navire**. Le radar de bord est surveillé en continu ; dès qu'un projectile converge vers le navire, l'ADS déclenche **simultanément** le largage de leurres et une manœuvre d'évasion prioritaire qui interrompt la tâche en cours, puis rend automatiquement la main une fois la menace passée.

Indépendant des systèmes au sol et du scramble, mais conçu pour tourner en parallèle d'eux sur le même navire.

### Installation

Sur chaque ordinateur ADS (1 ordinateur + 1 radar + largueurs de leurres + accès au pilotage) :

```
mkdir ads
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/aeronautics-ads-countermeasures-o0n1z2/ads/ads.lua ads/ads.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/aeronautics-ads-countermeasures-o0n1z2/ads/config_ads.lua ads/config_ads.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/aeronautics-ads-countermeasures-o0n1z2/ads/startup.lua startup.lua
edit ads/config_ads.lua
reboot
```

Deux réglages à adapter sur **chaque** navire :

```lua
identifiant = "NAV-01-CORSAIRE",                              -- unique sur le serveur
largueurs   = { { type = "redstone", cote = "left" },         -- sans eux, aucun leurre
                { type = "redstone", cote = "right" } },
```

### Armez-le en simulation d'abord

`piloteMode = "simulation"` et `journalNiveauEcran = "DEBUG"` : l'ADS détecte, calcule et journalise tout sans toucher aux commandes. Vérifiez dans `ads/ads.log` que les vraies menaces déclenchent et que les tirs qui passent au large ne déclenchent pas, ajustez `rayonMenace` et `motifsProjectile`, puis passez en `"auto"`.

**Trois limites à connaître avant de lui faire confiance** : un obus de tir direct arrive plus vite que le navire ne répond, les leurres ne trompent que ce qui vise, et les noms de méthodes des mods changent d'une version à l'autre (l'ADS les sonde et écrit son choix dans le journal). Détail dans [le guide](docs/guide-ads.md#1-ce-que-lads-ne-peut-pas-faire).

```
console_ads    -- etat ADS de toute la flotte (lecture seule)
```

---

## En cas de problème

Le journal indique toujours l'étape exacte :

```
[ERREUR] [etape: scan radar] erreur detectee a l'etape 'scan radar' : ...
```

Consultable à l'écran ou dans `balise/balise.log` / `ads/ads.log`. Chaque guide contient une table de diagnostic message → cause → correction.

---

## Fichiers

| Fichier | Rôle |
|---|---|
| `balise/balise.lua` | Programme de la balise |
| `balise/config_balise.lua` | Config balise (à éditer par balise) |
| `balise/startup.lua` | Démarrage automatique balise |
| `balise/recepteur.lua` | Moniteur de constellation |
| `ads/ads.lua` | Programme ADS |
| `ads/config_ads.lua` | Config ADS (à éditer par navire) |
| `ads/startup.lua` | Démarrage automatique ADS |
| `ads/console_ads.lua` | Console de supervision de flotte |

## Banc d'essai

```
lua5.4 tests/test_balise.lua     # 49 verifications
lua5.4 tests/test_ads.lua        # 127 verifications
```

`tests/craftos.lua` émule CraftOS hors du jeu (événements, minuteurs, rednet, modem, redstone, radar, interface de pilotage), ce qui permet de tester le fonctionnement nominal **et** le comportement en panne sans lancer Minecraft.
