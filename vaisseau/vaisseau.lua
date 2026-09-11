--[[----------------------------------------------------------------------------
  DOOMSDAY SHIP - SYSTEME EMBARQUE, PHASE 1
  Serveur : AERONAUTICS WARFARE (Create Aeronautics / Avionics, NeoForge
  1.21.1, CC: Tweaked). Cible : ordinateur avance du ballon, moniteurs
  accoles, modem Ender.

  LIVRE (phases 1 a 4) : framework MFD, couche materielle a decouverte par
  methode, surveillance et alarmes, transpondeur FrenchNet, conscience de
  situation fusionnant les stations radar du sol et le radar du bord,
  recensement des soutes, avertisseur sonore, relais « now playing », et huit
  pages - propulsion, portance, navigation, SA, EW, armement, liaison, alertes.

  PAS LIVRE, ET POURQUOI : l'envoi de route a l'autopilote, le tir et le
  largage de leurres. Ces trois modules sont ABSENTS du depot (verifie branche
  par branche, docs/api_notes.md). Ils passent par vaisseau/liaisons.lua, qui
  refuse l'appel avec un motif lisible au lieu de faire semblant. Les pages
  EW et armement sont donc completes a l'affichage et INERTES a la commande,
  et elles l'annoncent en clair plutot que de laisser esperer autre chose.

  Les valeurs de propulsion et de portance dependent de l'API de Create
  Aeronautics, que je ne connais pas : le HAL les cherche PAR METHODE et
  'diagnostic' revele les vraies. Une mesure non liee s'affiche INDISPO.

  ACCENTS : les chaines affichees ou journalisees sont sans accents (terminal
  CC oriente octet). Les commentaires, jamais affiches, sont rédigés normalement.
--------------------------------------------------------------------------------]]

local VERSION_PROGRAMME = "1.0.0"

local ETAPES = {
  DEMARRAGE = "demarrage du systeme embarque", CHARGEMENT = "chargement des modules",
  CONFIGURATION = "chargement de la configuration", MATERIEL = "liaison materielle",
  LIAISONS = "integration des modules exterieurs", AFFICHAGE = "affichage multifonction",
  MESURES = "lecture des capteurs", ALARME = "alarme", RESEAU = "reseau FrenchNet",
  ETAT = "etat persistant", BOUCLE = "boucle principale", ARRET = "arret du systeme",
  SA = "conduite de la situation", RADAR = "radar du bord",
  SOUTE = "recensement des soutes", AUDIO = "avertisseur sonore",
  MUSIQUE = "relais musique",
}

--------------------------------------------------------------------------------
-- 1. CHEMINS ET JOURNAL
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

local REPERTOIRE     = repertoire()
local CHEMIN_CONFIG  = fs.combine(REPERTOIRE, "config_vaisseau.lua")
local CHEMIN_JOURNAL = fs.combine(REPERTOIRE, "vaisseau.log")
local CHEMIN_ETAT    = fs.combine(REPERTOIRE, "etat.dat")

local function horodatage()
  local ok, texte = pcall(function()
    return os.date("!%Y-%m-%d %H:%M:%S", math.floor(os.epoch("utc") / 1000))
  end)
  if ok and texte then return texte end
  return ("jour %d %s"):format(os.day(), textutils.formatTime(os.time(), true))
end

