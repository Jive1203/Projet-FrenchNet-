# FrenchNet Command — Défense aérienne autonome (CC: Tweaked)

Système de défense aérienne installé au sol pour le serveur **AERONAUTICS WARFARE**
(NeoForge 1.21.1 — Create Aeronautics, Create Radars, Create Big Cannons,
Open Parties and Claims, CC: Tweaked).

**Command décide. Il ne tire pas.** Il détecte, classe, identifie ami-ennemi,
choisit un palier d'escalade, désigne la plateforme qui doit réagir, et transmet
sa décision à **FrenchNet Fire Control**, qui reste seul responsable du tir.

---

## 1. Contenu

Le système compte **quatre types de machines**, chacune avec son rôle :

| Machine | Rôle | Combien |
|---|---|---|
| **Poste de commandement** | décide, ne balaie pas, ne tire pas | 1 |
| **Station radar** | balaie et transmet ses contacts au poste | autant que de radars |
| **Balise de lanceur** | annonce position, munitions et tirs de sa plateforme | 1 par plateforme |
| **Transpondeur** | émet le code IFF d'un véhicule | 1 par véhicule ami |

### Poste de commandement

| Fichier | Rôle |
|---|---|
| `command/command.lua` | Programme principal (réseau, décision, supervision) |
| `command/noyau.lua` | Moteur de décision pur, sans API de jeu — **testable hors du jeu** |
| `command/terrain.lua` | Modèle de terrain observé — **testable hors du jeu** |
| `command/carte.lua` | Projection et symbologie de la carte — **testable hors du jeu** |
| `command/scanner.lua` | Adaptateur radar, partagé avec les stations |
| `command/interface.lua` | Interface de contrôle et carte tactique |
| `command/config_command.lua` | Configuration du poste |
| `command/startup.lua` | Lanceur automatique |

### Station radar, balise de lanceur, transpondeur

| Fichier | Où l'installer |
|---|---|
| `radar/radar.lua` + `radar/config_radar.lua` + `command/scanner.lua` | chaque station radar |
| `lanceur/lanceur.lua` + `lanceur/config_lanceur.lua` | chaque plateforme de défense |
| `command/transpondeur.lua` | chaque véhicule ami |

Fichiers créés à l'exécution sur le poste : `command/zones.dat` (zones),
`command/etat.dat` (mode, codes, alliés déclarés), `command/terrain.dat`
(relief appris), `command/command.log` (journal).

---

## 2. Matériel

**Poste de commandement**

