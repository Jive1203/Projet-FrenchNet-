--[[----------------------------------------------------------------------------
  LANCEUR - FRENCHNET OS (ordinateur de bord du navire intercepteur)
  --------------------------------------------------------------------------
  A placer a la RACINE de l'ordinateur de bord (/startup.lua).

  Il lance le SYSTEME D'EXPLOITATION, pas directement le systeme
  d'interception : c'est l'OS qui verifie le materiel, demarre l'interception
  dans sa propre tache et offre l'interface a l'equipage.

  Filet de securite : si l'OS rend la main de facon anormale, l'ordinateur
  redemarre apres une temporisation. Un arret volontaire (page Systeme, touche
  Q) depose un marqueur et bloque ce redemarrage, pour laisser la main a la
  maintenance.
--------------------------------------------------------------------------------]]

local CHEMIN_OS      = "/systeme/os.lua"
local MARQUEUR_ARRET = "/systeme/.arret_manuel"
local DELAI_REBOOT   = 15

term.clear()
term.setCursorPos(1, 1)

if not fs.exists(CHEMIN_OS) then
  print("[LANCEUR] Systeme introuvable : " .. CHEMIN_OS)
  print("[LANCEUR] Installez FrenchNet OS puis redemarrez l'ordinateur.")
  return
end

if fs.exists(MARQUEUR_ARRET) then pcall(fs.delete, MARQUEUR_ARRET) end

print("[LANCEUR] Demarrage de FrenchNet OS...")
local ok, err = pcall(function() shell.run(CHEMIN_OS) end)

if not ok then
  print("[LANCEUR] FrenchNet OS a leve une erreur :")
  print("  " .. tostring(err))
end

if fs.exists(MARQUEUR_ARRET) then
  print("[LANCEUR] Arret manuel detecte. Aucun redemarrage automatique.")
  print("[LANCEUR] Relancez avec : " .. CHEMIN_OS)
  return
end

print("[LANCEUR] Redemarrage de l'ordinateur dans " .. DELAI_REBOOT .. "s (Ctrl+T pour annuler).")
sleep(DELAI_REBOOT)
os.reboot()
