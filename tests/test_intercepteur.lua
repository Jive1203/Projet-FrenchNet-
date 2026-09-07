-- Banc d'essai du systeme embarque intercepteur, hors du jeu, sur Lua 5.4.
--   Usage : lua5.4 tests/test_intercepteur.lua   (depuis la racine du depot)
--
-- Simule CraftOS (tests/craftos.lua) enrichi d'un radar Create Radars et d'un
-- affut Create Big Cannons, plus un faux module d'autopilote qui fait
-- reellement voler le navire (tests/banc_autopilote.lua). Le navire parcourt
-- donc une mission complete : ordre de scramble, rejointe, entree dans l'arc
-- arriere, tir, degat, evasion, destruction confirmee, retour base.

local RACINE = (arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."
local SCR    = RACINE .. "/tests"
local SRC    = RACINE .. "/intercepteur"
local BANC   = "/tmp/banc_intercepteur_frenchnet"

local noyau = assert(loadfile(RACINE .. "/intercepteur/noyau.lua"))("intercepteur")
local V = noyau.vec

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

local function contient(sorties, motif)
  for _, ligne in ipairs(sorties) do
    if ligne:find(motif, 1, true) then return true, ligne end
  end
  return false
end

local function compter(sorties, motif)
  local n = 0
  for _, ligne in ipairs(sorties) do
    if ligne:find(motif, 1, true) then n = n + 1 end
  end
  return n
end

--------------------------------------------------------------------------------
-- PREPARATION DU BANC
--------------------------------------------------------------------------------

local function preparer(config, options)
  options = options or {}
  os.execute("rm -rf " .. BANC .. " && mkdir -p " .. BANC .. "/intercepteur "
    .. BANC .. "/autopilote")
  os.execute("cp " .. SRC .. "/noyau.lua " .. SRC .. "/interception.lua "
    .. SRC .. "/autopilote.lua " .. SRC .. "/radar.lua " .. SRC .. "/armement.lua "
    .. SRC .. "/liaison.lua " .. SRC .. "/intercepteur.lua "
    .. BANC .. "/intercepteur/")

  local f = io.open(BANC .. "/intercepteur/config_intercepteur.lua", "w")
  f:write(config)
  f:close()

  if not options.sansAutopilote then
    os.execute("cp " .. SCR .. "/banc_autopilote.lua " .. BANC .. "/autopilote/autopilote.lua")
  end
end

--- Configuration de reference du banc. 'REMPLACEMENTS' permet a chaque scenario
--- d'ajouter ou de surcharger des cles.
local function configuration(supplement)
  return ([[
return {
  identifiant = "INT-01",
  designation = "Banc d'essai",
  protocoleRednet = "frenchnet_ordre",
  cheminAutopilote = "/autopilote/autopilote.lua",
  autopiloteDeSecours = false,
  accuserReception = true,
  posteDeCommandement = 9,

  periodeControle = 0.25,
  periodeRadar = 0.5,
  battementSecondes = 30,
  delaiRechercheSecondes = 20,

  journalFichier = true,
  journalNiveauEcran = "DEBUG",
  periodeJournalInterception = 2,
  arretParTerminate = true,

  autopilote = { pid = { lacet = { kp = 1.8 } }, deadBand = { seuilPosition = 8 } },

  interception = {
    arcMiniDeg = 120, arcMaxiDeg = 240, arcCentreDeg = 180, margeArcDeg = 10,
    manoeuvre = "orbite", arcAmplitudeDeg = 45, arcPeriodeSecondes = 12,
    distanceMini = 300, distanceMaxi = 400, distanceAmplitude = 30,
    distanceSecurite = 150, distanceTransit = 250,
    deltaYNominal = 0, deltaYAmplitude = 15, toleranceAltitude = 60,
    predictionMiniSecondes = 1, predictionMaxiSecondes = 10,
    vitesseMaxi = 120, vitesseReference = 90,
    gainRapprochement = 0.35, ratioMini = 0.6, ratioMaxi = 1.6,
  },

  degats = {
    fenetreSecondes = 3, dureeMiniSecondes = 0.5,
    chuteAltitudeBlocs = 25, perteVitesseRatio = 0.40, perteVitesseMini = 15,
    perteContactSecondes = 5, altitudeSolConfirmee = 5,
    vitesseEpaveMaxi = 3, dureeEpaveSecondes = 4, refractaireSecondes = 8,
  },

  arme = {
    mode = "peripherique", coteRedstone = nil,
    vitesseObus = 80, graviteObus = 9.8,
    distanceTirMini = 80, distanceTirMaxi = 420, toleranceViseeDeg = 3,
    dureeRafale = 1.5, pauseRafale = 2.0,
  },

  radar = {
    rayonAppariement = 250, lissageVitesse = 0.5, dtMiniVitesse = 0.15,
    delaiValiditePiste = 3, periodeJournalPistage = 5,
  },

  evasion = {
    dureeSecondes = 6, angleBreakDeg = 55, distanceEvasion = 300,
    altitudePlancher = 80, altitudePlafond = 300, altitudeSolPresumee = 64,
  },

  retour = {
    pointsRetour = {
      { x = 900, y = 220, z = -900, nom = "point de degagement" },
      { x = 1000, y = 150, z = -1000, nom = "base" },
    },
    rayonPointRetour = 40, vitesseRetour = 120, altitudeCroisiere = 220,
  },

  %s
}
]]):format(supplement or "")
end

--------------------------------------------------------------------------------
-- MONDE SIMULE : peripheriques radar / affut / redstone
--------------------------------------------------------------------------------

local function equiper(env, etat, monde)
  local horloge = env.os.clock

  local modem = {
    isWireless = function() return true end,
    open = function(c) etat.canaux = etat.canaux or {}; etat.canaux[c] = true end,
    isOpen = function(c) return (etat.canaux or {})[c] == true end,
    close = function() end,
    transmit = function() end,
  }

  local radar = {
    getEntities = function()
      monde.balayages = monde.balayages + 1
      local contacts = {}
      local cible = monde.cible(horloge())
      if cible then
        contacts[#contacts + 1] = {
          id = "cible-01", type = "createaeronautics:aircraft",
          x = cible.x, y = cible.y, z = cible.z,
        }
      end
      -- Leurre lointain : verifie que l'appariement ne s'y accroche pas.
      contacts[#contacts + 1] = {
        id = "leurre-99", type = "minecraft:cow", x = -5000, y = 70, z = 5000,
      }
      return contacts
    end,
  }

  local affut = {
    setYaw   = function(v) monde.lacet = v end,
    setPitch = function(v) monde.tangage = v end,
    getYaw   = function() return monde.lacet or 0 end,
    getPitch = function() return monde.tangage or 0 end,
    fire     = function() monde.tirs = monde.tirs + 1 end,
  }

  local TYPES = {
    back     = "modem",
    radar_0  = "create_radars:radar",
    cannon_0 = "createbigcannons:cannon_mount",
  }
  local OBJETS = { back = modem, radar_0 = radar, cannon_0 = affut }

  env.peripheral = {
    getNames  = function() return { "back", "radar_0", "cannon_0" } end,
    getType   = function(n) return TYPES[n] end,
    isPresent = function(n) return TYPES[n] ~= nil end,
    wrap      = function(n) return OBJETS[n] end,
    hasType   = function(n, t)
      if n ~= "back" then return TYPES[n] == t end
      return t == "modem" or t == "ender_modem"
    end,
  }

  env.redstone = {
    setOutput = function(cote, actif) monde.redstone = actif end,
    getOutput = function() return monde.redstone == true end,
  }
  env.rs = env.redstone
  env.shell = { getRunningProgram = function() return "intercepteur/intercepteur.lua" end }
  env.modem = modem
end

--- Trajectoire de cible : ligne droite, arret possible a une date donnee.
local function cibleRectiligne(depart, vitesse, options)
  options = options or {}
  return function(t)
    if options.disparaitA and t >= options.disparaitA then return nil end
    local position = {
      x = depart.x + vitesse.x * t,
      y = depart.y + vitesse.y * t,
      z = depart.z + vitesse.z * t,
    }
    -- Chute brutale simulant un encaissement (declenche les criteres de degat).
    if options.chuteA and t >= options.chuteA then
      position.y = position.y - math.min((t - options.chuteA) * 40, 200)
    end
    return position
  end
end

local function monter(config, options)
  options = options or {}
  preparer(config, options)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({ racine = BANC, id = 21, label = "INT-01" })
  env.__craftos = craftos
  local monde = {
    balayages = 0, tirs = 0, lacet = nil, tangage = nil, redstone = false,
    cible = options.cible or cibleRectiligne(
      { x = 0, y = 150, z = 0 }, { x = 0, y = 0, z = 60 }),
  }
  equiper(env, etat, monde)
  -- Le navire demarre en attente, en arriere de la trajectoire de la cible.
  env.__BANC_DEPART = options.depart or { x = 0, y = 150, z = -1500 }
  return craftos, env, etat, monde
end

--------------------------------------------------------------------------------
print("\n== TEST 1 : mission nominale - scramble, rejointe, arc arriere ==")
do
  local craftos, env, etat, monde = monter(configuration())
  -- Cible cap au sud a 60 b/s ; navire lache 1500 blocs derriere elle.
  monde.cible = cibleRectiligne({ x = 0, y = 150, z = 0 }, { x = 0, y = 0, z = 60 })

  craftos.injecterRednet(9, {
    protocole = "FRENCHNET_ORDRE", type = "SCRAMBLE",
    identifiantOrdre = "ORD-001", destinataire = "INT-01",
    cible = { x = 0, y = 150, z = 0 },
  }, "frenchnet_ordre")

  local motif = craftos.executer(BANC .. "/intercepteur/intercepteur.lua", 120)

  verifier("le programme tourne sans se terminer", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("module d'autopilote charge (aucune loi de vol reecrite)",
    (contient(etat.sorties, "module d'autopilote charge depuis /autopilote/autopilote.lua")))
  verifier("correspondance d'API journalisee",
    (contient(etat.sorties, "correspondance d'API")))
  verifier("radar embarque detecte",
    (contient(etat.sorties, "radar embarque sur 'radar_0'")))
  verifier("affut detecte", (contient(etat.sorties, "affut detecte sur 'cannon_0'")))
  verifier("independance annoncee au demarrage",
    (contient(etat.sorties, "aucune notion de zone ni de classe a bord")))

  verifier("ordre de scramble recu et journalise",
    (contient(etat.sorties, "ORDRE DE SCRAMBLE ORD-001 recu du poste #9")))
  verifier("passage en transit", (contient(etat.sorties, "etat VEILLE -> TRANSIT")))
  verifier("cible acquise par le radar embarque",
    (contient(etat.sorties, "cible acquise par le radar embarque")))
  verifier("calcul de trajectoire d'interception journalise",
    (contient(etat.sorties, "[etape: calcul de trajectoire d'interception]")))
  verifier("prediction : impact predit annonce",
    (contient(etat.sorties, "impact predit dans")))
  verifier("ENTREE EN POSITION D'ATTAQUE",
    (contient(etat.sorties, "EN POSITION D'ATTAQUE")))
  verifier("passage a l'etat POSITION_ATTAQUE",
    (contient(etat.sorties, "-> POSITION_ATTAQUE")))
  verifier("manoeuvre d'orbite engagee dans l'arc",
    (contient(etat.sorties, "[etape: manoeuvre d'orbite / zigzag dans l'arc arriere]")))
  verifier("le radar a bien balaye", monde.balayages > 50, monde.balayages)

  -- Verification geometrique finale : le navire est-il vraiment dans l'arc
  -- arriere 4h-8h, a 300-400 blocs ?
  local ap = env.__BANC_AP
  local tFin = env.os.clock()
  local cible = monde.cible(tFin)
  local capCible = noyau.relevement({ x = 0, y = 0, z = 60 })
  local relatif = noyau.relevementRelatif(capCible, cible, ap.position)
  local distance = V.distance(ap.position, cible)

  verifier("position finale DANS l'arc arriere 4h-8h",
    relatif >= 120 and relatif <= 240,
    string.format("%.1f deg (%s)", relatif, noyau.positionHoraire(relatif)))
  verifier("position finale dans la bande 300-400 blocs",
    distance >= 290 and distance <= 410, string.format("%.1f blocs", distance))
  verifier("le navire n'a jamais tire sans ordre de feu", monde.tirs == 0, monde.tirs)
  verifier("aucun tir : le feu reste interdit",
    (contient(etat.sorties, "feu interdit")))
end

--------------------------------------------------------------------------------
print("\n== TEST 2 : approche par l'avant - le navire contourne, jamais de face ==")
do
  -- Navire lache 1200 blocs DEVANT une cible qui fonce sur lui.
  local craftos, env, etat, monde = monter(configuration(),
    { depart = { x = 0, y = 150, z = 1200 } })
  monde.cible = cibleRectiligne({ x = 0, y = 150, z = 0 }, { x = 0, y = 0, z = 60 })

  craftos.injecterRednet(9, {
    protocole = "FRENCHNET_ORDRE", type = "SCRAMBLE",
    identifiantOrdre = "ORD-002",
    cible = { x = 0, y = 150, z = 0 },
  }, "frenchnet_ordre")

  local motif = craftos.executer(BANC .. "/intercepteur/intercepteur.lua", 150)
  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))

  local ap = env.__BANC_AP
  local tFin = env.os.clock()
  local cible = monde.cible(tFin)
  local capCible = noyau.relevement({ x = 0, y = 0, z = 60 })
  local relatif = noyau.relevementRelatif(capCible, cible, ap.position)
  verifier("le navire termine dans l'arc arriere",
    relatif >= 120 and relatif <= 240,
    string.format("%.1f deg (%s)", relatif, noyau.positionHoraire(relatif)))
