# Notes d'API — ce qui existe réellement dans ce dépôt

**Document d'audit, produit avant toute écriture de code du Doomsday Ship.**
Rédigé en lisant le code, pas en le supposant. Chaque signature ci-dessous a été
relevée dans un fichier réel, à une ligne réelle.

Date de l'audit : au commit `5d7ee92`, branche `claude/frenchnet-command-defense-xm41dc`.
Méthode : inventaire de **toutes** les branches (`git ls-tree -r`), puis
`grep` sur `autopilot`, `fire_control`, `chaff`, `flare`, `balistique`, `ADS`,
`croisiere`, `HAL`.

---

## 1. Ce qui N'EXISTE PAS

Le cahier des charges suppose l'existence de cinq modules. **Quatre sont
absents du dépôt, sur toutes les branches.**

| Module supposé | Statut réel | Conséquence |
|---|---|---|
| **Autopilote embarqué** | **ABSENT** | Aucune API pour envoyer des waypoints |
| **FrenchNet Fire Control** (réseau) | **ABSENT** | Command lui *parle*, mais le destinataire n'existe pas ici |
| **FrenchNet Fire Control Embarqué** | **ABSENT** | Aucune API de sélection d'arme ni de tir |
| **ADS** (chaffs/flares) | **ABSENT** | Aucune API de contre-mesure |
| **Solveur balistique / HAL peripheral** | **ABSENT** | Aucun `hal` réutilisable, aucun solveur |
| **Missile de croisière** | **ABSENT** | — |

Les seules occurrences de « Fire Control » dans le dépôt sont les **protocoles
sortants de FrenchNet Command** (`command/config_command.lua:271`,
`command/command.lua:1234-1248`) : Command **émet vers** un Fire Control qui
n'est pas dans ce dépôt.

> **Ce que cela implique, sans détour.** Toute page du Doomsday Ship qui doit
> commander l'autopilote, tirer, ou larguer des contre-mesures ne peut PAS être
> intégrée aujourd'hui. Elle est écrite avec une **couture d'adaptation
> explicite** (`vaisseau/liaisons.lua`) qui journalise « module absent » au lieu
> de faire semblant. Dès que le module existe, une seule fonction est à écrire
> par intégration.

Si ces modules existent ailleurs — autre dépôt, disquette en jeu, autre
branche non poussée — il faut les rendre visibles ici avant de parler
d'intégration. Une API qu'on ne peut pas lire est une API qu'on invente.

---

## 2. Ce qui EXISTE et est réutilisable tel quel

Trois modules de FrenchNet Command **n'utilisent aucune API du jeu**. Ils sont
importables directement par l'ordinateur du ballon, sans adaptation.

### 2.1 `command/noyau.lua` — décision et IFF

C'est le module que la section 3.3 du cahier des charges demande de réutiliser
« sans le redévelopper ». Il est effectivement réutilisable **verbatim**.

```lua
local noyau = dofile("/vaisseau/noyau.lua")   -- copie de command/noyau.lua
```

**Constantes** (`command/noyau.lua`)

| Nom | Ligne | Valeur |
|---|---|---|
| `noyau.SEVERITE` | 37 | `{ CHARLIE=1, BRAVO=2, ALPHA=3, ROMEO=4 }` |
| `noyau.MODES` | 41 | `{ PAIX, GUERRE }` |
| `noyau.IFF` | 44 | `{ ALLIE, GENERAL, INCONNU }` |
| `noyau.CATEGORIES` | 48 | `{ INFANTERIE, VEHICULE_SOL, AERIENNE }` |
| `noyau.NATURES` | 51 | `{ JOUEUR, VEHICULE, ENTITE, MISSILE }` |
| `noyau.PALIERS` | 63 | `{ LIBRE=0, OBSERVATION=1, SCRAMBLE=2, DESTRUCTION=3 }` |
| `noyau.VERDICTS` | 75 | table de verdicts (`palier`, `suivi`, `feu`, `scramble`, `mobilisation`, `libelle`) |
| `noyau.TABLE_ENGAGEMENT` | 100 | `[classe][mode][iff] -> nom de verdict` |
| `noyau.IDENTIFICATION_RADAR` | 462 | `{ ALLIE, HOSTILE, NEUTRE, INCONNU }` |
| `noyau.CONCORDANCE` | 466 | `{ CONFIRME, PARTIEL, DISCORDANT, AUCUNE }` |
| `noyau.CATEGORIES_FIRE_CONTROL` | 831 | `{ AERIENNE="Aerial", VEHICULE_SOL="GroundVehicle", INFANTERIE="Infantry" }` |
| `noyau.RESULTATS_KILL` | 955 | `{ CONFIRME, EN_ATTENTE, AUCUN_SIGNAL, PERDU }` |

