# FrenchNet — Guide d'utilisation et de câblage

Comment brancher un ordinateur CC: Tweaked sur un véhicule **AERONAUTICS WARFARE**, et comment lui faire faire les six mouvements : **avancer, reculer, pivoter à gauche, pivoter à droite, monter, descendre**.

> Guide de mise en service. Pour l'API et le réglage fin, voir le [guide de l'autopilote](guide-autopilote.md).

---

## 1. Qui fait quoi

```
   BALISES GPS                 ORDINATEUR DU VÉHICULE                   VÉHICULE
   ───────────                 ──────────────────────                   ────────
   4 balises fixes   ─────►    autopilote.lua                  ┌────►  propulsion
   diffusent leur              ├─ où suis-je ?  (gps.locate)   │       gouvernes
   position                    ├─ où dois-je aller ? (mission) │       treuils…
                               └─ quatre commandes ────────────┘
                                     ▼
                                  CÂBLAGE
                            redstone ou périphérique
```

Trois couches, trois responsabilités :

| Couche | Qui la fournit | Ce qu'elle garantit |
|---|---|---|
| Position | Les [balises GPS](guide-complet.md) | `gps.locate()` renvoie X, Y, Z |
| Décision | `autopilote.lua` | Quatre commandes entre −1 et +1 |
| Mouvement | **Votre câblage** | Que +1 fasse bien avancer |

**C'est la troisième couche que ce guide couvre.** Les deux premières sont livrées et testées ; la troisième dépend de la façon dont votre véhicule est construit, et c'est vous qui la posez.

---

## 2. Matériel par véhicule

- 1 **ordinateur** (Computer ou Advanced Computer) posé sur le véhicule, qui doit faire partie de la structure assemblée ;
- 1 **modem Ender** accolé à l'ordinateur — c'est lui qui permet de recevoir le GPS des balises ;
- de quoi transmettre un signal redstone de l'ordinateur vers la propulsion : câble, **Redstone Link** de Create, ou tout mécanisme qui accepte un signal ;
- le chunk du véhicule doit rester **chargé** en vol.

Vérifiez d'abord que le GPS répond, avant tout câblage :

```
gps locate
```

Si cette commande ne renvoie rien, inutile d'aller plus loin : la constellation de balises n'est pas opérationnelle. Voir le [guide des balises](guide-complet.md).

---

## 3. Installation

```
mkdir autopilote
wget <dépôt>/autopilote/autopilote.lua       autopilote/autopilote.lua
wget <dépôt>/autopilote/config_vehicule.lua  autopilote/config_vehicule.lua
wget <dépôt>/autopilote/ravitaillement.lua   autopilote/ravitaillement.lua
wget <dépôt>/autopilote/interface.lua        autopilote/interface.lua
wget <dépôt>/autopilote/cablage.lua          autopilote/cablage.lua
wget <dépôt>/autopilote/startup.lua          startup.lua
```

Trois programmes à retenir :

| Commande | À quoi elle sert |
|---|---|
| `interface` | Régler le véhicule à l'écran (identité, décalages, vitesses, gains, **câblage**) |
| `cablage` | **Vérifier le montage et piloter à la main** |
| `interface vol` | Régler les gains PID en vol, avec courbes en temps réel |

---

## 4. Les quatre commandes, et ce qu'elles doivent produire

L'autopilote ne connaît que quatre nombres, tous entre **−1 et +1**. C'est la table de vérité de votre câblage :

| Axe | Commande | Le véhicule doit… | Mouvement demandé |
|---|---|---|---|
| `avance` | **+1** | avancer, nez en avant, pleine poussée | **avancer** |
| `avance` | **−1** | reculer | **reculer** (seulement si `vitesses.marcheArriere > 0`) |
| `lacet` | **+1** | pivoter sur lui-même vers **tribord** | **tourner à droite** |
| `lacet` | **−1** | pivoter sur lui-même vers **bâbord** | **tourner à gauche** |
| `vertical` | **+1** | prendre de l'altitude | **monter** |
| `vertical` | **−1** | perdre de l'altitude | **descendre** |
| `lateral` | **+1** | glisser vers **tribord**, sans tourner | translation droite |
| `lateral` | **−1** | glisser vers **bâbord**, sans tourner | translation gauche |
| tous | **0** | ne rien faire du tout | arrêt |

