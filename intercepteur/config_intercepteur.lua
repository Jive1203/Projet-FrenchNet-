--[[----------------------------------------------------------------------------
  CONFIGURATION D'UN NAVIRE INTERCEPTEUR - FRENCHNET / AERONAUTICS WARFARE
  --------------------------------------------------------------------------
  UN SEUL FICHIER DE REGLAGE PAR VEHICULE : autopilote/config_vehicule.lua.
  Ce fichier-ci ne le duplique PAS - il le designe (cheminConfigVehicule) et
  peut le surcharger ponctuellement via le bloc 'autopilote'. Gabarit,
  moteurs, gains PID et enveloppe de vol restent au meme endroit pour tous les
  programmes du vehicule.

  Quatre champs seulement sont reellement obligatoires :

      identifiant          -> unique pour chaque navire du serveur
      cheminConfigVehicule -> le fichier de reglage de l'autopilote
      arme.armes           -> au moins une arme embarquee
      retour.pointsRetour  -> au moins un point ; le dernier est la base

  ATTENTION - HYPOTHESES A VALIDER AVANT LE PREMIER VOL ARME :
  les seuils du bloc 'degats' et la balistique de chaque arme sont des valeurs
  de depart plausibles, PAS des mesures faites sur votre serveur. Relevez les
  votres en vol d'essai (le journal en mode DEBUG donne tout ce qu'il faut)
  avant d'engager un navire avec du materiel reel.
--------------------------------------------------------------------------------]]

