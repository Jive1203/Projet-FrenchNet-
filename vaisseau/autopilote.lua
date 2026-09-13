--[[----------------------------------------------------------------------------
  ADAPTATEUR D'AUTOPILOTE - DOOMSDAY SHIP
  --------------------------------------------------------------------------
  CE MODULE NE CONTIENT AUCUNE LOI DE PILOTAGE.

  Il remplit la case que la couture d'integration (vaisseau/liaisons.lua)
  reservait a un autopilote et qui etait vide : la page NAVIGATION construisait
  des routes que personne ne volait, la page PORTANCE proposait un largage de
  ballast que personne n'executait. Les deux affichaient honnetement leur
  refus -- c'etait le bon comportement, faute de mieux. Voici le mieux.

  Tout le pilotage vient du module standard /autopilote/autopilote.lua :
  asservissement en cascade, PID en controle principal, repli en zone morte,
  enveloppe de securite au ras du sol. Ce fichier ne fait que traduire.

  CE QU'IL TRADUIT
  ----------------
      definirRoute(waypoints)  ->  ap.suivreItineraire()
      engager() / desengager() ->  initialisation et arret du pilotage
      etat()                   ->  etat de vol, resume pour les pages
      largerBallast()          ->  impulsion redstone declaree en configuration
      pas(dt)                  ->  un cycle d'asservissement, appele par la
                                   boucle du systeme embarque

  LE CABLAGE N'EST PAS DECLARE ICI
  --------------------------------
  Le ballon se dirige par courants de redstone, comme tous les vaisseaux du
  serveur, et l'autopilote ne sait pas d'avance quelle face commande quoi. Ce
  n'est pas a cet adaptateur de le deviner : le programme 'calibrer' essaie les
  faces une par une et ecrit le resultat dans /autopilote/config_vehicule.lua.
  Si aucun axe n'y est cable, engager() REFUSE et dit pourquoi, plutot que
  d'accepter une route que le ballon ne suivra jamais.

  LE BALLAST N'EST PAS UN ORGANE D'AUTOPILOTE
  -------------------------------------------
  Aucune notion de ballast n'existe dans le module standard : c'est un
  mecanisme propre a ce ballon. Il se declare donc dans la configuration du
  vaisseau, section 'ballast', et se commande par une impulsion redstone. Non
  declare, le largage est refuse avec son motif -- un equipage qui croit avoir
  largue continue de descendre en pensant remonter.
--------------------------------------------------------------------------------]]

local adaptateur = { VERSION = "1.0.0" }

local CHEMIN_MODULE = "/autopilote/autopilote.lua"
local CHEMIN_CONFIG_VAISSEAU = "/vaisseau/config_vaisseau.lua"

--------------------------------------------------------------------------------
-- 1. ETAT INTERNE
--------------------------------------------------------------------------------

local module          -- le module d'autopilote standard, charge une fois
local ap              -- l'instance de vol
local motifIndispo    -- pourquoi l'autopilote n'est pas utilisable
local engage = false
local route = {}
local dernierPas = 0
local largages = 0
local journalRappel   -- fonction de journalisation fournie par le ballon

adaptateur.periode = 0.25   -- periode d'asservissement souhaitee, en secondes

local function journaliser(niveau, message)
  if type(journalRappel) == "function" then
    pcall(journalRappel, niveau, "autopilote", message)
  end
end

--- Le ballon peut fournir sa propre fonction de journal : les refus de
-- l'autopilote apparaissent alors dans le journal de bord, la ou l'equipage
-- les cherchera, et pas seulement dans celui de l'autopilote.
function adaptateur.journaliserAvec(rappel)
  journalRappel = rappel
end

--------------------------------------------------------------------------------
-- 2. CHARGEMENT DU MODULE STANDARD
--------------------------------------------------------------------------------

local function chargerModule()
  if module then return module end
  if motifIndispo then return nil, motifIndispo end

  if not fs.exists(CHEMIN_MODULE) then
    motifIndispo = "module d'autopilote absent : installez " .. CHEMIN_MODULE
      .. " (poste 'vehicule' de l'installateur)"
    return nil, motifIndispo
  end

  local morceau = loadfile(CHEMIN_MODULE)
  if not morceau then
    motifIndispo = "module d'autopilote illisible : " .. CHEMIN_MODULE
    return nil, motifIndispo
  end
  local ok, resultat = pcall(morceau)
  if not ok or type(resultat) ~= "table" then
    motifIndispo = "module d'autopilote invalide : " .. tostring(resultat)
    return nil, motifIndispo
  end

  module = resultat
  return module
end

--- Configuration du ballon, pour la section 'ballast'.
local function configVaisseau()
  if not fs.exists(CHEMIN_CONFIG_VAISSEAU) then return {} end
  local morceau = loadfile(CHEMIN_CONFIG_VAISSEAU)
  if not morceau then return {} end
  local ok, config = pcall(morceau)
  return (ok and type(config) == "table") and config or {}
end

