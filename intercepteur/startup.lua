--[[----------------------------------------------------------------------------
  LANCEUR AUTOMATIQUE - NAVIRE INTERCEPTEUR FRENCHNET
  --------------------------------------------------------------------------
  A placer a la RACINE de l'ordinateur de bord (/startup.lua).
  Assure le demarrage du systeme embarque a chaque allumage, rechargement de
  chunk ou redemarrage du serveur.

  Comportement :
    - lance /intercepteur/intercepteur.lua ;
    - si le programme rend la main de facon anormale, l'ordinateur redemarre
      apres une temporisation (ultime filet de securite) ;
    - un arret manuel (Ctrl+T) depose le marqueur .arret_manuel : dans ce cas
      le lanceur ne redemarre PAS, ce qui laisse la main pour la maintenance ;
    - le marqueur .rearmement_requis, lui, N'EST JAMAIS SUPPRIME par le
      lanceur : un navire rentre a sec de munitions doit le rester tant que
      l'equipage n'est pas intervenu, meme apres un rechargement de chunk.
--------------------------------------------------------------------------------]]

local CHEMIN_PROGRAMME = "/intercepteur/intercepteur.lua"
local MARQUEUR_ARRET   = "/intercepteur/.arret_manuel"
local DELAI_REBOOT     = 15

term.clear()
term.setCursorPos(1, 1)

if not fs.exists(CHEMIN_PROGRAMME) then
  print("[LANCEUR] Programme introuvable : " .. CHEMIN_PROGRAMME)
  print("[LANCEUR] Installez le systeme embarque puis redemarrez l'ordinateur.")
  return
end

if fs.exists(MARQUEUR_ARRET) then
  pcall(fs.delete, MARQUEUR_ARRET)
end

print("[LANCEUR] Demarrage du systeme embarque intercepteur...")
shell.run(CHEMIN_PROGRAMME)

if fs.exists(MARQUEUR_ARRET) then
  print("[LANCEUR] Arret manuel detecte. Aucun redemarrage automatique.")
  print("[LANCEUR] Relancez avec : " .. CHEMIN_PROGRAMME)
  return
end

print("[LANCEUR] Sortie anormale du systeme embarque.")
print("[LANCEUR] Redemarrage de l'ordinateur dans " .. DELAI_REBOOT .. "s (Ctrl+T pour annuler).")
sleep(DELAI_REBOOT)
os.reboot()
