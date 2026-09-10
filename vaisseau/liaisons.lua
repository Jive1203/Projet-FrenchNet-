--[[----------------------------------------------------------------------------
  DOOMSDAY SHIP - COUTURE D'INTEGRATION AVEC LES MODULES EXTERIEURS
  --------------------------------------------------------------------------
  Point de contact UNIQUE avec l'autopilote, le Fire Control embarque et l'ADS.

  POURQUOI CE FICHIER EXISTE
  Au moment ou il est ecrit, AUCUN de ces trois modules n'est present dans le
  depot - verifie branche par branche, voir docs/api_notes.md. Ecrire des
  appels a des fonctions dont j'ignore le nom produirait un systeme qui a l'air
  de marcher jusqu'au premier vol.

  Toute integration passe donc par ici, et par ici seulement :
    - si le module est present, on l'appelle ;
    - s'il est absent, on le DIT, une fois, clairement, et l'appel echoue avec
      un motif lisible. Aucune simulation, aucun bouchon qui rendrait « ok ».

  Le jour ou l'autopilote arrive, il y a exactement un fichier a modifier, et
  la fonction a ecrire est nommee dans le rapport ci-dessous.
--------------------------------------------------------------------------------]]

local liaisons = { VERSION = "1.0.0" }

--[[
  'fonctions' liste les fonctions que le systeme du ballon ATTEND de chaque
  module. Elles ne sont pas inventees a partir de rien : ce sont les besoins
  reels des pages. Quand le vrai module arrivera, il suffira de constater
  lesquelles il expose et d'adapter la table 'correspondances' de la
  configuration.
]]
liaisons.MODULES = {
  autopilote = {
    chemin  = "/vaisseau/autopilote.lua",
    role    = "tenue de cap, suivi de route, envoi de waypoints",
    besoins = { "definirRoute", "etat", "engager", "desengager" },
    pages   = { "navigation" },
  },
  fireControl = {
    chemin  = "/vaisseau/fire_control.lua",
    role    = "selection d'arme et execution du tir (AAA, MS-GA, ML-GA, M-GG, Artillery)",
    besoins = { "armes", "engager", "securiser", "munitions" },
    pages   = { "armement" },
  },
  ads = {
    chemin  = "/vaisseau/ads.lua",
    role    = "contre-mesures : chaffs et flares",
    besoins = { "stock", "larguer", "etat" },
    pages   = { "ew" },
  },
}

function liaisons.nouveau(config, journal, chargeur)
  return setmetatable({
    config   = config or {},
    journal  = journal or function() end,
    -- 'chargeur' injectable pour les tests ; loadfile en jeu.
    chargeur = chargeur or loadfile,
    modules  = {},
    absents  = {},
    signale  = {},
    appels   = 0,
    refus    = 0,
  }, { __index = liaisons })
end

--------------------------------------------------------------------------------
-- Chargement : une tentative par module, au demarrage. Le resultat est fige :
-- un module qui apparait en cours de vol ne sera pris qu'au prochain
-- demarrage, ce qui evite un rechargement a chaud pendant un engagement.
--------------------------------------------------------------------------------

