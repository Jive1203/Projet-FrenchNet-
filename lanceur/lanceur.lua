--[[----------------------------------------------------------------------------
  FRENCHNET - BALISE DE LANCEUR
  --------------------------------------------------------------------------
  A poser sur chaque plateforme de defense : batterie de Create Big Cannons,
  rampe de missiles, aeronef intercepteur. Un ordinateur + un modem Ender,
  et - c'est tout l'interet - un acces a l'inventaire de munitions.

  La balise diffuse en continu :
      nom, position, MUNITIONS RESTANTES, tirs effectues, portee, disponibilite

  Le poste de commandement s'en sert pour designer QUI engage une menace :
  la plateforme la mieux placee ET la mieux approvisionnee. Une plateforme a
  court de munitions n'est plus designee du tout - ce qui evite l'ordre de tir
  le plus couteux du systeme : celui qui ne part jamais.

  COMPTAGE DES MUNITIONS
    - "inventaire" : la balise compte reellement les munitions dans un coffre,
      un baril ou tout peripherique d'inventaire accole. C'est le mode fiable.
    - "manuel" : compteur tenu a la main (touches + et -), pour un lanceur dont
      l'ammo n'est pas dans un inventaire lisible.
  Les tirs sont deduits des BAISSES de stock observees : aucune declaration a
  faire, le stock qui descend EST le tir.
--------------------------------------------------------------------------------]]

local VERSION_PROGRAMME = "1.0.0"
local PROTOCOLE_VERSION = 1

