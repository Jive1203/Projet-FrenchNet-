# FrenchNet — Livraison aérienne : guide complet

Système de livraison automatisé et réutilisable pour dirigeable **Create Aeronautics**, sous **CC: Tweaked**, avec interface de commande publique ouverte à tous les joueurs et à toutes les factions d'**AERONAUTICS WARFARE**.

---

## 1. Principe et périmètre

Le navire **ne vole pas tout seul** : il **appelle** le module d'autopilote standardisé déjà construit et déjà réglé, et se contente de **réagir à ses messages d'état**. Ce dépôt ne contient :

- **aucune** boucle d'asservissement d'altitude ;
- **aucune** boucle d'asservissement de cap ;
- **aucun** PID ;
- **aucune** commande de moteur ou de gouverne.

Il contient la logistique : grille tarifaire centralisée, file de commandes publiques, prélèvement dans le stockage source, vol commandé, encaissement, dépôt, pénalités, retour automatique, supervision.

Il ne décide pas non plus des **prix** : ceux-ci viennent de l'ordinateur central (§6), et les **conteneurs** se déclarent dans l'interface de l'autopilote (§5.2).

Le réseau de balises GPS FrenchNet est supposé en place : le navire utilise `gps.locate()`, donc la constellation de quatre balises non alignées et à altitudes différentes est un prérequis.

```
        CENTRAL                BORNE PUBLIQUE          NAVIRE            AUTOPILOTE
   (local fermé, à code)       (tout le monde)       (ce dépôt)       (déjà construit)
        |                           |                    |                   |
        |--- TARIF signé ---------->|                    |                   |
        |--- TARIF signé ------------------------------->|                   |
        |                           |--- COMMANDE ------>|                   |
        |                           |<-- ACCUSE ---------|                   |
        |                           |                    |-- ap.allerA() --->|
        |                           |                    |<- "arrivee" ------|
        |                           |<-- ETAT / AVIS ----|                   |
                                                         |                   |
                                    parallel.waitForAny(ap.executer, mission...)
```

La boucle de vol `ap.executer()` tourne **dans le même `parallel`** que la mission : c'est l'usage prescrit par le module, et la condition pour qu'un ordre aboutisse.

---

## 2. Architecture des fichiers

| Fichier | Rôle |
|---|---|
| `navire/livraison.lua` | Programme embarqué. Machine à états de mission, serveur de commandes, superviseur. |
| `navire/autopilote.lua` | **Adaptateur** : traduit « va à ce point » vers l'API réelle du module d'autopilote. Zéro logique de vol. |
| `navire/config_livraison.lua` | Pages à ajouter à la configuration du véhicule — ou recouvrement autonome. |
| `central/central.lua` | Centrale tarifaire : menu verrouillé par code, diffusion signée de la grille. |
| `central/config_central.lua` | Configuration de la centrale (serrure, jeton, grille initiale). |
| `navire/startup.lua` | Lanceur automatique, ultime filet de sécurité au-dessus du superviseur interne. |
| `borne/borne.lua` | Borne de commande publique (catalogue, panier, niveau de service, coordonnées, suivi). |
| `borne/config_borne.lua` | Configuration de la borne. |
| `commun/journal.lua` | Journal horodaté, étiqueté par étape, avec rotation de fichier. |
| `commun/protocole.lua` | Enveloppe rednet, validation des commandes, tarification, distances. |
| `commun/inventaire.lua` | `pushItems` / `pullItems`, transferts exacts, catalogue, gros volumes. |
| `tests/craftos.lua` | Mini-émulateur CraftOS, inventaires compris. |
| `tests/test_livraison.lua` | 138 vérifications : nominal, pannes, API réelle de l'autopilote, centrale et pénalités. |

---

## 3. Raccordement de l'autopilote

L'autopilote FrenchNet est une **bibliothèque** : il ne décide de rien, ce sont les programmes de mission — livraison, scramble, patrouille — qui lui donnent une cible. `navire/autopilote.lua` est l'adaptateur qui fait le lien, et rien d'autre.

### 3.1 L'API réellement utilisée

```lua
local autopilote = dofile("/autopilote/autopilote.lua")

local ap = autopilote.nouveau()          -- lit config_vehicule.lua, la valide
ap.initialiser()                         -- relit la position avant tout
ap.allerA(point, options)                -- rejoindre un point
ap.attendreArrivee(delai)                -- bloquant, dans une tâche
ap.etat()                                -- instantané complet
ap.maintenirPosition(point, cap)         -- tenir la position
ap.arreter(motif)                        -- neutraliser les commandes
ap.rejoindreRavitaillement()             -- station verrouillée du réseau
ap.surEvenement(rappel)                  -- "etape" | "arrivee" | "anomalie"
ap.executer()                            -- LA BOUCLE DE VOL

parallel.waitForAny(ap.executer, mission)
```

Un point de passage :

```lua
{ x = , y = , z = , type = "survol" | "depot" | "atterrissage" | "amarrage",
  cap = degrés, arret = true, nom = "..." }
```

### 3.2 Deux conséquences qui gouvernent tout le programme

