--[[----------------------------------------------------------------------------
  FRENCHNET COMMAND - Systeme de defense aerienne autonome (CC: Tweaked)
  --------------------------------------------------------------------------
  Serveur    : AERONAUTICS WARFARE
  Pile       : NeoForge 1.21.1 - Create Aeronautics - Create Radars -
               Create Big Cannons - Open Parties and Claims - CC: Tweaked
  Cible      : ordinateur avance au sol + modem Ender + radar (Create Radars)

  ROLE ET LIMITE DU SYSTEME
  Command decide SI et QUAND engager une cible. Il ne pilote aucune arme, ne
  choisit aucun calibre, ne calcule aucune balistique. Il designe la plateforme
  qui doit reagir et transmet sa decision a FrenchNet Fire Control, qui reste
  seul responsable du tir.

  CHAINE DE TRAITEMENT ET POINTS DE JOURNALISATION
      1. DETECTION ............. chaque echo radar, avec sa piste
      2. CLASSIFICATION ........ categorie (3 valeurs) + statut IFF
      3. DECISION D'ESCALADE ... verdict issu de la table d'engagement
      4. DESIGNATION ........... plateforme retenue et score de repartition
      5. CONFIRMATION .......... destruction confirmee, perdue, ou reemission
  Chaque etape est journalisee avec son nom exact : en cas de comportement
  anormal, le journal donne directement l'etape fautive.

  NOTE SUR LES ACCENTS : les chaines affichees ou journalisees sont sans
  accents (terminal CC: Tweaked oriente octet). Les commentaires, jamais
  affiches, sont rédigés normalement.
--------------------------------------------------------------------------------]]

local VERSION_PROGRAMME = "1.0.0"
local PROTOCOLE_VERSION = 1

--------------------------------------------------------------------------------
-- 1. NOMENCLATURE DES ETAPES
--------------------------------------------------------------------------------

local ETAPES = {
  DEMARRAGE            = "demarrage du superviseur",
  CHARGEMENT_NOYAU     = "chargement du noyau de decision",
  CHARGEMENT_CONFIG    = "chargement de la configuration",
  VALIDATION_CONFIG    = "validation de la configuration",
  INIT_JOURNAL         = "initialisation du journal",
  CHARGEMENT_ZONES     = "chargement des zones",
  ENREGISTREMENT_ZONES = "enregistrement des zones",
  CHARGEMENT_ETAT      = "chargement de l'etat persistant",
  ENREGISTREMENT_ETAT  = "enregistrement de l'etat persistant",
  DETECTION_MODEM      = "detection du modem ender",
  OUVERTURE_REDNET     = "ouverture rednet",
  DETECTION_RADAR      = "detection du radar",
  BALAYAGE_RADAR       = "balayage radar",
  NORMALISATION_ECHOS  = "normalisation des echos radar",
  MISE_A_JOUR_PISTES   = "mise a jour des pistes",
  DETECTION            = "detection d'un contact",
  CLASSIFICATION       = "classification de la cible",
  RESOLUTION_ZONE      = "resolution de la zone",
  DECISION_ESCALADE    = "decision d'escalade",
  DESIGNATION_TIREUR   = "designation du tireur",
  EMISSION_ORDRE       = "emission de l'ordre vers Fire Control",
  EVALUATION_KILL      = "evaluation de la destruction",
  CONFIRMATION_KILL    = "confirmation de destruction",
  REEMISSION_ORDRE     = "reemission d'un ordre de tir",
  ALERTE_CONTROLEUR    = "alerte controleur humain",
  RECEPTION_TRANSPONDEUR = "reception d'un code transpondeur",
  RECEPTION_INVENTAIRE = "reception de l'inventaire Fire Control",
  RECEPTION_ROSTER     = "reception du roster de factions",
  BASCULE_MODE         = "bascule guerre / paix",
  ALERTE_MAXIMALE      = "alerte maximale manuelle",
  CONFIGURATION_ZONE   = "configuration d'une zone",
  ROTATION_CODE        = "rotation du code general",
  INTERFACE            = "interface de controle",
  BOUCLE_PRINCIPALE    = "boucle principale (parallele)",
  ROTATION_JOURNAL     = "rotation du fichier journal",
  ARRET                = "arret du programme",
}

--------------------------------------------------------------------------------
-- 2. OUTILS DE BASE ET CHEMINS
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

local REPERTOIRE      = repertoireProgramme()
local CHEMIN_CONFIG   = fs.combine(REPERTOIRE, "config_command.lua")
local CHEMIN_NOYAU    = fs.combine(REPERTOIRE, "noyau.lua")
local CHEMIN_INTERFACE= fs.combine(REPERTOIRE, "interface.lua")
local CHEMIN_JOURNAL  = fs.combine(REPERTOIRE, "command.log")
local CHEMIN_ZONES    = fs.combine(REPERTOIRE, "zones.dat")
local CHEMIN_ETAT     = fs.combine(REPERTOIRE, "etat.dat")
local MARQUEUR_ARRET  = fs.combine(REPERTOIRE, ".arret_manuel")

local function horodatage()
  local ok, texte = pcall(function()
    return os.date("!%Y-%m-%d %H:%M:%S", math.floor(os.epoch("utc") / 1000))
  end)
  if ok and texte then return texte end
  return string.format("jour %d %s", os.day(), textutils.formatTime(os.time(), true))
end

