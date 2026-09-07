--[[----------------------------------------------------------------------------
  FRENCHNET / AERONAUTICS WARFARE - Adaptateur vers le module d'autopilote
  --------------------------------------------------------------------------
  CE MODULE NE CONTIENT AUCUNE LOI DE PILOTAGE.

  Il ne fait que trois choses :
    1. charger le module d'autopilote STANDARDISE deja construit (sections 6
       et 7 de la documentation vehicule) ;
    2. normaliser son API, car les noms de fonctions peuvent varier d'une
       revision a l'autre, et journaliser la correspondance retenue ;
    3. lui transmettre le bloc 'autopilote' du fichier de configuration
       vehicule - le MEME fichier que celui du navire, comme prevu.

  L'asservissement en cascade, le PID en controle principal et le repli
  automatique en mode dead-band restent integralement dans le module
  d'autopilote. Le systeme d'interception se contente de lui fournir un point
  de consigne et une vitesse a tenir, et de lire en retour la telemetrie.

  REFUS DELIBERE : si le module d'autopilote est introuvable, le navire NE
  DECOLLE PAS. Voler avec un controleur de substitution serait plus dangereux
  que de rester au sol. Le repli 'autopiloteDeSecours' existe uniquement pour
  les bancs d'essai et doit rester a false en production.

  Chargement : local noyau = ...
--------------------------------------------------------------------------------]]

local noyau = ...
local E = noyau.ETAPES
local journal = noyau.journal

local M = {}

--------------------------------------------------------------------------------
-- 1. CONTRAT D'INTERFACE
--    Chaque entree decrit une capacite attendue du module d'autopilote, la
--    liste des noms de fonctions acceptes, et son caractere obligatoire.
--    Ajouter un nom ici suffit a s'adapter a une revision differente : aucune
--    autre ligne du systeme d'interception n'est a modifier.
--------------------------------------------------------------------------------

M.CONTRAT = {
  { role = "demarrer",       obligatoire = false,
    candidats = { "demarrer", "initialiser", "init", "start", "begin" },
    description = "initialisation de l'autopilote avec la configuration vehicule" },

  { role = "definirPoint",   obligatoire = true,
    candidats = { "definirPoint", "definirConsigne", "allerA", "viser",
                  "setTarget", "setSetpoint", "goTo", "definirCible" },
    description = "point de consigne (x, y, z) suivi par l'asservissement en cascade" },

  { role = "definirVitesse", obligatoire = false,
    candidats = { "definirVitesse", "reglerVitesse", "setSpeed", "setVitesse",
                  "definirVitesseCible" },
    description = "vitesse a tenir (b/s), transmise a la boucle externe" },

  { role = "definirCap",     obligatoire = false,
    candidats = { "definirCap", "reglerCap", "setYaw", "setHeading", "definirLacet" },
    description = "cap impose (deg), utilise pour presenter l'arme a la cible" },

  { role = "position",       obligatoire = true,
    candidats = { "position", "obtenirPosition", "getPosition", "getPos", "pos" },
    description = "position courante du navire" },

  { role = "vitesse",        obligatoire = false,
    candidats = { "vitesse", "obtenirVitesse", "getVelocity", "getVitesse", "vel" },
    description = "vecteur vitesse courant du navire" },

  { role = "mode",           obligatoire = false,
    candidats = { "mode", "obtenirMode", "getMode", "modeActif" },
    description = "mode de controle actif : PID ou dead-band" },

  { role = "stationnaire",   obligatoire = false,
    candidats = { "stationnaire", "maintenir", "hold", "station", "faireDuSurPlace" },
    description = "maintien de position sur place" },

  { role = "arreter",        obligatoire = false,
    candidats = { "arreter", "stopper", "stop", "halt", "couper" },
    description = "arret propre de l'autopilote" },

  { role = "actualiser",     obligatoire = false,
    candidats = { "actualiser", "cycle", "tick", "update", "pas" },
    description = "cycle de calcul, si l'autopilote n'a pas sa propre boucle" },
}

--------------------------------------------------------------------------------
-- 2. CHARGEMENT DU MODULE EXTERNE
--------------------------------------------------------------------------------