return {

  ---------------------------------------------------------------- IDENTITE ----

  -- Identifiant unique. Le systeme au sol s'en sert pour adresser ses ordres :
  -- un ordre dont le champ 'destinataire' ne correspond pas est ignore, et un
  -- ordre sans destinataire s'adresse a tous les navires.
  identifiant = "INT-01",

  -- Libelle libre, purement informatif.
  designation = "Intercepteur de scramble - escadrille nord",

  ----------------------------------------------------------------- RESEAU -----

  -- Protocole rednet des ordres. Doit etre IDENTIQUE cote sol.
  protocoleRednet = "frenchnet_ordre",

  -- Cote du modem Ender. nil = detection automatique (Ender prioritaire).
  coteModem = nil,

  -- Cote du radar embarque. nil = detection automatique par type.
  coteRadar = nil,

  -- Repondre au sol (accuse de reception, compte rendu de fin de mission).
  -- Purement informatif : le navire n'attend jamais de reponse et ne modifie
  -- jamais son comportement en fonction de ce qu'il envoie.
  accuserReception = true,

  -- Ordinateur du poste de commandement, destinataire des comptes rendus.
  -- nil = aucun compte rendu spontane.
  posteDeCommandement = nil,

  -- Liste blanche d'ordinateurs autorises a donner des ordres.
  -- nil = tout le monde. Utile si plusieurs reseaux coexistent.
  expediteursAutorises = nil,

  ------------------------------------------------------------- AUTOPILOTE -----

  -- MODULE D'AUTOPILOTE STANDARDISE.
  -- Le systeme d'interception n'ecrit AUCUNE loi de vol : asservissement en
  -- cascade, PID principal et repli en zone morte appartiennent a ce module.
  -- S'il est introuvable, le navire refuse de decoller.
  cheminAutopilote = "/autopilote/autopilote.lua",

  -- FICHIER DE REGLAGE DU VEHICULE. C'est le MEME fichier que celui de
  -- l'autopilote : gabarit, moteurs, gains PID, vitesses, tolerances,
  -- enveloppe de vol. Il n'y a donc qu'un seul fichier de reglage par
  -- vehicule, et il n'est PAS duplique ici.
  --   -> reglez-le avec : autopilote/interface.lua, ou la page Autopilote du
  --      systeme d'exploitation de bord.
  cheminConfigVehicule = "/autopilote/config_vehicule.lua",

  -- Surcouche ponctuelle appliquee PAR-DESSUS config_vehicule.lua, uniquement
  -- pour ce que la mission d'interception impose. Fusion recursive : tout ce
  -- qui n'est pas mentionne ici garde la valeur du fichier vehicule.
  -- Laisser vide en temps normal.
  autopilote = {
    -- Limitation du debit des consignes. La boucle de controle tourne a 4 Hz,
    -- mais chaque consigne transmise a l'autopilote recalcule un itineraire et
    -- journalise une ligne : on ne la reemet donc que si le point a bouge
    -- notablement, ou apres un delai.
    seuilDeplacementConsigne       = 8,   -- blocs
    seuilVitesseConsigne           = 5,   -- b/s
    periodeRafraichissementConsigne = 2,  -- secondes

    -- Exemple de surcouche : resserrer une tolerance uniquement en scramble.
    -- tolerances = { horizontale = 6 },
  },

  -------------------------------------------------------------- CADENCES ------

  -- Periode de la boucle de controle (secondes). 0,25 s = 5 ticks.
  periodeControle = 0.25,

  -- Periode de balayage radar (secondes).
  periodeRadar = 0.5,

  -- Resume d'etat dans le journal (secondes).
  battementSecondes = 30,

  -- Duree de recherche a l'estime apres perte du contact radar, avant
  -- d'abandonner la poursuite et de rentrer (secondes).
  delaiRechercheSecondes = 30,

  ----------------------------------------------------------- INTERCEPTION -----

  interception = {
    -- ARC ARRIERE. 120 deg = 4 heures, 240 deg = 8 heures, 180 deg = 6 heures
    -- (droit derriere la cible). Le navire ne se presente JAMAIS de face.
    arcMiniDeg   = 120,
    arcMaxiDeg   = 240,
    arcCentreDeg = 180,
    -- Marge conservee par rapport aux bords de l'arc quand le navire le
    -- rejoint par le flanc.
    margeArcDeg  = 10,

    -- MANOEUVRE une fois en position : "orbite" (sinusoidale) ou "zigzag"
    -- (triangulaire). Le navire ne reste jamais statique derriere la cible.
    manoeuvre           = "orbite",
    arcAmplitudeDeg     = 45,   -- balayage de part et d'autre de 6 heures
    arcPeriodeSecondes  = 12,   -- periode du balayage angulaire

    -- BANDE DE DISTANCE de tenue de position (blocs).
    distanceMini      = 300,
    distanceMaxi      = 400,
    distanceAmplitude = 30,     -- oscillation de la distance de consigne

    -- Sous cette distance, le navire ralentit sous la vitesse de la cible pour
    -- rouvrir l'ecart (anti-collision). Doit rester sous 'distanceMini'.
    distanceSecurite = 150,
    -- Au-dela de cet ecart, le navire fonce a vitesse maximale (rejointe).
    distanceTransit  = 250,

    -- ECART VERTICAL de consigne et tolerance de tenue de position.
    deltaYNominal     = 0,
    deltaYAmplitude   = 15,
    toleranceAltitude = 60,

    -- PREDICTION D'INTERCEPTION (secondes). Le navire vise la position FUTURE
    -- de la cible, jamais sa position actuelle. Bornes du temps de vol estime.
    predictionMiniSecondes = 1,
    predictionMaxiSecondes = 10,

    -- ASSERVISSEMENT DE VITESSE sur celle de la cible.
    vitesseMaxi        = 120,   -- doit correspondre a l'enveloppe du vehicule
    vitesseMini        = 0,
    vitesseReference   = 60,    -- vitesse supposee si la telemetrie manque
    gainRapprochement  = 0.35,  -- b/s de correction par bloc d'erreur
    ratioMini          = 0.6,   -- jamais moins de 60 % de la vitesse cible
    ratioMaxi          = 1.6,   -- jamais plus de 160 %
    vitesseMiniPourCap = 2,     -- sous ce seuil, le cap cible n'est pas fiable
  },

  ---------------------------------------------------------------- DEGATS ------

  -- CRITERES DE DEGAT. Le MEME jeu de seuils sert deux fois :
  --   * a decider que LE NAVIRE est touche  -> manoeuvre d'evasion prioritaire ;
  --   * a decider que LA CIBLE est touchee  -> premiere etape de la
  --     confirmation de destruction.
  -- HYPOTHESE : ces valeurs n'ont PAS ete mesurees sur votre serveur. Volez en
  -- journalNiveauEcran = "DEBUG" et relevez les vraies signatures avant de les
  -- considerer comme acquises.
  degats = {
    fenetreSecondes    = 3,     -- fenetre glissante d'analyse
    dureeMiniSecondes  = 0.5,   -- en dessous, on refuse de conclure

    chuteAltitudeBlocs = 25,    -- perte d'altitude sur la fenetre
    perteVitesseRatio  = 0.40,  -- perte de vitesse relative
    perteVitesseMini   = 15,    -- ... et perte absolue minimale (anti-fausse alarme)

    -- Signes terminaux exiges EN PLUS d'un degat avere pour conclure a la
    -- destruction. Un degat seul ne suffit pas : un appareil touche peut se
    -- retablir.
    perteContactSecondes = 5,   -- silence radar consecutif au degat
    altitudeSolConfirmee = 5,   -- cible descendue sous cette altitude
    vitesseEpaveMaxi     = 3,   -- cible immobile...
    dureeEpaveSecondes   = 4,   -- ... pendant ce temps

    -- Periode refractaire : delai minimal entre deux declenchements d'evasion,
    -- pour ne pas enchainer les manoeuvres sur un meme encaissement.
    refractaireSecondes = 8,
  },

  --------------------------------------------------------------- ARSENAL ------
  -- Le navire porte une LISTE d'armes. A chaque engagement, le systeme choisit
  -- celle dont la portee et l'utilite conviennent a la cible.
  --
  -- La page Armement du systeme d'exploitation de bord edite cette liste sans
  -- quitter le jeu : ajout, suppression, portee, utilite, balistique.

  arme = {
    -- Tolerance de pointage commune, en degres.
    toleranceViseeDeg = 3,

    -- REGLE D'ENGAGEMENT.
    --   true  : L'ORDRE DE TIR PRIME SUR LA POSITION. Le navire ouvre le feu
    --           des qu'il a une solution valable, meme s'il n'a pas encore
    --           rejoint son arc arriere. L'arc reste une consigne de
    --           trajectoire, rattrapee progressivement pendant le tir.
    --   false : comportement inverse, l'arc est un prealable au tir.
    prioriteTirSurPosition = true,

    -- Besoin d'armement par defaut quand la cible est en vol.
    besoinParDefaut = "anti-aerien",
    -- Une cible sous (relief + cette marge) est traitee comme une cible au sol.
    margeAltitudeSol = 12,

    -- LES ARMES. Au moins une est obligatoire.
    --   utilite : "anti-aerien" | "anti-sol" | "defensif" | "polyvalent"
    --             une arme polyvalente repond a tous les besoins ; une arme
    --             specialisee n'est choisie que pour le sien, et passe avant
    --             la polyvalente a portee equivalente.
    --   mode    : "peripherique" (affut pilotable) | "redstone" | "mixte"
    --   portees : fenetre d'emploi en blocs. Le navire cherche a tenir le
    --             CENTRE de cette fenetre sous ordre de feu.
    armes = {
      {
        identifiant  = "CANON-AA-1",
        nom          = "Canon automatique 4 pouces",
        utilite      = "anti-aerien",
        mode         = "peripherique",
        coteArme     = nil,        -- nil = premier affut libre detecte
        porteeMini   = 80,
        porteeMaxi   = 420,
        vitesseObus  = 80,         -- HYPOTHESE : a mesurer sur votre serveur
        graviteObus  = 9.8,        -- HYPOTHESE : a mesurer sur votre serveur
        dureeRafale  = 1.5,
        pauseRafale  = 2.0,
        tangageMini  = -60,
        tangageMaxi  = 60,
        actif        = true,
        note         = "arme principale d'interception",
      },
      {
        identifiant  = "MITRAILLEUSE-DEF",
        nom          = "Mitrailleuse de defense rapprochee",
        utilite      = "defensif",
        mode         = "redstone",
        coteRedstone = "back",
        porteeMini   = 10,
        porteeMaxi   = 120,
        vitesseObus  = 120,
        graviteObus  = 4.0,
        dureeRafale  = 0.8,
        pauseRafale  = 0.6,
        actif        = false,      -- passez a true une fois l'arme montee
        note         = "riposte a courte portee",
      },
    },
  },

  ----------------------------------------------------------------- RADAR ------

  radar = {
    -- Rayon d'appariement : un contact au-dela de cette distance de la
    -- position attendue n'est pas considere comme etant la cible suivie.
    rayonAppariement = 150,

    -- Lissage exponentiel de la vitesse estimee (0 = fige, 1 = brut).
    -- La vitesse alimente toute la prediction : un lissage trop faible fait
    -- danser le point d'interception, trop fort le fait trainer.
    lissageVitesse      = 0.35,
    dtMiniVitesse       = 0.15,  -- intervalle minimal entre deux echantillons
    echantillonsVitesse = 8,

    -- Ecart entre la vitesse annoncee par le mod et celle estimee, au-dela
    -- duquel on journalise une alerte (l'estimation reste prioritaire).
    ecartVitesseAlerte = 40,

    -- Age maximal d'un contact pour que la piste reste exploitable (secondes).
    delaiValiditePiste = 3,

    periodeJournalPistage = 5,
  },

  --------------------------------------------------------------- EVASION ------

  evasion = {
    dureeSecondes = 6,       -- duree de la manoeuvre avant reprise de l'attaque
    angleBreakDeg = 55,      -- rupture laterale : une fuite droite se tire trop bien
    distanceEvasion = 300,   -- longueur du degagement
    amplitudeVerticaleEvasion = 60,

    -- Enveloppe de vol respectee pendant l'evasion.
    altitudePlancher = 80,
    altitudePlafond  = 300,
    gardeAuSol       = 40,
    altitudeSolPresumee = 64,  -- relief moyen de la zone d'operation

    -- nil = vitesse maximale de l'enveloppe.
    vitesseEvasion = nil,
  },

  ---------------------------------------------------------- RETOUR BASE -------

  retour = {
    -- POINTS DE RETOUR, parcourus DANS L'ORDRE. Le dernier est la base.
    -- Meme systeme que pour la livraison : une liste de points configurables.
    -- Le rearmement, lui, reste une ACTION MANUELLE : a l'arrivee, le navire
    -- depose le fichier .rearmement_requis et refuse tout nouvel ordre de
    -- scramble tant que l'equipage ne l'a pas supprime.
    pointsRetour = {
      { x = 1500, y = 220, z = -2400, nom = "point de degagement" },
      { x = 1240, y = 200, z = -2580, nom = "entree de circuit" },
      { x = 1200, y = 150, z = -2600, nom = "base" },
    },

    -- Rayon de validation d'un point de retour (blocs).
    rayonPointRetour = 30,

    -- Vitesse de convoyage.
    vitesseRetour = 90,

    -- Altitude de croisiere imposee sur tous les points sauf le dernier.
    -- nil = on suit l'altitude de chaque point.
    altitudeCroisiere = 220,
  },

  --------------------------------------------------------------- JOURNAL ------

  -- Journal dans intercepteur.log, a cote du programme.
  journalFichier = true,

  -- Taille maximale avant rotation vers intercepteur.log.1 (octets).
  journalTailleMax = 98304,

  -- Verbosite ECRAN uniquement : "DEBUG" | "INFO" | "AVERT" | "ERREUR".
  -- Le fichier journal enregistre TOUJOURS tout, y compris les lignes de
  -- l'autopilote : le journal est PARTAGE, une mission se relit de bout en
  -- bout, vol compris.
  -- "DEBUG" trace chaque calcul de trajectoire d'interception : indispensable
  -- pendant les vols de reglage, verbeux en operation.
  journalNiveauEcran = "INFO",

  -- Periodicite du journal des calculs d'interception en DEBUG (secondes).
  periodeJournalInterception = 3,

  ------------------------------------------------------------- ROBUSTESSE -----

  -- true  : Ctrl+T arrete le systeme embarque (phase de reglage).
  -- false : Ctrl+T est ignore et journalise -> autonomie totale en vol.
  arretParTerminate = true,

  -- Temporisation progressive entre deux redemarrages automatiques (secondes).
  redemarrageDelaiMin = 3,
  redemarrageDelaiMax = 60,
}
