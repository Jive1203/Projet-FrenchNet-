--[[----------------------------------------------------------------------------
  FRENCHNET / AERONAUTICS WARFARE - Adaptateur vers le module d'autopilote
  --------------------------------------------------------------------------
  CE MODULE NE CONTIENT AUCUNE LOI DE PILOTAGE.

  Il relie le systeme d'interception au module d'autopilote standardise
  (autopilote/autopilote.lua) : asservissement en cascade, PID en controle
  principal, repli automatique en zone morte. Tout cela reste chez lui.

  Ce que le systeme d'interception lui envoie, et rien d'autre :
      un point de consigne, une vitesse maximale, parfois un itineraire.

  Ce qu'il lui demande en retour :
      sa position, sa vitesse, et le mode de pilotage actif de chaque axe.

  TROIS PRECAUTIONS IMPORTANTES

  1. LIMITATION DU DEBIT DES CONSIGNES. ap.allerA() n'est pas une commande
     bon marche : elle recalcule l'itineraire, journalise une ligne "mission
     acceptee" et, si la persistance est active, ecrit sur le disque. La
     boucle de controle tourne a 4 Hz : la rappeler a chaque cycle noierait
     le journal et martyriserait le disque. Les consignes ne sont donc
     reemises que lorsque le point a bouge de plus de 'seuilDeplacement'
     blocs, ou apres 'periodeRafraichissement' secondes.

  2. TRANSIT HAUTE ALTITUDE DESACTIVE. Par defaut l'autopilote monte a
     l'altitude de croisiere avant un long transit. En interception c'est
     exactement ce qu'il ne faut pas : la cible n'attendra pas.

  3. REPRISE DE MISSION DESACTIVEE. Un intercepteur qui redemarre apres un
     rechargement de chunk ne doit PAS reprendre une interception perimee
     sur une cible qui n'existe plus.

  Chargement : local noyau = ...
--------------------------------------------------------------------------------]]

local noyau = ...
local E = noyau.ETAPES
local journal = noyau.journal
local V = noyau.vec

local M = {}

--------------------------------------------------------------------------------
-- 1. EMPLACEMENTS
--------------------------------------------------------------------------------

local CHEMINS_MODULE = {
  "/autopilote/autopilote.lua",
  "/autopilote/api.lua",
  "/autopilote.lua",
  "/lib/autopilote.lua",
}

local CHEMIN_CONFIG_VEHICULE = "/autopilote/config_vehicule.lua"

--------------------------------------------------------------------------------
-- 2. CONTRAT DE REPLI
--    Utilise uniquement si le module charge n'expose PAS nouveau(), c'est-a-dire
--    s'il ne s'agit pas du module standardise FrenchNet. Chaque entree decrit
--    une capacite et les noms de fonction acceptes.
--------------------------------------------------------------------------------

M.CONTRAT_PLAT = {
  { role = "demarrer",       obligatoire = false,
    candidats = { "demarrer", "initialiser", "init", "start" } },
  { role = "definirPoint",   obligatoire = true,
    candidats = { "definirPoint", "definirConsigne", "allerA", "viser",
                  "setTarget", "setSetpoint", "goTo", "definirCible" } },
  { role = "definirVitesse", obligatoire = false,
    candidats = { "definirVitesse", "reglerVitesse", "setSpeed", "setVitesse" } },
  { role = "position",       obligatoire = true,
    candidats = { "position", "obtenirPosition", "getPosition", "getPos", "pos" } },
  { role = "vitesse",        obligatoire = false,
    candidats = { "vitesse", "obtenirVitesse", "getVelocity", "getVitesse", "vel" } },
  { role = "mode",           obligatoire = false,
    candidats = { "mode", "obtenirMode", "getMode", "modeActif" } },
  { role = "stationnaire",   obligatoire = false,
    candidats = { "stationnaire", "maintenirPosition", "maintenir", "hold" } },
  { role = "arreter",        obligatoire = false,
    candidats = { "arreter", "stopper", "stop", "halt" } },
  { role = "actualiser",     obligatoire = false,
    candidats = { "actualiser", "pas", "cycle", "tick", "update" } },
  { role = "boucle",         obligatoire = false,
    candidats = { "executer", "boucleDeVol", "run", "loop" } },
}