**1. `ap.executer()` tourne en parallèle de la mission.** Sans elle, aucun ordre n'est exécuté et `attendreArrivee` ne rend jamais la main. Le programme de livraison la lance donc dans son propre `parallel.waitForAny` :

```lua
parallel.waitForAny(pilote.executer, cycleServeur, cycleMission,
                    cycleDiffusion, cycleTerminate)
```

C'est aussi pourquoi la **vérification de position au démarrage** a lieu à l'intérieur de la tâche de mission, et non avant : rejoindre un point de sécurité passe par `attendreArrivee`, qui exige que la boucle de vol tourne déjà.

**2. Le décalage de dépôt est appliqué par l'autopilote**, et tourné selon le cap courant. Le programme lui transmet donc les **coordonnées brutes** demandées par le client, avec `type = "depot"` :

```lua
pilote.allerA({ x = 400, y = 80, z = -250 }, "depot")
```

et c'est l'autopilote qui place le centre du navire là où il faut pour que la trappe de soute tombe sur 400 / 80 / -250. Recalculer ce décalage ici serait précisément la réimplémentation qu'il faut éviter. Le journal ne montre donc **jamais** de « cible du centre navire » côté livraison.

| Situation | Type de point transmis |
|---|---|
| livraison chez un client | `depot` |
| retour à un point de sécurité | `atterrissage` |
| ralliement du point de chargement | `atterrissage` |
| ravitaillement | `ap.rejoindreRavitaillement()` |

### 3.3 Niveau de service

`slow ship` est transmis à l'autopilote comme un **plafond de vitesse** de mission :

```lua
optionsMission.vitesseMax = config.vitesses.croisiere * facteurVitesseLente
```

`vitesses.croisiere` est lue dans la configuration du véhicule, `facteurVitesseLente` dans les pages de livraison (défaut `0.6`). `fast ship` ne plafonne rien : le vaisseau vole à sa vitesse de croisière normale, et sa commande passe devant les `slow ship` en file d'attente.

### 3.4 Messages d'état

L'adaptateur s'abonne par `ap.surEvenement` et recopie dans le journal de livraison les trois événements de l'autopilote :

```
[INFO]  [etape: surveillance des messages d'etat de l'autopilote] autopilote : etape 2/3 franchie (COL-NORD)
[INFO]  [etape: surveillance des messages d'etat de l'autopilote] autopilote : arrive a destination (ecart 0.42 bloc)
[AVERT] [etape: surveillance des messages d'etat de l'autopilote] autopilote : ANOMALIE -- signal GPS perdu
```

Une anomalie de vol se lit ainsi au même endroit qu'un incident de cargaison. L'autopilote conserve par ailleurs son propre journal, séparément.

### 3.5 Où l'adaptateur cherche le module

Dans cet ordre, d'après la section `autopilote` des pages de livraison :

1. `autopilote.nomGlobal` — une table globale déjà chargée par un `startup` ;
2. `autopilote.chemin` — un fichier sur le disque, défaut `/autopilote/autopilote.lua`.

Puis il appelle `autopilote.nouveau{ config = cheminConfig }` et vérifie que l'instance expose bien `allerA`, `attendreArrivee`, `etat` et `executer`.

### 3.6 Si le module est introuvable

Le navire démarre, accepte et met en file les commandes, mais **n'en engage aucune** : rien n'est chargé, rien ne décolle. Le journal le dit en CRITIQUE :

```
[CRITIQUE] [etape: connexion au module d'autopilote] AUCUN VOL POSSIBLE : module d'autopilote introuvable (/autopilote/autopilote.lua)
[CRITIQUE] [etape: connexion au module d'autopilote] le navire accepte les commandes mais ne decollera pas -- verifier l'installation de l'autopilote
```

C'est délibéré. Simuler un vol ferait « livrer » une cargaison restée à quai et encaisser un paiement pour rien. L'adaptateur expose alors des méthodes de repli qui refusent poliment, de sorte que la borne reste servie et qu'aucun appel ne plante.

---

## 4. Géométrie : les décalages

Trois repères. **Deux appartiennent à l'autopilote** et sont déclarés dans sa configuration véhicule ; le troisième est propre à la livraison.

| Décalage | Fichier | Ce qu'il décrit | Qui l'applique |
|---|---|---|---|
| `decalageGps` | `/autopilote/config_vehicule.lua` | position du **calculateur** par rapport au **centre du navire** | l'autopilote |
| `decalageDepot` | `/autopilote/config_vehicule.lua` | position de la **trappe de soute** par rapport au **centre du navire** | l'autopilote, tourné selon le cap |
| `conteneurs[n].decalage` | pages de livraison | position de **chaque conteneur** par rapport au **centre du navire** | documentation de coque, contrôles de gabarit, repérage visuel |

Le programme de livraison ne fait donc **aucun calcul de position** : il demande `pilote.position()`, qui lit le centre du navire dans `ap.etat()`.

Relevez toutes les coordonnées avec **F3, ligne `Block:`** — la ligne `XYZ` donne la position du joueur, avec des décimales.

---

## 5. Configuration

### 5.1 Un seul fichier par véhicule

