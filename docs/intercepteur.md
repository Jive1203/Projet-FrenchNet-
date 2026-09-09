# Système embarqué du navire intercepteur de scramble

Serveur **AERONAUTICS WARFARE** — Create Aeronautics, Create Radars,
Create Big Cannons, CC: Tweaked.

Ce système vit **à bord** du navire. Il est indépendant du système de défense
au sol : il ne connaît ni les zones, ni les classes Charlie, Bravo, Alpha ou
Roméo. Il reçoit deux ordres, un point c'est tout.

---

## 1. À lire avant toute chose : ce qui est réel, ce qui est supposé

Le **module d'autopilote standardisé existe** et il est utilisé pour de vrai :
`autopilote/autopilote.lua` (asservissement en cascade, PID en contrôle
principal, repli automatique en zone morte). Le système d'interception
**l'appelle**, il ne réécrit aucune loi de vol.

En revanche, deux choses n'existent nulle part dans ce dépôt et sont donc
**définies ici, explicitement, comme des hypothèses** :

| Élément | État |
|---|---|
| Critères de dégât / confirmation de destruction | **Défini dans `intercepteur/config_intercepteur.lua`**, bloc `degats`. Valeurs de départ plausibles, **pas des mesures** faites sur votre serveur. |
| Balistique de chaque arme | **Définie par arme**, dans l'arsenal. Même statut : à mesurer. |

Le troisième — les points de retour — n'a plus besoin d'être réinventé : le
retour à la base est **confié au système de points de passage de l'autopilote**
(`ap.suivreItineraire`), celui-là même qui sert aux missions de livraison.

Si le module d'autopilote est introuvable au démarrage, **le navire refuse de
décoller**. C'est délibéré : voler avec un contrôleur de substitution serait
plus dangereux que de rester au sol.

## 2. Contenu

```
intercepteur/
  intercepteur.lua           machine à états + superviseur
  config_intercepteur.lua    configuration du navire
  config_armement.lua        arsenal — écrit par la page Armement de l'OS
  noyau.lua                  journal, étapes, exécution protégée, géométrie
  interception.lua           maths pures : prédiction, arc arrière, dégâts, tir
  autopilote.lua             ADAPTATEUR vers autopilote/autopilote.lua
  radar.lua                  radar embarqué (Create Radars) et pistage
  armement.lua               arsenal (Create Big Cannons) et choix d'arme
  liaison.lua                ordres du sol — SCRAMBLE et FEU uniquement
  startup.lua                lanceur du système d'interception seul

systeme/                     SYSTÈME D'EXPLOITATION DE BORD
  os.lua                     amorçage, shell, pages
  noyau_taches.lua           ordonnanceur multitâche (fenêtres CC)
  ui.lua                     boîte à outils d'affichage
  arsenal_fichier.lua        lecture/écriture du fichier d'arsenal
  startup.lua                lanceur du système complet

autopilote/                  MODULE D'AUTOPILOTE STANDARDISÉ (appelé, non modifié)
  autopilote.lua             cascade, PID, repli zone morte
  config_vehicule.lua        LE fichier de réglage du véhicule
  interface.lua              interface de réglage (déléguée par l'OS)
```

Les tests, depuis la racine du dépôt :

```
lua5.4 tests/test_interception.lua   # 101 — maths d'interception, hors CraftOS
lua5.4 tests/test_armement.lua       #  49 — arsenal et fichier d'armement
lua5.4 tests/test_systeme.lua        #  25 — noyau multitâche de l'OS
lua5.4 tests/test_intercepteur.lua   #  63 — mission complète, VRAI autopilote
lua5.4 tests/test_autopilote.lua     # 180 — non-régression de l'autopilote
lua5.4 tests/test_balise.lua         #  49 — non-régression des balises GPS
```

