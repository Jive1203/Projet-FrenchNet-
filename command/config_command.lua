--[[----------------------------------------------------------------------------
  CONFIGURATION DE FRENCHNET COMMAND - AERONAUTICS WARFARE
  --------------------------------------------------------------------------
  Systeme de defense aerienne autonome installe au sol.

  Ce fichier contient les reglages STABLES : reseau, codes, seuils, poids de
  designation. Il n'est PAS l'endroit ou l'on definit les zones : les zones se
  saisissent depuis l'interface (menu protege) et sont enregistrees dans
  command/zones.dat, pour qu'un controleur puisse les modifier en jeu sans
  toucher au code et sans redemarrer le poste.

  Le mode guerre/paix ne se regle pas ici non plus : c'est un bouton en un
  clic sur l'ecran principal, et son etat persiste dans command/etat.dat.

  RAPPEL : Command ne pilote aucune arme. Il decide et transmet a
  FrenchNet Fire Control.
--------------------------------------------------------------------------------]]

return {

  ---------------------------------------------------------------- IDENTITE ----

  -- Identifiant du poste de commandement. Apparait dans le journal et dans
  -- les messages reseau. Unique si plusieurs postes coexistent.
  identifiant = "CMD-01",

  -- Libelle libre affiche en tete d'ecran.
  designation = "Poste de commandement principal",

  ---------------------------------------------------- RESEAU DE RADARS -------

  --[[
    Le poste central ne balaie pas : il ECOUTE des stations radar deportees.
    Chaque station est un ordinateur + un modem Ender + un radar, qui diffuse
    ses contacts sur le protocole ci-dessous. Voir radar/config_radar.lua.

    Un radar peut aussi etre accole directement au poste : il devient alors la
    station "LOCAL". Mettre radarLocal a false pour ne pas le chercher.
  ]]
  protocoleRadar = "frenchnet_radar",

  -- Duree sans trame au-dela de laquelle une station est declaree muette
  -- (secondes). Sa couverture est alors perdue, et le journal le dit.
  validiteStation = 15,

  -- Distance en blocs sous laquelle deux echos venant de DEUX stations
  -- differentes, sans identifiant stable, sont fusionnes en une seule piste.
  -- Trop grand : deux appareils en formation n'en font plus qu'un. Trop petit :
  -- le meme appareil compte double et recoit deux ordres de tir.
  toleranceFusion = 8,

  ------------------------------------------------------------ RADAR LOCAL ----

  -- Chercher un radar accole au poste de commandement ?
  -- false = le poste s'appuie uniquement sur les stations deportees.
  radarLocal = true,

  -- Nom du peripherique radar local. nil = detection automatique.
  peripheriqueRadar = nil,

  -- Position du bloc radar. INDISPENSABLE si le radar rend des positions
  -- relatives : elle sert a les convertir en coordonnees absolues, et a
  -- calculer l'enveloppe fiable pour la confirmation de destruction.
  -- Relever avec F3, ligne "Block".
  positionRadar = { x = 0, y = 80, z = 0 },

  -- true  : le radar rend des coordonnees RELATIVES a sa propre position.
  -- false : le radar rend des coordonnees ABSOLUES du monde.
  -- nil   : detection automatique au premier balayage (une position dont la
  --         magnitude est tres inferieure a celle du radar est jugee relative).
  positionsRelatives = nil,

  -- Portee utile du radar en blocs. Sert de reference a l'enveloppe fiable
  -- de confirmation de destruction. 0 = inconnue (desactive le garde-fou,
  -- deconseille : voir ratioEnveloppeFiable).
  porteeRadar = 512,

  -- Periode de balayage radar, en secondes. 1 s est le bon compromis :
  -- assez rapide pour la fenetre de crash de 3 s, assez lent pour ne pas
  -- saturer un serveur.
  intervalleBalayage = 1,

  -- Nombre d'echantillons de piste conserves par cible (historique de
  -- trajectoire). 20 echantillons a 1 s couvrent largement la fenetre de 3 s.
  historiquePiste = 20,

  -- Duree sans echo radar avant qu'une piste soit consideree comme perdue et
  -- oubliee (secondes). Doit rester superieur a disparitionSecondes.
  oubliPisteSecondes = 30,

  ------------------------------------------------------------ TRANSPONDEURS ---

  -- CODE ALLIE : code fixe. Libre passage dans toutes les zones et tous les
  -- modes, sauf en zone Romeo en temps de guerre ou il declenche un scramble
  -- de verification visuelle SANS engagement.
  -- A changer avant toute mise en service reelle.
  codeAllie = "FN-ALLIE-0000",

  -- CODE GENERAL ROTATIF : acces conditionnel selon la zone. Se change
  -- regulierement pour la securite, depuis le menu protege de l'interface.
  codeGeneral = "FN-GEN-1234",

  -- Code general precedent, accepte pendant la periode de grace ci-dessous.
  -- Renseigne automatiquement lors d'une rotation depuis l'interface.
  codeGeneralPrecedent = nil,

  -- Duree pendant laquelle le code general precedent reste accepte apres une
  -- rotation (secondes). Sans cette grace, une rotation abattrait toute la
  -- flotte qui n'a pas encore recu le nouveau code.
  graceRotation = 300,

  -- Duree de validite d'une trame transpondeur (secondes). Au-dela, le code
  -- est considere perime et la cible retombe en INCONNU. Doit valoir au moins
  -- 3 fois la periode d'emission du transpondeur cote vehicule.
  validiteTranspondeur = 15,

  --------------------------------------- DEUXIEME VOIE D'IDENTIFICATION ------

  --[[
    Le systeme identifie par DEUX voies independantes :
      1. le TRANSPONDEUR : quel code porte l'appareil ;
      2. le RADAR : ce qu'est l'appareil, et a qui il appartient - nom de
         contraption, proprietaire et equipe rendus par Create Radars.

    Leur interet vient de leur independance : un transpondeur se capture avec
    l'engin qui le porte, le proprietaire d'une contraption non. Un code allie
    porte par un engin identifie hostile signale un transpondeur capture -
    exactement ce qu'une voie unique laisserait passer.

    LA DOCTRINE NE BOUGE PAS : sans code valide, la cible reste INCONNUE. La
    voie radar ne delivre aucun laissez-passer ; elle peut seulement en retirer
    un. Elle signale aussi le cas inverse - un appareil que le radar reconnait
    comme allie mais dont le transpondeur est muet - pour qu'un controleur
    puisse le declarer allie a la main avant qu'il ne soit engage.
  ]]
  identificationRadarActive = true,

  -- Que faire quand les deux voies se contredisent ?
  --   true (defaut) : le code est ecarte, la cible redevient INCONNUE, et le
  --                   controleur est alerte. C'est le reglage sur.
  --   false         : le code est conserve, la discordance est seulement
  --                   journalisee et signalee.
  discordanceDeclasse = true,

  -- Listes d'identification par nom, sans aucune dependance exterieure.
  -- Comparaison par egalite exacte, puis par sous-chaine insensible a la
  -- casse : l'entree "RAID" couvre "RAID-01", "RAID-02", etc.
  -- Sont examines : le nom du contact, son proprietaire et son equipe.
  -- La liste HOSTILE l'emporte sur la liste ALLIEE en cas de double
  -- appartenance : le doute ne profite pas a la cible.
  nomsHostiles = nil,   -- exemple : { "RAID", "Pirate", "Kriegsmarine" }
  nomsAllies   = nil,   -- exemple : { "FR-", "Escadrille" }

  -- Distance maximale, en blocs, entre la position annoncee par un
  -- transpondeur et un echo radar pour les associer l'un a l'autre.
  -- Trop grand : un ennemi profite du code d'un allie proche. Trop petit :
  -- un allie rapide perd son code entre deux trames.
  toleranceAppariement = 24,

  ---------------------------------------------------- MODELE DE TERRAIN ------

  --[[
    Le systeme APPREND le relief au lieu de le calculer.

    Reconstituer la generation de Minecraft a partir de la seed du monde est
    hors de portee d'un ordinateur CC: Tweaked : il faudrait la pile complete
    des density functions, les splines de terrain et l'arithmetique 64 bits
    exacte du generateur, pour un cout de plusieurs minutes par colonne - et le
    resultat ignorerait tout ce que les joueurs ont construit ou creuse.

    A la place, tout ce dont on connait la position et qui touche le sol est
    une sonde d'altitude : chaque station radar, chaque lanceur, chaque joueur
    qui marche. Le modele est enregistre dans command/terrain.dat et survit aux
    redemarrages ; il devient plus fin avec le temps.

    Si votre serveur peut exporter une heightmap, elle s'importe directement
    dans terrain.dat : c'est la seule facon d'injecter de vraies donnees de
    generation dans le systeme.
  ]]

  -- Cote d'une case du modele, en blocs. 16 = un chunk. Plus fin = plus precis
  -- mais plus gourmand en memoire et plus long a couvrir.
  terrainResolution = 16,

  -- Nombre de cases explorees autour d'un point sans releve, avant d'abandonner
  -- et de retomber sur l'altitude de reference.
  terrainRayonRecherche = 3,

  -- Plafond memoire, en nombre de cases. 4000 cases de 16 blocs couvrent
  -- environ 1 000 000 de blocs carres. Au-dela, les cases les moins etayees
  -- sont evincees.
  terrainCellulesMax = 4000,

  -- Utiliser les VEHICULES comme sondes d'altitude ?
  --   false (defaut) : non. Un aeronef en croisiere a altitude constante
  --                    passerait pour un vehicule au sol et empoisonnerait
  --                    durablement le modele.
  --   true           : oui, sur un theatre sans aviation de croisiere basse.
  sondesVehicules = false,

  -- Nombre de releves consecutifs a altitude stable exiges pour qu'un contact
  -- soit accepte comme sonde.
  sondeEchantillons = 3,

  -- Variation verticale toleree entre ces releves, en blocs.
  sondeToleranceVerticale = 0.5,

  -- Vitesse horizontale maximale d'un vehicule accepte comme sonde (blocs/s).
  sondeVitesseSolMax = 12,

  -- Ecart maximal, en blocs, entre un releve et une case deja bien etayee.
  -- Au-dela, le releve est refuse : ce n'est pas du terrain, c'est un contact
  -- en vol au-dessus.
  ecartMaxSonde = 30,

  -- Periode d'enregistrement du modele sur disque (secondes). Le fichier n'est
  -- reecrit que s'il a change.
  terrainEnregistrement = 120,

  ------------------------------------------------------------ CATEGORISATION --

  -- Altitude de reference du sol (Y), utilisee UNIQUEMENT la ou le modele de
  -- terrain ne sait pas encore repondre. Peut etre surchargee par zone
  -- (champ solY d'une zone).
  altitudeSolReference = 64,

  -- Hauteur au-dessus du sol de reference a partir de laquelle une cible est
  -- classee AERIENNE (blocs).
  hauteurAerienne = 25,

  -- Vitesse verticale soutenue (blocs/s) qui classe une cible comme aerienne
  -- meme sous le seuil d'altitude : decollage, ressource, vol en vallee.
  vitesseVerticaleAerienne = 6,

  -- Traiter les entites neutres du monde (animaux, monstres) comme des cibles ?
  --   false (defaut) : elles sont ignorees. Sans ce filtre, le systeme engage
  --                    les vaches et vide les soutes.
  --   true           : toute entite detectee devient une cible potentielle.
  traiterEntitesNeutres = false,

  ------------------------------------------------------------ FIRE CONTROL ----

  -- Protocole rednet vers FrenchNet Fire Control.
  protocoleFireControl = "frenchnet_fire_control",

  -- Protocole rednet d'ecoute des transpondeurs vehicules.
  protocoleTranspondeur = "frenchnet_transpondeur",

  -- Protocole rednet d'ecoute des BALISES DE LANCEUR. Chaque plateforme de
  -- defense y annonce sa position, ses munitions restantes et ses tirs.
  -- C'est cette source qui alimente la designation du tireur.
  -- Voir lanceur/config_lanceur.lua.
  protocoleLanceur = "frenchnet_lanceur",

  -- Protocole rednet du roster de factions (pont Open Parties and Claims).
  -- Open Parties and Claims n'est pas lisible depuis un ordinateur CC: Tweaked :
  -- l'appartenance de faction doit etre poussee sur ce protocole par un pont
  -- cote serveur, sous la forme { roster = { ["Pseudo"] = { faction = "..." } } }.
  -- En son absence, l'identification repose entierement sur les transpondeurs,
  -- ce qui est de toute facon la regle : pas de code valide = INCONNU.
  protocoleRoster = "frenchnet_roster",

  -- Identifiant de l'ordinateur Fire Control. nil = diffusion (broadcast) sur
  -- le protocole. Renseigner l'identifiant rend l'envoi cible et plus discret.
  idFireControl = nil,

  -- Cote du modem Ender : "top", "bottom", "left", "right", "front", "back".
  -- nil = detection automatique.
  coteModem = nil,

  -- Correspondance categorie interne -> libelle envoye a Fire Control.
  categoriesFireControl = {
    AERIENNE     = "Aerial",
    VEHICULE_SOL = "GroundVehicle",
    INFANTERIE   = "Infantry",
  },

  -- Modele du message d'ordre : plateforme, verbe, categorie.
  -- Format specifie : « AirShip1 Fire type Aerial »
  modeleOrdre = "%s %s type %s",

  --[[
    SECURITE - LIRE AVANT DE MODIFIER
    Un scramble de verification n'est PAS un ordre de tir. En zone Romeo en
    temps de guerre, un vehicule porteur du CODE ALLIE declenche un scramble
    « sans engagement » : si Command lui envoie le verbe « Fire »,
    Fire Control tire sur un allie.
      false (defaut) : verbes distincts, « Scramble » pour la verification et
                       « Fire » pour la destruction. C'est le reglage sur.
      true           : un seul verbe « Fire » pour les deux paliers, conforme
                       a la lettre du format d'origine. A n'activer que si
                       Fire Control ignore le verbe « Scramble ».
  ]]
  formatUniqueFire = false,
  verbeScramble    = "Scramble",

  -- Envoyer, en plus de la chaine d'ordre, une trame structuree contenant la
  -- piste complete (utile pour deboguer Fire Control). Desactive par defaut
  -- pour ne pas perturber un recepteur qui n'attend qu'une chaine.
  envoyerDetails = false,

  ------------------------------------------------------ DESIGNATION DU TIREUR -

  --[[
    Poids relatifs des trois criteres de designation. Les trois termes sont
    normalises sur le lot de plateformes candidates avant ponderation :

      score =   poidsMunitions * (1 - munitions / munitionsMax)
              + poidsDistance  * (distance / distanceMax)
              + poidsTirs      * (tirs / tirsMax)

    poidsMunitions : privilegie la plateforme la mieux approvisionnee. Le plus
                     lourd par defaut : envoyer l'ordre a une rampe presque
                     vide, c'est perdre la cible au deuxieme tir. Une
                     plateforme a stock NUL n'est jamais designee.
    poidsDistance  : privilegie la plateforme la plus proche.
    poidsTirs      : repartit l'usure entre les pieces, a stock et distance
                     comparables. Volontairement plus leger que les deux
                     autres.
  ]]
  poidsMunitions = 1.5,
  poidsDistance  = 1.0,
  poidsTirs      = 0.5,

  -- Si aucune plateforme n'est a portee de la menace :
  --   false (defaut) : aucune designation, alerte controleur.
  --   true           : designer quand meme la moins mauvaise.
  designerHorsPortee = false,

  -- Duree sans inventaire de Fire Control apres laquelle la liste des
  -- plateformes est jugee perimee (secondes) -> alerte controleur.
  validiteInventaire = 60,

  -------------------------------------------- CONFIRMATION DE DESTRUCTION -----

  -- Declencheur A : disparition complete du radar.
  -- Duree d'absence d'echo avant d'examiner la disparition (secondes).
  disparitionSecondes = 3,

  --[[
    GARDE-FOU DU DECLENCHEUR A.
    Une cible qui sort de portee, dont le chunk se decharge ou dont le pilote
    se deconnecte disparait EXACTEMENT comme une cible detruite. Sans garde-fou,
    le systeme declare « detruit » tout ce qui reussit a fuir, et cesse le feu
    precisement sur ce qu'il fallait continuer a traiter.
    La disparition ne vaut confirmation que si le dernier point connu etait a
    moins de (porteeRadar * ratioEnveloppeFiable) du radar. Au-dela, la piste
    est declaree PERDUE - pas detruite - et un controleur est alerte.
    Mettre a 1.0 supprime le garde-fou. Fortement deconseille.
  ]]
  ratioEnveloppeFiable = 0.80,

  -- Declencheur B : signature de crash.
  -- Fenetre d'analyse commune aux deux mesures (secondes).
  fenetreCrashSecondes = 3,
  -- Perte minimale de vitesse horizontale sur la fenetre (0.50 = 50 %).
  perteVitesseRatio    = 0.50,
  -- Perte minimale d'altitude sur la MEME fenetre (blocs).
  perteAltitudeBlocs   = 40,
  -- Vitesse horizontale minimale avant le tir pour que le declencheur B ait
  -- un sens (blocs/s) : sans cela, un stationnaire "perd 50 % de rien".
  vitesseMiniCrash     = 2,

  -- Delai laisse aux deux declencheurs avant de conclure a un echec et de
  -- reemettre un ordre de tir (secondes).
  delaiEvaluationSecondes = 8,

  -- Nombre TOTAL d'ordres de tir emis sur une meme cible, premier ordre
  -- compris, avant d'alerter un controleur humain.
  tentativesMax = 3,

  -------------------------------------------------------------- ALERTE MAX ----

  -- L'alerte maximale manuelle applique partout le regime ROMEO / GUERRE.
  -- Couvre-t-elle aussi les zones NON classifiees (hors juridiction) ?
  --   false (defaut) : non. Une zone non classifiee reste hors juridiction,
  --                    conformement a la doctrine.
  --   true           : oui, le systeme engage partout. A n'activer qu'en
  --                    connaissance de cause.
  alerteMaxCouvreHorsZone = false,

  -- Extinction automatique de l'alerte maximale apres ce delai (secondes).
  -- 0 = jamais (extinction manuelle uniquement).
  alerteMaxDureeSecondes = 0,

  -------------------------------------------------------------- INTERFACE -----

  -- Code d'acces au menu protege (zones, codes, reglages sensibles).
  -- A CHANGER. Sa seule fonction est d'eviter la fausse manoeuvre.
  codeAccesMenu = "1234",

  -- Position du poste de commandement, utilisee comme origine de la carte
  -- tactique. nil = reprend positionRadar.
  positionPoste = nil,

  -- Echelle initiale de la carte, en blocs par caractere.
  -- Valeurs possibles : 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024.
  echelleCarte = 32,

  -- Mode de suivi initial de la carte mouvante :
  --   "MENACE" : recentrage permanent sur le contact le plus dangereux
  --   "POSTE"  : recentrage permanent sur le poste de commandement
  --   "LIBRE"  : le controleur deplace la carte lui-meme
  suiviCarte = "MENACE",

  -- Nom du moniteur externe a utiliser pour l'affichage. nil = terminal.
  -- Un grand moniteur avance change tout pour la carte : 3x2 blocs a l'echelle
  -- 0.5 donne une situation tactique reellement lisible.
  moniteur = nil,

  -- Echelle de texte du moniteur externe (0.5 a 5).
  echelleMoniteur = 0.5,

  -- Nombre de contacts affiches simultanement sur l'ecran principal.
  contactsAffiches = 6,

  -- Cote sur lequel emettre un signal de redstone lorsqu'une alerte controleur
  -- est levee (sirene, gyrophare, lampe). nil = aucune sortie redstone.
  sortieRedstoneAlerte = nil,

  ---------------------------------------------------------------- JOURNAL -----

  journalFichier     = true,
  journalTailleMax   = 131072,
  -- Verbosite ECRAN : "DEBUG" | "INFO" | "AVERT" | "ERREUR".
  -- Le fichier journal enregistre toujours tout.
  journalNiveauEcran = "INFO",

  -- Resume periodique d'etat dans le journal (secondes).
  battementSecondes  = 60,

  --------------------------------------------------------------- ROBUSTESSE ---

  erreursAvantReinit  = 5,
  redemarrageDelaiMin = 3,
  redemarrageDelaiMax = 60,

  -- true  : Ctrl+T arrete le poste (phase de reglage).
  -- false : Ctrl+T est ignore et journalise -> autonomie totale.
  arretParTerminate = true,
}
