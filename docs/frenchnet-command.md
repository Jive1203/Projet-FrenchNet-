# FrenchNet Command — Défense aérienne autonome (CC: Tweaked)

Système de défense aérienne installé au sol pour le serveur **AERONAUTICS WARFARE**
(NeoForge 1.21.1 — Create Aeronautics, Create Radars, Create Big Cannons,
Open Parties and Claims, CC: Tweaked).

**Command décide. Il ne tire pas.** Il détecte, classe, identifie ami-ennemi,
choisit un palier d'escalade, désigne la plateforme qui doit réagir, et transmet
sa décision à **FrenchNet Fire Control**, qui reste seul responsable du tir.

---

## 1. Contenu

| Fichier | Rôle | Où l'installer |
|---|---|---|
| `command/command.lua` | Programme principal (radar, décision, réseau, supervision) | `/command/command.lua` |
| `command/noyau.lua` | Moteur de décision pur, sans API de jeu — **testable hors du jeu** | `/command/noyau.lua` |
| `command/interface.lua` | Interface de contrôle façon système d'exploitation | `/command/interface.lua` |
| `command/config_command.lua` | Configuration du poste | `/command/config_command.lua` |
| `command/startup.lua` | Lanceur automatique | `/startup.lua` (racine) |
| `command/transpondeur.lua` | Émetteur de code, à poser **sur chaque véhicule** | `/transpondeur.lua` |

Fichiers créés à l'exécution : `command/zones.dat` (zones), `command/etat.dat`
(mode guerre/paix, codes), `command/command.log` (journal).

---

## 2. Matériel

**Poste de commandement**

