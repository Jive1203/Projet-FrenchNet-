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
  RECEPTION_RADAR      = "reception d'une trame de station radar",
  ANNONCE              = "annonce du poste de commandement",
  FUSION_PISTES        = "fusion des pistes multi-radars",
  RECEPTION_LANCEUR    = "reception d'une balise de lanceur",
  TERRAIN              = "modele de terrain",
  CHARGEMENT_TERRAIN   = "chargement du modele de terrain",
  ENREGISTREMENT_TERRAIN = "enregistrement du modele de terrain",
  ORDRE_MANUEL         = "ordre manuel du controleur",
  IDENTIFICATION       = "identification a deux voies",
  DISCORDANCE_IFF      = "discordance entre les deux voies d'identification",
  DEMANDE_SCRAMBLE_AG  = "demande de scramble AG en attente de controleur",
  PROJECTILE           = "detection de projectile",
  ALLIE_MANUEL         = "declaration d'allie par un controleur",
  CARTE                = "carte tactique",
  RECEPTION_INVENTAIRE = "reception de l'inventaire Fire Control",
  RECEPTION_ROSTER     = "reception du roster de factions",
  BASCULE_MODE         = "bascule guerre / paix",
  ALERTE_MAXIMALE      = "alerte maximale manuelle",
  CONFIGURATION_ZONE   = "configuration d'une zone",
  ROTATION_CODE        = "rotation d'un code transpondeur",
  CHANGEMENT_MDP       = "changement de mot de passe",
  ACCES_CONSOLE        = "acces a la console",
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
local CHEMIN_TERRAIN_M= fs.combine(REPERTOIRE, "terrain.lua")
local CHEMIN_CARTE_M  = fs.combine(REPERTOIRE, "carte.lua")
local CHEMIN_SCANNER  = fs.combine(REPERTOIRE, "scanner.lua")
local CHEMIN_JOURNAL  = fs.combine(REPERTOIRE, "command.log")
local CHEMIN_ZONES    = fs.combine(REPERTOIRE, "zones.dat")
local CHEMIN_ETAT     = fs.combine(REPERTOIRE, "etat.dat")
local CHEMIN_TERRAIN  = fs.combine(REPERTOIRE, "terrain.dat")
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

