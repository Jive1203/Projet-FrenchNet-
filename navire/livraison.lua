--[[----------------------------------------------------------------------------
  FRENCHNET / AERONAUTICS WARFARE
  Systeme de livraison automatise embarque - dirigeable Create Aeronautics
  --------------------------------------------------------------------------
  Role      : recevoir des commandes publiques (borne ouverte a tous les
              joueurs et a toutes les factions), charger la marchandise dans
              le grand conteneur source, voler jusqu'aux coordonnees choisies
              par le client, encaisser le paiement, deposer la cargaison, puis
              rentrer seul a un point de retour.
  Cible     : calculateur avance embarque + modem Ender + modems filaires
              relies aux soutes.
  Vol       : ENTIEREMENT delegue au module d'autopilote standardise, via
              navire/autopilote.lua. Aucune boucle d'asservissement ici.
  Autonomie : supervision interne, reprise sur disque, relance automatique
              avec temporisation progressive, aucune intervention humaine.
  Journal   : chaque erreur porte l'ETAPE exacte ou elle survient.

  NOTE SUR LES ACCENTS : les chaines affichees a l'ecran et ecrites dans le
  journal sont volontairement sans accents. Le terminal de CC: Tweaked est
  oriente octet : un caractere accentue en UTF-8 y apparaitrait sous forme de
  deux glyphes parasites. Les commentaires, jamais affiches, sont eux rediges
  normalement.
--------------------------------------------------------------------------------]]

local VERSION_PROGRAMME = "1.0.0"

--------------------------------------------------------------------------------
-- 1. NOMENCLATURE DES ETAPES
--    Reprise telle quelle dans le journal : un plantage se localise d'un coup
--    d'oeil, sans relire le code.
--------------------------------------------------------------------------------

local ETAPES = {
  DEMARRAGE            = "demarrage du superviseur",
  CHARGEMENT_CONFIG    = "chargement de la configuration vehicule",
  VALIDATION_CONFIG    = "validation de la configuration vehicule",
  CHARGEMENT_MODULES   = "chargement des modules communs",
  INIT_JOURNAL         = "initialisation du journal",
  CONNEXION_AUTOPILOTE = "connexion au module d'autopilote",
  DETECTION_MODEM      = "detection du modem",
  OUVERTURE_REDNET     = "ouverture rednet",
  RECUPERATION_ETAT    = "reprise de l'etat sur disque",
  SAUVEGARDE_ETAT      = "sauvegarde de l'etat sur disque",
  POSITION_DEMARRAGE   = "verification de la position au demarrage",
  CALCUL_POSITION      = "calcul de position (GPS + decalages)",
  CHOIX_RETOUR         = "choix du point de retour",
  RECEPTION_COMMANDE   = "reception d'une commande publique",
  VALIDATION_COMMANDE  = "validation d'une commande publique",
  CATALOGUE            = "lecture du catalogue du conteneur source",
  PURGE_SOUTES         = "purge des soutes avant chargement",
  CHARGEMENT_CARGAISON = "chargement de la cargaison",
  TRANSIT_ALLER        = "vol vers le point de depot",
  DETECTION_LOCALE     = "detection des inventaires du destinataire",
  VERIF_PAIEMENT       = "verification du coffre de paiement",
  ASPIRATION_PAIEMENT  = "aspiration du paiement",
  DEPOT_CARGAISON      = "depot de la cargaison chez le destinataire",
  RETOUR_BASE          = "retour vers un point de securite",
  RAVITAILLEMENT       = "passage au point de ravitaillement",
  DIFFUSION_ETAT       = "diffusion de l'etat du navire",
  BOUCLE_PRINCIPALE    = "boucle principale (parallele)",
  ARRET                = "arret du programme",
}

--------------------------------------------------------------------------------
-- 2. CHEMINS ET CHARGEUR DE MODULES
--    CC: Tweaked n'a pas de require fiable pour du code hors /rom/modules :
--    on charge chaque fichier explicitement, dans l'environnement courant.
--------------------------------------------------------------------------------

local function repertoireProgramme()
  if shell and shell.getRunningProgram then
    local ok, chemin = pcall(shell.getRunningProgram)
    if ok and chemin then
      local dossier = fs.getDir(chemin)
      if dossier and dossier ~= "" and dossier ~= "." then return dossier end
    end
  end
  return ""
end

local REPERTOIRE = repertoireProgramme()          -- ex. "navire"
local RACINE     = fs.getDir(REPERTOIRE) or ""    -- racine du depot
if RACINE == "." then RACINE = "" end

local function versRacine(chemin)
  if chemin == nil then return nil end
  if chemin:sub(1, 1) == "/" then return chemin end
  return fs.combine(RACINE, chemin)
end

local function charger(chemin)
  if not fs.exists(chemin) then
    error("fichier introuvable : " .. tostring(chemin), 0)
  end
  local f = fs.open(chemin, "r")
  if not f then error("ouverture impossible : " .. tostring(chemin), 0) end
  local source = f.readAll()
  f.close()
  local morceau, err = load(source, "@" .. chemin, "t", _ENV)
  if not morceau then error(err, 0) end
  return morceau()
end

-- LE FICHIER DE CONFIGURATION PAR VEHICULE EST CELUI DE L'AUTOPILOTE.
-- Les pages propres a la livraison (conteneurs, livraison, tarif) y sont
-- simplement ajoutees : rien n'est duplique.
local CHEMIN_CONFIG_VEHICULE_DEFAUT = "/autopilote/config_vehicule.lua"
local CHEMIN_AUTOPILOTE_DEFAUT      = "/autopilote/autopilote.lua"

-- Recouvrement FACULTATIF, pour qui prefere ne pas toucher au fichier de
-- l'autopilote : memes sections, prioritaires sur celles du vehicule.
local CHEMIN_RECOUVREMENT = fs.combine(REPERTOIRE, "config_livraison.lua")

local MARQUEUR_ARRET = fs.combine(REPERTOIRE, ".arret_manuel")

--------------------------------------------------------------------------------
-- 3. VALEURS PAR DEFAUT
--    Toute cle absente de la configuration reprend la valeur ci-dessous : une
--    configuration incomplete ne doit jamais faire planter le navire.
--------------------------------------------------------------------------------

local function fusionner(defaut, fourni)
  if type(fourni) ~= "table" then
    if fourni == nil then return defaut end
    return fourni
  end
  if type(defaut) ~= "table" then return fourni end
  local resultat = {}
  for cle, valeur in pairs(defaut) do resultat[cle] = valeur end
  for cle, valeur in pairs(fourni) do
    if type(valeur) == "table" and type(defaut[cle]) == "table"
       and #valeur == 0 and #defaut[cle] == 0 then
      resultat[cle] = fusionner(defaut[cle], valeur)
    else
      resultat[cle] = valeur
    end
  end
  return resultat
end

local DEFAUTS = {
  -- Raccordement au module d'autopilote. Tout le reste de la navigation
  -- (decalages, tolerances, vitesses, gabarit, gains PID, ravitaillement) est
  -- lu par l'autopilote lui-meme dans le fichier vehicule : ce programme n'en
  -- possede aucune copie et n'y touche jamais.
  autopilote = {
    chemin          = CHEMIN_AUTOPILOTE_DEFAUT,
    cheminConfig    = nil,   -- nil = le defaut du module
    nomGlobal       = nil,
    delaiArriveeMax = 900,   -- secondes avant d'abandonner un trajet
  },
  conteneurs = {},
  livraison = {
    conteneursSource     = {},
    pointChargement      = nil,
    distanceChargement   = 24,
    motifPaiement        = "chest",
    delaiPaiementMax     = 0,
    intervallePaiement   = 5,
    rappelPaiementToutes = 60,
    choixRetour          = "auto",
    pointsRetour         = {},
    facteurVitesseLente  = 0.6,
    ravitaillerToutesLes = 0,
    limites = { maxLignes = 12, maxQuantite = 100000, maxPortee = 100000, fileMax = 20 },
  },
  tarif = {
    objetPaiement      = "minecraft:diamond",
    forfaitBase        = 5,
    prixUnitaireDefaut = 0.01,
    parObjet           = {},
    coefficientVitesse = { fast = 2.0, slow = 1.0 },
    prixMinimum        = 1,
  },
  reseau = { coteModem = nil, diffusionEtat = 10, diffusionCatalogue = 60 },
  journal = { fichier = "navire/livraison.log", tailleMax = 128 * 1024, niveauEcran = "INFO" },
  robustesse = {
    redemarrageDelaiMin = 3,
    redemarrageDelaiMax = 60,
    arretParTerminate   = true,
    etat                = "navire/etat.dat",
  },
}

