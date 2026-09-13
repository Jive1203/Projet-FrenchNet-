-- Banc d'essai de la calibration automatique du cablage, hors du jeu.
--   Usage : lua5.4 tests/test_calibration.lua   (depuis la racine du depot)
--
-- Principe de ces essais : on donne au vehicule simule un cablage REEL que le
-- programme ignore (tests/banc_vol.lua, option 'cablageReel'), et l'on verifie
-- qu'il le retrouve seul, face par face, en ne disposant que du GPS.
--
-- On eprouve les trois situations qui comptent :
--   * un capteur de cap existe     -> le lacet se lit directement ;
--   * pas de capteur, mais l'ordinateur est decale du centre -> le lacet se
--     deduit de la trajectoire circulaire du point GPS ;
--   * ni l'un ni l'autre           -> le lacet n'est PAS observable, et le
--     module doit le dire au lieu de declarer les faces inertes.

local RACINE = (arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."
local SCR    = RACINE .. "/tests"
local SRC    = RACINE .. "/autopilote"
local BANC   = "/tmp/banc_calibration_frenchnet"

local echecs, total = 0, 0

local function verifier(nom, condition, detail)
  total = total + 1
  if condition then
    print(string.format("  [OK]   %s", nom))
  else
    echecs = echecs + 1
    print(string.format("  [ECHEC] %s %s", nom, detail and ("-> " .. tostring(detail)) or ""))
  end
end

local function preparer()
  os.execute("rm -rf " .. BANC .. " && mkdir -p " .. BANC .. "/autopilote")
  os.execute("cp " .. SRC .. "/*.lua " .. BANC .. "/autopilote/ 2>/dev/null")
end

--- Journal en memoire : on verifie CE QUE LE MODULE DIT, pas seulement ce
-- qu'il calcule. Un diagnostic muet ne vaut rien pour l'operateur.
local function journalMemoire()
  local lignes = {}
  local j = {}
  local function poser(niveau)
    return function(etape, message)
      lignes[#lignes + 1] = string.format("[%s] [%s] %s", niveau,
        tostring(etape), tostring(message))
    end
  end
  j.debug, j.info      = poser("DEBUG"), poser("INFO")
  j.avert, j.erreur    = poser("AVERT"), poser("ERREUR")
  j.critique           = poser("CRITIQUE")
  j.lignes = lignes
  function j.contient(motif)
    for _, ligne in ipairs(lignes) do
      if ligne:find(motif, 1, true) then return true, ligne end
    end
    return false
  end
  return j
end

--- Monte un vehicule simule, son cablage cache, et un moteur de calibration
-- qui n'en sait rien.
local function monter(options)
  options = options or {}
  preparer()
  local banc = dofile(SCR .. "/banc_vol.lua")
  local env, etat = banc.creer({
    racine      = BANC,
    budget      = options.budget or 5000,
    bruitGps    = options.bruitGps or 0.10,
    decalageGps = options.decalageGps or { x = 0, y = 2, z = 4 },
    cablageReel = options.cablageReel,
    satellites  = options.satellites,
    vehicule    = options.vehicule or {
      x = 100, y = 150, z = 100, cap = 0,
      vMax = 4, vVerticalMax = 3, vLateralMax = 2, tauxMax = 25,
    },
  })

  local autopilote  = banc.charger(SRC .. "/autopilote.lua")
  local calibration = banc.charger(SRC .. "/calibration.lua", autopilote)
  local config      = autopilote.chargerConfiguration("/autopilote/config_vehicule.lua")

  -- On part d'un vehicule dont le cablage est INCONNU : c'est tout l'objet.
  config.sorties.axes = {
    avance = { mode = "aucun" }, vertical = { mode = "aucun" },
    lacet  = { mode = "aucun" }, lateral  = { mode = "aucun" },
  }
  config.decalageGps = options.decalageGps or { x = 0, y = 2, z = 4 }
  if options.configuration then options.configuration(config) end

  local journal = journalMemoire()
  local moteur = calibration.nouveau({
    config   = config,
    journal  = journal,
    reglages = options.reglages or {
      impulsion = 2.0, stabilisation = 1.0, attenteMax = 14,
      seuilBruit = 1.0, delaiSatellites = 4,
    },
  })

  return {
    env = env, etat = etat, banc = banc, config = config,
    autopilote = autopilote, calibration = calibration,
    moteur = moteur, journal = journal,
  }
end

--- Cablage de reference : six faces, trois axes, deux sens chacun.
local CABLAGE_COMPLET = {
  front  = { axe = "avance",   signe =  1 },
  back   = { axe = "avance",   signe = -1 },
  top    = { axe = "vertical", signe =  1 },
  bottom = { axe = "vertical", signe = -1 },
  right  = { axe = "lacet",    signe =  1 },
  left   = { axe = "lacet",    signe = -1 },
}

--- Axe retrouve, sous forme comparable.
local function decrire(axes, nom)
  local a = axes[nom] or { mode = "aucun" }
  if a.mode == "bipolaire" then
    return string.format("bipolaire +%s/-%s", tostring(a.cotePositif), tostring(a.coteNegatif))
  elseif a.mode == "analogique" then
    return string.format("analogique %s n=%s a=%s%s", tostring(a.cote),
      tostring(a.neutre), tostring(a.amplitude), a.inverse and " inverse" or "")
  end
  return "aucun"
end

--------------------------------------------------------------------------------
print("\n== TEST 1 : unitaires de geometrie ==")
do
  preparer()
  local banc = dofile(SCR .. "/banc_vol.lua")
  banc.creer({ racine = BANC, budget = 60 })
  local autopilote  = banc.charger(SRC .. "/autopilote.lua")
  local calibration = banc.charger(SRC .. "/calibration.lua", autopilote)

  -- Deux deplacements paralleles : translation.
  local genre = calibration.discriminer({ x = 10, z = 0 }, { x = 10, z = 0 }, 1, 0.25)
  verifier("deux poussees paralleles = translation", genre == "translation", genre)

  -- Deuxieme deplacement tourne de 30 deg : rotation, sens horaire = tribord.
  local d2 = { x = 10 * math.cos(math.rad(30)), z = 10 * math.sin(math.rad(30)) }
  local genreR, sinus = calibration.discriminer({ x = 10, z = 0 }, d2, 1, 0.25)
  verifier("deux poussees tournees = rotation", genreR == "rotation", genreR)
  verifier("rotation horaire = signe positif (tribord)", sinus > 0, sinus)

  -- Presque demi-tour : sinus faible mais cosinus negatif -> jamais translation.
  local d3 = { x = -10, z = 0.3 }
  local genreA = calibration.discriminer({ x = 10, z = 0 }, d3, 1, 0.25)
  verifier("demi-tour non pris pour une translation", genreA == "rotation_ambigue", genreA)

  -- Trop court pour decider.
  local genreI = calibration.discriminer({ x = 0.1, z = 0 }, { x = 0.1, z = 0 }, 1, 0.25)
  verifier("deplacement sous le bruit = indecidable", genreI == "indecidable", genreI)

  -- Cercle : trois points d'un cercle de rayon 4 centre en (100, 100).
  local points = {}
  for _, angle in ipairs({ 0, 40, 80 }) do
    local r = math.rad(angle)
    points[#points + 1] = { x = 100 + 4 * math.sin(r), z = 100 - 4 * math.cos(r) }
  end
  local centre, rayon = calibration.centreCercle(points[1], points[2], points[3])
  verifier("centre de rotation retrouve",
    centre and math.abs(centre.x - 100) < 0.01 and math.abs(centre.z - 100) < 0.01,
    centre and (centre.x .. "," .. centre.z))
  verifier("rayon de rotation retrouve", rayon and math.abs(rayon - 4) < 0.01, rayon)

  -- Ordinateur 4 blocs DEVANT le centre : le bras pointe le nez du vehicule.
  -- Au dernier point l'angle vaut 80 deg, donc le nez est a 80 deg.
  local cap = calibration.capParRotation(points, { x = 0, y = 2, z = 4 })
  verifier("cap reel deduit du cercle", cap and math.abs(cap - 80) < 2, cap)

  -- Bras trop court : on refuse plutot que de deduire n'importe quoi.
  local capCourt, motif = calibration.capParRotation(points, { x = 0, y = 2, z = 0 })
  verifier("bras de levier nul : deduction refusee", capCourt == nil, motif)

  -- Points alignes : ce n'est pas une rotation.
  local droit = { { x = 0, z = 0 }, { x = 5, z = 0 }, { x = 10, z = 0 } }
  local capDroit = calibration.capParRotation(droit, { x = 0, y = 0, z = 4 })
  verifier("points alignes : aucun cap deduit", capDroit == nil)
end

--------------------------------------------------------------------------------
print("\n== TEST 2 : cablage complet retrouve grace au decalage GPS ==")
do
  local m = monter({ cablageReel = CABLAGE_COMPLET })
  local ok, resultat = pcall(m.moteur.executer)
  verifier("la calibration va au bout", ok, not ok and tostring(resultat) or nil)

  if ok then
    verifier("lacet declare observable", resultat.lacetObservable == true)
    verifier("axe AVANCE trouve en bipolaire",
      resultat.axes.avance.mode == "bipolaire", decrire(resultat.axes, "avance"))
    verifier("axe VERTICAL trouve en bipolaire",
      resultat.axes.vertical.mode == "bipolaire", decrire(resultat.axes, "vertical"))
    verifier("axe LACET trouve en bipolaire",
      resultat.axes.lacet.mode == "bipolaire", decrire(resultat.axes, "lacet"))

    verifier("AVANCE : front en positif, back en negatif",
      resultat.axes.avance.cotePositif == "front"
      and resultat.axes.avance.coteNegatif == "back", decrire(resultat.axes, "avance"))
    verifier("VERTICAL : top monte, bottom descend",
      resultat.axes.vertical.cotePositif == "top"
      and resultat.axes.vertical.coteNegatif == "bottom", decrire(resultat.axes, "vertical"))
    verifier("LACET : right a tribord, left a babord",
      resultat.axes.lacet.cotePositif == "right"
      and resultat.axes.lacet.coteNegatif == "left", decrire(resultat.axes, "lacet"))

    verifier("aucun axe essentiel manquant", #resultat.manquants == 0,
      table.concat(resultat.manquants, ","))
    verifier("le cap reel a bien ete deduit d'une rotation",
      (m.journal.contient("cap reel du vehicule deduit de la rotation")))
    verifier("le vehicule est reste pres du point de calibration",
      math.abs(m.etat.vehicule.x - 100) < 250 and math.abs(m.etat.vehicule.z - 100) < 250,
      string.format("%.0f, %.0f", m.etat.vehicule.x, m.etat.vehicule.z))
    verifier("toutes les faces sont retombees a zero en fin de calibration",
      (m.etat.faces.front or 0) == 0 and (m.etat.faces.top or 0) == 0
      and (m.etat.faces.right or 0) == 0)
  end
end

--------------------------------------------------------------------------------
print("\n== TEST 3 : capteur de cap present (lacet lu directement) ==")
do
  local m = monter({
    cablageReel = CABLAGE_COMPLET,
    configuration = function(config)
      config.cap.source = "peripherique"
      config.cap.peripherique = "boussole"
      config.cap.methode = "getYaw"
      config.cap.convention = "frenchnet"
    end,
  })

  -- Boussole simulee : elle lit le cap vrai du vehicule.
  m.env.peripheral.wrap = function(nom)
    if nom ~= "boussole" then return nil end
    return { getYaw = function() return m.etat.vehicule.cap end }
  end

  local ok, resultat = pcall(m.moteur.executer)
  verifier("la calibration va au bout", ok, not ok and tostring(resultat) or nil)
  if ok then
    verifier("source de cap = peripherique", resultat.capSource == "peripherique",
      resultat.capSource)
    verifier("AVANCE : front en positif (cap connu, aucune convention)",
      resultat.axes.avance.cotePositif == "front", decrire(resultat.axes, "avance"))
    verifier("LACET : right a tribord",
      resultat.axes.lacet.cotePositif == "right", decrire(resultat.axes, "lacet"))
    verifier("lacet identifie au capteur, pas par le cercle",
      (m.journal.contient("deg au capteur")))
  end
end

--------------------------------------------------------------------------------
print("\n== TEST 4 : lacet NON observable, l'operateur est prevenu ==")
do
  -- Ordinateur pile au centre du vehicule et aucun capteur de cap : une
  -- rotation ne deplace plus le point GPS. Le module doit le dire.
  local m = monter({
    cablageReel = CABLAGE_COMPLET,
    decalageGps = { x = 0, y = 0, z = 0 },
  })
  local ok, resultat = pcall(m.moteur.executer)
  verifier("la calibration va au bout malgre tout", ok, not ok and tostring(resultat) or nil)

  if ok then
    verifier("lacet declare NON observable", resultat.lacetObservable == false)
    verifier("l'operateur est prevenu explicitement",
      (m.journal.contient("LACET NON OBSERVABLE")))
    verifier("le remede est indique dans le journal",
      (m.journal.contient("decalageGps")))
    verifier("les faces de rotation sont signalees comme suspectes",
      #resultat.suspectesLacet >= 2, #resultat.suspectesLacet)
    verifier("les faces suspectes sont bien left et right",
      (function()
        local trouve = {}
        for _, cle in ipairs(resultat.suspectesLacet) do trouve[cle] = true end
        return trouve.left and trouve.right
      end)(), table.concat(resultat.suspectesLacet, ","))
    verifier("axe LACET non equipe faute de mesure",
      resultat.axes.lacet.mode == "aucun", decrire(resultat.axes, "lacet"))
    verifier("les axes mesurables sont quand meme trouves",
      resultat.axes.avance.mode ~= "aucun" and resultat.axes.vertical.mode ~= "aucun")
    verifier("le lacet est signale manquant", (function()
      for _, nom in ipairs(resultat.manquants) do if nom == "lacet" then return true end end
      return false
    end)(), table.concat(resultat.manquants, ","))
  end
end

--------------------------------------------------------------------------------
print("\n== TEST 5 : sorties deportees sur un satellite ==")
do
  -- L'axe vertical n'est atteignable QUE par un ordinateur satellite : c'est le
  -- cas "plusieurs computers avec modems" du cahier des charges.
  local m = monter({
    cablageReel = {
      front         = { axe = "avance",   signe =  1 },
      back          = { axe = "avance",   signe = -1 },
      right         = { axe = "lacet",    signe =  1 },
      left          = { axe = "lacet",    signe = -1 },
      ["#42:top"]   = { axe = "vertical", signe =  1 },
      ["#42:bottom"]= { axe = "vertical", signe = -1 },
    },
    satellites = {
      [42] = { identifiant = "SAT-VENTRAL", vehicule = "AER-CARGO-01",
               cotes = { "top", "bottom" } },
    },
    configuration = function(config)
      config.sorties.distant.actif = true
    end,
  })

  local ok, resultat = pcall(m.moteur.executer)
  verifier("la calibration va au bout", ok, not ok and tostring(resultat) or nil)

  if ok then
    verifier("le satellite a ete decouvert par son annonce",
      resultat.satellites[42] ~= nil)
    verifier("son identifiant est journalise",
      (m.journal.contient("SAT-VENTRAL")))
    verifier("l'axe VERTICAL est trouve sur le satellite",
      resultat.axes.vertical.mode == "bipolaire"
      and resultat.axes.vertical.ordinateur == 42, decrire(resultat.axes, "vertical"))
    verifier("VERTICAL : top monte, bottom descend",
      resultat.axes.vertical.cotePositif == "top"
      and resultat.axes.vertical.coteNegatif == "bottom", decrire(resultat.axes, "vertical"))
    verifier("les axes locaux restent locaux",
      resultat.axes.avance.ordinateur == nil, tostring(resultat.axes.avance.ordinateur))
    verifier("le satellite a bien recu des trames",
      m.etat.satellites[42].trames > 0, m.etat.satellites[42].trames)
    verifier("les faces du satellite sont retombees a zero",
      (m.etat.faces["#42:top"] or 0) == 0 and (m.etat.faces["#42:bottom"] or 0) == 0)
  end
end

--------------------------------------------------------------------------------
print("\n== TEST 6 : un satellite d'un AUTRE vehicule n'est jamais commande ==")
do
  local m = monter({
    cablageReel = CABLAGE_COMPLET,
    satellites = {
      [77] = { identifiant = "SAT-VOISIN", vehicule = "AER-AUTRE-99",
               cotes = { "top", "bottom" } },
    },
    configuration = function(config)
      config.sorties.distant.actif = true
      config.identifiant = "AER-CARGO-01"
    end,
  })

  local ok, resultat = pcall(m.moteur.executer)
  verifier("la calibration va au bout", ok, not ok and tostring(resultat) or nil)
  if ok then
    verifier("le satellite du voisin est ecarte du recensement",
      resultat.satellites[77] == nil,
      resultat.satellites[77] and "retenu a tort" or nil)
    verifier("aucun axe ne pointe vers le vehicule voisin",
      (resultat.axes.vertical.ordinateur == nil)
      and (resultat.axes.avance.ordinateur == nil))
  end
end

--------------------------------------------------------------------------------
print("\n== TEST 7 : faces reservees et interdites ecartees ==")
do
  local m = monter({
    cablageReel = CABLAGE_COMPLET,
    configuration = function(config)
      config.cotesInterdits = { left = true }
      config.carburant.coteAmarre = "bottom"
    end,
  })

  m.moteur.recenserSatellites()
  m.moteur.preparer()
  local faces = m.moteur.recenser()

  local presentes = {}
  for _, face in ipairs(faces) do presentes[m.moteur.cleFace(face)] = true end

  verifier("face interdite par la configuration ecartee", not presentes.left)
  verifier("face reservee au voyant d'amarrage ecartee", not presentes.bottom)
  verifier("les autres faces restent candidates",
    presentes.front and presentes.back and presentes.top and presentes.right)
  verifier("le motif d'exclusion est journalise",
    (m.journal.contient("interdite par la configuration"))
    and (m.journal.contient("reservee")))
end

--------------------------------------------------------------------------------
print("\n== TEST 8 : arret de securite si le vehicule s'eloigne trop ==")
do
  local m = monter({
    cablageReel = { front = { axe = "avance", signe = 1 } },
    vehicule = { x = 100, y = 150, z = 100, cap = 0,
                 vMax = 60, vVerticalMax = 3, tauxMax = 20 },
    reglages = { impulsion = 4.0, stabilisation = 1.0, attenteMax = 14,
                 seuilBruit = 1.0, rayonSecurite = 30, delaiSatellites = 2,
                 recentrer = false },
  })

  local ok, err = pcall(m.moteur.executer)
  verifier("la calibration s'interrompt", not ok)
  verifier("le motif est l'arret de securite",
    tostring(err):find("arret de securite", 1, true) ~= nil
    or tostring(err):find("eloigne", 1, true) ~= nil, tostring(err))
  verifier("les commandes sont neutralisees malgre l'interruption",
    (m.etat.faces.front or 0) == 0, m.etat.faces.front)
  verifier("la coupure est journalisee",
    (m.journal.contient("commandes neutralisees")))
end

--------------------------------------------------------------------------------
print("\n== TEST 9 : ecriture dans la configuration vehicule ==")
do
  local m = monter({ cablageReel = CABLAGE_COMPLET })
  local ok, resultat = pcall(m.moteur.executer)
  verifier("la calibration va au bout", ok, not ok and tostring(resultat) or nil)

  if ok then
    -- Inversion reglee a la main par l'operateur sur un axe au cablage inchange.
    m.config.sorties.axes.vertical = {
      mode = "bipolaire", cotePositif = "top", coteNegatif = "bottom",
      amplitude = 15, seuil = 0.08, inverse = true,
    }
    m.calibration.appliquerA(m.config, resultat.axes)

    verifier("les axes calibres sont reportes dans la configuration",
      m.config.sorties.axes.avance.cotePositif == "front")
    verifier("une inversion reglee a la main sur un cablage inchange est conservee",
      m.config.sorties.axes.vertical.inverse == true,
      tostring(m.config.sorties.axes.vertical.inverse))

    local chemin = m.calibration.ecrireConfiguration(m.config,
      "/autopilote/config_vehicule.lua")
    verifier("le fichier est ecrit", chemin ~= nil)

    -- Relecture : la configuration ecrite doit etre du Lua valide et relisible
    -- par le module lui-meme, sinon l'autopilote ne demarrera plus.
    local relue = m.autopilote.chargerConfiguration("/autopilote/config_vehicule.lua")
    verifier("la configuration reecrite est relisible", type(relue) == "table")
    verifier("l'axe AVANCE a survecu a l'aller-retour",
      relue.sorties.axes.avance.cotePositif == "front"
      and relue.sorties.axes.avance.coteNegatif == "back",
      decrire(relue.sorties.axes, "avance"))
    verifier("l'axe LACET a survecu a l'aller-retour",
      relue.sorties.axes.lacet.cotePositif == "right", decrire(relue.sorties.axes, "lacet"))
    verifier("la configuration relue reste valide pour l'autopilote",
      (m.autopilote.verifierConfiguration(relue)))
  end
end

--------------------------------------------------------------------------------
print("\n== TEST 10 : vehicule sans commande laterale ==")
do
  local m = monter({
    cablageReel = {
      front  = { axe = "avance",   signe =  1 },
      back   = { axe = "avance",   signe = -1 },
      top    = { axe = "vertical", signe =  1 },
      bottom = { axe = "vertical", signe = -1 },
      right  = { axe = "lacet",    signe =  1 },
      left   = { axe = "lacet",    signe = -1 },
    },
    vehicule = { x = 100, y = 150, z = 100, cap = 0,
                 vMax = 4, vVerticalMax = 3, vLateralMax = 0, tauxMax = 25 },
  })
  local ok, resultat = pcall(m.moteur.executer)
  verifier("la calibration va au bout", ok, not ok and tostring(resultat) or nil)
  if ok then
    verifier("l'axe LATERAL est declare non equipe",
      resultat.axes.lateral.mode == "aucun", decrire(resultat.axes, "lateral"))
    verifier("le lateral absent ne bloque pas la calibration",
      #resultat.manquants == 0, table.concat(resultat.manquants, ","))
  end
end

--------------------------------------------------------------------------------
print("\n== TEST 11 : reconnaissance automatique et quarantaine ==")
do
  preparer()
  local banc = dofile(SCR .. "/banc_vol.lua")
  local env = banc.creer({
    racine = BANC, budget = 120,
    peripheriques = {
      back      = { type = "modem", methodes = { isWireless = function() return true end } },
      moniteur  = { type = "monitor" },
      coffre    = { type = "minecraft:chest",
                    methodes = { list = function() end, getItemDetail = function() end } },
      integre   = { methodes = { setAnalogOutput = function() end } },
      ["mod:ballista"] = { type = "ballistix:heavy_ballista",
                           methodes = { fire = function() end, aim = function() end } },
    },
  })
  local peripheriques = banc.charger(SRC .. "/peripheriques.lua")

  verifier("un modem est reconnu comme COMMUNICATION",
    (peripheriques.reconnaitre("back")) == "COMMUNICATION")
  verifier("un moniteur est reconnu comme AFFICHAGE",
    (peripheriques.reconnaitre("moniteur")) == "AFFICHAGE")
  verifier("un coffre est reconnu par son type prefixe",
    (peripheriques.reconnaitre("coffre")) == "STOCKAGE")
  verifier("un bloc a setAnalogOutput est reconnu par sa signature",
    (peripheriques.reconnaitre("integre")) == "SORTIE_REDSTONE")

  local code, motif = peripheriques.reconnaitre("mod:ballista")
  verifier("un bloc d'un mod inconnu n'est PAS devine", code == nil, code)
  verifier("le motif du refus est explicite",
    motif and motif:find("inconnu", 1, true) ~= nil, motif)

  local inventaire = peripheriques.inventorier(peripheriques.registreVide())
  verifier("l'inconnu part en quarantaine", #inventaire.quarantaine == 1,
    #inventaire.quarantaine)
  verifier("c'est bien le bloc du mod inconnu",
    inventaire.quarantaine[1] and inventaire.quarantaine[1].nom == "mod:ballista")
  verifier("les quatre autres sont classes",
    inventaire.fiches.back.classe == "COMMUNICATION"
    and inventaire.fiches.integre.classe == "SORTIE_REDSTONE")
end

--------------------------------------------------------------------------------
print("\n== TEST 12 : fiche operateur, validation et registre ==")
do
  preparer()
  local banc = dofile(SCR .. "/banc_vol.lua")
  banc.creer({
    racine = BANC, budget = 120,
    peripheriques = {
      ["mod:ballista"] = { type = "ballistix:heavy_ballista" },
      ["mod:gyro"]     = { type = "truc:gyroscope" },
    },
  })
  local peripheriques = banc.charger(SRC .. "/peripheriques.lua")

  -- ARMEMENT exige une confirmation explicite de l'operateur.
  local sansConfirmation = { nom = "mod:ballista", classe = "ARMEMENT", details = {} }
  local valide, anomalies = peripheriques.validerFiche(sansConfirmation)
  verifier("une fiche ARMEMENT sans confirmation est refusee", not valide)
  verifier("le motif nomme le champ manquant",
    anomalies[1] and anomalies[1]:find("confirmation", 1, true) ~= nil,
    anomalies[1])

  local armement = { nom = "mod:ballista", classe = "ARMEMENT",
    details = { confirmation = true, cotes = { "front" } } }
  verifier("une fiche ARMEMENT confirmee est acceptee",
    (peripheriques.validerFiche(armement)))

  -- Une classe inconnue ne passe pas.
  verifier("une classe inventee est refusee",
    not peripheriques.validerFiche({ nom = "x", classe = "PROPULSION_MAGIQUE" }))

  -- COMMANDE_VOL doit designer un axe qui existe.
  local mauvaisAxe = { nom = "mod:gyro", classe = "COMMANDE_VOL",
    details = { axe = "roulis", methode = "setRoll", facteur = 1 } }
  local okAxe, motifs = peripheriques.validerFiche(mauvaisAxe)
  verifier("un axe inexistant est refuse", not okAxe)
  verifier("les axes attendus sont rappeles",
    motifs[1] and motifs[1]:find("avance", 1, true) ~= nil, motifs[1])

  -- Aller-retour sur disque.
  local registre = peripheriques.registreVide()
  registre.fiches["mod:ballista"] = armement
  registre.fiches["mod:gyro"] = { nom = "mod:gyro", classe = "CAPTEUR_CAP",
    details = { methode = "getHeading", convention = "boussole",
                facteur = 1, decalage = 0 } }

  local chemin = peripheriques.enregistrer("/autopilote/registre_test.lua", registre)
  verifier("le registre est ecrit", chemin ~= nil)

  local relu, erreur = peripheriques.charger("/autopilote/registre_test.lua")
  verifier("le registre est relisible", erreur == nil, erreur)
  verifier("la fiche ARMEMENT a survecu",
    relu.fiches["mod:ballista"].details.confirmation == true)
  verifier("la fiche CAPTEUR_CAP a survecu",
    relu.fiches["mod:gyro"].details.methode == "getHeading")

  -- La fiche operateur prime sur la reconnaissance automatique.
  local inventaire = peripheriques.inventorier(relu)
  verifier("plus rien en quarantaine apres classement",
    #inventaire.quarantaine == 0, #inventaire.quarantaine)
  verifier("l'origine des fiches est bien l'operateur",
    inventaire.fiches["mod:gyro"].origine == "operateur")
end

--------------------------------------------------------------------------------
print("\n== TEST 13 : la quarantaine bloque la calibration ==")
do
  local m = monter({ cablageReel = CABLAGE_COMPLET })
  local moteur = m.calibration.nouveau({
    config  = m.config,
    journal = m.journal,
    quarantaine = { { nom = "mod:ballista", type = "ballistix:heavy_ballista",
                      motif = "type inconnu" } },
    reglages = { impulsion = 2.0, stabilisation = 1.0, seuilBruit = 1.0 },
  })

  local ok, err = pcall(moteur.executer)
  verifier("la calibration refuse de demarrer", not ok)
  verifier("le refus nomme la cause",
    tostring(err):find("CALIBRATION REFUSEE", 1, true) ~= nil, tostring(err))
  verifier("le remede est indique a l'operateur",
    tostring(err):find("classer", 1, true) ~= nil)
  verifier("le peripherique fautif est nomme dans le journal",
    (m.journal.contient("mod:ballista")))
  verifier("aucune face n'a ete actionnee",
    (m.etat.faces.front or 0) == 0 and (m.etat.faces.top or 0) == 0)

  -- Passer outre reste possible, mais il faut le demander explicitement.
  m.config.peripheriques = { exigerClassement = false }
  local moteur2 = m.calibration.nouveau({
    config  = m.config,
    journal = m.journal,
    quarantaine = { { nom = "mod:ballista", type = "ballistix:heavy_ballista" } },
    reglages = { impulsion = 2.0, stabilisation = 1.0, attenteMax = 14,
                 seuilBruit = 1.0, delaiSatellites = 2 },
  })
  local ok2, resultat2 = pcall(moteur2.executer)
  verifier("'exigerClassement = false' laisse passer", ok2,
    not ok2 and tostring(resultat2) or nil)
  if ok2 then
    verifier("et la calibration aboutit quand meme",
      resultat2.axes.avance.mode ~= "aucun", decrire(resultat2.axes, "avance"))
  end
end

--------------------------------------------------------------------------------
print("\n== TEST 14 : un armement n'est jamais essaye ==")
do
  preparer()
  local banc = dofile(SCR .. "/banc_vol.lua")
  local env, etat = banc.creer({
    racine = BANC, budget = 5000, bruitGps = 0.1,
    decalageGps = { x = 0, y = 2, z = 4 },
    cablageReel = CABLAGE_COMPLET,
    vehicule = { x = 100, y = 150, z = 100, cap = 0,
                 vMax = 4, vVerticalMax = 3, vLateralMax = 2, tauxMax = 25 },
    peripheriques = {
      front = { type = "ballistix:heavy_ballista" },   -- canon accole a l'avant
    },
  })

  local autopilote    = banc.charger(SRC .. "/autopilote.lua")
  local peripheriques = banc.charger(SRC .. "/peripheriques.lua")
  local calibration   = banc.charger(SRC .. "/calibration.lua", autopilote)

  local registre = peripheriques.registreVide()
  registre.fiches.front = { nom = "front", classe = "ARMEMENT",
    details = { confirmation = true, cotes = { "front" } } }

  local inventaire = peripheriques.inventorier(registre)
  local interdites = peripheriques.facesInterdites(inventaire)
  verifier("la face du canon est declaree interdite", interdites.front ~= nil,
    interdites.front)
  verifier("le motif nomme l'armement",
    interdites.front and interdites.front:find("armement", 1, true) ~= nil,
    interdites.front)

  local config = autopilote.chargerConfiguration("/autopilote/config_vehicule.lua")
  config.sorties.axes = {
    avance = { mode = "aucun" }, vertical = { mode = "aucun" },
    lacet = { mode = "aucun" }, lateral = { mode = "aucun" },
  }
  config.decalageGps = { x = 0, y = 2, z = 4 }

  local journal = journalMemoire()
  local moteur = calibration.nouveau({
    config = config, journal = journal,
    quarantaine = inventaire.quarantaine,
    facesInterdites = interdites,
    reglages = { impulsion = 2.0, stabilisation = 1.0, attenteMax = 14,
                 seuilBruit = 1.0, delaiSatellites = 2 },
  })

  local ok, resultat = pcall(moteur.executer)
  verifier("la calibration va au bout", ok, not ok and tostring(resultat) or nil)
  if ok then
    verifier("la face du canon n'a JAMAIS ete mise sous tension",
      (etat.faces.front or 0) == 0, etat.faces.front)
    verifier("aucun axe n'utilise la face du canon", (function()
      for _, axe in pairs(resultat.axes) do
        if axe.cote == "front" or axe.cotePositif == "front"
           or axe.coteNegatif == "front" then return false end
      end
      return true
    end)())
    verifier("l'exclusion est journalisee",
      (journal.contient("reservee")))
    verifier("les autres axes sont quand meme trouves",
      resultat.axes.vertical.mode == "bipolaire"
      and resultat.axes.lacet.mode == "bipolaire")
  end
end

--------------------------------------------------------------------------------
print("\n== TEST 15 : report des classes dans la configuration ==")
do
  preparer()
  local banc = dofile(SCR .. "/banc_vol.lua")
  banc.creer({
    racine = BANC, budget = 120,
    peripheriques = {
      gyro     = { type = "truc:gyroscope" },
      telemetre= { type = "truc:telemetre" },
      cuve     = { type = "truc:cuve" },
    },
  })
  local autopilote    = banc.charger(SRC .. "/autopilote.lua")
  local peripheriques = banc.charger(SRC .. "/peripheriques.lua")

  local registre = peripheriques.registreVide()
  registre.fiches.gyro = { nom = "gyro", classe = "CAPTEUR_CAP",
    details = { methode = "getHeading", convention = "boussole",
                facteur = 1, decalage = 0 } }
  registre.fiches.telemetre = { nom = "telemetre", classe = "CAPTEUR_SOL",
    details = { methode = "getDistance", facteur = 1, decalage = 0 } }
  registre.fiches.cuve = { nom = "cuve", classe = "JAUGE_CARBURANT",
    details = { methode = "tanks" } }

  local inventaire = peripheriques.inventorier(registre)
  local config = autopilote.chargerConfiguration("/autopilote/config_vehicule.lua")
  local appliques = peripheriques.appliquerA(config, inventaire)

  verifier("trois reglages reportes", #appliques == 3, #appliques)
  verifier("le cap bascule sur le capteur",
    config.cap.source == "peripherique" and config.cap.peripherique == "gyro",
    config.cap.peripherique)
  verifier("la convention d'angle est reprise de la fiche",
    config.cap.convention == "boussole", config.cap.convention)
  verifier("la hauteur sol bascule sur le telemetre",
    config.sol.source == "peripherique"
    and config.sol.peripherique.nom == "telemetre")
  verifier("le carburant bascule sur la cuve",
    config.carburant.source == "peripherique"
    and config.carburant.peripherique.nom == "cuve")
  verifier("la configuration reste valide pour l'autopilote",
    (autopilote.verifierConfiguration(config)))
end

print(string.format("\n===== %d/%d verifications reussies =====", total - echecs, total))
os.exit(echecs == 0 and 0 or 1)
