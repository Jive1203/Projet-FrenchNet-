# FrenchNet — ADS : contre-mesures embarquées (CC: Tweaked)

Système de défense automatique embarqué sur **chaque navire** du serveur **AERONAUTICS WARFARE**.

L'ADS surveille en continu le radar de bord, identifie les projectiles qui convergent vers le navire et déclenche **simultanément** deux réponses : largage de leurres et manœuvre d'évasion prioritaire. Une fois la menace passée, il rend automatiquement la main à la tâche interrompue.

- **Indépendant** : aucune dépendance aux systèmes de défense au sol ni au scramble. Par défaut, aucun ordre extérieur ne peut le désarmer.
- **Parallèle** : coexiste avec les autres programmes du même navire (livraison, orbite d'attaque, scramble) via un contrat de priorité documenté (§6).
- **Traçable** : chaque étape — détection, largage, manœuvre, reprise — est journalisée avec ses valeurs chiffrées.

---

## 1. Ce contre quoi l'ADS fonctionne — et ce contre quoi il ne fonctionne pas

**Le système est calibré pour les missiles guidés.** C'est le cas où il apporte quelque chose de mesurable, et les réglages par défaut sont réglés pour eux.

### Ce que le banc d'essai mesure réellement

Le test 17 fait voler un missile à guidage proportionnel **en boucle fermée** : il lit la position du navire à chaque scan et corrige sa trajectoire, donc il réagit aux ordres que l'ADS vient d'envoyer. Chaque profil est joué deux fois, une fois sans évasion (témoin) et une fois avec. Distance de passage minimale réellement atteinte :

| Profil de missile | Sans évasion | Avec évasion |
|---|---|---|
| Agile — 50 b/s, 40°/s de virage | **0 bloc (impact)** | 3,1 blocs (manqué) |
| Lourd — 40 b/s, 8°/s de virage | 7,5 blocs | **30,7 blocs** |

Contre un missile agile, l'évasion transforme un impact certain en un passage à 3 blocs. Contre un missile peu manœuvrant, elle quadruple la distance de passage. C'est là que l'ADS gagne sa place.

**Mais le gain n'est pas universel.** Sur un troisième profil testé (60 b/s, 12°/s), l'évasion **dégrade** la distance de passage : 10 blocs sans manœuvre, 5,4 blocs avec. La raison est physique et vaut d'être comprise : *virer par le travers réduit la vitesse de rapprochement, donc allonge le temps de vol restant du missile, donc le nombre de degrés qu'il peut encore corriger*. Contre un missile qui allait déjà manquer, rompre peut lui offrir la correction.

C'est le rationnel du réglage `secondesAvantDegagement` (§8) — tenir la route puis rompre tard. **Honnêteté : cette doctrine n'est pas validée par la simulation.** Sur quatre profils, elle n'améliore nettement qu'un cas et reste dans le bruit ailleurs. Elle est fournie désactivée par défaut, à mesurer sur votre serveur.

### Les leurres ne trompent que ce qui vise

Un projectile balistique ne regarde rien. Les flares n'ont d'effet que sur un autoguidage — c'est-à-dire précisément sur la menace visée ici. L'ADS largue dès la confirmation, sans attendre de savoir si l'entrant est guidé : un leurre coûte moins cher qu'un navire.

### Un obus de tir direct ne s'esquive pas

Hors sujet ici, mais à savoir : un obus de Create Big Cannons file à 100–200 b/s. Détecté à 200 blocs, il arrive en 1 à 2 secondes — moins que le temps de réponse d'un dirigeable. L'ADS le détectera, le classera et le journalisera, mais ne le fera pas manquer. Ne réglez pas le système sur lui : les motifs par défaut le couvrent, c'est tout ce qu'il faut.

### Les API des mods ne sont pas figées

Create Radars et Create Aeronautics changent de noms de méthodes d'une version à l'autre. L'ADS ne code aucun nom en dur : il **sonde** le matériel au démarrage et écrit dans le journal ce qu'il a retenu. Si le sondage échoue, il liste tous les périphériques présents avec leurs méthodes — une ligne de `config_ads.lua` suffit à rattraper, sans toucher au programme (§7).

---

## 2. Contenu

| Fichier | Rôle | Où l'installer |
|---|---|---|
| `ads/ads.lua` | Programme principal de l'ADS | `/ads/ads.lua` sur chaque navire |
| `ads/config_ads.lua` | Configuration **propre à chaque navire** | `/ads/config_ads.lua` |
| `ads/startup.lua` | Lanceur automatique au démarrage | `/startup.lua` (racine) |
| `ads/console_ads.lua` | Console de supervision (optionnelle, lecture seule) | Poste de contrôle |

---

## 3. Matériel requis par navire

- 1 ordinateur (**Computer** ou **Advanced Computer**) sur le navire ;
- 1 **radar** (Create Radars) accolé ou relié par câble réseau ;
- 1 ou plusieurs **largueurs de leurres** : Deployer, dropper ou dispenser Create, pilotés par redstone ou par câble réseau ;
- l'accès au **pilotage** : soit le périphérique de Create Aeronautics, soit un montage redstone de commande, soit un programme de navigation qui écoute sur rednet ;
- 1 **modem Ender** (optionnel mais recommandé) pour la télémétrie et le dialogue avec la navigation.

> Le modem n'est **pas vital** : sans lui, l'ADS défend quand même le navire, il perd seulement la télémétrie et le dialogue réseau avec la navigation. Le radar, lui, est vital : sans radar, pas d'ADS.

---

## 4. Installation

```
mkdir ads
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/aeronautics-ads-countermeasures-o0n1z2/ads/ads.lua ads/ads.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/aeronautics-ads-countermeasures-o0n1z2/ads/config_ads.lua ads/config_ads.lua
wget https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/claude/aeronautics-ads-countermeasures-o0n1z2/ads/startup.lua startup.lua
edit ads/config_ads.lua      -- identifiant + largueurs
reboot
```

Sans accès HTTP, passez par une disquette (`copy disk/ads.lua ads/ads.lua`) ou par `edit` et un copier-coller.

### Mise en service prudente — la seule méthode raisonnable

Ne branchez pas l'évasion sur un navire en vol le premier jour. Procédez ainsi :

1. `piloteMode = "simulation"` et `journalNiveauEcran = "DEBUG"`. L'ADS détecte, calcule et journalise tout, mais ne touche à **rien**.
2. Faites-vous tirer dessus. Lisez `ads/ads.log`. Vérifiez trois choses : les projectiles sont bien classés `PROJECTILE`, les menaces réelles déclenchent, les tirs qui passent au large ne déclenchent pas.
3. Ajustez `rayonMenace`, `alignementMini` et `motifsProjectile` avec les **noms réels** lus dans le journal.
4. Passez `piloteMode = "auto"`. Vérifiez sur un vol à vide que le navire vire bien et reprend bien sa route.
5. Passez `journalNiveauEcran = "INFO"`.

---

## 5. Comment l'ADS décide

### 5.1 Le repère de travail

Tout est calculé dans le **repère navire** : les axes du monde (X est, Y haut, Z sud) avec une origine qui suit le navire. Conséquence utile : la position d'un contact est déjà un vecteur relatif, et sa dérivée est déjà une **vitesse relative** — exactement ce que demande le calcul d'interception. L'ADS fonctionne donc même quand le navire ignore sa position absolue (radar sans GPS).

Create Radars rend selon les versions des coordonnées du monde ou des coordonnées relatives à l'antenne. `radarRepere = "auto"` tranche au premier scan sur les ordres de grandeur et **écrit son choix dans le journal**. Si le choix est faux, forcez `"relatif"` ou `"absolu"`.

### 5.2 Le pistage

Le radar rend une photographie instantanée : des positions, sans continuité d'un scan à l'autre. L'ADS reconstruit les **pistes** :

- association par identifiant quand le radar en fournit un ;
- sinon association par proximité à la position **prédite** (extrapolation linéaire), dans la limite de `pisteRayonAssociation`. Comparer à la position prédite et non à la dernière position connue est ce qui permet de suivre un projectile rapide.

La vitesse est obtenue par **régression linéaire** sur l'historique plutôt que par différence entre deux points : le radar échantillonne des positions arrondies, et une simple différence est très bruitée.

**Détection d'autoguidage.** Un obus vole droit : lisser sur toute la fenêtre est alors la meilleure estimation possible. Un missile guidé, lui, corrige en permanence — lisser sur douze échantillons revient à moyenner sa trajectoire d'il y a trois secondes avec celle d'il y a une seconde, et l'ADS poursuit alors un fantôme. L'ADS compare donc la vitesse de la première moitié de la fenêtre à celle de la seconde ; au-delà de `seuilManoeuvreDegresSec` (8 °/s), le contact est classé **manœuvrant** :

- son calcul de vitesse bascule sur une fenêtre courte, plus bruitée mais à jour ;
- il porte le marqueur `GUIDE(x deg/s)` dans le journal — c'est l'information la plus utile pour comprendre ce qui vous a tiré dessus ;
- il lui est demandé **une confirmation de moins** avant déclenchement : un contact qui manœuvre en gardant le navire dans son axe est un autoguidage verrouillé, pas un obus qui passe par hasard.

**Vitesse et repère.** La vitesse dérivée de l'historique est exprimée dans le même repère que les positions, donc déjà relative au navire — c'est exactement ce que demande le calcul d'interception, et c'est pourquoi elle est préférée dès trois échantillons. La vitesse *fournie* par le radar, elle, est celle du contact dans le monde : sur un navire en mouvement, l'utiliser telle quelle fausse tout. Elle n'est donc gardée qu'en dépannage sur les deux premiers échos, et corrigée de la vitesse propre du navire. En repère absolu, la position du navire est rafraîchie **à chaque scan** par l'interface de pilotage : la boucle GPS générale n'interroge que toutes les 5 s, et un navire à 20 b/s s'est déplacé de 100 blocs entre-temps — écart qui serait attribué aux contacts.

### 5.3 Les quatre critères de menace

Le cahier des charges demande « se rapprocher de façon constante » et « garder une trajectoire alignée ». Ces deux critères sont nécessaires mais **pas suffisants**, et c'est le point important :

> Un obus tiré sur le navire voisin de la formation se rapproche à 58 blocs/s et présente un alignement de 0,970 — au-dessus du seuil — pendant plusieurs secondes avant de passer à 60 blocs. Sur ces deux seuls critères, l'ADS casse l'orbite d'attaque et brûle ses leurres pour un tir qui ne le visait pas.

L'ADS ajoute donc les deux grandeurs qui tranchent, tirées du **point d'approche minimale** (CPA) :

```
t_cpa = -(r·v) / |v|²        instant du passage au plus près
d_cpa = |r + v·t_cpa|        distance de ce passage
```

Les quatre critères doivent tenir **simultanément** :

| Critère | Réglage | Défaut | Sens |
|---|---|---|---|
| Rapprochement constant | `rapprochementMiniBlocsSec`, `echantillonsRapprochementMini` | 3 b/s, 3 scans | il se rapproche vraiment, et pas par accident |
| Cap tenu vers le navire | `alignementMini` | 0.94 (20°) | il pointe sur nous |
| Il passera assez près | `rayonMenace` | 16 blocs | **il nous touchera** |
| C'est imminent | `horizonMenaceSecondes` | 20 s | ce n'est pas pour dans une minute |

> **Sur l'angle d'anticipation.** Un missile à guidage proportionnel ne vise pas votre position actuelle : il vise le point d'interception, donc il pointe *à côté* de vous. On pourrait croire que le critère d'alignement le rejetterait. Il n'en est rien, parce que tout est calculé dans le **repère navire** : la vitesse d'un contact y est déjà la vitesse *relative*, et pour une trajectoire de collision la vitesse relative pointe exactement sur le navire, quel que soit l'angle d'anticipation. La tolérance de 20° sert à encaisser ses corrections en cours de vol, pas son avance de tir. Ce raisonnement ne tient que dans le repère navire — d'où l'avertissement du journal quand le repère est absolu et que la position du navire est inconnue.

Puis `confirmationsMini` scans consécutifs qualifiants avant déclenchement — **sauf urgence** : sous `urgenceSecondes` (2,5 s) avant impact, l'ADS déclenche dès le premier scan qualifiant. Attendre deux confirmations à 2 secondes de l'impact revient à ne rien faire.

Chaque non-déclenchement est journalisé avec son motif chiffré : c'est ce qui permet de régler les seuils sur des données réelles plutôt qu'au jugé.

### 5.4 L'axe d'évasion

Fuir en ligne droite devant un projectile plus rapide que soi ne sert à rien : la composante utile de la fuite est nulle. Il faut se dégager **perpendiculairement** à sa trajectoire — c'est ce qui maximise l'écart latéral qu'il doit rattraper, et ce qui sature le plus vite la capacité de correction d'un autoguidage.

L'ADS construit la base du plan perpendiculaire à la trajectoire du projectile et évalue **quatre sens** : deux latéraux, une montée, une plongée. Pour chacun il recalcule la distance d'approche minimale que donnerait ce dégagement, et retient la meilleure.

Les quatre sens ne sont pas équivalents. Si le projectile passera à 5 blocs sur tribord, se dégager sur bâbord creuse l'écart, se dégager sur tribord ramène le navire dans la trajectoire. Les quatre scores sont écrits en `DEBUG` à chaque manœuvre.

Les axes qui mèneraient sous `altitudeMin` ou au-dessus de `altitudeMax` sont **écartés**, et l'écrêtage est journalisé. L'axe est **recalculé à chaque `intervalleManoeuvreSecondes`** : un missile guidé corrige, l'axe optimal se déplace.

### 5.5 La levée de menace et la reprise

La menace est levée quand le projectile a disparu du radar (`perteContactSecondes`), qu'il est passé au plus près, qu'il s'éloigne, ou que sa trajectoire diverge au-delà de `rayonMenace × hysteresisLevee`. L'hystérésis évite qu'une piste oscillant autour du seuil ne fasse entrer et sortir le navire d'évasion plusieurs fois par seconde.

Suit un `delaiSecuriteSecondes` de dégagement — le second missile arrive souvent juste après le premier — pendant lequel la manœuvre est **maintenue**. Une nouvelle menace pendant ce délai relance immédiatement l'engagement. Puis le contrôle est rendu.

---

## 6. Contrat de priorité : coexister avec les autres programmes du navire

L'ADS ne connaît pas vos programmes de livraison, de scramble ou d'orbite d'attaque, et n'a pas à les connaître. Il publie sa priorité de **trois façons complémentaires** ; n'importe laquelle suffit.

### 6.1 Verrou fichier — même ordinateur

Tant que l'ADS a la main, le fichier `/ads/.priorite_ads` existe. Un programme tournant sur le même ordinateur n'a qu'à tester :

```lua
if fs.exists("/ads/.priorite_ads") then
  -- L'ADS manoeuvre : ne pas envoyer de commande de vol.
  sleep(0.5)
else
  -- Route normale.
end
```

Le verrou est levé à la reprise, et aussi au démarrage, après un plantage et après un Ctrl+T : un navire ne doit **jamais** rester avec l'ADS aux commandes.

### 6.2 Messages rednet — autre ordinateur du même navire

Sur le protocole `protocoleTache` (`"frenchnet_nav"` par défaut) :

| `type` | Émis par | Contenu | Attendu du programme de navigation |
|---|---|---|---|
| `DEMANDE_TACHE` | ADS | `navire` | répondre `TACHE` |
| `TACHE` | navigation | `tache = { ... }` | — |
| `PREEMPTION` | ADS | `engagement`, `raison`, `menace` | **suspendre** la tâche en cours |
| `MANOEUVRE` | ADS | `cap`, `altitude`, `gaz`, `virage`, `vertical` | exécuter tel quel |
| `REPRISE` | ADS | `tache`, `cap`, `altitude`, `gaz` | **reprendre** la tâche |

Squelette côté navigation :

```lua
local ADS_PRIORITAIRE = false
local expediteur, m = rednet.receive("frenchnet_nav")
if type(m) == "table" and m.protocole == "FRENCHNET_ADS" then
  if m.type == "DEMANDE_TACHE" then
    rednet.send(expediteur, { protocole = "FRENCHNET_ADS", type = "TACHE",
      tache = tacheCourante }, "frenchnet_nav")
  elseif m.type == "PREEMPTION" then
    ADS_PRIORITAIRE = true          -- suspendre immediatement
  elseif m.type == "MANOEUVRE" then
    piloter(m.cap, m.altitude, m.gaz)
  elseif m.type == "REPRISE" then
    tacheCourante = m.tache or tacheCourante
    ADS_PRIORITAIRE = false          -- reprendre la ou on en etait
  end
end
```

### 6.3 Restitution directe — filet de sécurité

Si personne n'écoute, l'ADS relève lui-même le cap, l'altitude et les gaz **avant** l'alerte, et les restitue à la reprise. La sauvegarde est rafraîchie toutes les `rafraichirTacheSecondes`, **uniquement en état VEILLE** : sauvegarder pendant une évasion enregistrerait la manœuvre elle-même comme tâche à reprendre, et condamnerait le navire à tourner en rond après l'engagement.

### 6.4 Fichier de tâche partagé

Le programme de navigation peut aussi déposer sa tâche dans `/ads/tache_courante.lua` :

```lua
return { nom = "orbite_attaque", destination = { x = 1200, y = 210, z = -2600 } }
```

L'ADS le lit à chaque sauvegarde, cite la tâche dans le journal à la préemption et la renvoie telle quelle à la reprise.

### 6.5 Événements locaux

Sur le même ordinateur, l'ADS émet `ads_alerte` (numéro d'engagement) et `ads_reprise`. Un programme co-résident peut s'y accrocher par `os.pullEvent("ads_alerte")`.