end

--------------------------------------------------------------------------------
print("\n== TEST 3 : ordre de feu - engagement sans quitter l'arc ==")
do
  local craftos, env, etat, monde = monter(configuration())
  monde.cible = cibleRectiligne({ x = 0, y = 150, z = 0 }, { x = 0, y = 0, z = 55 })

  craftos.injecterRednet(9, {
    protocole = "FRENCHNET_ORDRE", type = "SCRAMBLE",
    identifiantOrdre = "ORD-010", cible = { x = 0, y = 150, z = 0 },
  }, "frenchnet_ordre")
  -- L'ordre de feu arrive plus tard, une fois le navire en place.
  craftos.injecterRednet(9, {
    protocole = "FRENCHNET_ORDRE", type = "FEU", identifiantOrdre = "ORD-011",
  }, "frenchnet_ordre")

  local motif = craftos.executer(BANC .. "/intercepteur/intercepteur.lua", 160)
  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("ordre de feu recu", (contient(etat.sorties, "ORDRE DE FEU ORD-011")))
  verifier("le feu est explicitement subordonne a l'arc",
    (contient(etat.sorties, "la contrainte de position prime sur l'ordre de tir")))
  verifier("solution de tir calculee et tir effectue",
    (contient(etat.sorties, "rafale n1 ouverte")))
  verifier("solution de tir detaillee dans le journal",
    (contient(etat.sorties, "azimut")) and (contient(etat.sorties, "chute compensee")))
  verifier("l'affut a reellement fait feu", monde.tirs >= 1, monde.tirs)
  verifier("cadence respectee (fin de rafale journalisee)",
    (contient(etat.sorties, "fin de rafale apres")))

  local ap = env.__BANC_AP
  local cible = monde.cible(env.os.clock())
  local relatif = noyau.relevementRelatif(noyau.relevement({ x = 0, y = 0, z = 55 }),
    cible, ap.position)
  verifier("le navire tire DEPUIS l'arc arriere",
    relatif >= 120 and relatif <= 240,
    string.format("%.1f deg (%s)", relatif, noyau.positionHoraire(relatif)))