Le fichier de configuration par véhicule est **celui de l'autopilote**, `/autopilote/config_vehicule.lua`. Il porte déjà :

```lua
nom, identifiant                 -- identité du vaisseau
decalageGps, decalageDepot       -- points de référence GPS et de dépôt
decalageDansRepereVehicule       -- repère dans lequel ils sont exprimés
tolerances                       -- horizontale, altitude, cap
vitesses                         -- croisière, verticaleMax, approche...
gabarit                          -- longueur, largeur, hauteur
gains                            -- gains PID de chaque axe
pilotage, maintien, sol, gps,    -- réglages fins de l'autopilote
cap, sorties, carburant, mission
```

La **station de ravitaillement** n'est volontairement pas dans ce fichier : c'est une constante de réseau, verrouillée dans `/autopilote/ravitaillement.lua`. Le système de livraison ne fait donc que demander `ap.rejoindreRavitaillement()`.

Le système de livraison ajoute à cette même table quatre pages : `conteneurs`, `livraison`, `tarif`, plus `reseau`, `journal` et `robustesse`. `navire/config_livraison.lua` les contient toutes prêtes à copier.

Deux dispositions possibles :

| Disposition | Comment | Quand |
|---|---|---|
| **Fichier unique** (recommandé) | recopier les pages à la fin de la table de `/autopilote/config_vehicule.lua` | cas normal : tout le véhicule dans un fichier |
| **Recouvrement** | laisser `navire/config_livraison.lua` en place | grille tarifaire partagée entre plusieurs vaisseaux, ou fichier autopilote à ne pas toucher |

Si les deux existent, le recouvrement l'emporte, page par page. Il peut aussi redéfinir `autopilote.chemin` et `autopilote.cheminConfig`, ce qui permet de faire tourner le programme sur une installation non standard.

`identifiant` doit être **unique sur le serveur** : c'est la clé des messages rednet comme des événements de l'autopilote. Deux dirigeables qui le partagent se répondent mutuellement.

### 5.2 Conteneurs — une page par conteneur

**Le plus simple est de ne pas les écrire à la main.** L'interface de réglage de l'autopilote a une section *Conteneurs* qui les détecte et les écrit dans `/autopilote/config_vehicule.lua` :

```
interface                  -- puis section "Conteneurs"
    D       détecte les inventaires branchés et crée une page pour chacun
    N       ajoute une page vierge
    Suppr   retire celui sous le curseur
```

Câblez les modems filaires, appuyez sur `D`, réglez le rôle et le décalage de chaque page, `S` pour enregistrer. Le fichier généré contient alors le tableau ci-dessous, que le système de livraison relit tel quel.

```lua
conteneurs = {
  {
    nom          = "Soute avant",
    peripherique = "minecraft:barrel_0",     -- nom RÉSEAU (peripheral.getNames)
    decalage     = { x = -4, y = -1, z = 6 },
    role         = "expedition",             -- expedition | recette | tampon
    priorite     = 1,                        -- ordre de remplissage
    capacite     = 27,                       -- indicatif
  },
}
```

| Rôle | Comportement |
|---|---|
| `expedition` | chargé au départ, **entièrement vidé** chez le destinataire |
| `recette` | reçoit le paiement aspiré chez le client |
| `tampon` | ignoré par la livraison — réserve interne |

Le conteneur doit être **relié au calculateur par un modem filaire** : `pushItems` et `pullItems` n'opèrent qu'entre deux inventaires du **même réseau**.

Pour relever les noms réseau, sur le calculateur :

```lua
for _, n in ipairs(peripheral.getNames()) do print(n, peripheral.getType(n)) end
```

### 5.3 Livraison

```lua
livraison = {
  conteneursSource     = { "create:item_vault_0", "create:item_vault_1" },
  pointChargement      = { x = 1200, y = 95, z = -2600 },
  distanceChargement   = 24,      -- au-delà, le navire rentre avant de charger

  motifPaiement        = "chest", -- filtre de nom du coffre de paiement
  coffrePaiement       = nil,     -- nom imposé, prioritaire sur le filtre
  coffreReception      = nil,     -- nom imposé

  delaiPaiementMax     = 300,     -- 5 min, puis le navire repart et pénalise
  intervallePaiement   = 5,
  rappelPaiementToutes = 60,

  choixRetour  = "auto",          -- "auto" (le plus proche) | "manuel" (principal)
  pointsRetour = {
    { nom = "BASE-NORD", x = 1200, y = 95, z = -2600, principal = true, rayonSecurite = 32 },
    { nom = "RELAIS-EST", x = 4300, y = 88, z = 500, rayonSecurite = 32 },
  },

  facteurVitesseLente  = 0.6,     -- slow ship : fraction de vitesses.croisiere
  ravitaillerToutesLes = 0,       -- 0 = jamais ; la POSITION appartient au réseau

  limites = { maxLignes = 12, maxQuantite = 100000, maxPortee = 100000, fileMax = 20 },
}
```

`rayonSecurite` définit la zone dans laquelle le navire se considère **déjà rentré** : au redémarrage, il ne bouge pas s'il s'y trouve.

