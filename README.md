# FrenchNet — AERONAUTICS WARFARE (CC: Tweaked)

Systèmes embarqués du serveur **AERONAUTICS WARFARE** (Create Aeronautics, NeoForge 1.21.1).

| Système | Rôle | Guide |
|---|---|---|
| **Balises GPS** | Constellation de balises fixes, hôtes GPS pour tout le serveur | [guide](docs/guide-complet.md) |
| **Autopilote** | Bibliothèque de pilotage autonome pour véhicules aériens | [guide](docs/guide-autopilote.md) |
| **Navire intercepteur** | Système embarqué de scramble + système d'exploitation de bord | [guide](docs/intercepteur.md) |
| **Câblage** | Brancher un ordinateur sur un véhicule et le faire bouger | [guide](docs/guide-cablage.md) |
| **Installation** | Poser les fichiers sur les ordinateurs, et dépannage | [guide](docs/guide-installation.md) |

---

> ⚠️ **`wget` renvoie 404 ?** Le dépôt est **privé**, et CC: Tweaked ne peut pas s'authentifier sur GitHub : aucune adresse `raw.githubusercontent.com` ne répondra. Rendez le dépôt public, ou passez les fichiers par la sauvegarde du monde. Marche à suivre complète dans le **[guide d'installation](docs/guide-installation.md)**.

## Installation en une commande

Dépôt public requis. Sur chaque ordinateur :

```
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/autopilote-lua-module-kfnu2k/installe.lua installe
installe balise       -- balise GPS fixe
installe vehicule     -- autopilote d'un véhicule
installe intercepteur -- navire de scramble (autopilote + interception + OS)
installe satellite    -- ordinateur de sortie déporté
```

L'installateur crée les dossiers, vérifie chaque fichier téléchargé (une page d'erreur HTML enregistrée comme du Lua est détectée et refusée) et préserve les configurations déjà réglées.

---

## Balises GPS

Balises fixes qui diffusent leur position X/Y/Z en continu par rednet (modem Ender, portée illimitée) et servent d'hôte GPS pour les avions.

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

4 balises minimum, **non alignées** et à **4 altitudes différentes**, dans des chunks **maintenus chargés**.

```
recepteur      -- liste les balises actives et leur distance
gps locate     -- teste le GPS depuis n'importe quelle machine
```

📖 **[Guide des balises](docs/guide-complet.md)** — options, format des messages, diagnostic.

---

## Autopilote

Bibliothèque de pilotage autonome, installable telle quelle sur n'importe quel véhicule aérien : dirigeable de livraison, intercepteur de scramble, navire armé. Ce n'est pas un programme final — les autres systèmes FrenchNet lui donnent une cible ou une liste de points de passage, et il amène le véhicule avec précision.

### Installation

Sur chaque véhicule (1 ordinateur + 1 modem Ender pour le GPS) :

```
mkdir autopilote
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/autopilote-lua-module-kfnu2k/autopilote/autopilote.lua autopilote/autopilote.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/autopilote-lua-module-kfnu2k/autopilote/config_vehicule.lua autopilote/config_vehicule.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/autopilote-lua-module-kfnu2k/autopilote/ravitaillement.lua autopilote/ravitaillement.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/autopilote-lua-module-kfnu2k/autopilote/interface.lua autopilote/interface.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/autopilote-lua-module-kfnu2k/autopilote/cablage.lua autopilote/cablage.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/autopilote-lua-module-kfnu2k/autopilote/startup.lua startup.lua
interface                                   -- réglage du véhicule à l'écran
cablage                                     -- vérification du câblage, pilotage manuel
reboot
```

**Premier montage ?** Commencez par le [guide de câblage](docs/guide-cablage.md) : il explique face par face comment brancher l'ordinateur pour avancer, pivoter, monter et descendre, et comment vérifier chaque sens avec l'outil `cablage`.

### Utilisation

```lua
local autopilote = dofile("/autopilote/autopilote.lua")
local ap = autopilote.nouveau()          -- lit config_vehicule.lua

ap.initialiser()                         -- relit la position AVANT tout mouvement
ap.suivreItineraire({
  { x =  480, y = 120, z = -1200, nom = "SORTIE-HANGAR" },
  { x = 1980, y = 118, z = -3100, nom = "ENTREPOT-3", type = "depot" },
})

parallel.waitForAny(ap.executer, function()
  ap.attendreArrivee(600)
  print("cargaison larguee")
  ap.rejoindreRavitaillement()
end)
```

`allerA` · `suivreItineraire` · `maintenirPosition` · `arreter` — les programmes de mission ne touchent jamais à la logique de vol.

### Ce qu'il fait tout seul

- **Asservissement en cascade** sur quatre axes (altitude, cap, avance, dérive) : une boucle de position calcule une vitesse cible, une boucle de vitesse produit la commande — le véhicule ralentit progressivement au lieu de dépasser puis revenir.
- **PID robustes** : intégrale bornée et gelée en saturation, dérivée sur la mesure, limitation de pente, temps réellement écoulé.
- **Repli automatique en zone morte** si un axe devient instable, avec hystérésis, journalisation et forçage manuel.
- **Arrivée** validée seulement après une durée continue dans les marges, puis **maintien de position** avec des gains plus serrés.
- **Décalages** du point de référence GPS et du point de dépôt, tournés selon le cap : le pilotage vise le centre réel, et la charge tombe sur la cible.
- **Robustesse** : perte GPS → estime puis mode secours, plantage → relance, redémarrage → relecture de la position avant tout mouvement, journal détaillé à chaque étape.

