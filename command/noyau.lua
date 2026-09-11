--[[----------------------------------------------------------------------------
  FRENCHNET COMMAND - NOYAU DE DECISION
  --------------------------------------------------------------------------
  Role : toute la logique de decision du systeme de defense, isolee de
         CC: Tweaked. Ce fichier n'utilise AUCUNE API du jeu (pas de term, pas
         de rednet, pas de peripheral, pas de fs) : il ne fait que transformer
         des donnees en decisions. C'est ce qui permet de le tester hors du
         jeu sur un interpreteur Lua ordinaire, et de garantir que la table
         d'engagement est exacte avant de la confier a des canons reels.

  Le noyau NE PILOTE AUCUNE ARME. Il produit des ordres textuels destines a
  FrenchNet Fire Control, qui reste seul responsable du tir.

  Chaine de traitement :
      contact radar
        -> zone.................. noyau.zonePourPoint
        -> categorie............. noyau.categoriser        (3 categories)
        -> statut IFF............ noyau.statutIff          (transpondeur)
        -> verdict............... noyau.verdict            (table d'engagement)
        -> designation tireur.... noyau.designer
        -> ordre texte........... noyau.formaterOrdre
        -> confirmation kill..... noyau.evaluerDestruction

  NOTE SUR LES ACCENTS : toute chaine susceptible d'etre affichee a l'ecran
  ou ecrite dans le journal est sans accent (le terminal CC: Tweaked est
  oriente octet). Les commentaires, jamais affiches, sont rédigés normalement.
--------------------------------------------------------------------------------]]

local noyau = { VERSION = "1.0.0" }

--------------------------------------------------------------------------------
-- 1. VOCABULAIRE
--------------------------------------------------------------------------------

-- Classes de zone, de la moins a la plus reglementee. La valeur numerique est
-- la SEVERITE : en cas de chevauchement, la plus grande valeur l'emporte.
noyau.SEVERITE = { CHARLIE = 1, BRAVO = 2, ALPHA = 3, ROMEO = 4 }
noyau.CLASSES  = { "CHARLIE", "BRAVO", "ALPHA", "ROMEO" }

-- Modes d'engagement du theatre.
noyau.MODES = { PAIX = "PAIX", GUERRE = "GUERRE" }

-- Statut d'identification ami-ennemi, deduit du seul transpondeur.
noyau.IFF = { ALLIE = "ALLIE", GENERAL = "GENERAL", INCONNU = "INCONNU" }

-- Les trois categories de cible transmises a Fire Control. C'est TOUT ce que
-- Command dit du type de cible : le choix de l'arme ne le regarde pas.
noyau.CATEGORIES = { INFANTERIE = "INFANTERIE", VEHICULE_SOL = "VEHICULE_SOL", AERIENNE = "AERIENNE" }

-- Nature brute du contact, telle que rapportee par le radar.
noyau.NATURES = {
  JOUEUR = "JOUEUR", VEHICULE = "VEHICULE", ENTITE = "ENTITE", MISSILE = "MISSILE",
}

--[[
  PALIERS D'ESCALADE
  ------------------
  L'escalade se fait en trois paliers : observation passive (1), scramble de
  verification (2), destruction (3). Le palier 0 n'est pas une escalade : c'est
  le libre passage sans aucun suivi, explicitement prevu pour le code general
  en zone Charlie et Bravo en temps de paix.
]]
noyau.PALIERS = { LIBRE = 0, OBSERVATION = 1, SCRAMBLE = 2, DESTRUCTION = 3 }

--[[
  VERDICTS
  --------
  Chaque verdict decrit exactement ce que Command demande au reseau :
    palier       : niveau d'escalade atteint (0 a 3)
    suivi        : la piste doit-elle rester surveillee ?
    feu          : un ordre de destruction doit-il partir ?
    scramble     : une interception de verification doit-elle partir ?
    mobilisation : l'ordre part-il vers TOUTES les plateformes disponibles ?
]]
noyau.VERDICTS = {
  HORS_JURIDICTION     = { palier = 0, suivi = false, feu = false, scramble = false, mobilisation = false,
                           libelle = "hors juridiction" },
  LIBRE                = { palier = 0, suivi = false, feu = false, scramble = false, mobilisation = false,
                           libelle = "libre passage sans suivi" },
  OBSERVATION          = { palier = 1, suivi = true,  feu = false, scramble = false, mobilisation = false,
                           libelle = "observation passive" },
  SCRAMBLE             = { palier = 2, suivi = true,  feu = false, scramble = true,  mobilisation = false,
                           libelle = "scramble de verification" },
  DESTRUCTION          = { palier = 3, suivi = true,  feu = true,  scramble = false, mobilisation = false,
                           libelle = "destruction" },
  DESTRUCTION_SCRAMBLE = { palier = 3, suivi = true,  feu = true,  scramble = true,  mobilisation = false,
                           libelle = "destruction avec scramble direct" },
  DESTRUCTION_TOTALE   = { palier = 3, suivi = true,  feu = true,  scramble = false, mobilisation = true,
                           libelle = "destruction totale, mobilisation generale" },
}

--------------------------------------------------------------------------------
-- 2. TABLE D'ENGAGEMENT
--    Source unique de verite. Toute la doctrine tient ici : si une regle doit
--    changer, elle change ici et nulle part ailleurs.
--
--    Lecture : TABLE_ENGAGEMENT[classeZone][mode][statutIff] -> nom de verdict
--------------------------------------------------------------------------------

