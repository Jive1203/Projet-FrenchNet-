# FrenchNet — Calibration automatique du câblage

Tous les vaisseaux du serveur se dirigent par **courants de redstone**. L'autopilote envoie quatre commandes — avance, vertical, lacet, latéral — et chacune doit ressortir sur la bonne face de l'ordinateur.

Jusqu'ici c'était à vous de le lui dire, face par face, dans `config_vehicule.lua` :

```lua
avance = { mode = "analogique", cote = "front", neutre = 0, amplitude = 15 },
```

L'outil `cablage` ne vérifiait que le **sens** d'un axe déjà déclaré. Personne ne cherchait **quelle face fait quoi**.

`calibrer` le cherche. Il essaie les sorties une par une, regarde ce que le vaisseau fait, et écrit la table lui-même.

---

## 1. En une commande

```
classer     -- identifier les blocs que le système ne connaît pas (si besoin)
calibrer    -- trouver quelle face commande quel axe
cablage     -- vérifier le sens de chaque axe, à l'œil
```

`calibrer` ne remplace pas `cablage` : il trouve les faces, `cablage` confirme qu'elles poussent du bon côté. La calibration est aveugle à une chose qu'un opérateur voit d'un coup d'œil — que le vaisseau avance bien *par le nez*.

---

## 2. Ce que le véhicule va faire

Il va **bouger**. Chaque face est mise sous tension quelques secondes, l'une après l'autre, et le déplacement mesuré au GPS révèle ce qu'elle commande.

Trois conditions, non négociables :

1. **en vol stationnaire**, en l'air, loin du relief et des constructions ;
2. **constellation GPS montée et chunks chargés** — sans position, pas de calibration ;
3. **personne à bord, personne dessous**.

Entre deux essais, l'outil repousse le véhicule dans l'autre sens dès qu'il connaît une commande opposée, mais il dérive quand même. Au-delà de `rayonSecurite` blocs du point de départ (250 par défaut), il s'arrête et coupe tout.

`Ctrl+T` coupe tout, à n'importe quel moment.

---

## 3. La méthode, et pourquoi elle est celle-là

Pour chaque face, une face à la fois, **jamais deux** :

1. tout neutraliser, attendre l'immobilité complète ;
2. relever la position à l'arrêt ;
3. porter la face testée à 15 pendant `impulsion` secondes ;
4. couper, attendre de nouveau l'immobilité ;
5. le déplacement observé **est** l'effet de cette face.

### Pourquoi mesurer à l'arrêt

`gps.locate()` interroge quatre balises qui répondent à des ticks différents. Sur un véhicule en mouvement, la trilatération renvoie un point faux — les quatre mesures ne décrivent pas le même instant. À l'arrêt, elle est juste.

C'est aussi pour cela que la calibration est lente : l'essentiel du temps est passé à **attendre que le vaisseau s'arrête vraiment**.

---

## 4. Le lacet, angle mort du GPS

`gps.locate()` donne un point, jamais un cap. Une commande de lacet fait pivoter le vaisseau **sans déplacer son centre** : elle est invisible.

Trois cas, et l'outil vous dit lequel est le vôtre.

### Cas 1 — Un capteur de cap existe

Le plus confortable. `config.cap.source = "peripherique"` : la variation d'angle se lit directement, et le lacet est identifié du premier coup. Le programme `classer` renseigne cette section tout seul dès qu'un bloc est classé `CAPTEUR_CAP`.

### Cas 2 — L'ordinateur est décalé du centre du véhicule

Si `decalageGps` a une composante horizontale non nulle, une rotation **promène le point GPS sur un cercle** autour du centre. Deux impulsions identiques suffisent à trancher :

- deux déplacements **parallèles** → translation ;
- deux déplacements **tournés** l'un par rapport à l'autre → rotation, et le signe du produit vectoriel donne le sens.