```lua
central = {
  identifiant   = "CENTRALE-01",   -- une grille venue d'ailleurs est ignorée
  jeton         = "...",           -- LE MÊME sur central, navires et bornes
  exigerCentral = false,           -- true : rien n'est accepté sans grille centrale
  delaiDemande  = 5,
},

penalites = {                      -- repli, tant que le central n'a rien diffusé
  mode = "prepaiement",            -- "prepaiement" | "refus"
  duree = 3600,
  incidentsAvantPenalite = 1,
  effacerApres = 86400,
},
```

### 5.4 Tarif — grille de repli seulement

**La grille qui fait foi est celle de l'ordinateur central** (§6). La page `tarif` ci-dessous n'est qu'un repli, appliqué tant qu'aucune grille centrale n'est arrivée. Dès la première diffusion du central, elle n'est plus consultée.

Le prix est calculé par la **même fonction** côté borne et côté navire, à partir de la même grille. Le chiffre affiché au client est donc exactement celui qui sera exigé à l'arrivée.

```
prix = plafond( ( forfaitBase + Σ (prixUnitaire(objet) × quantité) ) × coefficient(vitesse) )
```

```lua
tarif = {
  objetPaiement      = "minecraft:diamond",
  forfaitBase        = 5,
  prixUnitaireDefaut = 0.01,
  parObjet = {
    ["minecraft:netherite_ingot"] = 1.0,
    ["minecraft:cobblestone"]     = 0.002,
  },
  coefficientVitesse = { fast = 2.0, slow = 1.0 },
  prixMinimum = 1,
  prixMaximum = 2304,
}
```

**Le navire recalcule systématiquement le prix à bord.** La borne est publique : son chiffre ne fait pas foi. Un écart est journalisé et corrigé avant acceptation.

---

## 6. L'ordinateur central : les prix

Un seul ordinateur décide des prix. Ni la borne, qui est publique, ni le navire, qui se contente d'appliquer. C'est ce qui permet d'ouvrir une borne à tout le serveur sans ouvrir la caisse.

### 6.1 La serrure

Au premier démarrage, la centrale demande un code et n'en conserve qu'une **empreinte salée**, dans `central/code.dat`. Le code n'est écrit nulle part en clair.

| Réglage | Effet |
|---|---|
| `serrure.longueurMinimale` | longueur minimale du code (défaut 4) |
| `serrure.tentativesMax` | essais avant blocage (défaut 3) |
| `serrure.verrouillageSecondes` | durée du blocage après échecs (défaut 300) |
| `serrure.inactiviteSecondes` | reverrouillage automatique sans frappe (défaut 120) |

Chaque échec et chaque blocage sont inscrits au journal. Pendant un blocage, **la diffusion de la grille continue** : couper l'accès au menu n'arrête pas le commerce.

> Ce que la serrure fait : empêcher de lire le code en ouvrant les fichiers, et de forcer le menu par essais successifs. Ce qu'elle ne fait pas : protéger contre quelqu'un qui a accès physique à l'ordinateur et peut casser le disque ou remplacer le programme. **Fermez la pièce.**

### 6.2 Le menu

```
[1] Prix par objet          un prix unitaire par identifiant d'objet
[2] Reglages generaux       objet de paiement, forfait, coefficients, plafonds
[3] Penalites               mode, duree, seuil, oubli
[4] Diffuser la grille maintenant
[5] Changer le code d'acces
[V] Verrouiller
```

La liste des objets tarifables se remplit toute seule : les navires diffusent le catalogue de leur stockage source, la centrale les note. On peut aussi saisir un identifiant à la main (`a`).

L'écran d'édition d'un prix montre immédiatement l'effet du changement :

```
minecraft:iron_ingot
Prix unitaire actuel : 0.0200
Pour 1000 unites : slow 25 minecraft:diamond | fast 50 minecraft:diamond
```

### 6.3 La diffusion

Toute modification incrémente un numéro de séquence, écrit la grille sur disque et la diffuse immédiatement. Une diffusion périodique (`diffusionSecondes`, défaut 60) rattrape les machines qui viennent de redémarrer, et tout navire ou borne qui démarre réclame la grille par `TARIF_DEMANDE`.

Chaque grille porte une **signature** calculée sur son contenu, son numéro de séquence et le **jeton partagé** :

```lua
signature = empreinte( grille_canonisée .. "|" .. sequence .. "|" .. jeton )
```

Un destinataire refuse la grille si :

- elle se réclame d'un autre `central.identifiant` ;
- la signature ne correspond pas (contenu altéré, ou jeton différent) ;
- son numéro de séquence est **inférieur** à la dernière grille acceptée — c'est ce qui empêche de rejouer d'anciens prix après une hausse.

> **Ce que cette signature n'est pas.** Rednet n'authentifie personne, et l'empreinte utilisée n'est pas cryptographique. Qui peut lire le fichier de configuration d'une borne connaît le jeton et peut forger une grille. Cela arrête l'erreur de configuration, la trame corrompue et le rejeu ; cela n'arrête pas un joueur déterminé qui a déjà accès à vos ordinateurs.

### 6.4 Si la centrale se tait

