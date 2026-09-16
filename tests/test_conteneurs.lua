-- Banc d'essai de la section CONTENEURS de l'interface de reglage.
--   Usage : lua5.4 tests/test_conteneurs.lua   (depuis la racine du depot)
--
-- Cette section est la seule du schema a avoir une longueur variable : elle
-- decrit les conteneurs embarques d'un vehicule cargo, et c'est la page que
-- consomme le systeme de livraison FrenchNet. Trois risques a couvrir :
--   1. la serialisation doit rendre un VRAI tableau, relisible tel quel ;
--   2. les accesseurs doivent viser un indice numerique, pas une cle texte ;
--   3. ajouter, retirer et detecter ne doivent jamais laisser de trou.

local RACINE = (arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."
local SRC    = RACINE .. "/autopilote"

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
-- Environnement CraftOS minimal : de quoi charger le module et l'interface.
--------------------------------------------------------------------------------

local INVENTAIRES = { "minecraft:barrel_0", "minecraft:chest_0", "create:item_vault_0" }
local fichiers = {}   -- systeme de fichiers en memoire

local env = {}
for cle, valeur in pairs(_G) do env[cle] = valeur end

env.fs = {
  combine = function(a, b)
    a = (a or ""):gsub("/$", "")
    return (a == "" and b or (a .. "/" .. b))
  end,
  getDir = function(p) return (p or ""):match("^(.*)/[^/]*$") or "" end,
  exists = function(p) return fichiers[p] ~= nil or io.open(p, "r") ~= nil end,
  getSize = function(p) return #(fichiers[p] or "") end,
  delete = function(p) fichiers[p] = nil end,
  move = function(a, b) fichiers[b], fichiers[a] = fichiers[a], nil end,
  makeDir = function() end,
  open = function(p, mode)
    if mode == "r" then
      local contenu = fichiers[p]
      if not contenu then
        local f = io.open(p, "r")
        if not f then return nil end
        contenu = f:read("a")
        f:close()
      end
      return { readAll = function() return contenu end, close = function() end }
    end
    local morceaux = {}
    return {
      write     = function(t) morceaux[#morceaux + 1] = tostring(t) end,
      writeLine = function(t) morceaux[#morceaux + 1] = tostring(t) .. "\n" end,
      close     = function() fichiers[p] = table.concat(morceaux) end,
    }
  end,
}

env.peripheral = {
  getNames = function()
    local noms = { "back" }
    for _, nom in ipairs(INVENTAIRES) do noms[#noms + 1] = nom end
    return noms
  end,
  hasType = function(nom, type_)
    if nom == "back" then return type_ == "modem" end
    for _, n in ipairs(INVENTAIRES) do
      if n == nom then return type_ == "inventory" end
    end
    return nil
  end,
  wrap = function(nom)
    for _, n in ipairs(INVENTAIRES) do
      if n == nom then return { list = function() return {} end } end
    end
    return nil
  end,
  isPresent = function() return true end,
  getType = function() return "inventory" end,
}

env.term = setmetatable({
  getSize = function() return 51, 19 end,
  clear = function() end, setCursorPos = function() end,
  setTextColour = function() end, setBackgroundColour = function() end,
  setTextColor = function() end, setBackgroundColor = function() end,
  isColour = function() return false end, isColor = function() return false end,
  write = function() end, blit = function() end, clearLine = function() end,
  setCursorBlink = function() end, current = function() return {} end,
  redirect = function() return {} end, getCursorPos = function() return 1, 1 end,
}, { __index = function() return function() end end })

env.colors  = setmetatable({}, { __index = function() return 1 end })
env.colours = env.colors
env.keys    = setmetatable({}, { __index = function(_, cle) return cle end })
env.sleep   = function() end
env.write   = function() end
env.parallel = { waitForAny = function() end, waitForAll = function() end }
env.textutils = {
  serialise = tostring, serialize = tostring,
  formatTime = function() return "06:00" end,
}
env.os = setmetatable({
  clock = function() return 0 end,
  time  = function() return 6.0 end,
  day   = function() return 12 end,
  epoch = function() return 1754476800000 end,
  date  = os.date,
  startTimer = function() return 1 end,
  cancelTimer = function() end,
  queueEvent = function() end,
  pullEvent = function() return "terminate" end,
  pullEventRaw = function() return "terminate" end,
  getComputerID = function() return 7 end,
  getComputerLabel = function() return "CARGO" end,
  sleep = function() end,
}, { __index = os })

local function charger(chemin)
  local f = assert(io.open(chemin, "r"), "introuvable : " .. chemin)
  local source = f:read("a")
  f:close()
  return assert(load(source, "@" .. chemin, "t", env))()
end

env.dofile = function(chemin)
  if chemin == "/autopilote/autopilote.lua" then return charger(SRC .. "/autopilote.lua") end
  return charger(chemin)
end
env._G = env

--------------------------------------------------------------------------------
print("")
print("== A. Serialisation : le tableau de conteneurs survit a l'aller-retour")
--------------------------------------------------------------------------------

local autopilote = charger(SRC .. "/autopilote.lua")

local CONTENEURS = {
  { nom = "Soute avant", peripherique = "minecraft:barrel_0", role = "expedition",
    decalage = { x = -4, y = -1, z = 6 }, priorite = 1, capacite = 27 },
  { nom = "Coffre de recette", peripherique = "minecraft:chest_0", role = "recette",
    decalage = { x = 0, y = 1, z = 0 }, priorite = 1, capacite = 27 },
}

local configSource = {
  nom = "Cargo d'essai", identifiant = "CARGO-01",
  decalageGps = { x = 0, y = 2, z = 0 },
  decalageDepot = { x = 0, y = -3, z = 0 },
  conteneurs = CONTENEURS,
}

local texte = autopilote.serialiserConfig(configSource)
verifier("la section conteneurs est ecrite dans le fichier",
  texte:find("conteneurs", 1, true) ~= nil)
verifier("elle est commentee comme les autres sections",
  texte:find("Conteneurs embarques", 1, true) ~= nil)

local relu = assert(load(texte, "config", "t", {}))()
verifier("le fichier genere est du Lua valide qui rend une table",
  type(relu) == "table")
verifier("conteneurs est un VRAI tableau, pas une table a cles texte",
  type(relu.conteneurs) == "table" and #relu.conteneurs == 2,
  type(relu.conteneurs) == "table" and ("#=" .. #relu.conteneurs) or "absent")
verifier("le premier conteneur est intact",
  relu.conteneurs[1].nom == "Soute avant"
    and relu.conteneurs[1].peripherique == "minecraft:barrel_0"
    and relu.conteneurs[1].role == "expedition")
verifier("son decalage est intact",
  relu.conteneurs[1].decalage.x == -4 and relu.conteneurs[1].decalage.y == -1
    and relu.conteneurs[1].decalage.z == 6)
verifier("le conteneur de recette est intact",
  relu.conteneurs[2].role == "recette" and relu.conteneurs[2].decalage.y == 1)

--------------------------------------------------------------------------------
print("")
print("== B. Section dynamique : champs, accesseurs, detection")
--------------------------------------------------------------------------------

local interface = charger(SRC .. "/interface.lua")
local interne = interface.interne
verifier("l'interface expose ses rouages au banc d'essai", type(interne) == "table")

local config = { nom = "Cargo", identifiant = "CARGO-01", conteneurs = {
  { nom = "Soute", peripherique = "minecraft:barrel_0", role = "expedition",
    decalage = { x = 1, y = 2, z = 3 }, priorite = 1, capacite = 27 },
} }

local sections = interne.construireSections(config)
local indexConteneurs, indexVerrouillee
for i, section in ipairs(sections) do
  if section.titre == "Conteneurs" then indexConteneurs = i end
  if section.verrouille and not indexVerrouillee then indexVerrouillee = i end
end
verifier("la section Conteneurs existe", indexConteneurs ~= nil)
-- Elle est ajoutee EN FIN de liste, juste avant la section verrouillee : les
-- sections existantes gardent leur rang, donc aucune navigation apprise ne
-- change et les bancs d'essai de l'autopilote restent valables.
verifier("elle est inseree juste avant la section verrouillee, sans decaler les autres",
  indexVerrouillee and indexConteneurs == indexVerrouillee - 1,
  tostring(indexConteneurs) .. " -> " .. tostring(indexVerrouillee))
verifier("les sections fixes gardent leur rang d'origine",
  sections[1].titre == "Identite" and sections[2].titre == "Geometrie"
    and sections[3].titre == "Tolerances",
  sections[3] and sections[3].titre or "?")

local section = sections[indexConteneurs]
verifier("elle est marquee comme section de conteneurs", section.conteneurs == true)
-- 1 entete + 8 champs + 2 actions
verifier("un conteneur produit 11 lignes (entete, 8 champs, 2 actions)",
  #section.champs == 11, "#=" .. #section.champs)

local parLibelle = {}
for _, champ in ipairs(section.champs) do parLibelle[champ.libelle] = champ end
verifier("le peripherique se choisit dans la liste des inventaires detectes",
  parLibelle["Peripherique"] and parLibelle["Peripherique"].type == "choix"
    and #parLibelle["Peripherique"].options == 3,
  parLibelle["Peripherique"] and #parLibelle["Peripherique"].options or "absent")
verifier("le role se choisit parmi expedition, recette et tampon",
  parLibelle["Role"] and #parLibelle["Role"].options == 3
    and parLibelle["Role"].options[1] == "expedition")

local champX = parLibelle["Decalage x (tribord)"]
verifier("l'accesseur lit la valeur du bon conteneur", champX.lire(config) == 1)
champX.ecrire(config, -7)
verifier("l'accesseur ecrit dans l'INDICE NUMERIQUE, pas dans une cle texte",
  config.conteneurs[1].decalage.x == -7 and config.conteneurs["1"] == nil,
  tostring(config.conteneurs[1].decalage.x))
verifier("le tableau reste un tableau apres ecriture", #config.conteneurs == 1)

verifier("la detection rend les trois inventaires du reseau",
  #interne.inventairesDetectes() == 3,
  "#=" .. #interne.inventairesDetectes())
verifier("le modem n'est pas pris pour un inventaire", (function()
  for _, nom in ipairs(interne.inventairesDetectes()) do
    if nom == "back" then return false end
  end
  return true
end)())

--------------------------------------------------------------------------------
print("")
print("== C. Ajout, retrait et renumerotation")
--------------------------------------------------------------------------------

local c = { conteneurs = {
  { nom = "A", decalage = { x = 0, y = 0, z = 0 } },
  { nom = "B", decalage = { x = 0, y = 0, z = 0 } },
  { nom = "C", decalage = { x = 0, y = 0, z = 0 } },
} }
table.remove(c.conteneurs, 2)
local sections2 = interne.construireSections(c)
local section2
for _, s in ipairs(sections2) do if s.titre == "Conteneurs" then section2 = s end end
verifier("retirer celui du milieu ne laisse pas de trou",
  #c.conteneurs == 2 and c.conteneurs[1].nom == "A" and c.conteneurs[2].nom == "C")
verifier("la section est reconstruite sur le nouveau nombre",
  #section2.champs == 2 * 9 + 2, "#=" .. #section2.champs)

local dernier
for _, champ in ipairs(section2.champs) do
  if champ.type == "action" and champ.action == "detecter" then dernier = champ end
end
verifier("l'action de detection est proposee en bas de section", dernier ~= nil)

local videSections = interne.construireSections({})
local vide
for _, s in ipairs(videSections) do if s.titre == "Conteneurs" then vide = s end end
verifier("sans aucun conteneur, la section ne propose que ses deux actions",
  vide and #vide.champs == 2, vide and ("#=" .. #vide.champs) or "absente")

--------------------------------------------------------------------------------
print("")
print(string.format("== %d verification(s), %d echec(s)", total, echecs))
if echecs > 0 then os.exit(1) end
