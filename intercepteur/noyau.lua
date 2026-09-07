--[[----------------------------------------------------------------------------
  FRENCHNET / AERONAUTICS WARFARE - Noyau commun du systeme embarque intercepteur
  --------------------------------------------------------------------------
  Role : briques partagees par tous les modules du navire intercepteur.
           - nomenclature des ETAPES (reprise telle quelle dans le journal) ;
           - journal au MEME format que balise.lua ;
           - execution protegee (proteger / exigerEtape) ;
           - mathematiques vectorielles et relevements "horaires" ;
           - chargement d'un fichier de configuration Lua.

  Ce module ne connait NI les zones, NI les classes Charlie/Bravo/Alpha/Romeo,
  NI le systeme de defense au sol. Il est volontairement generique.

  NOTE SUR LES ACCENTS : les chaines affichees et journalisees sont sans
  accents (terminal CC: Tweaked oriente octet). Les commentaires du code, eux,
  sont rediges normalement.

  Chargement : ce fichier est un module. Il recoit le repertoire du programme
  en premier argument de chunk :
      local REPERTOIRE = ...
--------------------------------------------------------------------------------]]

local REPERTOIRE = ... or ""

local M = {}

M.VERSION = "1.0.0"

--------------------------------------------------------------------------------
-- 1. NOMENCLATURE DES ETAPES
--    Chaque etape porte un nom explicite : il est repris tel quel dans le
--    journal, ce qui permet de localiser instantanement un comportement
--    anormal apres coup.
--------------------------------------------------------------------------------

M.ETAPES = {
  -- cycle de vie
  DEMARRAGE               = "demarrage du superviseur",
  CHARGEMENT_CONFIG       = "chargement de la configuration",
  VALIDATION_CONFIG       = "validation de la configuration",
  INIT_JOURNAL            = "initialisation du journal",
  CHARGEMENT_MODULE       = "chargement d'un module embarque",
  ARRET                   = "arret du programme",
  BOUCLE_PRINCIPALE       = "boucle principale (parallele)",

  -- liaison avec le systeme au sol
  DETECTION_MODEM         = "detection du modem",
  OUVERTURE_REDNET        = "ouverture rednet",
  RECEPTION_ORDRE         = "reception d'un ordre du sol",
  ORDRE_REJETE            = "rejet d'un ordre non conforme",
  ACCUSE_RECEPTION        = "accuse de reception vers le sol",

  -- autopilote (module standardise externe)
  LIAISON_AUTOPILOTE      = "liaison avec le module d'autopilote",
  COMMANDE_AUTOPILOTE     = "commande envoyee a l'autopilote",
  MODE_AUTOPILOTE         = "changement de mode de l'autopilote",

  -- radar embarque
  DETECTION_RADAR         = "detection du radar embarque",
  PISTAGE_RADAR           = "pistage radar de la cible",
  PERTE_CONTACT           = "perte de contact radar",
  REACQUISITION           = "reacquisition de la cible",

  -- interception
  CALCUL_INTERCEPTION     = "calcul de trajectoire d'interception",
  ENTREE_POSITION_ATTAQUE = "entree en position d'attaque",
  SORTIE_POSITION_ATTAQUE = "sortie de la position d'attaque",
  MANOEUVRE_ARC           = "manoeuvre d'orbite / zigzag dans l'arc arriere",
  ASSERVISSEMENT_VITESSE  = "asservissement de vitesse sur la cible",

  -- armement
  DETECTION_ARME          = "detection de l'arme embarquee",
  SOLUTION_TIR            = "calcul de la solution de tir",
  TIR                     = "tir sur la cible",
  ARME_SILENCE            = "cessez-le-feu",

  -- survie et fin de mission
  DETECTION_DEGAT         = "detection de degat",
  MANOEUVRE_EVASION       = "manoeuvre d'evasion",
  FIN_EVASION             = "fin de la manoeuvre d'evasion",
  CONFIRMATION_DESTRUCTION= "confirmation de destruction de la cible",
  RETOUR_BASE             = "retour a la base",
  POINT_RETOUR            = "passage d'un point de retour",
  REARMEMENT              = "attente de rearmement manuel",

  -- supervision
  SURVEILLANCE            = "surveillance embarquee",
  TELEMETRIE              = "telemetrie du navire",
  ROTATION_JOURNAL        = "rotation du fichier journal",
}

--------------------------------------------------------------------------------
-- 2. OUTILS DE BASE
--------------------------------------------------------------------------------