**Fonctions** — signatures relevées, pas supposées

```lua
noyau.ordonnerCoins(points)                                   -- 180
noyau.pointDansPolygone(points, x, z)                         -- 197
noyau.pointDansZone(zone, x, y, z)                            -- 218
noyau.zonePourPoint(zones, x, y, z)                           -- 273
    --> classe, zone, chevauchees
noyau.categoriser(contact, config, zone, solConnu)            -- 308
    --> categorie, motif
noyau.statutIff(transpondeur, codes, maintenant, config, allieManuel)  -- 365
    --> iff, motif
noyau.identifierParRadar(contact, roster, config)             -- 492
    --> statut, motif
noyau.identifier(contact, transpondeur, codes, roster, maintenant, config, allieManuel)  -- 574
    --> iff, motif, detail{ transpondeur, radar, concordance, alerte }
noyau.verdict(classeZone, mode, statutIff, alerteMax, config) -- 663
    --> nomVerdict, verdict, motif
noyau.designer(plateformes, cible, config)                    -- 739
    --> candidats, rejetes
noyau.scrambleRequiertControleur(role, categorie, config, manuel)  -- 868
noyau.verbePourOrdre(role, categorie, config)                 -- 876
noyau.formaterOrdre(role, nomPlateforme, categorie, config)   -- 887
noyau.planifier(verdict, candidats)                           -- 902
noyau.evaluerDestruction(piste, evaluation, config, maintenant)  -- 979
noyau.validerZone(zone)                                       -- 1053
```

> **Il n'existe PAS d'« API IFF exposée » au sens d'un service réseau.** L'IFF
> est une **bibliothèque locale**. Le ballon doit donc l'appeler lui-même, avec
> ses propres codes et son propre roster — ou interroger le poste au sol par
> rednet, ce qui n'existe pas encore comme protocole. Voir §4.

### 2.2 `command/carte.lua` — projection et symbologie

Réutilisable pour la page Carte et la page SA/EW. Aucune API du jeu.

```lua
carte.nouvelle(config)                                        -- 131
carte.echelle(vue) / carte.zoomer(vue, sens)                  -- 148 / 150
carte.deplacer(vue, colonnes, lignes)                         -- 160
carte.centrer(vue, x, z, suivi)                               -- 169
carte.versEcran(vue, x, z, largeur, hauteur)  --> col, ligne, visible   -- 182
carte.versMonde(vue, col, ligne, largeur, hauteur) --> x, z   -- 190
carte.etendue(vue, largeur, hauteur)                          -- 198
carte.rasteriserZones(vue, largeur, hauteur, zones, noyau, altitudeSonde)  -- 258
carte.rasterCache(cache, vue, largeur, hauteur, zones, noyau, versionZones, altitudeSonde)  -- 308
carte.pisteSous(pistes, vue, col, ligne, largeur, hauteur, tolerance)  -- 333
carte.pisteLaPlusDangereuse(pistes, origine)                  -- 361
carte.appliquerSuivi(vue, pistes, poste, largeur, hauteur)    -- 383
carte.glyphe(piste) / carte.couleurContact(piste) / carte.symbole(piste)  -- 78 / 98 / 113
carte.ECHELLES = { 2,4,8,16,32,64,128,256,512,1024 }          -- 26
```

### 2.3 `command/terrain.lua` — modèle de terrain observé

```lua
terrain.nouveau(config)                                       -- 65
terrain.echantillonner(modele, x, y, z, source, instant, avecMotif)  -- 159
terrain.hauteurSol(modele, x, z, avecMotif) --> altitude, confiance, motif  -- 210
terrain.evaluerContact(modele, contact, config, zone)         -- 275
terrain.contactEstUneSonde(piste, config)                     -- 303
terrain.exporter(modele) / terrain.importer(modele, donnees)  -- 340 / 348
terrain.statistiques(modele)                                  -- 386
```

