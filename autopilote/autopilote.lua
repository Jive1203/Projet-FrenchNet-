--[[----------------------------------------------------------------------------
  FRENCHNET / AERONAUTICS WARFARE - Module d'autopilote (CC: Tweaked)
  --------------------------------------------------------------------------
  Role      : bibliotheque de pilotage autonome, installable telle quelle sur
              n'importe quel vehicule aerien du serveur (dirigeable de
              livraison, intercepteur de scramble, navire arme).
  Nature    : ce fichier n'est PAS un programme final. Il ne fait rien au
              chargement : il renvoie une table de fonctions. Les programmes
              FrenchNet (mission de livraison, scramble, patrouille...) le
              chargent, lui donnent une cible ou un itineraire, et il se
              charge seul d'y amener le vehicule.

  Interface publique (stable) :
      local autopilote = dofile("/autopilote/autopilote.lua")
      local ap = autopilote.nouveau()          -- lit config_vehicule.lua
      ap.allerA({ x = , y = , z = }, options)  -- rejoindre un point
      ap.suivreItineraire({ p1, p2, ... })     -- enchainer des points
      ap.maintenirPosition(point)              -- tenir la position
      ap.arreter()                             -- neutraliser les commandes
      ap.etat()                                -- instantane complet
      parallel.waitForAny(ap.executer, mission)-- la boucle de vol

  Architecture de pilotage : asservissement en CASCADE a deux etages.
      boucle externe (position) : distance restante -> vitesse cible
      boucle interne (vitesse)  : vitesse cible     -> commande moteur (PID)
  Appliquee separement sur quatre axes : altitude, cap, avance, derive.

  Repli : si un axe PID devient instable, il bascule automatiquement en
  commande par zone morte (si/sinon) avec hysteresis, et la bascule est
  journalisee. Un controleur peut aussi forcer l'un ou l'autre mode.

  NOTE SUR LES ACCENTS : les chaines affichees a l'ecran et ecrites dans le
  journal sont volontairement sans accents (le terminal de CC: Tweaked est
  oriente octet). Les commentaires du code, jamais affiches, sont eux
  rédigés normalement.
--------------------------------------------------------------------------------]]

local VERSION_MODULE = "1.0.0"

local autopilote = {}
autopilote.VERSION = VERSION_MODULE

--------------------------------------------------------------------------------
-- 1. NOMENCLATURE DES ETAPES
--    Chaque etape porte un nom explicite, repris tel quel dans le journal :
--    n'importe quel comportement anormal se trace ainsi jusqu'a sa ligne.
--------------------------------------------------------------------------------

local ETAPES = {
  DEMARRAGE         = "demarrage de l'autopilote",
  CHARGEMENT_CONFIG = "chargement de la configuration vehicule",
  VALIDATION_CONFIG = "validation de la configuration vehicule",
  RAVITAILLEMENT    = "chargement de la position de ravitaillement",
  INIT_JOURNAL      = "initialisation du journal",
  INIT_SORTIES      = "initialisation des sorties moteur",
  ACQUISITION       = "acquisition de la position initiale",
  LECTURE_GPS       = "lecture GPS",
  FILTRAGE          = "filtrage de la position",
  ESTIMATION_VITESSE= "estimation de la vitesse",
  ESTIMATION_CAP    = "estimation du cap",
  DECALAGE          = "application des decalages geometriques",
  BOUCLE_POSITION   = "boucle externe de position",
  BOUCLE_VITESSE    = "boucle interne de vitesse",
  SATURATION        = "saturation de commande",
  BASCULE_MODE      = "bascule PID / zone morte",
  ZONE_MORTE        = "commande par zone morte",
  APPLICATION_CMD   = "application des commandes moteur",
  NAVIGATION        = "navigation par points de passage",
  ETAPE_FRANCHIE    = "point de passage franchi",
  ARRIVEE           = "arrivee sur la cible",
  MAINTIEN          = "maintien de position",
  PERTE_GPS         = "perte du signal GPS",
  SECOURS           = "mode secours",
  MISSION           = "gestion de mission",
  PERSISTANCE       = "sauvegarde de l'etat de mission",
  BOUCLE_PRINCIPALE = "boucle principale de vol",
  ARRET             = "arret de l'autopilote",
}

autopilote.ETAPES = ETAPES

-- Modes de fonctionnement de la machine a etats.
local MODES = {
  ARRET       = "ARRET",       -- commandes neutres, aucune mission
  ACQUISITION = "ACQUISITION", -- lecture de la position avant tout mouvement
  TRANSIT     = "TRANSIT",     -- en route vers une cible
  MAINTIEN    = "MAINTIEN",    -- arrive : correction permanente de la derive
  SECOURS     = "SECOURS",     -- GPS perdu : commandes neutres + anomalie
}
autopilote.MODES = MODES

-- Phases d'un transit (sous-etat de MODES.TRANSIT).
local PHASES = {
  MONTEE    = "MONTEE",    -- montee a l'altitude de croisiere avant transit
  CROISIERE = "CROISIERE", -- transit horizontal a l'altitude de securite
  APPROCHE  = "APPROCHE",  -- ralentissement a l'approche du point
  FINALE    = "FINALE",    -- descente sur le point final / de depot
}
autopilote.PHASES = PHASES

local AXES = { "altitude", "cap", "avance", "derive" }
autopilote.AXES = AXES

-- Les axes 'avance' et 'derive' partagent la tolerance horizontale.
local CLE_HYSTERESIS = {
  altitude = "altitude", cap = "cap", avance = "horizontale", derive = "horizontale",
}

--------------------------------------------------------------------------------
-- 2. OUTILS NUMERIQUES
--------------------------------------------------------------------------------

-- math.atan2 existe en Lua 5.2 (Cobalt/CC: Tweaked) mais a disparu en 5.3+.
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local DEG = 180 / math.pi
local RAD = math.pi / 180

local function nombreValide(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function borner(valeur, mini, maxi)
  if valeur < mini then return mini end
  if valeur > maxi then return maxi end
  return valeur
end

local function signe(valeur)
  if valeur > 0 then return 1 elseif valeur < 0 then return -1 else return 0 end
end

--- Ramene un ecart angulaire dans ]-180, +180].
-- C'est LA fonction qui empeche le vehicule de partir en tete-a-queue : sans
-- elle, passer de 179 a -179 degres serait vu comme un virage de 358 degres.
local function normaliserAngle(angle)
  if not nombreValide(angle) then return 0 end
  angle = angle % 360
  if angle > 180 then angle = angle - 360 end
  return angle
end

--- Cap (releve compas) d'un deplacement horizontal.
-- Convention FrenchNet : 0 = nord (-Z), 90 = est (+X), 180 = sud (+Z),
-- 270 = ouest (-X). C'est la convention de la boussole du jeu.
local function capVers(dx, dz)
  if math.abs(dx) < 1e-9 and math.abs(dz) < 1e-9 then return nil end
  return normaliserAngle(atan2(dx, -dz) * DEG)
end

--- Vecteur unitaire "nez du vehicule" dans le repere monde.
local function vecteurAvant(cap)
  local r = cap * RAD
  return { x = math.sin(r), z = -math.cos(r) }
end

--- Vecteur unitaire "tribord" (droite du vehicule) dans le repere monde.
local function vecteurTribord(cap)
  local r = cap * RAD
  return { x = math.cos(r), z = math.sin(r) }
end

local function normeHorizontale(dx, dz)
  return math.sqrt(dx * dx + dz * dz)
end

local function copierProfond(valeur)
  if type(valeur) ~= "table" then return valeur end
  local copie = {}
  for cle, sousValeur in pairs(valeur) do copie[cle] = copierProfond(sousValeur) end
  return copie
end

--- Fusion recursive : 'ajout' ecrase 'base', les sous-tables sont fusionnees.
local function fusionner(base, ajout)
  local resultat = copierProfond(base)
  if type(ajout) ~= "table" then return resultat end
  for cle, valeur in pairs(ajout) do
    if type(valeur) == "table" and type(resultat[cle]) == "table" then
      resultat[cle] = fusionner(resultat[cle], valeur)
    else
      resultat[cle] = copierProfond(valeur)
    end
  end
  return resultat
end

--- Lecture d'une valeur par chemin pointe : lire(config, "gains.cap.croisiere.kp").
local function lire(table_source, chemin)
  local courant = table_source
  for morceau in tostring(chemin):gmatch("[^%.]+") do
    if type(courant) ~= "table" then return nil end
    courant = courant[morceau]
  end
  return courant
end

