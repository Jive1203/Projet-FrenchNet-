--[[----------------------------------------------------------------------------
  CONFIGURATION DE L'ADS D'UN NAVIRE - AERONAUTICS WARFARE
  --------------------------------------------------------------------------
  A EDITER SUR CHAQUE NAVIRE. Un seul champ est reellement obligatoire :

      identifiant  -> unique pour chaque navire de la flotte

  Tout le reste a une valeur par defaut raisonnable. Les trois reglages qui
  meritent vraiment votre attention au premier armement sont :

      largueurs        -> sans eux, aucun leurre ne part
      piloteMode       -> sans lui, le navire ne manoeuvre pas
      rayonMenace      -> trop grand, l'ADS se declenche pour rien

  CIBLE DU SYSTEME : les MISSILES GUIDES. Les reglages par defaut sont
  calibres pour eux (horizon long, rayon de menace large, tolerance d'angle
  ouverte pour encaisser les corrections d'un autoguidage). Un obus de tir
  direct sera detecte et signale, mais il arrive trop vite pour etre esquive :
  ne reglez pas le systeme sur lui.

  MISE EN SERVICE PRUDENTE : commencez avec piloteMode = "simulation" et
  journalNiveauEcran = "DEBUG". L'ADS detecte, calcule et journalise tout,
  mais ne touche pas aux commandes. Vous lisez ads.log, vous verifiez que les
  detections sont justes, puis vous passez en "auto".
--------------------------------------------------------------------------------]]

return {

  ---------------------------------------------------------------- IDENTITE ----

  -- Identifiant unique du navire. Doit differer sur CHAQUE navire.
  identifiant = "NAV-01-CORSAIRE",

  -- Libelle libre, purement informatif (flottille, role, classe...).
  designation = "Croiseur leger - escadre nord",

  ------------------------------------------------------------------ RESEAU ----

  -- Cote du modem Ender : "top", "bottom", "left", "right", "front", "back".
  -- nil = detection automatique (le modem Ender est prioritaire).
  -- Le modem n'est PAS vital : sans lui l'ADS defend quand meme le navire,
  -- il perd seulement la telemetrie et le dialogue avec la navigation.
  coteModem = nil,

  -- Protocole de telemetrie ADS (consoles de supervision).
  protocoleRednet = "frenchnet_ads",

  -- Protocole de dialogue avec le programme de navigation du navire
  -- (preemption / reprise de tache). Voir docs/guide-ads.md section 6.
  protocoleTache = "frenchnet_nav",

  -- Timeout de gps.locate, en secondes. Utilise uniquement si le radar rend
  -- des coordonnees du monde et que l'interface de pilotage n'en donne pas.
  delaiGps = 2,

  ------------------------------------------------------------------- RADAR ----

  -- Nom du peripherique radar. nil = detection automatique par le type
  -- (tout peripherique dont le type ou le nom contient "radar").
  -- Si la detection echoue, le journal liste TOUS les peripheriques presents
  -- avec leurs methodes : recopiez ici le nom exact.
  radarPeripherique = nil,

  -- Methode de scan a appeler. nil = sondage automatique parmi getEntities,
  -- scan, getTargets, getContacts, getEntitiesInRange, getBlips...
  -- La methode retenue est ecrite dans le journal au demarrage.
  radarMethodeScan = nil,

  -- Portee utile declaree du radar, en blocs. Sert au choix automatique du
  -- repere et au diagnostic, pas au filtrage.
  radarPortee = 256,

  -- Repere des coordonnees rendues par le radar :
  --   "auto"    = deduit au premier scan et journalise (recommande)
  --   "relatif" = coordonnees relatives a l'antenne
  --   "absolu"  = coordonnees du monde
  radarRepere = "auto",

  -- Periode de scan, en secondes. C'est LE reglage critique.
  -- Un obus de Create Big Cannons file a 100-200 blocs/s : a 0.25 s de
  -- periode, il parcourt 25 a 50 blocs entre deux scans. Descendre a 0.1 s
  -- ameliore la reactivite mais charge le serveur ; ne descendez pas sous
  -- 0.05 s (un tick). Voir docs/guide-ads.md section 8.
  intervalleScanSecondes = 0.25,

  -- Scans en erreur consecutifs avant reinitialisation complete du materiel.
  radarEchecsAvantReinit = 20,

  ----------------------------------------------------------------- PISTAGE ----

  -- Duree de vie d'une piste sans nouvel echo, en secondes.
  pisteMemoireSecondes = 6,

  -- Profondeur de l'historique servant au calcul de vitesse par regression.
  pisteEchantillonsMax = 12,

  -- Fenetre d'association, en blocs : un echo est rattache a une piste si sa
  -- position PREDITE est a moins de cette distance. Doit rester superieur a
  -- (vitesse du projectile x intervalleScanSecondes) sinon les pistes rapides
  -- sont perdues. Le journal vous previent au demarrage si c'est trop serre.
  pisteRayonAssociation = 24,

  -- Vitesse minimale, en blocs/s, pour qu'un contact anonyme soit traite comme
  -- un projectile. Sert de repli quand le radar ne nomme pas les entites.
  -- 5 b/s laisse passer les navires lents sans rater un missile de croisiere.
  vitesseProjectileMini = 5,

  -- Taux de virage, en degres/s, au-dela duquel un contact est classe
  -- MANOEUVRANT. Un projectile balistique vole droit ; un contact qui corrige
  -- en gardant le navire dans son axe est un AUTOGUIDAGE verrouille sur vous.
  -- L'ADS le marque "GUIDE" dans le journal, bascule son calcul de vitesse sur
  -- une fenetre courte (sinon il poursuit une trajectoire perimee) et lui
  -- demande une confirmation de moins avant de declencher.
  seuilManoeuvreDegresSec = 8,

  -- Reconnaissance par le nom du contact (recherche litterale, insensible a
  -- la casse). Completez avec les noms reels lus dans votre journal DEBUG.
  motifsProjectile = {
    "missile", "rocket", "roquette", "torpedo", "torpille", "guided", "seeker",
    "projectile", "shell", "obus", "cannon", "cbc", "ap_shell", "he_shell",
    "flak", "bomb",
  },

  -- Contacts JAMAIS consideres comme une menace. Ajoutez-y le nom de vos
  -- propres leurres : sans cela l'ADS se declencherait sur ses propres flares.
  motifsIgnores = {
    "player", "item", "flare", "leurre", "chaff", "particle", "boat", "minecart",
  },

  ------------------------------------------------------------------ MENACE ----

  -- Distance d'approche minimale, en blocs, en dessous de laquelle un
  -- projectile est considere comme dangereux. Prenez le demi-diametre du
  -- navire, plus le rayon de souffle du missile, plus une marge.
  -- Trop grand = declenchements pour rien.
  rayonMenace = 16,

  -- Au-dela de cet horizon (secondes avant le passage au plus pres), la
  -- menace n'est pas jugee imminente et l'ADS laisse la tache se poursuivre.
  -- 20 s parce qu'un missile a une longue phase de croisiere : le detecter
  -- tot laisse le temps de larguer plusieurs salves de leurres.
  horizonMenaceSecondes = 20,

  -- Alignement minimal : cosinus de l'angle entre la trajectoire RELATIVE du
  -- projectile et la direction du navire. 0.94 = 20 deg, 0.965 = 15 deg.
  -- Note : le calcul se fait dans le repere navire, donc la vitesse est deja
  -- relative et un missile a guidage proportionnel presente un alignement
  -- proche de 1 malgre son angle d'anticipation. La tolerance de 20 deg sert
  -- a encaisser ses corrections en cours de vol, pas son avance de tir.
  alignementMini = 0.94,

  -- Vitesse de rapprochement minimale, en blocs/s.
  rapprochementMiniBlocsSec = 3,

  -- Nombre de scans consecutifs de rapprochement exiges ("de facon constante").
  echantillonsRapprochementMini = 3,

  -- Nombre de scans consecutifs qualifiants avant declenchement.
  confirmationsMini = 2,

  -- Sous ce delai avant impact, l'ADS declenche des le PREMIER scan qualifiant,
  -- sans attendre les confirmations : attendre, c'est encaisser.
  urgenceSecondes = 2.5,

  -- Hysteresis de levee : la menace n'est levee que si le projectile passera
  -- a plus de rayonMenace x ce facteur. Evite le battement entree/sortie.
  hysteresisLevee = 1.6,

  -- Sans echo pendant ce delai, le contact est considere comme perdu.
  perteContactSecondes = 1.5,

  -- Delai de securite apres la levee de menace, avant de rendre la main :
  -- couvre le cas du tir en rafale et du second missile.
  delaiSecuriteSecondes = 4,

  ----------------------------------------------------------------- LEURRES ----

  leurresActifs = true,

  -- Largueurs de leurres / flares. Trois formes acceptees, melangeables :
  --
  --   { type = "redstone", cote = "left", impulsionSecondes = 0.4 }
  --       impulsion redstone vers un Deployer, un dropper, un dispenser
  --       ou tout montage Create de largage. C'est le montage le plus simple.
  --
  --   { type = "peripherique", nom = "create:deployer_0", methode = "activate" }
  --       appel direct sur un peripherique connecte par cable reseau.
  --
  --   { type = "rednet", cible = 42 }
  --       ordre envoye a un ordinateur dedie au largage.
  --
  -- LAISSER CETTE LISTE VIDE = AUCUN LEURRE. Le journal le signale en ERREUR
  -- a chaque demarrage et a chaque engagement.
  largueurs = {
    { type = "redstone", cote = "left",  impulsionSecondes = 0.4, libelle = "rampe babord" },
    { type = "redstone", cote = "right", impulsionSecondes = 0.4, libelle = "rampe tribord" },
  },

  -- Nombre de declenchements par salve.
  leurresParSalve = 2,

  -- Nombre de salves par engagement.
  salvesParEngagement = 3,

  -- Intervalle entre deux salves, en secondes.
  intervalleSalveSecondes = 0.8,

  -- Stock embarque de leurres. 0 = illimite (ravitaillement automatique par
  -- un montage Create). Sinon l'ADS decompte et vous previent avant la panne.
  stockLeurres = 24,

  -- Delai minimal entre deux largages sur le meme engagement, en secondes.
  delaiReengagementSecondes = 6,

  ----------------------------------------------------------------- EVASION ----

  evasionActive = true,

  -- Mode de pilotage :
  --   "auto"         = peripherique si trouve, sinon redstone si cable,
  --                    sinon delegation par rednet a la navigation
  --   "peripherique" = uniquement le peripherique de pilotage
  --   "redstone"     = uniquement les sorties redstone ci-dessous
  --   "rednet"       = uniquement la delegation au programme de navigation
  --   "simulation"   = rien n'est envoye au navire, tout est journalise
  piloteMode = "auto",

  -- Nom du peripherique de pilotage. nil = detection automatique.
  pilotePeripherique = nil,

  -- Surcharge des noms de methode, si Create Aeronautics en expose d'autres.
  -- Le journal liste les methodes reellement disponibles au demarrage.
  --   piloteMethodes = {
  --     cap = "setYaw", altitude = "setTargetAltitude", gaz = "setThrottle",
  --     lireCap = "getYaw", lireAlt = "getAltitude", lireGaz = "getThrottle",
  --     lirePos = "getPosition",
  --   },
  piloteMethodes = nil,

  -- Cablage redstone du pilotage (mode "redstone" ou repli du mode "auto").
  -- Chaque cote recoit une impulsion pendant la duree de la manoeuvre.
  piloteRedstone = {
    -- babord = "back", tribord = "front", monter = "top", descendre = "bottom",
    -- pleinGaz = "back",
  },

  -- Amplitude maximale d'un ordre de virage, en degres. Borner evite de
  -- demander un demi-tour que le navire mettra dix secondes a executer.
  amplitudeVirageDegres = 90,

  -- Amplitude d'un degagement vertical, en blocs.
  amplitudeAltitudeBlocs = 40,

  -- Bornes d'altitude a ne jamais franchir en manoeuvre : l'ADS ecarte tout
  -- axe de degagement qui menerait au sol ou au-dessus du plafond.
  altitudeMin = 80,
  altitudeMax = 300,

  -- Vitesse laterale que le navire peut esperer prendre, en blocs/s. Sert a
  -- comparer les axes de degagement entre eux. Une valeur approximative
  -- suffit : c'est le CLASSEMENT des axes qui compte, pas la valeur absolue.
  vitesseEvasionEstimee = 20,

  -- BREAK TARDIF, en secondes avant impact. 0 = rupture immediate des la
  -- confirmation de la menace (defaut).
  --
  -- Rationnel : virer par le travers reduit la vitesse de rapprochement, donc
  -- allonge le temps de vol restant du missile, donc le nombre de degres qu'il
  -- peut encore corriger. Rompre trop tot peut lui OFFRIR la correction. La
  -- doctrine consiste a tenir la route puis a rompre quand il ne lui reste plus
  -- assez de temps de vol.
  --
  -- HONNETETE : cette doctrine n'a PAS ete validee par la simulation du banc
  -- d'essai. Sur quatre profils de missile testes, elle n'ameliore nettement
  -- qu'un seul cas et reste dans le bruit sur les autres. Elle est fournie
  -- parce qu'elle est physiquement fondee et mesurable sur votre serveur :
  -- essayez 3 s et comparez vos distances de passage. Laissez 0 par defaut.
  secondesAvantDegagement = 0,

  -- Preference de degagement : "auto", "horizontale" ou "verticale".
  -- Un dirigeable lourd vire mal mais plonge bien : "verticale" lui convient.
  preferenceEvasion = "auto",

  -- Periode de re-evaluation de l'axe de degagement, en secondes. Un missile
  -- guide corrige sa trajectoire, l'axe optimal se deplace en permanence.
  intervalleManoeuvreSecondes = 1,

  -- Plein gaz pendant l'evasion.
  pleinGazEnEvasion = true,

  ------------------------------------------------------------------ TACHES ----

  -- Restituer les consignes de vol (cap, altitude, gaz) relevees avant
  -- l'alerte. Filet de securite si aucun programme de navigation n'ecoute.
  reprendreTache = true,

  -- Fichier local ou le programme de navigation peut deposer sa tache
  -- courante, sous la forme d'un 'return { ... }' Lua. Lu a chaque sauvegarde.
  fichierTache = "tache_courante.lua",

  -- Timeout de la demande de tache par rednet, en secondes.
  delaiInterrogationTache = 1.5,

  -- Periodicite de la sauvegarde de la tache courante, en secondes.
  -- Uniquement en VEILLE : jamais pendant une evasion.
  rafraichirTacheSecondes = 10,

  -- false (defaut) = INDEPENDANCE TOTALE : aucun ordre exterieur ne peut
  -- desarmer l'ADS de ce navire. true = un message reseau peut l'inhiber,
  -- ce qui ouvre la porte a un desarmement hostile. Reflechissez-y.
  autoriserInhibitionExterne = false,

  -------------------------------------------------------------- TELEMETRIE ----

  telemetrieActive = true,
  intervalleTelemetrieSecondes = 2,

  -------------------------------------------------------------- ROBUSTESSE ----

  -- Temporisation progressive entre deux redemarrages automatiques (secondes).
  redemarrageDelaiMin = 3,
  redemarrageDelaiMax = 60,

  -- true  : Ctrl+T desarme l'ADS (pratique en phase de reglage).
  -- false : Ctrl+T est ignore et journalise -> le navire reste protege
  --         tant que l'ordinateur existe.
  arretParTerminate = true,

  ----------------------------------------------------------------- JOURNAL ----

  journalFichier = true,

  -- Taille maximale avant rotation vers ads.log.1 (octets).
  journalTailleMax = 131072,

  -- Verbosite ECRAN uniquement : "DEBUG" | "INFO" | "AVERT" | "ERREUR".
  -- Le fichier journal enregistre toujours tout.
  -- "DEBUG" affiche chaque piste a chaque scan : indispensable au reglage,
  -- beaucoup trop bavard en operation.
  journalNiveauEcran = "INFO",

  -- Periodicite du resume d'etat dans le journal (secondes).
  battementSecondes = 60,
}
