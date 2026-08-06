--[[----------------------------------------------------------------------------
  FRENCHNET / AERONAUTICS WARFARE - Balise GPS fixe pour CC: Tweaked
  --------------------------------------------------------------------------
  Role      : diffuser en continu la position (X, Y, Z) de la balise via
              rednet (broadcast) sur un modem Ender (portee illimitee), et
              servir de hote GPS pour la constellation du serveur.
  Cible     : ordinateur fixe (advanced ou standard) + modem Ender.
  Autonomie : supervision interne, redemarrage automatique avec temporisation
              progressive, aucune intervention humaine requise.
  Journal   : chaque erreur est etiquetee avec l'ETAPE exacte ou elle survient.

  NOTE SUR LES ACCENTS : les chaines affichees a l'ecran et ecrites dans le
  journal sont volontairement sans accents. Le terminal de CC: Tweaked est
  oriente octet : un caractere accente en UTF-8 s'y afficherait sous forme de
  deux glyphes parasites. Les commentaires du code (jamais affiches) sont eux
  redigés normalement.
--------------------------------------------------------------------------------]]

local VERSION_PROGRAMME = "1.0.0"
local PROTOCOLE_VERSION = 1
local CANAL_GPS = 65534 -- gps.CHANNEL_GPS (constante vanilla CC: Tweaked)

--------------------------------------------------------------------------------
-- 1. NOMENCLATURE DES ETAPES
--    Chaque etape porte un nom explicite : il est repris tel quel dans le
--    journal, ce qui permet de localiser instantanement un plantage.
--------------------------------------------------------------------------------

local ETAPES = {
  DEMARRAGE                 = "demarrage du superviseur",
  CHARGEMENT_CONFIG         = "chargement de la configuration",
  VALIDATION_CONFIG         = "validation de la configuration",
  INIT_JOURNAL              = "initialisation du journal",
  DETECTION_MODEM           = "detection du modem ender",
  OUVERTURE_REDNET          = "ouverture rednet",
  OUVERTURE_CANAL_GPS       = "ouverture du canal GPS",
  RESOLUTION_POSITION       = "resolution de la position GPS",
  CONSTRUCTION_MESSAGE      = "construction du message de balise",
  ENVOI_REDNET              = "envoi rednet (broadcast)",
  REPONSE_GPS               = "reponse a une requete GPS",
  ECOUTE_PAIRS              = "ecoute des balises voisines",
  SURVEILLANCE_MATERIEL     = "surveillance du materiel (modem/rednet)",
  RAFRAICHISSEMENT_POSITION = "rafraichissement de la position",
  BOUCLE_PRINCIPALE         = "boucle principale (parallele)",
  ROTATION_JOURNAL          = "rotation du fichier journal",
  ARRET                     = "arret du programme",
}

--------------------------------------------------------------------------------
-- 2. VALEURS PAR DEFAUT
--    Toute cle absente du fichier de configuration reprend la valeur ci-dessous,
--    afin qu'une configuration incomplete ne fasse jamais planter la balise.
--------------------------------------------------------------------------------

local DEFAUTS = {
  identifiant              = nil,      -- OBLIGATOIRE, unique par balise
  designation              = "",       -- libelle libre (secteur, altitude...)
  intervalleSecondes       = 5,        -- periode de diffusion
  protocoleRednet          = "frenchnet_balise",
  positionManuelle         = nil,      -- { x = , y = , z = } -> recommande
  delaiGps                 = 5,        -- timeout de gps.locate (secondes)
  rafraichirPositionToutes = 300,      -- re-verification GPS (0 = jamais)
  hoteGps                  = true,     -- repondre aux requetes gps.locate
  ecouterPairs             = true,     -- detecter les autres balises
  journalFichier           = true,
  journalTailleMax         = 64 * 1024,
  journalNiveauEcran       = "INFO",   -- DEBUG | INFO | AVERT | ERREUR
  battementSecondes        = 60,       -- resume periodique dans le journal
  erreursAvantReinit       = 5,        -- echecs consecutifs -> reinitialisation
  redemarrageDelaiMin      = 3,
  redemarrageDelaiMax      = 60,
  arretParTerminate        = true,     -- Ctrl+T stoppe la balise
}

--------------------------------------------------------------------------------
-- 3. OUTILS DE BASE
--------------------------------------------------------------------------------

local function repertoireProgramme()
  if shell and shell.getRunningProgram then
    local ok, chemin = pcall(shell.getRunningProgram)
    if ok and chemin then
      local dossier = fs.getDir(chemin)
      if dossier and dossier ~= "" and dossier ~= "." then return dossier end
    end
  end
  return ""
