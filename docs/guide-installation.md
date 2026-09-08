# FrenchNet — Installer les fichiers sur les ordinateurs

Guide de dépannage du téléchargement, et méthodes d'installation.

---

## 1. Pourquoi `wget` échoue

**Le dépôt `Jive1203/Projet-FrenchNet-` est privé.** Vérifié depuis l'extérieur :

```
"private": true
raw.githubusercontent.com/.../balise/balise.lua  ->  404
```

CC: Tweaked n'a **aucun moyen de s'authentifier sur GitHub**. Sur un dépôt privé, toutes les adresses `raw.githubusercontent.com` renvoient 404, pour n'importe qui d'autre que vous connecté dans un navigateur. Réessayer ne changera rien : ce n'est ni une erreur de frappe, ni un problème de réseau, ni la configuration du serveur.

> Le réseau lui-même fonctionne : une adresse `raw` publique répond bien 200 depuis le même chemin. Seul l'accès au dépôt est refusé.

Trois façons de s'en sortir, de la plus simple à la plus autonome.

---

## 2. Solution A — rendre le dépôt public (recommandé)

Trente secondes, et tout fonctionne ensuite sans effort.

1. Sur GitHub : dépôt → **Settings** → tout en bas, **Danger Zone** → **Change repository visibility** → **Make public**.
2. Sur chaque ordinateur en jeu, **une seule commande** :

```
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/autopilote-lua-module-kfnu2k/installe.lua installe
```

3. Puis, selon le poste :

```
installe balise       -- balise GPS fixe
installe vehicule     -- autopilote d'un véhicule
installe satellite    -- ordinateur de sortie déporté
```

L'installateur crée les dossiers, télécharge tout, **vérifie chaque fichier** et affiche les étapes suivantes. Il ne réécrit jamais une configuration déjà réglée (sauf avec `-f`) : vos coordonnées relevées à la main sont en sécurité si vous relancez.

Ce que la vérification évite : sur un dépôt privé ou une branche renommée, GitHub renvoie parfois une **page HTML avec un code 200**. Un `wget` ordinaire l'enregistre telle quelle sous le nom `balise.lua`, et l'ordinateur ne plante que plus tard, sans raison apparente. L'installateur détecte le cas, refuse d'écrire le fichier et nomme la cause.

Le dépôt contient du code de jeu, pas de secret : le rendre public n'expose rien de sensible. Vérifiez simplement qu'aucun fichier de configuration ne contient de coordonnées que vous souhaitez garder pour vous.

---

## 3. Solution B — garder le dépôt privé

Aucun HTTP n'est alors utilisable. On passe par les fichiers de la sauvegarde, puis par une disquette pour dupliquer.

### 3a. Poser les fichiers sur un premier ordinateur

Chaque ordinateur CC: Tweaked a un dossier dans la sauvegarde du monde. Relevez son numéro en jeu :

```
id
```

Puis, côté fichiers :

| Contexte | Chemin |
|---|---|
| Serveur dédié | `<serveur>/world/computercraft/computer/<id>/` |
| Solo / LAN | `.minecraft/saves/<monde>/computercraft/computer/<id>/` |

Copiez-y l'arborescence telle quelle :

```
computer/<id>/
├── startup.lua              (copie de balise/startup.lua)
└── balise/
    ├── balise.lua
    ├── config_balise.lua
    └── recepteur.lua
```

