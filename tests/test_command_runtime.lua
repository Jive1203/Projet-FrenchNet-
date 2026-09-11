-- Banc d'essai d'execution de FrenchNet Command, hors du jeu.
--   Usage : lua5.4 tests/test_command_runtime.lua   (depuis la racine du depot)
--
-- Le fichier test_command.lua verifie la doctrine (le noyau). Celui-ci verifie
-- la CHAINE COMPLETE : balayage radar simule -> pistes -> classification ->
-- decision -> designation -> ordre reellement diffuse vers Fire Control ->
-- confirmation de destruction. C'est le seul moyen de detecter une erreur de
-- cablage entre des briques individuellement correctes.

local RACINE = (arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."
local SCR    = RACINE .. "/tests"
local SRC    = RACINE .. "/command"
local BANC   = "/tmp/banc_command_frenchnet"

package.path = SCR .. "/?.lua;" .. package.path

local echecs, total = 0, 0

local function verifier(nom, condition, detail)
  total = total + 1
  if condition then
    print(string.format("  [OK]   %s", nom))
  else
    echecs = echecs + 1
    print(string.format("  [ECHEC] %s %s", nom, detail and ("-> " .. detail) or ""))
  end
end

local function contient(sorties, motif)
  for _, ligne in ipairs(sorties) do
    if ligne:find(motif, 1, true) then return true, ligne end
  end
  return false
end

local function compter(sorties, motif)
  local n = 0
  for _, ligne in ipairs(sorties) do
    if ligne:find(motif, 1, true) then n = n + 1 end
  end
  return n
end

-- Quand l'interface tourne, elle prend la main sur l'affichage et le journal
-- ne passe plus par print : il faut alors le relire sur le disque.
local function journalDisque()
  local f = io.open(BANC .. "/command/command.log", "r")
  if not f then return "" end
  local contenu = f:read("a") or ""
  f:close()
  return contenu
end

local function ordres(etat)
  local liste = {}
  for _, d in ipairs(etat.diffusions) do
    if d.protocole == "frenchnet_fire_control" and type(d.message) == "string" then
      liste[#liste + 1] = d.message
    end
  end
  return liste
end

local function contientOrdre(etat, chaine)
  for _, o in ipairs(ordres(etat)) do
    if o == chaine then return true end
  end
  return false
end

--------------------------------------------------------------------------------
-- Preparation d'un banc : on n'installe PAS interface.lua, pour que Command
-- fonctionne en mode journal seul et que tout soit observable en sortie.
--------------------------------------------------------------------------------

local CONFIG_BASE = [[
return {
  identifiant = "CMD-TEST",
  positionRadar = { x = 0, y = 80, z = 0 },
  positionsRelatives = false,
  porteeRadar = 500,
  intervalleBalayage = 1,
  codeAllie = "FN-ALLIE-0000",
  codeGeneral = "FN-GEN-1234",
  altitudeSolReference = 64,
  hauteurAerienne = 25,
  toleranceAppariement = 24,
  validiteTranspondeur = 15,
  delaiEvaluationSecondes = 8,
  disparitionSecondes = 3,
  ratioEnveloppeFiable = 0.80,
  tentativesMax = 3,
  validiteInventaire = 600,
  journalFichier = true,
  journalNiveauEcran = "DEBUG",
  battementSecondes = 60,
  %s
}
]]

local function preparer(zones, etatOperationnel, supplementConfig)
  os.execute("rm -rf " .. BANC .. " && mkdir -p " .. BANC .. "/command")
  -- Le poste charge desormais plusieurs modules : sans eux il refuse de
  -- demarrer, ce qui est le comportement voulu mais ferait echouer tout le
  -- banc de facon peu lisible.
  os.execute("cp " .. SRC .. "/command.lua " .. SRC .. "/noyau.lua " .. SRC .. "/terrain.lua "
    .. SRC .. "/carte.lua " .. SRC .. "/scanner.lua " .. BANC .. "/command/")
  local f = io.open(BANC .. "/command/config_command.lua", "w")
  f:write(string.format(CONFIG_BASE, supplementConfig or ""))
  f:close()
  if zones then
    f = io.open(BANC .. "/command/zones.dat", "w")
    f:write(zones)
    f:close()
  end
  if etatOperationnel then
    f = io.open(BANC .. "/command/etat.dat", "w")
    f:write(etatOperationnel)
    f:close()
  end
end

local ZONE_ALPHA = [[{
  { nom = "BASE", classe = "ALPHA", forme = "cercle",
    centre = { x = 0, z = 0 }, rayon = 600 },
}]]

local ZONE_CHARLIE = [[{
  { nom = "CIVIL", classe = "CHARLIE", forme = "cercle",
    centre = { x = 0, z = 0 }, rayon = 600 },
}]]

local ETAT_GUERRE = [[{ mode = "GUERRE", alerteMax = false }]]
local ETAT_PAIX   = [[{ mode = "PAIX", alerteMax = false }]]

local INVENTAIRE = {
  plateformes = {
    { nom = "AirShip1", x = 0,   y = 200, z = 0, tirs = 0 },
    { nom = "SAM-Est",  x = 150, y = 70,  z = 0, tirs = 0 },
  },
}

-- Fabrique une fonction radar : le contact est visible entre deux instants,
-- a une position donnee par une fonction du temps.
local function radarScenario(debut, fin, positionA, nom)
  return function(t)
    if t < debut or t > fin then return { contraptions = {}, entities = {} } end
    local p = positionA(t)
    return { contraptions = { { name = nom or "Raider-7", x = p.x, y = p.y, z = p.z } },
             entities = {} }
  end
end

--------------------------------------------------------------------------------
print("\n== TEST 1 : chaine complete, intrus aerien en zone Alpha en guerre ==")
do
  preparer(ZONE_ALPHA, ETAT_GUERRE)
  local craftos = dofile(SCR .. "/craftos.lua")
  -- Contact visible de t=5 a t=7, puis disparition franche a l'interieur de
  -- l'enveloppe fiable : c'est une destruction.
  local env, etat = craftos.creer({
    racine = BANC,
    programme = "command/command.lua",
    radar = radarScenario(5, 7, function() return { x = 100, y = 150, z = 0 } end),
  })
  craftos.injecterRednet(3, INVENTAIRE, "frenchnet_fire_control")

  local motif = craftos.executer(BANC .. "/command/command.lua", 20)
  local s = etat.sorties

  verifier("le poste tourne sans se terminer", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("mode GUERRE restaure depuis etat.dat", (contient(s, "mode GUERRE")))
  verifier("zone Alpha chargee", (contient(s, "1 zone(s) active(s)")))
  verifier("radar local detecte par ses methodes, pas par son nom de type",
    (contient(s, "radar detecte sur 'top'")) and (contient(s, "par ses methodes")))

  -- Etape 1 : detection
  verifier("[1] detection journalisee",
    (contient(s, "[etape: detection d'un contact] nouveau contact Raider-7")))
  -- Etape 2 : classification
  verifier("[2] classification : cible aerienne",
    (contient(s, "cible Raider-7 classee AERIENNE")))
  verifier("[2] classification : IFF inconnu, aucun transpondeur",
    (contient(s, "transpondeur : aucun code transpondeur recu")))
  verifier("[2] les deux voies d'identification sont journalisees",
    (contient(s, "voie transpondeur INCONNU")) and (contient(s, "voie radar")))
  -- Etape 3 : decision d'escalade
  verifier("[3] decision : palier 3 destruction avec scramble direct",
    (contient(s, "palier 3 - destruction avec scramble direct")))
  verifier("[3] decision : motif complet journalise",
    (contient(s, "zone ALPHA / GUERRE / IFF INCONNU")))
  -- Etape 4 : designation
  verifier("[4] designation journalisee avec le score",
    (contient(s, "[etape: designation du tireur] cible Raider-7 -> plateforme SAM-Est")))

  -- Etape 5 : ordres reellement diffuses
  local liste = ordres(etat)
  verifier("deux ordres emis (Alpha : destruction + scramble)", #liste == 2,
    table.concat(liste, " | "))
  verifier("ordre de tir sur la plateforme la mieux placee",
    contientOrdre(etat, "SAM-Est Fire type Aerial"), table.concat(liste, " | "))
  verifier("scramble direct sur la seconde plateforme",
    contientOrdre(etat, "AirShip1 Scramble type Aerial"), table.concat(liste, " | "))

  -- Confirmation de destruction par le declencheur A.
  verifier("[5] destruction confirmee apres disparition dans l'enveloppe",
    (contient(s, "DESTRUCTION CONFIRMEE sur Raider-7")))
  verifier("[5] le declencheur ayant conclu est nomme",
    (contient(s, "declencheur A: disparition radar")))
  verifier("aucune alerte controleur sur un engagement nominal",
    not contient(s, "ALERTE CONTROLEUR"))
end

--------------------------------------------------------------------------------
print("\n== TEST 2 : vehicule allie, code transpondeur valide ==")
do
  preparer(ZONE_ALPHA, ETAT_GUERRE)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC,
    programme = "command/command.lua",
    radar = radarScenario(5, 11, function() return { x = 100, y = 150, z = 0 } end, "Ally-1"),
  })
  craftos.injecterRednet(3, INVENTAIRE, "frenchnet_fire_control")
  craftos.injecterRednet(9, {
    protocole = "FRENCHNET_TRANSPONDEUR", identifiant = "Ally-1", nom = "Ally-1",
    code = "FN-ALLIE-0000", x = 100, y = 150, z = 0,
  }, "frenchnet_transpondeur")

  craftos.executer(BANC .. "/command/command.lua", 12)
  local s = etat.sorties

  verifier("code transpondeur recu", (contient(s, "[etape: reception d'un code transpondeur]")))
  verifier("IFF allie reconnu", (contient(s, "transpondeur : code allie valide")))
  verifier("identification par transpondeur seul, faute de donnees radar",
    (contient(s, "concordance PARTIEL")))
  verifier("appariement par nom declare", (contient(s, "appariement par nom declare")))
  verifier("palier 1 : observation passive, libre passage",
    (contient(s, "palier 1 - observation passive")))
  verifier("aucun ordre emis vers Fire Control", #ordres(etat) == 0,
    table.concat(ordres(etat), " | "))
end

--------------------------------------------------------------------------------
print("\n== TEST 3 : zone Charlie en paix, inconnu suivi mais jamais detruit ==")
do
  preparer(ZONE_CHARLIE, ETAT_PAIX)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC,
    programme = "command/command.lua",
    radar = radarScenario(5, 15, function() return { x = 100, y = 150, z = 0 } end),
  })
  craftos.injecterRednet(3, INVENTAIRE, "frenchnet_fire_control")

  craftos.executer(BANC .. "/command/command.lua", 18)
  local s = etat.sorties
  local liste = ordres(etat)

  verifier("palier 2 : scramble de verification",
    (contient(s, "palier 2 - scramble de verification")))
  verifier("un seul ordre, de type scramble", #liste == 1 and liste[1]:find("Scramble", 1, true),
    table.concat(liste, " | "))
  verifier("aucun ordre de tir en zone Charlie en paix",
    not contientOrdre(etat, "SAM-Est Fire type Aerial"))
  verifier("aucune evaluation de destruction ouverte sur un scramble",
    not contient(s, "evaluation de destruction ouverte"))
