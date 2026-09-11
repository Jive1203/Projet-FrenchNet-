# Mise à jour automatique — FrenchNet

Un seul dépôt, plusieurs ordinateurs dans le monde, souvent dans des chunks
forceloaded qu'on ne visite jamais. Ce système les tient à jour sans aller les
chercher à pied.

---

## À lire avant d'activer quoi que ce soit

> **Une mise à jour automatique est un canal d'exécution de code à distance
> vers chaque ordinateur du serveur.** Quiconque contrôle la source contrôle le
> poste de commandement.

Il n'y a **ni signature ni chiffrement** : CC: Tweaked n'offre aucune primitive
cryptographique utilisable pour cela. La somme de contrôle détecte un
téléchargement **tronqué**, pas un attaquant. Le module le dit dans son
en-tête plutôt que de laisser croire le contraire.

Ce qui est réellement protégé, et qui est le risque le plus **probable** :

| Risque | Protection |
|---|---|
| Commit cassé, réponse HTML d'un proxy, coupure | le fichier est **compilé avant d'être écrit** ; du Lua invalide n'atteint jamais le disque |
| Coupure au milieu d'un lot | tout est préparé **à côté**, puis basculé d'un bloc — jamais une version à moitié installée |
| Version fautive installée | **sauvegarde + `update restaurer`**, et retour arrière automatique si un fichier ne se recharge pas |
| Redémarrage en plein engagement | **verrou d'occupation** : la bascule est reportée, pas annulée |
| Somme qui ne se stabilise jamais | **garde anti-boucle** : l'installation se suspend au lieu de redémarrer sans fin |
| Configurations écrasées | `siAbsent` : une config existante n'est **jamais** remplacée |

**Si ce poste commande des armes**, le réglage prudent est `automatique = false` :
les mises à jour sont téléchargées, vérifiées et préparées, mais installées
seulement quand vous tapez `update appliquer`.

---

## Installation

Sur chaque ordinateur, une fois :

```
mkdir maj
wget <depot>/maj/maj.lua           maj/maj.lua
wget <depot>/maj/update.lua        maj/update.lua
wget <depot>/maj/config_maj.lua    maj/config_maj.lua
edit maj/config_maj.lua            -- au minimum : poste = "..."
update verifier
```

Ensuite le système s'entretient seul : `startup.lua` lance `update` avant le
poste, à chaque démarrage.

### Réglage minimal

```lua
poste   = "command",   -- command | radar | lanceur | balise | vaisseau | transpondeur
urlBase = "https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/<branche>",
```

> **Attention à la branche.** Ce dépôt n'a pas de branche `main`. L'URL par
> défaut pointe la branche de développement : si vous fusionnez ailleurs,
> changez-la, sinon les postes suivront une branche qui bouge sous leurs pieds.

L'administrateur du serveur doit autoriser l'hôte dans
`config/computercraft-server.toml`. `diagnostic` section 5 dit si HTTP est
disponible sur cet ordinateur.

---

## Commandes

| Commande | Effet |
|---|---|
| `update` | vérifie, prépare, installe si la politique et l'occupation le permettent |
| `update verifier` | dit ce qui changerait — **n'écrit rien** |
| `update appliquer` | installe maintenant, **en ignorant le verrou d'occupation** |
| `update restaurer` | revient à la version précédente |
| `update etat` | version installée, source, politique, occupation, retour possible |
| `update auto` | boucle de vérification périodique, à lancer en service |

`update restaurer` est **la commande à connaître par cœur**.

---

## Le verrou d'occupation

Le poste écrit périodiquement « je conduis un engagement » dans
`/.maj/occupation.dat`. La mise à jour le lit **avant de basculer**.

- `command` est occupé tant qu'un engagement est actif, ou en alerte maximale.
- `vaisseau` est occupé dès qu'une menace est classée ou qu'une alarme est active.

L'horodatage n'est pas décoratif : sans lui, un poste qui a planté laisserait un
verrou éternel et bloquerait précisément la mise à jour qui répare. Passé
`occupationPeremption` (30 s), le verrou est ignoré — **un poste muet n'est pas
occupé, il est mort**.

Un poste occupé **reporte**, il n'annule pas : les fichiers restent prêts et
s'installent au prochain démarrage, quand rien n'est engagé par construction.
Seul un opérateur, avec `update appliquer`, passe outre — un automate ne doit
jamais pouvoir couper un poste en plein tir, un humain devant l'écran si.

---

## Les configurations ne sont jamais écrasées

Tout fichier `config_*.lua` est marqué `siAbsent` dans le manifeste : il est
installé **une seule fois**, jamais remplacé. Il contient les zones du théâtre,
les codes transpondeur et le mot de passe de la console — les remettre aux
valeurs d'usine à chaque version désarmerait la défense et rouvrirait la
console à tout le monde, en silence.

`tests/test_maj.lua` échoue si une configuration apparaît au manifeste sans
cette marque.

---

## Serveurs sans HTTP

Quand l'administrateur n'autorise pas `http`, **un seul** ordinateur le reçoit
et distribue aux autres par rednet :

```
maj/serveur_maj.lua        sur le poste qui a le droit HTTP
replliReseau = true        dans config_maj.lua des autres postes
```

Cela évite aussi que quinze postes martèlent GitHub à chaque relance du serveur.

> **Ce repli fait confiance au premier poste qui répond.** Sur un serveur où
> n'importe qui peut poser un ordinateur et un modem, quelqu'un peut répondre à
> votre place. `postesAutorises` et `motDePasseDistribution` atténuent, sans
> régler : les deux se contournent en écoutant le réseau. Si votre serveur
> n'est pas de confiance, **mettez à jour à la main**. C'est pourquoi
> `replliReseau` est à `false` par défaut.

Le poste de distribution ne sert **que** les fichiers listés au manifeste : une
demande pour un chemin arbitraire est refusée, sans quoi n'importe qui pourrait
faire lire les configurations — donc les codes et le mot de passe.

---

## Publier une version

```
lua5.4 outils/generer_manifeste.lua 1.1.0
lua5.4 tests/test_maj.lua
git commit && git push
```

`manifeste.lua` est **généré**, jamais édité à la main. Les sommes sont
calculées par `maj.somme`, le même code que celui qui vérifie à bord : un
générateur avec sa propre implémentation finirait par diverger, et tous les
postes refuseraient la mise à jour sans qu'on comprenne pourquoi.

`tests/test_maj.lua` échoue si le manifeste est périmé. C'est voulu : un
manifeste périmé ferait que chaque poste télécharge puis **refuse** pour somme
incorrecte — un échec bruyant et incompréhensible, répété sur tous les
ordinateurs. Mieux vaut que le banc le dise ici.

---

## Tests

```
lua5.4 tests/test_maj.lua    # 72 vérifications
```

Ce module mérite le banc le plus sévère du dépôt : un bug ici ne casse pas un
poste, il les casse **tous à la fois, à distance**. Ce qui est vérifié en
priorité n'est donc pas qu'il installe, mais qu'il **refuse** d'installer quand
quelque chose cloche, et qu'il sait revenir en arrière.

Le test 8 lance le programme `update` **réellement**, dans l'émulateur, avec un
vrai système de fichiers et un vrai `http`. Il a trouvé deux défauts que les
tests de la bibliothèque ne pouvaient pas voir.
