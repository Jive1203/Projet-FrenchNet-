--[[----------------------------------------------------------------------------
  CONFIGURATION D'UNE STATION RADAR FRENCHNET
  --------------------------------------------------------------------------
  A EDITER SUR CHAQUE STATION. Deux champs comptent vraiment :

      identifiant -> unique sur le reseau
      position    -> coordonnees exactes du bloc radar (F3, ligne "Block")

  La position n'est pas cosmetique. Elle sert a placer les pistes, a calculer
  l'enveloppe fiable de confirmation de destruction, et elle constitue un
  releve d'altitude du sol pour le modele de terrain du poste central.
--------------------------------------------------------------------------------]]

return {

  -- Identifiant unique. Doit differer sur CHAQUE station.
  identifiant = "RAD-01-NORD",

  -- Libelle libre, affiche sur la carte du poste de commandement.
  designation = "Secteur nord",

  -- Coordonnees exactes du bloc radar. F3, ligne "Block".
  position = { x = 1200, y = 210, z = -2600 },

  -- Portee utile du radar, en blocs. Sert au garde-fou d'enveloppe fiable :
  -- une cible qui disparait au-dela de 80 % de cette portee est consideree
  -- comme ayant fui, pas comme detruite.
  portee = 512,

  -- true  : le radar rend des coordonnees RELATIVES a son bloc.
  -- false : il rend des coordonnees ABSOLUES du monde.
  -- nil   : deduction automatique au premier balayage, journalisee en clair.
  positionsRelatives = nil,

  -- Nom du peripherique radar. nil = detection automatique (type contenant
  -- "radar").
  peripheriqueRadar = nil,

  -- Cote du modem Ender. nil = detection automatique.
  coteModem = nil,

  -- Periode de balayage, en secondes. 1 s convient : c'est assez rapide pour
  -- la fenetre de crash de 3 s du poste central.
  intervalleBalayage = 1,

  --[[
    CADENCE ADAPTATIVE - le reglage anti-saccade le plus efficace.

    Les methodes du radar s'executent sur le THREAD PRINCIPAL du serveur :
    c'est, de loin, ce que cette station coute le plus cher au monde qui
    l'heberge. Les appeler chaque seconde alors que rien ne vole depuis dix
    minutes est du gaspillage pur.

    Passe 'reposApres' secondes sans le moindre contact, la cadence se detend a
    'intervalleRepos'. Elle revient a pleine vitesse des le premier echo.

    LE PRIX A PAYER : sur un ciel jusque-la desert, un intrus peut mettre
    jusqu'a 'intervalleRepos' de plus a etre vu. Reglez en connaissance de
    cause. intervalleRepos = false supprime la detente et garde la pleine
    cadence en permanence.
  ]]
  intervalleRepos = 3,
  reposApres      = 10,

  -- Un ciel vide n'a pas besoin d'etre annonce chaque seconde. Tant qu'il n'y
  -- a rien et qu'il n'y avait rien, la station n'emet que toutes les N
  -- secondes - assez souvent pour que le poste ne la declare pas muette
  -- (validiteStation, 15 s par defaut), assez rarement pour ne reveiller
  -- personne pour rien. Tout changement part immediatement.
  rafraichissementVide = 5,

  -- Protocole rednet vers le poste de commandement. Doit etre IDENTIQUE sur
  -- toutes les stations et sur le poste.
  protocoleRadar = "frenchnet_radar",

  -- Protocole sur lequel le poste s'annonce. La station retient son numero et
  -- lui parle ensuite DIRECTEMENT au lieu de diffuser a tout le serveur - une
  -- diffusion reveille chaque ordinateur du monde, concerne ou non.
  protocoleAnnonce = "frenchnet_annonce",

  -- Identifiant de l'ordinateur du poste de commandement.
  -- nil = decouverte automatique par l'annonce ci-dessus, avec repli en
  -- diffusion generale tant que le poste ne s'est pas manifeste.
  -- Le renseigner supprime meme ce repli.
  idCommand = nil,

  ---------------------------------------------------------------- JOURNAL -----
  journalFichier     = true,
  journalNiveauEcran = "INFO",   -- DEBUG | INFO | AVERT | ERREUR
  battementSecondes  = 60,

  --------------------------------------------------------------- ROBUSTESSE ---
  redemarrageDelaiMin = 3,
  redemarrageDelaiMax = 60,
  arretParTerminate   = true,
}
