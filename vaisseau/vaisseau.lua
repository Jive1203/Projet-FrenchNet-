--[[----------------------------------------------------------------------------
  DOOMSDAY SHIP - SYSTEME EMBARQUE, PHASE 1
  --------------------------------------------------------------------------
  Serveur    : AERONAUTICS WARFARE (Create Aeronautics / Avionics, NeoForge
               1.21.1, CC: Tweaked)
  Cible      : ordinateur avance du ballon, moniteurs accoles, modem Ender

  CE QUE CETTE PHASE LIVRE
    framework MFD (surfaces, fenetres, registre de pages, layout persiste),
    couche materielle a decouverte par methode, surveillance et alarmes,
    pages Propulsion, Portance/Enveloppe et Navigation, transpondeur FrenchNet.

  CE QU'ELLE NE LIVRE PAS, ET POURQUOI
    L'envoi de route a l'autopilote, le tir et les contre-mesures. Ces trois
    modules sont ABSENTS du depot - verifie branche par branche, voir
    docs/api_notes.md. Ils passent par vaisseau/liaisons.lua, qui refuse
    l'appel avec un motif lisible au lieu de faire semblant.

  Les valeurs de propulsion et de portance dependent de l'API de Create
  Aeronautics, que je ne connais pas. Le HAL les cherche PAR METHODE et
  'diagnostic' revele les vraies. Une mesure non liee s'affiche INDISPO.

  NOTE SUR LES ACCENTS : les chaines affichees ou journalisees sont sans
  accents (terminal CC: Tweaked oriente octet). Les commentaires, jamais
  affiches, sont rédigés normalement.
--------------------------------------------------------------------------------]]

local VERSION_PROGRAMME = "1.0.0"

local ETAPES = {
  DEMARRAGE        = "demarrage du systeme embarque",
  CHARGEMENT       = "chargement des modules",
  CONFIGURATION    = "chargement de la configuration",
  MATERIEL         = "liaison materielle",
  LIAISONS         = "integration des modules exterieurs",
  AFFICHAGE        = "affichage multifonction",
  MESURES          = "lecture des capteurs",
  ALARME           = "alarme",
  RESEAU           = "reseau FrenchNet",
  ETAT             = "etat persistant",
  BOUCLE           = "boucle principale",
  ARRET            = "arret du systeme",
}

--------------------------------------------------------------------------------
-- 1. CHEMINS ET OUTILS
--------------------------------------------------------------------------------

local function repertoire()
  if shell and shell.getRunningProgram then
    local ok, chemin = pcall(shell.getRunningProgram)
    if ok and chemin then
      local d = fs.getDir(chemin)
      if d and d ~= "" and d ~= "." then return d end
    end
  end
  return "vaisseau"
end

local REPERTOIRE    = repertoire()
local CHEMIN_CONFIG = fs.combine(REPERTOIRE, "config_vaisseau.lua")
local CHEMIN_JOURNAL= fs.combine(REPERTOIRE, "vaisseau.log")
local CHEMIN_ETAT   = fs.combine(REPERTOIRE, "etat.dat")

local function horodatage()
  local ok, texte = pcall(function()
    return os.date("!%Y-%m-%d %H:%M:%S", math.floor(os.epoch("utc") / 1000))
  end)
  if ok and texte then return texte end
  return string.format("jour %d %s", os.day(), textutils.formatTime(os.time(), true))
end

--------------------------------------------------------------------------------
-- 2. JOURNAL - meme discipline que le reste de FrenchNet : ecriture groupee,
--    une erreur part sur disque immediatement, rien n'attend plus de quelques
--    secondes.
--------------------------------------------------------------------------------

local NIVEAUX = { DEBUG = 0, INFO = 1, AVERT = 2, ERREUR = 3, CRITIQUE = 4 }
local journal = {
  seuilEcran = 1, seuilFichier = 1, fichierActif = true,
  enAttente = {}, attenteDepuis = nil, lotMax = 24, ageMax = 5,
  tailleMax = 65536, silencieux = false,
}