local function nombreValide(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--------------------------------------------------------------------------------
-- 3. JOURNAL
--    Format : [horodatage] [NIVEAU] [etape: <nom>] message
--------------------------------------------------------------------------------

local journal = {
  fichierActif = false,
  seuilEcran   = 1,
  tailleMax    = 128 * 1024,
  tampon       = {},      -- derniers messages, pour l'ecran "journal" de l'interface
  tamponMax    = 200,
}

local NIVEAUX  = { DEBUG = 0, INFO = 1, AVERT = 2, ERREUR = 3, CRITIQUE = 4 }
local COULEURS = {
  DEBUG    = colors.lightGray,
  INFO     = colors.white,
  AVERT    = colors.yellow,
  ERREUR   = colors.red,
  CRITIQUE = colors.magenta,
}

function journal.rotation()
  -- Aucune journalisation interne ici : appele depuis journal.ecrire, toute
  -- erreur provoquerait une recursion.
  if not journal.fichierActif then return end
  if not fs.exists(CHEMIN_JOURNAL) then return end
  if fs.getSize(CHEMIN_JOURNAL) < journal.tailleMax then return end
  local archive = CHEMIN_JOURNAL .. ".1"
  if fs.exists(archive) then fs.delete(archive) end
  fs.move(CHEMIN_JOURNAL, archive)
end

function journal.ecrire(niveau, etape, message)
  local ligne = string.format("[%s] [%s] [etape: %s] %s",
    horodatage(), niveau, etape or "?", tostring(message))

  -- Tampon memoire (consulte par l'interface).
  journal.tampon[#journal.tampon + 1] = { niveau = niveau, texte = ligne }
  while #journal.tampon > journal.tamponMax do table.remove(journal.tampon, 1) end

  if (NIVEAUX[niveau] or 1) >= journal.seuilEcran and not journal.ecranSilencieux then
    pcall(function()
      if term.isColour and term.isColour() then term.setTextColour(COULEURS[niveau] or colors.white) end
      print(ligne)
      if term.isColour and term.isColour() then term.setTextColour(colors.white) end
    end)
  end

  if journal.fichierActif then
    pcall(function()
      journal.rotation()
      local f = fs.open(CHEMIN_JOURNAL, "a")
      if f then f.writeLine(ligne) f.close() end
    end)
  end
end

local function debug_(etape, msg)    journal.ecrire("DEBUG", etape, msg) end
local function info(etape, msg)      journal.ecrire("INFO", etape, msg) end
local function avert(etape, msg)     journal.ecrire("AVERT", etape, msg) end
local function erreur(etape, msg)    journal.ecrire("ERREUR", etape, msg) end
local function critique(etape, msg)  journal.ecrire("CRITIQUE", etape, msg) end

--[[
  Execution protegee etiquetee par l'etape : c'est le seul moyen d'appeler une
  API du jeu dans ce programme. Toute erreur est ainsi localisee precisement.

  Retourne TOUJOURS un booleen de succes en premiere valeur, puis les valeurs
  rendues par la fonction. Ne jamais deduire le succes de la premiere valeur
  rendue : rednet.broadcast, rednet.open ou fs.close ne retournent rien, et un
  appel parfaitement reussi rendrait alors nil. C'est exactement ce qui ferait
  passer chaque ordre de tir pour un echec de transmission.
]]
local function proteger(etape, fn, ...)
  local resultats = table.pack(pcall(fn, ...))
  if not resultats[1] then
    erreur(etape, string.format("erreur detectee a l'etape '%s' : %s",
      etape, tostring(resultats[2])))
    return false, resultats[2]
  end
  return true, table.unpack(resultats, 2, resultats.n)
end

--------------------------------------------------------------------------------
-- 4. CHARGEMENT DU NOYAU DE DECISION
--------------------------------------------------------------------------------

local noyau
do
  local charge, err = loadfile(CHEMIN_NOYAU)
  if not charge then
    printError("[etape: " .. ETAPES.CHARGEMENT_NOYAU .. "] noyau.lua introuvable ou invalide : " .. tostring(err))
    printError("Le poste ne peut pas demarrer sans son noyau de decision.")
    return
  end
  local ok, resultat = pcall(charge)
  if not ok or type(resultat) ~= "table" then
    printError("[etape: " .. ETAPES.CHARGEMENT_NOYAU .. "] noyau.lua n'a pas pu etre initialise : " .. tostring(resultat))
    return
  end
  noyau = resultat
end

--------------------------------------------------------------------------------
-- 5. CONFIGURATION
--------------------------------------------------------------------------------

local DEFAUTS = {
  identifiant              = "CMD-01",
  designation              = "",
  peripheriqueRadar        = nil,
  positionRadar            = { x = 0, y = 64, z = 0 },
  positionsRelatives       = nil,
  porteeRadar              = 512,
  intervalleBalayage       = 1,
  historiquePiste          = 20,
  oubliPisteSecondes       = 30,
  codeAllie                = nil,
  codeGeneral              = nil,
  codeGeneralPrecedent     = nil,
  graceRotation            = 300,
  validiteTranspondeur     = 15,
  toleranceAppariement     = 24,
  altitudeSolReference     = 64,
  hauteurAerienne          = 25,
  vitesseVerticaleAerienne = 6,
  traiterEntitesNeutres    = false,
  protocoleFireControl     = "frenchnet_fire_control",
  protocoleTranspondeur    = "frenchnet_transpondeur",
  protocoleRoster          = "frenchnet_roster",
  idFireControl            = nil,
  categoriesFireControl    = nil,
  modeleOrdre              = "%s %s type %s",
  formatUniqueFire         = false,
  verbeScramble            = "Scramble",
  envoyerDetails           = false,
  poidsTirs                = 1.0,
  poidsDistance            = 1.0,
  designerHorsPortee       = false,
  validiteInventaire       = 60,
  disparitionSecondes      = 3,
  ratioEnveloppeFiable     = 0.80,
  fenetreCrashSecondes     = 3,
  perteVitesseRatio        = 0.50,
  perteAltitudeBlocs       = 40,
  vitesseMiniCrash         = 2,
  delaiEvaluationSecondes  = 8,
  tentativesMax            = 3,
  alerteMaxCouvreHorsZone  = false,
  alerteMaxDureeSecondes   = 0,
  codeAccesMenu            = "1234",
  moniteur                 = nil,
  echelleMoniteur          = 0.5,
  contactsAffiches         = 6,
  sortieRedstoneAlerte     = nil,
  journalFichier           = true,
  journalTailleMax         = 131072,
  journalNiveauEcran       = "INFO",
  battementSecondes        = 60,
  erreursAvantReinit       = 5,
  redemarrageDelaiMin      = 3,
  redemarrageDelaiMax      = 60,
  arretParTerminate        = true,
}

local cfg = {}

local function chargerConfiguration()
  for k, v in pairs(DEFAUTS) do cfg[k] = v end

  if not fs.exists(CHEMIN_CONFIG) then
    avert(ETAPES.CHARGEMENT_CONFIG,
      "config_command.lua absent : valeurs par defaut utilisees, AUCUN code transpondeur defini")
    return true
  end

  local charge, err = loadfile(CHEMIN_CONFIG)
  if not charge then
    erreur(ETAPES.CHARGEMENT_CONFIG, "fichier illisible : " .. tostring(err))
    return false
  end
  local ok, table_ = pcall(charge)
  if not ok or type(table_) ~= "table" then
    erreur(ETAPES.CHARGEMENT_CONFIG, "la configuration ne retourne pas une table : " .. tostring(table_))
    return false
  end
  for k, v in pairs(table_) do cfg[k] = v end
  info(ETAPES.CHARGEMENT_CONFIG, "configuration chargee depuis " .. CHEMIN_CONFIG)
  return true
end

local function validerConfiguration()
  local anomalies = {}

  if type(cfg.identifiant) ~= "string" or cfg.identifiant == "" then
    anomalies[#anomalies + 1] = "identifiant manquant"
  end
  if type(cfg.codeAllie) ~= "string" or cfg.codeAllie == "" then
    anomalies[#anomalies + 1] =
      "codeAllie non defini : AUCUN vehicule ne pourra etre reconnu comme allie"
  end
  if type(cfg.codeGeneral) ~= "string" or cfg.codeGeneral == "" then
    anomalies[#anomalies + 1] =
      "codeGeneral non defini : tout vehicule sans code allie sera classe INCONNU"
  end
  if cfg.codeAllie and cfg.codeGeneral and cfg.codeAllie == cfg.codeGeneral then
    anomalies[#anomalies + 1] =
      "codeAllie et codeGeneral identiques : la distinction ami / conditionnel est perdue"
  end
  if type(cfg.positionRadar) ~= "table"
     or not (nombreValide(cfg.positionRadar.x) and nombreValide(cfg.positionRadar.y)
             and nombreValide(cfg.positionRadar.z)) then
    anomalies[#anomalies + 1] = "positionRadar invalide : les distances seront fausses"
    cfg.positionRadar = { x = 0, y = 64, z = 0 }
  end
  if not nombreValide(cfg.porteeRadar) or cfg.porteeRadar <= 0 then
    anomalies[#anomalies + 1] =
      "porteeRadar inconnue : le garde-fou d'enveloppe fiable est desactive, " ..
      "une cible en fuite pourra etre declaree detruite"
    cfg.porteeRadar = 0
  end
  if cfg.formatUniqueFire == true then
    anomalies[#anomalies + 1] =
      "formatUniqueFire actif : un scramble de verification sera transmis avec le verbe " ..
      "'Fire'. Un allie sous scramble Romeo/guerre peut etre engage par Fire Control."
  end
  if nombreValide(cfg.ratioEnveloppeFiable) and cfg.ratioEnveloppeFiable >= 1.0 then
    anomalies[#anomalies + 1] =
      "ratioEnveloppeFiable >= 1.0 : toute sortie de portee sera comptee comme une destruction"
  end
  if not nombreValide(cfg.tentativesMax) or cfg.tentativesMax < 1 then
    cfg.tentativesMax = 3
  end
  if nombreValide(cfg.delaiEvaluationSecondes) and nombreValide(cfg.fenetreCrashSecondes)
     and cfg.delaiEvaluationSecondes < cfg.fenetreCrashSecondes then
    anomalies[#anomalies + 1] =
      "delaiEvaluationSecondes inferieur a fenetreCrashSecondes : le declencheur B " ..
      "n'aura jamais le temps de se prononcer"
  end

  for _, a in ipairs(anomalies) do avert(ETAPES.VALIDATION_CONFIG, a) end
  if #anomalies == 0 then
    info(ETAPES.VALIDATION_CONFIG, "configuration validee, aucune anomalie")
  else
    avert(ETAPES.VALIDATION_CONFIG, string.format("%d anomalie(s) relevee(s)", #anomalies))
  end
  return true
end

--------------------------------------------------------------------------------
-- 6. ETAT DU SYSTEME
--------------------------------------------------------------------------------

local etat = {
  demarrageA        = 0,
  mode              = noyau.MODES.PAIX,
  alerteMax         = false,
  alerteMaxDepuis   = 0,

  zones             = {},   -- liste de zones (persistee dans zones.dat)
  pistes            = {},   -- [id] = piste
  transpondeurs     = {},   -- [cle] = { code, x, y, z, recuA, nom }
  roster            = {},   -- [nomJoueur] = { faction, hostilite }
  plateformes       = {},   -- inventaire recu de Fire Control
  inventaireRecuA   = -1e9,

  alertes           = {},   -- alertes controleur non acquittees
  cote              = nil,
  radar             = nil,
  radarNom          = nil,
  radarMethode      = nil,
  positionsRelatives= nil,

  compteurs = {
    balayages = 0, detections = 0, decisions = 0,
    ordresFeu = 0, ordresScramble = 0,
    killsConfirmes = 0, pistesPerdues = 0, reemissions = 0, alertes = 0,
  },
  echecsConsecutifs = 0,
  derniereDecision  = nil,
  arret             = false,
}

--------------------------------------------------------------------------------
-- 7. PERSISTANCE (zones et etat operationnel)
--------------------------------------------------------------------------------

local function ecrireTable(chemin, donnees, etape)
  return (proteger(etape, function()
    local f = fs.open(chemin, "w")
    if not f then error("impossible d'ouvrir " .. chemin .. " en ecriture", 0) end
    f.write(textutils.serialise(donnees))
    f.close()
  end))
end

local function lireTable(chemin, etape)
  if not fs.exists(chemin) then return nil end
  local ok, contenu = proteger(etape, function()
    local f = fs.open(chemin, "r")
    if not f then error("impossible d'ouvrir " .. chemin, 0) end
    local texte = f.readAll()
    f.close()
    return texte
  end)
  if not ok or not contenu then return nil end
  local ok, donnees = pcall(textutils.unserialise, contenu)
  if not ok or type(donnees) ~= "table" then
    erreur(etape, "contenu illisible dans " .. chemin)
    return nil
  end
  return donnees
end

local function enregistrerZones()
  if ecrireTable(CHEMIN_ZONES, etat.zones, ETAPES.ENREGISTREMENT_ZONES) then
    info(ETAPES.ENREGISTREMENT_ZONES, string.format("%d zone(s) enregistree(s)", #etat.zones))
    return true
  end
  return false
end

local function chargerZones()
  local donnees = lireTable(CHEMIN_ZONES, ETAPES.CHARGEMENT_ZONES)
  if not donnees then
    info(ETAPES.CHARGEMENT_ZONES, "aucun fichier de zones : le systeme demarre sans juridiction")
    etat.zones = {}
    return
  end
  etat.zones = {}
  for _, zone in ipairs(donnees) do
    local valide, motif = noyau.validerZone(zone)
    if valide then
      -- Les coins d'un rectangle sont reordonnes pour former un quadrilatere
      -- non croise : sans cela, des coins saisis en Z formeraient un sablier.
      if zone.forme == "rectangle" then zone.points = noyau.ordonnerCoins(zone.points) end
      etat.zones[#etat.zones + 1] = zone
    else
      avert(ETAPES.CHARGEMENT_ZONES,
        string.format("zone '%s' rejetee : %s", tostring(zone.nom), motif))
    end
  end
  info(ETAPES.CHARGEMENT_ZONES, string.format("%d zone(s) active(s)", #etat.zones))
  for _, z in ipairs(etat.zones) do
    debug_(ETAPES.CHARGEMENT_ZONES, string.format("zone %s classe %s forme %s",
      z.nom, z.classe, z.forme))
  end
end

local function enregistrerEtat()
  return ecrireTable(CHEMIN_ETAT, {
    mode                 = etat.mode,
    alerteMax            = etat.alerteMax,
    codeGeneral          = cfg.codeGeneral,
    codeGeneralPrecedent = cfg.codeGeneralPrecedent,
    rotationA            = cfg.rotationA,
  }, ETAPES.ENREGISTREMENT_ETAT)
end

local function chargerEtat()
  local donnees = lireTable(CHEMIN_ETAT, ETAPES.CHARGEMENT_ETAT)
  if not donnees then
    info(ETAPES.CHARGEMENT_ETAT, "aucun etat persistant : demarrage en temps de PAIX")
    return
  end
  if donnees.mode == noyau.MODES.GUERRE then etat.mode = noyau.MODES.GUERRE end
  etat.alerteMax = donnees.alerteMax == true
  if type(donnees.codeGeneral) == "string" and donnees.codeGeneral ~= "" then
    cfg.codeGeneral = donnees.codeGeneral
    cfg.codeGeneralPrecedent = donnees.codeGeneralPrecedent
    cfg.rotationA = donnees.rotationA
  end
  info(ETAPES.CHARGEMENT_ETAT, string.format(
    "etat restaure : mode %s, alerte maximale %s", etat.mode, tostring(etat.alerteMax)))
end

--------------------------------------------------------------------------------
-- 8. ALERTE CONTROLEUR HUMAIN
--------------------------------------------------------------------------------

local function alerterControleur(motif, detail)
  etat.compteurs.alertes = etat.compteurs.alertes + 1
  etat.alertes[#etat.alertes + 1] = {
    t = os.clock(), horodatage = horodatage(), motif = motif, detail = detail or "",
  }
  while #etat.alertes > 20 do table.remove(etat.alertes, 1) end
  critique(ETAPES.ALERTE_CONTROLEUR, string.format("ALERTE CONTROLEUR - %s : %s",
    motif, detail or ""))
  if type(cfg.sortieRedstoneAlerte) == "string" then
    proteger(ETAPES.ALERTE_CONTROLEUR, redstone.setOutput, cfg.sortieRedstoneAlerte, true)
  end
end

--------------------------------------------------------------------------------
-- 9. RESEAU
--------------------------------------------------------------------------------

local function detecterModem()
  if type(cfg.coteModem) == "string" then
    if peripheral.isPresent(cfg.coteModem) and peripheral.getType(cfg.coteModem) == "modem" then
      return cfg.coteModem
    end
    avert(ETAPES.DETECTION_MODEM, "coteModem force introuvable, bascule en detection automatique")
  end
  local repli
  for _, nom in ipairs(peripheral.getNames()) do
    if peripheral.getType(nom) == "modem" then
      local modem = peripheral.wrap(nom)
      local ok, sansFil = pcall(modem.isWireless)
      if ok and sansFil then return nom end
      repli = repli or nom
    end
  end
  return repli
end

local function ouvrirReseau()
  local trouve, cote = proteger(ETAPES.DETECTION_MODEM, detecterModem)
  if not (trouve and cote) then
    erreur(ETAPES.DETECTION_MODEM, "aucun modem detecte : le poste est sourd et muet")
    return false
  end
  etat.cote = cote
  info(ETAPES.DETECTION_MODEM, "modem detecte sur '" .. cote .. "'")

  local ok = proteger(ETAPES.OUVERTURE_REDNET, rednet.open, cote)
  if not ok and not rednet.isOpen(cote) then
    erreur(ETAPES.OUVERTURE_REDNET, "rednet n'a pas pu etre ouvert")
    return false
  end
  info(ETAPES.OUVERTURE_REDNET, "rednet ouvert")
  return true
end

--------------------------------------------------------------------------------
-- 10. ADAPTATEUR RADAR (Create Radars)
--
--     Les addons radar n'exposent pas tous la meme API. Plutot que de figer un
--     nom de methode, on essaie les noms connus dans l'ordre et on journalise
--     celui qui repond. Si votre version expose une methode differente,
--     ajoutez-la a METHODES_RADAR : c'est le seul endroit a modifier.
--------------------------------------------------------------------------------

local METHODES_RADAR = {
  { nom = "getEntities",     nature = noyau.NATURES.ENTITE },
  { nom = "getContraptions", nature = noyau.NATURES.VEHICULE },
  { nom = "getPlayers",      nature = noyau.NATURES.JOUEUR },
  { nom = "getTargets",      nature = noyau.NATURES.ENTITE },
  { nom = "getRadarTargets", nature = noyau.NATURES.ENTITE },
  { nom = "scan",            nature = noyau.NATURES.ENTITE },
}

local function detecterRadar()
  local nom = cfg.peripheriqueRadar
  if nom and peripheral.isPresent(nom) then
    etat.radar, etat.radarNom = peripheral.wrap(nom), nom
  else
    if nom then avert(ETAPES.DETECTION_RADAR, "peripheriqueRadar force introuvable, detection automatique") end
    for _, candidat in ipairs(peripheral.getNames()) do
      local typ = peripheral.getType(candidat)
      if type(typ) == "string" and typ:lower():find("radar", 1, true) then
        etat.radar, etat.radarNom = peripheral.wrap(candidat), candidat
        break
      end
    end
  end

  if not etat.radar then
    erreur(ETAPES.DETECTION_RADAR, "aucun peripherique radar detecte : aucune detection possible")
    return false
  end

  etat.methodesActives = {}
  for _, methode in ipairs(METHODES_RADAR) do
    if type(etat.radar[methode.nom]) == "function" then
      etat.methodesActives[#etat.methodesActives + 1] = methode
    end
  end

  if #etat.methodesActives == 0 then
    erreur(ETAPES.DETECTION_RADAR, string.format(
      "radar '%s' detecte mais aucune methode connue (essayees : getEntities, getContraptions, " ..
      "getPlayers, getTargets, getRadarTargets, scan). Completez METHODES_RADAR.", etat.radarNom))
    return false
  end

  local noms = {}
  for _, m in ipairs(etat.methodesActives) do noms[#noms + 1] = m.nom end
  info(ETAPES.DETECTION_RADAR, string.format("radar '%s' detecte, methodes : %s",
    etat.radarNom, table.concat(noms, ", ")))
  return true
end

-- Extrait une position d'un echo, quel que soit le format rendu par l'addon.
local function positionEcho(echo)
  if nombreValide(echo.x) and nombreValide(echo.y) and nombreValide(echo.z) then
    return echo.x, echo.y, echo.z
  end
  local p = echo.position or echo.pos or echo.coords
  if type(p) == "table" then
    local x = p.x or p[1]
    local y = p.y or p[2]
    local z = p.z or p[3]
    if nombreValide(x) and nombreValide(y) and nombreValide(z) then return x, y, z end
  end
  return nil
end

--[[
  Determine une fois pour toutes si le radar rend des positions relatives.
  Heuristique : si les echos sont tous a portee de l'ORIGINE du monde alors que
  le radar en est tres eloigne, ce sont forcement des positions relatives.
  Le resultat est journalise explicitement, et peut etre force en configuration.
]]
local function deciderReferentiel(echos)
  if type(cfg.positionsRelatives) == "boolean" then
    etat.positionsRelatives = cfg.positionsRelatives
    info(ETAPES.NORMALISATION_ECHOS, "referentiel force par configuration : " ..
      (etat.positionsRelatives and "RELATIF" or "ABSOLU"))
    return
  end
  local r = cfg.positionRadar
  local distanceRadarOrigine = math.sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
  local portee = (nombreValide(cfg.porteeRadar) and cfg.porteeRadar > 0) and cfg.porteeRadar or 512

  local prochesOrigine, prochesRadar = 0, 0
  for _, echo in ipairs(echos) do
    local x, y, z = positionEcho(echo)
    if x then
      if math.sqrt(x * x + y * y + z * z) <= portee * 1.5 then prochesOrigine = prochesOrigine + 1 end
      local dx, dy, dz = x - r.x, y - r.y, z - r.z
      if math.sqrt(dx * dx + dy * dy + dz * dz) <= portee * 1.5 then prochesRadar = prochesRadar + 1 end
    end
  end

  if distanceRadarOrigine <= portee * 1.5 then
    -- Radar proche de l'origine : les deux referentiels se confondent, on ne
    -- peut pas trancher. On prend l'absolu et on le dit.
    etat.positionsRelatives = false
    avert(ETAPES.NORMALISATION_ECHOS,
      "radar trop proche de l'origine du monde pour distinguer relatif et absolu : " ..
      "referentiel ABSOLU suppose. Renseignez positionsRelatives en configuration.")
    return
  end

  etat.positionsRelatives = (prochesOrigine > prochesRadar)
  info(ETAPES.NORMALISATION_ECHOS, string.format(
    "referentiel radar deduit : %s (%d echo(s) proche(s) de l'origine, %d du radar)",
    etat.positionsRelatives and "RELATIF" or "ABSOLU", prochesOrigine, prochesRadar))
end

--------------------------------------------------------------------------------
-- 11. BALAYAGE ET MISE A JOUR DES PISTES  [ETAPE 1 : DETECTION]
--------------------------------------------------------------------------------

local compteurAnonyme = 0

local function identifiantEcho(echo)
  local id = echo.id or echo.uuid or echo.uid or echo.entityId
  if id ~= nil then return "ID:" .. tostring(id) end
  local nom = echo.name or echo.nom or echo.label or echo.displayName
  if type(nom) == "string" and nom ~= "" then return "NOM:" .. nom end
  return nil
end

local function natureEcho(echo, natureParDefaut)
  local typ = tostring(echo.type or echo.entityType or echo.kind or ""):lower()
  if typ:find("player", 1, true) then return noyau.NATURES.JOUEUR end
  if echo.isPlayer == true then return noyau.NATURES.JOUEUR end
  if echo.isContraption == true or typ:find("contraption", 1, true)
     or typ:find("ship", 1, true) or typ:find("vehicle", 1, true) then
    return noyau.NATURES.VEHICULE
  end
  return natureParDefaut
end

local function collecterEchos()
  local bruts = {}
  for _, methode in ipairs(etat.methodesActives or {}) do
    local ok, resultat = proteger(ETAPES.BALAYAGE_RADAR, function()
      return etat.radar[methode.nom](etat.radar)
    end)
    if ok and type(resultat) == "table" then
      for _, echo in ipairs(resultat) do
        if type(echo) == "table" then
          bruts[#bruts + 1] = { echo = echo, nature = methode.nature }
        end
      end
    end
  end
  return bruts
end

-- Retrouve la piste correspondant a un echo sans identifiant stable :
-- rapprochement par proximite du dernier point connu.
local function apparierParProximite(x, y, z, nature, maintenant)
  local meilleur, meilleureDistance = nil, cfg.toleranceAppariement or 24
  for id, piste in pairs(etat.pistes) do
    if piste.nature == nature and (maintenant - piste.vuA) <= (cfg.intervalleBalayage or 1) * 3 then
      local d = noyau.distance3D(piste, { x = x, y = y, z = z })
      if d <= meilleureDistance then meilleur, meilleureDistance = id, d end
    end
  end
  return meilleur
end

local function mettreAJourPistes(maintenant)
  local bruts = collecterEchos()
  etat.compteurs.balayages = etat.compteurs.balayages + 1

  if etat.positionsRelatives == nil then
    local echos = {}
    for _, b in ipairs(bruts) do echos[#echos + 1] = b.echo end
    deciderReferentiel(echos)
  end

  local vus = {}
  local r = cfg.positionRadar

  for _, brut in ipairs(bruts) do
    local echo = brut.echo
    local x, y, z = positionEcho(echo)
    if not x then
      debug_(ETAPES.NORMALISATION_ECHOS, "echo sans position exploitable, ignore")
    else
      if etat.positionsRelatives then x, y, z = r.x + x, r.y + y, r.z + z end
      local nature = natureEcho(echo, brut.nature)

      -- Filtrage du bruit biologique : sans cela le systeme engage les vaches.
      if nature == noyau.NATURES.ENTITE and cfg.traiterEntitesNeutres ~= true then
        debug_(ETAPES.NORMALISATION_ECHOS, string.format(
          "entite neutre ignoree en %.0f/%.0f/%.0f (traiterEntitesNeutres = false)", x, y, z))
      else
        local id = identifiantEcho(echo)
        if not id then
          id = apparierParProximite(x, y, z, nature, maintenant)
          if not id then
            compteurAnonyme = compteurAnonyme + 1
            id = string.format("ANON-%d", compteurAnonyme)
          end
        end

        local piste = etat.pistes[id]
        if not piste then
          piste = {
            id = id,
            nom = echo.name or echo.nom or echo.label or echo.displayName or id,
            nature = nature,
            echantillons = {},
            premiereDetection = maintenant,
            engagement = nil,
          }
          etat.pistes[id] = piste
          etat.compteurs.detections = etat.compteurs.detections + 1
          info(ETAPES.DETECTION, string.format(
            "nouveau contact %s (%s) en X=%.0f Y=%.0f Z=%.0f",
            piste.nom, nature, x, y, z))
        end

        -- Vitesses, calculees par Command a partir de sa propre piste : ne
        -- dependre d'aucun champ optionnel de l'addon rend la mesure fiable.
        local precedent = piste.echantillons[#piste.echantillons]
        if precedent and maintenant > precedent.t then
          local dt = maintenant - precedent.t
          piste.vitesseHorizontale = noyau.distance2D(x, z, precedent.x, precedent.z) / dt
          piste.vitesseVerticale   = (y - precedent.y) / dt
        end

        piste.x, piste.y, piste.z = x, y, z
        piste.vuA = maintenant
        piste.present = true
        piste.distanceRadar = noyau.distance3D(piste, r)
        piste.echantillons[#piste.echantillons + 1] = { t = maintenant, x = x, y = y, z = z }
        while #piste.echantillons > (cfg.historiquePiste or 20) do
          table.remove(piste.echantillons, 1)
        end
        vus[id] = true
      end
    end
  end

  -- Pistes non revues lors de ce balayage.
  for id, piste in pairs(etat.pistes) do
    if not vus[id] then
      if piste.present then
        piste.present = false
        debug_(ETAPES.MISE_A_JOUR_PISTES, string.format(
          "contact %s perdu du radar a %.0fm du radar", piste.nom, piste.distanceRadar or -1))
      end
      -- Une piste sous evaluation de destruction n'est jamais oubliee avant
      -- d'avoir ete conclue : c'est la seule facon de trancher entre un crash
      -- et une fuite.
      local sousEvaluation = piste.engagement and piste.engagement.actif
      if not sousEvaluation and (maintenant - (piste.vuA or 0)) > (cfg.oubliPisteSecondes or 30) then
        etat.pistes[id] = nil
        debug_(ETAPES.MISE_A_JOUR_PISTES, "piste " .. piste.nom .. " oubliee")
      end
    end
  end
end

--------------------------------------------------------------------------------
-- 12. TRANSPONDEURS
--------------------------------------------------------------------------------

-- Associe a une piste le transpondeur le plus vraisemblable : meme nom declare,
-- sinon position la plus proche dans la tolerance d'appariement.
local function transpondeurPourPiste(piste, maintenant)
  local meilleur, meilleureDistance = nil, cfg.toleranceAppariement or 24

  for _, t in ipairs(etat.transpondeurs) do
    if (maintenant - t.recuA) <= (cfg.validiteTranspondeur or 15) then
      if type(t.nom) == "string" and t.nom ~= "" and t.nom == piste.nom then
        return t, "appariement par nom declare"
      end
      if nombreValide(t.x) and nombreValide(t.y) and nombreValide(t.z) then
        local d = noyau.distance3D(t, piste)
        if d <= meilleureDistance then meilleur, meilleureDistance = t, d end
      end
    end
  end

  if meilleur then
    return meilleur, string.format("appariement par position (%.0fm)", meilleureDistance)
  end
  return nil, "aucun transpondeur a portee d'appariement"
end

--------------------------------------------------------------------------------
-- 13. EMISSION VERS FIRE CONTROL  [ETAPES 4 ET 5 : DESIGNATION ET EMISSION]
--------------------------------------------------------------------------------

local function envoyerOrdre(chaine, details)
  local envoye
  if nombreValide(cfg.idFireControl) then
    envoye = proteger(ETAPES.EMISSION_ORDRE, rednet.send,
      cfg.idFireControl, chaine, cfg.protocoleFireControl)
  else
    envoye = proteger(ETAPES.EMISSION_ORDRE, rednet.broadcast,
      chaine, cfg.protocoleFireControl)
  end
  if not envoye then
    etat.echecsConsecutifs = etat.echecsConsecutifs + 1
    return false
  end
  etat.echecsConsecutifs = 0

  if cfg.envoyerDetails and type(details) == "table" then
    proteger(ETAPES.EMISSION_ORDRE, rednet.broadcast, details, cfg.protocoleFireControl)
  end
  return true
end

--[[
  Designe la ou les plateformes et emet les ordres correspondants.
  Retourne la liste des ordres reellement emis.
]]
local function engager(piste, verdict, verdictNom, maintenant)
  -- L'inventaire des plateformes vient de Fire Control. S'il est perime, on ne
  -- designe pas au hasard : on alerte.
  if #etat.plateformes == 0 then
    alerterControleur("aucune plateforme declaree",
      string.format("cible %s en %s, verdict %s, mais Fire Control n'a declare aucune plateforme",
        piste.nom, piste.classeZone or "?", verdictNom))
    return {}
  end
  local ageInventaire = maintenant - etat.inventaireRecuA
  if ageInventaire > (cfg.validiteInventaire or 60) then
    alerterControleur("inventaire Fire Control perime",
      string.format("dernier inventaire recu il y a %.0fs (limite %.0fs) : les compteurs de tirs " ..
        "et les positions de plateformes ne sont plus fiables", ageInventaire, cfg.validiteInventaire or 60))
  end

  local candidats, rejetes = noyau.designer(etat.plateformes, piste, cfg)

  for _, r in ipairs(rejetes) do
    debug_(ETAPES.DESIGNATION_TIREUR, string.format("plateforme %s ecartee : %s", r.nom, r.motif))
  end

  if #candidats == 0 then
    alerterControleur("aucune plateforme designable",
      string.format("cible %s (%s) en zone %s, verdict %s : %d plateforme(s) ecartee(s)",
        piste.nom, piste.categorie, piste.classeZone or "?", verdictNom, #rejetes))
    return {}
  end

  local ordres = noyau.planifier(verdict, candidats)
  local emis = {}

  for _, ordre in ipairs(ordres) do
    local c = ordre.candidat
    info(ETAPES.DESIGNATION_TIREUR, string.format(
      "cible %s -> plateforme %s designee pour %s (score %.3f = charge %.2f x %.1f + distance %.2f x %.1f, " ..
      "%d tir(s) deja effectue(s), %.0fm)",
      piste.nom, c.nom, ordre.role, c.score, c.chargeNormalisee, cfg.poidsTirs or 1,
      c.distanceNormalisee, cfg.poidsDistance or 1, c.tirs, c.distance))

    local chaine = noyau.formaterOrdre(ordre.role, c.nom, piste.categorie, cfg)
    local details = {
      protocole = "FRENCHNET_COMMAND", version = PROTOCOLE_VERSION,
      emetteur = cfg.identifiant, ordre = chaine, role = ordre.role,
      plateforme = c.nom, categorie = piste.categorie, verdict = verdictNom,
      cible = { id = piste.id, nom = piste.nom, x = piste.x, y = piste.y, z = piste.z },
      zone = piste.classeZone, mode = etat.mode, alerteMax = etat.alerteMax,
    }

    if envoyerOrdre(chaine, details) then
      info(ETAPES.EMISSION_ORDRE, string.format("ordre transmis a Fire Control : \"%s\"", chaine))
      if ordre.role == "FIRE" then
        etat.compteurs.ordresFeu = etat.compteurs.ordresFeu + 1
      else
        etat.compteurs.ordresScramble = etat.compteurs.ordresScramble + 1
      end
      emis[#emis + 1] = { role = ordre.role, plateforme = c.nom, chaine = chaine }
    else
      erreur(ETAPES.EMISSION_ORDRE, string.format(
        "echec de transmission de l'ordre \"%s\" vers Fire Control", chaine))
      alerterControleur("transmission Fire Control impossible", chaine)
    end
  end

  return emis
end

--------------------------------------------------------------------------------
-- 14. DECISION  [ETAPES 2 ET 3 : CLASSIFICATION ET ESCALADE]
--------------------------------------------------------------------------------

local function decider(piste, maintenant)
  ------------------------------------------------------------ resolution zone
  local classe, zone, chevauchees = noyau.zonePourPoint(etat.zones, piste.x, piste.y, piste.z)
  piste.classeZone, piste.zone = classe, zone

  if #chevauchees > 1 then
    local noms = {}
    for _, z in ipairs(chevauchees) do
      noms[#noms + 1] = string.format("%s(%s)", z.nom, z.classe)
    end
    debug_(ETAPES.RESOLUTION_ZONE, string.format(
      "cible %s dans %d zones : %s -> la plus stricte l'emporte : %s",
      piste.nom, #chevauchees, table.concat(noms, ", "), classe))
  end

  if not classe then
    -- Zone non classifiee : neutre ou hors juridiction. Le systeme ne fait
    -- rien du tout, ni surveillance ni action.
    if piste.verdictNom ~= "HORS_JURIDICTION" then
      debug_(ETAPES.RESOLUTION_ZONE, string.format(
        "cible %s hors de toute zone classifiee : aucune action", piste.nom))
    end
    if not (etat.alerteMax and cfg.alerteMaxCouvreHorsZone == true) then
      piste.verdictNom, piste.verdict = "HORS_JURIDICTION", noyau.VERDICTS.HORS_JURIDICTION
      piste.categorie, piste.iff = nil, nil
      return
    end
  end

  ---------------------------------------------------------- classification
  local categorie, motifCategorie = noyau.categoriser(piste, cfg, zone)
  local transpondeur, motifAppariement = transpondeurPourPiste(piste, maintenant)
  local codes = {
    codeAllie = cfg.codeAllie,
    codeGeneral = cfg.codeGeneral,
    codeGeneralPrecedent = cfg.codeGeneralPrecedent,
    rotationA = cfg.rotationA or 0,
  }
  local iff, motifIff = noyau.statutIff(transpondeur, codes, maintenant, cfg)

  local faction = etat.roster[piste.nom]
  local mentionFaction = faction
    and string.format(", faction %s (Open Parties and Claims)", tostring(faction.faction))
    or ""

  local changement = (piste.categorie ~= categorie) or (piste.iff ~= iff)
  piste.categorie, piste.iff = categorie, iff

  if changement then
    info(ETAPES.CLASSIFICATION, string.format(
      "cible %s classee %s [%s] ; IFF %s [%s ; %s]%s",
      piste.nom, categorie, motifCategorie, iff, motifIff, motifAppariement, mentionFaction))
  end

  ------------------------------------------------------------ escalade
  local verdictNom, verdict, motif = noyau.verdict(classe, etat.mode, iff, etat.alerteMax, cfg)

  local nouveau = (piste.verdictNom ~= verdictNom)
  piste.verdictNom, piste.verdict = verdictNom, verdict

  if nouveau then
    etat.compteurs.decisions = etat.compteurs.decisions + 1
    etat.derniereDecision = {
      t = maintenant, cible = piste.nom, verdict = verdictNom,
      categorie = categorie, zone = classe,
    }
    local niveau = (verdict.palier >= 3) and avert or info
    niveau(ETAPES.DECISION_ESCALADE, string.format(
      "cible %s (%s) : palier %d - %s | %s",
      piste.nom, categorie, verdict.palier, verdict.libelle, motif))
  end

  ------------------------------------------------------------ engagement
  if verdict.palier < 2 then
    -- Palier 0 (libre passage) ou 1 (observation passive) : rien a transmettre.
    if piste.engagement and piste.engagement.actif then
      avert(ETAPES.DECISION_ESCALADE, string.format(
        "cible %s : desescalade au palier %d, evaluation de destruction interrompue",
        piste.nom, verdict.palier))
    end
    piste.engagement = nil
    return
  end

  if piste.engagement and piste.engagement.actif then
    -- Une sequence est deja en cours sur cette piste : la reemission est geree
    -- par l'evaluation de destruction, pas ici.
    return
  end

  if piste.engagement and piste.engagement.termine then
    --[[
      Sequence deja conclue. On ne relance jamais en boucle - SAUF si le
      contexte s'est durci depuis : une bascule en temps de guerre, une alerte
      maximale ou une entree en zone plus stricte peuvent faire passer une
      cible du palier scramble au palier destruction. Sans cette reprise, une
      cible simplement "verifiee" en temps de paix traverserait toute une
      guerre sans jamais etre reengagee.
      Une destruction confirmee, elle, ne se rejoue jamais.
    ]]
    local ancien = noyau.VERDICTS[piste.engagement.verdictNom]
    local ancienPalier = ancien and ancien.palier or 0
    if piste.engagement.resultat == "DETRUITE" or verdict.palier <= ancienPalier then
      return
    end
    avert(ETAPES.DECISION_ESCALADE, string.format(
      "cible %s : escalade du palier %d au palier %d, nouvel engagement autorise",
      piste.nom, ancienPalier, verdict.palier))
    piste.engagement = nil
  end

  local emis = engager(piste, verdict, verdictNom, maintenant)
  if #emis == 0 then return end

  if verdict.feu then
    -- Seul un ordre de DESTRUCTION ouvre une evaluation de destruction. Un
    -- scramble de verification n'a rien a confirmer : il n'engage pas.
    local vitesseRef = piste.vitesseHorizontale or 0
    for i = #piste.echantillons, 2, -1 do
      local a, b = piste.echantillons[i - 1], piste.echantillons[i]
      local dt = b.t - a.t
      if dt > 0 then
        local v = noyau.distance2D(b.x, b.z, a.x, a.z) / dt
        if v > vitesseRef then vitesseRef = v end
      end
    end
    piste.engagement = {
      actif = true, termine = false, tentatives = 1, verdictNom = verdictNom,
      ordreA = maintenant, vitesseRef = vitesseRef, ordres = emis,
    }
    info(ETAPES.EVALUATION_KILL, string.format(
      "evaluation de destruction ouverte sur %s (tentative 1/%d, vitesse de reference %.1f b/s)",
      piste.nom, cfg.tentativesMax, vitesseRef))
  else
    -- Scramble seul : pas de confirmation attendue, sequence close.
    piste.engagement = {
      actif = false, termine = true, tentatives = 0, verdictNom = verdictNom, ordres = emis,
    }
  end
end

--------------------------------------------------------------------------------
-- 15. CONFIRMATION DE DESTRUCTION  [ETAPE 5]
--------------------------------------------------------------------------------

local function evaluerEngagements(maintenant)
  for id, piste in pairs(etat.pistes) do
    local e = piste.engagement
    if e and e.actif then
      local resultat, detail = noyau.evaluerDestruction(piste, e, cfg, maintenant)

      if resultat == noyau.RESULTATS_KILL.CONFIRME then
        e.actif, e.termine, e.resultat = false, true, "DETRUITE"
        etat.compteurs.killsConfirmes = etat.compteurs.killsConfirmes + 1
        info(ETAPES.CONFIRMATION_KILL, string.format(
          "DESTRUCTION CONFIRMEE sur %s apres %d tentative(s) | %s",
          piste.nom, e.tentatives, detail))
        -- La piste peut maintenant s'eteindre normalement.

      elseif resultat == noyau.RESULTATS_KILL.PERDU then
        e.actif, e.termine, e.resultat = false, true, "PERDUE"
        etat.compteurs.pistesPerdues = etat.compteurs.pistesPerdues + 1
        avert(ETAPES.CONFIRMATION_KILL, string.format(
          "cible %s PERDUE, destruction NON confirmee | %s", piste.nom, detail))
        alerterControleur("destruction non confirmee, cible perdue",
          string.format("%s (%s) - %s", piste.nom, piste.categorie or "?", detail))

      elseif resultat == noyau.RESULTATS_KILL.AUCUN_SIGNAL then
        if e.tentatives >= (cfg.tentativesMax or 3) then
          e.actif, e.termine, e.resultat = false, true, "ECHEC"
          avert(ETAPES.CONFIRMATION_KILL, string.format(
            "cible %s toujours active apres %d tentative(s) : sequence abandonnee",
            piste.nom, e.tentatives))
          alerterControleur("limite de tentatives atteinte",
            string.format("%s (%s) en zone %s : %d ordres de tir emis, aucune destruction " ..
              "confirmee. Intervention humaine requise.",
              piste.nom, piste.categorie or "?", piste.classeZone or "?", e.tentatives))
        else
          etat.compteurs.reemissions = etat.compteurs.reemissions + 1
          avert(ETAPES.REEMISSION_ORDRE, string.format(
            "cible %s : %s -> reemission d'un ordre de tir (tentative %d/%d)",
            piste.nom, detail, e.tentatives + 1, cfg.tentativesMax or 3))
          local emis = engager(piste, piste.verdict, piste.verdictNom, maintenant)
          if #emis > 0 then
            e.tentatives = e.tentatives + 1
            e.ordreA = maintenant
            e.ordres = emis
          else
            -- Impossible de reemettre (plus aucune plateforme) : engager() a
            -- deja alerte le controleur. On clot pour ne pas boucler.
            e.actif, e.termine, e.resultat = false, true, "IMPOSSIBLE"
          end
        end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- 16. ACTIONS DE CONTROLE (appelees par l'interface)
--------------------------------------------------------------------------------

local actions = {}

function actions.basculerMode()
  etat.mode = (etat.mode == noyau.MODES.GUERRE) and noyau.MODES.PAIX or noyau.MODES.GUERRE
  avert(ETAPES.BASCULE_MODE, string.format(
    "theatre bascule en temps de %s par le controleur", etat.mode))
  -- Toute decision precedente doit etre reprise sous le nouveau regime.
  for _, piste in pairs(etat.pistes) do piste.verdictNom = nil end
  enregistrerEtat()
  return etat.mode
end

function actions.basculerAlerteMax()
  etat.alerteMax = not etat.alerteMax
  if etat.alerteMax then
    etat.alerteMaxDepuis = os.clock()
    critique(ETAPES.ALERTE_MAXIMALE,
      "ALERTE MAXIMALE declenchee manuellement : regime ROMEO / GUERRE applique a " ..
      "toutes les zones classifiees, independamment de leur classe")
  else
    info(ETAPES.ALERTE_MAXIMALE, "alerte maximale levee par le controleur")
  end
  for _, piste in pairs(etat.pistes) do piste.verdictNom = nil end
  enregistrerEtat()
  return etat.alerteMax
end

function actions.acquitterAlertes()
  local n = #etat.alertes
  etat.alertes = {}
  if type(cfg.sortieRedstoneAlerte) == "string" then
    proteger(ETAPES.ALERTE_CONTROLEUR, redstone.setOutput, cfg.sortieRedstoneAlerte, false)
  end
  info(ETAPES.ALERTE_CONTROLEUR, string.format("%d alerte(s) acquittee(s) par le controleur", n))
  return n
end

function actions.ajouterZone(zone)
  local valide, motif = noyau.validerZone(zone)
  if not valide then
    avert(ETAPES.CONFIGURATION_ZONE, string.format(
      "creation de zone refusee (%s) : %s", tostring(zone and zone.nom), motif))
    return false, motif
  end
  if zone.forme == "rectangle" then zone.points = noyau.ordonnerCoins(zone.points) end
  for i, z in ipairs(etat.zones) do
    if z.nom == zone.nom then
      etat.zones[i] = zone
      info(ETAPES.CONFIGURATION_ZONE, string.format(
        "zone '%s' redefinie : classe %s, forme %s", zone.nom, zone.classe, zone.forme))
      enregistrerZones()
      for _, piste in pairs(etat.pistes) do piste.verdictNom = nil end
      return true
    end
  end
  etat.zones[#etat.zones + 1] = zone
  info(ETAPES.CONFIGURATION_ZONE, string.format(
    "zone '%s' creee : classe %s, forme %s", zone.nom, zone.classe, zone.forme))
  enregistrerZones()
  for _, piste in pairs(etat.pistes) do piste.verdictNom = nil end
  return true
end

function actions.supprimerZone(nom)
  for i, z in ipairs(etat.zones) do
    if z.nom == nom then
      table.remove(etat.zones, i)
      avert(ETAPES.CONFIGURATION_ZONE, string.format(
        "zone '%s' (classe %s) supprimee : le secteur redevient hors juridiction", nom, z.classe))
      enregistrerZones()
      for _, piste in pairs(etat.pistes) do piste.verdictNom = nil end
      return true
    end
  end
  return false, "zone introuvable"
end

function actions.changerCodeGeneral(nouveau)
  if type(nouveau) ~= "string" or nouveau == "" then return false, "code vide" end
  if nouveau == cfg.codeAllie then
    return false, "le code general ne peut pas etre egal au code allie"
  end
  cfg.codeGeneralPrecedent = cfg.codeGeneral
  cfg.codeGeneral = nouveau
  cfg.rotationA = os.clock()
  info(ETAPES.ROTATION_CODE, string.format(
    "code general tourne ; l'ancien code reste accepte %ds (periode de grace)",
    cfg.graceRotation or 300))
  enregistrerEtat()
  return true
end

actions.etat  = etat
actions.cfg   = cfg
actions.noyau = noyau
actions.journal = journal
actions.ETAPES = ETAPES

--------------------------------------------------------------------------------
-- 17. BOUCLES
--------------------------------------------------------------------------------

local function boucleRadar()
  while not etat.arret do
    local maintenant = os.clock()
    proteger(ETAPES.MISE_A_JOUR_PISTES, mettreAJourPistes, maintenant)
    for _, piste in pairs(etat.pistes) do
      if piste.present or (piste.engagement and piste.engagement.actif) then
        proteger(ETAPES.DECISION_ESCALADE, decider, piste, maintenant)
      end
    end
    proteger(ETAPES.EVALUATION_KILL, evaluerEngagements, maintenant)
    sleep(cfg.intervalleBalayage or 1)
  end
end

local function boucleReseau()
  while not etat.arret do
    local expediteur, message, protocole = rednet.receive(nil, 5)
    if expediteur then
      local maintenant = os.clock()

      if protocole == cfg.protocoleTranspondeur and type(message) == "table" then
        local code = message.code or message.transpondeur
        if type(code) == "string" then
          local cle = tostring(message.identifiant or message.nom or expediteur)
          local remplace
          for i, t in ipairs(etat.transpondeurs) do
            if t.cle == cle then remplace = i break end
          end
          local entree = {
            cle = cle, nom = message.nom or message.identifiant,
            code = code, recuA = maintenant, expediteur = expediteur,
            x = message.x, y = message.y, z = message.z,
          }
          if remplace then etat.transpondeurs[remplace] = entree
          else etat.transpondeurs[#etat.transpondeurs + 1] = entree end
          debug_(ETAPES.RECEPTION_TRANSPONDEUR, string.format(
            "code recu de %s (ordinateur %d)", cle, expediteur))
        end

      elseif protocole == cfg.protocoleFireControl and type(message) == "table"
             and message.plateformes then
        local liste = {}
        for _, p in ipairs(message.plateformes) do
          if type(p) == "table" then liste[#liste + 1] = p end
        end
        etat.plateformes = liste
        etat.inventaireRecuA = maintenant
        debug_(ETAPES.RECEPTION_INVENTAIRE, string.format(
          "inventaire Fire Control recu : %d plateforme(s)", #liste))

      elseif protocole == cfg.protocoleRoster and type(message) == "table"
             and message.roster then
        etat.roster = message.roster
        local n = 0
        for _ in pairs(etat.roster) do n = n + 1 end
        info(ETAPES.RECEPTION_ROSTER, string.format(
          "roster de factions recu du pont Open Parties and Claims : %d entree(s)", n))
      end

      -- Purge des transpondeurs perimes.
      for i = #etat.transpondeurs, 1, -1 do
        if (maintenant - etat.transpondeurs[i].recuA) > (cfg.validiteTranspondeur or 15) * 4 then
          table.remove(etat.transpondeurs, i)
        end
      end
    end
  end
end

local function boucleBattement()
  while not etat.arret do
    sleep(cfg.battementSecondes or 60)
    local pistes, engagees = 0, 0
    for _, p in pairs(etat.pistes) do
      pistes = pistes + 1
      if p.engagement and p.engagement.actif then engagees = engagees + 1 end
    end
    local c = etat.compteurs
    info("battement", string.format(
      "mode %s%s | %d piste(s), %d engagement(s) en cours | %d zone(s), %d plateforme(s) | " ..
      "feu %d, scramble %d, kills %d, perdues %d, reemissions %d, alertes %d",
      etat.mode, etat.alerteMax and " + ALERTE MAX" or "",
      pistes, engagees, #etat.zones, #etat.plateformes,
      c.ordresFeu, c.ordresScramble, c.killsConfirmes, c.pistesPerdues, c.reemissions, c.alertes))

    -- Extinction automatique de l'alerte maximale, si configuree.
    if etat.alerteMax and nombreValide(cfg.alerteMaxDureeSecondes) and cfg.alerteMaxDureeSecondes > 0 then
      if (os.clock() - etat.alerteMaxDepuis) >= cfg.alerteMaxDureeSecondes then
        info(ETAPES.ALERTE_MAXIMALE, "extinction automatique de l'alerte maximale (duree ecoulee)")
        actions.basculerAlerteMax()
      end
    end
  end
end

local function boucleTerminate()
  while true do
    local evenement = os.pullEventRaw("terminate")
    if evenement == "terminate" then
      if cfg.arretParTerminate ~= false then
        info(ETAPES.ARRET, "arret demande par le controleur (Ctrl+T)")
        etat.arret = true
        return
      end
      avert(ETAPES.ARRET, "Ctrl+T ignore : le poste est en autonomie totale")
    end
  end
end

--------------------------------------------------------------------------------
-- 18. SEQUENCE DE DEMARRAGE
--------------------------------------------------------------------------------

local function demarrer()
  term.clear()
  term.setCursorPos(1, 1)
  info(ETAPES.DEMARRAGE, string.format(
    "FrenchNet Command %s - protocole v%d", VERSION_PROGRAMME, PROTOCOLE_VERSION))

  if not chargerConfiguration() then return false end

  journal.seuilEcran   = NIVEAUX[cfg.journalNiveauEcran] or 1
  journal.tailleMax    = cfg.journalTailleMax or (128 * 1024)
  journal.fichierActif = cfg.journalFichier ~= false
  if journal.fichierActif then
    info(ETAPES.INIT_JOURNAL, "journal fichier actif : " .. CHEMIN_JOURNAL)
  end

  validerConfiguration()
  chargerEtat()
  chargerZones()

  if not ouvrirReseau() then return false end
  if not detecterRadar() then return false end

  etat.demarrageA = os.clock()
  info(ETAPES.DEMARRAGE, string.format(
    "poste %s operationnel en temps de %s%s",
    cfg.identifiant, etat.mode, etat.alerteMax and " avec ALERTE MAXIMALE active" or ""))

  if #etat.zones == 0 then
    avert(ETAPES.DEMARRAGE,
      "aucune zone classifiee : tout le theatre est hors juridiction, le systeme " ..
      "n'engagera rien. Definissez les zones depuis le menu protege.")
  end
  return true
end

--------------------------------------------------------------------------------
-- 19. SUPERVISEUR
--------------------------------------------------------------------------------

local function executer()
  local interface
  local charge = loadfile(CHEMIN_INTERFACE)
  if charge then
    local ok, module = pcall(charge)
    if ok and type(module) == "table" then interface = module end
  end

  local boucles = { boucleRadar, boucleReseau, boucleBattement, boucleTerminate }

  if interface then
    journal.ecranSilencieux = true -- l'interface prend la main sur l'affichage
    boucles[#boucles + 1] = function()
      local ok, err = pcall(interface.executer, {
        etat = etat, cfg = cfg, noyau = noyau, journal = journal,
        actions = actions, version = VERSION_PROGRAMME,
      })
      if not ok then
        journal.ecranSilencieux = false
        erreur(ETAPES.INTERFACE, "interface interrompue : " .. tostring(err))
        -- L'interface n'est pas critique : le systeme continue de decider sans
        -- ecran. On bloque cette coroutine pour ne pas tuer les autres.
        while not etat.arret do sleep(5) end
      end
    end
  else
    avert(ETAPES.INTERFACE, "interface.lua absent : fonctionnement en mode journal seul")
  end

  parallel.waitForAny(table.unpack(boucles))
end

--------------------------------------------------------------------------------
-- 20. POINT D'ENTREE AVEC REDEMARRAGE AUTOMATIQUE
--------------------------------------------------------------------------------

local delaiRedemarrage = cfg.redemarrageDelaiMin or 3

while true do
  if fs.exists(MARQUEUR_ARRET) then
    journal.ecranSilencieux = false
    info(ETAPES.ARRET, "marqueur d'arret manuel present : le poste ne demarre pas")
    return
  end

  local ok, err = pcall(function()
    if not demarrer() then error("sequence de demarrage incomplete", 0) end
    executer()
  end)

  journal.ecranSilencieux = false

  if etat.arret then
    info(ETAPES.ARRET, "arret propre du poste de commandement")
    return
  end

  if not ok then
    critique(ETAPES.BOUCLE_PRINCIPALE, string.format(
      "le poste s'est interrompu : %s", tostring(err)))
  else
    avert(ETAPES.BOUCLE_PRINCIPALE, "la boucle principale s'est terminee sans erreur, relance")
  end

  local delai = math.min(delaiRedemarrage, cfg.redemarrageDelaiMax or 60)
  avert(ETAPES.DEMARRAGE, string.format("redemarrage automatique dans %ds", delai))
  sleep(delai)
  delaiRedemarrage = math.min(delai * 2, cfg.redemarrageDelaiMax or 60)

  -- Remise a zero de l'etat volatil, en conservant les zones et le mode.
  etat.pistes, etat.transpondeurs = {}, {}
  etat.echecsConsecutifs = 0
end
