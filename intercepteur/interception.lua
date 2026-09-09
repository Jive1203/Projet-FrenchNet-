--[[----------------------------------------------------------------------------
  FRENCHNET / AERONAUTICS WARFARE - Mathematiques d'interception
  --------------------------------------------------------------------------
  Module PUR : aucune entree-sortie, aucun peripherique, aucun journal. Toutes
  les fonctions sont deterministes et testables hors du jeu, ce qui est le seul
  moyen serieux de valider une geometrie d'interception avant de la confier a
  un navire arme.

  Contenu :
    1. prediction de la position future d'une cible ;
    2. temps d'interception (solution analytique du probleme du chasseur) ;
    3. arc arriere 4h-8h : choix du relevement, point de consigne, controle
       d'appartenance ;
    4. manoeuvre d'orbite / zigzag et asservissement de vitesse ;
    5. criteres de degat PARTAGES (survie du navire ET confirmation de la
       destruction de la cible : c'est la MEME fonction, appelee deux fois) ;
    6. solution de tir balistique ;
    7. point d'evasion.

  Ce module ne connait ni les zones, ni les classes, ni le systeme au sol.

  Chargement : local noyau = ...
--------------------------------------------------------------------------------]]

local noyau = ...
local V = noyau.vec

local M = {}

--------------------------------------------------------------------------------
-- 1. PREDICTION
--------------------------------------------------------------------------------

--- Position estimee d'un mobile dans t secondes, a vitesse constante.
-- L'acceleration est volontairement ignoree : sur des pistes radar bruitees,
-- un terme en t^2 amplifie le bruit bien plus qu'il n'ameliore la prediction.
function M.predirePosition(position, vitesse, t)
  return {
    x = position.x + vitesse.x * t,
    y = position.y + vitesse.y * t,
    z = position.z + vitesse.z * t,
  }
end

--------------------------------------------------------------------------------
-- 2. TEMPS D'INTERCEPTION
--------------------------------------------------------------------------------

--- Resout le temps de vol t tel que le navire, a la vitesse scalaire
-- 'vitessePropre', atteigne la cible qui se deplace en ligne droite.
--
-- On cherche t >= 0 verifiant  |P + V.t| = s.t  avec P = pCible - pSoi.
-- En elevant au carre :  (|V|^2 - s^2).t^2 + 2(P.V).t + |P|^2 = 0
-- On retient la plus PETITE racine positive (interception la plus precoce).
--
-- Cas degeneres traites explicitement :
--   * a proche de zero (cible aussi rapide que le navire) -> equation lineaire ;
--   * aucune racine positive (cible plus rapide et fuyante) -> poursuite
--     impossible, on renvoie la borne haute et le drapeau 'atteignable=false'.
--
-- @return t (secondes, borne), atteignable (booleen)
function M.tempsInterception(pSoi, pCible, vCible, vitessePropre, bornes)
  bornes = bornes or {}
  local tMin = bornes.min or 0
  local tMax = bornes.max or 12

  local P = V.soustraire(pCible, pSoi)
  local s = math.max(vitessePropre or 0, 0.1)

  local a = V.produitScalaire(vCible, vCible) - s * s
  local b = 2 * V.produitScalaire(P, vCible)
  local c = V.produitScalaire(P, P)

  local t, atteignable

  if math.abs(a) < 1e-6 then
    -- Vitesses egales : la quadratique degenere en equation du premier degre.
    if math.abs(b) < 1e-9 then
      t, atteignable = tMax, false
    else
      t = -c / b
      atteignable = t > 0
    end
  else
    local discriminant = b * b - 4 * a * c
    if discriminant < 0 then
      t, atteignable = tMax, false
    else
      local racine = math.sqrt(discriminant)
      local t1 = (-b - racine) / (2 * a)
      local t2 = (-b + racine) / (2 * a)
      -- Plus petite racine strictement positive.
      local candidats = {}
      if t1 > 1e-6 then candidats[#candidats + 1] = t1 end
      if t2 > 1e-6 then candidats[#candidats + 1] = t2 end
      if #candidats == 0 then
        t, atteignable = tMax, false
      else
        t = math.min(table.unpack(candidats))
        atteignable = true
      end
    end
  end

  if not noyau.nombreValide(t) or t < 0 then
    t, atteignable = tMax, false
  end
  return noyau.borner(t, tMin, tMax), atteignable
end

--------------------------------------------------------------------------------
-- 3. ARC ARRIERE 4h - 8h
--    Relevement relatif : 0 = 12h (devant la cible), 180 = 6h (droit derriere).
--    L'arc demande est donc [120, 240] degres.
--------------------------------------------------------------------------------

--- Cap d'un mobile deduit de sa vitesse. Sous le seuil, la direction n'est plus
-- fiable (bruit radar sur un mobile quasi immobile) : on conserve le dernier
-- cap connu, et a defaut on considere que le navire est deja a 6h.
-- @return capDeg, fiable (booleen)
function M.capMobile(vitesse, capPrecedent, seuilVitesse, relevementSecours)
  if V.normeHorizontale(vitesse) >= (seuilVitesse or 2) then
    return noyau.relevement(vitesse), true
  end
  if capPrecedent then return capPrecedent, false end
  -- Aucun cap exploitable : on prend le relevement de secours (typiquement
  -- celui du navire vu de la cible) afin que le navire reste ou il est.
  return relevementSecours or 0, false
end

--- Choisit le relevement relatif vise dans l'arc arriere.
--
-- Regle de conduite : ne JAMAIS traverser l'hemisphere avant de la cible.
-- Si le navire est deja dans l'arc, on garde son cote. Sinon on rejoint la
-- borne d'arc la plus proche ANGULAIREMENT, ce qui fait contourner la cible
-- par le flanc au lieu de passer devant son nez.
--
-- @return relevementVise, dejaDansArc (booleen)
function M.choisirRelevementArc(relevementActuel, params)
  local mini  = params.arcMiniDeg or 120
  local maxi  = params.arcMaxiDeg or 240
  local marge = params.margeArcDeg or 10

  local beta = noyau.normaliserAngle(relevementActuel)
  if beta >= mini and beta <= maxi then
    return beta, true
  end

  local ecartMini = math.abs(noyau.ecartAngulaire(beta, mini))
  local ecartMaxi = math.abs(noyau.ecartAngulaire(beta, maxi))
  if ecartMini <= ecartMaxi then
    return noyau.borner(mini + marge, mini, maxi), false
  end
  return noyau.borner(maxi - marge, mini, maxi), false
end

--- Point du monde situe a 'relevementRelatif' et 'distance' de la cible,
-- relativement a son cap.
function M.pointArc(pCible, capCibleDeg, relevementRelatif, distance, deltaY)
  local direction = noyau.vecteurDepuisRelevement(
    noyau.normaliserAngle(capCibleDeg + relevementRelatif))
  return {
    x = pCible.x + direction.x * distance,
    y = pCible.y + (deltaY or 0),
    z = pCible.z + direction.z * distance,
  }
end

--- Le navire est-il dans l'arc arriere, a bonne distance et a bonne altitude ?
-- @return dansArc (booleen), details (table)
function M.dansArc(pSoi, pCible, capCibleDeg, params)
  local relatif  = noyau.relevementRelatif(capCibleDeg, pCible, pSoi)
  local distance = V.distance(pSoi, pCible)
  local deltaY   = pSoi.y - pCible.y

  local details = {
    relevementRelatif = relatif,
    positionHoraire   = noyau.positionHoraire(relatif),
    distance          = distance,
    deltaY            = deltaY,
  }

  details.angleOk = relatif >= (params.arcMiniDeg or 120)
                and relatif <= (params.arcMaxiDeg or 240)
  details.distanceOk = distance >= (params.distanceMini or 300)
                   and distance <= (params.distanceMaxi or 400)
  details.altitudeOk = math.abs(deltaY) <= (params.toleranceAltitude or 60)

  return details.angleOk and details.distanceOk and details.altitudeOk, details
end

--------------------------------------------------------------------------------
-- 4. MANOEUVRE DANS L'ARC : ORBITE / ZIGZAG
--------------------------------------------------------------------------------

local function triangle(x)
  -- Onde triangulaire de periode 1, amplitude [-1, 1].
  return 4 * math.abs(x - math.floor(x + 0.5)) - 1
end

--- Calage de phase a l'entree dans l'arc : la manoeuvre demarre exactement au
-- relevement courant, ce qui evite l'a-coup d'un saut vers 6h pile.
function M.calerPhase(relevementEntree, centre, amplitude)
  if amplitude < 1e-6 then return 0 end
  local rapport = noyau.borner((relevementEntree - centre) / amplitude, -1, 1)
  return math.asin(rapport)
end

--- Oscillation du point de consigne autour de l'arc arriere.
--
-- Le relevement et la distance oscillent avec des periodes de rapport
-- irrationnel (nombre d'or) : le motif ne se repete pas, ce qui rend la
-- trajectoire du navire nettement moins previsible pour la cible qu'une
-- orbite reguliere.
--
-- @return relevementVise, distanceVisee, deltaY
function M.oscillationArc(t, params, phase)
  local centre    = params.arcCentreDeg or 180
  local amplitude = math.min(params.arcAmplitudeDeg or 45,
    ((params.arcMaxiDeg or 240) - (params.arcMiniDeg or 120)) / 2 - (params.margeArcDeg or 10))
  amplitude = math.max(amplitude, 0)

  local periode = math.max(params.arcPeriodeSecondes or 12, 1)
  local mode    = params.manoeuvre or "orbite"
  phase = phase or 0

  local forme
  if mode == "zigzag" then
    forme = triangle(t / periode + phase / (2 * math.pi))
  else
    forme = math.sin(2 * math.pi * t / periode + phase)
  end

  local relevement = noyau.borner(centre + amplitude * forme,
    params.arcMiniDeg or 120, params.arcMaxiDeg or 240)

  -- Distance : oscillation lente et de faible amplitude, uniquement pour ne
  -- pas offrir une distance constante a la defense de la cible.
  local dMini = params.distanceMini or 300
  local dMaxi = params.distanceMaxi or 400
  local dCentre = (dMini + dMaxi) / 2
  local dAmplitude = math.min(params.distanceAmplitude or 30, (dMaxi - dMini) / 2)
  local periodeDistance = periode * 1.618
  local distance = noyau.borner(
    dCentre + dAmplitude * math.sin(2 * math.pi * t / periodeDistance),
    dMini, dMaxi)

  -- Altitude : leger decalage vertical, meme logique.
  local deltaY = (params.deltaYNominal or 0)
    + (params.deltaYAmplitude or 15) * math.sin(2 * math.pi * t / (periode * 2.4))

  return relevement, distance, deltaY
end

--------------------------------------------------------------------------------
-- 5. ASSERVISSEMENT DE VITESSE
--    "Ni trop vite ni trop lentement" : la vitesse commandee suit celle de la
--    cible, corrigee de l'erreur de distance. Deux garde-fous durs :
--      * en dessous de 'distanceSecurite', la commande passe SOUS la vitesse
--        cible pour rouvrir l'ecart (anti-collision) ;
--      * au-dela de 'distanceTransit', la commande passe a la vitesse maximale
--        (phase de rejointe).
--------------------------------------------------------------------------------

--- @return vitesseCommandee, regime ("transit" | "securite" | "asservi")
function M.vitesseCommandee(distanceActuelle, distanceVisee, vitesseCible, params)
  local vMax = params.vitesseMaxi or 120
  local vMin = params.vitesseMini or 0

  if distanceActuelle <= (params.distanceSecurite or 150) then
    -- Trop pres : on se laisse volontairement distancer.
    local v = noyau.borner(vitesseCible * (params.ratioMini or 0.6), vMin, vMax)
    return v, "securite"
  end

  if distanceActuelle - distanceVisee > (params.distanceTransit or 250) then
    return vMax, "transit"
  end

  local erreur = distanceActuelle - distanceVisee
  local v = vitesseCible + (params.gainRapprochement or 0.35) * erreur

  -- Bornage relatif a la cible : le navire ne doit ni la depasser ni decrocher.
  if vitesseCible > (params.vitesseMiniPourCap or 2) then
    v = noyau.borner(v,
      vitesseCible * (params.ratioMini or 0.6),
      vitesseCible * (params.ratioMaxi or 1.6))
  end

  return noyau.borner(v, vMin, vMax), "asservi"
end

--------------------------------------------------------------------------------
-- 6. CONSIGNE COMPLETE D'INTERCEPTION
--    C'est la fonction appelee a chaque cycle de controle. Elle produit le
--    point que l'autopilote doit rejoindre et la vitesse a tenir.
--------------------------------------------------------------------------------

--- @param etat table :
--    pSoi, vSoi        position et vitesse du navire
--    pCible, vCible    position et vitesse de la cible (radar embarque)
--    capCible          cap de la cible en degres
--    t                 horloge (secondes) pour l'oscillation
--    phase             phase de calage de la manoeuvre
--    enPosition        le navire est-il deja en position d'attaque ?
--    modeEngagement    "position" (defaut) ou "tir"
--    distanceTirVisee  distance optimale de l'arme retenue, en mode "tir"
-- @param params  bloc 'interception' de la configuration vehicule
-- @return consigne table
function M.calculerConsigne(etat, params)
  local vitessePropre = math.max(V.norme(etat.vSoi or { x = 0, y = 0, z = 0 }),
    params.vitesseReference or 60)

  -- 6a. Combien de temps avant de rejoindre la cible ? Ce delai est la duree
  --     de prediction : viser la position actuelle reviendrait a traineer
  --     derriere elle en permanence.
  local tGo, atteignable = M.tempsInterception(
    etat.pSoi, etat.pCible, etat.vCible, vitessePropre,
    { min = params.predictionMiniSecondes or 1,
      max = params.predictionMaxiSecondes or 10 })

  -- 6b. Ou sera la cible a cet instant.
  local pCiblePredite = M.predirePosition(etat.pCible, etat.vCible, tGo)

  -- 6c. Relevement vise dans l'arc arriere.
  local relevementActuel = noyau.relevementRelatif(etat.capCible, etat.pCible, etat.pSoi)
  local relevementVise, dejaDansArc = M.choisirRelevementArc(relevementActuel, params)

  local distanceVisee = ((params.distanceMini or 300) + (params.distanceMaxi or 400)) / 2
  local deltaY = params.deltaYNominal or 0

  -- 6d. Une fois en position, on n'y reste pas immobile : orbite ou zigzag.
  local manoeuvreActive = false
  if etat.enPosition then
    relevementVise, distanceVisee, deltaY = M.oscillationArc(etat.t, params, etat.phase)
    manoeuvreActive = true
  end

  -- 6d bis. ENGAGEMENT : LE TIR PRIME SUR LA POSITION.
  -- Sous ordre de feu, la place dans l'arc n'est plus un prealable. Une
  -- reprise d'arc franche ferait perdre la solution de tir en cours ; on
  -- borne donc la correction laterale a 'biaisArcEnTirDeg' par consigne. Le
  -- navire regagne son arc peu a peu, sans jamais cesser de tirer, et la
  -- distance visee devient celle de l'arme retenue, pas celle de l'arc.
  local biaisArc = nil
  if etat.modeEngagement == "tir" and params.prioriteTirSurPosition then
    local souhaite = M.choisirRelevementArc(relevementActuel, params)
    local biais = params.biaisArcEnTirDeg or 25
    biaisArc = noyau.borner(noyau.ecartAngulaire(souhaite, relevementActuel), -biais, biais)
    relevementVise = noyau.normaliserAngle(relevementActuel + biaisArc)
    if etat.distanceTirVisee then distanceVisee = etat.distanceTirVisee end
    manoeuvreActive = false
  end

  -- 6e. Point de consigne : arc arriere autour de la position PREDITE.
  --     C'est ici que se joue la priorite demandee : le navire vise sa place
  --     dans l'arc, jamais la cible elle-meme.
  local point = M.pointArc(pCiblePredite, etat.capCible, relevementVise,
    distanceVisee, deltaY)

  -- 6f. Vitesse commandee.
  local distanceActuelle = V.distance(etat.pSoi, etat.pCible)
  local vitesse, regime = M.vitesseCommandee(distanceActuelle, distanceVisee,
    V.norme(etat.vCible), params)

  return {
    point             = point,
    vitesse           = vitesse,
    regimeVitesse     = regime,
    tempsInterception = tGo,
    atteignable       = atteignable,
    pCiblePredite     = pCiblePredite,
    relevementActuel  = relevementActuel,
    relevementVise    = relevementVise,
    positionHoraire   = noyau.positionHoraire(relevementActuel),
    distanceActuelle  = distanceActuelle,
    distanceVisee     = distanceVisee,
    dejaDansArc       = dejaDansArc,
    manoeuvreActive   = manoeuvreActive,
    biaisArc          = biaisArc,
    modeEngagement    = etat.modeEngagement or "position",
  }
end

--------------------------------------------------------------------------------
-- 7. CRITERES DE DEGAT (PARTAGES)
--    La MEME fonction sert :
--      * a decider que LE NAVIRE est touche  -> manoeuvre d'evasion ;
--      * a decider que LA CIBLE est touchee  -> etape 1 de la confirmation
--        de destruction.
--    Un seul jeu de seuils, un seul comportement, aucune divergence possible
--    entre les deux usages.
--------------------------------------------------------------------------------

--- Ajoute un echantillon a un historique glissant et purge ce qui est trop
-- vieux. L'historique est une simple liste { {t=, y=, v=}, ... }.
function M.ajouterEchantillon(historique, t, altitude, vitesseScalaire, fenetre)
  historique[#historique + 1] = { t = t, y = altitude, v = vitesseScalaire }
  local limite = t - (fenetre or 5)
  while historique[1] and historique[1].t < limite do
    table.remove(historique, 1)
  end
  return historique
end

--- Evalue une perte rapide d'altitude ou de vitesse sur la fenetre glissante.
-- @param historique liste d'echantillons { t, y, v }
-- @param criteres   bloc 'degats' de la configuration
-- @return table { degat, chuteAltitude, perteVitesse, ratioVitesse, motif }
function M.evaluerDegats(historique, criteres)
  local resultat = {
    degat = false, chuteAltitude = 0, perteVitesse = 0, ratioVitesse = 0,
    motif = nil, echantillons = #historique,
  }
  if #historique < 2 then return resultat end

  local dernier = historique[#historique]
  local duree = dernier.t - historique[1].t
  if duree < (criteres.dureeMiniSecondes or 0.5) then return resultat end

  local yMax, vMax = -math.huge, 0
  for _, e in ipairs(historique) do
    if e.y > yMax then yMax = e.y end
    if e.v > vMax then vMax = e.v end
  end

  resultat.chuteAltitude = yMax - dernier.y
  resultat.perteVitesse  = vMax - dernier.v
  resultat.ratioVitesse  = (vMax > 1e-6) and (resultat.perteVitesse / vMax) or 0

  local motifs = {}

  if resultat.chuteAltitude >= (criteres.chuteAltitudeBlocs or 25) then
    motifs[#motifs + 1] = string.format("chute de %.1f bloc(s) en %.1fs (seuil %.1f)",
      resultat.chuteAltitude, duree, criteres.chuteAltitudeBlocs or 25)
  end

  if resultat.ratioVitesse >= (criteres.perteVitesseRatio or 0.40)
     and resultat.perteVitesse >= (criteres.perteVitesseMini or 15) then
    motifs[#motifs + 1] = string.format("perte de vitesse de %.0f%% (%.1f b/s) en %.1fs",
      resultat.ratioVitesse * 100, resultat.perteVitesse, duree)
  end

  if #motifs > 0 then
    resultat.degat = true
    resultat.motif = table.concat(motifs, " + ")
  end
  return resultat
end

--- Confirmation de destruction de la cible.
-- Un degat seul ne suffit pas : un appareil touche peut se retablir. On exige
-- un degat AVERE suivi d'un signe terminal.
-- @param etatCible table {
--     historique, degatDetecteA (ou nil), dernierContact, position, vitesse }
-- @return confirmee (booleen), motif (chaine ou nil), evaluation (table)
function M.confirmerDestruction(etatCible, criteres, maintenant)
  local evaluation = M.evaluerDegats(etatCible.historique, criteres)

  if not etatCible.degatDetecteA then
    return false, nil, evaluation
  end

  local depuisDegat = maintenant - etatCible.degatDetecteA

  -- Signe terminal 1 : le contact radar a disparu depuis le degat.
  local silence = maintenant - (etatCible.dernierContact or maintenant)
  if silence >= (criteres.perteContactSecondes or 5) then
    return true, string.format(
      "contact radar perdu depuis %.1fs apres un degat avere (il y a %.1fs)",
      silence, depuisDegat), evaluation
  end

  -- Signe terminal 2 : la cible est descendue sous l'altitude plancher.
  if etatCible.position and etatCible.position.y <= (criteres.altitudeSolConfirmee or 5) then
    return true, string.format("cible a Y=%.1f, sous le plancher de confirmation (%.1f)",
      etatCible.position.y, criteres.altitudeSolConfirmee or 5), evaluation
  end

  -- Signe terminal 3 : epave immobile suffisamment longtemps.
  if etatCible.vitesse
     and V.norme(etatCible.vitesse) <= (criteres.vitesseEpaveMaxi or 3)
     and depuisDegat >= (criteres.dureeEpaveSecondes or 4) then
    return true, string.format("cible immobilisee (%.1f b/s) depuis %.1fs apres degat",
      V.norme(etatCible.vitesse), depuisDegat), evaluation
  end

  return false, nil, evaluation
end

--------------------------------------------------------------------------------
-- 8. SOLUTION DE TIR
--    Distincte de la trajectoire d'interception : l'obus est bien plus rapide
--    que le navire, son temps de vol est donc bien plus court.
--------------------------------------------------------------------------------

--- @return solution table { point, tempsVol, azimut, elevation, distance }
-- 'azimut' est directement exploitable comme lacet Minecraft (0 = sud/+Z,
-- 90 = ouest/-X), convention identique a celle des relevements du noyau.
function M.solutionTir(pArme, pCible, vCible, params)
  local v0 = math.max(params.vitesseObus or 80, 1)
  local g  = params.graviteObus or 9.8

  -- Point d'impact : quelques iterations suffisent, le temps de vol depend de
  -- la distance qui depend elle-meme du temps de vol.
  local t = V.distance(pArme, pCible) / v0
  local point = pCible
  for _ = 1, (params.iterationsTir or 4) do
    point = M.predirePosition(pCible, vCible, t)
    t = V.distance(pArme, point) / v0
  end

  local delta = V.soustraire(point, pArme)
  local dh = V.normeHorizontale(delta)
  local chute = 0.5 * g * t * t

  return {
    point     = point,
    tempsVol  = t,
    distance  = V.norme(delta),
    azimut    = noyau.relevement(delta),
    elevation = math.deg(math.atan((delta.y + chute) / math.max(dh, 1e-6))),
    chute     = chute,
  }
end

--- Le tir est-il autorise ?
--
-- REGLE D'ENGAGEMENT : l'ordre de tir PRIME SUR LA POSITION.
-- Seules comptent les conditions qui rendent le coup possible - portee de
-- l'arme et qualite du pointage. La place dans l'arc arriere reste une
-- consigne de trajectoire, pas un prealable au tir : un navire qui a la
-- cible dans sa portee et une solution valable ouvre le feu, meme s'il est
-- encore en train de regagner son arc.
--
-- Le comportement inverse (arc bloquant) reste disponible en passant
-- 'prioriteTirSurPosition = false' dans la configuration.
--
-- @return autorise (booleen), motifRefus (chaine ou nil)
function M.tirAutorise(contexte, params)
  local porteeMini = contexte.porteeMini or params.distanceTirMini or 80
  local porteeMaxi = contexte.porteeMaxi or params.distanceTirMaxi or 420

  if contexte.distance > porteeMaxi then
    return false, string.format("cible a %.0f blocs, au-dela de la portee de l'arme (%.0f)",
      contexte.distance, porteeMaxi)
  end
  if contexte.distance < porteeMini then
    return false, string.format("cible a %.0f blocs, sous la portee mini de l'arme (%.0f)",
      contexte.distance, porteeMini)
  end
  if contexte.erreurVisee and contexte.erreurVisee > (params.toleranceViseeDeg or 3) then
    return false, string.format("erreur de visee %.1f deg (tolerance %.1f)",
      contexte.erreurVisee, params.toleranceViseeDeg or 3)
  end

  -- Arc bloquant uniquement si la priorite au tir a ete explicitement retiree.
  if params.prioriteTirSurPosition == false and not contexte.dansArc then
    return false, "hors de l'arc arriere (" .. (contexte.positionHoraire or "?")
      .. ") et priorite au tir desactivee"
  end

  return true, nil
end

--------------------------------------------------------------------------------
-- 9. POINT D'EVASION
--    Une fuite en ligne droite offre a l'adversaire une solution de tir
--    triviale. On impose donc un degagement en break : rupture laterale
--    alternee gauche/droite, plus une variation d'altitude.
--------------------------------------------------------------------------------

--- @param sens  +1 ou -1, alterne a chaque evasion
-- @return point, description
function M.pointEvasion(pSoi, pMenace, altitudeSol, params, sens)
  local fuite = V.horizontal(V.soustraire(pSoi, pMenace))
  local unitaire = V.normaliser(fuite, 1e-3)
  if not unitaire then
    -- Superposition parfaite (cas theorique) : on part vers le nord.
    unitaire = { x = 0, y = 0, z = -1 }
  end

  local relevementFuite = noyau.relevement(unitaire)
  local break_ = (params.angleBreakDeg or 55) * ((sens or 1) >= 0 and 1 or -1)
  local direction = noyau.vecteurDepuisRelevement(
    noyau.normaliserAngle(relevementFuite + break_))

  local distance = params.distanceEvasion or 300

  -- Variation d'altitude : on descend si on est haut, on monte si on est bas,
  -- en restant dans l'enveloppe de vol configuree.
  local plancher = params.altitudePlancher or 80
  local plafond  = params.altitudePlafond or 300
  local milieu   = (plancher + plafond) / 2
  local ampleur  = params.amplitudeVerticaleEvasion or 60
  local cibleY   = noyau.borner(
    pSoi.y + ((pSoi.y > milieu) and -ampleur or ampleur),
    math.max(plancher, (altitudeSol or 0) + (params.gardeAuSol or 40)),
    plafond)

  local point = {
    x = pSoi.x + direction.x * distance,
    y = cibleY,
    z = pSoi.z + direction.z * distance,
  }

  return point, string.format("break %s de %.0f deg, %s vers Y=%.0f, %.0f blocs",
    (break_ >= 0) and "a tribord" or "a babord", math.abs(break_),
    (cibleY < pSoi.y) and "descente" or "montee", cibleY, distance)
end

return M