--------------------------------------------------------------------------------
-- 4. VARIABLES DE CYCLE
--    Un "cycle" = une execution complete entre deux relances automatiques.
--------------------------------------------------------------------------------

local config, journal, Protocole, Inventaire, Autopilote, pilote
local etat                 -- etat persistant (phase, file de commandes...)
local coteModem
-- Declaration anticipee : la verification de position est definie plus bas mais
-- appelee par la tache de mission, qui la precede dans le fichier.
local verifierPositionAuDemarrage
local compteurCommandes = 0
local debutCycle = 0

--------------------------------------------------------------------------------
-- 5. OUTILS
--------------------------------------------------------------------------------

local function nombreValide(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function pointValide(p)
  return type(p) == "table" and nombreValide(p.x) and nombreValide(p.y) and nombreValide(p.z)
end

local function texteP(p)
  if not pointValide(p) then return "?" end
  return string.format("%d %d %d", math.floor(p.x), math.floor(p.y), math.floor(p.z))
end

local function log(niveau, etape, message, ...)
  if journal and journal[niveau] then journal[niveau](etape, message, ...) end
end

--------------------------------------------------------------------------------
-- 6. CONFIGURATION
--------------------------------------------------------------------------------

local function chargerConfiguration()
  -- 1. Recouvrement facultatif : il peut notamment redefinir le chemin du
  --    fichier vehicule et celui du module d'autopilote.
  local recouvrement = {}
  if fs.exists(CHEMIN_RECOUVREMENT) then
    local lu = charger(CHEMIN_RECOUVREMENT)
    if type(lu) ~= "table" then
      error("config_livraison.lua doit retourner une table", 0)
    end
    recouvrement = lu
  end

  -- 2. Fichier de configuration PAR VEHICULE : celui de l'autopilote.
  local cheminVehicule = (recouvrement.autopilote and recouvrement.autopilote.cheminConfig)
    or CHEMIN_CONFIG_VEHICULE_DEFAUT
  if not fs.exists(cheminVehicule) then
    error(("configuration vehicule absente : %s -- installez l'autopilote"
      .. " ou indiquez son chemin dans navire/config_livraison.lua"):format(cheminVehicule), 0)
  end
  local vehicule = charger(cheminVehicule)
  if type(vehicule) ~= "table" then
    error(cheminVehicule .. " doit retourner une table", 0)
  end

  -- 3. Sections de livraison : celles du fichier vehicule, puis le
  --    recouvrement, qui a le dernier mot.
  local c = {}
  for section, defaut in pairs(DEFAUTS) do
    c[section] = fusionner(fusionner(defaut, vehicule[section]), recouvrement[section])
  end

  -- 4. Identite : elle appartient au fichier vehicule, a plat, et sert de cle
  --    dans les messages rednet comme dans les evenements de l'autopilote.
  c.identite = {
    nom         = vehicule.nom or "Dirigeable de livraison",
    identifiant = vehicule.identifiant,
    designation = vehicule.designation or "",
  }
  c.cheminVehicule = cheminVehicule
  c.autopilote.cheminConfig = cheminVehicule
  return c
end

local function validerConfiguration(c)
  local erreurs, alertes = {}, {}

  -- Rien de ce qui appartient a l'autopilote n'est verifie ici : decalages,
  -- tolerances, vitesses, gabarit et gains PID sont valides par son propre
  -- validerConfiguration au moment de autopilote.nouveau().
  if type(c.identite.identifiant) ~= "string" or c.identite.identifiant == "" then
    erreurs[#erreurs + 1] = ("'identifiant' est absent de %s : il est obligatoire"
      .. " et doit etre unique sur le serveur"):format(tostring(c.cheminVehicule))
  end

  if type(c.conteneurs) ~= "table" or #c.conteneurs == 0 then
    erreurs[#erreurs + 1] = "aucun conteneur de cargaison declare (section 'conteneurs')"
  else
    local expedition, recette = 0, 0
    for i, page in ipairs(c.conteneurs) do
      if type(page.peripherique) ~= "string" or page.peripherique == "" then
        erreurs[#erreurs + 1] = ("conteneurs[%d].peripherique manquant"):format(i)
      end
      if not pointValide(page.decalage) then
        alertes[#alertes + 1] =
          ("conteneurs[%d].decalage incomplet, suppose au centre du navire"):format(i)
        page.decalage = { x = 0, y = 0, z = 0 }
      end
      page.role = page.role or "expedition"
      if page.role == "expedition" then expedition = expedition + 1 end
      if page.role == "recette" then recette = recette + 1 end
    end
    if expedition == 0 then
      erreurs[#erreurs + 1] = "aucun conteneur de role 'expedition' : rien a livrer"
    end
    if recette == 0 then
      alertes[#alertes + 1] =
        "aucun conteneur de role 'recette' : le paiement restera chez le client"
    end
  end

  if type(c.livraison.conteneursSource) ~= "table" or #c.livraison.conteneursSource == 0 then
    erreurs[#erreurs + 1] = "livraison.conteneursSource est vide : aucune source de marchandise"
  end

  if type(c.livraison.pointsRetour) ~= "table" or #c.livraison.pointsRetour == 0 then
    erreurs[#erreurs + 1] = "livraison.pointsRetour est vide : le navire ne saurait pas rentrer"
  else
    for i, p in ipairs(c.livraison.pointsRetour) do
      if not pointValide(p) then
        erreurs[#erreurs + 1] = ("livraison.pointsRetour[%d] : coordonnees invalides"):format(i)
      end
      p.nom = p.nom or ("RETOUR-" .. i)
      p.rayonSecurite = p.rayonSecurite or 32
    end
  end

  return erreurs, alertes
end

-- Sous-ensembles de conteneurs, calcules une fois pour toutes.
local function conteneursParRole(role)
  local liste = {}
  for _, page in ipairs(config.conteneurs) do
    if page.role == role then liste[#liste + 1] = page end
  end
  table.sort(liste, function(a, b) return (a.priorite or 99) < (b.priorite or 99) end)
  return liste
end

local function nomsConteneursNavire()
  local noms = {}
  for _, page in ipairs(config.conteneurs) do noms[page.peripherique] = true end
  return noms
end

--------------------------------------------------------------------------------
-- 7. ETAT PERSISTANT
--    Ecrit a chaque transition de phase : apres un plantage ou un reboot du
--    monde, le navire reprend exactement ou il en etait.
--------------------------------------------------------------------------------

local function etatNeuf()
  return {
    version          = 1,
    phase            = "REPOS",
    commande         = nil,     -- commande en cours de traitement
    file             = {},      -- commandes acceptees, en attente
    pointRetour      = nil,     -- nom du dernier point de retour utilise
    livraisons       = 0,       -- compteur depuis la mise en service
    derniereErreur   = nil,
    derniereActivite = 0,
  }
end

local function cheminEtat()
  return versRacine(config.robustesse.etat or "navire/etat.dat")
end

local function sauverEtat()
  local ok, err = pcall(function()
    local chemin = cheminEtat()
    local dossier = fs.getDir(chemin)
    if dossier and dossier ~= "" and not fs.exists(dossier) then fs.makeDir(dossier) end
    local f = fs.open(chemin, "w")
    if not f then error("ouverture impossible de " .. chemin, 0) end
    f.write(textutils.serialise(etat))
    f.close()
  end)
  if not ok then
    log("avert", ETAPES.SAUVEGARDE_ETAT, "sauvegarde impossible : %s", tostring(err))
  end
  return ok
end

local function reprendreEtat()
  local chemin = cheminEtat()
  if not fs.exists(chemin) then
    etat = etatNeuf()
    log("info", ETAPES.RECUPERATION_ETAT, "aucun etat anterieur : demarrage a neuf")
    return
  end
  local ok, resultat = pcall(function()
    local f = fs.open(chemin, "r")
    local texte = f.readAll()
    f.close()
    return textutils.unserialise(texte)
  end)
  if ok and type(resultat) == "table" and resultat.version == 1 then
    etat = resultat
    etat.file = etat.file or {}
    log("info", ETAPES.RECUPERATION_ETAT,
      "etat repris : phase=%s, commande=%s, file=%d, livraisons=%d",
      tostring(etat.phase), etat.commande and etat.commande.id or "aucune",
      #etat.file, etat.livraisons or 0)
  else
    etat = etatNeuf()
    log("avert", ETAPES.RECUPERATION_ETAT,
      "etat sur disque illisible (%s) : redemarrage a neuf", tostring(resultat))
  end
end

local function changerPhase(phase, detail)
  etat.phase = phase
  etat.derniereActivite = os.clock()
  sauverEtat()
  log("info", ETAPES.BOUCLE_PRINCIPALE, "phase -> %s%s", phase,
    detail and (" (" .. detail .. ")") or "")
end

--------------------------------------------------------------------------------
-- 8. RESEAU
--------------------------------------------------------------------------------

local function detecterModem()
  if config.reseau.coteModem then
    if peripheral.isPresent(config.reseau.coteModem) then return config.reseau.coteModem end
    error(("aucun modem sur le cote configure '%s'"):format(config.reseau.coteModem), 0)
  end
  local ender, sansFil
  for _, nom in ipairs(peripheral.getNames()) do
    local estModem = false
    if peripheral.hasType then
      local ok, res = pcall(peripheral.hasType, nom, "modem")
      estModem = ok and res == true
    else
      estModem = peripheral.getType(nom) == "modem"
    end
    if estModem then
      local p = peripheral.wrap(nom)
      if p and type(p.isWireless) == "function" and p.isWireless() then
        -- Le modem Ender se distingue d'un modem sans fil ordinaire par sa
        -- portee illimitee ; a defaut d'API pour le savoir, on prend le
        -- premier sans fil trouve, le modem Ender etant en general seul.
        ender = ender or nom
      else
        sansFil = sansFil or nom
      end
    end
  end
  local choisi = ender or sansFil
  if not choisi then error("aucun modem detecte sur le calculateur", 0) end
  return choisi
end

local function ouvrirReseau()
  coteModem = detecterModem()
  log("info", ETAPES.DETECTION_MODEM, "modem retenu : cote '%s'", coteModem)
  rednet.open(coteModem)
  if not rednet.isOpen(coteModem) then
    error("rednet.open a echoue sur le cote " .. coteModem, 0)
  end
  log("info", ETAPES.OUVERTURE_REDNET, "rednet ouvert, protocole '%s'", Protocole.PROTOCOLE)
end

local function repondre(destinataire, type_, contenu)
  contenu = contenu or {}
  contenu.navire = config.identite.identifiant
  contenu.nomNavire = config.identite.nom
  local ok, err = pcall(rednet.send, destinataire, Protocole.enveloppe(type_, contenu),
    Protocole.PROTOCOLE)
  if not ok then
    log("avert", ETAPES.DIFFUSION_ETAT, "reponse rednet impossible vers %s : %s",
      tostring(destinataire), tostring(err))
  end
  return ok
end

local function diffuser(type_, contenu)
  contenu = contenu or {}
  contenu.navire = config.identite.identifiant
  contenu.nomNavire = config.identite.nom
  local ok, err = pcall(rednet.broadcast, Protocole.enveloppe(type_, contenu),
    Protocole.PROTOCOLE)
  if not ok then
    log("avert", ETAPES.DIFFUSION_ETAT, "diffusion rednet impossible : %s", tostring(err))
  end
  return ok
end

--------------------------------------------------------------------------------
-- 9. CATALOGUE DU CONTENEUR SOURCE
--    Le grand stockage de la base peut etre un bulk container Create : des
--    dizaines de milliers d'objets sur quelques emplacements. On n'interroge
--    getItemDetail qu'une fois par TYPE d'objet, jamais par emplacement.
--------------------------------------------------------------------------------

local catalogueCache = { articles = {}, horodatage = -1e9, erreurs = {} }

local function lireCatalogue(force)
  local maintenant = os.clock()
  if not force and (maintenant - catalogueCache.horodatage) < 5 then
    return catalogueCache.articles, catalogueCache.erreurs
  end

  local articles, erreurs = Inventaire.catalogue(config.livraison.conteneursSource, true)
  catalogueCache = { articles = articles, erreurs = erreurs, horodatage = maintenant }

  local total = 0
  for _, a in ipairs(articles) do total = total + a.quantite end
  log("debug", ETAPES.CATALOGUE, "catalogue lu : %d types, %d objets, %d erreur(s)",
    #articles, total, #erreurs)
  for _, err in ipairs(erreurs) do
    log("avert", ETAPES.CATALOGUE, "conteneur source inaccessible : %s", err)
  end
  return articles, erreurs
end

local function disponibleDansSource(nomObjet)
  local articles = lireCatalogue()
  for _, a in ipairs(articles) do
    if a.nom == nomObjet then return a.quantite end
  end
  return 0
end

--------------------------------------------------------------------------------
-- 10. POSITION ET POINTS DE RETOUR
--------------------------------------------------------------------------------

local function positionNavire()
  -- L'autopilote tient deja la position du CENTRE du navire, corrigee du
  -- decalage GPS configure. Inutile de refaire ce calcul.
  local centre, err = pilote.position()
  if not centre then
    log("erreur", ETAPES.CALCUL_POSITION, "position indisponible : %s", tostring(err))
    return nil, err
  end
  log("debug", ETAPES.CALCUL_POSITION, "centre du navire = %s", texteP(centre))
  return centre
end

-- Point de retour le plus pertinent.
--   "manuel" : celui marque principal = true
--   "auto"   : le plus proche de 'reference' (position courante ou dernier depot)
local function choisirPointRetour(reference)
  local points = config.livraison.pointsRetour
  if #points == 0 then return nil, "aucun point de retour configure" end

  if config.livraison.choixRetour == "manuel" then
    for _, p in ipairs(points) do
      if p.principal then
        log("info", ETAPES.CHOIX_RETOUR, "point de retour impose : %s (%s)", p.nom, texteP(p))
        return p
      end
    end
    log("avert", ETAPES.CHOIX_RETOUR,
      "choixRetour='manuel' mais aucun point principal : bascule sur le plus proche")
  end

  if not pointValide(reference) then
    local p = points[1]
    log("avert", ETAPES.CHOIX_RETOUR,
      "aucune reference de distance : repli sur %s", p.nom)
    return p
  end

  local meilleur, meilleureDistance
  for _, p in ipairs(points) do
    local d = Protocole.distance(reference, p)
    if not meilleureDistance or d < meilleureDistance then
      meilleur, meilleureDistance = p, d
    end
  end
  log("info", ETAPES.CHOIX_RETOUR, "point de retour retenu : %s (%s, a %.0f blocs)",
    meilleur.nom, texteP(meilleur), meilleureDistance)
  return meilleur
end

local function pointRetourCouvrant(position)
  if not pointValide(position) then return nil end
  for _, p in ipairs(config.livraison.pointsRetour) do
    local d = Protocole.distance(position, p)
    if d <= (p.rayonSecurite or 32) then return p, d end
  end
  return nil
end

--------------------------------------------------------------------------------
-- 11. DEPLACEMENTS (delegues a l'autopilote)
--------------------------------------------------------------------------------

-- 'depot' est le point ou doit se trouver la trappe de soute ; le decalage
-- configure est applique pour en deduire la cible du centre du navire.
-- 'point' contient les coordonnees BRUTES demandees (celles du client, ou
-- celles d'un point de retour). 'typePoint' vaut "depot", "atterrissage" ou
-- "survol" : c'est l'AUTOPILOTE qui en deduit ou placer le centre du navire,
-- en tournant le decalage configure selon le cap courant. Ce programme ne
-- calcule aucun decalage et ne corrige aucune trajectoire.
local function volerVers(point, typePoint, options)
  options = options or {}
  local etape = options.etape or ETAPES.TRANSIT_ALLER

  if not pilote.disponible then
    return false, pilote.motif or "autopilote indisponible"
  end

  -- Niveau de service : slow ship voyage a une fraction de la vitesse de
  -- croisiere du vehicule. La consigne est transmise telle quelle a
  -- l'autopilote, qui seul decide comment la tenir.
  local optionsMission = { surArrivee = nil }
  if options.vitesse == Protocole.VITESSES.LENT then
    local croisiere = (pilote.config and pilote.config.vitesses
      and pilote.config.vitesses.croisiere) or 8.0
    optionsMission.vitesseMax = croisiere * (config.livraison.facteurVitesseLente or 0.6)
    log("info", etape, "niveau de service slow ship : vitesse plafonnee a %.1f blocs/s",
      optionsMission.vitesseMax)
  end

  local cible = { x = point.x, y = point.y, z = point.z,
                  nom = point.nom or options.raison }
  local ok, err = pilote.allerA(cible, typePoint, optionsMission)
  if not ok then return false, err end

  -- Bloquant : la boucle de vol de l'autopilote tourne dans une autre tache
  -- du parallel.waitForAny, c'est elle qui fera aboutir ce trajet.
  local arrive, motif = pilote.attendreArrivee(
    options.delaiMax or config.autopilote.delaiArriveeMax)
  if not arrive then return false, motif end

  log("debug", etape, "arrive au point %s %s", typePoint, texteP(point))
  return true
end

--------------------------------------------------------------------------------
-- 12. CHARGEMENT DE LA CARGAISON
--------------------------------------------------------------------------------

local function contenuSoutes()
  local totaux = {}
  for _, page in ipairs(conteneursParRole("expedition")) do
    local c = Inventaire.contenu(page.peripherique)
    if c then
      for nomObjet, quantite in pairs(c.totaux) do
        totaux[nomObjet] = (totaux[nomObjet] or 0) + quantite
      end
    end
  end
  return totaux
end

-- Renvoie tout ce qui traine dans les soutes vers le conteneur source.
-- N'a de sens qu'a la base : ailleurs, on se contente de le journaliser.
local function purgerSoutes()
  local sources = config.livraison.conteneursSource
  if #sources == 0 then return end

  local restes = contenuSoutes()
  local rien = true
  for _ in pairs(restes) do rien = false break end
  if rien then
    log("debug", ETAPES.PURGE_SOUTES, "soutes vides, rien a purger")
    return
  end

  for _, page in ipairs(conteneursParRole("expedition")) do
    local deplace, restant, err = Inventaire.vider(page.peripherique, sources[1], {
      journal = journal, etape = ETAPES.PURGE_SOUTES,
    })
    if err then
      log("avert", ETAPES.PURGE_SOUTES, "purge partielle de '%s' : %s", page.nom, err)
    else
      log("info", ETAPES.PURGE_SOUTES, "soute '%s' purgee : %d objets rendus, %d restants",
        page.nom, deplace, restant)
    end
  end
end

-- Charge exactement les articles commandes, sans toucher au reste du stock.
-- Reprise : ce qui est deja en soute est deduit de ce qui reste a charger.
local function chargerCargaison(commande)
  local soutes = conteneursParRole("expedition")
  if #soutes == 0 then return false, "aucune soute d'expedition declaree" end

  local sources = config.livraison.conteneursSource
  local dejaCharge = commande.chargementEntame and contenuSoutes() or {}

  if not commande.chargementEntame then
    purgerSoutes()
    commande.chargementEntame = true
    sauverEtat()
  end

  commande.charge = commande.charge or {}
  local incomplet = {}

  for _, ligne in ipairs(commande.articles) do
    local restant = ligne.quantite - (dejaCharge[ligne.nom] or 0)
    if restant <= 0 then
      log("info", ETAPES.CHARGEMENT_CARGAISON,
        "%s deja en soute (%d) : rien a charger", ligne.nom, dejaCharge[ligne.nom] or 0)
      commande.charge[ligne.nom] = ligne.quantite
    else
      local disponible = disponibleDansSource(ligne.nom)
      if disponible < restant then
        log("avert", ETAPES.CHARGEMENT_CARGAISON,
          "stock insuffisant pour %s : %d disponible(s) pour %d demande(s)",
          ligne.nom, disponible, restant)
      end

      local charge = 0
      -- Repartition sur les soutes dans l'ordre de priorite, et sur les
      -- conteneurs sources dans l'ordre declare.
      for _, soute in ipairs(soutes) do
        if charge >= restant then break end
        for _, source in ipairs(sources) do
          if charge >= restant then break end
          local n, err = Inventaire.transferer(source, soute.peripherique, ligne.nom,
            restant - charge, {
              journal = journal,
              etape   = ETAPES.CHARGEMENT_CARGAISON,
              surProgression = function(fait, total)
                if fait % 512 == 0 then
                  log("debug", ETAPES.CHARGEMENT_CARGAISON,
                    "%s : %d / %d charges dans '%s'", ligne.nom, fait, total, soute.nom)
                end
              end,
            })
          charge = charge + (n or 0)
          if err and n == 0 then
            log("debug", ETAPES.CHARGEMENT_CARGAISON,
              "rien de plus a prendre dans '%s' pour %s (%s)", source, ligne.nom, err)
          end
        end
      end

      commande.charge[ligne.nom] = (dejaCharge[ligne.nom] or 0) + charge
      log("info", ETAPES.CHARGEMENT_CARGAISON,
        "ligne %s : %d / %d charges", ligne.nom, commande.charge[ligne.nom], ligne.quantite)

      if commande.charge[ligne.nom] < ligne.quantite then
        incomplet[#incomplet + 1] = ("%s (%d/%d)")
          :format(ligne.nom, commande.charge[ligne.nom], ligne.quantite)
      end
    end
  end

  sauverEtat()

  if #incomplet > 0 then
    local detail = table.concat(incomplet, ", ")
    log("avert", ETAPES.CHARGEMENT_CARGAISON,
      "chargement incomplet : %s -- la livraison part avec ce qui a pu etre charge", detail)
    return true, detail
  end

  log("info", ETAPES.CHARGEMENT_CARGAISON, "chargement complet de la commande %s", commande.id)
  return true
end

--------------------------------------------------------------------------------
-- 13. INVENTAIRES DU DESTINATAIRE
--    Au point de depot, les inventaires visibles qui n'appartiennent ni au
--    navire ni a la base sont ceux du client (plateforme d'accueil equipee
--    d'un modem filaire).
--------------------------------------------------------------------------------

local function inventairesEtrangers()
  local aNous = nomsConteneursNavire()
  for _, nom in ipairs(config.livraison.conteneursSource) do aNous[nom] = true end

  local etrangers = {}
  for _, nom in ipairs(Inventaire.inventairesVisibles()) do
    if not aNous[nom] then etrangers[#etrangers + 1] = nom end
  end

  log("info", ETAPES.DETECTION_LOCALE, "%d inventaire(s) du destinataire detecte(s) : %s",
    #etrangers, #etrangers > 0 and table.concat(etrangers, ", ") or "aucun")
  return etrangers
end

local function choisirCoffres(commande)
  local etrangers = inventairesEtrangers()
  if #etrangers == 0 then
    return nil, nil, "aucun inventaire accessible au point de depot"
        .. " (le client doit relier son coffre par modem filaire)"
  end

  local present = {}
  for _, nom in ipairs(etrangers) do present[nom] = true end

  local paiement = config.livraison.coffrePaiement
  if paiement and not present[paiement] then paiement = nil end
  if not paiement and commande.coffrePaiement and present[commande.coffrePaiement] then
    paiement = commande.coffrePaiement
  end
  if not paiement and config.livraison.motifPaiement then
    for _, nom in ipairs(etrangers) do
      if nom:lower():find(config.livraison.motifPaiement:lower(), 1, true) then
        paiement = nom
        break
      end
    end
  end
  paiement = paiement or etrangers[1]

  local reception = config.livraison.coffreReception
  if reception and not present[reception] then reception = nil end
  if not reception and commande.coffreReception and present[commande.coffreReception] then
    reception = commande.coffreReception
  end
  if not reception then
    for _, nom in ipairs(etrangers) do
      if nom ~= paiement then reception = nom break end
    end
  end
  if not reception then
    reception = paiement
    log("avert", ETAPES.DETECTION_LOCALE,
      "un seul inventaire au point de depot : paiement et reception partagent '%s'", reception)
  end

  log("info", ETAPES.DETECTION_LOCALE, "coffre de paiement = '%s', coffre de reception = '%s'",
    paiement, reception)
  return paiement, reception
end

--------------------------------------------------------------------------------
-- 14. PAIEMENT
--    Attente en boucle tant que la quantite exigee n'est pas presente.
--------------------------------------------------------------------------------

local function attendrePaiement(commande, coffrePaiement)
  local exige = commande.paiement
  local debut = os.clock()
  local dernierRappel = -1e9
  local delaiMax = config.livraison.delaiPaiementMax or 0
  local intervalle = config.livraison.intervallePaiement or 5

  log("info", ETAPES.VERIF_PAIEMENT,
    "commande %s : attente de %d x %s dans '%s'%s",
    commande.id, exige.quantite, exige.objet, coffrePaiement,
    delaiMax > 0 and (" (abandon apres " .. delaiMax .. " s)") or " (attente illimitee)")

  diffuser(Protocole.TYPES.AVIS, {
    commande = commande.id, evenement = "ATTENTE_PAIEMENT",
    message = ("depose %d %s dans le coffre pour recevoir la commande %s")
      :format(exige.quantite, exige.objet, commande.id),
  })

  while true do
    local contenu, err = Inventaire.contenu(coffrePaiement)
    if not contenu then
      log("avert", ETAPES.VERIF_PAIEMENT, "coffre de paiement illisible : %s", tostring(err))
    else
      local present = contenu.totaux[exige.objet] or 0
      local maintenant = os.clock()
      if present >= exige.quantite then
        log("info", ETAPES.VERIF_PAIEMENT,
          "paiement detecte : %d x %s (exige %d) apres %.0f s",
          present, exige.objet, exige.quantite, maintenant - debut)
        return true
      end
      if (maintenant - dernierRappel) >= (config.livraison.rappelPaiementToutes or 60) then
        dernierRappel = maintenant
        log("info", ETAPES.VERIF_PAIEMENT,
          "paiement incomplet : %d / %d x %s (attente depuis %.0f s)",
          present, exige.quantite, exige.objet, maintenant - debut)
        diffuser(Protocole.TYPES.AVIS, {
          commande = commande.id, evenement = "PAIEMENT_INCOMPLET",
          message = ("%d / %d %s"):format(present, exige.quantite, exige.objet),
        })
      end
    end

    if delaiMax > 0 and (os.clock() - debut) > delaiMax then
      return false, ("paiement non recu apres %d s"):format(delaiMax)
    end
    os.sleep(intervalle)
  end
end

local function aspirerPaiement(commande, coffrePaiement)
  local recettes = conteneursParRole("recette")
  local exige = commande.paiement
  if #recettes == 0 then
    log("avert", ETAPES.ASPIRATION_PAIEMENT,
      "aucun conteneur de recette : le paiement reste chez le client")
    return true, 0
  end

  local pris = 0
  for _, page in ipairs(recettes) do
    if pris >= exige.quantite then break end
    local n, err = Inventaire.transferer(coffrePaiement, page.peripherique,
      exige.objet, exige.quantite - pris, {
        journal = journal, etape = ETAPES.ASPIRATION_PAIEMENT,
      })
    pris = pris + (n or 0)
    if err and (n or 0) == 0 then
      log("debug", ETAPES.ASPIRATION_PAIEMENT, "recette '%s' : %s", page.nom, err)
    end
  end

  if pris < exige.quantite then
    log("erreur", ETAPES.ASPIRATION_PAIEMENT,
      "paiement partiellement encaisse : %d / %d x %s", pris, exige.quantite, exige.objet)
    return false, pris
  end

  log("info", ETAPES.ASPIRATION_PAIEMENT, "paiement encaisse : %d x %s",
    pris, exige.objet)
  return true, pris
end

--------------------------------------------------------------------------------
-- 15. DEPOT DE LA CARGAISON
--------------------------------------------------------------------------------

local function deposerCargaison(commande, coffreReception)
  local total, reste = 0, 0
  for _, page in ipairs(conteneursParRole("expedition")) do
    local deplace, restant, err = Inventaire.vider(page.peripherique, coffreReception, {
      journal = journal, etape = ETAPES.DEPOT_CARGAISON,
    })
    total = total + (deplace or 0)
    reste = reste + (restant or 0)
    if err then
      log("avert", ETAPES.DEPOT_CARGAISON, "depot partiel depuis '%s' : %s", page.nom, err)
    end
  end

  if reste > 0 then
    log("avert", ETAPES.DEPOT_CARGAISON,
      "%d objets n'ont pas pu etre deposes (coffre plein ?) : ils repartent avec le navire",
      reste)
  end
  log("info", ETAPES.DEPOT_CARGAISON, "commande %s : %d objets deposes dans '%s'",
    commande.id, total, coffreReception)
  return total, reste
end

--------------------------------------------------------------------------------
-- 16. RETOUR AUTOMATIQUE
--------------------------------------------------------------------------------

local function retournerBase(reference, raison)
  local position = reference or positionNavire()

  local couvrant = pointRetourCouvrant(position)
  if couvrant then
    log("info", ETAPES.RETOUR_BASE,
      "deja au point de securite '%s' (%s) : aucun deplacement", couvrant.nom, texteP(couvrant))
    etat.pointRetour = couvrant.nom
    changerPhase(Protocole.PHASES.REPOS, "sur place")
    return true
  end

  local cible, err = choisirPointRetour(position)
  if not cible then
    log("erreur", ETAPES.RETOUR_BASE, "retour impossible : %s", tostring(err))
    return false, err
  end

  changerPhase(Protocole.PHASES.TRANSIT_RETOUR, cible.nom)
  local ok, errVol = volerVers(cible, "atterrissage", {
    raison = raison or ("retour vers " .. cible.nom),
    etape  = ETAPES.RETOUR_BASE,
  })
  if not ok then
    log("erreur", ETAPES.RETOUR_BASE, "retour vers '%s' en echec : %s", cible.nom, tostring(errVol))
    return false, errVol
  end

  etat.pointRetour = cible.nom
  changerPhase(Protocole.PHASES.REPOS, cible.nom)
  log("info", ETAPES.RETOUR_BASE, "navire rentre au point '%s'", cible.nom)
  return true
end

-- La position de ravitaillement est une constante de RESEAU : elle est
-- verrouillee dans le fichier ravitaillement.lua de l'autopilote, pas dans la
-- configuration du vehicule. On se contente donc de lui demander d'y aller.
local function ravitaillerSiNecessaire()
  local toutesLes = config.livraison.ravitaillerToutesLes or 0
  if toutesLes <= 0 then return end
  if (etat.livraisons or 0) % toutesLes ~= 0 then return end

  changerPhase(Protocole.PHASES.RAVITAILLEMENT, "station du reseau")
  local ok, err = pilote.rejoindreRavitaillement()
  if not ok then
    log("avert", ETAPES.RAVITAILLEMENT, "ravitaillement non engage : %s", tostring(err))
    return
  end

  local arrive, motif = pilote.attendreArrivee(config.autopilote.delaiArriveeMax)
  if arrive then
    log("info", ETAPES.RAVITAILLEMENT, "navire a la station de ravitaillement")
  else
    log("avert", ETAPES.RAVITAILLEMENT, "ravitaillement non abouti : %s", tostring(motif))
  end
end

--------------------------------------------------------------------------------
-- 17. EXECUTION D'UNE COMMANDE
--    Chaque etape est rejouable : apres un plantage, la phase relue sur disque
--    determine ou reprendre.
--------------------------------------------------------------------------------

local function executerCommande(commande)
  if not pilote.disponible then
    return false, "autopilote indisponible : " .. tostring(pilote.motif)
  end

  log("info", ETAPES.BOUCLE_PRINCIPALE,
    "traitement de la commande %s pour '%s' : %d ligne(s), vitesse %s, depot %s",
    commande.id, tostring(commande.client), #commande.articles, commande.vitesse,
    texteP(commande.destination))

  ------------------------------------------------------------------ chargement
  if etat.phase == Protocole.PHASES.REPOS
     or etat.phase == Protocole.PHASES.CHARGEMENT
     or etat.phase == Protocole.PHASES.TRANSIT_RETOUR then

    -- Le chargement n'est possible qu'a portee du conteneur source.
    local position = positionNavire()
    local pointCharge = config.livraison.pointChargement
    if pointValide(pointCharge) and pointValide(position) then
      local d = Protocole.distance(position, pointCharge)
      if d > (config.livraison.distanceChargement or 24) then
        log("info", ETAPES.CHARGEMENT_CARGAISON,
          "navire a %.0f blocs du point de chargement : retour a la base d'abord", d)
        changerPhase(Protocole.PHASES.TRANSIT_RETOUR, "rejoint le point de chargement")
        local ok, err = volerVers(pointCharge, "atterrissage", {
          raison = "rejoindre le point de chargement", etape = ETAPES.RETOUR_BASE,
        })
        if not ok then return false, "chargement impossible : " .. tostring(err) end
      end
    end

    changerPhase(Protocole.PHASES.CHARGEMENT, commande.id)
    -- journal.proteger renvoie (protege, <retours de la fonction>).
    local protege, ok, detail = journal.proteger(ETAPES.CHARGEMENT_CARGAISON,
      chargerCargaison, commande)
    if not protege then return false, "chargement en echec : " .. tostring(ok) end
    if not ok then return false, "chargement en echec : " .. tostring(detail) end
    commande.chargementIncomplet = detail
  end

  ----------------------------------------------------------------- transit ---
  if etat.phase ~= Protocole.PHASES.ATTENTE_PAIEMENT
     and etat.phase ~= Protocole.PHASES.DEPOT then
    changerPhase(Protocole.PHASES.TRANSIT_ALLER, texteP(commande.destination))
    diffuser(Protocole.TYPES.AVIS, {
      commande = commande.id, evenement = "DEPART",
      message = ("en route vers %s"):format(texteP(commande.destination)),
    })
    -- type "depot" : l'autopilote place le navire de facon que la trappe de
    -- soute tombe sur les coordonnees demandees par le client.
    local ok, err = volerVers(commande.destination, "depot", {
      raison   = "livraison " .. commande.id,
      vitesse  = commande.vitesse,
      etape    = ETAPES.TRANSIT_ALLER,
      delaiMax = config.autopilote.delaiArriveeMax,
    })
    if not ok then return false, "transit aller en echec : " .. tostring(err) end
    log("info", ETAPES.TRANSIT_ALLER, "arrive au point de depot %s",
      texteP(commande.destination))
  end

  ------------------------------------------------------------------ coffres --
  local protegeCoffres, coffrePaiement, coffreReception, errCoffres =
    journal.proteger(ETAPES.DETECTION_LOCALE, choisirCoffres, commande)
  if not protegeCoffres then
    return false, "detection des coffres en echec : " .. tostring(coffrePaiement)
  end
  if not coffrePaiement then return false, tostring(errCoffres) end

  ----------------------------------------------------------------- paiement --
  changerPhase(Protocole.PHASES.ATTENTE_PAIEMENT, commande.id)
  if commande.paiementEncaisse then
    -- Le cycle precedent avait deja encaisse avant de planter : refaire payer
    -- le client serait une double facturation.
    log("info", ETAPES.VERIF_PAIEMENT,
      "paiement de la commande %s deja encaisse lors d'un cycle precedent : etape sautee",
      commande.id)
  else
    local paye, errPaiement = attendrePaiement(commande, coffrePaiement)
    if not paye then
      log("erreur", ETAPES.VERIF_PAIEMENT, "commande %s abandonnee : %s",
        commande.id, tostring(errPaiement))
      diffuser(Protocole.TYPES.AVIS, {
        commande = commande.id, evenement = "ABANDON", message = tostring(errPaiement),
      })
      return false, errPaiement
    end

    local encaisse = aspirerPaiement(commande, coffrePaiement)
    commande.paiementEncaisse = true
    sauverEtat()
    if not encaisse then
      log("avert", ETAPES.ASPIRATION_PAIEMENT,
        "encaissement incomplet : la livraison se poursuit malgre tout")
    end
  end

  -------------------------------------------------------------------- depot --
  changerPhase(Protocole.PHASES.DEPOT, commande.id)
  local deposes, restants = deposerCargaison(commande, coffreReception)

  etat.livraisons = (etat.livraisons or 0) + 1
  diffuser(Protocole.TYPES.AVIS, {
    commande = commande.id, evenement = "LIVREE",
    message = ("%d objets deposes a %s"):format(deposes, texteP(commande.destination)),
  })
  log("info", ETAPES.DEPOT_CARGAISON,
    "commande %s terminee : %d objets livres, %d non deposes, livraison n%d",
    commande.id, deposes, restants, etat.livraisons)

  return true
end

--------------------------------------------------------------------------------
-- 18. MACHINE A ETATS PRINCIPALE
--------------------------------------------------------------------------------

local derniereVerifPosition = nil

local function defilerCommande()
  if #etat.file == 0 then return nil end
  local commande = table.remove(etat.file, 1)
  etat.commande = commande
  sauverEtat()
  return commande
end

local verificationDemarrageFaite = false

local function cycleMission()
  -- La verification de position doit avoir lieu ICI, et non avant
  -- parallel.waitForAny : rejoindre un point de securite passe par
  -- attendreArrivee, qui n'aboutit que si la boucle de vol de l'autopilote
  -- tourne deja dans une tache voisine.
  if not verificationDemarrageFaite then
    verificationDemarrageFaite = true
    if pilote.disponible then
      journal.proteger(ETAPES.POSITION_DEMARRAGE, verifierPositionAuDemarrage)
    else
      local position = positionNavire()
      local couvrant = pointRetourCouvrant(position)
      log("avert", ETAPES.POSITION_DEMARRAGE,
        "autopilote indisponible : position %s, point de securite %s",
        texteP(position), couvrant and couvrant.nom or "AUCUN")
    end
  end

  while true do
    -- Sans autopilote, on ne defile RIEN : une commande engagee serait chargee
    -- puis abandonnee au sol. Elle reste en file jusqu'a ce que le
    -- raccordement soit repare et le programme relance.
    if not etat.commande and pilote.disponible then defilerCommande() end

    if etat.commande then
      local commande = etat.commande
      -- journal.proteger renvoie (protege, <retours de executerCommande>).
      local protege, ok, motif = journal.proteger(
        "execution de la commande " .. commande.id, executerCommande, commande)
      local erreur
      if not protege then
        erreur = ok          -- 'ok' porte alors la trace de l'exception
      elseif not ok then
        erreur = motif or "motif inconnu"
      end

      if erreur then
        log("erreur", ETAPES.BOUCLE_PRINCIPALE,
          "commande %s non menee a son terme : %s", commande.id, tostring(erreur))
        etat.derniereErreur = tostring(erreur)
        diffuser(Protocole.TYPES.AVIS, {
          commande = commande.id, evenement = "ECHEC", message = tostring(erreur),
        })
      end

      etat.commande = nil
      changerPhase(Protocole.PHASES.REPOS, "commande liberee")

      if #etat.file == 0 then
        -- Toutes les commandes en cours sont terminees : retour automatique,
        -- sans qu'aucun ordre ne soit redonne.
        journal.proteger(ETAPES.RETOUR_BASE, retournerBase,
          commande.destination, "fin de tournee")
        ravitaillerSiNecessaire()
      end

    else
      -- Rien a faire : on verifie periodiquement qu'on est bien a un point de
      -- securite. Inutile d'interroger le GPS toutes les deux secondes.
      local maintenant = os.clock()
      if pilote.disponible and (maintenant - (derniereVerifPosition or -1e9)) >= 30 then
        derniereVerifPosition = maintenant
        local position = positionNavire()
        if position and not pointRetourCouvrant(position) then
          journal.proteger(ETAPES.RETOUR_BASE, retournerBase, position,
            "aucune commande en file")
        end
      end
      os.sleep(2)
    end
  end
end

--------------------------------------------------------------------------------
-- 19. SERVEUR DE COMMANDES PUBLIQUES
--------------------------------------------------------------------------------

local function resumeEtat()
  return {
    phase       = etat.phase,
    commande    = etat.commande and etat.commande.id or nil,
    client      = etat.commande and etat.commande.client or nil,
    destination = etat.commande and etat.commande.destination or nil,
    file        = #etat.file,
    livraisons  = etat.livraisons or 0,
    pointRetour = etat.pointRetour,
    autopilote  = pilote and pilote.disponible or false,
    version     = VERSION_PROGRAMME,
    erreur      = etat.derniereErreur,
  }
end

local function traiterMessage(expediteur, message)
  local ok, motif = Protocole.valide(message)
  if not ok then return end

  if message.type == Protocole.TYPES.CATALOGUE_DEMANDE then
    local articles = lireCatalogue(message.force == true)
    log("info", ETAPES.CATALOGUE, "catalogue transmis a l'ordinateur %d (%d types)",
      expediteur, #articles)
    repondre(expediteur, Protocole.TYPES.CATALOGUE, {
      articles = articles,
      tarif    = config.tarif,
      limites  = config.livraison.limites,
      etat     = resumeEtat(),
    })

  elseif message.type == Protocole.TYPES.ETAT_DEMANDE then
    repondre(expediteur, Protocole.TYPES.ETAT, { etat = resumeEtat() })

  elseif message.type == Protocole.TYPES.COMMANDE then
    local commande = message.commande
    log("info", ETAPES.RECEPTION_COMMANDE, "commande recue de l'ordinateur %d : %s",
      expediteur, type(commande) == "table" and tostring(commande.id) or "illisible")

    local valide, erreur = Protocole.validerCommande(commande, config.livraison.limites)
    if not valide then
      log("avert", ETAPES.VALIDATION_COMMANDE, "commande refusee : %s", erreur)
      repondre(expediteur, Protocole.TYPES.ACCUSE,
        { commande = commande and commande.id, accepte = false, motif = erreur })
      return
    end

    if #etat.file >= (config.livraison.limites.fileMax or 20) then
      log("avert", ETAPES.VALIDATION_COMMANDE, "file pleine (%d) : commande %s refusee",
        #etat.file, commande.id)
      repondre(expediteur, Protocole.TYPES.ACCUSE,
        { commande = commande.id, accepte = false, motif = "file d'attente pleine" })
      return
    end

    for _, existante in ipairs(etat.file) do
      if existante.id == commande.id then
        repondre(expediteur, Protocole.TYPES.ACCUSE,
          { commande = commande.id, accepte = false, motif = "commande deja enregistree" })
        return
      end
    end

    -- Le prix est RECALCULE a bord : la borne est publique, son chiffre ne
    -- fait pas foi.
    local paiement = Protocole.calculerPaiement(commande.articles, commande.vitesse,
      config.tarif)
    if commande.paiement.objet ~= paiement.objet
       or commande.paiement.quantite ~= paiement.quantite then
      log("avert", ETAPES.VALIDATION_COMMANDE,
        "prix annonce par la borne (%d x %s) corrige en %d x %s",
        commande.paiement.quantite, tostring(commande.paiement.objet),
        paiement.quantite, paiement.objet)
    end
    commande.paiement = paiement
    commande.expediteur = expediteur
    commande.recueLe = os.epoch and os.epoch("utc") or 0

    -- Une commande 'fast ship' passe devant les 'slow ship' deja en file,
    -- mais jamais devant une autre 'fast ship' : le prix majore achete une
    -- priorite, pas un passe-droit sur les clients qui l'ont deja payee.
    local rang = #etat.file + 1
    if commande.vitesse == Protocole.VITESSES.RAPIDE then
      rang = 1
      for i, existante in ipairs(etat.file) do
        if existante.vitesse == Protocole.VITESSES.RAPIDE then rang = i + 1 end
      end
    end
    table.insert(etat.file, rang, commande)
    compteurCommandes = compteurCommandes + 1
    sauverEtat()

    log("info", ETAPES.VALIDATION_COMMANDE,
      "commande %s acceptee (rang %d/%d) : %d ligne(s), %s, depot %s, prix %d x %s",
      commande.id, rang, #etat.file, #commande.articles, commande.vitesse,
      texteP(commande.destination), paiement.quantite, paiement.objet)

    repondre(expediteur, Protocole.TYPES.ACCUSE, {
      commande = commande.id, accepte = true, rang = rang, paiement = paiement,
    })

  elseif message.type == Protocole.TYPES.ANNULATION then
    local id = message.commande
    for i, existante in ipairs(etat.file) do
      if existante.id == id then
        table.remove(etat.file, i)
        sauverEtat()
        log("info", ETAPES.RECEPTION_COMMANDE, "commande %s annulee avant chargement", id)
        repondre(expediteur, Protocole.TYPES.ACCUSE,
          { commande = id, accepte = true, motif = "annulee" })
        return
      end
    end
    repondre(expediteur, Protocole.TYPES.ACCUSE,
      { commande = id, accepte = false, motif = "commande introuvable ou deja en cours" })
  end
end

local function cycleServeur()
  while true do
    local expediteur, message = rednet.receive(Protocole.PROTOCOLE, 15)
    if expediteur then
      journal.proteger(ETAPES.RECEPTION_COMMANDE, traiterMessage, expediteur, message)
    end
  end
end

local function cycleDiffusion()
  local dernierCatalogue = -1e9
  while true do
    diffuser(Protocole.TYPES.ETAT, { etat = resumeEtat() })
    if (os.clock() - dernierCatalogue) >= (config.reseau.diffusionCatalogue or 60) then
      dernierCatalogue = os.clock()
      local articles = lireCatalogue(true)
      diffuser(Protocole.TYPES.CATALOGUE, {
        articles = articles, tarif = config.tarif,
        limites = config.livraison.limites, etat = resumeEtat(),
      })
    end
    os.sleep(config.reseau.diffusionEtat or 10)
  end
end

local function cycleTerminate()
  while true do
    local evenement = os.pullEventRaw("terminate")
    if evenement == "terminate" then
      if config.robustesse.arretParTerminate then
        log("avert", ETAPES.ARRET, "Ctrl+T recu : arret demande par un operateur")
        local f = fs.open(MARQUEUR_ARRET, "w")
        if f then f.write("arret manuel") f.close() end
        error("ARRET_MANUEL", 0)
      else
        log("avert", ETAPES.ARRET,
          "Ctrl+T ignore (robustesse.arretParTerminate = false) : le navire reste autonome")
      end
    end
  end
end

--------------------------------------------------------------------------------
-- 20. VERIFICATION DE POSITION AU DEMARRAGE
--    Exigence : au redemarrage, rester sur place si le navire est deja a un
--    point de retour de securite, sinon s'y rendre AVANT de reprendre le
--    fonctionnement normal.
--------------------------------------------------------------------------------

verifierPositionAuDemarrage = function()
  local position, err = positionNavire()

  if not position then
    log("erreur", ETAPES.POSITION_DEMARRAGE,
      "position inconnue au demarrage (%s) : le navire reste sur place par securite",
      tostring(err))
    return false
  end

  local couvrant, distance = pointRetourCouvrant(position)
  if couvrant then
    log("info", ETAPES.POSITION_DEMARRAGE,
      "navire deja au point de securite '%s' (%.0f blocs du centre) : aucun deplacement",
      couvrant.nom, distance)
    etat.pointRetour = couvrant.nom
    -- Une commande interrompue avant le decollage repart proprement du debut.
    if etat.commande and etat.phase == Protocole.PHASES.CHARGEMENT then
      log("info", ETAPES.POSITION_DEMARRAGE,
        "commande %s interrompue pendant le chargement : reprise du chargement",
        etat.commande.id)
    end
    changerPhase(etat.commande and Protocole.PHASES.CHARGEMENT or Protocole.PHASES.REPOS,
      "verification de position")
    return true
  end

  log("avert", ETAPES.POSITION_DEMARRAGE,
    "navire hors de tout point de securite (%s) : rejoint le plus proche avant de reprendre",
    texteP(position))

  -- Une commande interrompue en vol repart en tete de file : on rentre
  -- d'abord, puis on la refait depuis le chargement.
  if etat.commande then
    local commande = etat.commande
    commande.chargementEntame = false
    table.insert(etat.file, 1, commande)
    etat.commande = nil
    log("info", ETAPES.POSITION_DEMARRAGE,
      "commande %s remise en tete de file pour etre refaite integralement", commande.id)
  end

  local ok, errRetour = retournerBase(position, "reprise apres redemarrage")
  if not ok then
    log("erreur", ETAPES.POSITION_DEMARRAGE,
      "impossible de rejoindre un point de securite : %s", tostring(errRetour))
  end
  return ok
end

--------------------------------------------------------------------------------
-- 21. CYCLE COMPLET
--------------------------------------------------------------------------------

local function cyclePrincipal()
  debutCycle = os.clock()

  ------------------------------------------------------------------ config ---
  config = chargerConfiguration()

  ----------------------------------------------------------------- journal ---
  local Journal = charger(fs.combine(RACINE, "commun/journal.lua"))
  journal = Journal.creer({
    chemin        = versRacine(config.journal.fichier),
    tailleMax     = config.journal.tailleMax,
    niveauEcran   = config.journal.niveauEcran,
    ecrireFichier = true,
  })
  log("info", ETAPES.DEMARRAGE, "FrenchNet Livraison v%s -- navire '%s' (%s)",
    VERSION_PROGRAMME, tostring(config.identite.nom), tostring(config.identite.identifiant))

  ---------------------------------------------------------------- validation -
  local erreurs, alertes = validerConfiguration(config)
  for _, a in ipairs(alertes) do log("avert", ETAPES.VALIDATION_CONFIG, "%s", a) end
  if #erreurs > 0 then
    for _, e in ipairs(erreurs) do log("critique", ETAPES.VALIDATION_CONFIG, "%s", e) end
    error("configuration invalide : " .. erreurs[1], 0)
  end
  log("info", ETAPES.VALIDATION_CONFIG,
    "configuration valide : %d conteneur(s), %d source(s), %d point(s) de retour",
    #config.conteneurs, #config.livraison.conteneursSource, #config.livraison.pointsRetour)

  ----------------------------------------------------------------- modules ---
  Protocole  = charger(fs.combine(RACINE, "commun/protocole.lua"))
  Inventaire = charger(fs.combine(RACINE, "commun/inventaire.lua"))
  Autopilote = charger(fs.combine(REPERTOIRE, "autopilote.lua"))
  log("info", ETAPES.CHARGEMENT_MODULES, "modules communs charges")

  -------------------------------------------------------------- autopilote ---
  -- connecter() appelle autopilote.nouveau(), qui lit et valide lui-meme le
  -- fichier de configuration du vehicule et verrouille la position de
  -- ravitaillement depuis le fichier reseau.
  pilote = Autopilote.connecter({
    chemin       = config.autopilote.chemin,
    cheminConfig = config.autopilote.cheminConfig,
    nomGlobal    = config.autopilote.nomGlobal,
  }, journal, charger)

  if pilote.disponible then
    journal.proteger(ETAPES.CONNEXION_AUTOPILOTE, pilote.initialiser)
  else
    log("critique", ETAPES.CONNEXION_AUTOPILOTE,
      "AUCUN VOL POSSIBLE : %s", tostring(pilote.motif))
    log("critique", ETAPES.CONNEXION_AUTOPILOTE,
      "le navire accepte les commandes mais ne decollera pas -- verifier"
      .. " l'installation de l'autopilote (%s)", tostring(config.autopilote.chemin))
  end

  -------------------------------------------------------------------- etat ---
  reprendreEtat()

  ------------------------------------------------------------------ reseau ---
  ouvrirReseau()

  ----------------------------------------------------------------- catalogue -
  lireCatalogue(true)

  log("info", ETAPES.BOUCLE_PRINCIPALE,
    "systeme de livraison operationnel -- file : %d commande(s), phase : %s",
    #etat.file, etat.phase)
  diffuser(Protocole.TYPES.ETAT, { etat = resumeEtat() })

  -- LA BOUCLE DE VOL DE L'AUTOPILOTE TOURNE ICI, a cote de la mission. Sans
  -- elle, aucun ordre de vol n'aboutit et attendreArrivee ne rend jamais la
  -- main. C'est l'usage prescrit par le module : parallel.waitForAny(
  -- ap.executer, mission).
  if pilote.disponible then
    parallel.waitForAny(pilote.executer, cycleServeur, cycleMission,
      cycleDiffusion, cycleTerminate)
  else
    parallel.waitForAny(cycleServeur, cycleMission, cycleDiffusion, cycleTerminate)
  end
end

--------------------------------------------------------------------------------
-- 22. SUPERVISEUR
--    Relance automatique apres n'importe quel plantage, avec temporisation
--    progressive. Aucune intervention humaine n'est requise.
--------------------------------------------------------------------------------

local function superviser()
  local redemarrages = 0

  while true do
    if fs.exists(MARQUEUR_ARRET) then
      print("[ARRET] marqueur '.arret_manuel' present : supprimez-le pour relancer.")
      return
    end

    local ok, erreur = xpcall(cyclePrincipal, function(err)
      if debug and debug.traceback then return debug.traceback(tostring(err), 2) end
      return tostring(err)
    end)

    if ok then
      -- cyclePrincipal ne rend la main que si une de ses taches s'arrete.
      erreur = "une tache de la boucle principale s'est terminee"
    end

    if tostring(erreur):find("ARRET_MANUEL", 1, true) then
      if journal then log("info", ETAPES.ARRET, "arret manuel confirme") end
      print("[ARRET] arret manuel.")
      return
    end

    redemarrages = redemarrages + 1
    local etapeCourante = journal and journal.etapeCourante or ETAPES.DEMARRAGE
    local message = ("plantage a l'etape '%s' : %s"):format(tostring(etapeCourante),
      tostring(erreur))

    if journal then
      log("critique", etapeCourante, "%s", message)
    else
      -- Le journal lui-meme n'a pas pu demarrer : sortie ecran directe.
      print("[CRITIQUE] [etape: " .. tostring(etapeCourante) .. "] " .. message)
    end

    -- Commandes de vol neutralisees et reseau referme proprement avant la
    -- relance : sans cela le prochain cycle heriterait d'un rednet a moitie
    -- ouvert, et les moteurs resteraient sur leur derniere consigne.
    if pilote and pilote.disponible then pcall(pilote.arreter, "relance du programme") end
    if coteModem then pcall(rednet.close, coteModem) end
    coteModem = nil

    local minimum = (config and config.robustesse.redemarrageDelaiMin) or 3
    local maximum = (config and config.robustesse.redemarrageDelaiMax) or 60
    local delai = math.min(maximum, minimum * (2 ^ math.min(redemarrages - 1, 8)))

    if journal then
      log("avert", ETAPES.DEMARRAGE, "relance automatique n%d dans %d s",
        redemarrages, delai)
    else
      print(("[AVERT] relance automatique n%d dans %d s"):format(redemarrages, delai))
    end

    -- L'etat reste sur disque : la relance reprend la mission en cours.
    journal = nil
    pilote = nil
    os.sleep(delai)
  end
end

superviser()