--------------------------------------------------------------------------------
-- 3. VERIFICATION DU CABLAGE
--    Un ballon dont aucun axe n'est cable accepte tout et ne bouge jamais.
--------------------------------------------------------------------------------

local function cablageSuffisant(config)
  local axes = (config.sorties or {}).axes or {}
  local manquants = {}
  for _, nomAxe in ipairs({ "avance", "vertical", "lacet" }) do
    local reglageAxe = axes[nomAxe]
    if not (reglageAxe and (reglageAxe.mode or "aucun") ~= "aucun") then
      manquants[#manquants + 1] = nomAxe
    end
  end
  if #manquants == 3 then
    return false, "aucun axe n'est cable dans /autopilote/config_vehicule.lua : "
      .. "lancez 'calibrer' pour que l'autopilote trouve seul quelle face "
      .. "commande quel axe"
  end
  if #manquants > 0 then
    return true, "axe(s) non cable(s) : " .. table.concat(manquants, ", ")
      .. " -- le ballon ne pourra pas corriger ces degres de liberte ('calibrer' "
      .. "les cherchera pour vous)"
  end
  return true
end

--------------------------------------------------------------------------------
-- 4. ENGAGEMENT
--------------------------------------------------------------------------------

--- Prepare l'autopilote et prend la main sur les moteurs.
-- @return true | false, motif
function adaptateur.engager()
  if engage and ap then return true end

  local m, motif = chargerModule()
  if not m then
    journaliser("AVERT", "engagement refuse : " .. tostring(motif))
    return false, motif
  end

  local okConfig, config = pcall(m.chargerConfiguration)
  if not okConfig then
    local raison = "configuration vehicule illisible : " .. tostring(config)
    journaliser("AVERT", "engagement refuse : " .. raison)
    return false, raison
  end

  local suffisant, remarque = cablageSuffisant(config)
  if not suffisant then
    journaliser("AVERT", "engagement refuse : " .. remarque)
    return false, remarque
  end
  if remarque then journaliser("AVERT", remarque) end

  if not ap then
    local okInstance, instance = pcall(m.nouveau, {})
    if not okInstance then
      local raison = "autopilote non instanciable : " .. tostring(instance)
      journaliser("ERREUR", "engagement refuse : " .. raison)
      return false, raison
    end
    ap = instance
  end

  local okInit, err = pcall(ap.initialiser)
  if not okInit then
    local raison = "initialisation impossible : " .. tostring(err)
    journaliser("ERREUR", "engagement refuse : " .. raison)
    return false, raison
  end

  engage = true
  dernierPas = os.clock()
  journaliser("INFO", "autopilote engage")
  return true
end

--- Rend la main a l'equipage et neutralise les moteurs.
function adaptateur.desengager()
  engage = false
  if not ap then return true end
  pcall(ap.arreter, "desengagement demande depuis la passerelle")
  journaliser("INFO", "autopilote desengage, moteurs neutralises")
  return true
end

--------------------------------------------------------------------------------
-- 5. ROUTE
--------------------------------------------------------------------------------

--- Transmet une route au pilote.
-- Les waypoints viennent de la page NAVIGATION : { nom, x, z, y facultatif }.
-- Une altitude absente prend celle de la croisiere : un point de carte n'a pas
-- de hauteur, et deviner zero enverrait le ballon dans le sol.
-- @return true, nombre de points | false, motif
function adaptateur.definirRoute(waypoints)
  if type(waypoints) ~= "table" or #waypoints == 0 then
    return false, "route vide"
  end

  if not engage then
    local ok, motif = adaptateur.engager()
    if not ok then return false, motif end
  end

  local altitudeDefaut = ((ap.config or {}).vitesses or {}).altitudeCroisiere or 120
  local points = {}
  for index, w in ipairs(waypoints) do
    local x, z = tonumber(w.x), tonumber(w.z)
    if not (x and z) then
      return false, string.format("waypoint %d sans coordonnees exploitables", index)
    end
    points[#points + 1] = {
      x = x, y = tonumber(w.y) or altitudeDefaut, z = z,
      nom = w.nom or ("WP" .. index),
    }
  end

  local ok, err = pcall(ap.suivreItineraire, points)
  if not ok then
    local raison = "itineraire refuse : " .. tostring(err)
    journaliser("AVERT", raison)
    return false, raison
  end

  route = points
  journaliser("INFO", string.format("route de %d point(s) acceptee", #points))
  return true, #points
end

--------------------------------------------------------------------------------
-- 6. ASSERVISSEMENT
--    Appele par la boucle du systeme embarque : l'adaptateur ne possede pas de
--    fil d'execution a lui, et un module qui accepte des routes sans jamais
--    recevoir de temps de calcul ne vaut pas mieux qu'un module absent.
--------------------------------------------------------------------------------

--- Un cycle d'asservissement.
-- @return true | false, motif
function adaptateur.pas()
  if not (engage and ap) then return false, "autopilote non engage" end
  local ok, err = pcall(ap.pas)
  if not ok then
    -- Une erreur d'asservissement ne doit jamais laisser les moteurs sous
    -- tension : on desengage, et l'equipage reprend la main en connaissance
    -- de cause.
    journaliser("ERREUR", "cycle de pilotage interrompu, moteurs neutralises : "
      .. tostring(err))
    adaptateur.desengager()
    return false, tostring(err)
  end
  dernierPas = os.clock()
  return true
end

--------------------------------------------------------------------------------
-- 7. ETAT
--------------------------------------------------------------------------------

--- Resume destine aux pages du systeme embarque.
function adaptateur.etat()
  if not ap then
    return {
      engage = false, disponible = false,
      motif = motifIndispo or "autopilote jamais engage",
      route = #route, largages = largages,
    }
  end

  local ok, etatVol = pcall(ap.etat)
  if not ok or type(etatVol) ~= "table" then
    return { engage = engage, disponible = true,
             motif = "etat de vol illisible", route = #route, largages = largages }
  end

  return {
    engage     = engage,
    disponible = true,
    mode       = etatVol.mode,
    phase      = etatVol.phase,
    position   = etatVol.position,
    cap        = etatVol.cap,
    sourceCap  = etatVol.sourceCap,
    vitesse    = etatVol.vitesse,
    cible      = etatVol.cible,
    distance   = etatVol.distance,
    hauteurSol = etatVol.hauteurSol,
    route      = #route,
    largages   = largages,
    dernierPas = dernierPas,
  }
end

--------------------------------------------------------------------------------
-- 8. BALLAST
--    Mecanisme propre a ce ballon : une face redstone et une duree, declarees
--    dans vaisseau/config_vaisseau.lua.
--
--      ballast = { cote = "back", duree = 0.5, niveau = 15 },
--
--    Non declare, le largage est REFUSE. Repondre "largue" sans rien larguer
--    ferait descendre un equipage persuade de remonter.
--------------------------------------------------------------------------------

function adaptateur.largerBallast()
  local config = configVaisseau()
  local reglages = config.ballast

  if type(reglages) ~= "table" or not reglages.cote then
    local motif = "aucun ballast declare : ajoutez "
      .. "ballast = { cote = \"back\", duree = 0.5 } dans "
      .. CHEMIN_CONFIG_VAISSEAU
    journaliser("AVERT", "largage refuse : " .. motif)
    return false, motif
  end

  if not redstone then
    return false, "API redstone indisponible"
  end

  local niveau = tonumber(reglages.niveau) or 15
  local duree  = tonumber(reglages.duree) or 0.5

  local ok, err = pcall(function()
    if redstone.setAnalogOutput then
      redstone.setAnalogOutput(reglages.cote, niveau)
    else
      redstone.setOutput(reglages.cote, true)
    end
    sleep(duree)
    if redstone.setAnalogOutput then
      redstone.setAnalogOutput(reglages.cote, 0)
    else
      redstone.setOutput(reglages.cote, false)
    end
  end)

  if not ok then
    -- La face reste peut-etre sous tension : on insiste, une trappe de ballast
    -- bloquee ouverte vide la soute entiere.
    pcall(redstone.setOutput, reglages.cote, false)
    pcall(redstone.setAnalogOutput, reglages.cote, 0)
    local motif = "largage interrompu : " .. tostring(err)
    journaliser("ERREUR", motif)
    return false, motif
  end

  largages = largages + 1
  journaliser("INFO", string.format(
    "ballast largue (face %s, %.1fs) -- largage n%d", reglages.cote, duree, largages))
  return true, largages
end

--------------------------------------------------------------------------------
-- 9. DIAGNOSTIC
--------------------------------------------------------------------------------

--- Ce que l'adaptateur peut faire, et ce qui lui manque. Lu par 'diagnostic'.
function adaptateur.diagnostic()
  local rapport = { module = CHEMIN_MODULE, present = fs.exists(CHEMIN_MODULE) }

  if not rapport.present then
    rapport.motif = "module d'autopilote non installe"
    return rapport
  end

  local m = chargerModule()
  if not m then
    rapport.motif = motifIndispo
    return rapport
  end

  local ok, config = pcall(m.chargerConfiguration)
  if not ok then
    rapport.motif = "configuration vehicule illisible : " .. tostring(config)
    return rapport
  end

  rapport.vehicule = config.identifiant
  rapport.axes = {}
  for _, nomAxe in ipairs({ "avance", "vertical", "lacet", "lateral" }) do
    local reglageAxe = ((config.sorties or {}).axes or {})[nomAxe] or {}
    rapport.axes[nomAxe] = reglageAxe.mode or "aucun"
  end

  local suffisant, remarque = cablageSuffisant(config)
  rapport.cablageSuffisant = suffisant
  rapport.remarque = remarque

  local configBallon = configVaisseau()
  rapport.ballast = (type(configBallon.ballast) == "table" and configBallon.ballast.cote)
    and ("face " .. configBallon.ballast.cote) or "non declare"

  return rapport
end

return adaptateur
