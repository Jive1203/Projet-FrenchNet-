--[[----------------------------------------------------------------------------
  LANCEUR AUTOMATIQUE - ADS FRENCHNET
  --------------------------------------------------------------------------
  A placer a la RACINE de l'ordinateur ADS du navire (/startup.lua).
  Assure l'armement de l'ADS a chaque allumage, rechargement de chunk ou
  redemarrage du serveur, sans aucune intervention humaine.

  Comportement :
    - lance /ads/ads.lua ;
    - leve tout verrou de priorite reste pose par un plantage precedent :
      un navire ne doit JAMAIS demarrer avec l'ADS aux commandes ;
    - si le programme rend la main de facon anormale, l'ordinateur redemarre
      apres une temporisation (ultime filet de securite) ;
    - un arret manuel (Ctrl+T) depose le marqueur /ads/.arret_manuel :
      dans ce cas le lanceur ne redemarre PAS l'ordinateur, ce qui laisse
      la main pour la maintenance.

  ATTENTION : si ce lanceur affiche "Programme introuvable", le navire sort
  du hangar SANS contre-mesures. Verifiez avant de decoller.
--------------------------------------------------------------------------------]]

local CHEMIN_ADS     = "/ads/ads.lua"
local MARQUEUR_ARRET = "/ads/.arret_manuel"
local VERROU_PRIORITE = "/ads/.priorite_ads"
local DELAI_REBOOT   = 15

term.clear()
term.setCursorPos(1, 1)

if not fs.exists(CHEMIN_ADS) then
  print("[LANCEUR] Programme introuvable : " .. CHEMIN_ADS)
  print("[LANCEUR] LE NAVIRE N'A AUCUNE CONTRE-MESURE.")
  print("[LANCEUR] Installez l'ADS puis redemarrez l'ordinateur.")
  return
end

if fs.exists(MARQUEUR_ARRET) then
  pcall(fs.delete, MARQUEUR_ARRET)
end

-- Un verrou survivant a un plantage priverait la navigation de ses commandes.
if fs.exists(VERROU_PRIORITE) then
  print("[LANCEUR] Verrou de priorite ADS trouve : leve avant demarrage.")
  pcall(fs.delete, VERROU_PRIORITE)
end

print("[LANCEUR] Armement de l'ADS FrenchNet...")
shell.run(CHEMIN_ADS)

-- Ici, l'ADS a rendu la main : soit arret volontaire, soit anomalie grave.
if fs.exists(VERROU_PRIORITE) then
  pcall(fs.delete, VERROU_PRIORITE)
end

if fs.exists(MARQUEUR_ARRET) then
  print("[LANCEUR] Arret manuel detecte. Aucun redemarrage automatique.")
  print("[LANCEUR] LE NAVIRE N'EST PLUS PROTEGE.")
  print("[LANCEUR] Relancez avec : " .. CHEMIN_ADS)
  return
end

print("[LANCEUR] Sortie anormale de l'ADS.")
print("[LANCEUR] Redemarrage de l'ordinateur dans " .. DELAI_REBOOT .. "s (Ctrl+T pour annuler).")
sleep(DELAI_REBOOT)
os.reboot()
