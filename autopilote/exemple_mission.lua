--[[----------------------------------------------------------------------------
  EXEMPLES DE PROGRAMMES DE MISSION - AUTOPILOTE FRENCHNET
  --------------------------------------------------------------------------
  L'autopilote est une BIBLIOTHEQUE : il ne decide de rien tout seul. Ce sont
  les programmes FrenchNet - livraison, scramble, patrouille armee - qui lui
  donnent une cible ou un itineraire. Ce fichier montre les trois cas d'usage
  du serveur, avec la meme interface dans les trois cas.

  Pour l'utiliser tel quel sur un vehicule :
      cp autopilote/exemple_mission.lua autopilote/mission.lua
      edit autopilote/mission.lua        -- adapter les coordonnees
      reboot                             -- startup.lua le lancera tout seul

  Usage :  exemple_mission livraison | scramble | station
--------------------------------------------------------------------------------]]

local autopilote = dofile("/autopilote/autopilote.lua")

--------------------------------------------------------------------------------
-- Ce que le programme appelant a besoin de savoir - et rien de plus :
--
--   local ap = autopilote.nouveau()          -- lit config_vehicule.lua
--   ap.initialiser()                         -- relit la position avant tout
--   ap.allerA(point, options)                -- rejoindre un point
--   ap.suivreItineraire(points, options)     -- enchainer des points
--   ap.maintenirPosition(point)              -- tenir la position
--   ap.arreter()                             -- neutraliser les commandes
--   ap.etat()                                -- instantane complet
--   ap.attendreArrivee(delai)                -- bloquant, dans une tache
--   ap.rejoindreRavitaillement()             -- station verrouillee du reseau
--
--   parallel.waitForAny(ap.executer, mission)   -- la boucle de vol
--
-- Un point : { x = , y = , z = , type = "survol" | "depot" | "atterrissage",
--              cap = degres, arret = true, nom = "..." }
--------------------------------------------------------------------------------

local ap = autopilote.nouveau()

-- Les evenements permettent de suivre la mission sans interroger l'autopilote.
ap.surEvenement(function(typeEvenement, donnees)
  if typeEvenement == "etape" then
    print(string.format("[MISSION] etape %d/%d franchie : %s",
      donnees.index, donnees.total, tostring(donnees.point.nom or "sans nom")))
  elseif typeEvenement == "arrivee" then
    print(string.format("[MISSION] arrive a destination (ecart %.2f bloc)",
      donnees.ecart or 0))
  elseif typeEvenement == "anomalie" then
    print("[MISSION] ANOMALIE : " .. tostring(donnees.motif))
  end
end)

--------------------------------------------------------------------------------
-- 1. DIRIGEABLE DE LIVRAISON
--    Itineraire complet, largage sur un point de depot, puis retour a la
--    station de ravitaillement. Le decalage de depot fait tomber la charge
--    sur la cible, pas le centre du dirigeable.
--------------------------------------------------------------------------------

local function livraison()
  ap.suivreItineraire({
    { x =  480, y = 120, z = -1200, nom = "SORTIE-HANGAR" },
    { x = 1150, y = 140, z = -2400, nom = "COL-NORD" },
    { x = 1980, y = 118, z = -3100, nom = "ENTREPOT-3", type = "depot" },
  }, {
    surEtape = function(index, point)
      print("[LIVRAISON] passage " .. index .. " : " .. tostring(point.nom))
    end,
  })

  local arrive = ap.attendreArrivee(600)
  if not arrive then
    print("[LIVRAISON] delai depasse : maintien de position et alerte")
    ap.maintenirPosition()
    return
  end

  print("[LIVRAISON] largage de la cargaison...")
  sleep(3)   -- ici : piston, hopper, ou tout autre mecanisme de largage

  ap.rejoindreRavitaillement()
  ap.attendreArrivee(900)
  print("[LIVRAISON] vehicule au ravitaillement, mission terminee")
end

--------------------------------------------------------------------------------
-- 2. INTERCEPTEUR DE SCRAMBLE
--    Une cible unique, en vol direct et rapide. On desactive la montee en
--    croisiere (transitHaute = false) : un intercepteur monte en route, il ne
--    perd pas trente secondes a prendre de l'altitude avant de partir.
--------------------------------------------------------------------------------

local function scramble(cible)
  cible = cible or { x = 2400, y = 190, z = 850 }
  ap.allerA({ x = cible.x, y = cible.y, z = cible.z, nom = "CONTACT" }, {
    transitHaute = false,
    surArrivee = function() print("[SCRAMBLE] sur zone, passage en patrouille") end,
  })
  if ap.attendreArrivee(300) then
    -- Arrive : l'autopilote est deja passe seul en maintien de position.
    while true do
      local vol = ap.etat()
      print(string.format("[SCRAMBLE] sur zone - derive %.2fm - cap %.0f",
        vol.distance or 0, vol.cap or 0))
      sleep(10)
    end
  end
end

--------------------------------------------------------------------------------
-- 3. NAVIRE ARME EN STATION
--    Le vehicule tient un point precis, cap impose, et corrige en permanence
--    sa derive. C'est le mode maintien, avec ses gains plus serres.
--------------------------------------------------------------------------------

local function station()
  ap.maintenirPosition({ x = -640, y = 155, z = 2210, nom = "POSTE-SUD" }, 270)
  while true do
    local vol = ap.etat()
    if vol.mode == "SECOURS" then
      print("[STATION] signal GPS perdu : commandes neutralisees")
    end
    sleep(15)
  end
end

--------------------------------------------------------------------------------
-- LANCEMENT
--    L'autopilote tourne dans sa propre tache : parallel.waitForAny arrete
--    tout des que l'une des deux se termine.
--------------------------------------------------------------------------------

local MISSIONS = { livraison = livraison, scramble = scramble, station = station }
local demandee = ({ ... })[1] or "livraison"
local mission = MISSIONS[demandee]

if not mission then
  printError("Mission inconnue : " .. tostring(demandee))
  print("Missions disponibles : livraison | scramble | station")
  return
end

print("=== FRENCHNET - MISSION " .. string.upper(demandee) .. " ===")
ap.initialiser()

local ok, err = pcall(parallel.waitForAny,
  function() ap.executer() end,
  function() mission() end)

ap.arreter("fin du programme de mission")
if not ok then error(err, 0) end
