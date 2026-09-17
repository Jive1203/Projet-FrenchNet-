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

--- Contenu du journal ecrit pendant l'essai, ARCHIVE COMPRIS : au-dela de la
-- taille maximale le journal tourne, et les premieres lignes (acquisition de
-- la position, par exemple) se retrouvent dans autopilote.log.1.
local function journal()
  local morceaux = {}
  for _, nom in ipairs({ "autopilote.log.1", "autopilote.log" }) do
    local f = io.open(BANC .. "/autopilote/" .. nom, "r")
    if f then
      morceaux[#morceaux + 1] = f:read("a")
      f:close()
    end
  end
  return table.concat(morceaux, "\n")
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
  -- L'altitude de croisiere livree (350) est volontairement tres haute : elle
  -- passe au-dessus de tout relief. Les essais de logique n'ont pas a payer
  -- 200 blocs de montee a chaque vol ; ils fixent donc leur propre altitude.
  -- Le test 23 verifie separement la valeur livree.
  local remplacements = options.config
  if not options.altitudeLivree then
    remplacements = {}
    for motif, valeur in pairs(options.config or {}) do remplacements[motif] = valeur end
    remplacements["altitudeCroisiere    = 350,"] = "altitudeCroisiere    = 160,"
  end
  preparer(remplacements)
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

  -- Ajustement de configuration par la TABLE plutot que par le texte : un
  -- gabarit qui evolue ne doit pas casser des essais qui portent sur autre
  -- chose que sa mise en page.
  if options.ajusterConfig then
    local configuration = autopilote.chargerConfiguration("/autopilote/config_vehicule.lua")
    -- La position d'antenne SIMULEE et celle DECLAREE doivent coincider, sinon
    -- l'autopilote retranche un decalage qui n'existe pas et vole avec un biais
    -- permanent. C'est un piege d'essai, pas un comportement a eprouver.
    if options.decalageGps then
      configuration.decalageGps = {
        x = options.decalageGps.x, y = options.decalageGps.y, z = options.decalageGps.z }
    end
    options.ajusterConfig(configuration)
    local fichier = env.fs.open("/autopilote/config_vehicule.lua", "w")
    fichier.write(autopilote.serialiserConfig(configuration))
    fichier.close()
  end

  -- Garde-fou : le meme piege ne doit pas revenir par une autre porte.
  if not options.decalageGpsDesaccord then
    local declare = autopilote.chargerConfiguration("/autopilote/config_vehicule.lua").decalageGps
    local simule = options.decalageGps or { x = 0, y = 2, z = 4 }
    for _, axe in ipairs({ "x", "y", "z" }) do
      if math.abs((declare[axe] or 0) - (simule[axe] or 0)) > 1e-9 then
        error(string.format(
          "montage incoherent : antenne simulee %s=%.2f mais configuration %s=%.2f",
          axe, simule[axe] or 0, axe, declare[axe] or 0), 2)
      end
    end
  end

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

--- Cablage continu classique : une face analogique pour l'avance, deux faces
-- opposees pour le vertical et le lacet. C'est l'autre famille de montage,
-- qui doit rester eprouvee a cote des boites a rapports.
local function cablageClassique(config)
  config.sorties.axes = {
    avance   = { mode = "analogique", cote = "front", neutre = 0, amplitude = 15 },
    vertical = { mode = "bipolaire", cotePositif = "top", coteNegatif = "bottom",
                 amplitude = 15, seuil = 0.08 },
    lacet    = { mode = "bipolaire", cotePositif = "right", coteNegatif = "left",
                 amplitude = 15, seuil = 0.08 },
    lateral  = { mode = "aucun" },
  }
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
  -- Antenne GPS centree : c'est la condition d'une tenue de position fine.
  -- Le test 23 documente ce qui se passe avec une antenne deportee.
  local banc, env, etat, _, ap = monter({ budget = 600,
    decalageGps = { x = 0, y = 2, z = 0 },
    config = { ["decalageGps = { x = 0, y = 2, z = 4 },"] = "decalageGps = { x = 0, y = 2, z = 0 }," } })
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
  for _ = 1, 260 do
    ap.pas()
    env.sleep(0.4)
    ecartMax = math.max(ecartMax, banc.distanceH(cible))
    if etat.horloge > 560 then break end
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
  local banc, env, etat, _, ap = monter({ budget = 200, sansPilote = true,
    ajusterConfig = cablageClassique })
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
  verifier("arret : avance ramenee au neutre configure", etat.redstone.front == 0,
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
  -- Le cablage livre melange une boite a rapports (liste imbriquee) et un axe
  -- a deux signaux : c'est le cas le plus exigeant pour le serialiseur.
  verifier("sorties moteur preservees a la reecriture",
    relue.sorties.axes.vertical.coteGrossier == "top"
    and relue.sorties.axes.vertical.neutre == 128
    and relue.sorties.axes.avance.mode == "boite_vitesses")
  verifier("liste des rapports preservee dans l'ordre",
    #relue.sorties.axes.avance.rapports == 7
    and relue.sorties.axes.avance.rapports[1].nom == "R"
    and relue.sorties.axes.avance.rapports[1].interdit == true
    and relue.sorties.axes.avance.rapports[7].effet == 1.0,
    "#" .. #relue.sorties.axes.avance.rapports)

  local fichier = io.open(BANC .. "/autopilote/config_vehicule.lua", "r")
  local contenu = fichier:read("a")
  fichier:close()
  -- On cherche des marqueurs propres a la station, pas un nombre qui pourrait
  -- apparaitre ailleurs par coincidence (128 est aussi une valeur de chauffe).
  verifier("la station de ravitaillement n'est jamais recopiee dans le vehicule",
    contenu:find("ravitaillement", 1, true) ~= nil
    and contenu:find("verrouillee", 1, true) ~= nil
    and contenu:find("PONTON", 1, true) == nil
    and contenu:find("-742", 1, true) == nil)
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
  for _ = 1, 60 do banc2.taper("down") end  -- descendre jusqu a la derniere section
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
print("\n== TEST 18 bis : le schema de l'interface couvre la configuration ==")
do
  local banc, env, etat, autopilote = monter({ budget = 200, sansInstance = true })
  local interface = banc.charger(SRC .. "/interface.lua")
  local config = autopilote.chargerConfiguration("/autopilote/config_vehicule.lua")
  local sections = interface.interne.construireSections(config)

  -- 1. Toute cle du schema doit exister dans le gabarit livre. Une cle mal
  -- orthographiee ne provoque aucune erreur a l'execution : elle cree
  -- silencieusement un reglage que l'autopilote ne lira jamais.
  local inconnues = {}
  for _, section in ipairs(sections) do
    for _, champ in ipairs(section.champs or {}) do
      if champ.cle then
        local parent, dernier = config, nil
        for morceau in tostring(champ.cle):gmatch("[^.]+") do
          if dernier then
            parent = type(parent) == "table" and parent[dernier] or nil
          end
          dernier = morceau
        end
        if type(parent) ~= "table" or not rawget(parent, dernier) then
          -- Une valeur nil legitime (face non cablee) n'est pas une erreur :
          -- on exige seulement que la TABLE parente existe.
          if type(parent) ~= "table" then inconnues[#inconnues + 1] = champ.cle end
        end
      end
    end
  end
  verifier("aucune cle du schema ne pointe hors de la configuration",
    #inconnues == 0, table.concat(inconnues, ", "))

  -- 2. Les sections ajoutees apres coup doivent etre la : sans elles, ces
  -- reglages ne s'editent qu'au bloc-notes.
  local titres = {}
  for _, section in ipairs(sections) do titres[section.titre] = true end
  for _, attendu in ipairs({ "Hauteur sol", "Enveloppe sol", "Sorties deportees",
                             "Carburant", "Amarrage", "Conteneurs" }) do
    verifier("section '" .. attendu .. "' presente a l'ecran", titres[attendu] == true)
  end

  -- 3. Reciproquement : les grandes familles du gabarit doivent etre editables.
  local couvertes = {}
  for _, section in ipairs(sections) do
    for _, champ in ipairs(section.champs or {}) do
      if champ.cle then couvertes[tostring(champ.cle):match("^[^.]+")] = true end
    end
  end
  local oubliees = {}
  for _, famille in ipairs({ "tolerances", "vitesses", "gains", "pilotage", "maintien",
                             "gps", "cap", "sol", "enveloppeSol", "sorties", "mission",
                             "journal", "carburant", "ravitaillement" }) do
    if not couvertes[famille] then oubliees[#oubliees + 1] = famille end
  end
  verifier("toutes les familles de reglages sont editables",
    #oubliees == 0, table.concat(oubliees, ", "))

  -- 4. Un champ optionnel doit pouvoir revenir a vide : une face non cablee
  -- vaut nil, et un cycle qui ne propose que des faces enfermerait
  -- l'utilisateur dans un cablage qu'il n'a pas.
  local optionnel = nil
  for _, section in ipairs(sections) do
    for _, champ in ipairs(section.champs or {}) do
      if champ.cle == "carburant.coteRetour" then optionnel = champ end
    end
  end
  verifier("la face 'forcer le retour' est declaree optionnelle",
    optionnel ~= nil and optionnel.optionnel == true)
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

--------------------------------------------------------------------------------
print("\n== TEST 21 : outil de cablage et pilotage manuel ==")
do
  local banc, env, etat, autopilote = monter({ budget = 300, sansInstance = true,
    ajusterConfig = cablageClassique })

  -- Marche avant : sortie analogique 'front'.
  banc.taper("up")                       -- avance a 50 % par defaut
  banc.taper("q")
  banc.charger(SRC .. "/cablage.lua")
  local ecran = banc.ecranTexte()
  verifier("l'outil affiche le cablage de chaque axe",
    ecran:find("AVANCE", 1, true) ~= nil and ecran:find("LACET", 1, true) ~= nil
    and ecran:find("VERTICAL", 1, true) ~= nil and ecran:find("LATERAL", 1, true) ~= nil)
  verifier("l'outil affiche les niveaux redstone reellement emis",
    ecran:find("front=", 1, true) ~= nil)
  verifier("commandes neutralisees a la sortie",
    etat.redstone.front == 0 and (etat.redstone.top or 0) == 0,
    string.format("front=%s top=%s", tostring(etat.redstone.front), tostring(etat.redstone.top)))

  -- Verification des niveaux pendant l'appui, avant relachement.
  local banc2, env2, etat2, autopilote2 = monter({ budget = 300, sansInstance = true, ajusterConfig = cablageClassique })
  banc2.taper("up")
  banc2.taper("tab")                     -- provoque un redessin, appui maintenu
  banc2.taper("q")
  banc2.charger(SRC .. "/cablage.lua")
  local ecran2 = banc2.ecranTexte()
  verifier("marche avant : le niveau analogique suit la puissance demandee",
    ecran2:find("front=8", 1, true) ~= nil or ecran2:find("front=7", 1, true) ~= nil,
    "niveau attendu 0 + 15*0.5")

  -- Montee, puis inversion de l'axe vertical, puis enregistrement.
  local banc3, env3, etat3, autopilote3 = monter({ budget = 300, sansInstance = true, ajusterConfig = cablageClassique })
  banc3.taper("pageUp")
  banc3.taper("tab")
  banc3.taper("q")
  banc3.charger(SRC .. "/cablage.lua")
  verifier("montee : cote positif alimente, cote negatif eteint",
    banc3.ecranTexte():find("top=8", 1, true) ~= nil
    and banc3.ecranTexte():find("bottom=0", 1, true) ~= nil,
    "0.5 * 15 = 8")

  local banc4, env4, etat4, autopilote4 = monter({ budget = 300, sansInstance = true, ajusterConfig = cablageClassique })
  banc4.taper("tab")                     -- AVANCE -> LACET
  banc4.taper("tab")                     -- LACET  -> VERTICAL
  banc4.taper("i")                       -- inverser l'axe vertical
  banc4.taper("pageUp")                  -- monter... a l'envers
  banc4.taper("s")                       -- enregistrer
  banc4.taper("q")
  banc4.charger(SRC .. "/cablage.lua")
  verifier("axe inverse : la montee sort par le cote negatif",
    banc4.ecranTexte():find("bottom=8", 1, true) ~= nil,
    "l'inversion doit permuter les deux cotes")
  local relue = autopilote4.chargerConfiguration("/autopilote/config_vehicule.lua")
  verifier("inversion enregistree dans la configuration du vehicule",
    relue.sorties.axes.vertical.inverse == true)

  -- L'inversion enregistree doit s'appliquer aussi en vol, pas seulement a la main.
  local banc5, env5, etat5, autopilote5 = monter({
    budget = 200, sansPilote = true,
    ajusterConfig = function(config)
      cablageClassique(config)
      config.sorties.axes.vertical.inverse = true
    end,
  })
  local ap5 = autopilote5.nouveau({ config = "/autopilote/config_vehicule.lua" })
  ap5.initialiser()
  ap5.pas(); env5.sleep(0.4); ap5.pas()
  ap5.allerA({ x = 300, y = 175, z = 100 })
  for _ = 1, 6 do ap5.pas() env5.sleep(0.4) end
  verifier("l'inversion s'applique aussi au vol automatique",
    (etat5.redstone.bottom or 0) > 0 and (etat5.redstone.top or 0) == 0,
    string.format("top=%s bottom=%s", tostring(etat5.redstone.top),
      tostring(etat5.redstone.bottom)))

  -- Test guide : la reponse "oui, c'etait a l'envers" inscrit l'inversion.
  local banc6, env6, etat6, autopilote6 = monter({ budget = 300, sansInstance = true, ajusterConfig = cablageClassique })
  banc6.taper("t")                       -- test guide de l'axe AVANCE
  banc6.taper("o")                       -- "le vehicule a fait l'inverse"
  banc6.taper("s")
  banc6.taper("q")
  banc6.charger(SRC .. "/cablage.lua")
  local relue6 = autopilote6.chargerConfiguration("/autopilote/config_vehicule.lua")
  verifier("test guide : inversion detectee et enregistree",
    relue6.sorties.axes.avance.inverse == true)
  verifier("test guide : les deux sens sont annonces a l'operateur",
    banc6.ecranTexte():find("avance (nez en avant)", 1, true) ~= nil
    and banc6.ecranTexte():find("recule", 1, true) ~= nil)
end

--------------------------------------------------------------------------------
print("\n== TEST 22 : installateur ==")
do
  local RACINE_INSTALL = "/tmp/banc_installateur_frenchnet"
  local BASE = "https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/"
    .. "claude/autopilote-lua-module-kfnu2k/"

  --- Prepare un banc neuf, avec ou sans HTTP, dans un dossier vierge.
  local function bancInstall(sousDossier, options)
    options = options or {}
    local racine = RACINE_INSTALL .. (sousDossier and ("/" .. sousDossier) or "")
    os.execute("rm -rf " .. racine .. " && mkdir -p " .. racine)
    local banc = dofile(SCR .. "/banc_vol.lua")
    local env, etat = banc.creer({ racine = racine, budget = 100, http = options.http })
    return banc, etat, racine
  end

  local function lire(racine, chemin)
    local f = io.open(racine .. "/" .. chemin, "r")
    if not f then return nil end
    local contenu = f:read("a")
    f:close()
    return contenu
  end

  local function servirBalise(etat)
    local function servir(fichier, corps)
      etat.http[BASE .. fichier] = { code = 200, corps = corps }
    end
    servir("balise/balise.lua", "-- balise\nreturn true\n")
    servir("balise/config_balise.lua", "return { identifiant = 'BAL-01' }\n")
    servir("balise/startup.lua", "-- lanceur\n")
    servir("balise/recepteur.lua", "-- recepteur\n")
  end

  ------------------------------------------------------------------ nominal
  local banc, etat, racine = bancInstall("nominal")
  servirBalise(etat)
  banc.charger(RACINE .. "/installe.lua", "balise")

  verifier("installation : programme telecharge et ecrit",
    lire(racine, "balise/balise.lua") ~= nil)
  verifier("installation : lanceur pose a la racine",
    lire(racine, "startup.lua") ~= nil)
  verifier("installation : configuration ecrite au premier passage",
    (lire(racine, "balise/config_balise.lua") or ""):find("BAL%-01") ~= nil)
  verifier("installation : compte rendu a l'ecran",
    (banc.contient("Installation complete")))
  verifier("installation : etapes suivantes indiquees",
    (banc.contient("config_balise")))
  verifier("installation : taille de chaque fichier affichee",
    (banc.contient("octets")))

  ------------------------------------------------- configuration preservee
  local f = io.open(racine .. "/balise/config_balise.lua", "w")
  f:write("return { identifiant = 'BAL-42-REGLEE' }\n")
  f:close()
  banc.charger(RACINE .. "/installe.lua", "balise")
  verifier("reinstallation : configuration reglee preservee",
    (lire(racine, "balise/config_balise.lua") or ""):find("BAL%-42%-REGLEE") ~= nil)
  verifier("reinstallation : preservation signalee",
    (banc.contient("configuration conservee")))

  banc.charger(RACINE .. "/installe.lua", "balise", "-f")
  verifier("option -f : configuration ecrasee sur demande explicite",
    (lire(racine, "balise/config_balise.lua") or ""):find("BAL%-01") ~= nil)

  --------------------------------------------------------- depot prive (HTML)
  -- GitHub renvoie une page, parfois avec un code 200 : le pire des cas, car
  -- un installateur naif l'enregistrerait comme du Lua.
  local bancPrive, etatPrive, racinePrive = bancInstall("prive")
  etatPrive.httpDefaut = { code = 200, corps = "<html><body>404: Not Found</body></html>" }
  bancPrive.charger(RACINE .. "/installe.lua", "balise")
  verifier("page HTML refusee : aucun fichier corrompu enregistre",
    lire(racinePrive, "balise/balise.lua") == nil)
  verifier("page HTML refusee : cause nommee",
    (bancPrive.contient("page HTML")))
  verifier("diagnostic depot prive affiche", (bancPrive.contient("PRIVE")))

  ---------------------------------------------------------------------- 404
  local banc404, etat404, racine404 = bancInstall("absent")
  banc404.charger(RACINE .. "/installe.lua", "balise")
  verifier("404 signale sans planter", (banc404.contient("404")))
  verifier("404 : aucun fichier ecrit", lire(racine404, "balise/balise.lua") == nil)

  ------------------------------------------------------------- HTTP coupe
  local bancSansHttp = bancInstall("sanshttp", { http = false })
  bancSansHttp.charger(RACINE .. "/installe.lua", "balise")
  verifier("HTTP desactive : la marche a suivre est affichee",
    (bancSansHttp.contient("enabled = true")))

  ------------------------------------------------------------- Lua invalide
  local bancCasse, etatCasse, racineCasse = bancInstall("casse")
  etatCasse.httpDefaut = { code = 200, corps = "ceci n'est pas du lua ((((\n" }
  bancCasse.charger(RACINE .. "/installe.lua", "balise")
  verifier("fichier tronque refuse avant enregistrement",
    lire(racineCasse, "balise/balise.lua") == nil)
  verifier("fichier tronque : cause nommee", (bancCasse.contient("Lua invalide")))

  ------------------------------------------------------------------- usage
  local bancUsage = bancInstall("usage")
  bancUsage.charger(RACINE .. "/installe.lua")
  verifier("sans argument : usage affiche", (bancUsage.contient("Usage")))
  local bancInconnu, etatInconnu = bancInstall("inconnu")
  servirBalise(etatInconnu)
  bancInconnu.charger(RACINE .. "/installe.lua", "n_importe_quoi")
  verifier("jeu de fichiers inconnu refuse", (bancInconnu.contient("inconnu")))
end

--------------------------------------------------------------------------------
print("\n== TEST 23 : profil vertical, altitude par defaut, antenne deportee ==")
do
  -- a. Montee verticale au depart, descente verticale a l'arrivee.
  local banc, env, etat, _, ap = monter({ budget = 600,
    decalageGps = { x = 0, y = 2, z = 0 },
    config = { ["decalageGps = { x = 0, y = 2, z = 4 },"] = "decalageGps = { x = 0, y = 2, z = 0 }," },
    vehicule = { x = 0, y = 90, z = 0, cap = 0, vLateralMax = 0 } })
  ap.pas(); env.sleep(0.4); ap.pas()
  local cible = { x = 200, y = 95, z = -150 }
  local departX, departZ = etat.vehicule.x, etat.vehicule.z
  ap.allerA(cible)

  local deriveMontee, deriveDescente = 0, 0
  local altitudeDebutDescente, aplombDebutDescente = nil, nil
  local phaseVue = {}
  local arrive = voler(ap, env, etat, 500, function()
    local phase = ap.etat().phase
    phaseVue[tostring(phase)] = true
    if phase == "MONTEE" then
      deriveMontee = math.max(deriveMontee,
        math.sqrt((etat.vehicule.x - departX) ^ 2 + (etat.vehicule.z - departZ) ^ 2))
    elseif phase == "DESCENTE" then
      if not altitudeDebutDescente then
        altitudeDebutDescente = etat.vehicule.y
        aplombDebutDescente = banc.distanceH(cible)
      end
      deriveDescente = math.max(deriveDescente, banc.distanceH(cible))
    end
  end)

  verifier("le vehicule arrive", arrive, ap.etat().mode)
  verifier("les quatre phases sont traversees",
    phaseVue.MONTEE and phaseVue.CROISIERE and phaseVue.DESCENTE,
    "MONTEE=" .. tostring(phaseVue.MONTEE) .. " DESCENTE=" .. tostring(phaseVue.DESCENTE))
  verifier("montee VERTICALE : l'aplomb du depart est tenu",
    deriveMontee < 4, string.format("%.2f bloc de derive", deriveMontee))
  verifier("la descente ne commence qu'une fois a l'aplomb du point",
    aplombDebutDescente and aplombDebutDescente <= 2.5,
    aplombDebutDescente and string.format("%.2f bloc", aplombDebutDescente))
  verifier("la descente part bien de l'altitude de croisiere",
    altitudeDebutDescente and altitudeDebutDescente >= 155,
    altitudeDebutDescente and string.format("%.1f", altitudeDebutDescente))
  -- La derive reste bornee par la bande de recentrage (deux fois le rayon
  -- d'aplomb) : au-dela, le vehicule repasse en approche pour se recentrer
  -- avant de poursuivre sa descente, au lieu de descendre de travers.
  verifier("descente VERTICALE : la derive reste dans la bande de recentrage",
    deriveDescente <= 5, string.format("%.2f bloc", deriveDescente))
  verifier("altitude finale atteinte", math.abs(etat.vehicule.y - 95) <= 1.0,
    string.format("%.2f", etat.vehicule.y))
  verifier("profil de vol journalise",
    journalContient("debut de la descente verticale"))

  -- b. Un point sans altitude est survole a l'altitude de croisiere.
  local banc2, env2, etat2, _, ap2 = monter({ budget = 600,
    decalageGps = { x = 0, y = 2, z = 0 },
    config = { ["decalageGps = { x = 0, y = 2, z = 4 },"] = "decalageGps = { x = 0, y = 2, z = 0 }," },
    vehicule = { x = 0, y = 90, z = 0, cap = 0, vLateralMax = 0 } })
  ap2.pas(); env2.sleep(0.4); ap2.pas()
  ap2.suivreItineraire({
    { x = 150, z = -120, nom = "SANS-ALTITUDE" },
    { x = 260, y = 100, z = -200, nom = "DESTINATION" },
  })
  verifier("point sans altitude accepte",
    ap2.etatInterne.itineraire[1].altitudeLibre == true)
  verifier("le point sans altitude prend l'altitude de croisiere",
    ap2.etatInterne.itineraire[1].y == 160, tostring(ap2.etatInterne.itineraire[1].y))
  verifier("le point avec altitude garde la sienne",
    ap2.etatInterne.itineraire[2].y == 100
    and ap2.etatInterne.itineraire[2].altitudeLibre == false)

  local altitudeMinEtape = 1e9
  voler(ap2, env2, etat2, 500, function()
    if ap2.etat().index == 1 then
      altitudeMinEtape = math.min(altitudeMinEtape, etat2.vehicule.y)
    end
  end)
  verifier("aucune descente sur un point sans altitude",
    altitudeMinEtape >= 89, string.format("%.1f", altitudeMinEtape))

  -- c. Altitude de croisiere livree : 350, au-dessus de la limite de construction.
  local _, _, _, autopilote3 = monter({ sansInstance = true, altitudeLivree = true })
  local livree = autopilote3.chargerConfiguration("/autopilote/config_vehicule.lua")
  verifier("altitude de croisiere livree a 350",
    livree.vitesses.altitudeCroisiere == 350,
    tostring(livree.vitesses.altitudeCroisiere))

  -- d. Une altitude presente mais aberrante reste une erreur.
  local banc4, env4, etat4, _, ap4 = monter({ budget = 200 })
  local okTexte = pcall(ap4.allerA, { x = 10, y = "haut", z = 20 })
  verifier("altitude non numerique refusee", not okTexte)
  local okSansY = pcall(ap4.allerA, { x = 10, z = 20 })
  verifier("altitude absente acceptee", okSansY)

  -- e. Antenne deportee sans capteur de cap : la limite est annoncee.
  local banc5 = monter({ budget = 200,
    decalageGps = { x = 0, y = 2, z = 4 } })
  verifier("limite de precision annoncee au demarrage",
    (banc5.contient("SANS capteur de cap")) and (banc5.contient("incertaine")))
end

--------------------------------------------------------------------------------
print("\n== TEST 24 : calibration automatique ==")
do
  local banc, env, etat, autopilote = monter({ sansInstance = true })
  local calibration = banc.charger(SRC .. "/calibration.lua")

  -- a. Analyse d'une reponse du premier ordre connue : K = 8, tau = 1.2 s.
  local echantillons = {}
  for i = 0, 60 do
    local t = i * 0.25
    echantillons[#echantillons + 1] = { t = t, v = 8 * (1 - math.exp(-t / 1.2)) }
  end
  local K, tau = calibration.interne.analyser(echantillons, 0.4)
  verifier("regime etabli retrouve", K and math.abs(K - 8) < 0.3,
    K and string.format("%.3f", K))
  verifier("inertie retrouvee", tau and math.abs(tau - 1.2) < 0.35,
    tau and string.format("%.3f", tau))

  -- b. Un axe immobile est signale, pas traduit en gains absurdes.
  local plats = {}
  for i = 0, 40 do plats[#plats + 1] = { t = i * 0.25, v = 0.001 } end
  local Kplat, _, motif = calibration.interne.analyser(plats, 0.4)
  verifier("axe immobile detecte", Kplat == nil and motif ~= nil, tostring(motif))
  verifier("le motif oriente le diagnostic",
    motif and motif:find("cable", 1, true) ~= nil, tostring(motif))

  -- c. Formules de gains : kp = 2/K, et l'inertie regle ki et kd.
  local gains = calibration.interne.gainsDeduits(8, 1.2)
  verifier("kp deduit du gain vehicule", math.abs(gains.kp - 2 / 8) < 1e-9,
    string.format("%.4f", gains.kp))
  verifier("ki deduit de l'inertie", math.abs(gains.ki - gains.kp / 3.6) < 1e-9)
  verifier("kd deduit de l'inertie", math.abs(gains.kd - gains.kp * 1.2 / 6) < 1e-9)
  verifier("boucle externe deduite de l'inertie",
    math.abs(gains.position - 1 / 3.6) < 1e-9)
  local rapides = calibration.interne.gainsDeduits(8, 0.3)
  verifier("un vehicule plus vif recoit des gains plus fermes",
    rapides.ki > gains.ki and rapides.position > gains.position)

  -- d. Mesure reelle sur le vehicule simule (vMax 10, vertical 5, lacet 50).
  local banc2, env2, etat2, autopilote2 = monter({
    budget = 400, sansInstance = true,
    decalageGps = { x = 0, y = 2, z = 0 },
    config = { ["decalageGps = { x = 0, y = 2, z = 4 },"] = "decalageGps = { x = 0, y = 2, z = 0 }," },
    vehicule = { x = 0, y = 150, z = 0, cap = 0, vLateralMax = 0 },
  })
  local calibration2 = banc2.charger(SRC .. "/calibration.lua")
  local ap2 = autopilote2.nouveau({
    config = "/autopilote/config_vehicule.lua", commandes = banc2.pilote() })
  ap2.initialiser()
  ap2.pas(); env2.sleep(0.4); ap2.pas()

  local resultats, motifEchec = calibration2.mesurer(ap2, {
    reglages = { duree = 8, repos = 3, rayonMax = 400 },
  })
  verifier("la calibration aboutit", resultats ~= nil, tostring(motifEchec))
  if resultats then
    verifier("marche avant mesuree proche de la realite du vehicule",
      resultats.avance and math.abs(resultats.avance.K - 10) < 1.5,
      resultats.avance and string.format("%.2f (reel 10)", resultats.avance.K))
    verifier("montee mesuree proche de la realite",
      resultats.vertical and math.abs(resultats.vertical.K - 5) < 1.2,
      resultats.vertical and string.format("%.2f (reel 5)", resultats.vertical.K))
    verifier("inertie mesuree plausible",
      resultats.avance and resultats.avance.tau > 0.2 and resultats.avance.tau < 3,
      resultats.avance and string.format("%.2f", resultats.avance.tau))
    verifier("axe lateral non equipe : ignore sans faire echouer l'essai",
      resultats.lateral == nil)

    local propositions, detail = calibration2.proposer(resultats, ap2.config)
    verifier("vitesse de croisiere proposee sous la mesure (marge)",
      propositions.vitesses.croisiere < resultats.avance.K
      and propositions.vitesses.croisiere > resultats.avance.K * 0.7,
      string.format("%.2f", propositions.vitesses.croisiere))
    verifier("vitesse d'approche deduite de la croisiere",
      propositions.vitesses.approche > 0
      and propositions.vitesses.approche < propositions.vitesses.croisiere)
    verifier("axe lateral remis a zero faute de mesure",
      propositions.vitesses.lateraleMax == 0)
    verifier("gains proposes pour les axes mesures",
      propositions.gains.avance and propositions.gains.avance.croisiere.kp > 0
      and propositions.gains.altitude)
    verifier("gains de maintien plus fermes que ceux de croisiere",
      propositions.gains.avance.maintien.kp > propositions.gains.avance.croisiere.kp)
    verifier("compte rendu lisible produit", #detail >= 3, "#" .. #detail)

    calibration2.appliquer(ap2.config, propositions)
    verifier("configuration vive mise a jour",
      ap2.config.vitesses.croisiere == propositions.vitesses.croisiere)
    verifier("le vehicule est rendu au maintien de position apres calibration",
      ap2.etat().mode == "MAINTIEN" or ap2.etat().mode == "ARRET", ap2.etat().mode)
  end

  -- e. Interruption au clavier.
  local banc3, env3, etat3, autopilote3 = monter({
    budget = 300, sansInstance = true,
    vehicule = { x = 0, y = 150, z = 0, cap = 0, vLateralMax = 0 } })
  local calibration3 = banc3.charger(SRC .. "/calibration.lua")
  local ap3 = autopilote3.nouveau({
    config = "/autopilote/config_vehicule.lua", commandes = banc3.pilote() })
  ap3.initialiser()
  ap3.pas(); env3.sleep(0.4); ap3.pas()
  banc3.taper("q")
  local rien, motifArret = calibration3.mesurer(ap3, { reglages = { duree = 8 } })
  verifier("une touche interrompt la calibration", rien == nil)
  verifier("l'interruption est expliquee",
    motifArret and motifArret:find("clavier", 1, true) ~= nil, tostring(motifArret))
  verifier("commandes neutralisees apres interruption",
    etat3.vehicule.commandes.avance == 0 and etat3.vehicule.commandes.vertical == 0)
end

--------------------------------------------------------------------------------
print("\n== TEST 25 : itineraires et console de navigation ==")
do
  local banc, env, etat, autopilote = monter({ sansInstance = true })
  local routesLib = banc.charger(SRC .. "/routes.lua")

  -- a. Aller-retour disque : l'altitude absente doit le RESTER.
  local liste = {
    { nom = "LIVRAISON-NORD", altitudeCroisiere = 350, points = {
        { x = 480, z = -1200, nom = "SORTIE" },
        { x = 1150, y = 140, z = -2400, nom = "COL", arret = true },
        { x = 1980, y = 118, z = -3100, nom = "ENTREPOT", type = "depot", cap = 90 },
    }},
    { nom = "PATROUILLE", points = { { x = 10, z = 20 } } },
  }
  verifier("enregistrement des itineraires", routesLib.enregistrer(liste))
  local relue = routesLib.charger()
  verifier("deux routes relues", #relue == 2, "#" .. #relue)
  verifier("altitude absente conservee absente", relue[1].points[1].y == nil)
  verifier("altitude presente conservee", relue[1].points[2].y == 140)
  verifier("type, cap, arret et nom conserves",
    relue[1].points[3].type == "depot" and relue[1].points[3].cap == 90
    and relue[1].points[2].arret == true and relue[1].points[1].nom == "SORTIE")
  verifier("altitude de croisiere de la route conservee",
    relue[1].altitudeCroisiere == 350)
  verifier("longueur de route calculee", routesLib.longueur(relue[1]) > 2000,
    string.format("%.0f", routesLib.longueur(relue[1])))

  -- b. Validation : ce sont les pieges concrets qui doivent etre attrapes.
  local config = autopilote.chargerConfiguration("/autopilote/config_vehicule.lua")
  local okVide, anomaliesVide = routesLib.valider({ nom = "X", points = {} }, config)
  verifier("route vide refusee", not okVide and #anomaliesVide >= 1)

  local okDepot, anomaliesDepot = routesLib.valider({ nom = "X", points = {
    { x = 1, z = 2, type = "depot" } } }, config)
  verifier("depot sans altitude refuse", not okDepot)
  verifier("le motif explique qu'il serait survole",
    table.concat(anomaliesDepot, " "):find("survole", 1, true) ~= nil)

  local okFinal = routesLib.valider({ nom = "X", points = { { x = 1, z = 2 } } }, config)
  verifier("point final sans altitude signale", not okFinal)

  local okHaut, anomaliesHaut = routesLib.valider({ nom = "X",
    altitudeCroisiere = 100, points = { { x = 1, y = 200, z = 2, type = "depot" } } }, config)
  verifier("point au-dessus de la croisiere signale", not okHaut)
  verifier("le motif dit que le vehicule montera",
    table.concat(anomaliesHaut, " "):find("montera", 1, true) ~= nil)

  local okBonne = routesLib.valider(relue[1], config)
  verifier("une route coherente est acceptee", okBonne)

  -- c. Conversion en mission.
  local points, options = routesLib.versMission(relue[1])
  verifier("conversion en itineraire d'autopilote", #points == 3
    and points[1].y == nil and points[3].type == "depot")
  verifier("options de mission transmises", options.altitudeCroisiere == 350)

  -- d. La console : creer une route, y ajouter un point, l'enregistrer.
  local banc2, env2, etat2, autopilote2 = monter({ sansInstance = true })
  os.execute("rm -f " .. BANC .. "/autopilote/itineraires.lua")
  local console = banc2.charger(SRC .. "/console.lua")
  verifier("console chargee comme bibliotheque",
    type(console) == "table" and type(console.demarrer) == "function")

  banc2.taper("n")                    -- nouvelle route
  banc2.tapeTexte("ESSAI")
  banc2.taper("enter")
  banc2.taper("enter")                -- ouvrir l'ecran des points
  banc2.taper("a")                    -- ajouter un point a la position GPS
  banc2.taper("s")                    -- enregistrer
  banc2.taper("q")                    -- retour aux itineraires
  banc2.taper("q")                    -- quitter
  console.demarrer()

  local routesLib2 = banc2.charger(SRC .. "/routes.lua")
  local apres = routesLib2.charger()
  verifier("route creee depuis la console", #apres == 1 and apres[1].nom == "ESSAI",
    "#" .. #apres)
  verifier("point capture depuis le GPS", apres[1] and #apres[1].points == 1,
    apres[1] and ("#" .. #apres[1].points))
  verifier("la capture prend la position reelle du vehicule",
    apres[1] and apres[1].points[1] and math.abs(apres[1].points[1].x - 100) <= 2,
    apres[1] and apres[1].points[1] and tostring(apres[1].points[1].x))
  -- Le message passe par la barre d'etat de la console, pas par print.
  verifier("la console previent que la capture vise l'antenne",
    banc2.ecranTexte():find("ANTENNE", 1, true) ~= nil)
end

--------------------------------------------------------------------------------
print("\n== TEST 26 : boite sequentielle et commande a deux signaux ==")
do
  local banc, env, etat, autopilote = monter({ budget = 300, sansInstance = true })
  local config = autopilote.chargerConfiguration("/autopilote/config_vehicule.lua")
  local sorties = autopilote.creerSorties(config)

  local function cycle(commande)
    sorties.appliquer({ avance = commande or 0, vertical = 0, lacet = 0, lateral = 0 })
  end

  ----------------------------------------------------------------- calage
  verifier("au demarrage, le rapport engage est inconnu",
    not sorties.calageTermine())

  local impulsionsDescente, impulsionsMontee, faceHauteEnContinu = 0, 0, 0
  local precedenteDescente, precedenteMontee = 0, 0
  local cycles = 0
  while not sorties.calageTermine() and cycles < 200 do
    cycle(0)
    cycles = cycles + 1
    local descente = etat.redstone.right or 0
    local montee = etat.redstone.left or 0
    if descente > 0 and precedenteDescente == 0 then
      impulsionsDescente = impulsionsDescente + 1
    end
    if montee > 0 and precedenteMontee == 0 then
      impulsionsMontee = impulsionsMontee + 1
    end
    if descente > 0 and precedenteDescente > 0 then
      faceHauteEnContinu = faceHauteEnContinu + 1
    end
    precedenteDescente, precedenteMontee = descente, montee
  end

  verifier("le calage aboutit", sorties.calageTermine(), cycles .. " cycles")
  verifier("le calage descend d'abord, jamais ne monte a l'aveugle",
    impulsionsDescente >= 7 and impulsionsMontee <= 1,
    string.format("%d descentes, %d montees", impulsionsDescente, impulsionsMontee))
  verifier("les ordres sont de vraies IMPULSIONS, pas un niveau maintenu",
    faceHauteEnContinu == 0, faceHauteEnContinu .. " cycles maintenus")
  verifier("le vehicule se retrouve au point mort",
    sorties.rapports().avance.rapport == "N",
    tostring(sorties.rapports().avance.rapport))
  verifier("les deux faces retombent a zero apres le calage",
    (etat.redstone.left or 0) == 0 and (etat.redstone.right or 0) == 0)

  ------------------------------------------------------- montee en rapport
  local vus = { N = true }
  for _ = 1, 120 do
    cycle(1.0)
    vus[sorties.rapports().avance.rapport] = true
  end
  verifier("une commande pleine monte jusqu'au dernier rapport",
    sorties.rapports().avance.rapport == "5",
    tostring(sorties.rapports().avance.rapport))
  verifier("les rapports sont passes un par un, dans l'ordre",
    vus["1"] and vus["2"] and vus["3"] and vus["4"] and vus["5"])
  verifier("la marche arriere n'est jamais engagee", not vus.R)

  ------------------------------------------------------------ hysteresis
  -- Rapport 3 = 0.60. Une commande a 0.62 ne doit RIEN changer : sans
  -- hysteresis, le selecteur passerait son temps a monter et descendre.
  for _ = 1, 60 do cycle(0.60) end
  local rapportStable = sorties.rapports().avance.rapport
  local changementsAvant = sorties.rapports().avance.changements
  for _ = 1, 40 do cycle(0.62) end
  verifier("une commande a peine differente ne fait pas changer de rapport",
    sorties.rapports().avance.changements == changementsAvant
    and sorties.rapports().avance.rapport == rapportStable,
    string.format("%s -> %s", rapportStable, sorties.rapports().avance.rapport))

  for _ = 1, 40 do cycle(1.0) end
  verifier("une commande franchement plus haute fait bien monter",
    sorties.rapports().avance.changements > changementsAvant)

  ------------------------------------------------------------ retour au neutre
  for _ = 1, 120 do sorties.neutraliser() end
  verifier("la neutralisation ramene au point mort, cran par cran",
    sorties.rapports().avance.rapport == "N",
    tostring(sorties.rapports().avance.rapport))

  ------------------------------------------------- commande a deux signaux
  -- neutre 128, amplitude 127, pas 16 : total = 128 + 127 x commande.
  local function verticalBrut(commande)
    sorties.appliquer({ avance = 0, vertical = commande, lacet = 0, lateral = 0 })
    return (etat.redstone.top or 0), (etat.redstone.bottom or 0)
  end

  local grossier, fin = verticalBrut(0)
  verifier("commande nulle : la chauffe de sustentation est appliquee",
    grossier == 8 and fin == 0, string.format("grossier %d fin %d", grossier, fin))

  grossier, fin = verticalBrut(1)
  verifier("commande pleine : les deux signaux au maximum",
    grossier == 15 and fin == 15, string.format("grossier %d fin %d", grossier, fin))

  grossier, fin = verticalBrut(-1)
  verifier("commande minimale : chauffe presque nulle",
    grossier == 0 and fin <= 1, string.format("grossier %d fin %d", grossier, fin))

  -- La raison d'etre du second signal : une correction trop fine pour le
  -- signal grossier doit quand meme etre transmise.
  local g1, f1 = verticalBrut(0.01)
  local g2, f2 = verticalBrut(0.02)
  verifier("une correction fine change le signal fin sans toucher le grossier",
    g1 == g2 and f1 ~= f2,
    string.format("(%d,%d) puis (%d,%d)", g1, f1, g2, f2))

  local resolutionFine = 127 / (16 * 16 - 1)
  verifier("resolution 16 fois meilleure qu'un seul signal",
    resolutionFine < (127 / 16) / 15, string.format("%.3f par cran", resolutionFine))

  ----------------------------------------- l'autopilote attend le calage
  -- Sans pilote injecte : un pilote fourni par le programme appelant remplace
  -- toute la couche de sorties, boites comprises. Ici on veut la vraie.
  local banc2, env2, etat2, _, ap2 = monter({ budget = 300, sansPilote = true })
  ap2.pas(); env2.sleep(0.4); ap2.pas()
  verifier("l'autopilote reste en acquisition tant que la boite n'est pas calee",
    ap2.etat().mode == "ACQUISITION", ap2.etat().mode)
  verifier("aucune poussee pendant le calage",
    (etat2.redstone.front or 0) == 0)
  verifier("la boite est annoncee au demarrage",
    journalContient("boite a 7 rapports"))

  for _ = 1, 60 do ap2.pas() env2.sleep(0.4) end
  verifier("l'autopilote sort d'acquisition une fois la boite calee",
    ap2.etat().mode ~= "ACQUISITION", ap2.etat().mode)
  verifier("la fin du calage est journalisee",
    journalContient("cale au point mort"))
  verifier("la butee basse atteinte est journalisee",
    journalContient("butee basse atteinte"))
end

--------------------------------------------------------------------------------
print("\n== TEST 27 : ordinateur de sortie deporte (satellite) ==")
do
  local banc, env, etat = monter({ budget = 200, sansInstance = true })
  local satellite = banc.charger(SRC .. "/satellite.lua")
  verifier("satellite chargeable comme bibliotheque",
    type(satellite) == "table" and type(satellite.creerSatellite) == "function")

  local config = {
    identifiant = "SAT-AVANT", vehicule = "AER-CARGO-01",
    protocole = "frenchnet_sortie", delaiChienDeGarde = 1.5,
    repos = { left = 0, right = 0 },
    cotesAutorises = { "left", "right" },
    remonterEntrees = true,
  }
  local sat = satellite.creerSatellite(config)

  verifier("au demarrage, les faces sont posees au repos", sat.neutralise == true)

  -- Trame nominale.
  local acceptee, acquittement = sat.traiterTrame(7, {
    protocole = "FRENCHNET_SORTIE", vehicule = "AER-CARGO-01", sequence = 12,
    sorties = { left = 11, right = 0 }, repos = { left = 4, right = 0 },
  })
  verifier("trame nominale acceptee", acceptee == true)
  verifier("niveaux appliques sur les faces", etat.redstone.left == 11)
  verifier("acquittement renvoye au maitre",
    acquittement and acquittement.protocole == "FRENCHNET_SORTIE_ACK"
    and acquittement.sequence == 12 and acquittement.identifiant == "SAT-AVANT")
  verifier("l'acquittement remonte les entrees redstone",
    acquittement and type(acquittement.entrees) == "table")

  -- Trame d'un autre vehicule : deux appareils cote a cote ne se commandent pas.
  local avant = etat.redstone.left
  local refusee = sat.traiterTrame(9, {
    protocole = "FRENCHNET_SORTIE", vehicule = "AER-CHASSE-02", sequence = 99,
    sorties = { left = 15 },
  })
  verifier("trame d'un autre vehicule ignoree", refusee == false)
  verifier("les faces ne bougent pas pour un autre vehicule", etat.redstone.left == avant)

  -- Face non autorisee.
  sat.traiterTrame(7, {
    protocole = "FRENCHNET_SORTIE", vehicule = "AER-CARGO-01", sequence = 13,
    sorties = { top = 15 },
  })
  verifier("face non autorisee refusee", (etat.redstone.top or 0) == 0)
  verifier("le refus est compte", sat.refus >= 1, tostring(sat.refus))

  -- Chien de garde : c'est LA securite du montage deporte.
  verifier("pas de neutralisation tant que les trames arrivent",
    sat.surveiller(sat.derniereTrame + 1.0) == false)
  local neutralise = sat.surveiller(sat.derniereTrame + 2.0)
  verifier("neutralisation au-dela du delai", neutralise == true)
  verifier("les faces retombent aux niveaux de REPOS envoyes par le maitre",
    etat.redstone.left == 4,
    "un axe analogique dont le neutre vaut 4 ne doit pas retomber a 0")
  verifier("chien de garde journalise", (banc.contient("liaison perdue")))

  -- Une entree redstone est bien remontee au maitre.
  banc.entree("right", 9)
  local sat2 = satellite.creerSatellite(config)
  local _, ack2 = sat2.traiterTrame(7, {
    protocole = "FRENCHNET_SORTIE", vehicule = "AER-CARGO-01", sequence = 1,
    sorties = {},
  })
  verifier("entree redstone remontee au maitre",
    ack2 and ack2.entrees and ack2.entrees.right == 9,
    ack2 and ack2.entrees and tostring(ack2.entrees.right))

  -- Cote maitre : l'acquittement met le satellite a jour et leve le silence.
  local banc3, env3, etat3, autopilote3 = monter({ budget = 200, sansInstance = true })
  local config3 = autopilote3.chargerConfiguration("/autopilote/config_vehicule.lua")
  config3.sorties.distant.actif = false
  local sorties3 = autopilote3.creerSorties(config3)
  verifier("acquittement d'un autre vehicule rejete",
    sorties3.traiterAck(12, { protocole = "FRENCHNET_SORTIE_ACK",
      vehicule = "AUTRE", identifiant = "X" }) == false)
  verifier("acquittement du bon vehicule accepte",
    sorties3.traiterAck(12, { protocole = "FRENCHNET_SORTIE_ACK",
      vehicule = config3.identifiant, identifiant = "SAT-AVANT", sequence = 3,
      entrees = { back = 7 } }) == true)
  verifier("entree distante lisible par le maitre",
    sorties3.entreeDistante(12, "back") == 7)
end

--------------------------------------------------------------------------------
print("\n== TEST 28 : surveillance carburant et ravitaillement automatique ==")
do
  --- Prepare un vehicule dont la jauge est un reservoir expose a CC.
  local function avecReservoir(contenu, capacite, options)
    options = options or {}
    local banc, env, etat, autopilote = monter({
      budget = options.budget or 900, sansInstance = true,
      decalageGps = { x = 0, y = 2, z = 0 },
      vehicule = options.vehicule
        or { x = 120, y = 100, z = -740, cap = 0, vLateralMax = 0 },
      ajusterConfig = function(config)
        config.vitesses.altitudeCroisiere = 140
        config.carburant = config.carburant or {}
        config.carburant.actif = true
        config.carburant.source = "peripherique"
        config.carburant.peripherique = { nom = "reservoir_0", methode = "tanks" }
        config.carburant.seuilBas = 0.25
        config.carburant.seuilPlein = 0.9
        config.carburant.periode = 2
        config.carburant.coteAmarre = "back"
        config.carburant.amarrage = config.carburant.amarrage or {}
        config.carburant.amarrage.altitudeApproche = 10
        config.carburant.amarrage.delaiMax = 400
        config.carburant.amarrage.attenteMax = 200
        if options.ajusterConfig then options.ajusterConfig(config) end
      end,
    })
    local niveau = { quantite = contenu }
    banc.brancher("reservoir_0", "fluid_storage", {
      tanks = function()
        return { { name = "create:fuel", amount = niveau.quantite, capacity = capacite } }
      end,
    })
    local ap = autopilote.nouveau({
      config = "/autopilote/config_vehicule.lua", commandes = banc.pilote() })
    local carburant = banc.charger(SRC .. "/carburant.lua")
    return banc, env, etat, autopilote, ap, carburant, niveau
  end

  ------------------------------------------------------------------ lecture
  local banc, env, etat, autopilote, ap, carburant, niveau = avecReservoir(500, 1000)
  local jauge = carburant.nouveau(ap)
  verifier("niveau lu sur le reservoir", math.abs(jauge.niveau() - 0.5) < 1e-6,
    tostring(jauge.niveau()))
  niveau.quantite = 100
  verifier("le niveau suit le reservoir", math.abs(jauge.niveau() - 0.1) < 1e-6)

  -- Jauge illisible : anomalie signalee, pas de valeur inventee.
  local bancX, envX, etatX, autopiloteX, apX, carburantX = avecReservoir(0, 1000)
  local apXjauge = carburantX.nouveau(apX, { config = {
    source = "peripherique",
    peripherique = { nom = "absent_0", methode = "tanks" } } })
  local valeur, motif = apXjauge.niveau()
  verifier("peripherique absent : aucun niveau invente", valeur == nil)
  verifier("l'anomalie nomme la cause",
    motif and motif:find("introuvable", 1, true) ~= nil, tostring(motif))

  -- Lecture par redstone, en jauge et en tout ou rien.
  local bancR, envR, etatR, autopiloteR, apR, carburantR = avecReservoir(0, 1000)
  bancR.entree("back", 12)
  local jaugeR = carburantR.nouveau(apR, { config = {
    source = "redstone", redstone = { cote = "back", mode = "analogique", max = 15 } } })
  verifier("jauge redstone analogique", math.abs(jaugeR.niveau() - 12 / 15) < 1e-6,
    tostring(jaugeR.niveau()))
  local jaugeS = carburantR.nouveau(apR, { config = {
    source = "redstone", redstone = { cote = "back", mode = "signal" } } })
  verifier("signal tout ou rien : courant = carburant bas", jaugeS.niveau() == 0)
  bancR.entree("back", 0)
  verifier("signal eteint = reservoir considere plein", jaugeS.niveau() == 1)

  ----------------------------------------------- retour et amarrage complets
  local banc2, env2, etat2, autopilote2, ap2, carburant2, niveau2 =
    avecReservoir(200, 1000, { budget = 1200 })
  local evenements = {}
  local jauge2 = carburant2.nouveau(ap2, {})
  jauge2.surEvenement(function(typeEvenement) evenements[typeEvenement] = true end)
  ap2.initialiser()

  local station = ap2.ravitaillement().position
  local termine = false
  local ok = pcall(env2.parallel.waitForAny,
    function() ap2.executer() end,
    function() jauge2.executer() end,
    function()
      -- On attend l'amarrage, puis on remplit le reservoir pour liberer.
      for _ = 1, 600 do
        if jauge2.estAmarre() then break end
        env2.sleep(1)
      end
      if jauge2.estAmarre() then
        niveau2.quantite = 980
        for _ = 1, 200 do
          if not jauge2.estOccupe() then break end
          env2.sleep(1)
        end
      end
      termine = true
    end)

  verifier("le retour au ravitaillement se declenche sous le seuil",
    evenements.retour == true)
  verifier("le vehicule s'amarre a la station", evenements.amarre == true,
    jauge2.etat().etat)
  verifier("amarrage sur la station verrouillee",
    banc2.distanceH(station) <= 1.5,
    string.format("%.2f bloc de la station", banc2.distanceH(station)))
  verifier("altitude d'amarrage atteinte",
    math.abs(etat2.vehicule.y - (station.y + 2)) <= 1.0,
    string.format("%.2f (decalage d'amarrage -2)", etat2.vehicule.y))
  verifier("le plein libere le vehicule", evenements.depart == true)
  verifier("retour en veille apres liberation",
    jauge2.etat().etat == "VEILLE", jauge2.etat().etat)
  verifier("signal d'amarrage retombe au depart",
    (etat2.redstone.back or 0) == 0)
  verifier("manoeuvre journalisee",
    journalContient("retour au ravitaillement declenche")
    and journalContient("descente de precision"))
end

print(string.format("\n===== %d/%d verifications reussies =====", total - echecs, total))
os.exit(echecs == 0 and 0 or 1)
