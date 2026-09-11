-- Mini-emulateur CraftOS pour tester balise.lua hors du jeu.
-- Fournit : fs, term, colors, peripheral, rednet, gps, parallel, sleep,
-- os.pullEvent/startTimer/clock/day/time/epoch, textutils, shell.

local M = {}

local env = {}   -- environnement global du programme teste
local etat       -- etat mutable du banc d'essai

--------------------------------------------------------------------- utilitaires
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
    p = p:gsub("^/", "")
    local d = p:match("^(.*)/[^/]*$")
    return d or ""
  end
  function fs.exists(p)
    local f = io.open(reel(p), "r")
    if f then f:close() return true end
    return false
  end
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
    -- Compteur d'ouvertures de fichier : ouvrir et fermer un fichier a chaque
    -- ligne de journal est une operation disque a chaque fois, et l'une des
    -- causes de saccade les plus faciles a supprimer. Le banc doit pouvoir le
    -- verifier, pas seulement le supposer.
    if etat then
      etat.ouverturesFichier = (etat.ouverturesFichier or 0) + 1
      etat.ouverturesPar = etat.ouverturesPar or {}
      etat.ouverturesPar[p] = (etat.ouverturesPar[p] or 0) + 1
    end
    local f = io.open(reel(p), mode)
    if not f then return nil end
    return {
      readAll = function() return f:read("a") end,
      readLine = function() return f:read("l") end,
      writeLine = function(s) f:write(tostring(s), "\n") end,
      write = function(s) f:write(tostring(s)) end,
      close = function() f:close() end,
    }
  end
  return fs
end

