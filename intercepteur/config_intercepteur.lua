--[[----------------------------------------------------------------------------
  CONFIGURATION D'UN NAVIRE INTERCEPTEUR - FRENCHNET / AERONAUTICS WARFARE
  --------------------------------------------------------------------------
  UN SEUL FICHIER PAR VEHICULE. Le bloc 'autopilote' ci-dessous est transmis
  tel quel au module d'autopilote standardise (sections 6 et 7) : il n'y a
  donc pas deux fichiers de reglage a maintenir pour un meme navire.

  Trois champs seulement sont reellement obligatoires :

      identifiant          -> unique pour chaque navire du serveur
      cheminAutopilote     -> ou trouver le module d'autopilote standardise
      retour.pointsRetour  -> au moins un point ; le dernier est la base

  ATTENTION - HYPOTHESES A VALIDER AVANT LE PREMIER VOL ARME :
  les seuils du bloc 'degats' et la balistique du bloc 'arme' sont des valeurs
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

  -- OU TROUVER LE MODULE D'AUTOPILOTE STANDARDISE.
  -- Le systeme d'interception n'ecrit AUCUNE loi de vol : il appelle ce
  -- module. Si le fichier est introuvable, le navire refuse de decoller.
  cheminAutopilote = "/autopilote/autopilote.lua",

  -- Repli SANS loi de pilotage reelle, pour les bancs d'essai uniquement.
  -- Laisser IMPERATIVEMENT a false en production : un navire arme qui vole
  -- avec un controleur de substitution est plus dangereux qu'un navire au sol.
  autopiloteDeSecours = false,

  -- Bloc transmis TEL QUEL au module d'autopilote. Les noms de cles ci-dessous
  -- sont ceux du module standardise : adaptez-les aux votres, ce systeme ne
  -- les lit jamais, il ne fait que les transmettre.
  autopilote = {
    -- Asservissement en cascade : boucle externe (position) et boucle interne
    -- (attitude / poussee).
    cascade = {
      boucleExterne = { periode = 0.25 },
      boucleInterne = { periode = 0.05 },
    },
    -- Controle principal : PID.
    pid = {
      lacet    = { kp = 1.8, ki = 0.05, kd = 0.35 },
      tangage  = { kp = 2.2, ki = 0.08, kd = 0.40 },
      roulis   = { kp = 1.5, ki = 0.00, kd = 0.25 },
      poussee  = { kp = 0.9, ki = 0.12, kd = 0.10 },
      antiEmballement = true,
    },
    -- Secours automatique : dead-band. Le basculement est decide par
    -- l'autopilote lui-meme ; le systeme d'interception se contente de le
    -- journaliser (etape "changement de mode de l'autopilote").
    deadBand = {
      seuilPosition = 8,
      seuilAngle    = 4,
      pousseeFixe   = 0.65,
    },
    -- Enveloppe de vol du vehicule.
    vitesseMaxi      = 120,
    accelerationMaxi = 18,
    altitudePlancher = 80,
    altitudePlafond  = 300,
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

  ------------------------------------------------------------------ ARME ------

  arme = {
    -- "peripherique" : affut pilotable expose par CC: Tweaked (nominal)
    -- "redstone"     : mise a feu par signal redstone
    -- "mixte"        : pointage par peripherique, mise a feu par redstone
    mode = "peripherique",

    coteArme     = nil,      -- nil = detection automatique de l'affut
    coteRedstone = "back",   -- utilise en mode "redstone" ou "mixte"

    -- BALISTIQUE. HYPOTHESE a mesurer sur votre serveur : la vitesse initiale
    -- depend de la charge propulsive et du calibre montes.
    vitesseObus   = 80,      -- blocs/seconde
    graviteObus   = 9.8,     -- blocs/seconde carree
    iterationsTir = 4,       -- convergence du point d'impact

    -- CONDITIONS DE TIR. Toutes doivent etre reunies, y compris la tenue de
    -- l'arc arriere : l'ordre de feu ne dispense jamais de la position.
    distanceTirMini   = 80,
    distanceTirMaxi   = 420,
    toleranceViseeDeg = 3,

    -- CADENCE. Une rafale continue chauffe l'arme sans gain de precision.
    dureeRafale = 1.5,
    pauseRafale = 2.0,

    -- Debattement de l'affut.
    tangageMini = -60,
    tangageMaxi = 60,
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
  -- Le fichier journal enregistre TOUJOURS tout.
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
