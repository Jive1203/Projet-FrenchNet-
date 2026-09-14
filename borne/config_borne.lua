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
