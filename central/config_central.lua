--[[----------------------------------------------------------------------------
  CONFIGURATION DE L'ORDINATEUR CENTRAL - TARIFS FRENCHNET
  --------------------------------------------------------------------------
  Le central est le SEUL endroit ou se decident les prix. Il diffuse sa grille
  aux navires et aux bornes ; ceux-ci l'appliquent sans jamais la modifier.

  AUCUN CODE N'EST ECRIT DANS CE FICHIER. Au premier demarrage, le central
  demande a l'operateur de choisir un code et n'en conserve qu'une empreinte
  salee, dans central/code.dat. Un joueur qui ouvre les fichiers n'y lit donc
  pas le code -- mais rien n'empeche celui qui a acces a l'ordinateur de le
  remplacer : la vraie protection reste la serrure de la piece.
--------------------------------------------------------------------------------]]

return {

  -- Nom affiche en tete d'ecran et dans les messages diffuses.
  titre = "FRENCHNET - CENTRALE TARIFAIRE",

  -- Identifiant du central. Les navires et les bornes n'acceptent une grille
  -- que si elle vient de cet identifiant ET porte la bonne signature.
  identifiant = "CENTRALE-01",

  -- JETON PARTAGE. Doit etre IDENTIQUE sur le central, les navires et les
  -- bornes. Il signe la grille : une trame alteree ou une vieille grille
  -- rejouee sont refusees. Ce n'est pas de la cryptographie -- qui lit le
  -- fichier d'une borne connait le jeton -- mais cela suffit a empecher une
  -- erreur de configuration ou un bricolage de passer inapercu.
  jeton = "CHANGEZ-MOI-jeton-partage-frenchnet",

  -- Cote du modem (Ender de preference). nil = detection automatique.
  coteModem = nil,

  -- Diffusion periodique de la grille, en secondes. Toute modification est
  -- de toute facon diffusee immediatement.
  diffusionSecondes = 60,

  ------------------------------------------------------------------ SERRURE ---
  serrure = {
    -- Longueur minimale du code choisi au premier demarrage.
    longueurMinimale = 4,
    -- Tentatives avant verrouillage temporaire.
    tentativesMax = 3,
    -- Duree du verrouillage apres echecs, en secondes.
    verrouillageSecondes = 300,
    -- Reverrouillage automatique apres ce temps sans frappe, en secondes.
    inactiviteSecondes = 120,
  },

  --------------------------------------------------------------- GRILLE INITIALE
  -- Utilisee uniquement si central/tarifs.dat n'existe pas encore. Ensuite,
  -- c'est le fichier de donnees qui fait foi et ce bloc n'est plus relu.
  tarifInitial = {
    objetPaiement      = "minecraft:diamond",
    forfaitBase        = 5,       -- prix plancher de toute expedition
    prixUnitaireDefaut = 0.01,    -- pour tout objet sans prix propre
    parObjet = {
      ["minecraft:netherite_ingot"] = 1.0,
      ["minecraft:diamond"]         = 0.5,
      ["minecraft:iron_ingot"]      = 0.02,
      ["minecraft:cobblestone"]     = 0.002,
    },
    coefficientVitesse = { fast = 2.0, slow = 1.0 },
    prixMinimum        = 1,
    prixMaximum        = 2304,
  },

  ---------------------------------------------------------------- PENALITES ---
  -- Appliquees par les navires au client qui laisse repartir une livraison
  -- sans l'avoir payee. Diffusees avec la grille.
  penalitesInitiales = {
    -- "prepaiement" : ses commandes suivantes exigent un paiement a la borne
    -- "refus"       : ses commandes sont refusees jusqu'a expiration
    mode = "prepaiement",
    -- Duree de la penalite, en secondes.
    duree = 3600,
    -- Nombre d'incidents avant qu'elle ne s'applique.
    incidentsAvantPenalite = 1,
    -- Oubli d'un incident isole apres ce delai sans recidive, en secondes.
    effacerApres = 86400,
  },

  ------------------------------------------------------------------ JOURNAL ---
  journal = {
    fichier     = "central/central.log",
    tailleMax   = 64 * 1024,
    niveauEcran = "AVERT",
  },

  --------------------------------------------------------------- ROBUSTESSE ---
  robustesse = {
    redemarrageDelaiMin = 3,
    redemarrageDelaiMax = 30,
  },
}