--- Vrai si v est un nombre exploitable (ni NaN, ni infini).
function M.nombreValide(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function M.horodatage()
  local ok, texte = pcall(function()
    return os.date("!%Y-%m-%d %H:%M:%S", math.floor(os.epoch("utc") / 1000))
  end)
  if ok and texte then return texte end
  -- Repli si os.epoch / os.date sont indisponibles : temps du monde Minecraft.
  local okMonde, resultat = pcall(function()
    return string.format("jour %d %s", os.day(), textutils.formatTime(os.time(), true))
  end)
  return okMonde and resultat or "horodatage indisponible"
end

--- Horloge monotone en secondes (os.clock est suffisant sous CC: Tweaked).
function M.maintenant()
  return os.clock()
end

function M.borner(v, mini, maxi)
  if v < mini then return mini end
  if v > maxi then return maxi end
  return v
end

--- Resout la premiere methode existante parmi une liste de noms candidats.
-- Sert a s'adapter aux variations d'API des peripheriques (Create Radars,
-- Create Big Cannons) et du module d'autopilote, sans figer un seul nom.
-- @return fonction, nomRetenu | nil
function M.resoudreMethode(objet, candidats)
  if type(objet) ~= "table" then return nil end
  for _, nom in ipairs(candidats) do
    if type(objet[nom]) == "function" then
      return objet[nom], nom
    end
  end
  return nil
end

--------------------------------------------------------------------------------
-- 3. MATHEMATIQUES VECTORIELLES
--    Repere Minecraft : X est vers l'est, Z vers le sud, Y vers le haut.
--------------------------------------------------------------------------------

local V = {}
M.vec = V

function V.creer(x, y, z) return { x = x or 0, y = y or 0, z = z or 0 } end
function V.copier(a)      return { x = a.x, y = a.y, z = a.z } end
function V.ajouter(a, b)  return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z } end
function V.soustraire(a, b) return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z } end
function V.multiplier(a, k) return { x = a.x * k, y = a.y * k, z = a.z * k } end
function V.horizontal(a)  return { x = a.x, y = 0, z = a.z } end

function V.norme(a)
  return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
end

function V.normeHorizontale(a)
  return math.sqrt(a.x * a.x + a.z * a.z)
end

