--[[----------------------------------------------------------------------------
  DOOMSDAY SHIP - COUCHE D'ABSTRACTION MATERIELLE (HAL)
  --------------------------------------------------------------------------
  Traduit « je veux le stress du moteur » en un appel de methode sur un
  peripherique reel du ballon.

  POURQUOI CETTE COUCHE EXISTE
  Je ne connais pas l'API de Create Aeronautics / Avionics. Ce depot a deja
  paye cette ignorance une fois : la detection du radar cherchait un
  peripherique dont le TYPE contenait « radar », et ne trouvait rien parce que
  le mod le nomme autrement. Ecrire ici getStress() en esperant que ce soit le
  bon nom repeterait la meme faute, en pire : une page de propulsion qui
  affiche un chiffre faux est plus dangereuse qu'une page vide.

  LA REGLE APPLIQUEE
    1. On decouvre PAR METHODE, jamais par nom de type.
    2. Chaque mesure liste plusieurs noms de methode plausibles.
    3. Une mesure introuvable rend nil ET SON MOTIF - jamais zero, jamais une
       valeur inventee. Les pages affichent « indisponible ».
    4. La configuration peut tout forcer, pour le jour ou le diagnostic aura
       revele les vrais noms.

  Lancez 'diagnostic' a bord AVANT de regler quoi que ce soit : il affiche les
  peripheriques reels, leurs methodes reelles et un echantillon de leurs
  valeurs. C'est ce qui permettra de remplacer les suppositions ci-dessous par
  des certitudes.

  'peripheriques' est injectable : ce module est testable hors du jeu.
--------------------------------------------------------------------------------]]

local hal = { VERSION = "1.0.0" }

