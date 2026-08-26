-- Banc d'essai en vol : mini-CraftOS + simulateur de vehicule aerien.
-- Permet de rejouer l'autopilote hors du jeu, en boucle fermee : les commandes
-- calculees par le module pilotent reellement un modele physique, dont la
-- position est renvoyee au module par un GPS simule (avec bruit et decalage).

local M = {}

--------------------------------------------------------------------- utilitaires
local function shallow(t) local r = {} for k, v in pairs(t) do r[k] = v end return r end

local function borner(v, a, b) if v < a then return a end if v > b then return b end return v end

local function normaliserAngle(a)
  a = a % 360
  if a > 180 then a = a - 360 end
  return a
end

local function vecteurAvant(cap)
  local r = math.rad(cap)
  return { x = math.sin(r), z = -math.cos(r) }
end

local function vecteurTribord(cap)
  local r = math.rad(cap)
  return { x = math.cos(r), z = math.sin(r) }
end

----------------------------------------------------------------------------- fs
local function makeFs(racine)
  local fs = {}
  local function reel(chemin)
    chemin = tostring(chemin):gsub("^/", "")
    return racine .. "/" .. chemin
  end
  function fs.combine(a, b)
    a = (a or ""):gsub("^/", ""):gsub("/$", "")
    b = (b or ""):gsub("^/", "")
    if a == "" then return b end
    return a .. "/" .. b
  end
  function fs.getDir(p) p = p:gsub("^/", "") return p:match("^(.*)/[^/]*$") or "" end
  function fs.exists(p) local f = io.open(reel(p), "r") if f then f:close() return true end return false end
  function fs.getSize(p)
    local f = io.open(reel(p), "r") if not f then return 0 end
    local n = f:seek("end") f:close() return n
  end
  function fs.delete(p) os.remove(reel(p)) end
  function fs.move(a, b) os.rename(reel(a), reel(b)) end
  function fs.open(p, mode)
    local f = io.open(reel(p), mode)
    if not f then return nil end
    return {
      readAll  = function() return f:read("a") end,
      readLine = function() return f:read("l") end,
      writeLine= function(s) f:write(tostring(s), "\n") end,
      write    = function(s) f:write(tostring(s)) end,
      close    = function() f:close() end,
    }
  end
  return fs
end

