-- Mini-emulateur CraftOS pour tester le systeme de livraison hors du jeu.
-- Fournit : fs, term, colors, peripheral (modem + inventaires), rednet, gps,
-- parallel, sleep, os.pullEvent/startTimer/clock/day/time/epoch, textutils,
-- shell, read.
--
-- Les inventaires simules respectent le contrat de l'API "inventory" de
-- CC: Tweaked : list() est une table CREUSE, pushItems/pullItems retournent le
-- nombre d'objets REELLEMENT deplaces et ne deplacent jamais plus d'une pile
-- par appel. C'est ce qui permet de tester pour de vrai la logique de
-- prelevement sur un bulk container Create de plusieurs dizaines de milliers
-- d'objets.

local M = {}

local env = {}
local etat

local function shallow(t) local r = {} for k, v in pairs(t) do r[k] = v end return r end

----------------------------------------------------------------------------- fs
local function makeFs(racine)
  local fs = {}
  local function reel(chemin)
    chemin = chemin:gsub("^/", "")
    return racine .. "/" .. chemin
  end
  function fs.combine(a, b)
    a = (a or ""):gsub("^/", ""):gsub("/$", "")
    b = (b or ""):gsub("^/", "")
    if a == "" then return b end
    return a .. "/" .. b
  end
  function fs.getDir(p)
    p = (p or ""):gsub("^/", "")
    local d = p:match("^(.*)/[^/]*$")
    return d or ""
  end
  function fs.exists(p)
    local f = io.open(reel(p), "r")
    if f then f:close() return true end
    -- Un repertoire existe si on peut y lister quelque chose.
    return os.execute("test -d '" .. reel(p) .. "'") == true
  end
  function fs.isDir(p) return os.execute("test -d '" .. reel(p) .. "'") == true end
  function fs.makeDir(p) os.execute("mkdir -p '" .. reel(p) .. "'") end
  function fs.getSize(p)
    local f = io.open(reel(p), "r")
    if not f then return 0 end
    local n = f:seek("end")
    f:close()
    return n
  end
  function fs.delete(p) os.remove(reel(p)) end
  function fs.move(a, b) os.rename(reel(a), reel(b)) end
  function fs.open(p, mode)
    local f = io.open(reel(p), mode)
    if not f then return nil end
    return {
      readAll   = function() return f:read("a") end,
      readLine  = function() return f:read("l") end,
      writeLine = function(s) f:write(tostring(s), "\n") end,
      write     = function(s) f:write(tostring(s)) end,
      close     = function() f:close() end,
    }
  end
  return fs
end

--------------------------------------------------------------------- evenements
local function queueEvent(...)
  etat.file[#etat.file + 1] = table.pack(...)
end

local function prochainEvenement()
  if #etat.file > 0 then return table.remove(etat.file, 1) end
  local meilleur, id
  for tid, echeance in pairs(etat.minuteurs) do
    if not meilleur or echeance < meilleur then meilleur, id = echeance, tid end
  end
  if not meilleur then return nil end
  etat.horloge = math.max(etat.horloge, meilleur)
  etat.minuteurs[id] = nil
  return table.pack("timer", id)
end

--------------------------------------------------------------------- inventaires
local PILE_MAX_DEFAUT = 64

local function creerInventaire(nom, definition, registre)
  local inv = {}
  local contenu = {}
  for emplacement, pile in pairs(definition.contenu or {}) do
    contenu[emplacement] = { name = pile.name, count = pile.count,
                             maxCount = pile.maxCount or PILE_MAX_DEFAUT,
                             displayName = pile.displayName }
  end
  local taille = definition.taille or 27

  inv.__nom = nom
  inv.__contenu = contenu
  inv.__taille = taille

  function inv.size() return taille end

  function inv.list()
    -- Table CREUSE, comme dans CC: Tweaked.
    local resultat = {}
    for emplacement, pile in pairs(contenu) do
      if pile and pile.count > 0 then
        resultat[emplacement] = { name = pile.name, count = pile.count }
      end
    end
    return resultat
  end

  function inv.getItemDetail(emplacement)
    local pile = contenu[emplacement]
    if not pile or pile.count <= 0 then return nil end
    return { name = pile.name, count = pile.count,
             displayName = pile.displayName or pile.name,
             maxCount = pile.maxCount or PILE_MAX_DEFAUT }
  end

  -- Depose au plus 'quantite' objets 'nomObjet' ; retourne le nombre accepte.
  function inv.__accepter(nomObjet, quantite, maxCount)
    maxCount = maxCount or PILE_MAX_DEFAUT
    local accepte = 0
    -- 1) completer les piles existantes du meme objet
    for emplacement = 1, taille do
      if accepte >= quantite then break end
      local pile = contenu[emplacement]
      if pile and pile.count > 0 and pile.name == nomObjet then
        local place = math.max(0, (pile.maxCount or maxCount) - pile.count)
        local n = math.min(place, quantite - accepte)
        pile.count = pile.count + n
        accepte = accepte + n
      end
    end
    -- 2) occuper les emplacements vides
    for emplacement = 1, taille do
      if accepte >= quantite then break end
      local pile = contenu[emplacement]
      if not pile or pile.count <= 0 then
        local n = math.min(maxCount, quantite - accepte)
        contenu[emplacement] = { name = nomObjet, count = n, maxCount = maxCount }
        accepte = accepte + n
      end
    end
    return accepte
  end

  function inv.pushItems(nomCible, emplacement, limite, emplacementCible)
    etat.appelsPush = etat.appelsPush + 1
    local cible = registre[nomCible]
    if not cible then error("No such peripheral: " .. tostring(nomCible), 0) end
    local pile = contenu[emplacement]
    if not pile or pile.count <= 0 then return 0 end
    local maxCount = pile.maxCount or PILE_MAX_DEFAUT
    -- Un appel ne deplace jamais plus d'une pile : c'est la regle de CC.
    local voulu = math.min(limite or maxCount, maxCount, pile.count)
    local deplace = cible.__accepter(pile.name, voulu, maxCount)
    pile.count = pile.count - deplace
    if pile.count <= 0 then contenu[emplacement] = nil end
    return deplace
  end

  function inv.pullItems(nomSource, emplacement, limite, emplacementCible)
    etat.appelsPull = etat.appelsPull + 1
    local source = registre[nomSource]
    if not source then error("No such peripheral: " .. tostring(nomSource), 0) end
    return source.pushItems(nom, emplacement, limite, emplacementCible)
  end

  return inv
