--[[----------------------------------------------------------------------------
  DOOMSDAY SHIP - RECENSEMENT DES SOUTES (PHASE 3, PARTIE NON BLOQUEE)
  Compte ce qu'il y a physiquement a bord : obus, poudre, leurres, carburant.

  POURQUOI CETTE MOITIE-LA EXISTE ALORS QUE L'ARMEMENT EST BLOQUE
  Le Fire Control Embarque et l'ADS sont absents du depot : personne ne peut
  dire combien de coups une tourelle a encore. Mais les COFFRES, eux, sont des
  peripheriques CC standards - list(), size(), getItemDetail() sont documentes
  et stables. Compter la soute ne demande donc aucune supposition.

  La distinction doit rester visible a l'ecran : « compte en soute » n'est pas
  « pret au tir ». Un obus dans un coffre n'est pas un obus dans la culasse, et
  afficher l'un pour l'autre ferait engager un equipage avec une piece vide.

  Detection PAR METHODE, comme le HAL : on cherche ce qui expose list(), pas ce
  qui s'appelle « chest ».
--------------------------------------------------------------------------------]]

local inv = { VERSION = "1.0.0" }

-- Familles reconnues par defaut. Les motifs sont cherches en sous-chaine dans
-- l'identifiant Minecraft de l'objet, insensible a la casse : un depot qui
-- nomme ses obus autrement ajoute son motif en configuration sans toucher ici.
inv.FAMILLES = {
  { cle = "obus",      libelle = "Obus",       motifs = { "shell", "obus", "cannon_ball", "shot" } },
  { cle = "poudre",    libelle = "Poudre",     motifs = { "powder", "cartridge", "propellant", "gunpowder" } },
  { cle = "leurres",   libelle = "Leurres",    motifs = { "chaff", "flare", "leurre", "decoy" } },
  { cle = "missiles",  libelle = "Missiles",   motifs = { "missile", "rocket" } },
  { cle = "carburant", libelle = "Carburant",  motifs = { "fuel", "biofuel", "coal", "blaze" } },
  { cle = "reparation",libelle = "Reparation", motifs = { "plate", "ingot", "sheet", "repair" } },
}

function inv.nouveau(config, peripheriques, journal)
  return setmetatable({
    config = config or {}, peripheriques = peripheriques or peripheral,
    journal = journal or function() end,
    soutes = {},      -- noms des peripheriques d'inventaire retenus
    total = {},       -- [nomObjet] = quantite
    familles = {},    -- [cleFamille] = quantite
    recensementA = nil, lectures = 0, echecs = 0,
  }, { __index = inv })
end

function inv:famillesActives()
  return self.config.famillesInventaire or inv.FAMILLES
end

-- Un inventaire est ce qui expose list() ET size(). Le couple ecarte les
-- peripheriques qui exposent un list() sans rapport (un modem filaire liste
-- ses pairs, et n'est pas une soute).
function inv:decouvrir()
  self.soutes = {}
  local ok, noms = pcall(self.peripheriques.getNames)
  if not ok or type(noms) ~= "table" then return 0 end

  local exclus = {}
  for _, nom in ipairs(self.config.souteExclue or {}) do exclus[nom] = true end

  for _, nom in ipairs(noms) do
    if not exclus[nom] then
      local aListe = select(2, pcall(self.peripheriques.hasType, nom, "inventory"))
      if aListe ~= true then
        -- hasType n'existe pas partout : on retombe sur la presence des deux
        -- methodes, ce qui est le vrai critere.
        local enveloppe = select(2, pcall(self.peripheriques.wrap, nom))
        aListe = type(enveloppe) == "table"
          and type(enveloppe.list) == "function" and type(enveloppe.size) == "function"
      end
      if aListe then self.soutes[#self.soutes + 1] = nom end
    end
  end

  if #self.soutes == 0 then
    self.journal("AVERT", "inventaire", "aucune soute visible : les comptes " ..
      "d'obus, de poudre et de leurres resteront INDISPO. Reliez les coffres a " ..
      "l'ordinateur par modem filaire, les deux modems actives.")
  else
    self.journal("INFO", "inventaire",
      ("%d soute(s) : %s"):format(#self.soutes, table.concat(self.soutes, ", ")))
  end
  return #self.soutes
end

local function correspond(nomObjet, motifs)
  local bas = nomObjet:lower()
  for _, motif in ipairs(motifs) do
    if bas:find(motif:lower(), 1, true) then return true end
  end
  return false
end

--[[
  Recense toutes les soutes. Retourne : total par objet, total par famille.
  Une soute illisible n'annule pas le recensement : elle est comptee en echec
  et signalee, parce qu'un total partiel annonce comme complet ferait croire a
  une reserve qui n'existe pas.
]]
function inv:recenser(maintenant)
  self.total, self.familles = {}, {}
  local lues, echouees = 0, 0

  for _, nom in ipairs(self.soutes) do
    self.lectures = self.lectures + 1
    local ok, contenu = pcall(self.peripheriques.call, nom, "list")
    if not ok or type(contenu) ~= "table" then
      echouees = echouees + 1
      self.echecs = self.echecs + 1
    else
      lues = lues + 1
      for _, pile in pairs(contenu) do
        if type(pile) == "table" and type(pile.name) == "string" then
          local n = tonumber(pile.count) or 0
          self.total[pile.name] = (self.total[pile.name] or 0) + n
        end
      end
    end
  end

  for _, famille in ipairs(self:famillesActives()) do
    local somme, trouve = 0, false
    for nomObjet, quantite in pairs(self.total) do
      if correspond(nomObjet, famille.motifs) then somme, trouve = somme + quantite, true end
    end
    -- Famille jamais vue -> nil, pas zero. « Aucun obus a bord » et « je ne
    -- sais pas reconnaitre vos obus » appellent des gestes opposes.
    self.familles[famille.cle] = trouve and somme or nil
  end

  self.recensementA = maintenant
  if echouees > 0 then
    self.journal("AVERT", "inventaire",
      ("%d soute(s) illisible(s) sur %d : les comptes sont PARTIELS")
        :format(echouees, #self.soutes))
  end
  return self.total, self.familles, lues, echouees
end

-- Quantite d'une famille, ou nil si elle n'a jamais ete vue.
function inv:compter(cleFamille) return self.familles[cleFamille] end

-- Les N objets les plus nombreux, pour la page inventaire.
function inv:principaux(combien)
  local liste = {}
  for nom, quantite in pairs(self.total) do
    liste[#liste + 1] = { nom = nom, quantite = quantite }
  end
  table.sort(liste, function(a, b)
    if a.quantite ~= b.quantite then return a.quantite > b.quantite end
    return a.nom < b.nom
  end)
  local coupe = {}
  for i = 1, math.min(combien or 10, #liste) do coupe[i] = liste[i] end
  return coupe
end

-- Nom court lisible : « minecraft:gunpowder » -> « gunpowder ».
function inv.nomCourt(nomObjet)
  return (tostring(nomObjet):match("([^:]+)$") or tostring(nomObjet)):gsub("_", " ")
end

function inv:resume()
  local objets = 0
  for _ in pairs(self.total) do objets = objets + 1 end
  return #self.soutes, objets, self.lectures, self.echecs
end

return inv
