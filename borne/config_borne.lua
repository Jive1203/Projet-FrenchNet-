--[[----------------------------------------------------------------------------
  CONFIGURATION DE LA BORNE DE COMMANDE PUBLIQUE FRENCHNET
  --------------------------------------------------------------------------
  La borne est OUVERTE A TOUS : n'importe quel joueur, n'importe quelle
  faction, peut s'en servir. Elle ne detient aucun secret et ne peut rien
  faire d'autre que deposer une commande : le navire revalide tout a bord
  (quantites, portee, prix) avant d'accepter quoi que ce soit.
--------------------------------------------------------------------------------]]

return {

  -- Nom affiche en tete d'ecran.
  titre = "FRENCHNET - LIVRAISON AERIENNE",

  -- Identifiant du dirigeable a servir. nil = le premier qui repond.
  -- A renseigner des qu'il y a plusieurs dirigeables sur le serveur.
  navireCible = nil,

  -- Cote du modem (Ender de preference). nil = detection automatique.
  coteModem = nil,

  -- Delai d'attente des reponses du navire, en secondes.
  delaiReponse = 5,

  -- Conteneurs sources visibles DEPUIS LA BORNE (modem filaire). Renseignes,
  -- ils permettent d'afficher le catalogue meme quand le navire est en
  -- mission loin de la base. Laisser vide pour n'utiliser que le catalogue
  -- transmis par le navire.
  conteneursSourceLocaux = {},

  -- Nombre d'articles affiches par page de catalogue.
  articlesParPage = 10,

  ------------------------------------------------------------------ CENTRAL ---
  -- La borne n'invente aucun prix : elle affiche la grille diffusee par
  -- l'ordinateur central, et le navire exige a l'arrivee cette meme grille.
  central = {
    -- Identifiant de la centrale tarifaire. Une grille qui se reclame d'un
    -- autre identifiant est ignoree.
    identifiant = "CENTRALE-01",
    -- JETON PARTAGE, identique sur le central, les navires et les bornes.
    -- Il signe la grille recue et le certificat de pre-paiement emis.
    jeton = "CHANGEZ-MOI-jeton-partage-frenchnet",
    -- Attente d'une reponse du central au demarrage, en secondes.
    delaiDemande = 5,
  },

  -------------------------------------------------------------- PRE-PAIEMENT --
  -- Un client penalise (il a laisse un navire repartir sans payer) doit
  -- regler a la borne avant qu'une nouvelle commande soit acceptee.
  prepaiement = {
    -- Coffre ou le client depose son paiement, relie a la borne par modem
    -- filaire. nil = la borne ne peut pas encaisser, les clients penalises
    -- sont alors simplement refuses.
    coffreDepot = nil,
    -- Coffre ou la borne range le paiement encaisse. nil = il reste dans le
    -- coffre de depot.
    coffreRecette = nil,
    -- Temps laisse au client pour deposer, en secondes.
    delaiMax = 120,
    -- Periode de verification du coffre, en secondes.
    intervalle = 3,
  },

  -- Nom propose par defaut dans le formulaire (le joueur peut le changer).
  clientParDefaut = "",

  -- Rappel affiche au client sur le fonctionnement du paiement.
  rappelPaiement =
    "Deposez le paiement dans un coffre a cote du point de livraison :\n"
    .. "le navire attend le montant exact avant de deposer la marchandise.",

  journal = {
    fichier     = "borne/borne.log",
    tailleMax   = 64 * 1024,
    niveauEcran = "AVERT",   -- l'ecran sert au client : on n'y met que l'essentiel
  },

  robustesse = {
    redemarrageDelaiMin = 3,
    redemarrageDelaiMax = 30,
    arretParTerminate   = true,
  },
}
