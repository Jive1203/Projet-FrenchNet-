--[[----------------------------------------------------------------------------
  CONFIGURATION D'UN ORDINATEUR DE SORTIE DEPORTE - AUTOPILOTE FRENCHNET
  --------------------------------------------------------------------------
  A EDITER SUR CHAQUE SATELLITE. Un satellite est un ordinateur pose ailleurs
  sur le vehicule, relie au maitre par un modem SANS FIL COURTE PORTEE, et qui
  tient ses propres faces redstone. Il permet de commander une propulsion
  dispersee sans faire courir de cable jusqu'a l'ordinateur principal.

  Deux champs seulement sont vraiment obligatoires :

      identifiant -> libelle libre, pour s'y retrouver dans les journaux
      vehicule    -> identifiant du vehicule maitre (filtre les trames)

  L'ordinateur maitre adresse ses trames par NUMERO D'ORDINATEUR. Ce numero
  s'affiche au demarrage du satellite : reportez-le dans la configuration du
  vehicule, champ 'ordinateur' de l'axe concerne.
--------------------------------------------------------------------------------]]

return {

  -- Libelle libre : apparait dans les journaux et dans l'outil de cablage.
  identifiant = "SAT-AVANT",

  -- Identifiant du vehicule maitre. Les trames d'un autre vehicule sont
  -- ignorees : deux appareils cote a cote ne se commandent pas l'un l'autre.
  -- nil = accepte n'importe quel maitre (deconseille en operation).
  vehicule = "AER-CARGO-01",

  -- Doit etre IDENTIQUE au 'sorties.distant.protocole' du vehicule.
  protocole = "frenchnet_sortie",

  -- Cote du modem sans fil. nil = detection automatique, en preferant un
  -- modem COURTE PORTEE (un modem Ender porterait jusqu'aux vehicules voisins).
  coteModem = nil,

  -- Chien de garde : sans trame pendant ce delai, le satellite remet ses
  -- faces au repos. C'est la securite qui empeche un vehicule de partir en
  -- pleine poussee parce que l'ordinateur principal a plante.
  delaiChienDeGarde = 1.5,

  -- Niveaux de repos par face, en secours. Normalement inutile : le maitre
  -- envoie ses propres niveaux de repos dans chaque trame. Ne sert que si le
  -- satellite n'a jamais recu la moindre trame depuis son demarrage.
  repos = { left = 0, right = 0, front = 0, back = 0, top = 0, bottom = 0 },

  -- Faces que ce satellite a le droit de piloter. Une trame demandant une
  -- autre face est refusee et journalisee : cela evite qu'une erreur de
  -- configuration ne fasse actionner un mecanisme sans rapport.
  cotesAutorises = { "left", "right", "front", "back", "top", "bottom" },

  -- Remonte l'etat des entrees redstone au maitre (jauge de carburant, radar
  -- sol, capteur eloigne...). Sans surcout notable.
  remonterEntrees = true,

  -- Periode d'annonce quand aucune trame n'arrive (secondes). Sert a
  -- l'outil de cablage pour decouvrir les satellites presents.
  periodeAnnonce = 3,

  ---------------------------------------------------------------- ROBUSTESSE --

  redemarrageDelaiMin = 3,
  redemarrageDelaiMax = 60,
  arretParTerminate   = true,

  ------------------------------------------------------------------ JOURNAL --

  journalFichier     = true,
  journalChemin      = "/autopilote/satellite.log",
  journalTailleMax   = 32768,
  journalNiveauEcran = "INFO",   -- DEBUG | INFO | AVERT | ERREUR
}
