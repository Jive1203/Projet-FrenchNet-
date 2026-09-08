-- Banc d'essai de ads.lua, hors du jeu, sur un interpreteur Lua 5.4.
--   Usage : lua5.4 tests/test_ads.lua   (depuis la racine du depot)
-- Simule CraftOS via tests/craftos.lua : evenements, minuteurs, rednet, modem,
-- radar (Create Radars), interface de pilotage (Create Aeronautics), redstone.
-- Verifie la cinematique pure, le fonctionnement nominal ET le comportement en
-- panne.

local RACINE = (arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."
local SCR    = RACINE .. "/tests"
local SRC    = RACINE .. "/ads"
local BANC   = "/tmp/banc_ads_frenchnet"

package.path = SCR .. "/?.lua;" .. package.path

local echecs, total = 0, 0

local function preparer(configLua)
  os.execute("rm -rf " .. BANC .. " && mkdir -p " .. BANC .. "/ads")
  os.execute("cp " .. SRC .. "/ads.lua " .. BANC .. "/ads/")
  if configLua ~= false then
    local f = io.open(BANC .. "/ads/config_ads.lua", "w")
    f:write(configLua or "")
    f:close()
  end
end

local function verifier(nom, condition, detail)
  total = total + 1
  if condition then
    print(string.format("  [OK]   %s", nom))
  else
    echecs = echecs + 1
    print(string.format("  [ECHEC] %s %s", nom, detail and ("-> " .. detail) or ""))
  end
end

local function contient(sorties, motif)
  for indice, ligne in ipairs(sorties) do
    if ligne:find(motif, 1, true) then return true, ligne, indice end
  end
  return false
end

local function indiceDe(sorties, motif)
  local _, _, indice = contient(sorties, motif)
  return indice
end

local function proche(a, b, tolerance)
  return type(a) == "number" and math.abs(a - b) <= (tolerance or 1e-6)
end

--------------------------------------------------------------------------------
-- Generateurs de scenarios radar. Le temps est compte a partir du PREMIER scan,
-- pour rester independant de la duree d'initialisation de l'ADS.
--------------------------------------------------------------------------------

--- Contact rectiligne uniforme, exprime en coordonnees relatives au navire.
-- @param p depart { x, y, z } ; @param v vitesse blocs/s ; @param fin  s (nil = jamais)
local function scenarioRectiligne(nom, p, v, fin)
  local t0
  return function(horloge)
    if not t0 then t0 = horloge end
    local t = horloge - t0
    if fin and t > fin then return {} end
    return { {
      name = nom,
      x = p.x + v.x * t, y = p.y + v.y * t, z = p.z + v.z * t,
    } }
  end
end

--------------------------------------------------------------------------------
-- Simulation en BOUCLE FERMEE d'un missile a guidage proportionnel.
--
-- C'est le seul montage qui prouve quelque chose sur la menace reelle : le
-- missile lit la position du navire a chaque scan et corrige sa trajectoire,
-- donc il reagit aux ordres que l'ADS vient d'envoyer. Un scenario rectiligne,
-- lui, ne peut pas distinguer une evasion utile d'une evasion inutile.
--
-- Le navire est modelise avec une INERTIE DE BARRE : l'ADS fixe un cap de
-- consigne, le navire s'y rend a vitesse angulaire finie. Sans cela le test
-- serait complaisant.
--------------------------------------------------------------------------------

local function vsomme(a, b) return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z } end
local function vdiff(a, b) return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z } end
local function vmul(a, k) return { x = a.x * k, y = a.y * k, z = a.z * k } end
local function vnorme(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
local function vunit(a)
  local n = vnorme(a)
  if n < 1e-9 then return nil end
  return vmul(a, 1 / n)
end
local function vcross(a, b)
  return { x = a.y * b.z - a.z * b.y,
           y = a.z * b.x - a.x * b.z,
           z = a.x * b.y - a.y * b.x }
end
local function vdot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end

--- Direction unitaire correspondant a un cap Minecraft (yaw 0 = +Z, 90 = -X).
local function directionDepuisCap(cap)
  local r = math.rad(cap)
  return { x = -math.sin(r), y = 0, z = math.cos(r) }
end

--- Fait tourner 'd' vers 'cible' d'au plus 'angleMax' radians (Rodrigues).
local function tournerVers(d, cible, angleMax)
  local cosang = math.max(-1, math.min(1, vdot(d, cible)))
  local angle = math.acos(cosang)
  if angle <= angleMax or angle < 1e-9 then return cible end
  local axe = vunit(vcross(d, cible))
  if not axe then return d end
  local c, si = math.cos(angleMax), math.sin(angleMax)
  return vunit(vsomme(vmul(d, c), vmul(vcross(axe, d), si))) or d
end

--- Construit un scenario de poursuite. Renvoie la fonction radar et une table
-- de mesure ou l'on relit la distance minimale reellement atteinte.
local function scenarioPoursuite(etat, reglages)
  local mesure = { distanceMini = math.huge, impact = false, duree = 0 }
  -- La direction du missile est tenue a part : les operations vectorielles
  -- renvoient des tables neuves et perdraient un champ porte par la position.
  local navire, missile, dirMissile, capReel, dernier

  return function(horloge)
    if not dernier then
      dernier  = horloge
      navire   = { x = 0, y = 150, z = 0 }
      capReel  = 0
      missile    = { x = 0, y = 150, z = reglages.distance }
      dirMissile = { x = 0, y = 0, z = -1 }
      etat.navire.x, etat.navire.y, etat.navire.z = navire.x, navire.y, navire.z
      return { { name = "aeronautics:guided_missile",
                 x = missile.x, y = missile.y, z = missile.z,
                 vx = dirMissile.x * reglages.vitesseMissile,
                 vy = dirMissile.y * reglages.vitesseMissile,
                 vz = dirMissile.z * reglages.vitesseMissile } }
    end

    local dt = horloge - dernier
    dernier = horloge
    if dt <= 0 then dt = 0.0001 end
    mesure.duree = mesure.duree + dt

    -- 1. Barre du navire : le cap reel rejoint le cap de consigne a vitesse
    --    angulaire finie. etat.navire.cap est ce que l'ADS a demande.
    local consigne = etat.navire.cap or 0
    local ecart = ((consigne - capReel + 180) % 360) - 180
    local maxi = reglages.viragNavireDegSec * dt
    capReel = capReel + math.max(-maxi, math.min(maxi, ecart))

    -- 2. Deplacement du navire, altitude suivie sur la consigne.
    local dirNavire = directionDepuisCap(capReel)
    navire = vsomme(navire, vmul(dirNavire, reglages.vitesseNavire * dt))
    local altitudeVisee = etat.navire.altitude or navire.y
    local dyMax = reglages.vitesseVerticale * dt
    navire.y = navire.y + math.max(-dyMax, math.min(dyMax, altitudeVisee - navire.y))
    etat.navire.x, etat.navire.y, etat.navire.z = navire.x, navire.y, navire.z

    -- 3. Guidage du missile : poursuite avec anticipation (point d'interception
    --    estime), limitee par sa vitesse de rotation.
    local versNavire = vdiff(navire, missile)
    local distance = vnorme(versNavire)
    local tVol = distance / reglages.vitesseMissile
    local anticipation = vsomme(navire, vmul(vmul(dirNavire, reglages.vitesseNavire), tVol))
    local voulue = vunit(vdiff(anticipation, missile)) or dirMissile
    dirMissile = tournerVers(dirMissile, voulue, math.rad(reglages.virageMissileDegSec) * dt)
    missile = vsomme(missile, vmul(dirMissile, reglages.vitesseMissile * dt))

    -- 4. Mesure : distance minimale reellement atteinte sur tout le vol.
    local d = vnorme(vdiff(missile, navire))
    if d < mesure.distanceMini then mesure.distanceMini = d end
    if d <= reglages.rayonImpact then mesure.impact = true end

    return { { name = "aeronautics:guided_missile",
               x = missile.x, y = missile.y, z = missile.z,
               vx = dirMissile.x * reglages.vitesseMissile,
               vy = dirMissile.y * reglages.vitesseMissile,
               vz = dirMissile.z * reglages.vitesseMissile } }
  end, mesure
end

local CONFIG_NOMINALE = [[
return {
  identifiant = "NAV-01-CORSAIRE",
  designation = "Croiseur d'essai",
  intervalleScanSecondes = 0.25,
  radarPortee = 300,
  radarRepere = "relatif",
  rayonMenace = 12,
  horizonMenaceSecondes = 12,
  delaiSecuriteSecondes = 4,
  piloteMode = "auto",
  altitudeMin = 80, altitudeMax = 300,
  amplitudeAltitudeBlocs = 40,
  largueurs = {
    { type = "redstone", cote = "left",  impulsionSecondes = 0.4, libelle = "rampe babord" },
    { type = "redstone", cote = "right", impulsionSecondes = 0.4, libelle = "rampe tribord" },
  },
  salvesParEngagement = 2,
  intervalleSalveSecondes = 0.5,
  stockLeurres = 24,
  journalNiveauEcran = "DEBUG",
  battementSecondes = 30,
}
]]

--------------------------------------------------------------------------------
print("\n== TEST 1 : cinematique pure (geometrie d'interception) ==")
do
  preparer(CONFIG_NOMINALE)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env = craftos.creer({ racine = BANC, programme = "ads/ads.lua" })
  env.__ADS_BANC_ESSAI = true
  craftos.executer(BANC .. "/ads/ads.lua", 10)

  local internes = env.__ADS_INTERNES
  verifier("internes exposes pour le banc d'essai", internes ~= nil)

  if internes then
    local vec, cin = internes.vec, internes.cinematique

    -- Approche frontale : le projectile arrive droit dessus.
    local frontal = cin.approcheMinimale(vec.creer(0, 0, 200), vec.creer(0, 0, -50))
    verifier("frontal : distance", proche(frontal.distance, 200, 1e-9), tostring(frontal.distance))
    verifier("frontal : rapprochement 50 b/s", proche(frontal.rapprochement, 50, 1e-9))
    verifier("frontal : impact dans 4 s", proche(frontal.tCpa, 4, 1e-9), tostring(frontal.tCpa))
    verifier("frontal : passage a 0 bloc", proche(frontal.distanceCpa, 0, 1e-6))
    verifier("frontal : alignement 1",
      proche(cin.alignement(vec.creer(0, 0, 200), vec.creer(0, 0, -50)), 1, 1e-9))

    -- Passage au large : il se rapproche ET reste aligne, mais il ratera.
    -- C'est le cas que les seuls criteres "rapprochement + alignement"
    -- ne savent pas rejeter, et que la distance d'approche minimale tranche.
    local r = vec.creer(60, 0, 240)
    local v = vec.creer(0, 0, -60)
    local large = cin.approcheMinimale(r, v)
    verifier("au large : se rapproche bien", large.rapprochement > 50, tostring(large.rapprochement))
    verifier("au large : parait aligne (cos > 0.965)",
      cin.alignement(r, v) > 0.965, tostring(cin.alignement(r, v)))
    verifier("au large : passera pourtant a 60 blocs",
      proche(large.distanceCpa, 60, 1e-6), tostring(large.distanceCpa))

    -- Projectile qui s'eloigne : CPA derriere nous.
    local fuite = cin.approcheMinimale(vec.creer(0, 0, 50), vec.creer(0, 0, 30))
    verifier("en fuite : tCpa negatif", fuite.tCpa < 0, tostring(fuite.tCpa))
    verifier("en fuite : rapprochement negatif", fuite.rapprochement < 0)

    -- Caps Minecraft : yaw 0 = sud (+Z), -90 = est (+X), 180 = nord (-Z).
    verifier("cap sud (+Z) = 0", proche(cin.capDepuisVecteur(vec.creer(0, 0, 1)), 0, 1e-9))
    verifier("cap est (+X) = -90", proche(cin.capDepuisVecteur(vec.creer(1, 0, 0)), -90, 1e-9))
    verifier("cap ouest (-X) = 90", proche(cin.capDepuisVecteur(vec.creer(-1, 0, 0)), 90, 1e-9))
    verifier("cap nord (-Z) = 180",
      math.abs(math.abs(cin.capDepuisVecteur(vec.creer(0, 0, -1))) - 180) < 1e-9)

    -- Axe d'evasion : perpendiculaire a la trajectoire, jamais dans son axe.
    local meilleur, candidats = cin.axeEvasion(vec.creer(5, 0, 200), vec.creer(0, 0, -60), 20)
    verifier("evasion : 4 axes evalues", #candidats == 4, "#" .. #candidats)
    verifier("evasion : axe perpendiculaire au projectile",
      meilleur and proche(vec.scalaire(meilleur.axe, vec.creer(0, 0, -1)), 0, 1e-9))
    verifier("evasion : le degagement eloigne le point d'impact",
      meilleur and meilleur.distanceCpa > 5, meilleur and tostring(meilleur.distanceCpa))
    -- Le projectile passera a +5 en X : le navire doit se degager vers -X pour
    -- creuser l'ecart, pas vers +X qui le ramenerait dans la trajectoire.
    verifier("evasion : degagement du cote oppose a l'ecart lateral",
      meilleur and meilleur.axe.x < 0, meilleur and tostring(meilleur.axe.x))
    local miroir = cin.axeEvasion(vec.creer(-5, 0, 200), vec.creer(0, 0, -60), 20)
    verifier("evasion : choix symetrique pour un ecart oppose",
      miroir and miroir.axe.x > 0, miroir and tostring(miroir.axe.x))

    -- Le filtre d'altitude doit pouvoir interdire les axes verticaux.
    local sansVertical = cin.axeEvasion(vec.creer(5, 0, 200), vec.creer(0, 0, -60), 20,
      function(c) return math.abs(c.verticale) < 0.2 end)
    verifier("evasion : filtre d'altitude respecte",
      sansVertical and math.abs(sansVertical.verticale) < 0.2)

    -- Vitesse par regression sur un historique bruite par l'arrondi radar.
    local echantillons = {}
    for i = 0, 5 do
      echantillons[#echantillons + 1] =
        { t = i * 0.25, p = vec.creer(0, 0, math.floor(200 - 60 * i * 0.25)) }
    end
    local vitesse = cin.vitesseParRegression(echantillons)
    verifier("regression : vitesse retrouvee (~ -60 b/s en Z)",
      vitesse and math.abs(vitesse.z + 60) < 3, vitesse and tostring(vitesse.z))
  end
end

--------------------------------------------------------------------------------
print("\n== TEST 2 : engagement complet (detection, leurres, evasion, reprise) ==")
do
  preparer(CONFIG_NOMINALE)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC, programme = "ads/ads.lua",
    pilote = { cap = 0, altitude = 150, gaz = 0.5, x = 0, y = 150, z = 0 },
    -- Missile legerement decale : il passera a 5 blocs, donc dans le rayon.
    radar = scenarioRectiligne("cbc:he_missile", { x = 5, y = 0, z = 240 },
      { x = 0, y = 0, z = -60 }, 6),
  })

  local motif = craftos.executer(BANC .. "/ads/ads.lua", 40)
  local sorties = etat.sorties

  verifier("l'ADS tourne sans se terminer", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("radar detecte et sonde", (contient(sorties, "radar de bord")))
  verifier("methode de scan retenue journalisee", (contient(sorties, "methode de scan 'getEntities'")))
  verifier("interface de pilotage detectee", (contient(sorties, "pilotage par le peripherique")))
  verifier("largueurs operationnels", (contient(sorties, "largueur(s) de leurres operationnel")))

  verifier("contact classe projectile", (contient(sorties, "classe PROJECTILE")))
  verifier("alerte de menace declenchee", (contient(sorties, "MENACE ENTRANTE")))
  verifier("preemption de la tache", (contient(sorties, "prend la priorite sur la tache en cours")))
  verifier("leurres largues", (contient(sorties, "leurre(s) largue(s)")))
  verifier("manoeuvre d'evasion executee", (contient(sorties, "degagement")))
  verifier("menace levee et tracee", (contient(sorties, "MENACE LEVEE")))
  verifier("motif de levee explicite",
    (contient(sorties, "projectile passe au plus pres"))
    or (contient(sorties, "projectile s'eloigne"))
    or (contient(sorties, "contact disparu"))
    or (contient(sorties, "echo perdu")))
  verifier("controle rendu a la tache", (contient(sorties, "controle rendu a la tache normale")))
  verifier("retour en VEILLE", (contient(sorties, "retour en VEILLE")))

  -- Ordre des evenements : l'alerte precede les deux reponses, la reprise suit.
  local iAlerte  = indiceDe(sorties, "MENACE ENTRANTE")
  local iLeurres = indiceDe(sorties, "leurre(s) largue(s)")
  local iEvasion = indiceDe(sorties, "degagement")
  local iReprise = indiceDe(sorties, "controle rendu a la tache normale")
  verifier("chronologie : alerte avant leurres", iAlerte and iLeurres and iAlerte < iLeurres)
  verifier("chronologie : alerte avant evasion", iAlerte and iEvasion and iAlerte < iEvasion)
  verifier("chronologie : reprise apres l'evasion", iEvasion and iReprise and iEvasion < iReprise)

  -- Simultaneite reelle : le premier leurre et la premiere manoeuvre partent
  -- du meme evenement, donc a moins d'une periode de manoeuvre d'ecart.
  local premierLeurre, premiereManoeuvre
  for _, impulsion in ipairs(etat.impulsionsRedstone) do
    if impulsion.valeur and not premierLeurre then premierLeurre = impulsion.t end
  end
  for _, consigne in ipairs(etat.consignes) do
    if consigne.commande == "cap" and not premiereManoeuvre then premiereManoeuvre = consigne.t end
  end
  verifier("leurres effectivement largues (redstone)", premierLeurre ~= nil)
  verifier("manoeuvre effectivement commandee (pilote)", premiereManoeuvre ~= nil)
  verifier("leurres et evasion simultanes (< 1.5 s d'ecart)",
    premierLeurre and premiereManoeuvre and math.abs(premierLeurre - premiereManoeuvre) < 1.5,
    premierLeurre and premiereManoeuvre
      and string.format("%.2f vs %.2f", premierLeurre, premiereManoeuvre) or "absent")

  -- Chaque largueur declare doit avoir servi, et chaque largage doit etre une
  -- impulsion distincte : deux ordres simultanes sur la meme sortie ne font
  -- qu'un seul leurre, et une echeance mal geree refermerait trop tot.
  local parCote, ouvertures = {}, 0
  for _, impulsion in ipairs(etat.impulsionsRedstone) do
    if impulsion.valeur then
      ouvertures = ouvertures + 1
      parCote[impulsion.cote] = (parCote[impulsion.cote] or 0) + 1
    end
  end
  verifier("les deux rampes de leurres ont servi",
    (parCote.left or 0) > 0 and (parCote.right or 0) > 0,
    string.format("babord=%d tribord=%d", parCote.left or 0, parCote.right or 0))
  verifier("plusieurs largages distincts (2 salves x 2 leurres)",
    ouvertures >= 6, "#" .. ouvertures)

  -- Impulsions refermees : une sortie restee a true bloquerait le largage suivant.
  local restees = {}
  for cote, valeur in pairs(etat.redstone) do
    if valeur then restees[#restees + 1] = cote end
  end
  verifier("toutes les impulsions redstone refermees", #restees == 0, table.concat(restees, ","))

  -- Reprise : le navire retrouve son cap et son altitude d'avant l'alerte.
  verifier("cap restitue apres l'engagement", proche(etat.navire.cap, 0, 0.001),
    tostring(etat.navire.cap))
  verifier("altitude restituee apres l'engagement", proche(etat.navire.altitude, 150, 0.001),
    tostring(etat.navire.altitude))
  verifier("verrou de priorite leve", not io.open(BANC .. "/ads/.priorite_ads", "r"))

  local log = io.open(BANC .. "/ads/ads.log", "r")
  local contenu = log and log:read("a") or ""
  if log then log:close() end
  verifier("journal ecrit sur disque", #contenu > 2000, #contenu .. " octets")
  verifier("journal etiquete par etape", contenu:find("[etape: ", 1, true) ~= nil)
  verifier("journal chiffre (distances, CPA)", contenu:find("CPA=", 1, true) ~= nil)
end

--------------------------------------------------------------------------------
print("\n== TEST 3 : projectile qui se rapproche et parait aligne mais ratera ==")
do
  preparer(CONFIG_NOMINALE)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC, programme = "ads/ads.lua",
    pilote = { cap = 0, altitude = 150 },
    -- Decalage lateral de 60 blocs : rapprochement franc, cos = 0.970 (donc
    -- "aligne" au sens du seuil), mais il passera a 60 blocs.
    radar = scenarioRectiligne("cbc:ap_shell", { x = 60, y = 0, z = 240 },
      { x = 0, y = 0, z = -60 }, 6),
  })

  local motif = craftos.executer(BANC .. "/ads/ads.lua", 30)
  local sorties = etat.sorties

  verifier("l'ADS tourne sans se terminer", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("contact bien classe projectile", (contient(sorties, "classe PROJECTILE")))
  verifier("AUCUNE alerte declenchee", not (contient(sorties, "MENACE ENTRANTE")))
  verifier("aucun leurre gaspille", #etat.impulsionsRedstone == 0,
    "#" .. #etat.impulsionsRedstone)
  verifier("aucune manoeuvre parasite", #etat.consignes == 0, "#" .. #etat.consignes)
  verifier("le journal explique le non-declenchement",
    (contient(sorties, "passera a")) or (contient(sorties, "CPA=")))
end

--------------------------------------------------------------------------------
print("\n== TEST 4 : menace persistante (l'ADS garde la priorite) ==")
do
  preparer(CONFIG_NOMINALE)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC, programme = "ads/ads.lua",
    pilote = { cap = 0, altitude = 150 },
    -- Approche lente et continue : la menace tient jusqu'a la fin du test.
    radar = scenarioRectiligne("aeronautics:guided_missile", { x = 3, y = 0, z = 100 },
      { x = 0, y = 0, z = -10 }),
  })

  local motif = craftos.executer(BANC .. "/ads/ads.lua", 8)
  local sorties = etat.sorties

  verifier("l'ADS tourne sans se terminer", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("alerte declenchee", (contient(sorties, "MENACE ENTRANTE")))
  local verrou = io.open(BANC .. "/ads/.priorite_ads", "r")
  verifier("verrou de priorite pose pendant la menace", verrou ~= nil)
  if verrou then
    local contenu = verrou:read("a")
    verrou:close()
    verifier("verrou horodate et numerote", contenu:find("engagement=", 1, true) ~= nil)
  end
  verifier("aucune reprise prematuree", not (contient(sorties, "controle rendu a la tache")))
  verifier("manoeuvre entretenue (plusieurs re-evaluations)",
    #etat.consignes >= 4, "#" .. #etat.consignes)
end

--------------------------------------------------------------------------------
print("\n== TEST 5 : contacts ignores (leurres du bord, joueurs, contacts lents) ==")
do
  preparer(CONFIG_NOMINALE)
  local craftos = dofile(SCR .. "/craftos.lua")
  local t0
  local env, etat = craftos.creer({
    racine = BANC, programme = "ads/ads.lua",
    pilote = { cap = 0, altitude = 150 },
    radar = function(horloge)
      if not t0 then t0 = horloge end
      local t = horloge - t0
      return {
        -- Notre propre leurre, qui fonce droit sur le navire.
        { name = "frenchnet:flare", x = 0, y = 0, z = 60 - 30 * t },
        -- Un joueur qui approche.
        { name = "player", x = 2, y = 0, z = 50 - 20 * t },
        -- Un dirigeable ami, lent.
        { name = "aeronautics:hull", x = 1, y = 0, z = 90 - 2 * t },
      }
    end,
  })

  local motif = craftos.executer(BANC .. "/ads/ads.lua", 20)
  local sorties = etat.sorties

  verifier("l'ADS tourne sans se terminer", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("aucune alerte sur nos propres leurres", not (contient(sorties, "MENACE ENTRANTE")))
  verifier("aucun contact classe projectile", not (contient(sorties, "classe PROJECTILE")))
  verifier("aucun leurre largue", #etat.impulsionsRedstone == 0)
end

--------------------------------------------------------------------------------
print("\n== TEST 6 : aucun radar a bord ==")
do
  preparer(CONFIG_NOMINALE)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({ racine = BANC, programme = "ads/ads.lua" })
  local motif = craftos.executer(BANC .. "/ads/ads.lua", 60)
  local sorties = etat.sorties

  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("erreur localisee a la detection du radar",
    (contient(sorties, "[etape: detection du radar de bord]")))
  verifier("diagnostic explicite", (contient(sorties, "aucun radar detecte")))
  verifier("inventaire du materiel joint au diagnostic",
    (contient(sorties, "Materiel present")) or (contient(sorties, "trace dans ads.log")))
  verifier("redemarrage automatique", (contient(sorties, "redemarrage automatique n1")))
  verifier("avertissement de vulnerabilite pendant la relance",
    (contient(sorties, "LE NAVIRE N'EST PAS PROTEGE")))
end

--------------------------------------------------------------------------------
print("\n== TEST 7 : radar en panne en plein vol ==")
do
  preparer(CONFIG_NOMINALE)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC, programme = "ads/ads.lua",
    pilote = { cap = 0, altitude = 150 },
    radar = function() return {} end,
  })
  -- Le radar tombe apres 10 s de fonctionnement nominal.
  local horlogeReelle = env.os.clock
  env.os.clock = function()
    local t = horlogeReelle()
    if t > 10 then etat.radarEnPanne = true end
    return t
  end

  local motif = craftos.executer(BANC .. "/ads/ads.lua", 60)
  local sorties = etat.sorties

  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("erreur localisee a l'etape de scan",
    (contient(sorties, "[etape: scan radar]")))
  verifier("reinitialisation apres echecs repetes",
    (contient(sorties, "scans radar en echec consecutifs")))
  verifier("relance automatique", (contient(sorties, "redemarrage automatique")))
end

--------------------------------------------------------------------------------
print("\n== TEST 8 : aucun largueur declare (evasion seule) ==")
do
  preparer([[
return {
  identifiant = "NAV-02-NU",
  intervalleScanSecondes = 0.25,
  radarRepere = "relatif",
  largueurs = {},
  piloteMode = "auto",
  altitudeMin = 80, altitudeMax = 300,
  journalNiveauEcran = "DEBUG",
}
]])
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC, programme = "ads/ads.lua",
    pilote = { cap = 0, altitude = 150 },
    radar = scenarioRectiligne("cbc:he_shell", { x = 4, y = 0, z = 100 },
      { x = 0, y = 0, z = -20 }, 6),
  })

  local motif = craftos.executer(BANC .. "/ads/ads.lua", 30)
  local sorties = etat.sorties

  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("absence de largueur signalee des le demarrage",
    (contient(sorties, "AUCUN largueur de leurres operationnel")))
  verifier("alerte tout de meme declenchee", (contient(sorties, "MENACE ENTRANTE")))
  verifier("manque de leurres signale pendant l'engagement",
    (contient(sorties, "aucun largueur declare")))
  verifier("l'evasion prend le relais", #etat.consignes > 0, "#" .. #etat.consignes)
end

--------------------------------------------------------------------------------
print("\n== TEST 9 : mode simulation (mise en service prudente) ==")
do
  preparer([[
return {
  identifiant = "NAV-03-ESSAI",
  intervalleScanSecondes = 0.25,
  radarRepere = "relatif",
  piloteMode = "simulation",
  largueurs = {},
  leurresActifs = false,
  journalNiveauEcran = "DEBUG",
}
]])
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC, programme = "ads/ads.lua",
    pilote = { cap = 42, altitude = 150 },
    radar = scenarioRectiligne("cbc:he_shell", { x = 4, y = 0, z = 100 },
      { x = 0, y = 0, z = -20 }, 6),
  })

  local motif = craftos.executer(BANC .. "/ads/ads.lua", 30)
  local sorties = etat.sorties

  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("mode simulation annonce", (contient(sorties, "mode simulation")))
  verifier("detection et calcul quand meme effectues",
    (contient(sorties, "MENACE ENTRANTE")) and (contient(sorties, "degagement")))
  verifier("aucune commande envoyee au navire",
    #etat.consignes == 0 and etat.navire.cap == 42, "#" .. #etat.consignes)
  verifier("aucune sortie redstone actionnee", #etat.impulsionsRedstone == 0)
  verifier("leurres desactives signales", (contient(sorties, "leurres desactives")))
end

--------------------------------------------------------------------------------
print("\n== TEST 10 : configuration invalide et configuration absente ==")
do
  preparer([[return { intervalleScanSecondes = 0.25 }]])
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({ racine = BANC, programme = "ads/ads.lua" })
  local motif = craftos.executer(BANC .. "/ads/ads.lua", 60)
  verifier("aucun plantage (config invalide)", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("erreur localisee a la validation",
    (contient(etat.sorties, "[etape: validation de la configuration]")))
  verifier("message explicite sur l'identifiant",
    (contient(etat.sorties, "identifiant' manquant")))
  verifier("temporisation progressive",
    (contient(etat.sorties, "redemarrage automatique n3")))

  preparer(false)
  local craftos2 = dofile(SCR .. "/craftos.lua")
  local env2, etat2 = craftos2.creer({ racine = BANC, programme = "ads/ads.lua" })
  local motif2 = craftos2.executer(BANC .. "/ads/ads.lua", 40)
  verifier("aucun plantage (config absente)", motif2 == "LIMITE_TEMPS", tostring(motif2))
  verifier("erreur localisee au chargement",
    (contient(etat2.sorties, "[etape: chargement de la configuration]")))
end

--------------------------------------------------------------------------------
print("\n== TEST 11 : Ctrl+T desarme l'ADS et libere le navire ==")
do
  preparer(CONFIG_NOMINALE)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC, programme = "ads/ads.lua",
    pilote = { cap = 0, altitude = 150 },
    radar = function() return {} end,
  })
  env.os.queueEvent("terminate")
  local motif = craftos.executer(BANC .. "/ads/ads.lua", 60)

  verifier("le programme se termine proprement",
    motif == "PLUS_D_EVENEMENTS" or motif == nil, tostring(motif))
  verifier("arret manuel journalise", (contient(etat.sorties, "arret manuel demande")))
  verifier("perte de protection signalee en clair",
    (contient(etat.sorties, "le navire n'est plus protege")))
  local marqueur = io.open(BANC .. "/ads/.arret_manuel", "r")
  verifier("marqueur d'arret depose pour le lanceur", marqueur ~= nil)
  if marqueur then marqueur:close() end
  verifier("aucun verrou de priorite laisse en place",
    not io.open(BANC .. "/ads/.priorite_ads", "r"))
end

--------------------------------------------------------------------------------
print("\n== TEST 12 : autonomie totale (Ctrl+T ignore) ==")
do
  preparer(CONFIG_NOMINALE:gsub("battementSecondes = 30,",
    "battementSecondes = 30, arretParTerminate = false,"))
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC, programme = "ads/ads.lua",
    pilote = { cap = 0, altitude = 150 },
    -- Approche longue : l'ADS redemarre apres 3 s de temporisation, il doit
    -- lui rester du temps pour re-detecter et engager.
    radar = scenarioRectiligne("cbc:he_missile", { x = 5, y = 0, z = 400 },
      { x = 0, y = 0, z = -40 }, 12),
  })
  env.os.queueEvent("terminate")
  local motif = craftos.executer(BANC .. "/ads/ads.lua", 40)

  verifier("l'ADS continue de tourner", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("tentative d'arret ignoree et journalisee",
    (contient(etat.sorties, "tentative d'arret manuel ignoree")))
  verifier("la defense reste operationnelle",
    (contient(etat.sorties, "MENACE ENTRANTE")))
  verifier("aucun marqueur d'arret depose",
    not io.open(BANC .. "/ads/.arret_manuel", "r"))
end

--------------------------------------------------------------------------------
print("\n== TEST 13 : telemetrie et contrat de tache sur rednet ==")
do
  preparer(CONFIG_NOMINALE)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC, programme = "ads/ads.lua",
    pilote = { cap = 0, altitude = 150 },
    radar = scenarioRectiligne("cbc:he_missile", { x = 5, y = 0, z = 240 },
      { x = 0, y = 0, z = -60 }, 6),
  })

  craftos.executer(BANC .. "/ads/ads.lua", 40)

  local etats, preemptions, reprises, demandes = 0, 0, 0, 0
  local menaceDiffusee = false
  for _, diffusion in ipairs(etat.diffusions) do
    local m = diffusion.message
    if type(m) == "table" and m.protocole == "FRENCHNET_ADS" then
      if m.type == "ETAT" then
        etats = etats + 1
        if m.menace then menaceDiffusee = true end
      elseif m.type == "PREEMPTION" then preemptions = preemptions + 1
      elseif m.type == "REPRISE" then reprises = reprises + 1
      elseif m.type == "DEMANDE_TACHE" then demandes = demandes + 1 end
    end
  end

  verifier("telemetrie d'etat diffusee", etats > 5, "#" .. etats)
  verifier("menace publiee dans la telemetrie", menaceDiffusee)
  verifier("preemption diffusee a la navigation", preemptions >= 1, "#" .. preemptions)
  verifier("reprise diffusee a la navigation", reprises >= 1, "#" .. reprises)
  verifier("tache courante demandee par rednet", demandes >= 1, "#" .. demandes)
  verifier("telemetrie sur le protocole ADS",
    etat.diffusions[1] and etat.diffusions[1].protocole ~= nil)
end

--------------------------------------------------------------------------------
print("\n== TEST 14 : reprise de la tache lue dans tache_courante.lua ==")
do
  preparer(CONFIG_NOMINALE)
  local f = io.open(BANC .. "/ads/tache_courante.lua", "w")
  f:write([[return { nom = "orbite_attaque", destination = { x = 1200, y = 210, z = -2600 } }]])
  f:close()

  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC, programme = "ads/ads.lua",
    pilote = { cap = 0, altitude = 150 },
    radar = scenarioRectiligne("cbc:he_missile", { x = 5, y = 0, z = 240 },
      { x = 0, y = 0, z = -60 }, 6),
  })

  craftos.executer(BANC .. "/ads/ads.lua", 40)
  local sorties = etat.sorties

  verifier("tache en cours identifiee a la preemption",
    (contient(sorties, "tache 'orbite_attaque'")))
  verifier("destination tracee dans le journal",
    (contient(sorties, "destination (1200, 210, -2600)")))
  verifier("meme tache citee a la reprise",
    (select(3, contient(sorties, "controle rendu a la tache normale")) ~= nil))

  local tacheRendue = false
  for _, diffusion in ipairs(etat.diffusions) do
    local m = diffusion.message
    if type(m) == "table" and m.type == "REPRISE" and type(m.tache) == "table"
       and m.tache.nom == "orbite_attaque" then
      tacheRendue = true
    end
  end
  verifier("tache complete renvoyee a la navigation", tacheRendue)