--- Ecriture d'une valeur par chemin pointe, en creant les tables manquantes.
local function ecrire(table_cible, chemin, valeur)
  local morceaux = {}
  for morceau in tostring(chemin):gmatch("[^%.]+") do morceaux[#morceaux + 1] = morceau end
  local courant = table_cible
  for i = 1, #morceaux - 1 do
    if type(courant[morceaux[i]]) ~= "table" then courant[morceaux[i]] = {} end
    courant = courant[morceaux[i]]
  end
  courant[morceaux[#morceaux]] = valeur
end

local function horodatage()
  local ok, texte = pcall(function()
    return os.date("!%Y-%m-%d %H:%M:%S", math.floor(os.epoch("utc") / 1000))
  end)
  if ok and texte then return texte end
  return string.format("horloge %.1fs", os.clock())
end

--- Horloge de tick : os.clock() avance d'un pas par tick de serveur.
-- C'est la reference du pilotage (voir la note "HORLOGE" du guide).
local function horlogeTicks()
  return os.clock()
end

--- Horloge murale, en secondes : sert a detecter le ralentissement serveur.
local function horlogeReelle()
  local ok, valeur = pcall(os.epoch, "utc")
  if ok and nombreValide(valeur) then return valeur / 1000 end
  return os.clock()
end

--------------------------------------------------------------------------------
-- 3. JOURNAL
--    Format identique au reste de FrenchNet :
--        [horodatage] [NIVEAU] [etape: <nom>] message
--    Un journal externe peut etre injecte (options.journal) pour que tous les
--    systemes FrenchNet d'un meme vehicule ecrivent dans le meme fichier.
--------------------------------------------------------------------------------

local NIVEAUX = { DEBUG = 0, INFO = 1, AVERT = 2, ERREUR = 3, CRITIQUE = 4 }

local function creerJournal(reglages, etiquette, journalExterne)
  local j = {
    seuilEcran = NIVEAUX[reglages.niveauEcran] or NIVEAUX.INFO,
    fichier    = reglages.fichier and true or false,
    chemin     = reglages.chemin,
    tailleMax  = reglages.tailleMax or 65536,
    etiquette  = etiquette or "AUTOPILOTE",
    ecrits     = 0,
  }

  local COULEURS = {
    DEBUG = 256, INFO = 1, AVERT = 16, ERREUR = 16384, CRITIQUE = 8192,
  }
  if type(colors) == "table" then
    COULEURS = {
      DEBUG    = colors.lightGray or 256,
      INFO     = colors.white or 1,
      AVERT    = colors.yellow or 16,
      ERREUR   = colors.red or 16384,
      CRITIQUE = colors.magenta or 8192,
    }
  end

  -- Verification d'ecriture immediate : mieux vaut le savoir au sol.
  if j.fichier then
    local ok, fichier = pcall(fs.open, j.chemin, "a")
    if ok and fichier then fichier.close() else j.fichier = false end
  end

  local function rotation()
    if not j.fichier or not fs.exists(j.chemin) then return end
    if fs.getSize(j.chemin) < j.tailleMax then return end
    local archive = j.chemin .. ".1"
    if fs.exists(archive) then fs.delete(archive) end
    fs.move(j.chemin, archive)
  end

  function j.ecrire(niveau, etape, message)
    if journalExterne and journalExterne.ecrire then
      return journalExterne.ecrire(niveau, etape, message)
    end
    local texte = tostring(message)
    local entete = string.format("[%s] [%s] [%s] [etape: %s] ",
      horodatage(), niveau, j.etiquette, tostring(etape))

    if (NIVEAUX[niveau] or 1) >= j.seuilEcran then
      local couleur
      if term and term.isColour and term.isColour() then
        couleur = COULEURS[niveau] or COULEURS.INFO
        pcall(term.setTextColour, couleur)
      end
      print(entete .. texte)
      if couleur then pcall(term.setTextColour, COULEURS.INFO) end
    end

    if j.fichier then
      pcall(rotation)
      local ok, fichier = pcall(fs.open, j.chemin, "a")
      if ok and fichier then
        pcall(function()
          fichier.writeLine(entete .. texte)
          fichier.close()
        end)
        j.ecrits = j.ecrits + 1
      end
    end
  end

  function j.debug(e, m)    j.ecrire("DEBUG", e, m)    end
  function j.info(e, m)     j.ecrire("INFO", e, m)     end
  function j.avert(e, m)    j.ecrire("AVERT", e, m)    end
  function j.erreur(e, m)   j.ecrire("ERREUR", e, m)   end
  function j.critique(e, m) j.ecrire("CRITIQUE", e, m) end

  return j
end

--- Journal muet : utilise avant le chargement de la configuration.
local function journalMuet()
  local j = {}
  j.ecrire = function() end
  j.debug, j.info, j.avert, j.erreur, j.critique = j.ecrire, j.ecrire, j.ecrire, j.ecrire, j.ecrire
  return j
end

local function gestionnaireErreur(err)
  local texte = tostring(err)
  if debug and debug.traceback then
    local ok, trace = pcall(debug.traceback, texte, 2)
    if ok and trace then return trace end
  end
  return texte
end

--------------------------------------------------------------------------------
-- 4. CONFIGURATION
--    REGLE ABSOLUE : aucune valeur de vol n'est ecrite en dur ici. Les cles
--    listees dans REQUIS doivent obligatoirement figurer dans le fichier de
--    configuration du vehicule, sans quoi l'autopilote refuse de demarrer.
--    DEFAUTS ne couvre que des reglages techniques secondaires (verbosite,
--    periodes, constantes de filtrage) pour qu'une configuration incomplete
--    ne fasse jamais planter le module en vol.
--------------------------------------------------------------------------------

local DEFAUTS = {
  decalageDansRepereVehicule = true,

  -- Reglages secondaires : completes automatiquement s'ils manquent, mais
  -- toujours presents (et donc modifiables) dans le fichier vehicule livre.
  vitesses = {
    marcheArriere        = 0,   -- vitesse de recul autorisee (0 = pas de marche arriere)
    rayonValidationEtape = 4,   -- rayon de validation d'un point intermediaire
    acquisitionCap       = 2.5, -- vitesse de reptation quand le cap est inconnu
  },

  gps = {
    intervalle          = 0.4,     -- periode de lecture GPS, en secondes
    delaiLocate         = 2,       -- timeout de gps.locate
    lecturesAcquisition = 2,       -- lectures valides exigees avant tout mouvement
    perteToleree        = 2.5,     -- navigation a l'estime autorisee, en secondes
    dtMax               = 2.0,     -- au-dela : discontinuite (chunk recharge)
    vitesseMaxPlausible = 80,      -- blocs/s : au-dela, la lecture est aberrante
    sourceHorloge       = "ticks", -- "ticks" (os.clock) | "reel" (os.epoch)
    seuilRalentissement = 1.6,     -- rapport temps reel / temps tick avant alerte
    filtre        = { type = "passe_bas", constanteTemps = 0.45, fenetre = 4 },
    filtreVitesse = { type = "passe_bas", constanteTemps = 0.60, fenetre = 4 },
  },

  cap = {
    source        = "route",  -- "route" (deduit du deplacement) | "peripherique"
    peripherique  = nil,      -- nom du peripherique fournissant le cap
    methode       = "getYaw",
    convention    = "minecraft", -- "minecraft" (yaw) | "boussole" (cap direct)
    facteur       = 1,
    decalage      = 0,
    vitesseMinRoute = 0.8,    -- blocs/s en dessous desquels la route n'est pas fiable
    dureeCapValide  = 2.0,    -- secondes pendant lesquelles un cap non mesure reste utilisable
    capParDefaut  = 0,
    filtre        = { constanteTemps = 0.35 },
  },

  pilotage = {
    mode = "auto",            -- "auto" | "pid" | "zone_morte"
    capMaxAvanceZoneMorte = 60, -- en zone morte, on tourne avant d'avancer
    distanceMinCapCible   = 3,  -- en deca, l'azimut vers la cible n'est plus fiable
    detection = {
      fenetre           = 5.0,
      changementsSigne  = 5,
      depassements      = 3,
      rapportDepassement= 0.6,
      retourAutoPid     = true,
      dureeAvantRetour  = 25,
    },
    commandesZoneMorte = { altitude = 0.5, cap = 0.25, avance = 0.4, derive = 0.35 },
    correctionDeriveParCap = true,
    corrections = { deriveParCapMax = 35, gainDeriveCap = 2.5 },
  },

  maintien = {
    cap = "auto",             -- "auto" | "conserver" | "vers_cible" | <degres>
    facteurVitesse = 0.35,    -- les vitesses cibles sont reduites en maintien
    arretDansMarges = true,   -- dans les marges : poussee horizontale coupee
  },

  mission = {
    reprendreApresRedemarrage = true,
    reprendreApresPerteGps    = true,
    fichierEtat = "/autopilote/etat_mission.txt",
    respecterAltitudeCroisiere = true,
    monteeAvantTransit = true,
  },

  journal = {
    fichier       = true,
    chemin        = "/autopilote/autopilote.log",
    tailleMax     = 65536,
    niveauEcran   = "INFO",
    periodeCycles = 12,       -- 1 cycle sur N est journalise en DEBUG
    historique    = 120,      -- echantillons conserves par axe pour le reglage
  },

  sorties = {
    type = "redstone",
    axes = {
      avance   = { mode = "aucun" },
      vertical = { mode = "aucun" },
      lacet    = { mode = "aucun" },
      lateral  = { mode = "aucun" },
    },
  },
}

--- Options PID par defaut, appliquees a chaque jeu de gains si absentes.
-- kp / ki / kd restent OBLIGATOIRES : ce sont des valeurs de vol.
local DEFAUTS_PID = {
  integraleMax  = 0.6,   -- borne du terme integral, en unites de commande
  sortieMin     = -1,
  sortieMax     = 1,
  penteMax      = 3.0,   -- variation maximale de la commande, par seconde
  filtreDerivee = 0.25,  -- constante de temps du lissage du terme derive
}

local REQUIS = {
  { chemin = "nom",         type = "chaine" },
  { chemin = "identifiant", type = "chaine" },

  { chemin = "decalageGps.x", type = "nombre" },
  { chemin = "decalageGps.y", type = "nombre" },
  { chemin = "decalageGps.z", type = "nombre" },

  { chemin = "decalageDepot.x", type = "nombre" },
  { chemin = "decalageDepot.y", type = "nombre" },
  { chemin = "decalageDepot.z", type = "nombre" },

  { chemin = "gabarit.longueur", type = "nombre", mini = 1 },
  { chemin = "gabarit.largeur",  type = "nombre", mini = 1 },
  { chemin = "gabarit.hauteur",  type = "nombre", mini = 1 },

  { chemin = "tolerances.horizontale",  type = "nombre", mini = 0.1 },
  { chemin = "tolerances.altitude",     type = "nombre", mini = 0.1 },
  { chemin = "tolerances.cap",          type = "nombre", mini = 0.5 },
  { chemin = "tolerances.dureeArrivee", type = "nombre", mini = 0 },
  { chemin = "tolerances.hysteresis.altitude",    type = "nombre", mini = 0 },
  { chemin = "tolerances.hysteresis.cap",         type = "nombre", mini = 0 },
  { chemin = "tolerances.hysteresis.horizontale", type = "nombre", mini = 0 },

  { chemin = "vitesses.croisiere",        type = "nombre", mini = 0.1 },
  { chemin = "vitesses.approche",         type = "nombre", mini = 0.1 },
  { chemin = "vitesses.verticaleMax",     type = "nombre", mini = 0.1 },
  { chemin = "vitesses.lateraleMax",      type = "nombre", mini = 0 },
  { chemin = "vitesses.tauxVirageMax",    type = "nombre", mini = 1 },
  { chemin = "vitesses.altitudeCroisiere",type = "nombre" },
  { chemin = "vitesses.distanceApproche", type = "nombre", mini = 1 },
  { chemin = "vitesses.distanceMinCroisiere", type = "nombre", mini = 0 },
  { chemin = "vitesses.avanceEnMontee",   type = "nombre", mini = 0 },
  { chemin = "vitesses.margeAltitude",    type = "nombre", mini = 0 },
}

-- Les gains sont obligatoires pour les quatre axes, en croisiere ET en maintien.
for _, axe in ipairs(AXES) do
  REQUIS[#REQUIS + 1] = { chemin = "gains." .. axe .. ".position.kp", type = "nombre" }
  for _, jeu in ipairs({ "croisiere", "maintien" }) do
    for _, gain in ipairs({ "kp", "ki", "kd" }) do
      REQUIS[#REQUIS + 1] = { chemin = "gains." .. axe .. "." .. jeu .. "." .. gain, type = "nombre" }
    end
  end
end

local CHEMIN_CONFIG_DEFAUT        = "/autopilote/config_vehicule.lua"
local CHEMIN_RAVITAILLEMENT       = "/autopilote/ravitaillement.lua"

--- Charge un fichier Lua qui doit se terminer par 'return { ... }'.
local function chargerTableLua(chemin, etiquette)
  if not fs.exists(chemin) then
    error(etiquette .. " introuvable : " .. chemin, 0)
  end
  local fichier = fs.open(chemin, "r")
  if not fichier then error("lecture impossible : " .. chemin, 0) end
  local source = fichier.readAll()
  fichier.close()

  local morceau, err = load(source, "@" .. chemin, "t", _G)
  if not morceau then
    error(etiquette .. " illisible (syntaxe Lua) : " .. tostring(err), 0)
  end
  local ok, resultat = pcall(morceau)
  if not ok then
    error(etiquette .. " a leve une erreur a l'evaluation : " .. tostring(resultat), 0)
  end
  if type(resultat) ~= "table" then
    error(etiquette .. " doit se terminer par 'return { ... }'", 0)
  end
  return resultat
end

--- Position de ravitaillement : valeur de RESEAU, identique sur tous les
-- vehicules, verrouillee. Elle vit dans son propre fichier pour deux raisons :
--   1. elle n'est pas ecrite en dur dans le code ;
--   2. elle n'appartient pas a la configuration du vehicule, donc l'interface
--      de reglage l'affiche mais refuse de la modifier.
local function chargerRavitaillement(chemin)
  local table_rav = chargerTableLua(chemin, "fichier de ravitaillement")
  local p = table_rav.position
  if type(p) ~= "table" or not (nombreValide(p.x) and nombreValide(p.y) and nombreValide(p.z)) then
    error("ravitaillement : 'position' doit etre { x = nombre, y = nombre, z = nombre }", 0)
  end
  return {
    nom         = tostring(table_rav.nom or "STATION DE RAVITAILLEMENT"),
    designation = tostring(table_rav.designation or ""),
    position    = { x = p.x, y = p.y, z = p.z },
    capFinal    = nombreValide(table_rav.capFinal) and table_rav.capFinal or nil,
    verrouille  = true,
  }
end

local function validerConfiguration(config)
  local anomalies = {}

  for _, regle in ipairs(REQUIS) do
    local valeur = lire(config, regle.chemin)
    if regle.type == "chaine" then
      if type(valeur) ~= "string" or valeur == "" then
        anomalies[#anomalies + 1] = "'" .. regle.chemin .. "' manquant (chaine non vide attendue)"
      end
    else
      if not nombreValide(valeur) then
        anomalies[#anomalies + 1] = "'" .. regle.chemin .. "' manquant ou non numerique"
      elseif regle.mini and valeur < regle.mini then
        anomalies[#anomalies + 1] = string.format("'%s' doit valoir au moins %s",
          regle.chemin, tostring(regle.mini))
      end
    end
  end

  if config.ravitaillement == nil then
    anomalies[#anomalies + 1] = "position de ravitaillement absente (fichier ravitaillement.lua)"
  end

  if nombreValide(config.gps.intervalle) and config.gps.intervalle < 0.05 then
    anomalies[#anomalies + 1] = "'gps.intervalle' doit valoir au moins 0.05 s (un tick)"
  end

  local modes = { auto = true, pid = true, zone_morte = true }
  if not modes[tostring(config.pilotage.mode)] then
    anomalies[#anomalies + 1] = "'pilotage.mode' doit valoir 'auto', 'pid' ou 'zone_morte'"
  end

  if #anomalies > 0 then
    error("configuration vehicule invalide -> " .. table.concat(anomalies, " | "), 0)
  end
  return config
end

--- Complete chaque jeu de gains avec les options PID par defaut.
local function completerGains(config)
  for _, axe in ipairs(AXES) do
    for _, jeu in ipairs({ "croisiere", "maintien" }) do
      local jeuGains = config.gains[axe][jeu]
      for cle, valeur in pairs(DEFAUTS_PID) do
        if jeuGains[cle] == nil then jeuGains[cle] = valeur end
      end
      -- Un vehicule sans marche arriere n'a pas de poussee negative : lui
      -- envoyer une commande d'avance negative n'a aucun sens physique et,
      -- sur un cablage bipolaire, le ferait reellement reculer.
      if axe == "avance" and (config.vitesses.marcheArriere or 0) <= 0 then
        jeuGains.sortieMin = 0
      end
    end
  end
  return config
end

--------------------------------------------------------------------------------
-- 5. FILTRAGE DES MESURES
--    Les balises renvoient une position bruitee (trilateration + arrondis).
--    Deux filtres au choix : passe-bas du premier ordre (par defaut) ou
--    moyenne glissante. Les deux utilisent le temps REELLEMENT ecoule : le
--    coefficient du passe-bas est recalcule a chaque cycle a partir de dt.
--------------------------------------------------------------------------------

local Filtre = {}

function Filtre.nouveau(reglages)
  local f = {
    type      = (reglages and reglages.type) or "passe_bas",
    tau       = (reglages and reglages.constanteTemps) or 0.45,
    fenetre   = math.max(1, math.floor((reglages and reglages.fenetre) or 4)),
    valeur    = nil,
    echantillons = {},
  }

  function f.reinitialiser(valeur)
    f.valeur = valeur
    f.echantillons = {}
    if valeur then f.echantillons[1] = valeur end
  end

  --- @param mesure nombre
  --- @param dt     temps reellement ecoule depuis la mesure precedente
  function f.appliquer(mesure, dt)
    if not nombreValide(mesure) then return f.valeur end
    if f.valeur == nil then
      f.reinitialiser(mesure)
      return mesure
    end

    if f.type == "moyenne" then
      f.echantillons[#f.echantillons + 1] = mesure
      while #f.echantillons > f.fenetre do table.remove(f.echantillons, 1) end
      local somme = 0
      for _, v in ipairs(f.echantillons) do somme = somme + v end
      f.valeur = somme / #f.echantillons
    else
      -- Passe-bas : alpha depend du dt reel, donc un cycle rallonge par une
      -- lenteur serveur ne fausse pas la constante de temps.
      local alpha = 1
      if f.tau > 0 and nombreValide(dt) and dt > 0 then
        alpha = dt / (f.tau + dt)
      end
      f.valeur = f.valeur + alpha * (mesure - f.valeur)
    end
    return f.valeur
  end

  return f
end

--- Filtre vectoriel (x, y, z) : trois filtres scalaires synchronises.
local function filtreVecteur(reglages)
  local fx, fy, fz = Filtre.nouveau(reglages), Filtre.nouveau(reglages), Filtre.nouveau(reglages)
  return {
    reinitialiser = function(v)
      fx.reinitialiser(v and v.x); fy.reinitialiser(v and v.y); fz.reinitialiser(v and v.z)
    end,
    appliquer = function(v, dt)
      return { x = fx.appliquer(v.x, dt), y = fy.appliquer(v.y, dt), z = fz.appliquer(v.z, dt) }
    end,
  }
end

--------------------------------------------------------------------------------
-- 6. REGULATEUR PID ROBUSTE
--    Quatre protections indispensables en vol :
--      a. terme integral borne ET gele quand la commande est deja saturee
--         (sinon l'integrateur s'emballe pendant une saturation prolongee) ;
--      b. terme derive calcule sur la MESURE et non sur l'erreur (sinon chaque
--         changement de consigne provoque un a-coup violent, "derivative kick") ;
--      c. limitation de la vitesse de variation de la sortie (les moteurs ne
--         recoivent jamais de saut brutal) ;
--      d. tous les calculs sont bases sur le dt reellement mesure.
--------------------------------------------------------------------------------

local Pid = {}

function Pid.nouveau(gains, nom)
  local p = {
    nom            = nom or "pid",
    integrale      = 0,
    mesurePrec     = nil,
    deriveeFiltree = 0,
    sortiePrec     = 0,
    sature         = false,
    details        = {},
  }

  function p.regler(nouveaux)
    p.gains = fusionner(DEFAUTS_PID, nouveaux or {})
  end
  p.regler(gains)

  --- Remise a zero de l'etat interne (changement de mission, saut de position,
  -- reprise apres perte GPS...). L'historique derive est invalide : le garder
  -- provoquerait un a-coup au premier cycle.
  function p.reinitialiser(sortie)
    p.integrale      = 0
    p.mesurePrec     = nil
    p.deriveeFiltree = 0
    p.sortiePrec     = sortie or 0
    p.sature         = false
  end

  --- @return commande, details
  function p.calculer(consigne, mesure, dt)
    local g = p.gains
    if not (nombreValide(consigne) and nombreValide(mesure) and nombreValide(dt) and dt > 0) then
      return p.sortiePrec, p.details
    end

    local erreur = consigne - mesure
    local terme_p = g.kp * erreur

    -- (b) derivee sur la mesure, lissee, et de signe oppose.
    local derivee = 0
    if p.mesurePrec ~= nil then derivee = (mesure - p.mesurePrec) / dt end
    p.mesurePrec = mesure
    if g.filtreDerivee and g.filtreDerivee > 0 then
      local alpha = dt / (g.filtreDerivee + dt)
      p.deriveeFiltree = p.deriveeFiltree + alpha * (derivee - p.deriveeFiltree)
    else
      p.deriveeFiltree = derivee
    end
    local terme_d = -g.kd * p.deriveeFiltree

    -- (a) integration conditionnelle, bornee.
    local integraleAvant = p.integrale
    p.integrale = borner(p.integrale + g.ki * erreur * dt, -g.integraleMax, g.integraleMax)

    -- (c) bornage + limitation de pente.
    local function limiter(valeur)
      local v = borner(valeur, g.sortieMin, g.sortieMax)
      if g.penteMax and g.penteMax > 0 then
        v = borner(v, p.sortiePrec - g.penteMax * dt, p.sortiePrec + g.penteMax * dt)
      end
      return v
    end

    local brute  = terme_p + p.integrale + terme_d
    local sortie = limiter(brute)

    -- Commande saturee et erreur qui pousse encore dans le meme sens :
    -- on annule l'accumulation de ce cycle.
    if math.abs(sortie - brute) > 1e-9 and (brute - sortie) * erreur > 0 then
      p.integrale = integraleAvant
      brute  = terme_p + p.integrale + terme_d
      sortie = limiter(brute)
    end

    p.sature     = math.abs(sortie - brute) > 1e-9
    p.sortiePrec = sortie
    p.details = {
      erreur = erreur, consigne = consigne, mesure = mesure,
      p = terme_p, i = p.integrale, d = terme_d,
      brute = brute, sortie = sortie, sature = p.sature, dt = dt,
    }
    return sortie, p.details
  end

  return p
end

--------------------------------------------------------------------------------
-- 7. DETECTEUR D'INSTABILITE
--    Deux signatures d'un PID mal regle ou bugue :
--      - l'erreur change de signe plusieurs fois dans une courte fenetre ;
--      - le vehicule depasse la consigne de facon repetee (l'amplitude apres
--        le passage a zero reste comparable a celle d'avant).
--    Les oscillations dans le bruit (sous le seuil de tolerance de l'axe) ne
--    comptent pas : sinon un vehicule parfaitement stable serait declare fou.
--------------------------------------------------------------------------------

local Detecteur = {}

function Detecteur.nouveau(reglages, seuilBruit)
  local d = {
    reglages   = reglages,
    seuilBruit = seuilBruit or 0,
    signePrec  = 0,
    ampliMax   = 0,
    croisements= {},
    depassements = {},
    instable   = false,
    motif      = nil,
  }

  function d.reinitialiser()
    d.signePrec, d.ampliMax = 0, 0
    d.croisements, d.depassements = {}, {}
    d.instable, d.motif = false, nil
  end

  local function elaguer(liste, maintenant, fenetre)
    while liste[1] and (maintenant - liste[1]) > fenetre do table.remove(liste, 1) end
  end

  --- @return instable (booleen), motif (chaine ou nil)
  function d.observer(erreur, maintenant)
    local r = d.reglages
    if not nombreValide(erreur) then return d.instable, d.motif end

    local amplitude = math.abs(erreur)
    if amplitude > d.ampliMax then d.ampliMax = amplitude end

    local s = 0
    if amplitude > d.seuilBruit then s = signe(erreur) end

    if s ~= 0 and d.signePrec ~= 0 and s ~= d.signePrec then
      d.croisements[#d.croisements + 1] = maintenant
      -- Depassement : apres le passage a zero, l'erreur reste du meme ordre
      -- de grandeur qu'avant -> le vehicule a franchi la consigne au lieu de
      -- s'en approcher.
      if d.ampliMax > 0 and amplitude >= d.ampliMax * (r.rapportDepassement or 0.6) then
        d.depassements[#d.depassements + 1] = maintenant
      end
      d.ampliMax = amplitude
    end
    if s ~= 0 then d.signePrec = s end

    elaguer(d.croisements, maintenant, r.fenetre)
    elaguer(d.depassements, maintenant, r.fenetre)

    if #d.croisements >= (r.changementsSigne or 5) then
      d.instable = true
      d.motif = string.format("%d changements de signe en %.1fs", #d.croisements, r.fenetre)
    elseif #d.depassements >= (r.depassements or 3) then
      d.instable = true
      d.motif = string.format("%d depassements de consigne en %.1fs", #d.depassements, r.fenetre)
    else
      -- Evaluation glissante, jamais collante : une fois la fenetre videe,
      -- l'axe est de nouveau considere comme sain (retour automatique au PID).
      d.instable, d.motif = false, nil
    end
    return d.instable, d.motif
  end

  return d
end

--------------------------------------------------------------------------------
-- 8. COMMANDE PAR ZONE MORTE (repli si/sinon) AVEC HYSTERESIS
--    Logique volontairement triviale, donc increvable :
--      si l'ecart depasse le seuil haut  -> corriger dans un sens ;
--      si l'ecart depasse le seuil bas   -> corriger dans l'autre ;
--      sinon                             -> ne rien changer.
--    L'hysteresis (seuil d'entree > seuil de sortie) empeche le yo-yo autour
--    de la limite : une fois la correction engagee, elle ne s'arrete qu'une
--    fois nettement rentre dans la zone morte.
--------------------------------------------------------------------------------

local ZoneMorte = {}

function ZoneMorte.nouveau(seuil, hysteresis, commande)
  local z = {
    seuil = seuil, hysteresis = hysteresis or 0, commande = commande or 0.5,
    actif = false, sens = 0,
  }

  function z.regler(seuilNouveau, hysteresisNouvelle, commandeNouvelle)
    z.seuil      = seuilNouveau or z.seuil
    z.hysteresis = hysteresisNouvelle or z.hysteresis
    z.commande   = commandeNouvelle or z.commande
  end

  function z.reinitialiser()
    z.actif, z.sens = false, 0
  end

  --- @param erreur consigne - mesure (positif = il faut augmenter la mesure)
  --- @return commande dans [-1, 1]
  function z.calculer(erreur)
    if not nombreValide(erreur) then return 0 end
    local seuilEntree = z.seuil + z.hysteresis
    local seuilSortie = math.max(0, z.seuil - z.hysteresis)
    local amplitude   = math.abs(erreur)

    if not z.actif then
      if amplitude > seuilEntree then
        z.actif, z.sens = true, signe(erreur)
      end
    else
      if amplitude < seuilSortie then
        z.actif, z.sens = false, 0
      elseif signe(erreur) ~= 0 and signe(erreur) ~= z.sens and amplitude > seuilEntree then
        z.sens = signe(erreur)
      end
    end

    if not z.actif then return 0 end
    return z.sens * z.commande
  end

  return z
end

--------------------------------------------------------------------------------
-- 9. SORTIES MOTEUR
--    Le module ne sait pas comment un vehicule donne est cable : c'est la
--    configuration qui le decrit, axe par axe. Quatre modes de sortie :
--      "analogique" : un cote redstone, neutre au milieu (ex. 7 sur 0-15) ;
--      "bipolaire"  : deux cotes redstone opposes (avant/arriere, haut/bas) ;
--      "peripherique": appel d'une methode d'un peripherique (controleur) ;
--      "aucun"      : axe non equipe sur ce vehicule.
--    Un programme appelant peut aussi injecter ses propres commandes
--    (options.commandes) : le module s'y adapte sans modification.
--------------------------------------------------------------------------------

local AXES_SORTIE = { "avance", "vertical", "lacet", "lateral" }

local function creerSorties(config, journal, commandesInjectees)
  local s = {
    derniere = { avance = 0, vertical = 0, lacet = 0, lateral = 0 },
    niveaux  = {},   -- dernier niveau redstone ecrit, par cote : outil de cablage
  }
  journal = journal or journalMuet()

  if type(commandesInjectees) == "table" and type(commandesInjectees.appliquer) == "function" then
    -- Pilote fourni par le programme appelant : on lui delegue tout.
    function s.appliquer(commandes)
      s.derniere = commandes
      commandesInjectees.appliquer(commandes)
    end
    function s.neutraliser()
      s.derniere = { avance = 0, vertical = 0, lacet = 0, lateral = 0 }
      if commandesInjectees.arreter then
        commandesInjectees.arreter()
      else
        commandesInjectees.appliquer(s.derniere)
      end
    end
    s.type = "injecte"
    return s
  end

  local reglages = config.sorties or {}
  s.type = reglages.type or "redstone"

  local function sortieRedstone(cote, niveau)
    if not cote then return end
    local valeur = math.floor(borner(niveau, 0, 15) + 0.5)
    s.niveaux[cote] = valeur
    if not redstone then return end
    if redstone.setAnalogOutput then
      redstone.setAnalogOutput(cote, valeur)
    else
      redstone.setOutput(cote, valeur > 0)
    end
  end

  local function appliquerAxe(nomAxe, valeur)
    local reglageAxe = (reglages.axes or {})[nomAxe] or { mode = "aucun" }
    local mode = reglageAxe.mode or "aucun"
    valeur = borner(valeur or 0, -1, 1)
    -- Cablage inverse : un axe branche a l'envers se corrige ici, sans rien
    -- redemonter sur le vehicule.
    if reglageAxe.inverse then valeur = -valeur end

    if mode == "aucun" then
      return

    elseif mode == "analogique" then
      local neutre    = reglageAxe.neutre or 7
      local amplitude = reglageAxe.amplitude or 7
      sortieRedstone(reglageAxe.cote, neutre + amplitude * valeur)

    elseif mode == "bipolaire" then
      local seuil     = reglageAxe.seuil or 0.05
      local amplitude = reglageAxe.amplitude or 15
      local niveau    = math.abs(valeur) * amplitude
      if math.abs(valeur) < seuil then
        sortieRedstone(reglageAxe.cotePositif, 0)
        sortieRedstone(reglageAxe.coteNegatif, 0)
      elseif valeur > 0 then
        sortieRedstone(reglageAxe.coteNegatif, 0)
        sortieRedstone(reglageAxe.cotePositif, niveau)
      else
        sortieRedstone(reglageAxe.cotePositif, 0)
        sortieRedstone(reglageAxe.coteNegatif, niveau)
      end

    elseif mode == "peripherique" then
      local nom = reglageAxe.nom or reglages.peripherique
      if not (peripheral and nom) then return end
      local materiel = peripheral.wrap(nom)
      if not materiel then
        journal.avert(ETAPES.APPLICATION_CMD,
          "peripherique de commande introuvable : " .. tostring(nom))
        return
      end
      local methode = materiel[reglageAxe.methode or ""]
      if type(methode) ~= "function" then
        journal.avert(ETAPES.APPLICATION_CMD, string.format(
          "methode '%s' absente du peripherique '%s'",
          tostring(reglageAxe.methode), tostring(nom)))
        return
      end
      local ok, err = pcall(methode, valeur * (reglageAxe.facteur or 1))
      if not ok then
        journal.avert(ETAPES.APPLICATION_CMD, "commande peripherique refusee : " .. tostring(err))
      end
    end
  end

  function s.appliquer(commandes)
    s.derniere = commandes
    for _, nomAxe in ipairs(AXES_SORTIE) do
      appliquerAxe(nomAxe, commandes[nomAxe])
    end
  end

  function s.neutraliser()
    s.appliquer({ avance = 0, vertical = 0, lacet = 0, lateral = 0 })
  end

  return s
end

--------------------------------------------------------------------------------
-- 10. CAPTEURS
--     Position : reseau de balises FrenchNet via l'API GPS native.
--     Cap      : peripherique dedie si le vehicule en possede un, sinon
--                deduit de la route reellement suivie (cap fond). Sans
--                peripherique et a l'arret, le dernier cap connu est conserve :
--                c'est la limite physique de la mesure, elle est journalisee.
--------------------------------------------------------------------------------

local function creerCapteurCap(config, journal)
  local reglages = config.cap
  local c = { valeur = reglages.capParDefaut or 0, source = "defaut", filtre = Filtre.nouveau(reglages.filtre) }

  local function lirePeripherique()
    if not (peripheral and reglages.peripherique) then return nil end
    local materiel = peripheral.wrap(reglages.peripherique)
    if not materiel then return nil end
    local methode = materiel[reglages.methode or ""]
    if type(methode) ~= "function" then return nil end
    local ok, valeur = pcall(methode)
    if not ok or not nombreValide(valeur) then return nil end
    valeur = valeur * (reglages.facteur or 1) + (reglages.decalage or 0)
    if reglages.convention == "minecraft" then
      -- Yaw Minecraft : 0 = sud (+Z). Cap boussole : 0 = nord (-Z).
      valeur = valeur + 180
    end
    return normaliserAngle(valeur)
  end

  --- @param vitesse vecteur vitesse monde lisse
  --- @param dt      temps reellement ecoule
  function c.mesurer(vitesse, dt)
    if reglages.source == "peripherique" then
      local mesure = lirePeripherique()
      if mesure then
        c.valeur, c.source = mesure, "peripherique"
        return c.valeur, c.source
      end
      if c.source ~= "peripherique_perdu" then
        journal.avert(ETAPES.ESTIMATION_CAP,
          "capteur de cap indisponible : repli sur le cap fond (deduit de la route)")
      end
      c.source = "peripherique_perdu"
    end

    local norme = normeHorizontale(vitesse.x, vitesse.z)
    if norme >= (reglages.vitesseMinRoute or 0.35) then
      local capRoute = capVers(vitesse.x, vitesse.z)
      if capRoute then
        -- Lissage angulaire : on filtre l'ecart, jamais l'angle absolu, sinon
        -- le passage de +179 a -179 ferait faire un tour complet au filtre.
        local ecart = normaliserAngle(capRoute - c.valeur)
        local lisse = c.filtre.appliquer(ecart, dt) or ecart
        c.valeur = normaliserAngle(c.valeur + lisse)
        c.filtre.reinitialiser(0)
        c.source = "route"
      end
    else
      c.source = "conserve"
    end
    return c.valeur, c.source
  end

  function c.forcer(valeur)
    if nombreValide(valeur) then
      c.valeur = normaliserAngle(valeur)
      c.source = "force"
    end
  end

  return c
end

--------------------------------------------------------------------------------
-- 11. GEOMETRIE
--     Le pilotage raisonne toujours sur le CENTRE REEL du vehicule, jamais sur
--     la position de l'ordinateur. Les decalages sont exprimes dans le repere
--     du vehicule (x = tribord, y = haut, z = avant) et sont donc tournes par
--     le cap courant avant d'etre appliques.
--------------------------------------------------------------------------------

local function decalageVersMonde(decalage, cap, dansRepereVehicule)
  if not dansRepereVehicule then
    return { x = decalage.x, y = decalage.y, z = decalage.z }
  end
  local avant   = vecteurAvant(cap)
  local tribord = vecteurTribord(cap)
  return {
    x = decalage.z * avant.x + decalage.x * tribord.x,
    y = decalage.y,
    z = decalage.z * avant.z + decalage.x * tribord.z,
  }
end

--------------------------------------------------------------------------------
-- 12. INSTANCE D'AUTOPILOTE
--------------------------------------------------------------------------------

--- Cree un autopilote pour ce vehicule.
-- @param options table optionnelle :
--   config        chemin du fichier de configuration (defaut : /autopilote/config_vehicule.lua)
--   configuration table de configuration deja chargee (prioritaire, pour les tests)
--   ravitaillement chemin du fichier de ravitaillement verrouille
--   commandes     pilote de sorties injecte { appliquer = fn, arreter = fn }
--   journal       journal externe partage avec les autres systemes FrenchNet
--   cap           fonction renvoyant le cap courant en degres (capteur maison)
function autopilote.nouveau(options)
  options = options or {}
  local ap = {}

  ------------------------------------------------------------------ configuration
  local cheminConfig = options.config or CHEMIN_CONFIG_DEFAUT
  local brute = options.configuration or chargerTableLua(cheminConfig, "configuration vehicule")
  local config = fusionner(DEFAUTS, brute)

  -- La position de ravitaillement ne peut PAS venir du fichier vehicule :
  -- c'est une constante de reseau. Toute tentative est ignoree et signalee.
  local ravitaillementDeclare = brute.ravitaillement ~= nil
  config.ravitaillement = chargerRavitaillement(options.ravitaillement or CHEMIN_RAVITAILLEMENT)

  validerConfiguration(config)
  completerGains(config)

  ap.config        = config
  ap.cheminConfig  = cheminConfig
  ap.VERSION       = VERSION_MODULE

  ----------------------------------------------------------------------- journal
  local journal = creerJournal(config.journal, config.identifiant, options.journal)
  ap.journal = journal

  journal.info(ETAPES.DEMARRAGE, string.format(
    "autopilote v%s | vehicule '%s' (%s) | gabarit %.0fx%.0fx%.0f",
    VERSION_MODULE, config.nom, config.identifiant,
    config.gabarit.longueur, config.gabarit.largeur, config.gabarit.hauteur))
  journal.info(ETAPES.RAVITAILLEMENT, string.format(
    "station de ravitaillement (verrouillee) : %s X=%.1f Y=%.1f Z=%.1f",
    config.ravitaillement.nom, config.ravitaillement.position.x,
    config.ravitaillement.position.y, config.ravitaillement.position.z))
  if ravitaillementDeclare then
    journal.avert(ETAPES.RAVITAILLEMENT,
      "la configuration du vehicule declare une position de ravitaillement : "
      .. "valeur IGNOREE, seul " .. CHEMIN_RAVITAILLEMENT .. " fait foi")
  end
  if (config.decalageGps.x ~= 0 or config.decalageGps.z ~= 0)
     and config.decalageDansRepereVehicule and config.cap.source ~= "peripherique" then
    journal.avert(ETAPES.DECALAGE,
      "decalage GPS horizontal non nul sans capteur de cap : le decalage sera "
      .. "tourne selon le cap deduit de la route, imprecis a l'arret")
  end

  ----------------------------------------------------------------------- organes
  local sorties = creerSorties(config, journal, options.commandes)
  journal.info(ETAPES.INIT_SORTIES, "sorties moteur de type '" .. tostring(sorties.type) .. "'")

  local capteurCap = creerCapteurCap(config, journal)
  if type(options.cap) == "function" then
    -- Capteur de cap fourni par le programme appelant : priorite absolue.
    local mesurerOrigine = capteurCap.mesurer
    capteurCap.mesurer = function(vitesse, dt)
      local ok, valeur = pcall(options.cap)
      if ok and nombreValide(valeur) then
        capteurCap.valeur = normaliserAngle(valeur)
        capteurCap.source = "injecte"
        return capteurCap.valeur, capteurCap.source
      end
      return mesurerOrigine(vitesse, dt)
    end
  end

  local filtrePosition = filtreVecteur(config.gps.filtre)
  local filtreVitesse  = filtreVecteur(config.gps.filtreVitesse)
  local filtreTaux     = Filtre.nouveau(config.gps.filtreVitesse)

  ------------------------------------------------------------------- etat interne
  local etat = {
    mode        = MODES.ARRET,
    phase       = nil,
    position    = nil,   -- centre du vehicule, lisse
    positionGps = nil,   -- derniere lecture brute de l'API GPS
    vitesse     = { x = 0, y = 0, z = 0 },
    cap         = config.cap.capParDefaut or 0,
    sourceCap   = "defaut",
    tauxLacet   = 0,
    commandes   = { avance = 0, vertical = 0, lacet = 0, lateral = 0 },
    cible       = nil,   -- point demande par l'appelant (non decale)
    cibleCentre = nil,   -- point reellement vise par le centre du vehicule
    depart      = nil,   -- origine du segment courant (repere de route)
    itineraire  = nil,
    index       = 0,
    optionsMission = {},
    dansMarges  = 0,     -- duree continue passee dans les tolerances
    tTick = nil, tReel = nil, dt = 0,
    perteGps = 0, lecturesValides = 0, rejetsConsecutifs = 0,
    cycles = 0, discontinuites = 0, anomalies = 0,
    transitHaute = false,
    diagnostics = {},
    derniereErreurCap = 0,
  }
  ap.etatInterne = etat

  -- Un jeu complet d'organes de regulation par axe.
  etat.axes = {}
  for _, axe in ipairs(AXES) do
    local seuilBruit = ({
      altitude = config.tolerances.altitude,
      cap      = config.tolerances.cap,
      avance   = config.tolerances.horizontale,
      derive   = config.tolerances.horizontale,
    })[axe]
    etat.axes[axe] = {
      nom        = axe,
      pid        = Pid.nouveau(config.gains[axe].croisiere, axe),
      jeu        = "croisiere",
      detecteur  = Detecteur.nouveau(config.pilotage.detection, seuilBruit),
      zoneMorte  = ZoneMorte.nouveau(seuilBruit,
                     config.tolerances.hysteresis[CLE_HYSTERESIS[axe]] or 0,
                     config.pilotage.commandesZoneMorte[axe] or 0.4),
      modeCourant= (config.pilotage.mode == "zone_morte") and "zone_morte" or "pid",
      bascule    = 0,
      stableDepuis = 0,
      historique = {},
    }
  end

  ---------------------------------------------------------------------- evenements
  local rappels = {}

  local function emettre(typeEvenement, donnees)
    donnees = donnees or {}
    donnees.type        = typeEvenement
    donnees.identifiant = config.identifiant
    donnees.vehicule    = config.nom
    for _, rappel in ipairs(rappels) do pcall(rappel, typeEvenement, donnees) end
    pcall(os.queueEvent, "autopilote", config.identifiant, typeEvenement, donnees)
  end

  --- Enregistre un rappel appele a chaque evenement de l'autopilote.
  function ap.surEvenement(rappel)
    if type(rappel) == "function" then rappels[#rappels + 1] = rappel end
    return ap
  end

  --- Journalisation DEBUG des grandeurs de cycle, limitee a 1 cycle sur N :
  -- tracer chaque cycle rendrait le journal illisible et userait le disque,
  -- mais on veut quand meme la trace complete de la chaine de calcul.
  local function debugCycle(etape, message)
    local periode = config.journal.periodeCycles or 12
    if periode <= 1 or (etat.cycles % periode) == 0 then
      journal.debug(etape, message)
    end
  end

  --------------------------------------------------------------------------------
  -- 12a. MESURE : horloge, GPS, decalage, filtrage, vitesse, cap
  --------------------------------------------------------------------------------

  --- Temps reellement ecoule depuis le cycle precedent.
  -- On ne suppose JAMAIS un pas de temps constant : le serveur peut ralentir,
  -- un chunk peut se recharger, une lecture GPS peut trainer. On mesure aussi
  -- l'ecart entre l'horloge de tick et l'horloge murale pour signaler un
  -- ralentissement serveur.
  local function mesurerTemps()
    local tTick, tReel = horlogeTicks(), horlogeReelle()
    local dt
    if config.gps.sourceHorloge == "reel" then
      dt = etat.tReel and (tReel - etat.tReel) or config.gps.intervalle
    else
      dt = etat.tTick and (tTick - etat.tTick) or config.gps.intervalle
    end

    local ralentissement = nil
    if etat.tTick and etat.tReel then
      local dTick, dReel = tTick - etat.tTick, tReel - etat.tReel
      if dTick > 0.01 and dReel / dTick > config.gps.seuilRalentissement then
        ralentissement = dReel / dTick
      end
    end

    etat.tTick, etat.tReel = tTick, tReel

    local discontinuite = false
    if not nombreValide(dt) or dt <= 0 then
      dt = config.gps.intervalle
    elseif dt > config.gps.dtMax then
      discontinuite = true
      journal.avert(ETAPES.LECTURE_GPS, string.format(
        "pas de temps anormal : %.2fs (limite %.2fs) - chunk recharge ou serveur "
        .. "fige, etat des regulateurs reinitialise", dt, config.gps.dtMax))
      dt = config.gps.dtMax
    end

    if ralentissement then
      journal.avert(ETAPES.LECTURE_GPS, string.format(
        "ralentissement serveur detecte : %.1f s reelles par seconde de tick", ralentissement))
    end

    etat.dt = dt
    return dt, discontinuite
  end

  --- Lecture brute de la constellation de balises FrenchNet.
  local function lireGps()
    local ok, x, y, z = pcall(gps.locate, config.gps.delaiLocate, false)
    if not ok then
      journal.erreur(ETAPES.LECTURE_GPS, "gps.locate a leve une erreur : " .. tostring(x))
      return nil
    end
    if not (nombreValide(x) and nombreValide(y) and nombreValide(z)) then return nil end
    return { x = x, y = y, z = z }
  end

  --- Remet a zero l'etat des filtres et des regulateurs apres une
  -- discontinuite (saut de position, reprise apres perte GPS, redemarrage).
  local function reinitialiserRegulation(position)
    filtrePosition.reinitialiser(position)
    filtreVitesse.reinitialiser({ x = 0, y = 0, z = 0 })
    filtreTaux.reinitialiser(0)
    etat.vitesse = { x = 0, y = 0, z = 0 }
    etat.tauxLacet = 0
    for _, axe in ipairs(AXES) do
      etat.axes[axe].pid.reinitialiser(0)
      etat.axes[axe].detecteur.reinitialiser()
      etat.axes[axe].zoneMorte.reinitialiser()
    end
  end

  --- Chaine complete de mesure : GPS -> decalage -> filtrage -> vitesse -> cap.
  -- @return true si la position est exploitable, false si le GPS est perdu
  local function mesurer(dt, discontinuite)
    local brut = lireGps()

    if not brut then
      etat.perteGps = etat.perteGps + dt
      if etat.position and etat.perteGps <= config.gps.perteToleree then
        -- Navigation a l'estime : on prolonge brievement sur la derniere
        -- vitesse connue, le temps qu'une trame de balise revienne.
        etat.position = {
          x = etat.position.x + etat.vitesse.x * dt,
          y = etat.position.y + etat.vitesse.y * dt,
          z = etat.position.z + etat.vitesse.z * dt,
        }
        journal.avert(ETAPES.PERTE_GPS, string.format(
          "aucune position GPS depuis %.1fs : navigation a l'estime (tolerance %.1fs)",
          etat.perteGps, config.gps.perteToleree))
        return true, "estime"
      end
      return false, "perdu"
    end

    -- Rejet des lectures aberrantes : une balise qui repond faux ou une
    -- trilateration ratee produit un saut impossible. Trois rejets d'affilee
    -- signifient au contraire que le vehicule a REELLEMENT bouge (teleport,
    -- rechargement de chunk) : on accepte alors la nouvelle position.
    if etat.positionGps and dt > 0 and not discontinuite then
      local dx = brut.x - etat.positionGps.x
      local dy = brut.y - etat.positionGps.y
      local dz = brut.z - etat.positionGps.z
      local vitesseApparente = math.sqrt(dx * dx + dy * dy + dz * dz) / dt
      if vitesseApparente > config.gps.vitesseMaxPlausible then
        etat.rejetsConsecutifs = etat.rejetsConsecutifs + 1
        if etat.rejetsConsecutifs < 3 then
          journal.avert(ETAPES.LECTURE_GPS, string.format(
            "lecture GPS aberrante ignoree : %.1f blocs/s apparents (max plausible %.1f)",
            vitesseApparente, config.gps.vitesseMaxPlausible))
          etat.perteGps = etat.perteGps + dt
          return etat.position ~= nil, "aberrante"
        end
        journal.avert(ETAPES.LECTURE_GPS,
          "saut de position confirme : reinitialisation des filtres et des regulateurs")
        discontinuite = true
      end
    end
    etat.rejetsConsecutifs = 0
    etat.positionGps = brut

    -- Decalage du point de reference GPS -> centre reel du vehicule.
    local decalage = decalageVersMonde(config.decalageGps, etat.cap,
      config.decalageDansRepereVehicule)
    local centre = { x = brut.x - decalage.x, y = brut.y - decalage.y, z = brut.z - decalage.z }

    local positionPrec = etat.position
    if discontinuite or not positionPrec then
      reinitialiserRegulation(centre)
      etat.position = centre
      etat.discontinuites = etat.discontinuites + (discontinuite and 1 or 0)
    else
      etat.position = filtrePosition.appliquer(centre, dt)
      -- Vitesse deduite de deux positions successives LISSEES, puis lissee a
      -- son tour : deriver du brut donnerait un signal inutilisable.
      local vitesseInstantanee = {
        x = (etat.position.x - positionPrec.x) / dt,
        y = (etat.position.y - positionPrec.y) / dt,
        z = (etat.position.z - positionPrec.z) / dt,
      }
      etat.vitesse = filtreVitesse.appliquer(vitesseInstantanee, dt)
    end

    -- Cap et vitesse de lacet.
    local capPrec, sourcePrec = etat.cap, etat.sourceCap
    local cap, sourceCap = capteurCap.mesurer(etat.vitesse, dt)
    etat.cap, etat.sourceCap = cap, sourceCap

    -- La vitesse de lacet n'est derivable que de deux mesures COMPARABLES.
    -- Sans capteur de cap et a l'arret, la source bascule sur "conserve" :
    -- deriver ce cap fige, puis le cap deduit de la route des que le vehicule
    -- bouge, produirait un pic de plusieurs centaines de degres par seconde
    -- qui affolerait la boucle de lacet.
    local mesureFraiche = (sourceCap == "route" or sourceCap == "peripherique"
      or sourceCap == "injecte")
    -- Un cap non mesure depuis trop longtemps n'est plus exploitable : sans
    -- capteur dedie, un vehicule immobile ne sait pas ou pointe son nez.
    if mesureFraiche then
      etat.capNonMesureDepuis = 0
    else
      etat.capNonMesureDepuis = (etat.capNonMesureDepuis or 0) + dt
    end
    local fiableAvant = etat.capFiable
    etat.capFiable = etat.capNonMesureDepuis <= config.cap.dureeCapValide
    if fiableAvant and not etat.capFiable then
      journal.avert(ETAPES.ESTIMATION_CAP, string.format(
        "cap non mesure depuis %.1fs (vitesse sol trop faible) : lacet neutralise "
        .. "et vitesse limitee a %.1f bloc/s le temps de le reacquerir",
        etat.capNonMesureDepuis, config.vitesses.acquisitionCap))
    elseif etat.capFiable and fiableAvant == false then
      journal.info(ETAPES.ESTIMATION_CAP, string.format(
        "cap de nouveau mesure (%s) : %.1f degres", sourceCap, cap))
    end
    if not discontinuite and dt > 0 and mesureFraiche and sourcePrec == sourceCap then
      local limite = config.vitesses.tauxVirageMax * 3
      local tauxInstantane = borner(normaliserAngle(cap - capPrec) / dt, -limite, limite)
      etat.tauxLacet = filtreTaux.appliquer(tauxInstantane, dt) or 0
    else
      -- Mesure non comparable : on relaxe vers zero plutot que de figer une
      -- valeur fausse, et on repart proprement au cycle suivant.
      etat.tauxLacet = etat.tauxLacet * 0.5
      filtreTaux.reinitialiser(etat.tauxLacet)
      etat.axes.cap.pid.reinitialiser(etat.axes.cap.pid.sortiePrec)
    end

    if etat.perteGps > 0 then
      journal.info(ETAPES.LECTURE_GPS, string.format(
        "signal GPS retabli apres %.1fs", etat.perteGps))
    end
    etat.perteGps = 0
    etat.lecturesValides = etat.lecturesValides + 1
    return true, "gps"
  end

  --------------------------------------------------------------------------------
  -- 12b. COMMANDE D'UN AXE : PID en cascade, ou repli zone morte
  --------------------------------------------------------------------------------

  local function basculerAxe(a, nouveauMode, motif)
    if a.modeCourant == nouveauMode then return end
    a.modeCourant  = nouveauMode
    a.bascule      = a.bascule + 1
    a.stableDepuis = 0
    a.pid.reinitialiser(0)
    a.zoneMorte.reinitialiser()
    journal.avert(ETAPES.BASCULE_MODE, string.format(
      "axe %s : bascule en mode %s (%s) - bascule n%d",
      a.nom, nouveauMode == "pid" and "PID" or "ZONE MORTE", tostring(motif), a.bascule))
    emettre("mode", { axe = a.nom, mode = a.modeCourant, motif = motif })
  end

  --- Choisit le mode de l'axe puis produit la commande moteur correspondante.
  -- @param entree { erreurPosition, consigneVitesse, mesureVitesse }
  local function commandeAxe(axe, entree, dt)
    local a = etat.axes[axe]

    -- Surveillance permanente, y compris en zone morte : c'est elle qui
    -- autorise le retour automatique au PID une fois le calme revenu.
    local instable, motif = a.detecteur.observer(entree.erreurPosition, etat.tTick or 0)

    local modeDemande = config.pilotage.mode
    if modeDemande == "pid" then
      if a.modeCourant ~= "pid" then basculerAxe(a, "pid", "mode force par le controleur") end
    elseif modeDemande == "zone_morte" then
      if a.modeCourant ~= "zone_morte" then
        basculerAxe(a, "zone_morte", "mode force par le controleur")
      end
    else
      if a.modeCourant == "pid" then
        if instable then basculerAxe(a, "zone_morte", motif) end
      elseif config.pilotage.detection.retourAutoPid then
        if instable then
          a.stableDepuis = 0
        else
          a.stableDepuis = a.stableDepuis + dt
          if a.stableDepuis >= config.pilotage.detection.dureeAvantRetour then
            basculerAxe(a, "pid", string.format("stabilite retrouvee depuis %.0fs", a.stableDepuis))
          end
        end
      end
    end

    local commande, details
    if a.modeCourant == "pid" then
      commande, details = a.pid.calculer(entree.consigneVitesse, entree.mesureVitesse, dt)
      details = details or {}
      -- Journalisation des entrees/sorties de saturation uniquement : une
      -- ligne par cycle noierait le journal.
      if a.pid.sature and not a.satureAvant then
        journal.avert(ETAPES.SATURATION, string.format(
          "axe %s : commande saturee (consigne %.2f, mesure %.2f, brute %.2f -> %.2f)",
          axe, entree.consigneVitesse or 0, entree.mesureVitesse or 0,
          details.brute or 0, commande or 0))
      elseif (not a.pid.sature) and a.satureAvant then
        journal.info(ETAPES.SATURATION, "axe " .. axe .. " : sortie de saturation")
      end
      a.satureAvant = a.pid.sature
    else
      commande = a.zoneMorte.calculer(entree.erreurPosition)
      details = {
        erreur = entree.erreurPosition, consigne = 0, mesure = entree.mesureVitesse,
        sortie = commande, sature = false, zoneMorte = true,
      }
    end

    -- Historique glissant : c'est ce que le menu de reglage en vol affiche
    -- pour voir immediatement si un axe oscille ou traine.
    local ligne = {
      t        = etat.tTick or 0,
      erreur   = entree.erreurPosition,
      consigne = entree.consigneVitesse,
      mesure   = entree.mesureVitesse,
      commande = commande,
      mode     = a.modeCourant,
      sature   = details.sature,
    }
    a.historique[#a.historique + 1] = ligne
    while #a.historique > config.journal.historique do table.remove(a.historique, 1) end
    a.dernier = ligne

    return commande, ligne
  end

  --------------------------------------------------------------------------------
  -- 12c. GUIDAGE : asservissement en cascade sur quatre axes
  --      Boucle EXTERNE (position -> vitesse cible) puis boucle INTERNE
  --      (vitesse -> commande moteur). C'est cette cascade qui fait ralentir
  --      le vehicule a l'approche du point au lieu de le depasser.
  --------------------------------------------------------------------------------

  local function guider(cibleCentre, limites, dt)
    local pos = etat.position
    local dx = cibleCentre.x - pos.x
    local dy = cibleCentre.y - pos.y
    local dz = cibleCentre.z - pos.z
    local distanceH = normeHorizontale(dx, dz)

    ---------------------------------------------------------------- repere de route
    -- u = axe de la route (depart -> cible), r = perpendiculaire (tribord route).
    local depart = etat.depart
    local longueurRoute = 0
    if depart then
      longueurRoute = normeHorizontale(cibleCentre.x - depart.x, cibleCentre.z - depart.z)
    end
    local routeDefinie = depart ~= nil and longueurRoute > 1e-6

    local u
    if routeDefinie then
      u = { x = (cibleCentre.x - depart.x) / longueurRoute,
            z = (cibleCentre.z - depart.z) / longueurRoute }
    elseif distanceH > 1e-6 then
      u = { x = dx / distanceH, z = dz / distanceH }   -- pas de route : cap direct
    else
      u = vecteurAvant(etat.cap)                        -- deja sur le point
    end
    local r = { x = -u.z, z = u.x }

    -- Ecart lateral a la route prevue, positif a tribord de celle-ci. Sans
    -- segment defini (maintien de position), il n'y a pas de route a suivre.
    local ecartLateral = 0
    if routeDefinie then
      ecartLateral = (pos.x - depart.x) * r.x + (pos.z - depart.z) * r.z
    end

    -- Distance restante PROJETEE sur la route : elle devient negative si le
    -- vehicule depasse le point, ce qui fait naturellement freiner la cascade.
    local resteRoute = dx * u.x + dz * u.z

    ---------------------------------------------------------------- cap a tenir
    -- Hysteresis sur le gel : sans elle, un vehicule qui oscille autour du
    -- seuil alternerait a chaque cycle entre cap fige et cap recalcule.
    if distanceH <= config.pilotage.distanceMinCapCible then
      etat.capGele = true
    elseif distanceH > config.pilotage.distanceMinCapCible * 2 then
      etat.capGele = false
    end

    local capCible = limites.capImpose
    if not capCible and etat.capGele then
      -- Trop pres du point : l'azimut vers la cible devient indefini et se met
      -- a tourner sur lui-meme des que le vehicule bouge d'un dixieme de bloc.
      -- On fige alors le cap vise, sinon la boucle de lacet part en chasse.
      capCible = etat.capCibleFige or etat.cap
    elseif not capCible then
      capCible = capVers(dx, dz) or etat.capCibleFige or etat.cap
      if config.pilotage.correctionDeriveParCap and routeDefinie then
        -- Etre a droite de la route (+) impose de corriger vers la gauche (-).
        local correction = borner(config.pilotage.corrections.gainDeriveCap * ecartLateral,
          -config.pilotage.corrections.deriveParCapMax,
           config.pilotage.corrections.deriveParCapMax)
        capCible = normaliserAngle(capCible - correction)
      end
      etat.capCibleFige = capCible
    end
    local erreurCap = normaliserAngle(capCible - etat.cap)
    etat.derniereErreurCap = erreurCap

    ------------------------------------------------- BOUCLE EXTERNE (position)
    local g = config.gains
    local vitesseRoute = borner(g.avance.position.kp * resteRoute,
      -limites.marcheArriere, limites.vitesseMax)
    local vitesseCroisee = borner(-g.derive.position.kp * ecartLateral,
      -limites.vitesseLaterale, limites.vitesseLaterale)
    local vitesseVerticaleCible = borner(g.altitude.position.kp * dy,
      -limites.vitesseVerticale, limites.vitesseVerticale)
    local tauxLacetCible = borner(g.cap.position.kp * erreurCap,
      -limites.tauxVirage, limites.tauxVirage)

    -- Nez trop loin de la route : on n'accelere pas dans la mauvaise direction.
    -- Quand le cap est inconnu, cette reduction n'a aucun sens (l'erreur de cap
    -- est calculee sur un cap suppose) : on la neutralise.
    local facteurCap = 1
    if etat.capFiable ~= false then
      facteurCap = math.cos(borner(math.abs(erreurCap), 0, 90) * RAD)
      if math.abs(erreurCap) >= 90 then facteurCap = 0 end
    end
    vitesseRoute = vitesseRoute * facteurCap

    -- Vecteur vitesse desire, exprime dans le repere MONDE...
    local desireX = u.x * vitesseRoute + r.x * vitesseCroisee
    local desireZ = u.z * vitesseRoute + r.z * vitesseCroisee

    -- ... puis projete dans le repere du VEHICULE, car c'est dans ce repere
    -- que poussent les moteurs (avance = nez, lateral = tribord).
    local avant   = vecteurAvant(etat.cap)
    local tribord = vecteurTribord(etat.cap)
    local vitesseAvanceCible  = desireX * avant.x   + desireZ * avant.z
    local vitesseLateraleCible= desireX * tribord.x + desireZ * tribord.z
    local vitesseAvanceMesure = etat.vitesse.x * avant.x   + etat.vitesse.z * avant.z
    local vitesseLateraleMesure=etat.vitesse.x * tribord.x + etat.vitesse.z * tribord.z

    vitesseAvanceCible = borner(vitesseAvanceCible, -limites.marcheArriere, limites.vitesseMax)
    vitesseLateraleCible = borner(vitesseLateraleCible,
      -limites.vitesseLaterale, limites.vitesseLaterale)

    -- Cap inconnu : la projection dans le repere du vehicule n'a pas de sens
    -- puisqu'on ignore ou pointe le nez. On avance donc AU PAS, droit devant,
    -- juste assez pour rendre la route observable : le cap se reacquiert seul,
    -- puis le guidage normal reprend. Sans cela, un vehicule sans capteur de
    -- cap et a l'arret ne peut jamais repartir.
    -- La reptation est plafonnee par ce que le guidage demande reellement, et
    -- annulee dans les marges : sinon un vehicule en maintien de position se
    -- pousserait lui-meme hors de sa cible, puis tournerait autour sans fin.
    if etat.capFiable == false then
      local normeDesiree = normeHorizontale(desireX, desireZ)
      local reptation = math.min(config.vitesses.acquisitionCap,
        limites.vitesseMax, normeDesiree)
      if distanceH <= config.tolerances.horizontale then reptation = 0 end
      vitesseAvanceCible = reptation
      vitesseLateraleCible = 0
    end

    debugCycle(ETAPES.BOUCLE_POSITION, string.format(
      "reste %.2fm (route %.2fm, lateral %.2fm) dy %.2fm capCible %.1f erreurCap %.1f "
      .. "-> vAv %.2f vLat %.2f vZ %.2f taux %.1f",
      distanceH, resteRoute, ecartLateral, dy, capCible, erreurCap,
      vitesseAvanceCible, vitesseLateraleCible, vitesseVerticaleCible, tauxLacetCible))

    ------------------------------------------------- BOUCLE INTERNE (vitesses)
    local commandes = {}
    commandes.vertical = commandeAxe("altitude",
      { erreurPosition = dy, consigneVitesse = vitesseVerticaleCible,
        mesureVitesse = etat.vitesse.y }, dt)

    if etat.capFiable == false then
      -- Cap inconnu : on ne tourne pas au hasard et on ne nourrit pas le
      -- detecteur d'instabilite avec une erreur qui n'a aucun sens.
      commandes.lacet = 0
      etat.axes.cap.pid.reinitialiser(0)
      etat.axes.cap.detecteur.reinitialiser()
      etat.axes.cap.zoneMorte.reinitialiser()
    else
      commandes.lacet = commandeAxe("cap",
        { erreurPosition = erreurCap, consigneVitesse = tauxLacetCible,
          mesureVitesse = etat.tauxLacet }, dt)
    end

    commandes.avance = commandeAxe("avance",
      { erreurPosition = resteRoute, consigneVitesse = vitesseAvanceCible,
        mesureVitesse = vitesseAvanceMesure }, dt)

    commandes.lateral = commandeAxe("derive",
      { erreurPosition = -ecartLateral, consigneVitesse = vitesseLateraleCible,
        mesureVitesse = vitesseLateraleMesure }, dt)

    -- Sans marche arriere, la boucle d'avance n'a AUCUNE autorite de freinage :
    -- reguler une vitesse cible nulle ne pourrait produire que de la poussee
    -- vers l'avant, donc aggraver la derive au lieu de la corriger. On coupe
    -- alors franchement et on laisse la trainee faire son travail. C'est ce qui
    -- empeche un vehicule de tourner sans fin autour de son point d'arrivee.
    if limites.marcheArriere <= 0 and vitesseAvanceCible <= 1e-6 then
      commandes.avance = 0
      etat.axes.avance.pid.reinitialiser(0)
    end

    -- En maintien, une fois DANS les marges, on coupe la poussee horizontale :
    -- l'integrateur, meme faible, finirait sinon par pousser le vehicule hors
    -- de sa propre cible, qui repartirait pour un tour. Le vehicule se laisse
    -- arreter par sa trainee, exactement comme en zone morte.
    if limites.arretDansMarges and distanceH <= config.tolerances.horizontale then
      commandes.avance  = 0
      commandes.lateral = 0
      etat.axes.avance.pid.reinitialiser(0)
      etat.axes.derive.pid.reinitialiser(0)
      debugCycle(ETAPES.MAINTIEN, string.format(
        "dans les marges (%.2fm) : poussee horizontale coupee", distanceH))
    end

    -- En repli zone morte, l'avance ne se declenche que si le nez est
    -- grossierement dans la bonne direction : sinon on tourne d'abord.
    if etat.axes.avance.modeCourant == "zone_morte" then
      if math.abs(erreurCap) > config.pilotage.capMaxAvanceZoneMorte then
        commandes.avance = 0
      elseif commandes.avance < 0 and limites.marcheArriere <= 0 then
        commandes.avance = 0
      end
    end

    debugCycle(ETAPES.BOUCLE_VITESSE, string.format(
      "commandes : avance %.2f lateral %.2f vertical %.2f lacet %.2f",
      commandes.avance, commandes.lateral, commandes.vertical, commandes.lacet))

    local diagnostic = {
      distanceH = distanceH, distanceY = dy, resteRoute = resteRoute,
      ecartLateral = ecartLateral, erreurCap = erreurCap, capCible = capCible,
      vitesseAvanceCible = vitesseAvanceCible, vitesseAvanceMesure = vitesseAvanceMesure,
      vitesseLateraleCible = vitesseLateraleCible, vitesseLateraleMesure = vitesseLateraleMesure,
      vitesseVerticaleCible = vitesseVerticaleCible, tauxLacetCible = tauxLacetCible,
      facteurCap = facteurCap,
    }
    etat.diagnostics = diagnostic
    return commandes, diagnostic
  end

  --------------------------------------------------------------------------------
  -- 12d. MISSION : cibles, points de passage, arrivee, maintien
  --------------------------------------------------------------------------------

  -- Un vehicule ne peut corriger sa derive sans tourner que s'il possede une
  -- vraie propulsion laterale : cablage declare ET vitesse laterale non nulle.
  local lateralDisponible = config.vitesses.lateraleMax > 0
    and ((sorties.type == "injecte")
      or (((config.sorties.axes or {}).lateral or {}).mode or "aucun") ~= "aucun")

  if lateralDisponible and config.cap.source ~= "peripherique" then
    -- Sans capteur de cap, le cap est deduit de la route reellement suivie.
    -- Une poussee laterale fait deriver cette route par rapport au nez : le
    -- cap estime devient faux, et la boucle de lacet se met a chasser.
    journal.avert(ETAPES.ESTIMATION_CAP,
      "propulsion laterale active sans capteur de cap : le cap deduit de la route "
      .. "sera fausse par la derive. Installez un capteur (cap.source = "
      .. "'peripherique') ou desactivez l'axe lateral.")
  end

  --- Bascule le jeu de gains de tous les axes (croisiere <-> maintien).
  local function appliquerJeuGains(jeu)
    if etat.jeuGains == jeu then return end
    etat.jeuGains = jeu
    for _, axe in ipairs(AXES) do
      etat.axes[axe].pid.regler(config.gains[axe][jeu])
      etat.axes[axe].jeu = jeu
    end
    journal.info(ETAPES.BOUCLE_VITESSE, "jeu de gains actif : " .. jeu)
  end

  --- Normalise un point fourni par un programme appelant.
  local function normaliserPoint(point)
    if type(point) ~= "table" then error("point de passage invalide (table attendue)", 0) end
    if not (nombreValide(point.x) and nombreValide(point.y) and nombreValide(point.z)) then
      error("point de passage invalide : x, y et z doivent etre numeriques", 0)
    end
    return {
      x = point.x, y = point.y, z = point.z,
      type = point.type or "survol",     -- "survol" | "depot" | "atterrissage"
      cap  = nombreValide(point.cap) and normaliserAngle(point.cap) or nil,
      arret = point.arret and true or false,
      nom  = point.nom,
    }
  end

  --- Position que doit viser le CENTRE du vehicule pour qu'un depot ou un
  -- atterrissage tombe exactement sur le point demande.
  local function cibleCentreDe(point)
    if point.type == "depot" or point.type == "atterrissage" then
      local decalage = decalageVersMonde(config.decalageDepot, etat.cap,
        config.decalageDansRepereVehicule)
      return { x = point.x - decalage.x, y = point.y - decalage.y, z = point.z - decalage.z }
    end
    return { x = point.x, y = point.y, z = point.z }
  end

  --- Copie serialisable : les rappels du programme appelant ne survivent pas a
  -- un redemarrage, et textutils.serialise refuse les fonctions.
  local function sansFonctions(valeur)
    if type(valeur) ~= "table" then
      if type(valeur) == "function" then return nil end
      return valeur
    end
    local copie = {}
    for cle, sousValeur in pairs(valeur) do
      if type(sousValeur) ~= "function" and type(cle) ~= "function" then
        copie[cle] = sansFonctions(sousValeur)
      end
    end
    return copie
  end

  local function sauvegarderMission()
    if not config.mission.reprendreApresRedemarrage then return end
    local ok = pcall(function()
      local fichier = fs.open(config.mission.fichierEtat, "w")
      if not fichier then return end
      fichier.write(textutils.serialise({
        identifiant = config.identifiant,
        mode        = etat.mode,
        itineraire  = sansFonctions(etat.itineraire),
        index       = etat.index,
        options     = sansFonctions(etat.optionsMission),
        cibleMaintien = sansFonctions(etat.cibleMaintien),
      }))
      fichier.close()
    end)
    if not ok then
      journal.avert(ETAPES.PERSISTANCE, "etat de mission non sauvegarde")
    end
  end

  local function effacerMission()
    pcall(function()
      if fs.exists(config.mission.fichierEtat) then fs.delete(config.mission.fichierEtat) end
    end)
  end

  local function entrerMaintien(point, motif)
    -- On repart avec des regulateurs propres : l'integrale accumulee pendant
    -- le transit n'a plus rien a voir avec le maintien de position.
    for _, axe in ipairs(AXES) do etat.axes[axe].pid.reinitialiser(0) end
    etat.mode        = MODES.MAINTIEN
    etat.phase       = nil
    etat.cibleMaintien = point
    etat.depart      = nil
    etat.dansMarges  = 0
    etat.capArrivee  = etat.cap
    appliquerJeuGains("maintien")
    journal.info(ETAPES.MAINTIEN, string.format(
      "maintien de position sur X=%.1f Y=%.1f Z=%.1f (%s)",
      point.x, point.y, point.z, tostring(motif)))
    emettre("maintien", { point = point, motif = motif })
    sauvegarderMission()
  end

  local function entrerSecours(motif)
    if etat.mode == MODES.SECOURS then return end
    etat.modeAvantSecours = etat.mode
    etat.mode = MODES.SECOURS
    etat.anomalies = etat.anomalies + 1
    sorties.neutraliser()
    journal.erreur(ETAPES.SECOURS, string.format(
      "MODE SECOURS : %s - commandes neutralisees, le vehicule ne navigue plus a l'aveugle",
      tostring(motif)))
    emettre("anomalie", { motif = motif, mode = MODES.SECOURS,
      derniereePosition = etat.position and copierProfond(etat.position) or nil })
  end

  local function sortirSecours()
    local precedent = etat.modeAvantSecours
    etat.modeAvantSecours = nil
    reinitialiserRegulation(etat.position)
    journal.info(ETAPES.SECOURS, "sortie du mode secours : position de nouveau connue")
    emettre("anomalie", { motif = "gps_retabli", mode = "retabli" })

    if precedent == MODES.TRANSIT and etat.itineraire
       and config.mission.reprendreApresPerteGps then
      etat.mode   = MODES.TRANSIT
      etat.depart = copierProfond(etat.position)
      etat.dansMarges = 0
      journal.info(ETAPES.MISSION, "reprise de la mission interrompue")
    else
      entrerMaintien(copierProfond(etat.position), "reprise apres perte GPS")
    end
  end

  local function pointFranchi(estDernier)
    local point = etat.itineraire[etat.index]
    journal.info(ETAPES.ETAPE_FRANCHIE, string.format(
      "point %d/%d franchi%s : X=%.1f Y=%.1f Z=%.1f",
      etat.index, #etat.itineraire,
      point.nom and (" '" .. tostring(point.nom) .. "'") or "",
      point.x, point.y, point.z))
    emettre("etape", {
      index = etat.index, total = #etat.itineraire, point = copierProfond(point),
      position = copierProfond(etat.position), dernier = estDernier,
    })

    if estDernier then
      journal.info(ETAPES.ARRIVEE, string.format(
        "ARRIVEE sur la cible apres %.1fs dans les marges (ecart %.2fm, altitude %.2fm)",
        etat.dansMarges, etat.diagnostics.distanceH or 0, etat.diagnostics.distanceY or 0))
      emettre("arrivee", {
        point = copierProfond(point), position = copierProfond(etat.position),
        ecart = etat.diagnostics.distanceH, ecartAltitude = etat.diagnostics.distanceY,
      })
      if type(etat.optionsMission.surArrivee) == "function" then
        pcall(etat.optionsMission.surArrivee, copierProfond(point))
      end
      entrerMaintien(cibleCentreDe(point), "arrivee sur la cible")
      etat.itineraire = nil
      etat.index = 0
      effacerMission()
    else
      etat.index      = etat.index + 1
      etat.depart     = copierProfond(etat.position)
      etat.dansMarges = 0
      if type(etat.optionsMission.surEtape) == "function" then
        pcall(etat.optionsMission.surEtape, etat.index - 1, copierProfond(point))
      end
      sauvegarderMission()
    end
  end

  --- Determine la phase de vol du cycle courant.
  local function determinerPhase(distanceH, point, estDernier, altitudeTransit)
    if etat.transitHaute and etat.phase == PHASES.MONTEE then
      local marge = config.vitesses.margeAltitude
      if etat.position.y >= altitudeTransit - marge then
        journal.info(ETAPES.NAVIGATION, string.format(
          "altitude de croisiere atteinte (%.1f / %.1f) : debut du transit",
          etat.position.y, altitudeTransit))
        return PHASES.CROISIERE
      end
      return PHASES.MONTEE
    end
    if distanceH <= config.vitesses.distanceApproche and (estDernier or point.arret) then
      return estDernier and PHASES.FINALE or PHASES.APPROCHE
    end
    return PHASES.CROISIERE
  end

  --- Le vehicule est-il dans les marges du point courant ?
  local function dansLesMarges(diagnostic, point, estDernier)
    if not (estDernier or point.arret) then
      -- Point de passage intermediaire : on le valide au passage, sans
      -- exiger l'immobilite, sinon le vehicule s'arrete a chaque etape.
      return diagnostic.distanceH <= config.vitesses.rayonValidationEtape
    end
    local ok = diagnostic.distanceH <= config.tolerances.horizontale
      and math.abs(diagnostic.distanceY) <= config.tolerances.altitude
    if ok and point.cap then
      ok = math.abs(normaliserAngle(point.cap - etat.cap)) <= config.tolerances.cap
    end
    return ok
  end

  --------------------------------------------------------------------------------
  -- 12e. CYCLE DE VOL
  --------------------------------------------------------------------------------

  --- Execute un cycle complet : mesure, decision, guidage, commande.
  -- Peut etre appele directement par un programme qui gere sa propre boucle.
  function ap.pas()
    etat.cycles = etat.cycles + 1
    local dt, discontinuite = mesurerTemps()
    local positionConnue = mesurer(dt, discontinuite)

    ------------------------------------------------------------------ GPS perdu
    if not positionConnue then
      entrerSecours(string.format("aucune position GPS depuis %.1fs", etat.perteGps))
      sorties.neutraliser()
      return etat
    end
    if etat.mode == MODES.SECOURS then sortirSecours() end

    ----------------------------------------------------------------- acquisition
    if etat.mode == MODES.ACQUISITION then
      if etat.lecturesValides < config.gps.lecturesAcquisition then
        sorties.neutraliser()
        return etat
      end
      journal.info(ETAPES.ACQUISITION, string.format(
        "position acquise (%d lectures) : X=%.1f Y=%.1f Z=%.1f cap %.1f (%s) - "
        .. "le vehicule peut bouger",
        etat.lecturesValides, etat.position.x, etat.position.y, etat.position.z,
        etat.cap, etat.sourceCap))
      emettre("acquisition", { position = copierProfond(etat.position), cap = etat.cap })
      if etat.missionEnAttente then
        local mission = etat.missionEnAttente
        etat.missionEnAttente = nil
        journal.info(ETAPES.MISSION, "reprise de la mission sauvegardee avant redemarrage")
        ap.suivreItineraire(mission.itineraire, mission.options, mission.index)
      elseif etat.cibleMaintienEnAttente then
        entrerMaintien(etat.cibleMaintienEnAttente, "reprise apres redemarrage")
        etat.cibleMaintienEnAttente = nil
      elseif etat.maintienApresAcquisition then
        etat.maintienApresAcquisition = nil
        entrerMaintien(copierProfond(etat.position), "maintien demande avant acquisition")
      else
        etat.mode = MODES.ARRET
        sorties.neutraliser()
        return etat
      end
    end

    ----------------------------------------------------------------------- arret
    if etat.mode == MODES.ARRET then
      sorties.neutraliser()
      return etat
    end

    ------------------------------------------------------- cible et limites du cycle
    local cible, limites, point, estDernier

    if etat.mode == MODES.TRANSIT then
      point      = etat.itineraire[etat.index]
      estDernier = etat.index >= #etat.itineraire
      local centre = cibleCentreDe(point)
      local distanceH = normeHorizontale(centre.x - etat.position.x, centre.z - etat.position.z)
      local altitudeTransit = etat.optionsMission.altitudeCroisiere
        or config.vitesses.altitudeCroisiere

      local phase = determinerPhase(distanceH, point, estDernier, altitudeTransit)
      if phase ~= etat.phase then
        journal.info(ETAPES.NAVIGATION, string.format(
          "phase %s -> %s (point %d/%d, distance %.1fm)",
          tostring(etat.phase), phase, etat.index, #etat.itineraire, distanceH))
        emettre("phase", { phase = phase, index = etat.index })
        etat.phase = phase
      end

      cible = { x = centre.x, y = centre.y, z = centre.z }
      if etat.transitHaute and config.mission.respecterAltitudeCroisiere
         and (phase == PHASES.MONTEE or phase == PHASES.CROISIERE) then
        -- On ne redescend qu'a l'approche : l'altitude de croisiere sert de
        -- plancher de securite pendant tout le transit.
        cible.y = math.max(centre.y, altitudeTransit)
      end

      local vitesseMax = config.vitesses.croisiere
      if phase == PHASES.MONTEE then
        vitesseMax = config.vitesses.avanceEnMontee
      elseif phase == PHASES.APPROCHE or phase == PHASES.FINALE then
        vitesseMax = config.vitesses.approche
      end
      if nombreValide(etat.optionsMission.vitesseMax) then
        vitesseMax = math.min(vitesseMax, etat.optionsMission.vitesseMax)
      end

      local capImpose = nil
      if phase == PHASES.FINALE and point.cap
         and distanceH <= config.vitesses.distanceApproche * 0.4 then
        capImpose = point.cap
      end

      limites = {
        vitesseMax       = vitesseMax,
        vitesseVerticale = config.vitesses.verticaleMax,
        vitesseLaterale  = config.vitesses.lateraleMax,
        tauxVirage       = config.vitesses.tauxVirageMax,
        marcheArriere    = config.vitesses.marcheArriere,
        capImpose        = capImpose,
      }
      appliquerJeuGains("croisiere")

    else -- MODES.MAINTIEN
      cible = etat.cibleMaintien
      local facteur = config.maintien.facteurVitesse
      local capImpose = nil
      local reglageCap = config.maintien.cap
      if nombreValide(reglageCap) then
        capImpose = normaliserAngle(reglageCap)
      elseif reglageCap == "conserver" then
        capImpose = etat.capArrivee
      elseif reglageCap == "vers_cible" then
        capImpose = nil
      else
        -- "auto" : le vehicule ne garde son cap d'arrivee que s'il peut
        -- vraiment corriger sans tourner. Sinon il pointe le nez vers la cible.
        local dxCible = cible.x - etat.position.x
        local dzCible = cible.z - etat.position.z
        local ecart = normeHorizontale(dxCible, dzCible)
        if ecart <= config.tolerances.horizontale then
          capImpose = etat.capArrivee
        elseif lateralDisponible then
          -- Avec propulsion laterale, le cap est conserve tant que la cible
          -- n'est pas DERRIERE : sans marche arriere, un vehicule qui derive
          -- vers l'arriere ne pourrait jamais revenir sans faire demi-tour.
          local avant = vecteurAvant(etat.capArrivee or etat.cap)
          local composanteAvant = dxCible * avant.x + dzCible * avant.z
          if composanteAvant >= 0 or config.vitesses.marcheArriere > 0 then
            capImpose = etat.capArrivee
          end
        end
      end
      if etat.capMaintienImpose then capImpose = etat.capMaintienImpose end

      limites = {
        vitesseMax       = config.vitesses.approche * facteur,
        vitesseVerticale = config.vitesses.verticaleMax * facteur,
        vitesseLaterale  = config.vitesses.lateraleMax * facteur,
        tauxVirage       = config.vitesses.tauxVirageMax * facteur,
        marcheArriere    = config.vitesses.marcheArriere * facteur,
        capImpose        = capImpose,
        arretDansMarges  = config.maintien.arretDansMarges,
      }
      appliquerJeuGains("maintien")
    end

    ------------------------------------------------------------------- guidage
    local commandes, diagnostic = guider(cible, limites, dt)
    etat.commandes = commandes
    etat.cibleCentre = cible
    sorties.appliquer(commandes)

    ------------------------------------------------------- arrivee / franchissement
    if etat.mode == MODES.TRANSIT then
      if dansLesMarges(diagnostic, point, estDernier) then
        -- Le decompte demarre a l'instant de l'entree dans les marges : on ne
        -- credite pas d'emblee un cycle entier qui s'est passe dehors.
        if etat.dansMarges <= 0 then
          etat.dansMarges = 1e-6
        else
          etat.dansMarges = etat.dansMarges + dt
        end
      else
        if etat.dansMarges > 0 then
          journal.debug(ETAPES.ARRIVEE, string.format(
            "sortie des marges apres %.1fs : compteur d'arrivee remis a zero", etat.dansMarges))
        end
        etat.dansMarges = 0
      end
      local dureeExigee = (estDernier or point.arret) and config.tolerances.dureeArrivee or 0
      if etat.dansMarges > 0 and etat.dansMarges >= dureeExigee then
        pointFranchi(estDernier)
      end
    else
      debugCycle(ETAPES.MAINTIEN, string.format(
        "derive %.2fm / altitude %.2fm / cap %.1f",
        diagnostic.distanceH, diagnostic.distanceY, etat.cap))
    end

    return etat
  end

  --------------------------------------------------------------------------------
  -- 13. INTERFACE PUBLIQUE
  --------------------------------------------------------------------------------

  --- Prepare l'autopilote : lit la position AVANT d'autoriser le moindre
  -- mouvement, et recharge une eventuelle mission interrompue par un plantage.
  function ap.initialiser()
    sorties.neutraliser()
    etat.mode = MODES.ACQUISITION
    etat.lecturesValides = 0
    journal.info(ETAPES.ACQUISITION,
      "acquisition de la position : aucune commande moteur ne sera emise avant "
      .. config.gps.lecturesAcquisition .. " lectures GPS valides")

    if config.mission.reprendreApresRedemarrage and fs.exists(config.mission.fichierEtat) then
      local ok, sauvegarde = pcall(function()
        local fichier = fs.open(config.mission.fichierEtat, "r")
        local contenu = fichier.readAll()
        fichier.close()
        return textutils.unserialise(contenu)
      end)
      if ok and type(sauvegarde) == "table" and sauvegarde.identifiant == config.identifiant then
        if type(sauvegarde.itineraire) == "table" and #sauvegarde.itineraire > 0 then
          etat.missionEnAttente = {
            itineraire = sauvegarde.itineraire,
            options    = sauvegarde.options or {},
            index      = sauvegarde.index or 1,
          }
          journal.avert(ETAPES.MISSION, string.format(
            "mission interrompue retrouvee (point %d/%d) : elle reprendra APRES "
            .. "acquisition de la position", sauvegarde.index or 1, #sauvegarde.itineraire))
        elseif type(sauvegarde.cibleMaintien) == "table" then
          etat.cibleMaintienEnAttente = sauvegarde.cibleMaintien
        end
      else
        journal.avert(ETAPES.MISSION, "etat de mission illisible ou etranger : ignore")
      end
    end
    return ap
  end

  --- Rejoindre un point unique.
  -- @param point   { x, y, z, type = "survol"|"depot"|"atterrissage", cap = degres }
  -- @param options { vitesseMax, altitudeCroisiere, transitHaute, surArrivee }
  function ap.allerA(point, optionsMission)
    return ap.suivreItineraire({ point }, optionsMission)
  end

  --- Enchainer une liste de points de passage.
  function ap.suivreItineraire(points, optionsMission, indexDepart)
    if type(points) ~= "table" or #points == 0 then
      error("itineraire vide : au moins un point de passage est attendu", 0)
    end
    local itineraire = {}
    for i, point in ipairs(points) do itineraire[i] = normaliserPoint(point) end

    etat.itineraire     = itineraire
    etat.index          = math.max(1, math.min(indexDepart or 1, #itineraire))
    etat.optionsMission = optionsMission or {}
    etat.dansMarges     = 0
    etat.capMaintienImpose = nil
    etat.maintienApresAcquisition = nil
    etat.depart         = etat.position and copierProfond(etat.position) or nil
    etat.mode           = MODES.TRANSIT
    appliquerJeuGains("croisiere")

    -- Transit haute altitude : seulement si la mission est assez longue pour
    -- que monter en croisiere ait un sens.
    local longueur = 0
    local precedent = etat.position
    for i = etat.index, #itineraire do
      if precedent then
        longueur = longueur + normeHorizontale(itineraire[i].x - precedent.x,
          itineraire[i].z - precedent.z)
      end
      precedent = itineraire[i]
    end
    etat.transitHaute = config.mission.monteeAvantTransit
      and etat.optionsMission.transitHaute ~= false
      and longueur >= config.vitesses.distanceMinCroisiere
    etat.phase = etat.transitHaute and PHASES.MONTEE or PHASES.CROISIERE

    local destination = itineraire[#itineraire]
    journal.info(ETAPES.MISSION, string.format(
      "mission acceptee : %d point(s), %.0fm au total, destination X=%.1f Y=%.1f Z=%.1f "
      .. "(%s) - transit %s",
      #itineraire, longueur, destination.x, destination.y, destination.z, destination.type,
      etat.transitHaute and ("a l'altitude de croisiere "
        .. tostring(etat.optionsMission.altitudeCroisiere or config.vitesses.altitudeCroisiere))
        or "direct"))
    emettre("mission", { itineraire = copierProfond(itineraire), index = etat.index })
    sauvegarderMission()
    return ap
  end

  --- Tenir la position : le point courant si aucun n'est precise.
  function ap.maintenirPosition(point, capImpose)
    local cible = point and normaliserPoint(point) or nil
    etat.itineraire = nil
    etat.index = 0
    etat.capMaintienImpose = nombreValide(capImpose) and normaliserAngle(capImpose) or nil
    if cible then
      entrerMaintien(cibleCentreDe(cible), "maintien demande par le programme appelant")
    elseif etat.position then
      entrerMaintien(copierProfond(etat.position), "maintien sur la position courante")
    else
      etat.maintienApresAcquisition = true
      etat.mode = MODES.ACQUISITION
      journal.avert(ETAPES.MAINTIEN,
        "maintien demande avant toute position connue : acquisition d'abord, "
        .. "puis maintien sur la position acquise")
    end
    return ap
  end

  --- Arret : commandes neutralisees, plus aucune mission.
  function ap.arreter(motif)
    etat.mode = MODES.ARRET
    etat.phase = nil
    etat.itineraire = nil
    etat.index = 0
    etat.dansMarges = 0
    sorties.neutraliser()
    for _, axe in ipairs(AXES) do etat.axes[axe].pid.reinitialiser(0) end
    effacerMission()
    journal.info(ETAPES.ARRET, "autopilote arrete" .. (motif and (" : " .. tostring(motif)) or ""))
    emettre("arret", { motif = motif })
    return ap
  end

  --- Distingue l'arret manuel (Ctrl+T) d'une erreur ordinaire.
  local function estTerminate(err)
    if type(err) ~= "string" then return false end
    return err == "Terminated" or err:match("^Terminated\n") ~= nil
  end

  --- Boucle de vol autonome. A lancer en parallele du programme de mission :
  --     parallel.waitForAny(ap.executer, mission)
  -- Toute erreur d'un cycle est capturee, journalisee et neutralisee : la
  -- boucle se relance seule au lieu de laisser le vehicule sans commande.
  function ap.executer()
    ap.actif = true
    if etat.mode == MODES.ARRET and etat.lecturesValides == 0 then ap.initialiser() end
    journal.info(ETAPES.BOUCLE_PRINCIPALE, string.format(
      "boucle de vol demarree (periode %.2fs, mode de pilotage '%s')",
      config.gps.intervalle, config.pilotage.mode))

    local echecs = 0
    while ap.actif do
      local ok, err = xpcall(ap.pas, gestionnaireErreur)
      if ok then
        echecs = 0
      else
        if estTerminate(err) then
          pcall(sorties.neutraliser)
          error(err, 0)
        end
        echecs = echecs + 1
        pcall(sorties.neutraliser)
        journal.critique(ETAPES.BOUCLE_PRINCIPALE, string.format(
          "cycle interrompu (%d d'affilee) : %s", echecs, tostring(err)))
        emettre("anomalie", { motif = "erreur_cycle", detail = tostring(err), echecs = echecs })
        if echecs >= 5 then
          entrerSecours("erreurs repetees dans la boucle de vol")
        end
        sleep(math.min(0.5 * echecs, 3))
      end
      sleep(config.gps.intervalle)
    end
    journal.info(ETAPES.BOUCLE_PRINCIPALE, "boucle de vol terminee")
  end

  --- Demande l'arret de la boucle ap.executer().
  function ap.stopper()
    ap.actif = false
    return ap
  end

  --- Instantane complet, destine aux programmes appelants et aux interfaces.
  function ap.etat()
    local diagnostic = etat.diagnostics or {}
    return {
      identifiant = config.identifiant,
      nom         = config.nom,
      mode        = etat.mode,
      phase       = etat.phase,
      position    = etat.position and copierProfond(etat.position) or nil,
      positionGps = etat.positionGps and copierProfond(etat.positionGps) or nil,
      vitesse     = copierProfond(etat.vitesse),
      vitesseSol  = normeHorizontale(etat.vitesse.x, etat.vitesse.z),
      cap         = etat.cap,
      sourceCap   = etat.sourceCap,
      tauxLacet   = etat.tauxLacet,
      cible       = etat.cibleCentre and copierProfond(etat.cibleCentre) or nil,
      point       = etat.itineraire and copierProfond(etat.itineraire[etat.index]) or nil,
      index       = etat.index,
      total       = etat.itineraire and #etat.itineraire or 0,
      commandes   = copierProfond(etat.commandes),
      distance    = diagnostic.distanceH,
      ecartAltitude = diagnostic.distanceY,
      ecartLateral  = diagnostic.ecartLateral,
      erreurCap     = diagnostic.erreurCap,
      diagnostics   = copierProfond(diagnostic),
      dansMarges  = etat.dansMarges,
      perteGps    = etat.perteGps,
      cycles      = etat.cycles,
      anomalies   = etat.anomalies,
      dt          = etat.dt,
      modesAxes   = (function()
        local m = {}
        for _, axe in ipairs(AXES) do m[axe] = etat.axes[axe].modeCourant end
        return m
      end)(),
      jeuGains    = etat.jeuGains,
      ravitaillement = copierProfond(config.ravitaillement),
    }
  end

  function ap.estArrive()
    return etat.mode == MODES.MAINTIEN and etat.itineraire == nil
  end

  --- Attend l'arrivee (necessite que ap.executer() tourne en parallele).
  -- @return true | false, motif
  function ap.attendreArrivee(delai)
    if ap.estArrive() then return true end
    local minuteur = delai and os.startTimer(delai) or nil
    while true do
      local evenement = table.pack(os.pullEvent())
      if evenement[1] == "autopilote" and evenement[2] == config.identifiant then
        if evenement[3] == "arrivee" then return true, evenement[4] end
      elseif evenement[1] == "timer" and minuteur and evenement[2] == minuteur then
        return false, "delai depasse"
      end
    end
  end

  --- Force le mode de pilotage : "auto" | "pid" | "zone_morte".
  function ap.definirMode(mode)
    local modes = { auto = true, pid = true, zone_morte = true }
    if not modes[tostring(mode)] then
      error("mode de pilotage inconnu : " .. tostring(mode), 0)
    end
    config.pilotage.mode = mode
    journal.avert(ETAPES.BASCULE_MODE, "mode de pilotage force par le controleur : " .. mode)
    -- Application immediate a tous les axes : un mode force ne doit pas
    -- attendre le prochain passage dans la boucle de l'axe concerne (un axe
    -- neutralise, comme le lacet sans cap fiable, ne serait jamais bascule).
    if mode ~= "auto" then
      for _, axe in ipairs(AXES) do
        basculerAxe(etat.axes[axe], mode, "mode force par le controleur")
      end
    end
    emettre("mode", { mode = mode, force = true })
    return ap
  end

  --- Reglage a chaud des gains d'un axe (menu de reglage en vol).
  -- @param axe "altitude" | "cap" | "avance" | "derive"
  -- @param jeu "croisiere" | "maintien" | "position"
  function ap.reglerGains(axe, jeu, gains)
    if not config.gains[axe] then error("axe inconnu : " .. tostring(axe), 0) end
    if jeu == "position" then
      if nombreValide(gains.kp) then config.gains[axe].position.kp = gains.kp end
    else
      if not config.gains[axe][jeu] then error("jeu de gains inconnu : " .. tostring(jeu), 0) end
      for _, cle in ipairs({ "kp", "ki", "kd", "integraleMax", "penteMax", "filtreDerivee" }) do
        if nombreValide(gains[cle]) then config.gains[axe][jeu][cle] = gains[cle] end
      end
      if etat.jeuGains == jeu then etat.axes[axe].pid.regler(config.gains[axe][jeu]) end
    end
    journal.info(ETAPES.BOUCLE_VITESSE, string.format(
      "gains modifies a chaud : axe %s / jeu %s -> kp=%.3f ki=%.3f kd=%.3f",
      axe, jeu, config.gains[axe][jeu] and config.gains[axe][jeu].kp or config.gains[axe].position.kp,
      config.gains[axe][jeu] and config.gains[axe][jeu].ki or 0,
      config.gains[axe][jeu] and config.gains[axe][jeu].kd or 0))
    return ap
  end

  --- Historique glissant d'un axe (pour tracer la reponse dans l'interface).
  function ap.historique(axe)
    return etat.axes[axe] and etat.axes[axe].historique or {}
  end

  --- Enregistre la configuration courante (gains regles en vol compris).
  function ap.sauvegarderConfig(chemin)
    chemin = chemin or ap.cheminConfig
    local ok, err = pcall(function()
      local fichier = fs.open(chemin, "w")
      if not fichier then error("ecriture impossible : " .. chemin, 0) end
      fichier.write(autopilote.serialiserConfig(config))
      fichier.close()
    end)
    if not ok then
      journal.erreur(ETAPES.CHARGEMENT_CONFIG, "sauvegarde impossible : " .. tostring(err))
      return false, tostring(err)
    end
    journal.info(ETAPES.CHARGEMENT_CONFIG, "configuration enregistree dans " .. chemin)
    return true
  end

  --- Position de ravitaillement (constante de reseau, non modifiable).
  function ap.ravitaillement()
    return copierProfond(config.ravitaillement)
  end

  --- Rejoint la station de ravitaillement en mode atterrissage.
  function ap.rejoindreRavitaillement(optionsMission)
    local station = config.ravitaillement
    journal.info(ETAPES.RAVITAILLEMENT, "route vers la station de ravitaillement " .. station.nom)
    return ap.allerA({
      x = station.position.x, y = station.position.y, z = station.position.z,
      type = "atterrissage", cap = station.capFinal, nom = station.nom,
    }, optionsMission)
  end

  --- Impose le cap courant (utile si le vehicule dispose d'un capteur maison).
  function ap.forcerCap(valeur)
    capteurCap.forcer(valeur)
    return ap
  end

  ap.MODES  = MODES
  ap.PHASES = PHASES
  ap.AXES   = AXES
  return ap
end

--------------------------------------------------------------------------------
-- 14. ECRITURE DE LA CONFIGURATION
--     L'interface de reglage et le menu de reglage en vol reecrivent le
--     fichier du vehicule. On ne se contente pas d'un textutils.serialise :
--     le fichier doit rester lisible et editable a la main, donc il est
--     regenere avec ses sections et ses commentaires.
--------------------------------------------------------------------------------

local ORDRE_CLES = {
  "nom", "identifiant", "decalageGps", "decalageDepot", "decalageDansRepereVehicule",
  "gabarit", "tolerances", "vitesses", "gains", "pilotage", "maintien",
  "gps", "cap", "sorties", "mission", "journal",
  "x", "y", "z", "longueur", "largeur", "hauteur",
  "position", "croisiere", "maintien", "kp", "ki", "kd",
}

local COMMENTAIRES = {
  nom            = "Nom lisible du vehicule",
  identifiant    = "Identifiant unique sur le serveur",
  decalageGps    = "Decalage ordinateur -> centre du vehicule (x=tribord, y=haut, z=avant)",
  decalageDepot  = "Decalage centre -> point de depot / d'atterrissage",
  gabarit        = "Dimensions du vehicule, en blocs",
  tolerances     = "Marges de tolerance (zone morte) et duree d'arrivee",
  vitesses       = "Vitesses de vol, altitude de croisiere et distances",
  gains          = "Gains PID : position (boucle externe), croisiere et maintien (boucle interne)",
  pilotage       = "Mode de pilotage, detection d'instabilite, repli zone morte",
  maintien       = "Comportement en maintien de position",
  gps            = "Lecture GPS, filtrage et tolerance de perte de signal",
  cap            = "Source du cap : capteur dedie ou route suivie",
  sorties        = "Cablage des sorties moteur, axe par axe",
  mission        = "Reprise apres redemarrage et regles de transit",
  journal        = "Journalisation et historique de reglage",
}

local function formaterNombre(valeur)
  if valeur == math.floor(valeur) and math.abs(valeur) < 1e15 then
    return string.format("%d", valeur)
  end
  local texte = string.format("%.6f", valeur)
  texte = texte:gsub("0+$", "")
  texte = texte:gsub("%.$", "")
  -- Garde-fou : une configuration relue doit rendre exactement la meme valeur.
  -- Un gain de 0.000004 ne doit pas devenir 0 en passant par le fichier.
  if tonumber(texte) ~= valeur then texte = string.format("%.14g", valeur) end
  return texte
end

local function cleValide(cle)
  return type(cle) == "string" and cle:match("^[%a_][%w_]*$") ~= nil
end

local function serialiserValeur(valeur, indentation)
  local typeValeur = type(valeur)
  if typeValeur == "number" then return formaterNombre(valeur) end
  if typeValeur == "string" then return string.format("%q", valeur) end
  if typeValeur == "boolean" then return tostring(valeur) end
  if typeValeur ~= "table" then return "nil" end

  -- Tableau simple : rendu sur une ligne.
  local estTableau = #valeur > 0
  if estTableau then
    local morceaux = {}
    for _, sousValeur in ipairs(valeur) do
      morceaux[#morceaux + 1] = serialiserValeur(sousValeur, indentation .. "  ")
    end
    return "{ " .. table.concat(morceaux, ", ") .. " }"
  end

  local cles, rang = {}, {}
  for i, cle in ipairs(ORDRE_CLES) do if rang[cle] == nil then rang[cle] = i end end
  for cle in pairs(valeur) do cles[#cles + 1] = cle end
  table.sort(cles, function(a, b)
    local ra, rb = rang[a] or 999, rang[b] or 999
    if ra ~= rb then return ra < rb end
    return tostring(a) < tostring(b)
  end)

  if #cles == 0 then return "{}" end

  local lignes = { "{" }
  for _, cle in ipairs(cles) do
    local texteCle = cleValide(cle) and (cle .. " = ") or ("[" .. string.format("%q", tostring(cle)) .. "] = ")
    lignes[#lignes + 1] = indentation .. "  " .. texteCle
      .. serialiserValeur(valeur[cle], indentation .. "  ") .. ","
  end
  lignes[#lignes + 1] = indentation .. "}"
  return table.concat(lignes, "\n")
end

--- Rend la configuration sous forme de fichier Lua complet et commente.
function autopilote.serialiserConfig(config)
  local aEcrire = copierProfond(config)
  -- La station de ravitaillement est une constante de reseau : elle ne doit
  -- jamais etre recopiee dans le fichier du vehicule.
  aEcrire.ravitaillement = nil

  local lignes = {
    "--[[--------------------------------------------------------------------------",
    "  CONFIGURATION VEHICULE - AUTOPILOTE FRENCHNET",
    "  ------------------------------------------------------------------------",
    "  Fichier genere par l'interface de reglage (autopilote/interface.lua).",
    "  Editable a la main : il suffit qu'il se termine par 'return { ... }'.",
    "",
    "  La position de ravitaillement N'EST PAS ici : c'est une constante de",
    "  reseau, verrouillee, definie dans autopilote/ravitaillement.lua.",
    "----------------------------------------------------------------------------]]",
    "",
    "return {",
  }

  local cles, rang = {}, {}
  for i, cle in ipairs(ORDRE_CLES) do if rang[cle] == nil then rang[cle] = i end end
  for cle in pairs(aEcrire) do cles[#cles + 1] = cle end
  table.sort(cles, function(a, b)
    local ra, rb = rang[a] or 999, rang[b] or 999
    if ra ~= rb then return ra < rb end
    return tostring(a) < tostring(b)
  end)

  for _, cle in ipairs(cles) do
    if COMMENTAIRES[cle] then
      lignes[#lignes + 1] = ""
      lignes[#lignes + 1] = "  -- " .. COMMENTAIRES[cle]
    end
    lignes[#lignes + 1] = "  " .. cle .. " = " .. serialiserValeur(aEcrire[cle], "  ") .. ","
  end

  lignes[#lignes + 1] = "}"
  lignes[#lignes + 1] = ""
  return table.concat(lignes, "\n")
end

--------------------------------------------------------------------------------
-- 15. FONCTIONS DE MODULE
--------------------------------------------------------------------------------

--- Charge et complete une configuration vehicule sans creer d'autopilote.
-- Utilise par l'interface de reglage, qui doit pouvoir tourner au sol, sans
-- GPS et sans moteurs.
function autopilote.chargerConfiguration(chemin, cheminRavitaillement)
  local brute = chargerTableLua(chemin or CHEMIN_CONFIG_DEFAUT, "configuration vehicule")
  local config = fusionner(DEFAUTS, brute)
  local ok, ravitaillement = pcall(chargerRavitaillement,
    cheminRavitaillement or CHEMIN_RAVITAILLEMENT)
  config.ravitaillement = ok and ravitaillement or nil
  pcall(completerGains, config)
  return config, (not ok) and tostring(ravitaillement) or nil
end

--- Valide une configuration deja chargee. Renvoie true, ou false + anomalies.
function autopilote.verifierConfiguration(config)
  local ok, err = pcall(validerConfiguration, config)
  if ok then return true end
  return false, tostring(err)
end

--- Couche de sorties moteur seule, sans autopilote ni GPS.
-- Utilisee par l'outil de cablage : il pilote le vehicule a la main en
-- passant par le meme code que le vol, donc ce qu'il verifie est vrai.
function autopilote.creerSorties(config, journal, commandes)
  return creerSorties(config, journal, commandes)
end

autopilote.CHEMIN_CONFIG_DEFAUT  = CHEMIN_CONFIG_DEFAUT
autopilote.CHEMIN_RAVITAILLEMENT = CHEMIN_RAVITAILLEMENT

--- Rouages internes, exposes pour les bancs d'essai et les outils de reglage.
autopilote.interne = {
  Pid = Pid, Filtre = Filtre, ZoneMorte = ZoneMorte, Detecteur = Detecteur,
  normaliserAngle = normaliserAngle, capVers = capVers,
  vecteurAvant = vecteurAvant, vecteurTribord = vecteurTribord,
  decalageVersMonde = decalageVersMonde, normeHorizontale = normeHorizontale,
  borner = borner, signe = signe, fusionner = fusionner, lire = lire, ecrire = ecrire,
  filtreVecteur = filtreVecteur, chargerTableLua = chargerTableLua,
  DEFAUTS = DEFAUTS, DEFAUTS_PID = DEFAUTS_PID, REQUIS = REQUIS,
}

return autopilote
