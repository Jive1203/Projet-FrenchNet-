--[[----------------------------------------------------------------------------
  DOOMSDAY SHIP - RELAIS MUSIQUE / « NOW PLAYING » (PHASE 4)

  CE MODULE PEUT ETRE BLOQUE PAR LE SERVEUR, ET C'EST NORMAL
  Le cahier des charges demande un relais HTTP. Or 'http' est nil quand
  l'administrateur ne l'a pas autorise dans computercraft-server.toml, et aucun
  code ne peut contourner cela. Le module a donc DEUX modes, et il dit toujours
  lequel il utilise :
    HTTP    - interrogation du relais, comme specifie ;
    RESEAU  - repli : un ordinateur hors du ballon interroge le relais et
              pousse la trame par rednet. L'affichage est le meme, la source
              non, et l'ecran le dit.
    AUCUN   - ni l'un ni l'autre : la page affiche l'absence, pas un titre vide.

  Aucun decodage audio ici. Un moniteur CC n'a pas de decodeur et chaque
  caractere modifie est un paquet reseau : on affiche un titre, on ne joue pas
  un flux. La page l'annonce pour que personne n'attende autre chose.

  'http' et 'reseau' sont injectables : ce module est testable hors du jeu.
--------------------------------------------------------------------------------]]

local musique = { VERSION = "1.0.0" }

musique.MODES = { HTTP = "HTTP", RESEAU = "RESEAU", AUCUN = "AUCUN" }

function musique.nouveau(config, http, journal, analyseur)
  return setmetatable({
    config = config or {}, http = http, journal = journal or function() end,
    -- Analyseur injectable : textutils en jeu, une fonction simple en test.
    analyseur = analyseur,
    piste = nil, recuA = nil, motif = "aucune interrogation encore faite",
    interrogations = 0, echecs = 0, viaReseau = 0,
  }, { __index = musique })
end

function musique:mode()
  if self.config.musiqueActive == false then return musique.MODES.AUCUN, "desactive en configuration" end
  if self.http and type(self.config.urlRelais) == "string" and self.config.urlRelais ~= "" then
    return musique.MODES.HTTP, self.config.urlRelais
  end
  if self.config.musiqueParReseau ~= false then
    return musique.MODES.RESEAU,
      "HTTP indisponible ou sans URL : en attente d'un relais sur rednet"
  end
  return musique.MODES.AUCUN, "HTTP indisponible et repli reseau desactive"
end

-- Accepte du JSON ou une table Lua serialisee : le relais est ecrit par
-- quelqu'un d'autre, autant lire les deux formes plutot que d'imposer la mienne.
function musique:analyser(corps)
  if type(corps) ~= "string" or corps == "" then return nil, "reponse vide" end
  if self.analyseur then
    local ok, r = pcall(self.analyseur, corps)
    if ok and type(r) == "table" then return r end
  end
  if textutils then
    if textutils.unserialiseJSON then
      local ok, r = pcall(textutils.unserialiseJSON, corps)
      if ok and type(r) == "table" then return r end
    end
    if textutils.unserialise then
      local ok, r = pcall(textutils.unserialise, corps)
      if ok and type(r) == "table" then return r end
    end
  end
  -- Dernier repli : le relais rend une simple ligne de texte.
  return { titre = corps:sub(1, 120) }
end

local function retenir(self, brute, maintenant, source)
  if type(brute) ~= "table" then return false end
  local titre = brute.titre or brute.title or brute.now_playing
  if type(titre) ~= "string" or titre == "" then
    self.motif = "le relais n'a pas renvoye de titre"
    return false
  end
  self.piste = {
    titre = titre,
    artiste = brute.artiste or brute.artist,
    album = brute.album,
    duree = tonumber(brute.duree or brute.duration),
    position = tonumber(brute.position or brute.elapsed),
    source = source,
  }
  self.recuA, self.motif = maintenant, nil
  return true
end

--[[
  Interrogation du relais. NE BLOQUE QUE SA PROPRE COROUTINE : elle tourne sous
  parallel, donc une requete qui traine ne fige ni les mesures ni l'affichage.
  Retourne : ok, motif.
]]
function musique:interroger(maintenant)
  local mode, detail = self:mode()
  if mode ~= musique.MODES.HTTP then
    self.motif = detail
    return false, detail
  end

  self.interrogations = self.interrogations + 1
  local ok, reponse = pcall(self.http.get, self.config.urlRelais,
    self.config.entetesRelais, false)
  if not ok or not reponse then
    self.echecs = self.echecs + 1
    self.motif = "relais injoignable : " .. tostring(reponse)
    -- Journalise une seule fois par panne : un relais mort a chaque
    -- interrogation noierait le journal de bord sous de la musique.
    if not self.panneDite then
      self.panneDite = true
      self.journal("AVERT", "musique", self.motif)
    end
    return false, self.motif
  end
  self.panneDite = nil

  local corps = reponse.readAll and reponse.readAll() or nil
  if reponse.close then pcall(reponse.close) end
  local brute, motif = self:analyser(corps)
  if not brute then
    self.motif = motif or "reponse illisible"
    return false, self.motif
  end
  return retenir(self, brute, maintenant, musique.MODES.HTTP), self.motif
end

-- Trame poussee par un relais exterieur, quand HTTP est coupe a bord.
function musique:recevoirTrame(trame, maintenant)
  if type(trame) ~= "table" or trame.protocole ~= "FRENCHNET_MUSIQUE" then return false end
  self.viaReseau = self.viaReseau + 1
  return retenir(self, trame, maintenant, musique.MODES.RESEAU)
end

-- Retourne : piste, motif. Une piste trop vieille est oubliee : un titre fige
-- depuis vingt minutes se lit comme un relais qui marche, alors qu'il est mort.
function musique:etat(maintenant)
  local peremption = self.config.musiquePeremption or 60
  if self.piste and self.recuA and (maintenant or 0) - self.recuA > peremption then
    self.piste = nil
    self.motif = ("relais muet depuis plus de %ds"):format(peremption)
  end
  if self.piste then return self.piste end
  return nil, self.motif or select(2, self:mode())
end

return musique