function V.distance(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function V.produitScalaire(a, b)
  return a.x * b.x + a.y * b.y + a.z * b.z
end

--- Normalise le vecteur. Renvoie nil si le vecteur est trop court pour porter
-- une direction fiable (bruit de mesure).
function V.normaliser(a, longueurMini)
  local n = V.norme(a)
  if n < (longueurMini or 1e-6) then return nil end
  return { x = a.x / n, y = a.y / n, z = a.z / n }
end

function V.valide(a)
  return type(a) == "table" and M.nombreValide(a.x) and M.nombreValide(a.y)
    and M.nombreValide(a.z)
end

function V.format(a)
  if not V.valide(a) then return "(invalide)" end
  return string.format("X=%.1f Y=%.1f Z=%.1f", a.x, a.y, a.z)
end

--------------------------------------------------------------------------------
-- 4. RELEVEMENTS "HORAIRES"
--    Convention retenue, verifiee par les tests :
--      relevement 0 deg   = 12 heures = droit devant (dans le sens du cap) ;
--      relevement 90 deg  =  3 heures = a tribord (a droite du pilote) ;
--      relevement 180 deg =  6 heures = droit derriere ;
--      relevement 270 deg =  9 heures = a babord.
--    Une heure vaut donc 30 degres, et l'arc arriere 4h-8h correspond a
--    l'intervalle [120 deg, 240 deg].
--
--    Demonstration du signe : un appareil cap au sud (+Z) a l'ouest (-X) sur
--    sa droite. Le relevement de -X doit donc valoir 90 deg, ce que donne
--    atan2(-x, z) et non atan2(x, z).
--------------------------------------------------------------------------------

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

function M.normaliserAngle(deg)
  return (deg % 360 + 360) % 360
end

--- Ecart angulaire signe le plus court entre deux relevements, dans [-180, 180].
function M.ecartAngulaire(a, b)
  local d = M.normaliserAngle(a - b)
  if d > 180 then d = d - 360 end
  return d
end

--- Relevement absolu (deg, 0..360) du vecteur horizontal fourni.
function M.relevement(v)
  return M.normaliserAngle(math.deg(atan2(-v.x, v.z)))
end

--- Vecteur unitaire horizontal correspondant a un relevement absolu.
function M.vecteurDepuisRelevement(deg)
  local r = math.rad(deg)
  return { x = -math.sin(r), y = 0, z = math.cos(r) }
end

--- Relevement d'un point PAR RAPPORT au cap d'un mobile.
-- @param capDeg     relevement absolu du cap du mobile
-- @param depuis     position du mobile
-- @param vers       position observee
-- @return relevement relatif (0 = devant le mobile, 180 = derriere lui)
function M.relevementRelatif(capDeg, depuis, vers)
  local d = V.horizontal(V.soustraire(vers, depuis))
  if V.normeHorizontale(d) < 1e-6 then return 0 end
  return M.normaliserAngle(M.relevement(d) - capDeg)
end

--- Conversion d'un relevement relatif en position horaire lisible ("6h30").
function M.positionHoraire(relatifDeg)
  local heures = M.normaliserAngle(relatifDeg) / 30
  local h = math.floor(heures)
  local minutes = math.floor((heures - h) * 60 + 0.5)
  if minutes >= 60 then minutes, h = 0, h + 1 end
  if h == 0 then h = 12 end
  return string.format("%dh%02d", h, minutes)
end

--------------------------------------------------------------------------------
-- 5. JOURNAL
--    Format identique a celui des balises :
--      [horodatage] [NIVEAU] [etape: <nom>] message
--    Toute ecriture est non bloquante : un disque plein ne doit jamais
--    interrompre une mission en cours.
--------------------------------------------------------------------------------

local NIVEAUX = { DEBUG = 0, INFO = 1, AVERT = 2, ERREUR = 3, CRITIQUE = 4 }
M.NIVEAUX = NIVEAUX

local COULEURS = {
  DEBUG    = "lightGray",
  INFO     = "white",
  AVERT    = "yellow",
  ERREUR   = "red",
  CRITIQUE = "magenta",
}

local journal = {
  fichierActif = false,
  seuilEcran   = NIVEAUX.INFO,
  tailleMax    = 96 * 1024,
  -- fs est absent quand le noyau est charge hors du jeu (bancs d'essai purs).
  chemin       = (fs and fs.combine(REPERTOIRE, "intercepteur.log")) or "intercepteur.log",
  ecrits       = 0,
}
M.journal = journal

function journal.rotation()
  -- Volontairement sans journalisation interne : appele depuis journal.ecrire,
  -- toute erreur ici ne doit surtout pas provoquer de recursion.
  if not journal.fichierActif then return end
  if not fs.exists(journal.chemin) then return end
  if fs.getSize(journal.chemin) < journal.tailleMax then return end
  local archive = journal.chemin .. ".1"
  if fs.exists(archive) then fs.delete(archive) end
  fs.move(journal.chemin, archive)
end

function journal.ecrire(niveau, etape, message)
  local texte = tostring(message)
  local premiereLigne = texte:match("^[^\n]*") or texte
  local multiligne = premiereLigne ~= texte

  local entete = string.format("[%s] [%s] [etape: %s] ",
    M.horodatage(), niveau, tostring(etape))

  -- 5a. Sortie ecran (filtree par le niveau configure).
  if (NIVEAUX[niveau] or 1) >= journal.seuilEcran then
    local couleur
    if term.isColour and term.isColour() then
      couleur = colors[COULEURS[niveau] or "white"]
      pcall(term.setTextColour, couleur)
    end
    print(entete .. premiereLigne
      .. ((multiligne and journal.fichierActif) and " [trace dans intercepteur.log]" or ""))
    if couleur then pcall(term.setTextColour, colors.white) end
  end

  -- 5b. Sortie fichier (jamais bloquante).
  if journal.fichierActif then
    pcall(journal.rotation)
    local ok, fichier = pcall(fs.open, journal.chemin, "a")
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

--- Journalise au plus une fois toutes les N secondes pour une meme cle.
-- Les boucles de controle tournent a 4 Hz : sans cela, un evenement permanent
-- (perte de contact, saturation) noierait le journal et masquerait le reste.
local dernieresEmissions = {}
function journal.limite(cle, periode, niveau, etape, message)
  local t = M.maintenant()
  local precedent = dernieresEmissions[cle]
  if precedent and (t - precedent) < periode then return false end
  dernieresEmissions[cle] = t
  journal.ecrire(niveau, etape, message)
  return true
end

function journal.initialiser(config)
  journal.seuilEcran   = NIVEAUX[config.journalNiveauEcran] or NIVEAUX.INFO
  journal.tailleMax    = config.journalTailleMax or journal.tailleMax
  journal.fichierActif = config.journalFichier and true or false
  if journal.fichierActif then
    local ok, fichier = pcall(fs.open, journal.chemin, "a")
    if ok and fichier then
      fichier.close()
    else
      journal.fichierActif = false
      journal.avert(M.ETAPES.INIT_JOURNAL,
        "impossible d'ecrire " .. journal.chemin .. " : journalisation ecran uniquement")
    end
  end
end

--------------------------------------------------------------------------------
-- 6. EXECUTION PROTEGEE
--------------------------------------------------------------------------------

local function gestionnaireErreur(err)
  local texte = tostring(err)
  if debug and debug.traceback then
    local ok, trace = pcall(debug.traceback, texte, 2)
    if ok and trace then return trace end
  end
  return texte
end
M.gestionnaireErreur = gestionnaireErreur

--- Distingue l'arret manuel (Ctrl+T) d'une erreur ordinaire.
-- CC: Tweaked leve exactement "Terminated" ; on exige donc ce mot en tout debut
-- de message. Une erreur du genre "Terminated modem link" ne doit surtout pas
-- etre prise pour un arret volontaire en plein vol.
function M.estTerminate(err)
  if type(err) ~= "string" then return false end
  return err == "Terminated" or err:match("^Terminated\n") ~= nil
end

--- Execute fn en capturant toute erreur et en la rattachant a une etape.
-- @return true, ... | false, messageErreur
function M.proteger(etape, fn, ...)
  local args = table.pack(...)
  local resultats
  local ok, err = xpcall(function()
    resultats = table.pack(fn(table.unpack(args, 1, args.n)))
  end, gestionnaireErreur)

  if not ok then
    if M.estTerminate(err) then error(err, 0) end
    journal.erreur(etape, "erreur detectee a l'etape '" .. etape .. "' : " .. tostring(err))
    return false, err
  end
  return true, table.unpack(resultats, 1, resultats.n)
end

--- Variante qui fait remonter l'erreur au superviseur apres journalisation.
function M.exigerEtape(etape, fn, ...)
  local resultats = table.pack(M.proteger(etape, fn, ...))
  if not resultats[1] then
    error("ETAPE[" .. etape .. "] " .. tostring(resultats[2]), 0)
  end
  return table.unpack(resultats, 2, resultats.n)
end

--------------------------------------------------------------------------------
-- 7. CONFIGURATION
--------------------------------------------------------------------------------

--- Charge un fichier de configuration Lua ("return { ... }").
function M.chargerConfiguration(chemin, defauts)
  if not fs.exists(chemin) then
    error("fichier de configuration introuvable : " .. chemin, 0)
  end
  local fichier = fs.open(chemin, "r")
  if not fichier then
    error("lecture impossible : " .. chemin, 0)
  end
  local source = fichier.readAll()
  fichier.close()

  local morceau, err = load(source, "@" .. chemin, "t", _G)
  if not morceau then
    error("configuration illisible (syntaxe Lua) : " .. tostring(err), 0)
  end
  local table_config = morceau()
  if type(table_config) ~= "table" then
    error("la configuration doit se terminer par 'return { ... }'", 0)
  end

  -- Fusion avec les valeurs par defaut : une configuration incomplete ne doit
  -- jamais faire planter le navire en vol.
  local config = {}
  for cle, valeur in pairs(defauts or {}) do config[cle] = valeur end
  for cle, valeur in pairs(table_config) do config[cle] = valeur end
  return config
end

--- Charge un module embarque du meme repertoire et lui transmet des arguments.
function M.chargerModule(nom, ...)
  local chemin = fs.combine(REPERTOIRE, nom .. ".lua")
  if not fs.exists(chemin) then
    error("module embarque manquant : " .. chemin, 0)
  end
  local fichier = fs.open(chemin, "r")
  local source = fichier.readAll()
  fichier.close()
  local morceau, err = load(source, "@" .. chemin, "t", _G)
  if not morceau then
    error("module illisible : " .. chemin .. " -> " .. tostring(err), 0)
  end
  local resultat = morceau(...)
  if type(resultat) ~= "table" then
    error("le module '" .. nom .. "' doit renvoyer une table", 0)
  end
  return resultat
end

M.REPERTOIRE = REPERTOIRE

return M
