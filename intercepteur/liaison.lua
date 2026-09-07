--[[----------------------------------------------------------------------------
  FRENCHNET / AERONAUTICS WARFARE - Liaison avec le systeme au sol
  --------------------------------------------------------------------------
  Le navire n'accepte QUE DEUX ordres :

      SCRAMBLE : decoller et intercepter la cible designee, avec sa position.
      FEU      : ouvrir le feu sur cette meme cible.

  Tout le reste est rejete et journalise. En particulier, le navire n'a
  AUCUNE connaissance des zones ni des classes Charlie, Bravo, Alpha ou
  Romeo : ces notions appartiennent exclusivement au systeme de defense au
  sol. Si un ordre en contient malgre tout, les champs concernes sont
  supprimes avant traitement et le fait est journalise en AVERT - c'est le
  signe d'un couplage en train de se reintroduire entre les deux systemes,
  et il vaut mieux le voir tout de suite dans le journal.

  Le navire ne demande jamais de mise a jour de position au sol : une fois
  l'ordre recu, le suivi est assure par le radar embarque.

  Chargement : local noyau = ...
--------------------------------------------------------------------------------]]

local noyau = ...
local E = noyau.ETAPES
local journal = noyau.journal

local M = {}

M.PROTOCOLE_ORDRE   = "FRENCHNET_ORDRE"
M.VERSION_PROTOCOLE = 1

--- Les DEUX seuls types d'ordre reconnus. Toute extension de cette liste
-- reintroduit une dependance envers le systeme au sol : y reflechir a deux
-- fois avant d'y toucher.
M.TYPES_ACCEPTES = { SCRAMBLE = true, FEU = true }

--- Champs relevant de la doctrine sol, que le navire ne doit jamais lire.
M.CHAMPS_INTERDITS = {
  "zone", "zones", "secteur", "secteurs", "classe", "class", "classification",
  "categorie", "niveauAlerte", "priorite", "doctrine", "regleEngagement",
  "charlie", "bravo", "alpha", "romeo",
}

--------------------------------------------------------------------------------
-- 1. DETECTION DU MODEM ET OUVERTURE DE REDNET
--------------------------------------------------------------------------------

local function estModemEnder(nom)
  if peripheral.hasType then
    local ok, resultat = pcall(peripheral.hasType, nom, "ender_modem")
    if ok and resultat then return true end
  end
  local ok, typePeripherique = pcall(peripheral.getType, nom)
  return ok and type(typePeripherique) == "string"
     and typePeripherique:find("ender", 1, true) ~= nil
end

--- @return cote, modem, ender (booleen)
function M.detecterModem(config)
  if type(config.coteModem) == "string" and config.coteModem ~= "" then
    if not peripheral.isPresent(config.coteModem) then
      error("aucun peripherique sur le cote modem impose '" .. config.coteModem .. "'", 0)
    end
    return config.coteModem, peripheral.wrap(config.coteModem),
      estModemEnder(config.coteModem)
  end

  local repliCote, repliModem
  for _, nom in ipairs(peripheral.getNames()) do
    local ok, typePeripherique = pcall(peripheral.getType, nom)
    if ok and typePeripherique == "modem" then
      local modem = peripheral.wrap(nom)
      local sansFil = false
      if modem and modem.isWireless then
        local okFil, resultat = pcall(modem.isWireless)
        sansFil = okFil and resultat
      end
      if sansFil then
        if estModemEnder(nom) then return nom, modem, true end
        repliCote, repliModem = repliCote or nom, repliModem or modem
      end
    end
  end

  if repliModem then return repliCote, repliModem, false end
  error("aucun modem sans fil detecte : le navire ne peut pas recevoir d'ordre. "
    .. "Un modem Ender est requis pour une portee illimitee.", 0)
end

function M.ouvrir(config)
  local cote, modem, ender = M.detecterModem(config)

  if ender then
    journal.info(E.DETECTION_MODEM, "modem Ender sur '" .. cote .. "' : portee illimitee")
  else
    journal.avert(E.DETECTION_MODEM, "modem sans fil sur '" .. cote
      .. "' mais il ne semble PAS etre un modem Ender : les ordres de scramble "
      .. "ne parviendront au navire que s'il reste a portee du sol")
  end

  if not rednet.isOpen(cote) then rednet.open(cote) end
  if not rednet.isOpen(cote) then
    error("rednet.open a echoue silencieusement sur '" .. cote .. "'", 0)
  end
  journal.info(E.OUVERTURE_REDNET, "rednet ouvert, protocole '"
    .. (config.protocoleRednet or "frenchnet_ordre") .. "'")

  return cote, modem, ender
end

--------------------------------------------------------------------------------
-- 2. VALIDATION D'UN ORDRE
--------------------------------------------------------------------------------

