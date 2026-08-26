--[[----------------------------------------------------------------------------
  CONFIGURATION VEHICULE - AUTOPILOTE FRENCHNET (AERONAUTICS WARFARE)
  --------------------------------------------------------------------------
  UN FICHIER PAR VEHICULE. Aucune valeur de vol n'est ecrite en dur dans
  autopilote.lua : tout ce qui suit est lu ici au demarrage. Si une valeur
  obligatoire manque, l'autopilote REFUSE de demarrer et dit laquelle.

  Deux facons de le modifier :
    - a la main   : edit autopilote/config_vehicule.lua
    - a l'ecran   : autopilote/interface.lua (interface de reglage FrenchNet)

  La position de ravitaillement n'est PAS ici : c'est une constante de reseau,
  verrouillee, definie dans autopilote/ravitaillement.lua. L'interface
  l'affiche mais refuse de la modifier.

  REPERE DES DECALAGES (quand decalageDansRepereVehicule = true, cas normal) :
      x = vers TRIBORD (la droite du vehicule, nez en avant)
      y = vers le HAUT
      z = vers l'AVANT (le nez)
  Le decalage est tourne selon le cap courant avant d'etre applique : il reste
  donc juste quelle que soit l'orientation du vehicule. Mettre
  decalageDansRepereVehicule = false pour des decalages exprimes en X/Y/Z
  monde (vehicule qui ne tourne jamais).

  Les valeurs ci-dessous sont un POINT DE DEPART pour un dirigeable d'une
  vingtaine de blocs. Elles se peaufinent en vol avec le menu de reglage
  (autopilote/interface.lua, touche R) qui les reecrit ici.
--------------------------------------------------------------------------------]]