### 6.6 Indépendance

`autoriserInhibitionExterne = false` par défaut : **aucun ordre réseau ne peut désarmer l'ADS d'un navire**. Le passer à `true` ouvre la porte à un désarmement hostile depuis n'importe quel ordinateur du serveur. La console `console_ads.lua` est volontairement en lecture seule.

---

## 7. Adaptation aux mods : le sondage

Au démarrage, l'ADS cherche le radar parmi les périphériques dont le type ou le nom contient `radar`, puis essaie successivement `getEntities`, `scan`, `getTargets`, `getContacts`, `getEntitiesInRange`, `getRadarEntities`, `getBlips`, `getDetectedEntities`, `entities`, `getAll`. La première méthode qui répond une table est retenue :

```
[INFO] [etape: detection du radar de bord] radar de bord 'create_radars:radar_0' operationnel,
       methode de scan 'getEntities', portee declaree 256.0b, periode de scan 0.25s
```

Même principe pour le pilotage (`setYaw`, `setTargetYaw`, `setHeading`, `setAltitude`, `setTargetAltitude`, `setThrottle`…). Les commandes sans méthode correspondante sont listées en `AVERT`.

Si le sondage échoue, le journal liste **tous** les périphériques présents avec leurs méthodes. Recopiez alors le nom exact :

