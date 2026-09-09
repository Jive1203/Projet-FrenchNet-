--[[----------------------------------------------------------------------------
  FRENCHNET / AERONAUTICS WARFARE - Systeme embarque du navire intercepteur
  --------------------------------------------------------------------------
  Role : conduire une mission de scramble de bout en bout, a bord du navire,
         SANS aucune dependance envers le systeme de defense au sol au-dela
         des deux ordres qu'il recoit (SCRAMBLE et FEU).

  Ce que ce programme NE fait pas, volontairement :
    * il ne connait ni zone, ni classe Charlie / Bravo / Alpha / Romeo ;
    * il n'ecrit AUCUNE loi de pilotage : l'asservissement en cascade, le PID
      et le repli dead-band appartiennent au module d'autopilote standardise,
      qui est appele via intercepteur/autopilote.lua ;
    * il ne recharge pas l'arme : le rearmement reste une action manuelle.

  Machine a etats :

      VEILLE ---------(SCRAMBLE)--------> TRANSIT
      TRANSIT --------(arc atteint)-----> POSITION_ATTAQUE
      POSITION_ATTAQUE --(ordre FEU)----> TIR
      TIR / POSITION_ATTAQUE --(degat)--> EVASION  (priorite absolue)
      EVASION --------(manoeuvre finie)-> TRANSIT
      * --------(destruction confirmee)-> RETOUR_BASE
      RETOUR_BASE ----(base atteinte)---> REARMEMENT
      REARMEMENT -----(action humaine)--> VEILLE

  Chaque transition et chaque etape critique sont journalisees avec leur nom
  d'etape, afin de pouvoir reconstituer apres coup tout comportement anormal.

  NOTE SUR LES ACCENTS : chaines affichees et journalisees sans accents
  (terminal CC: Tweaked oriente octet).
--------------------------------------------------------------------------------]]

local VERSION_PROGRAMME = "1.0.0"

--------------------------------------------------------------------------------
-- 1. CHARGEMENT DES MODULES EMBARQUES
--------------------------------------------------------------------------------

local function repertoireProgramme()
  if shell and shell.getRunningProgram then
    local ok, chemin = pcall(shell.getRunningProgram)
    if ok and chemin then
      local dossier = fs.getDir(chemin)
      if dossier and dossier ~= "" and dossier ~= "." then return dossier end
    end
  end
  return "intercepteur"
end

local REPERTOIRE = repertoireProgramme()

local function charger(nom, ...)
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
  return morceau(...)
end

local noyau        = charger("noyau", REPERTOIRE)
local E            = noyau.ETAPES
local journal      = noyau.journal
local V            = noyau.vec
local interception = charger("interception", noyau)
local autopilote   = charger("autopilote", noyau)
local radar        = charger("radar", noyau)
local armement     = charger("armement", noyau)
local liaison      = charger("liaison", noyau)

local CHEMIN_CONFIG     = fs.combine(REPERTOIRE, "config_intercepteur.lua")
local MARQUEUR_ARRET    = fs.combine(REPERTOIRE, ".arret_manuel")
local MARQUEUR_REARMEMENT = fs.combine(REPERTOIRE, ".rearmement_requis")

--------------------------------------------------------------------------------
-- 2. ETATS
--------------------------------------------------------------------------------

local ETATS = {
  VEILLE           = "VEILLE",
  TRANSIT          = "TRANSIT",
  POSITION_ATTAQUE = "POSITION_ATTAQUE",
  TIR              = "TIR",
  EVASION          = "EVASION",
  RETOUR_BASE      = "RETOUR_BASE",
  REARMEMENT       = "REARMEMENT",
}

--- Etats dans lesquels le navire poursuit activement une cible : ce sont les
-- seuls ou la detection de degat doit declencher une evasion.
local function etatEngage(etat)
  return etat == ETATS.TRANSIT or etat == ETATS.POSITION_ATTAQUE
      or etat == ETATS.TIR
end

--------------------------------------------------------------------------------
-- 3. VALEURS PAR DEFAUT
--------------------------------------------------------------------------------

local DEFAUTS = {
  identifiant           = nil,     -- OBLIGATOIRE
  designation           = "",
  protocoleRednet       = "frenchnet_ordre",
  coteModem             = nil,
  coteRadar             = nil,
  accuserReception      = true,
  posteDeCommandement   = nil,
  expediteursAutorises  = nil,

  cheminAutopilote      = nil,
  cheminConfigVehicule  = nil,     -- fichier de reglage du vehicule (autopilote)

  periodeControle       = 0.25,
  periodeRadar          = 0.5,
  battementSecondes     = 30,
  delaiRechercheSecondes = 30,

  journalFichier        = true,
  journalTailleMax      = 96 * 1024,
  journalNiveauEcran    = "INFO",
  arretParTerminate     = true,
  erreursAvantReinit    = 8,
  redemarrageDelaiMin   = 3,
  redemarrageDelaiMax   = 60,

  autopilote   = {},
  interception = {},
  degats       = {},
  arme         = {},
  radar        = {},
  evasion      = {},
  retour       = {},
}

local DEFAUTS_INTERCEPTION = {
  arcMiniDeg = 120, arcMaxiDeg = 240, arcCentreDeg = 180, margeArcDeg = 10,
  arcAmplitudeDeg = 45, arcPeriodeSecondes = 12, manoeuvre = "orbite",
  distanceMini = 300, distanceMaxi = 400, distanceAmplitude = 30,
  distanceSecurite = 150, distanceTransit = 250,
  deltaYNominal = 0, deltaYAmplitude = 15, toleranceAltitude = 60,
  predictionMiniSecondes = 1, predictionMaxiSecondes = 10,
  vitesseMaxi = 120, vitesseMini = 0, vitesseReference = 60,
  gainRapprochement = 0.35, ratioMini = 0.6, ratioMaxi = 1.6,
  vitesseMiniPourCap = 2,
  -- REGLE D'ENGAGEMENT : sous ordre de feu, le tir prime sur la position.
  prioriteTirSurPosition = true,
  biaisArcEnTirDeg = 25,
}

local DEFAUTS_DEGATS = {
  fenetreSecondes = 3, dureeMiniSecondes = 0.5,
  chuteAltitudeBlocs = 25, perteVitesseRatio = 0.40, perteVitesseMini = 15,
  perteContactSecondes = 5, altitudeSolConfirmee = 5,
  vitesseEpaveMaxi = 3, dureeEpaveSecondes = 4,
  refractaireSecondes = 8,
}

