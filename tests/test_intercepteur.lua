-- Banc d'essai du systeme embarque intercepteur, hors du jeu, sur Lua 5.4.
--   Usage : lua5.4 tests/test_intercepteur.lua   (depuis la racine du depot)
--
-- Ce banc n'utilise PAS de faux autopilote : il fait tourner le VRAI module
-- autopilote/autopilote.lua sur le simulateur de vol tests/banc_vol.lua. La
-- boucle est donc fermee de bout en bout :
--
--   ordre du sol -> liaison -> radar -> maths d'interception -> adaptateur
--   -> module d'autopilote (cascade, PID, repli zone morte) -> sorties moteur
--   -> modele physique du vehicule -> GPS bruite -> retour au module.
--
-- C'est le seul moyen de verifier que le navire rejoint reellement son arc
-- arriere, et pas seulement que le calcul est juste sur le papier.

local RACINE = (arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."
local SCR    = RACINE .. "/tests"
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

--------------------------------------------------------------------------------
-- CONFIGURATIONS DU BANC
--------------------------------------------------------------------------------

-- Le banc utilise la VRAIE configuration vehicule du depot
-- (autopilote/config_vehicule.lua). Elle decrit un cargo lent : les reglages
-- de scramble sont appliques PAR-DESSUS, via le bloc 'autopilote' de la
-- configuration du navire. C'est exactement le mecanisme documente - un seul
-- fichier de reglage par vehicule, surcharge ponctuelle par la mission - et le
-- banc le verifie donc au passage.

local function configNavire(supplement)
  return ([[
return {
  identifiant = "INT-01",
  designation = "Banc d'essai",
  protocoleRednet = "frenchnet_ordre",
  cheminAutopilote = "/autopilote/autopilote.lua",
  cheminConfigVehicule = "/autopilote/config_vehicule.lua",
  accuserReception = true,
  posteDeCommandement = 9,

  periodeControle = 0.25,
  periodeRadar = 0.5,
  battementSecondes = 30,
  delaiRechercheSecondes = 20,

  journalFichier = true,
  journalNiveauEcran = "DEBUG",
  periodeJournalInterception = 2,

  autopilote = {
    -- Reglages propres a l'adaptateur (debit des consignes).
    adaptateur = {
      seuilDeplacementConsigne = 8,
      seuilVitesseConsigne = 5,
      periodeRafraichissementConsigne = 2,
    },
    -- Surcouche de mission par-dessus config_vehicule.lua. On NE TOUCHE PAS
    -- aux vitesses ni aux gains : ils sont accordes au vehicule livre, et un
    -- banc qui les rehausse sans reaccorder les gains ne mesure plus rien
    -- d'autre que sa propre desadaptation. Seuls la cadence GPS et le journal
    -- sont ajustes pour le banc.
    gps = { intervalle = 0.25, lecturesAcquisition = 2, delai = 2 },
    journal = { fichier = false, niveauEcran = "AVERT" },
  },

  interception = {
    arcMiniDeg = 120, arcMaxiDeg = 240, arcCentreDeg = 180, margeArcDeg = 10,
    manoeuvre = "orbite", arcAmplitudeDeg = 45, arcPeriodeSecondes = 12,
    distanceMini = 200, distanceMaxi = 300, distanceAmplitude = 25,
    distanceSecurite = 100, distanceTransit = 150,
    toleranceAltitude = 60,
    predictionMiniSecondes = 1, predictionMaxiSecondes = 10,
    vitesseMaxi = 8, vitesseReference = 8,
    PRIORITE
  },

  degats = {
    fenetreSecondes = 3, dureeMiniSecondes = 0.5,
    chuteAltitudeBlocs = 25, perteVitesseRatio = 0.40, perteVitesseMini = 15,
    perteContactSecondes = 5, altitudeSolConfirmee = 5,
    vitesseEpaveMaxi = 3, dureeEpaveSecondes = 4, refractaireSecondes = 8,
  },

  arme = {
    toleranceViseeDeg = 3,
    besoinParDefaut = "anti-aerien",
    margeAltitudeSol = 12,
    ARMES
  },

  radar = {
    rayonAppariement = 400, lissageVitesse = 0.5, dtMiniVitesse = 0.15,
    delaiValiditePiste = 3, periodeJournalPistage = 5,
  },

  evasion = {
    dureeSecondes = 6, angleBreakDeg = 55, distanceEvasion = 300,
    altitudePlancher = 80, altitudePlafond = 300, altitudeSolPresumee = 64,
  },

  retour = {
    pointsRetour = {
      { x = 300, y = 200, z = 300, nom = "point de degagement" },
      { x = 100, y = 160, z = 100, nom = "base" },
    },
    rayonPointRetour = 40, vitesseRetour = 60, altitudeCroisiere = 200,
  },

  %s
}
]]):format(supplement or "")
end

--- Assemble une configuration de navire.
--- Le remplacement passe par une FONCTION : une chaine de remplacement verrait
--- ses '%' interpretes, et un gsub imbrique glisserait son compteur dans
--- l'argument 'n' de gsub, qui limiterait le nombre de substitutions a zero.
local function configuration(priorite, armes)
  local texte = configNavire()
  texte = (texte:gsub("PRIORITE", function() return priorite or "" end))
  texte = (texte:gsub("ARMES", function() return armes or "" end))
  return texte
end

local ARSENAL_NOMINAL = [[armes = {
      { identifiant = "CANON-AA-1", nom = "Canon 4 pouces", utilite = "anti-aerien",
        mode = "peripherique", porteeMini = 60, porteeMaxi = 320,
        vitesseObus = 80, graviteObus = 9.8, dureeRafale = 1.5, pauseRafale = 2.0,
        actif = true },
      { identifiant = "MITRA-DEF", nom = "Mitrailleuse", utilite = "defensif",
        mode = "redstone", coteRedstone = "back", porteeMini = 10, porteeMaxi = 90,
        vitesseObus = 120, graviteObus = 4.0, actif = true },
    },]]

local function ARSENAL_STANDARD() return configuration("", ARSENAL_NOMINAL) end

--------------------------------------------------------------------------------
-- MONTAGE DU BANC
--------------------------------------------------------------------------------

local function preparer(config, options)
  options = options or {}
  os.execute("rm -rf " .. BANC .. " && mkdir -p " .. BANC .. "/intercepteur "
    .. BANC .. "/autopilote")
  os.execute("cp " .. RACINE .. "/intercepteur/*.lua " .. BANC .. "/intercepteur/")
  os.execute("rm -f " .. BANC .. "/intercepteur/config_intercepteur.lua")

  if not options.sansAutopilote then
    os.execute("cp " .. RACINE .. "/autopilote/autopilote.lua " .. BANC .. "/autopilote/")
  end

  os.execute("cp " .. RACINE .. "/autopilote/config_vehicule.lua "
    .. BANC .. "/autopilote/")

  -- La station de ravitaillement est une constante de reseau exigee par le
  -- module d'autopilote : elle doit exister meme sur un banc.
  f = io.open(BANC .. "/autopilote/ravitaillement.lua", "w")
  f:write([[return { nom = "BASE", position = { x = 100, y = 160, z = 100 } }]])
  f:close()

  f = io.open(BANC .. "/intercepteur/config_intercepteur.lua", "w")
  f:write(config)
  f:close()
end

--- Peripheriques du navire : modem (ordres), radar (pistage), affut (tir).
local function equiper(env, monde)
  local horloge = env.os.clock

  local modem = {
    isWireless = function() return true end,
    open = function(c) monde.canaux[c] = true end,
    isOpen = function(c) return monde.canaux[c] == true end,
    close = function() end,
    transmit = function() end,
  }

  local radar = {
    getEntities = function()
      monde.balayages = monde.balayages + 1
      local contacts = {}
      local cible = monde.cible(horloge())
      if cible then
        contacts[#contacts + 1] = { id = "cible-01",
          type = "createaeronautics:aircraft", x = cible.x, y = cible.y, z = cible.z }
      end
      contacts[#contacts + 1] = { id = "leurre", type = "minecraft:cow",
        x = -9000, y = 70, z = 9000 }
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

  local TYPES = { back = "modem", radar_0 = "create_radars:radar",
    cannon_0 = "createbigcannons:cannon_mount" }
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

  env.shell = { getRunningProgram = function() return "intercepteur/intercepteur.lua" end }
end

--- Trajectoire de cible en ligne droite, avec chute et disparition optionnelles.
local function cibleRectiligne(depart, vitesse, options)
  options = options or {}
  return function(t)
    if options.disparaitA and t >= options.disparaitA then return nil end
    local p = { x = depart.x + vitesse.x * t, y = depart.y + vitesse.y * t,
                z = depart.z + vitesse.z * t }
    if options.chuteA and t >= options.chuteA then
      p.y = p.y - math.min((t - options.chuteA) * 40, 200)
    end
    return p
  end
end

local function monter(config, options)
  options = options or {}
  preparer(config, options)
  local banc = dofile(SCR .. "/banc_scramble.lua")
  local env, etat = banc.creer(SCR .. "/banc_vol.lua", {
    racine  = BANC,
    budget  = options.budget or 1200,
    bruitGps = 0.1,
    -- Vehicule conforme au reglage livre : c'est le seul moyen de mesurer la
    -- geometrie d'interception et non un desaccord de gains.
    vehicule = options.vehicule
      or { x = 0, y = 200, z = -800, cap = 180, vMax = 10, vVerticalMax = 5,
           tauxMax = 50, vLateralMax = 0 },
  })

  local monde = {
    balayages = 0, tirs = 0, canaux = {}, envois = {}, rednetOuvert = false,
    cible = options.cible
      or cibleRectiligne({ x = 0, y = 200, z = 0 }, { x = 0, y = 0, z = 3 }),
  }
  equiper(env, monde)

  -- Sorties moteur simulees : le VRAI module d'autopilote pilote le modele
  -- physique du banc au lieu de peripheriques inexistants.
  env.__FRENCHNET_BANC = { commandes = banc.bancVol.pilote() }

  return banc, env, etat, monde
end

local function injecterOrdre(env, message)
  env.os.queueEvent("rednet_message", 9, message, "frenchnet_ordre")
end

local function executer(banc, secondes)
  return banc.executer(BANC .. "/intercepteur/intercepteur.lua", secondes)
end

--------------------------------------------------------------------------------
print("\n== TEST 1 : mission complete avec le VRAI module d'autopilote ==")
do
  local banc, env, etat, monde = monter(ARSENAL_STANDARD())
  injecterOrdre(env, { protocole = "FRENCHNET_ORDRE", type = "SCRAMBLE",
    identifiantOrdre = "ORD-001", destinataire = "INT-01",
    cible = { x = 0, y = 200, z = 0 } })

  local motif = executer(banc, 900)
  local sorties = etat.sorties

  verifier("le programme tourne sans se terminer", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("VRAI module d'autopilote charge",
    (contient(sorties, "module d'autopilote standardise v")))
  verifier("configuration vehicule partagee lue",
    (contient(sorties, "configuration vehicule lue dans /autopilote/config_vehicule.lua")))
  verifier("cascade / PID / zone morte annonces",
    (contient(sorties, "asservissement en cascade, PID principal, repli zone morte")))
  verifier("debit des consignes limite",
    (contient(sorties, "consignes limitees en debit")))
  verifier("journal PARTAGE avec l'autopilote (lignes d'autopilote presentes)",
    (contient(sorties, "boucle de vol demarree")))
  verifier("arsenal operationnel",
    (contient(sorties, "arsenal operationnel")))
  verifier("deux armes declarees",
    (contient(sorties, "CANON-AA-1")) and (contient(sorties, "MITRA-DEF")))
  verifier("ordre de scramble recu",
    (contient(sorties, "ORDRE DE SCRAMBLE ORD-001")))
  verifier("le radar a balaye", monde.balayages > 50, monde.balayages)
  verifier("calcul de trajectoire d'interception",
    (contient(sorties, "[etape: calcul de trajectoire d'interception]")))

  -- Le vehicule simule s'est-il reellement deplace vers la cible ?
  local v = etat.vehicule
  local cible = monde.cible(etat.horloge)
  local distance = math.sqrt((v.x - cible.x) ^ 2 + (v.z - cible.z) ^ 2)
  verifier("le vehicule a reellement vole", v.distanceParcourue > 200,
    string.format("%.0f blocs parcourus", v.distanceParcourue))
  -- Ecart initial : 800 blocs. La cible fuit a 3 b/s, le navire croise a 8 b/s.
  verifier("le navire s'est rapproche de la cible", distance < 700,
    string.format("%.0f blocs (ecart initial 800)", distance))
end

--------------------------------------------------------------------------------
print("\n== TEST 2 : l'ordre de tir PRIME SUR LA POSITION ==")
do
  local banc, env, etat, monde = monter(configuration(
    "prioriteTirSurPosition = true, biaisArcEnTirDeg = 25,", ARSENAL_NOMINAL))
  injecterOrdre(env, { protocole = "FRENCHNET_ORDRE", type = "SCRAMBLE",
    identifiantOrdre = "ORD-010", cible = { x = 0, y = 200, z = 0 } })
  injecterOrdre(env, { protocole = "FRENCHNET_ORDRE", type = "FEU",
    identifiantOrdre = "ORD-011" })

  local motif = executer(banc, 900)
  local sorties = etat.sorties

  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("regle d'engagement annoncee au demarrage",
    (contient(sorties, "regle d'engagement : LE TIR PRIME SUR LA POSITION")))
  verifier("ordre de feu recu", (contient(sorties, "ORDRE DE FEU ORD-011")))
  verifier("la priorite est explicitement journalisee",
    (contient(sorties, "LE TIR PRIME SUR LA POSITION : le navire engage des qu'il a une")))
  verifier("passage a l'engagement SANS attendre l'arc",
    (contient(sorties, "ordre de feu prioritaire")))
  verifier("une arme est retenue selon la portee",
    (contient(sorties, "arme retenue :")))
end

--------------------------------------------------------------------------------
print("\n== TEST 3 : priorite desactivee - l'arc redevient un prealable ==")
do
  local banc, env, etat, monde = monter(configuration(
    "prioriteTirSurPosition = false,", ARSENAL_NOMINAL))
  injecterOrdre(env, { protocole = "FRENCHNET_ORDRE", type = "SCRAMBLE",
    identifiantOrdre = "ORD-020", cible = { x = 0, y = 200, z = 0 } })
  injecterOrdre(env, { protocole = "FRENCHNET_ORDRE", type = "FEU",
    identifiantOrdre = "ORD-021" })

  local motif = executer(banc, 600)
  local sorties = etat.sorties

  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("regle inverse annoncee",
    (contient(sorties, "regle d'engagement : la position prime sur le tir")))
  verifier("l'ordre de feu n'ouvre PAS l'engagement immediatement",
    not (contient(sorties, "ordre de feu prioritaire")))
  verifier("le feu reste subordonne a l'arc",
    (contient(sorties, "l'engagement se fera sans quitter l'arc arriere")))
end

--------------------------------------------------------------------------------
print("\n== TEST 4 : arsenal - aucune arme declaree ==")
do
  local banc, env, etat, monde = monter(configuration("", "armes = {},"))
  local motif = executer(banc, 120)
  verifier("aucun plantage du superviseur", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("configuration refusee avec un message clair",
    (contient(etat.sorties, "'arme.armes' doit contenir au moins une arme")))
  verifier("erreur localisee a la validation",
    (contient(etat.sorties, "[etape: validation de la configuration]")))
end

--------------------------------------------------------------------------------
print("\n== TEST 5 : arsenal - arme mal declaree ==")
do
  local banc, env, etat, monde = monter(configuration("", [[armes = {
      { identifiant = "MAUVAISE", utilite = "anti-navire", porteeMini = 500,
        porteeMaxi = 100, mode = "redstone" },
    },]]))
  local motif = executer(banc, 120)
  local sorties = etat.sorties
  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("utilite inconnue signalee", (contient(sorties, "utilite 'anti-navire' inconnue")))
  verifier("portees incoherentes signalees", (contient(sorties, "portees incoherentes")))
  verifier("mode redstone sans cote signale", (contient(sorties, "sans 'coteRedstone'")))
end

--------------------------------------------------------------------------------
print("\n== TEST 6 : autopilote introuvable - le navire refuse de decoller ==")
do
  local banc, env, etat, monde = monter(ARSENAL_STANDARD(), { sansAutopilote = true })
  local motif = executer(banc, 120)
  local sorties = etat.sorties
  verifier("aucun plantage du superviseur", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("refus explicite de decoller", (contient(sorties, "Le navire ne decolle pas")))
  verifier("emplacements explores listes", (contient(sorties, "Emplacements explores")))
  verifier("redemarrage automatique malgre tout",
    (contient(sorties, "redemarrage automatique")))
end

--------------------------------------------------------------------------------
print("\n== TEST 7 : independance du sol ==")
do
  local banc, env, etat, monde = monter(ARSENAL_STANDARD())
  injecterOrdre(env, { protocole = "FRENCHNET_ORDRE", type = "SCRAMBLE",
    identifiantOrdre = "ORD-050", cible = { x = 0, y = 200, z = 0 },
    zone = "ZONE-NORD-3", classe = "CHARLIE", niveauAlerte = 2, doctrine = "ROMEO" })
  injecterOrdre(env, { protocole = "FRENCHNET_ORDRE", type = "PATROUILLE",
    identifiantOrdre = "ORD-051", cible = { x = 0, y = 200, z = 0 } })
  injecterOrdre(env, { protocole = "FRENCHNET_ORDRE", type = "SCRAMBLE",
    identifiantOrdre = "ORD-052", destinataire = "INT-07",
    cible = { x = 500, y = 200, z = 500 } })

  local motif = executer(banc, 300)
  local sorties = etat.sorties

  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("champs de doctrine sol ignores et signales",
    (contient(sorties, "champ(s) de doctrine sol ignore(s)")))
  verifier("l'ordre est execute malgre les champs parasites",
    (contient(sorties, "ORDRE DE SCRAMBLE ORD-050")))
  verifier("type d'ordre inconnu rejete",
    (contient(sorties, "type d'ordre 'PATROUILLE' non reconnu")))
  verifier("ordre destine a un autre navire ignore",
    (contient(sorties, "ordre destine a 'INT-07'")))
  verifier("independance annoncee au demarrage",
    (contient(sorties, "aucune notion de zone ni de classe a bord")))
end

--------------------------------------------------------------------------------
print("\n== TEST 8 : degat subi -> evasion prioritaire ==")
do
  local banc, env, etat, monde = monter(ARSENAL_STANDARD())
  injecterOrdre(env, { protocole = "FRENCHNET_ORDRE", type = "SCRAMBLE",
    identifiantOrdre = "ORD-060", cible = { x = 0, y = 200, z = 0 } })

  -- A t = 60 s, le vehicule simule encaisse : perte brutale d'altitude.
  local horlogeInitiale = env.os.clock
  local applique = false
  env.os.clock = function()
    local t = horlogeInitiale()
    if t >= 60 and not applique then
      applique = true
      etat.vehicule.y = etat.vehicule.y - 45
    end
    return t
  end

  local motif = executer(banc, 600)
  local sorties = etat.sorties

  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("degat subi detecte", (contient(sorties, "DEGAT SUBI PAR LE NAVIRE")))
  verifier("criteres de degat partages annonces",
    (contient(sorties, "criteres identiques a ceux de la confirmation de destruction")))
  verifier("evasion prioritaire declenchee",
    (contient(sorties, "MANOEUVRE D'EVASION PRIORITAIRE")))
  verifier("evasion en break, pas en ligne droite", (contient(sorties, "break")))
end

--------------------------------------------------------------------------------
print("\n== TEST 9 : perte de contact -> abandon, PAS une destruction ==")
do
  local banc, env, etat, monde = monter(ARSENAL_STANDARD(),
    { cible = cibleRectiligne({ x = 0, y = 200, z = 0 }, { x = 0, y = 0, z = 3 },
        { disparaitA = 25 }) })
  injecterOrdre(env, { protocole = "FRENCHNET_ORDRE", type = "SCRAMBLE",
    identifiantOrdre = "ORD-070", cible = { x = 0, y = 200, z = 0 } })

  local motif = executer(banc, 900)
  local sorties = etat.sorties

  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("perte de contact signalee", (contient(sorties, "contact radar perdu depuis")))
  verifier("poursuite a l'estime", (contient(sorties, "poursuite a l'estime")))
  verifier("abandon apres le delai de recherche",
    (contient(sorties, "mission interrompue")))
  verifier("PAS de destruction confirmee sans degat prealable",
    not (contient(sorties, "DESTRUCTION DE LA CIBLE CONFIRMEE")))
  verifier("retour base engage", (contient(sorties, "RETOUR BASE engage")))
  verifier("itineraire confie a l'autopilote (mission acceptee)",
    (contient(sorties, "mission acceptee")))
end

--------------------------------------------------------------------------------
print("\n== TEST 10 : etapes critiques toutes journalisees ==")
do
  local banc, env, etat, monde = monter(ARSENAL_STANDARD())
  injecterOrdre(env, { protocole = "FRENCHNET_ORDRE", type = "SCRAMBLE",
    identifiantOrdre = "ORD-080", cible = { x = 0, y = 200, z = 0 } })
  injecterOrdre(env, { protocole = "FRENCHNET_ORDRE", type = "FEU",
    identifiantOrdre = "ORD-081" })

  executer(banc, 900)
  local sorties = etat.sorties

  for _, etape in ipairs({
    "[etape: reception d'un ordre du sol]",
    "[etape: calcul de trajectoire d'interception]",
    "[etape: liaison avec le module d'autopilote]",
    "[etape: pistage radar de la cible]",
    "[etape: detection de l'arme embarquee]",
    "[etape: surveillance embarquee]",
  }) do
    verifier("journal : " .. etape, (contient(sorties, etape)))
  end

  local log = io.open(BANC .. "/intercepteur/intercepteur.log", "r")
  local contenu = log and log:read("a") or ""
  if log then log:close() end
  verifier("journal ecrit sur disque", #contenu > 2000, #contenu .. " octets")
  verifier("journal etiquete par etape", contenu:find("[etape: ", 1, true) ~= nil)
end

--------------------------------------------------------------------------------
print("\n== TEST 11 : aucune zone ni classe lue comme donnee ==")
do
  local function codeSeul(source)
    source = source:gsub("%-%-%[%[.-%]%]", " ")
    source = source:gsub("%-%-[^\n]*", " ")
    source = source:gsub('"[^"\n]*"', ' ')
    source = source:gsub("'[^'\n]*'", " ")
    return source:lower()
  end

  local coupables = {}
  for _, nom in ipairs({ "noyau", "interception", "autopilote", "radar", "armement",
                         "intercepteur" }) do
    local f = io.open(RACINE .. "/intercepteur/" .. nom .. ".lua", "r")
    local code = codeSeul(f:read("a"))
    f:close()
    for _, mot in ipairs({ "charlie", "bravo", "alpha", "romeo", "zone", "classe" }) do
      if code:find("%f[%a]" .. mot .. "%f[%A]") then
        coupables[#coupables + 1] = nom .. ".lua contient '" .. mot .. "'"
      end
    end
  end
  verifier("aucune zone ni classe lue comme donnee par le code embarque",
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