### Réglage

```
interface            -- configuration du véhicule (au sol)
cablage              -- vérification du câblage et pilotage manuel au clavier
interface vol        -- réglage des gains PID en vol, avec courbes temps réel
interface journal    -- consultation du journal
```

Chaque véhicule a son propre `config_vehicule.lua` : identité, décalages, tolérances, vitesses, gabarit, gains PID. **Aucune valeur de vol n'est écrite en dur dans le code** — une valeur obligatoire manquante empêche le démarrage et est nommée en clair. La position de ravitaillement est une constante de réseau verrouillée (`ravitaillement.lua`), affichée mais non modifiable.

📖 **[Guide de l'autopilote](docs/guide-autopilote.md)** — API complète, conventions, méthode de réglage, table de diagnostic.

---

## Tests

Bancs d'essai hors du jeu, sur un interpréteur Lua 5.4 :

```
lua5.4 tests/test_balise.lua        -- 49 vérifications
lua5.4 tests/test_autopilote.lua    -- 180 vérifications, dont un vol simulé en boucle fermée
```

## Fichiers

| Fichier | Rôle |
|---|---|
| `balise/balise.lua` | Programme de la balise |
| `balise/config_balise.lua` | Config (à éditer par balise) |
| `balise/startup.lua` | Démarrage automatique |
| `balise/recepteur.lua` | Moniteur de constellation |
| `autopilote/autopilote.lua` | La bibliothèque de pilotage |
| `autopilote/config_vehicule.lua` | Config (à éditer par véhicule) |
| `autopilote/ravitaillement.lua` | Station de ravitaillement (verrouillée) |
| `autopilote/interface.lua` | Interface de réglage et menu de vol |
| `autopilote/cablage.lua` | Vérification du câblage et pilotage manuel |
| `autopilote/startup.lua` | Démarrage automatique du véhicule |
| `autopilote/exemple_mission.lua` | Trois missions types |
| `tests/banc_vol.lua` | Mini-CraftOS + simulateur de vol |
| `installe.lua` | Installateur en une commande |

---

## Navire intercepteur de scramble

Système **embarqué**, indépendant du système de défense au sol. Il ne connaît ni
les zones, ni les classes Charlie / Bravo / Alpha / Roméo, et n'accepte que
**deux ordres** : `SCRAMBLE` (intercepter la cible désignée) et `FEU`.

Il **appelle** le module d'autopilote ci-dessus — cascade, PID, repli en zone
morte — et n'écrit aucune loi de vol. Si le module est introuvable, le navire
refuse de décoller.

### Ce qu'il fait

- **Interception prédictive** — il résout le temps de vol et vise la position
  *future* de la cible, pas sa position actuelle.
- **Arc arrière 4 h – 8 h, 300 à 400 blocs** — jamais de face. Hors de l'arc,
  il contourne par le flanc.
- **Orbite ou zigzag** une fois en position, avec vitesse asservie sur celle de
  la cible (ni trop vite, ni trop lentement, sans percuter).
- **L'ordre de tir prime sur la position** — sous ordre de feu, le navire
  engage dès qu'il a une solution, même hors de son arc ; il y revient
  progressivement, par corrections bornées, sans cesser de tirer.
- **Arsenal configurable** — plusieurs armes, chacune avec sa portée, son
  utilité (anti-aérien, anti-sol, défensif, polyvalent) et sa balistique. Le
  navire choisit l'arme adaptée à la distance et à la nature de la cible.
- **Évasion prioritaire** sur détection de dégât, en break alterné.
- **Retour base automatique** sur destruction confirmée, confié au système de
  points de passage de l'autopilote. Le réarmement reste **manuel**.
- **Journal détaillé et partagé** avec l'autopilote : une mission se relit de
  bout en bout, vol compris.

### Système d'exploitation de bord

`systeme/os.lua` fait tourner l'interface et le système d'interception **côte à
côte**, chacun dans sa fenêtre, sur un noyau multitâche : l'équipage règle
l'armement pendant que le navire poursuit sa cible, sans qu'un ordre du sol ne
se perde.

Sept pages : **État**, **Mission**, **Armement**, **Autopilote**, **Journal**,
**Système**, **Console**.

La page **Armement** est celle qui déclare les armes : ajout, portée, utilité,
balistique, cadence — et elle affiche la **couverture de portée** en signalant
les trous, l'information qui manque le plus souvent à l'équipage.

### Installation

```
installe intercepteur
```

Puis, dans l'ordre : `interface` (régler le véhicule), `cablage` (vérifier les
moteurs), `systeme/os` → page Armement (déclarer les armes), et enfin
`edit intercepteur/config_intercepteur.lua` (identifiant et points de retour).

### Tests

```
lua5.4 tests/test_interception.lua   # 101 — maths d'interception, hors CraftOS
lua5.4 tests/test_armement.lua       #  49 — arsenal et fichier d'armement
lua5.4 tests/test_systeme.lua        #  25 — noyau multitâche de l'OS
lua5.4 tests/test_intercepteur.lua   #  63 — mission complète, VRAI autopilote
lua5.4 tests/test_autopilote.lua     # 180 — non-régression de l'autopilote
lua5.4 tests/test_balise.lua         #  49 — non-régression des balises
```

📖 **[Guide complet](docs/intercepteur.md)** — géométrie de l'arc arrière, règle
d'engagement, arsenal, critères de dégât, système d'exploitation, déploiement.
