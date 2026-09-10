--[[----------------------------------------------------------------------------
  DOOMSDAY SHIP - SURVEILLANCE ET DECLENCHEMENT DES ALARMES
  --------------------------------------------------------------------------
  Compare les mesures aux seuils et decide quelles alarmes lever ou baisser.
  Aucune API du jeu : ce module est testable seul, et il doit l'etre - c'est
  lui qui decide qu'on interrompt l'affichage en cours.

  DEUX PRINCIPES
  1. Une mesure INDISPONIBLE ne declenche pas l'alarme de la valeur, elle
     declenche l'alarme du CAPTEUR. Traiter un capteur muet comme un reservoir
     vide ferait larguer du ballast sans raison ; l'ignorer laisserait voler
     a l'aveugle. Les deux sont fautifs, donc on le dit pour ce que c'est.
  2. Une alarme a une HYSTERESIS : elle ne se leve qu'apres etre repassee
     franchement sous le seuil. Sans cela, une valeur qui oscille autour du
     seuil ferait clignoter l'ecran en continu pendant qu'on essaie de
     travailler dessus.
--------------------------------------------------------------------------------]]

local surveillance = { VERSION = "1.0.0" }

local function nombreValide(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--[[
  REGLES.
  'sensInverse' : la gravite augmente quand la valeur BAISSE - pression,
  gaz, munitions, energie. C'est le cas le plus frequent a bord.
  'famille' separe les alarmes qui appellent des gestes differents : couper la
  poussee ne remonte pas un ballon, larguer du ballast si.
]]
surveillance.REGLES = {
  { cle = "propulsion.charge", famille = "PROPULSION",
    titre = "SURCHARGE RESEAU", unite = "%",
    seuils = { attention = 70, alarme = 85, critique = 95 } },

  { cle = "energie.pourcentage", famille = "PROPULSION", sensInverse = true,
    titre = "ENERGIE BASSE", unite = "%",
    seuils = { attention = 40, alarme = 20, critique = 10 } },

  { cle = "portance.pression", famille = "PORTANCE", sensInverse = true,
    titre = "PRESSION ENVELOPPE", unite = "%",
    seuils = { attention = 70, alarme = 50, critique = 30 } },

  { cle = "portance.gaz", famille = "PORTANCE", sensInverse = true,
    titre = "CELLULES DE GAZ", unite = "%",
    seuils = { attention = 60, alarme = 40, critique = 20 } },

  { cle = "vol.vitesseVerticale", famille = "PORTANCE", sensInverse = true,
    titre = "PERTE DE PORTANCE", unite = "b/s",
    seuils = { attention = -3, alarme = -6, critique = -10 } },
}

surveillance.NIVEAUX = { "attention", "alarme", "critique" }
local RANG = { attention = "ATTENTION", alarme = "ALARME", critique = "CRITIQUE" }

function surveillance.nouveau(config)
  return setmetatable({
    config = config or {},
    actives = {},          -- [cle] = { niveau, depuis }
    capteursMuets = {},    -- [cle] = motif
    levees = 0, poses = 0,
  }, { __index = surveillance })
end

-- Seuils effectifs : ceux de la configuration priment sur ceux de la regle.
function surveillance:seuilsDe(regle)
  local par = (self.config.seuils or {})[regle.cle]
  if type(par) ~= "table" then return regle.seuils end
  return {
    attention = par.attention or regle.seuils.attention,
    alarme    = par.alarme    or regle.seuils.alarme,
    critique  = par.critique  or regle.seuils.critique,
  }
end

local function franchi(valeur, seuil, sensInverse)
  if seuil == nil then return false end
  if sensInverse then return valeur <= seuil end
  return valeur >= seuil
end

-- Niveau atteint par une valeur, du plus grave au plus benin.
function surveillance:niveauDe(regle, valeur)
  local seuils = self:seuilsDe(regle)
  if franchi(valeur, seuils.critique, regle.sensInverse)  then return "critique" end
  if franchi(valeur, seuils.alarme, regle.sensInverse)    then return "alarme" end
  if franchi(valeur, seuils.attention, regle.sensInverse) then return "attention" end
  return nil
end

--[[
  Evalue toutes les regles.
  'mesures' = { [cle] = { valeur = <nombre|nil>, motif = <chaine|nil> } }

  Retourne deux listes : les alarmes a POSER et les cles a LEVER. C'est
  l'appelant qui les pousse dans le MFD - ce module ne dessine rien et ne
  connait pas l'affichage.
]]
function surveillance:evaluer(mesures, maintenant)
  maintenant = maintenant or 0
  local aPoser, aLever = {}, {}
  local hysteresis = self.config.hysteresis or 5   -- en unites de la mesure

  for _, regle in ipairs(surveillance.REGLES) do
    local mesure = mesures[regle.cle] or {}
    local valeur = mesure.valeur

    ------------------------------------------------------------ capteur muet
    if not nombreValide(valeur) then
      -- On distingue « capteur absent depuis le demarrage » de « capteur qui
      -- vient de tomber ». Le premier est un probleme d'installation, le
      -- second une avarie en vol : ce ne sont pas les memes gestes.
      local cle = "capteur:" .. regle.cle
      if self.actives[regle.cle] then
        aLever[#aLever + 1] = regle.cle
        self.actives[regle.cle] = nil
      end
      if not self.capteursMuets[regle.cle] then
        self.capteursMuets[regle.cle] = mesure.motif or "mesure indisponible"
        aPoser[#aPoser + 1] = {
          cle = cle, niveau = "ATTENTION", famille = regle.famille,
          titre = "CAPTEUR MUET : " .. regle.titre,
          lignes = { tostring(mesure.motif or "mesure indisponible"),
                     "Cette surveillance est INACTIVE." },
        }
      end
    else
      if self.capteursMuets[regle.cle] then
        self.capteursMuets[regle.cle] = nil
        aLever[#aLever + 1] = "capteur:" .. regle.cle
      end

      local niveau = self:niveauDe(regle, valeur)
      local active = self.actives[regle.cle]

      if niveau then
        if not active or active.niveau ~= niveau then
          self.actives[regle.cle] = { niveau = niveau, depuis = maintenant }
          aPoser[#aPoser + 1] = {
            cle = regle.cle, niveau = RANG[niveau], famille = regle.famille,
            titre = regle.titre,
            lignes = {
              string.format("%s : %.1f %s", regle.titre, valeur, regle.unite or ""),
              string.format("seuil %s franchi", niveau),
            },
          }
        end
      elseif active then
        --[[
          HYSTERESIS. On ne leve qu'une fois la valeur revenue FRANCHEMENT du
          bon cote du seuil d'attention. Sans marge, une valeur qui oscille
          autour du seuil ferait clignoter l'ecran sans repit - exactement au
          moment ou l'equipage a besoin de le lire.
        ]]
        local seuils = self:seuilsDe(regle)
        local marge, revenue
        --[[
          Ecrit en if explicite, PAS en 'a and b or c'.
          Le raccourci ternaire de Lua est faux des que la branche 'then' vaut
          false : 'sensInverse and (valeur >= marge) or (valeur <= marge)'
          bascule sur la seconde comparaison quand la premiere est fausse, et
          levait donc l'alarme exactement quand il fallait la tenir. Le banc
          d'essai l'a pris en flagrant delit.
        ]]
        if regle.sensInverse then
          marge = seuils.attention + hysteresis
          revenue = valeur >= marge
        else
          marge = seuils.attention - hysteresis
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
