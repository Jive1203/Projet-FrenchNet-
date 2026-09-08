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

  -- Protocole rednet vers le poste de commandement. Doit etre IDENTIQUE sur
  -- toutes les stations et sur le poste.
  protocoleRadar = "frenchnet_radar",

  -- Identifiant de l'ordinateur du poste de commandement. nil = diffusion.
  -- Renseigner rend l'envoi cible et allege le reseau.
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