```lua
radarPeripherique  = "create_radars:radar_0",
radarMethodeScan   = "getEntitiesInRange",
pilotePeripherique = "aeronautics:helm_0",
piloteMethodes = { cap = "setYaw", altitude = "setTargetAltitude", gaz = "setThrottle",
                   lireCap = "getYaw", lireAlt = "getAltitude", lirePos = "getPosition" },
```

Les champs de chaque contact sont eux aussi reconnus sous plusieurs formes : `x`/`posX`/`relativeX`, `position = {x,y,z}`, `vx`/`velocityX`/`motionX`, `velocity = {…}`. Quand le radar ne fournit **aucune** vitesse, l'ADS la dérive de l'historique — c'est d'ailleurs la source préférée dès que trois échantillons sont disponibles.

---

## 8. Réglages qui comptent vraiment

### `intervalleScanSecondes` — le réglage critique

Un tick Minecraft vaut 0,05 s ; c'est le plancher. À 0,25 s, un obus à 150 b/s parcourt **37 blocs entre deux scans**. Deux conséquences :

- il faut `pisteRayonAssociation` > distance parcourue entre deux scans, sinon la piste est perdue à chaque scan et aucune vitesse n'est jamais calculée. L'ADS vous prévient au démarrage si le réglage est trop serré ;
- la détection demande au minimum 3 échantillons : à 0,25 s, cela fait 0,75 s de latence incompressible avant la première évaluation.

