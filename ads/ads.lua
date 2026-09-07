--[[----------------------------------------------------------------------------
  FRENCHNET / AERONAUTICS WARFARE - ADS (Automatic Defence Suite)
  Contre-mesures embarquees : detection de projectile entrant, largage de
  leurres, manoeuvre d'evasion prioritaire, puis reprise de la tache en cours.
  --------------------------------------------------------------------------
  Role      : sur CHAQUE navire, surveiller en continu le radar de bord,
              identifier les projectiles qui convergent vers le navire,
              declencher simultanement leurres + evasion, puis restituer le
              controle a la tache interrompue une fois la menace passee.
  Cible     : ordinateur embarque + radar (Create Radars) + modem Ender
              + largueurs de leurres + acces au pilotage (Create Aeronautics).
  Autonomie : superviseur interne, redemarrage automatique avec temporisation
              progressive, aucune intervention humaine requise.
  Journal   : chaque etape porte un nom ; toute anomalie est horodatee,
              etiquetee et chiffree (distances, vitesses, caps, altitudes).

  INDEPENDANCE : l'ADS ne depend d'AUCUN systeme au sol ni du scramble. Il ne
  recoit d'ordre de personne (sauf si 'autoriserInhibitionExterne' est mis a
  true, ce qui n'est PAS le defaut). Il coexiste avec les autres programmes du
  navire via un contrat de priorite documente (verrou fichier + rednet), ce qui
  lui permet de les interrompre puis de les relancer.

  NOTE SUR LES ACCENTS : les chaines affichees a l'ecran et ecrites dans le
  journal sont volontairement sans accents. Le terminal de CC: Tweaked est
  oriente octet : un caractere accentue en UTF-8 s'y afficherait sous forme de
  deux glyphes parasites. Les commentaires du code (jamais affiches) sont eux
  rédigés normalement.
--------------------------------------------------------------------------------]]

local VERSION_PROGRAMME = "1.0.0"
local PROTOCOLE_VERSION = 1

--------------------------------------------------------------------------------
-- 1. NOMENCLATURE DES ETAPES
--    Chaque etape porte un nom explicite : il est repris tel quel dans le
--    journal, ce qui permet de localiser instantanement un plantage.
--------------------------------------------------------------------------------

local ETAPES = {
  DEMARRAGE            = "demarrage du superviseur",
  CHARGEMENT_CONFIG    = "chargement de la configuration",
  VALIDATION_CONFIG    = "validation de la configuration",
  INIT_JOURNAL         = "initialisation du journal",
  DETECTION_MODEM      = "detection du modem ender",
  OUVERTURE_REDNET     = "ouverture rednet",
  DETECTION_RADAR      = "detection du radar de bord",
  DETECTION_PILOTE     = "detection de l'interface de pilotage",
  DETECTION_LARGUEURS  = "detection des largueurs de leurres",
  POSITION_NAVIRE      = "localisation du navire",
  SCAN_RADAR           = "scan radar",
  PISTAGE              = "pistage des contacts",
  EVALUATION_MENACE    = "evaluation de menace",
  ALERTE_MENACE        = "alerte menace entrante",
  LARGAGE_LEURRES      = "largage des leurres",
  MANOEUVRE_EVASION    = "manoeuvre d'evasion",
  PREEMPTION_TACHE     = "preemption de la tache en cours",
  SAUVEGARDE_TACHE     = "sauvegarde de la tache en cours",
  REPRISE_TACHE        = "reprise de la tache normale",
  FIN_MENACE           = "fin de menace",
  TELEMETRIE           = "telemetrie ADS",
  SURVEILLANCE         = "surveillance du materiel",
  BOUCLE_PRINCIPALE    = "boucle principale (parallele)",
  ROTATION_JOURNAL     = "rotation du fichier journal",
  ARRET                = "arret du programme",
}

-- Etats de la machine a etats de l'ADS.
local ETAT_VEILLE     = "VEILLE"      -- surveillance nominale
local ETAT_MENACE     = "MENACE"      -- contre-mesures et evasion en cours
local ETAT_DEGAGEMENT = "DEGAGEMENT"  -- menace levee, delai de securite
local ETAT_REPRISE    = "REPRISE"     -- restitution de la tache interrompue

--------------------------------------------------------------------------------
-- 2. VALEURS PAR DEFAUT
--    Toute cle absente du fichier de configuration reprend la valeur ci-dessous,
--    afin qu'une configuration incomplete ne fasse jamais planter l'ADS.
--------------------------------------------------------------------------------

local DEFAUTS = {
  ---------------------------------------------------------------- identite ----
  identifiant                 = nil,       -- OBLIGATOIRE, unique par navire
  designation                 = "",        -- libelle libre (flottille, role...)

  ----------------------------------------------------------------- reseau ----
  coteModem                   = nil,       -- nil = detection automatique
  delaiGps                    = 2,         -- timeout de gps.locate (secondes)

  ------------------------------------------------------------------ radar ----
  radarPeripherique           = nil,       -- nil = detection automatique
  radarMethodeScan            = nil,       -- nil = sondage automatique
  radarPortee                 = 256,       -- portee utile declaree (blocs)
  radarRepere                 = "auto",    -- auto | relatif | absolu
  intervalleScanSecondes      = 0.25,      -- periode de scan radar
  radarEchecsAvantReinit      = 20,        -- scans en erreur avant reinit

  ------------------------------------------------------------- pistage -------
  pisteMemoireSecondes        = 6,         -- duree de vie d'une piste sans echo
  pisteEchantillonsMax        = 12,        -- profondeur de l'historique
  pisteRayonAssociation       = 24,        -- gate d'association (blocs)
  vitesseProjectileMini       = 6,         -- blocs/s : en dessous, pas un projectile
  motifsProjectile            = {          -- reconnaissance par le nom du contact
    "missile", "rocket", "roquette", "shell", "obus", "projectile", "cannon",
    "cbc", "ap_shell", "he_shell", "flak", "torpedo", "torpille", "bomb",
  },
  motifsIgnores               = {          -- jamais considere comme une menace
    "player", "item", "flare", "leurre", "chaff", "particle", "boat", "minecart",
  },

  --------------------------------------------------------------- menace ------
  rayonMenace                 = 12,        -- distance d'approche minimale (blocs)
  horizonMenaceSecondes       = 12,        -- au-dela, la menace n'est pas imminente
  alignementMini              = 0.965,     -- cos(15 deg) : cap tenu vers le navire
  rapprochementMiniBlocsSec   = 3,         -- vitesse de rapprochement minimale
  echantillonsRapprochementMini = 3,       -- scans consecutifs de rapprochement
  confirmationsMini           = 2,         -- scans consecutifs avant declenchement
  urgenceSecondes             = 2.5,       -- en dessous : declenchement immediat
  hysteresisLevee             = 1.6,       -- facteur d'elargissement pour lever
  perteContactSecondes        = 1.5,       -- sans echo : contact considere perdu
  delaiSecuriteSecondes       = 4,         -- attente avant reprise de la tache

  -------------------------------------------------------------- leurres ------
  leurresActifs               = true,
  largueurs                   = {},        -- voir config_ads.lua
  leurresParSalve             = 2,
  salvesParEngagement         = 3,
  intervalleSalveSecondes     = 0.8,
  stockLeurres                = 24,        -- 0 = illimite (ravitaillement auto)
  delaiReengagementSecondes   = 6,         -- avant de re-larguer sur la meme piste

  -------------------------------------------------------------- evasion ------
  evasionActive               = true,
  pilotePeripherique          = nil,       -- nil = detection automatique
  piloteMode                  = "auto",    -- auto | peripherique | redstone | rednet | simulation
  piloteMethodes              = nil,       -- surcharge manuelle (voir config)
  piloteRedstone              = {},        -- { babord=, tribord=, monter=, descendre=, pleinGaz= }
  amplitudeVirageDegres       = 90,        -- virage franc
  amplitudeAltitudeBlocs      = 40,        -- changement d'altitude franc
  altitudeMin                 = 80,
  altitudeMax                 = 300,
  vitesseEvasionEstimee       = 20,        -- blocs/s, sert au calcul du meilleur axe
  preferenceEvasion           = "auto",    -- auto | horizontale | verticale
  intervalleManoeuvreSecondes = 1,         -- re-evaluation de l'axe d'evasion
  pleinGazEnEvasion           = true,

  ---------------------------------------------------------------- taches -----
  protocoleRednet             = "frenchnet_ads",
  protocoleTache              = "frenchnet_nav",
  fichierTache                = "tache_courante.lua",
  reprendreTache              = true,
  delaiInterrogationTache     = 1.5,       -- timeout de la demande de tache
  rafraichirTacheSecondes     = 10,        -- periodicite de la sauvegarde
  autoriserInhibitionExterne  = false,     -- independance totale par defaut

  ------------------------------------------------------------- telemetrie ----
  telemetrieActive            = true,
  intervalleTelemetrieSecondes = 2,

  ------------------------------------------------------------- robustesse ----
  journalFichier              = true,
  journalTailleMax            = 128 * 1024,
  journalNiveauEcran          = "INFO",    -- DEBUG | INFO | AVERT | ERREUR
  battementSecondes           = 60,
  erreursAvantReinit          = 10,
  redemarrageDelaiMin         = 3,
  redemarrageDelaiMax         = 60,
  arretParTerminate           = true,
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
local CHEMIN_CONFIG  = fs.combine(REPERTOIRE, "config_ads.lua")
local CHEMIN_JOURNAL = fs.combine(REPERTOIRE, "ads.log")
local MARQUEUR_ARRET = fs.combine(REPERTOIRE, ".arret_manuel")
local VERROU_PRIORITE = fs.combine(REPERTOIRE, ".priorite_ads")

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

--- Formate un nombre potentiellement infini ou absent pour le journal.
-- Le zero negatif est ramene a zero : un journal qui annonce "-0.0b/s" fait
-- douter le lecteur du signe au moment ou il en a le plus besoin.
local function fmt(v, decimales)
  if not nombreValide(v) then return "n/d" end
  if v == 0 then v = 0 end
  return string.format("%." .. (decimales or 1) .. "f", v)
end

--- Teste si un texte correspond a l'un des motifs (recherche litterale,
-- insensible a la casse). Sert a classer les contacts radar par leur nom.
local function correspondMotif(texte, motifs)
  if type(texte) ~= "string" or type(motifs) ~= "table" then return false end
  local minuscule = texte:lower()
  for _, motif in ipairs(motifs) do
    if type(motif) == "string" and motif ~= ""
       and minuscule:find(motif:lower(), 1, true) then
      return true, motif
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- 4. JOURNAL
--    Format : [horodatage] [NIVEAU] [etape: <nom>] message
--------------------------------------------------------------------------------

local journal = {
  fichierActif = false,
  seuilEcran   = 1,
  ecrits       = 0,
  tailleMax    = 128 * 1024, -- valeur de repli avant lecture de la configuration
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
      .. ((multiligne and journal.fichierActif) and " [trace dans ads.log]" or ""))
    if couleur then pcall(term.setTextColour, colors.white) end
  end

  -- 4b. Sortie fichier (jamais bloquante : un disque plein ne doit pas tuer l'ADS)
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
-- soit du saut de ligne introduit par la pile d'appels.
local function estTerminate(err)
  if type(err) ~= "string" then return false end
  return err == "Terminated" or err:match("^Terminated\n") ~= nil
end

--- Execute fn en capturant toute erreur et en la rattachant a une etape.
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
-- 6. CINEMATIQUE
--    Toute la geometrie d'interception. Ce bloc est volontairement pur (aucun
--    acces au materiel, aucune journalisation) : il est testable isolement.
--
--    REPERE DE TRAVAIL : tout est exprime dans le repere NAVIRE, c'est-a-dire
--    des axes du monde (X est, Y haut, Z sud) dont l'origine suit le navire.
--    Consequence : la position d'un contact est deja un vecteur relatif, et sa
--    derivee temporelle est deja une VITESSE RELATIVE. C'est exactement ce que
--    demande le calcul d'approche minimale, et cela reste valable meme quand le
--    navire ignore sa position absolue (radar sans GPS).
--------------------------------------------------------------------------------

local vec = {}

function vec.creer(x, y, z)      return { x = x, y = y, z = z } end
function vec.ajouter(a, b)       return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z } end
function vec.soustraire(a, b)    return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z } end
function vec.echelle(a, k)       return { x = a.x * k, y = a.y * k, z = a.z * k } end
function vec.scalaire(a, b)      return a.x * b.x + a.y * b.y + a.z * b.z end
function vec.norme(a)            return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end

function vec.vectoriel(a, b)
  return {
    x = a.y * b.z - a.z * b.y,
    y = a.z * b.x - a.x * b.z,
    z = a.x * b.y - a.y * b.x,
  }
end

--- Normalise un vecteur. Renvoie nil si sa norme est negligeable : le sens
-- n'a alors aucun sens physique et il ne faut surtout pas diviser par zero.
function vec.normaliser(a)
  local n = vec.norme(a)
  if n < 1e-9 then return nil end
  return { x = a.x / n, y = a.y / n, z = a.z / n }
end

local HAUT = vec.creer(0, 1, 0)

local cinematique = {}

--- Cap Minecraft (degres) correspondant a une direction horizontale.
-- Convention du jeu : yaw = 0 vers le SUD (+Z), 90 vers l'OUEST (-X),
-- -90 vers l'EST (+X), 180 vers le NORD (-Z). D'ou l'atan2(-dx, dz).
function cinematique.capDepuisVecteur(v)
  if math.abs(v.x) < 1e-9 and math.abs(v.z) < 1e-9 then return nil end
  local cap = math.deg(math.atan(-v.x, v.z))
  if cap <= -180 then cap = cap + 360 end
  if cap > 180 then cap = cap - 360 end
  return cap
end

--- Ramene un ecart de cap dans l'intervalle ]-180, 180].
function cinematique.normaliserCap(cap)
  cap = cap % 360
  if cap > 180 then cap = cap - 360 end
  return cap
end

