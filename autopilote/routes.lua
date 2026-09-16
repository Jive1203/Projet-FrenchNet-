--[[----------------------------------------------------------------------------
  ITINERAIRES - AUTOPILOTE FRENCHNET
  --------------------------------------------------------------------------
  Bibliotheque de gestion des itineraires : des routes nommees, composees de
  plusieurs points de passage, enregistrees sur l'ordinateur du vehicule et
  rejouables a volonte.

  Le fichier d'itineraires est un fichier Lua ordinaire, lisible et editable a
  la main comme le reste de FrenchNet :

      return {
        routes = {
          { nom = "LIVRAISON-NORD", altitudeCroisiere = 350, points = {
              { x = 480,  z = -1200, nom = "SORTIE-HANGAR" },
              { x = 1980, y = 118, z = -3100, nom = "ENTREPOT", type = "depot" },
          }},
        },
      }

  RAPPEL sur l'altitude : elle est FACULTATIVE. Un point sans altitude est
  survole a l'altitude de croisiere. Seul un point qui en precise une donne
  lieu a une descente verticale.
--------------------------------------------------------------------------------]]

local routes = {}
routes.VERSION = "1.0.0"

local CHEMIN_DEFAUT = "/autopilote/itineraires.lua"
local TYPES = { "survol", "depot", "atterrissage", "amarrage" }
routes.TYPES = TYPES