function journal.vider()
  if #journal.enAttente == 0 or not journal.fichierActif then
    journal.attenteDepuis = nil
    return
  end
  pcall(function()
    if fs.exists(CHEMIN_JOURNAL) and fs.getSize(CHEMIN_JOURNAL) >= journal.tailleMax then
      if fs.exists(CHEMIN_JOURNAL .. ".1") then fs.delete(CHEMIN_JOURNAL .. ".1") end
      fs.move(CHEMIN_JOURNAL, CHEMIN_JOURNAL .. ".1")
    end
    local f = fs.open(CHEMIN_JOURNAL, "a")
    if f then
      for _, ligne in ipairs(journal.enAttente) do f.writeLine(ligne) end
      f.close()
    end
  end)
  journal.enAttente, journal.attenteDepuis = {}, nil
end

local function ecrire(niveau, etape, message)
  local rang = NIVEAUX[niveau] or 1
  local ecran  = rang >= journal.seuilEcran and not journal.silencieux
  local disque = journal.fichierActif and rang >= journal.seuilFichier
  if not (ecran or disque) then return end

  local ligne = string.format("[%s] [%s] [etape: %s] %s",
    horodatage(), niveau, etape or "?", tostring(message))
  if ecran then pcall(print, ligne) end
  if disque then
    journal.enAttente[#journal.enAttente + 1] = ligne
    journal.attenteDepuis = journal.attenteDepuis or os.clock()
    if rang >= NIVEAUX.ERREUR or #journal.enAttente >= journal.lotMax then
      journal.vider()
    end
  end
end

local function info(e, m)  ecrire("INFO", e, m) end
local function avert(e, m) ecrire("AVERT", e, m) end
local function erreur(e, m) ecrire("ERREUR", e, m) end

--------------------------------------------------------------------------------
-- 3. ATTENTE INSENSIBLE A Ctrl+T
--    os.pullEvent leve une erreur "Terminated" a la moindre pression sur
--    Ctrl+T : une boucle batie dessus meurt avant d'avoir pu s'arreter
--    proprement. Une seule boucle traite l'evenement.
--------------------------------------------------------------------------------

local function attendreBrut(filtre)
  while true do
    local evenement = table.pack(os.pullEventRaw())
    if evenement[1] ~= "terminate"
       and (filtre == nil or evenement[1] == filtre) then
      return table.unpack(evenement, 1, evenement.n)
    end
  end
end

local function dormir(secondes)
  local minuteur = os.startTimer(secondes or 0)
  while true do
    local _, identifiant = attendreBrut("timer")
    if identifiant == minuteur then return end
  end
end

--------------------------------------------------------------------------------
-- 4. CHARGEMENT DES MODULES
--------------------------------------------------------------------------------

local function charger(nom, indispensable)
  local chemin = fs.combine(REPERTOIRE, nom)
  local charge, err = loadfile(chemin)
  if not charge then
    if indispensable then
      printError("[etape: " .. ETAPES.CHARGEMENT .. "] " .. nom .. " introuvable : " .. tostring(err))
    end
    return nil
  end
  local ok, module = pcall(charge)
  if not ok or type(module) ~= "table" then
    if indispensable then
      printError("[etape: " .. ETAPES.CHARGEMENT .. "] " .. nom .. " invalide : " .. tostring(module))
    end
    return nil
  end
  return module
end

local mfdModule    = charger("mfd.lua", true)
local halModule    = charger("hal.lua", true)
local liaisonsMod  = charger("liaisons.lua", true)
local surveillMod  = charger("surveillance.lua", true)

if not (mfdModule and halModule and liaisonsMod and surveillMod) then
  printError("Le systeme embarque ne peut pas demarrer sans ses modules de base.")
  return
end

--------------------------------------------------------------------------------
-- 5. ETAT ET CONFIGURATION
--------------------------------------------------------------------------------

local cfg = {}
local etat = {
  arret = false, mode = "VEILLE",
  position = { x = 0, y = 64, z = 0 },
  waypoints = {}, zones = {},
  idCommand = nil, decouverteA = -1e9,
  compteurs = { mesures = 0, alarmes = 0, dessins = 0, transpondeur = 0 },
}

local function chargerConfiguration()
  local charge = loadfile(CHEMIN_CONFIG)
  if not charge then
    avert(ETAPES.CONFIGURATION, "config_vaisseau.lua absent : valeurs par defaut")
    cfg = {}
    return
  end
  local ok, table_ = pcall(charge)
  if ok and type(table_) == "table" then
    cfg = table_
    journal.seuilEcran   = NIVEAUX[cfg.journalNiveauEcran] or 1
    journal.seuilFichier = NIVEAUX[cfg.journalNiveauFichier] or 1
    journal.fichierActif = cfg.journalFichier ~= false
    journal.tailleMax    = cfg.journalTailleMax or 65536
    journal.lotMax       = cfg.journalLot or 24
    journal.ageMax       = cfg.journalAgeMax or 5
    info(ETAPES.CONFIGURATION, "configuration chargee")
  else
    erreur(ETAPES.CONFIGURATION, "configuration illisible : " .. tostring(table_))
    cfg = {}
  end
end

local function enregistrerEtat()
  pcall(function()
    local f = fs.open(CHEMIN_ETAT, "w")
    if f then
      f.write(textutils.serialise({
        waypoints = etat.waypoints,
        renouvelleA = etat.contexte and etat.contexte.propulsion
          and etat.contexte.propulsion.renouvelleA,
      }))
      f.close()
    end
  end)
end

local function chargerEtat()
  if not fs.exists(CHEMIN_ETAT) then return end
  pcall(function()
    local f = fs.open(CHEMIN_ETAT, "r")
    if not f then return end
    local donnees = textutils.unserialise(f.readAll() or "")
    f.close()
    if type(donnees) ~= "table" then return end
    if type(donnees.waypoints) == "table" then etat.waypoints = donnees.waypoints end
    etat.renouvelleA = donnees.renouvelleA
    info(ETAPES.ETAT, string.format("etat restaure : %d waypoint(s)", #etat.waypoints))
  end)
end

--------------------------------------------------------------------------------
-- 6. POSITION
--    Le GPS de la constellation FrenchNet donne la position du ballon. Sans
--    lui, la carte est centree sur l'origine et le transpondeur emet sans
--    coordonnees : le poste au sol devra alors apparier par nom declare.
--------------------------------------------------------------------------------

local function rafraichirPosition()
  local x, y, z = gps.locate(2, false)
  if x then
    etat.position = { x = x, y = y, z = z }
    if not etat.gpsVu then
      etat.gpsVu = true
      info(ETAPES.RESEAU, string.format("position GPS acquise : X=%.0f Y=%.0f Z=%.0f", x, y, z))
    end
    return true
  end
  if etat.gpsVu then
    etat.gpsVu = false
    avert(ETAPES.RESEAU,
      "position GPS perdue : la carte se fige et le transpondeur emet sans coordonnees. " ..
      "Verifiez la constellation de balises.")
  end
  return false
end

--------------------------------------------------------------------------------
-- 7. RESEAU FRENCHNET
--------------------------------------------------------------------------------

local cote

local function ouvrirReseau()
  for _, nom in ipairs(peripheral.getNames()) do
    if peripheral.getType(nom) == "modem" then
      local m = peripheral.wrap(nom)
      local ok, sansFil = pcall(m.isWireless)
      if ok and sansFil then cote = nom break end
      cote = cote or nom
    end
  end
  if not cote then
    avert(ETAPES.RESEAU,
      "aucun modem : le ballon sera INVISIBLE de FrenchNet Command et classe INCONNU")
    return false
  end
  local ok = pcall(rednet.open, cote)
  if ok then info(ETAPES.RESEAU, "rednet ouvert sur '" .. cote .. "'") end
  return ok
end

-- Transpondeur : format releve dans command/transpondeur.lua, voir
-- docs/api_notes.md section 3.3. Sans lui, le poste au sol classe le ballon
-- INCONNU, avec les consequences prevues par la doctrine de zone.
local function emettreTranspondeur()
  if not cote then return end
  local code = cfg.codeTranspondeur
  if type(code) ~= "string" or code == "" then
    if not etat.codeSignale then
      etat.codeSignale = true
      avert(ETAPES.RESEAU,
        "aucun codeTranspondeur configure : FrenchNet Command classera ce ballon INCONNU")
    end
    return
  end
  local trame = {
    protocole = "FRENCHNET_TRANSPONDEUR",
    identifiant = cfg.identifiant, nom = cfg.identifiant, code = code,
    x = etat.position.x, y = etat.position.y, z = etat.position.z,
  }
  local envoi
  if etat.idCommand and (os.clock() - etat.decouverteA) <= 120 then
    envoi = pcall(rednet.send, etat.idCommand, trame, cfg.protocoleTranspondeur)
  else
    envoi = pcall(rednet.broadcast, trame, cfg.protocoleTranspondeur)
  end
  if envoi then etat.compteurs.transpondeur = etat.compteurs.transpondeur + 1 end
end

--------------------------------------------------------------------------------
-- 8. ASSEMBLAGE
--------------------------------------------------------------------------------

local hal, liaisons, surveillance, systemeMfd

local function construire()
  hal = halModule.nouveau(cfg, peripheral, ecrire)
  local liees, manquantes = hal:decouvrir()
  info(ETAPES.MATERIEL, string.format(
    "%d mesure(s) liee(s), %d introuvable(s)", liees, manquantes))

  liaisons = liaisonsMod.nouveau(cfg, ecrire)
  local presents, absents = liaisons:charger()
  info(ETAPES.LIAISONS, string.format(
    "%d module(s) exterieur(s) present(s), %d absent(s)", presents, absents))

  surveillance = surveillMod.nouveau(cfg)

  local contexte = {
    config = cfg, hal = hal, liaisons = liaisons, journal = ecrire,
    etat = etat, position = etat.position, waypoints = etat.waypoints,
    zones = etat.zones, enregistrerEtat = enregistrerEtat,
    propulsion = { renouvelleA = etat.renouvelleA },
  }
  etat.contexte = contexte

  systemeMfd = mfdModule.nouveau({
    journal = ecrire, contexte = contexte, layout = cfg.layout or {},
    largeurMini = cfg.largeurMiniFenetre, hauteurMini = cfg.hauteurMiniFenetre,
  })

  -- Registre de pages : en ajouter une ne demande de toucher a rien d'autre.
  for _, nom in ipairs({ "propulsion", "portance", "navigation" }) do
    local page = charger("pages/" .. nom .. ".lua", false)
    if page then
      local ok, motif = systemeMfd:enregistrerPage(nom, page)
      if not ok then
        avert(ETAPES.AFFICHAGE, string.format("page '%s' refusee : %s", nom, motif))
      end
    else
      avert(ETAPES.AFFICHAGE, "page '" .. nom .. "' introuvable")
    end
  end

  systemeMfd:detecterSurfaces()
  local fenetres = systemeMfd:appliquerLayout()
  info(ETAPES.AFFICHAGE, string.format("%d fenetre(s) placee(s)", fenetres))
  if fenetres == 0 then
    avert(ETAPES.AFFICHAGE,
      "aucune fenetre : verifiez le layout et la taille des ecrans")
  end
end

--------------------------------------------------------------------------------
-- 9. BOUCLES
--------------------------------------------------------------------------------

-- Mesures composites attendues par la surveillance mais absentes du catalogue
-- brut du HAL : ce sont des rapports, pas des lectures.
local function mesuresCourantes()
  local mesures = hal:etat()
  local charge = hal:pourcentage("propulsion.stress", "propulsion.capacite")
  mesures["propulsion.charge"] = { valeur = charge,
    motif = charge == nil and "stress ou capacite indisponible" or nil }
  local energie = hal:pourcentage("energie.stock", "energie.capacite")
  mesures["energie.pourcentage"] = { valeur = energie,
    motif = energie == nil and "stock ou capacite d'energie indisponible" or nil }
  return mesures
end

local function boucleMesures()
  while not etat.arret do
    local maintenant = os.clock()
    rafraichirPosition()
    etat.contexte.position = etat.position

    local mesures = mesuresCourantes()
    etat.compteurs.mesures = etat.compteurs.mesures + 1

    local aPoser, aLever = surveillance:evaluer(mesures, maintenant)
    for _, alarme in ipairs(aPoser) do
      systemeMfd:alarme(alarme.cle, alarme.niveau, alarme.titre, alarme.lignes)
      etat.compteurs.alarmes = etat.compteurs.alarmes + 1
      ecrire(alarme.niveau == "CRITIQUE" and "ERREUR" or "AVERT", ETAPES.ALARME,
        string.format("[%s] %s", alarme.famille or "?", alarme.titre))
    end
    for _, cle in ipairs(aLever) do systemeMfd:leverAlarme(cle) end

    journal.viderSiVieux = journal.viderSiVieux or function() end
    if journal.attenteDepuis and (maintenant - journal.attenteDepuis) >= journal.ageMax then
      journal.vider()
    end

    dormir(cfg.intervalleMesures or 1)
  end
end

local function boucleAffichage()
  while not etat.arret do
    local evenement = table.pack(os.pullEventRaw())
    if evenement[1] ~= "terminate" then
      systemeMfd:evenement(table.unpack(evenement, 1, evenement.n))
    end
    etat.compteurs.dessins = etat.compteurs.dessins + systemeMfd:dessiner()
  end
end

local function boucleTranspondeur()
  while not etat.arret do
    emettreTranspondeur()
    dormir(cfg.intervalleTranspondeur or 4)
  end
end

local function boucleReseau()
  while not etat.arret do
    local evenement = table.pack(os.pullEventRaw())
    if evenement[1] == "rednet_message" then
      local expediteur, message, protocole = evenement[2], evenement[3], evenement[4]
      if protocole == cfg.protocoleAnnonce and type(message) == "table"
         and message.protocole == "FRENCHNET_COMMAND_ICI" then
        if etat.idCommand ~= expediteur then
          info(ETAPES.RESEAU, string.format(
            "poste de commandement '%s' decouvert sur l'ordinateur %d",
            tostring(message.identifiant), expediteur))
        end
        etat.idCommand, etat.decouverteA = expediteur, os.clock()
      end
    end
  end
end

local function boucleBattement()
  while not etat.arret do
    dormir(cfg.battementSecondes or 60)
    local liees, manquantes, lectures, echecs = hal:resume()
    local actives, muets = surveillance:resume()
    info("battement", string.format(
      "%s | %d mesure(s) liee(s), %d manquante(s), %d lecture(s), %d echec(s) | " ..
      "%d alarme(s) active(s), %d capteur(s) muet(s) | %d dessin(s), %d trame(s) transpondeur",
      cfg.identifiant or "?", liees, manquantes, lectures, echecs,
      actives, muets, etat.compteurs.dessins, etat.compteurs.transpondeur))
    journal.vider()
    enregistrerEtat()
  end
end

local function boucleTerminate()
  while true do
    local evenement = os.pullEventRaw("terminate")
    if evenement == "terminate" then
      if cfg.arretParTerminate == false then
        avert(ETAPES.ARRET, "Ctrl+T ignore : le systeme est en autonomie totale")
      else
        info(ETAPES.ARRET, "arret demande par l'equipage (Ctrl+T)")
        etat.arret = true
        return
      end
    end
  end
end

--------------------------------------------------------------------------------
-- 10. POINT D'ENTREE
--------------------------------------------------------------------------------

local delai = 3
while true do
  local ok, err = pcall(function()
    term.clear() term.setCursorPos(1, 1)
    info(ETAPES.DEMARRAGE, "systeme embarque Doomsday Ship " .. VERSION_PROGRAMME)
    chargerConfiguration()
    chargerEtat()
    ouvrirReseau()
    construire()
    info(ETAPES.DEMARRAGE, string.format(
      "%s operationnel. Lancez 'diagnostic' pour relever les vrais peripheriques du ballon.",
      cfg.identifiant or "vaisseau"))
    journal.silencieux = true
    parallel.waitForAny(boucleMesures, boucleAffichage, boucleTranspondeur,
                        boucleReseau, boucleBattement, boucleTerminate)
  end)

  journal.silencieux = false
  if etat.arret then
    info(ETAPES.ARRET, "arret propre du systeme embarque")
    enregistrerEtat()
    journal.vider()
    return
  end
  if not ok then
    ecrire("CRITIQUE", ETAPES.BOUCLE, "le systeme s'est interrompu : " .. tostring(err))
    journal.vider()
  end
  avert(ETAPES.DEMARRAGE, string.format("redemarrage automatique dans %ds", delai))
  sleep(delai)
  delai = math.min(delai * 2, cfg.redemarrageDelaiMax or 60)
end
