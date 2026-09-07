# Système embarqué du navire intercepteur de scramble

Serveur **AERONAUTICS WARFARE** — Create Aeronautics, Create Radars,
Create Big Cannons, CC: Tweaked.

Ce système vit **à bord** du navire. Il est indépendant du système de défense
au sol : il ne connaît ni les zones, ni les classes Charlie, Bravo, Alpha ou
Roméo. Il reçoit deux ordres, un point c'est tout.

---

## 1. À lire avant toute chose : ce qui manque dans ce dépôt

Trois éléments référencés par le cahier des charges **n'existent pas dans ce
dépôt** au moment où ce système a été écrit :

| Élément attendu | État réel |
|---|---|
| Module d'autopilote standardisé (sections 6 et 7) | **Absent.** Les sections 6 et 7 de `docs/guide-complet.md` traitent de la vérification des balises GPS et de leur journalisation. |
| Critères de dégât pour la confirmation de destruction | **Absents.** Aucune définition nulle part. |
| Système de points de retour de la livraison | **Absent.** |

Conséquences, assumées explicitement :

1. **L'autopilote est appelé, jamais réécrit.** `intercepteur/autopilote.lua`
   est un *adaptateur* : il charge votre module depuis le disque, normalise son
   API et lui transmet la configuration. Aucune loi de vol n'est écrite ici.
   Si le module est introuvable, **le navire refuse de décoller** — voler avec
   un contrôleur de substitution serait plus dangereux que de rester au sol.
2. **Les critères de dégât sont définis dans la configuration**, en un seul
   endroit, et servent aux deux usages demandés (survie du navire *et*
   confirmation de destruction de la cible). Ce sont des valeurs de départ
   plausibles, **pas des mesures faites sur votre serveur**.
3. **Les points de retour sont une liste configurable** dans le même fichier.

Quand vos vrais modules arriveront, seul le fichier de configuration change.

---

## 2. Contenu

```
intercepteur/
  intercepteur.lua           programme principal : machine à états + superviseur
  config_intercepteur.lua    CONFIGURATION PAR VÉHICULE (partagée avec l'autopilote)
  noyau.lua                  journal, étapes, exécution protégée, vecteurs, relèvements
  interception.lua           mathématiques pures : prédiction, arc arrière, dégâts, tir
  autopilote.lua             ADAPTATEUR vers le module d'autopilote standardisé
  radar.lua                  radar embarqué (Create Radars) et pistage
  armement.lua               affût (Create Big Cannons) et cadence de tir
  liaison.lua                réception des ordres du sol (SCRAMBLE et FEU uniquement)
  startup.lua                lanceur automatique
tests/
  test_interception.lua      87 vérifications, maths pures, sans CraftOS
  test_intercepteur.lua      86 vérifications, mission complète simulée
  banc_autopilote.lua        faux autopilote de banc d'essai
```

Lancer les tests, depuis la racine du dépôt :

```
lua5.4 tests/test_interception.lua    # 87/87
lua5.4 tests/test_intercepteur.lua    # 86/86
lua5.4 tests/test_balise.lua          # 49/49 (non-régression du réseau GPS)
```

---

## 3. Contrat d'interface avec l'autopilote

L'adaptateur cherche le module dans cet ordre : `cheminAutopilote` de la
configuration, puis `/autopilote/autopilote.lua`, `/autopilote/api.lua`,
`/autopilote.lua`, `intercepteur/autopilote_vehicule.lua`, `/lib/autopilote.lua`.

Le module doit renvoyer une table. Pour chaque capacité, plusieurs noms de
fonction sont acceptés ; le nom réellement retenu est **journalisé au
démarrage**, ce qui permet de savoir exactement quelle fonction a été appelée
en cas de comportement de vol anormal.

| Capacité | Obligatoire | Noms acceptés |
|---|---|---|
| Initialisation | non | `demarrer`, `initialiser`, `init`, `start`, `begin` |
| Point de consigne | **oui** | `definirPoint`, `definirConsigne`, `allerA`, `viser`, `setTarget`, `setSetpoint`, `goTo`, `definirCible` |
| Vitesse à tenir | non | `definirVitesse`, `reglerVitesse`, `setSpeed`, `setVitesse`, `definirVitesseCible` |
| Cap imposé | non | `definirCap`, `reglerCap`, `setYaw`, `setHeading`, `definirLacet` |
| Position courante | **oui** | `position`, `obtenirPosition`, `getPosition`, `getPos`, `pos` |
| Vecteur vitesse | non | `vitesse`, `obtenirVitesse`, `getVelocity`, `getVitesse`, `vel` |
| Mode actif (PID / dead-band) | non | `mode`, `obtenirMode`, `getMode`, `modeActif` |
| Maintien sur place | non | `stationnaire`, `maintenir`, `hold`, `station`, `faireDuSurPlace` |
| Arrêt propre | non | `arreter`, `stopper`, `stop`, `halt`, `couper` |
| Cycle de calcul | non | `actualiser`, `cycle`, `tick`, `update`, `pas` |