local DEFAUTS_ARME = {
  -- Reglages communs a tout l'arsenal. Les portees, la balistique et la
  -- cadence sont declarees ARME PAR ARME dans 'arme.armes'.
  toleranceViseeDeg = 3,
  prioriteTirSurPosition = true,
  besoinParDefaut = "anti-aerien",
  armes = nil,   -- OBLIGATOIRE : liste des armes embarquees
}

local DEFAUTS_RADAR = {
  rayonAppariement = 150, lissageVitesse = 0.35, dtMiniVitesse = 0.15,
  echantillonsVitesse = 8, ecartVitesseAlerte = 40, periodeJournalPistage = 5,
  delaiValiditePiste = 3, vitesseMiniPourCap = 2,
}

local DEFAUTS_EVASION = {
  dureeSecondes = 6, angleBreakDeg = 55, distanceEvasion = 300,
  amplitudeVerticaleEvasion = 60, altitudePlancher = 80, altitudePlafond = 300,
  gardeAuSol = 40, vitesseEvasion = nil,
}

local DEFAUTS_RETOUR = {
  pointsRetour = nil, rayonPointRetour = 30, vitesseRetour = 90,
  altitudeCroisiere = nil,
}

--------------------------------------------------------------------------------
-- 4. CONFIGURATION
--------------------------------------------------------------------------------

local function fusionner(bloc, defauts)
  local resultat = {}
  for cle, valeur in pairs(defauts) do resultat[cle] = valeur end
  for cle, valeur in pairs(bloc or {}) do resultat[cle] = valeur end
  return resultat
end

local function chargerConfiguration()
  local config = noyau.chargerConfiguration(CHEMIN_CONFIG, DEFAUTS)
  config.interception = fusionner(config.interception, DEFAUTS_INTERCEPTION)
  config.degats       = fusionner(config.degats, DEFAUTS_DEGATS)
  config.arme         = fusionner(config.arme, DEFAUTS_ARME)
  config.radar        = fusionner(config.radar, DEFAUTS_RADAR)
  config.evasion      = fusionner(config.evasion, DEFAUTS_EVASION)
  config.retour       = fusionner(config.retour, DEFAUTS_RETOUR)
  return config
end

local function validerConfiguration(config)
  local anomalies = {}

  if type(config.identifiant) ~= "string" or config.identifiant == "" then
    table.insert(anomalies, "'identifiant' manquant : chaque navire doit porter "
      .. "un identifiant unique (il sert a filtrer les ordres du sol)")
  end

  local i = config.interception
  if i.distanceMini >= i.distanceMaxi then
    table.insert(anomalies, "'interception.distanceMini' doit etre strictement "
      .. "inferieure a 'interception.distanceMaxi'")
  end
  if i.distanceSecurite >= i.distanceMini then
    table.insert(anomalies, "'interception.distanceSecurite' doit rester sous "
      .. "'interception.distanceMini', sinon le navire se croit en permanence "
      .. "en risque de collision")
  end
  if i.arcMiniDeg >= i.arcMaxiDeg then
    table.insert(anomalies, "'interception.arcMiniDeg' doit etre inferieure a "
      .. "'interception.arcMaxiDeg'")
  end
  if i.arcCentreDeg < i.arcMiniDeg or i.arcCentreDeg > i.arcMaxiDeg then
    table.insert(anomalies, "'interception.arcCentreDeg' doit se situer dans l'arc")
  end
  if i.predictionMaxiSecondes <= 0 then
    table.insert(anomalies, "'interception.predictionMaxiSecondes' doit etre > 0 : "
      .. "sans prediction, le navire se contenterait de suivre la cible")
  end

  if config.interception.prioriteTirSurPosition == nil then
    config.interception.prioriteTirSurPosition = config.arme.prioriteTirSurPosition
  end
  config.interception.toleranceViseeDeg = config.arme.toleranceViseeDeg

  if type(config.arme.armes) ~= "table" or #config.arme.armes == 0 then
    table.insert(anomalies, "'arme.armes' doit contenir au moins une arme "
      .. "{ identifiant, utilite, porteeMini, porteeMaxi, ... }. Utilisez la page "
      .. "Armement du systeme d'exploitation pour la renseigner.")
  else
    for indice, declaration in ipairs(config.arme.armes) do
      local complete = {}
      for cle, valeur in pairs(declaration) do complete[cle] = valeur end
      complete.utilite     = complete.utilite or "polyvalent"
      complete.mode        = complete.mode or "peripherique"
      complete.porteeMini  = complete.porteeMini or 80
      complete.porteeMaxi  = complete.porteeMaxi or 420
      complete.vitesseObus = complete.vitesseObus or 80
      for _, anomalie in ipairs(armement.verifierArme(complete)) do
        table.insert(anomalies, "'arme.armes[" .. indice .. "]' : " .. anomalie)
      end
    end
  end

  local r = config.retour
  if type(r.pointsRetour) ~= "table" or #r.pointsRetour == 0 then
    table.insert(anomalies, "'retour.pointsRetour' doit contenir au moins un point "
      .. "{ x = , y = , z = } : le dernier de la liste est la base")
  else
    for indice, point in ipairs(r.pointsRetour) do
      if not (noyau.nombreValide(point.x) and noyau.nombreValide(point.y)
              and noyau.nombreValide(point.z)) then
        table.insert(anomalies, "'retour.pointsRetour[" .. indice .. "]' invalide")
      end
    end
  end

  local numeriques = {
    periodeControle = config.periodeControle,
    periodeRadar    = config.periodeRadar,
  }
  for cle, valeur in pairs(numeriques) do
    if not noyau.nombreValide(valeur) or valeur <= 0 then
      table.insert(anomalies, "'" .. cle .. "' doit etre un nombre > 0")
    end
  end

  if #anomalies > 0 then
    error("configuration invalide -> " .. table.concat(anomalies, " | "), 0)
  end
  return config
end

--------------------------------------------------------------------------------
-- 5. TRANSITIONS D'ETAT
--------------------------------------------------------------------------------

local function changerEtat(contexte, nouvel, etape, motif)
  if contexte.etat == nouvel then return end
  local ancien = contexte.etat
  contexte.etat = nouvel
  contexte.etatDepuis = noyau.maintenant()
  journal.info(etape or E.BOUCLE_PRINCIPALE, string.format(
    "etat %s -> %s%s", ancien, nouvel, motif and (" | " .. motif) or ""))
end

