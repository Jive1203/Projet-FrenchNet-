--[[----------------------------------------------------------------------------
  FRENCHNET - STATION RADAR DEPORTEE
  --------------------------------------------------------------------------
  Un ordinateur + un modem Ender + un radar (Create Radars), pose au sol a
  cote de son antenne. Il balaie, normalise les echos en coordonnees absolues,
  et transmet le tout au poste de commandement central.

  Le poste central ne balaie rien lui-meme : il fusionne les pistes de toutes
  les stations. C'est ce qui permet de couvrir un theatre bien plus large que
  la portee d'un radar, et de continuer a voir quand une station tombe.

  La station declare sa PROPRE POSITION a chaque trame. Le poste s'en sert
  pour trois choses :
    - calculer l'enveloppe fiable de confirmation de destruction,
    - savoir quelle station a vu quoi,
    - alimenter le modele de terrain : une station est posee au sol, donc sa
      position est un releve d'altitude exact.

  Journal : chaque erreur porte l'ETAPE exacte ou elle survient.
--------------------------------------------------------------------------------]]

local VERSION_PROGRAMME = "1.0.0"
local PROTOCOLE_VERSION = 1

local ETAPES = {
  DEMARRAGE         = "demarrage de la station",
  CHARGEMENT_CONFIG = "chargement de la configuration",
  CHARGEMENT_SCANNER= "chargement de l'adaptateur radar",
  VALIDATION_CONFIG = "validation de la configuration",
  DETECTION_MODEM   = "detection du modem ender",
  OUVERTURE_REDNET  = "ouverture rednet",
  DETECTION_RADAR   = "detection du radar",
  BALAYAGE          = "balayage radar",
  REFERENTIEL       = "deduction du referentiel",
  EMISSION          = "emission vers le poste de commandement",
  BOUCLE            = "boucle principale",
  ARRET             = "arret de la station",
}

local function repertoire()
  if shell and shell.getRunningProgram then
    local ok, chemin = pcall(shell.getRunningProgram)
    if ok and chemin then
      local d = fs.getDir(chemin)
      if d and d ~= "" and d ~= "." then return d end
    end
  end
  return ""
end

local REPERTOIRE     = repertoire()
local CHEMIN_CONFIG  = fs.combine(REPERTOIRE, "config_radar.lua")
local CHEMIN_SCANNER = fs.combine(REPERTOIRE, "scanner.lua")
local CHEMIN_JOURNAL = fs.combine(REPERTOIRE, "radar.log")
local MARQUEUR_ARRET = fs.combine(REPERTOIRE, ".arret_manuel")

local function horodatage()
  local ok, texte = pcall(function()
    return os.date("!%Y-%m-%d %H:%M:%S", math.floor(os.epoch("utc") / 1000))
  end)
  if ok and texte then return texte end
  return string.format("jour %d %s", os.day(), textutils.formatTime(os.time(), true))
end

local NIVEAUX = { DEBUG = 0, INFO = 1, AVERT = 2, ERREUR = 3, CRITIQUE = 4 }
local journal = { seuil = 1, fichier = true, tailleMax = 32768 }

local function ecrire(niveau, etape, message)
  local ligne = string.format("[%s] [%s] [etape: %s] %s", horodatage(), niveau, etape, tostring(message))
  if (NIVEAUX[niveau] or 1) >= journal.seuil then pcall(print, ligne) end
  if journal.fichier then
    pcall(function()
      if fs.exists(CHEMIN_JOURNAL) and fs.getSize(CHEMIN_JOURNAL) >= journal.tailleMax then
        if fs.exists(CHEMIN_JOURNAL .. ".1") then fs.delete(CHEMIN_JOURNAL .. ".1") end
        fs.move(CHEMIN_JOURNAL, CHEMIN_JOURNAL .. ".1")
      end
      local f = fs.open(CHEMIN_JOURNAL, "a")
      if f then f.writeLine(ligne) f.close() end
    end)
  end
end

local function info(e, m)  ecrire("INFO", e, m) end
local function avert(e, m) ecrire("AVERT", e, m) end
local function erreur(e, m) ecrire("ERREUR", e, m) end

local function proteger(etape, fn, ...)
  local r = table.pack(pcall(fn, ...))
  if not r[1] then
    erreur(etape, string.format("erreur detectee a l'etape '%s' : %s", etape, tostring(r[2])))
    return false, r[2]
  end
  return true, table.unpack(r, 2, r.n)
end

