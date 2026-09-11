# Doomsday Ship — système embarqué (Phases 1 à 4)

Système informatique du ballon lourd, pour **AERONAUTICS WARFARE**
(Create Aeronautics / Avionics, NeoForge 1.21.1, CC: Tweaked).

> **À lire d'abord : [`api_notes.md`](api_notes.md).** L'audit du dépôt montre
> que **quatre des cinq modules** que le cahier des charges suppose existants
> sont absents : autopilote, Fire Control (réseau et embarqué), ADS, solveur
> balistique. Rien de ce qui en dépend n'a été simulé.

---

## 1. Ce qui est livré

| Composant | Fichier | État |
|---|---|---|
| **Phase 1** | | |
| Framework MFD | `vaisseau/mfd.lua` | complet |
| Couche matérielle (HAL) | `vaisseau/hal.lua` | complet, découverte par méthode |
| Surveillance et alarmes | `vaisseau/surveillance.lua` | complet |
| Couture d'intégration | `vaisseau/liaisons.lua` | complet |
| Primitives d'affichage | `vaisseau/widgets.lua` | complet |
| Page Propulsion / Énergie | `vaisseau/pages/propulsion.lua` | rendu complet, **données selon HAL** |
| Page Portance / Enveloppe | `vaisseau/pages/portance.lua` | rendu complet, **données selon HAL** |
| Page Carte / Waypoints | `vaisseau/pages/navigation.lua` | rendu complet, **envoi autopilote bloqué** |
| **Phase 2** | | |
| Conscience de situation | `vaisseau/sa.lua` | complet |
| Page SA (situation tactique) | `vaisseau/pages/sa.lua` | complet |
| Page Liaison | `vaisseau/pages/liaison.lua` | complet |
| Radar du bord → FrenchNet | `vaisseau/vaisseau.lua` | complet |
| **Phase 3** | | |
| Recensement des soutes | `vaisseau/inventaire.lua` | complet |
| Page EW (détection) | `vaisseau/pages/ew.lua` | détection complète, **largage bloqué** |
| Page Armement | `vaisseau/pages/armement.lua` | affichage complet, **tir bloqué** |
| **Phase 4** | | |
| Avertisseur sonore | `vaisseau/audio.lua` | complet |
| Page Alertes | `vaisseau/pages/alertes.lua` | complet |
| Relais « now playing » | `vaisseau/musique.lua` | complet, **HTTP selon serveur** |
| | | |
| Programme principal | `vaisseau/vaisseau.lua` | complet |
| Diagnostic de bord | `vaisseau/diagnostic.lua` | complet |

**Non livré, et pourquoi** : le tir, le largage de leurres, l'envoi de route à
l'autopilote et le largage de ballast. Les trois modules dont ils dépendent —
autopilote, Fire Control Embarqué, ADS — **n'existent pas dans le dépôt**. Les
pages correspondantes sont complètes à l'affichage et **inertes à la commande**,
et elles l'annoncent en clair. Aucun appel n'est simulé.

Les valeurs réelles de propulsion et de portance dépendent de l'API de Create
Aeronautics, **que je ne connais pas** — le diagnostic est l'outil qui la
révélera.

---

## 2. Installation

Ordinateur avancé + modem Ender + moniteur(s) accolé(s), chunk **forceload**.