| `central.exigerCentral` | Comportement du navire |
|---|---|
| `false` (défaut) | il applique la dernière grille reçue, ou la page `tarif` locale s'il n'en a jamais reçu — le commerce continue |
| `true` | il **refuse toute commande** tant qu'aucune grille centrale n'est arrivée — aucun risque de facturer au mauvais prix, mais la centrale devient un point de panne unique |

La dernière grille reçue est écrite dans l'état du navire : un redémarrage ne la perd pas, et le numéro de séquence mémorisé continue d'interdire le rejeu.

---

## 7. La borne de commande publique

Un ordinateur avancé, un modem, aucun privilège. Menu :

```
[1] Passer une commande
[2] Suivre / annuler mes commandes
[3] Consulter le catalogue
[4] Rafraichir l'etat du navire
```

### 7.1 Trois écrans de commande

1. **Objets et quantités** — catalogue paginé et filtrable, panier cumulatif, une ligne par type d'objet. Les quantités sont plafonnées par le stock réel et par `limites.maxQuantite`.
2. **Niveau de service** — le prix des deux options est affiché côte à côte :
   ```
   [1] fast ship  - livraison prioritaire  : 10 x minecraft:diamond
   [2] slow ship  - livraison economique   :  5 x minecraft:diamond
   ```
   `fast ship` passe devant les `slow ship` déjà en file, **jamais** devant une autre `fast ship` : le prix majoré achète une priorité, pas un passe-droit sur les clients qui l'ont déjà payée. Il vole aussi à la vitesse de croisière pleine, quand `slow ship` est transmis à `facteurVitesseLente`.
3. **Coordonnées de dépôt** — X, Y, Z saisis par le client, entiers, contrôlés contre `maxPortee` et les limites d'altitude.

### 7.2 Pré-paiement d'un client pénalisé

Quand le client saisi est sous pénalité (§9.1), la borne agit avant d'envoyer quoi que ce soit :

| Mode diffusé par le central | Ce que fait la borne |
|---|---|
| `refus` | elle refuse sur place, en annonçant la durée restante |
| `prepaiement` | elle réclame le montant **immédiatement**, dans son propre coffre |

En mode pré-paiement, l'écran affiche le coffre à remplir et décompte le temps restant (`prepaiement.delaiMax`, défaut 120 s). Dès que le compte y est, la borne encaisse — elle transfère le paiement dans `prepaiement.coffreRecette` — puis joint à la commande un certificat signé avec le jeton partagé :

```lua
prepaiement = {
  certifie = true, objet = "minecraft:diamond", quantite = 5,
  borne = 7, signature = "...",
}
```

Le navire vérifie cette signature, marque la commande comme déjà réglée et **ne redemande rien à l'arrivée**. Un certificat forgé sans le bon jeton est refusé.

Sans `prepaiement.coffreDepot` configuré, la borne ne peut pas encaisser : les clients pénalisés sont alors simplement refusés.

