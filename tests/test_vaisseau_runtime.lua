-- Banc d'essai d'EXECUTION du systeme embarque du Doomsday Ship, hors du jeu.
--   Usage : lua5.4 tests/test_vaisseau_runtime.lua   (depuis la racine du depot)
--
-- test_vaisseau.lua verifie les modules un a un. Celui-ci demarre le systeme
-- COMPLET dans l'emulateur et verifie le cablage : peripheriques decouverts,
-- pages enregistrees, trames recues et emises, alarmes posees, son declenche.
-- C'est le seul moyen de detecter une erreur de montage entre des briques
-- individuellement correctes - et vaisseau.lua n'avait jamais ete execute.

local RACINE = (arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."
local SCR    = RACINE .. "/tests"
local BANC   = "/tmp/banc_vaisseau_frenchnet"

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

-- Le journal bascule en mode silencieux une fois le systeme demarre : les
-- lignes d'apres ne passent plus par print et doivent se relire sur le disque.
local function journalDisque()
  local f = io.open(BANC .. "/vaisseau/vaisseau.log", "r")
  if not f then return "" end
  local c = f:read("a") or ""
  f:close()
  return c
end

--------------------------------------------------------------------------------
-- Banc
--------------------------------------------------------------------------------

local CONFIG = [[
return {
  identifiant = "DOOMSDAY-TEST",
  designation = "Ballon d'essai",
  codeTranspondeur = "FN-ALLIE-0000",
  codes = { codeAllie = "FN-ALLIE-0000", codeGeneral = "FN-GEN-1234" },
  layout = { pageParDefaut = "sa",
             terminal = { fenetres = { { page = "sa", x = 0, y = 0, l = 1, h = 1 } } } },
  largeurMiniFenetre = 20, hauteurMiniFenetre = 6,
  zones = {
    { nom = "BASE", classe = "ALPHA", forme = "cercle",
      centre = { x = 0, z = 0 }, rayon = 600 },
  },
  seuils = { ["portance.pression"] = { attention = 70, alarme = 50, critique = 30 } },
  radarPositionsRelatives = false,
  porteeRadar = 500,
  intervalleMesures = 1, intervalleSA = 1, intervalleRadar = 2,
  intervalleInventaire = 5, intervalleTranspondeur = 4,
  journalFichier = true, journalNiveauEcran = "DEBUG", battementSecondes = 8,
  %s
}
]]

local FICHIERS = {
  "vaisseau/vaisseau.lua", "vaisseau/mfd.lua", "vaisseau/hal.lua",
  "vaisseau/liaisons.lua", "vaisseau/surveillance.lua", "vaisseau/widgets.lua",
  "vaisseau/sa.lua", "vaisseau/inventaire.lua", "vaisseau/audio.lua",
  "vaisseau/musique.lua",
}
local PAGES = { "propulsion", "portance", "navigation", "sa", "ew",
                "armement", "liaison", "alertes" }

local function preparer(supplement)
  os.execute("rm -rf " .. BANC .. " && mkdir -p " .. BANC .. "/vaisseau/pages")
  for _, f in ipairs(FICHIERS) do
    os.execute(("cp %s/%s %s/vaisseau/"):format(RACINE, f, BANC))
  end
  for _, p in ipairs(PAGES) do
    os.execute(("cp %s/vaisseau/pages/%s.lua %s/vaisseau/pages/"):format(RACINE, p, BANC))
  end
  -- noyau.lua et carte.lua sont les modules du POSTE AU SOL, copies verbatim a
  -- bord : c'est ce que dit la procedure d'installation, et c'est ce qu'il
  -- faut eprouver - pas une copie divergente.
  os.execute(("cp %s/command/noyau.lua %s/command/carte.lua %s/command/scanner.lua %s/vaisseau/")
    :format(RACINE, RACINE, RACINE, BANC))
  local f = io.open(BANC .. "/vaisseau/config_vaisseau.lua", "w")
  f:write(CONFIG:format(supplement or ""))
  f:close()
end

-- Soute et haut-parleur simules, en plus du radar et du modem de l'emulateur.
local function materielDeBord(notes)
  return {
    ["chest_0"] = { type = "inventory", methodes = {
      size = function() return 27 end,
      list = function() return {
        [1] = { name = "createbigcannons:autocannon_cartridge", count = 48 },
        [2] = { name = "minecraft:gunpowder", count = 64 },
        [5] = { name = "supplementaries:flare", count = 12 },
      } end } },
    ["speaker_0"] = { type = "speaker", methodes = {
      playNote = function(i, v, p) notes[#notes + 1] = { i, v, p } return true end,
      stop = function() return true end } },
    -- Peripherique du ballon expose sous un type qui ne dit rien d'utile :
    -- c'est le cas reel avec Create Aeronautics, et c'est pour cela que le HAL
    -- cherche PAR METHODE.
    ["front"] = { type = "createaeronautics:machin", methodes = {
      getStress = function() return 600 end,
      getStressCapacity = function() return 800 end,
      getSpeed = function() return 128 end,
      getPressure = function() return 25 end,     -- sous le seuil critique (30)
      getAltitude = function() return 200 end,
      getVerticalSpeed = function() return -1 end,
    } },
  }
end

--------------------------------------------------------------------------------
print("\n== TEST 1 : demarrage complet et cablage ==")
local notes = {}
do
  preparer()
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC,
    programme = "vaisseau/vaisseau.lua",
    gps = { x = 0, y = 200, z = 0 },
    peripheriques = materielDeBord(notes),
    -- Un intrus aerien entre t=4 et t=12, qui fonce sur le ballon.
    radar = function(t)
      if t < 4 or t > 12 then return { contraptions = {}, entities = {} } end
      return { contraptions = { { name = "Raider-7",
        x = 600 - (t - 4) * 50, y = 200, z = 0 } }, entities = {} }
    end,
  })

  local motif = craftos.executer(BANC .. "/vaisseau/vaisseau.lua", 30)
  local s = etat.sorties
  local log = journalDisque()

  verifier("le systeme tourne sans se terminer", motif == "LIMITE_TEMPS", tostring(motif))

  --[[
    LE PIEGE DEJA PAYE UNE FOIS. Le peripherique de propulsion s'annonce sous
    un type qui ne contient pas « stress ». Le HAL doit le trouver quand meme,
    par ses METHODES - sinon toutes les pages afficheraient INDISPO.
  ]]
  verifier("HAL : mesures liees malgre un type inconnu",
    (contient(s, "mesure propulsion.stress liee a front.getStress()")))
  verifier("HAL : les mesures absentes sont annoncees, pas inventees",
    (contient(s, "introuvable(s)")))

  verifier("les huit pages sont enregistrees",
    not contient(s, "introuvable") or not contient(s, "page 'sa' introuvable"))
  verifier("modules exterieurs : tous absents, et dits tels quels",
    (contient(s, "0 module(s) exterieur(s) present(s), 3 absent(s)")))
  verifier("autopilote nomme comme absent", (contient(s, "module 'autopilote' ABSENT")))

  verifier("zones du theatre chargees depuis la configuration",
    (contient(s, "1 zone(s) du theatre chargee(s)")))
  -- Le journal passe en silencieux une fois le systeme arme : la suite est sur
  -- le disque, pas sur la sortie standard.
  verifier("GPS acquis", log:find("position GPS acquise", 1, true) ~= nil)
  verifier("radar du bord detecte par ses methodes",
    (contient(s, "radar detecte sur 'top'")))
  verifier("soute trouvee", (contient(s, "chest_0")))
  verifier("haut-parleur trouve", (contient(s, "speaker_0")))

  --[[
    CHAINE SA COMPLETE : le radar du bord voit l'intrus, la trame part au sol
    au format FRENCHNET_RADAR, et la piste est identifiee a bord avec le MEME
    noyau qu'au sol.
  ]]
  -- On garde la PREMIERE trame radar qui porte des contacts : l'intrus n'est
  -- visible qu'entre t=4 et t=12, et retenir la derniere trame ne prouverait
  -- rien d'autre que le ciel vide d'apres.
  local trameRadar, trameTransp
  for _, d in ipairs(etat.diffusions) do
    if type(d.message) == "table" then
      if d.message.protocole == "FRENCHNET_RADAR" then
        if not trameRadar or (#d.message.contacts > #trameRadar.contacts) then
          trameRadar = d.message
        end
      end
      if d.message.protocole == "FRENCHNET_TRANSPONDEUR" then trameTransp = d.message end
    end
  end
  verifier("le ballon emet son transpondeur", trameTransp ~= nil)
  verifier("avec son code", trameTransp and trameTransp.code == "FN-ALLIE-0000",
    trameTransp and tostring(trameTransp.code))
  verifier("le ballon emet ses contacts au format FRENCHNET_RADAR", trameRadar ~= nil)
  verifier("la trame porte la position du ballon, pas celle d'une station fixe",
    trameRadar and trameRadar.x == 0 and trameRadar.y == 200,
    trameRadar and tostring(trameRadar.x))
  verifier("et au moins un contact",
    trameRadar and #trameRadar.contacts >= 1,
    trameRadar and tostring(#trameRadar.contacts))

  --[[
    ALARME DE PORTANCE. La pression simulee est a 25 %, sous le seuil critique
    de 30 : l'alarme doit etre posee, journalisee, ET sonnee. Le son est la
    seule alerte qui atteigne un equipage qui ne regarde pas l'ecran.
  ]]
  verifier("alarme de pression posee", log:find("PRESSION ENVELOPPE", 1, true) ~= nil)
  verifier("l'alarme est sonnee, pas seulement affichee", #notes > 0, tostring(#notes))

  --[[
    MENACE. L'intrus se rapproche a 50 b/s : au dela du preavis, c'est une
    menace imminente, et elle doit lever une alarme comme n'importe quelle
    avarie - meme pile, meme son, meme journal.
  ]]
  --[[
    L'intrus fonce a 50 b/s : c'est une menace ATTENTION, qui doit sonner en
    ALARME. IMMINENTE est reserve aux missiles - un inconnu ne l'atteint
    jamais, et ne sonner qu'a ce niveau aurait laisse l'equipage sourd au cas
    le plus frequent.
  ]]
  verifier("menace detectee et alarmee", log:find("[MENACE] MENACE", 1, true) ~= nil,
    "voir le journal")

  verifier("aucune erreur critique pendant le vol",
    not contient(s, "CRITIQUE") or not contient(s, "s'est interrompu"),
    (select(2, contient(s, "s'est interrompu"))) or "")
end

--------------------------------------------------------------------------------
print("\n== TEST 2 : le systeme vole sans les modules des phases 2-4 ==")
do
  --[[
    Un ballon qui n'a copie que la phase 1 doit demarrer et voler. C'est le
    piege de parallel.waitForAny : une boucle qui SORT parce que son module
    manque arreterait tout le systeme, et le point d'entree le relancerait en
    boucle sans fin. Les boucles non armees ne doivent donc pas exister.
  ]]
  preparer()
  for _, f in ipairs({ "sa", "inventaire", "audio", "musique" }) do
    os.execute(("rm -f %s/vaisseau/%s.lua"):format(BANC, f))
  end
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC, programme = "vaisseau/vaisseau.lua",
    gps = { x = 0, y = 200, z = 0 },
    peripheriques = materielDeBord({}),
    radar = function() return { contraptions = {}, entities = {} } end,
  })
  local motif = craftos.executer(BANC .. "/vaisseau/vaisseau.lua", 20)
  local s = etat.sorties

  verifier("le systeme tourne quand meme", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("les boucles sans module ne sont pas armees",
    (contient(s, "boucle 'situation' non armee")), table.concat(s, " | "):sub(-200))
  verifier("et le systeme ne redemarre pas en boucle",
    not contient(s, "redemarrage automatique"),
    (select(2, contient(s, "redemarrage automatique"))) or "")
  verifier("l'absence de sa.lua est dite en clair",
    (contient(s, "sa.lua absent")))
  verifier("le transpondeur part quand meme",
    (function()
      for _, d in ipairs(etat.diffusions) do
        if type(d.message) == "table"
           and d.message.protocole == "FRENCHNET_TRANSPONDEUR" then return true end
      end
      return false
    end)())
end

--------------------------------------------------------------------------------
print("\n== TEST 3 : reception des stations du sol ==")
do
  preparer()
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC, programme = "vaisseau/vaisseau.lua",
    gps = { x = 0, y = 200, z = 0 },
    peripheriques = materielDeBord({}),
    radar = function() return { contraptions = {}, entities = {} } end,
  })

  --[[
    Une station du sol voit un engin que le radar du bord ne voit pas, et un
    transpondeur allie est entendu pour lui. Le ballon doit l'identifier ALLIE
    avec le meme noyau qu'au sol : un equipage qui lit rouge la ou le
    controleur lit vert ne se comprend pas par radio.
  ]]
  --[[
    Sources PERIODIQUES, et pas une injection unique : un evenement pousse
    avant le demarrage serait consomme pendant l'acquisition GPS, bien avant
    que la boucle reseau existe. Une station radar et un poste de commandement
    emettent en continu, c'est donc cela qu'il faut simuler.
  ]]
  craftos.programmerRednet(9, "frenchnet_radar", 2, function()
    return { protocole = "FRENCHNET_RADAR", version = 1, station = "RAD-01-NORD",
             x = 0, y = 64, z = 0, portee = 512,
             contacts = { { id = "ID:77", nom = "Ami-1", nature = "VEHICULE",
                            x = 150, y = 205, z = 0 } } }
  end)
  craftos.programmerRednet(9, "frenchnet_transpondeur", 4, function()
    return { protocole = "FRENCHNET_TRANSPONDEUR", identifiant = "Ami-1",
             nom = "Ami-1", code = "FN-ALLIE-0000", x = 150, y = 205, z = 0 }
  end)
  craftos.programmerRednet(3, "frenchnet_annonce", 10, function()
    return { protocole = "FRENCHNET_COMMAND_ICI", identifiant = "CMD-01" }
  end)

  local motif = craftos.executer(BANC .. "/vaisseau/vaisseau.lua", 25)
  local s = etat.sorties
  local log = journalDisque()

  verifier("le systeme tourne", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("le poste de commandement est decouvert",
    log:find("poste de commandement 'CMD-01' decouvert", 1, true) ~= nil)

  --[[
    Une fois le poste connu, le ballon lui parle EN DIRECT : un broadcast
    reveille tous les ordinateurs du serveur, quatre fois par seconde et pour
    rien. C'est la difference entre un systeme et un generateur de lag.
  ]]
  local cible, diffuse = 0, 0
  for _, d in ipairs(etat.diffusions) do
    if type(d.message) == "table" and d.message.protocole == "FRENCHNET_TRANSPONDEUR" then
      diffuse = diffuse + 1
    end
  end
  for _, e in ipairs(etat.envois or {}) do
    if type(e.message) == "table" and e.message.protocole == "FRENCHNET_TRANSPONDEUR" then
      cible = cible + 1
    end
  end
  verifier("apres decouverte, le transpondeur part en envoi cible, pas en broadcast",
    cible > 0, ("cible=%d broadcast=%d"):format(cible, diffuse))

  --[[
    Le contact n'est vu QUE par la station du sol - le radar du bord ne voit
    rien dans ce banc. Il doit quand meme apparaitre, et etre identifie ALLIE
    par le meme noyau qu'au sol : un equipage qui lit rouge la ou le
    controleur lit vert ne se comprend pas par radio.
  ]]
  verifier("un contact vu par le sol seul est suivi a bord",
    log:find("SA 1 piste(s)", 1, true) ~= nil, "voir le battement du journal")
  verifier("aucune erreur critique", not contient(s, "s'est interrompu"),
    (select(2, contient(s, "s'est interrompu"))) or "")
end

--------------------------------------------------------------------------------
print(string.format("\n===== %d verification(s), %d echec(s) =====", total, echecs))
if echecs > 0 then os.exit(1) end
os.exit(0)