`tests/test_intercepteur.lua` n'utilise **pas** de faux autopilote : il fait
tourner le vrai module sur le simulateur de vol `tests/banc_vol.lua`, en boucle
fermée — ordre du sol → radar → maths → adaptateur → autopilote → sorties
moteur → modèle physique → GPS bruité → retour.

## 3. Comment l'autopilote est appelé

`intercepteur/autopilote.lua` est un **adaptateur**. Il ne contient aucune loi
de pilotage : il construit une instance du module standardisé et lui parle.

| Ce que fait l'adaptateur | Appel réel |
|---|---|
| Construire l'autopilote | `autopilote.nouveau{ configuration, journal, commandes }` puis `ap.initialiser()` |
| Donner une consigne de vol | `ap.allerA({x,y,z}, { vitesseMax, transitHaute = false })` |
| Confier un itinéraire (retour base) | `ap.suivreItineraire(points, { vitesseMax, surEtape, surArrivee })` |
| Lire la télémétrie | `ap.etat()` — position, vitesse, mode, modes par axe |
| Tenir la position | `ap.maintenirPosition(point, cap)` |
| Faire voler le véhicule | `ap.executer()`, lancé **en tâche parallèle** |

Si le module chargé n'expose pas `nouveau()`, l'adaptateur bascule sur une
liaison générique « à plat » (`M.CONTRAT_PLAT`, en tête du fichier) et le
signale en AVERT. C'est un filet, pas le chemin nominal.

### Trois précautions, et pourquoi

1. **Le débit des consignes est limité.** `ap.allerA()` recalcule un
   itinéraire, journalise une ligne et peut écrire sur le disque. La boucle de
   contrôle tourne à 4 Hz : la rappeler à chaque cycle noierait le journal.
   Une consigne n'est réémise que si le point a bougé de plus de
   `seuilDeplacementConsigne` blocs, si la vitesse demandée a changé de plus de
   `seuilVitesseConsigne`, ou après `periodeRafraichissementConsigne` secondes.
2. **`transitHaute = false`.** Par défaut l'autopilote monte à l'altitude de
   croisière avant un long transit. En interception, la cible n'attendra pas.
3. **Reprise de mission désactivée.** Un intercepteur qui redémarre après un
   rechargement de chunk ne doit pas repartir sur une interception périmée.

### Un seul fichier de réglage par véhicule

`autopilote/config_vehicule.lua` reste **le** fichier du véhicule : gabarit,
moteurs, gains PID, vitesses, tolérances, enveloppe de vol.
`config_intercepteur.lua` ne le duplique pas — il le désigne
(`cheminConfigVehicule`) et peut le surcharger ponctuellement par son bloc
`autopilote`, en fusion récursive.

### Journal partagé

L'adaptateur passe le journal du navire à `nouveau{ journal = ... }`. Les
lignes de l'autopilote atterrissent donc dans `intercepteur.log`, au même
format : **une mission se relit de bout en bout, vol compris**.

## 4. Les deux seuls ordres acceptés

Protocole rednet `frenchnet_ordre`, champ `protocole = "FRENCHNET_ORDRE"`.

### SCRAMBLE — décoller et intercepter

```lua
rednet.send(idNavire, {
  protocole        = "FRENCHNET_ORDRE",
  type             = "SCRAMBLE",
  identifiantOrdre = "ORD-2026-0912",
  destinataire     = "INT-01",              -- facultatif : nil = tous les navires
  cible            = { x = 4200, y = 180, z = -1500,
                       vx = 0, vy = 0, vz = 60 },  -- vitesse facultative
}, "frenchnet_ordre")
```

La position transmise ne sert **qu'au premier contact**. Dès l'ordre reçu, le
suivi passe au radar embarqué et le navire recalcule sa trajectoire en continu
à partir de ses propres mesures.

### FEU — ouvrir le feu sur cette même cible