return {

  ------------------------------------------------------------------- IDENTITE --

  nom         = "Dirigeable de livraison Alpha",
  identifiant = "AER-CARGO-01",

  ------------------------------------------------------------------ GEOMETRIE --

  -- Position de l'ordinateur (point de reference GPS) par rapport au CENTRE
  -- du vehicule. Le pilotage raisonne toujours sur le centre reel.
  decalageGps = { x = 0, y = 2, z = 4 },

  -- Position du point de depot / des patins d'atterrissage par rapport au
  -- CENTRE. C'est ce point-la qui tombera sur la cible quand le point de
  -- passage est de type "depot" ou "atterrissage".
  decalageDepot = { x = 0, y = -3, z = 0 },

  -- true : les decalages ci-dessus sont dans le repere du vehicule (recommande).
  decalageDansRepereVehicule = true,

  -- Gabarit, en blocs. Sert aux marges de securite et a l'affichage.
  gabarit = { longueur = 21, largeur = 9, hauteur = 7 },

  ------------------------------------------------------------------ TOLERANCES --

  tolerances = {
    horizontale  = 1.5,   -- blocs : rayon d'acceptation autour du point
    altitude     = 1.0,   -- blocs : zone morte en altitude
    cap          = 5.0,   -- degres : zone morte en cap
    dureeArrivee = 2.0,   -- secondes CONTINUES dans les marges avant "arrive"

    -- Hysteresis du repli zone morte : la correction s'engage au-dela de
    -- (tolerance + hysteresis) et ne s'arrete qu'en dessous de
    -- (tolerance - hysteresis). C'est ce qui empeche le yo-yo sur la limite.
    hysteresis = { altitude = 0.4, cap = 2.0, horizontale = 0.5 },
  },

  -------------------------------------------------------------------- VITESSES --

  vitesses = {
    croisiere            = 8.0,   -- blocs/s en transit
    approche             = 2.0,   -- blocs/s a l'approche du point
    verticaleMax         = 4.0,   -- blocs/s en montee comme en descente
    lateraleMax          = 0,     -- blocs/s de translation laterale (0 = non equipe)
    tauxVirageMax        = 40,    -- degres/s
    marcheArriere        = 0,     -- blocs/s de recul autorise (0 = interdit)

    altitudeCroisiere    = 160,   -- altitude de securite du transit
    margeAltitude        = 2.0,   -- tolerance pour declarer la croisiere atteinte
    distanceApproche     = 30,    -- blocs : debut du ralentissement et de la descente
    distanceMinCroisiere = 60,    -- en deca, vol direct sans monter en croisiere
    avanceEnMontee       = 0,     -- blocs/s pendant la montee initiale (0 = montee pure)
    rayonValidationEtape = 5,     -- blocs : validation d'un point intermediaire
    acquisitionCap       = 2.5,   -- blocs/s : reptation quand le cap est encore inconnu
  },

  ----------------------------------------------------------------- GAINS PID ---
  -- Pour chaque axe :
  --   position  = boucle EXTERNE : erreur de position -> vitesse cible
  --               (kp seul : c'est une pente, pas un regulateur complet)
  --   croisiere = boucle INTERNE en transit : erreur de vitesse -> commande
  --   maintien  = boucle INTERNE en maintien de position (gains plus serres)
  -- integraleMax / penteMax / filtreDerivee sont optionnels (valeurs sures
  -- par defaut) : integrale bornee, pente maximale de la commande par seconde,
  -- constante de lissage du terme derive.

  gains = {

    altitude = {
      position  = { kp = 0.70 },
      croisiere = { kp = 0.25, ki = 0.060, kd = 0.050,
                    integraleMax = 0.6, penteMax = 3.0, filtreDerivee = 0.25 },
      maintien  = { kp = 0.40, ki = 0.150, kd = 0.080,
                    integraleMax = 0.7, penteMax = 2.0, filtreDerivee = 0.25 },
    },

    cap = {
      position  = { kp = 1.20 },
      croisiere = { kp = 0.030, ki = 0.0080, kd = 0.0060,
                    integraleMax = 0.5, penteMax = 3.0, filtreDerivee = 0.25 },
      maintien  = { kp = 0.045, ki = 0.0150, kd = 0.0090,
                    integraleMax = 0.5, penteMax = 2.0, filtreDerivee = 0.25 },
    },

    avance = {
      position  = { kp = 0.35 },
      croisiere = { kp = 0.180, ki = 0.050, kd = 0.030,
                    integraleMax = 0.6, penteMax = 2.5, filtreDerivee = 0.25 },
      maintien  = { kp = 0.300, ki = 0.120, kd = 0.050,
                    integraleMax = 0.7, penteMax = 2.0, filtreDerivee = 0.25 },
    },

    derive = {
      position  = { kp = 0.50 },
      croisiere = { kp = 0.250, ki = 0.050, kd = 0.040,
                    integraleMax = 0.6, penteMax = 2.5, filtreDerivee = 0.25 },
      maintien  = { kp = 0.400, ki = 0.120, kd = 0.060,
                    integraleMax = 0.7, penteMax = 2.0, filtreDerivee = 0.25 },
    },
  },

  -------------------------------------------------------------------- PILOTAGE --

  pilotage = {
    -- "auto"       : PID, avec repli automatique en zone morte si un axe devient
    --                instable, et retour au PID une fois le calme revenu ;
    -- "pid"        : PID force, jamais de repli ;
    -- "zone_morte" : logique si/sinon forcee sur tous les axes.
    mode = "auto",

    detection = {
      fenetre            = 5.0,  -- secondes observees
      changementsSigne   = 5,    -- changements de signe de l'erreur -> instable
      depassements       = 3,    -- depassements de consigne -> instable
      rapportDepassement = 0.6,  -- amplitude apres/avant passage a zero
      retourAutoPid      = true,
      dureeAvantRetour   = 25,   -- secondes de calme avant de reprendre le PID
    },

    -- Commande fixe appliquee en repli zone morte, par axe (0 a 1).
    commandesZoneMorte = { altitude = 0.5, cap = 0.25, avance = 0.4, derive = 0.35 },

    -- En zone morte, on ne pousse pas tant que le nez n'est pas dans la
    -- bonne direction (degres).
    capMaxAvanceZoneMorte = 60,

    -- En deca de cette distance, l'azimut vers la cible n'a plus de sens
    -- (il tourne sur lui-meme) : le cap vise est fige.
    distanceMinCapCible = 3,

    -- Correction de derive par le cap : utile aux vehicules sans propulsion
    -- laterale, qui ne peuvent revenir sur la route qu'en tournant.
    correctionDeriveParCap = true,
    corrections = { deriveParCapMax = 35, gainDeriveCap = 2.5 },
  },

  -------------------------------------------------------------------- MAINTIEN --

  maintien = {
    -- Cap tenu une fois arrive : "auto" (garde le cap d'arrivee si le
    -- vehicule sait translater, sinon pointe la cible), "conserver",
    -- "vers_cible", ou une valeur en degres.
    cap = "auto",
    facteurVitesse = 0.35,  -- les vitesses maximales sont reduites d'autant

    -- true : une fois dans les marges, la poussee horizontale est coupee et le
    -- vehicule se laisse arreter par sa trainee. Evite qu'un integrateur
    -- residuel ne repousse le vehicule hors de sa propre cible.
    arretDansMarges = true,
  },

  ------------------------------------------------------------- GPS ET FILTRAGE --

  gps = {
    intervalle          = 0.4,   -- secondes entre deux lectures (>= 0.05)
    delaiLocate         = 2,     -- timeout de gps.locate
    lecturesAcquisition = 2,     -- lectures valides exigees avant tout mouvement
    perteToleree        = 2.5,   -- secondes de navigation a l'estime tolerees
    dtMax               = 2.0,   -- au-dela : discontinuite, regulateurs remis a zero
    vitesseMaxPlausible = 80,    -- blocs/s : au-dela, lecture jugee aberrante
    sourceHorloge       = "ticks", -- "ticks" (os.clock) ou "reel" (os.epoch)
    seuilRalentissement = 1.6,   -- rapport temps reel / temps tick avant alerte

    -- Filtrage des balises : "passe_bas" (constanteTemps) ou "moyenne" (fenetre).
    filtre        = { type = "passe_bas", constanteTemps = 0.45, fenetre = 4 },
    filtreVitesse = { type = "passe_bas", constanteTemps = 0.60, fenetre = 4 },
  },

  ------------------------------------------------------------------------- CAP --

  cap = {
    -- "route"        : cap deduit de la route reellement suivie (aucun materiel) ;
    -- "peripherique" : cap lu sur un peripherique (lecteur de vaisseau, gyro).
    source          = "route",
    peripherique    = nil,
    methode         = "getYaw",
    convention      = "minecraft",  -- "minecraft" (yaw) ou "boussole" (cap direct)
    facteur         = 1,
    decalage        = 0,
    vitesseMinRoute = 0.8,   -- blocs/s en deca desquels la route n'est pas fiable
    dureeCapValide  = 2.0,   -- secondes pendant lesquelles un cap non mesure reste valable
    capParDefaut    = 0,     -- cap suppose au demarrage
    filtre          = { constanteTemps = 0.35 },
  },

  ------------------------------------------------------------- SORTIES MOTEUR --
  -- Cablage du vehicule, axe par axe. Modes disponibles :
  --   "aucun"       : axe non equipe ;
  --   "analogique"  : un cote redstone, neutre au milieu (neutre +/- amplitude) ;
  --   "bipolaire"   : deux cotes opposes (avant/arriere, haut/bas, gauche/droite) ;
  --   "peripherique": appel d'une methode d'un peripherique de commande.
  -- Un programme appelant peut aussi injecter son propre pilote de sorties.

  sorties = {
    type = "redstone",
    axes = {
      avance   = { mode = "analogique", cote = "front", neutre = 7, amplitude = 7 },
      vertical = { mode = "bipolaire", cotePositif = "top", coteNegatif = "bottom",
                   amplitude = 15, seuil = 0.08 },
      lacet    = { mode = "bipolaire", cotePositif = "right", coteNegatif = "left",
                   amplitude = 15, seuil = 0.08 },
      lateral  = { mode = "aucun" },
    },
  },

  -------------------------------------------------------------------- MISSION --

  mission = {
    reprendreApresRedemarrage  = true,   -- reprend la mission apres un plantage
    reprendreApresPerteGps     = true,   -- reprend la mission apres retour du GPS
    respecterAltitudeCroisiere = true,   -- plancher de securite pendant le transit
    monteeAvantTransit         = true,   -- monter d'abord, transiter ensuite
    fichierEtat = "/autopilote/etat_mission.txt",
  },

  -------------------------------------------------------------------- JOURNAL --

  journal = {
    fichier       = true,
    chemin        = "/autopilote/autopilote.log",
    tailleMax     = 65536,
    niveauEcran   = "INFO",  -- DEBUG | INFO | AVERT | ERREUR
    periodeCycles = 12,      -- 1 cycle sur N trace en DEBUG
    historique    = 120,     -- echantillons gardes par axe pour le reglage en vol
  },
}