end

--------------------------------------------------------------------------------
print("\n== TEST 15 : radar en coordonnees du monde (repere absolu) ==")
do
  preparer(CONFIG_NOMINALE:gsub('radarRepere = "relatif"', 'radarRepere = "auto"'))
  local craftos = dofile(SCR .. "/craftos.lua")
  local t0
  local env, etat = craftos.creer({
    racine = BANC, programme = "ads/ads.lua",
    pilote = { cap = 0, altitude = 150, x = 1200, y = 150, z = -2600 },
    -- Coordonnees du monde : le navire est en (1200, 150, -2600).
    radar = function(horloge)
      if not t0 then t0 = horloge end
      local t = horloge - t0
      if t > 6 then return {} end
      return { { name = "cbc:he_missile",
        x = 1205, y = 150, z = -2600 + 240 - 60 * t } }
    end,
  })

  local motif = craftos.executer(BANC .. "/ads/ads.lua", 40)
  local sorties = etat.sorties

  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("repere absolu reconnu automatiquement",
    (contient(sorties, "repere radar retenu automatiquement : absolu")))
  verifier("menace detectee malgre le changement de repere",
    (contient(sorties, "MENACE ENTRANTE")))
  verifier("evasion declenchee", (contient(sorties, "degagement")))
end

--------------------------------------------------------------------------------
print("\n== TEST 16 : pilotage redstone et largueurs peripherique + rednet ==")
do
  preparer([[
return {
  identifiant = "NAV-04-REDSTONE",
  intervalleScanSecondes = 0.25,
  radarRepere = "relatif",
  rayonMenace = 12,
  piloteMode = "redstone",
  piloteRedstone = { babord = "back", tribord = "front",
                     monter = "top", descendre = "bottom", pleinGaz = "back" },
  largueurs = {
    { type = "peripherique", nom = "create:deployer_0", methode = "activate",
      libelle = "deployer avant" },
    { type = "rednet", cible = 42, libelle = "poste de largage" },
    { type = "peripherique", nom = "create:absent_9", libelle = "largueur arrache" },
  },
  salvesParEngagement = 2,
  intervalleSalveSecondes = 0.5,
  altitudeMin = 80, altitudeMax = 300,
  journalNiveauEcran = "DEBUG",
}
]])
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({
    racine = BANC, programme = "ads/ads.lua",
    radar = scenarioRectiligne("cbc:he_missile", { x = 5, y = 0, z = 240 },
      { x = 0, y = 0, z = -60 }, 6),
  })
  local activations = 0
  craftos.ajouterPeripherique("create:deployer_0", "deployer",
    { activate = function() activations = activations + 1 return true end })

  local motif = craftos.executer(BANC .. "/ads/ads.lua", 40)
  local sorties = etat.sorties

  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("pilotage redstone retenu", (contient(sorties, "pilotage par impulsions redstone")))
  verifier("largueur arrache signale en defaut",
    (contient(sorties, "largueur arrache")))
  verifier("alerte declenchee", (contient(sorties, "MENACE ENTRANTE")))

  verifier("largueur peripherique actionne", activations > 0, "#" .. activations)
  local envoisLargage = 0
  for _, envoi in ipairs(etat.envois) do
    local m = envoi.message
    if type(m) == "table" and m.type == "LARGAGE" and envoi.destinataire == 42 then
      envoisLargage = envoisLargage + 1
    end
  end
  verifier("largueur rednet sollicite", envoisLargage > 0, "#" .. envoisLargage)

  -- Sans retour de cap, le sens de barre est arbitraire mais le navire DOIT
  -- manoeuvrer : une trajectoire rectiligne devant un autoguidage est la pire
  -- des reponses.
  verifier("absence de retour de cap signalee",
    (contient(sorties, "aucun retour de cap disponible")))
  local sortiesBarre = 0
  for _, impulsion in ipairs(etat.impulsionsRedstone) do
    if impulsion.valeur and (impulsion.cote == "back" or impulsion.cote == "front"
       or impulsion.cote == "top" or impulsion.cote == "bottom") then
      sortiesBarre = sortiesBarre + 1
    end
  end
  verifier("commandes de vol effectivement emises en redstone",
    sortiesBarre > 0, "#" .. sortiesBarre)
  verifier("aucune consigne refusee silencieusement",
    not (contient(sorties, "aucune sortie redstone cablee")))

  local restees = {}
  for cote, valeur in pairs(etat.redstone) do
    if valeur then restees[#restees + 1] = cote end
  end
  verifier("toutes les sorties refermees", #restees == 0, table.concat(restees, ","))
end

--------------------------------------------------------------------------------
print("\n== TEST 17 : missile guide en boucle fermee (l'evasion sert-elle ?) ==")
do
  -- Deux passages par profil : un temoin sans evasion, un avec. Seule cette
  -- comparaison dit si la manoeuvre apporte quelque chose ; verifier qu'un
  -- ordre de barre a ete emis ne prouve rien du tout.
  local function passage(evasionActive, reglages)
    preparer(string.format([[
return {
  identifiant = "NAV-SIM",
  intervalleScanSecondes = 0.25,
  radarRepere = "absolu",
  radarPortee = 400,
  rayonMenace = 16,
  horizonMenaceSecondes = 20,
  piloteMode = "auto",
  altitudeMin = 80, altitudeMax = 300,
  vitesseEvasionEstimee = %d,
  evasionActive = %s,
  leurresActifs = false, largueurs = {},
  journalNiveauEcran = "DEBUG",
}
]], reglages.vitesseNavire, tostring(evasionActive)))

    local craftos = dofile(SCR .. "/craftos.lua")
    local env, etat = craftos.creer({
      racine = BANC, programme = "ads/ads.lua",
      pilote = { cap = 0, altitude = 150, x = 0, y = 150, z = 0 },
    })
    local radar, mesure = scenarioPoursuite(etat, reglages)
    craftos.ajouterPeripherique("create_radars:radar_0", "radar",
      { getEntities = function() return radar(etat.horloge) end })
    craftos.executer(BANC .. "/ads/ads.lua", 20)
    return mesure, etat
  end

  local function profil(vitesseMissile, virageMissileDegSec, distance)
    return { vitesseMissile = vitesseMissile, virageMissileDegSec = virageMissileDegSec,
             vitesseNavire = 25, viragNavireDegSec = 45, vitesseVerticale = 8,
             distance = distance, rayonImpact = 3 }
  end

  -- Profil 1 : missile agile. Sans evasion, il touche.
  local agile = profil(50, 40, 300)
  local temoinAgile = passage(false, agile)
  local avecAgile, etatAgile = passage(true, agile)

  verifier("temoin : sans evasion, le missile agile touche",
    temoinAgile.impact, string.format("%.1fb", temoinAgile.distanceMini))
  verifier("avec evasion, le missile agile manque",
    not avecAgile.impact, string.format("%.1fb", avecAgile.distanceMini))
  verifier("l'evasion creuse la distance de passage",
    avecAgile.distanceMini > temoinAgile.distanceMini,
    string.format("%.1fb -> %.1fb", temoinAgile.distanceMini, avecAgile.distanceMini))

  local sorties = etatAgile.sorties
  verifier("missile detecte et engage", (contient(sorties, "MENACE ENTRANTE")))
  verifier("contact reconnu comme autoguidage (manoeuvrant)",
    (contient(sorties, "contact MANOEUVRANT")))
  verifier("marqueur GUIDE porte dans le journal", (contient(sorties, "GUIDE(")))
  verifier("vitesse radar corrigee de la vitesse propre du navire",
    (contient(sorties, "radar (corrigee)")) or (contient(sorties, "(derivee")))
  verifier("le navire a reellement change de cap",
    math.abs(((etatAgile.navire.cap or 0) + 180) % 360 - 180) > 20,
    tostring(etatAgile.navire.cap))

  -- Profil 2 : missile lourd, peu manoeuvrant. C'est la que l'evasion paie le plus.
  local lourd = profil(40, 8, 300)
  local temoinLourd = passage(false, lourd)
  local avecLourd = passage(true, lourd)
  verifier("missile lourd : l'evasion multiplie la distance de passage",
    avecLourd.distanceMini > temoinLourd.distanceMini * 2,
    string.format("%.1fb -> %.1fb", temoinLourd.distanceMini, avecLourd.distanceMini))

  print(string.format("     [mesure] agile : %.1fb sans evasion -> %.1fb avec | "
    .. "lourd : %.1fb -> %.1fb", temoinAgile.distanceMini, avecAgile.distanceMini,
    temoinLourd.distanceMini, avecLourd.distanceMini))
end

print(string.format("\n===== %d/%d verifications reussies =====", total - echecs, total))
os.exit(echecs == 0 and 0 or 1)
