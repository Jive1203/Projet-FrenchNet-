--[[----------------------------------------------------------------------------
  FRENCHNET / AERONAUTICS WARFARE - Radar embarque (Create Radars)
  --------------------------------------------------------------------------
  Role : fournir en continu la position X, Y, Z de la cible suivie, et une
         estimation de sa vitesse.

  Le radar embarque est la SEULE source de suivi une fois l'ordre recu. La
  position transmise par le systeme au sol ne sert qu'a designer la cible au
  premier contact ; ensuite le navire recalcule sa trajectoire a partir de ses
  propres mesures.

  Deux precautions importantes :
    * l'API des peripheriques varie selon la version du mod : on resout les
      noms de methodes au demarrage et on journalise celui retenu ;
    * la vitesse est TOUJOURS estimee par differences finies lissees, meme si
      le radar en annonce une. Une vitesse fournie par le mod est utilisee en
      controle croise, pas en source unique : c'est elle qui alimente toute la
      prediction d'interception, une valeur fausse enverrait le navire au
      mauvais endroit.

  Chargement : local noyau = ...
--------------------------------------------------------------------------------]]

local noyau = ...
local E = noyau.ETAPES
local journal = noyau.journal
local V = noyau.vec

local M = {}

--------------------------------------------------------------------------------
-- 1. DETECTION DU PERIPHERIQUE
--------------------------------------------------------------------------------

local TYPES_RADAR = {
  "radar", "create_radars:radar", "createradars:radar",
  "monitoring_radar", "radar_block", "aircraft_radar",
}

local METHODES_SCAN = {
  "getEntities", "getEntitiesDetected", "getContacts", "getTargets",
  "scan", "getDetectedEntities", "entities",
}

local function estRadar(nom)
  local ok, typePeripherique = pcall(peripheral.getType, nom)
  if not ok or type(typePeripherique) ~= "string" then return false end
  local minuscule = typePeripherique:lower()
  for _, motif in ipairs(TYPES_RADAR) do
    if minuscule == motif or minuscule:find("radar", 1, true) then return true end
  end
  return false
end