end

local REPERTOIRE     = repertoireProgramme()
local CHEMIN_CONFIG  = fs.combine(REPERTOIRE, "config_balise.lua")
local CHEMIN_JOURNAL = fs.combine(REPERTOIRE, "balise.log")
local MARQUEUR_ARRET = fs.combine(REPERTOIRE, ".arret_manuel")

local function horodatage()
  local ok, texte = pcall(function()
    return os.date("!%Y-%m-%d %H:%M:%S", math.floor(os.epoch("utc") / 1000))
  end)
  if ok and texte then return texte end
  -- Repli si os.epoch / os.date sont indisponibles : temps du monde Minecraft.
  return string.format("jour %d %s", os.day(), textutils.formatTime(os.time(), true))
end

local function nombreValide(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--------------------------------------------------------------------------------
-- 4. JOURNAL
--    Format : [horodatage] [NIVEAU] [etape: <nom>] message
--------------------------------------------------------------------------------

local journal = {
  fichierActif = false,
  seuilEcran   = 1,
  ecrits       = 0,
  tailleMax    = 64 * 1024, -- valeur de repli avant lecture de la configuration
}

local NIVEAUX = { DEBUG = 0, INFO = 1, AVERT = 2, ERREUR = 3, CRITIQUE = 4 }
local COULEURS = {
  DEBUG    = colors.lightGray,
  INFO     = colors.white,
  AVERT    = colors.yellow,
  ERREUR   = colors.red,
  CRITIQUE = colors.magenta,
}

function journal.rotation()
  -- Volontairement sans journalisation interne : appele depuis journal.ecrire,
  -- toute erreur ici ne doit surtout pas provoquer de recursion.
  if not journal.fichierActif then return end
  if not fs.exists(CHEMIN_JOURNAL) then return end
  if fs.getSize(CHEMIN_JOURNAL) < journal.tailleMax then return end
  local archive = CHEMIN_JOURNAL .. ".1"
  if fs.exists(archive) then fs.delete(archive) end
  fs.move(CHEMIN_JOURNAL, archive)
end

function journal.ecrire(niveau, etape, message)
  local texte = tostring(message)
  -- Une pile d'appels tient sur plusieurs lignes : l'ecran n'affiche que la
  -- premiere (lisibilite), le fichier journal conserve la trace complete.
  local premiereLigne = texte:match("^[^\n]*") or texte
  local multiligne = premiereLigne ~= texte

  local entete = string.format("[%s] [%s] [etape: %s] ",
    horodatage(), niveau, tostring(etape))

  -- 4a. Sortie ecran (filtree par le niveau configure)
  if (NIVEAUX[niveau] or 1) >= journal.seuilEcran then
    local couleur
    if term.isColour and term.isColour() then
      couleur = COULEURS[niveau] or colors.white
      pcall(term.setTextColour, couleur)
    end
    print(entete .. premiereLigne
      .. ((multiligne and journal.fichierActif) and " [trace dans balise.log]" or ""))
    if couleur then pcall(term.setTextColour, colors.white) end
  end

  -- 4b. Sortie fichier (jamais bloquante : un disque plein ne doit pas tuer la balise)
  if journal.fichierActif then
    pcall(journal.rotation)
    local ok, fichier = pcall(fs.open, CHEMIN_JOURNAL, "a")
    if ok and fichier then
      pcall(function()
        fichier.writeLine(entete .. premiereLigne)
        if multiligne then
          for ligne in texte:gmatch("\n([^\n]*)") do
            fichier.writeLine("        | " .. ligne)
          end
        end
        fichier.close()
      end)
      journal.ecrits = journal.ecrits + 1
    end
  end
end

function journal.debug(e, m)    journal.ecrire("DEBUG", e, m)    end
function journal.info(e, m)     journal.ecrire("INFO", e, m)     end
function journal.avert(e, m)    journal.ecrire("AVERT", e, m)    end
function journal.erreur(e, m)   journal.ecrire("ERREUR", e, m)   end
function journal.critique(e, m) journal.ecrire("CRITIQUE", e, m) end

function journal.initialiser(config)
  journal.seuilEcran   = NIVEAUX[config.journalNiveauEcran] or NIVEAUX.INFO
  journal.tailleMax    = config.journalTailleMax
  journal.fichierActif = config.journalFichier and true or false
  if journal.fichierActif then
    -- Verification d'ecriture immediate : mieux vaut le savoir maintenant.
    local ok, fichier = pcall(fs.open, CHEMIN_JOURNAL, "a")
    if ok and fichier then
      fichier.close()
    else
      journal.fichierActif = false
      journal.avert(ETAPES.INIT_JOURNAL,
        "impossible d'ecrire " .. CHEMIN_JOURNAL .. " : journalisation ecran uniquement")
    end
  end
end

--------------------------------------------------------------------------------
-- 5. EXECUTION PROTEGEE
--    proteger() renvoie ok, resultat/erreur. L'erreur est toujours enrichie de
--    l'etape et, si disponible, de la pile d'appels.
--------------------------------------------------------------------------------

local function gestionnaireErreur(err)
  local texte = tostring(err)
  if debug and debug.traceback then
    local ok, trace = pcall(debug.traceback, texte, 2)
    if ok and trace then return trace end
  end
  return texte
end

--- Distingue l'arret manuel (Ctrl+T) d'une erreur ordinaire.
-- CC: Tweaked leve exactement "Terminated" (sans prefixe de position) ; on
-- exige donc ce mot en tout debut de message, suivi soit de la fin du texte,
-- soit du saut de ligne introduit par la pile d'appels. Une erreur reseau du
-- genre "Terminated modem link" ne doit surtout pas etre prise pour un arret
-- volontaire : la balise doit redemarrer, pas s'eteindre.
local function estTerminate(err)
  if type(err) ~= "string" then return false end
  return err == "Terminated" or err:match("^Terminated\n") ~= nil
end

--- Execute fn en capturant toute erreur et en la rattachant a une etape.
-- Les valeurs de retour de fn sont preservees (retours multiples inclus).
-- @return true, ... | false, messageErreur
local function proteger(etape, fn, ...)
  local args = table.pack(...)
  local resultats
  local ok, err = xpcall(function()
    resultats = table.pack(fn(table.unpack(args, 1, args.n)))
  end, gestionnaireErreur)

  if not ok then
    if estTerminate(err) then error(err, 0) end -- laisse remonter l'arret manuel
    journal.erreur(etape, "erreur detectee a l'etape '" .. etape .. "' : " .. tostring(err))
    return false, err
  end
  return true, table.unpack(resultats, 1, resultats.n)
end

--- Variante qui fait remonter l'erreur au superviseur apres journalisation.
local function exigerEtape(etape, fn, ...)
  local resultats = table.pack(proteger(etape, fn, ...))
  if not resultats[1] then
    error("ETAPE[" .. etape .. "] " .. tostring(resultats[2]), 0)
  end
  return table.unpack(resultats, 2, resultats.n)
end

--------------------------------------------------------------------------------
-- 6. CONFIGURATION
--------------------------------------------------------------------------------

local function chargerConfiguration()
  if not fs.exists(CHEMIN_CONFIG) then
    error("fichier de configuration introuvable : " .. CHEMIN_CONFIG, 0)
  end
  local fichier = fs.open(CHEMIN_CONFIG, "r")
  if not fichier then
    error("lecture impossible : " .. CHEMIN_CONFIG, 0)
  end
  local source = fichier.readAll()
  fichier.close()

  local morceau, err = load(source, "@" .. CHEMIN_CONFIG, "t", _G)
  if not morceau then
    error("configuration illisible (syntaxe Lua) : " .. tostring(err), 0)
  end
  local table_config = morceau()
  if type(table_config) ~= "table" then
    error("la configuration doit se terminer par 'return { ... }'", 0)
  end

  -- Fusion avec les valeurs par defaut.
  local config = {}
  for cle, valeur in pairs(DEFAUTS) do config[cle] = valeur end
  for cle, valeur in pairs(table_config) do config[cle] = valeur end
  return config
end

local function validerConfiguration(config)
  local anomalies = {}

  if type(config.identifiant) ~= "string" or config.identifiant == "" then
    table.insert(anomalies, "'identifiant' manquant : chaque balise doit porter un identifiant unique")
  elseif #config.identifiant > 32 then
    table.insert(anomalies, "'identifiant' trop long (32 caracteres maximum)")
  end

  if not nombreValide(config.intervalleSecondes) or config.intervalleSecondes < 1 then
    table.insert(anomalies, "'intervalleSecondes' doit etre un nombre >= 1")
  end

  if type(config.protocoleRednet) ~= "string" or config.protocoleRednet == "" then
    table.insert(anomalies, "'protocoleRednet' doit etre une chaine non vide")
  end

  if config.positionManuelle ~= nil then
    local p = config.positionManuelle
    if type(p) ~= "table" or not (nombreValide(p.x) and nombreValide(p.y) and nombreValide(p.z)) then
      table.insert(anomalies, "'positionManuelle' doit etre { x = nombre, y = nombre, z = nombre }")
    end
  end

  if not nombreValide(config.delaiGps) or config.delaiGps <= 0 then
    table.insert(anomalies, "'delaiGps' doit etre un nombre > 0")
  end

  -- Reglages numeriques secondaires : un type errone provoquerait une erreur
  -- arithmetique en pleine boucle, donc on le detecte des le demarrage.
  local numeriques = {
    "rafraichirPositionToutes", "erreursAvantReinit", "battementSecondes",
    "redemarrageDelaiMin", "redemarrageDelaiMax", "journalTailleMax",
  }
  for _, cle in ipairs(numeriques) do
    if not nombreValide(config[cle]) or config[cle] < 0 then
      table.insert(anomalies, "'" .. cle .. "' doit etre un nombre >= 0")
    end
  end

  if #anomalies > 0 then
    error("configuration invalide -> " .. table.concat(anomalies, " | "), 0)
  end
  return config
end

--------------------------------------------------------------------------------
-- 7. MATERIEL RESEAU (modem Ender)
--------------------------------------------------------------------------------

--- Determine si un peripherique est un modem Ender (portee illimitee).
local function estModemEnder(nom)
  if peripheral.hasType then
    local ok, resultat = pcall(peripheral.hasType, nom, "ender_modem")
    if ok and resultat then return true end
  end
  -- Repli : identification par le nom de bloc renvoye par certaines versions.
  local ok, type_periph = pcall(peripheral.getType, nom)
  if ok and type(type_periph) == "string" and string.find(type_periph, "ender", 1, true) then
    return true
  end
  return false
end

--- Cherche un modem sans fil, en privilegiant explicitement le modem Ender.
-- @return cote, modem, ender (booleen)
local function detecterModem(config)
  if type(config.coteModem) == "string" and config.coteModem ~= "" then
    -- Cote impose par la configuration.
    if not peripheral.isPresent(config.coteModem) then
      error("aucun peripherique sur le cote impose '" .. config.coteModem .. "'", 0)
    end
    local modem = peripheral.wrap(config.coteModem)
    local sansFil = false
    if modem and modem.isWireless then
      local ok, resultat = pcall(modem.isWireless)
      sansFil = ok and resultat
    end
    if not sansFil then
      error("le peripherique '" .. config.coteModem .. "' n'est pas un modem sans fil", 0)
    end
    return config.coteModem, modem, estModemEnder(config.coteModem)
  end

  local repli_cote, repli_modem = nil, nil
  for _, nom in ipairs(peripheral.getNames()) do
    local ok, type_periph = pcall(peripheral.getType, nom)
    if ok and type_periph == "modem" then
      local modem = peripheral.wrap(nom)
      local sansFil = false
      if modem and modem.isWireless then
        local okFil, resultat = pcall(modem.isWireless)
        sansFil = okFil and resultat
      end
      if sansFil then
        if estModemEnder(nom) then
          return nom, modem, true -- modem Ender : choix prioritaire
        end
        repli_cote, repli_modem = repli_cote or nom, repli_modem or modem
      end
    end
  end

  if repli_modem then
    return repli_cote, repli_modem, false
  end
  error("aucun modem sans fil detecte : verifiez que le modem Ender est bien accole a l'ordinateur", 0)
end

--------------------------------------------------------------------------------
-- 8. POSITION
--------------------------------------------------------------------------------

local function resoudrePosition(config)
  -- 8a. Position declaree manuellement : source de verite absolue pour une
  --     balise fixe (et prerequis pour servir d'hote GPS).
  if config.positionManuelle then
    local p = config.positionManuelle
    return { x = p.x, y = p.y, z = p.z, source = "manuelle" }
  end

  -- 8b. Sinon, trilateration via l'API GPS native.
  local x, y, z = gps.locate(config.delaiGps, false)
  if not x then
    error("gps.locate n'a renvoye aucune position (moins de 4 hotes GPS a portee, "
      .. "ou hotes trop mal repartis)", 0)
  end
  if not (nombreValide(x) and nombreValide(y) and nombreValide(z)) then
    error("gps.locate a renvoye des coordonnees invalides", 0)
  end
  return { x = x, y = y, z = z, source = "gps" }
end

--------------------------------------------------------------------------------
-- 9. MESSAGE DIFFUSE
--------------------------------------------------------------------------------

local function construireMessage(contexte)
  local config = contexte.config
  contexte.sequence = contexte.sequence + 1
  return {
    protocole      = "FRENCHNET_BALISE",
    version        = PROTOCOLE_VERSION,
    programme      = VERSION_PROGRAMME,
    identifiant    = config.identifiant,
    designation    = config.designation,
    idOrdinateur   = os.getComputerID(),
    etiquette      = os.getComputerLabel(),
    x              = contexte.position.x,
    y              = contexte.position.y,
    z              = contexte.position.z,
    positionSource = contexte.position.source,
    hoteGps        = contexte.hoteGpsActif and true or false,
    modemEnder     = contexte.modemEnder and true or false,
    intervalle     = config.intervalleSecondes,
    sequence       = contexte.sequence,
    horodatageUtc  = (function()
      local ok, v = pcall(os.epoch, "utc")
      return ok and v or nil
    end)(),
    jourMonde      = os.day(),
    heureMonde     = os.time(),
    fonctionnement = math.floor(os.clock() - contexte.demarrageHorloge),
    erreursTotales = contexte.erreursTotales,
    redemarrages   = contexte.redemarrages,
  }
end

--------------------------------------------------------------------------------
-- 10. BOUCLES CONCURRENTES
--------------------------------------------------------------------------------

--- 10a. Diffusion continue de la position.
local function boucleEmission(contexte)
  local config = contexte.config
  while true do
    local ok, message = proteger(ETAPES.CONSTRUCTION_MESSAGE, construireMessage, contexte)

    if ok then
      local okEnvoi = proteger(ETAPES.ENVOI_REDNET, function()
        rednet.broadcast(message, config.protocoleRednet)
      end)

      if okEnvoi then
        contexte.echecsConsecutifs = 0
        contexte.emissions = contexte.emissions + 1
        journal.debug(ETAPES.ENVOI_REDNET, string.format(
          "trame #%d diffusee : X=%.1f Y=%.1f Z=%.1f",
          message.sequence, message.x, message.y, message.z))
      else
        contexte.echecsConsecutifs = contexte.echecsConsecutifs + 1
        contexte.erreursTotales = contexte.erreursTotales + 1
      end
    else
      contexte.echecsConsecutifs = contexte.echecsConsecutifs + 1
      contexte.erreursTotales = contexte.erreursTotales + 1
    end

    -- Trop d'echecs d'affilee : le lien reseau est probablement rompu.
    -- On remonte au superviseur, qui refera toute la sequence d'initialisation.
    if contexte.echecsConsecutifs >= config.erreursAvantReinit then
      error("ETAPE[" .. ETAPES.ENVOI_REDNET .. "] " .. contexte.echecsConsecutifs
        .. " echecs d'emission consecutifs : reinitialisation du lien reseau", 0)
    end

    sleep(config.intervalleSecondes)
  end
end

--- 10b. Service hote GPS : repond aux gps.locate des autres machines.
--       Protocole vanilla : requete "PING" sur le canal 65534, reponse {x,y,z}.
local function boucleHoteGps(contexte)
  while true do
    local _, cote, canal, canalReponse, message = os.pullEvent("modem_message")
    if canal == CANAL_GPS and message == "PING" and cote == contexte.coteModem then
      proteger(ETAPES.REPONSE_GPS, function()
        contexte.modem.transmit(canalReponse, CANAL_GPS, {
          contexte.position.x, contexte.position.y, contexte.position.z,
        })
        contexte.reponsesGps = contexte.reponsesGps + 1
      end)
    end
  end
end

--- 10c. Ecoute des balises voisines : inventaire de la constellation et
---      detection d'un identifiant duplique (erreur de deploiement classique).
local function boucleEcoutePairs(contexte)
  local config = contexte.config
  while true do
    local ok, expediteur, message = proteger(ETAPES.ECOUTE_PAIRS, function()
      return rednet.receive(config.protocoleRednet, 30)
    end)

    if ok and expediteur and type(message) == "table"
       and message.protocole == "FRENCHNET_BALISE" then
      local identifiant = tostring(message.identifiant)

      if identifiant == config.identifiant and expediteur ~= os.getComputerID() then
        journal.critique(ETAPES.ECOUTE_PAIRS, string.format(
          "CONFLIT D'IDENTIFIANT : l'ordinateur #%d diffuse aussi '%s'. "
          .. "Renommez l'une des deux balises.", expediteur, identifiant))
      elseif expediteur ~= os.getComputerID() then
        if not contexte.pairs[identifiant] then
          journal.info(ETAPES.ECOUTE_PAIRS, string.format(
            "balise voisine detectee : %s (ordinateur #%d) X=%s Y=%s Z=%s",
            identifiant, expediteur, tostring(message.x), tostring(message.y),
            tostring(message.z)))
        end
        contexte.pairs[identifiant] = {
          idOrdinateur = expediteur,
          x = message.x, y = message.y, z = message.z,
          vuA = os.clock(),
        }
      end
    elseif not ok then
      sleep(5) -- evite une boucle d'erreur a pleine vitesse
    end
  end
end

--- 10d. Surveillance materielle + battement de coeur.
local function boucleSurveillance(contexte)
  local config = contexte.config
  while true do
    sleep(math.max(5, math.min(config.battementSecondes, 60)))

    exigerEtape(ETAPES.SURVEILLANCE_MATERIEL, function()
      if not peripheral.isPresent(contexte.coteModem) then
        error("le modem a disparu du cote '" .. contexte.coteModem .. "'", 0)
      end
      if not rednet.isOpen(contexte.coteModem) then
        error("rednet s'est referme sur le cote '" .. contexte.coteModem .. "'", 0)
      end
    end)

    local maintenant = os.clock()
    if maintenant - contexte.dernierBattement >= config.battementSecondes then
      contexte.dernierBattement = maintenant
      local nbPairs = 0
      for _ in pairs(contexte.pairs) do nbPairs = nbPairs + 1 end
      journal.info(ETAPES.SURVEILLANCE_MATERIEL, string.format(
        "OK | %s | X=%.1f Y=%.1f Z=%.1f | trames=%d | reponses GPS=%d | voisins=%d "
        .. "| erreurs=%d | actif depuis %ds",
        config.identifiant, contexte.position.x, contexte.position.y, contexte.position.z,
        contexte.emissions, contexte.reponsesGps, nbPairs, contexte.erreursTotales,
        math.floor(maintenant - contexte.demarrageHorloge)))
    end
  end
end

--- 10e. Re-verification periodique de la position (uniquement en mode GPS).
local function boucleRafraichissementPosition(contexte)
  local config = contexte.config
  while true do
    sleep(config.rafraichirPositionToutes)
    local ok, position = proteger(ETAPES.RAFRAICHISSEMENT_POSITION,
      resoudrePosition, config)
    if ok and position then
      local dx = math.abs(position.x - contexte.position.x)
      local dy = math.abs(position.y - contexte.position.y)
      local dz = math.abs(position.z - contexte.position.z)
      if dx + dy + dz > 0 then
        journal.avert(ETAPES.RAFRAICHISSEMENT_POSITION, string.format(
          "position corrigee : (%.1f, %.1f, %.1f) -> (%.1f, %.1f, %.1f)",
          contexte.position.x, contexte.position.y, contexte.position.z,
          position.x, position.y, position.z))
        contexte.position = position
      end
    else
      -- Echec sans consequence : on conserve la derniere position connue.
      journal.avert(ETAPES.RAFRAICHISSEMENT_POSITION,
        "position non rafraichie, conservation de la derniere valeur connue")
    end
  end
end

--------------------------------------------------------------------------------
-- 11. CYCLE DE VIE COMPLET (une session de la balise)
--------------------------------------------------------------------------------

-- Derniere configuration valide chargee : sert au superviseur pour calculer les
-- temporisations de redemarrage meme si un cycle ulterieur echoue tres tot.
local configActive = nil

local function cycleDeVie(etat)
  ------------------------------------------------------------------ configuration
  local config = exigerEtape(ETAPES.CHARGEMENT_CONFIG, chargerConfiguration)
  exigerEtape(ETAPES.VALIDATION_CONFIG, validerConfiguration, config)
  configActive = config
  exigerEtape(ETAPES.INIT_JOURNAL, journal.initialiser, config)

  journal.info(ETAPES.DEMARRAGE, string.format(
    "balise '%s'%s | programme v%s | ordinateur #%d",
    config.identifiant,
    config.designation ~= "" and (" (" .. config.designation .. ")") or "",
    VERSION_PROGRAMME, os.getComputerID()))

  ------------------------------------------------------------------------ modem
  local coteModem, modem, modemEnder = exigerEtape(ETAPES.DETECTION_MODEM,
    detecterModem, config)

  if modemEnder then
    journal.info(ETAPES.DETECTION_MODEM,
      "modem Ender detecte sur '" .. coteModem .. "' : portee illimitee")
  else
    journal.avert(ETAPES.DETECTION_MODEM, "modem sans fil detecte sur '" .. coteModem
      .. "' mais il ne semble PAS etre un modem Ender : la portee sera limitee "
      .. "(quelques centaines de blocs), insuffisante pour un espacement de 3000-4000 blocs")
  end

  ----------------------------------------------------------------------- rednet
  exigerEtape(ETAPES.OUVERTURE_REDNET, function()
    if not rednet.isOpen(coteModem) then rednet.open(coteModem) end
    if not rednet.isOpen(coteModem) then
      error("rednet.open a echoue silencieusement sur '" .. coteModem .. "'", 0)
    end
  end)
  journal.info(ETAPES.OUVERTURE_REDNET, "rednet ouvert, protocole '"
    .. config.protocoleRednet .. "'")

  --------------------------------------------------------------------- position
  local position = exigerEtape(ETAPES.RESOLUTION_POSITION, resoudrePosition, config)
  journal.info(ETAPES.RESOLUTION_POSITION, string.format(
    "position %s : X=%.1f Y=%.1f Z=%.1f", position.source,
    position.x, position.y, position.z))

  -- Controle croise : si les deux sources existent, on compare.
  if config.positionManuelle and config.verifierAvecGps then
    local ok, mesure = proteger(ETAPES.RESOLUTION_POSITION, function()
      local x, y, z = gps.locate(config.delaiGps, false)
      if not x then error("aucune reponse GPS pour le controle croise", 0) end
      return { x = x, y = y, z = z }
    end)
    if ok and mesure then
      local ecart = math.abs(mesure.x - position.x) + math.abs(mesure.y - position.y)
        + math.abs(mesure.z - position.z)
      if ecart > 0 then
        journal.avert(ETAPES.RESOLUTION_POSITION, string.format(
          "ecart entre position manuelle et mesure GPS : %.1f bloc(s) cumule(s) "
          .. "(mesure : %.1f, %.1f, %.1f)", ecart, mesure.x, mesure.y, mesure.z))
      else
        journal.info(ETAPES.RESOLUTION_POSITION, "controle croise GPS conforme")
      end
    end
  end

  ------------------------------------------------------------------- hote GPS ?
  local hoteGpsActif = false
  if config.hoteGps then
    if position.source == "manuelle" then
      exigerEtape(ETAPES.OUVERTURE_CANAL_GPS, function()
        modem.open(CANAL_GPS)
        if not modem.isOpen(CANAL_GPS) then
          error("le canal GPS " .. CANAL_GPS .. " n'a pas pu etre ouvert", 0)
        end
      end)
      hoteGpsActif = true
      journal.info(ETAPES.OUVERTURE_CANAL_GPS,
        "service hote GPS actif sur le canal " .. CANAL_GPS)
    else
      journal.avert(ETAPES.OUVERTURE_CANAL_GPS,
        "hote GPS desactive : la position provient de gps.locate et non de "
        .. "'positionManuelle'. Un hote GPS doit connaitre ses coordonnees exactes.")
    end
  end

  ---------------------------------------------------------------------- contexte
  local contexte = {
    config            = config,
    coteModem         = coteModem,
    modem             = modem,
    modemEnder        = modemEnder,
    position          = position,
    hoteGpsActif      = hoteGpsActif,
    sequence          = 0,
    emissions         = 0,
    reponsesGps       = 0,
    erreursTotales    = 0,
    echecsConsecutifs = 0,
    redemarrages      = etat.redemarrages,
    pairs             = {},
    demarrageHorloge  = os.clock(),
    dernierBattement  = 0,
  }

  ------------------------------------------------------------- boucles paralleles
  local taches = { function() boucleEmission(contexte) end }

  if hoteGpsActif then
    table.insert(taches, function() boucleHoteGps(contexte) end)
  end
  if config.ecouterPairs then
    table.insert(taches, function() boucleEcoutePairs(contexte) end)
  end
  table.insert(taches, function() boucleSurveillance(contexte) end)
  if position.source == "gps" and nombreValide(config.rafraichirPositionToutes)
     and config.rafraichirPositionToutes > 0 then
    table.insert(taches, function() boucleRafraichissementPosition(contexte) end)
  end

  journal.info(ETAPES.BOUCLE_PRINCIPALE, string.format(
    "diffusion active : %d tache(s), intervalle %ds", #taches, config.intervalleSecondes))

  -- waitForAny : si une tache remonte une erreur, on repasse par le superviseur
  -- qui refait integralement la sequence d'initialisation.
  parallel.waitForAny(table.unpack(taches))
  error("ETAPE[" .. ETAPES.BOUCLE_PRINCIPALE .. "] une tache s'est terminee de "
    .. "maniere inattendue", 0)
end

--------------------------------------------------------------------------------
-- 12. SUPERVISEUR
--     Ne rend jamais la main sauf arret manuel : capture toute erreur, la
--     journalise avec son etape, puis relance apres une temporisation
--     progressive (evite le matraquage en cas de panne materielle durable).
--------------------------------------------------------------------------------

local function superviseur()
  local etat = { redemarrages = 0 }
  local echecsConsecutifs = 0

  -- Le fichier marqueur signale a startup.lua un arret volontaire (Ctrl+T).
  if fs.exists(MARQUEUR_ARRET) then pcall(fs.delete, MARQUEUR_ARRET) end

  journal.info(ETAPES.DEMARRAGE, "superviseur FrenchNet v" .. VERSION_PROGRAMME
    .. " - configuration : " .. CHEMIN_CONFIG)

  while true do
    local debut = os.clock()
    local ok, err = xpcall(function() return cycleDeVie(etat) end, gestionnaireErreur)

    if ok then
      -- cycleDeVie ne doit jamais se terminer normalement.
      journal.avert(ETAPES.BOUCLE_PRINCIPALE, "cycle termine sans erreur : relance immediate")
      echecsConsecutifs = 0
    else
      if estTerminate(err) then
        if rawget(_G, "__BALISE_ARRET_MANUEL_AUTORISE") == false then
          -- Mode 'autonomie totale' : Ctrl+T est journalise puis ignore.
          journal.avert(ETAPES.ARRET,
            "tentative d'arret manuel ignoree (arretParTerminate = false)")
        else
          journal.info(ETAPES.ARRET, "arret manuel demande (Ctrl+T)")
          local okFichier, fichier = pcall(fs.open, MARQUEUR_ARRET, "w")
          if okFichier and fichier then
            fichier.writeLine(horodatage())
            fichier.close()
          end
          journal.info(ETAPES.ARRET, "balise stoppee")
          return
        end
      end

      echecsConsecutifs = (os.clock() - debut >= 60) and 1 or (echecsConsecutifs + 1)
      etat.redemarrages = etat.redemarrages + 1

      journal.critique(ETAPES.DEMARRAGE, "cycle interrompu : " .. tostring(err))

      local reglages = configActive or DEFAUTS
      local delaiMin = nombreValide(reglages.redemarrageDelaiMin)
        and reglages.redemarrageDelaiMin or DEFAUTS.redemarrageDelaiMin
      local delaiMax = nombreValide(reglages.redemarrageDelaiMax)
        and reglages.redemarrageDelaiMax or DEFAUTS.redemarrageDelaiMax
      local delai = math.floor(math.max(1,
        math.min(delaiMin * 2 ^ (echecsConsecutifs - 1), delaiMax)))
      journal.avert(ETAPES.DEMARRAGE, string.format(
        "redemarrage automatique n%d dans %d seconde(s)", etat.redemarrages, delai))
      sleep(delai)
    end
  end
end

--------------------------------------------------------------------------------
-- 13. POINT D'ENTREE
--     La configuration est lue une premiere fois ici uniquement pour savoir si
--     Ctrl+T doit etre honore ; toute erreur a ce stade est non bloquante.
--------------------------------------------------------------------------------

local okConfigInitiale, configInitiale = pcall(chargerConfiguration)
if okConfigInitiale and type(configInitiale) == "table"
   and configInitiale.arretParTerminate == false then
  rawset(_G, "__BALISE_ARRET_MANUEL_AUTORISE", false)
  -- Ctrl+T est ignore : la balise redemarre meme apres une tentative d'arret.
end

term.clear()
term.setCursorPos(1, 1)
print("=== FRENCHNET - BALISE GPS (AERONAUTICS WARFARE) ===")
print("Programme v" .. VERSION_PROGRAMME .. " - ordinateur #" .. os.getComputerID())
print(string.rep("-", 40))

if rawget(_G, "__BALISE_ARRET_MANUEL_AUTORISE") == false then
  -- Boucle externe ultime : meme un Terminate ne stoppe pas la balise.
  while true do
    local ok, err = pcall(superviseur)
    if not ok then
      journal.critique(ETAPES.ARRET, "superviseur interrompu : " .. tostring(err)
        .. " - relance dans 5s")
      pcall(sleep, 5)
    end
  end
else
  superviseur()
end