Descendez à 0,1 s sur un navire qui affronte du tir direct, remontez à 0,5 s sur un cargo qui ne croise que des missiles lents.

### `secondesAvantDegagement` — le break tardif

0 par défaut : rupture immédiate dès la confirmation. Le porter à 3 s fait tenir la route au navire jusqu'à ce que le missile n'ait plus assez de temps de vol pour corriger, puis rompre franchement. Physiquement fondé (§1), **non validé par la simulation** : mesurez vos distances de passage sur votre serveur avant de l'adopter. La préemption et les leurres ne sont pas retardés — seule la manœuvre l'est.

### `rayonMenace`

Demi-diamètre du navire, plus le rayon de souffle du missile, plus une marge. Trop grand, l'ADS se déclenche pour des tirs qui passent au large et brûle ses leurres. Trop petit, il laisse passer ce qui frôle. C'est le réglage à ajuster en premier avec les données du journal.

### `alignementMini`

Cosinus, pas un angle : 0.965 = 15°, 0.985 = 10°, 0.999 = 2,5°. Plus il est proche de 1, plus l'ADS est tolérant aux tirs de barrage — et plus il détecte tard un missile qui manœuvre.

### `motifsIgnores`

**Ajoutez-y le nom de vos propres leurres.** Sans cela, l'ADS se déclenche sur ses propres flares : ils partent du navire, s'en éloignent puis en approchent, et un flare mal nommé peut être classé projectile. Le journal `DEBUG` vous donne les noms réels des entités.