> **Limite assumée.** Le nom du client est du texte libre. Un joueur pénalisé peut en saisir un autre et repartir de zéro. Identifier réellement les joueurs demanderait un périphérique dédié (détecteur de joueur d'Advanced Peripherals, par exemple). En l'état, la pénalité dissuade et trace ; elle n'empêche pas un tricheur décidé.

### 7.3 Catalogue

La borne préfère le **stock local** si elle est câblée au stockage (`conteneursSourceLocaux`) : le catalogue reste alors juste même quand le navire est à l'autre bout de la carte. Sinon elle utilise celui que le navire transmet, et affiche le dernier connu s'il est injoignable.

Les tarifs, les limites et l'état viennent **toujours** du navire.

---

## 8. Manipulation des inventaires

Tout repose sur les deux fonctions officielles de l'API `inventory` de CC: Tweaked :

```lua
inventaire.pushItems(nomCible,  emplacementSource, [limite], [emplacementCible])
inventaire.pullItems(nomSource, emplacementSource, [limite], [emplacementCible])
```

Quatre points de la documentation dictent la forme du code :

1. **Les deux fonctions retournent le nombre d'objets réellement transférés**, qui peut être inférieur à la limite (cible pleine, pile maximale, filtre du conteneur). On boucle donc jusqu'à obtenir le compte voulu, et on s'arrête dès qu'un appel renvoie `0`.
2. **`limite` est plafonnée par la taille de pile** : un appel ne déplace jamais plus d'une pile. Vider 20 000 objets d'un *bulk container* Create demande des centaines d'appels — la boucle rend la main (`os.sleep(0)`) tous les 24 appels pour ne jamais déclencher `Too long without yielding`.
3. **Le premier argument est le nom réseau** du périphérique (`peripheral.getNames`), pas un côté ni un objet enveloppé. Les deux inventaires doivent être sur le **même réseau filaire**.
4. **`list()` renvoie une table creuse** indexée par emplacement : elle se parcourt avec `pairs()`, jamais `ipairs()`, sous peine de manquer tout ce qui suit un trou.

La logique de prélèvement — lister, filtrer par nom d'objet, transférer par lots, vérifier — suit la structure classique des tutoriels d'inventaire ComputerCraft (*Using Inventory Manager & Chest to dump inventory*, *Turtle Production Line — Retrieving Items From Chest*) : l'inventaire source est relu à chaque passe, ce qui rend le transfert correct même si des convoyeurs Create alimentent ou vident le conteneur pendant l'opération.

Garde-fous : 20 000 appels maximum par transfert, et arrêt immédiat dès qu'une passe complète ne déplace plus rien (source épuisée ou cible pleine).

**Repli automatique** : si `pushItems` échoue depuis la source — certains conteneurs modés le refusent — le transfert est retenté en `pullItems` depuis la cible, qui est l'opération symétrique.

---

## 9. Déroulement d'une mission

| Phase | Ce qui se passe |
|---|---|
| `REPOS` | au sol à un point de retour, en attente de commande |
| `CHARGEMENT` | purge des soutes, puis prélèvement **exact** dans le conteneur source |
| `TRANSIT_ALLER` | ordre de vol à l'autopilote, écoute de ses messages d'état |
| `ATTENTE_PAIEMENT` | vérification en boucle du coffre de paiement du client |
| `DEPOT` | aspiration du paiement, vidage complet des soutes chez le destinataire |
| `TRANSIT_RETOUR` | retour automatique au point de retour retenu |
| `RAVITAILLEMENT` | `ap.rejoindreRavitaillement()` : station fixe verrouillée par le réseau |

Chaque changement de phase est **écrit sur disque** (`navire/etat.dat`). Après un plantage, un rechargement de chunk ou un redémarrage du serveur, la mission reprend d'elle-même.

### 9.1 Paiement

À l'arrivée, le navire liste les inventaires visibles et retire les siens et ceux de la base : **ce qui reste appartient au client**. Il y repère le coffre de paiement (nom imposé, ou filtre `motifPaiement`, ou à défaut le premier), puis :

```
[INFO] [etape: verification du coffre de paiement] commande CMD-11-482913 : attente de 5 x minecraft:diamond dans 'minecraft:chest_3' (abandon apres 300 s)
[INFO] [etape: verification du coffre de paiement] paiement incomplet : 2 / 5 x minecraft:diamond (attente depuis 60 s)
[INFO] [etape: verification du coffre de paiement] paiement detecte : 5 x minecraft:diamond (exige 5) apres 184 s
[INFO] [etape: aspiration du paiement] paiement encaisse : 5 x minecraft:diamond
```

Le montant est aspiré dans un conteneur de rôle `recette` **avant** que la marchandise ne soit déposée, et la commande est marquée `paiementEncaisse`. Si le programme plante entre l'encaissement et le dépôt, la reprise **ne refait pas payer le client**.

#### La fenêtre de cinq minutes

`delaiPaiementMax` vaut **300 secondes** par défaut. Passé ce délai :

1. le navire **quitte la zone** — il ne reste pas indéfiniment exposé au-dessus d'une plateforme inconnue ;
2. la commande est annulée, un avis `ABANDON` est diffusé au client ;
3. la cargaison **revient avec lui** et est reversée au conteneur source dès l'arrivée à la base, pour que le catalogue reste juste et les soutes libres ;
4. le client est **pénalisé**.

`delaiPaiementMax = 0` rétablit l'attente illimitée. Déconseillé : le navire y reste bloqué et toute la file avec lui.

#### Les pénalités

Un incident est noté par client. Au-delà de `incidentsAvantPenalite` (défaut 1), la pénalité s'applique pour `duree` secondes. Un incident isolé resté sans récidive est oublié après `effacerApres`.

| Mode | Effet sur les commandes suivantes de ce client |
|---|---|
| `prepaiement` (défaut) | acceptées **seulement** avec un certificat de pré-paiement signé par une borne (§7.2) |
| `refus` | refusées jusqu'à expiration, avec la durée restante en motif |

Le régime est diffusé par le central avec la grille ; la page `penalites` locale n'est qu'un repli. Les fiches, elles, appartiennent au navire : elles sont écrites dans son état et survivent à un redémarrage, et il les diffuse dans son `ETAT` pour que les bornes sachent à quoi s'en tenir.

```
[AVERT] [etape: application d'une penalite client] 'Faction Rouge' penalise (1 incident(s), seuil 1) : mode prepaiement pendant 3600 s
```

### 9.2 Retour automatique

Dès que la file est vide, sans nouvel ordre :

- `choixRetour = "auto"` → le point de retour le **plus proche du dernier point de dépôt** ;
- `choixRetour = "manuel"` → celui marqué `principal = true` (repli automatique sur le plus proche s'il n'y en a pas).

S'il est déjà dans le `rayonSecurite` d'un point de retour, il ne bouge pas.

### 9.3 Au redémarrage

```
[INFO] [etape: verification de la position au demarrage] navire deja au point de securite 'BASE-NORD' (9 blocs du centre) : aucun deplacement
```

ou

```
[AVERT] [etape: verification de la position au demarrage] navire hors de tout point de securite (900 82 900) : rejoint le plus proche avant de reprendre
[INFO] [etape: verification de la position au demarrage] commande CMD-11-482913 remise en tete de file pour etre refaite integralement
```

Une commande interrompue **en vol** est remise en tête de file et refaite depuis le chargement (les soutes sont purgées vers le stock source au passage, rien n'est perdu). Une commande interrompue **au chargement** reprend là où elle en était : ce qui est déjà en soute est déduit du reste à charger.

---

## 10. Protocole rednet

Protocole : `frenchnet_livraison`. Enveloppe commune :

```lua
{ protocole = "FRENCHNET_LIVRAISON", version = 1, type = <TYPE>, navire = "DIRI-LIV-01", ... }
```

| Type | Sens | Contenu |
|---|---|---|
| `CATALOGUE_DEMANDE` | borne → navire | `force` |
| `CATALOGUE` | navire → borne | `articles`, `tarif`, `limites`, `etat` |
| `COMMANDE` | borne → navire | `commande` |
| `ACCUSE` | navire → borne | `commande`, `accepte`, `motif`, `rang`, `paiement` |
| `ANNULATION` | borne → navire | `commande` |
| `ETAT_DEMANDE` / `ETAT` | borne ↔ navire | `etat` |
| `AVIS` | navire → tous | `commande`, `evenement`, `message`, `client`, `penalite` |
| `TARIF_DEMANDE` | navire / borne → central | — |
| `TARIF` | central → tous | `tarif`, `penalites`, `sequence`, `signature`, `central` |

Événements diffusés : `DEPART`, `ATTENTE_PAIEMENT`, `PAIEMENT_INCOMPLET`, `LIVREE`, `ABANDON`, `ECHEC`.

L'`ETAT` du navire transporte aussi `tarifSequence`, `tarifCentral` (booléen), `penalites` (les fiches par client) et `regimePenalites` : c'est ce qui permet à une borne d'annoncer une pénalité avant même d'envoyer la commande.

Une commande :

```lua
{
  id          = "CMD-7-482913",
  client      = "Faction Rouge",
  vitesse     = "fast",                        -- "fast" | "slow"
  destination = { x = 400, y = 80, z = -250 },
  articles    = { { nom = "minecraft:iron_ingot", quantite = 2048 } },
  paiement    = { objet = "minecraft:diamond", quantite = 46 },
}
```

### 10.1 La borne est publique, donc suspecte

Tout ce qui arrive est revalidé à bord avant acceptation : structure, identifiant, nom de client, niveau de service, coordonnées entières et dans la portée, altitude plausible, nombre de lignes, quantités entières positives et plafonnées, volume total, **et prix recalculé**. Un message d'un autre protocole ou d'une autre version est ignoré sans réponse.

---

## 11. Journalisation et diagnostic

Format d'une ligne :

```
[2026-09-14 11:02:33] [ERREUR] [etape: chargement de la cargaison] stock insuffisant pour minecraft:iron_ingot : 12 disponible(s) pour 64 demande(s)
```

Niveaux : `DEBUG` < `INFO` < `AVERT` < `ERREUR` < `CRITIQUE`. `journal.niveauEcran` ne filtre que l'**écran** ; le fichier enregistre toujours tout, avec rotation vers `.log.1` à `tailleMax`.

Étapes journalisées : démarrage, chargement et validation de la configuration, chargement des modules, connexion à l'autopilote, détection du modem, ouverture rednet, reprise et sauvegarde de l'état, vérification de position au démarrage, calcul de position, choix du point de retour, réception et validation des commandes, lecture du catalogue, purge des soutes, chargement de la cargaison, vol vers le dépôt, détection des inventaires du destinataire, vérification et aspiration du paiement, dépôt, retour, ravitaillement, diffusion d'état, boucle principale, arrêt.

### Table de diagnostic

| Symptôme | Cause probable | Correctif |
|---|---|---|
| `AUCUN VOL POSSIBLE` | `/autopilote/autopilote.lua` absent | installer l'autopilote, ou corriger `autopilote.chemin` |
| `le module charge n'expose pas autopilote.nouveau()` | mauvais fichier chargé | vérifier `autopilote.chemin` |
| `autopilote.nouveau() a echoue` | configuration véhicule refusée par l'autopilote | lire le message : il nomme le champ fautif de `/autopilote/config_vehicule.lua` |
| `ordre refuse par l'autopilote` | point de passage invalide | vérifier les coordonnées de la commande ou du point de retour |
| `arrivee non confirmee : delai depasse` | trajet trop long, ou boucle de vol arrêtée | augmenter `autopilote.delaiArriveeMax`, vérifier le journal de l'autopilote |
| `position indisponible` | moins de 4 balises GPS à portée | vérifier la constellation FrenchNet et le `forceload` des chunks |
| `autopilote : ANOMALIE` | anomalie signalée par l'autopilote lui-même | son propre journal donne le détail |
| `le peripherique 'x' n'est pas un inventaire` | mauvais nom réseau | relire `peripheral.getNames()` |
| `aucun inventaire accessible au point de depot` | le client n'a pas de coffre relié | plateforme d'accueil + modem filaire |
| `quantite incomplete` au chargement | stock source insuffisant | réapprovisionner, ou commander moins |
| `%d objets n'ont pas pu etre deposes` | coffre de réception plein | agrandir le stockage du destinataire |
| `configuration vehicule absente` | l'autopilote n'est pas installé | installer `/autopilote/config_vehicule.lua`, ou indiquer son chemin |
| `configuration invalide` | page de livraison manquante | lire le CRITIQUE qui précède : il nomme le champ |
| `file d'attente pleine` | plus de `fileMax` commandes | augmenter la limite ou attendre |
| `grille tarifaire centrale indisponible` | `exigerCentral = true` et central muet | relancer la centrale, ou repasser `exigerCentral` à `false` |
| `signature invalide : jeton different ou grille alteree` | `jeton` différent d'une machine à l'autre | remettre le **même** jeton partout |
| `elle se reclame de 'X'` | `central.identifiant` ne correspond pas | aligner l'identifiant sur celui de la centrale |
| `grille perimee` | ancienne grille rejouée, ou centrale réinstallée à zéro | normal après un rejeu ; sinon effacer `navire/etat.dat` |
| `pre-paiement exige a la borne` | client sous pénalité en mode `prepaiement` | le client règle à la borne, ou attendre l'expiration |
| `certificat de pre-paiement invalide` | jeton différent sur la borne | remettre le même jeton |
| `cette borne n'est pas equipee pour encaisser` | `prepaiement.coffreDepot` non renseigné | brancher un coffre par modem filaire et le déclarer |
| `ACCES BLOQUE` sur la centrale | trois codes erronés | attendre `verrouillageSecondes` ; l'incident est au journal |

---

## 12. Tests

Un mini-émulateur CraftOS (`tests/craftos.lua`) rejoue le programme hors du jeu, avec horloge virtuelle, rednet, GPS, `parallel` et des **inventaires conformes au contrat de l'API `inventory`** (table creuse, une pile maximum par appel). Depuis la racine :

```
lua5.4 tests/test_livraison.lua
```

**138 vérifications** réparties en seize sections :

| Section | Couverture |
|---|---|
| A | validation des commandes publiques, tarification, distances |
| B | prélèvement exact sur un *bulk container* de 50 000 objets, stock restant intact, vidage, catalogue |
| C | livraison de bout en bout : chargement, vol, paiement, dépôt, retour — et vérification que le navire s'est placé pour que la soute tombe sur la cible |
| D | paiement déposé en retard : attente en boucle puis livraison |
| E | paiement jamais déposé : abandon au délai, cargaison reversée au stock, client pénalisé |
| F | autopilote absent : aucune commande engagée, stock intact |
| G | redémarrage hors zone de sécurité avec une commande en file |
| H | redémarrage déjà à un point de sécurité : aucun déplacement |
| I | commandes malveillantes ou malformées |
| J | priorité `fast ship` et tarification différenciée |
| K | configuration invalide : relance automatique à temporisation progressive |
| L | recouvrement facultatif : `navire/config_livraison.lua` a le dernier mot |
| M | grille centrale : adoption, signature fausse, grille étrangère, rejeu d'une ancienne grille, `exigerCentral` |
| N | pénalités : refus, pré-paiement exigé, certificat forgé rejeté, commande pré-payée livrée sans attente |
| O | borne publique : parcours complet d'une commande, du catalogue à l'accusé |
| P | centrale tarifaire : serrure, blocage après trois échecs, modification publiée, diffusion signée, code jamais en clair |

---

## 13. Notes techniques

- **Accents** : les chaînes affichées et journalisées sont volontairement sans accents. Le terminal de CC: Tweaked est orienté octet ; un caractère UTF-8 accentué y apparaîtrait sous forme de deux glyphes parasites. Les commentaires du code, jamais affichés, sont rédigés normalement.
- **Chargement des modules** : CC: Tweaked n'offre pas de `require` fiable hors `/rom/modules`. Chaque fichier est chargé explicitement par `load(source, nom, "t", _ENV)`, ce qui fonctionne sur toutes les versions et rend le code testable hors du jeu.
- **`xpcall`** : appelé via une fermeture plutôt qu'avec des arguments variadiques, forme qui n'existe qu'à partir de Lua 5.2.
- **Cession de la main** : tout transfert de gros volume appelle `os.sleep(0)` périodiquement. Sans cela, CC: Tweaked tue le programme sur `Too long without yielding`.
- **Concurrence** : boucle de vol de l'autopilote, serveur de commandes, machine à états, diffusion d'état et garde `terminate` tournent sous un même `parallel.waitForAny`. Une commande peut donc être reçue pendant un transfert ou un vol.
- **Arrêt propre avant relance** : le superviseur appelle `ap.arreter()` avant de relancer un cycle, sans quoi les moteurs resteraient sur leur dernière consigne.
- **Relance** : temporisation progressive 3 s → 6 s → 12 s… plafonnée à `redemarrageDelaiMax`. Le réseau est refermé proprement avant chaque relance. `startup.lua` redémarre l'ordinateur si le programme lui-même rend la main.
- **Arrêt volontaire** : `Ctrl+T` dépose `.arret_manuel` et empêche toute relance, tant que le fichier n'est pas supprimé. `robustesse.arretParTerminate = false` rend le navire insensible à `Ctrl+T`.