Le monde doit être **chargé après** la copie (ou l'ordinateur redémarré) pour que les fichiers apparaissent.

### 3b. Dupliquer sur les autres ordinateurs par disquette

C'est la méthode rapide pour équiper 4 balises : on ne recopie les fichiers qu'une fois.

Sur l'ordinateur déjà équipé, avec un **lecteur de disquette** accolé et une disquette dedans :

```
mkdir disk/balise
copy balise/balise.lua        disk/balise/balise.lua
copy balise/config_balise.lua disk/balise/config_balise.lua
copy balise/recepteur.lua     disk/balise/recepteur.lua
copy startup.lua              disk/startup.lua
```

Sur chaque autre balise, disquette insérée :

```
mkdir balise
copy disk/balise/balise.lua        balise/balise.lua
copy disk/balise/config_balise.lua balise/config_balise.lua
copy disk/startup.lua              startup.lua
edit balise/config_balise.lua      -- identifiant + coordonnées propres à CETTE balise
reboot
```

### Attention à la taille des disquettes

Une disquette contient **125 Ko** par défaut (`floppy_space_limit`). Les tailles réelles :

| Jeu de fichiers | Taille | Tient sur une disquette ? |
|---|---|---|
| Balise (4 fichiers) | 56 Ko | Oui, largement |
| **`autopilote/autopilote.lua` seul** | **127 Ko** | **Non — dépasse la limite** |
| Autopilote complet (véhicule) | 240 Ko | Non, il faut 2 à 3 disquettes |

Pour un véhicule, soit vous répartissez sur plusieurs disquettes (`autopilote.lua` seul sur la première), soit vous augmentez `floppy_space_limit` dans `computercraft-server.toml`. Les balises, elles, passent sans problème.

---

## 4. Solution C — pastebin, pour dupliquer entre ordinateurs

Dès qu'**un** ordinateur possède un fichier, CC: Tweaked sait le republier :

```
pastebin put balise/balise.lua      -- affiche un code, à noter
```

Sur les autres ordinateurs :

```
pastebin get <code> balise/balise.lua
```

Utile quand vous n'avez pas de lecteur de disquette sous la main. Deux réserves : cela nécessite le HTTP activé, et **le fichier devient public sur pastebin.com** — ne l'utilisez pas pour un fichier de configuration contenant des coordonnées que vous voulez garder privées.

> **À éviter :** glisser un jeton GitHub dans l'adresse pour lire un dépôt privé. N'importe quel joueur ayant accès à l'ordinateur pourrait le lire dans le fichier, et un jeton donne accès à bien plus que ce dépôt.

---

## 5. Vérifier la configuration HTTP du serveur

Même avec un dépôt public, le serveur doit autoriser les requêtes. Dans `serverconfig/computercraft-server.toml` :

```toml
[http]
enabled = true
```

Certains serveurs restreignent en plus les domaines via `[[http.rules]]`. Test rapide en jeu :

```
wget https://example.com essai
```

L'installateur fait ce contrôle lui-même et affiche la marche à suivre si le HTTP est coupé.

---

## 6. Diagnostic des messages

| Message affiché en jeu | Cause | Correctif |
|---|---|---|
| `Failed to download` / `404` | Dépôt privé, ou branche/chemin faux | Solution A, ou vérifier la branche |
| Le fichier existe mais plante à l'exécution | Page HTML enregistrée comme du Lua | Relancer avec `installe`, qui le détecte |
| `wget: HTTP requests are not enabled` | HTTP coupé côté serveur | Section 5 |
| `Domain not permitted` | Domaine non autorisé | Ajouter une règle `[[http.rules]]` |
| `Out of space` | Disquette pleine (125 Ko) | Section 3, tableau des tailles |
| `wget: No such program` | Version très ancienne de CC | Utiliser `pastebin` ou la disquette |
| Rien ne se passe au démarrage | `startup.lua` absent de la **racine** | Il ne va pas dans `balise/`, mais à la racine |

---

## 7. Après l'installation

**Balise** — deux lignes à changer, propres à chaque balise :

```lua
identifiant      = "BAL-01-NORD",                     -- unique sur le serveur
positionManuelle = { x = 1200, y = 210, z = -2600 },  -- F3, ligne "Block:"
```

Puis `reboot`. Vérification depuis n'importe quelle machine :

```
recepteur      -- liste les balises actives
gps locate     -- teste la trilatération (4 balises minimum, non alignées)
```

**Véhicule** — `interface` pour régler, `cablage` pour vérifier le montage et piloter à la main. Voir le [guide de câblage](guide-cablage.md).

📖 [Guide des balises](guide-complet.md) · [Guide de l'autopilote](guide-autopilote.md) · [Guide de câblage](guide-cablage.md)