end

--------------------------------------------------------------------------------
print("\n== TEST 4 : cible qui survit, trois tentatives puis alerte humaine ==")
do
  preparer(ZONE_ALPHA, ETAT_GUERRE)
  local craftos = dofile(SCR .. "/craftos.lua")
  -- Vol stable, sans crash ni disparition : aucun des deux declencheurs.
  local env, etat = craftos.creer({
    racine = BANC,
    programme = "command/command.lua",
    radar = radarScenario(5, 60, function(t) return { x = 100 + t, y = 150, z = 0 } end),
  })
  craftos.injecterRednet(3, INVENTAIRE, "frenchnet_fire_control")

  craftos.executer(BANC .. "/command/command.lua", 45)
  local s = etat.sorties

  verifier("reemission apres absence des deux signaux",
    (contient(s, "[etape: reemission d'un ordre de tir]")))
  verifier("tentative 2 emise", (contient(s, "tentative 2/3")))
  verifier("tentative 3 emise", (contient(s, "tentative 3/3")))
  verifier("sequence abandonnee apres 3 tentatives",
    (contient(s, "sequence abandonnee")))
  verifier("controleur humain alerte",
    (contient(s, "ALERTE CONTROLEUR - limite de tentatives atteinte")))
  verifier("pas de quatrieme tentative", not contient(s, "tentative 4/3"))

  local tirs = 0
  for _, o in ipairs(ordres(etat)) do
    if o:find(" Fire type ", 1, true) then tirs = tirs + 1 end
  end
  verifier("exactement trois ordres de tir emis", tirs == 3, "#" .. tirs)
