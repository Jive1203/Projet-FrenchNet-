--[[----------------------------------------------------------------------------
  DOOMSDAY SHIP - CONSCIENCE DE SITUATION ET ALERTE ELECTRONIQUE (PHASE 2)
  Fusionne les contacts venus des stations radar FrenchNet et du radar du
  ballon, les identifie, et dit lesquels menacent le ballon. Aucune API du jeu :
  ce module est testable seul, et il doit l'etre - c'est lui qui decide qu'on
  crie « MISSILE ».

  - L'IFF est celui de FrenchNet Command, appele en BIBLIOTHEQUE (noyau.lua),
    pas en service reseau : il n'existe aucun protocole pour demander « qui est
    ce contact » au sol. Deux IFF separes divergeraient, et l'equipage verrait
    rouge la ou le sol voit vert.
  - Le rapprochement demande DEUX mesures espacees dans le temps. Avec une
    seule, il vaut nil et non zero : « je ne sais pas encore » n'est pas
    « il ne se rapproche pas », et c'est sur cette nuance que se decide un
    largage de leurres.
  - Une piste qu'on ne voit plus est PERIMEE puis oubliee. Elle n'est jamais
    declaree detruite : la destruction se confirme au sol, pas ici.
--------------------------------------------------------------------------------]]

local sa = { VERSION = "1.0.0" }

local atan2 = math.atan2 or math.atan   -- 5.1/5.2 : atan2 ; 5.3+ : atan(y, x)