--------------------------------------------------------------------------------
-- Adaptateur radar partage avec le poste de commandement.
--------------------------------------------------------------------------------
local scanner
do
  local charge, err = loadfile(CHEMIN_SCANNER)
  if not charge then
    printError("[etape: " .. ETAPES.CHARGEMENT_SCANNER .. "] scanner.lua introuvable : " .. tostring(err))
    printError("Copiez command/scanner.lua a cote de radar.lua.")
    return
  end
  local ok, module = pcall(charge)
  if not ok or type(module) ~= "table" then
    printError("[etape: " .. ETAPES.CHARGEMENT_SCANNER .. "] scanner.lua invalide : " .. tostring(module))
    return
  end
  scanner = module
end

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------
local DEFAUTS = {
  identifiant        = nil,
  designation        = "",
  position           = { x = 0, y = 64, z = 0 },
  portee             = 512,
  positionsRelatives = nil,
  peripheriqueRadar  = nil,
  coteModem          = nil,
  intervalleBalayage = 1,
  protocoleRadar     = "frenchnet_radar",
  idCommand          = nil,
  journalNiveauEcran = "INFO",
  journalFichier     = true,
  battementSecondes  = 60,
  redemarrageDelaiMin = 3,
  redemarrageDelaiMax = 60,
  arretParTerminate  = true,
}

local cfg = {}
local etat = { relatives = nil, arret = false, trames = 0, contactsVus = 0, echecs = 0 }

local function chargerConfiguration()
  for k, v in pairs(DEFAUTS) do cfg[k] = v end
  if not fs.exists(CHEMIN_CONFIG) then
    avert(ETAPES.CHARGEMENT_CONFIG, "config_radar.lua absent : valeurs par defaut, identifiant manquant")
    return true
  end
  local charge, err = loadfile(CHEMIN_CONFIG)
  if not charge then
    erreur(ETAPES.CHARGEMENT_CONFIG, "fichier illisible : " .. tostring(err))
    return false
  end
  local ok, t = pcall(charge)
  if not ok or type(t) ~= "table" then
    erreur(ETAPES.CHARGEMENT_CONFIG, "la configuration ne retourne pas une table")
    return false
  end
  for k, v in pairs(t) do cfg[k] = v end
  journal.seuil   = NIVEAUX[cfg.journalNiveauEcran] or 1
  journal.fichier = cfg.journalFichier ~= false
  info(ETAPES.CHARGEMENT_CONFIG, "configuration chargee")
  return true
end