--[[
  JOURNAL A ECRITURE GROUPEE.

  Ouvrir, ecrire et fermer un fichier pour CHAQUE ligne est une operation
  disque a chaque fois. Avec une trentaine de contacts suivis et le niveau
  DEBUG, cela faisait des dizaines d'ouvertures de fichier par seconde sur
  l'ordinateur - une des causes de saccade les plus betes et les plus faciles
  a supprimer.

  Les lignes sont donc accumulees et ecrites par lots. Deux garde-fous :
    - une ligne ERREUR ou CRITIQUE vide le tampon immediatement. Ce qui compte
      dans un journal, c'est justement d'y retrouver ce qui a precede un
      plantage ;
    - le tampon est vide a chaque battement et a l'arret du poste.
]]
local journal = {
  fichierActif  = false,
  seuilEcran    = 1,
  seuilFichier  = 1,
  tailleMax     = 128 * 1024,
  tampon        = {},     -- derniers messages, pour l'ecran "journal" de l'interface
  tamponMax     = 200,
  enAttente     = {},     -- lignes pas encore ecrites sur disque
  lotMax        = 24,     -- ecriture forcee au-dela de ce nombre de lignes
  ageMax        = 5,      -- ecriture forcee au-dela de cet age, en secondes
  attenteDepuis = nil,
  ecrituresDisque = 0,
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

-- Ecrit sur disque tout ce qui attend, en UNE seule ouverture de fichier.
function journal.vider()
  local nombre = #journal.enAttente
  if nombre == 0 or not journal.fichierActif then
    journal.attenteDepuis = nil
    return 0
  end
  pcall(function()
    journal.rotation()
    local f = fs.open(CHEMIN_JOURNAL, "a")
    if f then
      for i = 1, nombre do f.writeLine(journal.enAttente[i]) end
      f.close()
      journal.ecrituresDisque = journal.ecrituresDisque + 1
    end
  end)
  journal.enAttente = {}
  journal.attenteDepuis = nil
  return nombre
end

--[[
  Vidage sur ANCIENNETE, appele une fois par balayage.
  Le groupement des ecritures fait gagner beaucoup de temps disque, mais il
  cree un risque : si l'ordinateur est coupe net - chunk decharge, serveur qui
  tombe - tout ce qui attend est perdu. Or c'est exactement ce qu'on vient
  chercher dans un journal apres un incident.
  La perte possible est donc bornee a quelques secondes, pas au prochain
  battement qui peut etre a une minute.
]]
function journal.viderSiVieux(maintenant)
  if not journal.attenteDepuis then return end
  if (maintenant - journal.attenteDepuis) >= (journal.ageMax or 5) then
    journal.vider()
  end
end

function journal.ecrire(niveau, etape, message)
  local rang = NIVEAUX[niveau] or 1
  local versEcran  = rang >= journal.seuilEcran and not journal.ecranSilencieux
  local versDisque = journal.fichierActif and rang >= journal.seuilFichier

  -- Rien a en faire : on ne construit meme pas la chaine. Formater une ligne
  -- pour la jeter aussitot est du travail pur perdu, et il y en a beaucoup.
  if not (versEcran or versDisque) then return end

  local ligne = string.format("[%s] [%s] [etape: %s] %s",
    horodatage(), niveau, etape or "?", tostring(message))

  -- Tampon memoire (consulte par l'interface), en anneau : pas de decalage
  -- de tableau a chaque ligne.
  local tampon = journal.tampon
  tampon[#tampon + 1] = { niveau = niveau, texte = ligne }
  if #tampon > journal.tamponMax * 2 then
    local garde = {}
    for i = #tampon - journal.tamponMax + 1, #tampon do garde[#garde + 1] = tampon[i] end
    journal.tampon = garde
  end

  if versEcran then
    pcall(function()
      if term.isColour and term.isColour() then term.setTextColour(COULEURS[niveau] or colors.white) end
      print(ligne)
      if term.isColour and term.isColour() then term.setTextColour(colors.white) end
    end)
  end

  if versDisque then
    journal.enAttente[#journal.enAttente + 1] = ligne
    journal.attenteDepuis = journal.attenteDepuis or os.clock()
    -- Une erreur part sur disque tout de suite : c'est precisement ce qu'on
    -- vient chercher dans un journal apres un plantage.
    if rang >= NIVEAUX.ERREUR or #journal.enAttente >= journal.lotMax then
      journal.vider()
    end
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
-- 3 bis. ATTENTE INSENSIBLE A Ctrl+T
--
--   os.pullEvent, et donc sleep() et rednet.receive(), LEVENT une erreur
--   "Terminated" des qu'un Ctrl+T arrive. Un poste bati dessus s'interrompt
--   entierement des qu'on effleure ces deux touches : les boucles de decision
--   meurent, le superviseur redemarre, et le mot de passe console n'est
--   jamais demande - le verrou serait contournable en appuyant sur Ctrl+T.
--
--   Toutes les boucles du poste attendent donc en pullEventRaw et IGNORENT
--   les evenements 'terminate'. Une seule boucle les traite : boucleTerminate,
--   qui decide s'il faut demander un mot de passe ou s'arreter.
--------------------------------------------------------------------------------

local function attendreBrut(filtre)
  while true do
    local evenement = table.pack(os.pullEventRaw())
    if evenement[1] ~= "terminate"
       and (filtre == nil or evenement[1] == filtre) then
      return table.unpack(evenement, 1, evenement.n)
    end
  end
end

-- Remplace sleep() : meme comportement, mais un Ctrl+T ne l'interrompt pas.
local function dormir(secondes)
  local minuteur = os.startTimer(secondes or 0)
  while true do
    local _, identifiant = attendreBrut("timer")
    if identifiant == minuteur then return end
  end
end

-- Remplace rednet.receive() : meme signature, meme insensibilite.
local function recevoir(protocole, delai)
  local minuteur = delai and os.startTimer(delai) or nil
  while true do
    local evenement = table.pack(os.pullEventRaw())
    if evenement[1] == "rednet_message"
       and (protocole == nil or evenement[4] == protocole) then
      return evenement[2], evenement[3], evenement[4]
    elseif evenement[1] == "timer" and minuteur and evenement[2] == minuteur then
      return nil
    end
  end
end

--------------------------------------------------------------------------------
-- 4. CHARGEMENT DU NOYAU DE DECISION
--------------------------------------------------------------------------------

local function chargerModule(chemin, nom, indispensable)
  local charge, err = loadfile(chemin)
  if not charge then
    local message = "[etape: " .. ETAPES.CHARGEMENT_NOYAU .. "] " .. nom
      .. " introuvable ou invalide : " .. tostring(err)
    if indispensable then printError(message) end
    return nil, message
  end
  local ok, resultat = pcall(charge)
  if not ok or type(resultat) ~= "table" then
    local message = "[etape: " .. ETAPES.CHARGEMENT_NOYAU .. "] " .. nom
      .. " n'a pas pu etre initialise : " .. tostring(resultat)
    if indispensable then printError(message) end
    return nil, message
  end
  return resultat
end

local noyau = chargerModule(CHEMIN_NOYAU, "noyau.lua", true)
if not noyau then
  printError("Le poste ne peut pas demarrer sans son noyau de decision.")
  return
end

local terrain = chargerModule(CHEMIN_TERRAIN_M, "terrain.lua", true)
if not terrain then
  printError("Le poste ne peut pas demarrer sans son modele de terrain.")
  return
end

local scanner = chargerModule(CHEMIN_SCANNER, "scanner.lua", true)
if not scanner then
  printError("Le poste ne peut pas demarrer sans son adaptateur radar.")
  return
end

-- La carte n'est pas indispensable au fonctionnement : sans elle le poste
-- decide toujours, il n'affiche simplement plus de situation tactique.
local carte = chargerModule(CHEMIN_CARTE_M, "carte.lua", false)

--------------------------------------------------------------------------------
-- 5. CONFIGURATION
--------------------------------------------------------------------------------

local DEFAUTS = {
  identifiant              = "CMD-01",
  designation              = "",
  peripheriqueRadar        = nil,
  radarLocal               = true,
  positionRadar            = { x = 0, y = 64, z = 0 },
  positionPoste            = nil,
  positionsRelatives       = nil,
  porteeRadar              = 512,
  validiteStation          = 15,
  toleranceFusion          = 8,
  protocoleRadar           = "frenchnet_radar",
  protocoleAnnonce         = "frenchnet_annonce",
  annonceSecondes          = 30,
  protocoleLanceur         = "frenchnet_lanceur",
  terrainResolution        = 16,
  terrainRayonRecherche    = 3,
  terrainCellulesMax       = 4000,
  terrainEnregistrement    = 120,
  sondesVehicules          = false,
  sondeEchantillons        = 3,
  sondeToleranceVerticale  = 0.5,
  sondeVitesseSolMax       = 12,
  ecartMaxSonde            = 30,
  poidsMunitions           = 1.5,
  scrambleAGAutomatique    = false,
  identificationRadarActive = true,
  discordanceDeclasse      = true,
  nomsAllies               = nil,
  nomsHostiles             = nil,
  vitesseProjectile        = 30,
  echelleCarte             = 32,
  suiviCarte               = "MENACE",
  intervalleBalayage       = 1,
  historiquePiste          = 20,
  oubliPisteSecondes       = 30,
  codeAllie                = nil,
  codeAlliePrecedent       = nil,
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
  motDePasseConsole        = "578933",
  verrouillageDemarrage    = false,
  moniteur                 = nil,
  echelleMoniteur          = "auto",
  carteLargeurMini         = 50,
  carteHauteurMini         = 20,
  contactsAffiches         = 6,
  sortieRedstoneAlerte     = nil,
  journalFichier           = true,
  journalTailleMax         = 131072,
  journalNiveauEcran       = "INFO",
  journalNiveauFichier     = "INFO",
  journalLot               = 24,
  journalAgeMax            = 5,
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
  if cfg.codeAccesMenu == "1234" then
    anomalies[#anomalies + 1] =
      "codeAccesMenu laisse a sa valeur par defaut : la configuration des zones " ..
      "n'est pas protegee"
  end
  if cfg.motDePasseConsole == "578933" then
    anomalies[#anomalies + 1] =
      "motDePasseConsole laisse a sa valeur par defaut, qui figure en clair dans le " ..
      "depot public : la console CraftOS n'est pas protegee"
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
  versionZones      = 0,    -- incremente a chaque edition : invalide le cache carte
  stations          = {},   -- [nom] = station radar deportee
  nombreStations    = 0,
  stationsActives   = 0,
  lanceurs          = {},   -- [nom] = balise de lanceur (position, munitions, tirs)
  terrain           = nil,  -- modele de terrain observe
  terrainSale       = false,
  alliesManuels     = {},   -- [nom de contact] = { t, motif } declares par un controleur
  demandesAG        = {},   -- [id de piste] = scramble AG en attente d'un controleur
  nombreDemandesAG  = 0,
  pistes            = {},   -- [id] = piste
  transpondeurs     = {},   -- [cle] = { code, x, y, z, recuA, nom }
  roster            = {},   -- [nomJoueur] = { faction, hostilite }
  plateformes       = {},   -- inventaire recu de Fire Control
  inventaireRecuA   = -1e9,

  alertes           = {},   -- alertes controleur non acquittees
  cote              = nil,

  compteurs = {
    balayages = 0, detections = 0, decisions = 0,
    ordresFeu = 0, ordresScramble = 0,
    killsConfirmes = 0, pistesPerdues = 0, reemissions = 0, alertes = 0,
    ordresManuels = 0, alliesManuels = 0, demandesAG = 0, projectiles = 0,
    discordances = 0,
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
  --[[
    Les boites englobantes memorisees sur les zones (champ _boite, calcule
    pour accelerer les tests d'appartenance) ne sont PAS enregistrees : une
    geometrie modifiee a la main dans le fichier se retrouverait avec une
    boite perimee, donc un test d'appartenance faux, donc une doctrine
    appliquee sur la mauvaise zone. Elles se recalculent en une passe.
  ]]
  local propres = {}
  for i, zone in ipairs(etat.zones) do
    local copie = {}
    for cle, valeur in pairs(zone) do
      if cle ~= "_boite" then copie[cle] = valeur end
    end
    propres[i] = copie
  end

  if ecrireTable(CHEMIN_ZONES, propres, ETAPES.ENREGISTREMENT_ZONES) then
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
    codeAllie            = cfg.codeAllie,
    codeAlliePrecedent   = cfg.codeAlliePrecedent,
    rotationAllieA       = cfg.rotationAllieA,
    codeGeneral          = cfg.codeGeneral,
    codeGeneralPrecedent = cfg.codeGeneralPrecedent,
    rotationGeneraleA    = cfg.rotationGeneraleA,
    codeAccesMenu        = cfg.codeAccesMenu,
    motDePasseConsole    = cfg.motDePasseConsole,
    alliesManuels        = etat.alliesManuels,
  }, ETAPES.ENREGISTREMENT_ETAT)
end

--[[
  Le modele de terrain est le seul etat que le poste APPREND. Le perdre a
  chaque redemarrage reviendrait a redecouvrir le relief a chaque
  rechargement de chunk, donc a mal classer les contacts pendant toute la
  phase d'apprentissage. Il est ecrit periodiquement, pas a chaque releve :
  ecrire un fichier a chaque pas de joueur saturerait le disque.
]]
local function enregistrerTerrain()
  if not etat.terrain then return false end
  local ok = ecrireTable(CHEMIN_TERRAIN, terrain.exporter(etat.terrain),
    ETAPES.ENREGISTREMENT_TERRAIN)
  if ok then
    etat.terrainSale = false
    local stats = terrain.statistiques(etat.terrain)
    debug_(ETAPES.ENREGISTREMENT_TERRAIN, string.format(
      "%d case(s), %d echantillon(s), %d blocs carres couverts",
      stats.cases, stats.echantillons, stats.surface))
  end
  return ok
end

local function chargerTerrain()
  etat.terrain = terrain.nouveau({
    resolution     = cfg.terrainResolution,
    rayonRecherche = cfg.terrainRayonRecherche,
    cellulesMax    = cfg.terrainCellulesMax,
    altitudeDefaut = cfg.altitudeSolReference,
  })
  local donnees = lireTable(CHEMIN_TERRAIN, ETAPES.CHARGEMENT_TERRAIN)
  if not donnees then
    info(ETAPES.CHARGEMENT_TERRAIN,
      "aucun modele de terrain enregistre : le poste part d'une carte vierge et " ..
      "apprend le relief au fil des observations (stations, lanceurs, joueurs au sol)")
    return
  end
  local ok, motif = terrain.importer(etat.terrain, donnees)
  if ok then
    info(ETAPES.CHARGEMENT_TERRAIN, motif)
  else
    avert(ETAPES.CHARGEMENT_TERRAIN, motif .. " : le modele repart de zero")
  end
end

local function chargerEtat()
  local donnees = lireTable(CHEMIN_ETAT, ETAPES.CHARGEMENT_ETAT)
  if not donnees then
    info(ETAPES.CHARGEMENT_ETAT, "aucun etat persistant : demarrage en temps de PAIX")
    return
  end
  if donnees.mode == noyau.MODES.GUERRE then etat.mode = noyau.MODES.GUERRE end
  etat.alerteMax = donnees.alerteMax == true
  --[[
    Les codes et les mots de passe tournes en jeu font autorite sur le fichier
    de configuration : celui-ci n'amorce qu'un poste neuf. Sans cela, chaque
    redemarrage ramenerait les codes d'usine - et toute la flotte deja
    reconfiguree deviendrait INCONNUE d'un coup.
  ]]
  if type(donnees.codeGeneral) == "string" and donnees.codeGeneral ~= "" then
    cfg.codeGeneral = donnees.codeGeneral
    cfg.codeGeneralPrecedent = donnees.codeGeneralPrecedent
    cfg.rotationGeneraleA = donnees.rotationGeneraleA or donnees.rotationA
  end
  if type(donnees.codeAllie) == "string" and donnees.codeAllie ~= "" then
    cfg.codeAllie = donnees.codeAllie
    cfg.codeAlliePrecedent = donnees.codeAlliePrecedent
    cfg.rotationAllieA = donnees.rotationAllieA
    info(ETAPES.CHARGEMENT_ETAT, "code allie restaure depuis l'etat persistant")
  end
  if type(donnees.codeAccesMenu) == "string" and donnees.codeAccesMenu ~= "" then
    cfg.codeAccesMenu = donnees.codeAccesMenu
  end
  if type(donnees.motDePasseConsole) == "string" and donnees.motDePasseConsole ~= "" then
    cfg.motDePasseConsole = donnees.motDePasseConsole
  end
  if type(donnees.alliesManuels) == "table" then
    etat.alliesManuels = donnees.alliesManuels
    local n = 0
    for _ in pairs(etat.alliesManuels) do n = n + 1 end
    if n > 0 then
      avert(ETAPES.ALLIE_MANUEL, string.format(
        "%d contact(s) restent declares ALLIES a la main par un controleur : " ..
        "ils traverseront toutes les zones sans etre engages", n))
    end
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
-- 10. RESEAU DE STATIONS RADAR
--
--     Le poste central ne balaie plus lui-meme : il ECOUTE. Chaque station
--     radar est un ordinateur autonome, pose a cote de son antenne, qui
--     normalise ses echos en coordonnees absolues et les transmet ici.
--
--     Ce que cela change :
--       - la couverture n'est plus limitee a la portee d'un seul radar ;
--       - la chute d'une station degrade la couverture au lieu d'aveugler
--         tout le systeme ;
--       - chaque station declare sa position, donc son enveloppe fiable
--         propre : la confirmation de destruction utilise celle de la station
--         qui a REELLEMENT vu la cible, pas une portee moyenne fictive ;
--       - une station posee au sol est un releve d'altitude exact pour le
--         modele de terrain.
--
--     Un radar peut aussi etre accole directement au poste : il devient alors
--     la station "LOCAL", traitee comme toutes les autres.
--------------------------------------------------------------------------------

local function enregistrerStation(nom, donnees, maintenant)
  local station = etat.stations[nom]
  local nouvelle = station == nil
  if nouvelle then
    station = { nom = nom, trames = 0 }
    etat.stations[nom] = station
    etat.nombreStations = etat.nombreStations + 1
  end

  station.designation = donnees.designation
  station.x, station.y, station.z = donnees.x, donnees.y, donnees.z
  station.portee   = nombreValide(donnees.portee) and donnees.portee or 0
  station.contacts = type(donnees.contacts) == "table" and donnees.contacts or {}
  station.recuA    = maintenant
  station.trames   = station.trames + 1
  station.locale   = donnees.locale == true

  if nouvelle then
    info(ETAPES.RECEPTION_RADAR, string.format(
      "station radar %s entree dans le reseau : X=%.0f Y=%.0f Z=%.0f, portee %.0f",
      nom, station.x or 0, station.y or 0, station.z or 0, station.portee))
  end

  -- Une station est posee au sol : sa position est un releve d'altitude exact.
  if nombreValide(station.x) and nombreValide(station.y) and nombreValide(station.z) then
    terrain.echantillonner(etat.terrain, station.x, station.y, station.z, "radar", maintenant)
  end
  return station
end

-- Station "LOCAL" : radar accole directement au poste de commandement.
local radarLocal, methodesLocales, relativesLocales

local function detecterRadarLocal()
  if cfg.radarLocal == false then
    info(ETAPES.DETECTION_RADAR,
      "aucun radar local configure : le poste fonctionne uniquement sur les stations deportees")
    return false
  end
  local r, nom, actives, motif, inventaire = scanner.detecter(peripheral, cfg.peripheriqueRadar)

  for _, p in ipairs(inventaire or {}) do
    debug_(ETAPES.DETECTION_RADAR, string.format(
      "peripherique '%s' types [%s] methodes [%s]",
      p.nom, table.concat(p.types, ", "),
      #p.methodes > 0 and table.concat(p.methodes, ", ") or "aucune"))
  end

  if not r then
    -- Absence de radar local : normal, le poste vit des stations deportees.
    -- On le dit en INFO, pas en ERREUR, mais on donne quand meme la piste.
    info(ETAPES.DETECTION_RADAR, motif .. " ; le poste s'appuiera sur les stations deportees")
    info(ETAPES.DETECTION_RADAR,
      "Si un radar est cense etre accole ici, lancez 'diagnostic' pour voir ce que " ..
      "l'ordinateur percoit reellement.")
    return false
  end
  radarLocal, methodesLocales = r, actives
  info(ETAPES.DETECTION_RADAR, motif .. " (station LOCAL)")
  return true
end

local function balayerRadarLocal(maintenant)
  if not radarLocal then return end
  local bruts = scanner.collecter(radarLocal, methodesLocales, function(fn)
    return proteger(ETAPES.BALAYAGE_RADAR, fn)
  end)

  if relativesLocales == nil then
    if type(cfg.positionsRelatives) == "boolean" then
      relativesLocales = cfg.positionsRelatives
      info(ETAPES.NORMALISATION_ECHOS, "referentiel local force par configuration : "
        .. (relativesLocales and "RELATIF" or "ABSOLU"))
    else
      local relatif, motif = scanner.deduireReferentiel(bruts, cfg.positionRadar, cfg.porteeRadar)
      relativesLocales = relatif
      info(ETAPES.NORMALISATION_ECHOS, motif)
    end
  end

  local contacts = scanner.normaliser(bruts, cfg.positionRadar, relativesLocales)
  enregistrerStation("LOCAL", {
    designation = "radar du poste de commandement", locale = true,
    x = cfg.positionRadar.x, y = cfg.positionRadar.y, z = cfg.positionRadar.z,
    portee = cfg.porteeRadar, contacts = contacts,
  }, maintenant)
end

--------------------------------------------------------------------------------
-- 11. FUSION DES PISTES  [ETAPE 1 : DETECTION]
--
--     Deux stations qui voient le meme aeronef ne doivent pas produire deux
--     pistes : le systeme tirerait deux fois sur la meme cible et compterait
--     deux menaces la ou il n'y en a qu'une. Les contacts sont donc regroupes
--     par identifiant stable, et a defaut par proximite.
--
--     Quand plusieurs stations voient le meme contact, la position retenue est
--     celle de la station LA PLUS PROCHE : c'est la mesure la moins degradee.
--------------------------------------------------------------------------------

local compteurAnonyme = 0

-- Rapprochement par proximite, pour les contacts sans identifiant stable.
local function apparierParProximite(collection, x, y, z, nature, tolerance, filtreTemps)
  local meilleur, meilleureDistance = nil, tolerance
  for id, candidat in pairs(collection) do
    if candidat.nature == nature and (not filtreTemps or filtreTemps(candidat)) then
      local d = noyau.distance3D(candidat, { x = x, y = y, z = z })
      if d <= meilleureDistance then meilleur, meilleureDistance = id, d end
    end
  end
  return meilleur
end

--[[
  Un contact peut-il servir de sonde d'altitude ?
  Les vehicules sont refuses par defaut : un aeronef en croisiere a altitude
  constante passerait pour un vehicule au sol et empoisonnerait durablement le
  modele de terrain. Un joueur qui marche, lui, est pose - c'est la sonde la
  plus abondante et la plus fiable dont dispose le systeme.
]]
local function alimenterTerrain(piste, maintenant)
  if piste.nature ~= noyau.NATURES.JOUEUR and cfg.sondesVehicules ~= true then return end

  local sonde, motif = terrain.contactEstUneSonde(piste, cfg)
  if not sonde then return end

  -- Garde-fou : un releve qui contredit franchement une case deja bien etayee
  -- n'est pas du terrain, c'est un contact en vol au-dessus.
  local sol, confiance = terrain.hauteurSol(etat.terrain, piste.x, piste.z)
  if confiance >= 0.5 and math.abs(piste.y - sol) > (cfg.ecartMaxSonde or 30) then
    debug_(ETAPES.TERRAIN, string.format(
      "releve de %s refuse : %.0f contre un sol connu a %.0f", piste.nom, piste.y, sol))
    return
  end

  local avecMotif = journal.seuilEcran <= 0 or journal.fichierActif
  local _, detail = terrain.echantillonner(etat.terrain, piste.x, piste.y, piste.z,
    "contact", maintenant, avecMotif)
  etat.terrainSale = true
  if detail then
    debug_(ETAPES.TERRAIN, string.format("sonde %s [%s] : %s", piste.nom, motif, detail))
  end
end

local function mettreAJourPistes(maintenant)
  etat.compteurs.balayages = etat.compteurs.balayages + 1
  proteger(ETAPES.BALAYAGE_RADAR, balayerRadarLocal, maintenant)

  local validite = cfg.validiteStation or 15
  local groupes, actives, neutresIgnorees = {}, 0, 0

  for nom, station in pairs(etat.stations) do
    local age = maintenant - (station.recuA or -1e9)
    if age > validite then
      if not station.muette then
        station.muette = true
        avert(ETAPES.RECEPTION_RADAR, string.format(
          "station %s muette depuis %.0fs : sa couverture est perdue", nom, age))
      end
    else
      if station.muette then
        station.muette = false
        info(ETAPES.RECEPTION_RADAR, "station " .. nom .. " de retour sur le reseau")
      end
      actives = actives + 1

      for _, contact in ipairs(station.contacts or {}) do
        local x, y, z = contact.x, contact.y, contact.z
        if nombreValide(x) and nombreValide(y) and nombreValide(z) then
          local nature = contact.nature or noyau.NATURES.ENTITE

          -- Filtrage du bruit biologique : sans cela le systeme engage les vaches.
          if nature == noyau.NATURES.ENTITE and cfg.traiterEntitesNeutres ~= true then
            -- Comptees, pas journalisees une par une : une station peut en
            -- rapporter des dizaines a chaque balayage.
            neutresIgnorees = neutresIgnorees + 1
          else
            local id = contact.id
            if not id then
              -- Rapprochement d'abord avec ce que ce balayage a deja vu (une
              -- autre station), puis avec les pistes existantes.
              id = apparierParProximite(groupes, x, y, z, nature, cfg.toleranceFusion or 8)
                or apparierParProximite(etat.pistes, x, y, z, nature,
                     cfg.toleranceAppariement or 24,
                     function(pi) return (maintenant - (pi.vuA or 0)) <= (cfg.intervalleBalayage or 1) * 3 end)
              if not id then
                compteurAnonyme = compteurAnonyme + 1
                id = string.format("ANON-%d", compteurAnonyme)
              end
            end

            local distance = noyau.distance3D({ x = x, y = y, z = z }, station)
            local g = groupes[id]
            if not g then
              groupes[id] = {
                id = id, nom = contact.nom or id, nature = nature,
                meta = contact.meta,
                x = x, y = y, z = z,
                distance = distance, portee = station.portee,
                stations = { nom },
              }
            else
              g.stations[#g.stations + 1] = nom
              -- Les metadonnees d'identification sont conservees des qu'une
              -- station en fournit : toutes ne renseignent pas les memes champs.
              g.meta = g.meta or contact.meta
              -- La station la plus proche fournit la mesure la moins degradee.
              if distance < g.distance then
                g.x, g.y, g.z = x, y, z
                g.distance, g.portee = distance, station.portee
                g.nom = contact.nom or g.nom
              end
            end
          end
        end
      end
    end
  end

  etat.stationsActives = actives
  if neutresIgnorees > 0 then
    debug_(ETAPES.NORMALISATION_ECHOS, string.format(
      "%d entite neutre ignoree(s) sur ce balayage (traiterEntitesNeutres = false)",
      neutresIgnorees))
  end

  ------------------------------------------------------------------- pistes
  local vus = {}
  for id, g in pairs(groupes) do
    local piste = etat.pistes[id]
    if not piste then
      piste = {
        id = id, nom = g.nom, nature = g.nature,
        echantillons = {}, premiereDetection = maintenant, engagement = nil,
      }
      etat.pistes[id] = piste
      etat.compteurs.detections = etat.compteurs.detections + 1
      info(ETAPES.DETECTION, string.format(
        "nouveau contact %s (%s) en X=%.0f Y=%.0f Z=%.0f, vu par %s",
        piste.nom, g.nature, g.x, g.y, g.z, table.concat(g.stations, "+")))
    elseif #g.stations > 1 and not piste.multiStation then
      piste.multiStation = true
      debug_(ETAPES.FUSION_PISTES, string.format(
        "contact %s vu simultanement par %d stations : %s",
        piste.nom, #g.stations, table.concat(g.stations, "+")))
    end

    -- Vitesses calculees par Command sur sa propre piste : ne dependre d'aucun
    -- champ optionnel de l'addon rend la mesure fiable.
    local precedent = piste.echantillons[#piste.echantillons]
    if precedent and maintenant > precedent.t then
      local dt = maintenant - precedent.t
      piste.vitesseHorizontale = noyau.distance2D(g.x, g.z, precedent.x, precedent.z) / dt
      piste.vitesseVerticale   = (g.y - precedent.y) / dt
    end

    --[[
      DETECTION CINEMATIQUE DE PROJECTILE
      Quand le mod ne dit rien d'utile sur le type, la vitesse trahit : aucun
      appareil pilote ne tient durablement la vitesse d'un obus. Un contact
      anonyme au-dela du seuil est requalifie en MISSILE - donc affiche comme
      tel et traite comme cible aerienne, quelle que soit son altitude.
      La requalification est definitive pour la piste : un projectile ne
      redevient pas un aeronef en ralentissant a l'impact.
    ]]
    if piste.nature ~= noyau.NATURES.MISSILE
       and piste.nature ~= noyau.NATURES.JOUEUR
       and nombreValide(piste.vitesseHorizontale)
       and piste.vitesseHorizontale >= (cfg.vitesseProjectile or 30) then
      piste.nature = noyau.NATURES.MISSILE
      piste.verdictNom = nil
      etat.compteurs.projectiles = etat.compteurs.projectiles + 1
      avert(ETAPES.PROJECTILE, string.format(
        "contact %s requalifie PROJECTILE : %.0f b/s, au-dela du seuil de %.0f b/s",
        piste.nom, piste.vitesseHorizontale, cfg.vitesseProjectile or 30))
    end

    piste.meta = g.meta or piste.meta
    piste.x, piste.y, piste.z = g.x, g.y, g.z
    piste.vuA = maintenant
    piste.present = true
    piste.stations = g.stations
    -- Distance a la station qui a reellement vu la cible, et portee de CETTE
    -- station : c'est sur elles que se calcule l'enveloppe fiable.
    piste.distanceRadar  = g.distance
    piste.porteeStation  = g.portee
    piste.echantillons[#piste.echantillons + 1] = { t = maintenant, x = g.x, y = g.y, z = g.z }
    while #piste.echantillons > (cfg.historiquePiste or 20) do
      table.remove(piste.echantillons, 1)
    end

    proteger(ETAPES.TERRAIN, alimenterTerrain, piste, maintenant)
    vus[id] = true
  end

  ------------------------------------------------------- pistes non revues
  for id, piste in pairs(etat.pistes) do
    if not vus[id] then
      if piste.present then
        piste.present = false
        debug_(ETAPES.MISE_A_JOUR_PISTES, string.format(
          "contact %s perdu du reseau radar a %.0fm de la station la plus proche",
          piste.nom, piste.distanceRadar or -1))
      end
      -- Une piste sous evaluation de destruction n'est jamais oubliee avant
      -- d'avoir ete conclue : c'est la seule facon de trancher entre un crash
      -- et une fuite.
      local sousEvaluation = piste.engagement and piste.engagement.actif
      if not sousEvaluation and (maintenant - (piste.vuA or 0)) > (cfg.oubliPisteSecondes or 30) then
        etat.pistes[id] = nil
        if etat.demandesAG[id] then
          etat.demandesAG[id] = nil
          etat.nombreDemandesAG = math.max(0, etat.nombreDemandesAG - 1)
          info(ETAPES.DEMANDE_SCRAMBLE_AG, string.format(
            "demande de scramble AG sur %s annulee : le contact a quitte la couverture radar",
            piste.nom))
        end
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
--[[
  Liste des plateformes exploitables a cet instant.
  Deux sources, fusionnees par nom :
    - les BALISES DE LANCEUR, qui annoncent d'elles-memes position, munitions
      restantes et tirs effectues. C'est la source de reference : elle est
      vivante et porte le stock reel.
    - l'inventaire global pousse par Fire Control, conserve pour les
      installations sans balise propre.
  Une balise perimee est ecartee : mieux vaut ne pas designer que designer une
  plateforme dont on ne sait plus si elle existe encore.
]]
local function plateformesDisponibles(maintenant)
  local validite = cfg.validiteInventaire or 60
  local parNom, liste = {}, {}

  for _, p in ipairs(etat.plateformes) do
    local nom = tostring(p.nom or p.name or "?")
    if not parNom[nom] then
      parNom[nom] = p
      liste[#liste + 1] = p
    end
  end

  for nom, lanceur in pairs(etat.lanceurs) do
    local age = maintenant - (lanceur.recuA or -1e9)
    if age <= validite then
      if parNom[nom] then
        -- La balise fait autorite sur l'inventaire global : elle est plus
        -- fraiche et elle seule connait le stock reel.
        for i, p in ipairs(liste) do
          if tostring(p.nom or p.name) == nom then liste[i] = lanceur break end
        end
      else
        liste[#liste + 1] = lanceur
      end
      parNom[nom] = lanceur
    elseif not lanceur.perimee then
      lanceur.perimee = true
      avert(ETAPES.RECEPTION_LANCEUR, string.format(
        "balise du lanceur %s muette depuis %.0fs : la plateforme n'est plus designable",
        nom, age))
    end
  end

  return liste
end

local function engager(piste, verdict, verdictNom, maintenant, manuel)
  local plateformes = plateformesDisponibles(maintenant)

  -- Les plateformes s'annoncent d'elles-memes. Aucune annonce = aucune defense
  -- joignable : on ne designe pas au hasard, on alerte.
  if #plateformes == 0 then
    alerterControleur("aucune plateforme joignable",
      string.format("cible %s en %s, verdict %s, mais aucune balise de lanceur ni inventaire " ..
        "Fire Control n'est valide", piste.nom, piste.classeZone or "?", verdictNom))
    return {}
  end

  local candidats, rejetes = noyau.designer(plateformes, piste, cfg)

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
  local emis, bloques = {}, {}

  for _, ordre in ipairs(ordres) do
    local c = ordre.candidat

    --[[
      Le scramble AG ne part jamais tout seul. La doctrine peut le reclamer,
      le systeme peut designer la plateforme, mais c'est un humain qui lance
      une patrouille contre de l'infanterie ou un vehicule. La demande est
      enregistree, le controleur la valide depuis la carte.
    ]]
    if noyau.scrambleRequiertControleur(ordre.role, piste.categorie, cfg, manuel) then
      if not etat.demandesAG[piste.id] then
        etat.demandesAG[piste.id] = {
          t = maintenant, nom = piste.nom, categorie = piste.categorie,
          zone = piste.classeZone, verdictNom = verdictNom, plateforme = c.nom,
        }
        etat.nombreDemandesAG = etat.nombreDemandesAG + 1
        etat.compteurs.demandesAG = etat.compteurs.demandesAG + 1
        avert(ETAPES.DEMANDE_SCRAMBLE_AG, string.format(
          "cible %s (%s) en zone %s : la doctrine appelle un %s, plateforme %s designee. " ..
          "AUCUN ordre transmis : un controleur doit valider depuis la carte.",
          piste.nom, piste.categorie, piste.classeZone or "?",
          noyau.verbePourOrdre("SCRAMBLE", piste.categorie, cfg), c.nom))
        alerterControleur("scramble AG en attente de validation",
          string.format("%s (%s) en zone %s - plateforme proposee : %s",
            piste.nom, piste.categorie, piste.classeZone or "?", c.nom))
      end
      bloques[#bloques + 1] = { role = ordre.role, plateforme = c.nom }
    else
    info(ETAPES.DESIGNATION_TIREUR, string.format(
      "cible %s -> plateforme %s designee pour %s (score %.3f = stock %.2f x %.1f + distance %.2f x %.1f " ..
      "+ charge %.2f x %.1f ; %s munition(s), %d tir(s), %.0fm)",
      piste.nom, c.nom, ordre.role, c.score,
      c.penaliteStock, cfg.poidsMunitions or 1.5,
      c.distanceNormalisee, cfg.poidsDistance or 1,
      c.chargeNormalisee, cfg.poidsTirs or 0.5,
      c.munitions and tostring(c.munitions) or "?", c.tirs, c.distance))

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
  end

  return emis, bloques
end

--------------------------------------------------------------------------------
-- 14. DECISION  [ETAPES 2 ET 3 : CLASSIFICATION ET ESCALADE]
--------------------------------------------------------------------------------

local function decider(piste, maintenant)
  --[[
    CLASSIFICATION D'ABORD, JURIDICTION ENSUITE.
    Une piste hors de toute zone classifiee ne declenche toujours AUCUNE
    action - c'est la doctrine et elle ne bouge pas. Mais elle est desormais
    classee quand meme, pour une raison precise : la carte tactique doit
    l'afficher avec le bon symbole, et un controleur doit pouvoir cliquer
    dessus pour ordonner un scramble a la main. Afficher un contact sans
    savoir ce qu'il est n'aiderait personne.
    Le cout est local : une lecture de terrain et un appariement de
    transpondeur. Aucun ordre n'en sort.
  ]]

  ---------------------------------------------------------- classification
  -- Le modele de terrain observe fournit l'altitude reelle du sol sous la
  -- cible. C'est ce qui distingue un char sur une crete d'un aeronef en vol
  -- rasant, la ou une altitude de reference unique se trompe des deux cotes.
  local sol, confianceSol = terrain.hauteurSol(etat.terrain, piste.x, piste.z)
  local solConnu = (confianceSol > 0) and sol or nil
  piste.solEstime, piste.confianceSol = sol, confianceSol

  local classe, zone, chevauchees = noyau.zonePourPoint(etat.zones, piste.x, piste.y, piste.z)
  piste.classeZone, piste.zone = classe, zone

  local categorie, motifCategorie = noyau.categoriser(piste, cfg, zone, solConnu)

  local transpondeur, motifAppariement = transpondeurPourPiste(piste, maintenant)
  local codes = {
    codeAllie            = cfg.codeAllie,
    codeAlliePrecedent   = cfg.codeAlliePrecedent,
    rotationAllieA       = cfg.rotationAllieA or 0,
    codeGeneral          = cfg.codeGeneral,
    codeGeneralPrecedent = cfg.codeGeneralPrecedent,
    rotationGeneraleA    = cfg.rotationGeneraleA or 0,
  }
  piste.allieManuel = etat.alliesManuels[piste.nom] ~= nil

  --[[
    DEUX VOIES D'IDENTIFICATION, RECOUPEES.
    Le transpondeur dit quel code porte l'appareil ; les donnees de Create
    Radars disent ce qu'il est et a qui il appartient. Un transpondeur se
    capture avec l'engin qui le porte, le proprietaire d'une contraption non :
    c'est le recoupement qui fait la valeur du dispositif.
    La doctrine ne bouge pas - sans code valide, la cible reste INCONNUE. La
    voie radar ne delivre aucun laissez-passer, elle peut seulement en retirer
    un quand elle contredit franchement le transpondeur.
  ]]
  local iff, motifIff, identification = noyau.identifier(
    piste, transpondeur, codes, etat.roster, maintenant, cfg, piste.allieManuel)
  piste.identification = identification

  local meta = piste.meta or {}
  local mentionMeta = ""
  if meta.proprietaire or meta.equipe then
    mentionMeta = string.format(" ; radar : proprietaire %s, equipe %s",
      tostring(meta.proprietaire or "-"), tostring(meta.equipe or "-"))
  end

  local changement = (piste.categorie ~= categorie) or (piste.iff ~= iff)
  piste.categorie, piste.iff = categorie, iff

  if changement then
    -- Le detail du terrain n'est reconstruit QUE pour cette ligne de journal,
    -- pas a chaque balayage de chaque contact.
    local _, _, motifSol = terrain.hauteurSol(etat.terrain, piste.x, piste.z, true)
    info(ETAPES.CLASSIFICATION, string.format(
      "cible %s classee %s [%s ; terrain : %s (confiance %.2f)] ; IFF %s [%s ; %s]%s",
      piste.nom, categorie, motifCategorie, tostring(motifSol), confianceSol,
      iff, motifIff, motifAppariement, mentionMeta))
    info(ETAPES.IDENTIFICATION, string.format(
      "cible %s : voie transpondeur %s [%s] / voie radar %s [%s] -> concordance %s",
      piste.nom,
      identification.transpondeur.statut, identification.transpondeur.motif,
      identification.radar.statut, identification.radar.motif,
      identification.concordance))
  end

  -- Une discordance n'est signalee qu'une fois par piste : elle ne change pas
  -- d'un balayage a l'autre, et la repeter noierait le journal.
  if identification.alerte and piste.alerteIdentification ~= identification.alerte then
    piste.alerteIdentification = identification.alerte
    etat.compteurs.discordances = etat.compteurs.discordances + 1
    avert(ETAPES.DISCORDANCE_IFF, string.format("cible %s : %s",
      piste.nom, identification.alerte))
    alerterControleur("discordance d'identification",
      string.format("%s - %s", piste.nom, identification.alerte))
  end

  ------------------------------------------------------------ resolution zone
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
    if piste.verdictNom ~= "HORS_JURIDICTION" then
      debug_(ETAPES.RESOLUTION_ZONE, string.format(
        "cible %s hors de toute zone classifiee : aucune action", piste.nom))
    end
    if not (etat.alerteMax and cfg.alerteMaxCouvreHorsZone == true) then
      piste.verdictNom, piste.verdict = "HORS_JURIDICTION", noyau.VERDICTS.HORS_JURIDICTION
      return
    end
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

  local emis, bloques = engager(piste, verdict, verdictNom, maintenant)

  if #emis == 0 then
    -- Rien n'est parti parce qu'un scramble AG attend un controleur : la
    -- sequence est close cote machine. Sans cela, la doctrine redemanderait
    -- le meme scramble a chaque balayage et noierait le journal.
    if #bloques > 0 then
      piste.engagement = {
        actif = false, termine = true, tentatives = 0,
        verdictNom = verdictNom, attenteControleur = true,
      }
    end
    return
  end

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
      --[[
        L'enveloppe fiable se calcule sur la portee de la STATION QUI A VU la
        cible, pas sur une portee moyenne du reseau. Une cible disparue a 400 m
        d'une station de 512 m de portee est probablement detruite ; la meme
        disparition a 400 m d'une station de 450 m est une sortie de portee.
        Confondre les deux, c'est cesser le feu sur ce qui s'echappe.
      ]]
      local cfgPiste = setmetatable(
        { porteeRadar = piste.porteeStation or cfg.porteeRadar },
        { __index = cfg })
      local resultat, detail = noyau.evaluerDestruction(piste, e, cfgPiste, maintenant)

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
      etat.versionZones = etat.versionZones + 1
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
      etat.versionZones = etat.versionZones + 1
      for _, piste in pairs(etat.pistes) do piste.verdictNom = nil end
      return true
    end
  end
  return false, "zone introuvable"
end

--[[
  ROTATION D'UN CODE TRANSPONDEUR
  Les deux codes se tournent depuis le menu protege, chacun avec sa propre
  periode de grace : l'ancien code reste accepte le temps que la flotte
  recoive le nouveau. Sans cette grace, tourner un code declasserait INCONNU
  tous les appareils encore en vol, et la doctrine de zone ferait le reste.

  La nouvelle valeur est enregistree dans etat.dat : elle survit au
  redemarrage et prime sur le fichier de configuration.
]]
local function tournerCode(genre, nouveau)
  if type(nouveau) ~= "string" or nouveau == "" then return false, "code vide" end
  if #nouveau < 4 then
    return false, "code trop court : 4 caracteres minimum"
  end

  local autre = (genre == "ALLIE") and cfg.codeGeneral or cfg.codeAllie
  if nouveau == autre then
    return false, "les deux codes ne peuvent pas etre identiques : la distinction " ..
      "ami / conditionnel serait perdue"
  end

  if genre == "ALLIE" then
    if nouveau == cfg.codeAllie then return false, "c'est deja le code en vigueur" end
    cfg.codeAlliePrecedent = cfg.codeAllie
    cfg.codeAllie = nouveau
    cfg.rotationAllieA = os.clock()
  else
    if nouveau == cfg.codeGeneral then return false, "c'est deja le code en vigueur" end
    cfg.codeGeneralPrecedent = cfg.codeGeneral
    cfg.codeGeneral = nouveau
    cfg.rotationGeneraleA = os.clock()
  end

  -- Toute piste doit etre reevaluee : un appareil classe INCONNU sous
  -- l'ancien code peut devenir allie sous le nouveau, et inversement.
  for _, piste in pairs(etat.pistes) do piste.verdictNom = nil end

  avert(ETAPES.ROTATION_CODE, string.format(
    "code %s tourne par un controleur ; l'ancien reste accepte %ds (periode de grace)",
    genre == "ALLIE" and "ALLIE" or "GENERAL", cfg.graceRotation or 300))
  enregistrerEtat()
  return true
end

function actions.changerCodeGeneral(nouveau) return tournerCode("GENERAL", nouveau) end
function actions.changerCodeAllie(nouveau)   return tournerCode("ALLIE", nouveau) end

--[[
  CHANGEMENT DE MOT DE PASSE
  L'ancien est exige : sans cela, un ecran laisse deverrouille suffirait a
  verrouiller le poste contre son propre exploitant.
  La valeur elle-meme n'est JAMAIS journalisee - un journal se lit.
]]
local function changerMotDePasse(genre, ancien, nouveau)
  local courant = (genre == "CONSOLE") and cfg.motDePasseConsole or cfg.codeAccesMenu
  if ancien ~= courant then
    avert(ETAPES.CHANGEMENT_MDP, string.format(
      "changement du mot de passe %s refuse : ancien mot de passe incorrect", genre))
    return false, "ancien mot de passe incorrect"
  end
  if type(nouveau) ~= "string" or #nouveau < 4 then
    return false, "nouveau mot de passe trop court : 4 caracteres minimum"
  end
  if nouveau == courant then return false, "c'est deja le mot de passe en vigueur" end

  if genre == "CONSOLE" then cfg.motDePasseConsole = nouveau
  else cfg.codeAccesMenu = nouveau end

  info(ETAPES.CHANGEMENT_MDP, string.format(
    "mot de passe %s change par un controleur (%d caracteres)", genre, #nouveau))
  enregistrerEtat()
  return true
end

function actions.changerMotDePasseConsole(ancien, nouveau)
  return changerMotDePasse("CONSOLE", ancien, nouveau)
end
function actions.changerCodeAccesMenu(ancien, nouveau)
  return changerMotDePasse("MENU", ancien, nouveau)
end

--[[
  ACCES A LA CONSOLE CraftOS
  Sortir de l'interface, c'est se retrouver devant un shell avec acces a tous
  les fichiers du poste : codes transpondeur, zones, journal. Le mot de passe
  console garde cette porte. Chaque tentative, reussie ou non, est journalisee.
]]
function actions.ouvrirConsole(motDePasse)
  if motDePasse ~= cfg.motDePasseConsole then
    etat.echecsConsole = (etat.echecsConsole or 0) + 1
    avert(ETAPES.ACCES_CONSOLE, string.format(
      "ACCES CONSOLE REFUSE : mot de passe incorrect (%d tentative(s) depuis le demarrage)",
      etat.echecsConsole))
    if etat.echecsConsole >= 3 then
      alerterControleur("tentatives d'acces console repetees",
        string.format("%d mots de passe console incorrects depuis le demarrage du poste",
          etat.echecsConsole))
    end
    return false, "mot de passe incorrect"
  end
  avert(ETAPES.ACCES_CONSOLE,
    "acces console accorde : le poste s'arrete et rend la main au shell CraftOS. " ..
    "La defense cesse de decider jusqu'a sa relance.")
  etat.arret = true
  return true
end

--[[
  ORDRE MANUEL DEPUIS LA CARTE TACTIQUE
  Un clic gauche sur un contact ouvre un panneau ou le controleur coche ce
  qu'il veut : scramble, attaque, les deux, ou « considerer comme allie ».

  Ces ordres passent PAR-DESSUS la doctrine de zone, y compris hors
  juridiction. C'est voulu : la doctrine automatise le cas general, l'humain
  garde la main sur le cas particulier. Chaque ordre manuel est journalise
  comme tel, avec la zone et le verdict automatique qu'il court-circuite, pour
  qu'une relecture du journal distingue toujours une decision machine d'une
  decision humaine.
]]
function actions.ordreManuel(pisteId, options)
  options = options or {}
  local piste = etat.pistes[pisteId]
  if not piste then return false, "contact introuvable" end

  if options.allie then
    return actions.marquerAllie(pisteId)
  end
  if not (options.scramble or options.attaque) then
    return false, "aucune action cochee"
  end

  -- Une cible sans categorie n'a rien a transmettre a Fire Control : la
  -- classification est faite a chaque balayage, mais un contact tout juste
  -- apparu peut ne pas encore l'avoir.
  if not piste.categorie then
    return false, "contact pas encore classe, reessayez au prochain balayage"
  end

  local nomVerdict, verdict
  if options.attaque and options.scramble then
    nomVerdict, verdict = "DESTRUCTION_SCRAMBLE", noyau.VERDICTS.DESTRUCTION_SCRAMBLE
  elseif options.attaque then
    nomVerdict, verdict = "DESTRUCTION", noyau.VERDICTS.DESTRUCTION
  else
    nomVerdict, verdict = "SCRAMBLE", noyau.VERDICTS.SCRAMBLE
  end

  local maintenant = os.clock()
  avert(ETAPES.ORDRE_MANUEL, string.format(
    "ORDRE MANUEL sur %s (%s) : %s demande par un controleur ; zone %s, verdict automatique %s",
    piste.nom, piste.categorie, verdict.libelle,
    piste.classeZone or "hors juridiction", piste.verdictNom or "aucun"))

  -- Le drapeau 'manuel' leve le verrou du scramble AG : la decision humaine
  -- que ce verrou attendait vient precisement d'etre prise.
  local emis = engager(piste, verdict, nomVerdict, maintenant, true)
  if #emis == 0 then
    return false, "aucune plateforme n'a pu etre designee"
  end
  etat.compteurs.ordresManuels = etat.compteurs.ordresManuels + 1

  if etat.demandesAG[pisteId] then
    etat.demandesAG[pisteId] = nil
    etat.nombreDemandesAG = math.max(0, etat.nombreDemandesAG - 1)
    info(ETAPES.DEMANDE_SCRAMBLE_AG,
      "demande de scramble AG sur " .. piste.nom .. " validee par un controleur")
  end

  if verdict.feu then
    local vitesseRef = piste.vitesseHorizontale or 0
    piste.engagement = {
      actif = true, termine = false, tentatives = 1, verdictNom = nomVerdict,
      ordreA = maintenant, vitesseRef = vitesseRef, ordres = emis, manuel = true,
    }
    info(ETAPES.EVALUATION_KILL, string.format(
      "evaluation de destruction ouverte sur %s apres ordre manuel (tentative 1/%d)",
      piste.nom, cfg.tentativesMax))
  else
    piste.engagement = {
      actif = false, termine = true, tentatives = 0, verdictNom = nomVerdict,
      ordres = emis, manuel = true,
    }
  end

  local resume = {}
  for _, o in ipairs(emis) do resume[#resume + 1] = o.chaine end
  return true, table.concat(resume, " | ")
end

--[[
  Declarer un contact ALLIE a la main.
  Prime sur le transpondeur : c'est ce qui permet de couvrir immediatement un
  appareil dont l'emetteur est detruit, sans attendre une rotation de code.
  Consequence directe et voulue : tout engagement en cours sur ce contact est
  interrompu sur-le-champ.
]]
function actions.marquerAllie(pisteId)
  local piste = etat.pistes[pisteId]
  if not piste then return false, "contact introuvable" end

  etat.alliesManuels[piste.nom] = { t = os.clock(), horodatage = horodatage() }
  etat.compteurs.alliesManuels = etat.compteurs.alliesManuels + 1
  piste.allieManuel = true
  piste.verdictNom = nil

  if etat.demandesAG[pisteId] then
    etat.demandesAG[pisteId] = nil
    etat.nombreDemandesAG = math.max(0, etat.nombreDemandesAG - 1)
    info(ETAPES.DEMANDE_SCRAMBLE_AG,
      "demande de scramble AG sur " .. piste.nom .. " annulee : contact declare allie")
  end

  local interrompu = piste.engagement and piste.engagement.actif
  if interrompu then
    avert(ETAPES.ALLIE_MANUEL, string.format(
      "engagement en cours sur %s INTERROMPU : le contact vient d'etre declare allie", piste.nom))
  end
  piste.engagement = nil

  avert(ETAPES.ALLIE_MANUEL, string.format(
    "contact %s declare ALLIE par un controleur : libre passage dans toutes les zones " ..
    "jusqu'a revocation", piste.nom))
  enregistrerEtat()
  return true, piste.nom
end

--[[
  Refus explicite d'une demande de scramble AG. Le contact reste suivi et
  reste classe : seule la patrouille est ecartee. Le refus est journalise au
  meme titre qu'une validation - un ordre non donne est une decision, et elle
  doit se retrouver dans le journal.
]]
function actions.refuserDemandeAG(pisteId)
  local demande = etat.demandesAG[pisteId]
  if not demande then return false, "aucune demande sur ce contact" end
  etat.demandesAG[pisteId] = nil
  etat.nombreDemandesAG = math.max(0, etat.nombreDemandesAG - 1)
  avert(ETAPES.DEMANDE_SCRAMBLE_AG, string.format(
    "demande de scramble AG sur %s (%s, zone %s) REFUSEE par un controleur : " ..
    "aucune patrouille ne part",
    demande.nom, demande.categorie or "?", demande.zone or "?"))
  return true, demande.nom
end

function actions.retirerAllie(nom)
  if not etat.alliesManuels[nom] then return false, "ce contact n'est pas declare allie" end
  etat.alliesManuels[nom] = nil
  for _, piste in pairs(etat.pistes) do
    if piste.nom == nom then piste.allieManuel, piste.verdictNom = false, nil end
  end
  avert(ETAPES.ALLIE_MANUEL, string.format(
    "declaration d'allie revoquee pour %s : le contact repasse sous la doctrine de zone", nom))
  enregistrerEtat()
  return true
end

-- Releve d'altitude saisi a la main par un controleur, pour amorcer le modele
-- de terrain sur un secteur qu'aucune sonde n'a encore visite.
function actions.releverTerrain(x, y, z)
  local _, detail = terrain.echantillonner(etat.terrain, x, y, z, "manuel", os.clock())
  if not detail then return false, "coordonnees invalides" end
  etat.terrainSale = true
  info(ETAPES.TERRAIN, "releve manuel : " .. detail)
  enregistrerTerrain()
  return true, detail
end

actions.terrain = terrain
actions.carte   = carte
actions.plateformesDisponibles = plateformesDisponibles
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
    journal.viderSiVieux(maintenant)
    dormir(cfg.intervalleBalayage or 1)
  end
end

local function boucleReseau()
  while not etat.arret do
    local expediteur, message, protocole = recevoir(nil, 5)
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

      elseif protocole == cfg.protocoleRadar and type(message) == "table"
             and message.protocole == "FRENCHNET_RADAR" then
        local nom = tostring(message.station or ("RAD-" .. expediteur))
        proteger(ETAPES.RECEPTION_RADAR, enregistrerStation, nom, message, maintenant)

      elseif protocole == cfg.protocoleLanceur and type(message) == "table"
             and message.protocole == "FRENCHNET_LANCEUR" then
        local nom = tostring(message.nom or ("LAN-" .. expediteur))
        local precedent = etat.lanceurs[nom]
        etat.lanceurs[nom] = {
          nom = nom, designation = message.designation,
          x = message.x, y = message.y, z = message.z,
          portee = message.portee,
          munitions = message.munitions, munitionsMax = message.munitionsMax,
          tirs = message.tirs, disponible = message.disponible,
          categories = message.categories,
          recuA = maintenant, expediteur = expediteur, perimee = false,
        }
        etat.inventaireRecuA = maintenant

        if not precedent then
          info(ETAPES.RECEPTION_LANCEUR, string.format(
            "plateforme %s entree dans le reseau : X=%.0f Y=%.0f Z=%.0f, %s munition(s), portee %.0f",
            nom, message.x or 0, message.y or 0, message.z or 0,
            tostring(message.munitions), message.portee or 0))
        elseif precedent.munitions and message.munitions
               and message.munitions ~= precedent.munitions then
          debug_(ETAPES.RECEPTION_LANCEUR, string.format(
            "%s : stock %s -> %s, %s tir(s) cumule(s)",
            nom, tostring(precedent.munitions), tostring(message.munitions), tostring(message.tirs)))
        end
        if message.munitions == 0 and (not precedent or precedent.munitions ~= 0) then
          avert(ETAPES.RECEPTION_LANCEUR, string.format(
            "plateforme %s a court de munitions : elle ne sera plus designee", nom))
        end

        -- Un lanceur est pose au sol : sa position est un releve d'altitude.
        if nombreValide(message.x) and nombreValide(message.y) and nombreValide(message.z) then
          terrain.echantillonner(etat.terrain, message.x, message.y, message.z,
            "plateforme", maintenant)
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

--[[
  ANNONCE DU POSTE.
  Sans elle, chaque station et chaque balise DIFFUSE ses trames a la cantonade,
  ce qui reveille tous les ordinateurs du serveur plusieurs fois par seconde,
  qu'ils soient concernes ou non. Le poste s'annonce donc periodiquement ; les
  stations retiennent son numero et lui parlent ensuite directement.

  Une annonce toutes les trente secondes est negligeable ; ce qu'elle
  economise ne l'est pas.
]]
local function boucleAnnonce()
  while not etat.arret do
    proteger(ETAPES.ANNONCE, rednet.broadcast, {
      protocole = "FRENCHNET_COMMAND_ICI", version = PROTOCOLE_VERSION,
      identifiant = cfg.identifiant,
    }, cfg.protocoleAnnonce)
    dormir(cfg.annonceSecondes or 30)
  end
end

local function boucleBattement()
  while not etat.arret do
    dormir(cfg.battementSecondes or 60)
    local pistes, engagees = 0, 0
    for _, p in pairs(etat.pistes) do
      pistes = pistes + 1
      if p.engagement and p.engagement.actif then engagees = engagees + 1 end
    end
    local c = etat.compteurs
    local lanceurs = 0
    for _ in pairs(etat.lanceurs) do lanceurs = lanceurs + 1 end
    local stats = terrain.statistiques(etat.terrain)
    info("battement", string.format(
      "mode %s%s | %d piste(s), %d engagement(s) | %d/%d station(s) radar, %d lanceur(s), %d zone(s) | " ..
      "terrain %d case(s) dont %d etayee(s) | feu %d, scramble %d, kills %d, perdues %d, " ..
      "reemissions %d, manuels %d, alertes %d",
      etat.mode, etat.alerteMax and " + ALERTE MAX" or "",
      pistes, engagees, etat.stationsActives, etat.nombreStations, lanceurs, #etat.zones,
      stats.cases, stats.etayees,
      c.ordresFeu, c.ordresScramble, c.killsConfirmes, c.pistesPerdues, c.reemissions,
      c.ordresManuels, c.alertes))

    if etat.nombreDemandesAG > 0 then
      avert(ETAPES.DEMANDE_SCRAMBLE_AG, string.format(
        "%d demande(s) de scramble AG toujours en attente d'un controleur",
        etat.nombreDemandesAG))
    end

    -- Le modele de terrain n'est ecrit que s'il a change depuis la derniere
    -- sauvegarde : inutile de reecrire un fichier identique toutes les minutes.
    if etat.terrainSale then proteger(ETAPES.ENREGISTREMENT_TERRAIN, enregistrerTerrain) end
    journal.vider()

    if etat.nombreStations > 0 and etat.stationsActives == 0 then
      alerterControleur("reseau radar entierement muet",
        string.format("%d station(s) connue(s), aucune ne repond : le systeme est aveugle",
          etat.nombreStations))
    end

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
      if cfg.arretParTerminate == false then
        avert(ETAPES.ARRET, "Ctrl+T ignore : le poste est en autonomie totale")
      elseif etat.interfaceActive and type(cfg.motDePasseConsole) == "string"
             and cfg.motDePasseConsole ~= "" then
        --[[
          L'interface est la : c'est elle qui demandera le mot de passe. On
          leve un drapeau plutot que d'arreter, sinon n'importe qui obtiendrait
          un shell et l'acces a tous les fichiers du poste - codes compris.
        ]]
        etat.demandeConsole = true
        info(ETAPES.ACCES_CONSOLE, "Ctrl+T : mot de passe console demande")
      else
        -- Pas d'interface pour poser la question, ou pas de mot de passe
        -- defini : on ne peut pas verrouiller un poste sans lui laisser une
        -- porte de sortie.
        info(ETAPES.ARRET, "arret demande par le controleur (Ctrl+T)")
        etat.arret = true
        return
      end
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
  journal.seuilFichier = NIVEAUX[cfg.journalNiveauFichier] or NIVEAUX.INFO
  journal.lotMax       = cfg.journalLot or 24
  journal.ageMax       = cfg.journalAgeMax or 5
  journal.fichierActif = cfg.journalFichier ~= false
  if journal.fichierActif then
    info(ETAPES.INIT_JOURNAL, "journal fichier actif : " .. CHEMIN_JOURNAL)
  end

  -- L'etat persistant est charge AVANT la validation : les codes et mots de
  -- passe tournes en jeu priment sur le fichier d'amorcage, et c'est la
  -- configuration EFFECTIVE qu'il faut valider. Valider le fichier
  -- reprocherait eternellement un mot de passe d'usine deja change.
  chargerEtat()
  validerConfiguration()
  chargerZones()
  chargerTerrain()

  if not ouvrirReseau() then return false end

  -- Un radar accole au poste est un bonus, pas une condition : le poste vit
  -- des stations deportees. Demarrer sans radar local est normal.
  detecterRadarLocal()

  etat.demarrageA = os.clock()
  info(ETAPES.DEMARRAGE, string.format(
    "poste %s operationnel en temps de %s%s",
    cfg.identifiant, etat.mode, etat.alerteMax and " avec ALERTE MAXIMALE active" or ""))

  if #etat.zones == 0 then
    avert(ETAPES.DEMARRAGE,
      "aucune zone classifiee : tout le theatre est hors juridiction, le systeme " ..
      "n'engagera rien. Definissez les zones depuis le menu protege.")
  end

  info(ETAPES.DEMARRAGE, string.format(
    "en attente du reseau : stations radar sur '%s', balises de lanceur sur '%s'",
    cfg.protocoleRadar, cfg.protocoleLanceur))
  info(ETAPES.ANNONCE, string.format(
    "ce poste est l'ordinateur %d. Il s'annonce toutes les %ds sur '%s' : les stations " ..
    "et les balises lui parleront directement au lieu de diffuser a tout le serveur. " ..
    "Vous pouvez aussi figer ce numero dans leur champ idCommand.",
    os.getComputerID(), cfg.annonceSecondes or 30, cfg.protocoleAnnonce))
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

  local boucles = { boucleRadar, boucleReseau, boucleAnnonce, boucleBattement, boucleTerminate }

  if interface then
    journal.ecranSilencieux = true -- l'interface prend la main sur l'affichage
    etat.interfaceActive = true
    boucles[#boucles + 1] = function()
      local ok, err = pcall(interface.executer, {
        etat = etat, cfg = cfg, noyau = noyau, journal = journal,
        terrain = terrain, carte = carte,
        actions = actions, version = VERSION_PROGRAMME,
      })
      if not ok then
        journal.ecranSilencieux = false
        erreur(ETAPES.INTERFACE, "interface interrompue : " .. tostring(err))
        -- L'interface n'est pas critique : le systeme continue de decider sans
        -- ecran. On bloque cette coroutine pour ne pas tuer les autres.
        while not etat.arret do dormir(5) end
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
    journal.vider()
    return
  end

  if not ok then
    critique(ETAPES.BOUCLE_PRINCIPALE, string.format(
      "le poste s'est interrompu : %s", tostring(err)))
    journal.vider()
  else
    avert(ETAPES.BOUCLE_PRINCIPALE, "la boucle principale s'est terminee sans erreur, relance")
  end

  --[[
    Temporisation de redemarrage. Volontairement le SEUL sleep() du programme :
    ici, un Ctrl+T doit pouvoir interrompre pour de bon. C'est la soupape de
    secours d'un poste qui plante en boucle - sans elle, un poste dont le
    demarrage echoue serait impossible a arreter, et donc impossible a reparer.
  ]]
  local delai = math.min(delaiRedemarrage, cfg.redemarrageDelaiMax or 60)
  avert(ETAPES.DEMARRAGE, string.format("redemarrage automatique dans %ds", delai))
  sleep(delai)
  delaiRedemarrage = math.min(delai * 2, cfg.redemarrageDelaiMax or 60)

  -- Remise a zero de l'etat volatil. On CONSERVE les zones, le mode, les
  -- declarations d'allies et surtout le modele de terrain : le relief appris
  -- ne disparait pas parce qu'un chunk s'est recharge.
  etat.pistes, etat.transpondeurs = {}, {}
  etat.stations, etat.nombreStations, etat.stationsActives = {}, 0, 0
  etat.lanceurs = {}
  etat.echecsConsecutifs = 0
end
