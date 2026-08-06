--[[----------------------------------------------------------------------------
  CONFIGURATION D'UNE BALISE FRENCHNET - AERONAUTICS WARFARE
  --------------------------------------------------------------------------
  A EDITER SUR CHAQUE ORDINATEUR BALISE. Deux champs seulement sont
  reellement obligatoires :

      identifiant      -> unique pour chaque balise du serveur
      positionManuelle -> coordonnees exactes du bloc de l'ordinateur

  Pour relever les coordonnees exactes en jeu : touche F3, ligne "Block"
  (et non "XYZ", qui donne la position du joueur avec des decimales).

  RAPPEL IMPORTANT sur 'positionManuelle' :
  une balise est FIXE, donc ses coordonnees sont connues d'avance. Les
  renseigner permet (1) de demarrer meme si la constellation GPS n'est pas
  encore montee - probleme de l'oeuf et de la poule - et (2) de servir
  d'hote GPS pour tout le serveur. Laisser ce champ a nil bascule la balise
  en mode "je me localise via gps.locate", ce qui exige 4 autres hotes GPS
  deja operationnels a portee.
--------------------------------------------------------------------------------]]

return {

  ---------------------------------------------------------------- IDENTITE ----

  -- Identifiant unique. Doit differer sur CHAQUE balise.
  -- Exemples de nommage pour un deploiement a 4+ balises non alignees :
  --   "BAL-01-NORD", "BAL-02-EST", "BAL-03-SUD", "BAL-04-OUEST", "BAL-05-ZENITH"
  identifiant = "BAL-01-NORD",

  -- Libelle libre, purement informatif (secteur, role, altitude...).
  designation = "Secteur nord - relais haute altitude",

  ---------------------------------------------------------------- POSITION ----

  -- Coordonnees exactes du bloc ordinateur. FORTEMENT RECOMMANDE.
  -- Mettre a nil pour utiliser gps.locate a la place.
  positionManuelle = { x = 1200, y = 210, z = -2600 },

  -- Controle croise au demarrage : compare 'positionManuelle' a une mesure
  -- gps.locate et journalise l'ecart. Utile pour valider la constellation.
  verifierAvecGps = false,

  -- Timeout de gps.locate, en secondes (mode GPS ou controle croise).
  delaiGps = 5,

  -- Re-verification periodique de la position, en secondes (mode GPS seulement).
  -- 0 = jamais. Sans effet si 'positionManuelle' est renseigne.
  rafraichirPositionToutes = 300,

  ----------------------------------------------------------------- RESEAU -----

  -- Periode de diffusion en secondes. 5 s est un bon compromis ;
  -- descendre a 1 s pour un suivi tres reactif, monter a 15-30 s pour
  -- reduire la charge reseau sur un serveur charge.
  intervalleSecondes = 5,

  -- Protocole rednet. Doit etre IDENTIQUE sur toutes les balises et sur les
  -- recepteurs (avions, tours de controle, moniteurs...).
  protocoleRednet = "frenchnet_balise",

  -- Cote du modem Ender : "top", "bottom", "left", "right", "front", "back".
  -- nil = detection automatique (le modem Ender est prioritaire sur un
  -- eventuel modem sans fil classique).
  coteModem = nil,

  -- Repondre aux requetes gps.locate des autres ordinateurs (canal 65534).
  -- Necessite 'positionManuelle'. C'est ce qui fait des balises une vraie
  -- constellation GPS exploitable par les avions et les turtles.
  hoteGps = true,

  -- Ecouter les autres balises : inventaire de la constellation et alerte
  -- immediate en cas d'identifiant duplique.
  ecouterPairs = true,

  --------------------------------------------------------------- ROBUSTESSE ---

  -- Nombre d'echecs d'emission consecutifs avant reinitialisation complete
  -- du lien reseau (re-detection du modem, re-ouverture de rednet).
  erreursAvantReinit = 5,

  -- Temporisation progressive entre deux redemarrages automatiques (secondes).
  redemarrageDelaiMin = 3,
  redemarrageDelaiMax = 60,

  -- true  : Ctrl+T arrete la balise (pratique en phase de reglage).
  -- false : Ctrl+T est ignore et journalise -> autonomie totale, la balise
  --         ne peut plus etre stoppee qu'en cassant l'ordinateur.
  arretParTerminate = true,

  ---------------------------------------------------------------- JOURNAL -----

  -- Ecriture du journal dans balise.log (a cote du programme).
  journalFichier = true,

  -- Taille maximale avant rotation vers balise.log.1 (octets).
  journalTailleMax = 65536,

  -- Verbosite ECRAN uniquement : "DEBUG" | "INFO" | "AVERT" | "ERREUR".
  -- Le fichier journal enregistre toujours tout.
  -- "DEBUG" affiche chaque trame diffusee : tres utile lors du deploiement.
  journalNiveauEcran = "INFO",

  -- Periodicite du resume d'etat dans le journal (secondes).
  battementSecondes = 60,
}
