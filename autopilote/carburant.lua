--[[----------------------------------------------------------------------------
  SURVEILLANCE CARBURANT ET RAVITAILLEMENT AUTOMATIQUE - FRENCHNET
  --------------------------------------------------------------------------
  Module autonome, construit UNIQUEMENT sur l'interface publique de
  l'autopilote : il surveille le niveau de carburant, ramene le vehicule a la
  station des que le reservoir descend trop bas (ou sur ordre redstone),
  l'amarre par un atterrissage de precision sur la zone de ravitaillement,
  attend le plein, puis rend la main.

  Usage :
      local autopilote = dofile("/autopilote/autopilote.lua")
      local carburant  = dofile("/autopilote/carburant.lua")

      local ap    = autopilote.nouveau()
      local jauge = carburant.nouveau(ap, {
        surRetour = function() print("retour ravitaillement") end,
        surDepart = function() reprendreLaMission() end,
      })

      ap.initialiser()
      parallel.waitForAny(ap.executer, jauge.executer, mission)

  CONTRAT AVEC LE PROGRAMME DE MISSION : quand la jauge prend la main, elle
  pilote le vehicule. Le programme de mission ne doit plus donner d'ordre tant
  que jauge.estOccupe() est vrai ; il reprend sur le rappel surDepart.

  La position de la station vient du fichier verrouille ravitaillement.lua :
  elle n'est pas modifiable depuis la configuration du vehicule.
--------------------------------------------------------------------------------]]

local carburant = {}
carburant.VERSION = "1.0.0"

local ETAPES = {
  DEMARRAGE  = "demarrage de la surveillance carburant",
  LECTURE    = "lecture de la jauge",
  ORDRE      = "ordre redstone",
  RETOUR     = "retour au ravitaillement",
  APPROCHE   = "approche de la station",
  AMARRAGE   = "amarrage de precision",
  ATTENTE    = "attente du plein",
  DEPART     = "liberation du vehicule",
  ANOMALIE   = "anomalie de ravitaillement",
}

local ETATS = {
  VEILLE   = "VEILLE",    -- surveillance seule, le vehicule est a la mission
  RETOUR   = "RETOUR",    -- route vers la verticale de la station
  AMARRAGE = "AMARRAGE",  -- descente de precision sur le docker
  AMARRE   = "AMARRE",    -- pose, en attente du plein
  ANOMALIE = "ANOMALIE",  -- quelque chose s'est mal passe, plus d'automatisme
}
carburant.ETATS = ETATS

local DEFAUTS = {
  actif  = true,
  source = "peripherique",   -- "peripherique" | "redstone" | "aucun"

  peripherique = {
    nom     = nil,
    methode = "tanks",       -- "tanks" = API fluides generique de CC: Tweaked
    fluide  = nil,           -- filtre sur le nom du fluide (nil = tous)
    max     = nil,           -- capacite, si la methode ne la donne pas
  },

  redstone = {
    cote       = "back",
    ordinateur = nil,        -- lecture via un satellite de sortie
    mode       = "analogique", -- "analogique" (0-15) | "signal" (allume = bas)
    inverse    = false,
    max        = 15,
  },

  seuilBas   = 0.25,   -- fraction du plein : declenche le retour
  seuilPlein = 0.92,   -- fraction du plein : autorise le depart
  periode    = 5,      -- secondes entre deux lectures

  coteRetour = nil,    -- entree : un courant force le retour immediat
  coteDepart = nil,    -- entree : un courant libere le vehicule
  coteAmarre = nil,    -- sortie : allumee tant que le vehicule est amarre
  ordinateurOrdres = nil,

  amarrage = {
    altitudeApproche     = 12,   -- hauteur tenue a la verticale avant descente
    toleranceHorizontale = 0.6,
    toleranceAltitude    = 0.4,
    toleranceCap         = 3,
    dureeArrivee         = 3,
    vitesseApproche      = 1.2,
    delaiMax             = 600,  -- s pour rejoindre puis s'amarrer
    attenteMax           = 1800, -- s d'attente amarre avant alerte
    maintenirPendantAttente = true,
  },
}