--------------------------------------------------------------------------------
-- 6. TRAITEMENT DES ORDRES
--------------------------------------------------------------------------------

local function traiterOrdre(contexte, ordre)
  local config = contexte.config

  ---------------------------------------------------------------------- SCRAMBLE
  if ordre.type == "SCRAMBLE" then
    if contexte.etat == ETATS.REARMEMENT then
      journal.avert(E.RECEPTION_ORDRE, string.format(
        "ordre de scramble %s REFUSE : le navire attend un rearmement manuel. "
        .. "Supprimez le fichier %s a bord pour le remettre en ligne.",
        ordre.identifiantOrdre, MARQUEUR_REARMEMENT))
      liaison.accuser(config, ordre, "REFUSE", "rearmement manuel requis")
      return
    end

    local reciblage = etatEngage(contexte.etat) or contexte.etat == ETATS.EVASION

    -- Nouvelle cible : toute la piste precedente est jetee. Conserver un
    -- historique de degats appartenant a l'ancienne cible provoquerait une
    -- fausse confirmation de destruction sur la nouvelle.
    contexte.piste = radar.creerPiste(config.radar)
    contexte.positionDesignee = V.copier(ordre.cible)
    contexte.degatCibleA   = nil
    contexte.feuAutorise   = false
    contexte.ordreCourant  = ordre
    contexte.debutMission  = noyau.maintenant()
    contexte.derniereCiblePresumee = V.copier(ordre.cible)

    if ordre.vitesseCible then
      contexte.piste.vitesse = V.copier(ordre.vitesseCible)
    end

    journal.info(E.RECEPTION_ORDRE, string.format(
      "%s sur la cible designee %s | le suivi passe immediatement au radar "
      .. "embarque, la position du sol ne sert que de premier contact",
      reciblage and "RECIBLAGE" or "MISE EN CHASSE", V.format(ordre.cible)))

    armement.cesserLeFeu(contexte.arsenal, "nouvel ordre de scramble")
    changerEtat(contexte, ETATS.TRANSIT, E.RECEPTION_ORDRE,
      "ordre " .. ordre.identifiantOrdre)
    liaison.accuser(config, ordre, contexte.etat, "cible prise en compte")
    return
  end

  -------------------------------------------------------------------------- FEU
  if ordre.type == "FEU" then
    if not etatEngage(contexte.etat) then
      journal.avert(E.RECEPTION_ORDRE, string.format(
        "ordre de feu %s REFUSE : le navire n'est pas engage (etat %s). "
        .. "Un ordre de scramble doit preceder l'ordre de tir.",
        ordre.identifiantOrdre, contexte.etat))
      liaison.accuser(config, ordre, "REFUSE", "aucune cible en cours de poursuite")
      return
    end

    if ordre.cible then
      -- Rafraichissement facultatif de la designation : n'ecrase jamais la
      -- piste radar, qui reste la source de verite.
      contexte.positionDesignee = V.copier(ordre.cible)
    end

    contexte.feuAutorise = true

    local priorite = config.interception.prioriteTirSurPosition
    journal.info(E.RECEPTION_ORDRE, string.format(
      "FEU AUTORISE par l'ordre %s | %s", ordre.identifiantOrdre,
      priorite
        and "LE TIR PRIME SUR LA POSITION : le navire engage des qu'il a une "
            .. "solution, l'arc arriere reste une consigne de trajectoire"
        or "l'engagement se fera sans quitter l'arc arriere"))

    -- Avec la priorite au tir, l'ordre de feu fait passer a l'engagement
    -- immediatement, sans attendre d'avoir rejoint l'arc.
    if priorite or contexte.etat == ETATS.POSITION_ATTAQUE then
      changerEtat(contexte, ETATS.TIR, E.RECEPTION_ORDRE,
        priorite and "ordre de feu prioritaire" or "ordre de feu recu en position")
    end
    liaison.accuser(config, ordre, contexte.etat, "feu autorise")
  end
end

--------------------------------------------------------------------------------
-- 7. EVASION
--------------------------------------------------------------------------------

local function entrerEvasion(contexte, motif)
  local config = contexte.config
  local pSoi = contexte.position
  local menace = (contexte.piste and contexte.piste.position)
    or contexte.derniereCiblePresumee or V.creer(pSoi.x, pSoi.y, pSoi.z + 1)

  contexte.sensEvasion = -(contexte.sensEvasion or -1)
  contexte.etatAvantEvasion = etatEngage(contexte.etat) and contexte.etat or ETATS.TRANSIT

  local parametres = fusionner(config.evasion, {})
  local point, description = interception.pointEvasion(pSoi, menace,
    contexte.altitudeSol or 64, parametres, contexte.sensEvasion)

  contexte.pointEvasion = point
  contexte.finEvasion   = noyau.maintenant() + (config.evasion.dureeSecondes or 6)

  armement.cesserLeFeu(contexte.arsenal, "manoeuvre d'evasion prioritaire")

  journal.avert(E.MANOEUVRE_EVASION, string.format(
    "MANOEUVRE D'EVASION PRIORITAIRE | %s | %s | point de degagement %s | "
    .. "reprise de la position d'attaque prevue dans %.1fs",
    motif, description, V.format(point), config.evasion.dureeSecondes or 6))

  changerEtat(contexte, ETATS.EVASION, E.MANOEUVRE_EVASION, motif)

  contexte.autopilote.definirPoint(point, "evasion",
    config.evasion.vitesseEvasion or config.interception.vitesseMaxi)

  liaison.rendreCompte(config, "EVASION", motif)
end