```
mkdir vaisseau
mkdir vaisseau/pages
wget <depot>/vaisseau/vaisseau.lua          vaisseau/vaisseau.lua
wget <depot>/vaisseau/mfd.lua               vaisseau/mfd.lua
wget <depot>/vaisseau/hal.lua               vaisseau/hal.lua
wget <depot>/vaisseau/surveillance.lua      vaisseau/surveillance.lua
wget <depot>/vaisseau/liaisons.lua          vaisseau/liaisons.lua
wget <depot>/vaisseau/widgets.lua           vaisseau/widgets.lua
wget <depot>/vaisseau/diagnostic.lua        vaisseau/diagnostic.lua
wget <depot>/vaisseau/config_vaisseau.lua   vaisseau/config_vaisseau.lua
wget <depot>/vaisseau/pages/propulsion.lua  vaisseau/pages/propulsion.lua
wget <depot>/vaisseau/pages/portance.lua    vaisseau/pages/portance.lua
wget <depot>/vaisseau/pages/navigation.lua  vaisseau/pages/navigation.lua
wget <depot>/vaisseau/sa.lua                vaisseau/sa.lua
wget <depot>/vaisseau/inventaire.lua        vaisseau/inventaire.lua
wget <depot>/vaisseau/audio.lua             vaisseau/audio.lua
wget <depot>/vaisseau/musique.lua           vaisseau/musique.lua
wget <depot>/vaisseau/pages/sa.lua          vaisseau/pages/sa.lua
wget <depot>/vaisseau/pages/ew.lua          vaisseau/pages/ew.lua
wget <depot>/vaisseau/pages/armement.lua    vaisseau/pages/armement.lua
wget <depot>/vaisseau/pages/liaison.lua     vaisseau/pages/liaison.lua
wget <depot>/vaisseau/pages/alertes.lua     vaisseau/pages/alertes.lua
wget <depot>/command/carte.lua              vaisseau/carte.lua
wget <depot>/command/noyau.lua              vaisseau/noyau.lua
wget <depot>/command/scanner.lua            vaisseau/scanner.lua
wget <depot>/vaisseau/startup.lua           startup.lua
```

Le répertoire d'installation n'est plus imposé : `vaisseau.lua` publie le sien
et les pages chargent leurs modules relativement à lui.

`carte.lua`, `noyau.lua` et `scanner.lua` sont les modules de FrenchNet
Command, réutilisés **verbatim** : les pages Navigation et SA s'en servent, et
le radar du bord aussi. Deux cartes, deux IFF ou deux détections de radar
divergeraient au premier changement, et l'équipage ne saurait plus laquelle
croire — pire, l'équipage lirait « rouge » là où le contrôleur lit « vert ».

### Premier geste à bord

```
diagnostic sauver
```

**Avant tout réglage.** Le catalogue de mesures du HAL contient des noms de
méthode *plausibles*, pas certains. Ce rapport donne :

1. les périphériques réels du ballon, leurs types, leurs méthodes ;
2. les mesures que le HAL a su lier seul, et celles qu'il n'a pas su ;
3. **un échantillon de valeur pour chaque méthode** — c'est ce qui dit laquelle
   donne quoi ;
4. l'état des modules extérieurs ;
5. HTTP sortant, modem, GPS.

Reportez ensuite les vrais noms dans `mesures` de la configuration.

---

## 3. Framework MFD

Trois notions, et rien de plus :

- **Surface** — un écran physique. Le terminal, ou un moniteur accolé.
- **Fenêtre** — une zone d'une surface, créée par `window.create`.
- **Page** — un module Lua indépendant qui se dessine dans une fenêtre.

### Le layout est en fractions, jamais en caractères

```lua
["monitor_0"] = { fenetres = {
  { page = "propulsion", x = 0,   y = 0,    l = 0.5, h = 0.55 },
  { page = "portance",   x = 0.5, y = 0,    l = 0.5, h = 0.55 },
  { page = "navigation", x = 0,   y = 0.55, l = 1,   h = 0.45 },
} },
```

Un 3×3 et un 2×2 n'ont pas la même taille. Une disposition figée en caractères
serait fausse sur l'un des deux ; en fractions, la même config marche sur les
deux. Une fenêtre plus petite que `largeurMiniFenetre` × `hauteurMiniFenetre`
est **refusée et journalisée** : mieux vaut une page absente qu'une page
illisible sur laquelle on croit pouvoir compter.

### Ajouter une page

Aucune ligne du framework à toucher. Un module qui expose `dessiner` suffit :

```lua
return {
  titre = "AVARIES",
  periode = 2,                       -- secondes entre deux redessins
  init = function(ctx) end,          -- facultatif
  dessiner = function(fenetre, ctx, geometrie) end,   -- obligatoire
  clic = function(ctx, x, y) end,    -- coordonnées LOCALES à la fenêtre
}
```

### Écrans à chaud, et trafic réseau

