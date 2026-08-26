# FrenchNet — Module d'autopilote (CC: Tweaked)

Bibliothèque de pilotage autonome pour les véhicules aériens du serveur **AERONAUTICS WARFARE** (Create Aeronautics, NeoForge 1.21.1). Elle s'installe telle quelle sur n'importe quel véhicule — dirigeable de livraison, intercepteur de scramble, navire armé — et s'appuie sur le [réseau de balises GPS FrenchNet](guide-complet.md).

> Ce n'est **pas un programme final**. `autopilote.lua` ne fait rien au chargement : il renvoie une table de fonctions. Ce sont les programmes de mission qui lui donnent une cible, et il se charge seul d'y amener le véhicule.

---

## 1. Interface publique

```lua
local autopilote = dofile("/autopilote/autopilote.lua")
local ap = autopilote.nouveau()      -- lit /autopilote/config_vehicule.lua

ap.initialiser()                     -- relit la position AVANT tout mouvement
parallel.waitForAny(ap.executer, mission)   -- la boucle de vol
```

| Appel | Rôle |
|---|---|
| `ap.allerA(point, options)` | Rejoindre un point |
| `ap.suivreItineraire(points, options)` | Enchaîner une liste de points de passage |
| `ap.maintenirPosition(point, cap)` | Tenir une position (point courant si omis) |
| `ap.arreter(motif)` | Neutraliser les commandes, annuler la mission |
| `ap.etat()` | Instantané complet (mode, position, vitesse, écarts, commandes…) |
| `ap.estArrive()` | Vrai une fois la cible atteinte et tenue |
| `ap.attendreArrivee(délai)` | Bloquant, dans une tâche parallèle |
| `ap.surEvenement(fn)` | Rappel sur chaque événement |
| `ap.definirMode("auto"\|"pid"\|"zone_morte")` | Forcer un mode de pilotage |
| `ap.reglerGains(axe, jeu, gains)` | Réglage à chaud |
| `ap.sauvegarderConfig()` | Écrire la configuration du véhicule |
| `ap.historique(axe)` | Historique glissant d'un axe |
| `ap.ravitaillement()` | Station de ravitaillement (verrouillée) |
| `ap.rejoindreRavitaillement()` | Route vers la station, en atterrissage |
| `ap.pas()` | Un seul cycle, pour qui gère sa propre boucle |

**Un point de passage :**

```lua
{ x = 1980, y = 118, z = -3100,
  type = "survol" | "depot" | "atterrissage",   -- défaut : survol
  cap  = 90,        -- cap à tenir en finale (degrés, optionnel)
  arret = true,     -- s'immobiliser à cette étape (défaut : passage au vol)
  nom  = "ENTREPOT-3" }
```

**Options de mission :** `vitesseMax`, `altitudeCroisiere`, `transitHaute = false` (vol direct), `surEtape(index, point)`, `surArrivee(point)`.

**Événements** — rappel `ap.surEvenement(fn)` *et* événement CC `os.pullEvent("autopilote")` :
`mission`, `phase`, `etape`, `arrivee`, `maintien`, `mode`, `anomalie`, `acquisition`, `arret`.

---

## 2. Installation

Sur chaque véhicule (1 ordinateur + 1 modem Ender pour le GPS) :

```
mkdir autopilote
wget <dépôt>/autopilote/autopilote.lua       autopilote/autopilote.lua
wget <dépôt>/autopilote/config_vehicule.lua  autopilote/config_vehicule.lua
wget <dépôt>/autopilote/ravitaillement.lua   autopilote/ravitaillement.lua
wget <dépôt>/autopilote/interface.lua        autopilote/interface.lua
wget <dépôt>/autopilote/startup.lua          startup.lua
interface                                    -- régler le véhicule à l'écran
reboot
```

| Fichier | Rôle |
|---|---|
| `autopilote/autopilote.lua` | La bibliothèque. Ne se modifie pas. |
| `autopilote/config_vehicule.lua` | **Un par véhicule.** Toutes les valeurs de vol. |
| `autopilote/ravitaillement.lua` | Constante de réseau **verrouillée**, identique partout. |
| `autopilote/interface.lua` | Interface visuelle : configuration + réglage en vol. |
| `autopilote/startup.lua` | Lanceur automatique (à la racine : `/startup.lua`). |
| `autopilote/mission.lua` | *Optionnel* : le programme de mission du véhicule. |
| `autopilote/exemple_mission.lua` | Trois missions types, à copier en `mission.lua`. |