local function retirerChampsSolAvecTrace(message, identifiantOrdre)
  local retires = {}
  for _, champ in ipairs(M.CHAMPS_INTERDITS) do
    if message[champ] ~= nil then
      retires[#retires + 1] = champ
      message[champ] = nil
    end
  end
  if #retires > 0 then
    journal.avert(E.RECEPTION_ORDRE, string.format(
      "ordre %s : champ(s) de doctrine sol ignore(s) [%s]. Le navire n'a aucune "
      .. "connaissance des zones ni des classes ; ces champs relevent "
      .. "exclusivement du systeme de defense au sol.",
      identifiantOrdre or "?", table.concat(retires, ", ")))
  end
  return message
end

--- Valide un message recu.
-- @return ordre (table normalisee) | nil, motifRejet
function M.valider(expediteur, message, config)
  if type(message) ~= "table" then
    return nil, "message non structure"
  end
  if message.protocole ~= M.PROTOCOLE_ORDRE then
    return nil, "protocole '" .. tostring(message.protocole) .. "' inconnu"
  end

  local type_ = tostring(message.type or ""):upper()
  if not M.TYPES_ACCEPTES[type_] then
    return nil, "type d'ordre '" .. type_ .. "' non reconnu (seuls SCRAMBLE et FEU "
      .. "sont acceptes par un navire intercepteur)"
  end

  -- Destinataire : un ordre sans destinataire s'adresse a tous les navires.
  local destinataire = message.destinataire
  if destinataire ~= nil and tostring(destinataire) ~= tostring(config.identifiant) then
    return nil, "ordre destine a '" .. tostring(destinataire) .. "'"
  end

  -- Expediteur : filtre optionnel, utile si plusieurs reseaux coexistent.
  if config.expediteursAutorises then
    local autorise = false
    for _, id in ipairs(config.expediteursAutorises) do
      if tonumber(id) == tonumber(expediteur) then autorise = true break end
    end
    if not autorise then
      return nil, "expediteur #" .. tostring(expediteur) .. " non autorise"
    end
  end

  local identifiantOrdre = tostring(message.identifiantOrdre or ("auto-" .. tostring(expediteur)))
  retirerChampsSolAvecTrace(message, identifiantOrdre)

  local ordre = {
    type             = type_,
    expediteur       = expediteur,
    identifiantOrdre = identifiantOrdre,
    recuA            = noyau.maintenant(),
    cible            = nil,
  }

  -- La position de cible est obligatoire pour un SCRAMBLE : c'est la seule
  -- information dont le navire a besoin pour partir. Elle est facultative sur
  -- un FEU (le radar embarque a deja la piste), mais acceptee comme
  -- rafraichissement si elle est fournie.
  local cible = message.cible or message.target
  if type(cible) == "table" and noyau.nombreValide(cible.x)
     and noyau.nombreValide(cible.y) and noyau.nombreValide(cible.z) then
    ordre.cible = { x = cible.x, y = cible.y, z = cible.z }
    if noyau.nombreValide(cible.vx) then
      ordre.vitesseCible = { x = cible.vx, y = cible.vy or 0, z = cible.vz or 0 }
    end
  elseif type_ == "SCRAMBLE" then
    return nil, "ordre SCRAMBLE sans position de cible exploitable "
      .. "{ cible = { x = , y = , z = } }"
  end

  return ordre
end

--------------------------------------------------------------------------------
-- 3. RECEPTION
--------------------------------------------------------------------------------

--- Attend un ordre valide. Renvoie nil a l'expiration du delai.
function M.recevoir(config, delai)
  local ok, expediteur, message = noyau.proteger(E.RECEPTION_ORDRE, function()
    return rednet.receive(config.protocoleRednet or "frenchnet_ordre", delai)
  end)
  if not ok or not expediteur then return nil end

  local ordre, motif = M.valider(expediteur, message, config)
  if not ordre then
    journal.limite("rejet_" .. tostring(motif):sub(1, 24), 5, "AVERT", E.ORDRE_REJETE,
      string.format("ordre rejete (expediteur #%s) : %s", tostring(expediteur), motif))
    return nil
  end

  if ordre.type == "SCRAMBLE" then
    journal.info(E.RECEPTION_ORDRE, string.format(
      "ORDRE DE SCRAMBLE %s recu du poste #%d | cible designee %s%s",
      ordre.identifiantOrdre, expediteur, noyau.vec.format(ordre.cible),
      ordre.vitesseCible and string.format(" | vitesse annoncee %.1f b/s",
        noyau.vec.norme(ordre.vitesseCible)) or ""))
  else
    journal.info(E.RECEPTION_ORDRE, string.format(
      "ORDRE DE FEU %s recu du poste #%d%s",
      ordre.identifiantOrdre, expediteur,
      ordre.cible and (" | position de cible rafraichie " .. noyau.vec.format(ordre.cible)) or ""))
  end

  return ordre
end

--------------------------------------------------------------------------------
-- 4. ACCUSE DE RECEPTION
--    Purement informatif pour le sol. N'introduit aucune dependance : le
--    navire n'attend jamais de reponse et ne modifie jamais son comportement
--    en fonction de ce qu'il envoie.
--------------------------------------------------------------------------------

function M.accuser(config, ordre, etat, precision)
  if not config.accuserReception then return end
  noyau.proteger(E.ACCUSE_RECEPTION, function()
    rednet.send(ordre.expediteur, {
      protocole        = "FRENCHNET_ACCUSE",
      version          = M.VERSION_PROTOCOLE,
      identifiant      = config.identifiant,
      identifiantOrdre = ordre.identifiantOrdre,
      type             = ordre.type,
      etat             = etat,
      precision        = precision,
      horodatageUtc    = (function()
        local ok, v = pcall(os.epoch, "utc")
        return ok and v or nil
      end)(),
    }, config.protocoleRednet or "frenchnet_ordre")
  end)
end

--- Compte rendu de fin de mission (destruction confirmee, retour base...).
function M.rendreCompte(config, sujet, detail)
  if not config.accuserReception then return end
  if not config.posteDeCommandement then return end
  noyau.proteger(E.ACCUSE_RECEPTION, function()
    rednet.send(config.posteDeCommandement, {
      protocole     = "FRENCHNET_COMPTE_RENDU",
      version       = M.VERSION_PROTOCOLE,
      identifiant   = config.identifiant,
      sujet         = sujet,
      detail        = detail,
      horodatageUtc = (function()
        local ok, v = pcall(os.epoch, "utc")
        return ok and v or nil
      end)(),
    }, config.protocoleRednet or "frenchnet_ordre")
  end)
end

return M
