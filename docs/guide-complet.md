# FrenchNet — Balises GPS pour CC: Tweaked

Réseau de balises fixes pour le serveur **AERONAUTICS WARFARE** (carte ~50 000 blocs).

Chaque balise est un ordinateur CC: Tweaked équipé d'un **modem Ender** (portée illimitée) qui :

- diffuse en continu sa position **X, Y, Z** en broadcast rednet, à intervalle configurable ;
- porte un **identifiant unique** et signale tout doublon détecté sur le réseau ;
- sert d'**hôte GPS** natif (canal 65534) pour que les avions, turtles et tours de contrôle puissent utiliser `gps.locate()` ;
- **ne plante jamais** : chaque erreur est capturée, journalisée avec l'étape exacte où elle survient, puis le programme se réinitialise automatiquement ;
- **fonctionne sans intervention humaine** : relance automatique après erreur, redémarrage automatique après un reboot de l'ordinateur ou un rechargement de chunk.

---

## 1. Contenu du dépôt

| Fichier | Rôle | Où l'installer |
|---|---|---|
| `balise/balise.lua` | Programme principal de la balise | `/balise/balise.lua` sur chaque balise |
| `balise/config_balise.lua` | Configuration **propre à chaque balise** | `/balise/config_balise.lua` |
| `balise/startup.lua` | Lanceur automatique au démarrage | `/startup.lua` (racine) |
| `balise/recepteur.lua` | Moniteur de contrôle (optionnel) | Sur un poste de supervision |

---

## 2. Matériel requis par balise

- 1 ordinateur (**Computer** ou **Advanced Computer**) ;
- 1 **modem Ender** accolé à l'ordinateur (n'importe quelle face) ;
- le chunk de la balise doit être **maintenu chargé** (spawn chunks, chunk loader, ou `forceload add` côté serveur). Un ordinateur dans un chunk déchargé cesse d'émettre : c'est la cause n°1 de balise muette.

> Un modem sans fil ordinaire fonctionne, mais sa portée (quelques centaines de blocs) est très inférieure à l'espacement de 3 000–4 000 blocs prévu. Le programme détecte le cas et l'écrit en clair dans le journal.

---

## 3. Installation

### Méthode A — `wget` (si l'accès HTTP est activé sur le serveur)

Sur chaque ordinateur balise :

```
mkdir balise
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-gps-beacons-gv3cs5/balise/balise.lua balise/balise.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-gps-beacons-gv3cs5/balise/config_balise.lua balise/config_balise.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/cc-tweaked-gps-beacons-gv3cs5/balise/startup.lua startup.lua
edit balise/config_balise.lua      -- renseigner identifiant + coordonnées
reboot
```

### Méthode B — disquette (aucun accès réseau requis)

Copier les fichiers sur une disquette depuis un ordinateur déjà équipé, puis sur chaque balise :

```
mkdir balise
copy disk/balise.lua balise/balise.lua
copy disk/config_balise.lua balise/config_balise.lua
copy disk/startup.lua startup.lua
edit balise/config_balise.lua
reboot
```

### Méthode C — saisie manuelle

`edit balise/balise.lua`, coller le contenu, puis idem pour les deux autres fichiers.

---

## 4. Configuration

Tout se règle dans `balise/config_balise.lua`. Deux champs seulement doivent impérativement être adaptés sur chaque balise :

```lua
identifiant      = "BAL-01-NORD",                        -- unique sur tout le serveur
positionManuelle = { x = 1200, y = 210, z = -2600 },     -- coordonnées exactes du bloc
```

> **Relever les coordonnées** : touche `F3` en jeu, ligne **`Block:`** (et non `XYZ:`, qui donne la position du joueur avec des décimales).

### Pourquoi renseigner `positionManuelle` ?

Une balise est fixe : ses coordonnées sont connues d'avance. Les inscrire résout le problème de l'œuf et de la poule — `gps.locate()` a besoin de **4 hôtes GPS déjà opérationnels**, ce qui est impossible tant qu'aucune balise ne connaît sa position. C'est également la condition pour qu'une balise puisse servir d'hôte GPS aux avions.

Si `positionManuelle` est laissé à `nil`, la balise se localise via `gps.locate()` (utile pour une balise secondaire ajoutée après coup), rediffuse cette position, mais refuse alors de faire office d'hôte GPS — et le journal l'explique.

### Options principales