Sans `mission.lua`, le lanceur met l'autopilote **en veille** : il relit sa position, reprend une mission interrompue par un plantage, et tient sa position en attendant un ordre.

---

## 3. Configuration

Aucune valeur de vol n'est écrite en dur dans le code. Si une valeur obligatoire manque, l'autopilote **refuse de démarrer** et nomme la clé fautive :

```
configuration vehicule invalide -> 'vitesses.croisiere' manquant ou non numerique
```

Deux façons de la modifier : `edit autopilote/config_vehicule.lua`, ou l'interface visuelle (`interface`), qui réécrit le fichier en conservant ses sections et ses commentaires.

### Repère des décalages

Avec `decalageDansRepereVehicule = true` (cas normal), les décalages sont exprimés **dans le repère du véhicule** et tournés selon le cap courant avant d'être appliqués :

```
x = vers TRIBORD (droite, nez en avant)      y = vers le HAUT      z = vers l'AVANT (nez)
```

- `decalageGps` — position de l'**ordinateur** par rapport au centre du véhicule. Le pilotage raisonne toujours sur le **centre réel**, jamais sur la position de l'ordinateur.
- `decalageDepot` — position du point de dépôt / des patins par rapport au centre. Sur un point `type = "depot"` ou `"atterrissage"`, c'est **ce point-là** qui tombe sur la cible.

`decalageDansRepereVehicule = false` : les décalages sont en X/Y/Z monde (véhicule qui ne tourne jamais).

### Convention de cap

Relevé compas : **0 = nord (−Z), 90 = est (+X), 180 = sud (+Z), 270 = ouest (−X)**. C'est la convention de la boussole du jeu. Un capteur qui renvoie le *yaw* Minecraft est converti automatiquement (`cap.convention = "minecraft"`).

### Station de ravitaillement

Elle vit dans `ravitaillement.lua`, **pas** dans la configuration du véhicule : c'est une constante de réseau, identique sur tous les véhicules. L'interface l'affiche mais refuse de la modifier ; un véhicule qui déclarerait la sienne verrait sa valeur **ignorée**, et l'anomalie journalisée.

---

## 4. Chaîne de mesure

À chaque cycle (`gps.intervalle`, 0,4 s par défaut) :

```
gps.locate  ->  rejet des aberrations  ->  décalage GPS  ->  filtrage
            ->  vitesse (positions lissées successives)  ->  cap  ->  guidage
```

- **Pas de temps réel.** Le module ne suppose jamais un pas constant : il mesure le temps réellement écoulé entre deux lectures. Un cycle rallongé par une lenteur serveur ne fausse ni l'intégrale, ni la dérivée, ni les filtres.
- **Horloge.** `gps.sourceHorloge = "ticks"` (défaut) utilise `os.clock()`, qui avance au rythme des ticks du serveur — c'est-à-dire au rythme de la physique du jeu. Un asservissement réglé en secondes de tick reste donc valable quel que soit le TPS. L'horloge murale (`os.epoch`) sert en parallèle à **détecter** un ralentissement serveur, qui est journalisé. `"reel"` bascule le pilotage sur l'horloge murale.
- **Rejet d'aberration.** Une lecture qui impliquerait plus de `gps.vitesseMaxPlausible` blocs/s est ignorée. Trois rejets d'affilée signifient au contraire un vrai saut (téléportation, rechargement de chunk) : la position est alors acceptée et **tous les régulateurs sont réinitialisés**.
- **Filtrage.** `passe_bas` (constante de temps, recalculée à chaque cycle depuis le dt réel) ou `moyenne` (fenêtre glissante). La vitesse est déduite de deux positions **lissées** successives, puis lissée à son tour.
- **Discontinuité.** Un `dt` supérieur à `gps.dtMax` (chunk rechargé, serveur figé) est signalé, borné, et remet à zéro filtres et régulateurs.

### Le cap, avec ou sans capteur