**Tribord = la droite du véhicule, nez en avant. Bâbord = la gauche.**

Deux remarques qui évitent des heures de perplexité :

- **Pivoter et translater ne sont pas la même chose.** `lacet` fait tourner le véhicule sur lui-même (il change de cap). `lateral` le fait glisser de côté sans changer de cap. Un véhicule qui n'a pas de propulseurs latéraux met simplement `lateral` en `mode = "aucun"` et `vitesses.lateraleMax = 0` : l'autopilote corrigera alors sa dérive en tournant.
- **La commande 0 doit vraiment tout arrêter.** Si votre montage laisse tourner un moteur à commande nulle, le véhicule dérivera en permanence et aucun réglage PID ne le rattrapera.

---

## 5. Les quatre modes de sortie

Chaque axe se configure indépendamment, dans la section `sorties` de `config_vehicule.lua` (ou dans l'interface, sections *Sorties avance / vertical / lacet / lateral*).

### `aucun` — axe non équipé

```lua
lateral = { mode = "aucun" },
```

Rien n'est émis. À utiliser pour tout axe que le véhicule ne sait pas exécuter.

### `analogique` — une face, une intensité

Une seule face de l'ordinateur porte un signal de 0 à 15 proportionnel à la commande.

```lua
avance = { mode = "analogique", cote = "front", neutre = 0, amplitude = 15 },
```

> **niveau = neutre + amplitude × commande**, arrondi et borné à 0–15.

| Cas | Réglage conseillé | Commande −1 | Commande 0 | Commande +1 |
|---|---|---|---|---|
| Véhicule **sans** marche arrière | `neutre = 0, amplitude = 15` | — | **0** | **15** |
| Véhicule **avec** marche arrière | `neutre = 7, amplitude = 7` | 0 | **7** | 14 |

Le premier cas est le réglage livré. Il est important : avec `neutre = 7`, un véhicule sans marche arrière recevrait un **signal de mi-gaz au repos**.

### `bipolaire` — deux faces opposées

Deux faces, une par sens. Une seule est alimentée à la fois, jamais les deux.

```lua
vertical = { mode = "bipolaire", cotePositif = "top", coteNegatif = "bottom",
             amplitude = 15, seuil = 0.08 },
```

| Commande | `cotePositif` | `coteNegatif` |
|---|---|---|
| +0,5 | 8 | 0 |
| 0 | 0 | 0 |
| −1 | 0 | 15 |

`seuil` est la commande en dessous de laquelle **rien** n'est émis : cela évite de faire vibrer un mécanisme pour trois millièmes de correction.

C'est le mode naturel pour tout ce qui a deux sens : monter/descendre, pivoter à gauche/droite, avancer/reculer.

### `peripherique` — appel direct

Si un bloc du véhicule est pilotable comme périphérique CC, on l'appelle directement :

```lua
lacet = { mode = "peripherique", nom = "controleur_0", methode = "setYaw", facteur = 1 },
```

La méthode reçoit `commande × facteur`. Si le périphérique attend des degrés par seconde plutôt qu'une valeur normalisée, `facteur = 45` fait la conversion.

### Corriger un axe branché à l'envers

```lua
vertical = { mode = "bipolaire", inverse = true, cotePositif = "top", coteNegatif = "bottom" },
```

`inverse = true` inverse le signe **avant** émission. Un axe monté à l'envers se corrige donc dans la configuration, **sans rien redémonter sur le véhicule**. L'outil `cablage` le détecte et l'écrit tout seul (§7).

---

## 6. Que brancher derrière le signal

L'autopilote s'arrête au signal redstone : c'est le montage Create qui le transforme en mouvement. La question à se poser pour chaque axe est simplement **« qu'est-ce que ma propulsion sait recevoir ? »** :

| Ce que sait faire votre mécanisme | Mode à choisir |
|---|---|
| Marche / arrêt | `bipolaire` (ou `analogique` avec `amplitude = 15`) |
| Deux sens, deux entrées séparées | `bipolaire` |
| Une intensité proportionnelle | `analogique` |
| Piloté par un bloc exposé à CC | `peripherique` |

Montages courants côté Create, à adapter à votre appareil :

- **un embrayage** (*Clutch*) coupe la transmission quand il est alimenté : idéal pour un axe tout ou rien ;
- **un inverseur** (*Gearshift*) inverse le sens de rotation quand il est alimenté : associé à une face en `bipolaire`, il donne les deux sens avec un seul groupe motopropulseur ;
- **un Redstone Link** transporte le signal de l'ordinateur jusqu'au mécanisme sans câble apparent, ce qui simplifie beaucoup les structures mobiles ;
- **un levier analogique** remplacé par la sortie de l'ordinateur, si votre appareil se pilote déjà à la main par un signal 0–15.

> **Ce que je ne peux pas vous dire.** Les noms exacts des blocs de commande de Create Aeronautics en NeoForge 1.21.1 varient selon les versions du mod, et je ne les ai pas vérifiés sur votre serveur. Je ne vais pas les inventer. Le raisonnement ci-dessus vaut quel que soit le bloc : identifiez ce que votre propulsion accepte en entrée, choisissez le mode correspondant, et **vérifiez avec `cablage`** — l'outil vous dira si le signal part bien et si le véhicule répond dans le bon sens.

---

## 7. Recette de mise en service

### Étape 1 — Poser l'ordinateur

Ordinateur + modem Ender sur le véhicule, tous deux dans la structure assemblée. Vérifiez `gps locate`.

### Étape 2 — Déclarer l'identité et la géométrie

```
interface
```

Section *Identité* : un nom, un identifiant unique sur le serveur.
Section *Géométrie* : les décalages, relevés à la main (touche F3, ligne *Block*) :

- `decalageGps` = position de **l'ordinateur** par rapport au **centre** du véhicule ;
- `decalageDepot` = position du point de dépôt ou des patins par rapport au centre.

Repère, nez en avant : **x = tribord, y = haut, z = avant**. Un ordinateur placé 4 blocs en avant et 2 blocs au-dessus du centre donne `decalageGps = { x = 0, y = 2, z = 4 }`.

### Étape 3 — Déclarer le câblage

Sections *Sorties avance / vertical / lacet / lateral* : pour chaque axe, le mode et les faces. `S` pour enregistrer, `Q` pour quitter.

### Étape 4 — Vérifier le signal, véhicule à l'arrêt

```
cablage
```

Appuyez sur ↑ : la ligne `AVANCE` doit se remplir et le niveau redstone de la face configurée doit monter. **Si ce niveau ne bouge pas, le problème est dans la configuration**, pas dans le montage : mauvaise face, ou mode `aucun`.

À ce stade, on ne vérifie que ceci : l'ordinateur émet bien, sur la bonne face, au bon niveau.

### Étape 5 — Brancher les mécanismes

Reliez chaque face à son mécanisme (§6). Un axe à la fois, en vérifiant après chacun.

### Étape 6 — Vérifier le sens, véhicule assemblé

Toujours dans `cablage`, dans un espace dégagé, puissance réduite (touche `2` = 20 %) :

- `Tab` sélectionne l'axe à tester ;
- `T` lance le **test guidé** : l'outil annonce ce que le véhicule doit faire, le pousse 2,5 s dans un sens, puis dans l'autre ;
- il vous demande ensuite si le véhicule a fait l'**inverse** de ce qui était annoncé. Répondez `O` (oui) ou `N` (non) ;
- une réponse `O` inscrit `inverse = true` sur cet axe. `S` enregistre.

Refaites-le pour les quatre axes. À la fin, ↑ fait avancer, → fait pivoter à droite, PageUp fait monter — sans exception.

### Étape 7 — Régler les vitesses réelles

Retour dans `interface`, section *Vitesses* : mesurez ce que le véhicule sait **réellement** faire, à pleine commande, et inscrivez-le. `croisiere`, `verticaleMax`, `tauxVirageMax` doivent être des mesures, pas des souhaits — sinon tous les régulateurs satureront en permanence.

Mettez `lateraleMax = 0` si le véhicule n'a pas de propulsion latérale.

---

## 8. Piloter à la main

`cablage` est aussi un poste de pilotage manuel : de quoi sortir un appareil d'un hangar ou le rapatrier sans autopilote.

| Touche | Mouvement |
|---|---|
| ↑ / ↓ | avancer / reculer |
| ← / → | pivoter à gauche / à droite |
| PageUp / PageDown | monter / descendre |
| Home / End | translater à bâbord / à tribord |
| `1` à `9`, `0` | puissance de 10 % à 100 % |
| `Espace` | tout arrêter |
| `Tab` | choisir l'axe à tester |
| `T` | test guidé de l'axe choisi |
| `I` | inverser l'axe choisi |
| `M` | maintien (voir l'avertissement) |
| `S` | enregistrer la configuration |
| `Q` | quitter (les commandes sont coupées) |

Deux sécurités :

- **relâchement** — la commande retombe à zéro dès que la touche est relâchée ;
- **homme mort** — si plus rien n'est frappé pendant 2 secondes, tout est coupé.

> La touche `M` **désactive l'homme mort** pour observer une manœuvre en cours. Un véhicule laissé en maintien continuera sur son erre. Ne l'utilisez pas pour vous absenter.

---

## 9. Passer à l'autopilote

Une fois les six mouvements vérifiés à la main, l'autopilote n'a plus rien à découvrir : il envoie exactement les mêmes commandes, par le même code.

```lua
local autopilote = dofile("/autopilote/autopilote.lua")
local ap = autopilote.nouveau()

ap.initialiser()                          -- relit la position avant tout mouvement
ap.allerA({ x = 1980, y = 118, z = -3100, type = "depot" })

parallel.waitForAny(ap.executer, function()
  ap.attendreArrivee(600)
  print("arrive")
end)
```

Premier vol : choisissez une cible **dégagée, à faible distance, à la même altitude**, et gardez `interface vol` ouvert pour voir les courbes. Vérifiez dans l'ordre : le véhicule part dans la bonne direction, il ralentit en approchant, il s'immobilise, il tient sa position.

Pour que le véhicule démarre seul à chaque allumage, copiez votre programme de mission en `/autopilote/mission.lua` : `startup.lua` s'en charge. Sans mission, le véhicule reste en veille et tient sa position.

---

## 10. Dépannage

| Symptôme | Cause la plus fréquente |
|---|---|
| `cablage` n'affiche aucun niveau sur une face | Axe en `mode = "aucun"`, ou mauvaise face dans la configuration |
| Le niveau monte mais le véhicule ne bouge pas | Le signal n'atteint pas le mécanisme : câble coupé par l'assemblage, ou Redstone Link mal apparié |
| Le véhicule part dans le mauvais sens | Axe inversé : `T` puis `O` dans `cablage`, ou `inverse = true` |
| Le véhicule dérive tout seul, commandes à zéro | Un mécanisme reste engagé à commande nulle. Vérifiez le niveau au repos : il doit être 0 (ou le neutre déclaré) |
| Il avance mais ne tourne pas | Axe `lacet` non câblé, ou `tauxVirageMax` à une valeur que l'appareil ne peut pas tenir |
| Il tourne sur lui-même sans avancer | Axe `avance` inversé, ou `vitesses.croisiere` très supérieure au réel |
| Il oscille en altitude | Gains trop forts : `interface vol`, axe ALTITUDE, réduire `kp` — voir le [guide de l'autopilote](guide-autopilote.md#13-méthode-de-réglage) |
| « aucune position GPS » | Moins de 4 balises à portée. `gps locate` depuis le véhicule pour confirmer |
| Il se stabilise systématiquement à côté de la cible | `decalageGps` faux : remesurez à la touche F3 |
| Le véhicule ne redémarre pas après un reboot | `startup.lua` absent de la racine, ou marqueur d'arrêt manuel : supprimez `/autopilote/.arret_manuel` |

Le journal dit toujours à quelle étape le problème survient :

```
interface journal
```