Les accesseurs de position et de vitesse peuvent renvoyer trois nombres,
une table `{x, y, z}` ou une table `{[1], [2], [3]}` : les trois formes sont
acceptées.

Un nom qui manque à la liste s'ajoute dans `M.CONTRAT`, en tête de
`intercepteur/autopilote.lua`. Aucune autre ligne du système n'est à toucher.

**Ce que le système d'interception envoie à l'autopilote, et rien d'autre :**
un point de consigne, une vitesse, parfois un cap. L'asservissement en cascade,
le PID en contrôle principal et le repli automatique en dead-band restent
entièrement de son ressort. Le basculement de mode est simplement **tracé** dans
le journal (étape `changement de mode de l'autopilote`) : c'est un signal
précieux pour expliquer après coup une trajectoire dégradée.

**Fichier de configuration unique par véhicule :** le bloc `autopilote = { … }`
de `config_intercepteur.lua` est transmis tel quel au module, à la fois en
argument de chunk et via `demarrer()`. Si votre autopilote lit déjà son propre
fichier, laissez ce bloc vide — il sera ignoré.

---

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

## 6. Les quatre comportements de combat

1. **Orbite / zigzag avec vitesse adaptée** — §5.4 et §5.5.
2. **Évasion prioritaire sur dégât** — §7.
3. **Priorité à l'arc arrière plutôt qu'à la cible** — le point de consigne est
   *toujours* une place dans l'arc, jamais la cible elle-même. Si le navire sort
   de l'arc, il repasse en `TRANSIT` pour le reprendre, et le tir cesse
   immédiatement, ordre de feu ou non : `interception.tirAutorise()` refuse tout
   tir hors arc.
4. **Retour base sur destruction confirmée** — §8.

---

## 7. Critères de dégât — un seul jeu, deux usages

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

## 8. Retour base et réarmement

Destruction confirmée → `RETOUR_BASE`. Le navire suit `retour.pointsRetour`
**dans l'ordre**, le dernier point étant la base, à `vitesseRetour` et — sauf
pour le dernier point — à `altitudeCroisiere`.

À l'arrivée, il se met en stationnaire et dépose le fichier
`intercepteur/.rearmement_requis`. **Tant que ce fichier existe, tout ordre de
scramble est refusé et journalisé.** Le réarmement est une action manuelle :
l'équipage supprime le fichier, le navire repasse en `VEILLE`.

Le lanceur `startup.lua` ne supprime **jamais** ce marqueur : un navire rentré
à sec de munitions le reste après un rechargement de chunk ou un redémarrage de
serveur.

---

## 9. Machine à états

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

## 10. Journal

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

## 11. Déploiement

**Ordinateur de bord** — un *advanced computer*, accolé ou relié par modem
filaire à : un modem Ender (ordres du sol), un radar Create Radars, un affût
Create Big Cannons.

```
/startup.lua                            <- intercepteur/startup.lua
/intercepteur/intercepteur.lua
/intercepteur/config_intercepteur.lua   <- À ÉDITER
/intercepteur/noyau.lua
/intercepteur/interception.lua
/intercepteur/autopilote.lua
/intercepteur/radar.lua
/intercepteur/armement.lua
/intercepteur/liaison.lua
/autopilote/autopilote.lua              <- VOTRE module standardisé
```

À éditer impérativement dans `config_intercepteur.lua` :

1. `identifiant` — unique par navire ;
2. `cheminAutopilote` — où se trouve votre module ;
3. `retour.pointsRetour` — au moins un point, le dernier étant la base ;
4. `arme.mode` et `arme.coteRedstone` si l'arme est déclenchée par signal.

### Avant le premier vol armé

Les seuils du bloc `degats` et la balistique du bloc `arme` sont des **valeurs
de départ plausibles, pas des mesures**. Faites un vol d'essai en
`journalNiveauEcran = "DEBUG"`, relevez dans le journal :

- la vraie signature d'un encaissement (chute d'altitude, perte de vitesse) →
  `degats.chuteAltitudeBlocs`, `degats.perteVitesseRatio`,
  `degats.perteVitesseMini` ;
- la vitesse initiale réelle de votre obus, qui dépend de la charge propulsive
  et du calibre → `arme.vitesseObus`, `arme.graviteObus`.

Tant que ces valeurs ne sont pas les vôtres, le navire peut déclencher des
évasions sur du bruit, ou manquer des dégâts réels.