### 2.4 `command/scanner.lua` — adaptateur radar

Utile au ballon s'il porte son propre radar. **Détecte par méthode, pas par nom
de type** — c'est ce qui le rend insensible au nommage du mod.

```lua
scanner.detecter(peripheriques, nomForce)
    --> radar, nom, methodesActives, motif, inventaire        -- 196
scanner.inventaire(peripheriques)                             -- 136
scanner.typesDe(peripheriques, nom) / scanner.methodesDe(peripheriques, nom)  -- 105 / 115
scanner.collecter(radar, methodesActives, proteger)           -- 343
scanner.normaliser(bruts, positionRadar, relatives) --> contacts, ignores  -- 402
scanner.deduireReferentiel(bruts, positionRadar, portee)      -- 366
scanner.positionEcho / natureEcho / identifiantEcho / nomEcho / metaEcho  -- 251+
scanner.METHODES     -- 63 : ~20 noms de méthode de balayage reconnus
scanner.NATURES      -- 26 : { JOUEUR, VEHICULE, ENTITE, MISSILE }
```

---

## 3. Protocoles rednet réellement en service

Relevés dans le code émetteur et le code récepteur. Ce sont les **seuls**
protocoles FrenchNet existants.

| Protocole rednet | Sens | Émis par | Reçu par |
|---|---|---|---|
| `frenchnet_radar` | station → poste | `radar/radar.lua:355` | `command/command.lua:2081` |
| `frenchnet_lanceur` | lanceur → poste | `lanceur/lanceur.lua` | `command/command.lua:2086` |
| `frenchnet_transpondeur` | véhicule → poste | `command/transpondeur.lua` | `command/command.lua:2062` |
| `frenchnet_annonce` | poste → tous | `command/command.lua:2166` | stations, lanceurs |
| `frenchnet_fire_control` | poste → Fire Control **et** inventaire en retour | `command/command.lua:1234` | `command/command.lua:2123` |
| `frenchnet_roster` | pont OPAC → poste | *(pont externe, absent)* | `command/command.lua:2134` |
| `frenchnet_balise` | balise GPS → tous | `balise/balise.lua` | `balise/recepteur.lua` |

### 3.1 Trame de station radar — `frenchnet_radar`

```lua
{
  protocole = "FRENCHNET_RADAR", version = 1,
  station = "RAD-01-NORD", designation = "Secteur nord",
  x = , y = , z = ,            -- position de la station, absolue
  portee  = 512,               -- sert à l'enveloppe fiable de confirmation
  contacts = {
    { id     = "ID:42" | "NOM:Raider-7" | nil,
      nom    = "Raider-7" | nil,
      nature = "JOUEUR" | "VEHICULE" | "ENTITE" | "MISSILE",
      meta   = { proprietaire=, equipe=, typeExact=, sante=, taille= } | nil,
      x = , y = , z = },       -- ABSOLU, déjà converti par la station
    ...
  },
}
```

**C'est ce format que le ballon doit produire** s'il veut alimenter le poste au
sol avec ses propres contacts radar (section 6 du cahier des charges).

### 3.2 Trame de balise de lanceur — `frenchnet_lanceur`

```lua
{ protocole = "FRENCHNET_LANCEUR", version = 1,
  nom = "AirShip1", designation = ,
  x = , y = , z = , portee = ,
  munitions = , munitionsMax = , tirs = , disponible = <bool>,
  categories = { "AERIENNE", ... } | nil }
```

### 3.3 Transpondeur — `frenchnet_transpondeur`

```lua
{ protocole = "FRENCHNET_TRANSPONDEUR",
  identifiant = <nom>, nom = <nom>, code = <string>,
  x = , y = , z = }
```

**Le ballon doit émettre cette trame**, sans quoi le poste au sol le classera
INCONNU — avec les conséquences prévues par la doctrine de zone.

### 3.4 Annonce du poste — `frenchnet_annonce`

```lua
{ protocole = "FRENCHNET_COMMAND_ICI", version = 1, identifiant = "CMD-01" }
```

Émise toutes les 30 s. L'écouter permet au ballon de connaître le numéro
d'ordinateur du poste et de lui parler en direct plutôt qu'en diffusion.

### 3.5 Ordres vers Fire Control — `frenchnet_fire_control`

Le message est **une chaîne**, pas une table :