local function nombreValide(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function fusionner(base, ajout)
  local resultat = {}
  for cle, valeur in pairs(base) do
    if type(valeur) == "table" then resultat[cle] = fusionner(valeur, {}) else resultat[cle] = valeur end
  end
  if type(ajout) ~= "table" then return resultat end
  for cle, valeur in pairs(ajout) do
    if type(valeur) == "table" and type(resultat[cle]) == "table" then
      resultat[cle] = fusionner(resultat[cle], valeur)
    else
      resultat[cle] = valeur
    end
  end
  return resultat
end

--------------------------------------------------------------------------------
-- LECTURE DE LA JAUGE
--------------------------------------------------------------------------------

--- Lecture par peripherique. Deux formes acceptees :
--   * methode "tanks" : API fluides generique de CC: Tweaked, qui expose tout
--     bloc a capacite fluide (cuve, reservoir) branche ou accole ;
--   * toute autre methode : elle doit renvoyer un nombre, ou une table
--     { amount = , capacity = }.
local function lirePeripherique(reglages, journal)
  local p = reglages.peripherique or {}
  if not (peripheral and p.nom) then return nil, "aucun peripherique declare" end
  local materiel = peripheral.wrap(p.nom)
  if not materiel then return nil, "peripherique introuvable : " .. tostring(p.nom) end

  local nomMethode = p.methode or "tanks"
  local methode = materiel[nomMethode]
  if type(methode) ~= "function" then
    return nil, string.format("methode '%s' absente de '%s'", nomMethode, tostring(p.nom))
  end

  local ok, resultat = pcall(methode)
  if not ok then return nil, "lecture refusee : " .. tostring(resultat) end

  if nomMethode == "tanks" then
    if type(resultat) ~= "table" then return nil, "reponse 'tanks' inattendue" end
    local quantite, capacite = 0, 0
    for _, cuve in pairs(resultat) do
      if type(cuve) == "table" then
        local correspond = (not p.fluide)
          or (cuve.name and tostring(cuve.name):find(p.fluide, 1, true) ~= nil)
        if correspond then
          quantite = quantite + (tonumber(cuve.amount) or 0)
          capacite = capacite + (tonumber(cuve.capacity) or 0)
        end
      end
    end
    if capacite <= 0 then capacite = tonumber(p.max) or 0 end
    if capacite <= 0 then
      return nil, "capacite inconnue : renseignez 'carburant.peripherique.max'"
    end
    return math.max(0, math.min(1, quantite / capacite))
  end

  if type(resultat) == "table" then
    local quantite = tonumber(resultat.amount) or tonumber(resultat.level)
    local capacite = tonumber(resultat.capacity) or tonumber(p.max)
    if quantite and capacite and capacite > 0 then
      return math.max(0, math.min(1, quantite / capacite))
    end
    return nil, "reponse du peripherique inexploitable"
  end

  local valeur = tonumber(resultat)
  if not valeur then return nil, "reponse du peripherique non numerique" end
  local capacite = tonumber(p.max)
  if not capacite or capacite <= 0 then
    -- Une methode qui renvoie deja une fraction est acceptee telle quelle.
    if valeur >= 0 and valeur <= 1 then return valeur end
    return nil, "capacite inconnue : renseignez 'carburant.peripherique.max'"
  end
  return math.max(0, math.min(1, valeur / capacite))
end

--- Lecture par signal redstone, local ou remonte par un satellite.
local function lireRedstone(reglages, ap)
  local r = reglages.redstone or {}
  local niveau
  if r.ordinateur then
    niveau = ap.entreeDistante(r.ordinateur, r.cote)
    if niveau == nil then return nil, "satellite #" .. tostring(r.ordinateur) .. " sans nouvelles" end
  elseif redstone and r.cote then
    local ok, valeur = pcall(redstone.getAnalogInput, r.cote)
    if not ok then return nil, "face '" .. tostring(r.cote) .. "' illisible" end
    niveau = valeur
  else
    return nil, "aucune face declaree"
  end
  if not nombreValide(niveau) then return nil, "lecture invalide" end

  if r.mode == "signal" then
    -- Tout ou rien : un courant signifie "carburant bas".
    local bas = niveau > 0
    if r.inverse then bas = not bas end
    return bas and 0 or 1
  end

  if r.inverse then niveau = (r.max or 15) - niveau end
  return math.max(0, math.min(1, niveau / (r.max or 15)))
end

--------------------------------------------------------------------------------
-- INSTANCE
--------------------------------------------------------------------------------

--- @param ap instance d'autopilote (deja construite)
--- @param options { surRetour, surAmarrage, surDepart, surAnomalie, config }
function carburant.nouveau(ap, options)
  options = options or {}
  local reglages = fusionner(DEFAUTS, options.config or ap.config.carburant or {})
  local journal = ap.journal
  local station = ap.ravitaillement()

  local jauge = {}
  local etat = {
    etat     = ETATS.VEILLE,
    niveau   = nil,
    motif    = nil,
    lectures = 0,
    echecs   = 0,
    derniereAnomalie = nil,
    depuis   = os.clock(),
  }
  local rappels = {}

  local function emettre(typeEvenement, donnees)
    donnees = donnees or {}
    donnees.type   = typeEvenement
    donnees.niveau = etat.niveau
    donnees.etat   = etat.etat
    for _, rappel in ipairs(rappels) do pcall(rappel, typeEvenement, donnees) end
    pcall(os.queueEvent, "carburant", ap.config.identifiant, typeEvenement, donnees)
  end

  local function changerEtat(nouvel, motif)
    if etat.etat == nouvel then return end
    journal.info(ETAPES.RETOUR, string.format("ravitaillement : %s -> %s (%s)",
      etat.etat, nouvel, tostring(motif)))
    etat.etat, etat.motif, etat.depuis = nouvel, motif, os.clock()
  end

  --- Ecrit la sortie "amarre" a destination de la station.
  local function signalerAmarre(actif)
    if not (reglages.coteAmarre and redstone) then return end
    pcall(redstone.setOutput, reglages.coteAmarre, actif and true or false)
  end

  --- Lit une entree d'ordre (retour ou depart), locale ou deportee.
  local function ordrePresent(cote)
    if not cote then return false end
    if reglages.ordinateurOrdres then
      local niveau = ap.entreeDistante(reglages.ordinateurOrdres, cote)
      return nombreValide(niveau) and niveau > 0
    end
    if not redstone then return false end
    local ok, valeur = pcall(redstone.getInput, cote)
    return ok and valeur and true or false
  end

  --- Niveau de carburant, en fraction du plein (0 a 1), ou nil.
  function jauge.niveau()
    if reglages.source == "aucun" then return nil end
    local valeur, motif
    if reglages.source == "redstone" then
      valeur, motif = lireRedstone(reglages, ap)
    else
      valeur, motif = lirePeripherique(reglages, journal)
    end

    if valeur == nil then
      etat.echecs = etat.echecs + 1
      if etat.derniereAnomalie ~= motif then
        etat.derniereAnomalie = motif
        journal.avert(ETAPES.LECTURE, "jauge illisible : " .. tostring(motif))
        emettre("anomalie", { motif = "jauge_illisible", detail = motif })
      end
      return nil, motif
    end

    etat.echecs = 0
    etat.derniereAnomalie = nil
    etat.lectures = etat.lectures + 1
    etat.niveau = valeur
    return valeur
  end

  function jauge.etat()
    return {
      etat = etat.etat, niveau = etat.niveau, motif = etat.motif,
      lectures = etat.lectures, echecs = etat.echecs,
      depuis = os.clock() - etat.depuis, station = station,
    }
  end

  function jauge.estAmarre() return etat.etat == ETATS.AMARRE end
  function jauge.estOccupe()
    return etat.etat ~= ETATS.VEILLE and etat.etat ~= ETATS.ANOMALIE
  end

  function jauge.surEvenement(rappel)
    if type(rappel) == "function" then rappels[#rappels + 1] = rappel end
    return jauge
  end

  ------------------------------------------------------------------ manoeuvre
  local a = reglages.amarrage

  local function tolerancesAmarrage()
    return {
      horizontale  = a.toleranceHorizontale,
      altitude     = a.toleranceAltitude,
      cap          = a.toleranceCap,
      dureeArrivee = a.dureeArrivee,
    }
  end

  --- Rejoint la verticale de la station, puis descend sur le docker.
  -- Le point d'amarrage est de type "amarrage" : l'autopilote applique le
  -- decalage du docker, de sorte que la PRISE tombe sur la zone, et non le
  -- centre geometrique du vehicule.
  local function manoeuvreAmarrage()
    changerEtat(ETATS.RETOUR, etat.motif)
    emettre("retour", { station = station })
    if options.surRetour then pcall(options.surRetour, etat.niveau, etat.motif) end

    -- 1. Verticale de la station, a l'altitude d'approche.
    journal.info(ETAPES.APPROCHE, string.format(
      "route vers la verticale de %s, %d bloc(s) au-dessus",
      station.nom, a.altitudeApproche))
    ap.allerA({
      x = station.position.x,
      y = station.position.y + a.altitudeApproche,
      z = station.position.z,
      cap = station.capFinal,
      nom = "VERTICALE " .. station.nom,
    }, { tolerances = tolerancesAmarrage() })

    local arrive = ap.attendreArrivee(a.delaiMax)
    if not arrive then
      changerEtat(ETATS.ANOMALIE, "verticale non atteinte")
      journal.erreur(ETAPES.ANOMALIE, "verticale de la station non atteinte dans le delai")
      emettre("anomalie", { motif = "verticale_non_atteinte" })
      if options.surAnomalie then pcall(options.surAnomalie, "verticale_non_atteinte") end
      return false
    end

    -- 2. Descente de precision sur le docker.
    changerEtat(ETATS.AMARRAGE, "descente sur le docker")
    journal.info(ETAPES.AMARRAGE, string.format(
      "descente de precision sur %s (tolerance %.2fm / %.2fm)",
      station.nom, a.toleranceHorizontale, a.toleranceAltitude))
    ap.allerA({
      x = station.position.x, y = station.position.y, z = station.position.z,
      type = "amarrage", cap = station.capFinal, nom = station.nom,
    }, {
      tolerances   = tolerancesAmarrage(),
      vitesseMax   = a.vitesseApproche,
      transitHaute = false,
    })

    if not ap.attendreArrivee(a.delaiMax) then
      changerEtat(ETATS.ANOMALIE, "amarrage non abouti")
      journal.erreur(ETAPES.ANOMALIE, "amarrage non abouti dans le delai")
      emettre("anomalie", { motif = "amarrage_non_abouti" })
      if options.surAnomalie then pcall(options.surAnomalie, "amarrage_non_abouti") end
      return false
    end

    -- 3. Amarre.
    changerEtat(ETATS.AMARRE, "vehicule amarre")
    signalerAmarre(true)
    if not a.maintenirPendantAttente then ap.arreter("amarre au ravitaillement") end
    journal.info(ETAPES.AMARRAGE, "vehicule amarre a la station, en attente du plein")
    emettre("amarre", { station = station })
    if options.surAmarrage then pcall(options.surAmarrage, station) end
    return true
  end

  --- Attend le plein, ou l'ordre de depart.
  local function attendreLePlein()
    local debut = os.clock()
    while true do
      local niveau = jauge.niveau()

      if ordrePresent(reglages.coteDepart) then
        journal.info(ETAPES.DEPART, "ordre de depart recu (redstone)")
        return true, "ordre_redstone"
      end
      if niveau and niveau >= reglages.seuilPlein then
        journal.info(ETAPES.DEPART, string.format(
          "plein atteint : %.0f %% (seuil %.0f %%)",
          niveau * 100, reglages.seuilPlein * 100))
        return true, "plein"
      end

      local attente = os.clock() - debut
      if attente > a.attenteMax then
        journal.erreur(ETAPES.ANOMALIE, string.format(
          "toujours amarre apres %.0fs sans atteindre le plein", attente))
        emettre("anomalie", { motif = "attente_trop_longue", attente = attente })
        if options.surAnomalie then pcall(options.surAnomalie, "attente_trop_longue") end
        return false, "attente_trop_longue"
      end

      sleep(reglages.periode)
    end
  end

  --- Libere le vehicule et rend la main au programme de mission.
  local function liberer(motif)
    signalerAmarre(false)
    if not a.maintenirPendantAttente then
      ap.initialiser()
      ap.maintenirPosition()
    end
    changerEtat(ETATS.VEILLE, motif)
    journal.info(ETAPES.DEPART, "vehicule libere : " .. tostring(motif))
    emettre("depart", { motif = motif })
    if options.surDepart then pcall(options.surDepart, motif) end
  end

  --- Declenche un retour immediat, quelle que soit la jauge.
  function jauge.declencherRetour(motif)
    if jauge.estOccupe() then return false end
    etat.motif = motif or "demande manuelle"
    return true
  end

  --- Force la liberation (bouton de la station, ordre du controleur).
  function jauge.liberer(motif)
    if etat.etat ~= ETATS.AMARRE then return false end
    liberer(motif or "liberation manuelle")
    return true
  end

  ------------------------------------------------------------------ boucle
  --- Boucle de surveillance, a lancer en parallele du vol.
  function jauge.executer()
    jauge.actif = true
    journal.info(ETAPES.DEMARRAGE, string.format(
      "surveillance carburant : source '%s', retour sous %.0f %%, depart au-dessus de %.0f %%",
      tostring(reglages.source), reglages.seuilBas * 100, reglages.seuilPlein * 100))

    if not reglages.actif then
      journal.avert(ETAPES.DEMARRAGE, "surveillance carburant desactivee par la configuration")
      while jauge.actif do sleep(10) end
      return
    end

    while jauge.actif do
      if etat.etat == ETATS.VEILLE then
        local niveau = jauge.niveau()
        local declencher, motif = false, nil

        if etat.motif then
          declencher, motif = true, etat.motif
        elseif ordrePresent(reglages.coteRetour) then
          declencher, motif = true, "ordre redstone de retour"
        elseif niveau and niveau <= reglages.seuilBas then
          declencher = true
          motif = string.format("carburant a %.0f %% (seuil %.0f %%)",
            niveau * 100, reglages.seuilBas * 100)
        end

        if declencher then
          etat.motif = motif
          journal.avert(ETAPES.RETOUR, "retour au ravitaillement declenche : " .. motif)
          local ok = manoeuvreAmarrage()
          if ok then
            local libere, motifDepart = attendreLePlein()
            if libere then
              liberer(motifDepart)
              etat.motif = nil
            end
          end
        else
          emettre("niveau", { niveau = niveau })
        end
      end

      sleep(reglages.periode)
    end
  end

  function jauge.stopper() jauge.actif = false end

  return jauge
end

return carburant