--- Point d'approche minimale (CPA) entre le navire (origine du repere) et un
-- contact de position relative r et de vitesse relative v (blocs/seconde).
--
-- POURQUOI CE CALCUL PLUTOT QU'UN SIMPLE "IL SE RAPPROCHE" : un projectile
-- peut se rapprocher tout en etant regle pour passer a cote (tir de barrage,
-- obus destine a un autre navire de la formation). Inversement un projectile
-- guide peut sembler mal aligne a l'instant t et corriger. Le seul critere
-- geometriquement honnete est la distance a laquelle il passera SI RIEN NE
-- CHANGE, et dans combien de temps.
--   t_cpa  = -(r.v) / |v|^2       instant du passage au plus pres
--   d_cpa  = |r + v * t_cpa|      distance de passage
function cinematique.approcheMinimale(r, v)
  local distance = vec.norme(r)
  local vitesseRelative = vec.norme(v)
  local rv = vec.scalaire(r, v)

  -- Taux de rapprochement : positif quand la distance diminue.
  local rapprochement = (distance > 1e-9) and (-rv / distance) or 0

  if vitesseRelative < 1e-6 then
    return {
      distance = distance, rapprochement = 0, vitesseRelative = 0,
      tCpa = math.huge, distanceCpa = distance,
    }
  end

  local tCpa = -rv / (vitesseRelative * vitesseRelative)
  local distanceCpa
  if tCpa <= 0 then
    -- Le contact s'eloigne deja : le point le plus proche est derriere nous,
    -- la distance actuelle est donc la plus petite qu'il atteindra encore.
    distanceCpa = distance
  else
    distanceCpa = vec.norme(vec.ajouter(r, vec.echelle(v, tCpa)))
  end

  return {
    distance = distance, rapprochement = rapprochement,
    vitesseRelative = vitesseRelative, tCpa = tCpa, distanceCpa = distanceCpa,
  }
end

--- Alignement du contact sur le navire : cosinus de l'angle entre la direction
-- de deplacement du contact et la direction "contact -> navire".
--  1  = il vient droit sur nous
--  0  = il passe par le travers
-- -1  = il s'eloigne dans l'axe
function cinematique.alignement(r, v)
  local versNavire = vec.normaliser(vec.echelle(r, -1))
  local direction  = vec.normaliser(v)
  if not versNavire or not direction then return 0 end
  return vec.scalaire(versNavire, direction)
end

--- Meilleur axe d'evasion face a un projectile de position relative r et de
-- vitesse relative v, pour un navire capable d'atteindre 'vitesseNavire'.
--
-- PRINCIPE : fuir en ligne droite devant un projectile plus rapide que soi ne
-- sert a rien, la composante utile de la fuite est nulle. Il faut se degager
-- PERPENDICULAIREMENT a sa trajectoire ("mise en travers") : c'est ce qui
-- maximise l'ecart lateral a acquerir pour lui, et ce qui sature le plus vite
-- la capacite de correction d'un autoguidage.
--
-- On construit donc la base du plan perpendiculaire a la trajectoire :
--   e = v ^ haut   (horizontale perpendiculaire)
--   w = e ^ v      (perpendiculaire restante, principalement verticale)
-- puis on essaie les quatre sens et on garde celui qui donne la plus grande
-- distance d'approche minimale. Les quatre sens ne sont PAS equivalents des
-- que le projectile a deja un ecart lateral : il faut fuir du bon cote.
-- @param filtre  fonction(candidat) -> bool, pour ecarter un sens interdit
--                (plafond, plancher...). Facultative.
-- @return meilleur candidat, liste complete des candidats evalues
function cinematique.axeEvasion(r, v, vitesseNavire, filtre)
  local direction = vec.normaliser(v)
  if not direction then return nil, {} end

  local e = vec.vectoriel(direction, HAUT)
  if vec.norme(e) < 1e-6 then
    -- Projectile strictement vertical : la verticale ne donne pas de repere,
    -- on prend un axe horizontal arbitraire mais deterministe.
    e = vec.vectoriel(direction, vec.creer(1, 0, 0))
  end
  e = vec.normaliser(e)
  if not e then return nil, {} end
  local w = vec.normaliser(vec.vectoriel(e, direction))

  local candidats = {}
  local function evaluer(nom, axe)
    if not axe then return end
    -- Le navire prend la vitesse 'axe * vitesseNavire' : la vitesse RELATIVE
    -- du projectile diminue d'autant.
    local vApres = vec.soustraire(v, vec.echelle(axe, vitesseNavire))
    local apres = cinematique.approcheMinimale(r, vApres)
    candidats[#candidats + 1] = {
      nom = nom, axe = axe,
      distanceCpa = apres.distanceCpa, tCpa = apres.tCpa,
      cap = cinematique.capDepuisVecteur(axe),
      verticale = axe.y,
    }
  end

  -- Noms exprimes DANS LE REPERE DU PROJECTILE (lateral = par le travers de sa
  -- trajectoire) et non dans celui du navire : babord/tribord seraient trompeurs
  -- puisque le sens de barre depend du cap courant, calcule plus loin.
  evaluer("lateral-", vec.echelle(e, -1))
  evaluer("lateral+", e)
  if w then
    evaluer("plongee", (w.y <= 0) and w or vec.echelle(w, -1))
    evaluer("montee",  (w.y > 0) and w or vec.echelle(w, -1))
  end

  local meilleur
  for _, candidat in ipairs(candidats) do
    candidat.autorise = (filtre == nil) or (filtre(candidat) and true or false)
    if candidat.autorise then
      if not meilleur or candidat.distanceCpa > meilleur.distanceCpa then
        meilleur = candidat
      end
    end
  end
  return meilleur, candidats
end

--- Vitesse d'un contact par regression lineaire sur son historique.
-- Une simple difference entre deux echantillons est tres bruitee (le radar
-- echantillonne des positions entieres). La regression sur toute la fenetre
-- lisse ce bruit sans introduire de retard notable.
-- @param echantillons liste { t = secondes, p = vecteur }, du plus ancien au plus recent
function cinematique.vitesseParRegression(echantillons)
  local n = #echantillons
  if n < 2 then return nil end

  local sommeT, sommeT2 = 0, 0
  local sommeP  = vec.creer(0, 0, 0)
  local sommeTP = vec.creer(0, 0, 0)
  local t0 = echantillons[1].t

  for _, e in ipairs(echantillons) do
    local t = e.t - t0
    sommeT  = sommeT + t
    sommeT2 = sommeT2 + t * t
    sommeP  = vec.ajouter(sommeP, e.p)
    sommeTP = vec.ajouter(sommeTP, vec.echelle(e.p, t))
  end

  local denominateur = n * sommeT2 - sommeT * sommeT
  if math.abs(denominateur) < 1e-9 then return nil end -- echantillons simultanes

  return vec.echelle(vec.soustraire(vec.echelle(sommeTP, n), vec.echelle(sommeP, sommeT)),
    1 / denominateur)
end

--------------------------------------------------------------------------------
-- 7. CONFIGURATION
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
    table.insert(anomalies, "'identifiant' manquant : chaque navire doit porter un identifiant unique")
  elseif #config.identifiant > 32 then
    table.insert(anomalies, "'identifiant' trop long (32 caracteres maximum)")
  end

  -- Reglages numeriques : un type errone provoquerait une erreur arithmetique
  -- en pleine interception, c'est-a-dire au pire moment possible.
  local numeriques = {
    "delaiGps", "radarPortee", "intervalleScanSecondes", "radarEchecsAvantReinit",
    "pisteMemoireSecondes", "pisteEchantillonsMax", "pisteRayonAssociation",
    "vitesseProjectileMini", "rayonMenace", "horizonMenaceSecondes",
    "rapprochementMiniBlocsSec", "echantillonsRapprochementMini",
    "confirmationsMini", "urgenceSecondes", "hysteresisLevee",
    "perteContactSecondes", "delaiSecuriteSecondes", "leurresParSalve",
    "salvesParEngagement", "intervalleSalveSecondes", "stockLeurres",
    "delaiReengagementSecondes", "amplitudeVirageDegres", "amplitudeAltitudeBlocs",
    "altitudeMin", "altitudeMax", "vitesseEvasionEstimee",
    "intervalleManoeuvreSecondes", "delaiInterrogationTache",
    "rafraichirTacheSecondes", "intervalleTelemetrieSecondes",
    "journalTailleMax", "battementSecondes", "erreursAvantReinit",
    "redemarrageDelaiMin", "redemarrageDelaiMax",
  }
  for _, cle in ipairs(numeriques) do
    if not nombreValide(config[cle]) or config[cle] < 0 then
      table.insert(anomalies, "'" .. cle .. "' doit etre un nombre >= 0")
    end
  end

  if nombreValide(config.intervalleScanSecondes) and config.intervalleScanSecondes < 0.05 then
    table.insert(anomalies, "'intervalleScanSecondes' doit valoir au moins 0.05 "
      .. "(un tick CC: Tweaked vaut 0.05 s)")
  end

  if nombreValide(config.alignementMini)
     and (config.alignementMini < -1 or config.alignementMini > 1) then
    table.insert(anomalies, "'alignementMini' est un cosinus : il doit etre compris entre -1 et 1")
  end

  if nombreValide(config.altitudeMin) and nombreValide(config.altitudeMax)
     and config.altitudeMin >= config.altitudeMax then
    table.insert(anomalies, "'altitudeMin' doit etre strictement inferieur a 'altitudeMax'")
  end

  if type(config.protocoleRednet) ~= "string" or config.protocoleRednet == "" then
    table.insert(anomalies, "'protocoleRednet' doit etre une chaine non vide")
  end

  local modes = { auto = true, peripherique = true, redstone = true,
                  rednet = true, simulation = true }
  if not modes[config.piloteMode] then
    table.insert(anomalies, "'piloteMode' doit valoir auto, peripherique, redstone, rednet ou simulation")
  end

  local reperes = { auto = true, relatif = true, absolu = true }
  if not reperes[config.radarRepere] then
    table.insert(anomalies, "'radarRepere' doit valoir auto, relatif ou absolu")
  end

  if type(config.largueurs) ~= "table" then
    table.insert(anomalies, "'largueurs' doit etre une liste (voir config_ads.lua)")
  end

  if #anomalies > 0 then
    error("configuration invalide -> " .. table.concat(anomalies, " | "), 0)
  end
  return config
end

--------------------------------------------------------------------------------
-- 8. MATERIEL
--
--    AVERTISSEMENT IMPORTANT. Create Radars et Create Aeronautics n'exposent
--    pas la meme API selon leur version : les noms de peripheriques et de
--    methodes changent d'une release a l'autre. Plutot que de figer des noms
--    qui casseraient a la premiere mise a jour, l'ADS SONDE le materiel au
--    demarrage, retient ce qui repond, et ECRIT DANS LE JOURNAL le nom exact
--    retenu. En cas d'echec il liste les peripheriques presents et leurs
--    methodes : il suffit alors de renseigner une ligne de config_ads.lua,
--    sans toucher au programme.
--------------------------------------------------------------------------------