```
"<Plateforme> <Verbe> type <Categorie>"

Verbes     : Fire | Scramble | Scramble AG
Categories : Aerial | GroundVehicle | Infantry
Exemples   : "SAM-Est Fire type Aerial"
             "Appui-1 Scramble AG type GroundVehicle"
```

Une table compagnon n'est émise que si `envoyerDetails = true` :

```lua
{ protocole = "FRENCHNET_COMMAND", version = 1, emetteur = , ordre = <chaine>,
  role = "FIRE"|"SCRAMBLE", plateforme = , categorie = , verdict = ,
  cible = { id, nom, x, y, z }, zone = , mode = , alerteMax = }
```

**Sens inverse** (inventaire des plateformes, même protocole) :

```lua
{ plateformes = { { nom, x, y, z, tirs, disponible, portee, munitions, categories }, ... } }
```

### 3.6 Roster de factions — `frenchnet_roster`

```lua
{ roster = { ["Pseudo"] = { faction = "FRANCE", hostilite = "ALLIEE"|"HOSTILE" } } }
```

Le **pont Open Parties and Claims qui produit cette trame n'existe pas** : OPAC
n'est pas lisible depuis CC: Tweaked. À écrire côté serveur.

---

## 4. Intégrations demandées : état réel

| Demande du cahier des charges | Faisable aujourd'hui ? |
|---|---|
| Framework MFD, fenêtres, pages | **Oui** — API CC: Tweaked pure |
| Page Carte / rendu | **Oui** — `carte.lua` réutilisable |
| Envoi de waypoints à l'autopilote | **Non** — module absent |
| Pages Propulsion / Portance | **Rendu oui, données non** — API Create Aeronautics inconnue |
| IFF « réutiliser FrenchNet Command » | **Oui**, en bibliothèque locale (`noyau.lua`), pas en service réseau |
| Liaison FrenchNet (position + contacts) | **Oui** — protocoles §3.1 et §3.3 documentés |
| Sélection d'arme / tir | **Non** — Fire Control Embarqué absent |
| Chaffs / flares | **Non** — ADS absent |
| Inventaire armement | Structure oui, alimentation non (dépend du Fire Control Embarqué) |
| Relais musique HTTP | **À vérifier sur le serveur** — voir §5 |

### Le même piège que Create Radars, et il n'est pas théorique

Les pages Propulsion et Portance lisent des périphériques de Create Aeronautics
dont **je ne connais pas l'API**. Ce dépôt a déjà payé cette erreur une fois :
la détection radar cherchait un périphérique dont le *type* contenait « radar »,
et ne trouvait rien parce que le mod le nomme autrement.

La leçon est appliquée d'emblée : `vaisseau/hal.lua` détecte **par méthode**, et
`vaisseau/diagnostic.lua` affiche les périphériques réels du ballon, leurs types,
leurs méthodes et un échantillon de leurs valeurs. **Lancez-le avant tout
réglage** et reportez sa sortie : c'est ce qui permettra d'écrire les vraies
lectures au lieu de les deviner.

---

## 5. Requêtes HTTP sortantes — à vérifier

Le module musique (section 5 du cahier des charges) exige `http.get` / `http.post`
depuis l'ordinateur du jeu. Cela dépend de la configuration du serveur :

```
# config/computercraft-server.toml
[http]
    enabled = true
    [[http.rules]]
        host = "<hôte du relais>"
        action = "allow"
```

Test en jeu, une ligne :

```lua
print(http and "HTTP disponible" or "HTTP DESACTIVE")
```

Si `http` est `nil`, **tout le module musique est bloqué** et doit être remplacé
par un simple affichage « now playing » alimenté par le relais via rednet — ou
supprimé. C'est une décision d'administrateur serveur, pas de code.

---

## 6. Ce que la Phase 1 livre, et ce qu'elle ne livre pas

**Livré** : framework MFD complet (détection à chaud, sous-fenêtres, registre de
pages, layout persisté), HAL de découverte, diagnostic, pages Propulsion,
Portance/Enveloppe et Carte/Waypoints, magasin de waypoints persisté.

**Non livré, et pourquoi** : l'envoi des waypoints à l'autopilote (module
absent), les valeurs réelles de propulsion et de portance (API du mod inconnue —
le diagnostic est l'outil qui les révélera). Les pages affichent
« donnée indisponible » plutôt qu'un chiffre inventé.
