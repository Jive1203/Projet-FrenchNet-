--[[----------------------------------------------------------------------------
  FRENCHNET - ADAPTATEUR RADAR (Create Radars)
  --------------------------------------------------------------------------
  Couche d'adaptation entre le peripherique radar du mod et le format de
  contact utilise par tout FrenchNet. Ce fichier est installe A LA FOIS sur
  chaque STATION RADAR et sur le POSTE DE COMMANDEMENT (qui peut avoir un
  radar en propre) : une seule source de verite, pas deux implementations qui
  divergent au premier changement d'API.

  Les addons radar n'exposent pas tous les memes methodes ni le meme format de
  position. Plutot que de figer un nom, on essaie les noms connus dans l'ordre
  et on journalise celui qui repond. Si votre version expose autre chose,
  METHODES est le seul endroit a modifier - et la correction profite du meme
  coup aux stations et au poste central.

  Le module ne touche a aucune API globale : 'peripheral' lui est passe en
  parametre, ce qui le rend testable hors du jeu avec un faux peripherique.
--------------------------------------------------------------------------------]]

local scanner = { VERSION = "1.0.0" }

local function nombreValide(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

scanner.NATURES = {
  JOUEUR = "JOUEUR", VEHICULE = "VEHICULE", ENTITE = "ENTITE", MISSILE = "MISSILE",
}

--[[
  DETECTION DE PROJECTILE
  Un missile n'est pas un aeronef : il ne se scramble pas, il ne se verifie
  pas, et il arrive vite. Il doit sauter aux yeux du controleur des la
  premiere trame.

  Deux voies de detection, volontairement independantes :
    - par le TYPE rendu par le mod (missile, roquette, obus, projectile...) ;
    - par la CINEMATIQUE, quand le mod ne dit rien d'utile : un contact
      anonyme, sans nom de joueur ni de contraption, qui file au-dela d'une
      vitesse qu'aucun appareil pilote ne tient.
  La seconde voie est evaluee par le poste central, qui seul dispose de
  l'historique de piste ; le scanner ne fait que la premiere.
]]
scanner.MOTIFS_PROJECTILE = {
  "missile", "rocket", "projectile", "shell", "cannon_ball", "cannonball",
  "fireball", "torpedo", "warhead", "bomb",
}

--[[
  METHODES DE BALAYAGE CONNUES
  Nom de methode -> nature par defaut des contacts qu'elle rend.

  La liste est volontairement large. Un nom manquant ici n'est pas grave : la
  detection ci-dessous procede PAR METHODE et non par nom de peripherique,
  donc tout peripherique exposant l'une de ces fonctions est reconnu comme
  radar, quel que soit le nom de type que le mod lui donne.

  Si votre version de Create Radars expose une methode absente de cette liste,
  lancez 'diagnostic' sur la station : il affiche toutes les methodes reelles
  du peripherique. Ajoutez-la ici, et la correction profite du meme coup aux
  stations et au poste central, qui partagent ce fichier.
]]
scanner.METHODES = {
  -- Noms les plus courants
  { nom = "getEntities",         nature = scanner.NATURES.ENTITE },
  { nom = "getContraptions",     nature = scanner.NATURES.VEHICULE },
  { nom = "getPlayers",          nature = scanner.NATURES.JOUEUR },
  -- Variantes rencontrees selon les versions et les forks
  { nom = "getTargets",          nature = scanner.NATURES.ENTITE },
  { nom = "getRadarTargets",     nature = scanner.NATURES.ENTITE },
  { nom = "getRadarEntities",    nature = scanner.NATURES.ENTITE },
  { nom = "getEntitiesInRange",  nature = scanner.NATURES.ENTITE },
  { nom = "getTrackedEntities",  nature = scanner.NATURES.ENTITE },
  { nom = "getDetectedEntities", nature = scanner.NATURES.ENTITE },
  { nom = "getContacts",         nature = scanner.NATURES.ENTITE },
  { nom = "getBlips",            nature = scanner.NATURES.ENTITE },
  { nom = "listEntities",        nature = scanner.NATURES.ENTITE },
  { nom = "listContraptions",    nature = scanner.NATURES.VEHICULE },
  { nom = "getVehicles",         nature = scanner.NATURES.VEHICULE },
  { nom = "getShips",            nature = scanner.NATURES.VEHICULE },
  { nom = "getAircraft",         nature = scanner.NATURES.VEHICULE },
  { nom = "getAirships",         nature = scanner.NATURES.VEHICULE },
  { nom = "scan",                nature = scanner.NATURES.ENTITE },
  { nom = "scanEntities",        nature = scanner.NATURES.ENTITE },
  { nom = "getAll",              nature = scanner.NATURES.ENTITE },
}

-- Methodes a NE PAS confondre avec un balayage : presentes sur beaucoup de
-- peripheriques et sans rapport avec la detection.
scanner.METHODES_IGNOREES = {
  getMetadata = true, getDocs = true, getType = true, getNames = true,
}

--------------------------------------------------------------------------------
-- 1 bis. INVENTAIRE DES PERIPHERIQUES
--
--   Sert a deux choses : au diagnostic affiche a l'operateur, et au message
--   d'erreur quand aucun radar n'est trouve. Un message qui dit seulement
--   « aucun radar detecte » n'aide personne ; celui-ci dit ce QUI a ete vu.
--------------------------------------------------------------------------------

-- peripheral.getType rend PLUSIEURS valeurs quand un bloc porte plusieurs
-- types (par exemple "createradars:radar" et "peripheral"). N'en lire qu'une
-- fait manquer le bon type : on les collecte toutes.
function scanner.typesDe(peripheriques, nom)
  local types = table.pack(pcall(peripheriques.getType, nom))
  if not types[1] then return {} end
  local liste = {}
  for i = 2, types.n do
    if type(types[i]) == "string" then liste[#liste + 1] = types[i] end
  end
  return liste
end

function scanner.methodesDe(peripheriques, nom)
  -- getMethods est la voie propre ; a defaut on parcourt la table enveloppee.
  if type(peripheriques.getMethods) == "function" then
    local ok, liste = pcall(peripheriques.getMethods, nom)
    if ok and type(liste) == "table" then return liste end
  end
  local ok, enveloppe = pcall(peripheriques.wrap, nom)
  if not ok or type(enveloppe) ~= "table" then return {} end
  local liste = {}
  for cle, valeur in pairs(enveloppe) do
    if type(valeur) == "function" then liste[#liste + 1] = cle end
  end
  table.sort(liste)
  return liste
end

--[[
  Inventaire complet : pour chaque peripherique visible, son nom, ses types et
  ses methodes. C'est la seule facon honnete de repondre a « l'ordinateur ne
  trouve pas le radar » : montrer ce qu'il voit reellement.
]]
function scanner.inventaire(peripheriques)
  local liste = {}
  local ok, noms = pcall(peripheriques.getNames)
  if not ok or type(noms) ~= "table" then return liste end
  for _, nom in ipairs(noms) do
    liste[#liste + 1] = {
      nom = nom,
      types = scanner.typesDe(peripheriques, nom),
      methodes = scanner.methodesDe(peripheriques, nom),
    }
  end
  return liste
end

local function resumerInventaire(inventaire)
  if #inventaire == 0 then
    return "AUCUN peripherique visible. Le radar doit toucher l'ordinateur par " ..
           "une face, ou etre relie par un modem filaire (cable + modem colles aux deux blocs, " ..
           "modem active d'un clic droit)."
  end
  local morceaux = {}
  for _, p in ipairs(inventaire) do
    morceaux[#morceaux + 1] = string.format("%s [%s] (%d methode(s))",
      p.nom, table.concat(p.types, ", "), #p.methodes)
  end
  return "peripheriques visibles : " .. table.concat(morceaux, " ; ")
end
scanner.resumerInventaire = resumerInventaire

--------------------------------------------------------------------------------
-- 1 ter. DETECTION DU PERIPHERIQUE
--------------------------------------------------------------------------------

-- Methodes de balayage effectivement exposees par un peripherique donne.
local function methodesActivesPour(peripheriques, nom)
  local disponibles = {}
  for _, m in ipairs(scanner.methodesDe(peripheriques, nom)) do disponibles[m] = true end
  local actives = {}
  for _, methode in ipairs(scanner.METHODES) do
    if disponibles[methode.nom] then actives[#actives + 1] = methode end
  end
  return actives, disponibles
end

--[[
  Retourne : radar, nom, methodes actives, motif journalisable, inventaire.

  ORDRE DE RECHERCHE, du plus sur au plus large :
    1. le peripherique force en configuration, s'il expose une methode connue ;
    2. tout peripherique exposant une methode de balayage connue - c'est le
       critere principal : il ne depend d'aucun nom de type, donc il survit a
       un changement de nommage du mod ;
    3. a defaut, tout peripherique dont un type contient "radar", meme sans
       methode reconnue : on rend alors une erreur explicite qui NOMME ses
       methodes reelles, pour qu'elles soient ajoutees a scanner.METHODES.

  Chercher d'abord par methode et seulement ensuite par nom est deliberé :
  un radar qui repond est un radar, quel que soit son nom ; un bloc nommé
  "radar" qui ne repond a rien n'en est pas un.
]]
function scanner.detecter(peripheriques, nomForce)
  local inventaire = scanner.inventaire(peripheriques)

  -- 1. Peripherique force
  if nomForce then
    local ok, present = pcall(peripheriques.isPresent, nomForce)
    if ok and present then
      local actives = methodesActivesPour(peripheriques, nomForce)
      if #actives > 0 then
        return peripheriques.wrap(nomForce), nomForce, actives, string.format(
          "radar force '%s' accepte, %d methode(s) de balayage", nomForce, #actives), inventaire
      end
      local reelles = scanner.methodesDe(peripheriques, nomForce)
      return nil, nomForce, nil, string.format(
        "peripheriqueRadar force sur '%s', mais il n'expose aucune methode de balayage connue. " ..
        "Ses methodes reelles sont : %s. Ajoutez la bonne a scanner.METHODES.",
        nomForce, #reelles > 0 and table.concat(reelles, ", ") or "aucune"), inventaire
    end
    -- On ne s'arrete pas la : la detection automatique reste possible.
  end

  -- 2. Detection par METHODE (critere principal)
  for _, p in ipairs(inventaire) do
    local actives = methodesActivesPour(peripheriques, p.nom)
    if #actives > 0 then
      local noms = {}
      for _, m in ipairs(actives) do noms[#noms + 1] = m.nom end
      return peripheriques.wrap(p.nom), p.nom, actives, string.format(
        "radar detecte sur '%s' [%s] par ses methodes : %s",
        p.nom, table.concat(p.types, ", "), table.concat(noms, ", ")), inventaire
    end
  end

  -- 3. Un bloc se dit radar mais ne repond a aucune methode connue
  for _, p in ipairs(inventaire) do
    for _, typ in ipairs(p.types) do
      if typ:lower():find("radar", 1, true) then
        return nil, p.nom, nil, string.format(
          "peripherique '%s' de type '%s' trouve, mais AUCUNE de ses methodes n'est reconnue. " ..
          "Methodes reelles : %s. Ajoutez la bonne a scanner.METHODES (voir 'diagnostic').",
          p.nom, typ,
          #p.methodes > 0 and table.concat(p.methodes, ", ") or "aucune"), inventaire
      end
    end
  end

  -- 4. Rien du tout : on dit ce qu'on voit.
  return nil, nil, nil,
    "aucun peripherique radar detecte. " .. resumerInventaire(inventaire), inventaire
end

--------------------------------------------------------------------------------
-- 2. LECTURE D'UN ECHO
--------------------------------------------------------------------------------

function scanner.positionEcho(echo)
  if nombreValide(echo.x) and nombreValide(echo.y) and nombreValide(echo.z) then
    return echo.x, echo.y, echo.z
  end
  local p = echo.position or echo.pos or echo.coords
  if type(p) == "table" then
    local x = p.x or p[1]
    local y = p.y or p[2]
    local z = p.z or p[3]
    if nombreValide(x) and nombreValide(y) and nombreValide(z) then return x, y, z end
  end
  return nil
end

function scanner.natureEcho(echo, natureParDefaut)
  local typ = tostring(echo.type or echo.entityType or echo.kind or ""):lower()
  local nom = tostring(echo.name or echo.nom or echo.label or ""):lower()

  -- Le projectile passe avant tout le reste : un obus mal classe en "entite
  -- neutre" serait purement et simplement ignore par le filtre a vaches.
  if echo.isProjectile == true then return scanner.NATURES.MISSILE end
  for _, motif in ipairs(scanner.MOTIFS_PROJECTILE) do
    if typ:find(motif, 1, true) or nom:find(motif, 1, true) then
      return scanner.NATURES.MISSILE
    end
  end

  if echo.isPlayer == true or typ:find("player", 1, true) then
    return scanner.NATURES.JOUEUR
  end
  if echo.isContraption == true or typ:find("contraption", 1, true)
     or typ:find("ship", 1, true) or typ:find("vehicle", 1, true) then
    return scanner.NATURES.VEHICULE
  end
  return natureParDefaut
end

function scanner.identifiantEcho(echo)
  local id = echo.id or echo.uuid or echo.uid or echo.entityId
  if id ~= nil then return "ID:" .. tostring(id) end
  local nom = echo.name or echo.nom or echo.label or echo.displayName
  if type(nom) == "string" and nom ~= "" then return "NOM:" .. nom end
  return nil
end

function scanner.nomEcho(echo, repli)
  return echo.name or echo.nom or echo.label or echo.displayName or repli
end

--[[
  IDENTIFICATION FOURNIE PAR LE RADAR
  Create Radars ne rend pas que des coordonnees. Selon les contraptions et les
  versions, un echo peut porter le PROPRIETAIRE de l'engin, son EQUIPE, son
  type exact. Ces champs constituent une voie d'identification a part entiere,
  independante du transpondeur - et c'est precisement leur interet : deux
  sources qui ne peuvent pas mentir de la meme facon.

  Un transpondeur se capture avec l'appareil qui le porte ; le proprietaire
  d'une contraption, non. Recouper les deux permet de reperer un code allie
  porte par un engin qui n'a rien d'allie.

  Tous ces champs sont facultatifs : leur absence ne degrade rien, elle prive
  seulement le systeme de sa seconde voie.
]]
function scanner.metaEcho(echo)
  local meta = {}
  meta.proprietaire = echo.owner or echo.ownerName or echo.player or echo.pilot
                   or echo.proprietaire
  meta.equipe       = echo.team or echo.faction or echo.clan or echo.equipe
                   or echo.group
  meta.typeExact    = echo.type or echo.entityType or echo.kind
  if type(echo.health) == "number" then meta.sante = echo.health end
  if type(echo.size) == "number" then meta.taille = echo.size
  elseif type(echo.mass) == "number" then meta.taille = echo.mass
  elseif type(echo.blocks) == "number" then meta.taille = echo.blocks end

  -- Rien d'exploitable : on rend nil plutot qu'une table vide, pour que le
  -- reste du systeme sache qu'il n'a qu'une seule voie d'identification.
  for _ in pairs(meta) do return meta end
  return nil
end

--------------------------------------------------------------------------------
-- 3. BALAYAGE
--------------------------------------------------------------------------------

--[[
  Interroge toutes les methodes actives. 'proteger' est la fonction d'execution
  protegee de l'appelant : elle doit rendre (succes, resultat) et journaliser
  elle-meme les erreurs, pour que chaque programme garde SA nomenclature
  d'etapes.
]]
function scanner.collecter(radar, methodesActives, proteger)
  local bruts = {}
  for _, methode in ipairs(methodesActives or {}) do
    local ok, resultat = proteger(function() return radar[methode.nom](radar) end)
    if ok and type(resultat) == "table" then
      for _, echo in ipairs(resultat) do
        if type(echo) == "table" then
          bruts[#bruts + 1] = { echo = echo, nature = methode.nature }
        end
      end
    end
  end
  return bruts
end

--------------------------------------------------------------------------------
-- 4. REFERENTIEL
--    Certains radars rendent des coordonnees relatives a leur propre bloc,
--    d'autres des coordonnees absolues du monde. Se tromper decale toutes les
--    pistes de plusieurs milliers de blocs, donc la deduction est journalisee
--    en clair et peut etre forcee en configuration.
--------------------------------------------------------------------------------

function scanner.deduireReferentiel(bruts, positionRadar, portee)
  portee = (nombreValide(portee) and portee > 0) and portee or 512
  local r = positionRadar
  local distanceOrigine = math.sqrt(r.x * r.x + r.y * r.y + r.z * r.z)

  if distanceOrigine <= portee * 1.5 then
    return false, "radar trop proche de l'origine du monde pour distinguer relatif et absolu : "
      .. "referentiel ABSOLU suppose. Renseignez positionsRelatives en configuration."
  end

  local prochesOrigine, prochesRadar = 0, 0
  for _, brut in ipairs(bruts) do
    local x, y, z = scanner.positionEcho(brut.echo)
    if x then
      if math.sqrt(x * x + y * y + z * z) <= portee * 1.5 then
        prochesOrigine = prochesOrigine + 1
      end
      local dx, dy, dz = x - r.x, y - r.y, z - r.z
      if math.sqrt(dx * dx + dy * dy + dz * dz) <= portee * 1.5 then
        prochesRadar = prochesRadar + 1
      end
    end
  end

  local relatif = prochesOrigine > prochesRadar
  return relatif, string.format(
    "referentiel radar deduit : %s (%d echo(s) proche(s) de l'origine, %d du radar)",
    relatif and "RELATIF" or "ABSOLU", prochesOrigine, prochesRadar)
end

--------------------------------------------------------------------------------
-- 5. NORMALISATION
--    Transforme les echos bruts en contacts FrenchNet, en coordonnees absolues.
--    C'est ce format, et lui seul, qui circule sur le reseau.
--------------------------------------------------------------------------------

function scanner.normaliser(bruts, positionRadar, relatives)
  local contacts, ignores = {}, 0
  for _, brut in ipairs(bruts) do
    local x, y, z = scanner.positionEcho(brut.echo)
    if not x then
      ignores = ignores + 1
    else
      if relatives then
        x, y, z = positionRadar.x + x, positionRadar.y + y, positionRadar.z + z
      end
      contacts[#contacts + 1] = {
        id     = scanner.identifiantEcho(brut.echo),
        nom    = scanner.nomEcho(brut.echo, nil),
        nature = scanner.natureEcho(brut.echo, brut.nature),
        meta   = scanner.metaEcho(brut.echo),
        x = x, y = y, z = z,
      }
    end
  end
  return contacts, ignores
end

return scanner
