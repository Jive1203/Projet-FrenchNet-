--[[----------------------------------------------------------------------------
  ORDINATEUR DE SORTIE DEPORTE - AUTOPILOTE FRENCHNET (AERONAUTICS WARFARE)
  --------------------------------------------------------------------------
  Role      : recevoir les niveaux redstone calcules par l'ordinateur principal
              du vehicule et les appliquer sur ses propres faces. Un ordinateur
              n'a que six faces ; sur un gros appareil, la propulsion est
              dispersee. Plusieurs satellites permettent de la commander sans
              faire courir de cable jusqu'au poste de pilotage.
  Liaison   : rednet sur modem sans fil COURTE PORTEE (les vehicules voisins ne
              doivent pas s'echanger leurs commandes moteur).
  Securite  : chien de garde. Sans trame pendant 'delaiChienDeGarde', le
              satellite remet ses faces au repos de lui-meme. Un ordinateur
              principal qui plante ne peut donc pas laisser les moteurs bloques
              en pleine poussee.
  Remontee  : le satellite renvoie l'etat de ses entrees redstone, ce qui
              permet au maitre de lire une jauge ou un capteur eloigne.
  Autonomie : superviseur interne, redemarrage automatique avec temporisation.

  Installation (sur CHAQUE satellite) :
      mkdir autopilote
      wget <depot>/autopilote/satellite.lua        autopilote/satellite.lua
      wget <depot>/autopilote/config_satellite.lua autopilote/config_satellite.lua
      edit autopilote/config_satellite.lua
      autopilote/satellite

  Le NUMERO D'ORDINATEUR affiche au demarrage est a reporter dans la
  configuration du vehicule (champ 'ordinateur' de l'axe concerne).
--------------------------------------------------------------------------------]]

local VERSION_PROGRAMME = "1.0.0"

--------------------------------------------------------------------------------
-- 1. ETAPES
--------------------------------------------------------------------------------

local ETAPES = {
  DEMARRAGE      = "demarrage du satellite",
  CONFIGURATION  = "chargement de la configuration",
  DETECTION_MODEM= "detection du modem sans fil",
  OUVERTURE      = "ouverture rednet",
  RECEPTION      = "reception d'une trame",
  APPLICATION    = "application des niveaux redstone",
  ACQUITTEMENT   = "acquittement au maitre",
  CHIEN_DE_GARDE = "chien de garde",
  ANNONCE        = "annonce de presence",
  ARRET          = "arret du satellite",
}

local CHEMIN_CONFIG = "/autopilote/config_satellite.lua"
local COTES = { "front", "back", "left", "right", "top", "bottom" }

--------------------------------------------------------------------------------
-- 2. JOURNAL (meme format que le reste de FrenchNet)
--------------------------------------------------------------------------------

local NIVEAUX = { DEBUG = 0, INFO = 1, AVERT = 2, ERREUR = 3, CRITIQUE = 4 }
local journal = { seuil = 1, fichier = false, chemin = nil, tailleMax = 32768 }

local function horodatage()
  local ok, texte = pcall(function()
    return os.date("!%Y-%m-%d %H:%M:%S", math.floor(os.epoch("utc") / 1000))
  end)
  return ok and texte or string.format("horloge %.1fs", os.clock())
end

function journal.ecrire(niveau, etape, message)
  local entete = string.format("[%s] [%s] [etape: %s] ", horodatage(), niveau, etape)
  if (NIVEAUX[niveau] or 1) >= journal.seuil then
    print(entete .. tostring(message))
  end
  if journal.fichier and journal.chemin then
    pcall(function()
      if fs.exists(journal.chemin) and fs.getSize(journal.chemin) > journal.tailleMax then
        if fs.exists(journal.chemin .. ".1") then fs.delete(journal.chemin .. ".1") end
        fs.move(journal.chemin, journal.chemin .. ".1")
      end
      local fichier = fs.open(journal.chemin, "a")
      if fichier then
        fichier.writeLine(entete .. tostring(message))
        fichier.close()
      end
    end)
  end
end

function journal.debug(e, m)  journal.ecrire("DEBUG", e, m)  end
function journal.info(e, m)   journal.ecrire("INFO", e, m)   end
function journal.avert(e, m)  journal.ecrire("AVERT", e, m)  end
function journal.erreur(e, m) journal.ecrire("ERREUR", e, m) end

--------------------------------------------------------------------------------
-- 3. CONFIGURATION
--------------------------------------------------------------------------------

local DEFAUTS = {
  identifiant = "SAT", vehicule = nil, protocole = "frenchnet_sortie",
  coteModem = nil, delaiChienDeGarde = 1.5,
  repos = {}, cotesAutorises = COTES, remonterEntrees = true, periodeAnnonce = 3,
  redemarrageDelaiMin = 3, redemarrageDelaiMax = 60, arretParTerminate = true,
  journalFichier = true, journalChemin = "/autopilote/satellite.log",
  journalTailleMax = 32768, journalNiveauEcran = "INFO",
}

local function chargerConfiguration()
  if not fs.exists(CHEMIN_CONFIG) then
    error("configuration introuvable : " .. CHEMIN_CONFIG, 0)
  end
  local fichier = fs.open(CHEMIN_CONFIG, "r")
  local source = fichier.readAll()
  fichier.close()
  local morceau, err = load(source, "@" .. CHEMIN_CONFIG, "t", _G)
  if not morceau then error("configuration illisible : " .. tostring(err), 0) end
  local table_config = morceau()
  if type(table_config) ~= "table" then
    error("la configuration doit se terminer par 'return { ... }'", 0)
  end
  local config = {}
  for cle, valeur in pairs(DEFAUTS) do config[cle] = valeur end
  for cle, valeur in pairs(table_config) do config[cle] = valeur end
  return config
end

--------------------------------------------------------------------------------
-- 4. MATERIEL
--------------------------------------------------------------------------------

--- Cherche un modem sans fil, en preferant explicitement la COURTE PORTEE.
local function detecterModem(config)
  if type(config.coteModem) == "string" and config.coteModem ~= "" then
    return config.coteModem
  end
  local repli = nil
  for _, nom in ipairs(peripheral.getNames()) do
    local ok, typePeriph = pcall(peripheral.getType, nom)
    if ok and typePeriph == "modem" then
      local modem = peripheral.wrap(nom)
      local okFil, sansFil = pcall(function() return modem.isWireless and modem.isWireless() end)
      if okFil and sansFil then
        local ender = false
        if peripheral.hasType then
          local okType, resultat = pcall(peripheral.hasType, nom, "ender_modem")
          ender = okType and resultat or false
        end
        if not ender then return nom end
        repli = repli or nom
      end
    end
  end
  if repli then
    journal.avert(ETAPES.DETECTION_MODEM,
      "seul un modem Ender est disponible : la portee depasse le vehicule, "
      .. "verifiez que deux appareils ne partagent pas le meme identifiant")
    return repli
  end
  error("aucun modem sans fil detecte", 0)
end

--------------------------------------------------------------------------------
-- 5. SORTIES ET ENTREES REDSTONE
--------------------------------------------------------------------------------

local function ecrireCote(cote, niveau)
  local valeur = math.max(0, math.min(15, math.floor((niveau or 0) + 0.5)))
  if redstone.setAnalogOutput then
    redstone.setAnalogOutput(cote, valeur)
  else
    redstone.setOutput(cote, valeur > 0)
  end
  return valeur
end

local function lireEntrees()
  local entrees = {}
  for _, cote in ipairs(COTES) do
    local ok, valeur = pcall(redstone.getAnalogInput, cote)
    entrees[cote] = ok and valeur or 0
  end
  return entrees
end

--------------------------------------------------------------------------------
-- 6. CYCLE DE VIE
--------------------------------------------------------------------------------

local function cycleDeVie()
  local config = chargerConfiguration()
  journal.seuil     = NIVEAUX[config.journalNiveauEcran] or NIVEAUX.INFO
  journal.fichier   = config.journalFichier and true or false
  journal.chemin    = config.journalChemin
  journal.tailleMax = config.journalTailleMax

  local autorises = {}
  for _, cote in ipairs(config.cotesAutorises or COTES) do autorises[cote] = true end

  local cote = detecterModem(config)
  if not rednet.isOpen(cote) then rednet.open(cote) end
  if not rednet.isOpen(cote) then
    error("rednet.open a echoue sur '" .. cote .. "'", 0)
  end

  journal.info(ETAPES.DEMARRAGE, string.format(
    "satellite '%s' v%s | ordinateur #%d | modem '%s' | vehicule '%s'",
    config.identifiant, VERSION_PROGRAMME, os.getComputerID(), cote,
    tostring(config.vehicule)))
  journal.info(ETAPES.DEMARRAGE,
    "REPORTEZ le numero #" .. os.getComputerID()
    .. " dans la configuration du vehicule (champ 'ordinateur' de l'axe)")

  local etat = {
    repos       = config.repos or {},
    niveaux     = {},
    derniereTrame = nil,
    neutralise  = true,
    trames      = 0,
    refus       = 0,
    maitre      = nil,
    sequence    = 0,
  }

  --- Applique un jeu de niveaux, en refusant les faces non autorisees.
  local function appliquer(niveaux, motif)
    for cote_, niveau in pairs(niveaux or {}) do
      if autorises[cote_] then
        etat.niveaux[cote_] = ecrireCote(cote_, niveau)
      else
        etat.refus = etat.refus + 1
        journal.avert(ETAPES.APPLICATION, string.format(
          "face '%s' non autorisee sur ce satellite : commande ignoree (%s)",
          tostring(cote_), tostring(motif)))
      end
    end
  end

  --- Chien de garde : c'est LA securite du montage deporte.
  local function neutraliser(motif)
    if etat.neutralise then return end
    etat.neutralise = true
    appliquer(etat.repos, "repos")
    -- Toute face non couverte par les niveaux de repos retombe a zero.
    for cote_ in pairs(etat.niveaux) do
      if etat.repos[cote_] == nil then etat.niveaux[cote_] = ecrireCote(cote_, 0) end
    end
    journal.avert(ETAPES.CHIEN_DE_GARDE,
      "liaison perdue (" .. tostring(motif) .. ") : faces remises au repos")
  end

  neutraliser("demarrage")
  etat.neutralise = true

  local function afficher()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== FRENCHNET - SORTIE DEPORTEE ===")
    print(string.format("%s  |  ordinateur #%d", config.identifiant, os.getComputerID()))
    print(string.format("vehicule : %s", tostring(config.vehicule)))
    local age = etat.derniereTrame and (os.clock() - etat.derniereTrame) or nil
    if etat.neutralise then
      print(string.format("LIAISON  : PERDUE - faces au repos%s",
        age and string.format(" (%.1fs)", age) or ""))
    else
      print(string.format("LIAISON  : OK - trame %d, il y a %.1fs", etat.sequence, age or 0))
    end
    print(string.rep("-", 30))
    for _, cote_ in ipairs(COTES) do
      if etat.niveaux[cote_] ~= nil then
        print(string.format("  %-7s %2d", cote_, etat.niveaux[cote_]))
      end
    end
    print(string.rep("-", 30))
    print(string.format("trames %d  refus %d", etat.trames, etat.refus))
    print("Ctrl+T pour arreter")
  end

  --- Reception des trames de commande.
  local function boucleReception()
    while true do
      local expediteur, message = rednet.receive(config.protocole, 1)

      if expediteur and type(message) == "table"
         and message.protocole == "FRENCHNET_SORTIE" then
        -- Filtre vehicule : deux appareils cote a cote ne se commandent pas.
        if config.vehicule and message.vehicule and message.vehicule ~= config.vehicule then
          journal.debug(ETAPES.RECEPTION, "trame d'un autre vehicule ignoree : "
            .. tostring(message.vehicule))
        else
          etat.maitre = expediteur
          etat.sequence = message.sequence or 0
          etat.derniereTrame = os.clock()
          etat.neutralise = false
          if type(message.repos) == "table" then etat.repos = message.repos end
          if message.delai then config.delaiChienDeGarde = message.delai end
          appliquer(message.sorties, "trame " .. tostring(message.sequence))
          etat.trames = etat.trames + 1

          -- Acquittement : c'est ce qui permet au maitre de savoir que ce
          -- groupe de moteurs repond encore, et de lire nos entrees.
          pcall(rednet.send, expediteur, {
            protocole   = "FRENCHNET_SORTIE_ACK",
            version     = 1,
            identifiant = config.identifiant,
            vehicule    = config.vehicule,
            idOrdinateur= os.getComputerID(),
            sequence    = etat.sequence,
            entrees     = config.remonterEntrees and lireEntrees() or nil,
            neutralise  = false,
          }, config.protocole)
        end
      end
    end
  end

  --- Chien de garde + annonce de presence.
  local function boucleSurveillance()
    while true do
      sleep(0.25)
      local age = etat.derniereTrame and (os.clock() - etat.derniereTrame) or math.huge
      if age > (config.delaiChienDeGarde or 1.5) then
        neutraliser(string.format("%.1fs sans trame", age == math.huge and -1 or age))
      end
    end
  end

  local function boucleAnnonce()
    while true do
      sleep(config.periodeAnnonce or 3)
      if etat.neutralise then
        pcall(rednet.broadcast, {
          protocole   = "FRENCHNET_SORTIE_ANNONCE",
          identifiant = config.identifiant,
          vehicule    = config.vehicule,
          idOrdinateur= os.getComputerID(),
          cotes       = config.cotesAutorises,
        }, config.protocole)
      end
    end
  end

  local function boucleAffichage()
    while true do
      pcall(afficher)
      sleep(0.5)
    end
  end

  parallel.waitForAny(boucleReception, boucleSurveillance, boucleAnnonce, boucleAffichage)
  error("une tache du satellite s'est terminee de maniere inattendue", 0)
end

--------------------------------------------------------------------------------
-- 7. SUPERVISEUR
--------------------------------------------------------------------------------

local function estTerminate(err)
  return type(err) == "string" and (err == "Terminated" or err:match("^Terminated\n") ~= nil)
end

local function neutraliserToutesLesFaces()
  for _, cote in ipairs(COTES) do pcall(ecrireCote, cote, 0) end
end

local echecs = 0
while true do
  local debut = os.clock()
  local ok, err = pcall(cycleDeVie)

  if ok then
    journal.avert(ETAPES.DEMARRAGE, "cycle termine sans erreur : relance immediate")
    echecs = 0
  else
    if estTerminate(err) then
      neutraliserToutesLesFaces()
      journal.info(ETAPES.ARRET, "arret manuel : toutes les faces remises a zero")
      return
    end
    -- Un satellite en erreur ne doit jamais laisser des moteurs sous tension.
    neutraliserToutesLesFaces()
    echecs = (os.clock() - debut >= 60) and 1 or (echecs + 1)
    journal.erreur(ETAPES.DEMARRAGE, "cycle interrompu : " .. tostring(err))
    local delai = math.min(3 * 2 ^ (echecs - 1), 60)
    journal.avert(ETAPES.DEMARRAGE, string.format("relance dans %ds", delai))
    sleep(delai)
  end
end