| Option | Défaut | Effet |
|---|---|---|
| `identifiant` | *(obligatoire)* | Identifiant unique de la balise |
| `designation` | `""` | Libellé libre (secteur, rôle) |
| `positionManuelle` | `nil` | Coordonnées exactes du bloc ordinateur |
| `intervalleSecondes` | `5` | Période de diffusion |
| `protocoleRednet` | `"frenchnet_balise"` | Protocole rednet (identique partout) |
| `coteModem` | `nil` | Face du modem ; `nil` = détection auto (Ender prioritaire) |
| `hoteGps` | `true` | Répondre aux `gps.locate()` des autres machines |
| `ecouterPairs` | `true` | Inventaire des voisines + alerte identifiant dupliqué |
| `verifierAvecGps` | `false` | Contrôle croisé position manuelle ↔ mesure GPS au démarrage |
| `rafraichirPositionToutes` | `300` | Re-mesure GPS périodique (mode GPS uniquement) |
| `erreursAvantReinit` | `5` | Échecs d'émission consécutifs avant réinitialisation réseau |
| `redemarrageDelaiMin` / `Max` | `3` / `60` | Temporisation progressive entre deux relances |
| `arretParTerminate` | `true` | `false` = `Ctrl+T` ignoré (autonomie totale) |
| `journalNiveauEcran` | `"INFO"` | `DEBUG` affiche chaque trame émise |
| `journalTailleMax` | `65536` | Rotation vers `balise.log.1` au-delà |
| `battementSecondes` | `60` | Périodicité du résumé d'état |

---

## 5. Plan de déploiement (4 balises minimum)

Pour que la trilatération GPS soit exacte, les balises ne doivent être **ni alignées, ni coplanaires** : quatre balises à la même altitude donnent une solution ambiguë en Y. Il faut donc quatre altitudes franchement différentes.

Exemple de constellation couvrant une carte de 50 000 blocs, chaque balise espacée de 3 000 à 4 000 blocs :

| Identifiant | X | Y | Z | Remarque |
|---|---|---|---|---|
| `BAL-01-NORD` | 1200 | **210** | -2600 | point haut |
| `BAL-02-EST` | 4300 | **95** | 500 | altitude moyenne |
| `BAL-03-SUD` | -800 | **140** | 3300 | |
| `BAL-04-OUEST` | -3500 | **60** | -400 | point bas |
| `BAL-05-ZENITH` | 500 | **250** | 300 | *(optionnel, améliore nettement la précision au centre)* |

Règles à respecter :

