--[[----------------------------------------------------------------------------
  CALIBRATION AUTOMATIQUE DU CABLAGE - AUTOPILOTE FRENCHNET
  --------------------------------------------------------------------------
  Tous les vehicules du serveur se dirigent par COURANTS DE REDSTONE. Jusqu'ici
  il fallait declarer a la main, dans config_vehicule.lua, quelle face commande
  quel axe :

      avance = { mode = "analogique", cote = "front", neutre = 0, amplitude = 15 }

  L'outil 'cablage' ne verifiait que le SENS d'un axe deja declare. Personne ne
  cherchait QUELLE FACE FAIT QUOI. C'est le trou que ce module comble : il
  essaie les sorties une par une, regarde ce que le vehicule fait, et en deduit
  la table 'sorties.axes' qu'il reecrit dans la configuration.

  METHODE
  -------
  Une face a la fois, jamais deux :

    1. tout neutraliser, attendre l'immobilite complete ;
    2. relever la position (et le cap si un capteur existe) a l'arret ;
    3. porter LA face testee au niveau d'essai pendant 'impulsion' secondes ;
    4. couper, attendre de nouveau l'immobilite ;
    5. le deplacement observe EST l'effet de cette face.

  Mesurer a l'arret, jamais en mouvement, est volontaire : gps.locate()
  interroge quatre balises qui repondent a des ticks differents. Sur un
  vehicule en mouvement la trilateration renvoie un point faux ; a l'arret elle
  est juste.

  TOUS LES RESEAUX ("essayer tous ses reseaux si necessaire")
  -----------------------------------------------------------
  Les faces candidates sont prises par rangs de cout croissant, et le balayage
  s'arrete des qu'un jeu de commandes complet est acquis :

      rang 1  faces deja declarees dans la configuration   (aucun essai)
      rang 2  les six faces de l'ordinateur maitre
      rang 3  les faces de chaque satellite annonce sur rednet

  LE LACET, ANGLE MORT DU GPS
  ---------------------------
  gps.locate() donne un point, jamais une orientation. Une commande de lacet
  fait pivoter le vehicule sans deplacer son centre : invisible. Trois cas :

    1. un capteur de cap existe (config.cap.source == "peripherique") : on lit
       la variation d'angle directement, c'est le cas confortable ;

    2. pas de capteur, mais l'ordinateur est DECALE du centre du vehicule
       (config.decalageGps horizontal non nul) : une rotation promene alors le
       point GPS sur un cercle. Deux impulsions identiques suffisent a
       trancher -- deux deplacements paralleles = translation, deux
       deplacements tournes l'un par rapport a l'autre = rotation, et le signe
       du produit vectoriel donne le sens ;

    3. ni capteur de cap, ni decalage GPS : le lacet n'est PAS observable. Le
       module le dit franchement et renvoie les faces concernees a l'operateur
       plutot que de les declarer inertes.

  LE PIEGE DU NEUTRE NON NUL
  --------------------------
  Un moteur a marche arriere se cable souvent avec un neutre au milieu de la
  plage (repos = 7 sur 0-15). Pour un tel montage, mettre la face a 0 -- ce que
  fait toute neutralisation -- commande PLEIN GAZ ARRIERE. On mesure donc
  d'abord la derive au repos : si le vehicule bouge alors que tout est a zero,
  le module teste l'hypothese du neutre median et la retient si elle immobilise
  le vehicule.

  Chargement :  local calibration = dofile("/autopilote/calibration.lua")
                -- ou, en injectant le module d'autopilote :
                local calibration = loadfile(chemin)(autopilote)
--------------------------------------------------------------------------------]]

local autopilote = ...
if type(autopilote) ~= "table" then
  autopilote = dofile("/autopilote/autopilote.lua")
end

local I = autopilote.interne
local borner          = I.borner
local normaliserAngle = I.normaliserAngle
local capVers         = I.capVers
local vecteurAvant    = I.vecteurAvant
local vecteurTribord  = I.vecteurTribord
local normeHorizontale= I.normeHorizontale

local calibration = { VERSION = "1.0.0" }

--------------------------------------------------------------------------------
-- 1. NOMENCLATURE DES ETAPES
--------------------------------------------------------------------------------

local ETAPES = {
  PREPARATION   = "calibration : preparation",
  DERIVE_REPOS  = "calibration : mesure de la derive au repos",
  NEUTRE        = "calibration : recherche du niveau de repos",
  RECENSEMENT   = "calibration : recensement des faces candidates",
  SATELLITES    = "calibration : recensement des satellites",
  ESSAI         = "calibration : essai d'une face",
  MESURE        = "calibration : mesure de position",
  CLASSEMENT    = "calibration : classement d'une face",
  DISCRIMINE    = "calibration : discrimination translation / rotation",
  RAFFINEMENT   = "calibration : raffinement d'un axe",
  ASSEMBLAGE    = "calibration : assemblage de la table des axes",
  SECURITE      = "calibration : arret de securite",
  ECRITURE      = "calibration : ecriture de la configuration",
}
calibration.ETAPES = ETAPES

--------------------------------------------------------------------------------
-- 2. AXES ET CONVENTIONS DE SIGNE
--    Rigoureusement les memes que l'outil 'cablage' : une commande positive
--    fait avancer, monter, pivoter a tribord, glisser a tribord.
--------------------------------------------------------------------------------

local AXES = {
  avance   = { libelle = "AVANCE",   positif = "avance",           negatif = "recule" },
  vertical = { libelle = "VERTICAL", positif = "monte",            negatif = "descend" },
  lacet    = { libelle = "LACET",    positif = "pivote a tribord", negatif = "pivote a babord" },
  lateral  = { libelle = "LATERAL",  positif = "glisse a tribord", negatif = "glisse a babord" },
}
calibration.AXES = AXES

local ORDRE_AXES = { "avance", "vertical", "lacet", "lateral" }
calibration.ORDRE_AXES = ORDRE_AXES

-- Axes sans lesquels un vehicule ne peut pas voler tout seul.
local AXES_ESSENTIELS = { "avance", "vertical", "lacet" }
calibration.AXES_ESSENTIELS = AXES_ESSENTIELS

local COTES = { "top", "bottom", "left", "right", "front", "back" }
calibration.COTES = COTES

--------------------------------------------------------------------------------
-- 3. REGLAGES PAR DEFAUT
--------------------------------------------------------------------------------

local DEFAUTS = {
  niveauEssai       = 15,    -- niveau redstone applique pendant un essai
  impulsion         = 3.0,   -- duree d'activation d'une face, en secondes
  stabilisation     = 2.0,   -- pas d'attente entre deux mesures d'immobilite
  attenteMax        = 20.0,  -- attente maximale d'immobilite avant de mesurer
  seuilBruit        = 1.2,   -- blocs : en deca, c'est du bruit de trilateration
  seuilCap          = 6.0,   -- degres : en deca, le cap n'a pas bouge
  seuilRotation     = 0.25,  -- sinus de l'angle entre deux deplacements
  rayonSecurite     = 250,   -- blocs : eloignement maximal du point de depart
  recentrer         = true,  -- revenir vers le point de depart apres un essai
  delaiSatellites   = 6.0,   -- duree d'ecoute des annonces de satellites
  arretAnticipe     = true,  -- stopper des que les axes essentiels sont acquis
  raffinerNeutre    = true,  -- chercher le niveau de repos d'une face active
  essaisParFace     = 1,     -- impulsions par face au premier passage
}
calibration.DEFAUTS = DEFAUTS

