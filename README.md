# FrenchNet — Livraison aérienne (CC: Tweaked)

Système de livraison automatisé embarqué sur un dirigeable **Create Aeronautics**, avec **borne de commande publique** ouverte à tous les joueurs et à toutes les factions d'**AERONAUTICS WARFARE**.

Le navire **ne pilote pas lui-même** : tout déplacement est délégué au **module d'autopilote FrenchNet** déjà construit, appelé tel quel, avec **son** fichier de configuration par véhicule — conteneurs compris, réglés dans sa propre interface. Ce dépôt n'ajoute que la logistique — commandes, cargaison, paiement, dépôt, retour automatique.

Les prix ne se décident nulle part ailleurs que sur **l'ordinateur central**, derrière un menu verrouillé par code, qui les diffuse signés aux bornes et aux navires.

## Ce que ça fait

1. L'opérateur fixe **un prix par objet** sur l'ordinateur central, derrière un code. Le central diffuse la grille signée ; bornes et navires l'appliquent sans jamais la modifier.
2. Un joueur ou une faction passe commande sur la borne publique : objets et quantités pris dans le grand conteneur source (y compris un *bulk container* Create de plusieurs dizaines de milliers d'objets), niveau de service **fast ship** (plus rapide, plus cher) ou **slow ship**, et coordonnées X/Y/Z exactes du point de dépôt.
3. Le navire prélève **exactement** ce qui est commandé avec `pushItems` / `pullItems`, sans toucher au reste du stock.
4. Il transmet le point de dépôt à l'autopilote (`ap.allerA`, point de type `"depot"`) et réagit à ses messages d'état.
5. À l'arrivée, il vérifie le **coffre de paiement** du client et attend le montant exact — **cinq minutes**, pas plus.
6. Payé : il vide la soute chez le destinataire. **Non payé au bout de cinq minutes : il repart**, la commande est annulée, la cargaison revient au stock et le client est **pénalisé** — ses commandes suivantes exigent un pré-paiement à la borne, ou sont refusées.
7. Une fois la file vide, il rentre **seul** au point de retour le plus pertinent, sans nouvel ordre.
8. En cas de plantage : relance automatique, reprise de l'état sur disque, et au redémarrage il reste sur place s'il est déjà à un point de sécurité, sinon il y va d'abord.

## Prérequis : l'autopilote

Le module d'autopilote et sa configuration véhicule doivent déjà être installés sur le calculateur embarqué :

```
/autopilote/autopilote.lua          -- le module de vol
/autopilote/config_vehicule.lua     -- la configuration DU VÉHICULE
/autopilote/ravitaillement.lua      -- la station de ravitaillement du réseau
```

Le réseau de balises GPS FrenchNet doit également être en place (quatre balises non alignées, à quatre altitudes différentes).

**Sans l'autopilote, le navire démarre, accepte et met en file les commandes, mais n'en engage aucune** — rien n'est chargé, rien ne décolle — et l'écrit en CRITIQUE dans le journal. C'est volontaire : un faux autopilote ferait « livrer » une cargaison restée à quai et encaisserait un paiement pour rien.

## Installation — navire

Sur le calculateur embarqué (1 ordinateur avancé + 1 modem Ender + modems filaires vers les soutes) :

```
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-delivery-system-xzg7ns/commun/journal.lua commun/journal.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-delivery-system-xzg7ns/commun/protocole.lua commun/protocole.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-delivery-system-xzg7ns/commun/inventaire.lua commun/inventaire.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-delivery-system-xzg7ns/navire/livraison.lua navire/livraison.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-delivery-system-xzg7ns/navire/autopilote.lua navire/autopilote.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-delivery-system-xzg7ns/navire/config_livraison.lua navire/config_livraison.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-delivery-system-xzg7ns/navire/startup.lua startup.lua
edit navire/config_livraison.lua
reboot
```

## Installation — ordinateur central

Sur un ordinateur avancé **dans un local fermé** (c'est lui qui fixe les prix) :

```
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-delivery-system-xzg7ns/commun/journal.lua commun/journal.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-delivery-system-xzg7ns/commun/protocole.lua commun/protocole.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-delivery-system-xzg7ns/central/central.lua central/central.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-delivery-system-xzg7ns/central/config_central.lua central/config_central.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-delivery-system-xzg7ns/central/startup.lua startup.lua
edit central/config_central.lua
reboot
```

Au premier démarrage, la centrale **demande un code** et n'en garde qu'une empreinte salée : il n'est écrit nulle part en clair. Notez-le.

Changez `jeton` dans les trois configurations (central, navire, borne) — **la même valeur partout**. Il signe la grille : une trame altérée, une grille venue d'ailleurs ou une ancienne grille moins chère rejouée sont refusées.

## Installation — borne publique

Sur un ordinateur avancé posé n'importe où, accessible à tous :

```
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-delivery-system-xzg7ns/commun/journal.lua commun/journal.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-delivery-system-xzg7ns/commun/protocole.lua commun/protocole.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-delivery-system-xzg7ns/commun/inventaire.lua commun/inventaire.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-delivery-system-xzg7ns/borne/borne.lua borne/borne.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-delivery-system-xzg7ns/borne/config_borne.lua borne/config_borne.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-delivery-system-xzg7ns/borne/startup.lua startup.lua
reboot
```

## Configuration

**Le fichier de configuration par véhicule est celui de l'autopilote**, `/autopilote/config_vehicule.lua`. Il porte déjà, et reste seul à porter : `nom`, `identifiant`, `decalageGps`, `decalageDepot`, `tolerances`, `vitesses`, `gabarit`, `gains` PID, la station `ravitaillement` — et désormais `conteneurs`.

### Les conteneurs se règlent dans l'autopilote

L'interface de l'autopilote a une section **Conteneurs** faite pour ça :

```
interface                    -- puis section "Conteneurs"
    D       détecter les inventaires branchés et créer une page pour chacun
    N       ajouter une page vierge
    Suppr   retirer celui sous le curseur
```

Pour chaque conteneur : `peripherique` (choisi dans la liste détectée), `role` — `expedition` (vidé chez le client), `recette` (reçoit le paiement), `tampon` (jamais livré) — `decalage` x/y/z par rapport au centre, `priorite`, `capacite`.

### Le reste

Le fichier `navire/config_livraison.lua` contient les **autres pages à ajouter** :

```lua
central   = { identifiant = "CENTRALE-01", jeton = "...", exigerCentral = false },
livraison = { ... },   -- source, paiement, points de retour, limites
penalites = { ... },   -- repli tant que le central ne s'est pas manifesté
tarif     = { ... },   -- repli, idem
```

Deux façons de les utiliser :

1. **Recommandé** — les recopier à la fin de la table de `/autopilote/config_vehicule.lua`. Tout tient dans un seul fichier par véhicule.
2. Ou laisser `navire/config_livraison.lua` en place : il est lu comme un **recouvrement** et ses valeurs l'emportent. Pratique quand plusieurs vaisseaux partagent la même grille tarifaire.

## Prérequis côté client (destinataire)

Le point de dépôt doit exposer au navire **au moins un inventaire** sur le réseau de modems filaires de la plateforme d'accueil :

| Coffre | Rôle | Détection |
|---|---|---|
| Coffre de paiement | le client y dépose le montant exact, **dans les cinq minutes** | nom contenant `motifPaiement` (défaut `chest`) |
| Coffre de réception | reçoit la marchandise | premier autre inventaire visible |

S'il n'y a qu'un seul coffre, il sert aux deux (le paiement est aspiré avant le dépôt). Sans aucun inventaire accessible, la livraison échoue proprement et le navire rentre avec la cargaison.

## Vérifier

```
lua5.4 tests/test_livraison.lua     -- 138 vérifications, hors du jeu
```

Le banc d'essai rejoue l'API réelle de l'autopilote (`nouveau`, `initialiser`, `allerA`, `attendreArrivee`, `etat`, `executer`), boucle de vol en parallèle comprise.

## En cas de problème

Le journal indique toujours l'étape exacte :

```
[2026-09-14 11:02:33] [ERREUR] [etape: chargement de la cargaison] stock insuffisant pour minecraft:iron_ingot : 12 disponible(s) pour 64 demande(s)
```

Consultable à l'écran ou dans `navire/livraison.log` (et `borne/borne.log`). L'autopilote tient son propre journal, séparément.

## Fichiers

| Fichier | Rôle |
|---|---|
| `navire/livraison.lua` | Programme embarqué : commandes, cargaison, paiement, dépôt, retour |
| `navire/autopilote.lua` | **Adaptateur** vers le module d'autopilote — aucune logique de vol |
| `navire/config_livraison.lua` | Pages à ajouter à la configuration du véhicule |
| `central/central.lua` | Centrale tarifaire : menu verrouillé par code, diffusion signée |
| `central/config_central.lua` | Configuration de la centrale |
| `central/startup.lua` | Démarrage automatique de la centrale |
| `navire/startup.lua` | Démarrage automatique du navire |
| `borne/borne.lua` | Borne de commande publique |
| `borne/config_borne.lua` | Configuration de la borne |
| `borne/startup.lua` | Démarrage automatique de la borne |
| `commun/journal.lua` | Journalisation par étape, avec rotation |
| `commun/protocole.lua` | Protocole rednet, validation des commandes, tarification |
| `commun/inventaire.lua` | `pushItems` / `pullItems`, transferts exacts, gros volumes |
| `tests/` | Émulateur CraftOS et banc d'essai hors du jeu |

📖 **[Guide complet](docs/guide-complet.md)** — raccordement de l'autopilote, format des messages, tarification, table de diagnostic, scénarios de panne.