--- Liste les methodes exposees par un peripherique (jamais bloquant).
local function methodesPeripherique(nom)
  local ok, liste = pcall(peripheral.getMethods, nom)
  if ok and type(liste) == "table" then return liste end
  -- Certaines versions n'exposent pas getMethods : on retombe sur le wrap.
  local okWrap, enveloppe = pcall(peripheral.wrap, nom)
  if okWrap and type(enveloppe) == "table" then
    local noms = {}
    for cle, valeur in pairs(enveloppe) do
      if type(valeur) == "function" then noms[#noms + 1] = cle end
    end
    table.sort(noms)
    return noms
  end
  return {}
end

--- Inventaire lisible du materiel connecte, pour le journal de diagnostic.
local function inventaireMateriel()
  local lignes = {}
  for _, nom in ipairs(peripheral.getNames()) do
    local okType, typePeriph = pcall(peripheral.getType, nom)
    local methodes = methodesPeripherique(nom)
    lignes[#lignes + 1] = string.format("%s (type %s) -> %s", nom,
      okType and tostring(typePeriph) or "?",
      #methodes > 0 and table.concat(methodes, ", ") or "aucune methode")
  end
  if #lignes == 0 then return "aucun peripherique connecte" end
  return table.concat(lignes, "\n")
end

--- Cherche un peripherique dont le type ou le nom contient l'un des motifs.
-- @return nom, enveloppe
local function trouverPeripherique(motifs, exclure)
  for _, nom in ipairs(peripheral.getNames()) do
    if not (exclure and exclure[nom]) then
      local okType, typePeriph = pcall(peripheral.getType, nom)
      local candidat = (okType and type(typePeriph) == "string") and typePeriph or ""
      if correspondMotif(candidat, motifs) or correspondMotif(nom, motifs) then
        local okWrap, enveloppe = pcall(peripheral.wrap, nom)
        if okWrap and enveloppe then return nom, enveloppe end
      end
    end
  end
  return nil
end

------------------------------------------------------------------------ modem --

--- Determine si un peripherique est un modem Ender (portee illimitee).
local function estModemEnder(nom)
  if peripheral.hasType then
    local ok, resultat = pcall(peripheral.hasType, nom, "ender_modem")
    if ok and resultat then return true end
  end
  local ok, typePeriph = pcall(peripheral.getType, nom)
  return ok and type(typePeriph) == "string"
     and string.find(typePeriph, "ender", 1, true) ~= nil
end

--- Cherche un modem sans fil, en privilegiant explicitement le modem Ender.
-- Le modem n'est PAS vital pour l'ADS : sans lui, la telemetrie et le contrat
-- de tache par rednet sont perdus, mais la defense du navire continue.
-- @return cote, modem, ender (booleen)
local function detecterModem(config)
  if type(config.coteModem) == "string" and config.coteModem ~= "" then
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

  local repliCote, repliModem = nil, nil
  for _, nom in ipairs(peripheral.getNames()) do
    local ok, typePeriph = pcall(peripheral.getType, nom)
    if ok and typePeriph == "modem" then
      local modem = peripheral.wrap(nom)
      local sansFil = false
      if modem and modem.isWireless then
        local okFil, resultat = pcall(modem.isWireless)
        sansFil = okFil and resultat
      end
      if sansFil then
        if estModemEnder(nom) then return nom, modem, true end
        repliCote, repliModem = repliCote or nom, repliModem or modem
      end
    end
  end

  if repliModem then return repliCote, repliModem, false end
  error("aucun modem sans fil detecte", 0)
end

------------------------------------------------------------------------ radar --

-- Noms de peripherique candidats pour le radar de bord (Create Radars).
local MOTIFS_RADAR = { "radar", "createradars", "create_radars", "radar_block" }

-- Methodes de scan candidates, essayees dans cet ordre. La premiere qui
-- renvoie une table est retenue et journalisee.
local METHODES_SCAN = {
  "getEntities", "scan", "getTargets", "getContacts", "getEntitiesInRange",
  "getRadarEntities", "getBlips", "getDetectedEntities", "entities", "getAll",
}

-- Cles possibles pour chaque champ d'un contact, dans l'ordre de preference.
local CLES_X       = { "x", "posX", "positionX", "relativeX", "dx" }
local CLES_Y       = { "y", "posY", "positionY", "relativeY", "dy" }
local CLES_Z       = { "z", "posZ", "positionZ", "relativeZ", "dz" }
local CLES_VX      = { "vx", "velocityX", "motionX", "vitesseX", "speedX" }
local CLES_VY      = { "vy", "velocityY", "motionY", "vitesseY", "speedY" }
local CLES_VZ      = { "vz", "velocityZ", "motionZ", "vitesseZ", "speedZ" }
local CLES_NOM     = { "name", "type", "entityType", "id", "displayName", "kind", "nom" }
local CLES_ID      = { "id", "uuid", "entityId", "entity_id", "uniqueId" }

local function premiereCle(source, cles)
  for _, cle in ipairs(cles) do
    local valeur = source[cle]
    if valeur ~= nil then return valeur, cle end
  end
  return nil
end

local function premierNombre(source, cles)
  for _, cle in ipairs(cles) do
    local valeur = source[cle]
    if nombreValide(valeur) then return valeur end
  end
  return nil
end

--- Extrait un sous-vecteur { x, y, z } eventuellement imbrique.
local function sousVecteur(source, nomCle)
  local valeur = source[nomCle]
  if type(valeur) == "table" then
    local x = premierNombre(valeur, { "x", 1 })
    local y = premierNombre(valeur, { "y", 2 })
    local z = premierNombre(valeur, { "z", 3 })
    if x and y and z then return vec.creer(x, y, z) end
  end
  return nil
end

--- Convertit un enregistrement brut du radar en contact normalise.
-- @return { cle, nom, position, vitesseFournie } ou nil si inexploitable
local function normaliserContact(brut, indice)
  if type(brut) ~= "table" then return nil end

  local position = sousVecteur(brut, "position") or sousVecteur(brut, "pos")
  if not position then
    local x = premierNombre(brut, CLES_X)
    local y = premierNombre(brut, CLES_Y)
    local z = premierNombre(brut, CLES_Z)
    if not (x and y and z) then return nil end
    position = vec.creer(x, y, z)
  end

  local vitesse = sousVecteur(brut, "velocity") or sousVecteur(brut, "motion")
  if not vitesse then
    local vx = premierNombre(brut, CLES_VX)
    local vy = premierNombre(brut, CLES_VY)
    local vz = premierNombre(brut, CLES_VZ)
    if vx and vy and vz then vitesse = vec.creer(vx, vy, vz) end
  end

  local nom = premiereCle(brut, CLES_NOM)
  nom = (type(nom) == "string") and nom or "contact"

  -- Identite : un identifiant stable est preferable, mais Create Radars ne
  -- l'expose pas toujours. Sans lui, le pistage associera par proximite.
  local identite = premiereCle(brut, CLES_ID)
  local cle = (type(identite) == "string" or type(identite) == "number")
    and ("id:" .. tostring(identite)) or nil

  return {
    cle = cle, nom = nom, position = position, vitesseFournie = vitesse,
    indice = indice, brut = brut,
  }
end

--- Sonde le radar : trouve le peripherique et la methode de scan qui repond.
local function detecterRadar(config)
  local nomRadar, radar

  if type(config.radarPeripherique) == "string" and config.radarPeripherique ~= "" then
    if not peripheral.isPresent(config.radarPeripherique) then
      error("radar impose '" .. config.radarPeripherique .. "' absent. Materiel present :\n"
        .. inventaireMateriel(), 0)
    end
    nomRadar = config.radarPeripherique
    radar = peripheral.wrap(nomRadar)
  else
    nomRadar, radar = trouverPeripherique(MOTIFS_RADAR)
    if not radar then
      error("aucun radar detecte. Renseignez 'radarPeripherique' dans config_ads.lua. "
        .. "Materiel present :\n" .. inventaireMateriel(), 0)
    end
  end

  -- Choix de la methode de scan.
  local candidates = {}
  if type(config.radarMethodeScan) == "string" and config.radarMethodeScan ~= "" then
    candidates = { config.radarMethodeScan }
  else
    candidates = METHODES_SCAN
  end

  for _, methode in ipairs(candidates) do
    if type(radar[methode]) == "function" then
      local ok, resultat = pcall(radar[methode])
      if ok and type(resultat) == "table" then
        return nomRadar, radar, methode
      end
    end
  end

  error("le radar '" .. nomRadar .. "' n'expose aucune methode de scan exploitable. "
    .. "Methodes essayees : " .. table.concat(candidates, ", ")
    .. ". Methodes reellement disponibles : "
    .. table.concat(methodesPeripherique(nomRadar), ", ")
    .. ". Renseignez 'radarMethodeScan' dans config_ads.lua.", 0)
end

--------------------------------------------------------------- interface pilote --

-- Peripheriques candidats pour le pilotage (Create Aeronautics et derives).
local MOTIFS_PILOTE = {
  "aeronautic", "aircraft", "airship", "helm", "pilot", "autopilot",
  "controller", "physics", "vs_ship", "ship_controller", "flight",
}

-- Pour chaque commande, les noms de methode candidats. La premiere methode
-- reellement presente est retenue et journalisee : plus aucune surprise a
-- l'usage, et une mise a jour du mod se rattrape par une ligne de config.
local COMMANDES_PILOTE = {
  cap       = { "setYaw", "setTargetYaw", "setHeading", "setTargetHeading",
                "setRotation", "setCap", "turnTo" },
  altitude  = { "setAltitude", "setTargetAltitude", "setElevation",
                "setTargetY", "setHeight", "climbTo" },
  gaz       = { "setThrottle", "setTargetThrottle", "setSpeed", "setPower",
                "setEngine", "setThrust" },
  lireCap   = { "getYaw", "getHeading", "getTargetYaw", "getRotation", "getCap" },
  lireAlt   = { "getAltitude", "getY", "getTargetAltitude", "getElevation", "getHeight" },
  lireGaz   = { "getThrottle", "getSpeed", "getPower", "getThrust" },
  lirePos   = { "getPosition", "getPos", "getLocation", "getCoordinates" },
  lireVit   = { "getVelocity", "getMotion", "getSpeedVector" },
}

--- Construit l'adaptateur de pilotage.
-- Modes :
--   peripherique : appels directs sur le peripherique de pilotage
--   redstone     : impulsions redstone vers un montage de commande
--   rednet       : ordres envoyes au programme de navigation du navire
--   simulation   : aucune action reelle, tout est journalise (banc d'essai,
--                  ou mise en service prudente d'un nouveau navire)
--   auto         : peripherique si trouve, sinon redstone si cable, sinon rednet
local function construirePilote(config, contexte)
  local pilote = {
    mode = config.piloteMode, nomPeripherique = nil, enveloppe = nil,
    methodes = {}, ordres = 0, echecs = 0,
  }

  local function resoudreMethodes(enveloppe)
    local surcharge = (type(config.piloteMethodes) == "table") and config.piloteMethodes or {}
    local trouvees, manquantes = {}, {}
    for commande, candidates in pairs(COMMANDES_PILOTE) do
      local impose = surcharge[commande]
      if type(impose) == "string" and type(enveloppe[impose]) == "function" then
        trouvees[commande] = impose
      else
        for _, nom in ipairs(candidates) do
          if type(enveloppe[nom]) == "function" then trouvees[commande] = nom break end
        end
        if not trouvees[commande] then manquantes[#manquantes + 1] = commande end
      end
    end
    return trouvees, manquantes
  end

  if config.piloteMode == "simulation" then
    pilote.mode = "simulation"
    return pilote
  end

  if config.piloteMode == "peripherique" or config.piloteMode == "auto" then
    local nom, enveloppe
    if type(config.pilotePeripherique) == "string" and config.pilotePeripherique ~= "" then
      if peripheral.isPresent(config.pilotePeripherique) then
        nom = config.pilotePeripherique
        enveloppe = peripheral.wrap(nom)
      elseif config.piloteMode == "peripherique" then
        error("interface de pilotage imposee '" .. config.pilotePeripherique
          .. "' absente. Materiel present :\n" .. inventaireMateriel(), 0)
      end
    else
      -- Le radar porte parfois des motifs communs : on l'exclut explicitement.
      nom, enveloppe = trouverPeripherique(MOTIFS_PILOTE,
        contexte.nomRadar and { [contexte.nomRadar] = true } or nil)
    end

    if enveloppe then
      local trouvees, manquantes = resoudreMethodes(enveloppe)
      if trouvees.cap or trouvees.altitude then
        pilote.mode = "peripherique"
        pilote.nomPeripherique = nom
        pilote.enveloppe = enveloppe
        pilote.methodes = trouvees
        pilote.manquantes = manquantes
        return pilote
      end
    end

    if config.piloteMode == "peripherique" then
      error("aucune interface de pilotage exploitable : aucune methode de cap ni "
        .. "d'altitude trouvee. Renseignez 'pilotePeripherique' et 'piloteMethodes' "
        .. "dans config_ads.lua. Materiel present :\n" .. inventaireMateriel(), 0)
    end
  end

  if config.piloteMode == "redstone" or config.piloteMode == "auto" then
    local cablage = (type(config.piloteRedstone) == "table") and config.piloteRedstone or {}
    local nbSorties = 0
    for _, cote in pairs(cablage) do
      if type(cote) == "string" and cote ~= "" then nbSorties = nbSorties + 1 end
    end
    if nbSorties > 0 then
      pilote.mode = "redstone"
      pilote.cablage = cablage
      return pilote
    end
    if config.piloteMode == "redstone" then
      error("mode redstone demande mais 'piloteRedstone' ne declare aucune sortie", 0)
    end
  end

  -- Dernier repli : deleguer la manoeuvre au programme de navigation par rednet.
  pilote.mode = "rednet"
  return pilote
end

--- Programme la fermeture d'une sortie redstone.
-- Si une impulsion court deja sur ce cote, on REPOUSSE son echeance au lieu
-- d'en empiler une seconde : sinon la premiere echeance refermerait la sortie
-- alors que la seconde impulsion est encore censee durer.
local function programmerImpulsion(contexte, cote, duree)
  local fin = os.clock() + (duree or 0.5)
  for _, impulsion in ipairs(contexte.impulsions) do
    if impulsion.cote == cote then
      impulsion.fin = math.max(impulsion.fin, fin)
      return
    end
  end
  contexte.impulsions[#contexte.impulsions + 1] = { cote = cote, fin = fin }
end

--- Applique une consigne au navire. Toutes les valeurs sont facultatives.
-- @param consigne { cap = degres, altitude = blocs, gaz = 0..1, raison = texte }
local function appliquerConsigne(contexte, consigne)
  local pilote = contexte.pilote
  pilote.ordres = pilote.ordres + 1

  if pilote.mode == "simulation" then
    contexte.dernieresConsignes = consigne
    return true, "simulation"
  end

  if pilote.mode == "peripherique" then
    local applique = {}
    local function appeler(commande, valeur)
      if valeur == nil then return end
      local methode = pilote.methodes[commande]
      if not methode then return end
      local ok = pcall(pilote.enveloppe[methode], valeur)
      if ok then
        applique[#applique + 1] = methode
      else
        pilote.echecs = pilote.echecs + 1
      end
    end
    appeler("cap", consigne.cap)
    appeler("altitude", consigne.altitude)
    appeler("gaz", consigne.gaz)
    contexte.dernieresConsignes = consigne
    if #applique == 0 then return false, "aucune methode appliquee" end
    return true, table.concat(applique, "+")
  end

  if pilote.mode == "redstone" then
    -- Le montage redstone ne recoit pas des valeurs mais des impulsions
    -- directionnelles : on traduit l'ecart de cap et d'altitude en sorties.
    local cablage = pilote.cablage or {}
    local actives = {}
    local function activer(nom, duree)
      local cote = cablage[nom]
      if type(cote) ~= "string" or cote == "" then return end
      pcall(redstone.setOutput, cote, true)
      actives[#actives + 1] = nom .. "@" .. cote
      programmerImpulsion(contexte, cote, duree or 0.5)
    end

    if consigne.virage == "babord"  then activer("babord",  consigne.duree) end
    if consigne.virage == "tribord" then activer("tribord", consigne.duree) end
    if consigne.vertical == "montee"  then activer("monter",   consigne.duree) end
    if consigne.vertical == "plongee" then activer("descendre", consigne.duree) end
    if consigne.gaz and consigne.gaz >= 0.99 then activer("pleinGaz", consigne.duree) end

    contexte.dernieresConsignes = consigne
    if #actives == 0 then return false, "aucune sortie redstone cablee pour cette consigne" end
    return true, table.concat(actives, "+")
  end

  -- Mode rednet : le programme de navigation execute la manoeuvre pour nous.
  if contexte.rednetOuvert then
    local ok = pcall(rednet.broadcast, {
      protocole = "FRENCHNET_ADS", version = PROTOCOLE_VERSION,
      type = "MANOEUVRE", navire = contexte.config.identifiant,
      cap = consigne.cap, altitude = consigne.altitude, gaz = consigne.gaz,
      virage = consigne.virage, vertical = consigne.vertical,
      raison = consigne.raison, priorite = "ADS",
    }, contexte.config.protocoleTache)
    contexte.dernieresConsignes = consigne
    if ok then return true, "rednet" end
  end
  pilote.echecs = pilote.echecs + 1
  return false, "aucun canal de commande disponible"
end

--- Lit une grandeur courante du navire via l'interface de pilotage.
local function lirePilote(contexte, commande)
  local pilote = contexte.pilote
  if pilote.mode ~= "peripherique" then return nil end
  local methode = pilote.methodes[commande]
  if not methode then return nil end
  local ok, valeur = pcall(pilote.enveloppe[methode])
  if ok then return valeur end
  return nil
end

------------------------------------------------------------------- largueurs --

--- Prepare les largueurs de leurres declares en configuration.
-- Trois formes acceptees :
--   { type = "redstone",     cote = "left",  impulsionSecondes = 0.4 }
--   { type = "peripherique", nom = "create:deployer_0", methode = "activate" }
--   { type = "rednet",       cible = 42 }   (ordinateur dedie au largage)
local function preparerLargueurs(config)
  local largueurs = {}
  for indice, brut in ipairs(config.largueurs or {}) do
    if type(brut) == "table" then
      local largueur = {
        type = brut.type or "redstone",
        cote = brut.cote, nom = brut.nom, methode = brut.methode or "activate",
        cible = brut.cible, impulsion = brut.impulsionSecondes or 0.4,
        libelle = brut.libelle or ("largueur#" .. indice),
        disponible = false, motif = nil,
      }

      if largueur.type == "redstone" then
        largueur.disponible = type(largueur.cote) == "string" and largueur.cote ~= ""
        largueur.motif = largueur.disponible and nil or "aucun cote redstone declare"
      elseif largueur.type == "peripherique" then
        if type(largueur.nom) == "string" and peripheral.isPresent(largueur.nom) then
          local enveloppe = peripheral.wrap(largueur.nom)
          if enveloppe and type(enveloppe[largueur.methode]) == "function" then
            largueur.enveloppe = enveloppe
            largueur.disponible = true
          else
            largueur.motif = "methode '" .. tostring(largueur.methode) .. "' absente"
          end
        else
          largueur.motif = "peripherique '" .. tostring(largueur.nom) .. "' absent"
        end
      elseif largueur.type == "rednet" then
        largueur.disponible = nombreValide(largueur.cible)
        largueur.motif = largueur.disponible and nil or "aucune cible rednet declaree"
      else
        largueur.motif = "type inconnu '" .. tostring(largueur.type) .. "'"
      end

      largueurs[#largueurs + 1] = largueur
    end
  end
  return largueurs
end

--- Declenche un largueur. L'impulsion redstone est refermee par la boucle
-- d'impulsions : le largage ne doit JAMAIS bloquer la manoeuvre d'evasion.
local function declencherLargueur(contexte, largueur)
  if not largueur.disponible then return false, largueur.motif or "indisponible" end

  if largueur.type == "redstone" then
    local ok = pcall(redstone.setOutput, largueur.cote, true)
    if not ok then return false, "sortie redstone '" .. tostring(largueur.cote) .. "' refusee" end
    programmerImpulsion(contexte, largueur.cote, largueur.impulsion)
    return true
  end

  if largueur.type == "peripherique" then
    local ok, err = pcall(largueur.enveloppe[largueur.methode])
    if not ok then return false, tostring(err) end
    return true
  end

  if largueur.type == "rednet" then
    if not contexte.rednetOuvert then return false, "rednet ferme" end
    local ok = pcall(rednet.send, largueur.cible, {
      protocole = "FRENCHNET_ADS", version = PROTOCOLE_VERSION,
      type = "LARGAGE", navire = contexte.config.identifiant,
    }, contexte.config.protocoleRednet)
    return ok, ok and nil or "envoi rednet refuse"
  end

  return false, "type inconnu"
end

--------------------------------------------------------------------------------
-- 9. POSITION ET ATTITUDE DU NAVIRE
--    Sert (a) a passer du repere absolu au repere navire quand le radar rend
--    des coordonnees du monde, (b) a borner la manoeuvre verticale.
--    Aucune de ces informations n'est vitale : sans GPS ni interface de
--    pilotage, l'ADS travaille en relatif pur et le journal le dit.
--------------------------------------------------------------------------------

local function lirePositionNavire(contexte)
  -- 9a. Interface de pilotage : c'est la source la plus fiable sur un navire
  --     en mouvement, car elle ne depend pas de la constellation GPS.
  local brut = lirePilote(contexte, "lirePos")
  if type(brut) == "table" then
    local x = premierNombre(brut, { "x", 1 })
    local y = premierNombre(brut, { "y", 2 })
    local z = premierNombre(brut, { "z", 3 })
    if x and y and z then return vec.creer(x, y, z), "pilote" end
  end

  -- 9b. Altitude seule : suffisant pour borner la manoeuvre verticale.
  local altitude = lirePilote(contexte, "lireAlt")

  -- 9c. GPS FrenchNet (constellation de balises).
  local ok, x, y, z = pcall(gps.locate, contexte.config.delaiGps or 2, false)
  if ok and nombreValide(x) and nombreValide(y) and nombreValide(z) then
    return vec.creer(x, y, z), "gps"
  end

  if nombreValide(altitude) then
    return vec.creer(0, altitude, 0), "altitude seule"
  end
  return nil, "inconnue"
end

--------------------------------------------------------------------------------
-- 10. PISTAGE RADAR
--     Le radar rend une photographie instantanee : des positions, sans
--     continuite d'un scan a l'autre. Le pistage reconstruit cette continuite
--     (les "pistes"), ce qui est indispensable pour disposer d'une vitesse et
--     d'un historique de rapprochement. Deux modes d'association :
--       - par identifiant, quand le radar en fournit un (ideal) ;
--       - par proximite avec fenetre de validation, sinon : on rattache un
--         echo a la piste dont la position PREDITE est la plus proche, dans la
--         limite de 'pisteRayonAssociation'.
--------------------------------------------------------------------------------

--- Position predite d'une piste a l'instant t (extrapolation lineaire).
local function positionPredite(piste, t)
  if not piste.vitesse then return piste.position end
  return vec.ajouter(piste.position, vec.echelle(piste.vitesse, t - piste.vuA))
end

--- Determine si un contact doit etre traite comme un projectile.
-- Deux voies : le nom (motifs configurables) ou, si le radar ne nomme rien
-- d'exploitable, la cinematique brute (tout ce qui va vite et fonce).
local function classerContact(config, piste)
  if correspondMotif(piste.nom, config.motifsIgnores) then
    return false, "nom ignore"
  end
  if correspondMotif(piste.nom, config.motifsProjectile) then
    return true, "nom"
  end
  if piste.vitesse then
    local vitesse = vec.norme(piste.vitesse)
    if vitesse >= config.vitesseProjectileMini then
      return true, "cinematique"
    end
  end
  return false, "non classe"
end

--- Integre une photographie radar dans le jeu de pistes.
local function mettreAJourPistes(contexte, contacts, maintenant)
  local config = contexte.config
  local pistes = contexte.pistes

  local dejaAssociees = {}

  for _, contact in ipairs(contacts) do
    local piste

    if contact.cle and pistes[contact.cle] then
      piste = pistes[contact.cle]
    else
      -- Association par proximite : on compare a la position PREDITE, sinon
      -- une piste rapide serait systematiquement perdue entre deux scans.
      local meilleureDistance = config.pisteRayonAssociation
      local meilleureCle
      for cle, candidate in pairs(pistes) do
        if not dejaAssociees[cle] and candidate.nom == contact.nom then
          local ecart = vec.norme(vec.soustraire(contact.position,
            positionPredite(candidate, maintenant)))
          if ecart <= meilleureDistance then
            meilleureDistance, meilleureCle = ecart, cle
          end
        end
      end
      if meilleureCle then
        piste = pistes[meilleureCle]
      end
    end

    if not piste then
      contexte.compteurPiste = contexte.compteurPiste + 1
      local cle = contact.cle or ("piste:" .. contexte.compteurPiste)
      piste = {
        cle = cle, nom = contact.nom, echantillons = {},
        vuePremiereFois = maintenant, confirmations = 0,
        rapprochementsConsecutifs = 0, distancePrecedente = nil,
        menacante = false, leurresLarguesA = nil,
      }
      pistes[cle] = piste
    end

    dejaAssociees[piste.cle] = true
    piste.nom      = contact.nom
    piste.position = contact.position
    piste.vuA      = maintenant

    -- Historique borne : au-dela de 'pisteEchantillonsMax', la regression
    -- integrerait des points trop anciens et lisserait une manoeuvre reelle.
    local echantillons = piste.echantillons
    echantillons[#echantillons + 1] = { t = maintenant, p = contact.position }
    while #echantillons > config.pisteEchantillonsMax do table.remove(echantillons, 1) end

    -- Vitesse : celle du radar si elle existe, sinon derivee de l'historique.
    -- La derivee est preferee des que l'historique est fourni : elle est
    -- exprimee dans le meme repere que les positions, donc deja relative.
    local derivee = cinematique.vitesseParRegression(echantillons)
    if derivee and #echantillons >= 3 then
      piste.vitesse = derivee
      piste.sourceVitesse = "derivee"
    elseif contact.vitesseFournie then
      piste.vitesse = contact.vitesseFournie
      piste.sourceVitesse = "radar"
    elseif derivee then
      piste.vitesse = derivee
      piste.sourceVitesse = "derivee"
    end
  end

  -- Expiration des pistes muettes.
  local perdues = {}
  for cle, piste in pairs(pistes) do
    if maintenant - piste.vuA > config.pisteMemoireSecondes then
      perdues[#perdues + 1] = piste
      pistes[cle] = nil
    end
  end
  return perdues
end

--------------------------------------------------------------------------------
-- 11. EVALUATION DE MENACE
--
--     CRITERES RETENUS, ET POURQUOI. Le cahier des charges demande "se
--     rapprocher de facon constante" et "garder une trajectoire alignee".
--     Ces deux criteres sont necessaires mais PAS suffisants : un obus tire
--     sur le navire voisin de la formation se rapproche et parait aligne
--     pendant plusieurs secondes avant de passer a 40 blocs. Declencher
--     dessus, c'est cramer ses leurres et casser une orbite d'attaque pour
--     rien. On ajoute donc les deux seules grandeurs qui tranchent :
--       - la DISTANCE D'APPROCHE MINIMALE (passera-t-il assez pres ?) ;
--       - le TEMPS avant ce passage (est-ce imminent ?).
--     Les quatre criteres doivent tenir simultanement.
--------------------------------------------------------------------------------

local function evaluerMenace(contexte, piste, maintenant)
  local config = contexte.config
  if not piste.vitesse then return nil end

  local mesure = cinematique.approcheMinimale(piste.position, piste.vitesse)
  mesure.alignement = cinematique.alignement(piste.position, piste.vitesse)

  -- Critere 1 : rapprochement franc et constant.
  local seRapproche = mesure.rapprochement >= config.rapprochementMiniBlocsSec
  if seRapproche then
    piste.rapprochementsConsecutifs = piste.rapprochementsConsecutifs + 1
  else
    piste.rapprochementsConsecutifs = 0
  end
  mesure.rapprochementsConsecutifs = piste.rapprochementsConsecutifs

  -- Critere 2 : cap tenu vers le navire.
  mesure.aligne = mesure.alignement >= config.alignementMini
  -- Critere 3 : il passera dans le rayon de menace.
  mesure.dansRayon = mesure.distanceCpa <= config.rayonMenace
  -- Critere 4 : c'est imminent.
  mesure.imminent = mesure.tCpa >= 0 and mesure.tCpa <= config.horizonMenaceSecondes

  mesure.constant = piste.rapprochementsConsecutifs >= config.echantillonsRapprochementMini
  mesure.qualifiee = mesure.constant and mesure.aligne and mesure.dansRayon and mesure.imminent

  -- Urgence : sous 'urgenceSecondes' avant impact, exiger plusieurs scans de
  -- confirmation revient a ne rien faire du tout. On declenche des le premier
  -- scan qualifiant, quitte a larguer quelques leurres pour rien.
  mesure.urgente = mesure.qualifiee and mesure.tCpa <= config.urgenceSecondes

  if mesure.qualifiee then
    piste.confirmations = piste.confirmations + 1
  else
    piste.confirmations = 0
  end
  mesure.confirmations = piste.confirmations

  mesure.declenche = mesure.qualifiee
    and (mesure.urgente or piste.confirmations >= config.confirmationsMini)

  -- Levee de menace : hysteresis, sinon une piste oscillant autour du seuil
  -- ferait entrer et sortir le navire d'evasion plusieurs fois par seconde.
  mesure.leve = (mesure.tCpa < 0)
    or (mesure.distanceCpa > config.rayonMenace * config.hysteresisLevee)
    or (mesure.rapprochement <= 0)

  piste.derniereMesure = mesure
  piste.evalueeA = maintenant
  return mesure
end

--- Compte rendu chiffre d'une piste, pour le journal. C'est ce texte qui
-- permet, apres coup, de comprendre pourquoi l'ADS a reagi ou non.
local function decrirePiste(piste)
  local m = piste.derniereMesure
  if not m then
    return string.format("%s [%s] position (%s, %s, %s) - cinematique indisponible",
      piste.cle, piste.nom, fmt(piste.position.x), fmt(piste.position.y), fmt(piste.position.z))
  end
  return string.format(
    "%s [%s] dist=%sb rapprochement=%sb/s vitesse=%sb/s (%s) alignement=%.3f "
    .. "CPA=%sb dans %ss | rapproche x%d, confirme x%d",
    piste.cle, piste.nom, fmt(m.distance), fmt(m.rapprochement),
    fmt(m.vitesseRelative), piste.sourceVitesse or "?", m.alignement,
    fmt(m.distanceCpa), fmt(m.tCpa, 2),
    m.rapprochementsConsecutifs or 0, m.confirmations or 0)
end

--- Motif detaille d'un non-declenchement, pour tracer les faux negatifs.
local function decrireRejet(config, m)
  local manques = {}
  if not m.constant then
    manques[#manques + 1] = string.format("rapprochement non constant (%d/%d scans, %sb/s < %sb/s requis)",
      m.rapprochementsConsecutifs or 0, config.echantillonsRapprochementMini,
      fmt(m.rapprochement), fmt(config.rapprochementMiniBlocsSec))
  end
  if not m.aligne then
    manques[#manques + 1] = string.format("cap non tenu (alignement %.3f < %.3f)",
      m.alignement, config.alignementMini)
  end
  if not m.dansRayon then
    manques[#manques + 1] = string.format("passera a %sb (rayon de menace %sb)",
      fmt(m.distanceCpa), fmt(config.rayonMenace))
  end
  if not m.imminent then
    manques[#manques + 1] = string.format("non imminent (CPA dans %ss, horizon %ss)",
      fmt(m.tCpa, 2), fmt(config.horizonMenaceSecondes))
  end
  return table.concat(manques, " ; ")
end

--------------------------------------------------------------------------------
-- 12. CONTRE-MESURES : LARGAGE DE LEURRES
--     Premiere des deux reponses immediates. Elle ne vise QUE les projectiles
--     guides : un obus balistique ne regarde rien et ne sera jamais leurre.
--     L'ADS largue quand meme, parce qu'il ne peut pas savoir a coup sur si le
--     projectile entrant est guide, et que le cout d'un leurre est sans commune
--     mesure avec celui du navire.
--------------------------------------------------------------------------------

local function largerSalve(contexte, numeroSalve)
  local config = contexte.config
  local largues, echecs = 0, {}

  local parSalve = math.max(1, math.floor(config.leurresParSalve))
  for numero = 1, parSalve do
    if config.stockLeurres > 0 and contexte.leurresRestants <= 0 then break end
    -- Un largueur mecanique doit se rearmer entre deux cycles ; sans ce court
    -- intervalle, les impulsions se confondent et un seul leurre part.
    if numero > 1 then sleep(0.15) end
    local unTirAuMoins = false
    for _, largueur in ipairs(contexte.largueurs) do
      local ok, motif = declencherLargueur(contexte, largueur)
      if ok then
        unTirAuMoins = true
      else
        echecs[#echecs + 1] = largueur.libelle .. " : " .. tostring(motif)
      end
    end
    if unTirAuMoins then
      largues = largues + 1
      if config.stockLeurres > 0 then
        contexte.leurresRestants = contexte.leurresRestants - 1
      end
    end
  end

  contexte.leurresLargues = contexte.leurresLargues + largues

  if largues > 0 then
    journal.info(ETAPES.LARGAGE_LEURRES, string.format(
      "engagement #%d salve %d/%d : %d leurre(s) largue(s) par %d largueur(s) | "
      .. "stock restant %s | total engagement %d",
      contexte.engagement, numeroSalve, config.salvesParEngagement, largues,
      #contexte.largueurs,
      config.stockLeurres > 0 and tostring(contexte.leurresRestants) or "illimite",
      contexte.leurresLargues))
  end

  if #echecs > 0 then
    journal.avert(ETAPES.LARGAGE_LEURRES, "largueur(s) en defaut -> "
      .. table.concat(echecs, " | "))
  end

  if largues == 0 then
    journal.erreur(ETAPES.LARGAGE_LEURRES, string.format(
      "engagement #%d salve %d : AUCUN leurre largue. Le navire n'a plus que "
      .. "l'evasion pour se defendre.", contexte.engagement, numeroSalve))
  end

  return largues
end

--- Sequence complete de contre-mesures pour un engagement.
local function sequenceLeurres(contexte)
  local config = contexte.config

  if not config.leurresActifs then
    journal.avert(ETAPES.LARGAGE_LEURRES,
      "leurres desactives en configuration : aucune contre-mesure larguee")
    return
  end
  if #contexte.largueurs == 0 then
    journal.erreur(ETAPES.LARGAGE_LEURRES,
      "aucun largueur declare dans 'largueurs' : le navire n'a pas de leurres. "
      .. "Verifiez config_ads.lua.")
    return
  end
  if config.stockLeurres > 0 and contexte.leurresRestants <= 0 then
    journal.erreur(ETAPES.LARGAGE_LEURRES, string.format(
      "SOUTE A LEURRES VIDE (stock declare %d) : engagement #%d mene a l'evasion seule. "
      .. "Ravitaillez le navire.", config.stockLeurres, contexte.engagement))
    return
  end

  local salves = math.max(1, math.floor(config.salvesParEngagement))
  for numero = 1, salves do
    -- Chaque salve est protegee : un largueur casse ne doit pas interrompre
    -- la sequence, encore moins la manoeuvre d'evasion qui tourne en parallele.
    proteger(ETAPES.LARGAGE_LEURRES, largerSalve, contexte, numero)
    if numero < salves then sleep(config.intervalleSalveSecondes) end
    if contexte.etat ~= ETAT_MENACE then
      journal.info(ETAPES.LARGAGE_LEURRES, string.format(
        "sequence de leurres interrompue apres %d/%d salve(s) : menace levee",
        numero, salves))
      return
    end
  end
end

--------------------------------------------------------------------------------
-- 13. MANOEUVRE D'EVASION
--     Seconde reponse immediate, simultanee de la premiere. Elle est
--     PRIORITAIRE : elle prend la main sur la tache en cours (orbite d'attaque,
--     navigation, livraison) et ne la rend qu'apres la levee de menace.
--------------------------------------------------------------------------------

--- Sens de barre a donner pour rejoindre 'capCible' depuis 'capActuel'.
-- Renvoie nil si le cap courant est inconnu (mode redstone sans retour d'etat).
local function sensVirage(capActuel, capCible)
  if not nombreValide(capActuel) or not nombreValide(capCible) then return nil end
  local ecart = cinematique.normaliserCap(capCible - capActuel)
  if math.abs(ecart) < 1 then return nil, ecart end
  -- Yaw croissant = rotation vers l'ouest = virage a babord dans la convention
  -- Minecraft (yaw 0 sud, +90 ouest).
  return (ecart > 0) and "babord" or "tribord", ecart
end

--- Calcule et applique une consigne d'evasion face a la piste menacante.
-- Recalcule a chaque passage : un missile guide corrige, l'axe optimal bouge.
local function manoeuvrerContre(contexte, piste)
  local config = contexte.config
  if not piste or not piste.vitesse then return false end

  local altitudeCourante = contexte.altitude
  local margeSecurite = math.max(2, config.amplitudeAltitudeBlocs * 0.25)

  -- Filtre : interdit de se degager vers le sol ou au-dessus du plafond.
  local function autorise(candidat)
    if math.abs(candidat.verticale) < 0.2 then return true end -- degagement lateral
    if not nombreValide(altitudeCourante) then return true end -- altitude inconnue
    local vise = altitudeCourante + candidat.verticale * config.amplitudeAltitudeBlocs
    return vise >= (config.altitudeMin + margeSecurite)
       and vise <= (config.altitudeMax - margeSecurite)
  end

  local meilleur, candidats = cinematique.axeEvasion(piste.position, piste.vitesse,
    config.vitesseEvasionEstimee, autorise)

  -- Preference declaree : on privilegie une famille d'axes tant qu'elle reste
  -- a moins de 20 % du meilleur gain, pour respecter les habitudes du navire
  -- (un dirigeable lourd vire mal mais plonge bien, et inversement).
  if meilleur and config.preferenceEvasion ~= "auto" then
    local horizontale = (config.preferenceEvasion == "horizontale")
    for _, candidat in ipairs(candidats) do
      local estHorizontal = math.abs(candidat.verticale) < 0.2
      if candidat.autorise and estHorizontal == horizontale
         and candidat.distanceCpa >= meilleur.distanceCpa * 0.8
         and candidat ~= meilleur then
        meilleur = candidat
        break
      end
    end
  end

  if not meilleur then
    journal.erreur(ETAPES.MANOEUVRE_EVASION, string.format(
      "aucun axe de degagement praticable (altitude %s, plancher %s, plafond %s) : "
      .. "le navire subit l'impact. Elargissez altitudeMin/altitudeMax.",
      fmt(altitudeCourante), fmt(config.altitudeMin), fmt(config.altitudeMax)))
    return false
  end

  -- Detail complet des options : indispensable pour rejouer une interception
  -- ratee et comprendre pourquoi l'ADS a choisi cet axe-la.
  local detail = {}
  for _, candidat in ipairs(candidats) do
    detail[#detail + 1] = string.format("%s CPA=%sb%s", candidat.nom,
      fmt(candidat.distanceCpa), candidat.autorise and "" or " (interdit)")
  end
  journal.debug(ETAPES.MANOEUVRE_EVASION, "axes evalues -> " .. table.concat(detail, " | "))

  local capCible = meilleur.cap
  local capActuel = contexte.cap
  local virage, ecartCap = sensVirage(capActuel, capCible)

  -- Montage purement redstone : sans retour de cap, l'ecart de cap est
  -- incalculable, donc le sens de barre aussi. Ne rien faire serait le pire
  -- des choix : une embardee d'un cote quelconque vaut toujours mieux qu'une
  -- trajectoire rectiligne devant un autoguidage. On tranche donc de facon
  -- deterministe, et on le dit une fois pour toutes dans le journal.
  if not virage and not nombreValide(capActuel) and contexte.pilote.mode == "redstone" then
    virage = (meilleur.nom == "lateral+") and "tribord" or "babord"
    if not contexte.avertCapInconnu then
      contexte.avertCapInconnu = true
      journal.avert(ETAPES.MANOEUVRE_EVASION,
        "aucun retour de cap disponible en pilotage redstone : le sens de barre "
        .. "est choisi arbitrairement. Cablez un retour de cap ou passez en "
        .. "pilotage par peripherique pour un degagement du bon cote.")
    end
  end

  -- Virage franc : on borne l'ordre a 'amplitudeVirageDegres' pour eviter de
  -- demander au navire un demi-tour qu'il mettra dix secondes a executer.
  if nombreValide(ecartCap) and math.abs(ecartCap) > config.amplitudeVirageDegres then
    capCible = cinematique.normaliserCap(capActuel
      + (ecartCap > 0 and 1 or -1) * config.amplitudeVirageDegres)
  end

  local altitudeCible
  local vertical
  if math.abs(meilleur.verticale) >= 0.2 then
    vertical = (meilleur.verticale > 0) and "montee" or "plongee"
    if nombreValide(altitudeCourante) then
      altitudeCible = altitudeCourante + meilleur.verticale * config.amplitudeAltitudeBlocs
      local plafond = config.altitudeMax - margeSecurite
      local plancher = config.altitudeMin + margeSecurite
      local brute = altitudeCible
      altitudeCible = math.max(plancher, math.min(plafond, altitudeCible))
      if math.abs(brute - altitudeCible) > 0.5 then
        journal.avert(ETAPES.MANOEUVRE_EVASION, string.format(
          "degagement vertical ecrete : %sb demande, %sb autorise (plancher %s / plafond %s)",
          fmt(brute), fmt(altitudeCible), fmt(config.altitudeMin), fmt(config.altitudeMax)))
      end
    end
  end

  local consigne = {
    cap = capCible, altitude = altitudeCible,
    gaz = config.pleinGazEnEvasion and 1 or nil,
    virage = virage, vertical = vertical,
    duree = config.intervalleManoeuvreSecondes,
    raison = "evasion ADS engagement #" .. contexte.engagement,
  }

  local ok, comment = appliquerConsigne(contexte, consigne)
  local mesure = piste.derniereMesure or {}

  journal.info(ETAPES.MANOEUVRE_EVASION, string.format(
    "engagement #%d : degagement '%s' | cap %s -> %s (%s) | altitude %s -> %s (%s) | "
    .. "CPA attendu %sb au lieu de %sb | impact estime dans %ss | commande %s (%s)",
    contexte.engagement, meilleur.nom,
    fmt(capActuel), fmt(capCible), virage or "cap direct",
    fmt(altitudeCourante), fmt(altitudeCible), vertical or "palier",
    fmt(meilleur.distanceCpa), fmt(mesure.distanceCpa), fmt(mesure.tCpa, 2),
    ok and "acceptee" or "REFUSEE", tostring(comment)))

  if not ok then
    journal.erreur(ETAPES.MANOEUVRE_EVASION,
      "la consigne d'evasion n'a pas pu etre transmise au navire (" .. tostring(comment)
      .. ") : verifiez 'piloteMode' et le cablage dans config_ads.lua")
  end

  contexte.manoeuvres = contexte.manoeuvres + 1
  return ok
end

--------------------------------------------------------------------------------
-- 14. TACHE EN COURS : SAUVEGARDE, PREEMPTION, REPRISE
--
--     CONTRAT DE PRIORITE. L'ADS ne connait pas les programmes de livraison,
--     de scramble ou d'orbite d'attaque, et n'a pas a les connaitre. Il publie
--     sa priorite de trois facons complementaires, et n'importe laquelle suffit :
--       1. VERROU FICHIER  /ads/.priorite_ads   -> present tant que l'ADS a la
--          main. Tout programme tournant sur le MEME ordinateur n'a qu'a tester
--          fs.exists() avant d'envoyer une commande de vol.
--       2. MESSAGE REDNET  type = "PREEMPTION" / "REPRISE" sur le protocole
--          'protocoleTache' -> pour les programmes tournant sur un AUTRE
--          ordinateur du meme navire.
--       3. RESTITUTION DIRECTE des consignes de vol relevees avant l'alerte
--          (cap, altitude, gaz) -> filet de securite si personne n'ecoute.
--     L'ADS ne recoit d'ordre de personne : il ne s'agit pas d'une negociation.
--------------------------------------------------------------------------------

local function lireFichierTache(contexte)
  local chemin = fs.combine(REPERTOIRE, contexte.config.fichierTache)
  if not fs.exists(chemin) then return nil end
  local fichier = fs.open(chemin, "r")
  if not fichier then return nil end
  local source = fichier.readAll()
  fichier.close()
  local morceau = load(source, "@" .. chemin, "t", {})
  if not morceau then return nil end
  local ok, valeur = pcall(morceau)
  if ok and type(valeur) == "table" then return valeur end
  return nil
end

--- Demande sa tache courante au programme de navigation, par rednet.
local function demanderTacheRednet(contexte)
  if not contexte.rednetOuvert then return nil end
  local config = contexte.config
  local ok = pcall(rednet.broadcast, {
    protocole = "FRENCHNET_ADS", version = PROTOCOLE_VERSION,
    type = "DEMANDE_TACHE", navire = config.identifiant,
  }, config.protocoleTache)
  if not ok then return nil end

  local limite = os.clock() + config.delaiInterrogationTache
  while os.clock() < limite do
    local okRecu, _, message = pcall(rednet.receive, config.protocoleTache,
      math.max(0.1, limite - os.clock()))
    if not okRecu then return nil end
    if type(message) == "table" and message.type == "TACHE"
       and type(message.tache) == "table" then
      return message.tache
    end
    if message == nil then return nil end -- timeout de rednet.receive
  end
  return nil
end

--- Photographie de ce que faisait le navire avant l'alerte.
local function capturerTache(contexte)
  local instantane = {
    a          = os.clock(),
    cap        = contexte.cap,
    altitude   = contexte.altitude,
    gaz        = contexte.gaz,
    tache      = nil,
    source     = "consignes de vol",
  }

  local tache = lireFichierTache(contexte)
  if tache then
    instantane.tache = tache
    instantane.source = contexte.config.fichierTache
  else
    tache = demanderTacheRednet(contexte)
    if tache then
      instantane.tache = tache
      instantane.source = "rednet " .. contexte.config.protocoleTache
    end
  end
  return instantane
end

local function decrireTache(instantane)
  if not instantane then return "aucune tache connue" end
  local t = instantane.tache
  local nom = t and (t.nom or t.name or t.type or t.tache) or nil
  local details = {}
  if nom then details[#details + 1] = "tache '" .. tostring(nom) .. "'" end
  if t and t.destination then
    local d = t.destination
    if type(d) == "table" and d.x then
      details[#details + 1] = string.format("destination (%s, %s, %s)",
        fmt(d.x, 0), fmt(d.y, 0), fmt(d.z, 0))
    else
      details[#details + 1] = "destination " .. tostring(d)
    end
  end
  details[#details + 1] = string.format("cap %s", fmt(instantane.cap))
  details[#details + 1] = string.format("altitude %s", fmt(instantane.altitude))
  if instantane.gaz then details[#details + 1] = string.format("gaz %s", fmt(instantane.gaz, 2)) end
  details[#details + 1] = "source " .. tostring(instantane.source)
  return table.concat(details, ", ")
end

--- Prend la main sur le navire. Idempotent.
local function preempterTache(contexte, piste)
  if contexte.priorite then return end
  contexte.priorite = true

  local instantane = contexte.tacheSauvegardee
  if not instantane then
    -- Cas limite : l'alerte est tombee avant la premiere sauvegarde. On
    -- photographie a la volee, sans interroger le reseau (trop lent ici).
    instantane = {
      a = os.clock(), cap = contexte.cap, altitude = contexte.altitude,
      gaz = contexte.gaz, source = "releve d'urgence",
    }
    contexte.tacheSauvegardee = instantane
    journal.avert(ETAPES.SAUVEGARDE_TACHE,
      "aucune sauvegarde de tache disponible au moment de l'alerte : "
      .. "seules les consignes de vol courantes seront restituees")
  end

  proteger(ETAPES.PREEMPTION_TACHE, function()
    local fichier = fs.open(VERROU_PRIORITE, "w")
    if fichier then
      fichier.writeLine(horodatage())
      fichier.writeLine("engagement=" .. contexte.engagement)
      fichier.close()
    end
  end)

  if contexte.rednetOuvert then
    proteger(ETAPES.PREEMPTION_TACHE, function()
      rednet.broadcast({
        protocole = "FRENCHNET_ADS", version = PROTOCOLE_VERSION,
        type = "PREEMPTION", navire = contexte.config.identifiant,
        engagement = contexte.engagement, raison = "menace entrante",
        menace = piste and { nom = piste.nom, cle = piste.cle } or nil,
      }, contexte.config.protocoleTache)
    end)
  end

  journal.info(ETAPES.PREEMPTION_TACHE, string.format(
    "engagement #%d : l'ADS prend la priorite sur la tache en cours (%s). "
    .. "Verrou '%s' pose, preemption diffusee sur '%s'.",
    contexte.engagement, decrireTache(instantane), VERROU_PRIORITE,
    contexte.config.protocoleTache))
end

--- Rend la main a la tache interrompue. Idempotent.
local function reprendreTache(contexte)
  if not contexte.priorite then return end
  local instantane = contexte.tacheSauvegardee
  local config = contexte.config

  proteger(ETAPES.REPRISE_TACHE, function()
    if fs.exists(VERROU_PRIORITE) then fs.delete(VERROU_PRIORITE) end
  end)

  if contexte.rednetOuvert then
    proteger(ETAPES.REPRISE_TACHE, function()
      rednet.broadcast({
        protocole = "FRENCHNET_ADS", version = PROTOCOLE_VERSION,
        type = "REPRISE", navire = config.identifiant,
        engagement = contexte.engagement,
        tache = instantane and instantane.tache or nil,
        cap = instantane and instantane.cap or nil,
        altitude = instantane and instantane.altitude or nil,
        gaz = instantane and instantane.gaz or nil,
      }, config.protocoleTache)
    end)
  end

  -- Restitution directe des consignes de vol : filet de securite si aucun
  -- programme de navigation n'ecoute (navire pilote uniquement par l'ADS).
  if config.reprendreTache and instantane then
    local consigne = {
      cap = instantane.cap, altitude = instantane.altitude, gaz = instantane.gaz,
      raison = "reprise apres engagement #" .. contexte.engagement,
    }
    if consigne.cap or consigne.altitude or consigne.gaz then
      local ok, comment = appliquerConsigne(contexte, consigne)
      if not ok then
        journal.avert(ETAPES.REPRISE_TACHE,
          "consignes de vol non restituees (" .. tostring(comment)
          .. ") : la reprise repose sur le programme de navigation")
      end
    end
  end

  contexte.priorite = false
  contexte.tacheSauvegardee = nil

  journal.info(ETAPES.REPRISE_TACHE, string.format(
    "engagement #%d clos : controle rendu a la tache normale (%s). Verrou leve.",
    contexte.engagement, decrireTache(instantane)))
end

--------------------------------------------------------------------------------
-- 15. BOUCLES CONCURRENTES
--------------------------------------------------------------------------------

--- Choix du repere des coordonnees rendues par le radar.
-- Create Radars rend selon les versions des coordonnees du monde ou des
-- coordonnees relatives a l'antenne. Se tromper inverse completement la
-- geometrie, donc on tranche sur des ordres de grandeur puis on le journalise.
local function determinerRepere(contexte, contacts)
  local config = contexte.config
  if config.radarRepere ~= "auto" then return config.radarRepere end
  if contexte.repereRetenu then return contexte.repereRetenu end
  if #contacts == 0 then return nil end

  local normeMax = 0
  for _, contact in ipairs(contacts) do
    normeMax = math.max(normeMax, vec.norme(contact.position))
  end

  local repere
  local justification
  if contexte.positionNavire then
    local ecartMax = 0
    for _, contact in ipairs(contacts) do
      ecartMax = math.max(ecartMax,
        vec.norme(vec.soustraire(contact.position, contexte.positionNavire)))
    end
    if ecartMax <= config.radarPortee * 2 and normeMax > config.radarPortee * 4 then
      repere, justification = "absolu", string.format(
        "les contacts sont a %sb du navire mais a %sb de l'origine du monde",
        fmt(ecartMax), fmt(normeMax))
    else
      repere, justification = "relatif", string.format(
        "les contacts sont a %sb de l'origine des coordonnees rendues", fmt(normeMax))
    end
  else
    repere = (normeMax > config.radarPortee * 4) and "absolu" or "relatif"
    justification = string.format("norme maximale observee %sb pour une portee de %sb "
      .. "(position du navire inconnue)", fmt(normeMax), fmt(config.radarPortee))
  end

  contexte.repereRetenu = repere
  journal.info(ETAPES.SCAN_RADAR, string.format(
    "repere radar retenu automatiquement : %s (%s). Forcez 'radarRepere' dans "
    .. "config_ads.lua si ce choix est faux.", repere, justification))
  return repere
end

--- Un scan : lecture du radar, normalisation, passage dans le repere navire.
local function scannerRadar(contexte)
  local brut = contexte.radar[contexte.methodeScan]()
  if type(brut) ~= "table" then
    error("la methode '" .. contexte.methodeScan .. "' n'a pas renvoye de table", 0)
  end

  local contacts = {}
  local rejetes = 0
  for indice, enregistrement in ipairs(brut) do
    local contact = normaliserContact(enregistrement, indice)
    if contact then contacts[#contacts + 1] = contact else rejetes = rejetes + 1 end
  end
  if rejetes > 0 and not contexte.rejetSignale then
    contexte.rejetSignale = true
    journal.avert(ETAPES.SCAN_RADAR, string.format(
      "%d contact(s) radar sans coordonnees exploitables : le format rendu par "
      .. "'%s' n'est pas reconnu. Journalisez un scan avec journalNiveauEcran = "
      .. "\"DEBUG\" pour identifier les cles a ajouter.", rejetes, contexte.methodeScan))
  end

  local repere = determinerRepere(contexte, contacts)
  if repere == "absolu" then
    if not contexte.positionNavire then
      if not contexte.avertRepereAbsolu then
        contexte.avertRepereAbsolu = true
        journal.avert(ETAPES.SCAN_RADAR,
          "coordonnees radar absolues mais position du navire inconnue : les "
          .. "contacts sont traites en relatif, la geometrie sera fausse. "
          .. "Verifiez la constellation GPS ou l'interface de pilotage.")
      end
    else
      for _, contact in ipairs(contacts) do
        contact.position = vec.soustraire(contact.position, contexte.positionNavire)
      end
    end
  end

  contexte.scans = contexte.scans + 1
  contexte.dernierScan = os.clock()
  contexte.contactsVus = #contacts
  return contacts
end

--- Evalue toutes les pistes et renvoie les menaces qualifiees, la plus
-- urgente en tete.
local function analyserPistes(contexte, maintenant)
  local config = contexte.config
  local menaces = {}

  for _, piste in pairs(contexte.pistes) do
    local projectile, motif = classerContact(config, piste)
    piste.projectile = projectile

    if projectile and not piste.signalee then
      piste.signalee = true
      journal.info(ETAPES.PISTAGE, string.format(
        "nouveau contact classe PROJECTILE (%s) -> %s", motif, decrirePiste(piste)))
    end

    if projectile then
      local mesure = evaluerMenace(contexte, piste, maintenant)
      if mesure then
        piste.distanceMini = math.min(piste.distanceMini or mesure.distance, mesure.distance)
        journal.debug(ETAPES.EVALUATION_MENACE, decrirePiste(piste))

        if mesure.declenche then
          menaces[#menaces + 1] = piste
        elseif mesure.qualifiee and not piste.preavis then
          piste.preavis = true
          journal.avert(ETAPES.EVALUATION_MENACE, string.format(
            "piste qualifiee, confirmation en cours (%d/%d scans) -> %s",
            mesure.confirmations, config.confirmationsMini, decrirePiste(piste)))
        elseif not mesure.qualifiee and piste.preavis then
          piste.preavis = false
          journal.info(ETAPES.EVALUATION_MENACE, string.format(
            "piste declassee avant declenchement : %s -> %s",
            decrireRejet(config, mesure), decrirePiste(piste)))
        end
      end
    end
  end

  table.sort(menaces, function(a, b)
    return (a.derniereMesure.tCpa or math.huge) < (b.derniereMesure.tCpa or math.huge)
  end)
  return menaces
end

--- Motif de levee de la menace principale, ou nil si elle tient toujours.
local function menaceLevee(contexte, maintenant)
  local piste = contexte.menacePrincipale
  local config = contexte.config
  if not piste then return "piste inexistante" end
  if contexte.pistes[piste.cle] ~= piste then
    return "contact disparu du radar (piste expiree)"
  end
  if maintenant - piste.vuA > config.perteContactSecondes then
    return string.format("echo perdu depuis %ss", fmt(maintenant - piste.vuA, 2))
  end
  local m = piste.derniereMesure
  if m and m.leve then
    -- Attention a l'ordre : au scan exact du point le plus proche, tCpa et le
    -- taux de rapprochement valent tous les deux zero. Annoncer "s'eloigne a
    -- 0.0 b/s" serait faux et rendrait le journal ininterpretable.
    if m.rapprochement < -0.5 then
      return string.format("projectile s'eloigne (%sb/s, distance %sb)",
        fmt(-m.rapprochement), fmt(m.distance))
    end
    if m.tCpa <= 0 or m.rapprochement <= 0 then
      return string.format("projectile passe au plus pres (distance %sb, rapprochement %sb/s)",
        fmt(m.distance), fmt(m.rapprochement))
    end
    return string.format("trajectoire divergente : passera a %sb (seuil de levee %sb)",
      fmt(m.distanceCpa), fmt(config.rayonMenace * config.hysteresisLevee))
  end
  return nil
end

--- 15a. Surveillance radar : le coeur du systeme.
local function boucleRadar(contexte)
  local config = contexte.config
  while true do
    local ok, contacts = proteger(ETAPES.SCAN_RADAR, scannerRadar, contexte)

    if ok then
      contexte.echecsScan = 0
      local maintenant = os.clock()

      local okPistage, perdues = proteger(ETAPES.PISTAGE,
        mettreAJourPistes, contexte, contacts, maintenant)
      if okPistage and perdues then
        for _, piste in ipairs(perdues) do
          if piste.projectile then
            journal.info(ETAPES.PISTAGE, string.format(
              "piste perdue apres %ss de silence : %s",
              fmt(config.pisteMemoireSecondes), decrirePiste(piste)))
          end
        end
      end

      local okAnalyse, menaces = proteger(ETAPES.EVALUATION_MENACE,
        analyserPistes, contexte, maintenant)
      menaces = (okAnalyse and menaces) or {}

      -------------------------------------------------------- machine a etats
      -- L'inhibition n'est possible que si elle a ete explicitement autorisee
      -- en configuration ; par defaut aucun ordre exterieur ne desarme l'ADS.
      if contexte.inhibe and #menaces > 0 then
        journal.avert(ETAPES.ALERTE_MENACE, string.format(
          "ADS INHIBE : %d menace(s) qualifiee(s) ignoree(s) -> %s",
          #menaces, decrirePiste(menaces[1])))
        menaces = {}
      end

      if contexte.etat == ETAT_VEILLE or contexte.etat == ETAT_DEGAGEMENT then
        if #menaces > 0 then
          local principale = menaces[1]
          local reengagement = (contexte.etat == ETAT_DEGAGEMENT)
          if not reengagement then
            contexte.engagement = contexte.engagement + 1
            contexte.manoeuvres = 0
          end
          contexte.etat = ETAT_MENACE
          contexte.menacePrincipale = principale
          contexte.menaceDepuis = maintenant
          contexte.alertesTotales = contexte.alertesTotales + 1

          journal.critique(ETAPES.ALERTE_MENACE, string.format(
            "MENACE ENTRANTE%s - engagement #%d | %s | %d piste(s) qualifiee(s) | "
            .. "declenchement %s",
            reengagement and " (nouvelle menace pendant le degagement)" or "",
            contexte.engagement, decrirePiste(principale), #menaces,
            principale.derniereMesure.urgente and "IMMEDIAT (urgence)"
              or ("apres " .. principale.derniereMesure.confirmations .. " confirmations")))

          -- Les deux reponses sont declenchees par le meme evenement, donc au
          -- meme instant : largage de leurres ET manoeuvre d'evasion.
          os.queueEvent("ads_alerte", contexte.engagement)
        elseif maintenant - (contexte.degagementDepuis or maintenant)
               >= config.delaiSecuriteSecondes and contexte.etat == ETAT_DEGAGEMENT then
          contexte.etat = ETAT_REPRISE
          journal.info(ETAPES.FIN_MENACE, string.format(
            "delai de securite de %ss ecoule sans nouvelle menace : reprise demandee",
            fmt(config.delaiSecuriteSecondes)))
          os.queueEvent("ads_reprise", contexte.engagement)
        end

      elseif contexte.etat == ETAT_MENACE then
        local motif = menaceLevee(contexte, maintenant)
        if not motif then
          -- La menace tient. On bascule sur plus urgent si necessaire.
          if #menaces > 0 and menaces[1] ~= contexte.menacePrincipale then
            journal.avert(ETAPES.EVALUATION_MENACE, string.format(
              "menace prioritaire reaffectee : %s remplace %s",
              menaces[1].cle, contexte.menacePrincipale.cle))
            contexte.menacePrincipale = menaces[1]
          end
        elseif #menaces > 0 then
          journal.info(ETAPES.FIN_MENACE, string.format(
            "menace #%s levee (%s) mais %d autre(s) menace(s) active(s) : "
            .. "l'evasion continue", contexte.menacePrincipale.cle, motif, #menaces))
          contexte.menacePrincipale = menaces[1]
        else
          local piste = contexte.menacePrincipale
          journal.info(ETAPES.FIN_MENACE, string.format(
            "MENACE LEVEE - engagement #%d | motif : %s | piste %s [%s] | "
            .. "distance minimale observee %sb | duree %ss | %d manoeuvre(s) | "
            .. "%d leurre(s) largue(s) au total",
            contexte.engagement, motif, piste.cle, piste.nom,
            fmt(piste.distanceMini), fmt(maintenant - contexte.menaceDepuis, 1),
            contexte.manoeuvres, contexte.leurresLargues))
          contexte.etat = ETAT_DEGAGEMENT
          contexte.degagementDepuis = maintenant
          contexte.menacePrincipale = nil
          journal.info(ETAPES.FIN_MENACE, string.format(
            "degagement en cours : maintien de la manoeuvre pendant %ss avant reprise",
            fmt(config.delaiSecuriteSecondes)))
        end
      end
    else
      contexte.echecsScan = contexte.echecsScan + 1
      contexte.erreursTotales = contexte.erreursTotales + 1
      if contexte.echecsScan >= config.radarEchecsAvantReinit then
        error("ETAPE[" .. ETAPES.SCAN_RADAR .. "] " .. contexte.echecsScan
          .. " scans radar en echec consecutifs : reinitialisation du materiel", 0)
      end
    end

    sleep(config.intervalleScanSecondes)
  end
end

--- 15b. Contre-mesures : reagit a l'alerte, en parallele de l'evasion.
local function boucleLeurres(contexte)
  while true do
    local _, engagement = os.pullEvent("ads_alerte")
    if contexte.dernierEngagementLeurre ~= engagement
       or (os.clock() - (contexte.dernierLargageA or -1e9))
          >= contexte.config.delaiReengagementSecondes then
      contexte.dernierEngagementLeurre = engagement
      contexte.dernierLargageA = os.clock()
      journal.info(ETAPES.LARGAGE_LEURRES, string.format(
        "engagement #%d : declenchement des contre-mesures", engagement))
      proteger(ETAPES.LARGAGE_LEURRES, sequenceLeurres, contexte)
    else
      journal.debug(ETAPES.LARGAGE_LEURRES, string.format(
        "engagement #%d : largage inhibe (delai de reengagement non ecoule)", engagement))
    end
  end
end

--- 15c. Evasion : prend la priorite, manoeuvre, puis restitue la tache.
local function boucleEngagement(contexte)
  local config = contexte.config
  while true do
    os.pullEvent("ads_alerte")

    local evasion = config.evasionActive and true or false
    if not evasion then
      journal.avert(ETAPES.MANOEUVRE_EVASION,
        "evasion desactivee en configuration : le navire ne manoeuvre pas, "
        .. "seules les contre-mesures sont larguees")
    else
      proteger(ETAPES.PREEMPTION_TACHE, preempterTache, contexte,
        contexte.menacePrincipale)
    end

    -- Cette attente tourne meme sans evasion : c'est elle qui consomme l'etat
    -- REPRISE pose par la boucle radar, donc qui referme l'engagement.
    -- Manoeuvre entretenue : un projectile guide corrige sa trajectoire,
    -- l'axe de degagement optimal se deplace donc en permanence.
    local periode = math.max(0.2, config.intervalleManoeuvreSecondes)
    while contexte.etat == ETAT_MENACE or contexte.etat == ETAT_DEGAGEMENT do
      if evasion then
        proteger(ETAPES.MANOEUVRE_EVASION, function()
          contexte.cap   = lirePilote(contexte, "lireCap") or contexte.cap
          local altitude = lirePilote(contexte, "lireAlt")
          if nombreValide(altitude) then contexte.altitude = altitude end
          contexte.gaz   = lirePilote(contexte, "lireGaz") or contexte.gaz
        end)
        if contexte.menacePrincipale then
          proteger(ETAPES.MANOEUVRE_EVASION, manoeuvrerContre, contexte,
            contexte.menacePrincipale)
        end
      end
      sleep(periode)
    end

    if evasion then
      proteger(ETAPES.REPRISE_TACHE, reprendreTache, contexte)
    end

    if contexte.etat ~= ETAT_MENACE then
      contexte.etat = ETAT_VEILLE
      journal.info(ETAPES.REPRISE_TACHE, string.format(
        "engagement #%d termine : retour en VEILLE, surveillance radar nominale",
        contexte.engagement))
    end
  end
end

--- 15d. Sauvegarde periodique de la tache en cours.
--       Uniquement en VEILLE : sauvegarder pendant une evasion enregistrerait
--       la manoeuvre elle-meme comme "tache a reprendre", ce qui condamnerait
--       le navire a tourner en rond apres l'engagement.
local function boucleTache(contexte)
  local config = contexte.config
  while true do
    if contexte.etat == ETAT_VEILLE and not contexte.priorite then
      proteger(ETAPES.SAUVEGARDE_TACHE, function()
        contexte.cap   = lirePilote(contexte, "lireCap") or contexte.cap
        contexte.gaz   = lirePilote(contexte, "lireGaz") or contexte.gaz
        local altitude = lirePilote(contexte, "lireAlt")
        if nombreValide(altitude) then contexte.altitude = altitude end

        local instantane = capturerTache(contexte)
        local avant = contexte.tacheSauvegardee
        contexte.tacheSauvegardee = instantane

        local descriptionAvant = avant and decrireTache(avant) or nil
        local description = decrireTache(instantane)
        if descriptionAvant ~= description then
          journal.debug(ETAPES.SAUVEGARDE_TACHE, "tache courante sauvegardee : " .. description)
        end
      end)
    end
    sleep(math.max(1, config.rafraichirTacheSecondes))
  end
end

--- 15e. Fermeture des impulsions redstone (largueurs et commandes de vol).
--       Une sortie laissee a true bloquerait le largueur suivant.
local function boucleImpulsions(contexte)
  while true do
    local maintenant = os.clock()
    local restantes = {}
    for _, impulsion in ipairs(contexte.impulsions) do
      if maintenant >= impulsion.fin then
        pcall(redstone.setOutput, impulsion.cote, false)
      else
        restantes[#restantes + 1] = impulsion
      end
    end
    contexte.impulsions = restantes
    sleep(0.1)
  end
end

--- 15f. Position absolue du navire (lente : gps.locate est bloquant).
--       Utile uniquement si le radar rend des coordonnees du monde.
local function bouclePositionNavire(contexte)
  while true do
    local ok, position, source = proteger(ETAPES.POSITION_NAVIRE,
      lirePositionNavire, contexte)
    if ok and position then
      if source ~= "altitude seule" then
        contexte.positionNavire = position
      end
      if nombreValide(position.y) then contexte.altitude = position.y end
      if contexte.sourcePosition ~= source then
        contexte.sourcePosition = source
        journal.info(ETAPES.POSITION_NAVIRE, string.format(
          "position du navire par '%s' : X=%s Y=%s Z=%s",
          source, fmt(position.x), fmt(position.y), fmt(position.z)))
      end
    elseif contexte.sourcePosition ~= "inconnue" then
      contexte.sourcePosition = "inconnue"
      journal.avert(ETAPES.POSITION_NAVIRE,
        "position du navire indisponible : l'ADS reste operationnel en repere "
        .. "relatif, mais les bornes d'altitude ne peuvent plus etre respectees")
    end
    sleep(5)
  end
end

--- 15g. Telemetrie : etat de l'ADS diffuse pour les consoles de supervision.
local function boucleTelemetrie(contexte)
  local config = contexte.config
  while true do
    sleep(config.intervalleTelemetrieSecondes)
    if contexte.rednetOuvert then
      proteger(ETAPES.TELEMETRIE, function()
        local piste = contexte.menacePrincipale
        local mesure = piste and piste.derniereMesure or nil
        rednet.broadcast({
          protocole   = "FRENCHNET_ADS", version = PROTOCOLE_VERSION,
          programme   = VERSION_PROGRAMME, type = "ETAT",
          navire      = config.identifiant, designation = config.designation,
          idOrdinateur = os.getComputerID(),
          etat        = contexte.etat, priorite = contexte.priorite,
          engagement  = contexte.engagement, alertes = contexte.alertesTotales,
          leurres     = contexte.leurresLargues,
          leurresRestants = config.stockLeurres > 0 and contexte.leurresRestants or nil,
          manoeuvres  = contexte.manoeuvres, scans = contexte.scans,
          contacts    = contexte.contactsVus, erreurs = contexte.erreursTotales,
          cap = contexte.cap, altitude = contexte.altitude,
          menace = piste and {
            nom = piste.nom, cle = piste.cle,
            distance = mesure and mesure.distance or nil,
            tCpa = mesure and mesure.tCpa or nil,
            distanceCpa = mesure and mesure.distanceCpa or nil,
          } or nil,
          fonctionnement = math.floor(os.clock() - contexte.demarrageHorloge),
        }, config.protocoleRednet)
      end)
    end
  end
end

--- 15h. Surveillance materielle et battement de coeur.
local function boucleSurveillance(contexte)
  local config = contexte.config
  while true do
    sleep(math.max(5, math.min(config.battementSecondes, 30)))

    exigerEtape(ETAPES.SURVEILLANCE, function()
      if not peripheral.isPresent(contexte.nomRadar) then
        error("le radar '" .. contexte.nomRadar .. "' a disparu du navire", 0)
      end
      local silence = os.clock() - (contexte.dernierScan or 0)
      if silence > math.max(10, config.intervalleScanSecondes * 40) then
        error(string.format("aucun scan radar exploite depuis %ss", fmt(silence)), 0)
      end
    end)

    local maintenant = os.clock()
    if maintenant - contexte.dernierBattement >= config.battementSecondes then
      contexte.dernierBattement = maintenant
      local nbPistes, nbProjectiles = 0, 0
      for _, piste in pairs(contexte.pistes) do
        nbPistes = nbPistes + 1
        if piste.projectile then nbProjectiles = nbProjectiles + 1 end
      end
      journal.info(ETAPES.SURVEILLANCE, string.format(
        "OK | %s | etat %s | scans=%d | pistes=%d (dont %d projectiles) | "
        .. "alertes=%d | leurres=%d%s | manoeuvres=%d | erreurs=%d | actif depuis %ds",
        config.identifiant, contexte.etat, contexte.scans, nbPistes, nbProjectiles,
        contexte.alertesTotales, contexte.leurresLargues,
        config.stockLeurres > 0 and (" (reste " .. contexte.leurresRestants .. ")") or "",
        contexte.manoeuvres, contexte.erreursTotales,
        math.floor(maintenant - contexte.demarrageHorloge)))
    end
  end
end

--- 15i. Inhibition externe (desactivee par defaut : l'ADS est independant).
local function boucleInhibition(contexte)
  local config = contexte.config
  while true do
    local ok, _, message = proteger(ETAPES.TELEMETRIE, function()
      return rednet.receive(config.protocoleRednet, 30)
    end)
    if ok and type(message) == "table" and message.protocole == "FRENCHNET_ADS"
       and message.type == "INHIBITION" and message.navire == config.identifiant then
      contexte.inhibe = message.actif and true or false
      journal.avert(ETAPES.TELEMETRIE, "inhibition externe " ..
        (contexte.inhibe and "ACTIVEE" or "levee") .. " par ordre reseau")
    elseif not ok then
      sleep(5)
    end
  end
end

--------------------------------------------------------------------------------
-- 16. CYCLE DE VIE COMPLET (une session de l'ADS)
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
    "ADS du navire '%s'%s | programme v%s | ordinateur #%d",
    config.identifiant,
    config.designation ~= "" and (" (" .. config.designation .. ")") or "",
    VERSION_PROGRAMME, os.getComputerID()))

  ---------------------------------------------------------------------- contexte
  local contexte = {
    config           = config,
    etat             = ETAT_VEILLE,
    pistes           = {},
    impulsions       = {},
    compteurPiste    = 0,
    scans            = 0,
    contactsVus      = 0,
    echecsScan       = 0,
    erreursTotales   = 0,
    engagement       = 0,
    alertesTotales   = 0,
    leurresLargues   = 0,
    manoeuvres       = 0,
    priorite         = false,
    inhibe           = false,
    rednetOuvert     = false,
    demarrageHorloge = os.clock(),
    dernierBattement = 0,
    redemarrages     = etat.redemarrages,
  }
  contexte.leurresRestants = config.stockLeurres

  ------------------------------------------------------------------------ modem
  -- Le modem n'est pas vital : sans lui l'ADS defend quand meme le navire.
  local okModem, coteModem, modem, modemEnder = proteger(ETAPES.DETECTION_MODEM,
    detecterModem, config)
  if okModem and coteModem then
    contexte.coteModem, contexte.modem, contexte.modemEnder = coteModem, modem, modemEnder
    local okRednet = proteger(ETAPES.OUVERTURE_REDNET, function()
      if not rednet.isOpen(coteModem) then rednet.open(coteModem) end
      if not rednet.isOpen(coteModem) then
        error("rednet.open a echoue silencieusement sur '" .. coteModem .. "'", 0)
      end
    end)
    contexte.rednetOuvert = okRednet and true or false
    if contexte.rednetOuvert then
      journal.info(ETAPES.OUVERTURE_REDNET, string.format(
        "rednet ouvert sur '%s'%s | telemetrie '%s' | taches '%s'",
        coteModem, modemEnder and " (modem Ender)" or " (modem sans fil ordinaire)",
        config.protocoleRednet, config.protocoleTache))
    end
  else
    journal.avert(ETAPES.DETECTION_MODEM,
      "aucun modem : pas de telemetrie ni de contrat de tache par reseau. "
      .. "La defense du navire reste operationnelle (verrou fichier + restitution "
      .. "directe des consignes de vol).")
  end

  ------------------------------------------------------------------------ radar
  local nomRadar, radar, methodeScan = exigerEtape(ETAPES.DETECTION_RADAR,
    detecterRadar, config)
  contexte.nomRadar, contexte.radar, contexte.methodeScan = nomRadar, radar, methodeScan
  journal.info(ETAPES.DETECTION_RADAR, string.format(
    "radar de bord '%s' operationnel, methode de scan '%s', portee declaree %sb, "
    .. "periode de scan %ss",
    nomRadar, methodeScan, fmt(config.radarPortee), fmt(config.intervalleScanSecondes, 2)))

  -- Un scan trop lent devant la vitesse des projectiles est un defaut de
  -- conception, pas une panne : il doit etre signale une fois, en clair.
  local parcoursParScan = config.vitesseProjectileMini * config.intervalleScanSecondes
  if parcoursParScan > config.pisteRayonAssociation then
    journal.avert(ETAPES.DETECTION_RADAR, string.format(
      "un projectile lent (%sb/s) parcourt deja %sb entre deux scans, pour une "
      .. "fenetre d'association de %sb : les pistes risquent d'etre perdues. "
      .. "Reduisez 'intervalleScanSecondes' ou augmentez 'pisteRayonAssociation'.",
      fmt(config.vitesseProjectileMini), fmt(parcoursParScan),
      fmt(config.pisteRayonAssociation)))
  end

  ------------------------------------------------------------------- pilotage
  contexte.pilote = exigerEtape(ETAPES.DETECTION_PILOTE, construirePilote, config, contexte)
  if contexte.pilote.mode == "peripherique" then
    local details = {}
    for commande, methode in pairs(contexte.pilote.methodes) do
      details[#details + 1] = commande .. "=" .. methode
    end
    table.sort(details)
    journal.info(ETAPES.DETECTION_PILOTE, string.format(
      "pilotage par le peripherique '%s' | %s",
      contexte.pilote.nomPeripherique, table.concat(details, " ")))
    if contexte.pilote.manquantes and #contexte.pilote.manquantes > 0 then
      journal.avert(ETAPES.DETECTION_PILOTE, string.format(
        "commandes sans methode correspondante : %s. Renseignez 'piloteMethodes' "
        .. "dans config_ads.lua si le mod expose d'autres noms. Methodes du "
        .. "peripherique : %s",
        table.concat(contexte.pilote.manquantes, ", "),
        table.concat(methodesPeripherique(contexte.pilote.nomPeripherique), ", ")))
    end
  elseif contexte.pilote.mode == "redstone" then
    journal.info(ETAPES.DETECTION_PILOTE, "pilotage par impulsions redstone")
  elseif contexte.pilote.mode == "rednet" then
    journal.avert(ETAPES.DETECTION_PILOTE,
      "aucune interface de pilotage directe : les manoeuvres seront DEMANDEES au "
      .. "programme de navigation par rednet sur '" .. config.protocoleTache
      .. "'. Si personne n'ecoute, le navire ne manoeuvrera pas. Materiel present :\n"
      .. inventaireMateriel())
  else
    journal.avert(ETAPES.DETECTION_PILOTE,
      "mode simulation : les manoeuvres sont calculees et journalisees mais "
      .. "AUCUNE commande n'est envoyee au navire")
  end

  ------------------------------------------------------------------ largueurs
  contexte.largueurs = exigerEtape(ETAPES.DETECTION_LARGUEURS, preparerLargueurs, config)
  do
    local prets, defauts = {}, {}
    for _, largueur in ipairs(contexte.largueurs) do
      if largueur.disponible then
        prets[#prets + 1] = largueur.libelle .. " (" .. largueur.type .. ")"
      else
        defauts[#defauts + 1] = largueur.libelle .. " : " .. tostring(largueur.motif)
      end
    end
    if #prets > 0 then
      journal.info(ETAPES.DETECTION_LARGUEURS, string.format(
        "%d largueur(s) de leurres operationnel(s) : %s | stock %s",
        #prets, table.concat(prets, ", "),
        config.stockLeurres > 0 and tostring(config.stockLeurres) or "illimite"))
    else
      journal.erreur(ETAPES.DETECTION_LARGUEURS,
        "AUCUN largueur de leurres operationnel : le navire ne pourra compter "
        .. "que sur l'evasion. Verifiez 'largueurs' dans config_ads.lua.")
    end
    if #defauts > 0 then
      journal.avert(ETAPES.DETECTION_LARGUEURS,
        "largueur(s) en defaut -> " .. table.concat(defauts, " | "))
    end
  end

  --------------------------------------------------------- position du navire
  do
    local ok, position, source = proteger(ETAPES.POSITION_NAVIRE, lirePositionNavire, contexte)
    if ok and position then
      if source ~= "altitude seule" then contexte.positionNavire = position end
      contexte.altitude = nombreValide(position.y) and position.y or nil
      contexte.sourcePosition = source
      journal.info(ETAPES.POSITION_NAVIRE, string.format(
        "position initiale par '%s' : X=%s Y=%s Z=%s",
        source, fmt(position.x), fmt(position.y), fmt(position.z)))
    else
      contexte.sourcePosition = "inconnue"
      journal.avert(ETAPES.POSITION_NAVIRE,
        "position du navire inconnue au demarrage : travail en repere relatif")
    end
    contexte.cap = lirePilote(contexte, "lireCap")
    contexte.gaz = lirePilote(contexte, "lireGaz")
  end

  -- Un verrou reste du cycle precedent signale un plantage en pleine evasion :
  -- c'est exactement le genre d'anomalie que le journal doit rendre visible.
  if fs.exists(VERROU_PRIORITE) then
    journal.avert(ETAPES.PREEMPTION_TACHE, "verrou de priorite '" .. VERROU_PRIORITE
      .. "' trouve au demarrage : l'ADS s'est interrompu pendant une evasion. "
      .. "Verrou leve, le navire reprend la main.")
    pcall(fs.delete, VERROU_PRIORITE)
    if contexte.rednetOuvert then
      pcall(rednet.broadcast, {
        protocole = "FRENCHNET_ADS", version = PROTOCOLE_VERSION,
        type = "REPRISE", navire = config.identifiant, raison = "redemarrage ADS",
      }, config.protocoleTache)
    end
  end

  ------------------------------------------------------------- boucles paralleles
  local taches = {
    function() boucleRadar(contexte) end,
    function() boucleLeurres(contexte) end,
    function() boucleEngagement(contexte) end,
    function() boucleTache(contexte) end,
    function() boucleImpulsions(contexte) end,
    function() bouclePositionNavire(contexte) end,
    function() boucleSurveillance(contexte) end,
  }
  if config.telemetrieActive and contexte.rednetOuvert then
    taches[#taches + 1] = function() boucleTelemetrie(contexte) end
  end
  if config.autoriserInhibitionExterne and contexte.rednetOuvert then
    taches[#taches + 1] = function() boucleInhibition(contexte) end
    journal.avert(ETAPES.DEMARRAGE,
      "'autoriserInhibitionExterne' est actif : un ordre reseau peut desarmer "
      .. "l'ADS de ce navire. Ce n'est PAS le reglage par defaut.")
  end

  journal.info(ETAPES.BOUCLE_PRINCIPALE, string.format(
    "ADS arme : %d tache(s) paralleles | surveillance radar toutes les %ss | "
    .. "rayon de menace %sb | horizon %ss | evasion %s | leurres %s",
    #taches, fmt(config.intervalleScanSecondes, 2), fmt(config.rayonMenace),
    fmt(config.horizonMenaceSecondes),
    config.evasionActive and "armee" or "DESACTIVEE",
    config.leurresActifs and "armes" or "DESACTIVES"))

  -- waitForAny : si une tache remonte une erreur, on repasse par le superviseur
  -- qui refait integralement la sequence d'initialisation.
  parallel.waitForAny(table.unpack(taches))
  error("ETAPE[" .. ETAPES.BOUCLE_PRINCIPALE .. "] une tache s'est terminee de "
    .. "maniere inattendue", 0)
end

--------------------------------------------------------------------------------
-- 17. SUPERVISEUR
--     Ne rend jamais la main sauf arret manuel : capture toute erreur, la
--     journalise avec son etape, puis relance apres une temporisation
--     progressive (evite le matraquage en cas de panne materielle durable).
--------------------------------------------------------------------------------

local function superviseur()
  local etat = { redemarrages = 0 }
  local echecsConsecutifs = 0

  if fs.exists(MARQUEUR_ARRET) then pcall(fs.delete, MARQUEUR_ARRET) end

  journal.info(ETAPES.DEMARRAGE, "superviseur ADS FrenchNet v" .. VERSION_PROGRAMME
    .. " - configuration : " .. CHEMIN_CONFIG)

  while true do
    local debut = os.clock()
    local ok, err = xpcall(function() return cycleDeVie(etat) end, gestionnaireErreur)

    if ok then
      journal.avert(ETAPES.BOUCLE_PRINCIPALE, "cycle termine sans erreur : relance immediate")
      echecsConsecutifs = 0
    else
      if estTerminate(err) then
        if rawget(_G, "__ADS_ARRET_MANUEL_AUTORISE") == false then
          -- Mode 'autonomie totale' : Ctrl+T est journalise puis ignore.
          journal.avert(ETAPES.ARRET,
            "tentative d'arret manuel ignoree (arretParTerminate = false)")
        else
          journal.info(ETAPES.ARRET, "arret manuel demande (Ctrl+T)")
          -- Le navire ne doit jamais rester avec l'ADS aux commandes.
          if fs.exists(VERROU_PRIORITE) then
            pcall(fs.delete, VERROU_PRIORITE)
            journal.avert(ETAPES.ARRET, "verrou de priorite leve avant l'arret")
          end
          local okFichier, fichier = pcall(fs.open, MARQUEUR_ARRET, "w")
          if okFichier and fichier then
            fichier.writeLine(horodatage())
            fichier.close()
          end
          journal.info(ETAPES.ARRET, "ADS desarme - le navire n'est plus protege")
          return
        end
      end

      echecsConsecutifs = (os.clock() - debut >= 60) and 1 or (echecsConsecutifs + 1)
      etat.redemarrages = etat.redemarrages + 1

      journal.critique(ETAPES.DEMARRAGE, "cycle interrompu : " .. tostring(err))

      -- Un plantage pendant une evasion laisserait le verrou pose et le navire
      -- prive de sa tache : on le leve systematiquement avant de relancer.
      if fs.exists(VERROU_PRIORITE) then
        pcall(fs.delete, VERROU_PRIORITE)
        journal.avert(ETAPES.REPRISE_TACHE,
          "verrou de priorite leve apres interruption : le navire reprend la main")
      end

      local reglages = configActive or DEFAUTS
      local delaiMin = nombreValide(reglages.redemarrageDelaiMin)
        and reglages.redemarrageDelaiMin or DEFAUTS.redemarrageDelaiMin
      local delaiMax = nombreValide(reglages.redemarrageDelaiMax)
        and reglages.redemarrageDelaiMax or DEFAUTS.redemarrageDelaiMax
      local delai = math.floor(math.max(1,
        math.min(delaiMin * 2 ^ (echecsConsecutifs - 1), delaiMax)))
      journal.avert(ETAPES.DEMARRAGE, string.format(
        "redemarrage automatique n%d dans %d seconde(s) - LE NAVIRE N'EST PAS "
        .. "PROTEGE PENDANT CE DELAI", etat.redemarrages, delai))
      sleep(delai)
    end
  end
end

--------------------------------------------------------------------------------
-- 18. POINT D'ENTREE
--------------------------------------------------------------------------------

-- Crochet de banc d'essai : expose la cinematique pure pour la tester
-- isolement, puis rend la main sans armer l'ADS. Jamais utilise en jeu.
if rawget(_G, "__ADS_BANC_ESSAI") then
  rawset(_G, "__ADS_INTERNES", {
    vec = vec, cinematique = cinematique,
    normaliserContact = normaliserContact,
    correspondMotif = correspondMotif,
    DEFAUTS = DEFAUTS, ETAPES = ETAPES,
  })
  return
end

-- La configuration est lue une premiere fois ici uniquement pour savoir si
-- Ctrl+T doit etre honore ; toute erreur a ce stade est non bloquante.
local okConfigInitiale, configInitiale = pcall(chargerConfiguration)
if okConfigInitiale and type(configInitiale) == "table"
   and configInitiale.arretParTerminate == false then
  rawset(_G, "__ADS_ARRET_MANUEL_AUTORISE", false)
end

term.clear()
term.setCursorPos(1, 1)
print("=== FRENCHNET - ADS / CONTRE-MESURES (AERONAUTICS WARFARE) ===")
print("Programme v" .. VERSION_PROGRAMME .. " - ordinateur #" .. os.getComputerID())
print(string.rep("-", 40))

if rawget(_G, "__ADS_ARRET_MANUEL_AUTORISE") == false then
  -- Boucle externe ultime : meme un Terminate ne desarme pas l'ADS.
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
