--[[----------------------------------------------------------------------------
  FRENCHNET / LIVRAISON - ADAPTATEUR vers le module d'autopilote standardise
  --------------------------------------------------------------------------
  CE FICHIER NE PILOTE PAS LE NAVIRE. Il ne contient ni asservissement
  d'altitude, ni asservissement de cap, ni boucle PID, ni commande de moteur,
  ni calcul de decalage de depot. Tout cela appartient au module d'autopilote
  FrenchNet deja construit (/autopilote/autopilote.lua), qui est une
  BIBLIOTHEQUE : il ne decide de rien, ce sont les programmes de mission comme
  celui-ci qui lui donnent une cible.

  API REELLE UTILISEE (voir autopilote/exemple_mission.lua) :

      local ap = autopilote.nouveau()      -- lit config_vehicule.lua
      ap.initialiser()                     -- relit la position avant tout
      ap.allerA(point, options)            -- rejoindre un point
      ap.suivreItineraire(points, options) -- enchainer des points
      ap.maintenirPosition(point, cap)     -- tenir la position
      ap.arreter(motif)                    -- neutraliser les commandes
      ap.etat()                            -- instantane complet
      ap.attendreArrivee(delai)            -- bloquant, dans une tache
      ap.rejoindreRavitaillement()         -- station verrouillee du reseau
      ap.executer()                        -- LA BOUCLE DE VOL

      parallel.waitForAny(ap.executer, mission)

  Deux consequences importantes pour le systeme de livraison :

  1. ap.executer() DOIT tourner en parallele de la mission. Sans lui, aucun
     ordre n'est execute et attendreArrivee ne rend jamais la main. Le
     programme de livraison le lance donc dans son parallel.waitForAny.

  2. Le DECALAGE DE DEPOT est applique par l'autopilote lui-meme, et tourne
     selon le cap courant. On lui transmet donc les coordonnees BRUTES
     demandees par le client, avec type = "depot" : c'est lui qui calcule ou
     doit se placer le centre du navire. Recalculer ce decalage ici serait
     precisement la reimplementation qu'il faut eviter.

  Point de passage accepte par l'autopilote :
      { x = , y = , z = , type = "survol" | "depot" | "atterrissage" | "amarrage",
        cap = degres, arret = true, nom = "..." }
--------------------------------------------------------------------------------]]

local M = {}

M.ETAPES = {
  CONNEXION    = "connexion au module d'autopilote",
  INITIALISATION = "initialisation de l'autopilote",
  ORDRE        = "envoi d'un ordre de vol a l'autopilote",
  SURVEILLANCE = "surveillance des messages d'etat de l'autopilote",
  STATIONNER   = "mise en stationnaire",
  RAVITAILLEMENT = "rejoint la station de ravitaillement",
}

M.CHEMIN_DEFAUT = "/autopilote/autopilote.lua"