end

--------------------------------------------------------------------------------
print("\n== TEST 5 : disparition au bord de portee, fuite et non destruction ==")
do
  preparer(ZONE_ALPHA, ETAT_GUERRE)
  local craftos = dofile(SCR .. "/craftos.lua")
  -- Contact a 460 m du radar : au-dela de l'enveloppe fiable (500 x 0.8 = 400).
  -- Sa disparition ne doit PAS compter comme une destruction.
  local env, etat = craftos.creer({
    racine = BANC,
    programme = "command/command.lua",
    radar = radarScenario(5, 7, function() return { x = 460, y = 150, z = 0 } end),
  })
  craftos.injecterRednet(3, INVENTAIRE, "frenchnet_fire_control")

  craftos.executer(BANC .. "/command/command.lua", 25)
  local s = etat.sorties

  verifier("aucune destruction confirmee", not contient(s, "DESTRUCTION CONFIRMEE"))
  verifier("piste declaree perdue, pas detruite",
    (contient(s, "PERDUE, destruction NON confirmee")))
  verifier("le motif nomme l'enveloppe fiable",
    (contient(s, "hors enveloppe fiable")))
  verifier("le motif nomme la sortie de portee probable",
    (contient(s, "sortie de portee probable")))
  verifier("controleur alerte",
    (contient(s, "ALERTE CONTROLEUR - destruction non confirmee, cible perdue")))
end

--------------------------------------------------------------------------------
print("\n== TEST 6 : hors juridiction et absence de plateformes ==")
do
  -- Aucune zone : tout le theatre est hors juridiction.
  preparer("{}", ETAT_GUERRE)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC,
    programme = "command/command.lua",
    radar = radarScenario(5, 15, function() return { x = 100, y = 150, z = 0 } end),
  })
  craftos.injecterRednet(3, INVENTAIRE, "frenchnet_fire_control")

  craftos.executer(BANC .. "/command/command.lua", 18)
  local s = etat.sorties

  verifier("avertissement au demarrage : aucune zone classifiee",
    (contient(s, "aucune zone classifiee")))
  verifier("contact detecte malgre tout", (contient(s, "nouveau contact Raider-7")))
  verifier("aucune action hors juridiction",
    (contient(s, "hors de toute zone classifiee : aucune action")))
  verifier("aucun ordre emis", #ordres(etat) == 0, table.concat(ordres(etat), " | "))

  -- Meme scenario, zone Alpha mais Fire Control muet.
  preparer(ZONE_ALPHA, ETAT_GUERRE)
  craftos = dofile(SCR .. "/craftos.lua")
  local env2, etat2 = craftos.creer({
    racine = BANC,
    programme = "command/command.lua",
    radar = radarScenario(5, 15, function() return { x = 100, y = 150, z = 0 } end),
  })
  craftos.executer(BANC .. "/command/command.lua", 12)

  verifier("Fire Control muet : alerte controleur",
    (contient(etat2.sorties, "ALERTE CONTROLEUR - aucune plateforme joignable")))
  verifier("Fire Control muet : aucun ordre emis a l'aveugle", #ordres(etat2) == 0)
end

--------------------------------------------------------------------------------
print("\n== TEST 7 : entites neutres ignorees par defaut ==")
do
  preparer(ZONE_ALPHA, ETAT_GUERRE)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC,
    programme = "command/command.lua",
    radar = function(t)
      if t < 5 then return { entities = {}, contraptions = {} } end
      return {
        entities = { { name = "Cow", type = "minecraft:cow", x = 50, y = 65, z = 0 } },
        contraptions = {},
      }
    end,
  })
  craftos.injecterRednet(3, INVENTAIRE, "frenchnet_fire_control")

  craftos.executer(BANC .. "/command/command.lua", 12)
  local s = etat.sorties

  verifier("entite neutre ignoree", (contient(s, "entite neutre ignoree")))
  verifier("aucun contact cree pour une vache", not contient(s, "nouveau contact Cow"))
  verifier("aucun ordre emis sur du bruit biologique", #ordres(etat) == 0)
end

--------------------------------------------------------------------------------
print("\n== TEST 8 : joueur au sol classe infanterie ==")
do
  preparer(ZONE_ALPHA, ETAT_GUERRE)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC,
    programme = "command/command.lua",
    radar = function(t)
      if t < 5 then return { entities = {}, contraptions = {} } end
      return {
        entities = { { name = "Intrus42", type = "minecraft:player", x = 80, y = 66, z = 0 } },
        contraptions = {},
      }
    end,
  })
  craftos.injecterRednet(3, INVENTAIRE, "frenchnet_fire_control")

  craftos.executer(BANC .. "/command/command.lua", 12)
  local s = etat.sorties

  verifier("joueur au sol classe infanterie",
    (contient(s, "cible Intrus42 classee INFANTERIE")))
  verifier("categorie transmise a Fire Control : Infantry",
    contientOrdre(etat, "SAM-Est Fire type Infantry")
    or contientOrdre(etat, "AirShip1 Fire type Infantry"),
    table.concat(ordres(etat), " | "))
end

