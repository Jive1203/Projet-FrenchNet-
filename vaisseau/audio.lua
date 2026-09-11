--[[----------------------------------------------------------------------------
  DOOMSDAY SHIP - AVERTISSEUR SONORE (PHASE 4)
  Joue les alarmes sur les haut-parleurs du bord.

  POURQUOI C'EST ECRIT AVEC PRUDENCE
  Le son est la seule alarme qui atteigne un equipage qui ne regarde pas
  l'ecran. C'est aussi la seule que l'equipage peut couper definitivement s'il
  la trouve insupportable - et une alarme coupee ne sert plus a rien. D'ou
  trois regles :
    1. chaque niveau a sa SIGNATURE, pas seulement son volume : une critique
       doit s'entendre differente d'une attention, meme de dos ;
    2. motif court et repete a intervalle, jamais un bourdonnement continu ;
    3. le silence est demandable, il est journalise, et il EXPIRE tout seul -
       un equipage qui coupe le son en plein engagement ne doit pas voler
       muet pour le reste de la partie.

  L'API haut-parleur de CC: Tweaked (playNote, playSound, stop) est documentee
  et stable : contrairement a Create Aeronautics, il n'y a rien a deviner ici.
  La detection reste faite PAR METHODE, par coherence avec le reste du bord.
--------------------------------------------------------------------------------]]

local audio = { VERSION = "1.0.0" }

--[[
  Signatures. { instrument, hauteur } joues dans l'ordre, un pas par appel de
  'jouerPas'. 'periode' = secondes entre deux repetitions du motif.
  Hauteur : 0-24 chez CC, 12 = do central.
]]
audio.SIGNATURES = {
  ATTENTION = { periode = 8, volume = 1.0,
    pas = { { "bell", 12 }, { false }, { "bell", 12 } } },
  ALARME    = { periode = 4, volume = 2.0,
    pas = { { "bit", 16 }, { "bit", 12 }, { "bit", 16 }, { "bit", 12 } } },
  -- La critique descend au lieu de monter : une sirene qui tombe ne se
  -- confond avec aucune autre alarme du serveur, et c'est voulu.
  CRITIQUE  = { periode = 2, volume = 3.0,
    pas = { { "didgeridoo", 18 }, { "didgeridoo", 14 }, { "didgeridoo", 10 },
            { "didgeridoo", 6 } } },
}

function audio.nouveau(config, peripheriques, journal)
  return setmetatable({
    config = config or {}, peripheriques = peripheriques or peripheral,
    journal = journal or function() end,
    hautParleurs = {}, actif = nil, pas = 1, prochainPasA = 0,
    silenceJusqua = nil, notes = 0, echecs = 0,
  }, { __index = audio })
end

function audio:decouvrir()
  self.hautParleurs = {}
  local ok, noms = pcall(self.peripheriques.getNames)
  if not ok or type(noms) ~= "table" then return 0 end
  for _, nom in ipairs(noms) do
    local env = select(2, pcall(self.peripheriques.wrap, nom))
    if type(env) == "table" and type(env.playNote) == "function" then
      self.hautParleurs[#self.hautParleurs + 1] = nom
    end
  end
  if #self.hautParleurs == 0 then
    self.journal("AVERT", "audio", "aucun haut-parleur : les alarmes seront " ..
      "VISUELLES SEULEMENT. Un equipage qui ne regarde pas l'ecran ne sera pas prevenu.")
  else
    self.journal("INFO", "audio",
      ("%d haut-parleur(s) : %s"):format(#self.hautParleurs, table.concat(self.hautParleurs, ", ")))
  end
  return #self.hautParleurs
end

function audio:disponible() return #self.hautParleurs > 0 end

-- Silence temporaire, qui EXPIRE : voler muet pour le reste de la partie
-- serait le plus sur moyen de ne pas entendre la prochaine alarme.
function audio:silencier(secondes, maintenant)
  local duree = secondes or self.config.silenceSecondes or 120
  self.silenceJusqua = (maintenant or 0) + duree
  self.journal("AVERT", "audio",
    ("son coupe par l'equipage pour %ds : il reviendra tout seul"):format(duree))
  return self.silenceJusqua
end

function audio:silencieux(maintenant)
  if self.config.audioActif == false then return true, "audio desactive en configuration" end
  if self.silenceJusqua and (maintenant or 0) < self.silenceJusqua then
    return true, ("silence demande, %ds restantes")
      :format(math.ceil(self.silenceJusqua - (maintenant or 0)))
  end
  return false
end

-- Arme une signature. Une alarme MOINS grave ne remplace pas une plus grave
-- deja en cours : on n'interrompt pas une sirene de perte de portance pour
-- annoncer une batterie faible.
local ORDRE = { ATTENTION = 1, ALARME = 2, CRITIQUE = 3 }

function audio:signaler(niveau, maintenant)
  local signature = audio.SIGNATURES[niveau]
  if not signature then return false, "niveau sonore inconnu : " .. tostring(niveau) end
  if self.actif and (ORDRE[self.actif] or 0) > (ORDRE[niveau] or 0) then
    return false, "une alarme plus grave est deja en cours"
  end
  if self.actif ~= niveau then
    self.actif, self.pas, self.prochainPasA = niveau, 1, maintenant or 0
  end
  return true
end

function audio:taire()
  self.actif, self.pas = nil, 1
end

--[[
  Fait avancer le motif d'un pas si l'instant est venu. A appeler souvent
  depuis la boucle ; elle ne bloque jamais et ne dort pas.
  Retourne : true si une note est partie.
]]
function audio:jouerPas(maintenant)
  maintenant = maintenant or 0
  if not self.actif or not self:disponible() then return false end
  if self:silencieux(maintenant) then return false end
  if maintenant < (self.prochainPasA or 0) then return false end

  local signature = audio.SIGNATURES[self.actif]
  local pas = signature.pas[self.pas]
  local intervalle = self.config.intervallePas or 0.25

  if pas and pas[1] then
    for _, nom in ipairs(self.hautParleurs) do
      local ok = pcall(self.peripheriques.call, nom, "playNote", pas[1],
        math.min(3, signature.volume * (self.config.volume or 1)), pas[2])
      if ok then self.notes = self.notes + 1 else self.echecs = self.echecs + 1 end
    end
  end

  self.pas = self.pas + 1
  if self.pas > #signature.pas then
    self.pas = 1
    self.prochainPasA = maintenant + signature.periode   -- pause entre motifs
  else
    self.prochainPasA = maintenant + intervalle
  end
  return pas ~= nil and pas[1] ~= nil and pas[1] ~= false
end

function audio:resume()
  return #self.hautParleurs, self.actif, self.notes, self.echecs
end

return audio
