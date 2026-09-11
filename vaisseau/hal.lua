--[[----------------------------------------------------------------------------
  DOOMSDAY SHIP - COUCHE D'ABSTRACTION MATERIELLE (HAL)
  Traduit « je veux le stress moteur » en un appel sur un peripherique reel.

  - Decouverte PAR METHODE, jamais par nom de type : ce depot a deja paye une
    fois la detection du radar par type, qui ne trouvait rien.
  - Chaque mesure liste plusieurs noms candidats ; l'API de Create Aeronautics
    n'est pas connue, seul 'diagnostic' a bord dira les vrais noms.
  - Mesure introuvable -> nil + motif, jamais zero : une page qui affiche un
    faux chiffre est plus dangereuse qu'une page vide.
  - La configuration peut tout forcer, pour le jour ou le diagnostic aura parle.
  'peripheriques' est injectable : ce module est testable hors du jeu.
--------------------------------------------------------------------------------]]

local hal = { VERSION = "1.0.0" }

local function nb(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function M(libelle, unite, ...) return { libelle = libelle, unite = unite, methodes = { ... } } end

-- Noms de methode CANDIDATS (conventions Create), pas des certitudes.
hal.MESURES = {
  ["propulsion.stress"]   = M("Stress",   "su",  "getStress", "getKineticStress", "getStressUsage", "getNetworkStress"),
  ["propulsion.capacite"] = M("Capacite", "su",  "getStressCapacity", "getCapacity", "getNetworkCapacity"),
  ["propulsion.vitesse"]  = M("Regime",   "rpm", "getSpeed", "getRPM", "getKineticSpeed", "getRotationSpeed"),
  ["propulsion.poussee"]  = M("Poussee",  "%",   "getThrust", "getThrottle", "getPropulsion"),

  ["energie.stock"]       = M("Energie",  "FE",  "getEnergy", "getEnergyStored", "getStoredPower"),
  ["energie.capacite"]    = M("Capacite", "FE",  "getEnergyCapacity", "getMaxEnergyStored", "getCapacity"),

  ["portance.pression"]   = M("Pression", "%",   "getPressure", "getEnvelopePressure", "getGasPressure"),
  ["portance.gaz"]        = M("Gaz",      "%",   "getGas", "getLiftGas", "getBalloonFill", "getFillLevel"),
  ["portance.portance"]   = M("Portance", "N",   "getLift", "getBuoyancy", "getLiftForce"),
  ["portance.ballast"]    = M("Ballast",  "%",   "getBallast", "getBallastLevel"),

  ["vol.altitude"]        = M("Altitude", "b",   "getAltitude", "getY", "getHeight"),
  ["vol.vitesseVerticale"]= M("Vario",    "b/s", "getVerticalSpeed", "getClimbRate", "getVerticalVelocity"),
  ["vol.cap"]             = M("Cap",      "deg", "getHeading", "getYaw", "getBearing"),
}

-- Presentes partout et sans rapport avec une mesure : jamais une source.
hal.METHODES_NEUTRES = {
  getMetadata = true, getDocs = true, getNames = true, getType = true,
  getSize = true, getInventory = true,
}

function hal.nouveau(config, peripheriques, journal)
  return setmetatable({
    config = config or {}, peripheriques = peripheriques or peripheral,
    journal = journal or function() end,
    liaisons = {},    -- [cle] = { peripherique, methode, facteur, decalage, source }
    manquantes = {},  -- [cle] = motif
    inventaire = {}, lectures = 0, echecs = 0,
  }, { __index = hal })
end

function hal:methodesDe(nom)
  if type(self.peripheriques.getMethods) == "function" then
    local ok, liste = pcall(self.peripheriques.getMethods, nom)
    if ok and type(liste) == "table" then return liste end
  end
  local ok, env = pcall(self.peripheriques.wrap, nom)
  if not ok or type(env) ~= "table" then return {} end
  local liste = {}
  for cle, v in pairs(env) do
    if type(v) == "function" then liste[#liste + 1] = cle end
  end
  table.sort(liste)
  return liste
end

-- getType peut rendre PLUSIEURS types : on les collecte tous.
function hal:typesDe(nom)
  local r = table.pack(pcall(self.peripheriques.getType, nom))
  if not r[1] then return {} end
  local types = {}
  for i = 2, r.n do
    if type(r[i]) == "string" then types[#types + 1] = r[i] end
  end
  return types
end

function hal:dresserInventaire()
  self.inventaire = {}
  local ok, noms = pcall(self.peripheriques.getNames)
  if not ok or type(noms) ~= "table" then return self.inventaire end
  for _, nom in ipairs(noms) do
    self.inventaire[#self.inventaire + 1] =
      { nom = nom, types = self:typesDe(nom), methodes = self:methodesDe(nom) }
  end
  return self.inventaire
end

-- Cherche un peripherique exposant l'un des noms candidats.
function hal:_chercher(mesure)
  local candidats = {}
  for _, m in ipairs(mesure.methodes) do candidats[m] = true end
  for _, p in ipairs(self.inventaire) do
    for _, methode in ipairs(p.methodes) do
      if candidats[methode] and not hal.METHODES_NEUTRES[methode] then
        return { peripherique = p.nom, methode = methode,
                 facteur = 1, decalage = 0, source = "detection" }
      end
    end
  end
end

-- Retourne : liaisons etablies, mesures manquantes.
function hal:decouvrir()
  self:dresserInventaire()
  self.liaisons, self.manquantes = {}, {}
  local forcees = self.config.mesures or {}
  local trouvees, absentes = 0, 0

  for cle, mesure in pairs(hal.MESURES) do
    local force, liaison, motif = forcees[cle]

    if force == false then
      -- Declaree absente de ce ballon : ce n'est pas une anomalie, on ne la
      -- compte donc pas dans les manquantes signalees.
      self.manquantes[cle] = "desactivee en configuration"
    elseif type(force) == "table" and force.peripherique and force.methode then
      -- La configuration vient du diagnostic, et le diagnostic dit la verite.
      if select(2, pcall(self.peripheriques.isPresent, force.peripherique)) then
        liaison = { peripherique = force.peripherique, methode = force.methode,
                    facteur = force.facteur or 1, decalage = force.decalage or 0,
                    source = "configuration" }
      else
        motif = ("peripherique force '%s' absent"):format(tostring(force.peripherique))
      end
    else
      liaison = self:_chercher(mesure)
      if liaison then
        self.journal("INFO", "materiel", ("mesure %s liee a %s.%s()")
          :format(cle, liaison.peripherique, liaison.methode))
      else
        -- Le motif NOMME les methodes cherchees : c'est ce qui permet de
        -- corriger la configuration apres un diagnostic.
        motif = ("aucun peripherique n'expose %s"):format(table.concat(mesure.methodes, ", "))
      end
    end

    if liaison then
      self.liaisons[cle] = liaison
      trouvees = trouvees + 1
    elseif motif then
      self.manquantes[cle] = motif
      absentes = absentes + 1
    end
  end

  if absentes > 0 then
    self.journal("AVERT", "materiel", ("%d mesure(s) sur %d introuvable(s) : les " ..
      "pages afficheront INDISPO plutot qu'un chiffre invente. Lancez 'diagnostic' " ..
      "pour relever les vraies methodes du ballon."):format(absentes, trouvees + absentes))
  end
  return trouvees, absentes
end

-- Retourne : valeur, motif. nil = « on ne sait pas », JAMAIS zero : un
-- reservoir vide et un capteur muet ne se ressemblent pas.
function hal:lire(cle)
  local l = self.liaisons[cle]
  if not l then return nil, self.manquantes[cle] or "mesure inconnue du catalogue" end

  self.lectures = self.lectures + 1
  local ok, v = pcall(self.peripheriques.call, l.peripherique, l.methode)
  if not ok then
    self.echecs = self.echecs + 1
    return nil, ("%s.%s() a echoue : %s"):format(l.peripherique, l.methode, tostring(v))
  end

  if not nb(v) then
    -- Certaines methodes rendent une table ; on tente les champs habituels.
    if type(v) == "table" then
      for _, champ in ipairs({ "value", "amount", "level", "stored" }) do
        if nb(v[champ]) then return v[champ] * l.facteur + l.decalage end
      end
    end
    return nil, ("%s.%s() ne rend pas un nombre exploitable"):format(l.peripherique, l.methode)
  end
  return v * l.facteur + l.decalage
end

function hal:pourcentage(cleValeur, cleCapacite)
  local v, c = self:lire(cleValeur), self:lire(cleCapacite)
  if not (nb(v) and nb(c)) or c <= 0 then return nil end
  return math.max(0, math.min(100, v / c * 100))
end

function hal:etat()
  local etat = {}
  for cle in pairs(hal.MESURES) do
    local v, motif = self:lire(cle)
    etat[cle] = { valeur = v, motif = motif }
  end
  return etat
end

function hal:resume()
  local liees, manquantes = 0, 0
  for _ in pairs(self.liaisons) do liees = liees + 1 end
  for _ in pairs(self.manquantes) do manquantes = manquantes + 1 end
  return liees, manquantes, self.lectures, self.echecs
end

return hal
