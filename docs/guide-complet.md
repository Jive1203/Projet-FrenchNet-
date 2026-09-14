# FrenchNet — Livraison aérienne : guide complet

Système de livraison automatisé et réutilisable pour dirigeable **Create Aeronautics**, sous **CC: Tweaked**, avec interface de commande publique ouverte à tous les joueurs et à toutes les factions d'**AERONAUTICS WARFARE**.

---

## 1. Principe et périmètre

Le navire **ne vole pas tout seul** : il **appelle** le module d'autopilote standardisé déjà construit et déjà réglé, et se contente de **réagir à ses messages d'état**. Ce dépôt ne contient :

- **aucune** boucle d'asservissement d'altitude ;
- **aucune** boucle d'asservissement de cap ;
- **aucun** PID ;
- **aucune** commande de moteur ou de gouverne.

Il contient la logistique : file de commandes publiques, prélèvement dans le stockage source, vol commandé, encaissement, dépôt, retour automatique, supervision.

Le réseau de balises GPS FrenchNet est supposé en place : le navire utilise `gps.locate()`, donc la constellation de quatre balises non alignées et à altitudes différentes est un prérequis.

```
   BORNE PUBLIQUE                NAVIRE                     AUTOPILOTE
   (tout le monde)               (ce dépôt)                 (déjà construit)
        |                           |                             |
        |--- COMMANDE ------------->|                             |
        |<-- ACCUSE ----------------|                             |
        |                           |--- ap.allerA(point) ------->|
        |                           |<-- "etape" / "arrivee" -----|
        |                           |<-- "anomalie" --------------|
        |<-- ETAT / AVIS -----------|                             |
                                    |                             |
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
| `navire/startup.lua` | Lanceur automatique, ultime filet de sécurité au-dessus du superviseur interne. |
| `borne/borne.lua` | Borne de commande publique (catalogue, panier, niveau de service, coordonnées, suivi). |
| `borne/config_borne.lua` | Configuration de la borne. |
| `commun/journal.lua` | Journal horodaté, étiqueté par étape, avec rotation de fichier. |
| `commun/protocole.lua` | Enveloppe rednet, validation des commandes, tarification, distances. |
| `commun/inventaire.lua` | `pushItems` / `pullItems`, transferts exacts, catalogue, gros volumes. |
| `tests/craftos.lua` | Mini-émulateur CraftOS, inventaires compris. |
| `tests/test_livraison.lua` | 97 vérifications, nominal et pannes, API réelle de l'autopilote comprise. |

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

  delaiPaiementMax     = 0,       -- 0 = attente illimitée
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

### 5.4 Tarif

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

## 6. La borne de commande publique

Un ordinateur avancé, un modem, aucun privilège. Menu :

```
[1] Passer une commande
[2] Suivre / annuler mes commandes
[3] Consulter le catalogue
[4] Rafraichir l'etat du navire
```

### 6.1 Trois écrans de commande

1. **Objets et quantités** — catalogue paginé et filtrable, panier cumulatif, une ligne par type d'objet. Les quantités sont plafonnées par le stock réel et par `limites.maxQuantite`.
2. **Niveau de service** — le prix des deux options est affiché côte à côte :
   ```
   [1] fast ship  - livraison prioritaire  : 10 x minecraft:diamond
   [2] slow ship  - livraison economique   :  5 x minecraft:diamond
   ```
   `fast ship` passe devant les `slow ship` déjà en file, **jamais** devant une autre `fast ship` : le prix majoré achète une priorité, pas un passe-droit sur les clients qui l'ont déjà payée. Il vole aussi à la vitesse de croisière pleine, quand `slow ship` est transmis à `facteurVitesseLente`.
3. **Coordonnées de dépôt** — X, Y, Z saisis par le client, entiers, contrôlés contre `maxPortee` et les limites d'altitude.

### 6.2 Catalogue

La borne préfère le **stock local** si elle est câblée au stockage (`conteneursSourceLocaux`) : le catalogue reste alors juste même quand le navire est à l'autre bout de la carte. Sinon elle utilise celui que le navire transmet, et affiche le dernier connu s'il est injoignable.

Les tarifs, les limites et l'état viennent **toujours** du navire.

---

## 7. Manipulation des inventaires

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

## 8. Déroulement d'une mission

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

### 8.1 Paiement

À l'arrivée, le navire liste les inventaires visibles et retire les siens et ceux de la base : **ce qui reste appartient au client**. Il y repère le coffre de paiement (nom imposé, ou filtre `motifPaiement`, ou à défaut le premier), puis :

```
[INFO] [etape: verification du coffre de paiement] commande CMD-11-482913 : attente de 5 x minecraft:diamond dans 'minecraft:chest_3' (attente illimitee)
[INFO] [etape: verification du coffre de paiement] paiement incomplet : 2 / 5 x minecraft:diamond (attente depuis 60 s)
[INFO] [etape: verification du coffre de paiement] paiement detecte : 5 x minecraft:diamond (exige 5) apres 184 s
[INFO] [etape: aspiration du paiement] paiement encaisse : 5 x minecraft:diamond
```

Le montant est aspiré dans un conteneur de rôle `recette` **avant** que la marchandise ne soit déposée, et la commande est marquée `paiementEncaisse`. Si le programme plante entre l'encaissement et le dépôt, la reprise **ne refait pas payer le client**.

`delaiPaiementMax = 0` fait attendre indéfiniment, comme demandé. Une valeur non nulle fait abandonner la commande, avec un avis diffusé et un retour à la base — la cargaison repart avec le navire.

### 8.2 Retour automatique

Dès que la file est vide, sans nouvel ordre :

- `choixRetour = "auto"` → le point de retour le **plus proche du dernier point de dépôt** ;
- `choixRetour = "manuel"` → celui marqué `principal = true` (repli automatique sur le plus proche s'il n'y en a pas).

S'il est déjà dans le `rayonSecurite` d'un point de retour, il ne bouge pas.

### 8.3 Au redémarrage

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

## 9. Protocole rednet

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
| `AVIS` | navire → tous | `commande`, `evenement`, `message` |

Événements diffusés : `DEPART`, `ATTENTE_PAIEMENT`, `PAIEMENT_INCOMPLET`, `LIVREE`, `ABANDON`, `ECHEC`.

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

### 9.1 La borne est publique, donc suspecte

Tout ce qui arrive est revalidé à bord avant acceptation : structure, identifiant, nom de client, niveau de service, coordonnées entières et dans la portée, altitude plausible, nombre de lignes, quantités entières positives et plafonnées, volume total, **et prix recalculé**. Un message d'un autre protocole ou d'une autre version est ignoré sans réponse.

---

## 10. Journalisation et diagnostic

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

---

## 11. Tests

Un mini-émulateur CraftOS (`tests/craftos.lua`) rejoue le programme hors du jeu, avec horloge virtuelle, rednet, GPS, `parallel` et des **inventaires conformes au contrat de l'API `inventory`** (table creuse, une pile maximum par appel). Depuis la racine :

```
lua5.4 tests/test_livraison.lua
```

**97 vérifications** réparties en treize sections :

| Section | Couverture |
|---|---|
| A | validation des commandes publiques, tarification, distances |
| B | prélèvement exact sur un *bulk container* de 50 000 objets, stock restant intact, vidage, catalogue |
| C | livraison de bout en bout : chargement, vol, paiement, dépôt, retour — et vérification que le navire s'est placé pour que la soute tombe sur la cible |
| D | paiement déposé en retard : attente en boucle puis livraison |
| E | paiement jamais déposé : abandon au délai, cargaison conservée, retour |
| F | autopilote absent : aucune commande engagée, stock intact |
| G | redémarrage hors zone de sécurité avec une commande en file |
| H | redémarrage déjà à un point de sécurité : aucun déplacement |
| I | commandes malveillantes ou malformées |
| J | priorité `fast ship` et tarification différenciée |
| K | configuration invalide : relance automatique à temporisation progressive |
| L | recouvrement facultatif : `navire/config_livraison.lua` a le dernier mot |
| M | borne publique : parcours complet d'une commande, du catalogue à l'accusé |

---

## 12. Notes techniques

- **Accents** : les chaînes affichées et journalisées sont volontairement sans accents. Le terminal de CC: Tweaked est orienté octet ; un caractère UTF-8 accentué y apparaîtrait sous forme de deux glyphes parasites. Les commentaires du code, jamais affichés, sont rédigés normalement.
- **Chargement des modules** : CC: Tweaked n'offre pas de `require` fiable hors `/rom/modules`. Chaque fichier est chargé explicitement par `load(source, nom, "t", _ENV)`, ce qui fonctionne sur toutes les versions et rend le code testable hors du jeu.
- **`xpcall`** : appelé via une fermeture plutôt qu'avec des arguments variadiques, forme qui n'existe qu'à partir de Lua 5.2.
- **Cession de la main** : tout transfert de gros volume appelle `os.sleep(0)` périodiquement. Sans cela, CC: Tweaked tue le programme sur `Too long without yielding`.
- **Concurrence** : boucle de vol de l'autopilote, serveur de commandes, machine à états, diffusion d'état et garde `terminate` tournent sous un même `parallel.waitForAny`. Une commande peut donc être reçue pendant un transfert ou un vol.
- **Arrêt propre avant relance** : le superviseur appelle `ap.arreter()` avant de relancer un cycle, sans quoi les moteurs resteraient sur leur dernière consigne.
- **Relance** : temporisation progressive 3 s → 6 s → 12 s… plafonnée à `redemarrageDelaiMax`. Le réseau est refermé proprement avant chaque relance. `startup.lua` redémarre l'ordinateur si le programme lui-même rend la main.
- **Arrêt volontaire** : `Ctrl+T` dépose `.arret_manuel` et empêche toute relance, tant que le fichier n'est pas supprimé. `robustesse.arretParTerminate = false` rend le navire insensible à `Ctrl+T`.