```lua
rednet.send(idNavire, {
  protocole        = "FRENCHNET_ORDRE",
  type             = "FEU",
  identifiantOrdre = "ORD-2026-0913",
  destinataire     = "INT-01",
  cible            = { x = …, y = …, z = … },  -- facultatif : rafraîchissement
}, "frenchnet_ordre")
```

Un ordre de feu reçu hors engagement est refusé et journalisé.

### Tout le reste est rejeté

Un `type` inconnu est refusé avec le message *« seuls SCRAMBLE et FEU sont
acceptés par un navire intercepteur »*.

Les champs `zone`, `secteur`, `classe`, `class`, `classification`, `categorie`,
`niveauAlerte`, `priorite`, `doctrine`, `regleEngagement`, `charlie`, `bravo`,
`alpha`, `romeo` sont **supprimés avant traitement**, et leur présence est
journalisée en AVERT. Ce n'est pas de la paranoïa : c'est le signe visible qu'un
couplage est en train de se réintroduire entre le sol et le bord, et il vaut
mieux le voir tout de suite dans le journal.

---

## 5. Géométrie de l'interception

### 5.1 Relèvements horaires

Convention interne, vérifiée par les tests :

| Relèvement | Position horaire | Signification |
|---|---|---|
| 0° | 12 h | droit devant la cible |
| 90° | 3 h | à tribord de la cible |
| **120°** | **4 h** | **borne droite de l'arc arrière** |
| 180° | 6 h | droit derrière la cible |
| **240°** | **8 h** | **borne gauche de l'arc arrière** |
| 270° | 9 h | à bâbord de la cible |

L'arc arrière demandé est donc l'intervalle **[120°, 240°]**, un cône de 120°
centré sur les 6 heures. `relèvement = atan2(−x, z)` coïncide avec le lacet
Minecraft (0 = sud/+Z, 90 = ouest/−X) : aucune conversion n'est nécessaire
entre une solution de tir et une commande d'affût.

### 5.2 Trajectoire prédictive, pas une poursuite

À chaque cycle, le navire résout analytiquement le temps de vol `t` tel que,
à sa vitesse propre `s`, il rejoigne une cible se déplaçant en ligne droite :

```
|P + V·t| = s·t     avec P = position cible − position navire, V = vitesse cible
⇔ (|V|² − s²)·t² + 2(P·V)·t + |P|² = 0
```

On retient la plus petite racine positive, bornée par
`predictionMiniSecondes` / `predictionMaxiSecondes`. Le point visé est
**l'arc arrière de la position prédite** à cet instant, jamais la position
actuelle de la cible. C'est toute la différence entre intercepter et traîner
derrière.

Si la cible est plus rapide et fuyante, aucune racine positive n'existe : le
journal l'annonce explicitement (*« CIBLE PLUS RAPIDE : interception non
garantie »*) et le navire vise la borne haute de prédiction.

### 5.3 Choix du relèvement : ne jamais passer devant le nez

- Le navire est **déjà dans l'arc** → il garde son côté.
- Le navire est **en dehors** → il rejoint la borne d'arc *angulairement* la
  plus proche (120° ou 240°), avec une marge. Il contourne donc la cible par le
  flanc au lieu de traverser son hémisphère avant.

### 5.4 Une fois en position : orbite ou zigzag

Le navire ne reste jamais statique derrière la cible.