- 1 **Advanced Computer** (l'interface et la carte sont en couleurs) ;
- 1 **modem Ender** accolé ;
- **aucun radar n'est nécessaire** : le poste écoute les stations. Un radar
  accolé est accepté et devient la station `LOCAL` ;
- fortement recommandé : un **moniteur avancé 3×2 minimum** (`moniteur` en
  configuration). La carte tactique change de nature sur un grand écran ;
- le chunk **doit rester chargé** (`forceload`). Un poste dans un chunk déchargé
  cesse purement et simplement de décider.

**Chaque station radar**

- 1 ordinateur + 1 **modem Ender** + 1 **radar** de Create Radars ;
- chunk **forceload**. Une station dans un chunk déchargé devient muette, et le
  poste le signale : `station RAD-xx muette depuis 18s : sa couverture est perdue`.

**Chaque plateforme de défense**

- 1 ordinateur + 1 **modem Ender** ;
- idéalement un **coffre ou baril de munitions accolé** : la balise compte le
  stock réel. À défaut, compteur manuel.

**Chaque véhicule ami**

- 1 ordinateur embarqué + 1 modem Ender, exécutant `transpondeur.lua`.
  Sans transpondeur, le véhicule est **INCONNU** — avec toutes les conséquences
  prévues par la doctrine de zone.

---

## 3. Installation

### Poste de commandement

```
mkdir command
wget <depot>/command/command.lua          command/command.lua
wget <depot>/command/noyau.lua            command/noyau.lua
wget <depot>/command/terrain.lua          command/terrain.lua
wget <depot>/command/carte.lua            command/carte.lua
wget <depot>/command/scanner.lua          command/scanner.lua
wget <depot>/command/interface.lua        command/interface.lua
wget <depot>/command/config_command.lua   command/config_command.lua
wget <depot>/command/startup.lua          startup.lua
edit command/config_command.lua
reboot
```

Trois champs avant la mise en service :

```lua
positionPoste = { x = ..., y = ..., z = ... },   -- F3, ligne "Block"
codeAllie     = "...",                            -- code fixe, à changer
codeAccesMenu = "...",                            -- code du menu protégé
```

Le poste refuse de démarrer sans `noyau.lua`, `terrain.lua` et `scanner.lua`.
`carte.lua` et `interface.lua` sont facultatifs : sans eux le poste décide
toujours, il n'affiche simplement plus rien.

### Chaque station radar

```
mkdir radar
wget <depot>/radar/radar.lua          radar/radar.lua
wget <depot>/radar/config_radar.lua   radar/config_radar.lua
wget <depot>/command/scanner.lua      radar/scanner.lua
wget <depot>/radar/startup.lua        startup.lua
edit radar/config_radar.lua
reboot
```

Deux champs par station : `identifiant` (unique) et `position` (F3, ligne
« Block »).

### Chaque plateforme de défense

```
mkdir lanceur
wget <depot>/lanceur/lanceur.lua          lanceur/lanceur.lua
wget <depot>/lanceur/config_lanceur.lua   lanceur/config_lanceur.lua
wget <depot>/lanceur/startup.lua          startup.lua
edit lanceur/config_lanceur.lua
reboot
```

L'`identifiant` saisi ici est **le nom repris dans les ordres de tir** :
il doit correspondre exactement à ce que Fire Control connaît.

### Chaque véhicule ami

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
| 2 | Scramble | interception de vérification, **sans engagement**. Contre une cible au sol c'est un **Scramble AG**, et il exige la validation d'un contrôleur |
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

## 5. Réseau de stations radar

Le poste central **ne balaie pas** : il écoute. Chaque station radar est un
ordinateur autonome posé à côté de son antenne, qui normalise ses échos en
coordonnées absolues et les transmet sur `frenchnet_radar`.

Ce que l'architecture apporte :

- la couverture n'est plus limitée à la portée d'un seul radar ;
- la chute d'une station **dégrade** la couverture au lieu d'aveugler le système,
  et le poste le dit : `station RAD-SUD muette depuis 18s` ;
- chaque station déclare **sa** portée, donc **son** enveloppe fiable. Une cible
  disparue à 400 m d'une station de 512 m est probablement détruite ; la même
  disparition à 400 m d'une station de 450 m est une fuite. La confirmation de
  destruction utilise la portée de la station qui a *réellement* vu la cible ;
- une station est posée au sol : sa position est un relevé d'altitude exact.

### Fusion des pistes

Deux stations qui voient le même appareil ne doivent pas produire deux pistes —
le système tirerait deux fois sur une seule cible et compterait deux menaces.
Les contacts sont regroupés par identifiant stable, et à défaut par proximité
(`toleranceFusion`, 8 blocs). La position retenue est celle de la **station la
plus proche** : la mesure la moins dégradée.

---

## 6. Modèle de terrain

> ### Pourquoi pas la seed du monde
>
> Reconstituer la génération de Minecraft 1.21.1 à partir de la seed est hors
> de portée d'un ordinateur CC: Tweaked. Il faudrait la pile complète des
> *density functions*, les splines de terrain, les paramètres de climat et les
> *surface rules*, plus une reproduction exacte de `XoroshiroRandomSource` —
> donc de l'arithmétique 64 bits, alors que Lua sous Cobalt travaille en
> flottants. Une seule colonne demande des dizaines d'évaluations de bruit :
> un ordinateur du jeu mettrait **des minutes par colonne**.
>
> Et le résultat ignorerait tout ce que les joueurs ont construit ou creusé —
> c'est-à-dire précisément ce qui compte sur un serveur de guerre.

À la place, le terrain est **appris par observation**. Tout ce dont on connaît
la position et qui touche le sol est une sonde d'altitude :

| Source | Poids | Fiabilité |
|---|---|---|
| import de heightmap | 5 | exportée du serveur |
| station radar | 4 | position déclarée |
| lanceur | 4 | position déclarée |
| relevé manuel | 4 | saisi par un contrôleur |
| joueur au sol | 1 | abondant, opportuniste |

Le modèle est une grille de cases de 16 blocs (`terrainResolution`),
enregistrée dans `command/terrain.dat`, qui **survit aux redémarrages** et
devient plus fine avec le temps. Chaque interrogation rend une altitude **et
une confiance** : le système sait ce qu'il ne sait pas, et le journalise.

### Pas de raisonnement circulaire

Utiliser un contact pour décider où est le sol, puis le sol pour décider que ce
contact vole, serait une boucle. Une sonde doit donc être **posée** :

- altitude stable sur au moins 3 relevés consécutifs (`sondeEchantillons`) ;
- **les véhicules sont refusés par défaut** (`sondesVehicules = false`) : un
  aéronef en croisière à altitude constante passerait pour un véhicule au sol et
  empoisonnerait durablement le modèle. Un joueur qui marche, lui, est posé ;
- un relevé qui contredit de plus de 30 blocs une case déjà bien étayée est
  refusé : ce n'est pas du terrain, c'est un contact en vol au-dessus.

---

## 7. Classification des cibles

Trois catégories, et rien d'autre n'est transmis à Fire Control :

| Catégorie | Condition | Libellé transmis |
|---|---|---|
| `INFANTERIE` | joueur, sous le seuil d'altitude | `Infantry` |
| `VEHICULE_SOL` | contraption ou entité, sous le seuil | `GroundVehicle` |
| `AERIENNE` | au-dessus du seuil, montée/chute soutenue, **ou projectile** | `Aerial` |

L'altitude est mesurée **au-dessus du sol réellement mesuré** par le modèle de
terrain, pas en Y absolu. Un char sur un plateau à Y = 205 reste un véhicule au
sol ; un aéronef à Y = 260 au-dessus du même plateau reste aérien. Là où le
modèle n'a pas encore de relevé, on retombe sur `solY` de la zone puis sur
`altitudeSolReference` — et le journal le dit.

### Projectiles

Un missile n'est ni un aéronef ni un véhicule : il ne se scramble pas, il ne se
vérifie pas, et il arrive vite. Deux détections indépendantes :

- **par le type** rendu par le mod (`missile`, `rocket`, `shell`, `projectile`,
  `fireball`, `torpedo`…), faite par la station radar ;
- **par la cinématique**, faite par le poste : un contact non-joueur au-delà de
  `vitesseProjectile` (30 b/s par défaut) est requalifié `PROJECTILE`. La
  requalification est définitive — un obus ne redevient pas un aéronef en
  ralentissant à l'impact.

Un projectile est **cible aérienne par nature**, quelle que soit son altitude :
un obus rasant classé « véhicule au sol » serait confié à un appui sol, contre
quelque chose qui va bien trop vite pour ça.

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

## 8. Désignation du tireur

Command choisit **qui** réagit, jamais **avec quoi**. Les plateformes
s'annoncent elles-mêmes par leur balise de lanceur :

```
score =   poidsMunitions × (1 − munitions / munitionsMax)
        + poidsDistance  × (distance / distanceMax)
        + poidsTirs      × (tirs / tirsMax)
```

Les trois termes sont normalisés sur le lot de candidats : sinon un réseau
étendu ferait toujours gagner la distance, et un réseau bien approvisionné
toujours les munitions. **Score le plus bas = désigné.** En cas d'égalité
parfaite, l'ordre alphabétique tranche — le déterminisme est ce qui rend une
décision rejouable à partir du journal.

**Le stock pèse le plus lourd** (1.5 contre 1.0 et 0.5) : envoyer l'ordre à une
rampe presque vide, c'est perdre la cible au deuxième tir. Une plateforme à
**stock nul n'est jamais désignée**, et le journal dit pourquoi :
`plateforme SAM-Sec ecartee : stock de munitions epuise`.

Sont aussi écartées : les plateformes hors de leur `portee` (sauf
`designerHorsPortee`), celles sans position valide, et celles qui **ne traitent
pas la catégorie** visée — une batterie anti-aérienne pure ne reçoit pas d'ordre
sur de l'infanterie (`categoriesTraitees` dans `config_lanceur.lua`).
Si plus aucune plateforme n'est désignable, **un contrôleur est alerté**.

### Comptage des munitions

La balise compte le stock **réel** dans un coffre ou baril accolé, en filtrant
les noms d'objet (`missile`, `shell`, `rocket`…). Elle en déduit les tirs :
**une baisse de stock EST un tir**, aucune déclaration à faire. Le compteur
survit aux redémarrages. À défaut d'inventaire lisible, comptage manuel avec
les touches `+` et `−` sur la balise.

### Ce qu'une balise de lanceur émet

```lua
rednet.broadcast({
  protocole = "FRENCHNET_LANCEUR", nom = "AirShip1",
  x = 1200, y = 210, z = -2600,
  portee = 400, munitions = 12, tirs = 3, disponible = true,
  categories = { "AERIENNE" },   -- nil = toutes
}, "frenchnet_lanceur")
```

Une balise silencieuse depuis plus de `validiteInventaire` (60 s) est écartée :
mieux vaut ne pas désigner que désigner une plateforme dont on ne sait plus si
elle existe encore. L'inventaire global poussé par Fire Control sur
`frenchnet_fire_control` reste accepté pour les installations sans balise ; la
balise fait autorité quand les deux existent.

### Ce que Command envoie

Une chaîne, au format spécifié :

```
AirShip1 Fire type Aerial
```

Selon le verdict :

| Verdict | Ordres émis |
|---|---|
| Scramble, cible aérienne | 1 ordre `Scramble` sur la meilleure plateforme |
| Scramble, cible au sol | **rien** — une demande de `Scramble AG` est soumise au contrôleur |
| Destruction | 1 ordre `Fire` |
| Destruction + scramble (Alpha) | 1 `Fire` + 1 `Scramble`, sur deux plateformes distinctes si possible |
| Destruction totale (Roméo) | 1 `Fire` vers **toutes** les plateformes disponibles |

### Scramble AG : air-sol, et jamais automatique

Un intercepteur lancé contre un aéronef et un appui lancé contre de l'infanterie
ne font pas le même métier. Les deux paliers de scramble portent donc des verbes
distincts :

```
AirShip1 Scramble type Aerial
Appui-1 Scramble AG type GroundVehicle
Appui-1 Scramble AG type Infantry
```

> **Le Scramble AG ne part jamais tout seul.**
>
> Lancer une patrouille air-sol engage des hommes et des appareils sur une cible
> qui, la plupart du temps, se trouve simplement au mauvais endroit : un joueur
> qui traverse à pied, un convoi allié dont le transpondeur est tombé. Le système
> sait détecter, classer et désigner ; il ne décide pas seul d'envoyer une
> patrouille au sol.
>
> Quand la doctrine appelle un scramble sur une cible au sol, Command **ne
> transmet rien**. Il enregistre une **demande de Scramble AG**, désigne quand
> même la plateforme la mieux placée, et alerte le contrôleur — qui valide, ou
> refuse, depuis la carte tactique. Les deux issues sont journalisées : un ordre
> non donné est une décision.
>
> Le feu n'est pas concerné : une destruction décidée par la doctrine reste
> automatique, au sol comme en l'air. `scrambleAGAutomatique = true` lève le
> verrou, en connaissance de cause.

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

## 9. Confirmation de destruction

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
> l'intérieur de l'enveloppe fiable** : `portée × ratioEnveloppeFiable`
> (80 % par défaut). Au-delà, la piste est déclarée **PERDUE** — pas détruite —
> et un contrôleur humain est alerté.
>
> La portée retenue est celle de **la station qui a réellement vu la cible**,
> pas une moyenne du réseau. Une cible disparue à 400 m d'une station de 512 m
> est probablement détruite ; la même disparition à 400 m d'une station de
> 450 m est une sortie de portée. Confondre les deux, c'est cesser le feu sur
> ce qui s'échappe.
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

## 10. Interface

Deux niveaux d'accès, volontairement séparés.

### Écran d'accueil — aucun code

```
 FRENCHNET COMMAND  CMD-01                    14:32

  THEATRE     [   PAIX   ]     <- un clic
  ALERTE      [  MAX OFF  ]

  Pistes suivies  3     Engagements  1
  Zones actives   4     Radars       3/4
  Lanceurs        2     Munitions    28

  Feu 7  Scramble 3  Kills 5  Perdues 1
  [ 1 SCRAMBLE AG A VALIDER - ouvrir la carte ]

 [Accueil][Carte][Contacts][Defense][Journal][Menu]
```

La bascule **guerre / paix** est un bouton, en un clic, sans code. C'est
l'action la plus fréquente et la plus urgente ; la mettre derrière un menu
coûterait des vies. Raccourci clavier : **`G`**. Onglets : **`1`** à **`6`**.

Une demande de Scramble AG en attente passe devant tout le reste : c'est la
seule chose que le système ne peut pas résoudre seul.

### Carte tactique — moving map

```
 FRENCHNET COMMAND  CMD-01                    14:32
                          ^
        R          *      ^        #
             +                 i
                    L
 32 b/car  1632x480 b  suivi MENACE  3/4 radar  1 AG EN ATTENTE
 > Convoi-3  VEHICULE_SOL  INCONNU  CHARLIE  412m
 [X] Scramble AG   [ ] Attaque   [ ] Allie
 [ TRANSMETTRE ]  [ Annuler ]
 SCRAMBLE AG demande par la doctrine - plateforme Appui-1  [Refuser]
```

**Règle de lecture : le glyphe dit *ce que c'est*, la couleur dit *qui c'est*.**
Les deux informations sont indépendantes, donc lisibles sans mémoriser une
combinatoire.

| Glyphe | Contact | | Couleur | Identification |
|---|---|---|---|---|
| `*` | missile ou projectile | | 🟢 vert | code allié — libre passage |
| `^` | aéronef ou navire volant | | 🔵 bleu | code général |
| `o` | joueur en vol (élytre, jetpack) | | 🟠 orange | inconnu, hors zone ou non engagé |
| `#` | véhicule au sol | | 🔴 rouge | confirmé ennemi, ou engagement en cours |
| `i` | infanterie | | | |
| `R` `L` `+` | station radar, lanceur, poste | | fond jaune | scramble AG en attente de validation |

Le rouge est rare par construction : il ne s'allume que sur une destruction
décidée ou un engagement ouvert. Un inconnu qui traverse une zone Charlie en
paix reste **orange**, parce que le système ne lui fait rien. Un rouge permanent
ne voudrait plus rien dire.

Le fond de carte est colorié par classe de zone — et il est calculé par le
**même moteur** que les décisions (`noyau.zonePourPoint`). La carte ne peut donc
pas mentir sur la doctrine : ce qu'on voit est littéralement ce que le système
applique.

**Carte mouvante** : en suivi `MENACE` (par défaut), la carte reste accrochée au
contact le plus dangereux et le suit pendant tout l'engagement. `POSTE` recentre
sur le poste, `LIBRE` rend la main.

| Commande | Effet |
|---|---|
| `+` / `−`, molette | zoom, de 2 à 1024 blocs par caractère |
| flèches | déplacer la carte (bascule en suivi `LIBRE`) |
| `C` / `M` | suivi poste / suivi menace |
| clic gauche | sélectionner le contact et ouvrir le panneau d'ordre |

**Clic gauche sur un contact** ouvre le panneau d'ordre juste en dessous :
cases à cocher **Scramble** (ou **Scramble AG**, le libellé reflète le verbe
réellement transmis), **Attaque**, les deux, ou **Allié**. Un ordre manuel passe
par-dessus la doctrine de zone, y compris hors juridiction, et est journalisé
comme tel avec le verdict automatique qu'il court-circuite.

**Déclarer un contact allié** prime sur le transpondeur : c'est ce qui permet de
couvrir immédiatement un appareil dont l'émetteur est détruit, sans attendre une
rotation de code. Conséquence directe et voulue : **tout engagement en cours sur
ce contact est interrompu sur-le-champ**. La déclaration survit aux redémarrages
et se révoque.

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

## 11. Journal et diagnostic

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
| `reception d'une trame de station radar` | entrée, silence et retour de chaque station |
| `reception d'une balise de lanceur` | position, stock, tirs, rupture de munitions |
| `fusion des pistes multi-radars` | contact vu par plusieurs stations, position retenue |
| `modele de terrain` | relevés acceptés et refusés, avec leur motif |
| `detection de projectile` | requalification cinématique, seuil franchi |
| `demande de scramble AG` | demande, rappel périodique, validation ou refus |
| `ordre manuel du controleur` | ce qu'un humain a ordonné, et le verdict qu'il court-circuite |
| `declaration d'allie par un controleur` | déclaration, engagement interrompu, révocation |

Les autres étapes couvrent le démarrage, le réseau, la persistance et
l'interface. La liste complète est en tête de `command/command.lua`, table
`ETAPES`.

### Table de diagnostic

| Symptôme | Cause probable |
|---|---|
| « aucune zone classifiee » au démarrage | `zones.dat` vide — rien ne sera engagé, c'est voulu |
| « reseau radar entierement muet » | toutes les stations sont tombées ou leurs chunks sont déchargés |
| « station RAD-xx muette depuis Ns » | station tombée, chunk déchargé, ou protocole différent |
| « aucune methode connue » sur le radar | API différente — compléter `scanner.METHODES` |
| « aucune plateforme joignable » | aucune balise de lanceur ne diffuse |
| « stock de munitions epuise » | la rampe est vide — elle n'est plus désignée, c'est voulu |
| « balise du lanceur X muette » | l'ordinateur de la plateforme est tombé |
| « aucune plateforme designable » | toutes hors portée, vides, ou de mauvaise catégorie |
| Tout est classé INCONNU | code allié non configuré, transpondeurs arrêtés, ou GPS absent |
| « piste perdue hors enveloppe fiable » | la cible est probablement sortie de portée, pas détruite |
| « scramble AG en attente de validation » | normal — un contrôleur doit valider depuis la carte |
| Le système engage des vaches | `traiterEntitesNeutres = true` — le remettre à `false` |
| Un aéronef classé véhicule au sol | modèle de terrain empoisonné — vérifier `sondesVehicules = false` |
| « terrain inconnu ici » | le modèle n'a pas encore de relevé — normal au démarrage |
| « referentiel ABSOLU suppose » | station trop proche de l'origine — forcer `positionsRelatives` |

---

## 12. Tests

```
lua5.4 tests/test_command.lua          # 191 vérifications — doctrine, terrain, carte
lua5.4 tests/test_command_runtime.lua  #  88 vérifications — la chaîne complète
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
théâtre hors juridiction, les entités neutres ignorées, un clic réel sur le
bouton guerre / paix — et, sur le réseau complet : **deux stations radar voyant
la même cible** (fusion en une seule piste, un seul couple d'ordres), la
**désignation par munitions** avec une rampe à sec écartée, le **verrou du
Scramble AG** (aucun ordre transmis, demande enregistrée une seule fois), les
**projectiles** par type et par cinématique, et enfin le **scénario complet du
poste de contrôle** : la doctrine demande, l'opérateur ouvre la carte, clique le
contact, coche la case, transmet — et l'ordre `Appui-1 Scramble AG type
GroundVehicle` part réellement sur le réseau.

> Ce second banc n'est pas décoratif. Il a mis au jour un défaut que les tests
> unitaires ne pouvaient pas voir : `rednet.broadcast` ne retourne rien, et le
> code en déduisait un échec de transmission. Chaque ordre de tir était
> journalisé comme perdu, une fausse alerte contrôleur était levée, et
> l'engagement n'étant jamais enregistré, le même ordre repartait à chaque
> balayage sans qu'aucune destruction ne soit jamais confirmée. Des briques
> individuellement correctes, mal câblées entre elles.

---

## 13. Limites connues

- **Le terrain n'est pas calculé depuis la seed, il est observé.** C'est un
  choix imposé par la plateforme (voir §6) et non un raccourci : au démarrage le
  modèle est vide et la classification retombe sur `altitudeSolReference`. Il
  faut laisser le système observer, ou importer une heightmap. La couverture et
  la confiance sont affichées en permanence sur la carte.
- **Open Parties and Claims n'est pas accessible depuis CC: Tweaked.** La
  faction arrive par un pont côté serveur sur `frenchnet_roster`, à écrire
  séparément. L'IFF réel repose sur les transpondeurs.
- **La fusion de pistes se fait par identifiant, à défaut par proximité.** Deux
  appareils en formation serrée sous `toleranceFusion` (8 blocs) peuvent être
  comptés comme un seul. Réduire la tolérance durcit la séparation mais fait
  réapparaître des doublons quand les stations divergent de quelques blocs.
- **La détection cinématique de projectile est un seuil de vitesse.** Un
  intercepteur très rapide au-delà de `vitesseProjectile` sera requalifié
  projectile — donc traité comme cible aérienne, ce qui reste correct, mais son
  symbole changera sur la carte.
- **L'API de Create Radars n'est pas figée.** L'adaptateur essaie six noms de
  méthode connus et journalise celui qui répond ; si votre version en expose un
  autre, `scanner.METHODES` est le seul endroit à modifier — et la correction
  profite du même coup aux stations et au poste, qui partagent le fichier.
- **Un transpondeur allié capturé donne le code allié.** Le code général
  rotatif limite la fenêtre d'exploitation ; le code allié fixe, non. Le faire
  tourner impose un redémarrage des postes.
- **L'appariement transpondeur ↔ écho radar se fait par nom ou par proximité**
  (`toleranceAppariement`, 24 blocs). Un ennemi collé à un allié dans cette
  tolérance peut hériter de son code. Réduire la tolérance durcit le système
  mais fait perdre son code à un allié rapide.
