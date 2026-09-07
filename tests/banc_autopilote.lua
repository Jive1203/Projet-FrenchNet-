--[[----------------------------------------------------------------------------
  BANC D'ESSAI - Faux module d'autopilote
  --------------------------------------------------------------------------
  Substitut du module d'autopilote standardise, utilise UNIQUEMENT par
  tests/test_intercepteur.lua. Il expose l'API attendue par l'adaptateur
  intercepteur/autopilote.lua et simule un vol simplifie : le navire se dirige
  vers le point de consigne a la vitesse commandee.

  Ce n'est pas une loi de pilotage : aucune dynamique, aucune inertie. Il sert
  a verifier la MACHINE A ETATS du navire, pas la qualite du vol.
--------------------------------------------------------------------------------]]

local config = ...

local etat = {
  config    = config,
  point     = nil,
  vitesse   = 0,
  cap       = 0,
  -- Position de depart imposee par le scenario, sinon origine par defaut.
  position  = _G.__BANC_DEPART and {
    x = _G.__BANC_DEPART.x, y = _G.__BANC_DEPART.y, z = _G.__BANC_DEPART.z,
  } or { x = 0, y = 150, z = 0 },
  vecteur   = { x = 0, y = 0, z = 0 },
  derniereActualisation = nil,
  mode      = "PID",
  commandes = 0,
}

-- Le banc pilote la simulation depuis l'exterieur via cette table partagee.
_G.__BANC_AP = etat

local function norme(v) return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end

return {
  demarrer = function() return true end,

  definirPoint = function(x, y, z)
    etat.point = { x = x, y = y, z = z }
    etat.commandes = etat.commandes + 1
  end,

  definirVitesse = function(v) etat.vitesse = v end,
  definirCap     = function(c) etat.cap = c end,

  position = function()
    return etat.position.x, etat.position.y, etat.position.z
  end,

  vitesse = function()
    return etat.vecteur.x, etat.vecteur.y, etat.vecteur.z
  end,

  mode = function() return etat.mode end,

  stationnaire = function()
    etat.vitesse = 0
    etat.vecteur = { x = 0, y = 0, z = 0 }
  end,

  arreter = function() etat.vitesse = 0 end,

  --- Integration du mouvement : appelee a chaque cycle de controle.
  actualiser = function()
    local t = os.clock()
    local dt = etat.derniereActualisation and (t - etat.derniereActualisation) or 0
    etat.derniereActualisation = t
    if dt <= 0 then return end

    -- Perturbation injectee par le banc (simulation d'un encaissement).
    if _G.__BANC_PERTURBATION then
      _G.__BANC_PERTURBATION(etat, t, dt)
    end

    if not etat.point or etat.vitesse <= 0 then
      etat.vecteur = { x = 0, y = 0, z = 0 }
      return
    end

    local d = {
      x = etat.point.x - etat.position.x,
      y = etat.point.y - etat.position.y,
      z = etat.point.z - etat.position.z,
    }
    local distance = norme(d)
    if distance < 1e-6 then
      etat.vecteur = { x = 0, y = 0, z = 0 }
      return
    end

    local pas = math.min(etat.vitesse * dt, distance)
    local u = { x = d.x / distance, y = d.y / distance, z = d.z / distance }
    etat.position = {
      x = etat.position.x + u.x * pas,
      y = etat.position.y + u.y * pas,
      z = etat.position.z + u.z * pas,
    }
    etat.vecteur = { x = u.x * pas / dt, y = u.y * pas / dt, z = u.z * pas / dt }
  end,
}