local function conduireEvasion(contexte)
  local maintenant = noyau.maintenant()

  -- Un nouveau degat pendant l'evasion prolonge la manoeuvre et change de sens.
  local evaluation = interception.evaluerDegats(contexte.telemetrie, contexte.config.degats)
  if evaluation.degat and (maintenant - (contexte.dernierDegatA or -math.huge))
     > (contexte.config.degats.refractaireSecondes or 8) then
    contexte.dernierDegatA = maintenant
    journal.avert(E.DETECTION_DEGAT,
      "nouveau degat pendant l'evasion : " .. tostring(evaluation.motif))
    entrerEvasion(contexte, "degat repete durant l'evasion")
    return
  end

  if maintenant >= (contexte.finEvasion or 0) then
    journal.info(E.FIN_EVASION, string.format(
      "manoeuvre d'evasion terminee apres %.1fs, reprise de la position d'attaque",
      maintenant - (contexte.finEvasion - (contexte.config.evasion.dureeSecondes or 6))))
    changerEtat(contexte, contexte.etatAvantEvasion or ETATS.TRANSIT, E.FIN_EVASION,
      "reprise de la poursuite")
    return
  end

  -- Point de degagement atteint avant la fin du delai : on en calcule un
  -- nouveau plutot que de faire du surplace au meme endroit.
  if contexte.pointEvasion
     and V.distance(contexte.position, contexte.pointEvasion) < 60 then
    local point, description = interception.pointEvasion(contexte.position,
      (contexte.piste and contexte.piste.position) or contexte.derniereCiblePresumee
        or contexte.position,
      contexte.altitudeSol or 64, contexte.config.evasion, contexte.sensEvasion)
    contexte.pointEvasion = point
    journal.debug(E.MANOEUVRE_EVASION, "degagement prolonge : " .. description)
  end

  contexte.autopilote.definirPoint(contexte.pointEvasion, "evasion",
    contexte.config.evasion.vitesseEvasion or contexte.config.interception.vitesseMaxi)
end

--------------------------------------------------------------------------------
-- 8. RETOUR A LA BASE
--------------------------------------------------------------------------------