noyau.TABLE_ENGAGEMENT = {

  -- CHARLIE : zone la moins reglementee.
  CHARLIE = {
    -- Paix : le code general passe librement et sans suivi ;
    --        l'inconnu est simplement suivi par un scramble, jamais detruit.
    PAIX   = { ALLIE = "OBSERVATION", GENERAL = "LIBRE",    INCONNU = "SCRAMBLE" },
    -- Guerre : le code general ne declenche QU'UN scramble de verification
    --          (c'est la difference avec Bravo) ; l'inconnu est detruit.
    GUERRE = { ALLIE = "OBSERVATION", GENERAL = "SCRAMBLE", INCONNU = "DESTRUCTION" },
  },

  -- BRAVO : meme regime que Charlie en paix, beaucoup plus dur en guerre.
  BRAVO = {
    PAIX   = { ALLIE = "OBSERVATION", GENERAL = "LIBRE",       INCONNU = "SCRAMBLE" },
    -- Guerre : tout ce qui n'a pas le code allie est detruit, sans distinction
    --          entre code general et inconnu.
    GUERRE = { ALLIE = "OBSERVATION", GENERAL = "DESTRUCTION", INCONNU = "DESTRUCTION" },
  },

  -- ALPHA : dans les deux modes, tout ce qui n'a pas le code allie est detruit
  --         immediatement, et la destruction s'accompagne TOUJOURS d'un
  --         scramble direct sur la cible.
  ALPHA = {
    PAIX   = { ALLIE = "OBSERVATION", GENERAL = "DESTRUCTION_SCRAMBLE", INCONNU = "DESTRUCTION_SCRAMBLE" },
    GUERRE = { ALLIE = "OBSERVATION", GENERAL = "DESTRUCTION_SCRAMBLE", INCONNU = "DESTRUCTION_SCRAMBLE" },
  },

  -- ROMEO : zone la plus reglementee. Destruction totale avec mobilisation
  --         generale dans les deux modes. Seule exception de tout le systeme :
  --         en temps de guerre, meme le code allie declenche un scramble de
  --         verification visuelle - sans engagement.
  ROMEO = {
    PAIX   = { ALLIE = "OBSERVATION", GENERAL = "DESTRUCTION_TOTALE", INCONNU = "DESTRUCTION_TOTALE" },
    GUERRE = { ALLIE = "SCRAMBLE",    GENERAL = "DESTRUCTION_TOTALE", INCONNU = "DESTRUCTION_TOTALE" },
  },
}

--------------------------------------------------------------------------------
-- 3. OUTILS DE BASE
--------------------------------------------------------------------------------

local function nombreValide(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end
noyau.nombreValide = nombreValide

local function distance2D(ax, az, bx, bz)
  local dx, dz = ax - bx, az - bz
  return math.sqrt(dx * dx + dz * dz)
end
noyau.distance2D = distance2D

local function distance3D(a, b)
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end
noyau.distance3D = distance3D

--------------------------------------------------------------------------------
-- 4. GEOMETRIE DES ZONES
--
--    Une zone se declare de deux facons, et de deux facons seulement :
--      rectangle : quatre points de coin { {x=,z=}, {x=,z=}, {x=,z=}, {x=,z=} }
--      cercle    : un centre { x=, z= } et un rayon
--
--    Les quatre points sont traites comme un vrai quadrilatere (test de
--    point-dans-polygone par lancer de rayon), ce qui accepte aussi bien un
--    rectangle aligne sur les axes qu'un rectangle pivote ou un quadrilatere
--    quelconque. Les coins peuvent etre donnes dans n'importe quel ordre
--    horaire ou antihoraire ; ils sont reordonnes a la validation.
--
--    Bornes verticales yMin / yMax facultatives (nil = illimite). Par defaut
--    une zone est une colonne infinie : c'est ce qu'on veut pour une zone de
--    defense aerienne.
--------------------------------------------------------------------------------

-- Reordonne 4 points en polygone convexe non croise (tri angulaire autour du
-- barycentre). Sans cela, des coins saisis "en Z" formeraient un sablier dont
-- le test d'appartenance serait faux.
function noyau.ordonnerCoins(points)
  local cx, cz = 0, 0
  for _, p in ipairs(points) do cx, cz = cx + p.x, cz + p.z end
  cx, cz = cx / #points, cz / #points
  local copie = {}
  for i, p in ipairs(points) do copie[i] = { x = p.x, z = p.z } end
  table.sort(copie, function(a, b)
    local aa = math.atan(a.z - cz, a.x - cx)
    local ab = math.atan(b.z - cz, b.x - cx)
    if aa == ab then return a.x < b.x end
    return aa < ab
  end)
  return copie
end

-- Lancer de rayon horizontal. Un point exactement sur une arete est considere
-- comme DANS la zone : en defense aerienne, le doute profite a la surveillance.
function noyau.pointDansPolygone(points, x, z)
  local dedans = false
  local n = #points
  local j = n
  for i = 1, n do
    local pi, pj = points[i], points[j]
    if (pi.z > z) ~= (pj.z > z) then
      local xIntersection = (pj.x - pi.x) * (z - pi.z) / (pj.z - pi.z) + pi.x
      if x < xIntersection then dedans = not dedans end
    end
    -- Point pose exactement sur l'arete [pi, pj] ?
    if math.abs((pj.x - pi.x) * (z - pi.z) - (pj.z - pi.z) * (x - pi.x)) < 1e-9
       and x >= math.min(pi.x, pj.x) - 1e-9 and x <= math.max(pi.x, pj.x) + 1e-9
       and z >= math.min(pi.z, pj.z) - 1e-9 and z <= math.max(pi.z, pj.z) + 1e-9 then
      return true
    end
    j = i
  end
  return dedans
end

function noyau.pointDansZone(zone, x, y, z)
  if type(zone) ~= "table" then return false end
  if not (nombreValide(x) and nombreValide(z)) then return false end

  -- Bornes verticales facultatives.
  if nombreValide(y) then
    if nombreValide(zone.yMin) and y < zone.yMin then return false end
    if nombreValide(zone.yMax) and y > zone.yMax then return false end
  end

  --[[
    Rejet rapide par boite englobante, calculee une fois et memorisee sur la
    zone. Quatre comparaisons ecartent l'immense majorite des points sans
    lancer de rayon ni calculer de racine carree. Une zone n'est jamais
    modifiee en place - elle est remplacee - donc le memo ne peut pas devenir
    faux.
  ]]
  local boite = zone._boite
  if not boite then
    if zone.forme == "cercle" and zone.centre and nombreValide(zone.rayon) then
      boite = { xMin = zone.centre.x - zone.rayon, xMax = zone.centre.x + zone.rayon,
                zMin = zone.centre.z - zone.rayon, zMax = zone.centre.z + zone.rayon }
    elseif zone.forme == "rectangle" and type(zone.points) == "table" and #zone.points >= 3 then
      local xMin, xMax, zMin, zMax = math.huge, -math.huge, math.huge, -math.huge
      for _, p in ipairs(zone.points) do
        if p.x < xMin then xMin = p.x end
        if p.x > xMax then xMax = p.x end
        if p.z < zMin then zMin = p.z end
        if p.z > zMax then zMax = p.z end
      end
      boite = { xMin = xMin, xMax = xMax, zMin = zMin, zMax = zMax }
    end
    zone._boite = boite
  end
  if boite and (x < boite.xMin or x > boite.xMax or z < boite.zMin or z > boite.zMax) then
    return false
  end

  if zone.forme == "cercle" then
    if not (zone.centre and nombreValide(zone.rayon)) then return false end
    return distance2D(x, z, zone.centre.x, zone.centre.z) <= zone.rayon
  elseif zone.forme == "rectangle" then
    if type(zone.points) ~= "table" or #zone.points < 3 then return false end
    return noyau.pointDansPolygone(zone.points, x, z)
  end
  return false
end

--[[
  Determine la classe applicable a un point.
  En cas de chevauchement, la classe la plus stricte l'emporte TOUJOURS :
  Romeo sur Alpha, Alpha sur Bravo, Bravo sur Charlie.
  Retourne : classe (ou nil si hors de toute zone), zone retenue, liste des
  zones chevauchees (pour le journal).
]]
function noyau.zonePourPoint(zones, x, y, z)
  local classe, retenue, chevauchees = nil, nil, {}
  if type(zones) ~= "table" then return nil, nil, chevauchees end

  for _, zone in ipairs(zones) do
    if zone.actif ~= false and noyau.pointDansZone(zone, x, y, z) then
      chevauchees[#chevauchees + 1] = zone
      local severite = noyau.SEVERITE[zone.classe]
      if severite and (not classe or severite > noyau.SEVERITE[classe]) then
        classe, retenue = zone.classe, zone
      end
    end
  end
  return classe, retenue, chevauchees
end

--------------------------------------------------------------------------------
-- 5. CATEGORISATION DE LA CIBLE
--
--    Deux criteres, comme specifie :
--      - la nature du contact (joueur ou vehicule), enrichie par la faction
--        quand un roster est disponible ;
--      - l'altitude, mesuree AU-DESSUS DU SOL DE REFERENCE et non en Y absolu :
--        un char sur un plateau a Y=200 reste un vehicule au sol.
--
--    Le resultat est l'une des trois categories, et rien d'autre. Le choix de
--    l'arme appartient a Fire Control.
--------------------------------------------------------------------------------

--[[
  solConnu : altitude du sol mesuree par le modele de terrain observe, quand
  celui-ci sait repondre pour ce point. Elle prime sur toute valeur declaree :
  un releve vaut mieux qu'une hypothese. A defaut, on retombe sur le sol de
  reference de la zone, puis sur celui de la configuration.
]]
function noyau.categoriser(contact, config, zone, solConnu)
  config = config or {}
  local solReference = (nombreValide(solConnu) and solConnu)
                    or (zone and nombreValide(zone.solY) and zone.solY)
                    or (nombreValide(config.altitudeSolReference) and config.altitudeSolReference)
                    or 64
  local hauteurAerienne = nombreValide(config.hauteurAerienne) and config.hauteurAerienne or 25
  local vitesseVerticaleAerienne = nombreValide(config.vitesseVerticaleAerienne)
                                   and config.vitesseVerticaleAerienne or 6

  -- Un missile est une cible AERIENNE quelle que soit son altitude. Un obus
  -- qui rase le sol reste un projectile : le classer "vehicule au sol" le
  -- ferait traiter par un appui sol, contre quelque chose qui va trop vite
  -- pour ca.
  if contact.nature == noyau.NATURES.MISSILE then
    return noyau.CATEGORIES.AERIENNE, "projectile detecte, cible aerienne par nature"
  end

  local hauteurSol = (nombreValide(contact.y) and (contact.y - solReference)) or 0

  -- Critere principal : l'altitude au-dessus du sol de reference.
  local aerienne = hauteurSol >= hauteurAerienne
  local motif = string.format("hauteur sol %.0f (seuil %.0f)", hauteurSol, hauteurAerienne)

  -- Critere secondaire : une montee ou une chute soutenue trahit un aeronef
  -- meme lorsqu'il rase encore le relief (decollage, ressource en vallee).
  if not aerienne and nombreValide(contact.vitesseVerticale)
     and math.abs(contact.vitesseVerticale) >= vitesseVerticaleAerienne then
    aerienne = true
    motif = string.format("vitesse verticale %.1f b/s (seuil %.1f)",
      contact.vitesseVerticale, vitesseVerticaleAerienne)
  end

  if aerienne then
    return noyau.CATEGORIES.AERIENNE, motif
  end

  if contact.nature == noyau.NATURES.JOUEUR then
    return noyau.CATEGORIES.INFANTERIE, motif .. ", nature joueur"
  end
  return noyau.CATEGORIES.VEHICULE_SOL, motif .. ", nature vehicule"
end

--------------------------------------------------------------------------------
-- 6. IDENTIFICATION AMI-ENNEMI (TRANSPONDEUR)
--
--    Regle absolue de la doctrine : l'absence de code ou un code invalide
--    classe automatiquement la cible comme INCONNU. Aucune faction, aucun nom,
--    aucune reputation ne rattrape un transpondeur muet.
--
--    codeAllie   : code fixe, libre passage (sauf Romeo en guerre).
--    codeGeneral : code tournant, change regulierement pour la securite.
--                  Le code precedent reste accepte pendant une periode de
--                  grace, sans quoi une rotation abattrait toute la flotte
--                  qui n'a pas encore recu le nouveau code.
--------------------------------------------------------------------------------

function noyau.statutIff(transpondeur, codes, maintenant, config, allieManuel)
  codes = codes or {}
  config = config or {}
  maintenant = maintenant or 0

  --[[
    Declaration manuelle par un controleur, depuis la carte tactique.
    Elle PRIME sur le transpondeur : un allie dont l'emetteur est detruit ou
    dont l'ordinateur a saute doit pouvoir etre couvert a la main, tout de
    suite, sans passer par une rotation de code. C'est une decision humaine
    assumee, donc journalisee comme telle et revocable d'un clic.
  ]]
  if allieManuel then
    return noyau.IFF.ALLIE, "allie declare manuellement par un controleur"
  end

  if type(transpondeur) ~= "table" or type(transpondeur.code) ~= "string"
     or transpondeur.code == "" then
    return noyau.IFF.INCONNU, "aucun code transpondeur recu"
  end

  local validite = nombreValide(config.validiteTranspondeur) and config.validiteTranspondeur or 15
  local age = maintenant - (transpondeur.recuA or 0)
  if age > validite then
    return noyau.IFF.INCONNU, string.format("code perime (%.0fs > %.0fs)", age, validite)
  end

  local grace = nombreValide(config.graceRotation) and config.graceRotation or 300

  --[[
    Periode de grace : apres une rotation, l'ancien code reste accepte le
    temps que la flotte recoive le nouveau. Sans elle, tourner un code
    declasserait INCONNU tous les appareils encore en vol - et la doctrine de
    zone ferait le reste.
    Les DEUX codes se tournent independamment, chacun avec sa propre date de
    rotation : tourner le code general ne doit pas ouvrir de grace sur le code
    allie, et reciproquement.
  ]]
  local function dansLaGrace(instantRotation)
    local depuis = maintenant - (instantRotation or 0)
    return depuis <= grace, depuis
  end

  if type(codes.codeAllie) == "string" and codes.codeAllie ~= ""
     and transpondeur.code == codes.codeAllie then
    return noyau.IFF.ALLIE, "code allie valide"
  end

  if type(codes.codeAlliePrecedent) == "string" and codes.codeAlliePrecedent ~= ""
     and transpondeur.code == codes.codeAlliePrecedent then
    local dedans, depuis = dansLaGrace(codes.rotationAllieA)
    if dedans then
      return noyau.IFF.ALLIE, string.format(
        "code allie precedent, grace %.0fs/%.0fs", depuis, grace)
    end
    return noyau.IFF.INCONNU, "code allie precedent expire"
  end

  if type(codes.codeGeneral) == "string" and codes.codeGeneral ~= ""
     and transpondeur.code == codes.codeGeneral then
    return noyau.IFF.GENERAL, "code general valide"
  end

  if type(codes.codeGeneralPrecedent) == "string" and codes.codeGeneralPrecedent ~= ""
     and transpondeur.code == codes.codeGeneralPrecedent then
    local dedans, depuis = dansLaGrace(codes.rotationGeneraleA or codes.rotationA)
    if dedans then
      return noyau.IFF.GENERAL, string.format(
        "code general precedent, grace %.0fs/%.0fs", depuis, grace)
    end
    return noyau.IFF.INCONNU, "code general precedent expire"
  end

  return noyau.IFF.INCONNU, "code invalide"
end

--------------------------------------------------------------------------------
-- 6 bis. DEUXIEME VOIE D'IDENTIFICATION : LES DONNEES DU RADAR
--
--   Le transpondeur repond a « quel code porte cet appareil ». Le radar
--   repond a « qu'est-ce que cet appareil, et a qui est-il ». Ce sont deux
--   questions differentes, et c'est ce qui fait leur valeur : un transpondeur
--   se capture avec l'engin qui le porte, le proprietaire d'une contraption
--   non. Un code allie porte par un engin identifie hostile est le signe d'un
--   transpondeur capture - exactement ce qu'une voie unique laisserait passer.
--
--   Sources de la voie radar, par ordre de priorite :
--     1. les listes nomsHostiles / nomsAllies de la configuration : aucune
--        dependance exterieure, utilisables des le premier jour ;
--     2. le roster de factions pousse par un pont Open Parties and Claims ;
--     3. les champs proprietaire et equipe rendus par Create Radars.
--
--   La voie radar ne DONNE jamais l'acces a elle seule : la doctrine reste
--   « pas de code valide = INCONNU ». Elle peut en revanche le RETIRER, et
--   c'est tout son interet defensif.
--------------------------------------------------------------------------------

noyau.IDENTIFICATION_RADAR = {
  ALLIE = "ALLIE", HOSTILE = "HOSTILE", NEUTRE = "NEUTRE", INCONNU = "INCONNU",
}

noyau.CONCORDANCE = {
  CONFIRME  = "CONFIRME",   -- les deux voies disent la meme chose
  PARTIEL   = "PARTIEL",    -- une seule voie s'est prononcee
  DISCORDANT = "DISCORDANT", -- les deux voies se contredisent
  AUCUNE    = "AUCUNE",     -- aucune voie ne s'est prononcee
}

-- Correspondance d'un libelle avec une liste. Egalite exacte d'abord, puis
-- sous-chaine insensible a la casse : un escadron nomme "RAID-01" doit pouvoir
-- etre couvert par l'entree "RAID" sans enumerer tous ses appareils.
local function figureDansListe(valeur, liste)
  if type(valeur) ~= "string" or type(liste) ~= "table" then return false end
  for _, entree in ipairs(liste) do
    if type(entree) == "string" and entree ~= "" then
      if valeur == entree then return true, entree end
      if valeur:lower():find(entree:lower(), 1, true) then return true, entree end
    end
  end
  return false
end
noyau.figureDansListe = figureDansListe

--[[
  Identification par les seules donnees du radar.
  Retourne : statut, motif journalisable.
]]
function noyau.identifierParRadar(contact, roster, config)
  config = config or {}
  roster = roster or {}
  if config.identificationRadarActive == false then
    return noyau.IDENTIFICATION_RADAR.INCONNU, "voie radar desactivee en configuration"
  end

  local meta = contact.meta or {}
  -- Le nom du contact, son proprietaire et son equipe sont examines : l'un
  -- des trois suffit a trancher.
  local candidats = {
    { valeur = contact.nom, source = "nom" },
    { valeur = meta.proprietaire, source = "proprietaire" },
    { valeur = meta.equipe, source = "equipe" },
  }

  -- Hostile d'abord : en cas de double appartenance, le doute ne profite pas
  -- a la cible.
  for _, c in ipairs(candidats) do
    local trouve, entree = figureDansListe(c.valeur, config.nomsHostiles)
    if trouve then
      return noyau.IDENTIFICATION_RADAR.HOSTILE, string.format(
        "%s '%s' figure sur la liste hostile (entree '%s')", c.source, tostring(c.valeur), entree)
    end
  end

  for _, c in ipairs(candidats) do
    if type(c.valeur) == "string" then
      local entree = roster[c.valeur]
      if type(entree) == "table" then
        local hostilite = tostring(entree.hostilite or ""):upper()
        if hostilite == "HOSTILE" then
          return noyau.IDENTIFICATION_RADAR.HOSTILE, string.format(
            "%s '%s' declare hostile par le roster (faction %s)",
            c.source, c.valeur, tostring(entree.faction))
        end
        if hostilite == "ALLIEE" or hostilite == "ALLIE" then
          return noyau.IDENTIFICATION_RADAR.ALLIE, string.format(
            "%s '%s' declare allie par le roster (faction %s)",
            c.source, c.valeur, tostring(entree.faction))
        end
        return noyau.IDENTIFICATION_RADAR.NEUTRE, string.format(
          "%s '%s' connu du roster, faction %s sans hostilite declaree",
          c.source, c.valeur, tostring(entree.faction))
      end
    end
  end

  for _, c in ipairs(candidats) do
    local trouve, entree = figureDansListe(c.valeur, config.nomsAllies)
    if trouve then
      return noyau.IDENTIFICATION_RADAR.ALLIE, string.format(
        "%s '%s' figure sur la liste alliee (entree '%s')", c.source, tostring(c.valeur), entree)
    end
  end

  local vus = {}
  for _, c in ipairs(candidats) do
    if type(c.valeur) == "string" then
      vus[#vus + 1] = c.source .. "=" .. c.valeur
    end
  end
  return noyau.IDENTIFICATION_RADAR.INCONNU,
    #vus > 0 and ("aucune correspondance pour " .. table.concat(vus, ", "))
    or "le radar ne fournit aucun element d'identification"
end

--[[
  IDENTIFICATION COMBINEE - c'est cette fonction que le systeme appelle.

  Retourne : iff, motif journalisable, detail.
  detail = {
    transpondeur = { statut, motif },
    radar        = { statut, motif },
    concordance  = ...,
    alerte       = message a remonter au controleur, ou nil,
  }

  Regle cardinale, inchangee : sans code valide, la cible est INCONNUE. La
  voie radar ne delivre aucun laissez-passer. Elle peut seulement en retirer
  un, quand elle contredit franchement le transpondeur.
]]
function noyau.identifier(contact, transpondeur, codes, roster, maintenant, config, allieManuel)
  config = config or {}
  local detail = {}

  local statutTr, motifTr = noyau.statutIff(transpondeur, codes, maintenant, config, allieManuel)
  local statutRa, motifRa = noyau.identifierParRadar(contact, roster, config)
  detail.transpondeur = { statut = statutTr, motif = motifTr }
  detail.radar        = { statut = statutRa, motif = motifRa }

  local R = noyau.IDENTIFICATION_RADAR
  local C = noyau.CONCORDANCE

  -- La declaration manuelle d'un controleur est une decision humaine : elle
  -- n'est pas soumise au recoupement, et elle est deja journalisee ailleurs.
  if allieManuel then
    detail.concordance = C.PARTIEL
    return noyau.IFF.ALLIE, motifTr, detail
  end

  local codePorteur = (statutTr == noyau.IFF.ALLIE) or (statutTr == noyau.IFF.GENERAL)

  ----------------------------------------------------------------- discordance
  if codePorteur and statutRa == R.HOSTILE then
    detail.concordance = C.DISCORDANT
    detail.alerte = string.format(
      "code %s valide porte par un contact identifie HOSTILE par le radar (%s) : " ..
      "transpondeur probablement capture",
      statutTr == noyau.IFF.ALLIE and "ALLIE" or "GENERAL", motifRa)
    if config.discordanceDeclasse ~= false then
      return noyau.IFF.INCONNU, string.format(
        "DISCORDANCE des deux voies -> declasse INCONNU | transpondeur : %s | radar : %s",
        motifTr, motifRa), detail
    end
    return statutTr, string.format(
      "DISCORDANCE des deux voies, code conserve (discordanceDeclasse = false) | " ..
      "transpondeur : %s | radar : %s", motifTr, motifRa), detail
  end

  ------------------------------------------------------------------ concordance
  if codePorteur then
    detail.concordance = (statutRa == R.ALLIE) and C.CONFIRME or C.PARTIEL
    return statutTr, string.format("%s | transpondeur : %s | radar : %s",
      detail.concordance == C.CONFIRME and "identification CONFIRMEE par les deux voies"
        or "identification par transpondeur seul",
      motifTr, motifRa), detail
  end

  ------------------------------------------------- pas de code valide : inconnu
  if statutRa == R.ALLIE then
    -- Le radar reconnait un ami, mais la doctrine est formelle : sans code
    -- valide la cible reste INCONNUE. Le signaler permet au controleur de la
    -- declarer alliee a la main en connaissance de cause, plutot que de la
    -- laisser se faire engager.
    detail.concordance = C.DISCORDANT
    detail.alerte = string.format(
      "contact identifie ALLIE par le radar (%s) mais SANS code transpondeur valide (%s) : " ..
      "emetteur en panne ? Il reste INCONNU tant qu'un controleur ne le declare pas allie",
      motifRa, motifTr)
    return noyau.IFF.INCONNU, string.format(
      "sans code valide -> INCONNU malgre une identification radar alliee | " ..
      "transpondeur : %s | radar : %s", motifTr, motifRa), detail
  end

  if statutRa == R.HOSTILE then
    detail.concordance = C.CONFIRME
    return noyau.IFF.INCONNU, string.format(
      "hostile CONFIRME par les deux voies | transpondeur : %s | radar : %s",
      motifTr, motifRa), detail
  end

  detail.concordance = (statutRa == R.INCONNU) and C.AUCUNE or C.PARTIEL
  return noyau.IFF.INCONNU, string.format(
    "transpondeur : %s | radar : %s", motifTr, motifRa), detail
end

--------------------------------------------------------------------------------
-- 7. VERDICT D'ENGAGEMENT
--------------------------------------------------------------------------------

--[[
  Retourne : nomVerdict, verdict (table), motif (chaine journalisable).

  classeZone : "CHARLIE" | "BRAVO" | "ALPHA" | "ROMEO" | nil
               nil signifie zone non classifiee -> neutre ou hors juridiction :
               le systeme ne fait RIEN, ni surveillance ni action.
  alerteMax  : alerte maximale declenchee manuellement par un controleur.
               Elle applique partout le regime le plus dur du systeme
               (Romeo en temps de guerre), independamment de la zone.
]]
function noyau.verdict(classeZone, mode, statutIff, alerteMax, config)
  config = config or {}

  if not classeZone then
    -- Hors juridiction. L'alerte maximale n'y change rien par defaut : une
    -- zone non classifiee reste non classifiee, c'est le sens meme de la
    -- regle. Le drapeau ci-dessous permet d'etendre l'alerte maximale a tout
    -- le monde si le commandement le decide explicitement.
    if alerteMax and config.alerteMaxCouvreHorsZone == true then
      classeZone = "ROMEO"
    else
      return "HORS_JURIDICTION", noyau.VERDICTS.HORS_JURIDICTION,
             "zone non classifiee, aucune action"
    end
  end

  local classeEffective = classeZone
  local modeEffectif = (mode == noyau.MODES.GUERRE) and noyau.MODES.GUERRE or noyau.MODES.PAIX
  local motifSuffixe = ""

  if alerteMax then
    classeEffective = "ROMEO"
    modeEffectif = noyau.MODES.GUERRE
    motifSuffixe = " [ALERTE MAXIMALE manuelle: regime ROMEO/GUERRE force]"
  end

  local parClasse = noyau.TABLE_ENGAGEMENT[classeEffective]
  if not parClasse then
    return "HORS_JURIDICTION", noyau.VERDICTS.HORS_JURIDICTION,
           "classe de zone inconnue: " .. tostring(classeEffective)
  end

  local statut = noyau.IFF[statutIff] and statutIff or noyau.IFF.INCONNU
  local nom = parClasse[modeEffectif][statut]
  local verdict = noyau.VERDICTS[nom]

  local motif = string.format("zone %s / %s / IFF %s -> %s%s",
    classeEffective, modeEffectif, statut, verdict.libelle, motifSuffixe)
  return nom, verdict, motif
end

--------------------------------------------------------------------------------
-- 8. DESIGNATION DU TIREUR
--
--    Command ne choisit pas d'arme. Il choisit QUI reagit, parmi les
--    plateformes dont les balises de lanceur se sont annoncees :
--
--      score =   poidsMunitions * (1 - munitions / munitionsMax)
--              + poidsDistance  * (distance / distanceMax)
--              + poidsTirs      * (tirs / tirsMax)
--
--    Les trois termes sont normalises sur le lot de candidats, sinon un reseau
--    etendu ferait toujours gagner la distance et un reseau bien approvisionne
--    toujours les munitions. Score le plus BAS = designe.
--
--    Le terme munitions est le premier de la liste et le plus lourd par
--    defaut : envoyer l'ordre a une rampe presque vide, c'est perdre la cible
--    au deuxieme tir. Une plateforme a stock NUL n'est pas designee du tout.
--    Le terme tirs subsiste, plus leger : a munitions et distance comparables,
--    il repartit l'usure entre les pieces.
--
--    Egalite parfaite : ordre alphabetique. Le determinisme n'est pas un
--    detail : c'est ce qui rend une decision rejouable a partir du journal.
--------------------------------------------------------------------------------

-- Une plateforme peut declarer les categories qu'elle sait traiter. Une
-- batterie anti-aerienne pure ne doit pas recevoir un ordre sur de l'infanterie.
local function traiteLaCategorie(p, categorie)
  if type(p.categories) ~= "table" or #p.categories == 0 then return true end
  if not categorie then return true end
  for _, c in ipairs(p.categories) do
    if c == categorie then return true end
  end
  return false
end

function noyau.designer(plateformes, cible, config)
  config = config or {}
  local poidsMunitions = nombreValide(config.poidsMunitions) and config.poidsMunitions or 1.5
  local poidsDistance  = nombreValide(config.poidsDistance) and config.poidsDistance or 1.0
  local poidsTirs      = nombreValide(config.poidsTirs) and config.poidsTirs or 0.5
  local horsPortee     = config.designerHorsPortee == true

  local candidats, rejetes = {}, {}
  if type(plateformes) ~= "table" then return candidats, rejetes end

  for _, p in ipairs(plateformes) do
    local nom = tostring(p.nom or p.name or "?")
    -- Le stock passe avant le drapeau de disponibilite : une balise a sec se
    -- declare aussi indisponible, et « stock de munitions epuise » dit au
    -- controleur quoi faire, la ou « indisponible » ne dit rien.
    if nombreValide(p.munitions) and p.munitions <= 0 then
      rejetes[#rejetes + 1] = { nom = nom, motif = "stock de munitions epuise" }
    elseif p.disponible == false then
      rejetes[#rejetes + 1] = { nom = nom, motif = "declaree indisponible" }
    elseif not traiteLaCategorie(p, cible and cible.categorie) then
      rejetes[#rejetes + 1] = { nom = nom,
        motif = "ne traite pas la categorie " .. tostring(cible and cible.categorie) }
    elseif not (nombreValide(p.x) and nombreValide(p.y) and nombreValide(p.z)) then
      rejetes[#rejetes + 1] = { nom = nom, motif = "position invalide" }
    else
      local d = distance3D(p, cible)
      if nombreValide(p.portee) and d > p.portee and not horsPortee then
        rejetes[#rejetes + 1] = { nom = nom,
          motif = string.format("hors portee (%.0f > %.0f)", d, p.portee) }
      else
        candidats[#candidats + 1] = {
          nom = nom, distance = d,
          tirs      = nombreValide(p.tirs) and p.tirs or 0,
          munitions = nombreValide(p.munitions) and p.munitions or nil,
          plateforme = p,
        }
      end
    end
  end

  if #candidats == 0 then return candidats, rejetes end

  local tirsMax, distMax, munitionsMax = 0, 0, 0
  local munitionsConnues = false
  for _, c in ipairs(candidats) do
    if c.tirs > tirsMax then tirsMax = c.tirs end
    if c.distance > distMax then distMax = c.distance end
    if c.munitions then
      munitionsConnues = true
      if c.munitions > munitionsMax then munitionsMax = c.munitions end
    end
  end
  if tirsMax <= 0 then tirsMax = 1 end
  if distMax <= 0 then distMax = 1 end
  if munitionsMax <= 0 then munitionsMax = 1 end

  for _, c in ipairs(candidats) do
    c.distanceNormalisee = c.distance / distMax
    c.chargeNormalisee   = c.tirs / tirsMax
    -- Sans aucune balise de lanceur annoncant son stock, le terme munitions
    -- serait arbitraire : on le neutralise plutot que d'inventer une valeur.
    c.stockNormalise = munitionsConnues and ((c.munitions or 0) / munitionsMax) or 1
    c.penaliteStock  = munitionsConnues and (1 - c.stockNormalise) or 0

    c.score = poidsMunitions * c.penaliteStock
            + poidsDistance  * c.distanceNormalisee
            + poidsTirs      * c.chargeNormalisee
  end

  table.sort(candidats, function(a, b)
    if math.abs(a.score - b.score) > 1e-9 then return a.score < b.score end
    return a.nom < b.nom
  end)

  return candidats, rejetes
end

--------------------------------------------------------------------------------
-- 9. FORMATAGE DES ORDRES VERS FIRE CONTROL
--
--    Format specifie : « NomPlateforme Fire type Classe »
--    exemple          : « AirShip1 Fire type Aerial »
--
--    AVERTISSEMENT DE SECURITE : un scramble de verification n'est PAS un
--    ordre de tir. En zone Romeo en temps de guerre, un vehicule porteur du
--    code allie declenche un scramble « sans engagement » : lui envoyer le
--    verbe « Fire » ferait tirer Fire Control sur un allie. Les deux verbes
--    sont donc distincts par defaut. Si votre Fire Control ne comprend qu'un
--    seul verbe, passez formatUniqueFire a true dans la configuration - en
--    sachant exactement ce que cela implique.
--------------------------------------------------------------------------------

noyau.CATEGORIES_FIRE_CONTROL = {
  AERIENNE     = "Aerial",
  VEHICULE_SOL = "GroundVehicle",
  INFANTERIE   = "Infantry",
}

--[[
  SCRAMBLE AIR-SOL
  Un intercepteur lance contre un aeronef et un appui lance contre de
  l'infanterie ne font pas le meme metier, ne partent pas avec la meme charge
  et n'abordent pas la cible de la meme facon. Les deux paliers de scramble
  portent donc des verbes distincts :

      cible AERIENNE                      -> « Scramble »
      cible INFANTERIE ou VEHICULE_SOL    -> « Scramble AG »   (air-sol)

  Exemple : « AirShip1 Scramble AG type GroundVehicle »
]]
noyau.CATEGORIES_SOL = { INFANTERIE = true, VEHICULE_SOL = true }

--[[
  LE SCRAMBLE AG N'EST JAMAIS AUTOMATIQUE.

  Lancer une patrouille air-sol contre de l'infanterie ou un vehicule engage
  des hommes et des appareils sur une cible qui, la plupart du temps, se
  trouve simplement au mauvais endroit : un joueur qui traverse a pied, un
  convoi allie sans transpondeur. Le systeme sait detecter et classer ; il ne
  decide pas seul d'envoyer une patrouille au sol.

  Quand la doctrine de zone appelle un scramble sur une cible au sol, Command
  ne transmet donc rien : il enregistre une DEMANDE DE SCRAMBLE AG et alerte
  le controleur, qui la valide - ou non - depuis la carte tactique. Un ordre
  manuel, lui, part immediatement : c'est deja une decision humaine.

  Le feu n'est pas concerne : une destruction decidee par la doctrine reste
  automatique, au sol comme en l'air.
]]
function noyau.scrambleRequiertControleur(role, categorie, config, manuel)
  config = config or {}
  if role ~= "SCRAMBLE" then return false end
  if manuel then return false end
  if not noyau.CATEGORIES_SOL[categorie] then return false end
  return config.scrambleAGAutomatique ~= true
end

function noyau.verbePourOrdre(role, categorie, config)
  config = config or {}
  if role ~= "SCRAMBLE" then return config.verbeFeu or "Fire" end
  -- Fire Control qui ne comprend qu'un seul verbe : tout devient « Fire ».
  if config.formatUniqueFire == true then return config.verbeFeu or "Fire" end
  if noyau.CATEGORIES_SOL[categorie] then
    return config.verbeScrambleAG or "Scramble AG"
  end
  return config.verbeScramble or "Scramble"
end

function noyau.formaterOrdre(role, nomPlateforme, categorie, config)
  config = config or {}
  local table_categories = config.categoriesFireControl or noyau.CATEGORIES_FIRE_CONTROL
  local libelle = table_categories[categorie] or tostring(categorie)
  local verbe = noyau.verbePourOrdre(role, categorie, config)
  local modele = config.modeleOrdre or "%s %s type %s"
  return string.format(modele, tostring(nomPlateforme), verbe, libelle)
end

--------------------------------------------------------------------------------
-- 10. PLAN D'ENGAGEMENT
--     Traduit un verdict en liste concrete d'ordres a emettre, une fois les
--     plateformes designees.
--------------------------------------------------------------------------------

function noyau.planifier(verdict, candidats)
  local ordres = {}
  if not verdict or #candidats == 0 then return ordres end

  if verdict.mobilisation then
    -- Romeo : mobilisation generale, toutes les plateformes disponibles.
    for _, c in ipairs(candidats) do
      ordres[#ordres + 1] = { role = "FIRE", candidat = c }
    end
    return ordres
  end

  if verdict.feu then
    ordres[#ordres + 1] = { role = "FIRE", candidat = candidats[1] }
    if verdict.scramble then
      -- Alpha : la destruction s'accompagne TOUJOURS d'un scramble direct.
      -- On prend la deuxieme meilleure plateforme si elle existe, pour ne pas
      -- demander a une seule plateforme d'etre a la fois canon et intercepteur.
      ordres[#ordres + 1] = { role = "SCRAMBLE", candidat = candidats[2] or candidats[1] }
    end
    return ordres
  end

  if verdict.scramble then
    ordres[#ordres + 1] = { role = "SCRAMBLE", candidat = candidats[1] }
  end
  return ordres
end

--------------------------------------------------------------------------------
-- 11. CONFIRMATION DE DESTRUCTION
--
--     Deux declencheurs INDEPENDANTS. L'un OU l'autre confirme ; si aucun des
--     deux n'apparait dans le delai, on reemet un ordre de tir.
--
--     Declencheur A - disparition complete du radar.
--       Piege : une cible qui sort simplement de portee, dont le chunk se
--       decharge, ou dont le pilote se deconnecte disparait EXACTEMENT comme
--       une cible detruite. Prise au pied de la lettre, cette regle declare
--       "detruit" tout ce qui reussit a s'echapper - c'est-a-dire qu'elle fait
--       cesser le feu precisement sur ce qu'il fallait continuer a traiter.
--       Garde-fou : la disparition ne confirme que si le dernier point connu
--       etait DANS L'ENVELOPPE FIABLE du radar (ratioEnveloppeFiable de la
--       portee). Au-dela, la piste est declaree PERDUE, pas detruite, et la
--       sequence de reemission continue.
--
--     Declencheur B - signature de crash.
--       Perte d'au moins 50 % de vitesse horizontale ET d'environ 40 blocs
--       d'altitude sur la MEME fenetre de trois secondes. Les deux ensemble
--       distinguent un crash d'une manoeuvre volontaire : un pilote qui pique
--       gagne de la vitesse, un pilote qui freine ne perd pas 40 blocs.
--------------------------------------------------------------------------------

noyau.RESULTATS_KILL = {
  CONFIRME    = "CONFIRME",
  EN_ATTENTE  = "EN_ATTENTE",
  AUCUN_SIGNAL = "AUCUN_SIGNAL",
  PERDU       = "PERDU",
}

-- Vitesse horizontale (blocs/s) entre deux echantillons consecutifs.
local function vitesseHorizontale(a, b)
  local dt = b.t - a.t
  if dt <= 0 then return nil end
  return distance2D(b.x, b.z, a.x, a.z) / dt
end

--[[
  piste      : { echantillons = { {t=,x=,y=,z=}, ... } (ordre chronologique),
                 vuA = instant du dernier contact radar,
                 present = booleen,
                 distanceRadar = distance du dernier point au radar }
  evaluation : { ordreA = instant du dernier ordre de tir,
                 vitesseRef = vitesse horizontale relevee avant le tir,
                 tentatives = nombre d'ordres deja emis }
  config     : seuils (voir config_command.lua)
]]
function noyau.evaluerDestruction(piste, evaluation, config, maintenant)
  config = config or {}
  local fenetre        = nombreValide(config.fenetreCrashSecondes) and config.fenetreCrashSecondes or 3
  local perteVitesse   = nombreValide(config.perteVitesseRatio) and config.perteVitesseRatio or 0.50
  local perteAltitude  = nombreValide(config.perteAltitudeBlocs) and config.perteAltitudeBlocs or 40
  local vitesseMini    = nombreValide(config.vitesseMiniCrash) and config.vitesseMiniCrash or 2
  local disparition    = nombreValide(config.disparitionSecondes) and config.disparitionSecondes or 3
  local delaiEval      = nombreValide(config.delaiEvaluationSecondes) and config.delaiEvaluationSecondes or 8
  local ratioEnveloppe = nombreValide(config.ratioEnveloppeFiable) and config.ratioEnveloppeFiable or 0.80
  local porteeRadar    = nombreValide(config.porteeRadar) and config.porteeRadar or 0

  local ecoule = maintenant - (evaluation.ordreA or maintenant)

  ---------------------------------------------------------------- declencheur A
  if piste.present == false then
    local absentDepuis = maintenant - (piste.vuA or maintenant)
    if absentDepuis >= disparition then
      local enveloppe = porteeRadar * ratioEnveloppe
      if porteeRadar <= 0 or (nombreValide(piste.distanceRadar) and piste.distanceRadar <= enveloppe) then
        return noyau.RESULTATS_KILL.CONFIRME, string.format(
          "declencheur A: disparition radar depuis %.1fs, dernier point a %.0fm (enveloppe fiable %.0fm)",
          absentDepuis, piste.distanceRadar or -1, enveloppe)
      end
      -- Disparu au bord de la portee : c'est une fuite jusqu'a preuve du
      -- contraire, pas une destruction.
      if ecoule >= delaiEval then
        return noyau.RESULTATS_KILL.PERDU, string.format(
          "piste perdue hors enveloppe fiable (%.0fm > %.0fm) : sortie de portee probable, PAS une destruction",
          piste.distanceRadar or -1, enveloppe)
      end
      return noyau.RESULTATS_KILL.EN_ATTENTE, string.format(
        "disparition au bord de portee (%.0fm), confirmation refusee",
        piste.distanceRadar or -1)
    end
  end

  ---------------------------------------------------------------- declencheur B
  local ech = piste.echantillons or {}
  if #ech >= 2 then
    local fin = ech[#ech]
    -- Echantillon le plus recent anterieur a (maintenant - fenetre).
    local debut, indexDebut
    for i = #ech, 1, -1 do
      if fin.t - ech[i].t >= fenetre then debut, indexDebut = ech[i], i break end
    end
    if debut and indexDebut and indexDebut >= 2 then
      local vDebut = vitesseHorizontale(ech[indexDebut - 1], debut)
      local vFin   = vitesseHorizontale(ech[#ech - 1], fin)
      local chute  = debut.y - fin.y
      if vDebut and vFin and vDebut >= vitesseMini then
        local perteReelle = 1 - (vFin / vDebut)
        if perteReelle >= perteVitesse and chute >= perteAltitude then
          return noyau.RESULTATS_KILL.CONFIRME, string.format(
            "declencheur B: -%.0f%% de vitesse horizontale (%.1f -> %.1f b/s) et -%.0f blocs sur %.1fs",
            perteReelle * 100, vDebut, vFin, chute, fin.t - debut.t)
        end
      end
    end
  end

  ------------------------------------------------------------------- expiration
  if ecoule >= delaiEval then
    return noyau.RESULTATS_KILL.AUCUN_SIGNAL, string.format(
      "aucun des deux declencheurs apres %.1fs", ecoule)
  end
  return noyau.RESULTATS_KILL.EN_ATTENTE, string.format("evaluation en cours (%.1fs)", ecoule)
end

--------------------------------------------------------------------------------
-- 12. VALIDATION DES ZONES
--     Une zone mal definie qui passerait silencieusement serait pire qu'une
--     zone absente : elle donnerait l'illusion d'une couverture.
--------------------------------------------------------------------------------

function noyau.validerZone(zone)
  if type(zone) ~= "table" then return false, "la zone n'est pas une table" end
  if type(zone.nom) ~= "string" or zone.nom == "" then return false, "nom manquant" end
  if not noyau.SEVERITE[zone.classe] then
    return false, "classe invalide (attendu CHARLIE, BRAVO, ALPHA ou ROMEO)"
  end

  if zone.forme == "cercle" then
    if type(zone.centre) ~= "table" or not (nombreValide(zone.centre.x) and nombreValide(zone.centre.z)) then
      return false, "centre invalide"
    end
    if not nombreValide(zone.rayon) or zone.rayon <= 0 then return false, "rayon invalide" end
  elseif zone.forme == "rectangle" then
    if type(zone.points) ~= "table" or #zone.points ~= 4 then
      return false, "un rectangle exige exactement 4 points de coin"
    end
    for i, p in ipairs(zone.points) do
      if type(p) ~= "table" or not (nombreValide(p.x) and nombreValide(p.z)) then
        return false, "point de coin " .. i .. " invalide"
      end
    end
  else
    return false, "forme invalide (attendu 'rectangle' ou 'cercle')"
  end

  if nombreValide(zone.yMin) and nombreValide(zone.yMax) and zone.yMin > zone.yMax then
    return false, "yMin superieur a yMax"
  end
  return true
end

return noyau