end

--------------------------------------------------------------------------------
print("\n== TEST 4 : degat subi -> evasion prioritaire puis reprise ==")
do
  local craftos, env, etat, monde = monter(configuration())
  monde.cible = cibleRectiligne({ x = 0, y = 150, z = 0 }, { x = 0, y = 0, z = 55 })

  craftos.injecterRednet(9, {
    protocole = "FRENCHNET_ORDRE", type = "SCRAMBLE",
    identifiantOrdre = "ORD-020", cible = { x = 0, y = 150, z = 0 },
  }, "frenchnet_ordre")

  -- A t = 60 s, le navire encaisse : perte brutale de 40 blocs d'altitude.
  env.__BANC_PERTURBATION = function(ap, t, dt)
    if t >= 60 and t < 61.5 then
      ap.position.y = ap.position.y - 30 * dt / 0.25 * 0.25
    end
  end

  local motif = craftos.executer(BANC .. "/intercepteur/intercepteur.lua", 160)
  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("degat subi detecte",
    (contient(etat.sorties, "DEGAT SUBI PAR LE NAVIRE")))
  verifier("criteres de degat annonces comme partages",
    (contient(etat.sorties, "criteres identiques a ceux de la confirmation de destruction")))
  verifier("manoeuvre d'evasion prioritaire declenchee",
    (contient(etat.sorties, "MANOEUVRE D'EVASION PRIORITAIRE")))
  verifier("evasion en break, pas en ligne droite",
    (contient(etat.sorties, "break")))
  verifier("passage a l'etat EVASION", (contient(etat.sorties, "-> EVASION")))
  verifier("fin d'evasion et reprise de la position d'attaque",
    (contient(etat.sorties, "[etape: fin de la manoeuvre d'evasion]")))
  verifier("retour a la poursuite apres evasion",
    (contient(etat.sorties, "etat EVASION -> TRANSIT")))