------------------------------------------------------------- serialisation simple
local function serialiser(valeur, indent)
  indent = indent or ""
  local t = type(valeur)
  if t == "number" or t == "boolean" then return tostring(valeur) end
  if t == "string" then return string.format("%q", valeur) end
  if t ~= "table" then return "nil" end
  local morceaux = {}
  if #valeur > 0 then
    for _, v in ipairs(valeur) do morceaux[#morceaux + 1] = serialiser(v, indent .. " ") end
    return "{" .. table.concat(morceaux, ",") .. "}"
  end
  local cles = {}
  for k in pairs(valeur) do cles[#cles + 1] = tostring(k) end
  table.sort(cles)
  for _, k in ipairs(cles) do
    morceaux[#morceaux + 1] = string.format("[%q]=%s", k, serialiser(valeur[k], indent .. " "))
  end
  return "{" .. table.concat(morceaux, ",") .. "}"
end

local function deserialiser(texte)
  local f = load("return " .. tostring(texte), "=serialise", "t", {})
  if not f then return nil end
  local ok, v = pcall(f)
  return ok and v or nil
end

--------------------------------------------------------------------- simulateur
-- Modele du vehicule : reponse du premier ordre a chaque commande, integration
-- de la position dans le repere monde. Volontairement simple, mais suffisant
-- pour reveler un PID divergent, un depassement ou une erreur de signe.
local function creerVehicule(options)
  local v = {
    x = options.x or 0, y = options.y or 64, z = options.z or 0,
    cap = options.cap or 0,
    vAvant = 0, vLateral = 0, vVertical = 0, tauxLacet = 0,
    vMax        = options.vMax or 10,
    vVerticalMax= options.vVerticalMax or 5,
    vLateralMax = options.vLateralMax or 3,
    tauxMax     = options.tauxMax or 50,
    tau         = options.tau or 0.8,
    tauVertical = options.tauVertical or 0.6,
    tauLateral  = options.tauLateral or 0.5,
    tauLacet    = options.tauLacet or 0.4,
    inverseAvance = options.inverseAvance or false,
    commandes   = { avance = 0, vertical = 0, lacet = 0, lateral = 0 },
    distanceParcourue = 0,
  }

  function v.avancer(dt)
    local c = v.commandes
    local signeAvance = v.inverseAvance and -1 or 1
    local cibleAvant   = borner(c.avance or 0, -1, 1) * v.vMax * signeAvance
    local cibleLateral = borner(c.lateral or 0, -1, 1) * v.vLateralMax
    local cibleVertical= borner(c.vertical or 0, -1, 1) * v.vVerticalMax
    local cibleTaux    = borner(c.lacet or 0, -1, 1) * v.tauxMax

    local function relaxer(courant, cible, tau)
      local k = borner(dt / math.max(tau, 1e-6), 0, 1)
      return courant + (cible - courant) * k
    end

    v.vAvant    = relaxer(v.vAvant, cibleAvant, v.tau)
    v.vLateral  = relaxer(v.vLateral, cibleLateral, v.tauLateral)
    v.vVertical = relaxer(v.vVertical, cibleVertical, v.tauVertical)
    v.tauxLacet = relaxer(v.tauxLacet, cibleTaux, v.tauLacet)

    v.cap = normaliserAngle(v.cap + v.tauxLacet * dt)
    local avant, tribord = vecteurAvant(v.cap), vecteurTribord(v.cap)
    local dx = (avant.x * v.vAvant + tribord.x * v.vLateral) * dt
    local dz = (avant.z * v.vAvant + tribord.z * v.vLateral) * dt
    v.x = v.x + dx
    v.z = v.z + dz
    v.y = v.y + v.vVertical * dt
    v.distanceParcourue = v.distanceParcourue + math.sqrt(dx * dx + dz * dz)
  end

  return v
end

--------------------------------------------------------------------- environnement
function M.creer(options)
  options = options or {}
  local etat = {
    horloge = 0,
    pasSimulation = options.pasSimulation or 0.05,
    sorties = {},
    redstone = {},
    evenements = {},
    file = {},
    minuteurs = {},
    prochainMinuteur = 0,
    gpsActif = true,
    bruitGps = options.bruitGps or 0.15,
    graine = options.graine or 20260826,
    budget = options.budget or 600,
    facteurTempsReel = options.facteurTempsReel or 1,
    trace = {},
  }
  etat.vehicule = creerVehicule(options.vehicule or {})
  etat.decalageGps = options.decalageGps or { x = 0, y = 0, z = 0 }
  M.etat = etat

  -- Generateur pseudo-aleatoire local : les essais doivent etre reproductibles.
  local function alea()
    etat.graine = (etat.graine * 1103515245 + 12345) % 2147483648
    return etat.graine / 2147483648
  end

  local function avancerSimulation(duree)
    local restant = duree
    while restant > 1e-9 do
      local pas = math.min(etat.pasSimulation, restant)
      etat.vehicule.avancer(pas)
      etat.horloge = etat.horloge + pas
      restant = restant - pas
    end
    if options.tracer then
      etat.trace[#etat.trace + 1] = {
        t = etat.horloge, x = etat.vehicule.x, y = etat.vehicule.y, z = etat.vehicule.z,
        cap = etat.vehicule.cap,
      }
    end
  end

  local osMock = {}
  osMock.clock = function() return etat.horloge end
  osMock.time  = function() return 6.0 end
  osMock.day   = function() return 12 end
  osMock.epoch = function() return 1754476800000 + math.floor(etat.horloge * 1000 * etat.facteurTempsReel) end
  osMock.date  = os.date
  osMock.getComputerID = function() return options.id or 21 end
  osMock.getComputerLabel = function() return options.label or "AER-TEST" end
  osMock.queueEvent = function(...)
    local e = table.pack(...)
    etat.evenements[#etat.evenements + 1] = e
    etat.file[#etat.file + 1] = e
  end
  osMock.startTimer = function(n)
    etat.prochainMinuteur = etat.prochainMinuteur + 1
    etat.minuteurs[etat.prochainMinuteur] = etat.horloge + (n or 0)
    return etat.prochainMinuteur
  end
  osMock.cancelTimer = function(id) etat.minuteurs[id] = nil end
  osMock.pullEvent = function(filtre)
    while true do
      if #etat.file > 0 then
        local e = table.remove(etat.file, 1)
        if filtre == nil or e[1] == filtre then return table.unpack(e, 1, e.n) end
      else
        -- Rien en attente : on laisse le temps s'ecouler jusqu'au minuteur suivant.
        local meilleur, id
        for tid, echeance in pairs(etat.minuteurs) do
          if not meilleur or echeance < meilleur then meilleur, id = echeance, tid end
        end
        if not meilleur then error("Terminated", 0) end
        avancerSimulation(math.max(0, meilleur - etat.horloge))
        etat.minuteurs[id] = nil
        if filtre == nil or filtre == "timer" then return "timer", id end
      end
    end
  end
  osMock.reboot = function() error("REBOOT", 0) end

  --- sleep() fait avancer la simulation : c'est le moteur du banc d'essai.
  local function sleep(n)
    avancerSimulation(n or 0)
    if etat.horloge > etat.budget then
      -- Meme mecanisme que Ctrl+T : la seule erreur que ap.executer() laisse
      -- remonter, ce qui permet d'arreter proprement une boucle infinie.
      error("Terminated", 0)
    end
  end

  local gps = {
    CHANNEL_GPS = 65534,
    locate = function(timeout)
      if not etat.gpsActif then
        avancerSimulation(math.min(timeout or 2, 2))
        return nil
      end
      local v = etat.vehicule
      local avant, tribord = vecteurAvant(v.cap), vecteurTribord(v.cap)
      local d = etat.decalageGps
      local bruit = etat.bruitGps
      return
        v.x + d.z * avant.x + d.x * tribord.x + (alea() - 0.5) * 2 * bruit,
        v.y + d.y                             + (alea() - 0.5) * 2 * bruit,
        v.z + d.z * avant.z + d.x * tribord.z + (alea() - 0.5) * 2 * bruit
    end,
  }

  local redstoneMock = {
    setAnalogOutput = function(cote, valeur) etat.redstone[cote] = valeur end,
    getAnalogOutput = function(cote) return etat.redstone[cote] or 0 end,
    setOutput = function(cote, actif) etat.redstone[cote] = actif and 15 or 0 end,
    getOutput = function(cote) return (etat.redstone[cote] or 0) > 0 end,
  }

  ------------------------------------------------------------------ terminal
  -- Terminal a tampon : permet de verifier ce que l'interface affiche
  -- reellement, ligne par ligne.
  local LARGEUR_TERM, HAUTEUR_TERM = options.largeurTerm or 51, options.hauteurTerm or 19
  local tampon, curseur = {}, { x = 1, y = 1 }
  local function viderTampon()
    for ligne = 1, HAUTEUR_TERM do tampon[ligne] = string.rep(" ", LARGEUR_TERM) end
  end
  viderTampon()
  etat.tampon = tampon
  etat.ecrans = {}

  -- Chaque effacement d'ecran archive ce qui etait affiche : les essais
  -- peuvent ainsi verifier ce que l'interface a montre, meme apres coup.
  local function archiverPuisVider()
    local contenu = table.concat(tampon, "\n")
    if contenu:find("%S") then etat.ecrans[#etat.ecrans + 1] = contenu end
    viderTampon()
  end

  local termMock = {
    getSize = function() return LARGEUR_TERM, HAUTEUR_TERM end,
    clear = archiverPuisVider,
    clearLine = function()
      if tampon[curseur.y] then tampon[curseur.y] = string.rep(" ", LARGEUR_TERM) end
    end,
    setCursorPos = function(x, y) curseur.x, curseur.y = math.floor(x), math.floor(y) end,
    getCursorPos = function() return curseur.x, curseur.y end,
    setCursorBlink = function() end,
    isColour = function() return options.couleur ~= false end,
    isColor = function() return options.couleur ~= false end,
    setTextColour = function() end,
    setTextColor = function() end,
    setBackgroundColour = function() end,
    setBackgroundColor = function() end,
    write = function(texte)
      texte = tostring(texte)
      local ligne = tampon[curseur.y]
      if not ligne then return end
      local debut = curseur.x
      if debut < 1 then texte = texte:sub(2 - debut) debut = 1 end
      if debut > LARGEUR_TERM then return end
      texte = texte:sub(1, LARGEUR_TERM - debut + 1)
      tampon[curseur.y] = ligne:sub(1, debut - 1) .. texte .. ligne:sub(debut + #texte)
      curseur.x = debut + #texte
    end,
  }

  ---------------------------------------------------------------------- clavier
  local keysMock = {}
  do
    local noms = { "up", "down", "left", "right", "enter", "numPadEnter", "tab",
      "backspace", "delete", "home", "pageUp", "pageDown", "f2", "f3", "f4", "f5",
      "space", "one", "two", "three", "four", "five", "six", "seven", "eight",
      "nine", "zero" }
    local code = 200
    for _, nomTouche in ipairs(noms) do keysMock[nomTouche] = code code = code + 1 end
    keysMock["end"] = code code = code + 1
    for lettre = string.byte("a"), string.byte("z") do
      keysMock[string.char(lettre)] = lettre
    end
  end

  local env = shallow(_G)
  env.term      = termMock
  env.keys      = keysMock
  env.fs        = makeFs(options.racine)
  env.os        = osMock
  env.gps       = gps
  env.redstone  = redstoneMock
  env.rs        = redstoneMock
  env.sleep     = sleep
  env.peripheral= {
    getNames = function() return {} end,
    getType  = function() return nil end,
    isPresent= function() return false end,
    wrap     = function() return nil end,
  }
  env.colors  = setmetatable({}, { __index = function() return 1 end })
  env.colours = env.colors
  env.textutils = {
    serialise = serialiser, serialize = serialiser,
    unserialise = deserialiser, unserialize = deserialiser,
    formatTime = function() return "06:00" end,
  }
  env.parallel = {
    waitForAny = function(...)
      local fns = { ... }
      return fns[1]()
    end,
  }
  env.shell = { getRunningProgram = function()
    return options.programme or "missions/banc.lua"
  end }

  -- dofile passe par le systeme de fichiers simule ET par l'environnement
  -- simule : c'est ainsi que interface.lua charge autopilote.lua pendant les essais.
  env.dofile = function(chemin)
    local fichier = env.fs.open(chemin, "r")
    if not fichier then error("dofile : fichier introuvable " .. tostring(chemin), 0) end
    local source = fichier.readAll()
    fichier.close()
    local morceau, err = load(source, "@" .. chemin, "t", env)
    if not morceau then error(err, 0) end
    return morceau()
  end
  env.write = function() end
  env.printError = function(s) etat.sorties[#etat.sorties + 1] = "ERR " .. tostring(s) end
  env.print = function(...)
    local morceaux = {}
    for i = 1, select("#", ...) do morceaux[#morceaux + 1] = tostring((select(i, ...))) end
    local ligne = table.concat(morceaux, "\t")
    etat.sorties[#etat.sorties + 1] = ligne
    if options.verbeux then print(ligne) end
  end
  env._G = env
  env.avancerSimulation = avancerSimulation

  M.env = env
  return env, etat
end

--- Charge un fichier Lua dans l'environnement simule.
function M.charger(chemin)
  local source = io.open(chemin, "r"):read("a")
  local morceau = assert(load(source, "@" .. chemin, "t", M.env))
  return morceau()
end

function M.sorties() return M.etat.sorties end

function M.contient(motif)
  for _, ligne in ipairs(M.etat.sorties) do
    if ligne:find(motif, 1, true) then return true, ligne end
  end
  return false
end

--- Empile un evenement clavier a destination de l'interface.
function M.taper(touche)
  M.env.os.queueEvent("key", M.env.keys[touche] or touche)
end

--- Empile un relachement de touche (pilotage manuel).
function M.relacher(touche)
  M.env.os.queueEvent("key_up", M.env.keys[touche] or touche)
end

--- Empile une suite de caracteres (saisie de texte).
function M.tapeTexte(texte)
  for i = 1, #texte do M.env.os.queueEvent("char", texte:sub(i, i)) end
end

--- Tout ce que l'interface a affiche : ecran courant et ecrans precedents.
function M.ecranTexte()
  local morceaux = { table.concat(M.etat.tampon, "\n") }
  for _, contenu in ipairs(M.etat.ecrans) do morceaux[#morceaux + 1] = contenu end
  return table.concat(morceaux, "\n")
end

--- Contenu du seul ecran courant.
function M.ecranCourant()
  return table.concat(M.etat.tampon, "\n")
end

--- Pilote de sorties injectable : relie directement les commandes calculees
-- par l'autopilote au modele physique du banc (comme le ferait le cablage
-- reel du vehicule).
function M.pilote()
  return {
    appliquer = function(commandes)
      M.etat.vehicule.commandes = {
        avance   = commandes.avance or 0,
        vertical = commandes.vertical or 0,
        lacet    = commandes.lacet or 0,
        lateral  = commandes.lateral or 0,
      }
    end,
    arreter = function()
      M.etat.vehicule.commandes = { avance = 0, vertical = 0, lacet = 0, lateral = 0 }
    end,
  }
end

--- Distance horizontale entre le vehicule simule et un point.
function M.distanceH(point)
  local v = M.etat.vehicule
  local dx, dz = point.x - v.x, point.z - v.z
  return math.sqrt(dx * dx + dz * dz)
end

return M
