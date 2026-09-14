-- Banc d'essai du systeme de livraison FrenchNet, hors du jeu, sur Lua 5.4.
--   Usage : lua5.4 tests/test_livraison.lua   (depuis la racine du depot)
--
-- Simule CraftOS via tests/craftos.lua : evenements, minuteurs, rednet, modem,
-- GPS, parallel, et surtout des INVENTAIRES conformes au contrat de l'API
-- "inventory" de CC: Tweaked (list() creuse, pushItems/pullItems plafonnes a
-- une pile par appel).
--
-- Couvre le fonctionnement nominal ET les pannes : paiement jamais depose,
-- autopilote absent, redemarrage hors zone de securite, commandes publiques
-- malveillantes, configuration invalide.

local RACINE = (arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."
local SCR    = RACINE .. "/tests"
local BANC   = "/tmp/banc_livraison_frenchnet"

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

local function ecrire(chemin, contenu)
  local f = assert(io.open(chemin, "w"))
  f:write(contenu)
  f:close()
end

local function titre(texte)
  print("")
  print("== " .. texte)
end

--------------------------------------------------------------------------------
-- A. PROTOCOLE (test unitaire pur, sans emulateur)
--------------------------------------------------------------------------------

titre("A. Protocole : validation des commandes publiques et tarification")

local Protocole = assert(loadfile(RACINE .. "/commun/protocole.lua"))()

local function commandeType(modifs)
  local c = {
    id = "CMD-1-1", client = "Faction Rouge", vitesse = "slow",
    destination = { x = 400, y = 80, z = -250 },
    articles = { { nom = "minecraft:cobblestone", quantite = 128 } },
    paiement = { objet = "minecraft:diamond", quantite = 5 },
  }
  for cle, valeur in pairs(modifs or {}) do c[cle] = valeur end
  return c
end

verifier("commande nominale acceptee", Protocole.validerCommande(commandeType()))
verifier("vitesse inconnue refusee",
  not Protocole.validerCommande(commandeType({ vitesse = "turbo" })))
verifier("quantite negative refusee",
  not Protocole.validerCommande(commandeType({
    articles = { { nom = "minecraft:cobblestone", quantite = -5 } } })))
verifier("quantite decimale refusee",
  not Protocole.validerCommande(commandeType({
    articles = { { nom = "minecraft:cobblestone", quantite = 1.5 } } })))
verifier("altitude aberrante refusee",
  not Protocole.validerCommande(commandeType({ destination = { x = 0, y = 5000, z = 0 } })))
verifier("coordonnee non numerique refusee",
  not Protocole.validerCommande(commandeType({ destination = { x = "loin", y = 80, z = 0 } })))
verifier("commande sans article refusee",
  not Protocole.validerCommande(commandeType({ articles = {} })))
verifier("trop de lignes refuse", (function()
  local articles = {}
  for i = 1, 20 do articles[i] = { nom = "objet" .. i, quantite = 1 } end
  return not Protocole.validerCommande(commandeType({ articles = articles }),
    { maxLignes = 12 })
end)())
verifier("quantite au-dela du plafond refusee",
  not Protocole.validerCommande(commandeType({
    articles = { { nom = "minecraft:cobblestone", quantite = 999999 } } }),
    { maxQuantite = 100000 }))
verifier("destination hors zone refusee",
  not Protocole.validerCommande(commandeType({ destination = { x = 900000, y = 80, z = 0 } }),
    { maxPortee = 100000 }))

local tarif = {
  objetPaiement = "minecraft:diamond", forfaitBase = 5, prixUnitaireDefaut = 0.01,
  parObjet = { ["minecraft:diamond"] = 0.5 },
  coefficientVitesse = { fast = 2.0, slow = 1.0 }, prixMinimum = 1,
}
local prixLent   = Protocole.calculerPaiement(
  { { nom = "minecraft:cobblestone", quantite = 100 } }, "slow", tarif)
local prixRapide = Protocole.calculerPaiement(
  { { nom = "minecraft:cobblestone", quantite = 100 } }, "fast", tarif)
verifier("prix slow ship = forfait + unitaire", prixLent.quantite == 6,
  "obtenu " .. prixLent.quantite)
verifier("prix fast ship strictement superieur au slow ship",
  prixRapide.quantite > prixLent.quantite,
  ("fast=%d slow=%d"):format(prixRapide.quantite, prixLent.quantite))
verifier("tarif specifique par objet applique",
  Protocole.calculerPaiement({ { nom = "minecraft:diamond", quantite = 10 } },
    "slow", tarif).quantite == 10)
verifier("distance euclidienne exacte",
  math.abs(Protocole.distance({ x = 0, y = 0, z = 0 }, { x = 3, y = 4, z = 0 }) - 5) < 1e-9)

--------------------------------------------------------------------------------
-- B. INVENTAIRES (pushItems / pullItems sous emulateur)
--------------------------------------------------------------------------------

titre("B. Inventaires : prelevement exact sur un bulk container Create")

local PROGRAMME_INVENTAIRE = [[
local Inv = (function()
  local f = fs.open("commun/inventaire.lua", "r")
  local source = f.readAll()
  f.close()
  return load(source, "@commun/inventaire.lua", "t", _ENV)()
end)()

-- 1. Prelevement d'une quantite exacte dans un conteneur de 50 000 objets.
local n, err = Inv.transferer("create:item_vault_0", "minecraft:barrel_0",
  "minecraft:cobblestone", 1000)
print("TRANSFERE=" .. tostring(n) .. " ERR=" .. tostring(err))

-- 2. Le reste du stock ne doit pas avoir bouge.
local source = Inv.contenu("create:item_vault_0")
print("RESTE_COBBLE=" .. tostring(source.totaux["minecraft:cobblestone"]))
print("RESTE_FER=" .. tostring(source.totaux["minecraft:iron_ingot"]))

-- 3. Un objet absent ne provoque pas d'erreur fatale, juste un compte nul.
local n2 = Inv.transferer("create:item_vault_0", "minecraft:barrel_0",
  "minecraft:netherite_ingot", 10)
print("ABSENT=" .. tostring(n2))

-- 4. Demander plus que le stock : on prend tout ce qu'il y a, sans planter.
local n3, err3 = Inv.transferer("create:item_vault_0", "minecraft:barrel_0",
  "minecraft:iron_ingot", 999999)
print("TROP=" .. tostring(n3) .. " ERR3=" .. tostring(err3 ~= nil))

-- 5. Vidage complet vers le coffre du destinataire.
local deplace, restant = Inv.vider("minecraft:barrel_0", "minecraft:chest_reception")
print("VIDE=" .. tostring(deplace) .. " RESTANT=" .. tostring(restant))

-- 6. Catalogue agrege avec libelles.
local articles = Inv.catalogue({ "create:item_vault_0" }, true)
print("CATALOGUE=" .. tostring(#articles))
for _, a in ipairs(articles) do print("ART=" .. a.nom .. ":" .. a.quantite) end

-- 7. Detection des inventaires visibles.
print("VISIBLES=" .. tostring(#Inv.inventairesVisibles()))
]]

do
  os.execute("rm -rf " .. BANC .. " && mkdir -p " .. BANC .. "/commun")
  os.execute("cp " .. RACINE .. "/commun/inventaire.lua " .. BANC .. "/commun/")
  ecrire(BANC .. "/banc_inventaire.lua", PROGRAMME_INVENTAIRE)

  local craftos = dofile(SCR .. "/craftos.lua")
  craftos.creer({
    racine = BANC,
    programme = "banc_inventaire.lua",
    gps = { x = 100, y = 72, z = 100 },
    inventaires = {
      ["create:item_vault_0"] = { taille = 64, contenu = {
        [1] = { name = "minecraft:cobblestone", count = 50000, displayName = "Pierre" },
        [2] = { name = "minecraft:iron_ingot", count = 5000, displayName = "Lingot de fer" },
      } },
      ["minecraft:barrel_0"]        = { taille = 256, contenu = {} },
      ["minecraft:chest_reception"] = { taille = 256, contenu = {} },
    },
  })
  local motif, etat = craftos.executer(BANC .. "/banc_inventaire.lua", 600)
  local sorties = etat.sorties

  verifier("programme d'inventaire termine sans erreur",
    motif == "PLUS_D_EVENEMENTS" or motif == "LIMITE_TEMPS", motif)
  verifier("1000 objets preleves exactement", contient(sorties, "TRANSFERE=1000 ERR=nil"))
  verifier("le reste du stock de pierre est intact", contient(sorties, "RESTE_COBBLE=49000"))
  verifier("le stock de fer n'a pas ete touche par le premier transfert",
    contient(sorties, "RESTE_FER=5000"))
  verifier("objet absent : zero deplace, pas de plantage", contient(sorties, "ABSENT=0"))
  verifier("demande superieure au stock : tout le stock est pris",
    contient(sorties, "TROP=5000"))
  verifier("demande superieure au stock : incompletude signalee",
    contient(sorties, "ERR3=true"))
  verifier("vidage complet de la soute", contient(sorties, "VIDE=6000 RESTANT=0"))
  -- Le fer a entierement ete preleve a l'etape 4 : il ne reste que la pierre.
  verifier("catalogue : un seul type restant apres prelevement total du fer",
    contient(sorties, "CATALOGUE=1"))
  verifier("catalogue : quantite de pierre restante exacte",
    contient(sorties, "ART=minecraft:cobblestone:49000"))
  verifier("trois inventaires visibles sur le reseau", contient(sorties, "VISIBLES=3"))
  verifier("plus d'une pile par appel impossible : bouclage effectif",
    etat.appelsPush >= 1000 / 64, "appels push = " .. etat.appelsPush)
end

--------------------------------------------------------------------------------
-- C a H. NAVIRE COMPLET
--------------------------------------------------------------------------------

-- Autopilote factice : il expose EXACTEMENT l'API du module reel
-- (nouveau / initialiser / allerA / attendreArrivee / etat / executer /
-- maintenirPosition / arreter / surEvenement / rejoindreRavitaillement) et
-- reproduit les deux proprietes dont depend le systeme de livraison :
--   1. rien n'aboutit tant que executer() ne tourne pas en parallele ;
--   2. c'est LUI qui applique le decalage de depot, pas le programme appelant.
-- Il ne simule aucune dynamique de vol : le trajet dure une seconde.
local AUTOPILOTE_FACTICE = [[
local autopilote = {}
autopilote.VERSION = "banc-1.0"
autopilote.CHEMIN_CONFIG_DEFAUT = "/autopilote/config_vehicule.lua"

local function charger(chemin)
  local f = fs.open(chemin, "r")
  local source = f.readAll()
  f.close()
  return load(source, "@" .. chemin, "t", _ENV)()
end

function autopilote.nouveau(options)
  options = options or {}
  local config = charger(options.config or autopilote.CHEMIN_CONFIG_DEFAUT)
  if type(config.identifiant) ~= "string" or config.identifiant == "" then
    error("configuration vehicule invalide -> 'identifiant' manquant", 0)
  end

  local ap = { config = config, VERSION = autopilote.VERSION }
  local position, mission, rappels = nil, nil, {}
  local dGps   = config.decalageGps or { x = 0, y = 0, z = 0 }
  local dDepot = config.decalageDepot or { x = 0, y = 0, z = 0 }

  local function emettre(type_, donnees)
    for _, f in ipairs(rappels) do pcall(f, type_, donnees) end
    os.queueEvent("autopilote", config.identifiant, type_, donnees or {})
  end

  function ap.surEvenement(f) rappels[#rappels + 1] = f end

  function ap.initialiser()
    local x, y, z = gps.locate(2)
    if x then position = { x = x - dGps.x, y = y - dGps.y, z = z - dGps.z } end
    return ap
  end

  function ap.etat()
    return {
      identifiant = config.identifiant, nom = config.nom,
      mode = mission and "TRANSIT" or "MAINTIEN",
      position = position and { x = position.x, y = position.y, z = position.z } or nil,
    }
  end

  function ap.allerA(point, optionsMission)
    if type(point) ~= "table" or type(point.x) ~= "number" then
      error("point de passage invalide", 0)
    end
    mission = { x = point.x, y = point.y, z = point.z,
                type = point.type or "survol", nom = point.nom }
    os.queueEvent("banc_mission")
    return ap
  end

  function ap.suivreItineraire(points, o) return ap.allerA(points[#points], o) end

  function ap.rejoindreRavitaillement(o)
    local r = config.ravitaillement or { x = 0, y = 70, z = 0 }
    return ap.allerA({ x = r.x, y = r.y, z = r.z, type = "atterrissage",
                       nom = "RAVITAILLEMENT" }, o)
  end

  function ap.maintenirPosition() mission = nil return ap end
  function ap.arreter() mission = nil return ap end
  function ap.estArrive() return mission == nil end

  function ap.attendreArrivee(delai)
    if mission == nil then return true end
    local minuteur = delai and os.startTimer(delai) or nil
    while true do
      local ev = table.pack(os.pullEvent())
      if ev[1] == "autopilote" and ev[2] == config.identifiant and ev[3] == "arrivee" then
        return true, ev[4]
      elseif ev[1] == "timer" and minuteur and ev[2] == minuteur then
        return false, "delai depasse"
      end
    end
  end

  -- LA BOUCLE DE VOL : sans elle, aucune mission n'aboutit jamais.
  function ap.executer()
    ap.initialiser()
    while true do
      local ev = table.pack(os.pullEvent())
      if ev[1] == "banc_mission" and mission then
        local cible = { x = mission.x, y = mission.y, z = mission.z }
        if mission.type == "depot" or mission.type == "atterrissage" then
          cible.x = cible.x - dDepot.x
          cible.y = cible.y - dDepot.y
          cible.z = cible.z - dDepot.z
        end
        sleep(4)   -- le trajet dure un instant : sans cela il serait atomique
        position = cible
        __bancGps(cible.x + dGps.x, cible.y + dGps.y, cible.z + dGps.z)
        mission = nil
        emettre("arrivee", { ecart = 0 })
      end
    end
  end

  return ap
end

return autopilote
]]

-- Fichier de configuration PAR VEHICULE : celui de l'autopilote, auquel les
-- pages de livraison ont ete ajoutees. C'est la disposition recommandee, et
-- c'est donc elle que le banc d'essai eprouve.
local function configVehicule(remplacements)
  local modele = [[
return {
  nom         = "Navire d'essai",
  identifiant = "@@IDENTIFIANT@@",

  -- ---- sections appartenant a l'autopilote --------------------------------
  decalageGps   = { x = 0, y = 2, z = 0 },
  decalageDepot = { x = 0, y = -3, z = 0 },
  decalageDansRepereVehicule = false,
  gabarit    = { longueur = 20, largeur = 10, hauteur = 8 },
  tolerances = { horizontale = 1.5, altitude = 1.0, cap = 4.0 },
  vitesses   = { croisiere = 8.0, verticaleMax = 4.0, approche = 2.0 },
  gains      = { altitude = { position = { kp = 1 } } },
  pilotage   = { mode = "auto" },
  ravitaillement = { x = 100, y = 70, z = 120 },

  -- ---- pages ajoutees par le systeme de livraison --------------------------
  autopilote = {
    chemin          = "/autopilote/autopilote.lua",
    delaiArriveeMax = 120,
  },
  conteneurs = @@CONTENEURS@@,
  livraison = {
    conteneursSource     = { "create:item_vault_0" },
    pointChargement      = { x = 100, y = 70, z = 100 },
    distanceChargement   = 24,
    motifPaiement        = "paiement",
    delaiPaiementMax     = @@DELAI_PAIEMENT@@,
    intervallePaiement   = 5,
    rappelPaiementToutes = 10,
    choixRetour          = "auto",
    pointsRetour = {
      { nom = "BASE", x = 100, y = 70, z = 100, principal = true, rayonSecurite = 32 },
    },
    facteurVitesseLente = 0.6,
    limites = { maxLignes = 12, maxQuantite = 100000, maxPortee = 100000, fileMax = 20 },
  },
  tarif = {
    objetPaiement      = "minecraft:diamond",
    forfaitBase        = 5,
    prixUnitaireDefaut = 0,
    parObjet           = {},
    coefficientVitesse = { fast = 2.0, slow = 1.0 },
    prixMinimum        = 1,
  },
  reseau     = { diffusionEtat = 30, diffusionCatalogue = 120 },
  journal    = { fichier = "navire/livraison.log", tailleMax = 131072, niveauEcran = "DEBUG" },
  robustesse = { redemarrageDelaiMin = 3, redemarrageDelaiMax = 10,
                 arretParTerminate = true, etat = "navire/etat.dat" },
}
]]
  local valeurs = {
    IDENTIFIANT = "DIRI-TEST-01",
    DELAI_PAIEMENT = "0",
    CONTENEURS = [[{
    { nom = "Soute", peripherique = "minecraft:barrel_0",
      decalage = { x = 0, y = -1, z = 2 }, role = "expedition", priorite = 1 },
    { nom = "Recette", peripherique = "minecraft:chest_0",
      decalage = { x = 0, y = 1, z = 0 }, role = "recette", priorite = 1 },
  }]],
  }
  for cle, valeur in pairs(remplacements or {}) do valeurs[cle] = valeur end
  for cle, valeur in pairs(valeurs) do
    modele = modele:gsub("@@" .. cle .. "@@", (valeur:gsub("%%", "%%%%")))
  end
  return modele
end

local function preparerNavire(options)
  options = options or {}
  os.execute("rm -rf " .. BANC)
  os.execute("mkdir -p " .. BANC .. "/commun " .. BANC .. "/navire " .. BANC .. "/autopilote")
  os.execute("cp " .. RACINE .. "/commun/*.lua " .. BANC .. "/commun/")
  os.execute("cp " .. RACINE .. "/navire/livraison.lua " .. RACINE .. "/navire/autopilote.lua "
    .. BANC .. "/navire/")
  ecrire(BANC .. "/autopilote/config_vehicule.lua", configVehicule(options.config))
  if not options.sansAutopilote then
    ecrire(BANC .. "/autopilote/autopilote.lua", AUTOPILOTE_FACTICE)
  end
  if options.recouvrement then
    ecrire(BANC .. "/navire/config_livraison.lua", options.recouvrement)
  end
  if options.etat then
    ecrire(BANC .. "/navire/etat.dat", options.etat)
  end
end

local function inventairesNavire(paiementDepose)
  return {
    ["create:item_vault_0"] = { taille = 64, contenu = {
      [1] = { name = "minecraft:cobblestone", count = 50000, displayName = "Pierre" },
      [2] = { name = "minecraft:iron_ingot", count = 5000, displayName = "Lingot de fer" },
    } },
    ["minecraft:barrel_0"]        = { taille = 256, contenu = {} },
    ["minecraft:chest_0"]         = { taille = 27,  contenu = {} },
    ["minecraft:chest_paiement"]  = { taille = 27, contenu = paiementDepose and {
      [1] = { name = "minecraft:diamond", count = 5 },
    } or {} },
    ["minecraft:chest_reception"] = { taille = 256, contenu = {} },
  }
end

local function commandeRednet(modifs)
  local commande = {
    id = "CMD-TEST-1", client = "Faction Rouge", vitesse = "slow",
    destination = { x = 400, y = 80, z = -250 },
    articles = {
      { nom = "minecraft:cobblestone", quantite = 128 },
      { nom = "minecraft:iron_ingot", quantite = 64 },
    },
    paiement = { objet = "minecraft:diamond", quantite = 5 },
  }
  for cle, valeur in pairs(modifs or {}) do commande[cle] = valeur end
  return {
    protocole = "FRENCHNET_LIVRAISON", version = 1, type = "COMMANDE",
    commande = commande,
  }
end

local function lancerNavire(craftos, options)
  craftos.creer({
    racine    = BANC,
    programme = "navire/livraison.lua",
    id        = 11,
    -- Position GPS du CALCULATEUR : centre du navire + decalageGps (0, 2, 0).
    gps       = options.gps or { x = 100, y = 75, z = 100 },
    inventaires = options.inventaires or inventairesNavire(true),
  })
  for _, action in ipairs(options.actions or {}) do
    craftos.planifier(action.t, action.fn)
  end
  return craftos.executer(BANC .. "/navire/livraison.lua", options.secondes or 500)
end

local function accuses(etat)
  local resultat = {}
  for _, envoi in ipairs(etat.envois) do
    if envoi.message and envoi.message.type == "ACCUSE" then
      resultat[#resultat + 1] = envoi.message
    end
  end
  return resultat
end

--------------------------------------------------------------------------------
titre("C. Livraison nominale de bout en bout")
--------------------------------------------------------------------------------

do
  preparerNavire()
  local craftos = dofile(SCR .. "/craftos.lua")
  local trace = {}
  local function echantillonner(m, e)
    if e.gps then
      trace[#trace + 1] = ("%d/%d/%d"):format(e.gps.x, e.gps.y, e.gps.z)
    end
    m.planifier(m.horloge() + 1, echantillonner)
  end
  local motif, etat = lancerNavire(craftos, {
    actions = {
      { t = 1, fn = echantillonner },
      { t = 12, fn = function(m)
        m.injecterRednet(42, commandeRednet(), "frenchnet_livraison")
      end },
    },
    secondes = 500,
  })
  local sorties = etat.sorties

  verifier("le programme tourne jusqu'au bout du temps imparti",
    motif == "LIMITE_TEMPS", motif)
  verifier("commande acceptee et accusee au client", (function()
    local liste = accuses(etat)
    return #liste > 0 and liste[1].accepte == true
  end)(), "accuses = " .. #accuses(etat))
  verifier("prix recalcule a bord : 5 diamants", (function()
    local liste = accuses(etat)
    return #liste > 0 and liste[1].paiement and liste[1].paiement.quantite == 5
  end)())
  verifier("chargement journalise", contient(sorties, "chargement complet de la commande"))
  verifier("ordre de vol transmis a l'autopilote en coordonnees brutes",
    contient(sorties, "ordre de vol : depot 400 80 -250"))
  verifier("arrivee confirmee par l'autopilote",
    contient(sorties, "arrive au point de depot 400 80 -250"))
  verifier("le decalage de depot est applique par l'AUTOPILOTE, pas ici",
    (function()
      -- Le programme ne calcule aucune cible : il transmet 400/80/-250 et
      -- c'est l'autopilote qui place le centre du navire en 400/83/-250.
      local gps = etat.gps
      return not contient(sorties, "cible du centre navire")
    end)())
  verifier("boucle de vol de l'autopilote lancee en parallele",
    contient(sorties, "demarrage de la boucle de vol de l'autopilote"))
  verifier("paiement detecte", contient(sorties, "paiement detecte"))
  verifier("commande terminee", contient(sorties, "commande CMD-TEST-1 terminee"))
  verifier("retour automatique a la base", contient(sorties, "navire rentre au point 'BASE'"))

  local vault = craftos.contenu("create:item_vault_0")
  verifier("stock source : exactement 128 pierres prelevees",
    vault["minecraft:cobblestone"] == 50000 - 128,
    tostring(vault["minecraft:cobblestone"]))
  verifier("stock source : exactement 64 lingots preleves",
    vault["minecraft:iron_ingot"] == 5000 - 64, tostring(vault["minecraft:iron_ingot"]))

  local recu = craftos.contenu("minecraft:chest_reception")
  verifier("client livre : 128 pierres", recu["minecraft:cobblestone"] == 128,
    tostring(recu["minecraft:cobblestone"]))
  verifier("client livre : 64 lingots", recu["minecraft:iron_ingot"] == 64,
    tostring(recu["minecraft:iron_ingot"]))

  local paiement = craftos.contenu("minecraft:chest_paiement")
  verifier("coffre de paiement vide apres encaissement",
    paiement["minecraft:diamond"] == nil, tostring(paiement["minecraft:diamond"]))
  local recette = craftos.contenu("minecraft:chest_0")
  verifier("recette du navire : 5 diamants encaisses",
    recette["minecraft:diamond"] == 5, tostring(recette["minecraft:diamond"]))

  local soute = craftos.contenu("minecraft:barrel_0")
  verifier("soute vide apres livraison", next(soute) == nil)

  verifier("navire revenu a la position de base",
    etat.gps and etat.gps.x == 100 and etat.gps.z == 100,
    etat.gps and (etat.gps.x .. "/" .. etat.gps.y .. "/" .. etat.gps.z) or "nil")

  -- Preuve que le decalage de depot a bien ete applique par l'autopilote :
  -- depot demande en 400/80/-250, decalageDepot (0,-3,0), donc centre du
  -- navire en 400/83/-250, donc calculateur (decalageGps 0,2,0) en 400/85/-250.
  verifier("le navire s'est bien place pour que la soute tombe sur la cible",
    (function()
      for _, position in ipairs(trace) do
        if position == "400/85/-250" then return true end
      end
      return false
    end)(), table.concat(trace, " "))
end

--------------------------------------------------------------------------------
titre("D. Le paiement arrive en retard : le navire attend en boucle")
--------------------------------------------------------------------------------

do
  preparerNavire()   -- delaiPaiementMax = 0 : attente illimitee
  local craftos = dofile(SCR .. "/craftos.lua")
  local motif, etat = lancerNavire(craftos, {
    inventaires = inventairesNavire(false),   -- coffre de paiement vide au depart
    actions = {
      { t = 12, fn = function(m)
        m.injecterRednet(42, commandeRednet(), "frenchnet_livraison")
      end },
      { t = 200, fn = function(m)
        m.deposer("minecraft:chest_paiement", "minecraft:diamond", 5)
      end },
    },
    secondes = 600,
  })
  local sorties = etat.sorties

  verifier("attente du paiement journalisee", contient(sorties, "attente de 5 x minecraft:diamond"))
  verifier("relance periodique pendant l'attente",
    contient(sorties, "paiement incomplet : 0 / 5 x minecraft:diamond"))
  verifier("paiement detecte des qu'il est depose", contient(sorties, "paiement detecte"))
  verifier("livraison effectuee apres l'attente",
    contient(sorties, "commande CMD-TEST-1 terminee"))

  local recu = craftos.contenu("minecraft:chest_reception")
  verifier("marchandise livree apres paiement tardif",
    recu["minecraft:cobblestone"] == 128 and recu["minecraft:iron_ingot"] == 64)
end

--------------------------------------------------------------------------------
titre("E. Le paiement n'arrive jamais : abandon au delai configure")
--------------------------------------------------------------------------------

do
  preparerNavire({ config = { DELAI_PAIEMENT = "30" } })
  local craftos = dofile(SCR .. "/craftos.lua")
  local motif, etat = lancerNavire(craftos, {
    inventaires = inventairesNavire(false),
    actions = {
      { t = 12, fn = function(m)
        m.injecterRednet(42, commandeRednet(), "frenchnet_livraison")
      end },
    },
    secondes = 400,
  })
  local sorties = etat.sorties

  verifier("abandon apres le delai de paiement",
    contient(sorties, "paiement non recu apres 30 s"))
  verifier("commande declaree abandonnee",
    contient(sorties, "commande CMD-TEST-1 abandonnee"))
  verifier("rien n'est livre sans paiement", (function()
    local recu = craftos.contenu("minecraft:chest_reception")
    return next(recu) == nil
  end)())
  verifier("la cargaison repart avec le navire", (function()
    local soute = craftos.contenu("minecraft:barrel_0")
    return soute["minecraft:cobblestone"] == 128
  end)())
  verifier("retour a la base malgre l'echec", contient(sorties, "navire rentre au point 'BASE'"))
end

--------------------------------------------------------------------------------
titre("F. Autopilote absent : aucun vol, aucune commande engagee")
--------------------------------------------------------------------------------

do
  preparerNavire({ sansAutopilote = true })
  local craftos = dofile(SCR .. "/craftos.lua")
  local motif, etat = lancerNavire(craftos, {
    actions = {
      { t = 12, fn = function(m)
        m.injecterRednet(42, commandeRednet(), "frenchnet_livraison")
      end },
    },
    secondes = 300,
  })
  local sorties = etat.sorties

  verifier("indisponibilite de l'autopilote signalee en CRITIQUE",
    contient(sorties, "AUCUN VOL POSSIBLE"))
  verifier("le module manquant est nomme",
    contient(sorties, "module d'autopilote introuvable (/autopilote/autopilote.lua)"))
  verifier("le navire previent qu'il ne decollera pas",
    contient(sorties, "le navire accepte les commandes mais ne decollera pas"))
  verifier("la commande est tout de meme acceptee et mise en file", (function()
    local liste = accuses(etat)
    return #liste > 0 and liste[1].accepte == true
  end)())
  verifier("aucun objet n'a ete preleve dans le stock source", (function()
    local vault = craftos.contenu("create:item_vault_0")
    return vault["minecraft:cobblestone"] == 50000 and vault["minecraft:iron_ingot"] == 5000
  end)())
  verifier("aucune livraison effectuee", not contient(sorties, "commande CMD-TEST-1 terminee"))
end

--------------------------------------------------------------------------------
titre("G. Redemarrage hors zone de securite avec une commande en file")
--------------------------------------------------------------------------------

do
  preparerNavire({ etat = [[{
  version = 1,
  phase = "REPOS",
  livraisons = 3,
  file = {
    {
      id = "CMD-REPRISE-9",
      client = "Faction Bleue",
      vitesse = "slow",
      destination = { x = 400, y = 80, z = -250 },
      articles = { { nom = "minecraft:cobblestone", quantite = 64 } },
      paiement = { objet = "minecraft:diamond", quantite = 5 },
    },
  },
}]] })
  local craftos = dofile(SCR .. "/craftos.lua")
  local motif, etat = lancerNavire(craftos, {
    gps = { x = 900, y = 82, z = 900 },   -- loin de tout point de retour
    secondes = 500,
  })
  local sorties = etat.sorties

  verifier("etat repris depuis le disque",
    contient(sorties, "etat repris : phase=REPOS"))
  verifier("commande en file retrouvee apres redemarrage",
    contient(sorties, "file=1"))
  verifier("position hors zone de securite detectee",
    contient(sorties, "hors de tout point de securite"))
  verifier("rejoint un point de securite avant de reprendre",
    contient(sorties, "navire rentre au point 'BASE'"))
  verifier("la commande reprise est ensuite livree",
    contient(sorties, "commande CMD-REPRISE-9 terminee"))
  verifier("compteur de livraisons repris (3 -> 4)",
    contient(sorties, "livraison n4"))
end

--------------------------------------------------------------------------------
titre("H. Redemarrage DEJA a un point de securite : le navire ne bouge pas")
--------------------------------------------------------------------------------

do
  preparerNavire()
  local craftos = dofile(SCR .. "/craftos.lua")
  local motif, etat = lancerNavire(craftos, {
    gps = { x = 108, y = 75, z = 104 },   -- a 9 blocs de la base, dans le rayon
    secondes = 120,
  })
  local sorties = etat.sorties

  verifier("point de securite reconnu au demarrage",
    contient(sorties, "navire deja au point de securite 'BASE'"))
  verifier("aucun ordre de vol emis", not contient(sorties, "ordre de vol :"))
  verifier("la position n'a pas change",
    etat.gps.x == 108 and etat.gps.y == 75 and etat.gps.z == 104,
    etat.gps.x .. "/" .. etat.gps.y .. "/" .. etat.gps.z)
end

--------------------------------------------------------------------------------
titre("I. Commandes publiques malveillantes ou malformees")
--------------------------------------------------------------------------------

do
  preparerNavire({ sansAutopilote = true })   -- on ne teste que le filtre d'entree
  local craftos = dofile(SCR .. "/craftos.lua")
  local motif, etat = lancerNavire(craftos, {
    actions = {
      { t = 12, fn = function(m)
        m.injecterRednet(50, commandeRednet({ id = "A", vitesse = "turbo" }),
          "frenchnet_livraison")
        m.injecterRednet(51, commandeRednet({ id = "B",
          destination = { x = 400, y = 9999, z = -250 } }), "frenchnet_livraison")
        m.injecterRednet(52, commandeRednet({ id = "C",
          articles = { { nom = "minecraft:cobblestone", quantite = -10 } } }),
          "frenchnet_livraison")
        m.injecterRednet(53, commandeRednet({ id = "D",
          articles = { { nom = "minecraft:cobblestone", quantite = 500000 } } }),
          "frenchnet_livraison")
        m.injecterRednet(54, { protocole = "AUTRE_CHOSE", type = "COMMANDE" },
          "frenchnet_livraison")
        m.injecterRednet(55, commandeRednet({ id = "E" }), "frenchnet_livraison")
      end },
    },
    secondes = 200,
  })
  local sorties = etat.sorties
  local liste = accuses(etat)

  local refus, acceptations = 0, 0
  for _, a in ipairs(liste) do
    if a.accepte then acceptations = acceptations + 1 else refus = refus + 1 end
  end

  verifier("quatre commandes invalides refusees", refus == 4, "refus = " .. refus)
  verifier("la commande valide est acceptee", acceptations == 1,
    "acceptations = " .. acceptations)
  verifier("motif de refus explicite pour la vitesse",
    contient(sorties, "niveau de vitesse inconnu"))
  verifier("motif de refus explicite pour l'altitude",
    contient(sorties, "altitude de depot hors limites"))
  verifier("message d'un autre protocole ignore sans accuse", #liste == 5,
    "accuses = " .. #liste)
end

--------------------------------------------------------------------------------
titre("J. fast ship prioritaire sur slow ship dans la file")
--------------------------------------------------------------------------------

do
  preparerNavire({ sansAutopilote = true })   -- file figee : rien n'est defile
  local craftos = dofile(SCR .. "/craftos.lua")
  local motif, etat = lancerNavire(craftos, {
    actions = {
      { t = 12, fn = function(m)
        m.injecterRednet(60, commandeRednet({ id = "LENT-1", vitesse = "slow" }),
          "frenchnet_livraison")
        m.injecterRednet(61, commandeRednet({ id = "LENT-2", vitesse = "slow" }),
          "frenchnet_livraison")
        m.injecterRednet(62, commandeRednet({ id = "RAPIDE-1", vitesse = "fast" }),
          "frenchnet_livraison")
        m.injecterRednet(63, commandeRednet({ id = "RAPIDE-2", vitesse = "fast" }),
          "frenchnet_livraison")
      end },
    },
    secondes = 200,
  })
  local liste = accuses(etat)
  local rang = {}
  for _, a in ipairs(liste) do rang[a.commande] = a.rang end

  verifier("premiere commande lente en rang 1", rang["LENT-1"] == 1, tostring(rang["LENT-1"]))
  verifier("seconde commande lente en rang 2", rang["LENT-2"] == 2, tostring(rang["LENT-2"]))
  verifier("fast ship double les slow ship", rang["RAPIDE-1"] == 1, tostring(rang["RAPIDE-1"]))
  verifier("fast ship ne double pas une autre fast ship", rang["RAPIDE-2"] == 2,
    tostring(rang["RAPIDE-2"]))
  verifier("prix fast ship double du prix slow ship", (function()
    local prixLent, prixRapide
    for _, a in ipairs(liste) do
      if a.commande == "LENT-1" then prixLent = a.paiement.quantite end
      if a.commande == "RAPIDE-1" then prixRapide = a.paiement.quantite end
    end
    return prixLent == 5 and prixRapide == 10
  end)())
end

--------------------------------------------------------------------------------
titre("K. Configuration invalide : relance automatique, jamais de blocage")
--------------------------------------------------------------------------------

do
  preparerNavire({ config = { CONTENEURS = "{}" } })
  local craftos = dofile(SCR .. "/craftos.lua")
  local motif, etat = lancerNavire(craftos, { secondes = 120 })
  local sorties = etat.sorties

  verifier("configuration invalide detectee",
    contient(sorties, "aucun conteneur de cargaison declare"))
  verifier("plantage journalise avec son etape",
    contient(sorties, "etape: validation de la configuration vehicule"))
  verifier("relance automatique programmee", contient(sorties, "relance automatique n1"))
  verifier("temporisation progressive a la deuxieme relance",
    contient(sorties, "relance automatique n2"))
end

--------------------------------------------------------------------------------
titre("L. Recouvrement facultatif : navire/config_livraison.lua a le dernier mot")
--------------------------------------------------------------------------------

do
  -- La grille tarifaire du fichier vehicule annonce 5 diamants ; le
  -- recouvrement la remplace par 9. C'est lui qui doit l'emporter.
  preparerNavire({ sansAutopilote = true, recouvrement = [[
return {
  tarif = {
    objetPaiement      = "minecraft:diamond",
    forfaitBase        = 9,
    prixUnitaireDefaut = 0,
    parObjet           = {},
    coefficientVitesse = { fast = 2.0, slow = 1.0 },
    prixMinimum        = 1,
  },
}
]] })
  local craftos = dofile(SCR .. "/craftos.lua")
  local motif, etat = lancerNavire(craftos, {
    actions = {
      { t = 12, fn = function(m)
        m.injecterRednet(42, commandeRednet(), "frenchnet_livraison")
      end },
    },
    secondes = 200,
  })

  local liste = accuses(etat)
  verifier("le recouvrement remplace le tarif du fichier vehicule",
    #liste > 0 and liste[1].paiement and liste[1].paiement.quantite == 9,
    #liste > 0 and tostring(liste[1].paiement and liste[1].paiement.quantite) or "aucun accuse")
  verifier("les sections non recouvertes restent celles du fichier vehicule",
    contient(etat.sorties, "3 point(s) de retour")
      or contient(etat.sorties, "1 point(s) de retour"))
end

--------------------------------------------------------------------------------
titre("M. Borne publique : parcours complet d'une commande")
--------------------------------------------------------------------------------

do
  os.execute("rm -rf " .. BANC)
  os.execute("mkdir -p " .. BANC .. "/commun " .. BANC .. "/borne")
  os.execute("cp " .. RACINE .. "/commun/*.lua " .. BANC .. "/commun/")
  os.execute("cp " .. RACINE .. "/borne/borne.lua " .. RACINE .. "/borne/config_borne.lua "
    .. BANC .. "/borne/")

  local craftos = dofile(SCR .. "/craftos.lua")
  local _, etat = craftos.creer({
    racine    = BANC,
    programme = "borne/borne.lua",
    id        = 7,
    gps       = { x = 100, y = 72, z = 100 },
    inventaires = {},
    -- Frappes du client, dans l'ordre ou la borne les demande.
    entrees = {
      "1",              -- menu : passer une commande
      "1",              -- premier article du catalogue
      "128",            -- quantite
      "v",              -- valider le panier
      "2",              -- slow ship
      "400", "80", "-250",  -- coordonnees de depot
      "Faction Rouge",  -- nom du client
      "o",              -- confirmer l'envoi
      "q",              -- quitter la borne
    },
  })

  local CATALOGUE = {
    protocole = "FRENCHNET_LIVRAISON", version = 1, type = "CATALOGUE",
    navire = "DIRI-TEST-01", nomNavire = "Navire d'essai",
    articles = {
      { nom = "minecraft:cobblestone", quantite = 50000, libelle = "Pierre" },
      { nom = "minecraft:iron_ingot", quantite = 5000, libelle = "Lingot de fer" },
    },
    tarif = {
      objetPaiement = "minecraft:diamond", forfaitBase = 5, prixUnitaireDefaut = 0,
      parObjet = {}, coefficientVitesse = { fast = 2.0, slow = 1.0 }, prixMinimum = 1,
    },
    limites = { maxLignes = 12, maxQuantite = 100000, maxPortee = 100000, fileMax = 20 },
    etat = { phase = "REPOS", file = 0, livraisons = 12, autopilote = true },
  }

  -- Navire factice : repond a chaque diffusion de la borne, et alimente la file
  -- d'evenements clavier attendue par les ecrans de pause.
  local repondu = 0
  local function navireFactice(m)
    while repondu < #etat.diffusions do
      repondu = repondu + 1
      local envoi = etat.diffusions[repondu]
      local type_ = envoi.message and envoi.message.type
      if type_ == "CATALOGUE_DEMANDE" then
        m.injecterRednet(11, CATALOGUE, "frenchnet_livraison")
      elseif type_ == "COMMANDE" then
        m.injecterRednet(11, {
          protocole = "FRENCHNET_LIVRAISON", version = 1, type = "ACCUSE",
          navire = "DIRI-TEST-01", commande = envoi.message.commande.id,
          accepte = true, rang = 1,
          paiement = { objet = "minecraft:diamond", quantite = 5 },
        }, "frenchnet_livraison")
      end
    end
    m.injecterEvenement("key", 57)   -- deverrouille les ecrans de pause
    m.planifier(m.horloge() + 1, navireFactice)
  end
  craftos.planifier(1, navireFactice)

  local motif = craftos.executer(BANC .. "/borne/borne.lua", 300)
  local sorties = etat.sorties

  local commandeEnvoyee
  for _, envoi in ipairs(etat.diffusions) do
    if envoi.message and envoi.message.type == "COMMANDE" then
      commandeEnvoyee = envoi.message.commande
    end
  end

  verifier("la borne a bien emis une commande", commandeEnvoyee ~= nil, motif)
  if commandeEnvoyee then
    verifier("article et quantite saisis par le client",
      commandeEnvoyee.articles[1].nom == "minecraft:cobblestone"
        and commandeEnvoyee.articles[1].quantite == 128,
      commandeEnvoyee.articles[1].nom .. " x " .. commandeEnvoyee.articles[1].quantite)
    verifier("niveau de service slow ship retenu", commandeEnvoyee.vitesse == "slow",
      tostring(commandeEnvoyee.vitesse))
    verifier("coordonnees de depot saisies par le client",
      commandeEnvoyee.destination.x == 400 and commandeEnvoyee.destination.y == 80
        and commandeEnvoyee.destination.z == -250)
    verifier("nom de faction transmis", commandeEnvoyee.client == "Faction Rouge",
      tostring(commandeEnvoyee.client))
    verifier("prix annonce au client : 5 diamants",
      commandeEnvoyee.paiement.quantite == 5 and
      commandeEnvoyee.paiement.objet == "minecraft:diamond",
      tostring(commandeEnvoyee.paiement.quantite))
  end
  verifier("acceptation affichee au client",
    contient(sorties, "Commande acceptee par le navire."))
  verifier("montant a deposer rappele au client",
    contient(sorties, "Montant a deposer : 5 x minecraft:diamond"))
  verifier("les deux niveaux de service sont chiffres a l'ecran",
    contient(sorties, "fast ship") and contient(sorties, "slow ship"))
  verifier("la borne s'arrete proprement sur demande",
    contient(sorties, "[ARRET] arret manuel de la borne."), motif)
end

--------------------------------------------------------------------------------
print("")
print(string.format("== %d verification(s), %d echec(s)", total, echecs))
if echecs > 0 then os.exit(1) end