> **Le piège, et il est traité.** Une impulsion qui fait tourner le vaisseau de près d'un demi-tour rend les deux cordes presque antiparallèles, donc de sinus quasi nul — ce qui ressemblerait à une translation. Or une translation ne peut pas s'inverser entre deux impulsions identiques : un cosinus négatif signe forcément une rotation. Quand le sens reste illisible, l'outil recommence avec une impulsion trois fois plus courte.

**Et c'est une aubaine.** Les trois positions successives sont sur un cercle centré sur le **vrai centre du véhicule**. Le vecteur centre → ordinateur est donc le bras `decalageGps` vu dans le repère du monde : comparé au bras déclaré, il donne **l'orientation réelle du nez**. La convention arbitraire d'avant est alors remplacée par une mesure, et les faces déjà classées sont reprojetées sans être ré-essayées.

Le journal le dit quand cela arrive :

```
cap reel du vehicule deduit de la rotation : 80 deg (rayon mesure 4.0 bloc(s))
convention d'avant corrigee de +180 deg par la mesure
```

### Cas 3 — Ni capteur, ni décalage

Le lacet **n'est pas observable**. L'outil le déclare franchement au lieu de déclarer les faces inertes :

```
LACET NON OBSERVABLE : ni capteur de cap, ni decalage GPS horizontal.
Faces sans effet mesurable, candidates a une rotation : left, right
```

Trois remèdes, dans l'ordre de préférence :

1. **renseigner `decalageGps`** si l'ordinateur n'est pas au centre — c'est souvent déjà vrai, simplement non déclaré ;
2. **équiper un capteur de cap** et le classer avec `classer` ;
3. **déclarer les faces de lacet à la main** dans `sorties.axes`.

---

## 5. Tous les réseaux, et dans quel ordre

« Essayer tout » coûte cher. Les faces sont donc prises par **rangs de coût croissant**, et le balayage s'arrête dès que les axes essentiels sont acquis :

| Rang | Faces | Coût |
|---|---|---|
| 1 | déjà déclarées dans la configuration | aucun essai |
| 2 | les six faces de l'ordinateur maître | 6 essais |
| 3 | les faces de chaque satellite annoncé | 6 par satellite |

Les **satellites** sont les ordinateurs de sortie déportés (`autopilote/satellite.lua`) : un ordinateur n'a que six faces, et sur un gros vaisseau la propulsion est dispersée. Ils s'annoncent d'eux-mêmes sur rednet, `calibrer` les écoute et essaie leurs faces comme les siennes.

> Un satellite qui porte un **autre identifiant de véhicule** est écarté du recensement. Deux appareils côte à côte ne se commandent jamais l'un l'autre — c'est aussi pour cela que les satellites utilisent un modem **courte portée** et non un modem Ender.

---

## 6. Faces jamais essayées

L'outil n'envoie pas de courant n'importe où. Sont écartées d'office :

| Face | Motif |
|---|---|
| occupée par un périphérique | le courant y serait absorbé par le bloc |
| listée dans `cotesInterdits` | interdite par la configuration |
| `carburant.coteRetour` / `coteDepart` / `coteAmarre` | entrées d'ordres et voyant d'amarrage |
| jauge de carburant ou capteur sol en redstone | entrées de mesure |
| face d'un bloc classé `ARMEMENT` | **ne doit jamais être actionnée** |
| face d'un périphérique **non classé** | on ne devine pas ce qu'est un bloc inconnu |

Chaque exclusion est journalisée avec son motif.

---

## 7. Périphériques inconnus : la quarantaine

C'est la règle de sécurité qui gouverne tout le reste.

**La calibration envoie du courant dans des sorties pour voir ce qui bouge.** Faire cela sur un bloc dont on ignore la nature, c'est accepter qu'il s'agisse d'une batterie de canons, d'un largueur d'ancre ou d'une soute.

