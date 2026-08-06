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
    transmissions = {},
    modemPresent = true,
    rednetOuvert = false,
    echecBroadcast = false,
    limiteHorloge = options.limiteHorloge or 300,
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

  local peripheralMock = {
    getNames = function() return etat.modemPresent and { "back" } or {} end,
    getType = function(n) return (etat.modemPresent and n == "back") and "modem" or nil end,
    isPresent = function(n) return etat.modemPresent and n == "back" end,
    wrap = function(n) return (etat.modemPresent and n == "back") and modem or nil end,
    hasType = function(n, t)
      if not etat.modemPresent then return nil end
      return t == "modem" or t == "ender_modem"
    end,
  }

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
    formatTime = function() return "06:00" end,
    serialise = function(t) return tostring(t) end,
  }
  env.shell = { getRunningProgram = function() return "balise/balise.lua" end }
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

function M.injecterModem(cote, canal, reponse, message)
  queueEvent("modem_message", cote, canal, reponse, message, 10)
end

function M.sorties() return etat.sorties end

return M