--------------------------------------------------------------------------------
-- M.connecter(reglages, journal, charger)
--   reglages = {
--     chemin        = "/autopilote/autopilote.lua",
--     cheminConfig  = "/autopilote/config_vehicule.lua",  -- nil = defaut du module
--     nomGlobal     = nil,     -- table globale deja chargee, si startup l'expose
--   }
-- Retourne toujours une instance ; consulter instance.disponible.
--------------------------------------------------------------------------------
function M.connecter(reglages, journal, charger)
  reglages = reglages or {}

  local pilote = {
    disponible  = false,
    ap          = nil,
    motif       = nil,
    dernierEtat = { phase = "INCONNU" },
    evenements  = 0,
  }

  local function log(niveau, etape, message, ...)
    if journal and journal[niveau] then journal[niveau](etape, message, ...) end
  end

  ---------------------------------------------------------------- repli sur --
  -- Instance DEGRADEE : toutes les methodes existent et refusent poliment.
  -- Le programme de livraison peut ainsi tourner, servir les commandes et
  -- les garder en file sans jamais planter sur un appel a nil.
  local function refus()
    return false, pilote.motif or "autopilote indisponible"
  end
  pilote.executer    = function() error(pilote.motif or "autopilote indisponible", 0) end
  pilote.initialiser = refus
  pilote.allerA      = refus
  pilote.attendreArrivee = refus
  pilote.maintenirPosition = refus
  pilote.arreter     = refus
  pilote.rejoindreRavitaillement = refus
  pilote.etat        = function() return pilote.dernierEtat end
  pilote.position    = function()
    -- Sans autopilote, il reste le GPS brut : le decalage n'est pas corrige,
    -- mais cela suffit a dire ou se trouve le navire dans le journal.
    if not gps or type(gps.locate) ~= "function" then
      return nil, pilote.motif or "autopilote indisponible"
    end
    local ok, x, y, z = pcall(gps.locate, 5)
    if ok and type(x) == "number" then return { x = x, y = y, z = z } end
    return nil, "position GPS indisponible"
  end

  ------------------------------------------------------------------ recherche --
  local module
  if reglages.nomGlobal and type(_G[reglages.nomGlobal]) == "table" then
    module = _G[reglages.nomGlobal]
    log("info", M.ETAPES.CONNEXION, "module d'autopilote pris dans la globale '%s'",
      reglages.nomGlobal)
  end

  local chemin = reglages.chemin or M.CHEMIN_DEFAUT
  if not module and fs.exists(chemin) then
    local ok, resultat = pcall(charger, chemin)
    if ok and type(resultat) == "table" then
      module = resultat
      log("info", M.ETAPES.CONNEXION, "module d'autopilote charge depuis '%s'", chemin)
    else
      log("erreur", M.ETAPES.CONNEXION, "chargement de '%s' impossible : %s",
        chemin, tostring(resultat))
    end
  end

  if not module then
    pilote.motif = ("module d'autopilote introuvable (%s)"):format(chemin)
    log("critique", M.ETAPES.CONNEXION, "%s", pilote.motif)
    return pilote
  end

  if type(module.nouveau) ~= "function" then
    pilote.motif = "le module charge n'expose pas autopilote.nouveau()"
    log("critique", M.ETAPES.CONNEXION, "%s", pilote.motif)
    return pilote
  end

  --------------------------------------------------------------- instanciation --
  -- nouveau() lit lui-meme config_vehicule.lua, valide la configuration et
  -- verrouille la position de ravitaillement depuis le fichier reseau.
  local options = {}
  if reglages.cheminConfig then options.config = reglages.cheminConfig end

  local ok, ap = pcall(module.nouveau, options)
  if not ok or type(ap) ~= "table" then
    pilote.motif = ("autopilote.nouveau() a echoue : %s"):format(tostring(ap))
    log("critique", M.ETAPES.CONNEXION, "%s", pilote.motif)
    return pilote
  end

  for _, requise in ipairs({ "allerA", "attendreArrivee", "etat", "executer" }) do
    if type(ap[requise]) ~= "function" then
      pilote.motif = ("l'instance d'autopilote n'expose pas %s()"):format(requise)
      log("critique", M.ETAPES.CONNEXION, "%s", pilote.motif)
      return pilote
    end
  end

  pilote.ap = ap
  pilote.disponible = true
  pilote.config = ap.config
  log("info", M.ETAPES.CONNEXION,
    "autopilote v%s raccorde -- vehicule '%s' (%s)",
    tostring(ap.VERSION), tostring(ap.config and ap.config.nom),
    tostring(ap.config and ap.config.identifiant))

  ------------------------------------------------------ ecoute des evenements --
  -- L'autopilote emet "etape", "arrivee" et "anomalie". On les recopie dans le
  -- journal de livraison : une anomalie de vol doit se lire au meme endroit
  -- que les incidents de cargaison.
  if type(ap.surEvenement) == "function" then
    pcall(ap.surEvenement, function(typeEvenement, donnees)
      pilote.evenements = pilote.evenements + 1
      donnees = donnees or {}
      if typeEvenement == "etape" then
        log("info", M.ETAPES.SURVEILLANCE, "autopilote : etape %s/%s franchie (%s)",
          tostring(donnees.index), tostring(donnees.total),
          tostring(donnees.point and donnees.point.nom or "sans nom"))
      elseif typeEvenement == "arrivee" then
        pilote.dernierEtat = { phase = "ARRIVE" }
        log("info", M.ETAPES.SURVEILLANCE, "autopilote : arrive a destination (ecart %.2f bloc)",
          tonumber(donnees.ecart) or 0)
      elseif typeEvenement == "anomalie" then
        log("avert", M.ETAPES.SURVEILLANCE, "autopilote : ANOMALIE -- %s",
          tostring(donnees.motif))
      elseif typeEvenement == "mission" then
        log("debug", M.ETAPES.SURVEILLANCE, "autopilote : mission acceptee (%s point(s))",
          tostring(donnees.itineraire and #donnees.itineraire or 0))
      end
    end)
  end

  --------------------------------------------------------------- boucle de vol --
  -- A passer TELLE QUELLE a parallel.waitForAny : c'est elle qui vole.
  function pilote.executer()
    log("info", M.ETAPES.INITIALISATION, "demarrage de la boucle de vol de l'autopilote")
    return ap.executer()
  end

  function pilote.initialiser()
    if type(ap.initialiser) ~= "function" then return true end
    local okInit, err = pcall(ap.initialiser)
    if not okInit then
      log("erreur", M.ETAPES.INITIALISATION, "initialisation refusee : %s", tostring(err))
      return false, err
    end
    return true
  end

  ------------------------------------------------------------------- position --
  -- L'autopilote connait deja le centre du navire : inutile de refaire la
  -- correction de decalage GPS ici.
  function pilote.etat()
    local okEtat, instantane = pcall(ap.etat)
    if okEtat and type(instantane) == "table" then
      pilote.dernierEtat = instantane
      return instantane
    end
    return pilote.dernierEtat
  end

  function pilote.position()
    local instantane = pilote.etat()
    if instantane and instantane.position then return instantane.position end
    -- Pas encore de lecture valide : on force une acquisition.
    pilote.initialiser()
    instantane = pilote.etat()
    if instantane and instantane.position then return instantane.position end
    return nil, "position indisponible (constellation GPS hors de portee ?)"
  end

  ---------------------------------------------------------------------- ordre --
  -- 'point' est le point DEMANDE (coordonnees du client). 'type' vaut
  -- "depot", "atterrissage" ou "survol" : l'autopilote applique lui-meme le
  -- decalage correspondant, tourne selon le cap courant.
  function pilote.allerA(point, typePoint, options)
    if not pilote.disponible then
      return false, pilote.motif or "autopilote indisponible"
    end
    local cible = {
      x = point.x, y = point.y, z = point.z,
      type = typePoint or "survol",
      nom  = point.nom,
      cap  = point.cap,
      arret = point.arret,
    }
    log("info", M.ETAPES.ORDRE, "ordre de vol : %s %d %d %d (%s)",
      cible.type, math.floor(cible.x), math.floor(cible.y), math.floor(cible.z),
      (options and options.raison) or cible.nom or "sans motif")

    local okOrdre, err = pcall(ap.allerA, cible, options)
    if not okOrdre then
      log("erreur", M.ETAPES.ORDRE, "ordre refuse par l'autopilote : %s", tostring(err))
      return false, err
    end
    return true
  end

  -- Bloquant : exige que pilote.executer() tourne dans une autre tache.
  function pilote.attendreArrivee(delai)
    local okAttente, arrive, motif = pcall(ap.attendreArrivee, delai)
    if not okAttente then
      log("erreur", M.ETAPES.SURVEILLANCE, "attente d'arrivee interrompue : %s",
        tostring(arrive))
      return false, tostring(arrive)
    end
    if not arrive then
      log("erreur", M.ETAPES.SURVEILLANCE, "arrivee non confirmee : %s",
        tostring(motif or "motif inconnu"))
      return false, motif or "arrivee non confirmee"
    end
    return true
  end

  function pilote.maintenirPosition(point, cap)
    if type(ap.maintenirPosition) ~= "function" then return false, "fonction absente" end
    local okMaintien, err = pcall(ap.maintenirPosition, point, cap)
    if not okMaintien then
      log("avert", M.ETAPES.STATIONNER, "maintien de position refuse : %s", tostring(err))
      return false, err
    end
    log("info", M.ETAPES.STATIONNER, "navire en maintien de position")
    return true
  end

  function pilote.arreter(motif)
    if type(ap.arreter) ~= "function" then return false end
    return pcall(ap.arreter, motif)
  end

  function pilote.rejoindreRavitaillement(options)
    if type(ap.rejoindreRavitaillement) ~= "function" then
      return false, "l'autopilote n'expose pas rejoindreRavitaillement()"
    end
    log("info", M.ETAPES.RAVITAILLEMENT, "ralliement de la station de ravitaillement")
    local okRavi, err = pcall(ap.rejoindreRavitaillement, options)
    if not okRavi then
      log("avert", M.ETAPES.RAVITAILLEMENT, "ralliement refuse : %s", tostring(err))
      return false, err
    end
    return true
  end

  return pilote
end

return M