local function cheminsCandidats(config)
  local liste = {}
  if type(config.cheminAutopilote) == "string" and config.cheminAutopilote ~= "" then
    liste[#liste + 1] = config.cheminAutopilote
  end
  -- Emplacements usuels d'un module partage entre plusieurs vehicules.
  liste[#liste + 1] = "/autopilote/autopilote.lua"
  liste[#liste + 1] = "/autopilote/api.lua"
  liste[#liste + 1] = "/autopilote.lua"
  liste[#liste + 1] = fs.combine(noyau.REPERTOIRE, "autopilote_vehicule.lua")
  liste[#liste + 1] = "/lib/autopilote.lua"
  return liste
end

local function chargerFichier(chemin, config)
  local fichier = fs.open(chemin, "r")
  if not fichier then
    error("lecture impossible : " .. chemin, 0)
  end
  local source = fichier.readAll()
  fichier.close()

  local morceau, err = load(source, "@" .. chemin, "t", _G)
  if not morceau then
    error("module d'autopilote illisible (" .. chemin .. ") : " .. tostring(err), 0)
  end
  -- On transmet la configuration en argument de chunk ET via demarrer() : les
  -- deux conventions existent, l'une ou l'autre sera honoree.
  local resultat = morceau(config)
  if type(resultat) ~= "table" then
    error("le module d'autopilote (" .. chemin .. ") doit renvoyer une table", 0)
  end
  return resultat
end

--------------------------------------------------------------------------------
-- 3. AUTOPILOTE DE SECOURS (BANCS D'ESSAI UNIQUEMENT)
--    Ce n'est PAS un controleur de vol. Il se contente de memoriser les
--    consignes recues et de rapporter une position, afin que la machine a
--    etats du navire puisse etre testee hors du jeu. Toute utilisation en
--    production est journalisee en CRITIQUE a chaque demarrage.
--------------------------------------------------------------------------------

local function autopiloteDeSecours()
  local etat = {
    point = { x = 0, y = 0, z = 0 },
    vitesse = 0,
    cap = 0,
    position = { x = 0, y = 0, z = 0 },
    vecteurVitesse = { x = 0, y = 0, z = 0 },
  }
  return {
    __secours = true,
    __etat = etat,
    demarrer = function() return true end,
    definirPoint = function(x, y, z) etat.point = { x = x, y = y, z = z } end,
    definirVitesse = function(v) etat.vitesse = v end,
    definirCap = function(c) etat.cap = c end,
    position = function() return etat.position.x, etat.position.y, etat.position.z end,
    vitesse = function()
      return etat.vecteurVitesse.x, etat.vecteurVitesse.y, etat.vecteurVitesse.z
    end,
    mode = function() return "SECOURS" end,
    stationnaire = function() etat.vitesse = 0 end,
    arreter = function() etat.vitesse = 0 end,
  }
end

--------------------------------------------------------------------------------
-- 4. NORMALISATION
--------------------------------------------------------------------------------

--- Lit un triplet de coordonnees quelle que soit la forme rendue par
-- l'autopilote : trois valeurs, une table {x,y,z} ou une table {[1],[2],[3]}.
local function lireVecteur(...)
  local a, b, c = ...
  if type(a) == "table" then
    if noyau.nombreValide(a.x) then return { x = a.x, y = a.y or 0, z = a.z or 0 } end
    if noyau.nombreValide(a[1]) then return { x = a[1], y = a[2] or 0, z = a[3] or 0 } end
    return nil
  end
  if noyau.nombreValide(a) and noyau.nombreValide(b) and noyau.nombreValide(c) then
    return { x = a, y = b, z = c }
  end
  return nil
end

--------------------------------------------------------------------------------
-- 5. LIAISON
--------------------------------------------------------------------------------

--- Etablit la liaison avec le module d'autopilote et renvoie une facade
-- normalisee. Leve une erreur explicite si le module est introuvable.
-- @param config configuration complete du vehicule
-- @return facade
function M.lier(config)
  local module, cheminRetenu, essais = nil, nil, {}

  for _, chemin in ipairs(cheminsCandidats(config)) do
    if fs.exists(chemin) then
      local ok, resultat = pcall(chargerFichier, chemin, config.autopilote or {})
      if ok then
        module, cheminRetenu = resultat, chemin
        break
      end
      essais[#essais + 1] = chemin .. " (" .. tostring(resultat) .. ")"
    else
      essais[#essais + 1] = chemin .. " (absent)"
    end
  end

  if not module then
    if config.autopiloteDeSecours then
      journal.critique(E.LIAISON_AUTOPILOTE,
        "AUTOPILOTE DE SECOURS ACTIF : aucune loi de pilotage reelle n'est "
        .. "chargee. Ce mode est reserve aux bancs d'essai. Emplacements "
        .. "explores : " .. table.concat(essais, " | "))
      module, cheminRetenu = autopiloteDeSecours(), "(secours interne)"
    else
      error("module d'autopilote standardise introuvable. Le navire ne decolle pas. "
        .. "Renseignez 'cheminAutopilote' dans config_intercepteur.lua. "
        .. "Emplacements explores : " .. table.concat(essais, " | "), 0)
    end
  end

  ------------------------------------------------------------------ resolution
  local lien, correspondances, manquants = {}, {}, {}
  for _, entree in ipairs(M.CONTRAT) do
    local fn, nom = noyau.resoudreMethode(module, entree.candidats)
    if fn then
      lien[entree.role] = fn
      correspondances[#correspondances + 1] = entree.role .. " -> " .. nom .. "()"
    elseif entree.obligatoire then
      manquants[#manquants + 1] = entree.role .. " (" .. entree.description
        .. " ; noms acceptes : " .. table.concat(entree.candidats, ", ") .. ")"
    end
  end

  if #manquants > 0 then
    error("le module d'autopilote charge depuis " .. tostring(cheminRetenu)
      .. " n'expose pas les capacites obligatoires suivantes : "
      .. table.concat(manquants, " | "), 0)
  end

  journal.info(E.LIAISON_AUTOPILOTE, "module d'autopilote charge depuis "
    .. tostring(cheminRetenu))
  -- La correspondance retenue est journalisee : en cas de comportement de vol
  -- anormal, elle dit immediatement quelle fonction a reellement ete appelee.
  journal.info(E.LIAISON_AUTOPILOTE, "correspondance d'API : "
    .. table.concat(correspondances, ", "))

  ---------------------------------------------------------------------- facade
  local facade = {
    module     = module,
    chemin     = cheminRetenu,
    secours    = module.__secours == true,
    modePrecedent = nil,
    dernierPoint  = nil,
    derniereVitesse = nil,
  }

  --- Initialisation. Le bloc 'autopilote' du fichier de configuration vehicule
  -- lui est transmis tel quel : un seul fichier de configuration par vehicule,
  -- partage entre l'autopilote et le systeme d'interception.
  function facade.demarrer()
    if not lien.demarrer then return false end
    return noyau.proteger(E.LIAISON_AUTOPILOTE, lien.demarrer, config.autopilote or {})
  end

  --- Point de consigne. C'est LA commande de vol du systeme d'interception :
  -- tout le reste (cascade, PID, dead-band) appartient a l'autopilote.
  function facade.definirPoint(point, motif)
    facade.dernierPoint = point
    local ok = noyau.proteger(E.COMMANDE_AUTOPILOTE, lien.definirPoint,
      point.x, point.y, point.z)
    if ok then
      journal.limite("consigne_point", 2, "DEBUG", E.COMMANDE_AUTOPILOTE,
        string.format("consigne %s%s", noyau.vec.format(point),
          motif and (" | " .. motif) or ""))
    end
    return ok
  end

  function facade.definirVitesse(v)
    if not lien.definirVitesse then return false end
    facade.derniereVitesse = v
    return noyau.proteger(E.COMMANDE_AUTOPILOTE, lien.definirVitesse, v)
  end

  function facade.definirCap(capDeg)
    if not lien.definirCap then return false end
    return noyau.proteger(E.COMMANDE_AUTOPILOTE, lien.definirCap, capDeg)
  end

  function facade.stationnaire()
    if lien.stationnaire then
      return noyau.proteger(E.COMMANDE_AUTOPILOTE, lien.stationnaire)
    end
    -- Repli : consigne sur la position courante, vitesse nulle.
    local p = facade.position()
    if p then facade.definirPoint(p, "maintien de position") end
    facade.definirVitesse(0)
    return true
  end

  function facade.arreter()
    if not lien.arreter then return false end
    return noyau.proteger(E.COMMANDE_AUTOPILOTE, lien.arreter)
  end

  function facade.actualiser()
    if not lien.actualiser then return false end
    return noyau.proteger(E.COMMANDE_AUTOPILOTE, lien.actualiser)
  end

  --- Position courante du navire. nil si l'autopilote ne repond pas : la
  -- machine a etats sait traiter ce cas (elle gele les commandes).
  function facade.position()
    local ok, a, b, c = noyau.proteger(E.COMMANDE_AUTOPILOTE, lien.position)
    if not ok then return nil end
    return lireVecteur(a, b, c)
  end

  function facade.vitesse()
    if not lien.vitesse then return nil end
    local ok, a, b, c = noyau.proteger(E.COMMANDE_AUTOPILOTE, lien.vitesse)
    if not ok then return nil end
    return lireVecteur(a, b, c)
  end

  --- Mode de controle actif. Le basculement PID -> dead-band est decide par
  -- l'autopilote lui-meme ; on se contente de le tracer, car c'est un signal
  -- precieux pour expliquer une trajectoire degradee apres coup.
  function facade.mode()
    if not lien.mode then return nil end
    local ok, valeur = noyau.proteger(E.MODE_AUTOPILOTE, lien.mode)
    if not ok then return nil end
    local texte = tostring(valeur)
    if texte ~= facade.modePrecedent then
      if facade.modePrecedent ~= nil then
        journal.avert(E.MODE_AUTOPILOTE, string.format(
          "l'autopilote est passe du mode '%s' au mode '%s'",
          facade.modePrecedent, texte))
      else
        journal.info(E.MODE_AUTOPILOTE, "mode de controle initial : " .. texte)
      end
      facade.modePrecedent = texte
    end
    return texte
  end

  return facade
end

return M
