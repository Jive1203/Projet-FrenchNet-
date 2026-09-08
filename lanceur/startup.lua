--[[----------------------------------------------------------------------------
  LANCEUR AUTOMATIQUE - BALISE DE LANCEUR FRENCHNET
  --------------------------------------------------------------------------
  A placer a la RACINE de l'ordinateur de la balise de lanceur (/startup.lua).
  Assure le demarrage du systeme de defense a chaque allumage, rechargement de
  chunk ou redemarrage du serveur, sans intervention humaine.

  Comportement :
    - lance /lanceur/lanceur.lua ;
    - si le programme rend la main de facon anormale, l'ordinateur redemarre
      apres une temporisation (ultime filet de securite) ;
    - un arret manuel depose le marqueur /lanceur/.arret_manuel : dans ce cas
      le lanceur ne redemarre PAS l'ordinateur, ce qui laisse la main pour la
      maintenance.

  IMPORTANT : le chunk de la balise de lanceur doit rester charge
  (forceload), sinon la defense cesse purement et simplement de decider.
--------------------------------------------------------------------------------]]

local CHEMIN_COMMAND = "/lanceur/lanceur.lua"
local MARQUEUR_ARRET = "/lanceur/.arret_manuel"
local DELAI_REBOOT   = 15

term.clear()
term.setCursorPos(1, 1)

if not fs.exists(CHEMIN_COMMAND) then
  print("[LANCEUR] Programme introuvable : " .. CHEMIN_COMMAND)
  print("[LANCEUR] Installez la balise de lanceur puis redemarrez l'ordinateur.")
  return
end

if fs.exists(MARQUEUR_ARRET) then
  pcall(fs.delete, MARQUEUR_ARRET)
end

print("[LANCEUR] Demarrage de la balise de lanceur...")
shell.run(CHEMIN_COMMAND)

-- Ici, Command a rendu la main : soit arret volontaire, soit anomalie grave.
if fs.exists(MARQUEUR_ARRET) then
  print("[LANCEUR] Arret manuel detecte. Aucun redemarrage automatique.")
  print("[LANCEUR] Relancez avec : " .. CHEMIN_COMMAND)
  return
end

print("[LANCEUR] Sortie anormale de la balise de lanceur.")
print("[LANCEUR] Redemarrage de l'ordinateur dans " .. DELAI_REBOOT .. "s (Ctrl+T pour annuler).")
sleep(DELAI_REBOOT)
os.reboot()