local function validerConfiguration()
  local anomalies = {}
  if type(cfg.identifiant) ~= "string" or cfg.identifiant == "" then
    cfg.identifiant = "RAD-" .. os.getComputerID()
    anomalies[#anomalies + 1] = "identifiant absent, repli sur " .. cfg.identifiant
  end
  local p = cfg.position
  if type(p) ~= "table" or type(p.x) ~= "number" or type(p.y) ~= "number" or type(p.z) ~= "number" then
    anomalies[#anomalies + 1] =
      "position invalide : les pistes seront mal placees et le terrain mal appris"
    cfg.position = { x = 0, y = 64, z = 0 }
  end
  if type(cfg.portee) ~= "number" or cfg.portee <= 0 then
    anomalies[#anomalies + 1] =
      "portee inconnue : le poste ne pourra pas appliquer son garde-fou d'enveloppe fiable"
    cfg.portee = 0
  end
  for _, a in ipairs(anomalies) do avert(ETAPES.VALIDATION_CONFIG, a) end
  if #anomalies == 0 then info(ETAPES.VALIDATION_CONFIG, "configuration validee") end
end

--------------------------------------------------------------------------------
-- Reseau et radar
--------------------------------------------------------------------------------
local cote, radar, methodes

local function ouvrirReseau()
  if type(cfg.coteModem) == "string" and peripheral.isPresent(cfg.coteModem) then
    cote = cfg.coteModem
  else
    for _, nom in ipairs(peripheral.getNames()) do
      if peripheral.getType(nom) == "modem" then
        local m = peripheral.wrap(nom)
        local ok, sansFil = pcall(m.isWireless)
        if ok and sansFil then cote = nom break end
        cote = cote or nom
      end
    end
  end
  if not cote then
    erreur(ETAPES.DETECTION_MODEM, "aucun modem detecte : la station est muette")
    return false
  end
  info(ETAPES.DETECTION_MODEM, "modem detecte sur '" .. cote .. "'")
  local ok = proteger(ETAPES.OUVERTURE_REDNET, rednet.open, cote)
  if not ok and not rednet.isOpen(cote) then return false end
  info(ETAPES.OUVERTURE_REDNET, "rednet ouvert")
  return true
end

local function detecterRadar()
  local r, nom, actives, motif = scanner.detecter(peripheral, cfg.peripheriqueRadar)
  if not r then
    erreur(ETAPES.DETECTION_RADAR, motif)
    return false
  end
  radar, methodes = r, actives
  info(ETAPES.DETECTION_RADAR, motif)
  return true
end

--------------------------------------------------------------------------------
-- Boucle de balayage
--------------------------------------------------------------------------------
local function balayer()
  while not etat.arret do
    local bruts = scanner.collecter(radar, methodes, function(fn)
      return proteger(ETAPES.BALAYAGE, fn)
    end)

    if etat.relatives == nil then
      if type(cfg.positionsRelatives) == "boolean" then
        etat.relatives = cfg.positionsRelatives
        info(ETAPES.REFERENTIEL, "referentiel force par configuration : " ..
          (etat.relatives and "RELATIF" or "ABSOLU"))
      else
        local relatif, motif = scanner.deduireReferentiel(bruts, cfg.position, cfg.portee)
        etat.relatives = relatif
        info(ETAPES.REFERENTIEL, motif)
      end
    end

    local contacts, ignores = scanner.normaliser(bruts, cfg.position, etat.relatives)
    if ignores > 0 then
      ecrire("DEBUG", ETAPES.BALAYAGE, ignores .. " echo(s) sans position exploitable ignore(s)")
    end

    local trame = {
      protocole = "FRENCHNET_RADAR", version = PROTOCOLE_VERSION,
      station   = cfg.identifiant, designation = cfg.designation,
      x = cfg.position.x, y = cfg.position.y, z = cfg.position.z,
      portee    = cfg.portee,
      contacts  = contacts,
    }

    local ok
    if type(cfg.idCommand) == "number" then
      ok = proteger(ETAPES.EMISSION, rednet.send, cfg.idCommand, trame, cfg.protocoleRadar)
    else
      ok = proteger(ETAPES.EMISSION, rednet.broadcast, trame, cfg.protocoleRadar)
    end

    if ok then
      etat.trames = etat.trames + 1
      etat.contactsVus = etat.contactsVus + #contacts
      etat.echecs = 0
      ecrire("DEBUG", ETAPES.EMISSION, string.format("trame %d : %d contact(s) transmis",
        etat.trames, #contacts))
    else
      etat.echecs = etat.echecs + 1
      if etat.echecs == 1 or etat.echecs % 10 == 0 then
        erreur(ETAPES.EMISSION, string.format(
          "%d echec(s) consecutif(s) de transmission vers le poste de commandement", etat.echecs))
      end
    end

    sleep(cfg.intervalleBalayage or 1)
  end
end

local function battement()
  while not etat.arret do
    sleep(cfg.battementSecondes or 60)
    info("battement", string.format("station %s : %d trame(s), %d contact(s) cumule(s), %d echec(s)",
      cfg.identifiant, etat.trames, etat.contactsVus, etat.echecs))
  end
end

local function terminaison()
  while true do
    local e = os.pullEventRaw("terminate")
    if e == "terminate" then
      if cfg.arretParTerminate ~= false then
        info(ETAPES.ARRET, "arret demande par l'operateur (Ctrl+T)")
        etat.arret = true
        local f = fs.open(MARQUEUR_ARRET, "w") if f then f.write("1") f.close() end
        return
      end
      avert(ETAPES.ARRET, "Ctrl+T ignore : station en autonomie totale")
    end
  end
end

--------------------------------------------------------------------------------
-- Point d'entree
--------------------------------------------------------------------------------
local delai = 3
while true do
  if fs.exists(MARQUEUR_ARRET) then
    info(ETAPES.ARRET, "marqueur d'arret manuel present : la station ne demarre pas")
    return
  end

  local ok, err = pcall(function()
    term.clear() term.setCursorPos(1, 1)
    info(ETAPES.DEMARRAGE, "station radar FrenchNet " .. VERSION_PROGRAMME)
    if not chargerConfiguration() then error("configuration illisible", 0) end
    validerConfiguration()
    if not ouvrirReseau() then error("reseau indisponible", 0) end
    if not detecterRadar() then error("radar indisponible", 0) end
    info(ETAPES.DEMARRAGE, string.format(
      "station %s operationnelle en X=%.0f Y=%.0f Z=%.0f, portee %.0f",
      cfg.identifiant, cfg.position.x, cfg.position.y, cfg.position.z, cfg.portee))
    parallel.waitForAny(balayer, battement, terminaison)
  end)

  if etat.arret then
    info(ETAPES.ARRET, "arret propre de la station")
    return
  end
  if not ok then
    ecrire("CRITIQUE", ETAPES.BOUCLE, "la station s'est interrompue : " .. tostring(err))
  end
  delai = math.min(delai, cfg.redemarrageDelaiMax or 60)
  avert(ETAPES.DEMARRAGE, string.format("redemarrage automatique dans %ds", delai))
  sleep(delai)
  delai = math.min(delai * 2, cfg.redemarrageDelaiMax or 60)
  etat.relatives = nil
end