| `cap.source` | Fonctionnement |
|---|---|
| `"route"` (défaut) | Cap déduit de la route réellement suivie. Aucun matériel requis. |
| `"peripherique"` | Cap lu sur un lecteur de vaisseau / gyroscope. |

Sans capteur, un véhicule **immobile ne sait pas où pointe son nez**. Le module le gère explicitement :

- en dessous de `cap.vitesseMinRoute`, le cap n'est plus mesuré ; au-delà de `cap.dureeCapValide` sans mesure, il est déclaré **non fiable** ;
- cap non fiable → la commande de lacet est **neutralisée** (on ne tourne pas au hasard) et le véhicule avance **au pas** (`vitesses.acquisitionCap`) juste assez pour rendre la route observable ; le cap se réacquiert seul, puis le guidage normal reprend ;
- la vitesse de lacet n'est jamais dérivée de deux mesures non comparables — sans quoi le passage « cap figé → cap de route » produirait un pic de plusieurs centaines de degrés par seconde.

> **Propulsion latérale et cap déduit ne vont pas ensemble.** Une poussée latérale fait dériver la route par rapport au nez : le cap estimé devient faux. Le module l'avertit au démarrage. Pour un véhicule qui translate, installez un capteur de cap.

---

## 5. Asservissement en cascade

Un PID unique sur la position dépasse la cible puis revient. Le module utilise **deux étages** :

```
      distance restante                vitesse cible              commande moteur
  ------------------------>  BOUCLE  ------------------------>  BOUCLE  ---------->
                            EXTERNE   (proportionnelle à la     INTERNE   (PID)
                          (position)   distance, plafonnée)    (vitesse)
```

La boucle externe est une simple pente (`gains.<axe>.position.kp`) plafonnée par les vitesses configurées : loin de la cible elle sature à la vitesse de croisière, près de la cible elle décroît. **C'est ce qui fait ralentir progressivement le véhicule au lieu de le dépasser.**

La cascade est appliquée séparément sur **quatre axes** :

| Axe | Erreur de position | Vitesse régulée | Commande |
|---|---|---|---|
| `altitude` | écart d'altitude | vitesse verticale | poussée verticale |
| `cap` | écart de cap (±180°) | vitesse de lacet | lacet |
| `avance` | distance restante **projetée sur la route** | vitesse d'avance | poussée avant |
| `derive` | écart latéral à la route prévue | vitesse latérale | poussée latérale |

**Repère de route et repère véhicule.** L'écart latéral est mesuré perpendiculairement au segment `départ → cible`. Le vecteur vitesse désiré est construit dans le repère de la route, puis **projeté dans le repère du véhicule** — car c'est là que poussent les moteurs. Un véhicule dont le nez n'est pas aligné sur la route voit sa vitesse d'avance réduite par un facteur en cosinus : on n'accélère pas dans la mauvaise direction.

**Écart de cap.** Calculé par `atan2`, puis systématiquement ramené dans `]−180°, +180°]` : le véhicule tourne toujours du côté le plus court et ne part jamais en tête-à-queue en franchissant la discontinuité.

**Correction de dérive par le cap** (`pilotage.correctionDeriveParCap`) : le cap visé est biaisé vers la route, ce qui permet aux véhicules sans propulsion latérale de revenir sur leur trajectoire en tournant.

---

## 6. Des PID robustes, pas théoriques

Quatre protections, vérifiées par le banc d'essai :

1. **Intégrale bornée et gelée.** Le terme intégral est plafonné (`integraleMax`), et son accumulation est **suspendue** quand la commande est déjà saturée et que l'erreur pousse encore dans le même sens. Pas d'emballement de l'intégrateur pendant une saturation prolongée, et retour immédiat en sortie de saturation.
2. **Dérivée sur la mesure.** Le terme dérivé est calculé sur la mesure, jamais sur l'erreur : un changement de consigne ne provoque plus l'à-coup violent du PID naïf. Il est lui-même lissé (`filtreDerivee`).
3. **Limitation de pente.** La commande ne peut pas varier de plus de `penteMax` par seconde : les moteurs ne reçoivent jamais de saut brutal.
4. **Temps réel.** Tous les termes sont calculés sur le `dt` mesuré.

