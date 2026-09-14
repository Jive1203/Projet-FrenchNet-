--[[----------------------------------------------------------------------------
  FRENCHNET / AERONAUTICS WARFARE
  Borne de commande publique - systeme de livraison aerienne
  --------------------------------------------------------------------------
  Ouverte a TOUS les joueurs et a TOUTES les factions du serveur. Elle permet :

    1. de choisir les objets et les quantites a commander dans le grand
       conteneur de stockage source (y compris un bulk container Create
       contenant des dizaines de milliers d'objets) ;
    2. de choisir le niveau de service : fast ship (plus rapide, plus cher)
       ou slow ship (moins cher, plus lent) ;
    3. de saisir soi-meme les coordonnees X, Y et Z exactes du point de depot.

  La borne ne detient aucun privilege : elle transmet la commande par rednet,
  le navire revalide integralement quantites, portee et prix a bord.

  NOTE SUR LES ACCENTS : chaines d'ecran volontairement sans accents, le
  terminal de CC: Tweaked etant oriente octet.
--------------------------------------------------------------------------------]]

local VERSION_PROGRAMME = "1.0.0"

local ETAPES = {
  DEMARRAGE         = "demarrage de la borne",
  CHARGEMENT_CONFIG = "chargement de la configuration de la borne",
  CHARGEMENT_MODULES= "chargement des modules communs",
  DETECTION_MODEM   = "detection du modem",
  OUVERTURE_REDNET  = "ouverture rednet",
  CATALOGUE         = "recuperation du catalogue",
  SAISIE_ARTICLES   = "saisie des articles",
  SAISIE_VITESSE    = "choix du niveau de service",
  SAISIE_DESTINATION= "saisie des coordonnees de depot",
  CALCUL_PRIX       = "calcul du prix",
  ENVOI_COMMANDE    = "envoi de la commande au navire",
  ATTENTE_ACCUSE    = "attente de l'accuse du navire",
  SUIVI             = "suivi des commandes",
  ANNULATION        = "annulation d'une commande",
  BOUCLE_PRINCIPALE = "boucle principale de la borne",
  ARRET             = "arret de la borne",
}

--------------------------------------------------------------------------------
-- Chemins et chargeur
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

local REPERTOIRE = repertoireProgramme()
local RACINE     = fs.getDir(REPERTOIRE) or ""
if RACINE == "." then RACINE = "" end

local function versRacine(chemin)
  if chemin == nil then return nil end
  if chemin:sub(1, 1) == "/" then return chemin end
  return fs.combine(RACINE, chemin)
end

local function charger(chemin)
  if not fs.exists(chemin) then error("fichier introuvable : " .. tostring(chemin), 0) end
  local f = fs.open(chemin, "r")
  local source = f.readAll()
  f.close()
  local morceau, err = load(source, "@" .. chemin, "t", _ENV)
  if not morceau then error(err, 0) end
  return morceau()
end

local CHEMIN_CONFIG  = fs.combine(REPERTOIRE, "config_borne.lua")
local MARQUEUR_ARRET = fs.combine(REPERTOIRE, ".arret_manuel")

--------------------------------------------------------------------------------
-- Variables de cycle
--------------------------------------------------------------------------------

local config, journal, Protocole, Inventaire
local coteModem
local catalogue = { articles = {}, tarif = nil, limites = nil, navire = nil,
                    nomNavire = nil, etat = nil, horodatage = -1e9 }
local mesCommandes = {}   -- commandes deposees depuis cette borne

local function log(niveau, etape, message, ...)
  if journal and journal[niveau] then journal[niveau](etape, message, ...) end
end

--------------------------------------------------------------------------------
-- Affichage
--------------------------------------------------------------------------------

local function couleur(c)
  if term.isColour and term.isColour() then pcall(term.setTextColour, c) end
end

local function entete(sousTitre)
  term.clear()
  term.setCursorPos(1, 1)
  couleur(colors.yellow)
  print("== " .. (config and config.titre or "FRENCHNET - LIVRAISON") .. " ==")
  couleur(colors.lightGray)
  local e = catalogue.etat
  if e then
    print(("Navire : %s | phase %s | file %d | livraisons %d")
      :format(tostring(catalogue.nomNavire or catalogue.navire or "?"),
              tostring(e.phase), e.file or 0, e.livraisons or 0))
    if e.autopilote == false then
      couleur(colors.red)
      print("ATTENTION : autopilote du navire indisponible, aucun vol possible.")
    end
  else
    print("Navire : non contacte pour l'instant")
  end
  if sousTitre then
    couleur(colors.white)
    print("-- " .. sousTitre)
  end
  couleur(colors.white)
  print(("-"):rep(math.min(50, ({ term.getSize() })[1] or 50)))
end

local function pause(message)
  couleur(colors.lightGray)
  print(message or "Appuyez sur une touche...")
  couleur(colors.white)
  os.pullEvent("key")
end

local function saisir(invite, defaut)
  couleur(colors.white)
  write(invite)
  if defaut and defaut ~= "" then write(" [" .. defaut .. "] ") end
  local texte = read()
  if texte == nil or texte == "" then return defaut end
  return texte
end

--------------------------------------------------------------------------------
-- Reseau
--------------------------------------------------------------------------------

local function detecterModem()
  if config.coteModem then
    if peripheral.isPresent(config.coteModem) then return config.coteModem end
    error(("aucun modem sur le cote configure '%s'"):format(config.coteModem), 0)
  end
  local sansFil, filaire
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
        sansFil = sansFil or nom
      else
        filaire = filaire or nom
      end
    end
  end
  local choisi = sansFil or filaire
  if not choisi then error("aucun modem detecte sur la borne", 0) end
  return choisi
end

local function ouvrirReseau()
  coteModem = detecterModem()
  rednet.open(coteModem)
  if not rednet.isOpen(coteModem) then
    error("rednet.open a echoue sur le cote " .. coteModem, 0)
  end
  log("info", ETAPES.OUVERTURE_REDNET, "rednet ouvert sur '%s'", coteModem)
end

local function pourNous(message)
  if not Protocole.valide(message) then return false end
  if config.navireCible and message.navire ~= config.navireCible then return false end
  return true
end

-- Envoie une demande et attend la premiere reponse du type voulu.
local function interroger(typeDemande, contenu, typeAttendu)
  local ok, err = pcall(rednet.broadcast,
    Protocole.enveloppe(typeDemande, contenu or {}), Protocole.PROTOCOLE)
  if not ok then
    log("erreur", ETAPES.CATALOGUE, "diffusion impossible : %s", tostring(err))
    return nil, "reseau indisponible : " .. tostring(err)
  end

  local minuteur = os.startTimer(config.delaiReponse or 5)
  while true do
    local ev = table.pack(os.pullEvent())
    if ev[1] == "rednet_message" and ev[4] == Protocole.PROTOCOLE then
      local message = ev[3]
      if pourNous(message) and message.type == typeAttendu then
        return message, nil, ev[2]
      end
    elseif ev[1] == "timer" and ev[2] == minuteur then
      return nil, "aucune reponse du navire dans le delai imparti"
    end
  end
end

--------------------------------------------------------------------------------
-- Catalogue
--------------------------------------------------------------------------------

local function rafraichirCatalogue(silencieux)
  -- 1) Source locale si la borne est cablee au stockage : toujours a jour,
  --    meme quand le navire est en mission a l'autre bout de la carte.
  local locaux = config.conteneursSourceLocaux or {}
  if #locaux > 0 then
    local articles, erreurs = Inventaire.catalogue(locaux, true)
    if #articles > 0 then
      catalogue.articles = articles
      catalogue.horodatage = os.clock()
      log("info", ETAPES.CATALOGUE, "catalogue local : %d type(s), %d erreur(s)",
        #articles, #erreurs)
    end
  end

  -- 2) Le navire fait foi pour les tarifs, les limites et son etat.
  local reponse, err = interroger(Protocole.TYPES.CATALOGUE_DEMANDE,
    { force = true }, Protocole.TYPES.CATALOGUE)
  if reponse then
    if #locaux == 0 then catalogue.articles = reponse.articles or {} end
    catalogue.tarif     = reponse.tarif
    catalogue.limites   = reponse.limites
    catalogue.etat      = reponse.etat
    catalogue.navire    = reponse.navire
    catalogue.nomNavire = reponse.nomNavire
    catalogue.horodatage = os.clock()
    log("info", ETAPES.CATALOGUE, "catalogue du navire '%s' : %d type(s)",
      tostring(reponse.navire), #(reponse.articles or {}))
    return true
  end

  log("avert", ETAPES.CATALOGUE, "catalogue non rafraichi : %s", tostring(err))
  if not silencieux then
    couleur(colors.red)
    print("Navire injoignable : " .. tostring(err))
    couleur(colors.white)
    if #catalogue.articles > 0 then
      print("Affichage du dernier catalogue connu.")
    end
  end
  return false, err
end

local function afficherPage(articles, page, parPage, filtre)
  local debut = (page - 1) * parPage + 1
  local fin = math.min(#articles, debut + parPage - 1)
  for i = debut, fin do
    local a = articles[i]
    couleur(colors.white)
    print(("%2d. %-28s %8d"):format(i, (a.libelle or a.nom):sub(1, 28), a.quantite))
  end
  couleur(colors.lightGray)
  print(("Page %d / %d -- %d type(s)%s")
    :format(page, math.max(1, math.ceil(#articles / parPage)), #articles,
            filtre and (" -- filtre '" .. filtre .. "'") or ""))
  couleur(colors.white)
end

local function filtrerArticles(filtre)
  if not filtre or filtre == "" then return catalogue.articles end
  local motif = filtre:lower()
  local resultat = {}
  for _, a in ipairs(catalogue.articles) do
    if a.nom:lower():find(motif, 1, true)
       or (a.libelle and a.libelle:lower():find(motif, 1, true)) then
      resultat[#resultat + 1] = a
    end
  end
  return resultat
end

--------------------------------------------------------------------------------
-- Formulaire de commande
--------------------------------------------------------------------------------

local function saisirArticles()
  local panier, parPage = {}, config.articlesParPage or 10
  local page, filtre = 1, nil

  while true do
    local articles = filtrerArticles(filtre)
    entete("1/3 - CHOIX DES OBJETS ET DES QUANTITES")

    if #articles == 0 then
      couleur(colors.red)
      print("Catalogue vide ou aucun objet ne correspond au filtre.")
      couleur(colors.white)
    else
      afficherPage(articles, page, parPage, filtre)
    end

    if #panier > 0 then
      couleur(colors.lime)
      print("Panier :")
      for i, ligne in ipairs(panier) do
        print(("  %d) %s x %d"):format(i, ligne.nom, ligne.quantite))
      end
      couleur(colors.white)
    end

    print("")
    print("[numero] ajouter  [s]uivant  [p]recedent  [c]hercher")
    print("[r]etirer une ligne  [v]alider  [a]nnuler")
    local choix = saisir("> ", "")

    if choix == nil or choix == "a" then
      return nil
    elseif choix == "v" then
      if #panier == 0 then
        print("Panier vide : ajoutez au moins un objet.")
        pause()
      else
        return panier
      end
    elseif choix == "s" then
      if page * parPage < #articles then page = page + 1 end
    elseif choix == "p" then
      if page > 1 then page = page - 1 end
    elseif choix == "c" then
      filtre = saisir("Filtre (nom ou fragment, vide = tout) : ", "")
      if filtre == "" then filtre = nil end
      page = 1
    elseif choix == "r" then
      local n = tonumber(saisir("Ligne a retirer : ", ""))
      if n and panier[n] then table.remove(panier, n) end
    else
      local indice = tonumber(choix)
      local article = indice and articles[indice]
      if not article then
        print("Numero inconnu.")
        pause()
      else
        local limites = catalogue.limites or {}
        local maximum = math.min(article.quantite, limites.maxQuantite or 100000)
        print(("%s : %d disponible(s), maximum commandable %d")
          :format(article.nom, article.quantite, maximum))
        local quantite = tonumber(saisir("Quantite : ", ""))
        if not quantite or quantite <= 0 or quantite ~= math.floor(quantite) then
          print("Quantite invalide : entier strictement positif attendu.")
          pause()
        elseif quantite > maximum then
          print(("Quantite plafonnee a %d."):format(maximum))
          pause()
        else
          -- Regroupement : une seule ligne par type d'objet.
          local fusionnee = false
          for _, ligne in ipairs(panier) do
            if ligne.nom == article.nom then
              ligne.quantite = math.min(maximum, ligne.quantite + quantite)
              fusionnee = true
              break
            end
          end
          if not fusionnee then
            if #panier >= (limites.maxLignes or 12) then
              print(("Nombre de lignes maximal atteint (%d)."):format(limites.maxLignes or 12))
              pause()
            else
              panier[#panier + 1] = { nom = article.nom, quantite = quantite,
                                      libelle = article.libelle }
            end
          end
        end
      end
    end
  end
end

local function saisirVitesse(panier)
  local tarif = catalogue.tarif
  local rapide = Protocole.calculerPaiement(panier, Protocole.VITESSES.RAPIDE, tarif)
  local lent   = Protocole.calculerPaiement(panier, Protocole.VITESSES.LENT, tarif)

  while true do
    entete("2/3 - NIVEAU DE SERVICE")
    print("Deux niveaux de service sont proposes :")
    print("")
    couleur(colors.orange)
    print(("  [1] fast ship  - livraison prioritaire  : %d x %s")
      :format(rapide.quantite, rapide.objet))
    couleur(colors.lightBlue)
    print(("  [2] slow ship  - livraison economique   : %d x %s")
      :format(lent.quantite, lent.objet))
    couleur(colors.white)
    print("")
    print("fast ship part en tete de file et vole a la vitesse maximale")
    print("autorisee par l'autopilote ; slow ship coute moins cher.")
    print("")
    local choix = saisir("Votre choix (1/2, a=annuler) : ", "2")
    if choix == "a" then return nil end
    if choix == "1" then return Protocole.VITESSES.RAPIDE, rapide end
    if choix == "2" then return Protocole.VITESSES.LENT, lent end
  end
end

local function saisirDestination()
  local limites = catalogue.limites or {}
  local portee = limites.maxPortee or 100000

  while true do
    entete("3/3 - POINT DE DEPOT")
    print("Indiquez les coordonnees EXACTES du point de depot.")
    print("Relevez-les en jeu avec F3, ligne 'Block'.")
    print("")
    print("Prevoyez a cet endroit :")
    print("  - un coffre de PAIEMENT accessible au navire ;")
    print("  - un coffre de RECEPTION pour la marchandise ;")
    print("  - les deux relies par modem filaire a la plateforme.")
    print("")

    local x = tonumber(saisir("X : ", ""))
    local y = tonumber(saisir("Y : ", ""))
    local z = tonumber(saisir("Z : ", ""))

    if not (x and y and z) then
      print("Coordonnees incompletes.")
      pause()
    elseif x ~= math.floor(x) or y ~= math.floor(y) or z ~= math.floor(z) then
      print("Coordonnees entieres attendues (pas de decimales).")
      pause()
    elseif math.abs(x) > portee or math.abs(z) > portee then
      print(("Hors de la zone desservie (+/- %d blocs)."):format(portee))
      pause()
    elseif y < -128 or y > 1024 then
      print("Altitude hors limites (-128 a 1024).")
      pause()
    else
      return { x = x, y = y, z = z }
    end
  end
end

local function nouvelIdentifiant()
  local base = os.epoch and os.epoch("utc") or (os.clock() * 1000)
  return ("CMD-%d-%d"):format(os.getComputerID(), math.floor(base) % 1000000)
end

local function envoyerCommande(commande)
  log("info", ETAPES.ENVOI_COMMANDE,
    "envoi de la commande %s : %d ligne(s), %s, depot %d %d %d, prix %d x %s",
    commande.id, #commande.articles, commande.vitesse,
    commande.destination.x, commande.destination.y, commande.destination.z,
    commande.paiement.quantite, commande.paiement.objet)

  local reponse, err = interroger(Protocole.TYPES.COMMANDE,
    { commande = commande }, Protocole.TYPES.ACCUSE)

  if not reponse then
    log("erreur", ETAPES.ATTENTE_ACCUSE, "aucun accuse pour %s : %s", commande.id, tostring(err))
    return false, err
  end
  if not reponse.accepte then
    log("avert", ETAPES.ATTENTE_ACCUSE, "commande %s refusee : %s",
      commande.id, tostring(reponse.motif))
    return false, reponse.motif
  end

  log("info", ETAPES.ATTENTE_ACCUSE, "commande %s acceptee, rang %d",
    commande.id, reponse.rang or 0)
  return true, reponse
end

local function passerCommande()
  if #catalogue.articles == 0 then
    entete("COMMANDE")
    print("Catalogue inconnu : contact du navire en cours...")
    rafraichirCatalogue()
    if #catalogue.articles == 0 then
      print("Impossible d'etablir le catalogue. Reessayez plus tard.")
      pause()
      return
    end
  end

  local panier = saisirArticles()
  if not panier then return end

  local vitesse, paiement = saisirVitesse(panier)
  if not vitesse then return end

  local destination = saisirDestination()
  if not destination then return end

  local client = saisir("Nom du joueur ou de la faction : ", config.clientParDefaut or "")
  if client == nil then client = "" end

  local commande = {
    id          = nouvelIdentifiant(),
    client      = client:sub(1, 48),
    articles    = panier,
    vitesse     = vitesse,
    destination = destination,
    paiement    = paiement,
  }

  -- Verification locale avant l'envoi : autant refuser tout de suite ce que
  -- le navire refuserait de toute facon.
  local valide, erreur = Protocole.validerCommande(commande, catalogue.limites)
  if not valide then
    entete("COMMANDE REFUSEE")
    couleur(colors.red)
    print("Commande invalide : " .. tostring(erreur))
    couleur(colors.white)
    pause()
    return
  end

  entete("RECAPITULATIF")
  print("Commande  : " .. commande.id)
  print("Client    : " .. (commande.client ~= "" and commande.client or "anonyme"))
  print("Service   : " .. (vitesse == Protocole.VITESSES.RAPIDE and "fast ship" or "slow ship"))
  print(("Depot     : %d %d %d"):format(destination.x, destination.y, destination.z))
  print("Articles  :")
  for _, ligne in ipairs(panier) do
    print(("  - %s x %d"):format(ligne.nom, ligne.quantite))
  end
  couleur(colors.yellow)
  print(("PRIX      : %d x %s"):format(paiement.quantite, paiement.objet))
  couleur(colors.white)
  print("")
  print(config.rappelPaiement or "")
  print("")

  local confirmation = saisir("Confirmer l'envoi ? (o/N) : ", "n")
  if confirmation ~= "o" and confirmation ~= "O" then
    print("Commande abandonnee.")
    pause()
    return
  end

  local ok, resultat = envoyerCommande(commande)
  entete("ENVOI")
  if ok then
    commande.rang = resultat.rang
    commande.paiement = resultat.paiement or commande.paiement
    mesCommandes[#mesCommandes + 1] = commande
    couleur(colors.lime)
    print("Commande acceptee par le navire.")
    couleur(colors.white)
    print(("Reference : %s"):format(commande.id))
    print(("Rang dans la file : %d"):format(resultat.rang or 0))
    print(("Montant a deposer : %d x %s")
      :format(commande.paiement.quantite, commande.paiement.objet))
    print("")
    print(config.rappelPaiement or "")
  else
    couleur(colors.red)
    print("Commande refusee : " .. tostring(resultat))
    couleur(colors.white)
  end
  pause()
end

--------------------------------------------------------------------------------
-- Suivi et annulation
--------------------------------------------------------------------------------

local function suivreCommandes()
  while true do
    rafraichirCatalogue(true)
    entete("SUIVI DES COMMANDES DE CETTE BORNE")

    if #mesCommandes == 0 then
      print("Aucune commande deposee depuis cette borne.")
    else
      for i, c in ipairs(mesCommandes) do
        print(("%d) %s  %s  %d %d %d  %d x %s"):format(
          i, c.id, c.vitesse, c.destination.x, c.destination.y, c.destination.z,
          c.paiement.quantite, c.paiement.objet))
      end
    end

    local e = catalogue.etat
    if e then
      print("")
      print(("Navire : phase %s, commande en cours %s, file %d")
        :format(tostring(e.phase), tostring(e.commande or "aucune"), e.file or 0))
      if e.erreur then
        couleur(colors.red)
        print("Derniere erreur : " .. tostring(e.erreur))
        couleur(colors.white)
      end
    end

    print("")
    local choix = saisir("[numero] annuler  [r]afraichir  [q]uitter : ", "q")
    if choix == "q" or choix == nil then return end
    if choix ~= "r" then
      local n = tonumber(choix)
      local c = n and mesCommandes[n]
      if c then
        local reponse, err = interroger(Protocole.TYPES.ANNULATION,
          { commande = c.id }, Protocole.TYPES.ACCUSE)
        if reponse and reponse.accepte then
          log("info", ETAPES.ANNULATION, "commande %s annulee", c.id)
          table.remove(mesCommandes, n)
          print("Commande annulee.")
        else
          print("Annulation refusee : "
            .. tostring(reponse and reponse.motif or err))
        end
        pause()
      end
    end
  end
end

local function afficherCatalogue()
  local page, parPage, filtre = 1, config.articlesParPage or 10, nil
  while true do
    local articles = filtrerArticles(filtre)
    entete("CATALOGUE DU CONTENEUR SOURCE")
    if #articles == 0 then
      print("Catalogue vide.")
    else
      afficherPage(articles, page, parPage, filtre)
    end
    print("")
    local choix = saisir("[s]uivant [p]recedent [c]hercher [r]afraichir [q]uitter : ", "q")
    if choix == "q" or choix == nil then return end
    if choix == "s" and page * parPage < #articles then page = page + 1 end
    if choix == "p" and page > 1 then page = page - 1 end
    if choix == "c" then
      filtre = saisir("Filtre : ", "")
      if filtre == "" then filtre = nil end
      page = 1
    end
    if choix == "r" then rafraichirCatalogue() end
  end
end

--------------------------------------------------------------------------------
-- Boucle principale
--------------------------------------------------------------------------------

local function menu()
  while true do
    entete(nil)
    print("[1] Passer une commande")
    print("[2] Suivre / annuler mes commandes")
    print("[3] Consulter le catalogue")
    print("[4] Rafraichir l'etat du navire")
    print("[Q] Quitter")
    print("")
    local choix = saisir("> ", "")
    if choix == "1" then
      journal.proteger(ETAPES.SAISIE_ARTICLES, passerCommande)
    elseif choix == "2" then
      journal.proteger(ETAPES.SUIVI, suivreCommandes)
    elseif choix == "3" then
      journal.proteger(ETAPES.CATALOGUE, afficherCatalogue)
    elseif choix == "4" then
      rafraichirCatalogue()
      pause()
    elseif choix == "q" or choix == "Q" then
      if config.robustesse.arretParTerminate then
        local f = fs.open(MARQUEUR_ARRET, "w")
        if f then f.write("arret manuel") f.close() end
        error("ARRET_MANUEL", 0)
      end
    end
  end
end

local function cyclePrincipal()
  config = charger(CHEMIN_CONFIG)
  if type(config) ~= "table" then error("config_borne.lua doit retourner une table", 0) end
  config.robustesse = config.robustesse or {}
  config.journal = config.journal or {}

  local Journal = charger(fs.combine(RACINE, "commun/journal.lua"))
  journal = Journal.creer({
    chemin      = versRacine(config.journal.fichier or "borne/borne.log"),
    tailleMax   = config.journal.tailleMax,
    niveauEcran = config.journal.niveauEcran or "AVERT",
  })
  log("info", ETAPES.DEMARRAGE, "borne publique FrenchNet v%s", VERSION_PROGRAMME)

  Protocole  = charger(fs.combine(RACINE, "commun/protocole.lua"))
  Inventaire = charger(fs.combine(RACINE, "commun/inventaire.lua"))
  log("info", ETAPES.CHARGEMENT_MODULES, "modules communs charges")

  ouvrirReseau()
  rafraichirCatalogue(true)

  menu()
end

--------------------------------------------------------------------------------
-- Superviseur : la borne est publique, elle ne doit jamais rester plantee.
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

    if ok then erreur = "la boucle de la borne s'est terminee" end

    if tostring(erreur):find("ARRET_MANUEL", 1, true) then
      print("[ARRET] arret manuel de la borne.")
      return
    end
    if tostring(erreur):find("Terminated", 1, true) then
      local f = fs.open(MARQUEUR_ARRET, "w")
      if f then f.write("arret manuel") f.close() end
      print("[ARRET] interruption clavier.")
      return
    end

    redemarrages = redemarrages + 1
    local etapeCourante = journal and journal.etapeCourante or ETAPES.DEMARRAGE
    if journal then
      log("critique", etapeCourante, "plantage a l'etape '%s' : %s",
        tostring(etapeCourante), tostring(erreur))
    else
      print("[CRITIQUE] [etape: " .. tostring(etapeCourante) .. "] " .. tostring(erreur))
    end

    if coteModem then pcall(rednet.close, coteModem) end
    coteModem = nil

    local minimum = (config and config.robustesse.redemarrageDelaiMin) or 3
    local maximum = (config and config.robustesse.redemarrageDelaiMax) or 30
    local delai = math.min(maximum, minimum * (2 ^ math.min(redemarrages - 1, 8)))
    print(("[AVERT] relance automatique n%d dans %d s"):format(redemarrages, delai))

    journal = nil
    os.sleep(delai)
  end
end

superviser()