--------------------------------------------------------------------------------
-- 3. CHARGEMENT
--------------------------------------------------------------------------------

local function chargerModule(config)
  local essais = {}
  local candidats = {}
  if type(config.cheminAutopilote) == "string" and config.cheminAutopilote ~= "" then
    candidats[1] = config.cheminAutopilote
  end
  for _, chemin in ipairs(CHEMINS_MODULE) do candidats[#candidats + 1] = chemin end

  for _, chemin in ipairs(candidats) do
    if fs.exists(chemin) then
      local ok, resultat = pcall(function()
        local fichier = fs.open(chemin, "r")
        local source = fichier.readAll()
        fichier.close()
        local morceau, err = load(source, "@" .. chemin, "t", _G)
        if not morceau then error(tostring(err), 0) end
        local table_ = morceau(config.autopilote or {})
        if type(table_) ~= "table" then
          error("le module doit renvoyer une table", 0)
        end
        return table_
      end)
      if ok then return resultat, chemin end
      essais[#essais + 1] = chemin .. " (" .. tostring(resultat) .. ")"
    else
      essais[#essais + 1] = chemin .. " (absent)"
    end
  end
  return nil, nil, essais
end

--- Fusion recursive : les valeurs de 'surcouche' ecrasent celles de 'base',
-- table par table, sans detruire les branches non mentionnees.
local function fusionnerProfond(base, surcouche)
  local resultat = {}
  for cle, valeur in pairs(base) do
    if type(valeur) == "table" then
      resultat[cle] = fusionnerProfond(valeur, {})
    else
      resultat[cle] = valeur
    end
  end
  for cle, valeur in pairs(surcouche or {}) do
    if type(valeur) == "table" and type(resultat[cle]) == "table" then
      resultat[cle] = fusionnerProfond(resultat[cle], valeur)
    else
      resultat[cle] = valeur
    end
  end
  return resultat
end

--------------------------------------------------------------------------------
-- 4. FACADE SUR LE MODULE STANDARDISE FRENCHNET (chemin nominal)
--------------------------------------------------------------------------------

local function lierStandard(moduleAp, chemin, config)
  local reglages = config.autopilote or {}

  ------------------------------------------------------------------ configuration
  -- UN SEUL FICHIER DE CONFIGURATION PAR VEHICULE : celui de l'autopilote.
  -- Le bloc 'autopilote' de la configuration du navire ne fait que le
  -- surcharger ponctuellement, il ne le remplace pas.
  local cheminVehicule = config.cheminConfigVehicule
    or moduleAp.CHEMIN_CONFIG_DEFAUT or CHEMIN_CONFIG_VEHICULE

  local base = {}
  if type(moduleAp.chargerConfiguration) == "function" and fs.exists(cheminVehicule) then
    local ok, chargee = pcall(moduleAp.chargerConfiguration, cheminVehicule)
    if ok and type(chargee) == "table" then
      base = chargee
      journal.info(E.LIAISON_AUTOPILOTE,
        "configuration vehicule lue dans " .. cheminVehicule)
    else
      error("configuration vehicule illisible (" .. cheminVehicule .. ") : "
        .. tostring(chargee), 0)
    end
  else
    error("configuration vehicule introuvable : " .. cheminVehicule
      .. ". C'est le fichier de reglage de l'autopilote, et donc du navire.", 0)
  end

  -- Les reglages propres a l'ADAPTATEUR (debit des consignes) ne concernent
  -- pas l'autopilote : on les met de cote au lieu de polluer sa configuration.
  local surcouche = {}
  for cle, valeur in pairs(reglages) do
    if cle ~= "adaptateur" then surcouche[cle] = valeur end
  end
  local reglagesAdaptateur = reglages.adaptateur or reglages

  local configVehicule = fusionnerProfond(base, surcouche)
  configVehicule.adaptateur = nil
  configVehicule.seuilDeplacementConsigne = nil
  configVehicule.seuilVitesseConsigne = nil
  configVehicule.periodeRafraichissementConsigne = nil

  -- Reprise de mission : desactivee sauf demande explicite. Un intercepteur
  -- qui redemarre ne doit pas repartir sur une interception perimee.
  configVehicule.mission = configVehicule.mission or {}
  if reglages.mission == nil or reglages.mission.reprendreApresRedemarrage == nil then
    configVehicule.mission.reprendreApresRedemarrage = false
  end

  ------------------------------------------------------------------- instance
  -- Point d'injection reserve aux BANCS D'ESSAI. Un banc hors du jeu y depose
  -- un pilote de sorties simule, ce qui permet de rejouer une mission complete
  -- avec le VRAI module d'autopilote au lieu d'un substitut. A bord, cette
  -- table n'existe pas et rien n'est injecte : le module utilise ses propres
  -- sorties moteur.
  local banc = rawget(_G, "__FRENCHNET_BANC")
  if type(banc) == "table" and banc.commandes then
    journal.avert(E.LIAISON_AUTOPILOTE,
      "sorties moteur SIMULEES (banc d'essai) : le vehicule n'est pas reellement pilote")
  end

  local ap = moduleAp.nouveau({
    configuration = configVehicule,
    -- Journal PARTAGE : les lignes de l'autopilote atterrissent dans le meme
    -- fichier que celles du systeme d'interception, au meme format. C'est ce
    -- qui permet de relire une mission de bout en bout, vol compris.
    journal   = journal,
    commandes = type(banc) == "table" and banc.commandes or nil,
    cap       = type(banc) == "table" and banc.cap or nil,
  })
  ap.initialiser()

  journal.info(E.LIAISON_AUTOPILOTE, string.format(
    "module d'autopilote standardise v%s charge depuis %s | vehicule '%s' | "
    .. "asservissement en cascade, PID principal, repli zone morte",
    tostring(ap.VERSION), chemin, tostring(configVehicule.identifiant)))

  ------------------------------------------------------------------- reglages
  local seuil = reglagesAdaptateur.seuilDeplacementConsigne or 8
  local periode = reglagesAdaptateur.periodeRafraichissementConsigne or 2
  local seuilVitesse = reglagesAdaptateur.seuilVitesseConsigne or 5

  journal.info(E.LIAISON_AUTOPILOTE, string.format(
    "consignes limitees en debit : reemission au-dela de %.0f bloc(s) de "
    .. "deplacement, de %.0f b/s d'ecart de vitesse, ou toutes les %.1fs",
    seuil, seuilVitesse, periode))

  ---------------------------------------------------------------------- facade
  local facade = {
    module        = moduleAp,
    instance      = ap,
    chemin        = chemin,
    standard      = true,
    secours       = false,
    etatCache     = nil,
    dernierPoint  = nil,
    derniereVitesse = nil,
    derniereEmission = -math.huge,
    consignesEmises = 0,
    modePrecedent = nil,
  }

  --- Rafraichit l'instantane de l'autopilote. Appele une fois par cycle de
  -- controle : ap.etat() recopie en profondeur, l'appeler plusieurs fois par
  -- cycle serait du gaspillage pur.
  function facade.rafraichir()
    local ok, instantane = noyau.proteger(E.COMMANDE_AUTOPILOTE, ap.etat)
    if ok and type(instantane) == "table" then
      facade.etatCache = instantane
      return instantane
    end
    return nil
  end

  function facade.position()
    local e = facade.etatCache
    return (e and e.position) and { x = e.position.x, y = e.position.y, z = e.position.z } or nil
  end

  function facade.vitesse()
    local e = facade.etatCache
    return (e and e.vitesse) and { x = e.vitesse.x, y = e.vitesse.y, z = e.vitesse.z } or nil
  end

  --- Mode de pilotage reellement actif, axe par axe. Le basculement PID ->
  -- zone morte est decide par l'autopilote seul ; on se contente de le tracer,
  -- car c'est le meilleur indice pour expliquer une trajectoire degradee.
  function facade.mode()
    local e = facade.etatCache
    if not e then return nil end

    local degrades = {}
    for axe, mode in pairs(e.modesAxes or {}) do
      if mode ~= "pid" then degrades[#degrades + 1] = axe .. ":" .. tostring(mode) end
    end
    table.sort(degrades)
    local texte = (#degrades == 0) and "PID"
      or ("ZONE_MORTE sur " .. table.concat(degrades, ", "))

    if texte ~= facade.modePrecedent then
      if facade.modePrecedent ~= nil then
        journal.avert(E.MODE_AUTOPILOTE, string.format(
          "mode de pilotage : '%s' -> '%s'", facade.modePrecedent, texte))
      else
        journal.info(E.MODE_AUTOPILOTE, "mode de pilotage initial : " .. texte)
      end
      facade.modePrecedent = texte
    end
    return texte
  end

  --- Etat de vol de l'autopilote (ARRET / ACQUISITION / TRANSIT / MAINTIEN /
  -- SECOURS). Utilise par l'ecran d'etat du systeme d'exploitation.
  function facade.modeVol()
    local e = facade.etatCache
    return e and e.mode or nil
  end

  function facade.instantane() return facade.etatCache end

  --- Consigne de vol. C'est LA commande du systeme d'interception.
  -- @return true si la consigne a effectivement ete transmise
  function facade.definirPoint(point, motif, vitesse)
    local maintenant = noyau.maintenant()

    -- Limitation du debit : voir la precaution 1 en tete de fichier.
    if facade.dernierPoint then
      local deplacement = V.distance(point, facade.dernierPoint)
      local ecartVitesse = math.abs((vitesse or 0) - (facade.derniereVitesse or 0))
      if deplacement < seuil and ecartVitesse < seuilVitesse
         and (maintenant - facade.derniereEmission) < periode then
        return false
      end
    end

    local ok = noyau.proteger(E.COMMANDE_AUTOPILOTE, ap.allerA,
      { x = point.x, y = point.y, z = point.z, type = "survol" },
      {
        vitesseMax = vitesse,
        -- Precaution 2 : pas de montee en croisiere avant l'interception.
        transitHaute = false,
      })

    if ok then
      facade.dernierPoint = { x = point.x, y = point.y, z = point.z }
      facade.derniereVitesse = vitesse
      facade.derniereEmission = maintenant
      facade.consignesEmises = facade.consignesEmises + 1
      journal.limite("consigne_point", 3, "DEBUG", E.COMMANDE_AUTOPILOTE,
        string.format("consigne %s a %.1f b/s%s", V.format(point), vitesse or -1,
          motif and (" | " .. motif) or ""))
    end
    return ok
  end

  --- Itineraire complet confie a l'autopilote : c'est SON systeme de points de
  -- passage qui est utilise, pas une reimplementation. Sert au retour base.
  -- @param options { vitesse, altitudeCroisiere, surEtape, surArrivee }
  function facade.suivreItineraire(points, options)
    options = options or {}
    local itineraire = {}
    for i, p in ipairs(points) do
      itineraire[i] = { x = p.x, y = p.y, z = p.z, nom = p.nom, type = p.type or "survol" }
    end
    facade.dernierPoint = nil
    facade.derniereEmission = noyau.maintenant()
    return noyau.proteger(E.COMMANDE_AUTOPILOTE, ap.suivreItineraire, itineraire, {
      vitesseMax        = options.vitesse,
      altitudeCroisiere = options.altitudeCroisiere,
      transitHaute      = true, -- retour au calme : la croisiere reprend son sens
      surEtape          = options.surEtape,
      surArrivee        = options.surArrivee,
    })
  end

  function facade.estArrive()
    local ok, arrive = noyau.proteger(E.COMMANDE_AUTOPILOTE, ap.estArrive)
    return ok and arrive or false
  end

  function facade.stationnaire(point, cap)
    facade.dernierPoint = nil
    return noyau.proteger(E.COMMANDE_AUTOPILOTE, ap.maintenirPosition, point, cap)
  end

  --- Cap impose : sert a presenter l'arme a la cible sans quitter la trajectoire.
  function facade.definirCap(capDeg)
    if type(ap.forcerCap) ~= "function" then return false end
    return noyau.proteger(E.COMMANDE_AUTOPILOTE, ap.forcerCap, capDeg)
  end

  function facade.arreter(motif)
    return noyau.proteger(E.COMMANDE_AUTOPILOTE, ap.arreter, motif)
  end

  --- Boucle de vol de l'autopilote. A lancer en tache PARALLELE du systeme
  -- d'interception : c'est elle qui pilote reellement le vehicule.
  function facade.boucleDeVol()
    return ap.executer()
  end

  function facade.stopperBoucle()
    if type(ap.stopper) == "function" then pcall(ap.stopper) end
  end

  return facade
end

--------------------------------------------------------------------------------
-- 5. FACADE DE REPLI (module non standard exposant des fonctions plates)
--------------------------------------------------------------------------------

local function lireVecteur(...)
  local a, b, c = ...
  if type(a) == "table" then
    if noyau.nombreValide(a.x) then return { x = a.x, y = a.y or 0, z = a.z or 0 } end
    if noyau.nombreValide(a[1]) then return { x = a[1], y = a[2] or 0, z = a[3] or 0 } end
    return nil
  end
  if noyau.nombreValide(a) and noyau.nombreValide(b) and noyau.nombreValide(c) then
    return { x = a, y = b, z = c }
  end
  return nil
end

local function lierPlat(moduleAp, chemin, config)
  local lien, correspondances, manquants = {}, {}, {}
  for _, entree in ipairs(M.CONTRAT_PLAT) do
    local fn, nom = noyau.resoudreMethode(moduleAp, entree.candidats)
    if fn then
      lien[entree.role] = fn
      correspondances[#correspondances + 1] = entree.role .. " -> " .. nom .. "()"
    elseif entree.obligatoire then
      manquants[#manquants + 1] = entree.role .. " (noms acceptes : "
        .. table.concat(entree.candidats, ", ") .. ")"
    end
  end

  if #manquants > 0 then
    error("le module charge depuis " .. tostring(chemin) .. " n'expose ni nouveau() "
      .. "(module standardise FrenchNet) ni les capacites minimales d'un module "
      .. "plat : " .. table.concat(manquants, " | "), 0)
  end

  journal.avert(E.LIAISON_AUTOPILOTE, "module d'autopilote NON STANDARD charge depuis "
    .. tostring(chemin) .. " : liaison en mode plat")
  journal.info(E.LIAISON_AUTOPILOTE, "correspondance d'API : "
    .. table.concat(correspondances, ", "))

  local facade = {
    module = moduleAp, chemin = chemin, standard = false, secours = false,
    dernierPoint = nil, modePrecedent = nil, consignesEmises = 0,
  }

  if lien.demarrer then noyau.proteger(E.LIAISON_AUTOPILOTE, lien.demarrer, config.autopilote or {}) end

  function facade.rafraichir() return nil end
  function facade.instantane() return nil end
  function facade.modeVol() return nil end

  function facade.position()
    local ok, a, b, c = noyau.proteger(E.COMMANDE_AUTOPILOTE, lien.position)
    if not ok then return nil end
    return lireVecteur(a, b, c)
  end

  function facade.vitesse()
    if not lien.vitesse then return nil end
    local ok, a, b, c = noyau.proteger(E.COMMANDE_AUTOPILOTE, lien.vitesse)
    if not ok then return nil end
    return lireVecteur(a, b, c)
  end

  function facade.mode()
    if not lien.mode then return nil end
    local ok, valeur = noyau.proteger(E.MODE_AUTOPILOTE, lien.mode)
    if not ok then return nil end
    local texte = tostring(valeur)
    if texte ~= facade.modePrecedent then
      journal.info(E.MODE_AUTOPILOTE, "mode de pilotage : " .. texte)
      facade.modePrecedent = texte
    end
    return texte
  end

  function facade.definirPoint(point, motif, vitesse)
    facade.dernierPoint = { x = point.x, y = point.y, z = point.z }
    facade.consignesEmises = facade.consignesEmises + 1
    local ok = noyau.proteger(E.COMMANDE_AUTOPILOTE, lien.definirPoint,
      point.x, point.y, point.z)
    if ok and lien.definirVitesse and vitesse then
      noyau.proteger(E.COMMANDE_AUTOPILOTE, lien.definirVitesse, vitesse)
    end
    if ok then
      journal.limite("consigne_point", 3, "DEBUG", E.COMMANDE_AUTOPILOTE,
        string.format("consigne %s%s", V.format(point), motif and (" | " .. motif) or ""))
    end
    return ok
  end

  --- Pas d'itineraire natif : on rejoue les points un par un.
  function facade.suivreItineraire(points, options)
    options = options or {}
    facade.itineraire = points
    facade.indexItineraire = 1
    facade.surEtape = options.surEtape
    facade.surArrivee = options.surArrivee
    return facade.definirPoint(points[1], "itineraire", options.vitesse)
  end

  function facade.estArrive() return false end

  function facade.stationnaire(point)
    if lien.stationnaire then
      return noyau.proteger(E.COMMANDE_AUTOPILOTE, lien.stationnaire, point)
    end
    local p = point or facade.position()
    if p then facade.definirPoint(p, "maintien de position", 0) end
    return true
  end

  function facade.definirCap() return false end
  function facade.arreter(motif)
    if not lien.arreter then return false end
    return noyau.proteger(E.COMMANDE_AUTOPILOTE, lien.arreter, motif)
  end

  function facade.boucleDeVol()
    if lien.boucle then return lien.boucle() end
    -- Aucune boucle propre : on cadence nous-memes.
    while true do
      if lien.actualiser then noyau.proteger(E.COMMANDE_AUTOPILOTE, lien.actualiser) end
      sleep(0.05)
    end
  end

  function facade.stopperBoucle() end

  return facade
end

--------------------------------------------------------------------------------
-- 6. LIAISON
--------------------------------------------------------------------------------

--- Etablit la liaison avec le module d'autopilote.
-- Leve une erreur explicite si le module est introuvable : voler avec un
-- controleur de substitution serait plus dangereux que de rester au sol.
function M.lier(config)
  local moduleAp, chemin, essais = chargerModule(config)

  if not moduleAp then
    error("module d'autopilote introuvable. Le navire ne decolle pas. "
      .. "Installez autopilote/autopilote.lua ou renseignez 'cheminAutopilote' "
      .. "dans config_intercepteur.lua. Emplacements explores : "
      .. table.concat(essais or {}, " | "), 0)
  end

  -- Module standardise FrenchNet : c'est le chemin nominal.
  if type(moduleAp.nouveau) == "function" then
    return lierStandard(moduleAp, chemin, config)
  end

  -- Sinon on tente une liaison generique, en le signalant clairement.
  return lierPlat(moduleAp, chemin, config)
end

return M
