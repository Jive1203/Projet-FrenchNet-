--[[----------------------------------------------------------------------------
  DOOMSDAY SHIP - SURVEILLANCE ET DECLENCHEMENT DES ALARMES
  Compare les mesures aux seuils, decide quoi lever ou poser. Aucune API du
  jeu : ce module doit etre testable seul, c'est lui qui interrompt l'affichage.

  - Mesure INDISPONIBLE -> alarme du CAPTEUR, pas de la valeur. La confondre
    avec un reservoir vide ferait larguer du ballast sans raison ; l'ignorer
    ferait voler a l'aveugle.
  - HYSTERESIS a la levee : sans marge, une valeur qui oscille autour du seuil
    ferait clignoter l'ecran pendant qu'on essaie de le lire.
--------------------------------------------------------------------------------]]

local surveillance = { VERSION = "1.0.0" }

local function nb(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- 'sensInverse' : la gravite monte quand la valeur BAISSE (cas le plus frequent
-- a bord). 'famille' separe des gestes differents : couper la poussee ne
-- remonte pas un ballon, larguer du ballast si.
surveillance.REGLES = {
  { cle = "propulsion.charge",    famille = "PROPULSION", unite = "%",
    titre = "SURCHARGE RESEAU",   seuils = { attention = 70, alarme = 85, critique = 95 } },
  { cle = "energie.pourcentage",  famille = "PROPULSION", unite = "%", sensInverse = true,
    titre = "ENERGIE BASSE",      seuils = { attention = 40, alarme = 20, critique = 10 } },
  { cle = "portance.pression",    famille = "PORTANCE",   unite = "%", sensInverse = true,
    titre = "PRESSION ENVELOPPE", seuils = { attention = 70, alarme = 50, critique = 30 } },
  { cle = "portance.gaz",         famille = "PORTANCE",   unite = "%", sensInverse = true,
    titre = "CELLULES DE GAZ",    seuils = { attention = 60, alarme = 40, critique = 20 } },
  { cle = "vol.vitesseVerticale", famille = "PORTANCE",   unite = "b/s", sensInverse = true,
    titre = "PERTE DE PORTANCE",  seuils = { attention = -3, alarme = -6, critique = -10 } },
}

surveillance.NIVEAUX = { "attention", "alarme", "critique" }
local RANG = { attention = "ATTENTION", alarme = "ALARME", critique = "CRITIQUE" }

function surveillance.nouveau(config)
  return setmetatable({
    config = config or {},
    actives = {},        -- [cle] = { niveau, depuis }
    capteursMuets = {},  -- [cle] = motif
    levees = 0, poses = 0,
  }, { __index = surveillance })
end

-- Les seuils de la configuration priment sur ceux de la regle.
function surveillance:seuilsDe(regle)
  local par = (self.config.seuils or {})[regle.cle]
  if type(par) ~= "table" then return regle.seuils end
  return {
    attention = par.attention or regle.seuils.attention,
    alarme    = par.alarme    or regle.seuils.alarme,
    critique  = par.critique  or regle.seuils.critique,
  }
end

local function franchi(v, seuil, inverse)
  if seuil == nil then return false end
  if inverse then return v <= seuil end
  return v >= seuil
end

function surveillance:niveauDe(regle, valeur)
  local s = self:seuilsDe(regle)
  if franchi(valeur, s.critique, regle.sensInverse)  then return "critique" end
  if franchi(valeur, s.alarme, regle.sensInverse)    then return "alarme" end
  if franchi(valeur, s.attention, regle.sensInverse) then return "attention" end
  return nil
end

--[[
  'mesures' = { [cle] = { valeur = <nombre|nil>, motif = <chaine|nil> } }
  Retourne les alarmes a POSER et les cles a LEVER : c'est l'appelant qui les
  pousse dans le MFD, ce module ne dessine rien.
]]
function surveillance:evaluer(mesures, maintenant)
  maintenant = maintenant or 0
  local aPoser, aLever = {}, {}
  local hysteresis = self.config.hysteresis or 5   -- en unites de la mesure

  for _, regle in ipairs(surveillance.REGLES) do
    local mesure = mesures[regle.cle] or {}
    local valeur = mesure.valeur

    if not nb(valeur) then
      local motif = mesure.motif or "mesure indisponible"
      if self.actives[regle.cle] then   -- la valeur n'est plus jugeable
        aLever[#aLever + 1] = regle.cle
        self.actives[regle.cle] = nil
      end
      if not self.capteursMuets[regle.cle] then
        self.capteursMuets[regle.cle] = motif
        aPoser[#aPoser + 1] = {
          cle = "capteur:" .. regle.cle, niveau = "ATTENTION", famille = regle.famille,
          titre = "CAPTEUR MUET : " .. regle.titre,
          lignes = { tostring(motif), "Cette surveillance est INACTIVE." },
        }
      end
    else
      if self.capteursMuets[regle.cle] then
        self.capteursMuets[regle.cle] = nil
        aLever[#aLever + 1] = "capteur:" .. regle.cle
      end

      local niveau, active = self:niveauDe(regle, valeur), self.actives[regle.cle]

      if niveau then
        if not active or active.niveau ~= niveau then
          self.actives[regle.cle] = { niveau = niveau, depuis = maintenant }
          aPoser[#aPoser + 1] = {
            cle = regle.cle, niveau = RANG[niveau], famille = regle.famille,
            titre = regle.titre,
            lignes = { ("%s : %.1f %s"):format(regle.titre, valeur, regle.unite or ""),
                       ("seuil %s franchi"):format(niveau) },
          }
        end
      elseif active then
        -- Ecrit en 'if' explicite, PAS en 'a and b or c' : le ternaire de Lua
        -- bascule sur la seconde branche des que la premiere vaut false, et
        -- levait l'alarme exactement quand il fallait la tenir.
        local s, marge, revenue = self:seuilsDe(regle)
        if regle.sensInverse then
          marge = s.attention + hysteresis
          revenue = valeur >= marge
        else
          marge = s.attention - hysteresis
          revenue = valeur <= marge
        end
        if revenue then
          self.actives[regle.cle] = nil
          aLever[#aLever + 1] = regle.cle
        end
      end
    end
  end

  self.poses  = self.poses + #aPoser
  self.levees = self.levees + #aLever
  return aPoser, aLever
end

function surveillance:resume()
  local actives, muets = 0, 0
  for _ in pairs(self.actives) do actives = actives + 1 end
  for _ in pairs(self.capteursMuets) do muets = muets + 1 end
  return actives, muets
end

return surveillance
