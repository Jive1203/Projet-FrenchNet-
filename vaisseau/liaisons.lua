--[[----------------------------------------------------------------------------
  DOOMSDAY SHIP - COUTURE D'INTEGRATION AVEC LES MODULES EXTERIEURS
  Point de contact UNIQUE avec l'autopilote, le Fire Control embarque et l'ADS.

  A l'ecriture, AUCUN des trois n'existe dans le depot (verifie branche par
  branche, voir docs/api_notes.md). Appeler des fonctions dont j'ignore le nom
  produirait un systeme qui a l'air de marcher jusqu'au premier vol. Donc :
  module present -> on l'appelle ; module absent -> l'appel ECHOUE avec un
  motif lisible, une seule fois au journal. Aucun bouchon qui rendrait « ok ».
  Le jour ou l'autopilote arrive, il y a un seul fichier a modifier, et les
  fonctions a ecrire sont nommees dans le rapport.
--------------------------------------------------------------------------------]]

local liaisons = { VERSION = "1.0.0" }

-- 'besoins' = ce que les pages appellent reellement, pas une API inventee.
liaisons.MODULES = {
  autopilote = {
    chemin = "/vaisseau/autopilote.lua",
    role = "tenue de cap, suivi de route, envoi de waypoints",
    besoins = { "definirRoute", "etat", "engager", "desengager" },
    pages = { "navigation" } },
  fireControl = {
    chemin = "/vaisseau/fire_control.lua",
    role = "selection d'arme et execution du tir (AAA, MS-GA, ML-GA, M-GG, Artillery)",
    besoins = { "armes", "engager", "securiser", "munitions" },
    pages = { "armement" } },
  ads = {
    chemin = "/vaisseau/ads.lua",
    role = "contre-mesures : chaffs et flares",
    besoins = { "stock", "larguer", "etat" },
    pages = { "ew" } },
}

function liaisons.nouveau(config, journal, chargeur)
  return setmetatable({
    config = config or {}, journal = journal or function() end,
    chargeur = chargeur or loadfile,   -- injectable pour les tests
    modules = {}, absents = {}, signale = {}, appels = 0, refus = 0,
  }, { __index = liaisons })
end

-- Presence ne vaut pas conformite : on nomme les fonctions attendues absentes.
local function manquantes(description, module)
  local absentes = {}
  for _, besoin in ipairs(description.besoins) do
    if type(module[besoin]) ~= "function" then absentes[#absentes + 1] = besoin end
  end
  return absentes
end

-- Une seule tentative par module, au demarrage : un module qui apparait en vol
-- attendra le prochain redemarrage plutot qu'un rechargement a chaud pendant
-- un engagement.
function liaisons:charger()
  local presents, absents = 0, 0

  for nom, d in pairs(liaisons.MODULES) do
    local chemin = (self.config.chemins or {})[nom] or d.chemin
    -- Surtout pas 'local charge, module = ...' : loadfile rend nil + un message
    -- d'erreur, et ce message passerait pour un module charge.
    local module
    local charge = self.chargeur(chemin)
    if charge then
      local ok, resultat = pcall(charge)
      if ok and type(resultat) == "table" then module = resultat end
    end

    if module then
      self.modules[nom] = module
      presents = presents + 1
      local absentes = manquantes(d, module)
      if #absentes > 0 then
        self.journal("AVERT", "liaisons", ("module '%s' charge depuis %s mais il " ..
          "n'expose pas : %s. Les pages %s resteront partiellement inertes.")
          :format(nom, chemin, table.concat(absentes, ", "), table.concat(d.pages, ", ")))
      else
        self.journal("INFO", "liaisons",
          ("module '%s' charge depuis %s : %s"):format(nom, chemin, d.role))
      end
    else
      absents = absents + 1
      self.absents[nom] = chemin
      self.journal("AVERT", "liaisons", ("module '%s' ABSENT (%s introuvable). %s : " ..
        "indisponible. Les pages %s afficheront l'absence au lieu de simuler.")
        :format(nom, chemin, d.role, table.concat(d.pages, ", ")))
    end
  end
  return presents, absents
end

function liaisons:module(nom)
  local module = self.modules[nom]
  if module then return module end
  local d = liaisons.MODULES[nom]
  return nil, ("module '%s' absent (%s attendu)")
    :format(nom, self.absents[nom] or (d and d.chemin) or "?")
end

-- Journalise un refus une seule fois par couple module/fonction : le repeter a
-- chaque image noierait le journal sans rien apprendre.
function liaisons:_refuser(cle, message, motif)
  self.refus = self.refus + 1
  if not self.signale[cle] then
    self.signale[cle] = true
    self.journal("AVERT", "liaisons", message)
  end
  return false, motif
end

-- Retourne : ok, resultat|motif. Un module absent ne leve JAMAIS d'erreur, il
-- rend false et un motif que la page affiche tel quel.
function liaisons:appeler(nom, fonction, ...)
  self.appels = self.appels + 1
  local module, motif = self:module(nom)
  local cle = nom .. "." .. tostring(fonction)

  if not module then
    return self:_refuser(cle, ("%s() demande alors que %s"):format(cle, motif), motif)
  end
  if type(module[fonction]) ~= "function" then
    return self:_refuser(cle,
      ("le module '%s' n'expose pas %s()"):format(nom, tostring(fonction)),
      ("%s.%s() n'existe pas"):format(nom, tostring(fonction)))
  end

  local r = table.pack(pcall(module[fonction], ...))
  if not r[1] then
    self.refus = self.refus + 1
    self.journal("ERREUR", "liaisons",
      ("%s() a echoue : %s"):format(cle, tostring(r[2])))
    return false, tostring(r[2])
  end
  return true, table.unpack(r, 2, r.n)
end

function liaisons:disponible(nom)
  return self.modules[nom] ~= nil
end

-- Rapport d'integration : le document a lire AVANT de croire qu'une fonction
-- marche. Affiche par la page Liaison et par le diagnostic.
function liaisons:rapport()
  local noms = {}
  for nom in pairs(liaisons.MODULES) do noms[#noms + 1] = nom end
  table.sort(noms)

  local lignes = {}
  for _, nom in ipairs(noms) do
    local d, module = liaisons.MODULES[nom], self.modules[nom]
    if not module then
      lignes[#lignes + 1] = { module = nom, statut = "ABSENT",
        detail = (self.absents[nom] or d.chemin) .. " introuvable" }
    else
      local absentes = manquantes(d, module)
      lignes[#lignes + 1] = { module = nom,
        statut = (#absentes == 0) and "OK" or "PARTIEL",
        detail = (#absentes == 0) and d.role
                 or ("manque : " .. table.concat(absentes, ", ")) }
    end
  end
  return lignes
end

return liaisons