Deux contraintes physiques sont déduites de la configuration :

- si `vitesses.marcheArriere = 0`, la commande d'avance ne peut pas être négative (le véhicule n'a pas de poussée arrière) — et une vitesse cible nulle coupe franchement la poussée, puisque pousser vers l'avant ne pourrait qu'aggraver la dérive ;
- en maintien de position, une fois **dans les marges**, la poussée horizontale est coupée (`maintien.arretDansMarges`) : sans cela, un intégrateur résiduel finit par repousser le véhicule hors de sa propre cible, qui repart pour un tour.

---

## 7. Repli en zone morte

Si un axe PID devient instable, il bascule seul en **commande si/sinon** :

```
si l'écart dépasse le seuil haut   -> corriger dans un sens
si l'écart dépasse le seuil bas    -> corriger dans l'autre
sinon                              -> ne rien changer
```

- **Détection automatique** — `pilotage.detection` : erreur qui change de signe plusieurs fois dans une courte fenêtre, ou dépassements répétés de la consigne. Les oscillations *sous* la tolérance de l'axe ne comptent pas : un véhicule stable n'est jamais déclaré fou.
- **Hystérésis** — la correction s'engage au-delà de `tolérance + hystérésis` et ne s'arrête qu'en dessous de `tolérance − hystérésis`. Pas de yo-yo sur la limite.
- **Journalisation** — chaque bascule est écrite avec son motif (`5 changements de signe en 5.0s`) et signalée au programme appelant (événement `mode`).
- **Retour automatique** au PID après `dureeAvantRetour` secondes de calme (désactivable).
- **Forçage manuel** — `ap.definirMode("pid" | "zone_morte" | "auto")`, ou les touches `P` / `Z` / `A` du menu de réglage en vol. Le forçage s'applique immédiatement à tous les axes.

---

## 8. Arrivée, maintien, dépôt

- **Arrivée.** Le véhicule est déclaré arrivé seulement s'il reste dans **toutes** ses marges (horizontale, altitude, et cap si un cap final est demandé) pendant `tolerances.dureeArrivee` secondes **continues**. Une sortie des marges remet le compteur à zéro. Une lecture isolée ne vaut jamais arrivée.
- **Maintien.** Une fois arrivé, l'autopilote passe seul en maintien de position, avec le **jeu de gains `maintien`** (plus serrés) et des vitesses réduites (`maintien.facteurVitesse`), jusqu'au prochain ordre. Il corrige en permanence la dérive.
- **Cap en maintien** (`maintien.cap`) : `auto` conserve le cap d'arrivée tant que le véhicule peut vraiment corriger sans tourner (propulsion latérale, cible pas derrière lui) et pointe le nez vers la cible sinon ; `conserver`, `vers_cible`, ou une valeur en degrés forcent le comportement.
- **Dépôt et atterrissage.** Sur un point `type = "depot"` ou `"atterrissage"`, le décalage correspondant est appliqué **à chaque cycle** (il dépend du cap courant) : le point de contact réel tombe sur la cible, pas le centre géométrique.

---

## 9. Navigation par points de passage

```
MONTEE  ->  CROISIERE  ->  APPROCHE  ->  FINALE
```

1. **MONTEE** — montée à `vitesses.altitudeCroisiere` avant de transiter. La vitesse horizontale est plafonnée par `vitesses.avanceEnMontee` (0 = montée purement verticale). Sautée si la mission est plus courte que `vitesses.distanceMinCroisiere`, ou si `transitHaute = false`.
2. **CROISIERE** — transit à l'altitude de sécurité, qui sert de **plancher** pendant tout le trajet (`mission.respecterAltitudeCroisiere`). Un point de passage plus haut est respecté ; on ne redescend jamais avant l'approche.
3. **APPROCHE / FINALE** — sous `vitesses.distanceApproche`, la vitesse tombe à `vitesses.approche` et la descente sur l'altitude réelle du point final commence.

Les points intermédiaires sont validés **au passage** (`vitesses.rayonValidationEtape`), sans immobilisation — sauf si le point porte `arret = true`, auquel cas les critères d'arrivée complets s'appliquent. Chaque étape franchie est signalée au programme appelant.