local function entrerRetourBase(contexte, motif)
  local config = contexte.config
  contexte.feuAutorise = false
  contexte.baseAtteinte = false
  armement.cesserLeFeu(contexte.arsenal, "fin de mission")

  local points = config.retour.pointsRetour
  journal.info(E.RETOUR_BASE, string.format(
    "RETOUR BASE engage | %s | %d point(s) de retour, le dernier etant la base | "
    .. "le rearmement restera une action manuelle", motif, #points))

  changerEtat(contexte, ETATS.RETOUR_BASE, E.RETOUR_BASE, motif)
  liaison.rendreCompte(config, "RETOUR_BASE", motif)

  -- L'itineraire est confie a l'autopilote : c'est SON systeme de points de
  -- passage qui est utilise, celui-la meme qui sert aux missions de livraison.
  -- Le navire ne reimplemente pas la navigation, il la delegue.
  contexte.autopilote.suivreItineraire(points, {
    vitesse           = config.retour.vitesseRetour,
    altitudeCroisiere = config.retour.altitudeCroisiere,
    surEtape = function(index, point)
      journal.info(E.POINT_RETOUR, string.format("point de retour %d/%d atteint%s : %s",
        index, #points, point.nom and (" (" .. point.nom .. ")") or "",
        V.format(point)))
    end,
    surArrivee = function(point)
      journal.info(E.POINT_RETOUR, string.format("point de retour %d/%d atteint%s : %s",
        #points, #points, point.nom and (" (" .. point.nom .. ")") or "",
        V.format(point)))
      contexte.baseAtteinte = true
    end,
  })
end

local function conduireRetour(contexte)
  -- L'autopilote pilote le convoyage ; on n'observe que son aboutissement.
  if not (contexte.baseAtteinte or contexte.autopilote.estArrive()) then
    journal.limite("retour", 15, "DEBUG", E.RETOUR_BASE,
      "convoyage en cours vers la base, conduite par l'autopilote")
    return
  end

  journal.info(E.RETOUR_BASE, "base atteinte, navire immobilise")
  contexte.autopilote.stationnaire()

  local ok, fichier = pcall(fs.open, MARQUEUR_REARMEMENT, "w")
  if ok and fichier then
    fichier.writeLine(noyau.horodatage())
    fichier.writeLine("Rearmement manuel requis. Supprimez ce fichier pour "
      .. "remettre le navire en ligne.")
    fichier.close()
  end

  journal.avert(E.REARMEMENT, string.format(
    "REARMEMENT MANUEL REQUIS | le navire refusera tout ordre de scramble tant "
    .. "que le fichier %s existera a bord", MARQUEUR_REARMEMENT))
  changerEtat(contexte, ETATS.REARMEMENT, E.REARMEMENT, "mission terminee")
  liaison.rendreCompte(contexte.config, "REARMEMENT",
    "navire au sol, rearmement manuel attendu")
end

local function surveillerRearmement(contexte)
  contexte.autopilote.stationnaire()
  if not fs.exists(MARQUEUR_REARMEMENT) then
    journal.info(E.REARMEMENT,
      "marqueur de rearmement retire par l'equipage : navire de nouveau disponible")
    contexte.arsenal.coups = 0
    for _, arme in ipairs(contexte.arsenal.armes) do arme.rafales = 0 end
    changerEtat(contexte, ETATS.VEILLE, E.REARMEMENT, "rearmement confirme")
    liaison.rendreCompte(contexte.config, "DISPONIBLE", "rearmement manuel effectue")
    return
  end
  journal.limite("rearmement", 60, "INFO", E.REARMEMENT,
    "en attente de rearmement manuel (supprimer " .. MARQUEUR_REARMEMENT .. ")")
end

--------------------------------------------------------------------------------
-- 9. CONDUITE DE L'INTERCEPTION
--------------------------------------------------------------------------------

--- Position presumee de la cible quand le radar ne la voit pas : navigation a
-- l'estime a partir du dernier vecteur connu. Sans cela, une coupure d'une
-- seconde ferait perdre la poursuite.
local function positionPresumee(contexte, maintenant)
  local piste = contexte.piste
  if piste and piste.position and piste.dernierContact then
    return interception.predirePosition(piste.position, piste.vitesse,
      maintenant - piste.dernierContact)
  end
  return contexte.positionDesignee
end

--- Nature du besoin d'armement, deduite de la seule observation du radar.
-- Le navire ne recoit aucune classification du sol : il decide lui-meme si la
-- cible est aerienne ou au sol, a partir de son altitude relative au relief.
local function besoinCible(contexte, pCible)
  local plancher = (contexte.altitudeSol or 64)
    + (contexte.config.arme.margeAltitudeSol or 12)
  if pCible.y <= plancher then return "anti-sol" end
  return contexte.config.arme.besoinParDefaut or "anti-aerien"
end

local function conduireInterception(contexte)
  local config = contexte.config
  local maintenant = noyau.maintenant()
  local piste = contexte.piste

  ------------------------------------------------------- 9a. contact disponible ?
  local exploitable = piste and piste:exploitable(maintenant, config.radar.delaiValiditePiste)

  if not exploitable then
    -- Duree sans contact. Tant que le radar n'a JAMAIS accroche la cible, elle
    -- se compte depuis la reception de l'ordre : autrement le premier cycle de
    -- controle, qui precede forcement le premier balayage radar, verrait un
    -- silence infini et interromprait la mission avant meme le decollage.
    local jamaisAcquise = not (piste and piste.dernierContact)
    local reference = (piste and piste.dernierContact)
      or contexte.debutMission or maintenant
    local silence = maintenant - reference

    -- Destruction confirmee par le silence radar consecutif a un degat ?
    if contexte.degatCibleA and piste then
      local confirmee, motif = interception.confirmerDestruction({
        historique     = piste.historique,
        degatDetecteA  = contexte.degatCibleA,
        dernierContact = piste.dernierContact,
        position       = piste.position,
        vitesse        = piste.vitesse,
      }, config.degats, maintenant)
      if confirmee then
        journal.info(E.CONFIRMATION_DESTRUCTION,
          "DESTRUCTION DE LA CIBLE CONFIRMEE : " .. motif)
        liaison.rendreCompte(config, "DESTRUCTION_CONFIRMEE", motif)
        entrerRetourBase(contexte, "destruction de la cible confirmee")
        return
      end
    end

    -- Sinon : recherche a l'estime pendant un delai borne.
    if jamaisAcquise then
      journal.limite("ralliement", 5, "DEBUG", E.PISTAGE_RADAR, string.format(
        "cible pas encore accrochee par le radar apres %.1fs : ralliement sur la "
        .. "position designee par le sol", silence))
    else
      journal.limite("perte_contact", 5, "AVERT", E.PERTE_CONTACT, string.format(
        "contact radar perdu depuis %.1fs, poursuite a l'estime", silence))
    end

    if silence > (config.delaiRechercheSecondes or 30) then
      journal.avert(E.PERTE_CONTACT, string.format(
        "cible %s apres %.0fs : mission interrompue",
        jamaisAcquise and "jamais accrochee par le radar" or "non reacquise",
        silence))
      entrerRetourBase(contexte, jamaisAcquise
        and "cible jamais accrochee par le radar embarque"
        or "cible perdue, aucune reacquisition")
      return
    end

    armement.cesserLeFeu(contexte.arsenal, "contact radar perdu")
  end

  local pCible = positionPresumee(contexte, maintenant)
  if not pCible then return end
  contexte.derniereCiblePresumee = pCible

  local vCible = (piste and piste.vitesse) or V.creer(0, 0, 0)
  local capCible = (piste and piste.cap) or noyau.relevement(
    V.normeHorizontale(vCible) > 1e-3 and vCible or V.creer(0, 0, 1))

  local dansArc, details = interception.dansArc(contexte.position, pCible,
    capCible, config.interception)

  ------------------------------------------------- 9b. arme retenue pour ce cycle
  -- La selection precede le calcul de trajectoire : sous ordre de feu, c'est
  -- la portee de l'arme choisie qui fixe la distance a tenir, pas la bande de
  -- l'arc arriere.
  local enTir = (contexte.etat == ETATS.TIR)
  local priorite = config.interception.prioriteTirSurPosition
  local besoin = besoinCible(contexte, pCible)
  local arme, motifSansArme = nil, nil

  if enTir then
    arme, motifSansArme = armement.choisir(contexte.arsenal, besoin, details.distance)
    if arme ~= contexte.armeRetenue then
      if arme then
        journal.info(E.SOLUTION_TIR, string.format(
          "arme retenue : %s (%s, %s, portee %.0f-%.0f) pour une cible a %.0f blocs",
          arme.identifiant, arme.nom, arme.utilite,
          arme.porteeMini, arme.porteeMaxi, details.distance))
      end
      if contexte.armeRetenue then
        armement.cesserLeFeu(contexte.arsenal, "changement d'arme", contexte.armeRetenue)
      end
      contexte.armeRetenue = arme
    end
    if not arme then
      journal.limite("sans_arme", 8, "AVERT", E.SOLUTION_TIR, motifSansArme)
    end
  elseif contexte.armeRetenue then
    armement.cesserLeFeu(contexte.arsenal, "engagement termine", contexte.armeRetenue)
    contexte.armeRetenue = nil
  end

  ------------------------------------------------------ 9c. consigne de vol
  local consigne = interception.calculerConsigne({
    pSoi = contexte.position, vSoi = contexte.vitesse,
    pCible = pCible, vCible = vCible, capCible = capCible,
    t = maintenant, phase = contexte.phaseManoeuvre or 0,
    enPosition = (contexte.etat == ETATS.POSITION_ATTAQUE or enTir),
    modeEngagement = enTir and "tir" or "position",
    distanceTirVisee = arme and armement.distanceIdeale(arme) or nil,
  }, config.interception)

  journal.limite("calcul_interception", config.periodeJournalInterception or 3,
    "DEBUG", E.CALCUL_INTERCEPTION, string.format(
      "cible %s v=%.1f b/s cap=%.0f | impact predit dans %.1fs en %s%s | "
      .. "navire a %s (%.0f blocs) | consigne %s a %.1f b/s (%s, engagement %s)",
      V.format(pCible), V.norme(vCible), capCible,
      consigne.tempsInterception, V.format(consigne.pCiblePredite),
      consigne.atteignable and "" or " [CIBLE PLUS RAPIDE : interception non garantie]",
      details.positionHoraire, details.distance,
      V.format(consigne.point), consigne.vitesse, consigne.regimeVitesse,
      consigne.modeEngagement))

  contexte.autopilote.definirPoint(consigne.point, "interception", consigne.vitesse)
  contexte.derniereConsigne = consigne

  ------------------------------------------- 9d. entree / sortie de l'arc
  if dansArc and contexte.etat == ETATS.TRANSIT then
    contexte.phaseManoeuvre = interception.calerPhase(details.relevementRelatif,
      config.interception.arcCentreDeg, config.interception.arcAmplitudeDeg)
    journal.info(E.ENTREE_POSITION_ATTAQUE, string.format(
      "EN POSITION D'ATTAQUE | %s a %.0f blocs de la cible (bande %.0f-%.0f), "
      .. "ecart vertical %.0f | manoeuvre '%s' engagee",
      details.positionHoraire, details.distance,
      config.interception.distanceMini, config.interception.distanceMaxi,
      details.deltaY, config.interception.manoeuvre))
    changerEtat(contexte,
      contexte.feuAutorise and ETATS.TIR or ETATS.POSITION_ATTAQUE,
      E.ENTREE_POSITION_ATTAQUE, "arc arriere tenu")

  elseif not dansArc and (contexte.etat == ETATS.POSITION_ATTAQUE or enTir) then
    local raisons = {}
    if not details.angleOk then
      raisons[#raisons + 1] = "hors arc (" .. details.positionHoraire .. ")"
    end
    if not details.distanceOk then
      raisons[#raisons + 1] = string.format("distance %.0f hors bande", details.distance)
    end
    if not details.altitudeOk then
      raisons[#raisons + 1] = string.format("ecart vertical %.0f", details.deltaY)
    end
    local detail = table.concat(raisons, ", ")

    if enTir and priorite then
      -- LE TIR PRIME SUR LA POSITION : on ne rompt pas l'engagement pour
      -- aller reprendre sa place. Le navire regagne son arc par petites
      -- corrections, sans cesser de tirer.
      journal.limite("arc_perdu_en_tir", 8, "AVERT", E.SORTIE_POSITION_ATTAQUE,
        string.format("position d'attaque perdue (%s) mais ENGAGEMENT MAINTENU : "
          .. "le tir prime sur la position, reprise de l'arc par biais borne "
          .. "de %.0f deg", detail, config.interception.biaisArcEnTirDeg or 25))
    else
      journal.avert(E.SORTIE_POSITION_ATTAQUE, "position d'attaque perdue : "
        .. detail .. " | retour en transit pour la reprendre")
      armement.cesserLeFeu(contexte.arsenal, "sortie de l'arc arriere")
      changerEtat(contexte, ETATS.TRANSIT, E.SORTIE_POSITION_ATTAQUE, detail)
    end
  end

  if consigne.manoeuvreActive then
    journal.limite("manoeuvre_arc", 10, "DEBUG", E.MANOEUVRE_ARC, string.format(
      "manoeuvre '%s' : consigne a %s / %.0f blocs, vitesse %.1f b/s (%s, cible %.1f b/s)",
      config.interception.manoeuvre,
      noyau.positionHoraire(consigne.relevementVise), consigne.distanceVisee,
      consigne.vitesse, consigne.regimeVitesse, V.norme(vCible)))
  end

  ---------------------------------------------------------- 9e. engagement
  if enTir and exploitable and arme then
    local solution = interception.solutionTir(contexte.position, piste.position,
      piste.vitesse, arme)
    armement.pointer(arme, solution)

    local autorise, motifRefus = interception.tirAutorise({
      dansArc         = dansArc,
      distance        = details.distance,
      positionHoraire = details.positionHoraire,
      porteeMini      = arme.porteeMini,
      porteeMaxi      = arme.porteeMaxi,
      erreurVisee     = armement.erreurVisee(arme, solution),
    }, config.interception)

    if autorise then
      armement.entretenirRafale(contexte.arsenal, arme, maintenant, string.format(
        "cible a %.0f blocs en %s%s | impact predit %s dans %.2fs | azimut %.0f deg, "
        .. "elevation %.1f deg (chute compensee %.1f bloc)",
        details.distance, details.positionHoraire,
        dansArc and "" or " [HORS ARC - tir prioritaire]",
        V.format(solution.point), solution.tempsVol, solution.azimut,
        solution.elevation, solution.chute))
    else
      armement.cesserLeFeu(contexte.arsenal, motifRefus, arme)
      journal.limite("tir_refuse", 5, "DEBUG", E.TIR, "tir suspendu : " .. motifRefus)
    end
  end

  --------------------------------------------- 9f. degats subis par la cible
  if exploitable then
    local evaluation = interception.evaluerDegats(piste.historique, config.degats)
    if evaluation.degat and not contexte.degatCibleA then
      contexte.degatCibleA = maintenant
      journal.info(E.DETECTION_DEGAT, string.format(
        "DEGAT SUR LA CIBLE : %s | memes criteres que pour la survie du navire",
        evaluation.motif))
      liaison.rendreCompte(config, "DEGAT_CIBLE", evaluation.motif)
    end

    if contexte.degatCibleA then
      local confirmee, motif = interception.confirmerDestruction({
        historique     = piste.historique,
        degatDetecteA  = contexte.degatCibleA,
        dernierContact = piste.dernierContact,
        position       = piste.position,
        vitesse        = piste.vitesse,
      }, config.degats, maintenant)
      if confirmee then
        journal.info(E.CONFIRMATION_DESTRUCTION,
          "DESTRUCTION DE LA CIBLE CONFIRMEE : " .. motif)
        liaison.rendreCompte(config, "DESTRUCTION_CONFIRMEE", motif)
        entrerRetourBase(contexte, "destruction de la cible confirmee")
      end
    end
  end
end

---------------------------------
-- 10. BOUCLES CONCURRENTES
--------------------------------------------------------------------------------

--- 10a. Reception des ordres du sol.
local function boucleLiaison(contexte)
  while true do
    local ordre = liaison.recevoir(contexte.config, 5)
    if ordre then
      noyau.proteger(E.RECEPTION_ORDRE, traiterOrdre, contexte, ordre)
    end
  end
end

--- 10b. Pistage radar.
local function boucleRadar(contexte)
  while true do
    if contexte.etat ~= ETATS.VEILLE and contexte.etat ~= ETATS.REARMEMENT
       and contexte.piste then
      local attendue = positionPresumee(contexte, noyau.maintenant())
      if attendue then
        -- Relevement de secours : si la cible est trop lente pour donner un cap
        -- fiable, on considere que le navire est deja a 6 heures d'elle.
        contexte.piste.relevementSecours = noyau.relevement(
          V.soustraire(contexte.position, attendue))

        local avant = contexte.piste.contacts
        radar.balayer(contexte.radar, contexte.piste, attendue, contexte.config.degats)
        if contexte.piste.contacts > avant and avant == 0 then
          journal.info(E.REACQUISITION, "cible acquise par le radar embarque a "
            .. V.format(contexte.piste.position))
        end
      end
    end
    sleep(contexte.config.periodeRadar)
  end
end

--- 10c. Boucle de controle : telemetrie, survie, machine a etats.
local function boucleControle(contexte)
  local config = contexte.config

  while true do
    local maintenant = noyau.maintenant()

    ------------------------------------------------------ telemetrie du navire
    -- Un seul instantane de l'autopilote par cycle : ap.etat() recopie en
    -- profondeur, le rappeler plusieurs fois serait du gaspillage pur.
    contexte.autopilote.rafraichir()
    local position = contexte.autopilote.position()
    if position then
      contexte.position = position
      contexte.vitesse  = contexte.autopilote.vitesse() or contexte.vitesse
      contexte.autopilote.mode() -- trace tout basculement PID <-> zone morte
      interception.ajouterEchantillon(contexte.telemetrie, maintenant, position.y,
        V.norme(contexte.vitesse), config.degats.fenetreSecondes)
    else
      journal.limite("position_indisponible", 5, "AVERT", E.TELEMETRIE,
        "l'autopilote ne rend pas de position : commandes gelees, "
        .. "derniere position connue conservee")
    end

    ------------------------------------------- degats subis : priorite absolue
    if etatEngage(contexte.etat) and contexte.position then
      local evaluation = interception.evaluerDegats(contexte.telemetrie, config.degats)
      if evaluation.degat and (maintenant - (contexte.dernierDegatA or -math.huge))
         > (config.degats.refractaireSecondes or 8) then
        contexte.dernierDegatA = maintenant
        contexte.degatsSubis = (contexte.degatsSubis or 0) + 1
        journal.avert(E.DETECTION_DEGAT, string.format(
          "DEGAT SUBI PAR LE NAVIRE (n%d) : %s | criteres identiques a ceux de "
          .. "la confirmation de destruction", contexte.degatsSubis, evaluation.motif))
        entrerEvasion(contexte, evaluation.motif)
      end
    end

    ------------------------------------------------------------ machine a etats
    if contexte.position then
      if contexte.etat == ETATS.VEILLE then
        journal.limite("veille", 120, "DEBUG", E.SURVEILLANCE,
          "en veille, en attente d'un ordre de scramble")
      elseif contexte.etat == ETATS.EVASION then
        noyau.proteger(E.MANOEUVRE_EVASION, conduireEvasion, contexte)
      elseif contexte.etat == ETATS.RETOUR_BASE then
        noyau.proteger(E.RETOUR_BASE, conduireRetour, contexte)
      elseif contexte.etat == ETATS.REARMEMENT then
        noyau.proteger(E.REARMEMENT, surveillerRearmement, contexte)
      else
        noyau.proteger(E.CALCUL_INTERCEPTION, conduireInterception, contexte)
      end
    end

    ---------------------------------------------- tableau de bord du systeme
    -- Publie pour l'ecran d'etat du systeme d'exploitation. Lecture seule de
    -- son cote : aucune commande ne transite par ce canal.
    noyau.publier({
      identifiant   = config.identifiant,
      designation   = config.designation,
      etat          = contexte.etat,
      etatDepuis    = contexte.etatDepuis,
      position      = contexte.position,
      vitesse       = contexte.vitesse and V.norme(contexte.vitesse) or 0,
      modeVol       = contexte.autopilote.modeVol(),
      modePilotage  = contexte.autopilote.modePrecedent,
      instantaneVol = contexte.autopilote.instantane(),
      feuAutorise   = contexte.feuAutorise,
      armeRetenue   = contexte.armeRetenue and contexte.armeRetenue.identifiant or nil,
      arsenal       = contexte.arsenal,
      coups         = contexte.arsenal and contexte.arsenal.coups or 0,
      degatsSubis   = contexte.degatsSubis or 0,
      piste         = contexte.piste,
      consigne      = contexte.derniereConsigne,
      ordre         = contexte.ordreCourant,
      prioriteTir   = config.interception.prioriteTirSurPosition,
      consignesEmises = contexte.autopilote.consignesEmises,
      rearmementRequis = fs.exists(MARQUEUR_REARMEMENT),
    })

    sleep(config.periodeControle)
  end
end

--- 10d. Battement de coeur : resume periodique de l'etat du navire.
local function boucleSurveillance(contexte)
  local config = contexte.config
  while true do
    sleep(math.max(5, math.min(config.battementSecondes, 60)))

    local piste = contexte.piste
    local maintenant = noyau.maintenant()
    journal.info(E.SURVEILLANCE, string.format(
      "%s | etat %s depuis %.0fs | vol %s | position %s | vitesse %.1f b/s | "
      .. "cible %s | feu %s | arme %s | rafales %d | degats subis %d | actif depuis %ds",
      config.identifiant, contexte.etat, maintenant - (contexte.etatDepuis or maintenant),
      tostring(contexte.autopilote.modeVol() or "?"),
      contexte.position and V.format(contexte.position) or "inconnue",
      V.norme(contexte.vitesse or V.creer(0, 0, 0)),
      (piste and piste.position)
        and string.format("%s (contact il y a %.1fs)", V.format(piste.position),
          piste:silence(maintenant))
        or "aucune",
      contexte.feuAutorise and "AUTORISE" or "interdit",
      contexte.armeRetenue and contexte.armeRetenue.identifiant or "-",
      contexte.arsenal and contexte.arsenal.coups or 0,
      contexte.degatsSubis or 0,
      math.floor(maintenant - contexte.demarrageHorloge)))
  end
end

--------------------------------------------------------------------------------
-- 11. CYCLE DE VIE
--------------------------------------------------------------------------------

local configActive = nil

local function cycleDeVie(etat)
  local config = noyau.exigerEtape(E.CHARGEMENT_CONFIG, chargerConfiguration)
  noyau.exigerEtape(E.VALIDATION_CONFIG, validerConfiguration, config)
  configActive = config
  noyau.exigerEtape(E.INIT_JOURNAL, journal.initialiser, config)

  journal.info(E.DEMARRAGE, string.format(
    "navire intercepteur '%s'%s | programme v%s | ordinateur #%d",
    config.identifiant,
    config.designation ~= "" and (" (" .. config.designation .. ")") or "",
    VERSION_PROGRAMME, os.getComputerID()))
  journal.info(E.DEMARRAGE,
    "systeme independant du sol : aucune notion de zone ni de classe a bord ; "
    .. "seuls les ordres SCRAMBLE et FEU sont acceptes")

  ------------------------------------------------------------------- autopilote
  local ap = noyau.exigerEtape(E.LIAISON_AUTOPILOTE, autopilote.lier, config)

  ------------------------------------------------------------------- liaison sol
  local coteModem = noyau.exigerEtape(E.OUVERTURE_REDNET, liaison.ouvrir, config)

  ------------------------------------------------------------------------ radar
  local contexteRadar = noyau.exigerEtape(E.DETECTION_RADAR,
    radar.creerContexte, config, interception)

  ---------------------------------------------------------------------- armement
  local arsenal = noyau.exigerEtape(E.DETECTION_ARME,
    armement.creerArsenal, config.arme)

  ---------------------------------------------------------------------- contexte
  ap.rafraichir()
  local position = ap.position()
  local contexte = {
    config            = config,
    autopilote        = ap,
    radar             = contexteRadar,
    arsenal           = arsenal,
    armeRetenue       = nil,
    coteModem         = coteModem,
    etat              = ETATS.VEILLE,
    etatDepuis        = noyau.maintenant(),
    position          = position or V.creer(0, 0, 0),
    vitesse           = ap.vitesse() or V.creer(0, 0, 0),
    telemetrie        = {},
    piste             = nil,
    feuAutorise       = false,
    degatsSubis       = 0,
    sensEvasion       = -1,
    demarrageHorloge  = noyau.maintenant(),
    redemarrages      = etat.redemarrages,
    altitudeSol       = config.evasion.altitudeSolPresumee or 64,
  }

  if not position then
    journal.avert(E.TELEMETRIE, "l'autopilote n'a pas encore de position : "
      .. "le navire restera en veille tant qu'il n'en fournira pas")
  end

  -- Un navire qui redemarre alors qu'un rearmement etait en attente doit le
  -- rester : sinon un simple rechargement de chunk remettrait en ligne un
  -- navire a sec de munitions.
  if fs.exists(MARQUEUR_REARMEMENT) then
    journal.avert(E.REARMEMENT, "marqueur de rearmement present au demarrage : "
      .. "le navire reste indisponible jusqu'a intervention de l'equipage")
    contexte.etat = ETATS.REARMEMENT
  end

  journal.info(E.BOUCLE_PRINCIPALE, string.format(
    "systeme embarque operationnel | controle a %.2fs, radar a %.2fs | "
    .. "arc arriere %.0f-%.0f deg (%s-%s), distance %.0f-%.0f blocs | "
    .. "prediction d'interception %.0f-%.0fs | regle d'engagement : %s",
    config.periodeControle, config.periodeRadar,
    config.interception.arcMiniDeg, config.interception.arcMaxiDeg,
    noyau.positionHoraire(config.interception.arcMiniDeg),
    noyau.positionHoraire(config.interception.arcMaxiDeg),
    config.interception.distanceMini, config.interception.distanceMaxi,
    config.interception.predictionMiniSecondes, config.interception.predictionMaxiSecondes,
    config.interception.prioriteTirSurPosition
      and "LE TIR PRIME SUR LA POSITION"
      or "la position prime sur le tir"))

  -- La boucle de vol de l'autopilote tourne EN PARALLELE du systeme
  -- d'interception : c'est elle qui pilote reellement le vehicule, le systeme
  -- d'interception se contente de lui donner des consignes.
  parallel.waitForAny(
    function() ap.boucleDeVol() end,
    function() boucleLiaison(contexte) end,
    function() boucleRadar(contexte) end,
    function() boucleControle(contexte) end,
    function() boucleSurveillance(contexte) end)

  error("ETAPE[" .. E.BOUCLE_PRINCIPALE .. "] une tache s'est terminee de "
    .. "maniere inattendue", 0)
end

--------------------------------------------------------------------------------
-- 12. SUPERVISEUR
--------------------------------------------------------------------------------

local function superviseur()
  local etat = { redemarrages = 0 }
  local echecsConsecutifs = 0

  if fs.exists(MARQUEUR_ARRET) then pcall(fs.delete, MARQUEUR_ARRET) end

  journal.info(E.DEMARRAGE, "superviseur intercepteur v" .. VERSION_PROGRAMME
    .. " - configuration : " .. CHEMIN_CONFIG)

  while true do
    local debut = noyau.maintenant()
    local ok, err = xpcall(function() return cycleDeVie(etat) end,
      noyau.gestionnaireErreur)

    if ok then
      journal.avert(E.BOUCLE_PRINCIPALE, "cycle termine sans erreur : relance immediate")
      echecsConsecutifs = 0
    else
      if noyau.estTerminate(err) then
        if rawget(_G, "__INTERCEPTEUR_ARRET_MANUEL_AUTORISE") == false then
          journal.avert(E.ARRET,
            "tentative d'arret manuel ignoree (arretParTerminate = false)")
        else
          journal.info(E.ARRET, "arret manuel demande (Ctrl+T)")
          local okFichier, fichier = pcall(fs.open, MARQUEUR_ARRET, "w")
          if okFichier and fichier then
            fichier.writeLine(noyau.horodatage())
            fichier.close()
          end
          journal.info(E.ARRET, "systeme embarque stoppe")
          return
        end
      end

      echecsConsecutifs = (noyau.maintenant() - debut >= 60) and 1 or (echecsConsecutifs + 1)
      etat.redemarrages = etat.redemarrages + 1

      journal.critique(E.DEMARRAGE, "cycle interrompu : " .. tostring(err))

      local reglages = configActive or DEFAUTS
      local delaiMin = noyau.nombreValide(reglages.redemarrageDelaiMin)
        and reglages.redemarrageDelaiMin or DEFAUTS.redemarrageDelaiMin
      local delaiMax = noyau.nombreValide(reglages.redemarrageDelaiMax)
        and reglages.redemarrageDelaiMax or DEFAUTS.redemarrageDelaiMax
      local delai = math.floor(math.max(1,
        math.min(delaiMin * 2 ^ (echecsConsecutifs - 1), delaiMax)))
      journal.avert(E.DEMARRAGE, string.format(
        "redemarrage automatique n%d dans %d seconde(s)", etat.redemarrages, delai))
      sleep(delai)
    end
  end
end

--------------------------------------------------------------------------------
-- 13. POINT D'ENTREE
--------------------------------------------------------------------------------

local okConfigInitiale, configInitiale = pcall(chargerConfiguration)
if okConfigInitiale and type(configInitiale) == "table"
   and configInitiale.arretParTerminate == false then
  rawset(_G, "__INTERCEPTEUR_ARRET_MANUEL_AUTORISE", false)
end

term.clear()
term.setCursorPos(1, 1)
print("=== FRENCHNET - NAVIRE INTERCEPTEUR (AERONAUTICS WARFARE) ===")
print("Programme v" .. VERSION_PROGRAMME .. " - ordinateur #" .. os.getComputerID())
print(string.rep("-", 40))

if rawget(_G, "__INTERCEPTEUR_ARRET_MANUEL_AUTORISE") == false then
  while true do
    local ok, err = pcall(superviseur)
    if not ok then
      journal.critique(E.ARRET, "superviseur interrompu : " .. tostring(err)
        .. " - relance dans 5s")
      pcall(sleep, 5)
    end
  end
else
  superviseur()
end
