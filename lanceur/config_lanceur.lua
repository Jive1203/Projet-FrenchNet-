--[[----------------------------------------------------------------------------
  CONFIGURATION D'UNE BALISE DE LANCEUR FRENCHNET
  --------------------------------------------------------------------------
  A EDITER SUR CHAQUE PLATEFORME DE DEFENSE.

  Le nom saisi ici est celui qui apparaitra dans les ordres transmis a
  Fire Control : « AirShip1 Fire type Aerial ». Il doit donc correspondre
  exactement au nom que Fire Control connait.
--------------------------------------------------------------------------------]]

return {

  -- Nom de la plateforme. C'est LE nom repris dans les ordres de tir.
  identifiant = "AirShip1",

  -- Libelle libre, affiche sur la carte du poste de commandement.
  designation = "Intercepteur secteur nord",

  -- Position de la plateforme. F3, ligne "Block".
  -- Sert au calcul de distance de designation, a l'affichage sur la carte,
  -- et de releve d'altitude pour le modele de terrain.
  position = { x = 1200, y = 210, z = -2600 },

  -- Portee utile en blocs. Une menace au-dela ne fera pas designer cette
  -- plateforme (sauf designerHorsPortee cote poste de commandement).
  portee = 400,

  -- Categories que cette plateforme sait traiter. nil = toutes.
  -- Exemples : { "AERIENNE" } pour une batterie anti-aerienne pure,
  --            { "INFANTERIE", "VEHICULE_SOL" } pour un appui sol.
  categoriesTraitees = nil,

  ------------------------------------------------------------- MUNITIONS ------

  -- "inventaire" : comptage reel dans un coffre ou baril accole. Mode fiable.
  -- "manuel"     : compteur tenu a la main (touches + et - sur la balise).
  sourceMunitions = "inventaire",

  -- Nom du peripherique d'inventaire. nil = premier inventaire detecte.
  nomInventaire = nil,

  -- Fragments de nom d'objet comptes comme munitions. Insensible a la casse,
  -- recherche par sous-chaine sur l'identifiant de l'objet.
  filtreMunition = { "missile", "shell", "rocket", "cartridge", "autocannon" },

  -- Stock declare, en mode manuel uniquement.
  munitionsManuelles = 12,

  -- Capacite maximale, purement informative (barre de stock sur la carte).
  munitionsMax = 24,

  -- Seuil d'alerte de stock bas, journalise sur la balise.
  seuilAlerte = 3,

  ---------------------------------------------------------------- RESEAU ------

  -- Periode de RELEVE du stock, en secondes.
  intervalleSecondes = 5,

  -- Periode de RAPPEL, quand rien ne change. La balise n'emet que sur
  -- changement de stock ou de disponibilite ; ce rappel evite que le poste la
  -- declare perimee (validiteInventaire, 60 s par defaut). Un tir fait partir
  -- la trame immediatement.
  rafraichissementPlein = 20,

  -- Protocole rednet. IDENTIQUE sur toutes les balises et sur le poste.
  protocoleLanceur = "frenchnet_lanceur",

  -- Protocole sur lequel le poste s'annonce. La balise retient son numero et
  -- lui parle ensuite directement au lieu de diffuser a tout le serveur.
  protocoleAnnonce = "frenchnet_annonce",

  -- Identifiant de l'ordinateur du poste. nil = decouverte automatique.
  idCommand = nil,

  ---------------------------------------------------------------- JOURNAL -----
  journalFichier     = true,
  journalNiveauEcran = "INFO",
  arretParTerminate  = true,
}