---

## 10. Interface visuelle

```
interface            -- configuration du véhicule (au sol, sans GPS)
interface vol        -- autopilote en maintien + menu de réglage en vol
interface journal    -- consultation du journal
```

**Écran de configuration** — barre de titre, panneau de sections à gauche, champs à droite, aide contextuelle et barre d'état. Clavier (flèches, `Tab`, `Entrée`, `S` sauvegarder, `J` journal, `Q` quitter) **et souris** sur les ordinateurs avancés. La saisie remplace la valeur à la première frappe. Une configuration invalide n'est pas enregistrée sans confirmation, et l'anomalie est affichée en clair. La section *Ravitaillement* est marquée d'un cadenas : consultable, non modifiable.

**Menu de réglage en vol** — affiche en temps réel, pour l'axe choisi : **erreur courante, vitesse cible, vitesse réelle, commande envoyée**, état de saturation, mode de l'axe, et **l'historique des dernières secondes tracé à l'écran** (erreur et commande). On voit immédiatement si le réglage oscille — dents de scie serrées — ou s'il traîne — pente molle qui n'atteint jamais zéro.

| Touche | Effet |
|---|---|
| `Tab` / `←` `→` | Changer d'axe (altitude, cap, avance, dérive) |
| `↑` `↓` | Choisir le gain (kp, ki, kd) |
| `+` `−` | Ajuster le gain du pas courant |
| `[` `]` | Diviser / multiplier le pas par 10 |
| `J` | Basculer entre le jeu `croisiere` et le jeu `maintien` |
| `P` / `Z` / `A` | Forcer PID / zone morte / automatique |
| `F2` | **Enregistrer les gains trouvés dans la configuration du véhicule** |
| `Q` | Quitter |

Le menu s'intègre à n'importe quelle mission :

```lua
local interface = dofile("/autopilote/interface.lua")
parallel.waitForAny(ap.executer, function() interface.reglageEnVol(ap) end)
```

---

## 11. Pannes et robustesse

| Panne | Comportement |
|---|---|
| **Perte du signal GPS** | Navigation à l'estime sur la dernière vitesse connue pendant `gps.perteToleree` secondes, puis **mode SECOURS** : commandes neutralisées, anomalie signalée et journalisée. Le véhicule ne navigue jamais à l'aveugle. |
| **Retour du GPS** | Sortie du mode secours, régulateurs réinitialisés, mission reprise (`mission.reprendreApresPerteGps`) ou maintien de position. |
| **Erreur dans un cycle** | Capturée, journalisée, commandes neutralisées, boucle relancée. Cinq erreurs d'affilée basculent en mode secours. |
| **Plantage / reboot / chunk rechargé** | `startup.lua` relance le véhicule. L'autopilote **relit sa position avant le moindre mouvement** (`gps.lecturesAcquisition` lectures valides) puis reprend la mission sauvegardée (`mission.reprendreApresRedemarrage`). |
| **Serveur qui ralentit** | Détecté par comparaison horloge de tick / horloge murale, journalisé. Les calculs restent justes : ils utilisent le temps réellement écoulé. |
| **Lecture GPS aberrante** | Ignorée, journalisée ; un vrai saut de position est reconnu au bout de trois lectures et remet les régulateurs à zéro. |
| **Ctrl+T** | Arrêt propre : commandes neutralisées, marqueur déposé, pas de redémarrage automatique. |

---

## 12. Journal

Même format que le reste de FrenchNet :

```
[2026-08-26 14:12:03] [AVERT] [AER-CARGO-01] [etape: bascule PID / zone morte] axe altitude : bascule en mode ZONE MORTE (5 changements de signe en 5.0s) - bascule n1
```

Chaque étape critique porte un nom repris tel quel dans le journal :