function liaisons:charger()
  local presents, manquants = 0, 0

  for nom, description in pairs(liaisons.MODULES) do
    local chemin = (self.config.chemins or {})[nom] or description.chemin
    local charge = self.chargeur(chemin)
    local module

    if charge then
      local ok, resultat = pcall(charge)
      if ok and type(resultat) == "table" then module = resultat end
    end

    if module then
      -- Presence ne vaut pas conformite : on verifie que les fonctions dont
      -- les pages ont besoin sont bien la, et on nomme celles qui manquent.
      local absentes = {}
      for _, besoin in ipairs(description.besoins) do
        if type(module[besoin]) ~= "function" then absentes[#absentes + 1] = besoin end
      end
      self.modules[nom] = module
      presents = presents + 1
      if #absentes > 0 then
        self.journal("AVERT", "liaisons", string.format(
          "module '%s' charge depuis %s mais il n'expose pas : %s. Les pages %s " ..
          "resteront partiellement inertes.",
          nom, chemin, table.concat(absentes, ", "),
          table.concat(description.pages, ", ")))
      else
        self.journal("INFO", "liaisons", string.format(
          "module '%s' charge depuis %s : %s", nom, chemin, description.role))
      end
    else
      manquants = manquants + 1
      self.absents[nom] = chemin
      self.journal("AVERT", "liaisons", string.format(
        "module '%s' ABSENT (%s introuvable). %s : indisponible. " ..
        "Les pages %s afficheront l'absence au lieu de simuler.",
        nom, chemin, description.role, table.concat(description.pages, ", ")))
    end
  end

  return presents, manquants
end

--------------------------------------------------------------------------------
-- Acces
--------------------------------------------------------------------------------

function liaisons:module(nom)
  local module = self.modules[nom]
  if module then return module end
  local description = liaisons.MODULES[nom]
  return nil, string.format("module '%s' absent (%s attendu)", nom,
    self.absents[nom] or (description and description.chemin) or "?")
end

--[[
  Appel protege d'une fonction d'un module exterieur.
  Retourne : ok, resultat ou motif.

  Un module absent ne provoque JAMAIS d'erreur : il rend false et un motif que
  la page affiche telle quelle. Le motif n'est journalise qu'une fois par
  couple module/fonction - repeter « autopilote absent » a chaque image
  noierait le journal sans rien apprendre.
]]
function liaisons:appeler(nom, fonction, ...)
  self.appels = self.appels + 1
  local module, motif = self:module(nom)

  if not module then
    self.refus = self.refus + 1
    local cle = nom .. "." .. tostring(fonction)
    if not self.signale[cle] then
      self.signale[cle] = true
      self.journal("AVERT", "liaisons", string.format(
        "%s() demande alors que %s", cle, motif))
    end
    return false, motif
  end

  if type(module[fonction]) ~= "function" then
    self.refus = self.refus + 1
    local cle = nom .. "." .. tostring(fonction)
    if not self.signale[cle] then
      self.signale[cle] = true
      self.journal("AVERT", "liaisons", string.format(
        "le module '%s' n'expose pas %s()", nom, tostring(fonction)))
    end
    return false, string.format("%s.%s() n'existe pas", nom, tostring(fonction))
  end

  local resultats = table.pack(pcall(module[fonction], ...))
  if not resultats[1] then
    self.refus = self.refus + 1
    self.journal("ERREUR", "liaisons", string.format(
      "%s.%s() a echoue : %s", nom, fonction, tostring(resultats[2])))
    return false, tostring(resultats[2])
  end
  return true, table.unpack(resultats, 2, resultats.n)
end

function liaisons:disponible(nom)
  return self.modules[nom] ~= nil
end

--[[
  Rapport d'integration, affiche par la page Liaison et par le diagnostic.
  C'est le document a lire avant de croire qu'une fonction marche.
]]
function liaisons:rapport()
  local lignes = {}
  local noms = {}
  for nom in pairs(liaisons.MODULES) do noms[#noms + 1] = nom end
  table.sort(noms)

  for _, nom in ipairs(noms) do
    local description = liaisons.MODULES[nom]
    local module = self.modules[nom]
    if not module then
      lignes[#lignes + 1] = {
        module = nom, statut = "ABSENT",
        detail = (self.absents[nom] or description.chemin) .. " introuvable",
      }
    else
      local absentes = {}
      for _, besoin in ipairs(description.besoins) do
        if type(module[besoin]) ~= "function" then absentes[#absentes + 1] = besoin end
      end
      lignes[#lignes + 1] = {
        module = nom,
        statut = (#absentes == 0) and "OK" or "PARTIEL",
        detail = (#absentes == 0) and description.role
          or ("manque : " .. table.concat(absentes, ", ")),
      }
    end
  end
  return lignes
end

return liaisons