- **`manoeuvre = "orbite"`** — balayage sinusoïdal du relèvement autour des
  6 heures, amplitude `arcAmplitudeDeg` (bornée pour ne jamais sortir de l'arc).
- **`manoeuvre = "zigzag"`** — même chose en onde triangulaire.

La distance de consigne oscille elle aussi, sur une période dans un **rapport
irrationnel** (nombre d'or) avec celle du relèvement : le motif ne se répète
pas, ce qui rend la trajectoire nettement moins prévisible qu'une orbite
régulière. L'altitude suit une troisième période.

À l'entrée dans l'arc, la phase est **calée sur le relèvement courant** : la
manœuvre démarre là où le navire se trouve, sans à-coup vers les 6 heures.

### 5.5 Vitesse asservie sur celle de la cible

| Régime | Condition | Commande |
|---|---|---|
| `transit` | écart de distance > `distanceTransit` | vitesse maximale |
| `securite` | distance < `distanceSecurite` | **sous** la vitesse cible, pour rouvrir l'écart |
| `asservi` | sinon | `vitesse cible + gain × erreur de distance` |

En régime asservi, la commande est bornée entre `ratioMini` et `ratioMaxi` fois
la vitesse de la cible : ni trop vite, ni trop lentement. Le régime `securite`
est le garde-fou anti-collision — il commande volontairement une vitesse
inférieure à celle de la cible.

---

## 6. Règle d'engagement : le tir prime sur la position

**Sous ordre de feu, la place dans l'arc arrière n'est plus un préalable.**
`interception.tirAutorise()` ne vérifie que ce qui rend le coup possible :
portée de l'arme retenue et qualité du pointage. Un navire qui a la cible dans
sa portée avec une solution valable **ouvre le feu**, même s'il est encore en
train de regagner son arc.

Conséquences concrètes :

- l'ordre `FEU` fait passer à l'engagement immédiatement, sans attendre d'être
  en position ;
- sortir de l'arc pendant le tir **n'interrompt pas** l'engagement : le fait est
  journalisé, le tir continue ;
- la trajectoire garde l'arc comme objectif, mais la correction latérale est
  **bornée à `biaisArcEnTirDeg`** (25° par défaut) par consigne. Une reprise
  d'arc franche casserait la solution de tir en cours ; le navire regagne donc
  sa place peu à peu, sans cesser de tirer ;
- la distance tenue devient **le centre de la fenêtre de portée de l'arme
  retenue**, et non plus la bande 300-400 blocs de l'arc.

Le comportement inverse reste disponible : `prioriteTirSurPosition = false`
rend l'arc bloquant pour le tir. Les deux règles sont testées.

## 7. Les quatre comportements de combat

1. **Orbite / zigzag avec vitesse adaptée** — §5.4 et §5.5. Active hors
   engagement ; sous ordre de feu, la trajectoire passe en mode tir (ci-dessus).
2. **Évasion prioritaire sur dégât** — §9. Elle prime sur tout, y compris sur
   un engagement en cours : le tir cesse immédiatement.
3. **Priorité à l'arc arrière plutôt qu'à la cible** — hors ordre de feu, le
   point de consigne est *toujours* une place dans l'arc, jamais la cible.
4. **Retour base sur destruction confirmée** — §10.

## 8. L'arsenal

Le navire porte une **liste d'armes**, pas une arme. Chacune déclare :

| Champ | Rôle |
|---|---|
| `identifiant`, `nom` | identité, reprise dans le journal à chaque tir |
| `utilite` | `anti-aerien`, `anti-sol`, `defensif` ou `polyvalent` |
| `mode` | `peripherique` (affût pilotable), `redstone`, ou `mixte` |
| `porteeMini`, `porteeMaxi` | fenêtre d'emploi en blocs |
| `vitesseObus`, `graviteObus` | balistique — **à mesurer sur votre serveur** |
| `dureeRafale`, `pauseRafale` | cadence |
| `tangageMini`, `tangageMaxi` | débattement de l'affût |
| `actif` | une arme non armée reste déclarée mais n'est jamais choisie |

**Choix de l'arme**, à chaque cycle d'engagement :

1. disponible et armée ;
2. utilité compatible — une arme polyvalente répond à tout, une spécialisée
   seulement à son besoin ;
3. distance dans sa fenêtre de portée ;
4. à égalité, celle dont la distance tombe le plus **au centre** de sa fenêtre
   — une arme employée au milieu de sa portée est plus précise qu'à son bord ;
5. à égalité encore, la spécialisée passe avant la polyvalente.

Le besoin (`anti-aerien` / `anti-sol`) est déduit **par le navire lui-même**, de
l'altitude de la cible par rapport au relief : aucune classification ne vient
du sol.

Une arme qui ne répond pas au démarrage est marquée indisponible et
journalisée, **sans compromettre les autres** : un navire à trois canons dont un
est cassé est un navire à deux canons, pas un navire au sol. Si *aucune* arme
n'est disponible, le démarrage échoue avec le décompte exact.

## 9. Critères de dégât — un seul jeu, deux usages

`interception.evaluerDegats()` est appelée **deux fois avec les mêmes seuils** :
sur la télémétrie du navire, et sur la piste radar de la cible. Aucune
divergence possible entre les deux usages.

Sur une fenêtre glissante de `fenetreSecondes` :

- **chute d'altitude** ≥ `chuteAltitudeBlocs` (défaut 25 blocs) ;
- **perte de vitesse** ≥ `perteVitesseRatio` (défaut 40 %) **et** ≥
  `perteVitesseMini` en valeur absolue (défaut 15 b/s) — la seconde condition
  évite qu'un mobile déjà lent ne déclenche une fausse alarme.

Une fenêtre plus courte que `dureeMiniSecondes` ne conclut jamais.

**Côté navire** : un dégât déclenche l'évasion, quel que soit l'état engagé.
La manœuvre est un **break** — rupture latérale de `angleBreakDeg`, alternée
gauche/droite à chaque évasion, plus une variation d'altitude (descente si le
navire est haut, montée s'il est bas, dans l'enveloppe de vol et au-dessus de
la garde au sol). Une fuite en ligne droite offrirait à l'adversaire une
solution de tir triviale. Passé `dureeSecondes`, le navire reprend sa position
d'attaque. Une période réfractaire (`refractaireSecondes`) évite d'enchaîner
les manœuvres sur un même encaissement.

**Côté cible** : un dégât seul **ne suffit pas** — un appareil touché peut se
rétablir. La destruction n'est confirmée qu'avec un dégât avéré **suivi** d'un
signe terminal :

- contact radar perdu depuis `perteContactSecondes`, **ou**
- altitude passée sous `altitudeSolConfirmee`, **ou**
- cible immobilisée (< `vitesseEpaveMaxi`) depuis `dureeEpaveSecondes`.

Une perte de contact **sans dégât préalable** n'est pas une destruction : c'est
une perte de piste. Le navire poursuit à l'estime pendant
`delaiRechercheSecondes`, puis rentre. Cette distinction est testée.

---

## 10. Retour base et réarmement

Destruction confirmée → `RETOUR_BASE`. L'itinéraire `retour.pointsRetour` est
**confié à l'autopilote** (`ap.suivreItineraire`) : c'est son système de points
de passage qui est utilisé, celui des missions de livraison. Le navire ne
réimplémente pas la navigation, il la délègue, et se contente d'observer son
aboutissement (`ap.estArrive()`). Le passage de chaque point est journalisé via
les rappels `surEtape` / `surArrivee` de la mission.

À l'arrivée, stationnaire, et dépôt du fichier
`intercepteur/.rearmement_requis`. **Tant que ce fichier existe, tout ordre de
scramble est refusé et journalisé.** Le réarmement est manuel : l'équipage
supprime le fichier — depuis la page Mission du système d'exploitation, ou à la
main — et le navire repasse en `VEILLE`.

Aucun lanceur ne supprime ce marqueur : un navire rentré à sec de munitions le
reste après un rechargement de chunk ou un redémarrage de serveur. C'est vérifié
par les tests.

## 11. Machine à états

```
        VEILLE ──────────── SCRAMBLE ──────────▶ TRANSIT
                                                    │
                                        arc arrière tenu
                                                    ▼
     TIR ◀────── ordre FEU ────── POSITION_ATTAQUE ─┤
      │                                  │          │
      └────────────┬─────────────────────┘     arc perdu
                   │                                │
              dégât subi                            └──▶ TRANSIT
                   ▼
                EVASION ──── manœuvre terminée ────▶ TRANSIT

  (depuis tout état engagé) destruction confirmée ──▶ RETOUR_BASE
                                base atteinte ──────▶ REARMEMENT
                          action de l'équipage ─────▶ VEILLE
```

L'évasion est **prioritaire** : elle interrompt le tir et prime sur la tenue de
position, avant de rendre la main à la poursuite.

Quatre boucles concurrentes (`parallel.waitForAny`) : liaison sol, pistage
radar, contrôle, surveillance. Un superviseur relance le cycle complet après
toute erreur, avec temporisation progressive, comme les balises GPS.

---

## 12. Journal

Format identique à celui des balises :

```
[horodatage] [NIVEAU] [etape: <nom>] message
```

Écrit dans `intercepteur/intercepteur.log` avec rotation, et à l'écran selon
`journalNiveauEcran`. **Le fichier enregistre toujours tout**, quel que soit le
niveau écran.

Étapes critiques tracées, toutes vérifiées par le banc d'essai :

| Événement demandé | Étape journalisée |
|---|---|
| Réception de l'ordre | `reception d'un ordre du sol` |
| Calcul de trajectoire d'interception | `calcul de trajectoire d'interception` |
| Entrée en position d'attaque | `entree en position d'attaque` |
| Tir | `tir sur la cible` |
| Détection de dégât | `detection de degat` |
| Manœuvre d'évasion | `manoeuvre d'evasion` |
| Retour base | `retour a la base` |

S'y ajoutent : liaison autopilote et correspondance d'API retenue, changement
de mode PID ↔ dead-band, pistage et perte de contact, sortie de l'arc avec le
motif exact, solution de tir détaillée (azimut, élévation, chute compensée),
confirmation de destruction avec son motif, passage de chaque point de retour,
attente de réarmement, et un battement de cœur périodique.

Les événements permanents (perte de contact, tir suspendu) sont journalisés au
plus une fois toutes les N secondes : à 4 Hz, sans cela, ils noieraient le reste.

Pour un vol de réglage, passer `journalNiveauEcran = "DEBUG"` : chaque calcul
d'interception est alors affiché, avec la position prédite, le temps avant
impact, la position horaire courante et le régime de vitesse.

---

## 13. Le système d'exploitation de bord

`systeme/os.lua` n'est pas un menu posé devant un programme.

- **Un noyau multitâche** (`systeme/noyau_taches.lua`) fait tourner côte à côte
  l'interface et le système d'interception, chacun dans sa fenêtre CC. Les
  événements de terminal (clavier, souris) ne vont qu'à la tâche au premier
  plan ; rednet, les minuteurs et les périphériques vont à **toutes** les
  tâches. L'équipage peut donc régler l'armement pendant que le navire poursuit
  sa cible, sans qu'un ordre du sol ne se perde. C'est testé.
- **Un amorçage** vérifie le matériel et les fichiers *avant* de lancer quoi que
  ce soit, et dit précisément ce qui manque. Un contrôle bloquant en échec
  laisse l'interface disponible pour corriger, mais ne lance pas l'interception.
- **Une tâche qui tombe ne noircit pas l'écran** : son erreur est conservée et
  lisible depuis la page Console.

### Les pages

| Page | Contenu |
|---|---|
| **1 État** | état du navire, mode de vol, mode de pilotage (PID / zone morte par axe), position, cible, distance, position horaire, temps avant impact, arme retenue, dégâts subis |
| **2 Mission** | dernier ordre reçu, rappel de l'indépendance vis-à-vis du sol, validation du réarmement (`R`) |
| **3 Armement** | **édition de l'arsenal** : ajouter (`A`), supprimer (`D`), armer/désarmer (`Espace`), basculer la règle d'engagement (`P`), enregistrer (`S`). Affiche la **couverture de portée** et signale les **trous** |
| **4 Autopilote** | module et réglage véhicule utilisés, vol en cours, modes par axe, consignes émises ; ouvre l'interface de réglage (`C`) |
| **5 Journal** | `intercepteur.log` filtrable par niveau, défilement |
| **6 Système** | version, tâches et leur état, périphériques, arrêt (`Q`), redémarrage (`B`) |
| **7 Console** | sortie brute du système d'interception, en plein écran |

### La page Armement

C'est elle qui déclare les armes, leur portée et leur utilité. Elle écrit
`intercepteur/config_armement.lua` — un fichier **séparé** de la configuration
principale, et régénéré en entier à chaque enregistrement, commentaires
compris.

Pourquoi séparé ? Parce qu'un programme qui réécrit un fichier rédigé à la main
finit toujours par en perdre les commentaires. L'arsenal, lui, appartient
entièrement à la page : il peut être régénéré sans rien perdre.
`config_intercepteur.lua` reste intact et fournit l'arsenal par défaut tant que
ce fichier n'existe pas ; le supprimer y revient.

Deux garde-fous avant écriture :

- **validation complète** — identifiant vide ou dupliqué, utilité inconnue,
  portées incohérentes, mise à feu redstone sans côté : refusé avec le motif ;
- **le fichier généré est rechargé avant d'être écrit**. S'il ne se charge pas,
  rien n'est remplacé.

### Couverture de portée

La page affiche la plage réellement couverte par les armes armées pour le
besoin courant, et signale les **trous**. C'est l'information qui manque le plus
souvent à l'équipage : savoir qu'à 250 blocs, aucune arme du bord ne répond.

## 14. Déploiement

**Ordinateur de bord** — un *advanced computer*, relié à : un modem Ender
(ordres du sol), un radar Create Radars, et un affût Create Big Cannons par
arme pilotée.

Installation en une commande (dépôt public requis) :

```
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/interceptor-ship-onboard-system-uca5no/installe.lua installe
installe intercepteur
```

L'installateur pose l'autopilote, le système d'interception et le système
d'exploitation, et **préserve les fichiers de configuration déjà réglés**.

Arborescence obtenue :

```
/startup.lua                            -> lance FrenchNet OS
/systeme/                               systeme d'exploitation
/intercepteur/                          systeme d'interception
/autopilote/autopilote.lua              module d'autopilote
/autopilote/config_vehicule.lua         LE reglage du vehicule
```

### Dans l'ordre, au premier montage

1. `interface` — régler le véhicule : gabarit, moteurs, gains PID, vitesses.
   C'est le réglage qui conditionne tout le reste ; un intercepteur avec les
   gains d'un cargo ne volera pas.
2. `cablage` — vérifier le câblage moteur et piloter à la main.
3. `systeme/os` puis page **Armement** — déclarer les armes, leurs portées et
   leurs utilités. Vérifier qu'il n'y a **pas de trou de portée**.
4. `edit intercepteur/config_intercepteur.lua` — `identifiant` unique et
   `retour.pointsRetour` (le dernier point est la base).

### Avant le premier vol armé

Les seuils du bloc `degats` et la balistique de chaque arme sont des **valeurs
de départ plausibles, pas des mesures**. Faites un vol d'essai avec
`journalNiveauEcran = "DEBUG"` et relevez dans le journal :

- la vraie signature d'un encaissement (chute d'altitude, perte de vitesse) →
  `degats.chuteAltitudeBlocs`, `degats.perteVitesseRatio`,
  `degats.perteVitesseMini` ;
- la vitesse initiale réelle de vos obus, qui dépend de la charge propulsive et
  du calibre → `vitesseObus` et `graviteObus` de chaque arme.

Tant que ces valeurs ne sont pas les vôtres, le navire peut déclencher des
évasions sur du bruit, ou manquer des dégâts réels.
