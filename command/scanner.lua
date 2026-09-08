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

-- Nom de methode -> nature par defaut des contacts qu'elle rend.
scanner.METHODES = {
  { nom = "getEntities",     nature = scanner.NATURES.ENTITE },
  { nom = "getContraptions", nature = scanner.NATURES.VEHICULE },
  { nom = "getPlayers",      nature = scanner.NATURES.JOUEUR },
  { nom = "getTargets",      nature = scanner.NATURES.ENTITE },
  { nom = "getRadarTargets", nature = scanner.NATURES.ENTITE },
  { nom = "scan",            nature = scanner.NATURES.ENTITE },
}

--------------------------------------------------------------------------------
-- 1. DETECTION DU PERIPHERIQUE
--------------------------------------------------------------------------------

--[[
  Retourne : radar, nom, methodes actives, motif
  radar = nil signifie echec ; le motif est directement journalisable.
]]
function scanner.detecter(peripheriques, nomForce)
  local radar, nom

  if nomForce and peripheriques.isPresent(nomForce) then
    radar, nom = peripheriques.wrap(nomForce), nomForce
  else
    for _, candidat in ipairs(peripheriques.getNames()) do
      local typ = peripheriques.getType(candidat)
      if type(typ) == "string" and typ:lower():find("radar", 1, true) then
        radar, nom = peripheriques.wrap(candidat), candidat
        break
      end
    end
  end

  if not radar then
    return nil, nil, nil, "aucun peripherique radar detecte"
  end

  local actives = {}
  for _, methode in ipairs(scanner.METHODES) do
    if type(radar[methode.nom]) == "function" then actives[#actives + 1] = methode end
  end

  if #actives == 0 then
    local essayees = {}
    for _, m in ipairs(scanner.METHODES) do essayees[#essayees + 1] = m.nom end
    return nil, nom, nil, string.format(
      "radar '%s' detecte mais aucune methode connue (essayees : %s). Completez scanner.METHODES.",
      nom, table.concat(essayees, ", "))
  end

  local noms = {}
  for _, m in ipairs(actives) do noms[#noms + 1] = m.nom end
  return radar, nom, actives, string.format("radar '%s' detecte, methodes : %s",
    nom, table.concat(noms, ", "))
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
        x = x, y = y, z = z,
      }
    end
  end
  return contacts, ignores
end

return scanner