- 1 **Advanced Computer** (l'interface est en couleurs) ;
- 1 **modem Ender** accolé ;
- 1 **radar** de Create Radars, accessible en périphérique ;
- optionnel : un moniteur avancé (`moniteur` en configuration) ;
- le chunk **doit rester chargé** (`forceload`). Un poste dans un chunk déchargé
  cesse purement et simplement de décider.

**Chaque véhicule ami**

- 1 ordinateur embarqué + 1 modem Ender, exécutant `transpondeur.lua`.
  Sans transpondeur, le véhicule est **INCONNU** — avec toutes les conséquences
  prévues par la doctrine de zone.

---

## 3. Installation

```
mkdir command
wget <depot>/command/command.lua          command/command.lua
wget <depot>/command/noyau.lua            command/noyau.lua
wget <depot>/command/interface.lua        command/interface.lua
wget <depot>/command/config_command.lua   command/config_command.lua
wget <depot>/command/startup.lua          startup.lua
edit command/config_command.lua
reboot
```

Trois champs à renseigner avant la mise en service :

```lua
positionRadar = { x = ..., y = ..., z = ... },   -- F3, ligne "Block"
codeAllie     = "...",                            -- code fixe, à changer
codeAccesMenu = "...",                            -- code du menu protégé
```

Sur chaque véhicule :

```
wget <depot>/command/transpondeur.lua transpondeur.lua
transpondeur FN-ALLIE-0000
```

Le code est mémorisé dans `/transpondeur.cfg` et rejoué au démarrage.

---

## 4. Doctrine d'engagement

### 4.1 Les trois paliers

| Palier | Nom | Ce que Command fait |
|---|---|---|
| 0 | Libre passage | rien du tout, pas même un suivi |
| 1 | Observation passive | la piste est suivie, aucun ordre n'est émis |
| 2 | Scramble | interception de vérification, **sans engagement** |
| 3 | Destruction | ordre de tir vers Fire Control |

### 4.2 Les codes transpondeur

- **Code allié** — fixe. Libre passage dans toutes les zones et tous les modes,
  **sauf en zone Roméo en temps de guerre**, où il déclenche un scramble de
  vérification visuelle sans engagement. C'est la seule exception du système.
- **Code général** — rotatif, changé régulièrement depuis le menu protégé.
  Accès conditionnel selon la zone. L'ancien code reste accepté pendant une
  **période de grâce** (`graceRotation`, 300 s par défaut) : sans elle, une
  rotation abattrait toute la flotte qui n'a pas encore reçu le nouveau code.
- **Absence de code, code invalide, code périmé** → **INCONNU**, sans appel.

### 4.3 Table d'engagement complète

Source unique de vérité : `command/noyau.lua`, table `TABLE_ENGAGEMENT`.
Les 24 cases sont vérifiées une par une par `tests/test_command.lua`.

| Zone | Mode | Code allié | Code général | Inconnu |
|---|---|---|---|---|
| **Charlie** | Paix | observation | **libre passage sans suivi** | scramble |
| **Charlie** | Guerre | observation | **scramble seul** | destruction |
| **Bravo** | Paix | observation | **libre passage sans suivi** | scramble |
| **Bravo** | Guerre | observation | **destruction** | destruction |
| **Alpha** | Paix | observation | destruction + scramble | destruction + scramble |
| **Alpha** | Guerre | observation | destruction + scramble | destruction + scramble |
| **Roméo** | Paix | observation | destruction totale + mobilisation | destruction totale + mobilisation |
| **Roméo** | Guerre | **scramble de vérification** | destruction totale + mobilisation | destruction totale + mobilisation |

Différence Charlie / Bravo en temps de guerre : le code général déclenche un
**scramble** en Charlie, une **destruction** en Bravo. La cible inconnue est
détruite dans les deux cas.

### 4.4 Zone non classifiée

Un point qui n'appartient à aucune zone Charlie, Bravo, Alpha ou Roméo est
**hors juridiction** : le système ne fait rien, ni surveillance ni action.
C'est un comportement voulu, pas un oubli — il apparaît dans le journal
au niveau DEBUG.

### 4.5 Alerte maximale manuelle

Déclenchable en un clic depuis l'écran d'accueil, à tout moment. Elle applique
le régime **Roméo / Guerre** à toutes les zones classifiées, quelle que soit
leur classe. Elle ne couvre pas les zones non classifiées, sauf si
`alerteMaxCouvreHorsZone = true`.

### 4.6 Chevauchement de zones

**La classe la plus stricte l'emporte toujours** : Roméo > Alpha > Bravo >
Charlie. Toutes les zones chevauchées sont listées dans le journal, avec la
classe retenue.

---

## 5. Classification des cibles

Deux critères, trois catégories — et rien d'autre n'est transmis à Fire Control :

| Catégorie | Condition | Libellé transmis |
|---|---|---|
| `INFANTERIE` | joueur, sous le seuil d'altitude | `Infantry` |
| `VEHICULE_SOL` | contraption ou entité, sous le seuil | `GroundVehicle` |
| `AERIENNE` | au-dessus du seuil, ou montée/chute soutenue | `Aerial` |

L'altitude est mesurée **au-dessus d'un sol de référence**, pas en Y absolu :
un char sur un plateau à Y = 210 reste un véhicule au sol si la zone déclare
`solY = 200`. Sans cette précaution, tout le relief d'altitude devient
« cible aérienne ».

**Le choix de l'arme n'appartient pas à Command.** La catégorie est tout ce
qu'il dit du type de cible.

### Faction et Open Parties and Claims

Open Parties and Claims n'est **pas lisible depuis un ordinateur CC: Tweaked**.
L'appartenance de faction doit être poussée par un pont côté serveur, sur le
protocole `frenchnet_roster` :

```lua
rednet.broadcast({ roster = { ["Pseudo"] = { faction = "FRANCE" } } }, "frenchnet_roster")
```

Elle est journalisée avec chaque classification, mais **ne rattrape jamais un
transpondeur muet** : la règle « pas de code valide = INCONNU » est absolue.

---

## 6. Désignation du tireur

Command choisit **qui** réagit, jamais **avec quoi**. Parmi les plateformes
déclarées par Fire Control :

```
score = poidsTirs × (tirs / tirsMax) + poidsDistance × (distance / distanceMax)
```

Les deux termes sont normalisés sur le lot de candidats : sinon un réseau étendu
ferait toujours gagner le nombre de tirs, et un réseau serré toujours la
distance. **Score le plus bas = désigné.** En cas d'égalité parfaite, l'ordre
alphabétique tranche — le déterminisme est ce qui rend une décision rejouable à
partir du journal.

Sont écartées : les plateformes marquées `disponible = false`, celles sans
position valide, et celles hors de leur `portee` (sauf `designerHorsPortee`).
Si plus aucune plateforme n'est désignable, **un contrôleur est alerté**.

### Ce que Fire Control doit envoyer

```lua
rednet.broadcast({
  plateformes = {
    { nom = "AirShip1", x = 1200, y = 210, z = -2600, tirs = 12, disponible = true, portee = 400 },
    { nom = "SAM-Est",  x = 1400, y = 70,  z = -2500, tirs = 3 },
  }
}, "frenchnet_fire_control")
```

`tirs` et `portee` sont facultatifs (0 et illimité par défaut). Un inventaire
plus vieux que `validiteInventaire` (60 s) déclenche une alerte : les compteurs
de tirs ne sont plus fiables.

### Ce que Command envoie

Une chaîne, au format spécifié :

```
AirShip1 Fire type Aerial
```

Selon le verdict :

| Verdict | Ordres émis |
|---|---|
| Scramble | 1 ordre `Scramble` sur la meilleure plateforme |
| Destruction | 1 ordre `Fire` |
| Destruction + scramble (Alpha) | 1 `Fire` + 1 `Scramble`, sur deux plateformes distinctes si possible |
| Destruction totale (Roméo) | 1 `Fire` vers **toutes** les plateformes disponibles |

> ### ⚠ Pourquoi deux verbes et pas un seul
>
> Un scramble de vérification **n'est pas** un ordre de tir. En zone Roméo en
> temps de guerre, un véhicule porteur du **code allié** déclenche un scramble
> « sans engagement ». Lui envoyer le verbe `Fire` ferait tirer Fire Control
> sur un allié.
>
> Par défaut, Command émet `Scramble` pour la vérification et `Fire` pour la
> destruction. Si votre Fire Control ne comprend qu'un seul verbe, passez
> `formatUniqueFire = true` — en sachant exactement ce que cela implique. Le
> réglage est signalé au démarrage dans le journal.

---

## 7. Confirmation de destruction

Après un ordre de **destruction** (jamais après un scramble : il n'engage pas),
Command ouvre une évaluation. **Deux déclencheurs indépendants, l'un OU l'autre
confirme.**

### Déclencheur A — disparition du radar

La cible disparaît complètement pendant `disparitionSecondes` (3 s).

> ### ⚠ Le garde-fou d'enveloppe fiable
>
> Une cible qui **sort de portée**, dont le **chunk se décharge**, ou dont le
> **pilote se déconnecte** disparaît du radar exactement comme une cible
> détruite. Pris au pied de la lettre, ce déclencheur déclare « détruit » tout
> ce qui réussit à fuir — c'est-à-dire qu'il fait cesser le feu précisément sur
> ce qu'il fallait continuer à traiter.
>
> La disparition ne vaut confirmation que si le **dernier point connu était à
> l'intérieur de l'enveloppe fiable** : `porteeRadar × ratioEnveloppeFiable`
> (80 % par défaut). Au-delà, la piste est déclarée **PERDUE** — pas détruite —
> et un contrôleur humain est alerté.
>
> `ratioEnveloppeFiable = 1.0` supprime le garde-fou. Fortement déconseillé,
> et signalé au démarrage.

### Déclencheur B — signature de crash

Sur une **même fenêtre de trois secondes** :

- perte d'au moins **50 %** de vitesse horizontale, **et**
- perte d'environ **40 blocs** d'altitude.

Les deux ensemble distinguent un crash d'une manœuvre volontaire : un pilote
qui pique **gagne** de la vitesse, un pilote qui freine ne perd pas 40 blocs.
Une vitesse de référence minimale (`vitesseMiniCrash`) évite qu'un stationnaire
« perde 50 % de rien ».

### Si aucun des deux n'apparaît

Command réémet un ordre de tir, dans la limite de **`tentativesMax` = 3 ordres
au total**. Au troisième échec, la séquence est abandonnée et un **contrôleur
humain est alerté** — bandeau sur l'écran d'accueil, ligne `CRITIQUE` dans le
journal, et signal de redstone si `sortieRedstoneAlerte` est configuré.

Une piste sous évaluation n'est **jamais oubliée** avant d'avoir été conclue :
c'est la seule façon de trancher entre un crash et une fuite.

---

## 8. Interface

Deux niveaux d'accès, volontairement séparés.

### Écran d'accueil — aucun code

```
 FRENCHNET COMMAND  CMD-01                    14:32

  THEATRE     [   PAIX   ]     <- un clic
  ALERTE      [  MAX OFF  ]

  Pistes suivies  3     Engagements  1
  Zones actives   4     Radar        OK
  Plateformes     2     Inventaire   a jour

  Feu 7  Scramble 3  Kills 5  Perdues 1

 [Accueil][Contacts][Defenses][Journal][Menu]
```

La bascule **guerre / paix** est un bouton, en un clic, sans code. C'est
l'action la plus fréquente et la plus urgente ; la mettre derrière un menu
coûterait des vies. Raccourci clavier : **`G`**. Onglets : **`1`** à **`5`**.

Toute bascule **réévalue immédiatement toutes les pistes** sous le nouveau
régime — y compris une piste déjà « scramblée » en temps de paix, qui passe en
destruction si la guerre l'exige.

### Menu protégé — code d'accès

Configuration des zones et rotation des codes. Ce ne sont pas des actions
d'urgence, et une fausse manœuvre y est bien plus coûteuse qu'une seconde
perdue à taper quatre chiffres. Le menu se reverrouille dès qu'on le quitte.

**Créer une zone** : nom → forme → géométrie → plafond/plancher (facultatifs)
→ classe.

- **Rectangle** : quatre points de coin, en X et Z (`1200 -2600`). L'ordre des
  coins n'a pas d'importance : ils sont réordonnés en quadrilatère non croisé.
  Un rectangle pivoté fonctionne aussi bien qu'un rectangle aligné sur les axes.
- **Cercle** : un centre en X et Z, puis un rayon en blocs.

Les zones sont enregistrées dans `command/zones.dat` et survivent au
redémarrage. Un clic sur une ligne de la liste propose la suppression.

---

## 9. Journal et diagnostic

Format identique au reste de FrenchNet :

```
[2026-09-07 14:32:11] [AVERT] [etape: decision d'escalade] cible Raider-7 (AERIENNE) : palier 3 - destruction avec scramble direct | zone ALPHA / GUERRE / IFF INCONNU -> destruction avec scramble direct
```

Consultable à l'écran (onglet **Journal**) et dans `command/command.log`
(rotation automatique à `journalTailleMax`).

### Les cinq étapes critiques

| Étape | Ce qu'elle trace |
|---|---|
| `detection d'un contact` | nouveau contact radar, nature, position |
| `classification de la cible` | catégorie, statut IFF, appariement du transpondeur, faction |
| `decision d'escalade` | verdict, palier, zone, mode, alerte maximale |
| `designation du tireur` | plateforme retenue, score détaillé, tirs, distance |
| `confirmation de destruction` | déclencheur qui a conclu, ou raison de la réémission |

Les autres étapes couvrent le démarrage, le réseau, la persistance et
l'interface. La liste complète est en tête de `command/command.lua`, table
`ETAPES`.

### Table de diagnostic

| Symptôme | Cause probable |
|---|---|
| « aucune zone classifiee » au démarrage | `zones.dat` vide — rien ne sera engagé, c'est voulu |
| « aucun peripherique radar detecte » | radar absent, ou nom à forcer dans `peripheriqueRadar` |
| « aucune methode connue » sur le radar | API différente — compléter `METHODES_RADAR` dans `command.lua` |
| « inventaire Fire Control perime » | Fire Control ne diffuse plus son inventaire |
| « aucune plateforme designable » | toutes hors portée ou indisponibles |
| Tout est classé INCONNU | code allié non configuré, transpondeurs arrêtés, ou GPS absent |
| « piste perdue hors enveloppe fiable » | la cible est probablement sortie de portée, pas détruite |
| Le système engage des vaches | `traiterEntitesNeutres = true` — le remettre à `false` |
| « referentiel ABSOLU suppose » | radar trop proche de l'origine — forcer `positionsRelatives` |

---

## 10. Tests

```
lua5.4 tests/test_command.lua          # 133 vérifications — la doctrine
lua5.4 tests/test_command_runtime.lua  #  55 vérifications — la chaîne complète
```

**`test_command.lua` — le noyau de décision**, sans Minecraft : les 24 cases de
la table d'engagement, la géométrie des zones, la priorité de la classe la plus
stricte, la catégorisation, l'identification par transpondeur, la répartition de
charge, le plan d'engagement, le format des ordres, et les deux déclencheurs de
confirmation de destruction — y compris le piqué volontaire et le freinage, que
le système doit refuser de compter comme des crashs.

Le noyau (`command/noyau.lua`) n'utilise **aucune API du jeu**. C'est délibéré :
la doctrine est vérifiée case par case avant d'être confiée à des canons.

**`test_command_runtime.lua` — la chaîne complète**, sur un émulateur CraftOS
(`tests/craftos.lua`) avec radar simulé : balayage → piste → classification →
décision → désignation → ordre réellement diffusé → confirmation de destruction.
Il couvre l'intrus détruit, l'allié à code valide, le scramble Charlie en paix,
les trois tentatives suivies de l'alerte humaine, la fuite au bord de portée, le
théâtre hors juridiction, Fire Control muet, les entités neutres ignorées, et un
clic réel sur le bouton guerre / paix de l'interface.

> Ce second banc n'est pas décoratif. Il a mis au jour un défaut que les tests
> unitaires ne pouvaient pas voir : `rednet.broadcast` ne retourne rien, et le
> code en déduisait un échec de transmission. Chaque ordre de tir était
> journalisé comme perdu, une fausse alerte contrôleur était levée, et
> l'engagement n'étant jamais enregistré, le même ordre repartait à chaque
> balayage sans qu'aucune destruction ne soit jamais confirmée. Des briques
> individuellement correctes, mal câblées entre elles.

---

## 11. Limites connues

- **Open Parties and Claims n'est pas accessible depuis CC: Tweaked.** La
  faction arrive par un pont côté serveur sur `frenchnet_roster`, à écrire
  séparément. L'IFF réel repose sur les transpondeurs.
- **L'API de Create Radars n'est pas figée.** L'adaptateur essaie six noms de
  méthode connus et journalise celui qui répond ; si votre version en expose un
  autre, `METHODES_RADAR` est le seul endroit à modifier.
- **Un transpondeur allié capturé donne le code allié.** Le code général
  rotatif limite la fenêtre d'exploitation ; le code allié fixe, non. Le faire
  tourner impose un redémarrage des postes.
- **L'appariement transpondeur ↔ écho radar se fait par nom ou par proximité**
  (`toleranceAppariement`, 24 blocs). Un ennemi collé à un allié dans cette
  tolérance peut hériter de son code. Réduire la tolérance durcit le système
  mais fait perdre son code à un allié rapide.