1. **Quatre balises minimum** en portée de tout point à couvrir ;
2. **quatre Y différents** (écart d'au moins 40–50 blocs) ;
3. pas de balise alignée avec deux autres sur un même axe ;
4. une cinquième balise centrale en altitude apporte une redondance appréciable si l'une tombe.

### Attention aux dimensions

Le modem Ender est **interdimensionnel**. Une balise placée dans le Nether ou l'End répondrait aux requêtes GPS de l'Overworld avec des coordonnées incohérentes et fausserait toutes les positions. Déployez **une constellation par dimension**, et n'y mélangez pas les balises.

---

## 6. Vérification après déploiement

Sur un ordinateur de contrôle muni d'un modem Ender :

```
recepteur
```

Affichage attendu :

```
CONSTELLATION FRENCHNET - protocole 'frenchnet_balise'
Recepteur : X=0 Y=64 Z=0
---------------------------------------------------
BAL-01-NORD      1200  210  -2600    2867m  1s GPS
BAL-02-EST       4300   95    500    4329m  1s
---------------------------------------------------
2 balise(s) active(s) / 2 connue(s) - Ctrl+T pour quitter
```

Une balise passée en `MUETTE` depuis plus de 30 s signale un chunk déchargé, un modem cassé ou un ordinateur arrêté.

Test de la fonction GPS elle-même, depuis n'importe quelle machine à portée :

```
gps locate
```

---

## 7. Journalisation et diagnostic

Chaque ligne du journal porte l'**étape exacte** où elle a été produite :

```
[2026-08-06 10:40:00] [INFO]   [etape: ouverture rednet] rednet ouvert, protocole 'frenchnet_balise'
[2026-08-06 10:40:00] [ERREUR] [etape: envoi rednet (broadcast)] erreur detectee a l'etape 'envoi rednet (broadcast)' : Network is unreachable [trace dans balise.log]
[2026-08-06 10:40:25] [AVERT]  [etape: demarrage du superviseur] redemarrage automatique n1 dans 3 seconde(s)
```

Le journal est écrit à l'écran **et** dans `balise/balise.log` (avec la pile d'appels complète, tronquée à l'écran pour rester lisible), avec rotation automatique vers `balise.log.1`.

### Table des étapes

| Étape journalisée | Cause probable | Action |
|---|---|---|
| `chargement de la configuration` | `config_balise.lua` absent ou syntaxe Lua invalide | Vérifier le fichier, virgules et accolades |
| `validation de la configuration` | `identifiant` manquant, intervalle < 1, position mal formée | Corriger la valeur indiquée dans le message |
| `detection du modem ender` | Modem absent, cassé, ou `coteModem` erroné | Reposer le modem, ou mettre `coteModem = nil` |
| `ouverture rednet` | Modem occupé ou face invalide | Redémarrer l'ordinateur |
| `resolution de la position GPS` | Moins de 4 hôtes GPS à portée | Renseigner `positionManuelle`, ou monter d'abord 4 balises |
| `ouverture du canal GPS` | Canal 65534 déjà utilisé | Redémarrer l'ordinateur |
| `envoi rednet (broadcast)` | Lien réseau rompu, modem arraché | Automatique : réinitialisation après 5 échecs |
| `reponse a une requete GPS` | Modem indisponible au moment de répondre | Automatique, sans conséquence |
| `surveillance du materiel (modem/rednet)` | Modem retiré ou rednet refermé en cours de route | Automatique : cycle complet relancé |
| `ecoute des balises voisines` | Trame malformée reçue | Ignorée, sans conséquence |
| `rafraichissement de la position` | Constellation momentanément indisponible | Dernière position connue conservée |
| `boucle principale (parallele)` | Une tâche s'est arrêtée | Automatique : redémarrage complet |

Message `CONFLIT D'IDENTIFIANT` : deux balises portent le même `identifiant`. Renommez-en une, sinon les récepteurs confondront leurs positions.

---

## 8. Comportement en cas de panne

| Situation | Réaction de la balise |
|---|---|
| Erreur d'envoi rednet isolée | Journalisée, émission suivante à l'heure |
| 5 échecs d'émission consécutifs | Réinitialisation complète : re-détection du modem, réouverture de rednet |
| Modem arraché en cours d'exploitation | Détecté sous 60 s, cycle relancé jusqu'à réapparition du modem |
| Erreur imprévue quelconque | Capturée, journalisée avec son étape, relance après 3 s → 6 s → 12 s… plafonnée à 60 s |
| Serveur redémarré / chunk rechargé | `startup.lua` relance la balise automatiquement |
| Sortie anormale du programme | `startup.lua` redémarre l'ordinateur après 15 s |
| `Ctrl+T` | Arrêt propre (ou ignoré si `arretParTerminate = false`) |

Aucune de ces situations ne demande d'intervention humaine.

---

## 9. Format du message diffusé

Chaque trame est une table Lua envoyée via `rednet.broadcast(message, "frenchnet_balise")` :

```lua
{
  protocole      = "FRENCHNET_BALISE",  -- filtre de sécurité
  version        = 1,                   -- version du protocole
  programme      = "1.0.0",
  identifiant    = "BAL-01-NORD",
  designation    = "Secteur nord - relais haute altitude",
  idOrdinateur   = 7,                   -- os.getComputerID() de la balise
  etiquette      = "BALISE-NORD",
  x = 1200, y = 210, z = -2600,
  positionSource = "manuelle",          -- "manuelle" ou "gps"
  hoteGps        = true,
  modemEnder     = true,
  intervalle     = 5,
  sequence       = 42,                  -- compteur de trames depuis le démarrage
  horodatageUtc  = 1754476800000,       -- os.epoch("utc")
  jourMonde      = 12,                  -- os.day()
  heureMonde     = 6.0,                 -- os.time()
  fonctionnement = 210,                 -- secondes depuis le démarrage du cycle
  erreursTotales = 0,
  redemarrages   = 0,
}
```

Le champ `sequence` permet de détecter les trames perdues, et `redemarrages` de repérer une balise instable.

### Côté client (avion, tour de contrôle)

```lua
rednet.open("back")  -- modem Ender

-- A) Se localiser grâce à la constellation
local x, y, z = gps.locate(5)

-- B) Suivre les balises en direct
while true do
  local id, msg = rednet.receive("frenchnet_balise", 10)
  if msg and msg.protocole == "FRENCHNET_BALISE" then
    print(("%s : %d %d %d"):format(msg.identifiant, msg.x, msg.y, msg.z))
  end
end
```

---

## 10. Tests

Le dépôt contient un mini-émulateur CraftOS (`tests/craftos.lua` : événements, minuteurs, `rednet`, `peripheral`, `gps`, `parallel`) qui permet de rejouer le programme hors du jeu, avec une horloge virtuelle. Depuis la racine du dépôt :

```
lua5.4 tests/test_balise.lua
```

49 vérifications couvrant le fonctionnement nominal, la panne réseau, le modem arraché, la configuration invalide ou absente, l'absence de constellation GPS, l'identifiant dupliqué, les deux modes d'arrêt et la rotation du journal.

---

## 11. Notes techniques

- **Accents** : les messages affichés et journalisés sont volontairement sans accents. Le terminal de CC: Tweaked est orienté octet ; un caractère UTF-8 accentué y apparaîtrait sous forme de deux glyphes parasites. Les commentaires du code, jamais affichés, sont eux rédigés normalement.
- **Compatibilité** : CC: Tweaked ≥ 1.89 (utilise `peripheral.hasType` quand disponible, avec repli automatique sur les versions antérieures).
- **Protocole GPS** : implémentation conforme au protocole natif (requête `"PING"` sur le canal 65534, réponse `{x, y, z}`), donc directement compatible avec l'API `gps` du jeu et avec les hôtes `gps host` classiques.
- **Charge réseau** : à `intervalleSecondes = 5`, cinq balises produisent 1 message par seconde sur l'ensemble du serveur — négligeable.
