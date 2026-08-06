--[[----------------------------------------------------------------------------
  LANCEUR AUTOMATIQUE - BALISE FRENCHNET
  --------------------------------------------------------------------------
  A placer a la RACINE de l'ordinateur balise (/startup.lua).
  Assure le demarrage de la balise a chaque allumage, rechargement de chunk
  ou redemarrage du serveur, sans aucune intervention humaine.

  Comportement :
    - lance /balise/balise.lua ;
    - si le programme rend la main de facon anormale, l'ordinateur redemarre
      apres une temporisation (ultime filet de securite) ;
    - un arret manuel (Ctrl+T) depose le marqueur /balise/.arret_manuel :
      dans ce cas le lanceur ne redemarre PAS l'ordinateur, ce qui laisse
      la main pour la maintenance.
--------------------------------------------------------------------------------]]

local CHEMIN_BALISE  = "/balise/balise.lua"
local MARQUEUR_ARRET = "/balise/.arret_manuel"
local DELAI_REBOOT   = 15

term.clear()
term.setCursorPos(1, 1)

if not fs.exists(CHEMIN_BALISE) then
  print("[LANCEUR] Programme introuvable : " .. CHEMIN_BALISE)
  print("[LANCEUR] Installez la balise puis redemarrez l'ordinateur.")
  return
end

if fs.exists(MARQUEUR_ARRET) then
  pcall(fs.delete, MARQUEUR_ARRET)
end

print("[LANCEUR] Demarrage de la balise FrenchNet...")
shell.run(CHEMIN_BALISE)

-- Ici, la balise a rendu la main : soit arret volontaire, soit anomalie grave.
if fs.exists(MARQUEUR_ARRET) then
  print("[LANCEUR] Arret manuel detecte. Aucun redemarrage automatique.")
  print("[LANCEUR] Relancez avec : " .. CHEMIN_BALISE)
  return
end

print("[LANCEUR] Sortie anormale de la balise.")
print("[LANCEUR] Redemarrage de l'ordinateur dans " .. DELAI_REBOOT .. "s (Ctrl+T pour annuler).")
sleep(DELAI_REBOOT)
os.reboot()
