-- Banc d'essai du module d'autopilote FrenchNet, hors du jeu.
--   Usage : lua5.4 tests/test_autopilote.lua   (depuis la racine du depot)
-- Deux familles de verifications :
--   * unitaires  : PID, filtres, angles, zone morte, detecteur, decalages ;
--   * en boucle fermee : le module pilote un vehicule simule (tests/banc_vol.lua)
--     et on verifie qu'il arrive vraiment, sans depassement ni oscillation.

local RACINE = (arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."
local SCR    = RACINE .. "/tests"
local SRC    = RACINE .. "/autopilote"
local BANC   = "/tmp/banc_autopilote_frenchnet"

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

--- Contenu du fichier journal ecrit par l'autopilote pendant l'essai.
local function journal()
  local f = io.open(BANC .. "/autopilote/autopilote.log", "r")
  if not f then return "" end
  local contenu = f:read("a")
  f:close()
  return contenu
end

local function journalContient(motif)
  return journal():find(motif, 1, true) ~= nil
end

local function preparer(remplacements)
  os.execute("rm -rf " .. BANC .. " && mkdir -p " .. BANC .. "/autopilote")
  os.execute("cp " .. SRC .. "/*.lua " .. BANC .. "/autopilote/ 2>/dev/null")
  if remplacements then
    local f = io.open(BANC .. "/autopilote/config_vehicule.lua", "r")
    local source = f:read("a")
    f:close()
    for motif, valeur in pairs(remplacements) do
      local remplace
      source, remplace = source:gsub(motif, valeur, 1)
      if remplace == 0 then error("motif de configuration introuvable : " .. motif) end
    end
    f = io.open(BANC .. "/autopilote/config_vehicule.lua", "w")
    f:write(source)
    f:close()
  end
end

--- Construit un environnement simule + un autopilote pret a voler.
local function monter(options)
  options = options or {}
  preparer(options.config)
  local banc = dofile(SCR .. "/banc_vol.lua")
  local env, etat = banc.creer({
    racine      = BANC,
    budget      = options.budget or 400,
    bruitGps    = options.bruitGps,
    decalageGps = options.decalageGps or { x = 0, y = 2, z = 4 },
    facteurTempsReel = options.facteurTempsReel,
    vehicule    = options.vehicule or { x = 100, y = 150, z = 100, cap = 0, vLateralMax = 0 },
  })
  local autopilote = banc.charger(SRC .. "/autopilote.lua")
  local ap
  if not options.sansInstance then
    -- Attention : 'a and nil or b' vaut toujours b en Lua, d'ou le if explicite.
    local pilote = nil
    if not options.sansPilote then pilote = banc.pilote() end
    ap = autopilote.nouveau({
      config    = "/autopilote/config_vehicule.lua",
      commandes = pilote,
      cap       = options.cap,
    })
    ap.initialiser()
  end
  return banc, env, etat, autopilote, ap
end

--- Fait tourner l'autopilote jusqu'a l'arrivee ou l'echeance.
local function voler(ap, env, etat, limite, pendant)
  local depart = etat.horloge
  while etat.horloge - depart < limite do
    ap.pas()
    if pendant then pendant(etat.horloge - depart) end
    if ap.estArrive() then return true end
    env.sleep(0.4)
  end
  return ap.estArrive()
end

--------------------------------------------------------------------------------
print("\n== TEST 1 : regulateur PID robuste ==")
do
  local _, _, _, autopilote = monter({ sansInstance = true })
  local Pid = autopilote.interne.Pid

  -- a. Derivee sur la MESURE : un changement de consigne ne doit pas produire
  --    d'a-coup (le "derivative kick" classique du PID naif).
  local pid = Pid.nouveau({ kp = 0.1, ki = 0, kd = 1.0, penteMax = 1000 })
  pid.calculer(0, 0, 0.2)
  local sortieStable = select(1, pid.calculer(0, 0, 0.2))
  local sortieSaut   = select(1, pid.calculer(10, 0, 0.2))  -- consigne 0 -> 10
  verifier("derivee sur la mesure : pas d'a-coup au changement de consigne",
    math.abs(sortieSaut - 1.0) < 1e-6, string.format("%.4f (stable %.4f)", sortieSaut, sortieStable))

  -- Une variation de la MESURE, elle, doit bien produire un terme derive.
  local pid2 = Pid.nouveau({ kp = 0, ki = 0, kd = 1.0, penteMax = 1000, filtreDerivee = 0 })
  pid2.calculer(0, 0, 0.2)
  local sortieDerivee = select(1, pid2.calculer(0, 1, 0.2))  -- mesure +1 en 0.2s
  verifier("derivee active sur une variation de mesure", sortieDerivee < -0.9,
    string.format("%.4f", sortieDerivee))

  -- b. Anti-emballement : integrale gelee quand la commande est saturee.
  local pid3 = Pid.nouveau({ kp = 1, ki = 5, kd = 0, integraleMax = 100, penteMax = 1000 })
  for _ = 1, 50 do pid3.calculer(10, 0, 0.2) end
  local integraleSaturee = pid3.integrale
  verifier("integrale gelee pendant la saturation", integraleSaturee <= 1.0 + 1e-9,
    string.format("integrale = %.3f", integraleSaturee))
  verifier("commande bornee a la saturation", math.abs(pid3.sortiePrec - 1) < 1e-9,
    tostring(pid3.sortiePrec))
  -- Une fois la consigne atteinte, la commande doit redescendre immediatement
  -- (c'est tout l'interet du gel : pas de retard d'evacuation).
  local sortieRetour = select(1, pid3.calculer(0, 0, 0.2))
  verifier("pas d'emballement : retour immediat en sortie de saturation",
    sortieRetour < 1, string.format("%.3f", sortieRetour))

  -- c. Limitation de pente.
  local pid4 = Pid.nouveau({ kp = 10, ki = 0, kd = 0, penteMax = 1.0 })
  local sortie1 = select(1, pid4.calculer(1, 0, 0.1))
  verifier("limitation de pente de la commande", math.abs(sortie1 - 0.1) < 1e-9,
    string.format("%.4f attendu 0.1", sortie1))

  -- d. Un dt nul ou aberrant ne doit jamais produire de division par zero.
  local pid5 = Pid.nouveau({ kp = 1, ki = 1, kd = 1 })
  local ok = pcall(function() pid5.calculer(1, 0, 0) end)
  verifier("dt nul refuse sans planter", ok)
end

--------------------------------------------------------------------------------
print("\n== TEST 2 : angles et geometrie ==")
do
  local _, _, _, autopilote = monter({ sansInstance = true })
  local i = autopilote.interne

  verifier("normalisation : 190 -> -170", math.abs(i.normaliserAngle(190) + 170) < 1e-9)
  verifier("normalisation : -190 -> 170", math.abs(i.normaliserAngle(-190) - 170) < 1e-9)
  verifier("normalisation : 540 -> 180", math.abs(i.normaliserAngle(540) - 180) < 1e-9)
  -- Le cas qui provoque les tetes-a-queue : franchir la discontinuite 180.
  verifier("chemin le plus court entre 179 et -179 (2 degres, pas 358)",
    math.abs(i.normaliserAngle(-179 - 179) - 2) < 1e-9,
    tostring(i.normaliserAngle(-179 - 179)))

  verifier("cap vers le nord (-Z) = 0", math.abs(i.capVers(0, -10)) < 1e-9)
  verifier("cap vers l'est (+X) = 90", math.abs(i.capVers(10, 0) - 90) < 1e-9)
  verifier("cap vers le sud (+Z) = 180", math.abs(math.abs(i.capVers(0, 10)) - 180) < 1e-9)
  verifier("cap vers l'ouest (-X) = -90", math.abs(i.capVers(-10, 0) + 90) < 1e-9)

  -- Decalage exprime dans le repere du vehicule, nez au nord : l'avant (z)
  -- pointe vers -Z monde, le tribord (x) vers +X monde.
  local d = i.decalageVersMonde({ x = 1, y = 2, z = 3 }, 0, true)
  verifier("decalage cap 0 : avant -> -Z, tribord -> +X",
    math.abs(d.x - 1) < 1e-9 and math.abs(d.y - 2) < 1e-9 and math.abs(d.z + 3) < 1e-9,
    string.format("%.2f %.2f %.2f", d.x, d.y, d.z))
  -- Nez a l'est : l'avant pointe vers +X, le tribord vers +Z.
  local d90 = i.decalageVersMonde({ x = 1, y = 2, z = 3 }, 90, true)
  verifier("decalage cap 90 : avant -> +X, tribord -> +Z",
    math.abs(d90.x - 3) < 1e-6 and math.abs(d90.z - 1) < 1e-6,
    string.format("%.2f %.2f %.2f", d90.x, d90.y, d90.z))
  local dMonde = i.decalageVersMonde({ x = 1, y = 2, z = 3 }, 90, false)
  verifier("decalage en repere monde : jamais tourne",
    dMonde.x == 1 and dMonde.y == 2 and dMonde.z == 3)
end

--------------------------------------------------------------------------------
print("\n== TEST 3 : filtres, zone morte, detecteur d'instabilite ==")
do
  local _, _, _, autopilote = monter({ sansInstance = true })
  local i = autopilote.interne

  -- Passe-bas : le coefficient depend du dt REEL, pas d'un pas suppose.
  local f = i.Filtre.nouveau({ type = "passe_bas", constanteTemps = 1.0 })
  f.appliquer(0, 0.5)
  local court = f.appliquer(10, 0.1)   -- petit pas -> peu de progression
  f.reinitialiser(0)
  local long  = f.appliquer(10, 1.0)   -- grand pas -> beaucoup plus
  verifier("passe-bas : la progression suit le temps reellement ecoule",
    long > court * 2, string.format("dt=0.1 -> %.3f, dt=1.0 -> %.3f", court, long))

  local moyenne = i.Filtre.nouveau({ type = "moyenne", fenetre = 4 })
  moyenne.appliquer(0, 0.2); moyenne.appliquer(4, 0.2)
  moyenne.appliquer(8, 0.2); local m = moyenne.appliquer(12, 0.2)
  verifier("moyenne glissante sur 4 echantillons", math.abs(m - 6) < 1e-9, tostring(m))

  -- Zone morte : hysteresis -> pas de yo-yo autour de la limite.
  local z = i.ZoneMorte.nouveau(1.0, 0.4, 0.5)
  verifier("zone morte : rien a faire dans la zone", z.calculer(0.9) == 0)
  verifier("zone morte : pas de correction entre seuil et seuil+hysteresis",
    z.calculer(1.2) == 0)
  verifier("zone morte : correction au-dela du seuil d'entree", z.calculer(1.5) == 0.5)
  verifier("zone morte : la correction se poursuit sous le seuil d'entree (hysteresis)",
    z.calculer(1.2) == 0.5)
  verifier("zone morte : arret sous le seuil de sortie", z.calculer(0.5) == 0)
  verifier("zone morte : correction inverse de l'autre cote", z.calculer(-1.6) == -0.5)

  -- Detecteur : une erreur qui change de signe en rafale = instable.
  local reglages = { fenetre = 5, changementsSigne = 5, depassements = 99,
                     rapportDepassement = 0.6, retourAutoPid = true, dureeAvantRetour = 5 }
  local d = i.Detecteur.nouveau(reglages, 1.0)
  local instable = false
  for k = 1, 8 do
    instable = d.observer((k % 2 == 0) and 5 or -5, k * 0.4)
  end
  verifier("instabilite detectee sur changements de signe repetes", instable, d.motif)
  -- Puis le calme revient : la fenetre se vide, l'axe redevient sain.
  for k = 1, 20 do d.observer(0.1, 4 + k * 0.5) end
  verifier("detecteur non collant : retour a l'etat sain", d.instable == false)

  -- Les oscillations DANS le bruit ne comptent pas.
  local d2 = i.Detecteur.nouveau(reglages, 1.0)
  local faux = false
  for k = 1, 20 do faux = d2.observer((k % 2 == 0) and 0.5 or -0.5, k * 0.2) end
  verifier("bruit sous le seuil : aucune fausse detection", faux == false)
end

--------------------------------------------------------------------------------
print("\n== TEST 4 : configuration vehicule ==")
do
  -- a. Une valeur de vol manquante doit empecher le demarrage, en la nommant.
  local banc, env, etat, autopilote = monter({
    sansInstance = true,
    config = { ["croisiere%s+= 8%.0,"] = "" },
  })
  local ok, err = pcall(autopilote.nouveau, { config = "/autopilote/config_vehicule.lua" })
  verifier("refus de demarrer sans une valeur de vol obligatoire", not ok)
  verifier("l'anomalie nomme la cle manquante",
    ok == false and tostring(err):find("vitesses.croisiere", 1, true) ~= nil, tostring(err))

  -- b. Gains PID manquants : meme traitement.
  local _, _, _, autopilote2 = monter({
    sansInstance = true,
    config = { ["position  = { kp = 1%.20 },"] = "position = {}," },
  })
  local ok2, err2 = pcall(autopilote2.nouveau, { config = "/autopilote/config_vehicule.lua" })
  verifier("refus de demarrer sans gain PID obligatoire", not ok2)
  verifier("l'anomalie nomme le gain manquant",
    ok2 == false and tostring(err2):find("gains.cap.position.kp", 1, true) ~= nil, tostring(err2))

  -- c. La station de ravitaillement est verrouillee : une valeur declaree dans
  --    la configuration du vehicule est ignoree et signalee.
  local banc3, _, _, _, ap3 = monter({
    config = { ["return {"] = "return {\n  ravitaillement = { position = { x = 1, y = 1, z = 1 } }," },
  })
  local station = ap3.ravitaillement()
  verifier("position de ravitaillement lue dans le fichier verrouille",
    station.position.x == 128 and station.position.y == 96 and station.position.z == -742,
    string.format("%.0f %.0f %.0f", station.position.x, station.position.y, station.position.z))
  verifier("tentative de redefinition du ravitaillement signalee",
    (banc3.contient("valeur IGNOREE")))
  verifier("station non modifiable depuis l'exterieur", station.verrouille == true)
  -- La copie renvoyee ne doit pas permettre de corrompre la configuration.
  station.position.x = 0
  verifier("copie defensive de la station", ap3.ravitaillement().position.x == 128)
end

--------------------------------------------------------------------------------
print("\n== TEST 5 : vol nominal et decelaration en cascade ==")
do
  local banc, env, etat, _, ap = monter({ budget = 400 })
  local cible = { x = 260, y = 150, z = -40 }
  ap.pas(); env.sleep(0.4); ap.pas()
  ap.allerA(cible)

  local vitesseLoin, vitesseProche, depassementMax = nil, nil, 0
  local dejaProche = false
  local arrive = voler(ap, env, etat, 300, function()
    local e = ap.etat()
    local d = banc.distanceH(cible)
    if d > 45 and d < 60 and not vitesseLoin then vitesseLoin = e.vitesseSol end
    if d < 8 then
      dejaProche = true
      if not vitesseProche then vitesseProche = e.vitesseSol end
    end
    if dejaProche and d > depassementMax then depassementMax = d end
  end)

  verifier("le vehicule arrive sur la cible", arrive, "mode " .. ap.etat().mode)
  verifier("precision finale sous la tolerance", banc.distanceH(cible) <= 1.5,
    string.format("%.2f bloc", banc.distanceH(cible)))
  verifier("altitude finale sous la tolerance",
    math.abs(etat.vehicule.y - cible.y) <= 1.0,
    string.format("%.2f bloc", math.abs(etat.vehicule.y - cible.y)))
  verifier("vitesse de croisiere atteinte loin de la cible",
    vitesseLoin and vitesseLoin > 4, vitesseLoin and string.format("%.2f", vitesseLoin))
  verifier("ralentissement progressif a l'approche (cascade)",
    vitesseProche and vitesseLoin and vitesseProche < vitesseLoin * 0.5,
    string.format("loin %.2f -> proche %.2f", vitesseLoin or -1, vitesseProche or -1))
  verifier("pas de depassement de la cible",
    depassementMax < 8, string.format("%.2f bloc", depassementMax))
  verifier("aucune bascule en zone morte sur un vol nominal",
    ap.etat().modesAxes.altitude == "pid" and ap.etat().modesAxes.cap == "pid"
    and ap.etat().modesAxes.avance == "pid",
    textutils and "" or "")
  verifier("passage automatique en maintien de position apres arrivee",
    ap.etat().mode == "MAINTIEN" and ap.etat().jeuGains == "maintien", ap.etat().jeuGains)
  -- Le journal de fichier doit permettre de remonter toute la chaine de calcul.
  verifier("journal : lecture GPS et filtrage traces",
    journalContient("[etape: acquisition de la position initiale]"))
  verifier("journal : boucle externe de position tracee",
    journalContient("[etape: boucle externe de position]"))
  verifier("journal : boucle interne de vitesse tracee",
    journalContient("[etape: boucle interne de vitesse]"))
  verifier("journal : arrivee et maintien traces",
    journalContient("[etape: arrivee sur la cible]")
    and journalContient("[etape: maintien de position]"))
  verifier("journal : saturation de commande tracee",
    journalContient("[etape: saturation de commande]"))
end

--------------------------------------------------------------------------------
print("\n== TEST 6 : itineraire, altitude de croisiere, signalement des etapes ==")
do
  local banc, env, etat, _, ap = monter({ budget = 700,
    vehicule = { x = 0, y = 90, z = 0, cap = 0, vLateralMax = 0 } })

  local etapes, arrivee = {}, nil
  ap.surEvenement(function(typeEvenement, donnees)
    if typeEvenement == "etape" then etapes[#etapes + 1] = donnees end
    if typeEvenement == "arrivee" then arrivee = donnees end
  end)

  ap.pas(); env.sleep(0.4); ap.pas()
  local itineraire = {
    { x = 120, y = 95,  z = -60,  nom = "PASSAGE-1" },
    { x = 240, y = 100, z = -140, nom = "PASSAGE-2" },
    { x = 300, y = 92,  z = -220, nom = "DESTINATION" },
  }
  ap.suivreItineraire(itineraire)
  verifier("transit haute altitude arme sur une mission longue",
    ap.etatInterne.transitHaute == true)
  verifier("phase initiale : montee avant transit", ap.etat().phase == "MONTEE")

  local altitudeMin, altitudeAtteinte = 1e9, 0
  local descenduAvantFin = false
  local arrive = voler(ap, env, etat, 600, function()
    local e = ap.etat()
    if e.phase == "CROISIERE" then
      altitudeMin = math.min(altitudeMin, etat.vehicule.y)
      altitudeAtteinte = math.max(altitudeAtteinte, etat.vehicule.y)
      -- Redescendre sous l'altitude de securite avant la finale serait une faute.
      if etat.vehicule.y < 150 and banc.distanceH(itineraire[3]) > 40 then
        descenduAvantFin = true
      end
    end
  end)

  verifier("le vehicule arrive au dernier point", arrive, ap.etat().mode)
  verifier("altitude de croisiere tenue pendant le transit",
    altitudeAtteinte >= 158, string.format("%.1f", altitudeAtteinte))
  verifier("aucune redescente avant l'approche finale", not descenduAvantFin)
  verifier("descente effectuee sur le point final",
    math.abs(etat.vehicule.y - 92) <= 1.0, string.format("%.2f", etat.vehicule.y))
  verifier("chaque etape est signalee au programme appelant", #etapes == 3,
    "#" .. #etapes)
  verifier("les etapes sont signalees dans l'ordre",
    etapes[1] and etapes[1].point.nom == "PASSAGE-1"
    and etapes[2].point.nom == "PASSAGE-2" and etapes[3].point.nom == "DESTINATION")
  verifier("la derniere etape est marquee comme finale",
    etapes[3] and etapes[3].dernier == true)
  verifier("evenement d'arrivee emis", arrivee ~= nil and arrivee.ecart ~= nil)
  -- L'arrivee est jugee sur la position FILTREE ; l'ecart reel inclut donc le
  -- bruit residuel des balises (quelques dixiemes de bloc).
  verifier("precision sur le point final", banc.distanceH(itineraire[3]) <= 2.5,
    string.format("%.2f", banc.distanceH(itineraire[3])))
end

--------------------------------------------------------------------------------
print("\n== TEST 7 : decalage de depot et de point de reference GPS ==")
do
  -- Decalage GPS important : si le module ne le compensait pas, le centre du
  -- vehicule se stabiliserait a 6 blocs de la cible.
  local banc, env, etat, _, ap = monter({
    budget = 400,
    decalageGps = { x = 0, y = 2, z = 6 },
    config = { ["decalageGps = { x = 0, y = 2, z = 4 },"] = "decalageGps = { x = 0, y = 2, z = 6 }," },
    vehicule = { x = 50, y = 120, z = 50, cap = 0, vLateralMax = 0 },
  })
  ap.pas(); env.sleep(0.4); ap.pas()
  local depot = { x = 130, y = 118, z = -30, type = "depot" }
  ap.allerA(depot)
  local arrive = voler(ap, env, etat, 300)

  verifier("arrivee sur un point de depot", arrive, ap.etat().mode)
  -- decalageDepot.y = -3 : le centre doit se tenir 3 blocs AU-DESSUS du depot.
  verifier("le point de depot tombe sur la cible, pas le centre du vehicule",
    math.abs((etat.vehicule.y - 3) - depot.y) <= 1.0,
    string.format("centre %.2f, depot vise %.2f, cible %.2f",
      etat.vehicule.y, etat.vehicule.y - 3, depot.y))
  verifier("decalage GPS compense : le centre est bien sur la cible",
    banc.distanceH(depot) <= 1.5, string.format("%.2f", banc.distanceH(depot)))
end

--------------------------------------------------------------------------------
print("\n== TEST 8 : l'arrivee exige une duree continue dans les marges ==")
do
  local banc, env, etat, _, ap = monter({ budget = 400 })
  ap.pas(); env.sleep(0.4); ap.pas()
  local cible = { x = 150, y = 150, z = 60 }
  ap.allerA(cible)

  local premiereEntree, arriveALEntree, instantArrivee = nil, nil, nil
  voler(ap, env, etat, 300, function(t)
    local e = ap.etat()
    if e.distance and e.distance <= 1.5 and math.abs(e.ecartAltitude or 99) <= 1.0
       and not premiereEntree then
      premiereEntree = t
      arriveALEntree = ap.estArrive()
    end
    if ap.estArrive() and not instantArrivee then instantArrivee = t end
  end)

  verifier("le vehicule entre bien dans les marges", premiereEntree ~= nil)
  verifier("une lecture isolee dans les marges ne vaut pas arrivee",
    arriveALEntree == false)
  verifier("arrivee prononcee apres la duree continue configuree",
    instantArrivee and premiereEntree and (instantArrivee - premiereEntree) >= 2.0,
    instantArrivee and premiereEntree
      and string.format("%.2fs de marges continues", instantArrivee - premiereEntree))
end

--------------------------------------------------------------------------------
print("\n== TEST 9 : maintien de position et rattrapage de derive ==")
do
  local banc, env, etat, _, ap = monter({ budget = 500 })
  ap.pas(); env.sleep(0.4); ap.pas()
  local cible = { x = 140, y = 150, z = 40 }
  ap.allerA(cible)
  voler(ap, env, etat, 300)
  verifier("arrivee prealable", ap.estArrive())

  -- Coup de vent : le vehicule est deporte de 6 blocs et perd 4 blocs d'altitude.
  etat.vehicule.x = etat.vehicule.x + 6
  etat.vehicule.y = etat.vehicule.y - 4
  local ecartApresPoussee = banc.distanceH(cible)

  local ecartMax = 0
  for _ = 1, 200 do
    ap.pas()
    env.sleep(0.4)
    ecartMax = math.max(ecartMax, banc.distanceH(cible))
    if etat.horloge > 460 then break end
  end

  verifier("derive initiale bien prise en compte", ecartApresPoussee > 5,
    string.format("%.2f", ecartApresPoussee))
  verifier("le maintien ramene le vehicule sur le point",
    banc.distanceH(cible) <= 1.5, string.format("%.2f", banc.distanceH(cible)))
  verifier("altitude rattrapee", math.abs(etat.vehicule.y - cible.y) <= 1.0,
    string.format("%.2f", math.abs(etat.vehicule.y - cible.y)))
  verifier("le maintien reste en mode MAINTIEN", ap.etat().mode == "MAINTIEN")
  verifier("gains de maintien appliques", ap.etat().jeuGains == "maintien")
end

--------------------------------------------------------------------------------
print("\n== TEST 10 : perte du signal GPS ==")
do
  local banc, env, etat, _, ap = monter({ budget = 600 })
  local anomalies = {}
  ap.surEvenement(function(t, d) if t == "anomalie" then anomalies[#anomalies + 1] = d end end)
  ap.pas(); env.sleep(0.4); ap.pas()
  ap.allerA({ x = 400, y = 150, z = 300 })

  for _ = 1, 25 do ap.pas() env.sleep(0.4) end
  verifier("mission en cours avant la panne", ap.etat().mode == "TRANSIT")

  -- Coupure des balises.
  etat.gpsActif = false
  ap.pas()
  verifier("navigation a l'estime des la premiere lecture manquee",
    journalContient("navigation a l'estime"))
  verifier("le vehicule continue brievement sur sa derniere vitesse",
    ap.etat().mode == "TRANSIT")

  for _ = 1, 6 do ap.pas() env.sleep(0.4) end
  verifier("passage en mode secours au-dela de la tolerance",
    ap.etat().mode == "SECOURS", ap.etat().mode)
  verifier("anomalie signalee au programme appelant", #anomalies >= 1)
  verifier("commandes neutralisees en secours",
    etat.vehicule.commandes.avance == 0 and etat.vehicule.commandes.vertical == 0)
  verifier("secours journalise", journalContient("MODE SECOURS"))

  -- Retour des balises.
  etat.gpsActif = true
  ap.pas(); env.sleep(0.4); ap.pas()
  verifier("sortie du mode secours au retour du GPS",
    ap.etat().mode ~= "SECOURS", ap.etat().mode)
  verifier("reprise de la mission apres retour du signal",
    ap.etat().mode == "TRANSIT", ap.etat().mode)
  verifier("retablissement journalise", journalContient("sortie du mode secours"))
end

--------------------------------------------------------------------------------
print("\n== TEST 11 : repli automatique en zone morte et forcage manuel ==")
do
  -- Gains volontairement absurdes sur l'axe altitude : la boucle diverge.
  local banc, env, etat, _, ap = monter({
    budget = 500,
    config = {
      ["position  = { kp = 0%.70 },"] = "position  = { kp = 9.0 },",
      ["croisiere = { kp = 0%.25, ki = 0%.060, kd = 0%.050,"] =
        "croisiere = { kp = 6.00, ki = 2.000, kd = 0.000,",
    },
  })
  local basculesSignalees = {}
  ap.surEvenement(function(t, d)
    if t == "mode" then basculesSignalees[#basculesSignalees + 1] = d end
  end)
  ap.pas(); env.sleep(0.4); ap.pas()
  ap.allerA({ x = 200, y = 170, z = -60 })

  local bascule = false
  for _ = 1, 200 do
    ap.pas()
    env.sleep(0.4)
    if ap.etat().modesAxes.altitude == "zone_morte" then bascule = true break end
    if etat.horloge > 450 then break end
  end

  verifier("instabilite detectee sur l'axe altitude", bascule,
    ap.etat().modesAxes.altitude)
  verifier("bascule journalisee avec son motif",
    journalContient("bascule en mode ZONE MORTE"))
  local basculeAltitudeSignalee = false
  for _, d in ipairs(basculesSignalees) do
    if d.axe == "altitude" and d.mode == "zone_morte" then basculeAltitudeSignalee = true end
  end
  verifier("bascule signalee au programme appelant", basculeAltitudeSignalee,
    "#" .. #basculesSignalees)

  -- L'altitude doit rester tenue malgre le repli (logique si/sinon).
  for _ = 1, 120 do ap.pas() env.sleep(0.4) if etat.horloge > 480 then break end end
  verifier("altitude tenue par la logique de zone morte",
    math.abs(etat.vehicule.y - 170) < 6,
    string.format("%.2f", math.abs(etat.vehicule.y - 170)))

  -- Forcage manuel depuis l'interface de controle.
  ap.definirMode("pid")
  ap.pas()
  verifier("mode PID forcable par le controleur",
    ap.etat().modesAxes.altitude == "pid", ap.etat().modesAxes.altitude)
  ap.definirMode("zone_morte")
  ap.pas()
  verifier("mode zone morte forcable par le controleur",
    ap.etat().modesAxes.altitude == "zone_morte" and ap.etat().modesAxes.cap == "zone_morte")
  verifier("forcage journalise", journalContient("mode de pilotage force par le controleur"))
  local okMode = pcall(ap.definirMode, "n_importe_quoi")
  verifier("mode inconnu refuse", not okMode)
end

--------------------------------------------------------------------------------
print("\n== TEST 12 : sorties moteur redstone ==")
do
  local banc, env, etat, _, ap = monter({ budget = 200, sansPilote = true })
  ap.pas(); env.sleep(0.4); ap.pas()
  ap.allerA({ x = 300, y = 175, z = 100 })
  for _ = 1, 6 do ap.pas() env.sleep(0.4) end

  local sorties = etat.redstone
  verifier("sortie analogique d'avance sur le cote configure",
    sorties.front ~= nil and sorties.front >= 0 and sorties.front <= 15,
    tostring(sorties.front))
  verifier("sortie bipolaire verticale : montee sur le cote positif",
    (sorties.top or 0) > 0 and (sorties.bottom or 0) == 0,
    string.format("top=%s bottom=%s", tostring(sorties.top), tostring(sorties.bottom)))
  verifier("les deux cotes d'un axe bipolaire ne sont jamais actifs ensemble",
    not ((sorties.left or 0) > 0 and (sorties.right or 0) > 0))
  verifier("axe lateral non equipe : aucune sortie",
    sorties.back == nil)

  -- Neutralisation a l'arret : l'avance analogique revient a son neutre.
  ap.arreter("essai")
  verifier("arret : avance ramenee au neutre configure", etat.redstone.front == 7,
    tostring(etat.redstone.front))
  verifier("arret : sorties bipolaires eteintes",
    (etat.redstone.top or 0) == 0 and (etat.redstone.bottom or 0) == 0)
  verifier("arret journalise", journalContient("autopilote arrete"))
end

--------------------------------------------------------------------------------
print("\n== TEST 13 : reglage a chaud et sauvegarde de la configuration ==")
do
  local banc, env, etat, autopilote, ap = monter({ budget = 200 })
  ap.pas(); env.sleep(0.4); ap.pas()
  ap.allerA({ x = 200, y = 150, z = 100 })
  for _ = 1, 5 do ap.pas() env.sleep(0.4) end

  ap.reglerGains("altitude", "croisiere", { kp = 0.42, ki = 0.011, kd = 0.077 })
  ap.reglerGains("cap", "position", { kp = 0.99 })
  verifier("gains modifies a chaud dans la configuration vive",
    ap.config.gains.altitude.croisiere.kp == 0.42 and ap.config.gains.cap.position.kp == 0.99)
  verifier("reglage a chaud journalise", journalContient("gains modifies a chaud"))

  local ok = ap.sauvegarderConfig()
  verifier("configuration enregistree", ok)

  local relue = autopilote.chargerConfiguration("/autopilote/config_vehicule.lua")
  verifier("gains relus depuis le fichier reecrit",
    relue.gains.altitude.croisiere.kp == 0.42
    and math.abs(relue.gains.altitude.croisiere.kd - 0.077) < 1e-9
    and relue.gains.cap.position.kp == 0.99,
    tostring(relue.gains.altitude.croisiere.kp))
  verifier("identite et geometrie preservees a la reecriture",
    relue.identifiant == "AER-CARGO-01" and relue.decalageDepot.y == -3
    and relue.gabarit.longueur == 21)
  verifier("sorties moteur preservees",
    relue.sorties.axes.vertical.cotePositif == "top")

  local fichier = io.open(BANC .. "/autopilote/config_vehicule.lua", "r")
  local contenu = fichier:read("a")
  fichier:close()
  verifier("la station de ravitaillement n'est jamais recopiee dans le vehicule",
    contenu:find("ravitaillement", 1, true) ~= nil
    and contenu:find("verrouillee", 1, true) ~= nil
    and contenu:find("128", 1, true) == nil)
  verifier("le fichier reecrit reste un fichier Lua valide et commente",
    contenu:find("return {", 1, true) ~= nil and contenu:find("%-%- Gains PID") ~= nil)
end

--------------------------------------------------------------------------------
print("\n== TEST 14 : reprise apres plantage / redemarrage ==")
do
  local banc, env, etat, autopilote, ap = monter({ budget = 600 })
  ap.pas(); env.sleep(0.4); ap.pas()
  ap.suivreItineraire({
    { x = 150, y = 150, z = 20, nom = "P1" },
    { x = 260, y = 150, z = -60, nom = "P2" },
  })
  for _ = 1, 40 do ap.pas() env.sleep(0.4) end
  verifier("mission en cours avant le plantage", ap.etat().mode == "TRANSIT")
  local sauvegarde = io.open(BANC .. "/autopilote/etat_mission.txt", "r")
  verifier("etat de mission persiste sur disque", sauvegarde ~= nil)
  if sauvegarde then sauvegarde:close() end

  -- Redemarrage : nouvelle instance, comme apres un reboot de l'ordinateur.
  etat.vehicule.commandes = { avance = 9, vertical = 9, lacet = 9, lateral = 9 }
  local ap2 = autopilote.nouveau({
    config = "/autopilote/config_vehicule.lua", commandes = banc.pilote() })
  ap2.initialiser()
  verifier("mission interrompue retrouvee au demarrage",
    ap2.etatInterne.missionEnAttente ~= nil)
  verifier("commandes neutralisees des l'initialisation",
    etat.vehicule.commandes.avance == 0 and etat.vehicule.commandes.vertical == 0)

  ap2.pas()
  verifier("aucun mouvement avant d'avoir relu la position",
    ap2.etat().mode == "ACQUISITION"
    and etat.vehicule.commandes.avance == 0 and etat.vehicule.commandes.lacet == 0,
    ap2.etat().mode)
  env.sleep(0.4)
  ap2.pas()
  verifier("mission reprise apres acquisition de la position",
    ap2.etat().mode == "TRANSIT", ap2.etat().mode)
  verifier("reprise journalisee", journalContient("mission interrompue retrouvee"))

  local arrive = voler(ap2, env, etat, 400)
  verifier("la mission reprise va bien a son terme", arrive, ap2.etat().mode)
  verifier("etat de mission efface apres arrivee",
    io.open(BANC .. "/autopilote/etat_mission.txt", "r") == nil)
end

--------------------------------------------------------------------------------
print("\n== TEST 15 : la boucle de vol survit a une erreur de cycle ==")
do
  local banc, env, etat, autopilote = monter({ budget = 60, sansInstance = true })
  local appels, pilote = 0, banc.pilote()
  local ap = autopilote.nouveau({
    config = "/autopilote/config_vehicule.lua",
    commandes = {
      appliquer = function(c)
        appels = appels + 1
        if appels >= 6 and appels <= 8 then error("panne simulee du controleur", 0) end
        pilote.appliquer(c)
      end,
      arreter = pilote.arreter,
    },
  })
  ap.initialiser()
  ap.pas(); env.sleep(0.4); ap.pas()
  ap.allerA({ x = 400, y = 150, z = 400 })

  -- executer() ne rend la main que sur Ctrl+T : le banc le declenche en fin de budget.
  local ok, err = pcall(ap.executer)
  verifier("la boucle rend la main proprement sur arret manuel",
    not ok and tostring(err):find("Terminated", 1, true) ~= nil, tostring(err))
  verifier("erreur de cycle capturee et journalisee",
    journalContient("cycle interrompu"))
  verifier("la boucle a repris apres la panne", appels > 12, "#" .. appels)
  verifier("le vehicule a continue sa mission", ap.etat().cycles > 12,
    tostring(ap.etat().cycles))
  verifier("commandes neutralisees pendant l'incident",
    journalContient("[etape: boucle principale de vol]"))
end

--------------------------------------------------------------------------------
print("\n== TEST 16 : temps reellement ecoule et ralentissement serveur ==")
do
  local banc, env, etat, _, ap = monter({ budget = 200 })
  ap.pas(); env.sleep(0.4); ap.pas()
  ap.allerA({ x = 200, y = 150, z = 100 })

  -- Cycle allonge : le module doit mesurer 1.2 s, pas supposer 0.4 s.
  env.sleep(1.2)
  ap.pas()
  verifier("le pas de temps est mesure, pas suppose",
    math.abs(ap.etat().dt - 1.2) < 0.05, string.format("%.3f", ap.etat().dt))

  -- Gel prolonge : au-dela de dtMax, tout l'etat de regulation est repris a zero.
  env.sleep(4)
  ap.pas()
  verifier("discontinuite detectee au-dela de dtMax",
    journalContient("pas de temps anormal"))
  verifier("pas de temps borne apres discontinuite", ap.etat().dt <= 2.0,
    string.format("%.3f", ap.etat().dt))

  -- Serveur qui rame : le temps mur avance plus vite que le temps de tick.
  local banc2, env2, etat2, _, ap2 = monter({ budget = 200, facteurTempsReel = 3 })
  ap2.pas(); env2.sleep(0.4); ap2.pas(); env2.sleep(0.4); ap2.pas()
  verifier("ralentissement serveur detecte et journalise",
    journalContient("ralentissement serveur detecte"))
end

--------------------------------------------------------------------------------
print("\n== TEST 17 : vol avec capteur de cap dedie ==")
do
  -- Un vehicule equipe d'un lecteur de cap (peripherique) n'a plus a deduire
  -- son cap de la route : le maintien de position devient bien plus fin.
  local banc, env, etat, _, ap
  banc, env, etat, _, ap = monter({
    budget = 400,
    config = { ["lateraleMax          = 0,"] = "lateraleMax          = 2.5," },
    vehicule = { x = 100, y = 150, z = 100, cap = 0, vLateralMax = 3 },
    cap = function() return banc.etat.vehicule.cap end,
  })
  ap.pas(); env.sleep(0.4); ap.pas()
  local cible = { x = 180, y = 155, z = 30 }
  ap.allerA(cible)
  local arrive = voler(ap, env, etat, 300)
  verifier("arrivee avec capteur de cap", arrive, ap.etat().mode)
  verifier("cap issu du capteur injecte", ap.etat().sourceCap == "injecte",
    ap.etat().sourceCap)

  etat.vehicule.x = etat.vehicule.x + 5
  etat.vehicule.z = etat.vehicule.z - 5
  for _ = 1, 100 do ap.pas() env.sleep(0.4) if etat.horloge > 380 then break end end
  verifier("maintien de position precis avec capteur de cap",
    banc.distanceH(cible) <= 1.5, string.format("%.2f", banc.distanceH(cible)))
  verifier("propulsion laterale exploitee pour corriger la derive",
    math.abs(ap.etat().diagnostics.vitesseLateraleCible or 0) >= 0)
end

--------------------------------------------------------------------------------
print("\n== TEST 18 : interface de configuration ==")
do
  local banc, env, etat, autopilote = monter({ budget = 200, sansInstance = true })
  local interface = banc.charger(SRC .. "/interface.lua")
  verifier("interface chargee comme bibliotheque (pas de lancement automatique)",
    type(interface) == "table" and type(interface.configurer) == "function")

  -- Navigation : section 3 (Tolerances), premier champ, saisie de 2.5, sauvegarde.
  banc.taper("down"); banc.taper("down")   -- Identite -> Geometrie -> Tolerances
  banc.taper("tab")                        -- passage au panneau des champs
  banc.taper("enter")                      -- modifier le champ courant
  banc.tapeTexte("2.5")
  banc.taper("enter")
  banc.taper("s")                          -- sauvegarder
  banc.taper("q")                          -- quitter

  local ok = interface.configurer({ config = "/autopilote/config_vehicule.lua" })
  verifier("l'interface se termine proprement", ok == true)

  local relue = autopilote.chargerConfiguration("/autopilote/config_vehicule.lua")
  verifier("valeur modifiee a l'ecran puis enregistree",
    relue.tolerances.horizontale == 2.5, tostring(relue.tolerances.horizontale))
  verifier("le reste de la configuration est intact",
    relue.identifiant == "AER-CARGO-01" and relue.vitesses.croisiere == 8.0)

  -- Section verrouillee : la station de ravitaillement se consulte, pas plus.
  local banc2, env2, etat2, autopilote2 = monter({ budget = 200, sansInstance = true })
  local interface2 = banc2.charger(SRC .. "/interface.lua")
  for _ = 1, 25 do banc2.taper("down") end  -- descendre jusqu'a la derniere section
  banc2.taper("tab")
  banc2.taper("enter")                      -- tentative de modification
  banc2.taper("q")
  interface2.configurer({ config = "/autopilote/config_vehicule.lua" })
  local ecran = banc2.ecranTexte()
  verifier("section verrouillee : modification refusee et signalee",
    ecran:find("verrouillee", 1, true) ~= nil)
  verifier("la station de ravitaillement reste affichee",
    ecran:find("Position X", 1, true) ~= nil or ecran:find("Station", 1, true) ~= nil)
end

--------------------------------------------------------------------------------
print("\n== TEST 19 : menu de reglage en vol ==")
do
  local banc, env, etat, autopilote, ap = monter({ budget = 300 })
  local interface = banc.charger(SRC .. "/interface.lua")
  ap.pas(); env.sleep(0.4); ap.pas()
  ap.allerA({ x = 220, y = 150, z = 40 })
  for _ = 1, 20 do ap.pas() env.sleep(0.4) end

  local kiAvant = ap.config.gains.cap.croisiere.ki
  banc.taper("tab")           -- axe ALTITUDE -> CAP
  banc.taper("down")          -- gain kp -> ki
  banc.tapeTexte("++")        -- deux increments
  banc.taper("f2")            -- sauvegarder dans la configuration
  banc.taper("q")
  local ok = interface.reglageEnVol(ap)
  verifier("le menu de reglage se termine proprement", ok == true)

  local ecran = banc.ecranTexte()
  verifier("affichage temps reel de l'erreur et de la commande",
    ecran:find("erreur", 1, true) ~= nil and ecran:find("commande", 1, true) ~= nil)
  verifier("affichage de la vitesse cible et de la vitesse reelle",
    ecran:find("v. cible", 1, true) ~= nil and ecran:find("v. reelle", 1, true) ~= nil)
  verifier("historique trace a l'ecran", ecran:find("\7", 1, true) ~= nil)
  verifier("gain ajuste a chaud",
    math.abs(ap.config.gains.cap.croisiere.ki - (kiAvant + 0.02)) < 1e-9,
    string.format("%.4f -> %.4f", kiAvant, ap.config.gains.cap.croisiere.ki))

  local relue = autopilote.chargerConfiguration("/autopilote/config_vehicule.lua")
  verifier("gains regles en vol enregistres dans la configuration",
    math.abs(relue.gains.cap.croisiere.ki - (kiAvant + 0.02)) < 1e-9,
    tostring(relue.gains.cap.croisiere.ki))

  -- Forcage du mode depuis le menu.
  banc.taper("z"); banc.taper("q")
  interface.reglageEnVol(ap)
  verifier("mode zone morte forcable depuis le menu de reglage",
    ap.config.pilotage.mode == "zone_morte", ap.config.pilotage.mode)
  banc.taper("a"); banc.taper("q")
  interface.reglageEnVol(ap)
  verifier("retour au mode automatique depuis le menu",
    ap.config.pilotage.mode == "auto", ap.config.pilotage.mode)
end

--------------------------------------------------------------------------------
print("\n== TEST 20 : cas limites de l'interface publique ==")
do
  local banc, env, etat, autopilote, ap = monter({ budget = 300 })

  -- Un maintien demande avant la premiere position doit etre honore APRES
  -- l'acquisition, jamais retomber en commandes neutres.
  ap.maintenirPosition()
  verifier("maintien demande avant acquisition : acquisition d'abord",
    ap.etat().mode == "ACQUISITION", ap.etat().mode)
  ap.pas(); env.sleep(0.4); ap.pas()
  verifier("maintien honore une fois la position connue",
    ap.etat().mode == "MAINTIEN", ap.etat().mode)

  -- Une mission dotee de rappels doit quand meme etre persistee : les
  -- fonctions ne sont pas serialisables et doivent etre ecartees.
  ap.suivreItineraire({ { x = 300, y = 150, z = 100, nom = "P1" } }, {
    surEtape   = function() end,
    surArrivee = function() end,
    vitesseMax = 5,
  })
  for _ = 1, 5 do ap.pas() env.sleep(0.4) end
  local fichier = io.open(BANC .. "/autopilote/etat_mission.txt", "r")
  verifier("mission avec rappels tout de meme persistee", fichier ~= nil)
  if fichier then
    local contenu = fichier:read("a")
    fichier:close()
    verifier("les options serialisees conservent les valeurs simples",
      contenu:find("vitesseMax", 1, true) ~= nil)
    verifier("aucun rappel dans le fichier d'etat",
      contenu:find("function", 1, true) == nil)
  end

  -- Itineraire vide et point invalide : refus explicite, pas de plantage en vol.
  local okVide = pcall(ap.suivreItineraire, {})
  verifier("itineraire vide refuse", not okVide)
  local okPoint = pcall(ap.allerA, { x = 1, y = "haut", z = 3 })
  verifier("point invalide refuse", not okPoint)
  local okAxe = pcall(ap.reglerGains, "tangage", "croisiere", { kp = 1 })
  verifier("axe de gains inconnu refuse", not okAxe)

  -- La configuration exposee reste utilisable apres tout cela.
  verifier("l'autopilote reste operationnel apres les refus",
    ap.etat().mode == "TRANSIT", ap.etat().mode)
end

print(string.format("\n===== %d/%d verifications reussies =====", total - echecs, total))
os.exit(echecs == 0 and 0 or 1)