local function nombreValide(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--------------------------------------------------------------------------------
-- LECTURE ET ECRITURE
--------------------------------------------------------------------------------

--- @return liste de routes (vide si le fichier n'existe pas), motif d'erreur
function routes.charger(chemin)
  chemin = chemin or CHEMIN_DEFAUT
  if not fs.exists(chemin) then return {}, nil end

  local fichier = fs.open(chemin, "r")
  if not fichier then return {}, "lecture impossible : " .. chemin end
  local source = fichier.readAll()
  fichier.close()

  local morceau, err = load(source, "@" .. chemin, "t", _G)
  if not morceau then return {}, "fichier illisible : " .. tostring(err) end
  local ok, contenu = pcall(morceau)
  if not ok or type(contenu) ~= "table" then
    return {}, "le fichier doit se terminer par 'return { routes = { ... } }'"
  end

  local liste = contenu.routes or contenu
  if type(liste) ~= "table" then return {}, "aucune liste 'routes' trouvee" end

  -- On normalise a la lecture : un fichier edite a la main ne doit pas
  -- pouvoir faire planter l'interface.
  local propres = {}
  for _, route in ipairs(liste) do
    if type(route) == "table" then
      propres[#propres + 1] = {
        nom = tostring(route.nom or "SANS NOM"),
        altitudeCroisiere = nombreValide(route.altitudeCroisiere)
          and route.altitudeCroisiere or nil,
        vitesseMax = nombreValide(route.vitesseMax) and route.vitesseMax or nil,
        points = routes.normaliserPoints(route.points),
      }
    end
  end
  return propres, nil
end

function routes.normaliserPoints(points)
  local propres = {}
  for _, point in ipairs(type(points) == "table" and points or {}) do
    if type(point) == "table" and nombreValide(point.x) and nombreValide(point.z) then
      propres[#propres + 1] = {
        x = point.x,
        z = point.z,
        y = nombreValide(point.y) and point.y or nil,
        type = point.type or "survol",
        cap = nombreValide(point.cap) and point.cap or nil,
        arret = point.arret and true or false,
        nom = point.nom and tostring(point.nom) or nil,
      }
    end
  end
  return propres
end

local function formaterNombre(valeur)
  if valeur == math.floor(valeur) and math.abs(valeur) < 1e15 then
    return string.format("%d", valeur)
  end
  local texte = string.format("%.3f", valeur):gsub("0+$", ""):gsub("%.$", "")
  if tonumber(texte) ~= valeur then texte = string.format("%.14g", valeur) end
  return texte
end

local function serialiserPoint(point)
  local morceaux = {}
  morceaux[#morceaux + 1] = "x = " .. formaterNombre(point.x)
  if nombreValide(point.y) then
    morceaux[#morceaux + 1] = "y = " .. formaterNombre(point.y)
  end
  morceaux[#morceaux + 1] = "z = " .. formaterNombre(point.z)
  if point.type and point.type ~= "survol" then
    morceaux[#morceaux + 1] = string.format("type = %q", point.type)
  end
  if nombreValide(point.cap) then
    morceaux[#morceaux + 1] = "cap = " .. formaterNombre(point.cap)
  end
  if point.arret then morceaux[#morceaux + 1] = "arret = true" end
  if point.nom and point.nom ~= "" then
    morceaux[#morceaux + 1] = string.format("nom = %q", point.nom)
  end
  return "{ " .. table.concat(morceaux, ", ") .. " }"
end

--- @return true | false, motif
function routes.enregistrer(liste, chemin)
  chemin = chemin or CHEMIN_DEFAUT
  local lignes = {
    "--[[--------------------------------------------------------------------------",
    "  ITINERAIRES - AUTOPILOTE FRENCHNET",
    "  ------------------------------------------------------------------------",
    "  Fichier genere par la console de navigation (autopilote/console.lua).",
    "  Editable a la main : il suffit qu'il se termine par 'return { ... }'.",
    "",
    "  L'altitude d'un point est FACULTATIVE. Sans altitude, le point est",
    "  survole a l'altitude de croisiere. Avec altitude, le vehicule s'y rend",
    "  a l'aplomb puis descend VERTICALEMENT.",
    "----------------------------------------------------------------------------]]",
    "",
    "return {",
    "  routes = {",
  }

  for _, route in ipairs(liste) do
    lignes[#lignes + 1] = string.format("    { nom = %q,", route.nom or "SANS NOM")
    if nombreValide(route.altitudeCroisiere) then
      lignes[#lignes + 1] = "      altitudeCroisiere = "
        .. formaterNombre(route.altitudeCroisiere) .. ","
    end
    if nombreValide(route.vitesseMax) then
      lignes[#lignes + 1] = "      vitesseMax = " .. formaterNombre(route.vitesseMax) .. ","
    end
    lignes[#lignes + 1] = "      points = {"
    for _, point in ipairs(route.points or {}) do
      lignes[#lignes + 1] = "        " .. serialiserPoint(point) .. ","
    end
    lignes[#lignes + 1] = "      },"
    lignes[#lignes + 1] = "    },"
  end

  lignes[#lignes + 1] = "  },"
  lignes[#lignes + 1] = "}"
  lignes[#lignes + 1] = ""

  local fichier = fs.open(chemin, "w")
  if not fichier then return false, "ecriture impossible : " .. chemin end
  fichier.write(table.concat(lignes, "\n"))
  fichier.close()
  return true
end

--------------------------------------------------------------------------------
-- OUTILS
--------------------------------------------------------------------------------

function routes.nouvelle(nom)
  return { nom = nom or "NOUVELLE ROUTE", points = {} }
end

--- Longueur horizontale d'une route, depuis une position de depart facultative.
function routes.longueur(route, depuis)
  local total, precedent = 0, depuis
  for _, point in ipairs(route.points or {}) do
    if precedent then
      local dx, dz = point.x - precedent.x, point.z - precedent.z
      total = total + math.sqrt(dx * dx + dz * dz)
    end
    precedent = point
  end
  return total
end

--- Controle de coherence avant lancement.
-- @return true | false, liste d'anomalies
function routes.valider(route, config)
  local anomalies = {}
  if type(route) ~= "table" then return false, { "itineraire absent" } end
  if not route.points or #route.points == 0 then
    anomalies[#anomalies + 1] = "aucun point de passage"
  end

  for index, point in ipairs(route.points or {}) do
    local etiquette = string.format("point %d%s", index,
      point.nom and (" (" .. tostring(point.nom) .. ")") or "")
    -- On valide aussi bien une route normalisee qu'une table ecrite a la main.
    local typePoint = point.type or "survol"

    if not (nombreValide(point.x) and nombreValide(point.z)) then
      anomalies[#anomalies + 1] = etiquette .. " : X ou Z manquant"
    end
    local typeConnu = false
    for _, t in ipairs(TYPES) do if t == typePoint then typeConnu = true end end
    if not typeConnu then
      anomalies[#anomalies + 1] = etiquette .. " : type inconnu '" .. tostring(typePoint) .. "'"
    end
    -- Un point de pose sans altitude n'a aucun sens : il serait survole.
    if typePoint ~= "survol" and not nombreValide(point.y) then
      anomalies[#anomalies + 1] = etiquette .. " : un point de type '" .. tostring(typePoint)
        .. "' exige une altitude, sinon il est simplement survole"
    end
  end

  local dernier = route.points and route.points[#route.points]
  if dernier and not nombreValide(dernier.y) then
    anomalies[#anomalies + 1] = "le point final n'a pas d'altitude : le vehicule "
      .. "restera en croisiere au-dessus, sans descendre"
  end

  local altitude = route.altitudeCroisiere
    or (config and config.vitesses and config.vitesses.altitudeCroisiere)
  if nombreValide(altitude) then
    for index, point in ipairs(route.points or {}) do
      if nombreValide(point.y) and point.y > altitude then
        anomalies[#anomalies + 1] = string.format(
          "point %d : altitude %.0f au-dessus de la croisiere %.0f, le vehicule "
          .. "montera au lieu de descendre", index, point.y, altitude)
      end
    end
  end

  return #anomalies == 0, anomalies
end

--- Convertit une route en itineraire pour ap.suivreItineraire.
-- @return points, options
function routes.versMission(route, rappels)
  local points = {}
  for index, point in ipairs(route.points or {}) do
    points[index] = {
      x = point.x, y = point.y, z = point.z,
      type = point.type, cap = point.cap, arret = point.arret, nom = point.nom,
    }
  end
  local options = {
    altitudeCroisiere = route.altitudeCroisiere,
    vitesseMax = route.vitesseMax,
    surEtape = rappels and rappels.surEtape or nil,
    surArrivee = rappels and rappels.surArrivee or nil,
  }
  return points, options
end

function routes.trouver(liste, nom)
  for index, route in ipairs(liste) do
    if route.nom == nom then return route, index end
  end
  return nil
end

routes.CHEMIN_DEFAUT = CHEMIN_DEFAUT

return routes