--------------------------------------------------------------------------------
print("\n== TEST 9 : interface, bascule guerre / paix en un clic ==")
do
  preparer(ZONE_ALPHA, ETAT_PAIX)
  -- Cette fois l'interface EST installee : on verifie qu'elle se charge, se
  -- dessine, et que le bouton de l'ecran d'accueil bascule reellement le
  -- theatre - sans code d'acces, comme la doctrine l'exige.
  os.execute("cp " .. SRC .. "/interface.lua " .. BANC .. "/command/")

  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC,
    programme = "command/command.lua",
    radar = radarScenario(5, 15, function() return { x = 100, y = 150, z = 0 } end),
  })
  craftos.injecterRednet(3, INVENTAIRE, "frenchnet_fire_control")
  -- Clic sur le bouton THEATRE de l'ecran d'accueil (colonnes 12 a 23, ligne 4),
  -- puis une touche pour refermer l'ecran de confirmation.
  craftos.injecterEvenement("mouse_click", 1, 14, 4)
  craftos.injecterEvenement("key", "touche_enter")

  craftos.executer(BANC .. "/command/command.lua", 20)

  local f = io.open(BANC .. "/command/etat.dat", "r")
  local persiste = f and f:read("a") or ""
  if f then f:close() end

  verifier("l'interface se charge sans faire tomber le poste",
    not contient(etat.sorties, "interface interrompue"),
    (select(2, contient(etat.sorties, "interface interrompue"))) or "")
  verifier("l'interface prend la main sur l'affichage",
    not contient(etat.sorties, "interface.lua absent"))
  verifier("un clic bascule le theatre en GUERRE",
    persiste:find('mode = "GUERRE"', 1, true) ~= nil, persiste)
  verifier("la bascule est persistee sur disque pour survivre a un redemarrage",
    persiste:find("alerteMax", 1, true) ~= nil, persiste)

  -- La cible etait en zone Alpha : en paix comme en guerre, tout ce qui n'a pas
  -- le code allie est detruit avec scramble direct. L'ordre doit etre parti.
  verifier("les decisions continuent pendant que l'interface tourne",
    contientOrdre(etat, "SAM-Est Fire type Aerial"), table.concat(ordres(etat), " | "))
end

