--[[----------------------------------------------------------------------------
  FRENCHNET / LIVRAISON - Protocole rednet commun
  --------------------------------------------------------------------------
  Un seul protocole rednet relie la borne de commande publique (accessible a
  tous les joueurs et a toutes les factions) et le ou les dirigeables :

      protocole rednet : "frenchnet_livraison"

  Tous les messages partagent la meme enveloppe :

      { protocole = "FRENCHNET_LIVRAISON", version = 1, type = <TYPE>, ... }

  TYPES emis par la BORNE :
    CATALOGUE_DEMANDE  la borne reclame le contenu du conteneur source
    COMMANDE           depot d'une commande complete
    ANNULATION         annulation d'une commande encore en file
    ETAT_DEMANDE       demande de l'etat courant du navire

  TYPES emis par le NAVIRE :
    CATALOGUE          contenu agrege du conteneur source (+ tarifs)
    ACCUSE             acceptation ou refus d'une commande
    ETAT               etat courant (phase, position, file, commande en cours)
    AVIS               evenement notable (paiement recu, livraison effectuee...)

  TYPES emis par l'ORDINATEUR CENTRAL :
    TARIF              grille de prix signee, diffusee a tous les ordinateurs
  et recus par lui :
    TARIF_DEMANDE      un navire ou une borne reclame la grille courante
--------------------------------------------------------------------------------]]

local M = {}

M.NOM       = "FRENCHNET_LIVRAISON"
M.VERSION   = 1
M.PROTOCOLE = "frenchnet_livraison"

M.TYPES = {
  CATALOGUE_DEMANDE = "CATALOGUE_DEMANDE",
  CATALOGUE         = "CATALOGUE",
  COMMANDE          = "COMMANDE",
  ACCUSE            = "ACCUSE",
  ANNULATION        = "ANNULATION",
  ETAT_DEMANDE      = "ETAT_DEMANDE",
  ETAT              = "ETAT",
  AVIS              = "AVIS",
  TARIF_DEMANDE     = "TARIF_DEMANDE",
  TARIF             = "TARIF",
}

-- Phases de mission du navire. Elles sont persistees sur disque : apres un
-- plantage, le programme reprend exactement la ou il s'etait arrete.
M.PHASES = {
  REPOS             = "REPOS",              -- au sol, en attente de commande
  CHARGEMENT        = "CHARGEMENT",         -- prelevement dans le conteneur source
  TRANSIT_ALLER     = "TRANSIT_ALLER",      -- vol vers le point de depot
  ATTENTE_PAIEMENT  = "ATTENTE_PAIEMENT",   -- verification du coffre de paiement
  DEPOT             = "DEPOT",              -- vidage de la soute chez le client
  TRANSIT_RETOUR    = "TRANSIT_RETOUR",     -- retour vers un point de securite
  RAVITAILLEMENT    = "RAVITAILLEMENT",     -- passage au point de ravitaillement
}

-- Niveaux de service proposes a la borne publique.
M.VITESSES = { RAPIDE = "fast", LENT = "slow" }

function M.enveloppe(type_, contenu)
  local msg = contenu or {}
  msg.protocole = M.NOM
  msg.version   = M.VERSION
  msg.type      = type_
  return msg
end

-- Verifie qu'un message recu vient bien du systeme et non d'un autre programme
-- qui partagerait le canal rednet.
function M.valide(msg, type_)
  if type(msg) ~= "table" then return false, "message non structure" end
  if msg.protocole ~= M.NOM then return false, "protocole inconnu" end
  if msg.version ~= M.VERSION then
    return false, ("version incompatible (recu %s, attendu %d)")
      :format(tostring(msg.version), M.VERSION)
  end
  if type_ and msg.type ~= type_ then return false, "type inattendu" end
  return true
end