---

## 9. Lire le journal

Format identique aux balises : `[horodatage] [NIVEAU] [etape: <nom>] message`. Le fichier `ads/ads.log` enregistre **tout** ; `journalNiveauEcran` ne filtre que l'affichage.

Un engagement complet se lit ainsi :

```
[INFO]     [etape: pistage des contacts]        nouveau contact classe PROJECTILE (nom) -> piste:1
                                                [cbc:he_missile] position (5.0, 0.0, 240.0) - cinematique indisponible
[CRITIQUE] [etape: alerte menace entrante]      MENACE ENTRANTE - engagement #1 | piste:1 [cbc:he_missile]
                                                dist=180.1b rapprochement=60.0b/s vitesse=60.0b/s (derivee)
                                                alignement=1.000 CPA=5.0b dans 3.00s | rapproche x4, confirme x2
                                                | 1 piste(s) qualifiee(s) | declenchement apres 2 confirmations
[INFO]     [etape: preemption de la tache ...]  engagement #1 : l'ADS prend la priorite sur la tache en cours
                                                (tache 'orbite_attaque', destination (1200, 210, -2600), cap 0.0,
                                                altitude 150.0, gaz 0.50, source tache_courante.lua).
                                                Verrou 'ads/.priorite_ads' pose, preemption diffusee sur 'frenchnet_nav'.
[INFO]     [etape: manoeuvre d'evasion]         engagement #1 : degagement 'lateral-' | cap 0.0 -> 90.0 (babord)
                                                | altitude 150.0 -> n/d (palier) | CPA attendu 61.7b au lieu de 5.0b
                                                | impact estime dans 3.00s | commande acceptee (setYaw+setThrottle)
[INFO]     [etape: largage des leurres]         engagement #1 salve 1/2 : 2 leurre(s) largue(s) par 2 largueur(s)
                                                | stock restant 22 | total engagement 2
[INFO]     [etape: fin de menace]               MENACE LEVEE - engagement #1 | motif : projectile passe au plus pres
                                                (distance 5.0b, rapprochement 0.0b/s) | piste piste:1 [cbc:he_missile]
                                                | distance minimale observee 5.0b | duree 3.0s | 3 manoeuvre(s)
                                                | 4 leurre(s) largue(s) au total
[INFO]     [etape: reprise de la tache normale] engagement #1 clos : controle rendu a la tache normale
                                                (tache 'orbite_attaque', destination (1200, 210, -2600), cap 0.0,
                                                altitude 150.0, gaz 0.50, ...). Verrou leve.
```