--- @return peripherique, cote, nomMethodeScan
function M.detecter(config)
  local candidats = {}

  if type(config.coteRadar) == "string" and config.coteRadar ~= "" then
    if not peripheral.isPresent(config.coteRadar) then
      error("aucun peripherique sur le cote radar impose '" .. config.coteRadar .. "'", 0)
    end
    candidats[1] = config.coteRadar
  else
    for _, nom in ipairs(peripheral.getNames()) do
      if estRadar(nom) then candidats[#candidats + 1] = nom end
    end
  end

  if #candidats == 0 then
    error("aucun radar embarque detecte. Verifiez que le radar Create Radars est "
      .. "bien connecte a l'ordinateur (contact direct ou modem filaire), ou "
      .. "renseignez 'coteRadar' dans la configuration.", 0)
  end

  for _, nom in ipairs(candidats) do
    local peripherique = peripheral.wrap(nom)
    local fn, nomMethode = noyau.resoudreMethode(peripherique, METHODES_SCAN)
    if fn then
      journal.info(E.DETECTION_RADAR, string.format(
        "radar embarque sur '%s' (type %s), balayage via %s()",
        nom, tostring(select(2, pcall(peripheral.getType, nom))), nomMethode))
      return peripherique, nom, nomMethode
    end
  end

  error("un radar a bien ete trouve mais aucune methode de balayage connue n'y "
    .. "figure. Methodes recherchees : " .. table.concat(METHODES_SCAN, ", "), 0)
end

--------------------------------------------------------------------------------
-- 2. NORMALISATION DES CONTACTS
--    Les mods ne s'accordent pas sur la forme des entrees renvoyees. On
--    accepte les variantes courantes plutot que d'en figer une seule.
--------------------------------------------------------------------------------

local function lirePosition(contact)
  if type(contact) ~= "table" then return nil end
  if noyau.nombreValide(contact.x) and noyau.nombreValide(contact.y)
     and noyau.nombreValide(contact.z) then
    return { x = contact.x, y = contact.y, z = contact.z }
  end
  for _, cle in ipairs({ "position", "pos", "location", "coords" }) do
    local p = contact[cle]
    if type(p) == "table" then
      if noyau.nombreValide(p.x) then return { x = p.x, y = p.y or 0, z = p.z or 0 } end
      if noyau.nombreValide(p[1]) then return { x = p[1], y = p[2] or 0, z = p[3] or 0 } end
    end
  end
  return nil
end

local function lireVitesse(contact)
  if type(contact) ~= "table" then return nil end
  for _, cle in ipairs({ "velocity", "vitesse", "motion", "vel" }) do
    local v = contact[cle]
    if type(v) == "table" then
      if noyau.nombreValide(v.x) then return { x = v.x, y = v.y or 0, z = v.z or 0 } end
      if noyau.nombreValide(v[1]) then return { x = v[1], y = v[2] or 0, z = v[3] or 0 } end
    end
  end
  return nil
end

local function lireIdentifiant(contact)
  if type(contact) ~= "table" then return nil end
  for _, cle in ipairs({ "id", "uuid", "entityId", "identifiant", "name", "nom" }) do
    if contact[cle] ~= nil then return tostring(contact[cle]) end
  end
  return nil
end

--------------------------------------------------------------------------------
-- 3. PISTE
--    Une piste est le suivi d'UNE cible : historique de positions, vitesse
--    lissee, date du dernier contact.
--------------------------------------------------------------------------------

local Piste = {}
Piste.__index = Piste

function M.creerPiste(config)
  return setmetatable({
    identifiant     = nil,
    position        = nil,
    vitesse         = { x = 0, y = 0, z = 0 },
    vitesseRadar    = nil,
    cap             = nil,
    capFiable       = false,
    dernierContact  = nil,
    premierContact  = nil,
    contacts        = 0,
    historique      = {},   -- criteres de degat (partages avec le navire)
    echantillons    = {},   -- differences finies pour la vitesse
    config          = config,
  }, Piste)
end

--- Integre une mesure. Le lissage exponentiel evite qu'un unique echantillon
-- bruite ne fasse basculer toute la trajectoire d'interception.
function Piste:integrer(position, vitesseAnnoncee, maintenant, criteresDegat)
  local precedent = self.echantillons[#self.echantillons]

  if precedent then
    local dt = maintenant - precedent.t
    if dt >= (self.config.dtMiniVitesse or 0.15) then
      local brute = V.multiplier(V.soustraire(position, precedent.p), 1 / dt)
      local lissage = noyau.borner(self.config.lissageVitesse or 0.35, 0.05, 1)
      self.vitesse = {
        x = self.vitesse.x + lissage * (brute.x - self.vitesse.x),
        y = self.vitesse.y + lissage * (brute.y - self.vitesse.y),
        z = self.vitesse.z + lissage * (brute.z - self.vitesse.z),
      }
      self.echantillons[#self.echantillons + 1] = { t = maintenant, p = V.copier(position) }
    end
  else
    self.echantillons[1] = { t = maintenant, p = V.copier(position) }
  end

  while #self.echantillons > (self.config.echantillonsVitesse or 8) do
    table.remove(self.echantillons, 1)
  end

  -- Controle croise avec la vitesse annoncee par le mod, si elle existe.
  if vitesseAnnoncee then
    self.vitesseRadar = vitesseAnnoncee
    local ecart = V.distance(vitesseAnnoncee, self.vitesse)
    if ecart > (self.config.ecartVitesseAlerte or 40) then
      journal.limite("ecart_vitesse", 10, "AVERT", E.PISTAGE_RADAR, string.format(
        "ecart de %.1f b/s entre la vitesse annoncee par le radar (%.1f) et "
        .. "la vitesse estimee (%.1f) : estimation conservee",
        ecart, V.norme(vitesseAnnoncee), V.norme(self.vitesse)))
    end
  end

  self.position       = position
  self.premierContact = self.premierContact or maintenant
  self.dernierContact = maintenant
  self.contacts       = self.contacts + 1

  local cap, fiable = nil, false
  local interception = self.config.__interception
  if interception then
    cap, fiable = interception.capMobile(self.vitesse, self.cap,
      self.config.vitesseMiniPourCap or 2, self.relevementSecours)
    self.cap, self.capFiable = cap, fiable
    interception.ajouterEchantillon(self.historique, maintenant, position.y,
      V.norme(self.vitesse), (criteresDegat and criteresDegat.fenetreSecondes) or 5)
  end

  return self
end

function Piste:silence(maintenant)
  if not self.dernierContact then return math.huge end
  return maintenant - self.dernierContact
end

function Piste:exploitable(maintenant, delaiValidite)
  return self.position ~= nil and self:silence(maintenant) <= (delaiValidite or 3)
end

--------------------------------------------------------------------------------
-- 4. BALAYAGE ET APPARIEMENT
--------------------------------------------------------------------------------

--- Selectionne, parmi les contacts radar, celui qui correspond a la cible
-- suivie : le plus proche de sa position attendue, dans un rayon de tolerance.
-- L'appariement par identifiant est prefere quand le mod en fournit un.
-- @return contact, distanceAppariement
local function apparier(contacts, attendue, identifiant, rayon)
  local meilleur, meilleureDistance = nil, math.huge

  for _, contact in ipairs(contacts) do
    local position = lirePosition(contact)
    if position then
      if identifiant and lireIdentifiant(contact) == identifiant then
        return contact, V.distance(position, attendue)
      end
      local d = V.distance(position, attendue)
      if d < meilleureDistance then meilleur, meilleureDistance = contact, d end
    end
  end

  if meilleur and meilleureDistance <= rayon then
    return meilleur, meilleureDistance
  end
  return nil, meilleureDistance
end

--- Un cycle de balayage : interroge le radar et met la piste a jour.
-- @return true si la piste a ete rafraichie
function M.balayer(contexte, piste, positionAttendue, criteresDegat)
  local ok, contacts = noyau.proteger(E.PISTAGE_RADAR, function()
    return contexte.scan(contexte.radar)
  end)
  if not ok or type(contacts) ~= "table" then return false end

  -- Certaines API encapsulent la liste dans un champ.
  if contacts.entities then contacts = contacts.entities end
  if contacts.contacts then contacts = contacts.contacts end

  local rayon = contexte.config.rayonAppariement or 150
  local contact, distance = apparier(contacts, positionAttendue, piste.identifiant, rayon)

  if not contact then
    journal.limite("pas_de_contact", 5, "DEBUG", E.PISTAGE_RADAR, string.format(
      "aucun contact apparie autour de %s (plus proche a %.0f blocs, rayon %.0f)",
      V.format(positionAttendue),
      (distance ~= math.huge) and distance or -1, rayon))
    return false
  end

  local position = lirePosition(contact)
  local identifiant = lireIdentifiant(contact)
  if identifiant and not piste.identifiant then
    piste.identifiant = identifiant
    journal.info(E.PISTAGE_RADAR, "cible verrouillee, identifiant radar : " .. identifiant)
  end

  piste:integrer(position, lireVitesse(contact), noyau.maintenant(), criteresDegat)

  journal.limite("pistage", contexte.config.periodeJournalPistage or 5,
    "DEBUG", E.PISTAGE_RADAR, string.format(
      "cible %s | vitesse %.1f b/s | cap %s | contacts %d",
      V.format(position), V.norme(piste.vitesse),
      piste.cap and string.format("%.0f deg%s", piste.cap,
        piste.capFiable and "" or " (extrapole)") or "?",
      piste.contacts))

  return true
end

--------------------------------------------------------------------------------
-- 5. CONTEXTE RADAR
--------------------------------------------------------------------------------

function M.creerContexte(config, interception)
  local radar, cote, nomMethode = M.detecter(config)
  local blocRadar = config.radar or {}
  blocRadar.__interception = interception

  return {
    radar  = radar,
    cote   = cote,
    config = blocRadar,
    methode = nomMethode,
    -- peripheral.wrap renvoie des fonctions simples : on les appelle SANS
    -- passer le peripherique en premier argument (ce n'est pas une methode).
    scan = function(peripherique)
      return peripherique[nomMethode]()
    end,
  }
end

return M