-- Ecriture GROUPEE : chaque ligne ecrite separement est une ouverture de
-- fichier, et le serveur les paie toutes. Une erreur part quand meme sur
-- disque immediatement, et rien n'attend plus de quelques secondes.
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

  local ligne = ("[%s] [%s] [etape: %s] %s")
    :format(horodatage(), niveau, etape or "?", tostring(message))
  if ecran then pcall(print, ligne) end
  if disque then
    journal.enAttente[#journal.enAttente + 1] = ligne
    journal.attenteDepuis = journal.attenteDepuis or os.clock()
    -- Une erreur n'attend jamais le lot : un poste qui plante emporterait le
    -- tampon, et c'est justement cette ligne-la qu'on voudrait relire.
    if rang >= NIVEAUX.ERREUR or #journal.enAttente >= journal.lotMax then
      journal.vider()
    end
  end
end

local function info(e, m)   ecrire("INFO", e, m) end
local function avert(e, m)  ecrire("AVERT", e, m) end
local function erreur(e, m) ecrire("ERREUR", e, m) end

-- os.pullEvent leve "Terminated" a la moindre pression sur Ctrl+T : une boucle
-- batie dessus meurt avant d'avoir pu s'arreter proprement. Une seule boucle
-- traite l'evenement (boucleTerminate).
local function attendreBrut(filtre)
  while true do
    local e = table.pack(os.pullEventRaw())
    if e[1] ~= "terminate" and (filtre == nil or e[1] == filtre) then
      return table.unpack(e, 1, e.n)
    end
  end
end

local function dormir(secondes)
  local minuteur = os.startTimer(secondes or 0)
  while true do
    local _, id = attendreBrut("timer")
    if id == minuteur then return end
  end
end

--------------------------------------------------------------------------------
-- 2. MODULES, CONFIGURATION, ETAT
--------------------------------------------------------------------------------

local function charger(nom, indispensable)
  local chemin = fs.combine(REPERTOIRE, nom)
  local charge, err = loadfile(chemin)
  local ok, module
  if charge then ok, module = pcall(charge) end
  if not charge or not ok or type(module) ~= "table" then
    if indispensable then
      printError(("[etape: %s] %s inutilisable : %s")
        :format(ETAPES.CHARGEMENT, nom, tostring(err or module)))
    end
    return nil
  end
  return module
end

local mfdModule   = charger("mfd.lua", true)
local halModule   = charger("hal.lua", true)
local liaisonsMod = charger("liaisons.lua", true)
local surveillMod = charger("surveillance.lua", true)

if not (mfdModule and halModule and liaisonsMod and surveillMod) then
  printError("Le systeme embarque ne peut pas demarrer sans ses modules de base.")
  return
end

-- Modules des phases 2 a 4. Chacun est FACULTATIF : un ballon qui n'a pas
-- copie sa.lua doit voler avec ses pages de phase 1 plutot que de refuser de
-- demarrer. Leur absence est journalisee a la construction, pas ici.
local saMod     = charger("sa.lua", false)
local invMod    = charger("inventaire.lua", false)
local audioMod  = charger("audio.lua", false)
local musiqueMod= charger("musique.lua", false)
local noyauMod  = charger("noyau.lua", false)     -- copie de command/noyau.lua
local scanMod   = charger("scanner.lua", false)   -- copie de command/scanner.lua

local cfg = {}
local etat = {
  arret = false, mode = "VEILLE",
  position = { x = 0, y = 64, z = 0 },
  waypoints = {}, zones = {},
  idCommand = nil, decouverteA = -1e9,
  compteurs = { mesures = 0, alarmes = 0, dessins = 0, transpondeur = 0,
                contacts = 0, emissionsRadar = 0 },
  menace = 0, alarmesActives = {},
}

local function chargerConfiguration()
  local charge = loadfile(CHEMIN_CONFIG)
  if not charge then
    avert(ETAPES.CONFIGURATION, "config_vaisseau.lua absent : valeurs par defaut")
    return
  end
  local ok, lue = pcall(charge)
  if not ok or type(lue) ~= "table" then
    erreur(ETAPES.CONFIGURATION, "configuration illisible : " .. tostring(lue))
    return
  end
  cfg = lue

  --[[
    Noms de protocole par defaut, appliques ICI et pas seulement dans le
    fichier de configuration livre. Une configuration tronquee ou recopiee a
    la main sans ces trois lignes rendait le ballon SOURD au poste de
    commandement - sans la moindre erreur, puisque comparer a nil est une
    comparaison parfaitement valide. Il restait alors en diffusion generale et
    n'entendait jamais l'annonce.
  ]]
  cfg.protocoleTranspondeur = cfg.protocoleTranspondeur or "frenchnet_transpondeur"
  cfg.protocoleAnnonce      = cfg.protocoleAnnonce      or "frenchnet_annonce"
  cfg.protocoleRadar        = cfg.protocoleRadar        or "frenchnet_radar"

  journal.seuilEcran   = NIVEAUX[cfg.journalNiveauEcran] or 1
  journal.seuilFichier = NIVEAUX[cfg.journalNiveauFichier] or 1
  journal.fichierActif = cfg.journalFichier ~= false
  journal.tailleMax    = cfg.journalTailleMax or 65536
  journal.lotMax       = cfg.journalLot or 24
  journal.ageMax       = cfg.journalAgeMax or 5
  info(ETAPES.CONFIGURATION, "configuration chargee")
end

local function enregistrerEtat()
  pcall(function()
    local f = fs.open(CHEMIN_ETAT, "w")
    if not f then return end
    local propulsion = etat.contexte and etat.contexte.propulsion
    f.write(textutils.serialise({
      waypoints = etat.waypoints,
      renouvelleA = propulsion and propulsion.renouvelleA,
    }))
    f.close()
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
    info(ETAPES.ETAT, ("etat restaure : %d waypoint(s)"):format(#etat.waypoints))
  end)
end

--------------------------------------------------------------------------------
-- 3. POSITION ET RESEAU
--------------------------------------------------------------------------------

-- Sans GPS, la carte est centree sur l'origine et le transpondeur emet sans
-- coordonnees : le poste au sol devra apparier par nom declare.
local function rafraichirPosition()
  local x, y, z = gps.locate(2, false)
  if x then
    etat.position = { x = x, y = y, z = z }
    if not etat.gpsVu then
      etat.gpsVu = true
      info(ETAPES.RESEAU, ("position GPS acquise : X=%.0f Y=%.0f Z=%.0f"):format(x, y, z))
    end
    return true
  end
  if etat.gpsVu then
    etat.gpsVu = false
    avert(ETAPES.RESEAU, "position GPS perdue : la carte se fige et le transpondeur " ..
      "emet sans coordonnees. Verifiez la constellation de balises.")
  end
  return false
end

local cote

local function ouvrirReseau()
  for _, nom in ipairs(peripheral.getNames()) do
    if peripheral.getType(nom) == "modem" then
      local ok, sansFil = pcall(peripheral.call, nom, "isWireless")
      cote = cote or nom
      if ok and sansFil then cote = nom break end   -- le sans-fil prime
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

-- Format releve dans command/transpondeur.lua (docs/api_notes.md 3.3). Sans
-- lui, le poste au sol classe le ballon INCONNU, avec les consequences prevues
-- par la doctrine de zone.
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
  -- Envoi cible tant que le poste est connu : un broadcast reveille TOUS les
  -- ordinateurs du serveur, quatre fois par seconde et pour rien.
  local envoi
  if etat.idCommand and (os.clock() - etat.decouverteA) <= 120 then
    envoi = pcall(rednet.send, etat.idCommand, trame, cfg.protocoleTranspondeur)
  else
    envoi = pcall(rednet.broadcast, trame, cfg.protocoleTranspondeur)
  end
  if envoi then etat.compteurs.transpondeur = etat.compteurs.transpondeur + 1 end
end

--------------------------------------------------------------------------------
-- 4. RADAR DU BORD
--    Le ballon peut porter son propre radar. Ses contacts servent DEUX FOIS :
--    a bord pour la page SA, et au sol - le ballon emet alors une trame
--    FRENCHNET_RADAR comme n'importe quelle station, ce que la section 6 du
--    cahier des charges demande.
--------------------------------------------------------------------------------

local radarBord, nomRadar, methodesRadar, relativesRadar

local function ouvrirRadarBord()
  if not scanMod then return false end
  local motif, inventaire
  radarBord, nomRadar, methodesRadar, motif, inventaire =
    scanMod.detecter(peripheral, cfg.peripheriqueRadar)
  if radarBord then
    info(ETAPES.RADAR, motif)
  else
    -- Pas de radar a bord n'est pas une panne : beaucoup de ballons n'en
    -- portent pas. On le dit une fois, avec l'inventaire reel, et on continue.
    avert(ETAPES.RADAR, motif or "aucun radar a bord")
  end
  return radarBord ~= nil
end

local function protegerRadar(fonction)
  local r = table.pack(pcall(fonction))
  if not r[1] then return false, r[2] end
  return true, table.unpack(r, 2, r.n)
end

--[[
  Un balayage. Retourne la liste de contacts en coordonnees ABSOLUES.

  Le referentiel (relatif au bloc radar ou absolu au monde) est deduit par
  scanner.deduireReferentiel, MAIS cette deduction suppose un radar loin de
  l'origine du monde - ce qui n'est pas garanti pour un ballon qui se deplace.
  'radarPositionsRelatives' permet donc de le figer en configuration, et c'est
  le reglage recommande a bord : se tromper decale toutes les pistes de
  plusieurs milliers de blocs.
]]
local function balayerRadarBord(maintenant)
  if not (radarBord and scanMod) then return nil end
  local bruts = scanMod.collecter(radarBord, methodesRadar, protegerRadar)
  if #bruts == 0 then return {} end

  local position = etat.position
  if cfg.radarPositionsRelatives ~= nil then
    relativesRadar = cfg.radarPositionsRelatives
  elseif relativesRadar == nil then
    local relatif, motif = scanMod.deduireReferentiel(bruts, position, cfg.porteeRadar)
    relativesRadar = relatif
    avert(ETAPES.RADAR, motif .. " Figez radarPositionsRelatives en configuration : " ..
      "un ballon qui bouge ne donne pas deux fois la meme deduction.")
  end
  return (scanMod.normaliser(bruts, position, relativesRadar))
end

--------------------------------------------------------------------------------
-- 5. ASSEMBLAGE
--------------------------------------------------------------------------------

local hal, liaisons, surveillance, systemeMfd
local sa, inventaire, audio, musique

local function construire()
  hal = halModule.nouveau(cfg, peripheral, ecrire)
  info(ETAPES.MATERIEL, ("%d mesure(s) liee(s), %d introuvable(s)"):format(hal:decouvrir()))

  liaisons = liaisonsMod.nouveau(cfg, ecrire)
  info(ETAPES.LIAISONS,
    ("%d module(s) exterieur(s) present(s), %d absent(s)"):format(liaisons:charger()))

  surveillance = surveillMod.nouveau(cfg)

  ------------------------------------------------------------------ phase 2
  if saMod then
    -- L'IFF du bord est celui du sol, appele en bibliotheque : deux IFF
    -- separes finiraient par se contredire par radio.
    if not noyauMod then
      avert(ETAPES.SA, "noyau.lua absent de /vaisseau : la page SA affichera les " ..
        "contacts SANS identification ami-ennemi. Copiez command/noyau.lua a bord.")
    end
    sa = saMod.nouveau(cfg, noyauMod, ecrire)
  else
    avert(ETAPES.SA, "sa.lua absent : pas de situation tactique a bord")
  end

  ------------------------------------------------------------------ phase 3
  if invMod then
    inventaire = invMod.nouveau(cfg, peripheral, ecrire)
    inventaire:decouvrir()
  end

  ------------------------------------------------------------------ phase 4
  if audioMod then
    audio = audioMod.nouveau(cfg, peripheral, ecrire)
    audio:decouvrir()
  end
  if musiqueMod then
    musique = musiqueMod.nouveau(cfg, http, ecrire)
    local mode, detail = musique:mode()
    info(ETAPES.MUSIQUE, ("relais musique en mode %s (%s)"):format(mode, tostring(detail)))
  end

  -- Les zones du theatre viennent de la CONFIGURATION : le poste au sol ne les
  -- diffuse pas (aucun protocole ne l'en charge, verifie dans command.lua).
  -- Sans elles, la carte du bord n'a pas de fond et l'IFF n'a pas de classe de
  -- zone - c'est dit plutot que devine.
  if type(cfg.zones) == "table" and #cfg.zones > 0 then
    etat.zones = cfg.zones
    info(ETAPES.SA, ("%d zone(s) du theatre chargee(s) depuis la configuration")
      :format(#etat.zones))
  else
    avert(ETAPES.SA, "aucune zone en configuration : la carte du bord n'aura pas " ..
      "de fond et la doctrine de zone ne sera pas appliquee a bord. Le poste au " ..
      "sol ne diffuse pas ses zones ; recopiez-les dans config_vaisseau.lua.")
  end

  local contexte = {
    config = cfg, hal = hal, liaisons = liaisons, journal = ecrire,
    etat = etat, position = etat.position, waypoints = etat.waypoints,
    zones = etat.zones, enregistrerEtat = enregistrerEtat,
    propulsion = { renouvelleA = etat.renouvelleA },
    sa = sa, sa_module = saMod, inventaire = inventaire, audio = audio,
    musique = musique, sa_pistes = {}, sa_menace = 0,
    alarmesActives = {}, maintenant = 0,
  }
  etat.contexte = contexte

  systemeMfd = mfdModule.nouveau({
    journal = ecrire, contexte = contexte, layout = cfg.layout or {},
    largeurMini = cfg.largeurMiniFenetre, hauteurMini = cfg.hauteurMiniFenetre,
  })

  -- Registre de pages : en ajouter une ne demande de toucher a rien d'autre.
  for _, nom in ipairs({ "propulsion", "portance", "navigation",
                         "sa", "ew", "armement", "liaison", "alertes" }) do
    local page = charger("pages/" .. nom .. ".lua", false)
    if not page then
      avert(ETAPES.AFFICHAGE, "page '" .. nom .. "' introuvable")
    else
      local ok, motif = systemeMfd:enregistrerPage(nom, page)
      if not ok then
        avert(ETAPES.AFFICHAGE, ("page '%s' refusee : %s"):format(nom, motif))
      end
    end
  end

  systemeMfd:detecterSurfaces()
  local fenetres = systemeMfd:appliquerLayout()
  info(ETAPES.AFFICHAGE, ("%d fenetre(s) placee(s)"):format(fenetres))
  if fenetres == 0 then
    avert(ETAPES.AFFICHAGE, "aucune fenetre : verifiez le layout et la taille des ecrans")
  end
end

--------------------------------------------------------------------------------
-- 6. BOUCLES
--------------------------------------------------------------------------------

-- Mesures composites attendues par la surveillance mais absentes du catalogue
-- du HAL : ce sont des rapports, pas des lectures.
local function mesuresCourantes()
  local mesures = hal:etat()
  local charge = hal:pourcentage("propulsion.stress", "propulsion.capacite")
  mesures["propulsion.charge"] =
    { valeur = charge, motif = charge == nil and "stress ou capacite indisponible" or nil }
  local energie = hal:pourcentage("energie.stock", "energie.capacite")
  mesures["energie.pourcentage"] =
    { valeur = energie, motif = energie == nil and "stock ou capacite d'energie indisponible" or nil }
  return mesures
end

--[[
  VERROU D'OCCUPATION, pour la mise a jour automatique.
  A bord, « occupe » veut dire : une menace est classee, ou une alarme est
  active. Basculer une version a ce moment-la eteindrait l'ecran et la sirene
  au seul instant ou l'equipage s'en sert.
  Ecrit sur changement, ou toutes les 10 secondes : chaque ecriture est une
  ouverture de fichier.
]]
local CHEMIN_OCCUPATION = "/.maj/occupation.dat"
local occupationPrecedente, occupationEcriteA = nil, -1e9

local function declarerOccupation(maintenant)
  local occupe = (etat.menace or 0) >= 2 or next(etat.alarmesActives) ~= nil
  if occupe == occupationPrecedente and (maintenant - occupationEcriteA) < 10 then return end
  occupationPrecedente, occupationEcriteA = occupe, maintenant

  pcall(function()
    if not fs.exists("/.maj") then fs.makeDir("/.maj") end
    local f = fs.open(CHEMIN_OCCUPATION, "w")
    if not f then return end
    local motif = occupe
      and (((etat.menace or 0) >= 2) and "menace classee" or "alarme active")
      or "veille"
    f.write(("{ instant = %d, occupe = %s, motif = %q }"):format(
      math.floor((os.epoch("utc") or 0) / 1000), occupe and "true" or "false", motif))
    f.close()
  end)
end

--[[
  Pose et levee d'alarme, en un seul endroit.
  Trois destinataires, parce qu'ils n'atteignent pas les memes gens : l'ecran
  (celui qui regarde), le son (celui qui ne regarde pas) et le journal (celui
  qui lira apres). Les faire diverger a trois appels separes se serait paye au
  premier oubli.
]]
local function poserAlarme(a)
  systemeMfd:alarme(a.cle, a.niveau, a.titre, a.lignes)
  etat.compteurs.alarmes = etat.compteurs.alarmes + 1
  etat.alarmesActives[a.cle] = { cle = a.cle, niveau = a.niveau, titre = a.titre }
  if audio then audio:signaler(a.niveau, os.clock()) end
  ecrire(a.niveau == "CRITIQUE" and "ERREUR" or "AVERT", ETAPES.ALARME,
    ("[%s] %s"):format(a.famille or "?", a.titre))
end

local function leverAlarme(cle)
  systemeMfd:leverAlarme(cle)
  etat.alarmesActives[cle] = nil
  -- Le son ne se tait que si PLUS RIEN n'est actif : une sirene qui s'arrete
  -- alors qu'une autre avarie tient encore ferait croire au retour au calme.
  if audio and next(etat.alarmesActives) == nil then audio:taire() end
end

-- Liste ordonnee des alarmes actives, pour la page alertes.
local function alarmesEnCours()
  local rang = { ATTENTION = 1, ALARME = 2, CRITIQUE = 3 }
  local liste = {}
  for _, a in pairs(etat.alarmesActives) do liste[#liste + 1] = a end
  table.sort(liste, function(x, y)
    return (rang[x.niveau] or 0) > (rang[y.niveau] or 0)
  end)
  return liste
end

local function boucleMesures()
  while not etat.arret do
    local maintenant = os.clock()
    rafraichirPosition()
    etat.contexte.position = etat.position
    etat.compteurs.mesures = etat.compteurs.mesures + 1

    local aPoser, aLever = surveillance:evaluer(mesuresCourantes(), maintenant)
    for _, a in ipairs(aPoser) do poserAlarme(a) end
    for _, cle in ipairs(aLever) do leverAlarme(cle) end

    -- Rafraichi ICI et pas seulement dans la boucle SA : celle-ci n'est armee
    -- que si sa.lua est a bord, et la page alertes doit rester juste sans lui.
    etat.contexte.alarmesActives = alarmesEnCours()
    etat.contexte.maintenant = maintenant
    declarerOccupation(maintenant)

    -- Vidange a l'age : sans elle, un poste calme garderait ses dernieres
    -- lignes en memoire jusqu'au lot suivant, et les perdrait a la panne.
    if journal.attenteDepuis and (maintenant - journal.attenteDepuis) >= journal.ageMax then
      journal.vider()
    end

    dormir(cfg.intervalleMesures or 1)
  end
end

local function boucleAffichage()
  while not etat.arret do
    local e = table.pack(os.pullEventRaw())
    if e[1] ~= "terminate" then systemeMfd:evenement(table.unpack(e, 1, e.n)) end
    etat.compteurs.dessins = etat.compteurs.dessins + systemeMfd:dessiner()
  end
end

--[[
  CONDUITE DE LA SITUATION (phase 2).
  Purge, evaluation, puis alarme EW. L'alarme de menace est une alarme comme
  les autres - meme pile, meme son, meme journal : un equipage ne doit pas
  avoir a apprendre deux langages d'alerte selon que la panne vient du ballon
  ou du ciel.
]]
local CLE_MENACE = "menace:sa"

local function boucleSA()
  while not etat.arret do
    local maintenant = os.clock()
    sa:purger(maintenant)
    local pistes, pire, pirePiste = sa:evaluer(etat.position, maintenant,
      cfg.codes, cfg.roster, etat.zones)

    local ctx = etat.contexte
    ctx.sa_pistes, ctx.sa_menace, ctx.maintenant = pistes, pire, maintenant
    etat.menace = pire

    --[[
      Deux niveaux d'alerte, pas un seul.

      Ne sonner qu'a IMMINENTE laisserait muet le cas le plus frequent : un
      inconnu qui fonce sur le ballon n'atteint jamais ce niveau (il est
      reserve aux missiles), et l'equipage l'apprendrait a l'impact. Sonner a
      tout, a l'inverse, apprendrait a ignorer la sirene.

      ATTENTION -> alarme ALARME.  IMMINENTE -> alarme CRITIQUE.
      L'oreille fait la difference : ce sont deux signatures sonores distinctes.
    ]]
    local NIVEAU = { [2] = "ALARME", [3] = "CRITIQUE" }
    local TITRE  = { [2] = "MENACE", [3] = "MENACE IMMINENTE" }
    local posee = etat.alarmesActives[CLE_MENACE]

    if pire >= 2 then
      -- Comparaison de NIVEAU, pas simple presence : sans cela une menace
      -- passee d'ATTENTION a IMMINENTE garderait la sonnerie la plus douce.
      if not posee or posee.niveau ~= NIVEAU[pire] then
        local nom = pirePiste and (pirePiste.nom or pirePiste.id) or "?"
        poserAlarme({ cle = CLE_MENACE, niveau = NIVEAU[pire], famille = "MENACE",
          titre = TITRE[pire],
          lignes = { tostring(nom),
                     tostring(pirePiste and pirePiste.motifMenace or ""),
                     ctx.liaisons and ctx.liaisons:disponible("ads")
                       and "Page EW : largage de leurres"
                       or "LEURRES INDISPONIBLES (ADS absent) : manoeuvrez" } })
      end
    elseif posee then
      leverAlarme(CLE_MENACE)
    end

    dormir(cfg.intervalleSA or 1)
  end
end

--[[
  RADAR DU BORD. Ses contacts alimentent la page SA, et sont emis au sol au
  format FRENCHNET_RADAR - le ballon devient une station mobile.
  Emission CIBLEE vers le poste tant qu'il est connu : un broadcast reveille
  tous les ordinateurs du serveur a chaque balayage.
]]
local function boucleRadarBord()
  while not etat.arret do
    local maintenant = os.clock()
    local contacts = balayerRadarBord(maintenant)
    if contacts then
      etat.compteurs.contacts = #contacts
      local trame = {
        protocole = "FRENCHNET_RADAR", version = 1,
        station = cfg.identifiant or "DOOMSDAY",
        designation = cfg.designation,
        x = etat.position.x, y = etat.position.y, z = etat.position.z,
        portee = cfg.porteeRadar or 512,
        contacts = contacts,
      }
      -- A bord d'abord : la page SA ne doit pas dependre du reseau pour
      -- afficher ce que le ballon voit lui-meme.
      sa:integrerRadar(trame, maintenant, "BORD")
      if cote and cfg.emettreRadar ~= false then
        local envoi
        if etat.idCommand and (maintenant - etat.decouverteA) <= 120 then
          envoi = pcall(rednet.send, etat.idCommand, trame, cfg.protocoleRadar)
        else
          envoi = pcall(rednet.broadcast, trame, cfg.protocoleRadar)
        end
        if envoi then etat.compteurs.emissionsRadar = etat.compteurs.emissionsRadar + 1 end
      end
    end
    dormir(cfg.intervalleRadar or 2)
  end
end

-- Recensement des soutes : lent par choix. Chaque list() est un appel sur le
-- thread principal du serveur, et un coffre ne se vide pas en une seconde.
local function boucleInventaire()
  while not etat.arret do
    inventaire:recenser(os.clock())
    dormir(cfg.intervalleInventaire or 15)
  end
end

-- Avertisseur sonore : petits pas frequents, jamais de note bloquante.
local function boucleAudio()
  while not etat.arret do
    audio:jouerPas(os.clock())
    dormir(cfg.intervallePas or 0.25)
  end
end

-- Relais musique. Sans HTTP la boucle ne s'arme pas du tout : elle dormirait
-- pour rien, et la page affiche deja le motif.
local function boucleMusique()
  while not etat.arret do
    musique:interroger(os.clock())
    dormir(cfg.intervalleMusique or 20)
  end
end

local function boucleTranspondeur()
  while not etat.arret do
    emettreTranspondeur()
    dormir(cfg.intervalleTranspondeur or 4)
  end
end

--[[
  Reception. Le ballon ecoute quatre choses, et ignore tout le reste :
  l'annonce du poste (pour lui parler en direct au lieu de diffuser), les
  trames des stations radar du sol, les transpondeurs des autres appareils, et
  le relais musique quand il pousse par reseau faute de HTTP.
]]
local function boucleReseau()
  while not etat.arret do
    local e = table.pack(os.pullEventRaw())
    if e[1] == "rednet_message" then
      local expediteur, message, protocole = e[2], e[3], e[4]
      local maintenant = os.clock()
      if type(message) ~= "table" then
        -- rien : une trame qui n'est pas une table n'est pas des notres
      elseif message.protocole == "FRENCHNET_COMMAND_ICI"
             and protocole == cfg.protocoleAnnonce then
        if etat.idCommand ~= expediteur then
          info(ETAPES.RESEAU, ("poste de commandement '%s' decouvert sur l'ordinateur %d")
            :format(tostring(message.identifiant), expediteur))
        end
        etat.idCommand, etat.decouverteA = expediteur, maintenant

      elseif message.protocole == "FRENCHNET_RADAR" and sa then
        -- Les stations du sol voient ce que le ballon ne voit pas : leurs
        -- contacts valent autant que les siens, et sont fusionnes, pas empiles.
        sa:integrerRadar(message, maintenant, "SOL")

      elseif message.protocole == "FRENCHNET_TRANSPONDEUR" and sa then
        -- Un transpondeur entendu ici sert a identifier une piste. Le ballon
        -- n'accorde aucun laissez-passer de lui-meme : c'est noyau.lua qui
        -- tranche, avec les memes regles qu'au sol.
        sa:integrerTranspondeur(message, maintenant)

      elseif message.protocole == "FRENCHNET_MUSIQUE" and musique then
        musique:recevoirTrame(message, maintenant)
      end
    end
  end
end

local function boucleBattement()
  while not etat.arret do
    dormir(cfg.battementSecondes or 60)
    local liees, manquantes, lectures, echecs = hal:resume()
    local actives, muets = surveillance:resume()
    local pistes, stations = 0, 0
    if sa then pistes, stations = sa:resume() end
    local soutes = inventaire and select(1, inventaire:resume()) or 0
    info("battement", ("%s | mesures %d/%d liees, %d lecture(s), %d echec(s) | " ..
      "%d alarme(s), %d capteur(s) muet(s) | SA %d piste(s), %d station(s), menace %s | " ..
      "%d soute(s) | %d dessin(s), %d transpondeur, %d emission(s) radar")
      :format(cfg.identifiant or "?", liees, liees + manquantes, lectures, echecs,
        actives, muets, pistes, stations,
        saMod and saMod.NOM_MENACE[etat.menace] or "?", soutes,
        etat.compteurs.dessins, etat.compteurs.transpondeur, etat.compteurs.emissionsRadar))
    journal.vider()
    enregistrerEtat()
  end
end

local function boucleTerminate()
  while true do
    if os.pullEventRaw("terminate") == "terminate" then
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
-- 7. POINT D'ENTREE
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
    ouvrirRadarBord()
    info(ETAPES.DEMARRAGE, ("%s operationnel. Lancez 'diagnostic' pour relever les " ..
      "vrais peripheriques du ballon."):format(cfg.identifiant or "vaisseau"))
    --[[
      waitForAny rend la main des qu'UNE SEULE de ses fonctions se termine, et
      arrete alors toutes les autres. Une boucle de phase 2-4 qui sortirait
      parce que son module manque arreterait donc le systeme entier, et le
      point d'entree le relancerait en boucle sans fin.

      On ne passe donc a waitForAny que les boucles REELLEMENT armees. Les
      autres n'existent pas, plutot que d'exister et de dormir : une boucle
      vide consommerait un minuteur toutes les secondes pour ne rien faire.
    ]]
    local boucles = { boucleMesures, boucleAffichage, boucleTranspondeur,
                      boucleReseau, boucleBattement, boucleTerminate }
    local function armer(condition, boucle, nom)
      if condition then boucles[#boucles + 1] = boucle
      else info(ETAPES.BOUCLE, "boucle '" .. nom .. "' non armee") end
    end
    armer(sa ~= nil, boucleSA, "situation")
    armer(radarBord ~= nil and sa ~= nil, boucleRadarBord, "radar du bord")
    armer(inventaire ~= nil, boucleInventaire, "soutes")
    armer(audio ~= nil, boucleAudio, "audio")
    armer(musique ~= nil and http ~= nil, boucleMusique, "musique")

    -- Silence apres l'armement : sans cela, la liste des boucles reellement
    -- armees - l'information qui dit ce que ce ballon sait faire - n'allait
    -- que sur le disque.
    journal.silencieux = true
    parallel.waitForAny(table.unpack(boucles))
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
  avert(ETAPES.DEMARRAGE, ("redemarrage automatique dans %ds"):format(delai))
  -- Seul sleep du fichier, donc seul point sensible a Ctrl+T : c'est voulu,
  -- c'est la porte de sortie quand le systeme replante en boucle.
  sleep(delai)
  delai = math.min(delai * 2, cfg.redemarrageDelaiMax or 60)
end
