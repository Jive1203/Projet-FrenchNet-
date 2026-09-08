--[[----------------------------------------------------------------------------
  LANCEUR AUTOMATIQUE - STATION RADAR FRENCHNET
  --------------------------------------------------------------------------
  A placer a la RACINE de l'ordinateur de la station radar (/startup.lua).
  Assure le demarrage du systeme de defense a chaque allumage, rechargement de
  chunk ou redemarrage du serveur, sans intervention humaine.

  Comportement :
    - lance /radar/radar.lua ;
    - si le programme rend la main de facon anormale, l'ordinateur redemarre
      apres une temporisation (ultime filet de securite) ;
    - un arret manuel depose le marqueur /radar/.arret_manuel : dans ce cas
      le lanceur ne redemarre PAS l'ordinateur, ce qui laisse la main pour la
      maintenance.

  IMPORTANT : le chunk de la station radar doit rester charge
  (forceload), sinon la defense cesse purement et simplement de decider.
--------------------------------------------------------------------------------]]

local CHEMIN_COMMAND = "/radar/radar.lua"
local MARQUEUR_ARRET = "/radar/.arret_manuel"
local DELAI_REBOOT   = 15

term.clear()
term.setCursorPos(1, 1)

if not fs.exists(CHEMIN_COMMAND) then
  print("[LANCEUR] Programme introuvable : " .. CHEMIN_COMMAND)
  print("[LANCEUR] Installez la station radar puis redemarrez l'ordinateur.")
  return
end

if fs.exists(MARQUEUR_ARRET) then
  pcall(fs.delete, MARQUEUR_ARRET)
end

print("[LANCEUR] Demarrage de la station radar...")
shell.run(CHEMIN_COMMAND)

-- Ici, Command a rendu la main : soit arret volontaire, soit anomalie grave.
if fs.exists(MARQUEUR_ARRET) then
  print("[LANCEUR] Arret manuel detecte. Aucun redemarrage automatique.")
  print("[LANCEUR] Relancez avec : " .. CHEMIN_COMMAND)
  return
end

print("[LANCEUR] Sortie anormale de la station radar.")
print("[LANCEUR] Redemarrage de l'ordinateur dans " .. DELAI_REBOOT .. "s (Ctrl+T pour annuler).")
sleep(DELAI_REBOOT)
os.reboot()
