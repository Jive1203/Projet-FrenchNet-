--[[----------------------------------------------------------------------------
  PAGES DE LIVRAISON A AJOUTER A LA CONFIGURATION DU VEHICULE
  --------------------------------------------------------------------------
  LE FICHIER DE CONFIGURATION PAR VEHICULE EST CELUI DE L'AUTOPILOTE :

        /autopilote/config_vehicule.lua

  C'est lui qui porte deja, et qui reste seul a porter :

        nom, identifiant             identite du vehicule
        decalageGps                  point de reference GPS / centre du navire
        decalageDepot                point de depot et d'atterrissage
        tolerances                   marges en altitude, en cap, horizontale
        vitesses                     croisiere, verticaleMax, approche...
        gabarit                      longueur, largeur, hauteur
        gains                        gains PID de chaque axe
        ravitaillement               position fixe, verrouillee par le reseau

  RIEN DE TOUT CELA N'EST DUPLIQUE ICI, et le systeme de livraison n'y touche
  jamais : il se contente d'appeler l'autopilote.

  DEUX FACONS D'UTILISER CE FICHIER
  ---------------------------------
  1. RECOMMANDE - recopier les sections ci-dessous (conteneurs, livraison,
     tarif, reseau, journal, robustesse) a la fin de la table de
     /autopilote/config_vehicule.lua, juste avant son accolade fermante. Tout
     tient alors dans un seul fichier par vehicule, comme demande.

  2. Ou bien laisser ce fichier tel quel dans /navire/ : le programme le lit
     comme un RECOUVREMENT et ses valeurs l'emportent sur celles du fichier
     vehicule. Pratique quand plusieurs vehicules partagent la meme grille
     tarifaire, ou pour ne pas toucher au fichier de l'autopilote.

  Coordonnees : F3, ligne "Block" (et non "XYZ", qui donne la position du
  joueur avec des decimales).
--------------------------------------------------------------------------------]]

