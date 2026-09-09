-- Banc d'essai de l'arsenal et de la page Armement du systeme d'exploitation.
--   Usage : lua5.4 tests/test_armement.lua   (depuis la racine du depot)
--
-- Deux volets :
--   1. intercepteur/armement.lua  - choix de l'arme selon portee et utilite ;
--   2. systeme/arsenal_fichier.lua - lecture, validation, couverture de portee
--      et REECRITURE du fichier d'arsenal edite en jeu.
--
-- Le second volet a besoin d'un systeme de fichiers : on en simule un sur un
-- repertoire temporaire, ce qui permet de verifier que le fichier ecrit se
-- recharge vraiment - la seule garantie qui compte pour un fichier genere.

local RACINE = (arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."
local BANC   = "/tmp/banc_armement_frenchnet"

local echecs, total = 0, 0

local function verifier(nom, condition, detail)
  total = total + 1
  if condition then
    print(string.format("  [OK]   %s", nom))
  else
    echecs = echecs + 1
    print(string.format("  [ECHEC] %s %s", nom, detail and ("-> " .. tostring(detail)) or ""))
  end
end

--------------------------------------------------------------------------------
-- SYSTEME DE FICHIERS SIMULE
--------------------------------------------------------------------------------

local function creerFs(racine)
  local fs = {}
  local function reel(chemin)
    return racine .. "/" .. tostring(chemin):gsub("^/", "")
  end
  function fs.combine(a, b)
    a = (a or ""):gsub("^/", ""):gsub("/$", "")
    b = (b or ""):gsub("^/", "")
    if a == "" then return b end
    return a .. "/" .. b
  end
  function fs.getDir(p) p = p:gsub("^/", "") return p:match("^(.*)/[^/]*$") or "" end
  function fs.exists(p)
    local f = io.open(reel(p), "r")
    if f then f:close() return true end
    return false
  end
  function fs.makeDir(p) os.execute("mkdir -p '" .. reel(p) .. "'") end
  function fs.delete(p) os.remove(reel(p)) end
  function fs.open(p, mode)
    local f = io.open(reel(p), mode)
    if not f then return nil end
    return {
      readAll = function() return f:read("a") end,
      readLine = function() return f:read("l") end,
      write = function(s) f:write(tostring(s)) end,
      writeLine = function(s) f:write(tostring(s), "\n") end,
      close = function() f:close() end,
    }
  end
  return fs
end

-- Environnement minimal partage par les deux modules testes.
local env = setmetatable({}, { __index = _G })
env.fs = creerFs(BANC)
env.os = setmetatable({ date = os.date, clock = os.clock, time = os.time,
  epoch = function() return 1754476800000 end }, { __index = os })
env._G = env

local function charger(chemin, ...)
  local source = io.open(RACINE .. "/" .. chemin, "r"):read("a")
  return assert(load(source, "@" .. chemin, "t", env))(...)
end

os.execute("rm -rf " .. BANC .. " && mkdir -p " .. BANC .. "/intercepteur")

local noyau = charger("intercepteur/noyau.lua", "intercepteur")
-- Journal muet : ce banc mesure des decisions, pas des lignes de journal.
noyau.journal.fichierActif = false
noyau.journal.seuilEcran = 99

local armement = charger("intercepteur/armement.lua", noyau)
local arsenalF = charger("systeme/arsenal_fichier.lua")

--------------------------------------------------------------------------------
print("\n== TEST 1 : utilites et compatibilite des besoins ==")
do
  verifier("une arme anti-aerienne repond a un besoin anti-aerien",
    armement.repondA("anti-aerien", "anti-aerien"))
  verifier("une arme anti-aerienne ne repond PAS a un besoin anti-sol",
    armement.repondA("anti-aerien", "anti-sol") == false)
  verifier("une arme polyvalente repond a tout",
    armement.repondA("polyvalent", "anti-aerien")
    and armement.repondA("polyvalent", "anti-sol")
    and armement.repondA("polyvalent", "defensif"))
  verifier("une utilite inconnue ne repond a rien",
    armement.repondA("anti-navire", "anti-aerien") == false)
  verifier("utiliteValide reconnait les quatre utilites",
    armement.utiliteValide("anti-aerien") and armement.utiliteValide("anti-sol")
    and armement.utiliteValide("defensif") and armement.utiliteValide("polyvalent")
    and not armement.utiliteValide("laser"))
end

--------------------------------------------------------------------------------
print("\n== TEST 2 : declaration d'arme - anomalies bloquantes ==")
do
  local function anomalies(arme)
    local complete = { utilite = "polyvalent", mode = "peripherique",
      porteeMini = 10, porteeMaxi = 100, vitesseObus = 80 }
    for cle, valeur in pairs(arme) do complete[cle] = valeur end
    return table.concat(armement.verifierArme(complete), " | ")
  end

  verifier("declaration correcte : aucune anomalie", anomalies({}) == "", anomalies({}))
  verifier("utilite inconnue signalee",
    anomalies({ utilite = "anti-navire" }):find("inconnue", 1, true) ~= nil)
  verifier("portee mini >= maxi signalee",
    anomalies({ porteeMini = 200 }):find("portees incoherentes", 1, true) ~= nil)
  verifier("vitesse d'obus nulle signalee",
    anomalies({ vitesseObus = 0 }):find("vitesseObus", 1, true) ~= nil)
  verifier("mode inconnu signale",
    anomalies({ mode = "laser" }):find("inconnu", 1, true) ~= nil)
  verifier("mode redstone sans cote signale",
    anomalies({ mode = "redstone" }):find("coteRedstone", 1, true) ~= nil)
  verifier("mode redstone avec cote accepte",
    anomalies({ mode = "redstone", coteRedstone = "back" }) == "")
end

--------------------------------------------------------------------------------
print("\n== TEST 3 : choix de l'arme selon la portee et l'utilite ==")
do
  local arsenal = { coups = 0, armes = {
    { identifiant = "CANON-LONG", utilite = "anti-aerien", disponible = true,
      porteeMini = 200, porteeMaxi = 600, actif = true },
    { identifiant = "MITRA-COURT", utilite = "defensif", disponible = true,
      porteeMini = 10, porteeMaxi = 120, actif = true },
    { identifiant = "POLY", utilite = "polyvalent", disponible = true,
      porteeMini = 50, porteeMaxi = 500, actif = true },
    { identifiant = "MORTIER", utilite = "anti-sol", disponible = true,
      porteeMini = 30, porteeMaxi = 250, actif = true },
    { identifiant = "CASSE", utilite = "anti-aerien", disponible = false,
      porteeMini = 0, porteeMaxi = 900, actif = true },
  } }

  local arme = armement.choisir(arsenal, "anti-aerien", 400)
  verifier("a 400 blocs en anti-aerien : le canon long", arme.identifiant == "CANON-LONG",
    arme and arme.identifiant)

  arme = armement.choisir(arsenal, "defensif", 60)
  verifier("a 60 blocs en defensif : la mitrailleuse", arme.identifiant == "MITRA-COURT",
    arme and arme.identifiant)

  arme = armement.choisir(arsenal, "anti-sol", 100)
  verifier("a 100 blocs en anti-sol : le mortier specialise plutot que la polyvalente",
    arme.identifiant == "MORTIER", arme and arme.identifiant)

  -- 470 blocs : hors du mortier, dans le canon long ET la polyvalente ; le
  -- besoin anti-sol elimine le canon long, il ne reste que la polyvalente.
  arme = armement.choisir(arsenal, "anti-sol", 470)
  verifier("hors de portee du specialise : la polyvalente prend le relais",
    arme.identifiant == "POLY", arme and arme.identifiant)

  local motif
  arme, motif = armement.choisir(arsenal, "anti-aerien", 5)
  verifier("trop pres de toute arme : aucun choix", arme == nil, arme and arme.identifiant)
  verifier("  ... motif chiffre et exploitable",
    motif and motif:find("hors portee", 1, true) ~= nil, motif)

  arme, motif = armement.choisir(arsenal, "anti-aerien", 5000)
  verifier("trop loin de toute arme : aucun choix", arme == nil)

  -- Une arme indisponible n'est jamais retenue, meme si sa portee convient.
  arme = armement.choisir(arsenal, "anti-aerien", 800)
  verifier("une arme indisponible n'est jamais retenue", arme == nil,
    arme and arme.identifiant)

  verifier("distance ideale = centre de la fenetre de portee",
    armement.distanceIdeale(arsenal.armes[1]) == 400,
    armement.distanceIdeale(arsenal.armes[1]))
end

--------------------------------------------------------------------------------
print("\n== TEST 4 : preference pour le centre de la fenetre de portee ==")
do
  -- Deux armes polyvalentes se recouvrent : a 100 blocs, celle dont la fenetre
  -- est centree sur 100 doit gagner ; a 400, l'autre.
  local arsenal = { coups = 0, armes = {
    { identifiant = "COURTE", utilite = "polyvalent", disponible = true,
      porteeMini = 50, porteeMaxi = 150, actif = true },
    { identifiant = "LONGUE", utilite = "polyvalent", disponible = true,
      porteeMini = 100, porteeMaxi = 700, actif = true },
  } }
  verifier("a 100 blocs : l'arme courte, centree sur cette distance",
    armement.choisir(arsenal, "anti-aerien", 100).identifiant == "COURTE")
  verifier("a 400 blocs : l'arme longue, centree sur cette distance",
    armement.choisir(arsenal, "anti-aerien", 400).identifiant == "LONGUE")
end

--------------------------------------------------------------------------------
print("\n== TEST 5 : fichier d'arsenal - ecriture et relecture ==")
do
  local arsenal = {
    toleranceViseeDeg = 4,
    prioriteTirSurPosition = true,
    besoinParDefaut = "anti-aerien",
    margeAltitudeSol = 15,
    armes = {
      { identifiant = "CANON-AA-1", nom = "Canon 4 pouces", utilite = "anti-aerien",
        mode = "peripherique", porteeMini = 80, porteeMaxi = 420, vitesseObus = 80,
        graviteObus = 9.8, dureeRafale = 1.5, pauseRafale = 2.0,
        tangageMini = -60, tangageMaxi = 60, actif = true, note = "arme principale" },
      { identifiant = "MITRA-DEF", nom = "Mitrailleuse", utilite = "defensif",
        mode = "redstone", coteRedstone = "back", porteeMini = 10, porteeMaxi = 90,
        vitesseObus = 120, graviteObus = 4.0, actif = false },
    },
  }

  local ok, detail = arsenalF.enregistrer(arsenal)
  verifier("fichier d'arsenal ecrit", ok, detail)

  local relu, source = arsenalF.charger()
  verifier("fichier relu depuis le disque", source == arsenalF.CHEMIN, source)
  verifier("deux armes relues", #relu.armes == 2, #relu.armes)
  verifier("identifiants preserves",
    relu.armes[1].identifiant == "CANON-AA-1" and relu.armes[2].identifiant == "MITRA-DEF")
  verifier("portees preservees",
    relu.armes[1].porteeMini == 80 and relu.armes[1].porteeMaxi == 420)
  verifier("utilites preservees",
    relu.armes[1].utilite == "anti-aerien" and relu.armes[2].utilite == "defensif")
  verifier("valeurs decimales preservees", relu.armes[1].graviteObus == 9.8,
    relu.armes[1].graviteObus)
  verifier("booleen 'armee' preserve, y compris a false",
    relu.armes[1].actif == true and relu.armes[2].actif == false,
    tostring(relu.armes[1].actif) .. "/" .. tostring(relu.armes[2].actif))
  verifier("regle d'engagement preservee", relu.prioriteTirSurPosition == true)
  verifier("cote redstone preserve", relu.armes[2].coteRedstone == "back")

  -- Le fichier reste lisible et modifiable a la main.
  local contenu = env.fs.open(arsenalF.CHEMIN, "r").readAll()
  verifier("fichier commente", contenu:find("REGLE D'ENGAGEMENT", 1, true) ~= nil)
  verifier("fichier annonce sa provenance",
    contenu:find("page Armement du systeme d'exploitation", 1, true) ~= nil)
  verifier("note d'arme reportee en commentaire",
    contenu:find("-- arme principale", 1, true) ~= nil)
end

--------------------------------------------------------------------------------
print("\n== TEST 6 : validation avant ecriture ==")
do
  local anomalies = arsenalF.verifier({ armes = {} })
  verifier("arsenal vide refuse", #anomalies > 0, anomalies[1])

  anomalies = arsenalF.verifier({ armes = {
    { identifiant = "A", utilite = "polyvalent", porteeMini = 10, porteeMaxi = 100,
      mode = "peripherique", vitesseObus = 80, actif = true },
    { identifiant = "A", utilite = "polyvalent", porteeMini = 10, porteeMaxi = 100,
      mode = "peripherique", vitesseObus = 80, actif = true },
  } })
  verifier("identifiant duplique refuse", #anomalies > 0, anomalies[1])
  verifier("  ... message nommant l'arme en conflit",
    anomalies[1]:find("deja utilise", 1, true) ~= nil, anomalies[1])

  local _, armees = arsenalF.verifier({ armes = {
    { identifiant = "A", utilite = "polyvalent", porteeMini = 10, porteeMaxi = 100,
      mode = "peripherique", vitesseObus = 80, actif = true },
    { identifiant = "B", utilite = "polyvalent", porteeMini = 10, porteeMaxi = 100,
      mode = "peripherique", vitesseObus = 80, actif = false },
  } })
  verifier("comptage des armes reellement armees", armees == 1, armees)
end

--------------------------------------------------------------------------------
print("\n== TEST 7 : couverture de portee et trous ==")
do
  local couverture = arsenalF.couverture({ besoinParDefaut = "anti-aerien", armes = {
    { identifiant = "COURTE", utilite = "anti-aerien", porteeMini = 10,
      porteeMaxi = 100, actif = true },
    { identifiant = "LONGUE", utilite = "anti-aerien", porteeMini = 300,
      porteeMaxi = 600, actif = true },
  } }, "anti-aerien")

  verifier("couverture bornee correctement",
    couverture.mini == 10 and couverture.maxi == 600,
    tostring(couverture.mini) .. "-" .. tostring(couverture.maxi))
  verifier("TROU DE PORTEE detecte entre 100 et 300", #couverture.trous == 1
    and couverture.trous[1].de == 100 and couverture.trous[1].a == 300,
    #couverture.trous)

  local continue = arsenalF.couverture({ armes = {
    { identifiant = "A", utilite = "polyvalent", porteeMini = 10, porteeMaxi = 200,
      actif = true },
    { identifiant = "B", utilite = "polyvalent", porteeMini = 150, porteeMaxi = 600,
      actif = true },
  } }, "anti-aerien")
  verifier("fenetres qui se recouvrent : aucun trou", #continue.trous == 0)

  local desarmee = arsenalF.couverture({ armes = {
    { identifiant = "A", utilite = "anti-aerien", porteeMini = 10, porteeMaxi = 200,
      actif = false },
  } }, "anti-aerien")
  verifier("une arme desarmee ne couvre rien", desarmee.mini == nil)

  local mauvaisBesoin = arsenalF.couverture({ armes = {
    { identifiant = "A", utilite = "anti-sol", porteeMini = 10, porteeMaxi = 200,
      actif = true },
  } }, "anti-aerien")
  verifier("une arme d'une autre utilite ne couvre pas ce besoin",
    mauvaisBesoin.mini == nil)
end

--------------------------------------------------------------------------------
print("\n== TEST 8 : nouvelle arme et schema des champs ==")
do
  local arme = arsenalF.nouvelleArme(3)
  verifier("identifiant numerote", arme.identifiant == "ARME-03", arme.identifiant)
  verifier("valeurs par defaut coherentes",
    #armement.verifierArme(arme) == 0,
    table.concat(armement.verifierArme(arme), " | "))

  -- Chaque champ editable doit avoir un type exploitable par la page.
  local types = { texte = true, nombre = true, liste = true, booleen = true }
  local mauvais = {}
  for _, champ in ipairs(arsenalF.CHAMPS) do
    if not types[champ.type] then mauvais[#mauvais + 1] = champ.cle end
    if champ.type == "liste" and type(champ.valeurs) ~= "table" then
      mauvais[#mauvais + 1] = champ.cle .. " (liste sans valeurs)"
    end
  end
  verifier("tous les champs de la page ont un type exploitable",
    #mauvais == 0, table.concat(mauvais, ", "))
  verifier("le schema couvre la portee et l'utilite", (function()
    local vus = {}
    for _, champ in ipairs(arsenalF.CHAMPS) do vus[champ.cle] = true end
    return vus.porteeMini and vus.porteeMaxi and vus.utilite and vus.identifiant
  end)())
end

--------------------------------------------------------------------------------
print(string.format("\n===== %d/%d verifications reussies =====", total - echecs, total))
os.exit(echecs == 0 and 0 or 1)
