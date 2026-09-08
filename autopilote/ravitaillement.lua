--[[----------------------------------------------------------------------------
  STATION DE RAVITAILLEMENT - CONSTANTE DE RESEAU FRENCHNET
  --------------------------------------------------------------------------
  VALEUR VERROUILLEE. Ce fichier est IDENTIQUE sur tous les vehicules du
  serveur : c'est la position de ravitaillement en carburant commune.

  Il est volontairement separe de config_vehicule.lua :
    - l'interface de reglage l'AFFICHE mais REFUSE de la modifier ;
    - un vehicule qui declarerait sa propre position de ravitaillement dans
      sa configuration verrait sa valeur ignoree, et l'anomalie journalisee ;
    - la valeur n'est pas ecrite en dur dans le code de l'autopilote.

  Ne modifier ce fichier que pour un demenagement de la station, et le
  redeployer alors sur TOUS les vehicules.
--------------------------------------------------------------------------------]]

return {
  nom         = "STATION FRENCHNET - PONTON CARBURANT",
  designation = "Ponton de ravitaillement principal",

  -- Coordonnees exactes du point de contact (touche F3, ligne "Block").
  position = { x = 128, y = 96, z = -742 },

  -- Cap a tenir en finale sur le ponton, en degres (0 = nord). nil = libre.
  capFinal = 90,
}