local ETAPES = {
  DEMARRAGE         = "demarrage de la balise",
  CHARGEMENT_CONFIG = "chargement de la configuration",
  VALIDATION_CONFIG = "validation de la configuration",
  DETECTION_MODEM   = "detection du modem ender",
  OUVERTURE_REDNET  = "ouverture rednet",
  DETECTION_STOCK   = "detection de l'inventaire de munitions",
  COMPTAGE          = "comptage des munitions",
  EMISSION          = "emission de la balise",
  TIR_DETECTE       = "tir detecte",
  REARMEMENT        = "rearmement detecte",
  RUPTURE_STOCK     = "rupture de stock",
  BOUCLE            = "boucle principale",
  ARRET             = "arret de la balise",
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
local CHEMIN_CONFIG  = fs.combine(REPERTOIRE, "config_lanceur.lua")
local CHEMIN_JOURNAL = fs.combine(REPERTOIRE, "lanceur.log")
local CHEMIN_ETAT    = fs.combine(REPERTOIRE, "etat_lanceur.dat")

local function horodatage()
  local ok, texte = pcall(function()
    return os.date("!%Y-%m-%d %H:%M:%S", math.floor(os.epoch("utc") / 1000))
  end)
  if ok and texte then return texte end
  return string.format("jour %d %s", os.day(), textutils.formatTime(os.time(), true))
end

local NIVEAUX = { DEBUG = 0, INFO = 1, AVERT = 2, ERREUR = 3, CRITIQUE = 4 }
local journal = { seuil = 1, fichier = true }

local function ecrire(niveau, etape, message)
  local ligne = string.format("[%s] [%s] [etape: %s] %s", horodatage(), niveau, etape, tostring(message))
  if (NIVEAUX[niveau] or 1) >= journal.seuil then pcall(print, ligne) end
  if journal.fichier then
    pcall(function()
      local f = fs.open(CHEMIN_JOURNAL, "a")
      if f then f.writeLine(ligne) f.close() end
    end)
  end
end
local function info(e, m)  ecrire("INFO", e, m) end
local function avert(e, m) ecrire("AVERT", e, m) end
local function erreur(e, m) ecrire("ERREUR", e, m) end

--------------------------------------------------------------------------------
local DEFAUTS = {
  identifiant       = nil,
  designation       = "",
  position          = { x = 0, y = 64, z = 0 },
  portee            = 400,
  categoriesTraitees = nil,   -- nil = toutes ; sinon { "AERIENNE", ... }
  sourceMunitions   = "inventaire",
  nomInventaire     = nil,
  filtreMunition    = { "missile", "shell", "rocket", "cartridge", "autocannon" },
  munitionsManuelles = 0,
  munitionsMax      = nil,
  seuilAlerte       = 3,
  intervalleSecondes = 5,
  protocoleLanceur  = "frenchnet_lanceur",
  idCommand         = nil,
  journalFichier    = true,
  journalNiveauEcran = "INFO",
  arretParTerminate = true,
}

local cfg = {}
local etat = { munitions = 0, tirs = 0, arret = false, emissions = 0, precedent = nil, inventaire = nil }

local function chargerConfiguration()
  for k, v in pairs(DEFAUTS) do cfg[k] = v end
  if fs.exists(CHEMIN_CONFIG) then
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
  else
    avert(ETAPES.CHARGEMENT_CONFIG, "config_lanceur.lua absent : valeurs par defaut")
  end
  journal.seuil   = NIVEAUX[cfg.journalNiveauEcran] or 1
  journal.fichier = cfg.journalFichier ~= false

  if type(cfg.identifiant) ~= "string" or cfg.identifiant == "" then
    cfg.identifiant = os.getComputerLabel() or ("LAN-" .. os.getComputerID())
    avert(ETAPES.VALIDATION_CONFIG, "identifiant absent, repli sur " .. cfg.identifiant)
  end

  -- Compteur de tirs restaure : il doit survivre a un rechargement de chunk,
  -- sinon la repartition de charge du poste reparte de zero a chaque reboot.
  if fs.exists(CHEMIN_ETAT) then
    local f = fs.open(CHEMIN_ETAT, "r")
    if f then
      local donnees = textutils.unserialise(f.readAll() or "")
      f.close()
      if type(donnees) == "table" and type(donnees.tirs) == "number" then
        etat.tirs = donnees.tirs
        if cfg.sourceMunitions == "manuel" and type(donnees.munitions) == "number" then
          cfg.munitionsManuelles = donnees.munitions
        end
        info(ETAPES.DEMARRAGE, string.format("compteur restaure : %d tir(s)", etat.tirs))
      end
    end
  end
  return true
end

local function enregistrerEtat()
  pcall(function()
    local f = fs.open(CHEMIN_ETAT, "w")
    if f then
      f.write(textutils.serialise({ tirs = etat.tirs, munitions = etat.munitions }))
      f.close()
    end
  end)
end

--------------------------------------------------------------------------------
-- Comptage des munitions
--------------------------------------------------------------------------------
local function detecterInventaire()
  if cfg.sourceMunitions ~= "inventaire" then return end
  if type(cfg.nomInventaire) == "string" and peripheral.isPresent(cfg.nomInventaire) then
    etat.inventaire = cfg.nomInventaire
  else
    for _, nom in ipairs(peripheral.getNames()) do
      local ok, resultat = pcall(peripheral.hasType, nom, "inventory")
      if ok and resultat then etat.inventaire = nom break end
    end
  end
  if etat.inventaire then
    info(ETAPES.DETECTION_STOCK, "inventaire de munitions sur '" .. etat.inventaire .. "'")
  else
    avert(ETAPES.DETECTION_STOCK,
      "aucun inventaire lisible : bascule en comptage MANUEL. Le poste de commandement " ..
      "designera cette plateforme sur un stock declare a la main.")
    cfg.sourceMunitions = "manuel"
  end
end

local function correspondMunition(nomObjet)
  local minuscule = tostring(nomObjet):lower()
  for _, motif in ipairs(cfg.filtreMunition or {}) do
    if minuscule:find(tostring(motif):lower(), 1, true) then return true end
  end
  return false
end

local function compter()
  if cfg.sourceMunitions == "manuel" then return cfg.munitionsManuelles or 0 end
  if not etat.inventaire then return 0 end
  local ok, contenu = pcall(peripheral.call, etat.inventaire, "list")
  if not ok or type(contenu) ~= "table" then
    erreur(ETAPES.COMPTAGE, "lecture de l'inventaire impossible : " .. tostring(contenu))
    return etat.munitions
  end
  local total = 0
  for _, objet in pairs(contenu) do
    if type(objet) == "table" and correspondMunition(objet.name) then
      total = total + (objet.count or 1)
    end
  end
  return total
end

--------------------------------------------------------------------------------
-- Boucles
--------------------------------------------------------------------------------
local function diffuser()
  while not etat.arret do
    local avant = etat.munitions
    etat.munitions = compter()

    -- Une baisse de stock EST un tir : aucune declaration a faire.
    if etat.precedent ~= nil and etat.munitions < avant then
      local consommees = avant - etat.munitions
      etat.tirs = etat.tirs + consommees
      info(ETAPES.TIR_DETECTE, string.format(
        "%d munition(s) consommee(s), stock %d, total %d tir(s)",
        consommees, etat.munitions, etat.tirs))
      enregistrerEtat()
    elseif etat.precedent ~= nil and etat.munitions > avant then
      info(ETAPES.REARMEMENT, string.format("rearmement : stock %d (+%d)",
        etat.munitions, etat.munitions - avant))
    end
    etat.precedent = etat.munitions

    if etat.munitions == 0 then
      avert(ETAPES.RUPTURE_STOCK,
        "stock epuise : le poste de commandement cessera de designer cette plateforme")
    elseif etat.munitions <= (cfg.seuilAlerte or 3) then
      avert(ETAPES.RUPTURE_STOCK, string.format("stock bas : %d munition(s)", etat.munitions))
    end

    local trame = {
      protocole   = "FRENCHNET_LANCEUR", version = PROTOCOLE_VERSION,
      nom         = cfg.identifiant,
      designation = cfg.designation,
      x = cfg.position.x, y = cfg.position.y, z = cfg.position.z,
      portee      = cfg.portee,
      munitions   = etat.munitions,
      munitionsMax = cfg.munitionsMax,
      tirs        = etat.tirs,
      disponible  = etat.munitions > 0,
      categories  = cfg.categoriesTraitees,
    }

    local ok
    if type(cfg.idCommand) == "number" then
      ok = pcall(rednet.send, cfg.idCommand, trame, cfg.protocoleLanceur)
    else
      ok = pcall(rednet.broadcast, trame, cfg.protocoleLanceur)
    end

    if ok then
      etat.emissions = etat.emissions + 1
      ecrire("DEBUG", ETAPES.EMISSION, string.format(
        "balise %d : %d munition(s), %d tir(s)", etat.emissions, etat.munitions, etat.tirs))
    else
      erreur(ETAPES.EMISSION, "transmission vers le poste de commandement impossible")
    end

    -- Affichage local, pour l'operateur sur place.
    pcall(function()
      term.setCursorPos(1, 7)
      term.clearLine()
      write(string.format("Munitions %-5d Tirs %-5d Emissions %d",
        etat.munitions, etat.tirs, etat.emissions))
    end)

    sleep(cfg.intervalleSecondes or 5)
  end
end

-- Comptage manuel : + et - ajustent le stock declare, R remet le compteur de
-- tirs a zero apres un rearmement complet.
local function clavier()
  while not etat.arret do
    local _, touche = os.pullEvent("char")
    if cfg.sourceMunitions == "manuel" then
      if touche == "+" or touche == "=" then
        cfg.munitionsManuelles = (cfg.munitionsManuelles or 0) + 1
        enregistrerEtat()
      elseif touche == "-" then
        cfg.munitionsManuelles = math.max(0, (cfg.munitionsManuelles or 0) - 1)
        enregistrerEtat()
      end
    end
    if touche == "r" or touche == "R" then
      etat.tirs = 0
      enregistrerEtat()
      info(ETAPES.REARMEMENT, "compteur de tirs remis a zero par l'operateur")
    end
  end
end

local function terminaison()
  while true do
    local e = os.pullEventRaw("terminate")
    if e == "terminate" then
      if cfg.arretParTerminate ~= false then
        info(ETAPES.ARRET, "arret demande par l'operateur")
        etat.arret = true
        return
      end
    end
  end
end

--------------------------------------------------------------------------------
while true do
  local ok, err = pcall(function()
    term.clear() term.setCursorPos(1, 1)
    if not chargerConfiguration() then error("configuration illisible", 0) end
    print("BALISE DE LANCEUR FRENCHNET " .. VERSION_PROGRAMME)
    print("Plateforme : " .. cfg.identifiant)
    print(string.format("Position   : X=%.0f Y=%.0f Z=%.0f  portee %.0f",
      cfg.position.x, cfg.position.y, cfg.position.z, cfg.portee))
    print("Munitions  : " .. tostring(cfg.sourceMunitions)
      .. (cfg.sourceMunitions == "manuel" and "  (+ / - pour ajuster, R remet les tirs a zero)" or ""))
    print(string.rep("-", 40))

    local cote
    for _, nom in ipairs(peripheral.getNames()) do
      if peripheral.getType(nom) == "modem" then
        local m = peripheral.wrap(nom)
        local okSansFil, sansFil = pcall(m.isWireless)
        if okSansFil and sansFil then cote = nom break end
        cote = cote or nom
      end
    end
    if not cote then
      erreur(ETAPES.DETECTION_MODEM, "aucun modem detecte : la balise est muette")
      error("reseau indisponible", 0)
    end
    rednet.open(cote)
    info(ETAPES.OUVERTURE_REDNET, "rednet ouvert sur '" .. cote .. "'")

    detecterInventaire()
    parallel.waitForAny(diffuser, clavier, terminaison)
  end)

  if etat.arret then return end
  ecrire("CRITIQUE", ETAPES.BOUCLE, "la balise s'est interrompue : " .. tostring(err))
  avert(ETAPES.DEMARRAGE, "redemarrage automatique dans 5s")
  sleep(5)
end