Trois choses se lisent directement sur cet extrait : l'évasion (`10:40:01`) et le premier largage (`10:40:01`) partent du **même événement d'alerte**, la manœuvre est **recalculée** à chaque seconde tant que la menace tient, et la tâche citée à la reprise est **exactement** celle citée à la préemption.

### Table de diagnostic

| Message | Cause | Correction |
|---|---|---|
| `aucun radar detecte` | pas de périphérique radar, ou nom non reconnu | renseigner `radarPeripherique` (le journal liste le matériel) |
| `n'expose aucune methode de scan exploitable` | version de Create Radars différente | renseigner `radarMethodeScan` |
| `contact(s) radar sans coordonnees exploitables` | format de contact inconnu | passer en `DEBUG`, relever les clés, ouvrir une issue |
| `repere radar retenu automatiquement : X` | choix automatique — **vérifiez-le** | forcer `radarRepere` si le choix est faux |
| `AUCUN largueur de leurres operationnel` | `largueurs` vide ou mal câblé | renseigner `largueurs` |
| `SOUTE A LEURRES VIDE` | `stockLeurres` épuisé | ravitailler, ou `stockLeurres = 0` si ravitaillement auto |
| `aucune interface de pilotage exploitable` | Create Aeronautics non détecté | `pilotePeripherique` + `piloteMethodes`, ou `piloteRedstone` |
| `les manoeuvres seront DEMANDEES ... par rednet` | aucun pilotage direct trouvé | normal si un programme de navigation écoute ; sinon, câbler |
| `la consigne d'evasion n'a pas pu etre transmise` | mode de pilotage inopérant | vérifier `piloteMode` et le câblage |
| `aucun axe de degagement praticable` | bornes d'altitude trop serrées | élargir `altitudeMin` / `altitudeMax` |
| `degagement vertical ecrete` | manœuvre bornée par le plafond/plancher | normal ; élargir les bornes si trop fréquent |
| `un projectile lent parcourt deja Xb entre deux scans` | scan trop lent pour le pistage | réduire `intervalleScanSecondes` ou augmenter `pisteRayonAssociation` |
| `scans radar en echec consecutifs` | radar arraché ou hors chunk | vérifier le radar ; l'ADS se réinitialise seul |
| `verrou de priorite trouve au demarrage` | plantage pendant une évasion | verrou levé automatiquement ; regarder la cause plus haut dans le journal |
| `piste qualifiee, confirmation en cours` | menace en cours de confirmation | normal |
| `piste declassee avant declenchement` | fausse alerte évitée | normal ; le motif chiffré indique quel critère a tranché |
| `ADS INHIBE` | `autoriserInhibitionExterne = true` et ordre reçu | remettre à `false` |

