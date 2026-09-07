-- Banc d'essai du noyau de decision de FrenchNet Command, hors du jeu.
--   Usage : lua5.4 tests/test_command.lua   (depuis la racine du depot)
--
-- Le noyau n'utilise aucune API de CC: Tweaked : il se teste donc directement,
-- sans emulateur. C'est tout l'interet de l'avoir isole : la doctrine
-- d'engagement est verifiee case par case AVANT d'etre confiee a des canons.

local RACINE = (arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."
local noyau  = dofile(RACINE .. "/command/noyau.lua")

local echecs, total = 0, 0

local function verifier(nom, condition, detail)
  total = total + 1
  if condition then
    print(string.format("  [OK]   %s", nom))
  else
    echecs = echecs + 1
    print(string.format("  [ECHEC] %s %s", nom, detail and ("-> " .. detail) or ""))
  end
end

local function egal(nom, obtenu, attendu)
  verifier(nom, obtenu == attendu,
    string.format("obtenu '%s', attendu '%s'", tostring(obtenu), tostring(attendu)))
end

local function presque(a, b, tolerance)
  return math.abs(a - b) <= (tolerance or 1e-6)
end

--------------------------------------------------------------------------------
print("\n== TEST 1 : table d'engagement, les 24 cas de la doctrine ==")
do
  -- Chaque ligne est une phrase de la specification, transcrite telle quelle.
  local attendus = {
    -- zone,    mode,     IFF,       verdict attendu
    { "CHARLIE", "PAIX",   "ALLIE",   "OBSERVATION" },
    { "CHARLIE", "PAIX",   "GENERAL", "LIBRE" },                 -- libre passage sans suivi
    { "CHARLIE", "PAIX",   "INCONNU", "SCRAMBLE" },              -- suivi, jamais detruit
    { "CHARLIE", "GUERRE", "ALLIE",   "OBSERVATION" },
    { "CHARLIE", "GUERRE", "GENERAL", "SCRAMBLE" },              -- verification seule
    { "CHARLIE", "GUERRE", "INCONNU", "DESTRUCTION" },

    { "BRAVO",   "PAIX",   "ALLIE",   "OBSERVATION" },
    { "BRAVO",   "PAIX",   "GENERAL", "LIBRE" },
    { "BRAVO",   "PAIX",   "INCONNU", "SCRAMBLE" },
    { "BRAVO",   "GUERRE", "ALLIE",   "OBSERVATION" },
    { "BRAVO",   "GUERRE", "GENERAL", "DESTRUCTION" },           -- sans distinction
    { "BRAVO",   "GUERRE", "INCONNU", "DESTRUCTION" },

    { "ALPHA",   "PAIX",   "ALLIE",   "OBSERVATION" },
    { "ALPHA",   "PAIX",   "GENERAL", "DESTRUCTION_SCRAMBLE" },
    { "ALPHA",   "PAIX",   "INCONNU", "DESTRUCTION_SCRAMBLE" },
    { "ALPHA",   "GUERRE", "ALLIE",   "OBSERVATION" },
    { "ALPHA",   "GUERRE", "GENERAL", "DESTRUCTION_SCRAMBLE" },
    { "ALPHA",   "GUERRE", "INCONNU", "DESTRUCTION_SCRAMBLE" },

    { "ROMEO",   "PAIX",   "ALLIE",   "OBSERVATION" },
    { "ROMEO",   "PAIX",   "GENERAL", "DESTRUCTION_TOTALE" },
    { "ROMEO",   "PAIX",   "INCONNU", "DESTRUCTION_TOTALE" },
    { "ROMEO",   "GUERRE", "ALLIE",   "SCRAMBLE" },              -- LA seule exception
    { "ROMEO",   "GUERRE", "GENERAL", "DESTRUCTION_TOTALE" },
    { "ROMEO",   "GUERRE", "INCONNU", "DESTRUCTION_TOTALE" },
  }

  for _, cas in ipairs(attendus) do
    local nom = noyau.verdict(cas[1], cas[2], cas[3], false, {})
    egal(string.format("%-7s %-6s %-7s", cas[1], cas[2], cas[3]), nom, cas[4])
  end
end

--------------------------------------------------------------------------------
print("\n== TEST 2 : coherence interne des verdicts ==")
do
  local V = noyau.VERDICTS
  verifier("aucun ordre n'est emis sous le palier 2",
    not V.LIBRE.feu and not V.LIBRE.scramble
    and not V.OBSERVATION.feu and not V.OBSERVATION.scramble
    and not V.HORS_JURIDICTION.feu and not V.HORS_JURIDICTION.scramble)
  verifier("le scramble seul n'ouvre jamais le feu",
    V.SCRAMBLE.scramble and not V.SCRAMBLE.feu)
  verifier("Alpha : la destruction s'accompagne toujours d'un scramble",
    V.DESTRUCTION_SCRAMBLE.feu and V.DESTRUCTION_SCRAMBLE.scramble)
  verifier("Romeo : la destruction totale mobilise toutes les forces",
    V.DESTRUCTION_TOTALE.feu and V.DESTRUCTION_TOTALE.mobilisation)
  verifier("Bravo/Charlie : destruction simple, sans mobilisation generale",
    V.DESTRUCTION.feu and not V.DESTRUCTION.mobilisation and not V.DESTRUCTION.scramble)
  verifier("hors juridiction : aucun suivi",
    V.HORS_JURIDICTION.suivi == false and V.HORS_JURIDICTION.palier == 0)
  verifier("libre passage sans suivi (code general Charlie/Bravo en paix)",
    V.LIBRE.suivi == false)
  verifier("observation passive : suivie mais jamais engagee",
    V.OBSERVATION.suivi == true and V.OBSERVATION.palier == 1)
end

--------------------------------------------------------------------------------
print("\n== TEST 3 : zone non classifiee et alerte maximale ==")
do
  local nom = noyau.verdict(nil, "GUERRE", "INCONNU", false, {})
  egal("zone non classifiee : aucune action", nom, "HORS_JURIDICTION")

  nom = noyau.verdict("CHARLIE", "PAIX", "INCONNU", true, {})
  egal("alerte max sur Charlie en paix : regime Romeo", nom, "DESTRUCTION_TOTALE")

  nom = noyau.verdict("CHARLIE", "PAIX", "ALLIE", true, {})
  egal("alerte max : le code allie subit la regle Romeo/guerre", nom, "SCRAMBLE")

  nom = noyau.verdict(nil, "PAIX", "INCONNU", true, {})
  egal("alerte max hors zone : hors juridiction par defaut", nom, "HORS_JURIDICTION")

  nom = noyau.verdict(nil, "PAIX", "INCONNU", true, { alerteMaxCouvreHorsZone = true })
  egal("alerte max hors zone, option activee", nom, "DESTRUCTION_TOTALE")
end

--------------------------------------------------------------------------------
print("\n== TEST 4 : geometrie des zones ==")
do
  local carre = { nom = "CARRE", classe = "ALPHA", forme = "rectangle",
    points = { {x=0,z=0}, {x=100,z=0}, {x=100,z=100}, {x=0,z=100} } }
  verifier("rectangle : point interieur", noyau.pointDansZone(carre, 50, 80, 50))
  verifier("rectangle : point exterieur", not noyau.pointDansZone(carre, 150, 80, 50))
  verifier("rectangle : point sur une arete compte comme interieur",
    noyau.pointDansZone(carre, 0, 80, 50))

  -- Coins saisis "en Z" : sans reordonnancement, le polygone serait un sablier
  -- et le centre tomberait en dehors.
  local enZ = { nom = "Z", classe = "ALPHA", forme = "rectangle",
    points = noyau.ordonnerCoins({ {x=0,z=0}, {x=100,z=100}, {x=100,z=0}, {x=0,z=100} }) }
  verifier("rectangle : coins mal ordonnes redresses", noyau.pointDansZone(enZ, 50, 80, 50))

  local losange = { nom = "LOSANGE", classe = "BRAVO", forme = "rectangle",
    points = { {x=50,z=0}, {x=100,z=50}, {x=50,z=100}, {x=0,z=50} } }
  verifier("rectangle pivote : centre interieur", noyau.pointDansZone(losange, 50, 80, 50))
  verifier("rectangle pivote : coin exterieur", not noyau.pointDansZone(losange, 5, 80, 5))

  local cercle = { nom = "CERCLE", classe = "ROMEO", forme = "cercle",
    centre = {x=0,z=0}, rayon = 50 }
  verifier("cercle : point interieur", noyau.pointDansZone(cercle, 30, 80, 0))
  verifier("cercle : point sur le bord", noyau.pointDansZone(cercle, 50, 80, 0))
  verifier("cercle : point exterieur", not noyau.pointDansZone(cercle, 60, 80, 0))

  local plafonnee = { nom = "PLAFOND", classe = "ALPHA", forme = "cercle",
    centre = {x=0,z=0}, rayon = 50, yMax = 120, yMin = 60 }
  verifier("bornes verticales : dans la tranche", noyau.pointDansZone(plafonnee, 10, 100, 0))
  verifier("bornes verticales : au-dessus du plafond",
    not noyau.pointDansZone(plafonnee, 10, 200, 0))
  verifier("bornes verticales : sous le plancher",
    not noyau.pointDansZone(plafonnee, 10, 10, 0))
end

--------------------------------------------------------------------------------
print("\n== TEST 5 : chevauchement, la classe la plus stricte l'emporte ==")
do
  local function paire(classeA, classeB)
    local zones = {
      { nom="A", classe=classeA, forme="rectangle",
        points={ {x=-500,z=-500},{x=500,z=-500},{x=500,z=500},{x=-500,z=500} } },
      { nom="B", classe=classeB, forme="cercle", centre={x=0,z=0}, rayon=100 },
    }
    return (noyau.zonePourPoint(zones, 0, 80, 0))
  end

  egal("Romeo sur Alpha",   paire("ALPHA", "ROMEO"), "ROMEO")
  egal("Romeo sur Alpha (ordre inverse)", paire("ROMEO", "ALPHA"), "ROMEO")
  egal("Alpha sur Bravo",   paire("BRAVO", "ALPHA"), "ALPHA")
  egal("Bravo sur Charlie", paire("CHARLIE", "BRAVO"), "BRAVO")
  egal("Romeo sur Charlie", paire("CHARLIE", "ROMEO"), "ROMEO")

  -- Hors du cercle, seule la grande zone s'applique.
  local zones = {
    { nom="A", classe="CHARLIE", forme="rectangle",
      points={ {x=-500,z=-500},{x=500,z=-500},{x=500,z=500},{x=-500,z=500} } },
    { nom="B", classe="ROMEO", forme="cercle", centre={x=0,z=0}, rayon=100 },
  }
  egal("hors du chevauchement : classe de la zone englobante",
    (noyau.zonePourPoint(zones, 300, 80, 300)), "CHARLIE")
  egal("hors de toute zone : aucune classe",
    (noyau.zonePourPoint(zones, 5000, 80, 5000)), nil)

  local _, _, chevauchees = noyau.zonePourPoint(zones, 0, 80, 0)
  verifier("les zones chevauchees sont toutes remontees pour le journal",
    #chevauchees == 2, "#" .. #chevauchees)
end

--------------------------------------------------------------------------------
print("\n== TEST 6 : categorisation en trois classes ==")
do
  local cfg = { altitudeSolReference = 64, hauteurAerienne = 25, vitesseVerticaleAerienne = 6 }
  local C = noyau.CATEGORIES
  local N = noyau.NATURES

  egal("joueur au sol -> infanterie",
    (noyau.categoriser({ y = 64, nature = N.JOUEUR }, cfg)), C.INFANTERIE)
  egal("vehicule au sol -> vehicule au sol",
    (noyau.categoriser({ y = 70, nature = N.VEHICULE }, cfg)), C.VEHICULE_SOL)
  egal("vehicule en altitude -> cible aerienne",
    (noyau.categoriser({ y = 100, nature = N.VEHICULE }, cfg)), C.AERIENNE)
  egal("joueur en altitude (elytre, jetpack) -> cible aerienne",
    (noyau.categoriser({ y = 100, nature = N.JOUEUR }, cfg)), C.AERIENNE)
  egal("montee rapide sous le seuil -> cible aerienne",
    (noyau.categoriser({ y = 70, nature = N.VEHICULE, vitesseVerticale = 10 }, cfg)), C.AERIENNE)

  -- Le piege de l'altitude absolue : un char sur un plateau a Y=210.
  local zoneMontagne = { solY = 200 }
  egal("vehicule sur un plateau eleve reste au sol (sol de reference de la zone)",
    (noyau.categoriser({ y = 210, nature = N.VEHICULE }, cfg, zoneMontagne)), C.VEHICULE_SOL)
  egal("aeronef au-dessus du meme plateau reste aerien",
    (noyau.categoriser({ y = 260, nature = N.VEHICULE }, cfg, zoneMontagne)), C.AERIENNE)
end

--------------------------------------------------------------------------------
print("\n== TEST 7 : identification par transpondeur ==")
do
  local codes = { codeAllie = "ALLIE-X", codeGeneral = "GEN-2", codeGeneralPrecedent = "GEN-1",
                  rotationA = 1000 }
  local cfg = { validiteTranspondeur = 15, graceRotation = 300 }
  local I = noyau.IFF

  egal("aucun transpondeur -> inconnu",
    (noyau.statutIff(nil, codes, 1000, cfg)), I.INCONNU)
  egal("code vide -> inconnu",
    (noyau.statutIff({ code = "", recuA = 1000 }, codes, 1000, cfg)), I.INCONNU)
  egal("code allie -> allie",
    (noyau.statutIff({ code = "ALLIE-X", recuA = 995 }, codes, 1000, cfg)), I.ALLIE)
  egal("code general courant -> general",
    (noyau.statutIff({ code = "GEN-2", recuA = 995 }, codes, 1000, cfg)), I.GENERAL)
  egal("code inconnu -> inconnu",
    (noyau.statutIff({ code = "PIRATE", recuA = 995 }, codes, 1000, cfg)), I.INCONNU)
  egal("code allie perime -> inconnu",
    (noyau.statutIff({ code = "ALLIE-X", recuA = 900 }, codes, 1000, cfg)), I.INCONNU)
  egal("code general precedent pendant la grace -> general",
    (noyau.statutIff({ code = "GEN-1", recuA = 1000 }, codes, 1000, cfg)), I.GENERAL)
  egal("code general precedent apres la grace -> inconnu",
    (noyau.statutIff({ code = "GEN-1", recuA = 1395 }, codes, 1400, cfg)), I.INCONNU)
end

--------------------------------------------------------------------------------
print("\n== TEST 8 : designation du tireur et repartition de charge ==")
do
  local cible = { x = 50, y = 100, z = 0 }

  -- AirShip1 est plus proche mais a deja beaucoup tire : la charge doit primer.
  local candidats = noyau.designer({
    { nom = "AirShip1",  x = 0,   y = 100, z = 0, tirs = 10 },
    { nom = "Tourelle2", x = 100, y = 64,  z = 0, tirs = 0 },
  }, cible, { poidsTirs = 1.0, poidsDistance = 1.0 })
  egal("la plateforme la moins sollicitee est designee", candidats[1].nom, "Tourelle2")

  -- A charge egale, c'est la distance qui tranche.
  candidats = noyau.designer({
    { nom = "AirShip1",  x = 0,   y = 100, z = 0, tirs = 5 },
    { nom = "Tourelle2", x = 100, y = 64,  z = 0, tirs = 5 },
  }, cible, {})
  egal("a charge egale, la plus proche est designee", candidats[1].nom, "AirShip1")

  -- Priorite absolue a la distance : la charge est ignoree.
  candidats = noyau.designer({
    { nom = "AirShip1",  x = 0,   y = 100, z = 0, tirs = 10 },
    { nom = "Tourelle2", x = 100, y = 64,  z = 0, tirs = 0 },
  }, cible, { poidsTirs = 0, poidsDistance = 1 })
  egal("poidsTirs a zero : seule la distance compte", candidats[1].nom, "AirShip1")

  -- Determinisme : deux plateformes strictement equivalentes.
  candidats = noyau.designer({
    { nom = "Zulu",  x = 0, y = 100, z = 0, tirs = 3 },
    { nom = "Alpha", x = 0, y = 100, z = 0, tirs = 3 },
  }, cible, {})
  egal("egalite parfaite : ordre alphabetique, decision rejouable",
    candidats[1].nom, "Alpha")

  -- Filtres.
  local c2, rejetes = noyau.designer({
    { nom = "Loin", x = 5000, y = 64, z = 5000, tirs = 0, portee = 100 },
    { nom = "HS",   x = 0,    y = 100, z = 0,   tirs = 0, disponible = false },
  }, cible, {})
  verifier("plateformes hors portee et indisponibles ecartees", #c2 == 0, "#" .. #c2)
  verifier("les motifs de rejet sont remontes", #rejetes == 2, "#" .. #rejetes)

  local c3 = noyau.designer({
    { nom = "Loin", x = 5000, y = 64, z = 5000, tirs = 0, portee = 100 },
  }, cible, { designerHorsPortee = true })
  verifier("designerHorsPortee force la designation", #c3 == 1, "#" .. #c3)
end

--------------------------------------------------------------------------------
print("\n== TEST 9 : plan d'engagement ==")
do
  local candidats = {
    { nom = "P1" }, { nom = "P2" }, { nom = "P3" },
  }
  local V = noyau.VERDICTS

  local ordres = noyau.planifier(V.OBSERVATION, candidats)
  verifier("observation passive : aucun ordre", #ordres == 0, "#" .. #ordres)

  ordres = noyau.planifier(V.SCRAMBLE, candidats)
  verifier("scramble : un seul intercepteur",
    #ordres == 1 and ordres[1].role == "SCRAMBLE")

  ordres = noyau.planifier(V.DESTRUCTION, candidats)
  verifier("destruction simple : un seul tireur",
    #ordres == 1 and ordres[1].role == "FIRE")

  ordres = noyau.planifier(V.DESTRUCTION_SCRAMBLE, candidats)
  verifier("Alpha : un tireur et un intercepteur, plateformes distinctes",
    #ordres == 2 and ordres[1].role == "FIRE" and ordres[2].role == "SCRAMBLE"
    and ordres[1].candidat.nom ~= ordres[2].candidat.nom)

  ordres = noyau.planifier(V.DESTRUCTION_SCRAMBLE, { { nom = "Seule" } })
  verifier("Alpha avec une seule plateforme : elle assure les deux roles",
    #ordres == 2 and ordres[1].candidat.nom == "Seule" and ordres[2].candidat.nom == "Seule")

  ordres = noyau.planifier(V.DESTRUCTION_TOTALE, candidats)
  verifier("Romeo : mobilisation generale, toutes les plateformes",
    #ordres == 3 and ordres[1].role == "FIRE" and ordres[3].role == "FIRE")

  ordres = noyau.planifier(V.DESTRUCTION, {})
  verifier("aucune plateforme : aucun ordre", #ordres == 0)
end

--------------------------------------------------------------------------------
print("\n== TEST 10 : format des ordres vers Fire Control ==")
do
  local cfg = {}
  egal("format specifie",
    noyau.formaterOrdre("FIRE", "AirShip1", "AERIENNE", cfg), "AirShip1 Fire type Aerial")
  egal("vehicule au sol",
    noyau.formaterOrdre("FIRE", "Tourelle2", "VEHICULE_SOL", cfg), "Tourelle2 Fire type GroundVehicle")
  egal("infanterie",
    noyau.formaterOrdre("FIRE", "Mortier3", "INFANTERIE", cfg), "Mortier3 Fire type Infantry")

  -- Un scramble n'est pas un ordre de tir : verbe distinct par defaut.
  egal("scramble : verbe distinct (reglage sur)",
    noyau.formaterOrdre("SCRAMBLE", "AirShip1", "AERIENNE", cfg), "AirShip1 Scramble type Aerial")
  egal("formatUniqueFire : verbe unique, conforme a la lettre du format",
    noyau.formaterOrdre("SCRAMBLE", "AirShip1", "AERIENNE", { formatUniqueFire = true }),
    "AirShip1 Fire type Aerial")
end

--------------------------------------------------------------------------------
print("\n== TEST 11 : confirmation de destruction, declencheur A (radar) ==")
do
  local cfg = { disparitionSecondes = 3, ratioEnveloppeFiable = 0.80, porteeRadar = 500,
                delaiEvaluationSecondes = 8 }
  local R = noyau.RESULTATS_KILL

  -- Disparition franche, bien a l'interieur de la portee : c'est un kill.
  local resultat = noyau.evaluerDestruction(
    { present = false, vuA = 96, distanceRadar = 300, echantillons = {} },
    { ordreA = 95 }, cfg, 100)
  egal("disparition dans l'enveloppe fiable -> destruction confirmee", resultat, R.CONFIRME)

  -- Disparition au bord de la portee : c'est une fuite jusqu'a preuve du
  -- contraire. Confirmer ici reviendrait a cesser le feu sur ce qui s'echappe.
  resultat = noyau.evaluerDestruction(
    { present = false, vuA = 96, distanceRadar = 480, echantillons = {} },
    { ordreA = 99 }, cfg, 100)
  egal("disparition au bord de portee -> pas de confirmation", resultat, R.EN_ATTENTE)

  resultat = noyau.evaluerDestruction(
    { present = false, vuA = 96, distanceRadar = 480, echantillons = {} },
    { ordreA = 90 }, cfg, 100)
  egal("disparition au bord, delai ecoule -> piste perdue, pas detruite", resultat, R.PERDU)

  -- Absence trop breve : un echo manque ne prouve rien.
  resultat = noyau.evaluerDestruction(
    { present = false, vuA = 99, distanceRadar = 100, echantillons = {} },
    { ordreA = 99 }, cfg, 100)
  egal("absence trop breve -> evaluation en cours", resultat, R.EN_ATTENTE)
end

--------------------------------------------------------------------------------
print("\n== TEST 12 : confirmation de destruction, declencheur B (crash) ==")
do
  local cfg = { fenetreCrashSecondes = 3, perteVitesseRatio = 0.50, perteAltitudeBlocs = 40,
                vitesseMiniCrash = 2, delaiEvaluationSecondes = 8, porteeRadar = 500 }
  local R = noyau.RESULTATS_KILL

  -- Crash : la vitesse s'effondre ET l'appareil perd 50 blocs sur la fenetre.
  local crash = { present = true, echantillons = {
    { t = 0, x = 0,  y = 150, z = 0 },
    { t = 1, x = 20, y = 150, z = 0 },   -- 20 b/s
    { t = 2, x = 40, y = 140, z = 0 },
    { t = 3, x = 55, y = 120, z = 0 },
    { t = 4, x = 58, y = 100, z = 0 },   -- 3 b/s, -50 blocs depuis t=1
  } }
  local resultat, detail = noyau.evaluerDestruction(crash, { ordreA = 0 }, cfg, 4)
  egal("perte de vitesse ET d'altitude -> destruction confirmee", resultat, R.CONFIRME)
  verifier("le detail du declencheur B est journalisable",
    type(detail) == "string" and detail:find("declencheur B", 1, true) ~= nil, tostring(detail))

  -- Pique volontaire : l'appareil perd 50 blocs mais GAGNE de la vitesse.
  -- C'est exactement ce que les deux criteres combines doivent distinguer.
  local pique = { present = true, echantillons = {
    { t = 0, x = 0,  y = 150, z = 0 },
    { t = 1, x = 10, y = 150, z = 0 },   -- 10 b/s
    { t = 2, x = 25, y = 140, z = 0 },
    { t = 3, x = 45, y = 120, z = 0 },
    { t = 4, x = 70, y = 100, z = 0 },   -- 25 b/s
  } }
  resultat = noyau.evaluerDestruction(pique, { ordreA = 3 }, cfg, 4)
  egal("pique volontaire (vitesse en hausse) -> aucune confirmation", resultat, R.EN_ATTENTE)

  -- Freinage en palier : la vitesse s'effondre mais l'altitude tient.
  local freinage = { present = true, echantillons = {
    { t = 0, x = 0,  y = 150, z = 0 },
    { t = 1, x = 30, y = 150, z = 0 },   -- 30 b/s
    { t = 2, x = 55, y = 149, z = 0 },
    { t = 3, x = 70, y = 148, z = 0 },
    { t = 4, x = 72, y = 147, z = 0 },   -- 2 b/s, -3 blocs seulement
  } }
  resultat = noyau.evaluerDestruction(freinage, { ordreA = 3 }, cfg, 4)
  egal("freinage sans perte d'altitude -> aucune confirmation", resultat, R.EN_ATTENTE)

  -- Stationnaire : sans vitesse de reference, le declencheur B n'a pas de sens.
  local stationnaire = { present = true, echantillons = {
    { t = 0, x = 0, y = 150, z = 0 },
    { t = 1, x = 0, y = 150, z = 0 },
    { t = 2, x = 0, y = 130, z = 0 },
    { t = 3, x = 0, y = 110, z = 0 },
    { t = 4, x = 0, y = 100, z = 0 },
  } }
  resultat = noyau.evaluerDestruction(stationnaire, { ordreA = 3 }, cfg, 4)
  egal("stationnaire en descente -> aucune confirmation (pas de vitesse de reference)",
    resultat, R.EN_ATTENTE)
end

--------------------------------------------------------------------------------
print("\n== TEST 13 : reemission apres absence de signal ==")
do
  local cfg = { delaiEvaluationSecondes = 8, porteeRadar = 500, fenetreCrashSecondes = 3 }
  local R = noyau.RESULTATS_KILL

  -- Cible toujours la, en vol stable : ni disparition, ni signature de crash.
  local intacte = { present = true, echantillons = {
    { t = 0,  x = 0,   y = 150, z = 0 },
    { t = 5,  x = 100, y = 150, z = 0 },
    { t = 10, x = 200, y = 150, z = 0 },
  } }
  local resultat, detail = noyau.evaluerDestruction(intacte, { ordreA = 0 }, cfg, 10)
  egal("aucun des deux signaux apres le delai -> reemission", resultat, R.AUCUN_SIGNAL)
  verifier("le detail nomme l'absence des deux declencheurs",
    detail:find("aucun des deux", 1, true) ~= nil, detail)

  resultat = noyau.evaluerDestruction(intacte, { ordreA = 8 }, cfg, 10)
  egal("avant le delai -> on laisse le temps aux declencheurs", resultat, R.EN_ATTENTE)
end

--------------------------------------------------------------------------------
print("\n== TEST 14 : validation des zones ==")
do
  local function motif(zone)
    local ok, m = noyau.validerZone(zone)
    return ok, m
  end

  verifier("zone circulaire valide",
    (motif({ nom="A", classe="ALPHA", forme="cercle", centre={x=0,z=0}, rayon=50 })))
  verifier("zone rectangulaire valide",
    (motif({ nom="A", classe="ROMEO", forme="rectangle",
      points={{x=0,z=0},{x=1,z=0},{x=1,z=1},{x=0,z=1}} })))
  verifier("classe inconnue refusee",
    not (motif({ nom="A", classe="DELTA", forme="cercle", centre={x=0,z=0}, rayon=50 })))
  verifier("nom manquant refuse",
    not (motif({ classe="ALPHA", forme="cercle", centre={x=0,z=0}, rayon=50 })))
  verifier("rayon negatif refuse",
    not (motif({ nom="A", classe="ALPHA", forme="cercle", centre={x=0,z=0}, rayon=-5 })))
  verifier("rectangle a 3 points refuse",
    not (motif({ nom="A", classe="ALPHA", forme="rectangle",
      points={{x=0,z=0},{x=1,z=0},{x=1,z=1}} })))
  verifier("forme inconnue refusee",
    not (motif({ nom="A", classe="ALPHA", forme="triangle" })))
  verifier("plafond sous le plancher refuse",
    not (motif({ nom="A", classe="ALPHA", forme="cercle", centre={x=0,z=0}, rayon=5,
      yMin=200, yMax=100 })))
end

--------------------------------------------------------------------------------
print("\n== TEST 15 : scenario complet, un intrus traverse quatre zones ==")
do
  local zones = {
    { nom="CIVIL",   classe="CHARLIE", forme="cercle", centre={x=0,z=0},    rayon=200 },
    { nom="APPROCHE",classe="BRAVO",   forme="cercle", centre={x=600,z=0},  rayon=200 },
    { nom="BASE",    classe="ALPHA",   forme="cercle", centre={x=1200,z=0}, rayon=200 },
    { nom="QG",      classe="ROMEO",   forme="cercle", centre={x=1800,z=0}, rayon=200 },
  }
  local cfg = { altitudeSolReference = 64, hauteurAerienne = 25 }

  -- Un aeronef sans transpondeur, en temps de guerre, du plus permissif au
  -- plus strict.
  local attendus = {
    { 0,    "CHARLIE", "DESTRUCTION" },
    { 600,  "BRAVO",   "DESTRUCTION" },
    { 1200, "ALPHA",   "DESTRUCTION_SCRAMBLE" },
    { 1800, "ROMEO",   "DESTRUCTION_TOTALE" },
    { 3000, nil,       "HORS_JURIDICTION" },
  }
  for _, cas in ipairs(attendus) do
    local classe = noyau.zonePourPoint(zones, cas[1], 150, 0)
    egal(string.format("intrus en X=%d : zone", cas[1]), classe, cas[2])
    local nom = noyau.verdict(classe, "GUERRE", "INCONNU", false, {})
    egal(string.format("intrus en X=%d : verdict", cas[1]), nom, cas[3])
  end

  -- Le meme trajet avec le code allie : libre passage partout, sauf au QG.
  local attendusAllie = {
    { 0,    "OBSERVATION" },
    { 600,  "OBSERVATION" },
    { 1200, "OBSERVATION" },
    { 1800, "SCRAMBLE" },      -- Romeo en guerre : verification, sans engagement
  }
  for _, cas in ipairs(attendusAllie) do
    local classe = noyau.zonePourPoint(zones, cas[1], 150, 0)
    local nom, verdict = noyau.verdict(classe, "GUERRE", "ALLIE", false, {})
    egal(string.format("allie en X=%d", cas[1]), nom, cas[2])
    verifier(string.format("allie en X=%d : jamais de tir", cas[1]), verdict.feu == false)
  end

  -- Categorisation le long du meme trajet.
  egal("aeronef a Y=150 -> cible aerienne",
    (noyau.categoriser({ y = 150, nature = noyau.NATURES.VEHICULE }, cfg)),
    noyau.CATEGORIES.AERIENNE)

  -- Ordre final effectivement transmis a Fire Control.
  local candidats = noyau.designer({
    { nom = "AirShip1", x = 1800, y = 200, z = 100, tirs = 2 },
    { nom = "SAM-Est",  x = 1900, y = 70,  z = 0,   tirs = 2 },
  }, { x = 1800, y = 150, z = 0 }, {})
  local ordres = noyau.planifier(noyau.VERDICTS.DESTRUCTION_TOTALE, candidats)
  verifier("mobilisation generale : les deux plateformes recoivent un ordre", #ordres == 2)
  local chaines = {}
  for _, o in ipairs(ordres) do
    chaines[#chaines + 1] = noyau.formaterOrdre(o.role, o.candidat.nom, "AERIENNE", {})
  end
  table.sort(chaines)
  egal("ordre 1", chaines[1], "AirShip1 Fire type Aerial")
  egal("ordre 2", chaines[2], "SAM-Est Fire type Aerial")
end

--------------------------------------------------------------------------------
print(string.format("\n===== %d verification(s), %d echec(s) =====", total, echecs))
if echecs > 0 then os.exit(1) end
os.exit(0)
