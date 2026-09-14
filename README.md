# FrenchNet — Livraison aérienne (CC: Tweaked)

Système de livraison automatisé embarqué sur un dirigeable **Create Aeronautics**, avec **borne de commande publique** ouverte à tous les joueurs et à toutes les factions d'**AERONAUTICS WARFARE**.

Le navire **ne pilote pas lui-même** : tout déplacement est délégué au **module d'autopilote FrenchNet** déjà construit, appelé tel quel, avec **son** fichier de configuration par véhicule. Ce dépôt n'ajoute que la logistique — commandes, cargaison, paiement, dépôt, retour automatique.

## Ce que ça fait

1. Un joueur ou une faction passe commande sur la borne publique : objets et quantités pris dans le grand conteneur source (y compris un *bulk container* Create de plusieurs dizaines de milliers d'objets), niveau de service **fast ship** (plus rapide, plus cher) ou **slow ship**, et coordonnées X/Y/Z exactes du point de dépôt.
2. Le navire prélève **exactement** ce qui est commandé avec `pushItems` / `pullItems`, sans toucher au reste du stock.
3. Il transmet le point de dépôt à l'autopilote (`ap.allerA`, point de type `"depot"`) et réagit à ses messages d'état.
4. À l'arrivée, il vérifie le **coffre de paiement** du client et **attend en boucle** tant que le montant exact n'y est pas (par défaut 5 diamants).
5. Paiement encaissé, il vide la soute chez le destinataire.
6. Une fois la file vide, il rentre **seul** au point de retour le plus pertinent, sans nouvel ordre.
7. En cas de plantage : relance automatique, reprise de l'état sur disque, et au redémarrage il reste sur place s'il est déjà à un point de sécurité, sinon il y va d'abord.

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

**Le fichier de configuration par véhicule est celui de l'autopilote**, `/autopilote/config_vehicule.lua`. Il porte déjà, et reste seul à porter : `nom`, `identifiant`, `decalageGps`, `decalageDepot`, `tolerances`, `vitesses`, `gabarit`, `gains` PID, et la station `ravitaillement`. Rien de tout cela n'est dupliqué ici, et le système de livraison n'y touche jamais.

Le fichier `navire/config_livraison.lua` contient les **pages à ajouter** à cette configuration :

```lua
conteneurs = {                            -- une page par conteneur de cargaison
  { nom = "Soute avant", peripherique = "minecraft:barrel_0",
    decalage = { x = -4, y = -1, z = 6 }, -- par rapport au CENTRE du navire
    role = "expedition", priorite = 1 },
  { nom = "Coffre de recette", peripherique = "minecraft:chest_0",
    decalage = { x = 0, y = 1, z = 0 }, role = "recette" },
},
livraison = { ... },   -- source, paiement, points de retour, limites
tarif     = { ... },   -- grille publique fast ship / slow ship
```

Deux façons de les utiliser :

1. **Recommandé** — les recopier à la fin de la table de `/autopilote/config_vehicule.lua`. Tout tient dans un seul fichier par véhicule.
2. Ou laisser `navire/config_livraison.lua` en place : il est lu comme un **recouvrement** et ses valeurs l'emportent. Pratique quand plusieurs vaisseaux partagent la même grille tarifaire.

Rôles de conteneur : `expedition` (vidé chez le client), `recette` (où atterrit le paiement), `tampon` (jamais livré).

## Prérequis côté client (destinataire)

Le point de dépôt doit exposer au navire **au moins un inventaire** sur le réseau de modems filaires de la plateforme d'accueil :

| Coffre | Rôle | Détection |
|---|---|---|
| Coffre de paiement | le client y dépose le montant exact | nom contenant `motifPaiement` (défaut `chest`) |
| Coffre de réception | reçoit la marchandise | premier autre inventaire visible |

S'il n'y a qu'un seul coffre, il sert aux deux (le paiement est aspiré avant le dépôt). Sans aucun inventaire accessible, la livraison échoue proprement et le navire rentre avec la cargaison.

## Vérifier

```
lua5.4 tests/test_livraison.lua     -- 97 vérifications, hors du jeu
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
| `navire/startup.lua` | Démarrage automatique du navire |
| `borne/borne.lua` | Borne de commande publique |
| `borne/config_borne.lua` | Configuration de la borne |
| `borne/startup.lua` | Démarrage automatique de la borne |
| `commun/journal.lua` | Journalisation par étape, avec rotation |
| `commun/protocole.lua` | Protocole rednet, validation des commandes, tarification |
| `commun/inventaire.lua` | `pushItems` / `pullItems`, transferts exacts, gros volumes |
| `tests/` | Émulateur CraftOS et banc d'essai hors du jeu |

📖 **[Guide complet](docs/guide-complet.md)** — raccordement de l'autopilote, format des messages, tarification, table de diagnostic, scénarios de panne.