---

## 10. Superviser la flotte

```
console_ads          -- etat ADS de tous les navires a portee
```

Lecture seule. Par navire : état (`VEILLE` / `MENACE` / `DEGAGEMENT` / `REPRISE`), leurres restants, numéro d'engagement, contacts suivis, et le détail de la menace en cours (distance, temps avant impact, distance de passage).

---

## 11. Banc d'essai

```
lua5.4 tests/test_ads.lua        # 136 verifications
lua5.4 tests/test_balise.lua     # 49 verifications
```

`tests/craftos.lua` émule CraftOS hors du jeu : événements, minuteurs, rednet, modem, redstone, radar (Create Radars) et interface de pilotage (Create Aeronautics).

Le **test 17** va plus loin qu'une vérification de comportement : il simule un missile à guidage proportionnel **en boucle fermée** — le missile lit la position du navire à chaque scan et corrige, le navire a une inertie de barre finie — et compare la distance de passage avec et sans évasion. C'est le seul montage qui prouve que la manœuvre sert à quelque chose ; vérifier qu'un ordre de barre a été émis ne prouve rien.

Les autres tests couvrent la cinématique pure (CPA, alignement, axes d'évasion, caps Minecraft, régression de vitesse), l'engagement complet, le rejet d'un tir qui passe au large, la menace persistante, les contacts ignorés, l'absence de radar, la panne de radar en vol, l'absence de largueur, le mode simulation, la configuration invalide ou absente, `Ctrl+T`, l'autonomie totale, la télémétrie, la reprise de tâche et le repère absolu.

---

## 12. Interaction avec les balises GPS

L'ADS est **indépendant** du réseau de balises. Il ne s'en sert que dans un cas : quand le radar rend des coordonnées du monde et que l'interface de pilotage ne donne pas la position du navire, il appelle `gps.locate()` pour convertir dans le repère navire. Sans constellation GPS, il bascule en repère relatif et le journal le dit.

Voir [guide-complet.md](guide-complet.md) pour le réseau de balises.