end

--------------------------------------------------------------------------------
print("\n== TEST 5 : destruction confirmee -> retour base -> rearmement manuel ==")
do
  local craftos, env, etat, monde = monter(configuration())
  -- La cible chute a t=70 s (degat), puis disparait du radar a t=76 s.
  monde.cible = cibleRectiligne({ x = 0, y = 150, z = 0 }, { x = 0, y = 0, z = 55 },
    { chuteA = 70, disparaitA = 76 })

  craftos.injecterRednet(9, {
    protocole = "FRENCHNET_ORDRE", type = "SCRAMBLE",
    identifiantOrdre = "ORD-030", cible = { x = 0, y = 150, z = 0 },
  }, "frenchnet_ordre")
  craftos.injecterRednet(9, {
    protocole = "FRENCHNET_ORDRE", type = "FEU", identifiantOrdre = "ORD-031",
  }, "frenchnet_ordre")

  local motif = craftos.executer(BANC .. "/intercepteur/intercepteur.lua", 260)
  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("degat sur la cible detecte",
    (contient(etat.sorties, "DEGAT SUR LA CIBLE")))
  verifier("destruction confirmee (et non simple perte de contact)",
    (contient(etat.sorties, "DESTRUCTION DE LA CIBLE CONFIRMEE")))
  verifier("retour base engage",
    (contient(etat.sorties, "RETOUR BASE engage")))
  verifier("points de retour suivis dans l'ordre",
    (contient(etat.sorties, "point de retour 1/2 atteint")))
  verifier("base atteinte", (contient(etat.sorties, "point de retour 2/2 atteint"))
    or (contient(etat.sorties, "base atteinte")))
  verifier("rearmement manuel exige",
    (contient(etat.sorties, "REARMEMENT MANUEL REQUIS")))
  verifier("passage a l'etat REARMEMENT", (contient(etat.sorties, "-> REARMEMENT")))

  local marqueur = io.open(BANC .. "/intercepteur/.rearmement_requis", "r")
  verifier("marqueur .rearmement_requis depose a bord", marqueur ~= nil)
  if marqueur then marqueur:close() end