Le système reconnaît seul ce qu'il connaît : modems, moniteurs, intégrateurs redstone, inventaires, capteurs usuels — par leur type, et à défaut par leurs méthodes. Face à un bloc d'un mod qu'il n'a jamais vu, il n'a que deux choix : deviner, ou demander.

**Il demande.** Le bloc part en quarantaine, la calibration refuse de démarrer :

```
CALIBRATION REFUSEE : 1 peripherique(s) ne sont pas classes. Un operateur doit
leur attribuer une classe avec le programme 'classer'.
```

### Les classes

Une classe n'est pas une étiquette décorative : elle désigne **la case de la configuration que le bloc a le droit de remplir**. C'est une autorisation.

| Classe | Ce que c'est | Ce que l'autopilote en fait |
|---|---|---|
| `COMMUNICATION` | modem | rednet : satellites, tour de contrôle |
| `SORTIE_REDSTONE` | intégrateur, relais | ses faces deviennent des candidates à la calibration |
| `CAPTEUR_CAP` | boussole, lecteur de navire | remplit `config.cap` — **le plus précieux**, il rend le lacet identifiable du premier coup |
| `CAPTEUR_SOL` | télémètre, scanner | remplit `config.sol` : protection au ras du relief |
| `JAUGE_CARBURANT` | cuve, détecteur d'énergie | remplit `config.carburant` : retour au ravitaillement |
| `COMMANDE_VOL` | contrôleur pilotable par méthode | câble un axe en mode `peripherique`, sans essai |
| `AFFICHAGE` | moniteur, haut-parleur | recopie d'état |
| `STOCKAGE` | coffre, soute | inventaire pour la télémétrie |
| `ARMEMENT` | **tout ce qui tire, largue, explose ou ancre** | **exclu de la calibration et du vol, sans exception** |
| `IGNORE` | décoration, bloc en panne | retiré de l'inventaire |

`classer` présente les classes une par une, avec ce que chacune autorise, puis fait remplir les champs propres à la classe choisie. La classe `ARMEMENT` exige une **confirmation explicite** : on ne la coche pas par distraction.

Une fiche remplie par un opérateur **prime toujours** sur la reconnaissance automatique : c'est l'humain qui a vu le bloc, pas le programme.

Le registre est écrit dans `/autopilote/registre_peripheriques.lua`, lisible et corrigible à la main.

### Passer outre

```lua
peripheriques = { exigerClassement = false },
```

Les inconnus sont alors seulement signalés, et leurs faces évitées. À vos risques.

---

## 8. Le piège du neutre non nul

Un moteur à marche arrière se câble souvent avec un **repos au milieu de la plage** : 7 sur 0–15, où 0 est plein gaz arrière et 15 plein gaz avant.

Pour un tel montage, mettre la face à 0 — ce que fait toute neutralisation — commande **plein gaz arrière**.

L'outil mesure donc d'abord la dérive au repos, toutes faces à zéro. Si le véhicule bouge alors que rien n'est commandé, il teste l'hypothèse du neutre médian :

```
derive de 8.4 bloc(s) alors que TOUTES les faces sont a 0 : une commande a
probablement un neutre non nul. Test de l'hypothese neutre = 7.
niveau de repos 7 retenu : le vehicule s'immobilise.
```

Si le véhicule dérive aussi bien à 0 qu'à 7, ce n'est pas un problème de neutre : vent, courant, ou moteur déjà sous tension par un autre circuit. L'outil le dit et continue, mais les mesures sont à vérifier.

---

## 9. Ce que l'outil écrit

Une table `sorties.axes` complète, reportée dans `config_vehicule.lua` :

```lua
axes = {
  avance   = { mode = "bipolaire", cotePositif = "front", coteNegatif = "back",
               amplitude = 15, seuil = 0.08 },
  vertical = { mode = "bipolaire", cotePositif = "top", coteNegatif = "bottom",
               amplitude = 15, seuil = 0.08, ordinateur = 42 },
  lacet    = { mode = "bipolaire", cotePositif = "right", coteNegatif = "left",
               amplitude = 15, seuil = 0.08 },
  lateral  = { mode = "aucun" },
}
```