| Étape | Ce qu'elle trace |
|---|---|
| `lecture GPS` | Lecture, rejet d'aberration, pas de temps anormal, ralentissement serveur |
| `filtrage de la position` | Lissage et réinitialisations |
| `estimation du cap` | Source du cap, perte et réacquisition |
| `boucle externe de position` | Distance restante, écart latéral, cap visé, vitesses cibles |
| `boucle interne de vitesse` | Les quatre commandes moteur |
| `saturation de commande` | Entrées et sorties de saturation |
| `bascule PID / zone morte` | Chaque bascule et son motif |
| `navigation par points de passage` | Changements de phase |
| `point de passage franchi` | Étapes validées |
| `arrivee sur la cible` | Arrivée et écarts finaux |
| `maintien de position` | Dérive résiduelle |
| `perte du signal GPS` / `mode secours` | Anomalies |
| `boucle principale de vol` | Erreurs de cycle et relances |

`journal.periodeCycles` limite les traces de cycle à 1 sur N (le journal reste lisible) ; les transitions, saturations et anomalies sont **toujours** écrites. `journal.niveauEcran` ne filtre que l'écran : le fichier reçoit tout.

---

## 13. Méthode de réglage

Sur un véhicule neuf, dans l'ordre :

1. **Géométrie d'abord.** Relevez `decalageGps` et `decalageDepot` à la main (F3, ligne *Block*). Un décalage faux se voit tout de suite : le véhicule se stabilise systématiquement à côté.
2. **Vitesses ensuite.** `croisiere`, `verticaleMax`, `tauxVirageMax` doivent correspondre à ce que le véhicule sait réellement faire. Trop optimistes, tous les PID satureront en permanence.
3. **Boucle externe** (`position.kp`). Elle fixe la distance de freinage : la vitesse maximale est atteinte à `vitesseMax / kp` blocs de la cible. `kp = 0,35` avec 8 blocs/s ⇒ freinage amorcé à 23 blocs.
4. **Boucle interne**, axe par axe, avec le menu de réglage en vol :
   - monter `kp` jusqu'à ce que la réponse devienne vive, puis redescendre d'un tiers dès que la courbe d'erreur montre des dents de scie ;
   - ajouter `kd` pour amortir le dépassement ;
   - ajouter `ki` en dernier, faiblement, uniquement si une erreur résiduelle persiste (courbe qui traîne à côté de zéro).
5. **`F2` pour enregistrer**, puis refaire un vol complet pour vérifier.

Ordre de grandeur : la commande vaut 1 à pleine poussée. Si 0,2 de commande donne 2 blocs/s, alors `kp ≈ 0,1` par bloc/s d'erreur est un point de départ raisonnable pour la boucle interne d'avance.

---

## 14. Limites connues

- **Sans capteur de cap**, un véhicule immobile ne connaît pas son orientation. Le module le gère (lacet neutralisé, reptation d'acquisition), mais le maintien de position reste plus grossier qu'avec un capteur : comptez le double de tolérance. Pour du vol de précision — dépôt serré, appontage — installez un lecteur de cap et renseignez `cap.source = "peripherique"`.
- **La propulsion latérale exige un capteur de cap** (voir §4).
- Le module ne connaît **pas les obstacles**. L'altitude de croisière est une sécurité, pas un évitement : choisissez-la au-dessus du relief de la zone d'opération.
- Les commandes sont normalisées dans `[−1, +1]` ; c'est le câblage décrit dans `sorties` qui les traduit en redstone ou en appels de périphérique. Un programme peut aussi injecter son propre pilote de sorties (`options.commandes`).

---

## 15. Tests

Le dépôt contient un banc d'essai en **boucle fermée** (`tests/banc_vol.lua`) : mini-CraftOS (événements, minuteurs, `fs`, `term` à tampon, `gps`, `redstone`, clavier) plus un simulateur de véhicule aérien. Les commandes calculées par le module pilotent réellement un modèle physique, dont la position lui est renvoyée par un GPS simulé — avec bruit et décalage.

```
lua5.4 tests/test_autopilote.lua
```

151 vérifications : PID (dérivée sur la mesure, anti-emballement, limitation de pente), angles et décalages, filtres, zone morte, détecteur d'instabilité, configuration refusée, vol nominal et décélération en cascade, itinéraire et altitude de croisière, dépôt, durée d'arrivée continue, maintien et rattrapage de dérive, perte GPS, repli automatique et forçage, sorties redstone, sauvegarde de configuration, reprise après plantage, survie à une erreur de cycle, pas de temps variable, vol avec capteur de cap, interface de configuration et menu de réglage en vol.