return {

  --------------------------------------------------------------- AUTOPILOTE ---
  -- Raccordement, rien de plus. Les valeurs par defaut conviennent a une
  -- installation standard de l'autopilote FrenchNet.
  autopilote = {
    -- Module d'autopilote a charger.
    chemin = "/autopilote/autopilote.lua",

    -- Fichier de configuration du vehicule. nil = le defaut du module,
    -- c'est-a-dire /autopilote/config_vehicule.lua.
    cheminConfig = nil,

    -- Table globale deja chargee par un startup, si votre installation en
    -- expose une. nil dans le cas normal.
    nomGlobal = nil,

    -- Delai maximal accorde a un trajet, en secondes, avant d'abandonner.
    delaiArriveeMax = 900,
  },

  ------------------------------------------------------------------ CENTRAL ---
  -- L'ORDINATEUR CENTRAL DETIENT LES PRIX. Le navire ne fixe rien : il
  -- applique la grille diffusee, et la section 'tarif' plus bas ne sert que
  -- de repli tant que le central ne s'est pas manifeste.
  central = {
    -- Identifiant de la centrale tarifaire. Une grille qui se reclame d'un
    -- autre identifiant est ignoree.
    identifiant = "CENTRALE-01",

    -- JETON PARTAGE, identique sur le central, les navires et les bornes.
    -- Il signe la grille recue et les certificats de pre-paiement emis par
    -- les bornes. Ce n'est pas de la cryptographie : qui lit ce fichier
    -- connait le jeton. Cela empeche l'erreur et le bricolage, pas un joueur
    -- qui aurait deja acces a l'ordinateur.
    jeton = "CHANGEZ-MOI-jeton-partage-frenchnet",

    -- true : aucune commande n'est acceptee tant que la grille centrale n'a
    -- pas ete recue. Plus sur commercialement, mais le navire est inutile si
    -- le central tombe.
    exigerCentral = false,

    -- Attente d'une reponse du central au demarrage, en secondes.
    delaiDemande = 5,
  },

  ---------------------------------------------------------------- PENALITES ---
  -- Repli applique tant que le central n'a pas diffuse son propre regime.
  -- Un client qui laisse le navire repartir sans payer est marque.
  penalites = {
    -- "prepaiement" : ses commandes suivantes exigent un reglement a la borne
    -- "refus"       : ses commandes sont refusees jusqu'a expiration
    mode = "prepaiement",
    duree = 3600,                  -- secondes
    incidentsAvantPenalite = 1,
    effacerApres = 86400,          -- oubli d'un incident reste sans suite
  },

  --------------------------------------------------------------- CONTENEURS ---
  -- UNE PAGE PAR CONTENEUR DE CARGAISON.
  --
  -- LE PLUS SIMPLE EST DE NE PAS LES ECRIRE ICI : l'interface de reglage de
  -- l'autopilote a une section CONTENEURS qui les detecte, les configure et
  -- les ecrit dans /autopilote/config_vehicule.lua.
  --
  --     interface        puis section Conteneurs
  --                      D detecter   N ajouter   Suppr retirer
  --
  -- Ce qui suit reste utile pour un parc de vaisseaux identiques, ou pour
  -- relire d'un coup d'oeil ce qui est branche.
  -- 'peripherique' est le nom RESEAU rendu par peripheral.getNames() : le
  -- conteneur doit etre relie au calculateur par un modem filaire.
  -- 'decalage' est sa position PAR RAPPORT AU CENTRE DU NAVIRE, en blocs,
  -- dans le meme repere que les decalages de l'autopilote.
  -- 'role' :
  --    "expedition"  soute de livraison, videe chez le destinataire
  --    "recette"     coffre ou est aspire le paiement
  --    "tampon"      reserve interne, jamais livree
  conteneurs = {

    {
      nom          = "Soute avant",
      peripherique = "minecraft:barrel_0",
      decalage     = { x = -4, y = -1, z = 6 },
      role         = "expedition",
      priorite     = 1,          -- ordre de remplissage au chargement
      capacite     = 27,         -- emplacements, indicatif
    },

    {
      nom          = "Soute arriere",
      peripherique = "minecraft:barrel_1",
      decalage     = { x = 4, y = -1, z = -6 },
      role         = "expedition",
      priorite     = 2,
      capacite     = 27,
    },

    {
      nom          = "Coffre de recette",
      peripherique = "minecraft:chest_0",
      decalage     = { x = 0, y = 1, z = 0 },
      role         = "recette",
      priorite     = 1,
      capacite     = 27,
    },
  },

  ---------------------------------------------------------------- LIVRAISON ---
  livraison = {

    -- CONTENEUR SOURCE au sol, a la base : le grand stockage dans lequel le
    -- navire preleve la marchandise au chargement. Plusieurs noms possibles
    -- (un bulk container Create, une rangee de vaults, un entrepot...).
    conteneursSource = {
      "create:item_vault_0",
      "create:item_vault_1",
    },

    -- Le chargement n'est possible que si le navire se trouve a moins de
    -- 'distanceChargement' blocs du point de chargement (donc a la base).
    pointChargement    = { x = 1200, y = 95, z = -2600 },
    distanceChargement = 24,

    -- COFFRE DE PAIEMENT chez le destinataire. Au point de depot, le navire
    -- cherche sur son reseau les inventaires qui ne sont ni les siens ni ceux
    -- de la base : ce sont ceux du client, raccordes a sa plateforme
    -- d'accueil par modem filaire. 'motifPaiement' filtre le nom du coffre de
    -- paiement parmi ceux-la.
    motifPaiement  = "chest",
    -- Nom impose du coffre de paiement. Prioritaire sur 'motifPaiement'.
    coffrePaiement = nil,
    -- Nom impose du coffre de reception de la marchandise. nil = detection.
    coffreReception = nil,

    -- Attente du paiement a l'arrivee, en secondes. Passe ce delai, le
    -- navire quitte la zone, la commande est annulee et le client penalise.
    -- 0 = attendre indefiniment (deconseille : le navire y reste bloque).
    delaiPaiementMax     = 300,
    intervallePaiement   = 5,    -- secondes entre deux verifications
    rappelPaiementToutes = 60,   -- secondes entre deux lignes de journal

    -- POINTS DE RETOUR. Le navire y revient seul une fois toutes les
    -- commandes terminees, sans nouvel ordre.
    --   choixRetour = "auto"    -> le plus proche du dernier point de depot
    --   choixRetour = "manuel"  -> celui marque principal = true
    choixRetour = "auto",
    pointsRetour = {
      { nom = "BASE-NORD",   x = 1200, y = 95,  z = -2600, principal = true,
        rayonSecurite = 32 },
      { nom = "RELAIS-EST",  x = 4300, y = 88,  z = 500,   principal = false,
        rayonSecurite = 32 },
      { nom = "RELAIS-SUD",  x = -800, y = 120, z = 3300,  principal = false,
        rayonSecurite = 32 },
    },

    -- Niveau de service 'slow ship' : fraction de la vitesse de croisiere du
    -- vehicule (vitesses.croisiere du fichier autopilote) transmise comme
    -- plafond de vitesse a l'autopilote. 1.0 = aucune difference reelle.
    facteurVitesseLente = 0.6,

    -- Passage a la station de ravitaillement du reseau apres N livraisons.
    -- 0 = jamais. La position, elle, appartient a l'autopilote.
    ravitaillerToutesLes = 0,

    -- Garde-fous appliques a toute commande venant de la borne publique.
    limites = {
      maxLignes   = 12,       -- lignes d'articles par commande
      maxQuantite = 100000,   -- objets par commande (bulk container Create)
      maxPortee   = 100000,   -- blocs, distance maximale desservie
      fileMax     = 20,       -- commandes en attente
    },
  },

  -------------------------------------------------------------------- TARIF ---
  -- Grille publique. Le prix affiche par la borne est EXACTEMENT celui que le
  -- navire exigera a l'arrivee : les deux utilisent ce meme calcul.
  tarif = {
    objetPaiement      = "minecraft:diamond",
    forfaitBase        = 5,       -- prix plancher de toute expedition
    prixUnitaireDefaut = 0.01,    -- par objet transporte
    parObjet = {                  -- tarifs specifiques, par identifiant d'objet
      ["minecraft:netherite_ingot"] = 1.0,
      ["minecraft:diamond"]         = 0.5,
      ["minecraft:iron_ingot"]      = 0.02,
      ["minecraft:cobblestone"]     = 0.002,
    },
    coefficientVitesse = { fast = 2.0, slow = 1.0 },
    prixMinimum        = 1,
    prixMaximum        = 2304,    -- 36 piles de diamants : plafond raisonnable
  },

  ------------------------------------------------------------------- RESEAU ---
  reseau = {
    -- Cote du modem sans fil / Ender. nil = detection automatique.
    coteModem = nil,
    -- Diffusion periodique de l'etat du navire vers les bornes (secondes).
    diffusionEtat = 10,
    -- Diffusion periodique du catalogue du conteneur source (secondes).
    diffusionCatalogue = 60,
  },

  ------------------------------------------------------------------ JOURNAL ---
  -- Journal DU SYSTEME DE LIVRAISON. L'autopilote tient le sien, separement.
  journal = {
    fichier     = "navire/livraison.log",
    tailleMax   = 128 * 1024,
    -- Verbosite ECRAN uniquement : "DEBUG" | "INFO" | "AVERT" | "ERREUR".
    -- Le fichier enregistre toujours tout.
    niveauEcran = "INFO",
  },

  --------------------------------------------------------------- ROBUSTESSE ---
  robustesse = {
    -- Temporisation progressive entre deux relances automatiques.
    redemarrageDelaiMin = 3,
    redemarrageDelaiMax = 60,
    -- true  : Ctrl+T arrete le programme (phase de reglage).
    -- false : Ctrl+T est ignore et journalise -> autonomie totale.
    arretParTerminate = true,
    -- Fichier de reprise : phase de mission et file de commandes.
    etat = "navire/etat.dat",
  },
}