Deux faces opposées sur un même axe donnent un montage **bipolaire**. Une seule face donne un **analogique**. Aucune face donne `aucun` — l'axe n'est pas équipé, et c'est une information, pas un échec.

> **Une inversion réglée à la main est conservée.** Si vous avez corrigé le sens d'un axe avec `cablage` et que la calibration retrouve exactement le même câblage, votre `inverse = true` est gardé : vous l'avez validé en vol, la calibration ne le sait pas mieux que vous.

---

## 10. Réglages

Section `calibration` de `config_vehicule.lua`. À ne toucher que si la calibration se trompe.

| Réglage | Défaut | Effet |
|---|---|---|
| `impulsion` | `3.0` | Durée d'activation d'une face. Trop court : l'effet se perd dans le bruit GPS. Trop long : le véhicule part loin, et une rotation dépasse le demi-tour |
| `stabilisation` | `2.0` | Pas d'attente entre deux mesures d'immobilité |
| `attenteMax` | `20` | Attente maximale d'immobilité avant de mesurer malgré tout |
| `seuilBruit` | `1.2` | Blocs : en deçà, c'est du bruit de trilatération |
| `seuilCap` | `6.0` | Degrés : en deçà, le cap n'a pas bougé |
| `seuilRotation` | `0.25` | Sinus de l'angle entre deux déplacements successifs |
| `rayonSecurite` | `250` | Blocs : au-delà, arrêt et coupure générale |
| `recentrer` | `true` | Repousser en sens inverse pour limiter la dérive |
| `arretAnticipe` | `true` | Stopper dès que les axes essentiels sont acquis |
| `delaiSatellites` | `6` | Durée d'écoute des annonces de satellites |

**Un vaisseau lourd dérive longtemps** : montez `stabilisation` et `attenteMax` si les mesures semblent incohérentes.

---

## 11. Dépannage

| Symptôme | Cause probable | Remède |
|---|---|---|
| `CALIBRATION REFUSEE` | un bloc n'est pas classé | `classer` |
| `position indisponible` | moins de 4 balises GPS à portée | monter la constellation, charger les chunks |
| `arret de securite` | le véhicule s'est trop éloigné | calibrer plus haut et plus dégagé, ou baisser `impulsion` |
| Tous les axes `aucun` | rien n'est branché, ou tout est sur des faces exclues | vérifier `cotesInterdits` et le journal des exclusions |
| `LACET NON OBSERVABLE` | ni capteur de cap, ni décalage GPS | §4, cas 3 |
| Le vaisseau vole à reculons | convention d'avant prise à l'envers | `inverse = true` sur l'axe avance, via `cablage` touche `I` |
| `axe(s) non cable(s)` au démarrage | la calibration n'a pas tout trouvé | relancer `calibrer`, ou déclarer à la main |
| Une rotation classée `avance` | impulsion trop longue | baisser `impulsion` à 1,5 s et recalibrer |

---

## 12. Qui appelle tout cela

Trois systèmes du dépôt demandent un autopilote, et les trois sont passés au même régime : **refuser de partir plutôt que d'obéir sans bouger**.

| Système | Comportement sans câblage |
|---|---|
| `autopilote/autopilote.lua` | journalise `AUCUN AXE N'EST CABLE` au démarrage et nomme `calibrer` |
| `intercepteur/` | **refuse de décoller** : un intercepteur qui reste au sol pendant que la cible passe est pire qu'un intercepteur absent |
| `vaisseau/` (Doomsday Ship) | `engager()` **refuse** la route, la page NAVIGATION affiche le motif |

---

📖 [Guide de câblage](guide-cablage.md) — les quatre modes de sortie, ce qu'il faut brancher derrière
📖 [Guide de l'autopilote](guide-autopilote.md) — missions, points de passage, réglages de vol