--------------------------------------------------------------------------------
-- Validation d'une commande publique.
-- La borne est ouverte a tout le monde : un message peut arriver deforme,
-- tronque ou malveillant. Le navire n'accepte que ce qui passe ici.
--------------------------------------------------------------------------------
local function nombreEntier(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
     and math.floor(v) == v
end

function M.validerCommande(cmd, limites)
  limites = limites or {}
  local maxLignes   = limites.maxLignes   or 16
  local maxQuantite = limites.maxQuantite or 100000
  local maxPortee   = limites.maxPortee   or 100000

  if type(cmd) ~= "table" then return false, "commande non structuree" end
  if type(cmd.id) ~= "string" or #cmd.id == 0 or #cmd.id > 48 then
    return false, "identifiant de commande invalide"
  end
  if cmd.client ~= nil and (type(cmd.client) ~= "string" or #cmd.client > 48) then
    return false, "nom de client invalide"
  end
  if cmd.vitesse ~= M.VITESSES.RAPIDE and cmd.vitesse ~= M.VITESSES.LENT then
    return false, "niveau de vitesse inconnu (attendu fast ou slow)"
  end

  local d = cmd.destination
  if type(d) ~= "table" or not nombreEntier(d.x) or not nombreEntier(d.y)
     or not nombreEntier(d.z) then
    return false, "coordonnees de destination invalides"
  end
  if math.abs(d.x) > maxPortee or math.abs(d.z) > maxPortee then
    return false, "destination hors de la zone desservie"
  end
  if d.y < -128 or d.y > 1024 then
    return false, "altitude de depot hors limites"
  end

  if type(cmd.articles) ~= "table" or #cmd.articles == 0 then
    return false, "aucun article commande"
  end
  if #cmd.articles > maxLignes then
    return false, ("trop de lignes (%d, maximum %d)"):format(#cmd.articles, maxLignes)
  end

  local total = 0
  for i, article in ipairs(cmd.articles) do
    if type(article) ~= "table" then return false, "ligne " .. i .. " non structuree" end
    if type(article.nom) ~= "string" or #article.nom == 0 or #article.nom > 96 then
      return false, "nom d'objet invalide a la ligne " .. i
    end
    if not nombreEntier(article.quantite) or article.quantite <= 0 then
      return false, "quantite invalide a la ligne " .. i
    end
    if article.quantite > maxQuantite then
      return false, ("quantite excessive a la ligne %d (maximum %d)"):format(i, maxQuantite)
    end
    total = total + article.quantite
  end
  if total > maxQuantite then
    return false, ("volume total excessif (%d, maximum %d)"):format(total, maxQuantite)
  end

  if type(cmd.paiement) ~= "table" or type(cmd.paiement.objet) ~= "string"
     or not nombreEntier(cmd.paiement.quantite) or cmd.paiement.quantite < 0 then
    return false, "paiement invalide"
  end

  return true
end

--------------------------------------------------------------------------------
-- Tarification. Volontairement simple et entierement pilotee par la
-- configuration, pour que le prix affiche par la borne soit exactement celui
-- que le navire exigera a l'arrivee.
--------------------------------------------------------------------------------
function M.calculerPaiement(articles, vitesse, tarif)
  tarif = tarif or {}
  local parObjet     = tarif.parObjet or {}
  local defautUnite  = tarif.prixUnitaireDefaut or 0.01
  local forfait      = tarif.forfaitBase or 1
  local coefficients = tarif.coefficientVitesse or { fast = 2.0, slow = 1.0 }

  local brut = forfait
  for _, article in ipairs(articles or {}) do
    local unitaire = parObjet[article.nom] or defautUnite
    brut = brut + unitaire * (article.quantite or 0)
  end

  local coef = coefficients[vitesse] or 1.0
  local quantite = math.ceil(brut * coef)
  if tarif.prixMinimum and quantite < tarif.prixMinimum then
    quantite = tarif.prixMinimum
  end
  if tarif.prixMaximum and quantite > tarif.prixMaximum then
    quantite = tarif.prixMaximum
  end

  return { objet = tarif.objetPaiement or "minecraft:diamond", quantite = quantite }
end

--------------------------------------------------------------------------------
-- GRILLE TARIFAIRE CENTRALISEE
--------------------------------------------------------------------------------
-- L'ordinateur central diffuse la grille ; navires et bornes l'appliquent.
--
-- CE QUE CETTE SIGNATURE FAIT, ET CE QU'ELLE NE FAIT PAS.
-- rednet n'authentifie personne : n'importe qui peut emettre sur le protocole.
-- Le jeton partage et l'empreinte ci-dessous empechent une trame malformee,
-- une erreur de configuration et le rejeu d'une vieille grille moins chere.
-- Ce n'est PAS de la cryptographie : quelqu'un qui lit le fichier de
-- configuration d'une borne connait le jeton et peut forger une grille. La
-- protection reelle reste de ne pas laisser un joueur ouvrir l'ordinateur.
--------------------------------------------------------------------------------

-- Empreinte 64 bits, deux accumulateurs polynomiaux modulo 2^32.
-- VOLONTAIREMENT SANS OPERATEUR BINAIRE : ni ~, ni >>, ni <<, qui n'existent
-- qu'a partir de Lua 5.3, alors que CC: Tweaked tourne sur Cobalt (Lua 5.2).
-- Les produits restent sous 2^37, tres en deca des 2^53 exacts d'un flottant
-- double : le resultat est donc identique sur toutes les versions.
function M.empreinte(texte)
  texte = tostring(texte)
  local h1, h2 = 5381, 52711
  for i = 1, #texte do
    local octet = texte:byte(i)
    h1 = (h1 * 33 + octet) % 4294967296
    h2 = (h2 * 31 + octet * (i % 251 + 1)) % 4294967296
  end
  return string.format("%08x%08x", math.floor(h1), math.floor(h2))
end

-- Rend une table sous une forme stable, independante de l'ordre de pairs().
local function canoniser(valeur)
  if type(valeur) ~= "table" then return tostring(valeur) end
  local cles = {}
  for cle in pairs(valeur) do cles[#cles + 1] = tostring(cle) end
  table.sort(cles)
  local morceaux = {}
  for _, cle in ipairs(cles) do
    local sous = valeur[cle]
    if sous == nil then sous = valeur[tonumber(cle)] end
    morceaux[#morceaux + 1] = cle .. "=" .. canoniser(sous)
  end
  return "{" .. table.concat(morceaux, ",") .. "}"
end
M.canoniser = canoniser

function M.signerTarif(tarif, sequence, jeton)
  return M.empreinte(canoniser(tarif) .. "|" .. tostring(sequence) .. "|" .. tostring(jeton))
end

-- Verifie une grille recue. 'sequenceConnue' est la derniere acceptee : une
-- grille plus ancienne est rejetee, pour qu'on ne puisse pas rejouer d'anciens
-- prix apres une hausse.
function M.verifierTarif(message, jeton, sequenceConnue)
  if type(message) ~= "table" or type(message.tarif) ~= "table" then
    return false, "grille absente ou non structuree"
  end
  if type(message.sequence) ~= "number" then
    return false, "numero de sequence absent"
  end
  if sequenceConnue and message.sequence < sequenceConnue then
    return false, ("grille perimee (sequence %d, deja vu %d)")
      :format(message.sequence, sequenceConnue)
  end
  if jeton and jeton ~= "" then
    local attendue = M.signerTarif(message.tarif, message.sequence, jeton)
    if message.signature ~= attendue then
      return false, "signature invalide : jeton different ou grille alteree"
    end
  end
  return true
end

--------------------------------------------------------------------------------
-- PENALITES
--    Un client qui laisse un navire attendre puis repartir sans payer est
--    marque. Selon le mode, ses commandes suivantes exigent un pre-paiement a
--    la borne, ou sont refusees jusqu'a expiration.
--------------------------------------------------------------------------------

M.MODES_PENALITE = { PREPAIEMENT = "prepaiement", REFUS = "refus" }

-- Retourne : active (booleen), reste (secondes), fiche
function M.penaliteActive(penalites, client, maintenantMs)
  if type(penalites) ~= "table" or type(client) ~= "string" or client == "" then
    return false, 0, nil
  end
  local fiche = penalites[client]
  if type(fiche) ~= "table" or type(fiche.jusqua) ~= "number" then return false, 0, nil end
  local reste = (fiche.jusqua - (maintenantMs or 0)) / 1000
  if reste <= 0 then return false, 0, fiche end
  return true, reste, fiche
end

function M.signerPrepaiement(commandeId, paiement, jeton)
  return M.empreinte(tostring(commandeId) .. "|" .. canoniser(paiement)
    .. "|" .. tostring(jeton))
end

function M.distance(a, b)
  if not a or not b then return math.huge end
  local dx, dy, dz = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0), (a.z or 0) - (b.z or 0)
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

return M