--------------------------------------------------------------------------------
-- 4. GEOMETRIE
--------------------------------------------------------------------------------

--- Produit vectoriel 2D dans le plan horizontal (x vers l'est, z vers le sud).
-- Positif = le second vecteur est tourne dans le sens horaire vu du dessus,
-- c'est-a-dire vers TRIBORD. Meme convention que vecteurAvant / vecteurTribord.
local function produitVectoriel(a, b)
  return a.x * b.z - a.z * b.x
end
calibration.produitVectoriel = produitVectoriel

--- Deux deplacements successifs sont-ils une rotation ou une translation ?
--
-- Une translation repetee produit deux deplacements PARALLELES et de meme sens.
-- Une rotation les fait tourner du meme angle a chaque impulsion.
--
-- Le piege : une impulsion qui fait tourner le vehicule de pres d'un
-- demi-tour rend les deux cordes presque ANTIPARALLELES, donc de sinus
-- quasi nul -- ce qui ressemblerait a une translation. Or une translation ne
-- peut pas s'inverser entre deux impulsions identiques : un cosinus negatif
-- signe donc forcement une rotation. Quand le sinus est en plus trop faible
-- pour en donner le sens, on le declare ambigu et l'appelant recommence avec
-- une impulsion plus courte.
--
-- @return "rotation" | "rotation_ambigue" | "translation" | "indecidable", sinus
local function discriminer(d1, d2, seuilBruit, seuilRotation)
  local n1 = normeHorizontale(d1.x, d1.z)
  local n2 = normeHorizontale(d2.x, d2.z)
  if n1 < seuilBruit or n2 < seuilBruit then return "indecidable", 0 end

  local sinus   = produitVectoriel(d1, d2) / (n1 * n2)
  local cosinus = (d1.x * d2.x + d1.z * d2.z) / (n1 * n2)

  if cosinus < 0 then
    if math.abs(sinus) < seuilRotation then return "rotation_ambigue", sinus end
    return "rotation", sinus
  end
  if math.abs(sinus) >= seuilRotation then return "rotation", sinus end
  return "translation", sinus
end
calibration.discriminer = discriminer

--- Centre du cercle passant par trois points du plan horizontal.
-- @return { x, z }, rayon  |  nil si les points sont alignes
local function centreCercle(p0, p1, p2)
  local d = 2 * (p0.x * (p1.z - p2.z) + p1.x * (p2.z - p0.z) + p2.x * (p0.z - p1.z))
  if math.abs(d) < 1e-9 then return nil end
  local u0 = p0.x * p0.x + p0.z * p0.z
  local u1 = p1.x * p1.x + p1.z * p1.z
  local u2 = p2.x * p2.x + p2.z * p2.z
  local cx = (u0 * (p1.z - p2.z) + u1 * (p2.z - p0.z) + u2 * (p0.z - p1.z)) / d
  local cz = (u0 * (p2.x - p1.x) + u1 * (p0.x - p2.x) + u2 * (p1.x - p0.x)) / d
  local centre = { x = cx, z = cz }
  return centre, normeHorizontale(p0.x - cx, p0.z - cz)
end
calibration.centreCercle = centreCercle

--- Cap VRAI du vehicule, deduit d'une rotation observee au GPS.
--
-- Quand le vehicule pivote, l'ordinateur -- s'il n'est pas au centre -- decrit
-- un cercle autour de ce centre. Le vecteur centre -> ordinateur est donc le
-- bras de levier 'decalageGps', vu dans le repere du monde. Comme on connait
-- ce bras dans le repere du vehicule, la comparaison donne l'orientation
-- reelle du nez. C'est ce qui evite de s'en remettre a une convention
-- arbitraire et de faire voler le vaisseau a reculons.
--
-- @param points     trois positions successives pendant la rotation
-- @param decalage   config.decalageGps (repere vehicule : x tribord, z avant)
-- @return cap en degres, rayon mesure  |  nil, motif
local function capParRotation(points, decalage)
  if #points < 3 then return nil, "moins de trois points" end
  local centre, rayon = centreCercle(points[1], points[2], points[3])
  if not centre then return nil, "points alignes : ce n'est pas une rotation" end

  local bras = normeHorizontale(decalage.x or 0, decalage.z or 0)
  if bras < 1 then return nil, "bras de levier GPS trop court" end
  if rayon < bras * 0.4 or rayon > bras * 2.5 then
    return nil, string.format(
      "rayon mesure %.1f incoherent avec le bras declare %.1f", rayon, bras)
  end

  local dernier = points[#points]
  local capBras = capVers(dernier.x - centre.x, dernier.z - centre.z)
  if not capBras then return nil, "bras de levier nul" end

  -- Angle du bras dans le repere du vehicule : 0 = droit devant, +90 = tribord.
  local angleBras = math.deg(math.atan(decalage.x or 0, decalage.z or 0))
  return normaliserAngle(capBras - angleBras), rayon
end
calibration.capParRotation = capParRotation

--- Projette un deplacement monde dans le repere du vehicule.
-- @return composante avant, composante tribord
local function projeter(delta, cap)
  local avant   = vecteurAvant(cap)
  local tribord = vecteurTribord(cap)
  return delta.x * avant.x + delta.z * avant.z,
         delta.x * tribord.x + delta.z * tribord.z
end
calibration.projeter = projeter

--------------------------------------------------------------------------------
-- 5. ENTREES / SORTIES INJECTABLES
--    Tout ce qui touche au monde passe par cette table : les bancs d'essai la
--    remplacent entierement, sans qu'une seule ligne de logique ne change.
--------------------------------------------------------------------------------

local function ioParDefaut(config)
  local reglages = (config.sorties or {}).distant or {}
  local io = {}

  function io.mesurer(delai)
    if not gps then return nil, "API gps absente" end
    local x, y, z = gps.locate(delai or 3, false)
    if not x then return nil, "gps.locate sans reponse (moins de 4 balises a portee)" end
    return { x = x, y = y, z = z }
  end

  function io.dormir(secondes) sleep(secondes) end

  function io.ecrireLocal(cote, niveau)
    if not redstone then return false, "API redstone absente" end
    if redstone.setAnalogOutput then
      redstone.setAnalogOutput(cote, niveau)
    else
      redstone.setOutput(cote, niveau > 0)
    end
    return true
  end

  function io.envoyerSatellite(ordinateur, sorties, repos, sequence)
    if not rednet then return false, "API rednet absente" end
    return pcall(rednet.send, ordinateur, {
      protocole = "FRENCHNET_SORTIE",
      version   = 1,
      vehicule  = config.identifiant,
      sequence  = sequence,
      sorties   = sorties,
      repos     = repos,
      delai     = reglages.delaiSatellite,
    }, reglages.protocole or "frenchnet_sortie")
  end

  function io.recevoir(delai)
    if not rednet then return nil end
    local ok, expediteur, message = pcall(rednet.receive,
      reglages.protocole or "frenchnet_sortie", delai)
    if not ok then return nil end
    return expediteur, message
  end

  function io.facesOccupees()
    local occupees = {}
    if not peripheral then return occupees end
    for _, cote in ipairs(COTES) do
      local ok, present = pcall(peripheral.isPresent, cote)
      if ok and present then occupees[cote] = true end
    end
    return occupees
  end

  function io.capPeripherique()
    local c = config.cap or {}
    if c.source ~= "peripherique" or not (peripheral and c.peripherique) then
      return nil
    end
    local materiel = peripheral.wrap(c.peripherique)
    if not materiel then return nil end
    local methode = materiel[c.methode or ""]
    if type(methode) ~= "function" then return nil end
    local ok, valeur = pcall(methode)
    if not ok or type(valeur) ~= "number" then return nil end
    valeur = valeur * (c.facteur or 1) + (c.decalage or 0)
    if c.convention == "minecraft" then valeur = valeur + 180 end
    return normaliserAngle(valeur)
  end

  return io
end
calibration.ioParDefaut = ioParDefaut

--------------------------------------------------------------------------------
-- 6. INSTANCE DE CALIBRATION
--------------------------------------------------------------------------------

local function journalMuet()
  local j = {}
  local function rien() end
  j.debug, j.info, j.avert, j.erreur, j.critique = rien, rien, rien, rien, rien
  return j
end

--- @param options table
--   config           configuration vehicule (obligatoire)
--   journal          journal FrenchNet (facultatif)
--   io               table d'entrees/sorties (facultatif : construite par defaut)
--   reglages         surcharges des reglages de calibration
--   quarantaine      liste des peripheriques non classes (bloque la calibration)
--   facesInterdites  { [cote] = motif } faces a ne jamais actionner
function calibration.nouveau(options)
  options = options or {}
  local config  = options.config or {}
  local journal = options.journal or journalMuet()
  local io      = options.io or ioParDefaut(config)

  local reglages = {}
  for cle, valeur in pairs(DEFAUTS) do reglages[cle] = valeur end
  for cle, valeur in pairs(config.calibration or {}) do reglages[cle] = valeur end
  for cle, valeur in pairs(options.reglages or {}) do reglages[cle] = valeur end

  local c = {
    config    = config,
    journal   = journal,
    io        = io,
    reglages  = reglages,
    faces     = {},      -- liste des faces candidates
    resultats = {},      -- [cle de face] = fiche
    satellites= {},      -- [idOrdinateur] = { cotes = {...}, identifiant = }
    niveaux   = {},      -- [cle de face] = niveau actuellement applique
    neutre    = 0,       -- niveau de repos retenu pour toutes les faces
    sequence  = 0,
    origine   = nil,
    capSource = "aucune",
    lacetObservable = false,
    essais    = 0,
    anomalies = {},
    quarantaine     = options.quarantaine or {},
    facesInterdites = options.facesInterdites or {},
  }

  -- Bras de levier entre l'ordinateur et le centre du vehicule, dans le plan
  -- horizontal. C'est lui qui rend une rotation visible au GPS, et c'est lui
  -- qui borne la corde qu'une rotation peut produire.
  do
    local decalage = config.decalageGps or {}
    c.brasGps = (config.decalageDansRepereVehicule == false) and 0
      or normeHorizontale(decalage.x or 0, decalage.z or 0)
  end

  ------------------------------------------------------------------ utilitaires
  local function cleFace(face)
    return (face.ordinateur and ("#" .. face.ordinateur .. ":") or "") .. face.cote
  end
  c.cleFace = cleFace

  local function noter(texte)
    c.anomalies[#c.anomalies + 1] = texte
  end

  ------------------------------------------------------------------- actionnement
  --- Porte une face au niveau demande. Une seule face bouge a la fois : toutes
  -- les autres sont ramenees au niveau de repos par 'neutraliser'.
  local function ecrireFace(face, niveau)
    c.niveaux[cleFace(face)] = niveau
    if not face.ordinateur then
      return io.ecrireLocal(face.cote, niveau)
    end
    c.sequence = c.sequence + 1
    -- Une trame porte TOUTES les faces du satellite concerne : le satellite
    -- applique ce qu'il recoit et remet le reste au repos.
    local sorties, repos = {}, {}
    for _, autre in ipairs(c.faces) do
      if autre.ordinateur == face.ordinateur then
        sorties[autre.cote] = (cleFace(autre) == cleFace(face)) and niveau or c.neutre
        repos[autre.cote] = c.neutre
      end
    end
    return io.envoyerSatellite(face.ordinateur, sorties, repos, c.sequence)
  end
  c.ecrireFace = ecrireFace

  --- Ramene toutes les faces candidates au niveau de repos.
  function c.neutraliser()
    for _, face in ipairs(c.faces) do
      if not face.ordinateur then
        io.ecrireLocal(face.cote, c.neutre)
        c.niveaux[cleFace(face)] = c.neutre
      end
    end
    -- Un seul envoi par satellite, toutes faces au repos.
    local parOrdinateur = {}
    for _, face in ipairs(c.faces) do
      if face.ordinateur then
        parOrdinateur[face.ordinateur] = parOrdinateur[face.ordinateur] or {}
        parOrdinateur[face.ordinateur][face.cote] = c.neutre
        c.niveaux[cleFace(face)] = c.neutre
      end
    end
    for ordinateur, sorties in pairs(parOrdinateur) do
      c.sequence = c.sequence + 1
      io.envoyerSatellite(ordinateur, sorties, sorties, c.sequence)
    end
  end

  ----------------------------------------------------------------------- mesures
  local function mesurer()
    local position, motif = io.mesurer(config.delaiGps or (config.gps or {}).delai or 3)
    if not position then
      error("ETAPE[" .. ETAPES.MESURE .. "] " .. tostring(motif), 0)
    end
    position.cap = io.capPeripherique()
    return position
  end
  c.mesurer = mesurer

  local function ecart(a, b)
    return {
      x = b.x - a.x, y = b.y - a.y, z = b.z - a.z,
      horizontal = normeHorizontale(b.x - a.x, b.z - a.z),
    }
  end
  c.ecart = ecart

  --- Attend l'immobilite reelle et renvoie la mesure stabilisee.
  function c.attendreImmobilite()
    local precedente = mesurer()
    local ecoule = 0
    while ecoule < reglages.attenteMax do
      io.dormir(reglages.stabilisation)
      ecoule = ecoule + reglages.stabilisation
      local courante = mesurer()
      local d = ecart(precedente, courante)
      local bougeCap = false
      if courante.cap and precedente.cap then
        bougeCap = math.abs(normaliserAngle(courante.cap - precedente.cap)) > reglages.seuilCap
      end
      if normeHorizontale(d.x, d.z) <= reglages.seuilBruit
         and math.abs(d.y) <= reglages.seuilBruit and not bougeCap then
        return courante
      end
      precedente = courante
    end
    journal.avert(ETAPES.MESURE, string.format(
      "vehicule encore en mouvement apres %ds : mesure prise malgre tout",
      math.floor(reglages.attenteMax)))
    return precedente
  end

  local function verifierRayon(position)
    if not c.origine then return end
    local d = ecart(c.origine, position)
    local distance = math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
    if distance > reglages.rayonSecurite then
      error("ETAPE[" .. ETAPES.SECURITE .. "] le vehicule s'est eloigne de "
        .. string.format("%.0f", distance) .. " blocs du point de calibration "
        .. "(limite " .. reglages.rayonSecurite .. ") : commandes coupees. "
        .. "Calibrez en vol stationnaire, loin du relief.", 0)
    end
  end

  ------------------------------------------------------------------ preparation
  --- Neutralise, verifie que le vehicule tient en place, et cherche le niveau
  -- de repos si ce n'est pas le cas.
  function c.preparer()
    journal.info(ETAPES.PREPARATION, string.format(
      "calibration v%s | impulsion %.1fs | seuil de bruit %.1f bloc(s)",
      calibration.VERSION, reglages.impulsion, reglages.seuilBruit))

    c.neutraliser()
    local depart = c.attendreImmobilite()
    c.origine = depart
    c.capSource = depart.cap and "peripherique" or "aucune"

    journal.info(ETAPES.PREPARATION, string.format(
      "point de calibration X=%.1f Y=%.1f Z=%.1f | cap %s",
      depart.x, depart.y, depart.z,
      depart.cap and string.format("%.0f deg (capteur)", depart.cap) or "non mesure"))

    -- Derive au repos : toutes faces a zero, le vehicule doit tenir en place.
    local avant = depart
    io.dormir(reglages.impulsion)
    local apres = mesurer()
    local d = ecart(avant, apres)
    local derive = math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)

    if derive > reglages.seuilBruit and reglages.raffinerNeutre then
      journal.avert(ETAPES.DERIVE_REPOS, string.format(
        "derive de %.1f bloc(s) alors que TOUTES les faces sont a 0 : une "
        .. "commande a probablement un neutre non nul (moteur a marche arriere). "
        .. "Test de l'hypothese neutre = 7.", derive))
      c.chercherNeutre()
    elseif derive > reglages.seuilBruit then
      noter(string.format("derive de %.1f bloc(s) au repos non expliquee", derive))
      journal.avert(ETAPES.DERIVE_REPOS, string.format(
        "derive de %.1f bloc(s) au repos : les mesures seront moins sures", derive))
    else
      journal.info(ETAPES.DERIVE_REPOS, string.format(
        "derive au repos %.2f bloc(s) : le vehicule tient en place", derive))
    end

    return depart
  end

  --- Teste l'hypothese d'un niveau de repos median (7 sur 0-15).
  -- Un moteur bipolaire cable ainsi part plein gaz arriere quand on le met a 0.
  function c.chercherNeutre()
    local ancien = c.neutre
    c.neutre = 7
    c.neutraliser()
    local avant = c.attendreImmobilite()
    io.dormir(reglages.impulsion)
    local apres = mesurer()
    local d = ecart(avant, apres)
    local derive = math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)

    if derive <= reglages.seuilBruit then
      journal.info(ETAPES.NEUTRE,
        "niveau de repos 7 retenu : le vehicule s'immobilise. Les axes seront "
        .. "ecrits en analogique neutre = 7, amplitude = 7.")
      return 7
    end

    c.neutre = ancien
    c.neutraliser()
    noter("niveau de repos introuvable : le vehicule derive a 0 comme a 7")
    journal.avert(ETAPES.NEUTRE,
      "le vehicule derive aussi bien a 0 qu'a 7 : ce n'est pas un probleme de "
      .. "neutre. Vent, courant, ou moteur deja sous tension par un autre "
      .. "circuit. La calibration continue, mais verifiez les mesures.")
    return ancien
  end

  ------------------------------------------------------------------ recensement
  --- Ecoute les annonces des satellites : c'est ainsi qu'on decouvre les
  -- ordinateurs de sortie deportes sans les declarer a l'avance.
  function c.recenserSatellites()
    local distant = (config.sorties or {}).distant or {}
    if not distant.actif then
      journal.info(ETAPES.SATELLITES,
        "sorties deportees desactivees : seules les faces locales seront essayees")
      return {}
    end

    journal.info(ETAPES.SATELLITES, string.format(
      "ecoute des annonces de satellites pendant %.0fs...", reglages.delaiSatellites))

    local fin = reglages.delaiSatellites
    local ecoule = 0
    while ecoule < fin do
      local expediteur, message = io.recevoir(math.min(2, fin - ecoule))
      ecoule = ecoule + 2
      if expediteur and type(message) == "table"
         and (message.protocole == "FRENCHNET_SORTIE_ANNONCE"
              or message.protocole == "FRENCHNET_SORTIE_ACK") then
        -- Un satellite d'un AUTRE vehicule ne doit jamais etre commande.
        if not message.vehicule or not config.identifiant
           or message.vehicule == config.identifiant then
          if not c.satellites[expediteur] then
            journal.info(ETAPES.SATELLITES, string.format(
              "satellite #%d (%s) : faces %s", expediteur,
              tostring(message.identifiant),
              table.concat(message.cotes or COTES, ", ")))
          end
          c.satellites[expediteur] = {
            identifiant = message.identifiant,
            cotes = message.cotes or COTES,
          }
        end
      end
    end

    local nombre = 0
    for _ in pairs(c.satellites) do nombre = nombre + 1 end
    if nombre == 0 then
      journal.avert(ETAPES.SATELLITES,
        "sorties deportees actives mais aucun satellite n'a repondu : "
        .. "verifiez qu'ils tournent et qu'ils portent le meme identifiant de vehicule")
    end
    return c.satellites
  end

  --- Construit la liste ordonnee des faces a essayer.
  function c.recenser()
    local faces, vues = {}, {}
    local occupees = io.facesOccupees()
    local interdits = config.cotesInterdits or {}

    local function ajouter(face)
      local cle = cleFace(face)
      if vues[cle] then return end
      vues[cle] = true
      faces[#faces + 1] = face
    end

    -- Faces reservees a autre chose que la propulsion : entrees de carburant,
    -- voyant d'amarrage... Les actionner declencherait un mecanisme sans rapport.
    local reservees = {}
    local carburant = config.carburant or {}
    for _, cle in ipairs({ "coteRetour", "coteDepart", "coteAmarre" }) do
      if carburant[cle] then
        reservees[(carburant.ordinateurOrdres and ("#" .. carburant.ordinateurOrdres .. ":") or "")
          .. carburant[cle]] = cle
      end
    end
    -- Faces d'un armement, ou faces occupees par un peripherique que personne
    -- n'a encore classe. On n'envoie pas de courant dans un bloc dont on ignore
    -- la nature pour voir ce qui se passe.
    for cote, motif in pairs(c.facesInterdites) do
      reservees[cote] = motif
    end

    if (carburant.redstone or {}).cote and carburant.source == "redstone" then
      local r = carburant.redstone
      reservees[(r.ordinateur and ("#" .. r.ordinateur .. ":") or "") .. r.cote] = "jauge de carburant"
    end
    if (config.sol or {}).source == "redstone" and (config.sol.redstone or {}).cote then
      local r = config.sol.redstone
      reservees[(r.ordinateur and ("#" .. r.ordinateur .. ":") or "") .. r.cote] = "capteur de hauteur sol"
    end

    ------------------------------------------- rang 1 : faces deja declarees
    for _, nomAxe in ipairs(ORDRE_AXES) do
      local reglageAxe = ((config.sorties or {}).axes or {})[nomAxe]
      if type(reglageAxe) == "table" and (reglageAxe.mode or "aucun") ~= "aucun" then
        for _, cle in ipairs({ "cote", "cotePositif", "coteNegatif" }) do
          if reglageAxe[cle] then
            ajouter({ cote = reglageAxe[cle], ordinateur = reglageAxe.ordinateur,
                      rang = 1, axeDeclare = nomAxe })
          end
        end
      end
    end

    ------------------------------------------ rang 2 : faces de l'ordinateur
    -- L'ordre de ces tests est celui de la GRAVITE du motif, pas celui de la
    -- commodite : une face porteuse d'un armement est aussi une face occupee
    -- par un peripherique. Si le second test parlait le premier, le journal
    -- dirait "un peripherique l'occupe" la ou l'operateur doit lire "armement".
    for _, cote in ipairs(COTES) do
      if reservees[cote] then
        journal.info(ETAPES.RECENSEMENT, string.format(
          "face '%s' ecartee : reservee (%s)", cote, reservees[cote]))
      elseif interdits[cote] then
        journal.info(ETAPES.RECENSEMENT,
          "face '" .. cote .. "' ecartee : interdite par la configuration")
      elseif occupees[cote] then
        journal.debug(ETAPES.RECENSEMENT,
          "face '" .. cote .. "' ecartee : un peripherique l'occupe")
      else
        ajouter({ cote = cote, rang = 2 })
      end
    end

    ------------------------------------------- rang 3 : faces des satellites
    local ordinateurs = {}
    for ordinateur in pairs(c.satellites) do ordinateurs[#ordinateurs + 1] = ordinateur end
    table.sort(ordinateurs)
    for _, ordinateur in ipairs(ordinateurs) do
      for _, cote in ipairs(c.satellites[ordinateur].cotes or COTES) do
        local cle = "#" .. ordinateur .. ":" .. cote
        if reservees[cle] then
          journal.info(ETAPES.RECENSEMENT, string.format(
            "face %s ecartee : reservee (%s)", cle, reservees[cle]))
        else
          ajouter({ cote = cote, ordinateur = ordinateur, rang = 3 })
        end
      end
    end

    table.sort(faces, function(a, b)
      if a.rang ~= b.rang then return a.rang < b.rang end
      return cleFace(a) < cleFace(b)
    end)

    c.faces = faces
    local parRang = {}
    for _, face in ipairs(faces) do parRang[face.rang] = (parRang[face.rang] or 0) + 1 end
    journal.info(ETAPES.RECENSEMENT, string.format(
      "%d face(s) candidate(s) : %d declaree(s), %d locale(s), %d deportee(s)",
      #faces, parRang[1] or 0, parRang[2] or 0, parRang[3] or 0))
    return faces
  end

  ---------------------------------------------------------------- essai d'une face
  --- Une impulsion sur une face, et le deplacement qui en resulte.
  -- @return table { x, y, z, horizontal, dcap } ou nil si la face est refusee
  function c.impulsion(face, niveau)
    c.neutraliser()
    local avant = c.attendreImmobilite()
    verifierRayon(avant)

    local ok, motif = ecrireFace(face, niveau or reglages.niveauEssai)
    if not ok then
      journal.avert(ETAPES.ESSAI, string.format(
        "face %s inactionnable (%s) : ignoree", cleFace(face), tostring(motif)))
      return nil
    end

    io.dormir(reglages.impulsion)
    ecrireFace(face, c.neutre)

    local apres = c.attendreImmobilite()
    verifierRayon(apres)
    c.essais = c.essais + 1

    local d = ecart(avant, apres)
    if avant.cap and apres.cap then
      d.dcap = normaliserAngle(apres.cap - avant.cap)
    end
    d.capAvant = avant.cap
    -- Les positions absolues servent a l'ajustement de cercle : c'est de la
    -- geometrie du trajet, pas seulement de son amplitude.
    d.pointAvant = { x = avant.x, y = avant.y, z = avant.z }
    d.pointApres = { x = apres.x, y = apres.y, z = apres.z }
    return d
  end

  ------------------------------------------------------------------- classement
  --- Classe une face a partir d'un ou deux deplacements.
  -- @return nomAxe|nil, signe, motif
  function c.classer(face, d1)
    if not d1 then return nil, 0, "essai refuse" end

    local horizontal = d1.horizontal >= reglages.seuilBruit
    local vertical   = math.abs(d1.y) >= reglages.seuilBruit
    local capBouge   = d1.dcap ~= nil and math.abs(d1.dcap) >= reglages.seuilCap

    ---------------------------------------------------------------- inerte ?
    if not horizontal and not vertical and not capBouge then
      if c.lacetObservable then
        return nil, 0, "aucun effet mesurable"
      end
      return nil, 0, "aucun effet mesurable, et le lacet n'est pas observable "
        .. "sur ce vehicule : cette face peut commander une rotation"
    end

    ------------------------------------------------- lacet mesure au capteur
    -- Un vehicule qui pivote sur place ne deplace pas son CENTRE, mais il
    -- promene l'ordinateur autour de lui : le point GPS parcourt une corde, au
    -- plus egale au diametre du cercle, soit deux fois le bras de levier. Tant
    -- que le deplacement reste sous cette borne, il s'explique entierement par
    -- la rotation. Au-dela, la face translate aussi, et le classement se fait
    -- sur l'effet dominant.
    local borneRotation = 2.2 * c.brasGps + reglages.seuilBruit * 1.5
    if capBouge and d1.horizontal <= borneRotation then
      return "lacet", (d1.dcap > 0) and 1 or -1,
        string.format("cap %+.0f deg au capteur (%.1f bloc(s) de corde, borne %.1f)",
          d1.dcap, d1.horizontal, borneRotation)
    end

    -------------------------------------------------------------- vertical ?
    if vertical and math.abs(d1.y) > d1.horizontal then
      return "vertical", (d1.y > 0) and 1 or -1,
        string.format("%+.1f bloc(s) d'altitude", d1.y)
    end

    ------------------------------------------------------------- horizontal
    if not horizontal then
      if capBouge then
        return "lacet", (d1.dcap > 0) and 1 or -1,
          string.format("cap %+.0f deg au capteur", d1.dcap)
      end
      return nil, 0, "effet trop faible pour etre classe"
    end

    -- Un capteur de cap tranche tout de suite entre avance et derive laterale.
    if d1.capAvant then
      local avant, tribord = projeter(d1, d1.capAvant)
      if math.abs(avant) >= math.abs(tribord) then
        return "avance", (avant > 0) and 1 or -1,
          string.format("%+.1f bloc(s) vers l'avant", avant)
      end
      return "lateral", (tribord > 0) and 1 or -1,
        string.format("%+.1f bloc(s) vers tribord", tribord)
    end

    -- Sans capteur : seconde impulsion pour trancher rotation / translation.
    local d2 = c.impulsion(face)
    if not d2 then return nil, 0, "seconde impulsion refusee" end

    local genre, sinus = discriminer(d1, d2, reglages.seuilBruit, reglages.seuilRotation)

    -- Impulsion trop longue : le vehicule a fait pres d'un demi-tour et le sens
    -- de rotation n'est plus lisible. On recommence plus court, une seule fois.
    if genre == "rotation_ambigue" then
      local ancienne = reglages.impulsion
      reglages.impulsion = math.max(0.5, ancienne / 3)
      journal.avert(ETAPES.DISCRIMINE, string.format(
        "face %s : rotation trop rapide pour en lire le sens, nouvel essai a "
        .. "%.1fs d'impulsion au lieu de %.1fs", cleFace(face),
        reglages.impulsion, ancienne))
      local e1 = c.impulsion(face)
      local e2 = e1 and c.impulsion(face) or nil
      reglages.impulsion = ancienne
      if e1 and e2 then
        genre, sinus = discriminer(e1, e2, reglages.seuilBruit, reglages.seuilRotation)
        d1 = e1
      end
      if genre == "rotation_ambigue" then
        c.referenceObsolete = true
        return "lacet", 0,
          "rotation confirmee mais sens illisible : reduisez 'impulsion' dans "
          .. "la configuration, puis recalibrez cet axe"
      end
    end

    journal.debug(ETAPES.DISCRIMINE, string.format(
      "face %s : %s (sinus %.2f)", cleFace(face), genre, sinus))

    if genre == "rotation" then
      -- La rotation est une aubaine : les trois positions successives sont sur
      -- un cercle centre sur le VRAI centre du vehicule. On en tire le cap reel
      -- du nez, ce qui remplace la convention arbitraire par une mesure.
      c.exploiterRotation({ d1.pointAvant, d2.pointAvant, d2.pointApres })

      -- Le vehicule vient de pivoter : la reference d'avant, exprimee dans le
      -- repere MONDE, ne vaut plus rien. C'est le piege de cette methode, et
      -- l'oublier ferait classer 'lateral' la prochaine commande d'avance.
      c.referenceObsolete = true
      return "lacet", (sinus > 0) and 1 or -1,
        string.format("deplacement tourne de %.0f deg entre deux impulsions "
          .. "identiques : rotation", math.deg(math.asin(borner(sinus, -1, 1))))
    end

    -- Translation : le premier axe horizontal decouvert definit l'avant du
    -- vehicule, par convention. Un vehicule qui vole a reculons apres
    -- calibration se corrige avec 'inverse = true', sans tout recommencer.
    if not c.referenceAvant then
      c.referenceAvant = { x = d1.x, z = d1.z }
      c.capReference = capVers(d1.x, d1.z)
      c.faceReference = face
      c.referenceObsolete = false
      journal.info(ETAPES.CLASSEMENT, string.format(
        "avant du vehicule fixe par %s : cap %.0f deg", cleFace(face), c.capReference or 0))
      return "avance", 1, "premiere translation observee : definit l'avant"
    end

    if c.referenceObsolete then c.rafraichirReference() end

    local avant, tribord = projeter(d1, c.capReference)
    if math.abs(avant) >= math.abs(tribord) then
      return "avance", (avant > 0) and 1 or -1,
        string.format("%+.1f bloc(s) vers l'avant", avant)
    end
    return "lateral", (tribord > 0) and 1 or -1,
      string.format("%+.1f bloc(s) vers tribord", tribord)
  end

  --- Tire le cap reel du vehicule d'une rotation observee, et redresse tout ce
  -- qui avait ete classe sur la convention arbitraire.
  function c.exploiterRotation(points)
    if c.capVrai or c.capSource == "peripherique" then return end
    local decalage = c.config.decalageGps or {}
    if c.config.decalageDansRepereVehicule == false then return end

    -- Second retour : le rayon mesure en cas de succes, le motif du refus sinon.
    local capVrai, rayonOuMotif = capParRotation(points, decalage)
    if not capVrai then
      journal.debug(ETAPES.DISCRIMINE,
        "cap reel non deductible de cette rotation : " .. tostring(rayonOuMotif))
      return
    end

    journal.info(ETAPES.CLASSEMENT, string.format(
      "cap reel du vehicule deduit de la rotation : %.0f deg "
      .. "(rayon mesure %.1f bloc(s))", capVrai, rayonOuMotif))

    -- La reference arbitraire doit etre remesuree A CET INSTANT pour que
    -- l'ecart entre elle et le cap reel soit un biais constant, applicable a
    -- tout ce qui a deja ete classe.
    if c.faceReference then
      c.referenceObsolete = true
      c.rafraichirReference()
    end

    if c.capReference then
      c.biais = normaliserAngle(capVrai - c.capReference)
      journal.info(ETAPES.CLASSEMENT, string.format(
        "convention d'avant corrigee de %+.0f deg par la mesure", c.biais))
      c.capReference = capVrai
      c.capVrai = capVrai
      c.reclasserTranslations()
    else
      c.capReference = capVrai
      c.capVrai = capVrai
    end
  end

  --- Reprojette les translations deja classees sur le cap reel du vehicule.
  -- Aucun nouvel essai : on reutilise les deplacements deja mesures.
  function c.reclasserTranslations()
    if not c.biais or math.abs(c.biais) < 1 then return end
    for _, fiche in pairs(c.resultats) do
      if fiche.delta and fiche.capReferenceUtilise
         and (fiche.axe == "avance" or fiche.axe == "lateral") then
        local cap = normaliserAngle(fiche.capReferenceUtilise + c.biais)
        local avant, tribord = projeter(fiche.delta, cap)
        local axe   = (math.abs(avant) >= math.abs(tribord)) and "avance" or "lateral"
        local valeur = (axe == "avance") and avant or tribord
        local signe = (valeur > 0) and 1 or -1
        if axe ~= fiche.axe or signe ~= fiche.signe then
          journal.info(ETAPES.CLASSEMENT, string.format(
            "face %s reclassee %s %s -> %s %s apres mesure du cap reel",
            fiche.cle, AXES[fiche.axe].libelle, fiche.signe > 0 and "+" or "-",
            AXES[axe].libelle, signe > 0 and "+" or "-"))
        end
        fiche.axe, fiche.signe = axe, signe
        fiche.motif = string.format("%+.1f bloc(s) sur le cap reel", valeur)
      end
    end
  end

  --- Ramene le vehicule vers son point de depart apres un essai concluant.
  --
  -- Chaque impulsion deplace le vehicule et rien ne l'y ramene : sur un
  -- balayage complet il derive de plusieurs centaines de blocs et finit par
  -- declencher l'arret de securite -- ou par rencontrer le relief. Des qu'une
  -- face de sens oppose est connue sur le meme axe, on la pousse une fois :
  -- le vehicule revient a peu pres sur ses pas, et l'on verifie au passage que
  -- la face opposee agit bien.
  -- @return true si une compensation a eu lieu
  function c.compenser(axe, signe)
    if not (reglages.recentrer and axe) or signe == 0 then return false end
    for _, fiche in pairs(c.resultats) do
      if fiche.axe == axe and fiche.signe == -signe then
        journal.debug(ETAPES.ESSAI, string.format(
          "retour vers le point de depart par %s (%s oppose)", fiche.cle, axe))
        c.compensations = (c.compensations or 0) + 1
        c.impulsion({ cote = fiche.cote, ordinateur = fiche.ordinateur })
        return true
      end
    end
    return false
  end

  --- Remesure l'orientation du vehicule apres un essai de rotation.
  -- On repousse la face qui avait servi a fixer l'avant : le deplacement
  -- obtenu donne le nouveau cap de reference.
  function c.rafraichirReference()
    if not c.faceReference then c.referenceObsolete = false return end
    journal.info(ETAPES.CLASSEMENT, string.format(
      "le vehicule a pivote : nouvelle mesure de l'avant avec %s",
      cleFace(c.faceReference)))
    local d = c.impulsion(c.faceReference)
    if d and d.horizontal >= reglages.seuilBruit then
      c.referenceAvant = { x = d.x, z = d.z }
      c.capReference = capVers(d.x, d.z)
      journal.info(ETAPES.CLASSEMENT, string.format(
        "avant du vehicule : cap %.0f deg", c.capReference or 0))
    else
      journal.avert(ETAPES.CLASSEMENT,
        "remesure de l'avant sans effet : l'ancienne reference est conservee")
    end
    c.referenceObsolete = false
  end

  ---------------------------------------------------------------------- balayage
  --- Les axes essentiels sont-ils tous couverts dans les deux sens utiles ?
  function c.jeuComplet()
    for _, nomAxe in ipairs(AXES_ESSENTIELS) do
      local trouve = false
      for _, fiche in pairs(c.resultats) do
        if fiche.axe == nomAxe then trouve = true break end
      end
      if not trouve then return false end
      -- Le lacet a besoin des DEUX sens : un vehicule qui ne tourne que d'un
      -- cote ne peut pas tenir un cap.
      if nomAxe == "lacet" then
        local positif, negatif = false, false
        for _, fiche in pairs(c.resultats) do
          if fiche.axe == "lacet" then
            if fiche.signe > 0 then positif = true else negatif = true end
          end
        end
        if not (positif and negatif) then return false end
      end
    end
    return true
  end

  function c.balayer()
    c.lacetObservable = (c.capSource == "peripherique")
    if not c.lacetObservable then
      local decalage = config.decalageGps or {}
      local bras = normeHorizontale(decalage.x or 0, decalage.z or 0)
      if bras >= 1 and config.decalageDansRepereVehicule ~= false then
        c.lacetObservable = true
        journal.info(ETAPES.PREPARATION, string.format(
          "pas de capteur de cap, mais l'ordinateur est decale de %.1f bloc(s) du "
          .. "centre : une rotation promene le point GPS sur un cercle, elle est "
          .. "donc observable.", bras))
      else
        journal.avert(ETAPES.PREPARATION,
          "LACET NON OBSERVABLE : ni capteur de cap, ni decalage GPS horizontal. "
          .. "Les faces de rotation ne pourront pas etre identifiees seules et "
          .. "seront renvoyees a l'operateur. Pour y remedier : declarez "
          .. "'decalageGps' si l'ordinateur n'est pas au centre, ou equipez un "
          .. "capteur de cap.")
        noter("lacet non observable : faces de rotation a declarer a la main")
      end
    end

    for index, face in ipairs(c.faces) do
      local cle = cleFace(face)

      if face.rang == 1 and face.axeDeclare then
        journal.info(ETAPES.ESSAI, string.format(
          "face %s deja declaree sur l'axe %s : non reessayee", cle, face.axeDeclare))
      else
        journal.info(ETAPES.ESSAI, string.format(
          "essai %d/%d : face %s (rang %d)", index, #c.faces, cle, face.rang))

        local d = c.impulsion(face)
        local axe, signe, motif = c.classer(face, d)

        if axe then
          c.resultats[cle] = {
            cle = cle, cote = face.cote, ordinateur = face.ordinateur,
            axe = axe, signe = signe, motif = motif,
            amplitude = d and math.max(d.horizontal, math.abs(d.y)) or 0,
            -- Conserves pour pouvoir reprojeter sans reessayer la face le jour
            -- ou une rotation revele le cap reel du vehicule.
            delta = (axe == "avance" or axe == "lateral") and d or nil,
            capReferenceUtilise = (axe == "avance" or axe == "lateral")
              and (d and d.capAvant or c.capReference) or nil,
          }
          journal.info(ETAPES.CLASSEMENT, string.format(
            "face %s -> %s %s (%s)", cle, AXES[axe].libelle,
            signe > 0 and "positif" or "negatif", motif))
          c.compenser(axe, signe)
        else
          c.resultats[cle] = { cle = cle, cote = face.cote,
            ordinateur = face.ordinateur, axe = nil, signe = 0, motif = motif }
          journal.debug(ETAPES.CLASSEMENT, string.format("face %s : %s", cle, motif))
          if not c.lacetObservable and d and d.horizontal < reglages.seuilBruit
             and math.abs(d.y) < reglages.seuilBruit then
            c.suspectesLacet = c.suspectesLacet or {}
            c.suspectesLacet[#c.suspectesLacet + 1] = cle
          end
        end
      end

      if reglages.arretAnticipe and c.jeuComplet() then
        local suivante = c.faces[index + 1]
        if not suivante or suivante.rang ~= face.rang then
          journal.info(ETAPES.ESSAI, string.format(
            "jeu de commandes complet apres %d essai(s) : les rangs suivants ne "
            .. "seront pas balayes", index))
          break
        end
      end
    end

    c.neutraliser()
    return c.resultats
  end

  ------------------------------------------------------------------- assemblage
  --- Assemble la table 'sorties.axes' a partir des faces classees.
  function c.assembler()
    local axes = {}

    for _, nomAxe in ipairs(ORDRE_AXES) do
      local positives, negatives = {}, {}
      for _, fiche in pairs(c.resultats) do
        if fiche.axe == nomAxe then
          local liste = (fiche.signe > 0) and positives or negatives
          liste[#liste + 1] = fiche
        end
      end
      local function parAmplitude(a, b) return (a.amplitude or 0) > (b.amplitude or 0) end
      table.sort(positives, parAmplitude)
      table.sort(negatives, parAmplitude)

      if #positives > 0 and #negatives > 0 then
        -- Deux faces opposees : montage bipolaire, le cas le plus courant.
        axes[nomAxe] = {
          mode = "bipolaire",
          cotePositif = positives[1].cote,
          coteNegatif = negatives[1].cote,
          amplitude = 15, seuil = 0.08,
        }
        if positives[1].ordinateur or negatives[1].ordinateur then
          axes[nomAxe].ordinateur = positives[1].ordinateur or negatives[1].ordinateur
        end
        if positives[1].ordinateur ~= negatives[1].ordinateur then
          noter(string.format(
            "axe %s : les deux sens sont sur des ordinateurs differents (%s et %s), "
            .. "ce que la configuration ne sait pas exprimer. Seul %s est retenu.",
            nomAxe, tostring(positives[1].ordinateur), tostring(negatives[1].ordinateur),
            positives[1].cle))
          axes[nomAxe] = { mode = "analogique", cote = positives[1].cote,
            ordinateur = positives[1].ordinateur,
            neutre = c.neutre, amplitude = 15 - c.neutre }
        end

      elseif #positives > 0 or #negatives > 0 then
        -- Une seule face : montage analogique. Le neutre retenu est celui
        -- qu'on a valide en preparation (0 dans l'immense majorite des cas).
        local fiche = positives[1] or negatives[1]
        axes[nomAxe] = {
          mode = "analogique",
          cote = fiche.cote,
          ordinateur = fiche.ordinateur,
          neutre = c.neutre,
          amplitude = (c.neutre > 0) and c.neutre or 15,
          inverse = (#positives == 0) or nil,
        }

      else
        axes[nomAxe] = { mode = "aucun" }
      end
    end

    c.axes = axes
    return axes
  end

  ------------------------------------------------------------------- resultat
  function c.resultat()
    local manquants = {}
    for _, nomAxe in ipairs(AXES_ESSENTIELS) do
      if not c.axes or (c.axes[nomAxe] or {}).mode == "aucun" then
        manquants[#manquants + 1] = nomAxe
      end
    end

    local classees = {}
    for cle, fiche in pairs(c.resultats) do
      if fiche.axe then classees[cle] = fiche end
    end

    return {
      version         = calibration.VERSION,
      vehicule        = c.config.identifiant,
      axes            = c.axes,
      faces           = c.resultats,
      classees        = classees,
      manquants       = manquants,
      suspectesLacet  = c.suspectesLacet or {},
      lacetObservable = c.lacetObservable,
      capSource       = c.capSource,
      neutre          = c.neutre,
      essais          = c.essais,
      satellites      = c.satellites,
      anomalies       = c.anomalies,
      origine         = c.origine,
    }
  end

  ------------------------------------------------------------------- execution
  --- Deroule la calibration complete. Neutralise quoi qu'il arrive.
  --- La calibration envoie du courant dans des sorties pour voir ce qui bouge.
  -- Tant qu'un bloc du bord n'a pas ete identifie, cette manoeuvre peut tout
  -- aussi bien declencher un canon. On refuse donc de commencer.
  function c.verifierQuarantaine()
    if #c.quarantaine == 0 then return true end

    journal.erreur(ETAPES.PREPARATION, string.format(
      "%d peripherique(s) INCONNU(S) du systeme :", #c.quarantaine))
    for _, fiche in ipairs(c.quarantaine) do
      journal.erreur(ETAPES.PREPARATION, string.format("  - '%s' (type '%s') : %s",
        tostring(fiche.nom), tostring(fiche.type), tostring(fiche.motif)))
    end

    if (c.config.peripheriques or {}).exigerClassement == false then
      journal.avert(ETAPES.PREPARATION,
        "'exigerClassement = false' : la calibration continue sans eux. Leurs "
        .. "faces ne seront pas essayees.")
      return true
    end

    error("ETAPE[" .. ETAPES.PREPARATION .. "] CALIBRATION REFUSEE : "
      .. #c.quarantaine .. " peripherique(s) ne sont pas classes. Un operateur "
      .. "doit leur attribuer une classe avec le programme 'classer' -- les "
      .. "classes y sont decrites une par une. Passer outre : "
      .. "'peripheriques.exigerClassement = false' dans la configuration.", 0)
  end

  function c.executer()
    local ok, err = pcall(function()
      c.verifierQuarantaine()
      c.recenserSatellites()
      c.preparer()
      c.recenser()
      c.balayer()
      c.assembler()
    end)

    -- Regle non negociable : on ne laisse jamais un moteur sous tension.
    pcall(c.neutraliser)

    if not ok then
      journal.erreur(ETAPES.SECURITE,
        "calibration interrompue, commandes neutralisees : " .. tostring(err))
      error(err, 0)
    end

    local resultat = c.resultat()
    journal.info(ETAPES.ASSEMBLAGE, string.format(
      "%d essai(s), %d face(s) classee(s)", resultat.essais,
      (function() local n = 0 for _ in pairs(resultat.classees) do n = n + 1 end return n end)()))
    for _, nomAxe in ipairs(ORDRE_AXES) do
      local axe = resultat.axes[nomAxe] or { mode = "aucun" }
      if axe.mode == "bipolaire" then
        journal.info(ETAPES.ASSEMBLAGE, string.format("  %-8s bipolaire +%s / -%s",
          nomAxe, axe.cotePositif, axe.coteNegatif))
      elseif axe.mode == "analogique" then
        journal.info(ETAPES.ASSEMBLAGE, string.format("  %-8s analogique %s (%d+/-%d)%s",
          nomAxe, axe.cote, axe.neutre or 0, axe.amplitude or 15,
          axe.inverse and " INVERSE" or ""))
      else
        journal.info(ETAPES.ASSEMBLAGE, string.format("  %-8s non equipe", nomAxe))
      end
    end
    if #resultat.manquants > 0 then
      journal.avert(ETAPES.ASSEMBLAGE, "axes ESSENTIELS non trouves : "
        .. table.concat(resultat.manquants, ", ")
        .. " -- verifiez le cablage, ou declarez-les a la main.")
    end
    if #resultat.suspectesLacet > 0 then
      journal.avert(ETAPES.ASSEMBLAGE, string.format(
        "%d face(s) sans effet mesurable alors que le lacet n'est pas observable : "
        .. "%s. Ce sont les candidates a une commande de rotation : declarez-les "
        .. "a la main.", #resultat.suspectesLacet,
        table.concat(resultat.suspectesLacet, ", ")))
    end

    return resultat
  end

  return c
end

--------------------------------------------------------------------------------
-- 7. ECRITURE DANS LA CONFIGURATION
--------------------------------------------------------------------------------

--- Reporte une table d'axes dans une configuration vehicule, sans toucher au
-- reste. Conserve les inversions deja reglees a la main sur un axe inchange.
function calibration.appliquerA(config, axes)
  config.sorties = config.sorties or {}
  local ancien = config.sorties.axes or {}
  local nouveau = {}

  for _, nomAxe in ipairs(ORDRE_AXES) do
    local propose = axes[nomAxe] or { mode = "aucun" }
    local courant = ancien[nomAxe]

    -- Un axe dont le cablage n'a pas bouge garde son 'inverse' : c'est un
    -- reglage que l'operateur a valide en vol, la calibration ne le sait pas
    -- mieux que lui.
    if courant and propose.mode == courant.mode
       and propose.cote == courant.cote
       and propose.cotePositif == courant.cotePositif
       and propose.coteNegatif == courant.coteNegatif
       and propose.ordinateur == courant.ordinateur then
      propose.inverse = courant.inverse
    end
    nouveau[nomAxe] = propose
  end

  config.sorties.axes = nouveau
  return config
end

--- Ecrit la configuration complete sur disque, via le serialiseur du module.
function calibration.ecrireConfiguration(config, chemin)
  chemin = chemin or autopilote.CHEMIN_CONFIG_DEFAUT
  local fichier = fs.open(chemin, "w")
  if not fichier then
    error("ETAPE[" .. ETAPES.ECRITURE .. "] ecriture impossible : " .. chemin, 0)
  end
  fichier.write(autopilote.serialiserConfig(config))
  fichier.close()
  return chemin
end

return calibration