end

--------------------------------------------------------------------------------
print("\n== TEST 6 : scramble refuse tant que le rearmement n'est pas fait ==")
do
  local craftos, env, etat, monde = monter(configuration())
  -- Le marqueur existe deja au demarrage (navire rentre a sec).
  local f = io.open(BANC .. "/intercepteur/.rearmement_requis", "w")
  f:write("2026-09-07 12:00:00\n")
  f:close()

  craftos.injecterRednet(9, {
    protocole = "FRENCHNET_ORDRE", type = "SCRAMBLE",
    identifiantOrdre = "ORD-040", cible = { x = 0, y = 150, z = 0 },
  }, "frenchnet_ordre")

  local motif = craftos.executer(BANC .. "/intercepteur/intercepteur.lua", 60)
  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("navire indisponible au demarrage",
    (contient(etat.sorties, "marqueur de rearmement present au demarrage")))
  verifier("ordre de scramble REFUSE",
    (contient(etat.sorties, "ordre de scramble ORD-040 REFUSE")))
  verifier("le navire reste au sol", monde.tirs == 0)
end

--------------------------------------------------------------------------------
print("\n== TEST 7 : independance du sol - ordres et champs non conformes ==")
do
  local craftos, env, etat, monde = monter(configuration())

  -- Un ordre porteur de doctrine sol : les champs doivent etre retires.
  craftos.injecterRednet(9, {
    protocole = "FRENCHNET_ORDRE", type = "SCRAMBLE", identifiantOrdre = "ORD-050",
    cible = { x = 0, y = 150, z = 0 },
    zone = "ZONE-NORD-3", classe = "CHARLIE", niveauAlerte = 2, doctrine = "ROMEO",
  }, "frenchnet_ordre")

  -- Un type d'ordre inconnu : rejete.
  craftos.injecterRednet(9, {
    protocole = "FRENCHNET_ORDRE", type = "PATROUILLE", identifiantOrdre = "ORD-051",
    cible = { x = 0, y = 150, z = 0 },
  }, "frenchnet_ordre")

  -- Un ordre destine a un autre navire : ignore.
  craftos.injecterRednet(9, {
    protocole = "FRENCHNET_ORDRE", type = "SCRAMBLE", identifiantOrdre = "ORD-052",
    destinataire = "INT-07", cible = { x = 500, y = 150, z = 500 },
  }, "frenchnet_ordre")

  -- Un SCRAMBLE sans position de cible : rejete.
  craftos.injecterRednet(9, {
    protocole = "FRENCHNET_ORDRE", type = "SCRAMBLE", identifiantOrdre = "ORD-053",
  }, "frenchnet_ordre")

  local motif = craftos.executer(BANC .. "/intercepteur/intercepteur.lua", 60)
  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("champs de doctrine sol ignores et signales",
    (contient(etat.sorties, "champ(s) de doctrine sol ignore(s)")))
  verifier("les quatre champs sont nommes",
    (contient(etat.sorties, "zone")) and (contient(etat.sorties, "classe")))
  verifier("l'ordre reste execute malgre les champs parasites",
    (contient(etat.sorties, "ORDRE DE SCRAMBLE ORD-050")))
  verifier("type d'ordre inconnu rejete",
    (contient(etat.sorties, "type d'ordre 'PATROUILLE' non reconnu")))
  verifier("seuls SCRAMBLE et FEU sont acceptes",
    (contient(etat.sorties, "seuls SCRAMBLE et FEU sont acceptes")))
  verifier("ordre destine a un autre navire ignore",
    (contient(etat.sorties, "ordre destine a 'INT-07'")))
  verifier("SCRAMBLE sans position de cible rejete",
    (contient(etat.sorties, "sans position de cible exploitable")))