`peripheral` / `peripheral_detach` / `monitor_resize` relancent la détection et
le placement. L'échelle de texte est choisie automatiquement : **la plus grande
qui laisse encore la place demandée**.

Chaque fenêtre est dessinée entre `setVisible(false)` et `setVisible(true)` :
CC accumule les écritures et ne pousse qu'une image complète. Sur un moniteur
Minecraft, chaque modification est un paquet envoyé à tous les joueurs à portée
— accumuler, c'est diviser ce trafic par le nombre de lignes.

### Alarmes : une pile, pas un écrasement

Une alarme prend la surface, quel que soit l'affichage en cours, et **l'écran
d'avant est restitué** quand elle est levée. La pile est ordonnée par niveau :
une critique passe devant une attention déjà affichée, et celle-ci réapparaît
ensuite. Une alarme qui ferait perdre l'affichage précédent obligerait
l'équipage à le retrouver à la main, en pleine avarie.

Un clic acquitte l'alarme affichée.

---

## 4. Couche matérielle — la leçon déjà payée

> Ce dépôt a déjà payé l'erreur une fois : la détection radar cherchait un
> périphérique dont le **type** contenait « radar », et ne trouvait rien parce
> que le mod le nomme autrement.

Le HAL applique la leçon d'emblée :

1. **découverte par méthode**, jamais par nom de type ;
2. chaque mesure liste plusieurs noms de méthode plausibles ;
3. **une mesure introuvable rend `nil` et son motif — jamais zéro.**

Ce troisième point est le plus important. Un réservoir vide et un capteur muet
ne se ressemblent pas, et les confondre sur une page de portance se paie cher.
Les pages affichent `INDISPO` avec le motif, et la surveillance lève une
**alarme de capteur** distincte de l'alarme de valeur.

```lua
mesures = {
  ["propulsion.stress"] = { peripherique = "back", methode = "getStress" },
  ["portance.ballast"]  = false,   -- ce ballon n'en a pas : ne pas alerter
}
```

---

## 5. Surveillance et alarmes

| Mesure | Famille | Sens | Seuils par défaut |
|---|---|---|---|
| `propulsion.charge` | PROPULSION | normal | 70 / 85 / 95 % |
| `energie.pourcentage` | PROPULSION | inverse | 40 / 20 / 10 % |
| `portance.pression` | PORTANCE | inverse | 70 / 50 / 30 % |
| `portance.gaz` | PORTANCE | inverse | 60 / 40 / 20 % |
| `vol.vitesseVerticale` | PORTANCE | inverse | −3 / −6 / −10 b/s |

**Deux familles distinctes, volontairement.** Une alarme unique « avarie »
obligerait l'équipage à diagnostiquer avant d'agir, et les gestes ne sont pas
les mêmes : couper la poussée ne remonte pas un ballon, larguer du ballast si.

**Hystérésis.** Une alarme ne se lève qu'après un retour franc sous le seuil
(`hysteresis`, 5 par défaut). Sans marge, une valeur qui oscille autour du seuil
ferait clignoter l'écran sans répit — exactement quand l'équipage a besoin de
le lire.

> Le banc d'essai a pris un vrai bug en flagrant délit sur ce point : le
> raccourci ternaire `a and b or c` de Lua est **faux** dès que la branche
> `then` vaut `false`, et l'hystérésis levait l'alarme précisément quand il
> fallait la tenir. Écrit en `if` explicite depuis.

---

## 6. Intégrations : ce qui marche et ce qui refuse

Tout passe par `vaisseau/liaisons.lua`, et par lui seul.

| Module | Attendu à | Fonctions attendues | État |
|---|---|---|---|
| `autopilote` | `/vaisseau/autopilote.lua` | `definirRoute`, `etat`, `engager`, `desengager` | **ABSENT** |
| `fireControl` | `/vaisseau/fire_control.lua` | `armes`, `engager`, `securiser`, `munitions` | **ABSENT** |
| `ads` | `/vaisseau/ads.lua` | `stock`, `larguer`, `etat` | **ABSENT** |

Un appel à un module absent **échoue avec un motif lisible**, affiché tel quel
sur la page. Jamais un succès simulé : un équipage qui croit avoir largué et qui
n'a rien largué continue de descendre en pensant remonter.