--------------------------------------------------------------------------------
print("\n== TEST 10 : persistance du journal fichier ==")
do
  local f = io.open(BANC .. "/command/command.log", "r")
  local contenu = f and f:read("a") or ""
  if f then f:close() end
  verifier("command.log ecrit sur le disque", #contenu > 0, "#" .. #contenu)
  verifier("le journal fichier porte les etapes",
    contenu:find("[etape: decision d'escalade]", 1, true) ~= nil)
end

--------------------------------------------------------------------------------
-- Trame de station radar deportee, telle que radar/radar.lua l'emet.
local function trameStation(nom, position, portee, contactsPour)
  return function(t)
    return {
      protocole = "FRENCHNET_RADAR", station = nom,
      x = position.x, y = position.y, z = position.z, portee = portee,
      contacts = contactsPour(t) or {},
    }
  end
end

-- Trame de balise de lanceur, telle que lanceur/lanceur.lua l'emet.
local function trameLanceur(nom, position, munitions, portee, categories)
  return function()
    return {
      protocole = "FRENCHNET_LANCEUR", nom = nom,
      x = position.x, y = position.y, z = position.z,
      portee = portee, munitions = munitions, tirs = 0,
      disponible = munitions > 0, categories = categories,
    }
  end
end

local SANS_RADAR_LOCAL = "radarLocal = false,"

--------------------------------------------------------------------------------
print("\n== TEST 11 : reseau multi-radars, une cible vue par deux stations ==")
do
  preparer(ZONE_ALPHA, ETAT_GUERRE, SANS_RADAR_LOCAL)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({ racine = BANC, programme = "command/command.lua" })

  -- Le MEME contact, avec le meme identifiant stable, rapporte par deux
  -- stations distinctes. Il ne doit produire QU'UNE piste : sinon le systeme
  -- tire deux fois sur un seul appareil et compte deux menaces.
  local function contact()
    return { { id = "ID:42", nom = "Raider-7", nature = "VEHICULE",
               x = 100, y = 150, z = 100 } }
  end
  craftos.programmerRednet(11, "frenchnet_radar", 2,
    trameStation("RAD-NORD", { x = 0, y = 80, z = 0 }, 500,
      function(t) if t >= 5 and t <= 9 then return contact() end return {} end))
  craftos.programmerRednet(12, "frenchnet_radar", 2,
    trameStation("RAD-SUD", { x = 0, y = 80, z = 400 }, 500,
      function(t) if t >= 5 and t <= 9 then return contact() end return {} end))
  craftos.programmerRednet(13, "frenchnet_lanceur", 5,
    trameLanceur("SAM-Est", { x = 150, y = 70, z = 0 }, 8, 600))
  craftos.programmerRednet(14, "frenchnet_lanceur", 5,
    trameLanceur("AirShip1", { x = 0, y = 200, z = 0 }, 8, 600))

  craftos.executer(BANC .. "/command/command.lua", 22)
  local s = etat.sorties
  local liste = ordres(etat)

  verifier("aucun radar local : le poste vit des stations deportees",
    (contient(s, "aucun radar local configure")))
  verifier("station nord entree dans le reseau",
    (contient(s, "station radar RAD-NORD entree dans le reseau")))
  verifier("station sud entree dans le reseau",
    (contient(s, "station radar RAD-SUD entree dans le reseau")))
  verifier("les deux plateformes se sont annoncees",
    (contient(s, "plateforme SAM-Est entree dans le reseau"))
    and (contient(s, "plateforme AirShip1 entree dans le reseau")))
  verifier("le contact est fusionne, pas duplique",
    (contient(s, "vu simultanement par 2 stations")))
  verifier("une seule detection pour un contact vu deux fois",
    compter(s, "nouveau contact Raider-7") == 1,
    "#" .. compter(s, "nouveau contact Raider-7"))
  verifier("un seul couple d'ordres (Alpha : destruction + scramble)",
    #liste == 2, table.concat(liste, " | "))
  verifier("la station la plus proche fournit la mesure",
    (contient(s, "vu par RAD-NORD")) or (contient(s, "RAD-NORD+RAD-SUD"))
    or (contient(s, "RAD-SUD+RAD-NORD")))
end

--------------------------------------------------------------------------------
print("\n== TEST 12 : designation par munitions, balises de lanceur ==")
do
  preparer(ZONE_ALPHA, ETAT_GUERRE, SANS_RADAR_LOCAL)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({ racine = BANC, programme = "command/command.lua" })

  craftos.programmerRednet(11, "frenchnet_radar", 2,
    trameStation("RAD-NORD", { x = 0, y = 80, z = 0 }, 500,
      function(t)
        if t >= 5 and t <= 9 then
          return { { id = "ID:7", nom = "Raider-7", nature = "VEHICULE",
                     x = 100, y = 150, z = 0 } }
        end
        return {}
      end))
  -- La rampe la plus proche est a sec ; la plus eloignee est pleine.
  craftos.programmerRednet(21, "frenchnet_lanceur", 5,
    trameLanceur("SAM-Sec", { x = 90, y = 70, z = 0 }, 0, 600))
  craftos.programmerRednet(22, "frenchnet_lanceur", 5,
    trameLanceur("SAM-Plein", { x = 400, y = 70, z = 0 }, 16, 600))
  craftos.programmerRednet(23, "frenchnet_lanceur", 5,
    trameLanceur("AirShip1", { x = 380, y = 200, z = 0 }, 16, 600))

  craftos.executer(BANC .. "/command/command.lua", 22)
  local s = etat.sorties

  verifier("stock epuise signale", (contient(s, "a court de munitions")))
  verifier("la rampe a sec est ecartee de la designation",
    (contient(s, "stock de munitions epuise")))
  verifier("aucun ordre a la rampe vide", not contientOrdre(etat, "SAM-Sec Fire type Aerial"))
  verifier("l'ordre de tir part vers une rampe approvisionnee",
    contientOrdre(etat, "SAM-Plein Fire type Aerial")
    or contientOrdre(etat, "AirShip1 Fire type Aerial"),
    table.concat(ordres(etat), " | "))
  verifier("le journal detaille le stock retenu", (contient(s, "munition(s),")))
end

--------------------------------------------------------------------------------
print("\n== TEST 13 : le scramble AG n'est jamais automatique ==")
do
  -- Battement raccourci : le rappel periodique des demandes en attente doit
  -- pouvoir etre observe dans la duree du banc.
  preparer(ZONE_CHARLIE, ETAT_PAIX, SANS_RADAR_LOCAL .. " battementSecondes = 10,")
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({ racine = BANC, programme = "command/command.lua" })

  -- Vehicule au sol inconnu en zone Charlie en paix : la doctrine appelle un
  -- scramble. Comme la cible est au sol, c'est un scramble AG : il ne doit
  -- PAS partir tout seul.
  craftos.programmerRednet(11, "frenchnet_radar", 2,
    trameStation("RAD-NORD", { x = 0, y = 80, z = 0 }, 500,
      function(t)
        if t >= 5 then
          return { { id = "ID:9", nom = "Convoi-3", nature = "VEHICULE",
                     x = 100, y = 70, z = 0 } }
        end
        return {}
      end))
  craftos.programmerRednet(22, "frenchnet_lanceur", 5,
    trameLanceur("Appui-1", { x = 120, y = 70, z = 0 }, 10, 600))

  craftos.executer(BANC .. "/command/command.lua", 25)
  local s = etat.sorties

  verifier("cible classee vehicule au sol", (contient(s, "classee VEHICULE_SOL")))
  verifier("la doctrine appelle bien un scramble",
    (contient(s, "palier 2 - scramble de verification")))
  verifier("aucun ordre transmis a Fire Control", #ordres(etat) == 0,
    table.concat(ordres(etat), " | "))
  verifier("une demande de scramble AG est enregistree",
    (contient(s, "AUCUN ordre transmis : un controleur doit valider")))
  verifier("la plateforme proposee est nommee", (contient(s, "plateforme Appui-1 designee")))
  verifier("le controleur est alerte",
    (contient(s, "ALERTE CONTROLEUR - scramble AG en attente de validation")))
  verifier("la demande n'est enregistree qu'une fois, pas a chaque balayage",
    compter(s, "AUCUN ordre transmis : un controleur doit valider") == 1,
    "#" .. compter(s, "AUCUN ordre transmis : un controleur doit valider"))
  verifier("la demande est rappelee au battement",
    (contient(s, "demande(s) de scramble AG toujours en attente")))
end

--------------------------------------------------------------------------------
print("\n== TEST 14 : projectiles ==")
do
  preparer(ZONE_ALPHA, ETAT_GUERRE, SANS_RADAR_LOCAL)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({ racine = BANC, programme = "command/command.lua" })

  craftos.programmerRednet(11, "frenchnet_radar", 2,
    trameStation("RAD-NORD", { x = 0, y = 80, z = 0 }, 500,
      function(t)
        if t < 5 then return {} end
        return {
          -- Obus identifie par la station : cible aerienne, meme au ras du sol.
          { id = "ID:OBUS", nom = "Obus", nature = "MISSILE", x = 60, y = 68, z = 0 },
          -- Contact anonyme trop rapide pour etre pilote : requalification
          -- cinematique par le poste central.
          { id = "ID:RAPIDE", nom = "Trace", nature = "VEHICULE",
            x = 100 + (t - 5) * 60, y = 150, z = 50 },
        }
      end))
  craftos.programmerRednet(22, "frenchnet_lanceur", 5,
    trameLanceur("SAM-Est", { x = 150, y = 70, z = 0 }, 20, 900))

  craftos.executer(BANC .. "/command/command.lua", 16)
  local s = etat.sorties

  verifier("obus classe cible aerienne malgre son altitude au sol",
    (contient(s, "cible Obus classee AERIENNE")))
  verifier("le motif nomme le projectile",
    (contient(s, "projectile detecte, cible aerienne par nature")))
  verifier("contact trop rapide requalifie projectile",
    (contient(s, "requalifie PROJECTILE")))
  verifier("le seuil de vitesse est journalise", (contient(s, "au-dela du seuil de")))
  verifier("les ordres portent bien la categorie aerienne",
    contientOrdre(etat, "SAM-Est Fire type Aerial"), table.concat(ordres(etat), " | "))
end

--------------------------------------------------------------------------------
print("\n== TEST 15 : carte tactique, du clic a l'ordre transmis ==")
do
  -- Scenario complet du poste de controle : la doctrine reclame un scramble
  -- AG sur un vehicule au sol, s'arrete et demande validation ; l'operateur
  -- ouvre la carte, clique sur le contact, coche le scramble, transmet.
  preparer(ZONE_CHARLIE, ETAT_PAIX, SANS_RADAR_LOCAL)
  os.execute("cp " .. SRC .. "/interface.lua " .. BANC .. "/command/")

  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({ racine = BANC, programme = "command/command.lua" })

  craftos.programmerRednet(11, "frenchnet_radar", 2,
    trameStation("RAD-NORD", { x = 0, y = 80, z = 0 }, 500,
      function(t)
        if t >= 3 then
          return { { id = "ID:9", nom = "Convoi-3", nature = "VEHICULE",
                     x = 100, y = 70, z = 0 } }
        end
        return {}
      end))
  craftos.programmerRednet(22, "frenchnet_lanceur", 5,
    trameLanceur("Appui-1", { x = 120, y = 70, z = 0 }, 10, 600))

  -- Onglet Carte (barre du bas), puis clic sur le contact au centre de la
  -- carte mouvante, case « Scramble AG », bouton TRANSMETTRE, touche pour
  -- refermer l'accuse de reception.
  craftos.programmerEvenement(10, "mouse_click", 1, 12, 19)
  craftos.programmerEvenement(12, "mouse_click", 1, 26, 8)
  craftos.programmerEvenement(14, "mouse_click", 1, 5, 15)
  craftos.programmerEvenement(16, "mouse_click", 1, 5, 16)
  craftos.programmerEvenement(18, "key", "touche_enter")

  craftos.executer(BANC .. "/command/command.lua", 26)
  local s = etat.sorties
  local liste = ordres(etat)

  verifier("l'interface et la carte se chargent sans faire tomber le poste",
    not contient(s, "interface interrompue"),
    (select(2, contient(s, "interface interrompue"))) or "")
  local journal = journalDisque()
  local function dansJournal(motif) return journal:find(motif, 1, true) ~= nil end

  verifier("la demande de scramble AG a bien ete levee par la doctrine",
    dansJournal("AUCUN ordre transmis : un controleur doit valider"))
  verifier("le controleur a transmis un ordre manuel",
    dansJournal("ORDRE MANUEL sur Convoi-3"))
  verifier("l'ordre manuel est trace comme tel, avec le verdict automatique",
    dansJournal("demande par un controleur"))
  verifier("la demande en attente est marquee validee",
    dansJournal("validee par un controleur"))
  verifier("l'ordre transmis porte le verbe air-sol",
    contientOrdre(etat, "Appui-1 Scramble AG type GroundVehicle"),
    table.concat(liste, " | "))
  verifier("un seul ordre est parti, celui du controleur", #liste == 1,
    table.concat(liste, " | "))
end

--------------------------------------------------------------------------------
print("\n== TEST 16 : transpondeur capture, les deux voies se contredisent ==")
do
  -- Le scenario qui justifie la seconde voie d'identification : un engin
  -- porte un code allie PARFAITEMENT VALIDE, mais Create Radars indique un
  -- proprietaire hostile. Avec une seule voie, il traversait la zone Alpha
  -- en toute impunite.
  preparer(ZONE_ALPHA, ETAT_GUERRE,
    SANS_RADAR_LOCAL .. ' nomsHostiles = { "RAID" }, nomsAllies = { "FR-" },')

  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({ racine = BANC, programme = "command/command.lua" })

  craftos.programmerRednet(11, "frenchnet_radar", 2,
    trameStation("RAD-NORD", { x = 0, y = 80, z = 0 }, 500,
      function(t)
        if t < 4 then return {} end
        return {
          -- Nom anodin, proprietaire hostile : c'est la metadonnee radar qui
          -- trahit l'engin, pas son nom.
          { id = "ID:INFILTRE", nom = "Vol-7", nature = "VEHICULE",
            x = 100, y = 150, z = 0, meta = { proprietaire = "RAID-Chef" } },
          -- Temoin : meme code allie, mais proprietaire ami. Doit passer.
          { id = "ID:AMI", nom = "FR-Rafale1", nature = "VEHICULE",
            x = 120, y = 150, z = 40, meta = { proprietaire = "FR-Pilote" } },
        }
      end))
  craftos.programmerRednet(22, "frenchnet_lanceur", 5,
    trameLanceur("SAM-Est", { x = 150, y = 70, z = 0 }, 20, 900))

  -- Les deux appareils emettent le MEME code allie, parfaitement valide.
  for _, cible in ipairs({ "Vol-7", "FR-Rafale1" }) do
    craftos.programmerRednet(30, "frenchnet_transpondeur", 4, function()
      return { protocole = "FRENCHNET_TRANSPONDEUR", identifiant = cible, nom = cible,
               code = "FN-ALLIE-0000" }
    end)
  end

  craftos.executer(BANC .. "/command/command.lua", 22)
  local s = etat.sorties

  verifier("la voie radar identifie l'infiltre par son proprietaire",
    (contient(s, "proprietaire 'RAID-Chef' figure sur la liste hostile")))
  verifier("les deux voies sont journalisees pour l'infiltre",
    (contient(s, "voie transpondeur ALLIE")) and (contient(s, "voie radar HOSTILE")))
  verifier("la discordance declasse le code : cible INCONNU",
    (contient(s, "DISCORDANCE des deux voies -> declasse INCONNU")))
  verifier("le controleur est alerte d'un transpondeur capture",
    (contient(s, "transpondeur probablement capture")))
  verifier("alerte controleur levee",
    (contient(s, "ALERTE CONTROLEUR - discordance d'identification")))
  verifier("l'infiltre est engage au lieu de passer",
    (contient(s, "cible Vol-7")) and (contient(s, "palier 3")))
  verifier("un ordre de tir est bien parti", #ordres(etat) > 0,
    table.concat(ordres(etat), " | "))

  -- Le temoin ne doit surtout pas etre pris dans la meme rafale.
  verifier("l'allie authentique est confirme par les deux voies",
    (contient(s, "cible FR-Rafale1")) and (contient(s, "concordance CONFIRME")))
  verifier("l'allie authentique reste en observation passive",
    (contient(s, "cible FR-Rafale1 (AERIENNE) : palier 1")))
  verifier("aucune discordance signalee sur l'allie authentique",
    compter(s, "ALERTE CONTROLEUR - discordance d'identification") == 1,
    "#" .. compter(s, "ALERTE CONTROLEUR - discordance d'identification"))
end

--------------------------------------------------------------------------------
print("\n== TEST 17 : moniteur 3x3 adopte comme ecran de situation ==")
do
  preparer(ZONE_ALPHA, ETAT_GUERRE, SANS_RADAR_LOCAL)
  os.execute("cp " .. SRC .. "/interface.lua " .. BANC .. "/command/")

  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC, programme = "command/command.lua",
    moniteur = { largeur = 3, hauteur = 3 },
  })

  craftos.programmerRednet(11, "frenchnet_radar", 2,
    trameStation("RAD-NORD", { x = 0, y = 80, z = 0 }, 500,
      function(t)
        if t >= 4 then
          return { { id = "ID:7", nom = "Raider-7", nature = "VEHICULE",
                     x = 100, y = 150, z = 0 } }
        end
        return {}
      end))
  craftos.programmerRednet(22, "frenchnet_lanceur", 5,
    trameLanceur("SAM-Est", { x = 150, y = 70, z = 0 }, 12, 600))

  craftos.executer(BANC .. "/command/command.lua", 20)
  local journal = journalDisque()
  local function dansJournal(motif) return journal:find(motif, 1, true) ~= nil end

  verifier("le moniteur est detecte sans aucun reglage",
    dansJournal("moniteur 'right' adopte comme ecran de situation"))
  verifier("une echelle de texte est choisie automatiquement",
    dansJournal("caracteres a l'echelle"))
  verifier("le moniteur a ete efface au moins une fois",
    (etat.moniteurEfface or 0) > 0, tostring(etat.moniteurEfface))
  verifier("la carte est reellement dessinee sur le moniteur",
    etat.moniteurEcrit ~= nil and #etat.moniteurEcrit > 0,
    "#" .. #(etat.moniteurEcrit or {}))
  verifier("le terminal est bien restaure apres chaque dessin",
    (etat.redirections or 0) % 2 == 0, tostring(etat.redirections))
  verifier("l'interface n'est pas tombee",
    not dansJournal("interface interrompue"))

  -- L'echelle retenue doit laisser au moins la carte minimale demandee.
  local largeur = etat.moniteur and select(1, etat.moniteur.getSize()) or 0
  local hauteur = etat.moniteur and select(2, etat.moniteur.getSize()) or 0
  verifier("l'echelle retenue laisse la place demandee pour la carte",
    largeur >= 50 and hauteur >= 20, string.format("%dx%d", largeur, hauteur))
end

--------------------------------------------------------------------------------
print("\n== TEST 18 : la console est gardee par un mot de passe ==")
do
  preparer(ZONE_ALPHA, ETAT_GUERRE, SANS_RADAR_LOCAL
    .. ' motDePasseConsole = "578933",')
  os.execute("cp " .. SRC .. "/interface.lua " .. BANC .. "/command/")

  local craftos = dofile(SCR .. "/craftos.lua")
  -- Deux tentatives : d'abord un mauvais mot de passe, puis le bon.
  local env, etat = craftos.creer({
    racine = BANC, programme = "command/command.lua",
    saisies = { "000000", "578933" },
  })

  craftos.programmerRednet(11, "frenchnet_radar", 2,
    trameStation("RAD-NORD", { x = 0, y = 80, z = 0 }, 500, function() return {} end))

  -- Ctrl+T : le poste ne doit PAS s'arreter, il doit demander le mot de passe.
  craftos.programmerEvenement(6, "terminate")
  craftos.programmerEvenement(9, "key", "touche_enter")   -- referme le refus
  craftos.programmerEvenement(12, "terminate")

  local motif = craftos.executer(BANC .. "/command/command.lua", 30)
  local journal = journalDisque()
  local function dansJournal(m) return journal:find(m, 1, true) ~= nil end

  verifier("Ctrl+T declenche une demande de mot de passe, pas un arret",
    dansJournal("Ctrl+T : mot de passe console demande"))
  verifier("un mot de passe incorrect est refuse",
    dansJournal("ACCES CONSOLE REFUSE"))
  verifier("le refus est compte", dansJournal("1 tentative(s)"))
  verifier("le bon mot de passe ouvre la console",
    dansJournal("acces console accorde"))
  verifier("le journal previent que la defense cesse de decider",
    dansJournal("cesse de decider"))
  verifier("le poste s'arrete proprement apres l'acces accorde",
    dansJournal("arret propre du poste"), tostring(motif))
end

--------------------------------------------------------------------------------
print("\n== TEST 19 : rotation des deux codes transpondeur ==")
do
  local noyauSeul = dofile(RACINE .. "/command/noyau.lua")
  -- Verification directe de la grace independante des deux codes : c'est ce
  -- qui evite qu'une rotation abatte la flotte qui n'a pas encore le nouveau
  -- code, et qu'une rotation de l'un ouvre une grace sur l'autre.
  local codes = {
    codeAllie = "A2", codeAlliePrecedent = "A1", rotationAllieA = 1000,
    codeGeneral = "G2", codeGeneralPrecedent = "G1", rotationGeneraleA = 500,
  }
  local cfg = { validiteTranspondeur = 15, graceRotation = 300 }
  local function statut(code)
    return (noyauSeul.statutIff({ code = code, recuA = 1000 }, codes, 1000, cfg))
  end
  verifier("nouveau code allie accepte", statut("A2") == "ALLIE")
  verifier("ancien code allie encore accepte dans la grace", statut("A1") == "ALLIE")
  verifier("nouveau code general accepte", statut("G2") == "GENERAL")
  verifier("ancien code general expire hors de sa propre grace",
    statut("G1") == "INCONNU")
  verifier("code inconnu toujours refuse", statut("XX") == "INCONNU")

  -- Persistance : un code tourne doit survivre au redemarrage, sinon toute la
  -- flotte reconfiguree redeviendrait INCONNUE au prochain rechargement.
  preparer(ZONE_ALPHA, ETAT_GUERRE, SANS_RADAR_LOCAL)
  local f = io.open(BANC .. "/command/etat.dat", "w")
  f:write([[{ mode = "GUERRE", alerteMax = false,
    codeAllie = "FN-ALLIE-TOURNE", codeAlliePrecedent = "FN-ALLIE-0000",
    rotationAllieA = 0,
    codeGeneral = "FN-GEN-TOURNE",
    codeAccesMenu = "9876", motDePasseConsole = "112233" }]])
  f:close()

  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({ racine = BANC, programme = "command/command.lua" })
  craftos.programmerRednet(11, "frenchnet_radar", 2,
    trameStation("RAD-NORD", { x = 0, y = 80, z = 0 }, 500,
      function(t)
        if t >= 4 then
          return { { id = "ID:1", nom = "Ally-1", nature = "VEHICULE",
                     x = 100, y = 150, z = 0 } }
        end
        return {}
      end))
  craftos.programmerRednet(30, "frenchnet_transpondeur", 4, function()
    return { protocole = "FRENCHNET_TRANSPONDEUR", identifiant = "Ally-1",
             nom = "Ally-1", code = "FN-ALLIE-TOURNE" }
  end)

  craftos.executer(BANC .. "/command/command.lua", 14)
  local s = etat.sorties

  verifier("le code allie tourne est restaure au demarrage",
    (contient(s, "code allie restaure depuis l'etat persistant")))
  verifier("un appareil portant le code tourne est reconnu allie",
    (contient(s, "transpondeur : code allie valide")))
  verifier("aucun avertissement de mot de passe d'usine apres changement",
    not contient(s, "motDePasseConsole laisse a sa valeur par defaut"))
end

--------------------------------------------------------------------------------
print("\n== TEST 20 : mesures anti-saccade ==")
do
  --[[
    Les trois causes de saccade cote serveur que le poste peut reellement
    reduire sont ici verifiees, pas supposees :
      - les ecritures disque du journal, groupees au lieu d'une ouverture de
        fichier par ligne ;
      - les ecritures sur le moniteur, differentielles au lieu d'un redessin
        complet a chaque image - or chaque modification d'un moniteur est un
        paquet envoye a tous les joueurs a portee ;
      - les trames reseau inutiles.
  ]]
  preparer(ZONE_ALPHA, ETAT_GUERRE, SANS_RADAR_LOCAL
    .. ' journalNiveauEcran = "DEBUG", journalNiveauFichier = "DEBUG",')
  os.execute("cp " .. SRC .. "/interface.lua " .. BANC .. "/command/")

  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC, programme = "command/command.lua",
    moniteur = { largeur = 3, hauteur = 3 },
  })

  -- Situation VOLONTAIREMENT STATIQUE : un contact immobile. C'est le cas le
  -- plus frequent en exploitation, et celui ou un redessin complet a chaque
  -- image est le plus gaspilleur.
  craftos.programmerRednet(11, "frenchnet_radar", 2,
    trameStation("RAD-NORD", { x = 0, y = 80, z = 0 }, 500,
      function(t)
        if t >= 4 then
          return { { id = "ID:7", nom = "Statique", nature = "VEHICULE",
                     x = 100, y = 150, z = 0 } }
        end
        return {}
      end))
  craftos.programmerRednet(22, "frenchnet_lanceur", 5,
    trameLanceur("SAM-Est", { x = 150, y = 70, z = 0 }, 12, 600))

  craftos.executer(BANC .. "/command/command.lua", 40)

  ------------------------------------------------------------ journal disque
  local journal = journalDisque()
  local lignes = 0
  for _ in journal:gmatch("[^\n]+") do lignes = lignes + 1 end
  local ouvertures = (etat.ouverturesPar or {})["command/command.log"] or 0

  verifier("le journal contient bien des lignes", lignes > 20, tostring(lignes))
  verifier(string.format(
    "%d ligne(s) de journal ecrites en %d ouverture(s) de fichier", lignes, ouvertures),
    ouvertures > 0 and ouvertures < lignes / 3,
    string.format("%d ouvertures pour %d lignes", ouvertures, lignes))

  ------------------------------------------------------------ moniteur
  local ecritures = #(etat.moniteurEcrit or {})
  verifier("le moniteur a bien ete dessine au moins une fois", ecritures > 0)
  -- 36 lignes redessinees a chaque image donneraient des milliers d'ecritures
  -- sur quarante secondes. Le differentiel doit les faire s'effondrer.
  verifier(string.format(
    "situation statique : seulement %d ecriture(s) sur le moniteur", ecritures),
    ecritures < 400, tostring(ecritures))

  ------------------------------------------------------------ annonce du poste
  local annonces = 0
  for _, d in ipairs(etat.diffusions) do
    if d.protocole == "frenchnet_annonce" then annonces = annonces + 1 end
  end
  verifier("le poste s'annonce pour que les stations cessent de diffuser",
    annonces > 0, tostring(annonces))
  verifier("l'annonce reste rare (une toutes les 30s par defaut)",
    annonces <= 3, tostring(annonces))

  local j = journalDisque()
  verifier("le numero de l'ordinateur est journalise au demarrage",
    j:find("Il s'annonce toutes les", 1, true) ~= nil)
end

--------------------------------------------------------------------------------
print(string.format("\n===== %d verification(s), %d echec(s) =====", total, echecs))
if echecs > 0 then os.exit(1) end
os.exit(0)