local function nb(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Cap boussole lu par un equipage : 0 = nord (-Z), 90 = est (+X).
function sa.cap(dx, dz)
  if not (nb(dx) and nb(dz)) or (dx == 0 and dz == 0) then return nil end
  return (math.deg(atan2(dx, -dz)) + 360) % 360
end

function sa.distance(ax, ay, az, bx, by, bz)
  local dx, dy, dz = bx - ax, (by or 0) - (ay or 0), bz - az
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

sa.NIVEAUX_MENACE = { AUCUNE = 0, VEILLE = 1, ATTENTION = 2, IMMINENTE = 3 }
local NOM_MENACE = { [0] = "AUCUNE", "VEILLE", "ATTENTION", "IMMINENTE" }
sa.NOM_MENACE = NOM_MENACE

function sa.nouveau(config, noyau, journal)
  return setmetatable({
    config = config or {}, noyau = noyau, journal = journal or function() end,
    pistes = {},          -- [cle] = piste fusionnee
    transpondeurs = {},   -- [cle] = { code, recuA }
    stations = {},        -- [nom] = { x, y, z, portee, vuA }
    alliesManuels = {},   -- [cle] = true
    recues = 0, fusions = 0, perimees = 0,
  }, { __index = sa })
end

-- Cle de fusion : l'identifiant du contact s'il en a un, sinon son nom. Deux
-- stations qui voient le meme engin doivent produire UNE piste, sinon la carte
-- affiche deux menaces la ou il n'y en a qu'une et l'equipage double la riposte.
function sa.cleDe(contact)
  if type(contact.id) == "string" and contact.id ~= "" then return contact.id end
  if type(contact.nom) == "string" and contact.nom ~= "" then return "NOM:" .. contact.nom end
  if nb(contact.x) and nb(contact.z) then
    -- Dernier recours : une case de 4 blocs. Grossier, mais deux echos anonymes
    -- a 1 bloc l'un de l'autre sont le meme engin bien plus souvent que deux.
    return ("POS:%d:%d"):format(math.floor(contact.x / 4), math.floor(contact.z / 4))
  end
end

--[[
  Absorbe une trame FRENCHNET_RADAR (format releve, docs/api_notes.md 3.1).
  'source' distingue le radar du bord des stations au sol : un contact vu
  uniquement par le bord ne vaut pas confirmation au sol, et reciproquement.
  Retourne : contacts integres, contacts rejetes.
]]
function sa:integrerRadar(trame, maintenant, source)
  maintenant = maintenant or 0
  if type(trame) ~= "table" or type(trame.contacts) ~= "table" then return 0, 0 end
  self.recues = self.recues + 1

  local station = tostring(trame.station or source or "?")
  self.stations[station] = {
    x = trame.x, y = trame.y, z = trame.z,
    portee = trame.portee, vuA = maintenant, source = source or "SOL",
  }

  local integres, rejetes = 0, 0
  for _, contact in ipairs(trame.contacts) do
    local cle = nb(contact.x) and nb(contact.z) and sa.cleDe(contact)
    if not cle then
      rejetes = rejetes + 1
    else
      local piste = self.pistes[cle]
      if piste then
        self.fusions = self.fusions + 1
        -- Historique de distance conserve AVANT ecrasement : c'est lui qui
        -- donnera le rapprochement au prochain calcul.
        piste.xPrec, piste.zPrec, piste.yPrec = piste.x, piste.z, piste.y
        piste.vuPrecA = piste.vuA
      else
        piste = { cle = cle, stations = {} }
        self.pistes[cle] = piste
      end
      piste.id, piste.nom = contact.id, contact.nom
      piste.nature = contact.nature or piste.nature
      piste.meta = contact.meta or piste.meta
      piste.x, piste.y, piste.z = contact.x, contact.y, contact.z
      piste.vuA = maintenant
      piste.stations[station] = maintenant
      piste.source = source or piste.source or "SOL"
      integres = integres + 1
    end
  end
  return integres, rejetes
end

-- Codes transpondeur entendus. Le code est rattache a la piste par nom ou par
-- identifiant : c'est l'appariement que fait deja le poste au sol.
function sa:integrerTranspondeur(trame, maintenant)
  if type(trame) ~= "table" or type(trame.code) ~= "string" then return false end
  local nom = trame.identifiant or trame.nom
  if type(nom) ~= "string" or nom == "" then return false end
  self.transpondeurs[nom] = { code = trame.code, recuA = maintenant or 0,
                              x = trame.x, y = trame.y, z = trame.z }
  return true
end

function sa:transpondeurDe(piste)
  if piste.nom and self.transpondeurs[piste.nom] then return self.transpondeurs[piste.nom] end
  if piste.id and self.transpondeurs[piste.id] then return self.transpondeurs[piste.id] end
  -- Un identifiant "NOM:Raider-7" designe le meme engin que "Raider-7".
  if type(piste.id) == "string" then
    local court = piste.id:match("^NOM:(.+)$")
    if court and self.transpondeurs[court] then return self.transpondeurs[court] end
  end
end

-- Declaration manuelle d'allie : decision humaine, donc journalisee et
-- revocable. Elle prime sur le transpondeur (noyau.identifier le sait).
function sa:declarerAllie(cle, valeur)
  self.alliesManuels[cle] = valeur or nil
  self.journal("INFO", "sa", ("contact %s %s allie par l'equipage")
    :format(tostring(cle), valeur and "declare" or "n'est plus declare"))
end

-- Une piste qu'on ne voit plus est oubliee, jamais declaree detruite : la
-- confirmation de destruction se fait au sol, avec l'enveloppe fiable des
-- stations. Ici, ce serait un kill invente.
function sa:purger(maintenant)
  local duree = self.config.perimeSecondes or 12
  local oubliees = 0
  for cle, piste in pairs(self.pistes) do
    if (maintenant or 0) - (piste.vuA or 0) > duree then
      self.pistes[cle] = nil
      self.alliesManuels[cle] = nil
      oubliees = oubliees + 1
    end
  end
  self.perimees = self.perimees + oubliees
  return oubliees
end

--[[
  Menace d'une piste vis-a-vis du ballon.
  Le critere est le TEMPS AVANT CONTACT, pas la distance seule. Un engin a
  400 blocs qui fonce a 50 b/s est a huit secondes ; un engin a 250 blocs qui
  s'eloigne n'est a rien du tout. Classer par distance mettrait le second
  devant le premier, et l'equipage largerait ses leurres au mauvais moment.
  Un missile est traite a part : il n'a pas d'intention a deviner, seulement
  une trajectoire.
]]
function sa.tempsAvantContact(distance, rapprochement)
  if not (nb(distance) and nb(rapprochement)) or rapprochement <= 0 then return nil end
  return distance / rapprochement
end

function sa:niveauMenace(piste)
  local c = self.config
  if piste.iff == "ALLIE" or piste.allieManuel then
    return sa.NIVEAUX_MENACE.AUCUNE, "allie"
  end
  local d, v = piste.distance, piste.rapprochement
  local tac = sa.tempsAvantContact(d, v)
  local preavis = c.preavisSecondes or 20

  if piste.nature == "MISSILE" then
    if not nb(d) then return sa.NIVEAUX_MENACE.ATTENTION, "missile a distance inconnue" end
    -- Rapprochement inconnu : on ne peut pas exclure qu'il arrive. Pour un
    -- missile, le doute penche du cote de l'alerte.
    if (tac and tac <= preavis) or (v == nil and d <= (c.missileImminent or 200))
       or (nb(v) and v > 0 and d <= (c.missileImminent or 200)) then
      return sa.NIVEAUX_MENACE.IMMINENTE, ("missile a %.0f b%s"):format(d,
        tac and (", contact dans %.0fs"):format(tac) or "")
    end
    return sa.NIVEAUX_MENACE.ATTENTION, ("missile a %.0f b"):format(d)
  end

  if piste.iff == "GENERAL" then return sa.NIVEAUX_MENACE.VEILLE, "code general" end
  if not nb(d) then return sa.NIVEAUX_MENACE.VEILLE, "inconnu, distance indeterminee" end
  if tac and tac <= preavis then
    return sa.NIVEAUX_MENACE.ATTENTION,
      ("inconnu a %.0f b, contact dans %.0fs"):format(d, tac)
  end
  if d <= (c.menaceProche or 300) then
    return sa.NIVEAUX_MENACE.ATTENTION, ("inconnu a %.0f b"):format(d)
  end
  if d <= (c.menaceVeille or 800) then
    return sa.NIVEAUX_MENACE.VEILLE, ("inconnu a %.0f b"):format(d)
  end
  return sa.NIVEAUX_MENACE.AUCUNE, "hors de portee d'interet"
end

--[[
  Passe complete : geometrie, IFF, categorie, menace.
  'origine' = position du ballon. Retourne la liste des pistes (triee du plus
  menacant au moins menacant) et le niveau de menace le plus eleve.
]]
function sa:evaluer(origine, maintenant, codes, roster, zones)
  maintenant = maintenant or 0
  origine = origine or { x = 0, y = 64, z = 0 }
  local noyau, cfg = self.noyau, self.config
  local liste, pire, pirePiste = {}, sa.NIVEAUX_MENACE.AUCUNE, nil

  for cle, piste in pairs(self.pistes) do
    ------------------------------------------------------------------ geometrie
    if nb(piste.x) and nb(piste.z) then
      piste.distance = sa.distance(origine.x, origine.y, origine.z,
                                   piste.x, piste.y or origine.y, piste.z)
      piste.cap = sa.cap(piste.x - origine.x, piste.z - origine.z)
      piste.altitudeRelative = nb(piste.y) and (piste.y - (origine.y or 0)) or nil

      -- Rapprochement = variation de distance entre DEUX releves. Sans second
      -- releve, il reste nil : « pas encore mesure » n'est pas « stable ».
      piste.rapprochement = nil
      if nb(piste.xPrec) and nb(piste.zPrec) and nb(piste.vuPrecA)
         and piste.vuA and piste.vuA > piste.vuPrecA then
        local avant = sa.distance(origine.x, origine.y, origine.z,
                                  piste.xPrec, piste.yPrec or origine.y, piste.zPrec)
        piste.rapprochement = (avant - piste.distance) / (piste.vuA - piste.vuPrecA)
      end
    end

    ------------------------------------------------------------------------ IFF
    piste.allieManuel = self.alliesManuels[cle] or nil
    if noyau then
      local iff, motif, detail = noyau.identifier(piste, self:transpondeurDe(piste),
        codes or cfg.codes or {}, roster, maintenant, cfg, piste.allieManuel)
      piste.iff, piste.motifIff, piste.detailIff = iff, motif, detail
      -- Un code valide porte par un engin identifie hostile : transpondeur
      -- probablement capture. Le sol le journalise ; a bord, on le montre.
      if detail and detail.alerte and not piste.alerteDite then
        piste.alerteDite = true
        self.journal("AVERT", "sa", detail.alerte)
      end

      if zones then
        local classe = noyau.zonePourPoint(zones, piste.x or 0,
          piste.y or origine.y or 64, piste.z or 0)
        piste.classeZone = classe
      end
      local categorie = noyau.categoriser(piste, cfg, piste.classeZone, nil)
      piste.categorie = categorie
    end

    --------------------------------------------------------------------- menace
    local niveau, motif = self:niveauMenace(piste)
    piste.menace, piste.motifMenace = niveau, motif
    piste.menaceNom = NOM_MENACE[niveau]
    if niveau > pire then pire, pirePiste = niveau, piste end

    liste[#liste + 1] = piste
  end

  -- Tri : menace d'abord, distance ensuite. C'est l'ordre dans lequel un
  -- equipage veut lire une liste de contacts, pas l'ordre alphabetique.
  table.sort(liste, function(a, b)
    if a.menace ~= b.menace then return a.menace > b.menace end
    return (a.distance or math.huge) < (b.distance or math.huge)
  end)
  return liste, pire, pirePiste
end

function sa:resume()
  local pistes, stations = 0, 0
  for _ in pairs(self.pistes) do pistes = pistes + 1 end
  for _ in pairs(self.stations) do stations = stations + 1 end
  return pistes, stations, self.recues, self.perimees
end

return sa