« Présent » ne vaut pas « conforme » : un module chargé dont il manque des
fonctions est signalé `PARTIEL`, avec le nom de celles qui manquent.

Le jour où l'autopilote arrive, il y a **un seul fichier à modifier**.

---

## 7. Liaison FrenchNet

Le ballon émet son **transpondeur** au format relevé dans
`command/transpondeur.lua` (voir `api_notes.md` §3.3) :

```lua
{ protocole = "FRENCHNET_TRANSPONDEUR", identifiant = , nom = , code = , x = , y = , z = }
```

**Sans `codeTranspondeur` configuré, FrenchNet Command classe ce ballon
INCONNU** — avec toutes les conséquences prévues par la doctrine de zone. Le
système le journalise au démarrage.

Il écoute aussi `frenchnet_annonce` : dès que le poste au sol s'annonce, le
ballon lui parle **directement** au lieu de diffuser à tout le serveur.

La position vient du GPS de la constellation de balises. Sans GPS, la carte se
fige et le transpondeur émet sans coordonnées — le poste devra apparier par nom
déclaré. Le système le dit en clair.

---

## 8. Tests

```
lua5.4 tests/test_vaisseau.lua          # 176 vérifications (modules et pages)
lua5.4 tests/test_vaisseau_runtime.lua  #  30 vérifications (système complet)
```

`test_vaisseau_runtime.lua` démarre le système **entier** dans l'émulateur et
vérifie le câblage : périphériques découverts, huit pages enregistrées, trames
émises et reçues, alarmes posées et **sonnées**. Il a immédiatement trouvé cinq
défauts que les tests unitaires ne pouvaient pas voir — dont des pages qui ne
se chargeaient pas du tout et un transpondeur perdu en silence.

Ce que le banc vérifie en priorité n'est **pas** que le système marche quand
tout va bien, mais qu'il **dit la vérité quand quelque chose manque** :

- une mesure absente rend `nil` et son motif, jamais zéro ;
- un capteur muet lève une alarme de **capteur**, pas de valeur, et prévient que
  la surveillance est inactive ;
- un module extérieur absent **échoue** — le test compte les refus et vérifie
  que le motif n'est journalisé qu'une fois ;
- une fenêtre trop petite est refusée plutôt qu'affichée illisible ;
- une alarme levée **restitue** l'affichage précédent.

---

## 9. Ce qui reste bloqué, et par quoi

| Attendu | Bloqué par | Comportement actuel |
|---|---|---|
| Envoi de route à l'autopilote | `autopilote.lua` absent | refus motivé, affiché |
| Largage de ballast | `autopilote.lua` absent | refus motivé, affiché |
| Sélection d'arme et tir | `fire_control.lua` absent | page complète, **inerte** |
| Munitions en culasse | `fire_control.lua` absent | `INDISPO` — le compte **en soute** est affiché à part |
| Largage de chaffs / flares | `ads.lua` absent | page complète, **inerte** |
| Stock de leurres prêts | `ads.lua` absent | compte **en soute** affiché, marqué « PAS prêt au largage » |
| Relais musique par HTTP | config du serveur | repli `RESEAU`, sinon `AUCUN` — le mode est toujours affiché |

Le jour où l'un de ces modules arrive, il y a **un seul fichier à modifier** :
`vaisseau/liaisons.lua`, et les fonctions à écrire y sont déjà nommées.

### Zones du théâtre : pas de protocole, donc pas de magie

Le poste au sol **ne diffuse pas ses zones** — vérifié dans `command.lua`,
aucun protocole ne s'en charge. Le ballon les lit donc dans
`config_vaisseau.lua`, et le système le dit au démarrage quand elles manquent.
Sans elles, la carte du bord n'a pas de fond et la doctrine de zone ne
s'applique pas à bord.

### Vidéo temps réel : non

Un moniteur CC n'a pas de décodeur et chaque caractère modifié est un paquet
réseau. Images statiques converties en `paintutils` et texte, oui. Un clip
converti hors ligne en séquence d'images basse résolution jouée en boucle lente,
éventuellement. De la vidéo, non — ce n'est pas une limite de code.