--------------------------------------------------------------------- evenements
local function queueEvent(...)
  etat.file[#etat.file + 1] = table.pack(...)
end

-- Emissions rednet PERIODIQUES. Une station radar ou une balise de lanceur
-- emet en continu : la tester avec une seule trame injectee au demarrage ne
-- prouverait rien, puisque le poste central declare muette toute source qui
-- se tait. La fabrique recoit l'horloge virtuelle et rend la trame a envoyer.
local function declencherProgrammes()
  -- Evenements a date fixe : un clic d'operateur n'a de sens qu'une fois la
  -- situation etablie a l'ecran.
  for _, e in ipairs(etat.evenementsProgrammes or {}) do
    if not e.emis and e.instant <= etat.horloge then
      e.emis = true
      queueEvent(table.unpack(e.args, 1, e.args.n))
    end
  end
  for _, p in ipairs(etat.programmes or {}) do
    local garde = 0
    while p.prochain <= etat.horloge and p.intervalle > 0 and garde < 1000 do
      local message = p.fabrique(etat.horloge)
      if message then queueEvent("rednet_message", p.id, message, p.protocole) end
      p.prochain = p.prochain + p.intervalle
      garde = garde + 1
    end
  end
end

local function prochainEvenement()
  if #etat.file > 0 then
    return table.remove(etat.file, 1)
  end
  -- File vide : on avance l'horloge virtuelle jusqu'au prochain minuteur.
  local meilleur, id
  for tid, echeance in pairs(etat.minuteurs) do
    if not meilleur or echeance < meilleur then meilleur, id = echeance, tid end
  end
  if not meilleur then return nil end
  etat.horloge = math.max(etat.horloge, meilleur)
  etat.minuteurs[id] = nil
  declencherProgrammes()
  return table.pack("timer", id)
end

--------------------------------------------------------------------- construction
function M.creer(options)
  options = options or {}
  etat = {
    file = {},
    minuteurs = {},
    prochainMinuteur = 0,
    horloge = 0,
    sorties = {},
    diffusions = {},
    envois = {},
    transmissions = {},
    modemPresent = true,
    rednetOuvert = false,
    echecBroadcast = false,
    limiteHorloge = options.limiteHorloge or 300,
    programmes = {},
    evenementsProgrammes = {},
  }
  M.etat = etat

  local fs = makeFs(options.racine)

  local osMock = {}
  osMock.clock = function() return etat.horloge end
  osMock.time = function() return 6.0 end
  osMock.day = function() return 12 end
  osMock.epoch = function() return 1754476800000 + math.floor(etat.horloge * 1000) end
  osMock.date = os.date
  osMock.getComputerID = function() return options.id or 7 end
  osMock.getComputerLabel = function() return options.label or "BALISE-TEST" end
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

  -- Radar simule (Create Radars). options.radar est une fonction qui recoit
  -- l'horloge virtuelle et rend { entities = {...}, contraptions = {...} }.
  -- Elle permet de scenariser une trajectoire complete : approche, tir, crash
  -- ou fuite, sans jamais lancer Minecraft.
  local radar
  if options.radar then
    radar = {
      getEntities = function()
        local r = options.radar(etat.horloge) or {}
        return r.entities or {}
      end,
      getContraptions = function()
        local r = options.radar(etat.horloge) or {}
        return r.contraptions or {}
      end,
    }
  end

  --[[
    Moniteur simule. La taille en caracteres depend de l'echelle de texte,
    comme dans le jeu : c'est indispensable pour tester le choix automatique
    d'echelle, qui cherche la plus grande echelle encore assez large.
    Modele : un bloc fait 64 pixels, un caractere 6x9 pixels a l'echelle 1.
  ]]
  local moniteur
  if options.moniteur then
    local blocsL = options.moniteur.largeur or 3
    local blocsH = options.moniteur.hauteur or 3
    local echelle = 1
    moniteur = {
      setTextScale = function(e) echelle = e end,
      getTextScale = function() return echelle end,
      getSize = function()
        return math.max(1, math.floor((blocsL * 64 - 16) / (6 * echelle))),
               math.max(1, math.floor((blocsH * 64 - 16) / (9 * echelle)))
      end,
      isColour = function() return options.moniteur.couleur ~= false end,
      isColor = function() return options.moniteur.couleur ~= false end,
      clear = function() etat.moniteurEfface = (etat.moniteurEfface or 0) + 1 end,
      clearLine = function() end,
      setCursorPos = function(x, y) etat.moniteurCurseur = { x, y } end,
      getCursorPos = function() return 1, 1 end,
      setTextColour = function() end, setTextColor = function() end,
      setBackgroundColour = function() end, setBackgroundColor = function() end,
      write = function(texte)
        etat.moniteurEcrit = etat.moniteurEcrit or {}
        etat.moniteurEcrit[#etat.moniteurEcrit + 1] = tostring(texte)
      end,
      blit = function(texte)
        etat.moniteurEcrit = etat.moniteurEcrit or {}
        etat.moniteurEcrit[#etat.moniteurEcrit + 1] = tostring(texte)
      end,
    }
    etat.moniteur = moniteur
  end

  --[[
    Peripheriques libres, en plus des trois cables en dur ci-dessus.
      options.peripheriques = { ["speaker_0"] = { type = "speaker",
                                                  methodes = { playNote = fn } } }
    Sans cela, impossible d'eprouver hors du jeu un systeme qui lit des coffres
    ou fait sonner un haut-parleur : ce sont justement les parties dont on veut
    savoir si elles sont branchees.
  ]]
  local extras = options.peripheriques or {}
  local nomsExtras = {}
  for nom in pairs(extras) do nomsExtras[#nomsExtras + 1] = nom end
  table.sort(nomsExtras)

  local function presents()
    local noms = {}
    if etat.modemPresent then noms[#noms + 1] = "back" end
    if radar then noms[#noms + 1] = "top" end
    if moniteur then noms[#noms + 1] = "right" end
    for _, nom in ipairs(nomsExtras) do noms[#noms + 1] = nom end
    return noms
  end

  local peripheralMock = {
    getNames = presents,
    getType = function(n)
      if extras[n] then return extras[n].type or "peripheral" end
      if n == "back" then return etat.modemPresent and "modem" or nil end
      if n == "top" and radar then return "createradars:radar" end
      if n == "right" and moniteur then return "monitor" end
      return nil
    end,
    isPresent = function(n)
      if extras[n] then return true end
      if n == "back" then return etat.modemPresent end
      if n == "right" then return moniteur ~= nil end
      return n == "top" and radar ~= nil
    end,
    wrap = function(n)
      if extras[n] then return extras[n].methodes end
      if n == "back" then return etat.modemPresent and modem or nil end
      if n == "top" then return radar end
      if n == "right" then return moniteur end
      return nil
    end,
    hasType = function(n, t)
      if extras[n] then return extras[n].type == t end
      if n == "top" and radar then return t == "peripheral" or t:find("radar", 1, true) ~= nil end
      if not etat.modemPresent then return nil end
      return t == "modem" or t == "ender_modem"
    end,
  }

  -- peripheral.call, absent jusqu'ici : le HAL, les soutes et l'avertisseur
  -- sonore passent tous par lui. Sans lui, toute mesure serait declaree
  -- indisponible dans l'emulateur et le banc ne prouverait rien.
  peripheralMock.call = function(n, methode, ...)
    local enveloppe = peripheralMock.wrap(n)
    if type(enveloppe) ~= "table" or type(enveloppe[methode]) ~= "function" then
      error(("no such method %s on %s"):format(tostring(methode), tostring(n)), 0)
    end
    return enveloppe[methode](...)
  end

  ----------------------------------------------------------------------- rednet
  local rednet = {}
  rednet.open = function(c)
    if not peripheralMock.isPresent(c) then error("No such modem: " .. c, 0) end
    etat.rednetOuvert = true
  end
  rednet.isOpen = function() return etat.rednetOuvert and etat.modemPresent end
  rednet.broadcast = function(msg, proto)
    if etat.echecBroadcast then error("Network is unreachable", 0) end
    if not etat.rednetOuvert then error("No open side", 0) end
    etat.diffusions[#etat.diffusions + 1] = { message = msg, protocole = proto, t = etat.horloge }
  end
  rednet.send = function(destinataire, msg, proto)
    if not etat.rednetOuvert then error("No open side", 0) end
    etat.envois[#etat.envois + 1] =
      { destinataire = destinataire, message = msg, protocole = proto, t = etat.horloge }
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
      sleep(math.min(timeout or 2, 2))
      if options.gps then return options.gps.x, options.gps.y, options.gps.z end
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
  --[[
    term REDIRIGEABLE pour de vrai. L'interface redirige temporairement vers
    le moniteur pour y dessiner la carte avec les memes primitives : un
    bouchon qui ignore la redirection ne testerait rien de ce mecanisme.
  ]]
  local terminalNatif = {
    clear = function() end,
    clearLine = function() end,
    setCursorPos = function() end,
    getCursorPos = function() return 1, 1 end,
    isColour = function() return false end,
    isColor = function() return false end,
    setTextColour = function() end,
    setTextColor = function() end,
    setBackgroundColour = function() end,
    setBackgroundColor = function() end,
    write = function() end,
    blit = function() end,
    getSize = function() return 51, 19 end,
  }

  local cibleTerm = terminalNatif
  local term = {}
  for _, methode in ipairs({ "clear", "clearLine", "setCursorPos", "getCursorPos",
      "isColour", "isColor", "setTextColour", "setTextColor",
      "setBackgroundColour", "setBackgroundColor", "write", "blit", "getSize" }) do
    term[methode] = function(...)
      local fn = cibleTerm[methode]
      if fn then return fn(...) end
    end
  end
  term.current  = function() return cibleTerm end
  term.native   = function() return terminalNatif end
  term.redirect = function(nouveau)
    local ancien = cibleTerm
    cibleTerm = nouveau or terminalNatif
    etat.redirections = (etat.redirections or 0) + 1
    return ancien
  end

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
  -- textutils.serialise / unserialise : implementation reelle. Les zones et
  -- l'etat operationnel transitent par ces deux fonctions, un bouchon
  -- masquerait toute erreur de persistance.
  local function serialise(valeur, indentation)
    indentation = indentation or ""
    local t = type(valeur)
    if t == "number" or t == "boolean" then return tostring(valeur) end
    if t == "string" then return string.format("%q", valeur) end
    if t ~= "table" then return "nil" end
    local suivante = indentation .. "  "
    local morceaux = {}
    local n = 0
    for i, v in ipairs(valeur) do
      morceaux[#morceaux + 1] = suivante .. serialise(v, suivante)
      n = i
    end
    for k, v in pairs(valeur) do
      local numerique = type(k) == "number" and k >= 1 and k <= n and k == math.floor(k)
      if not numerique then
        local cle = (type(k) == "string" and k:match("^[%a_][%w_]*$"))
          and k or ("[" .. serialise(k, suivante) .. "]")
        morceaux[#morceaux + 1] = suivante .. cle .. " = " .. serialise(v, suivante)
      end
    end
    if #morceaux == 0 then return "{}" end
    return "{\n" .. table.concat(morceaux, ",\n") .. ",\n" .. indentation .. "}"
  end

  env.textutils = {
    formatTime = function() return "06:00" end,
    serialise = serialise,
    serialize = serialise,
    unserialise = function(texte)
      local f = load("return " .. tostring(texte), "unserialise", "t", {})
      if not f then return nil end
      local ok, resultat = pcall(f)
      if ok then return resultat end
      return nil
    end,
  }
  env.textutils.unserialize = env.textutils.unserialise

  -- loadfile passe par le systeme de fichiers simule : sans cela, un programme
  -- qui charge un module voisin lirait le vrai depot au lieu du banc d'essai.
  env.loadfile = function(chemin)
    local f = io.open((options.racine or ".") .. "/" .. tostring(chemin):gsub("^/", ""), "r")
    if not f then return nil, chemin .. ": No such file" end
    local source = f:read("a")
    f:close()
    return load(source, "@" .. chemin, "t", env)
  end

  --[[
    window.create, absent jusqu'ici. Tout le framework MFD repose dessus : sans
    lui, l'affichage du systeme embarque n'avait jamais ete execute une seule
    fois, et le banc ne prouvait rien de ce qui se dessine.

    Fidele sur ce qui compte pour le code teste : getSize rend la taille de la
    fenetre et non celle de l'ecran (une page qui lirait la taille de l'ecran
    deborderait sur sa voisine), setVisible est compte (c'est le mecanisme
    anti-lag : on accumule les ecritures et on ne pousse qu'une image), et les
    ecritures sont enregistrees pour pouvoir etre comptees.
  ]]
  env.window = {
    create = function(parent, x, y, larg, haut, visible)
      local f = { x = x, y = y, larg = larg, haut = haut,
                  visible = visible ~= false, ecritures = 0, bascules = 0 }
      etat.fenetres = etat.fenetres or {}
      etat.fenetres[#etat.fenetres + 1] = f
      local function bornee(cx, cy) return cx >= 1 and cx <= larg and cy >= 1 and cy <= haut end
      local cx, cy = 1, 1
      return {
        getSize = function() return larg, haut end,
        getPosition = function() return f.x, f.y end,
        setVisible = function(v) f.visible = v f.bascules = f.bascules + 1 end,
        isVisible = function() return f.visible end,
        redraw = function() end,
        reposition = function(nx, ny, nl, nh)
          f.x, f.y = nx, ny
          if nl then larg, f.larg = nl, nl end
          if nh then haut, f.haut = nh, nh end
        end,
        setCursorPos = function(a, b) cx, cy = a, b end,
        getCursorPos = function() return cx, cy end,
        setCursorBlink = function() end,
        clear = function() f.efface = (f.efface or 0) + 1 end,
        clearLine = function() end,
        scroll = function() end,
        setTextColour = function() end, setTextColor = function() end,
        setBackgroundColour = function() end, setBackgroundColor = function() end,
        getTextColour = function() return 1 end, getTextColor = function() return 1 end,
        getBackgroundColour = function() return 32768 end,
        getBackgroundColor = function() return 32768 end,
        isColour = function() return true end, isColor = function() return true end,
        write = function(texte)
          f.ecritures = f.ecritures + 1
          if bornee(cx, cy) then
            etat.fenetreEcrit = etat.fenetreEcrit or {}
            etat.fenetreEcrit[#etat.fenetreEcrit + 1] = tostring(texte)
          end
          cx = cx + #tostring(texte)
        end,
        blit = function(texte)
          f.ecritures = f.ecritures + 1
          etat.fenetreEcrit = etat.fenetreEcrit or {}
          etat.fenetreEcrit[#etat.fenetreEcrit + 1] = tostring(texte)
        end,
      }
    end,
  }

  -- dofile : les pages du systeme embarque chargent leurs widgets avec, et
  -- sans lui elles echouaient toutes en silence dans l'emulateur.
  env.dofile = function(chemin)
    local f, err = env.loadfile(chemin)
    if not f then error(err or ("cannot open " .. tostring(chemin)), 0) end
    return f()
  end

  -- Table 'keys' minimale et saisie clavier simulee : l'interface de controle
  -- les utilise, le reste du systeme non.
  env.keys = setmetatable({}, { __index = function(_, nom) return "touche_" .. nom end })
  env.read = function()
    local file = options.saisies or {}
    local suivante = table.remove(file, 1)
    return suivante or ""
  end

  env.redstone = {
    setOutput = function(cote, valeur)
      etat.redstone = etat.redstone or {}
      etat.redstone[cote] = valeur
    end,
    getOutput = function(cote) return (etat.redstone or {})[cote] == true end,
  }
  env.shell = {
    getRunningProgram = function() return options.programme or "balise/balise.lua" end,
    run = function() return true end,
  }
  env.write = function(s) io.write(tostring(s)) end
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

  return env, etat
end

--------------------------------------------------------------------- execution
-- Execute le programme jusqu'a epuisement du temps virtuel alloue.
function M.executer(chemin, secondes)
  local source = io.open(chemin, "r"):read("a")
  local morceau = assert(load(source, "@" .. chemin, "t", env))
  local principal = coroutine.create(morceau)

  local ev = { n = 0 }
  local motif
  while coroutine.status(principal) ~= "dead" do
    local ok, err = coroutine.resume(principal, table.unpack(ev, 1, ev.n))
    if not ok then motif = err break end
    if etat.horloge > secondes then motif = "LIMITE_TEMPS" break end
    local suivant = prochainEvenement()
    if not suivant then motif = "PLUS_D_EVENEMENTS" break end
    ev = suivant
  end
  return motif, etat
end

function M.injecterRednet(id, message, protocole)
  queueEvent("rednet_message", id, message, protocole)
end

-- Evenement brut : clic souris, touche, redimensionnement... Utilise pour
-- piloter l'interface de controle comme le ferait un operateur.
function M.injecterEvenement(...)
  queueEvent(...)
end

--[[
  Source rednet periodique : station radar, balise de lanceur, transpondeur.
  'fabrique(horloge)' rend la trame a emettre, ou nil pour ne rien emettre a
  cet instant - ce qui permet de simuler une station qui tombe en panne.
]]
-- Evenement brut declenche a un instant precis de l'horloge virtuelle.
function M.programmerEvenement(instant, ...)
  etat.evenementsProgrammes[#etat.evenementsProgrammes + 1] =
    { instant = instant, args = table.pack(...) }
end

function M.programmerRednet(id, protocole, intervalle, fabrique)
  etat.programmes[#etat.programmes + 1] = {
    id = id, protocole = protocole, intervalle = intervalle,
    fabrique = fabrique, prochain = 0,
  }
end

function M.injecterModem(cote, canal, reponse, message)
  queueEvent("modem_message", cote, canal, reponse, message, 10)
end

function M.sorties() return etat.sorties end

return M