end

--------------------------------------------------------------------------------
print("\n== TEST 8 : ordre de feu sans poursuite en cours ==")
do
  local craftos, env, etat, monde = monter(configuration())
  craftos.injecterRednet(9, {
    protocole = "FRENCHNET_ORDRE", type = "FEU", identifiantOrdre = "ORD-060",
  }, "frenchnet_ordre")

  local motif = craftos.executer(BANC .. "/intercepteur/intercepteur.lua", 40)
  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("ordre de feu refuse hors engagement",
    (contient(etat.sorties, "ordre de feu ORD-060 REFUSE")))
  verifier("motif explicite",
    (contient(etat.sorties, "Un ordre de scramble doit preceder l'ordre de tir")))
  verifier("aucun tir", monde.tirs == 0, monde.tirs)
end

--------------------------------------------------------------------------------
print("\n== TEST 9 : autopilote introuvable -> le navire refuse de decoller ==")
do
  local craftos, env, etat, monde = monter(configuration(), { sansAutopilote = true })
  local motif = craftos.executer(BANC .. "/intercepteur/intercepteur.lua", 60)

  verifier("aucun plantage du superviseur", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("refus explicite de decoller",
    (contient(etat.sorties, "Le navire ne decolle pas")))
  verifier("erreur localisee a l'etape de liaison autopilote",
    (contient(etat.sorties, "[etape: liaison avec le module d'autopilote]")))
  verifier("emplacements explores listes",
    (contient(etat.sorties, "Emplacements explores")))
  verifier("redemarrage automatique malgre tout",
    (contient(etat.sorties, "redemarrage automatique")))
end

--------------------------------------------------------------------------------
print("\n== TEST 10 : perte de contact prolongee -> abandon et retour base ==")
do
  local craftos, env, etat, monde = monter(configuration())
  monde.cible = cibleRectiligne({ x = 0, y = 150, z = 0 }, { x = 0, y = 0, z = 55 },
    { disparaitA = 30 })

  craftos.injecterRednet(9, {
    protocole = "FRENCHNET_ORDRE", type = "SCRAMBLE",
    identifiantOrdre = "ORD-070", cible = { x = 0, y = 150, z = 0 },
  }, "frenchnet_ordre")

  local motif = craftos.executer(BANC .. "/intercepteur/intercepteur.lua", 200)
  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("perte de contact signalee",
    (contient(etat.sorties, "contact radar perdu depuis")))
  verifier("poursuite a l'estime avant abandon",
    (contient(etat.sorties, "poursuite a l'estime")))
  verifier("abandon apres le delai de recherche",
    (contient(etat.sorties, "cible non reacquise apres")))
  verifier("PAS de destruction confirmee sans degat prealable",
    not (contient(etat.sorties, "DESTRUCTION DE LA CIBLE CONFIRMEE")))
  verifier("retour base engage sur cible perdue",
    (contient(etat.sorties, "cible perdue, aucune reacquisition")))
end

--------------------------------------------------------------------------------
print("\n== TEST 11 : journal - toutes les etapes critiques sont tracees ==")
do
  local craftos, env, etat, monde = monter(configuration())
  monde.cible = cibleRectiligne({ x = 0, y = 150, z = 0 }, { x = 0, y = 0, z = 55 },
    { chuteA = 80, disparaitA = 86 })

  craftos.injecterRednet(9, {
    protocole = "FRENCHNET_ORDRE", type = "SCRAMBLE",
    identifiantOrdre = "ORD-080", cible = { x = 0, y = 150, z = 0 },
  }, "frenchnet_ordre")
  craftos.injecterRednet(9, {
    protocole = "FRENCHNET_ORDRE", type = "FEU", identifiantOrdre = "ORD-081",
  }, "frenchnet_ordre")

  env.__BANC_PERTURBATION = function(ap, t, dt)
    if t >= 55 and t < 56.5 then ap.position.y = ap.position.y - 30 * dt end
  end

  craftos.executer(BANC .. "/intercepteur/intercepteur.lua", 280)

  -- Les etapes explicitement exigees, une par une.
  local ETAPES_EXIGEES = {
    "[etape: reception d'un ordre du sol]",
    "[etape: calcul de trajectoire d'interception]",
    "[etape: entree en position d'attaque]",
    "[etape: tir sur la cible]",
    "[etape: detection de degat]",
    "[etape: manoeuvre d'evasion]",
    "[etape: retour a la base]",
  }
  for _, etape in ipairs(ETAPES_EXIGEES) do
    verifier("journal : " .. etape, (contient(etat.sorties, etape)))
  end

  local log = io.open(BANC .. "/intercepteur/intercepteur.log", "r")
  local contenu = log and log:read("a") or ""
  if log then log:close() end
  verifier("journal ecrit sur disque", #contenu > 2000, #contenu .. " octets")
  verifier("journal horodate et etiquete par etape",
    contenu:find("[etape: ", 1, true) ~= nil)
  verifier("battement de coeur periodique",
    (contient(etat.sorties, "[etape: surveillance embarquee]")))
end

--------------------------------------------------------------------------------
print("\n== TEST 12 : aucune connaissance de zone ni de classe dans le code ==")
do
  -- Verification structurelle : le CODE embarque (commentaires exclus - ils
  -- mentionnent les classes precisement pour dire qu'elles sont ignorees) ne
  -- doit contenir aucune reference aux zones ni aux classes. Seul liaison.lua
  -- les connait, et uniquement pour les rejeter.
  -- On retire les commentaires ET les chaines litterales : les uns expliquent
  -- que le navire ignore ces notions, les autres les citent dans des messages
  -- de journal qui affirment la meme chose. Ce qui reste est le code executable,
  -- ou une zone ou une classe ne peut apparaitre que si elle est LUE comme
  -- donnee (cle de table, identifiant, comparaison) - ce qui est l'anomalie
  -- que ce controle cherche.
  local function codeSeul(source)
    source = source:gsub("%-%-%[%[.-%]%]", " ")  -- commentaires longs
    source = source:gsub("%-%-[^\n]*", " ")      -- commentaires de ligne
    source = source:gsub('"[^"\n]*"', ' ')       -- chaines a guillemets doubles
    source = source:gsub("'[^'\n]*'", " ")       -- chaines a guillemets simples
    return source:lower()
  end

  local fichiers = { "noyau", "interception", "autopilote", "radar", "armement",
    "intercepteur" }
  local coupables = {}
  for _, nom in ipairs(fichiers) do
    local f = io.open(RACINE .. "/intercepteur/" .. nom .. ".lua", "r")
    local code = codeSeul(f:read("a"))
    f:close()
    for _, mot in ipairs({ "charlie", "bravo", "alpha", "romeo", "zone", "classe" }) do
      if code:find("%f[%a]" .. mot .. "%f[%A]") then
        coupables[#coupables + 1] = nom .. ".lua contient '" .. mot .. "'"
      end
    end
  end
  verifier("aucune zone ni classe n'est lue comme donnee par le code embarque",
    #coupables == 0, table.concat(coupables, ", "))

  local f = io.open(RACINE .. "/intercepteur/liaison.lua", "r")
  local liaison = f:read("a")
  f:close()
  verifier("liaison.lua ne les connait que pour les REJETER",
    liaison:find("CHAMPS_INTERDITS", 1, true) ~= nil)
  verifier("seuls deux types d'ordre sont declares",
    liaison:find("TYPES_ACCEPTES = { SCRAMBLE = true, FEU = true }", 1, true) ~= nil)
end

--------------------------------------------------------------------------------
print(string.format("\n===== %d/%d verifications reussies =====", total - echecs, total))
os.exit(echecs == 0 and 0 or 1)