local function nombreValide(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--------------------------------------------------------------------------------
-- 1. CATALOGUE DES MESURES
--
--    Les noms de methode ci-dessous sont des CANDIDATS, pas des certitudes.
--    Ils viennent des conventions habituelles de Create et de ses extensions.
--    Tant que le diagnostic n'a pas confirme, une mesure non trouvee est
--    signalee comme telle et n'est pas affichee.
--------------------------------------------------------------------------------

hal.MESURES = {
  -- Propulsion
  ["propulsion.stress"] = {
    libelle = "Stress",       unite = "su",
    methodes = { "getStress", "getKineticStress", "getStressUsage", "getNetworkStress" } },
  ["propulsion.capacite"] = {
    libelle = "Capacite",     unite = "su",
    methodes = { "getStressCapacity", "getCapacity", "getNetworkCapacity" } },
  ["propulsion.vitesse"] = {
    libelle = "Regime",       unite = "rpm",
    methodes = { "getSpeed", "getRPM", "getKineticSpeed", "getRotationSpeed" } },
  ["propulsion.poussee"] = {
    libelle = "Poussee",      unite = "%",
    methodes = { "getThrust", "getThrottle", "getPropulsion" } },

  -- Energie
  ["energie.stock"] = {
    libelle = "Energie",      unite = "FE",
    methodes = { "getEnergy", "getEnergyStored", "getStoredPower" } },
  ["energie.capacite"] = {
    libelle = "Capacite",     unite = "FE",
    methodes = { "getEnergyCapacity", "getMaxEnergyStored", "getCapacity" } },

  -- Portance et enveloppe
  ["portance.pression"] = {
    libelle = "Pression",     unite = "%",
    methodes = { "getPressure", "getEnvelopePressure", "getGasPressure" } },
  ["portance.gaz"] = {
    libelle = "Gaz",          unite = "%",
    methodes = { "getGas", "getLiftGas", "getBalloonFill", "getFillLevel" } },
  ["portance.portance"] = {
    libelle = "Portance",     unite = "N",
    methodes = { "getLift", "getBuoyancy", "getLiftForce" } },
  ["portance.ballast"] = {
    libelle = "Ballast",      unite = "%",
    methodes = { "getBallast", "getBallastLevel" } },

  -- Vol
  ["vol.altitude"] = {
    libelle = "Altitude",     unite = "b",
    methodes = { "getAltitude", "getY", "getHeight" } },
  ["vol.vitesseVerticale"] = {
    libelle = "Vario",        unite = "b/s",
    methodes = { "getVerticalSpeed", "getClimbRate", "getVerticalVelocity" } },
  ["vol.cap"] = {
    libelle = "Cap",          unite = "deg",
    methodes = { "getHeading", "getYaw", "getBearing" } },
}

-- Methodes presentes sur beaucoup de peripheriques et sans rapport avec une
-- mesure : ne jamais les prendre pour une source.
hal.METHODES_NEUTRES = {
  getMetadata = true, getDocs = true, getNames = true, getType = true,
  getSize = true, getInventory = true,
}

--------------------------------------------------------------------------------
-- 2. CONSTRUCTION ET INVENTAIRE
--------------------------------------------------------------------------------

function hal.nouveau(config, peripheriques, journal)
  return setmetatable({
    config        = config or {},
    peripheriques = peripheriques or peripheral,
    journal       = journal or function() end,
    liaisons      = {},   -- [cleMesure] = { peripherique, methode, facteur }
    manquantes    = {},   -- [cleMesure] = motif
    inventaire    = {},
    lectures      = 0,
    echecs        = 0,
  }, { __index = hal })
end

function hal:methodesDe(nom)
  if type(self.peripheriques.getMethods) == "function" then
    local ok, liste = pcall(self.peripheriques.getMethods, nom)
    if ok and type(liste) == "table" then return liste end
  end
  local ok, enveloppe = pcall(self.peripheriques.wrap, nom)
  if not ok or type(enveloppe) ~= "table" then return {} end
  local liste = {}
  for cle, valeur in pairs(enveloppe) do
    if type(valeur) == "function" then liste[#liste + 1] = cle end
  end
  table.sort(liste)
  return liste
end

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
    self.inventaire[#self.inventaire + 1] = {
      nom = nom, types = self:typesDe(nom), methodes = self:methodesDe(nom),
    }
  end
  return self.inventaire
end

--------------------------------------------------------------------------------
-- 3. DECOUVERTE DES LIAISONS
--------------------------------------------------------------------------------

--[[
  Pour chaque mesure du catalogue :
    1. si la configuration la force, on prend ce qu'elle dit - sans discuter,
       parce qu'elle vient du diagnostic et que le diagnostic dit la verite ;
    2. sinon, on cherche un peripherique exposant l'un des noms candidats ;
    3. sinon, la mesure est declaree MANQUANTE, avec son motif.

  Retourne : nombre de liaisons etablies, nombre de mesures manquantes.
]]
function hal:decouvrir()
  self:dresserInventaire()
  self.liaisons, self.manquantes = {}, {}
  local forcees = self.config.mesures or {}
  local trouvees, absentes = 0, 0

  for cle, mesure in pairs(hal.MESURES) do
    local force = forcees[cle]

    if force == false then
      -- Mesure explicitement declaree absente sur ce ballon : ce n'est pas
      -- une anomalie, on ne la signalera pas comme telle.
      self.manquantes[cle] = "desactivee en configuration"
    elseif type(force) == "table" and force.peripherique and force.methode then
      local existe = select(2, pcall(self.peripheriques.isPresent, force.peripherique))
      if existe then
        self.liaisons[cle] = {
          peripherique = force.peripherique, methode = force.methode,
          facteur = force.facteur or 1, decalage = force.decalage or 0,
          source = "configuration",
        }
        trouvees = trouvees + 1
      else
        self.manquantes[cle] = string.format(
          "peripherique force '%s' absent", tostring(force.peripherique))
        absentes = absentes + 1
      end
    else
      local candidats = {}
      for _, m in ipairs(mesure.methodes) do candidats[m] = true end

      local liaison
      for _, p in ipairs(self.inventaire) do
        for _, methode in ipairs(p.methodes) do
          if candidats[methode] and not hal.METHODES_NEUTRES[methode] then
            liaison = { peripherique = p.nom, methode = methode,
                        facteur = 1, decalage = 0, source = "detection" }
            break
          end
        end
        if liaison then break end
      end

      if liaison then
        self.liaisons[cle] = liaison
        trouvees = trouvees + 1
        self.journal("INFO", "materiel", string.format(
          "mesure %s liee a %s.%s()", cle, liaison.peripherique, liaison.methode))
      else
        self.manquantes[cle] = string.format(
          "aucun peripherique n'expose %s", table.concat(mesure.methodes, ", "))
        absentes = absentes + 1
      end
    end
  end

  if absentes > 0 then
    self.journal("AVERT", "materiel", string.format(
      "%d mesure(s) sur %d introuvable(s) : les pages afficheront INDISPO " ..
      "plutot qu'un chiffre invente. Lancez 'diagnostic' pour relever les vraies " ..
      "methodes du ballon.", absentes, trouvees + absentes))
  end
  return trouvees, absentes
end

--------------------------------------------------------------------------------
-- 4. LECTURE
--------------------------------------------------------------------------------

--[[
  Retourne : valeur, motif.
  valeur = nil signifie « on ne sait pas », JAMAIS « zero ». Un reservoir vide
  et un capteur muet ne se ressemblent pas, et les confondre sur une page de
  portance se paie cher.
]]
function hal:lire(cle)
  local liaison = self.liaisons[cle]
  if not liaison then
    return nil, self.manquantes[cle] or "mesure inconnue du catalogue"
  end

  self.lectures = self.lectures + 1
  local ok, valeur = pcall(function()
    return self.peripheriques.call(liaison.peripherique, liaison.methode)
  end)

  if not ok then
    self.echecs = self.echecs + 1
    return nil, string.format("%s.%s() a echoue : %s",
      liaison.peripherique, liaison.methode, tostring(valeur))
  end
  if not nombreValide(valeur) then
    -- Certaines methodes rendent une table ; on tente les champs habituels.
    if type(valeur) == "table" then
      for _, champ in ipairs({ "value", "amount", "level", "stored" }) do
        if nombreValide(valeur[champ]) then
          return valeur[champ] * liaison.facteur + liaison.decalage
        end
      end
    end
    return nil, string.format("%s.%s() ne rend pas un nombre exploitable",
      liaison.peripherique, liaison.methode)
  end

  return valeur * liaison.facteur + liaison.decalage
end

-- Lecture avec repli : utile pour les pages qui preferent un pourcentage.
function hal:pourcentage(cleValeur, cleCapacite)
  local valeur = self:lire(cleValeur)
  local capacite = self:lire(cleCapacite)
  if not (nombreValide(valeur) and nombreValide(capacite)) or capacite <= 0 then
    return nil
  end
  return math.max(0, math.min(100, valeur / capacite * 100))
end

-- Instantane de toutes les mesures, pour les pages et le journal.
function hal:etat()
  local etat = {}
  for cle in pairs(hal.MESURES) do
    local valeur, motif = self:lire(cle)
    etat[cle] = { valeur = valeur, motif = motif }
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
