# Doomsday Ship — système embarqué (Phase 1)

Système informatique du ballon lourd, pour **AERONAUTICS WARFARE**
(Create Aeronautics / Avionics, NeoForge 1.21.1, CC: Tweaked).

> **À lire d'abord : [`api_notes.md`](api_notes.md).** L'audit du dépôt montre
> que **quatre des cinq modules** que le cahier des charges suppose existants
> sont absents : autopilote, Fire Control (réseau et embarqué), ADS, solveur
> balistique. Rien de ce qui en dépend n'a été simulé.

---

## 1. Ce que la Phase 1 livre

| Composant | Fichier | État |
|---|---|---|
| Framework MFD | `vaisseau/mfd.lua` | complet |
| Couche matérielle (HAL) | `vaisseau/hal.lua` | complet, découverte par méthode |
| Surveillance et alarmes | `vaisseau/surveillance.lua` | complet |
| Couture d'intégration | `vaisseau/liaisons.lua` | complet |
| Primitives d'affichage | `vaisseau/widgets.lua` | complet |
| Page Propulsion / Énergie | `vaisseau/pages/propulsion.lua` | rendu complet, **données selon HAL** |
| Page Portance / Enveloppe | `vaisseau/pages/portance.lua` | rendu complet, **données selon HAL** |
| Page Carte / Waypoints | `vaisseau/pages/navigation.lua` | rendu complet, **envoi autopilote bloqué** |
| Programme principal | `vaisseau/vaisseau.lua` | complet |
| Diagnostic de bord | `vaisseau/diagnostic.lua` | complet |

**Non livré, et pourquoi** : l'envoi de route à l'autopilote et le largage de
ballast (modules absents). Les valeurs réelles de propulsion et de portance
dépendent de l'API de Create Aeronautics, **que je ne connais pas** — le
diagnostic est l'outil qui la révélera.

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
wget <depot>/command/carte.lua              vaisseau/carte.lua
wget <depot>/command/noyau.lua              vaisseau/noyau.lua
wget <depot>/vaisseau/startup.lua           startup.lua
```

`carte.lua` et `noyau.lua` sont les modules de FrenchNet Command, réutilisés
**verbatim** : la page Navigation et, en phase 2, la page SA/EW s'en servent.
Deux cartes ou deux IFF divergeraient au premier changement, et l'équipage ne
saurait plus laquelle croire.

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
lua5.4 tests/test_vaisseau.lua    # 67 vérifications
```

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

## 9. Phases suivantes

| Phase | Contenu | Dépendance bloquante |
|---|---|---|
| 2 | SA/EW, liaison FrenchNet, page Liaison | aucune — `noyau.lua` suffit pour l'IFF |
| 3 | Armement, inventaire, ADS embarqué | **Fire Control Embarqué et ADS absents** |
| 4 | TV/alertes, audio, relais musique | **HTTP sortant à vérifier** sur le serveur |

La phase 3 ne peut pas commencer tant que le Fire Control Embarqué et l'ADS
n'existent pas dans le dépôt. La phase 2, si.

### Vidéo temps réel : non

Un moniteur CC n'a pas de décodeur et chaque caractère modifié est un paquet
réseau. Images statiques converties en `paintutils` et texte, oui. Un clip
converti hors ligne en séquence d'images basse résolution jouée en boucle lente,
éventuellement. De la vidéo, non — ce n'est pas une limite de code.
