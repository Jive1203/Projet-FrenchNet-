-- Banc d'essai des mathematiques d'interception, sur interpreteur Lua 5.4 pur.
--   Usage : lua5.4 tests/test_interception.lua   (depuis la racine du depot)
--
-- Ce banc ne simule PAS CraftOS : interception.lua est un module pur, sans
-- peripherique ni entree-sortie. C'est precisement ce qui permet de verifier
-- la geometrie d'interception avant de la confier a un navire arme.

local RACINE = (arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."

local noyau        = assert(loadfile(RACINE .. "/intercepteur/noyau.lua"))("intercepteur")
local interception = assert(loadfile(RACINE .. "/intercepteur/interception.lua"))(noyau)
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

local function proche(a, b, tolerance)
  return math.abs(a - b) <= (tolerance or 1e-6)
end

--------------------------------------------------------------------------------
print("\n== TEST 1 : convention des relevements horaires ==")
do
  -- Reference geometrique : un appareil cap au SUD (+Z).
  local cap = noyau.relevement({ x = 0, y = 0, z = 1 })
  verifier("cap sud (+Z) = relevement 0 (12 heures)", proche(cap, 0), cap)

  local cible = V.creer(0, 100, 0)
  local derriere = V.creer(0, 100, -300)   -- au nord de la cible = derriere elle
  local tribord  = V.creer(-300, 100, 0)   -- a l'ouest = a droite d'un cap sud
  local babord   = V.creer(300, 100, 0)

  verifier("droit derriere = 180 deg (6 heures)",
    proche(noyau.relevementRelatif(cap, cible, derriere), 180, 1e-9))
  verifier("a tribord = 90 deg (3 heures)",
    proche(noyau.relevementRelatif(cap, cible, tribord), 90, 1e-9))
  verifier("a babord = 270 deg (9 heures)",
    proche(noyau.relevementRelatif(cap, cible, babord), 270, 1e-9))
  verifier("libelle horaire de 180 deg", noyau.positionHoraire(180) == "6h00",
    noyau.positionHoraire(180))
  verifier("libelle horaire de 120 deg = 4h00", noyau.positionHoraire(120) == "4h00",
    noyau.positionHoraire(120))
  verifier("libelle horaire de 240 deg = 8h00", noyau.positionHoraire(240) == "8h00",
    noyau.positionHoraire(240))

  -- 4 heures doit se trouver DERRIERE et a DROITE de la cible.
  local p4h = interception.pointArc(cible, cap, 120, 300, 0)
  verifier("4 heures est en arriere de la cible (nord d'un cap sud)", p4h.z < cible.z,
    p4h.z)
  verifier("4 heures est a tribord de la cible (ouest d'un cap sud)", p4h.x < cible.x,
    p4h.x)
  local p8h = interception.pointArc(cible, cap, 240, 300, 0)
  verifier("8 heures est en arriere de la cible", p8h.z < cible.z, p8h.z)
  verifier("8 heures est a babord de la cible", p8h.x > cible.x, p8h.x)
end

--------------------------------------------------------------------------------
print("\n== TEST 2 : temps d'interception (solution analytique) ==")
do
  local origine = V.creer(0, 0, 0)
  local immobile = V.creer(0, 0, 0)

  local t = interception.tempsInterception(origine, V.creer(0, 0, 300), immobile, 60,
    { min = 0, max = 60 })
  verifier("cible immobile a 300 blocs, 60 b/s -> 5,0 s", proche(t, 5, 1e-6), t)

  t = interception.tempsInterception(origine, V.creer(0, 0, 300), V.creer(0, 0, -30), 60,
    { min = 0, max = 60 })
  verifier("cible de face a 30 b/s -> 3,33 s (fermeture 90 b/s)", proche(t, 10/3, 1e-6), t)

  t = interception.tempsInterception(origine, V.creer(300, 0, 0), V.creer(0, 0, 50), 60,
    { min = 0, max = 60 })
  -- Verification independante : la cible et le navire doivent etre au meme point.
  local rencontre = interception.predirePosition(V.creer(300, 0, 0), V.creer(0, 0, 50), t)
  verifier("cible perpendiculaire : la solution est coherente",
    proche(V.distance(origine, rencontre), 60 * t, 1e-3),
    string.format("t=%.4f distance=%.3f parcours=%.3f", t,
      V.distance(origine, rencontre), 60 * t))

  local t2, atteignable = interception.tempsInterception(origine, V.creer(0, 0, 300),
    V.creer(0, 0, 90), 60, { min = 1, max = 10 })
  verifier("cible fuyante plus rapide -> non atteignable", atteignable == false)
  verifier("  ... et le temps est plafonne a la borne haute", proche(t2, 10), t2)

  local t3 = interception.tempsInterception(origine, V.creer(0, 0, 3000), immobile, 60,
    { min = 1, max = 8 })
  verifier("prediction bornee a 8 s meme pour une cible lointaine", proche(t3, 8), t3)
end

--------------------------------------------------------------------------------
print("\n== TEST 3 : choix du relevement dans l'arc arriere 4h-8h ==")
do
  local params = { arcMiniDeg = 120, arcMaxiDeg = 240, margeArcDeg = 10 }

  local r, dedans = interception.choisirRelevementArc(180, params)
  verifier("deja a 6h -> on garde 6h", proche(r, 180) and dedans == true, r)

  r, dedans = interception.choisirRelevementArc(130, params)
  verifier("deja a 4h20 -> on garde sa place dans l'arc", proche(r, 130) and dedans, r)

  -- Navire a 2 heures (60 deg) : la borne la plus proche est 120 (4 heures).
  r, dedans = interception.choisirRelevementArc(60, params)
  verifier("a 2h -> rejoint 4h par le flanc tribord", proche(r, 130) and not dedans, r)

  -- Navire a 10 heures (300 deg) : la borne la plus proche est 240 (8 heures).
  r = interception.choisirRelevementArc(300, params)
  verifier("a 10h -> rejoint 8h par le flanc babord", proche(r, 230), r)

  -- Nez a nez : quelle que soit la borne retenue, elle doit rester dans l'arc.
  for _, beta in ipairs({ 0, 5, 355, 90, 270, 119, 241 }) do
    local choix = interception.choisirRelevementArc(beta, params)
    verifier(string.format("depuis %d deg, le relevement vise reste dans [120,240]", beta),
      choix >= 120 and choix <= 240, choix)
  end
end

--------------------------------------------------------------------------------
print("\n== TEST 4 : controle d'appartenance a l'arc ==")
do
  local params = { arcMiniDeg = 120, arcMaxiDeg = 240, distanceMini = 300,
    distanceMaxi = 400, toleranceAltitude = 60 }
  local cible = V.creer(0, 150, 0)
  local cap = 0 -- cap au sud

  local bon = interception.pointArc(cible, cap, 180, 350, 0)
  local ok, d = interception.dansArc(bon, cible, cap, params)
  verifier("6h a 350 blocs : en position", ok, d.positionHoraire .. " " .. d.distance)

  local tropPres = interception.pointArc(cible, cap, 180, 200, 0)
  ok, d = interception.dansArc(tropPres, cible, cap, params)
  verifier("6h a 200 blocs : hors bande de distance", not ok and d.angleOk and not d.distanceOk)

  local devant = interception.pointArc(cible, cap, 0, 350, 0)
  ok, d = interception.dansArc(devant, cible, cap, params)
  verifier("12h a 350 blocs : hors arc", not ok and not d.angleOk, d.positionHoraire)

  local hautPerche = interception.pointArc(cible, cap, 180, 350, 120)
  ok, d = interception.dansArc(hautPerche, cible, cap, params)
  verifier("6h a 350 blocs mais 120 blocs plus haut : hors tolerance d'altitude",
    not ok and not d.altitudeOk, d.deltaY)
end

--------------------------------------------------------------------------------
print("\n== TEST 5 : orbite et zigzag confines dans l'arc ==")
do
  local params = {
    arcMiniDeg = 120, arcMaxiDeg = 240, margeArcDeg = 10, arcCentreDeg = 180,
    arcAmplitudeDeg = 45, arcPeriodeSecondes = 12, distanceMini = 300,
    distanceMaxi = 400, distanceAmplitude = 30, deltaYAmplitude = 15,
  }

  for _, mode in ipairs({ "orbite", "zigzag" }) do
    params.manoeuvre = mode
    local minRel, maxRel = math.huge, -math.huge
    local minDist, maxDist = math.huge, -math.huge
    local bouge = false
    local premier
    for i = 0, 4000 do
      local t = i * 0.05
      local rel, dist = interception.oscillationArc(t, params, 0)
      minRel, maxRel = math.min(minRel, rel), math.max(maxRel, rel)
      minDist, maxDist = math.min(minDist, dist), math.max(maxDist, dist)
      premier = premier or rel
      if math.abs(rel - premier) > 5 then bouge = true end
    end
    verifier(mode .. " : relevement confine dans [120,240]",
      minRel >= 120 - 1e-9 and maxRel <= 240 + 1e-9,
      string.format("[%.2f, %.2f]", minRel, maxRel))
    verifier(mode .. " : distance confinee dans [300,400]",
      minDist >= 300 - 1e-9 and maxDist <= 400 + 1e-9,
      string.format("[%.2f, %.2f]", minDist, maxDist))
    verifier(mode .. " : le navire n'est pas statique", bouge,
      string.format("amplitude observee %.1f deg", maxRel - minRel))
  end

  -- Calage de phase : la manoeuvre demarre au relevement d'entree, sans a-coup.
  params.manoeuvre = "orbite"
  local phase = interception.calerPhase(150, 180, 45)
  local rel0 = interception.oscillationArc(0, params, phase)
  verifier("calage de phase : demarrage sans saut de relevement",
    proche(rel0, 150, 1e-6), rel0)
end

--------------------------------------------------------------------------------
print("\n== TEST 6 : asservissement de vitesse ==")
do
  local params = {
    vitesseMaxi = 120, vitesseMini = 0, distanceSecurite = 150,
    distanceTransit = 250, gainRapprochement = 0.35, ratioMini = 0.6,
    ratioMaxi = 1.6, vitesseMiniPourCap = 2,
  }

  local v, regime = interception.vitesseCommandee(1200, 350, 60, params)
  verifier("tres loin -> regime transit a vitesse maximale",
    regime == "transit" and proche(v, 120), regime .. " " .. v)

  v, regime = interception.vitesseCommandee(100, 350, 60, params)
  verifier("trop pres -> regime securite, vitesse SOUS celle de la cible",
    regime == "securite" and v < 60, regime .. " " .. v)

  v, regime = interception.vitesseCommandee(350, 350, 60, params)
  verifier("pile en place -> vitesse egale a celle de la cible",
    regime == "asservi" and proche(v, 60), regime .. " " .. v)

  v = interception.vitesseCommandee(390, 350, 60, params)
  verifier("legerement en retard -> on accelere un peu", v > 60 and v <= 60 * 1.6, v)

  v = interception.vitesseCommandee(310, 350, 60, params)
  verifier("legerement en avance -> on ralentit un peu", v < 60 and v >= 60 * 0.6, v)

  v = interception.vitesseCommandee(560, 350, 60, params)
  verifier("erreur importante -> plafonnee a 1,6x la vitesse cible",
    proche(v, 96), v)
end

--------------------------------------------------------------------------------
print("\n== TEST 7 : consigne complete, prediction contre poursuite ==")
do
  local params = {
    arcMiniDeg = 120, arcMaxiDeg = 240, margeArcDeg = 10, arcCentreDeg = 180,
    arcAmplitudeDeg = 45, arcPeriodeSecondes = 12, distanceMini = 300,
    distanceMaxi = 400, distanceSecurite = 150, distanceTransit = 250,
    predictionMiniSecondes = 1, predictionMaxiSecondes = 10,
    vitesseMaxi = 120, vitesseReference = 90, gainRapprochement = 0.35,
    ratioMini = 0.6, ratioMaxi = 1.6, deltaYNominal = 0,
  }

  local vCible = V.creer(0, 0, 70)                -- cible au cap sud, 70 b/s
  local pCible = V.creer(0, 150, 0)
  local pSoi   = V.creer(0, 150, -900)            -- navire loin derriere
  local cap    = noyau.relevement(vCible)

  local consigne = interception.calculerConsigne({
    pSoi = pSoi, vSoi = V.creer(0, 0, 90), pCible = pCible, vCible = vCible,
    capCible = cap, t = 0, phase = 0, enPosition = false,
  }, params)

  verifier("temps d'interception non nul", consigne.tempsInterception > 0.5,
    consigne.tempsInterception)
  verifier("le point predit est en AVANT de la cible actuelle",
    consigne.pCiblePredite.z > pCible.z + 100,
    string.format("predit Z=%.1f, actuel Z=%.1f", consigne.pCiblePredite.z, pCible.z))

  -- Le point de consigne doit etre l'arc arriere de la position PREDITE, pas
  -- de la position actuelle : c'est toute la difference entre intercepter et
  -- trainer derriere.
  local arcPredit = interception.pointArc(consigne.pCiblePredite, cap,
    consigne.relevementVise, consigne.distanceVisee, 0)
  local arcActuel = interception.pointArc(pCible, cap,
    consigne.relevementVise, consigne.distanceVisee, 0)
  verifier("consigne calee sur l'arc de la position predite",
    V.distance(consigne.point, arcPredit) < 1e-6,
    V.distance(consigne.point, arcPredit))
  verifier("consigne distincte de l'arc de la position actuelle",
    V.distance(consigne.point, arcActuel) > 100,
    V.distance(consigne.point, arcActuel))
  verifier("regime transit pendant la rejointe", consigne.regimeVitesse == "transit",
    consigne.regimeVitesse)

  -- Approche par l'avant : le navire ne doit jamais viser le nez de la cible.
  local devant = V.creer(0, 150, 900)
  local consigneDevant = interception.calculerConsigne({
    pSoi = devant, vSoi = V.creer(0, 0, 90), pCible = pCible, vCible = vCible,
    capCible = cap, t = 0, phase = 0, enPosition = false,
  }, params)
  verifier("navire de face : relevement vise ramene dans l'arc arriere",
    consigneDevant.relevementVise >= 120 and consigneDevant.relevementVise <= 240,
    consigneDevant.relevementVise)
  local relConsigne = noyau.relevementRelatif(cap, consigneDevant.pCiblePredite,
    consigneDevant.point)
  verifier("navire de face : le point de consigne est bien dans l'arc arriere",
    relConsigne >= 119.9 and relConsigne <= 240.1, relConsigne)

  -- En position : la manoeuvre s'active et le point bouge dans le temps.
  local a = interception.calculerConsigne({
    pSoi = interception.pointArc(pCible, cap, 180, 350, 0), vSoi = vCible,
    pCible = pCible, vCible = vCible, capCible = cap, t = 0, phase = 0,
    enPosition = true }, params)
  local b = interception.calculerConsigne({
    pSoi = interception.pointArc(pCible, cap, 180, 350, 0), vSoi = vCible,
    pCible = pCible, vCible = vCible, capCible = cap, t = 3, phase = 0,
    enPosition = true }, params)
  verifier("en position : manoeuvre active", a.manoeuvreActive and b.manoeuvreActive)
  verifier("en position : le point de consigne se deplace (orbite)",
    V.distance(a.point, b.point) > 20, V.distance(a.point, b.point))
end

--------------------------------------------------------------------------------
print("\n== TEST 8 : criteres de degat, utilises pour le navire ET pour la cible ==")
do
  local criteres = {
    fenetreSecondes = 3, dureeMiniSecondes = 0.5, chuteAltitudeBlocs = 25,
    perteVitesseRatio = 0.40, perteVitesseMini = 15,
  }

  -- Vol nominal : aucune alarme.
  local h = {}
  for i = 0, 12 do
    interception.ajouterEchantillon(h, i * 0.25, 150 + math.sin(i) * 2, 80, 3)
  end
  verifier("vol stable : aucun degat detecte", interception.evaluerDegats(h, criteres).degat == false)

  -- Chute d'altitude brutale.
  local hChute = {}
  interception.ajouterEchantillon(hChute, 0.0, 150, 80, 3)
  interception.ajouterEchantillon(hChute, 1.0, 145, 80, 3)
  interception.ajouterEchantillon(hChute, 2.0, 118, 80, 3)
  local rChute = interception.evaluerDegats(hChute, criteres)
  verifier("chute de 32 blocs en 2 s : degat detecte", rChute.degat, rChute.motif)
  verifier("  ... motif mentionnant la chute",
    rChute.motif and rChute.motif:find("chute", 1, true) ~= nil, rChute.motif)

  -- Perte de vitesse brutale.
  local hVitesse = {}
  interception.ajouterEchantillon(hVitesse, 0.0, 150, 90, 3)
  interception.ajouterEchantillon(hVitesse, 1.0, 150, 88, 3)
  interception.ajouterEchantillon(hVitesse, 2.0, 150, 40, 3)
  local rVitesse = interception.evaluerDegats(hVitesse, criteres)
  verifier("perte de 55 % de vitesse : degat detecte", rVitesse.degat, rVitesse.motif)

  -- Perte de vitesse relative importante mais absolue faible : pas un degat.
  local hLent = {}
  interception.ajouterEchantillon(hLent, 0.0, 150, 10, 3)
  interception.ajouterEchantillon(hLent, 1.0, 150, 4, 3)
  verifier("ralentissement d'un mobile deja lent : pas de fausse alarme",
    interception.evaluerDegats(hLent, criteres).degat == false)

  -- Fenetre trop courte : on refuse de conclure.
  local hCourt = {}
  interception.ajouterEchantillon(hCourt, 0.0, 150, 80, 3)
  interception.ajouterEchantillon(hCourt, 0.1, 100, 80, 3)
  verifier("fenetre trop courte : aucune conclusion hative",
    interception.evaluerDegats(hCourt, criteres).degat == false)

  -- Purge de la fenetre glissante.
  local hPurge = {}
  for i = 0, 40 do interception.ajouterEchantillon(hPurge, i * 0.25, 150, 80, 3) end
  verifier("historique borne par la fenetre glissante", #hPurge <= 14, #hPurge)
end

--------------------------------------------------------------------------------
print("\n== TEST 9 : confirmation de destruction ==")
do
  local criteres = {
    fenetreSecondes = 3, dureeMiniSecondes = 0.5, chuteAltitudeBlocs = 25,
    perteVitesseRatio = 0.40, perteVitesseMini = 15, perteContactSecondes = 5,
    altitudeSolConfirmee = 5, vitesseEpaveMaxi = 3, dureeEpaveSecondes = 4,
  }

  local etat = { historique = {}, degatDetecteA = nil, dernierContact = 100,
    position = V.creer(0, 150, 0), vitesse = V.creer(0, 0, 80) }
  interception.ajouterEchantillon(etat.historique, 98, 150, 80, 3)
  interception.ajouterEchantillon(etat.historique, 100, 150, 80, 3)

  local ok = interception.confirmerDestruction(etat, criteres, 100)
  verifier("cible saine : pas de destruction", ok == false)

  -- Contact perdu SANS degat prealable : ce n'est pas une destruction, c'est
  -- une perte de piste. Distinction essentielle.
  etat.dernierContact = 90
  ok = interception.confirmerDestruction(etat, criteres, 100)
  verifier("contact perdu sans degat : PAS une destruction", ok == false)

  -- Degat avere puis silence radar.
  etat.degatDetecteA = 92
  local motif
  ok, motif = interception.confirmerDestruction(etat, criteres, 100)
  verifier("degat avere + 10 s de silence radar : destruction confirmee", ok, motif)
  verifier("  ... motif explicite",
    motif and motif:find("contact radar perdu", 1, true) ~= nil, motif)

  -- Degat avere puis passage sous le plancher.
  etat.dernierContact = 100
  etat.position = V.creer(0, 3, 0)
  ok, motif = interception.confirmerDestruction(etat, criteres, 100)
  verifier("degat avere + altitude sous le plancher : destruction confirmee", ok, motif)

  -- Degat avere puis epave immobile.
  etat.position = V.creer(0, 60, 0)
  etat.vitesse = V.creer(0, 0, 1)
  ok, motif = interception.confirmerDestruction(etat, criteres, 100)
  verifier("degat avere + cible immobilisee 8 s : destruction confirmee", ok, motif)
end

--------------------------------------------------------------------------------
print("\n== TEST 10 : solution de tir ==")
do
  local params = { vitesseObus = 80, graviteObus = 9.8, iterationsTir = 6 }
  local arme = V.creer(0, 150, 0)

  -- Cible immobile a 400 blocs : le canon doit pointer plus haut que la cible
  -- pour compenser la chute de l'obus.
  local s = interception.solutionTir(arme, V.creer(0, 150, 400), V.creer(0, 0, 0), params)
  verifier("temps de vol coherent (400 blocs a 80 b/s)", proche(s.tempsVol, 5, 0.01),
    s.tempsVol)
  verifier("elevation positive pour compenser la chute", s.elevation > 0, s.elevation)
  verifier("chute compensee ~ 0,5.g.t^2", proche(s.chute, 0.5 * 9.8 * 25, 0.5), s.chute)

  -- Cible qui traverse : le point d'impact doit etre devant elle.
  local sTrav = interception.solutionTir(arme, V.creer(400, 150, 0), V.creer(0, 0, 60), params)
  verifier("point d'impact devance la cible traversiere", sTrav.point.z > 200,
    sTrav.point.z)
  -- Coherence : le temps de vol correspond bien a la distance du point d'impact.
  verifier("solution de tir convergee",
    proche(V.distance(arme, sTrav.point) / 80, sTrav.tempsVol, 1e-3),
    string.format("%.4f vs %.4f", V.distance(arme, sTrav.point) / 80, sTrav.tempsVol))

  -- Azimut : cible plein sud -> lacet 0 ; cible a l'ouest -> lacet 90.
  verifier("azimut d'une cible au sud = 0", proche(s.azimut, 0, 1e-6), s.azimut)
  local sOuest = interception.solutionTir(arme, V.creer(-400, 150, 0), V.creer(0,0,0), params)
  verifier("azimut d'une cible a l'ouest = 90", proche(sOuest.azimut, 90, 1e-6), sOuest.azimut)
end

--------------------------------------------------------------------------------
print("\n== TEST 11 : autorisation de tir ==")
do
  local params = { distanceTirMaxi = 420, distanceTirMini = 80, toleranceViseeDeg = 3 }

  local ok = interception.tirAutorise(
    { dansArc = true, distance = 350, erreurVisee = 1, positionHoraire = "6h00" }, params)
  verifier("dans l'arc, a portee, bien vise : tir autorise", ok)

  local motif
  ok, motif = interception.tirAutorise(
    { dansArc = false, distance = 350, erreurVisee = 1, positionHoraire = "1h00" }, params)
  verifier("hors de l'arc : tir refuse meme sur ordre de feu", ok == false, motif)
  verifier("  ... motif mentionnant l'arc",
    motif and motif:find("arc arriere", 1, true) ~= nil, motif)

  ok, motif = interception.tirAutorise(
    { dansArc = true, distance = 900, erreurVisee = 1 }, params)
  verifier("hors de portee : tir refuse", ok == false, motif)

  ok, motif = interception.tirAutorise(
    { dansArc = true, distance = 350, erreurVisee = 12 }, params)
  verifier("visee insuffisante : tir refuse", ok == false, motif)
end

--------------------------------------------------------------------------------
print("\n== TEST 12 : point d'evasion ==")
do
  local params = { angleBreakDeg = 55, distanceEvasion = 300, altitudePlancher = 80,
    altitudePlafond = 300, amplitudeVerticaleEvasion = 60, gardeAuSol = 40 }

  local menace = V.creer(0, 150, 0)
  local soi    = V.creer(0, 150, -350)

  local p, description = interception.pointEvasion(soi, menace, 64, params, 1)
  verifier("l'evasion eloigne le navire de la menace",
    V.distance(p, menace) > V.distance(soi, menace), V.distance(p, menace))
  verifier("l'evasion n'est PAS une fuite en ligne droite",
    math.abs(p.x - soi.x) > 100, p.x - soi.x)
  verifier("description exploitable dans le journal",
    description:find("break", 1, true) ~= nil, description)

  local pBabord = interception.pointEvasion(soi, menace, 64, params, -1)
  verifier("le sens du break s'inverse", (p.x - soi.x) * (pBabord.x - soi.x) < 0,
    string.format("%.1f / %.1f", p.x - soi.x, pBabord.x - soi.x))

  -- Navire haut -> descente ; navire bas -> montee ; jamais hors enveloppe.
  local haut = interception.pointEvasion(V.creer(0, 280, -350), menace, 64, params, 1)
  verifier("navire haut : l'evasion descend", haut.y < 280, haut.y)
  local bas = interception.pointEvasion(V.creer(0, 100, -350), menace, 64, params, 1)
  verifier("navire bas : l'evasion monte", bas.y > 100, bas.y)
  verifier("altitude d'evasion dans l'enveloppe de vol",
    haut.y >= 80 and haut.y <= 300 and bas.y >= 80 and bas.y <= 300,
    string.format("%.0f / %.0f", haut.y, bas.y))

  -- Garde au sol : un relief eleve doit relever le plancher effectif.
  local rasMotte = interception.pointEvasion(V.creer(0, 90, -350), menace, 200, params, 1)
  verifier("garde au sol respectee au-dessus d'un relief", rasMotte.y >= 240, rasMotte.y)
end

--------------------------------------------------------------------------------
print(string.format("\n===== %d/%d verifications reussies =====", total - echecs, total))
os.exit(echecs == 0 and 0 or 1)