end

------------------------------------------------------------------- serialisation
local function serialiser(valeur, indentation)
  indentation = indentation or ""
  local t = type(valeur)
  if t == "number" or t == "boolean" then return tostring(valeur) end
  if t == "string" then return string.format("%q", valeur) end
  if t ~= "table" then return "nil" end
  local morceaux = { "{" }
  local interne = indentation .. "  "
  for cle, sous in pairs(valeur) do
    local cleTexte
    if type(cle) == "string" and cle:match("^[%a_][%w_]*$") then
      cleTexte = cle .. " = "
    else
      cleTexte = "[" .. serialiser(cle) .. "] = "
    end
    morceaux[#morceaux + 1] = interne .. cleTexte .. serialiser(sous, interne) .. ","
  end
  morceaux[#morceaux + 1] = indentation .. "}"
  return table.concat(morceaux, "\n")
end

local function deserialiser(texte)
  if type(texte) ~= "string" then return nil end
  local f = load("return " .. texte, "unserialise", "t", {})
  if not f then return nil end
  local ok, resultat = pcall(f)
  if not ok then return nil end
  return resultat
end

--------------------------------------------------------------------- construction
function M.creer(options)
  options = options or {}
  etat = {
    file = {}, minuteurs = {}, prochainMinuteur = 0, horloge = 0,
    sorties = {}, diffusions = {}, envois = {}, transmissions = {},
    modemPresent = true, rednetOuvert = false, echecBroadcast = false,
    inventaires = {}, appelsPush = 0, appelsPull = 0, planifie = {},
    gps = options.gps and shallow(options.gps) or nil,
    entrees = options.entrees or {},
    indiceEntree = 0,
  }
  M.etat = etat

  local fs = makeFs(options.racine)

  local osMock = {}
  osMock.clock = function() return etat.horloge end
  osMock.time = function() return 6.0 end
  osMock.day = function() return 12 end
  osMock.epoch = function() return 1754476800000 + math.floor(etat.horloge * 1000) end
  osMock.date = os.date
  osMock.getComputerID = function() return options.id or 11 end
  osMock.getComputerLabel = function() return options.label or "NAVIRE-TEST" end
  osMock.queueEvent = queueEvent
  osMock.reboot = function() error("REBOOT", 0) end
  osMock.startTimer = function(n)
    etat.prochainMinuteur = etat.prochainMinuteur + 1
    etat.minuteurs[etat.prochainMinuteur] = etat.horloge + (n or 0)
    return etat.prochainMinuteur
  end
  osMock.cancelTimer = function(id) etat.minuteurs[id] = nil end
  osMock.pullEventRaw = function(filtre) return coroutine.yield(filtre) end
  osMock.pullEvent = function(filtre)
    while true do
      local e = table.pack(coroutine.yield(filtre))
      if e[1] == "terminate" then error("Terminated", 0) end
      if filtre == nil or e[1] == filtre then return table.unpack(e, 1, e.n) end
    end
  end

  local function sleep(n)
    local id = osMock.startTimer(n or 0)
    while true do
      local _, tid = osMock.pullEvent("timer")
      if tid == id then return end
    end
  end

  osMock.sleep = sleep

  ------------------------------------------------------------------- peripheral
  local modem = {
    isWireless = function() return true end,
    open = function(c) etat.canaux = etat.canaux or {}; etat.canaux[c] = true end,
    isOpen = function(c) return (etat.canaux or {})[c] == true end,
    close = function(c) if etat.canaux then etat.canaux[c] = nil end end,
    transmit = function(canal, reponse, msg)
      etat.transmissions[#etat.transmissions + 1] =
        { canal = canal, reponse = reponse, message = msg, t = etat.horloge }
    end,
  }

  for nom, definition in pairs(options.inventaires or {}) do
    etat.inventaires[nom] = creerInventaire(nom, definition, etat.inventaires)
  end

  local peripheralMock = {}
  function peripheralMock.getNames()
    local noms = {}
    if etat.modemPresent then noms[#noms + 1] = "back" end
    for nom in pairs(etat.inventaires) do noms[#noms + 1] = nom end
    table.sort(noms)
    return noms
  end
  function peripheralMock.getType(n)
    if n == "back" then return etat.modemPresent and "modem" or nil end
    return etat.inventaires[n] and "inventory" or nil
  end
  function peripheralMock.isPresent(n)
    if n == "back" then return etat.modemPresent end
    return etat.inventaires[n] ~= nil
  end
  function peripheralMock.wrap(n)
    if n == "back" then return etat.modemPresent and modem or nil end
    return etat.inventaires[n]
  end
  function peripheralMock.hasType(n, t)
    if n == "back" then
      if not etat.modemPresent then return nil end
      return t == "modem" or t == "ender_modem"
    end
    if not etat.inventaires[n] then return nil end
    return t == "inventory"
  end
  function peripheralMock.getName(p) return p and p.__nom or nil end

  ----------------------------------------------------------------------- rednet
  local rednet = {}
  rednet.open = function(c)
    if not peripheralMock.isPresent(c) then error("No such modem: " .. c, 0) end
    etat.rednetOuvert = true
  end
  rednet.close = function() etat.rednetOuvert = false end
  rednet.isOpen = function() return etat.rednetOuvert and etat.modemPresent end
  rednet.broadcast = function(msg, proto)
    if etat.echecBroadcast then error("Network is unreachable", 0) end
    if not etat.rednetOuvert then error("No open side", 0) end
    etat.diffusions[#etat.diffusions + 1] = { message = msg, protocole = proto, t = etat.horloge }
  end
  rednet.send = function(id, msg, proto)
    if etat.echecBroadcast then error("Network is unreachable", 0) end
    if not etat.rednetOuvert then error("No open side", 0) end
    etat.envois[#etat.envois + 1] =
      { destinataire = id, message = msg, protocole = proto, t = etat.horloge }
    return true
  end
  rednet.receive = function(proto, timeout)
    local minuteur = timeout and osMock.startTimer(timeout) or nil
    while true do
      local e = table.pack(osMock.pullEvent())
      if e[1] == "rednet_message" and (proto == nil or e[4] == proto) then
        return e[2], e[3], e[4]
      elseif e[1] == "timer" and minuteur and e[2] == minuteur then
        return nil
      end
    end
  end

  -------------------------------------------------------------------------- gps
  local gps = {
    CHANNEL_GPS = 65534,
    locate = function(timeout)
      sleep(math.min(timeout or 2, 1))
      if etat.gps then return etat.gps.x, etat.gps.y, etat.gps.z end
      return nil
    end,
  }

  --------------------------------------------------------------------- parallel
  local parallel = {}
  local function courir(fns, limite)
    local routines, filtres = {}, {}
    for i, f in ipairs(fns) do routines[i] = coroutine.create(f) end
    local ev = { n = 0 }
    local mortes = 0
    while true do
      for i, r in ipairs(routines) do
        if r and (filtres[i] == nil or filtres[i] == ev[1] or ev[1] == "terminate") then
          local ok, param = coroutine.resume(r, table.unpack(ev, 1, ev.n))
          if not ok then error(param, 0) end
          filtres[i] = param
          if coroutine.status(r) == "dead" then
            routines[i] = false
            mortes = mortes + 1
            if mortes >= limite then return i end
          end
        end
      end
      ev = table.pack(coroutine.yield())
    end
  end
  parallel.waitForAny = function(...) return courir({ ... }, 1) end
  parallel.waitForAll = function(...) return courir({ ... }, select("#", ...)) end

  ------------------------------------------------------------------------ term
  local term = {
    clear = function() end,
    setCursorPos = function() end,
    isColour = function() return false end,
    isColor = function() return false end,
    setTextColour = function() end,
    setTextColor = function() end,
    getSize = function() return 51, 19 end,
  }

  ------------------------------------------------------------------ environnement
  env = shallow(_G)
  env.fs = fs
  env.os = osMock
  env.peripheral = peripheralMock
  env.rednet = rednet
  env.gps = gps
  env.parallel = parallel
  env.term = term
  env.sleep = sleep
  env.colors = setmetatable({}, { __index = function() return 1 end })
  env.colours = env.colors
  env.textutils = {
    formatTime  = function() return "06:00" end,
    serialise   = serialiser,
    serialize   = serialiser,
    unserialise = deserialiser,
    unserialize = deserialiser,
  }
  env.shell = { getRunningProgram = function() return options.programme or "navire/livraison.lua" end }
  env.write = function(s)
    etat.sorties[#etat.sorties + 1] = tostring(s)
    if options.verbeux then io.write(tostring(s)) end
  end
  env.read = function()
    etat.indiceEntree = etat.indiceEntree + 1
    local valeur = etat.entrees[etat.indiceEntree]
    if valeur == nil then error("PLUS_D_ENTREES", 0) end
    return valeur
  end
  env.printError = function(s) print("ERR " .. tostring(s)) end
  env.print = function(...)
    local morceaux = {}
    for i = 1, select("#", ...) do morceaux[#morceaux + 1] = tostring((select(i, ...))) end
    local ligne = table.concat(morceaux, "\t")
    etat.sorties[#etat.sorties + 1] = ligne
    if options.verbeux then print(ligne) end
  end
  env._G = env
  env.queueEvent = queueEvent
  env.modem = modem
  -- Utilise par l'autopilote factice du banc d'essai : deplace instantanement
  -- le navire en changeant la position rendue par le GPS.
  env.__bancGps = function(x, y, z) etat.gps = { x = x, y = y, z = z } end

  return env, etat
end

--------------------------------------------------------------------- execution
function M.executer(chemin, secondes)
  local fichier = io.open(chemin, "r")
  if not fichier then error("programme introuvable : " .. chemin, 0) end
  local source = fichier:read("a")
  fichier:close()
  local morceau = assert(load(source, "@" .. chemin, "t", env))
  local principal = coroutine.create(morceau)

  local ev = { n = 0 }
  local motif
  while coroutine.status(principal) ~= "dead" do
    local ok, err = coroutine.resume(principal, table.unpack(ev, 1, ev.n))
    if not ok then motif = err break end
    if etat.horloge > secondes then motif = "LIMITE_TEMPS" break end

    -- Actions programmees (injection d'une commande, depot d'un paiement,
    -- coupure du reseau...) : declenchees des que l'horloge virtuelle les
    -- rattrape, donc toujours APRES le demarrage complet du programme.
    local i = 1
    while i <= #etat.planifie do
      local action = etat.planifie[i]
      if action.t <= etat.horloge then
        table.remove(etat.planifie, i)
        action.fn(M, etat)
      else
        i = i + 1
      end
    end

    local suivant = prochainEvenement()
    if not suivant then motif = "PLUS_D_EVENEMENTS" break end
    ev = suivant
  end
  return motif, etat
end

-- Programme une action a l'instant virtuel 't' (en secondes).
function M.planifier(t, fn)
  etat.planifie[#etat.planifie + 1] = { t = t, fn = fn }
  -- Un minuteur garantit que l'horloge atteindra bien cet instant meme si le
  -- programme teste n'a plus rien d'autre a faire.
  etat.prochainMinuteur = etat.prochainMinuteur + 1
  etat.minuteurs[etat.prochainMinuteur] = t
end

function M.injecterRednet(id, message, protocole)
  queueEvent("rednet_message", id, message, protocole)
end

function M.injecterEvenement(...)
  queueEvent(...)
end

function M.horloge() return etat.horloge end

function M.contenu(nom)
  local inv = etat.inventaires[nom]
  if not inv then return nil end
  local totaux = {}
  for _, pile in pairs(inv.__contenu) do
    if pile and pile.count > 0 then
      totaux[pile.name] = (totaux[pile.name] or 0) + pile.count
    end
  end
  return totaux
end

function M.deposer(nom, nomObjet, quantite)
  local inv = etat.inventaires[nom]
  if not inv then return 0 end
  return inv.__accepter(nomObjet, quantite, 64)
end

function M.sorties() return etat.sorties end

return M
