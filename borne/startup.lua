--[[----------------------------------------------------------------------------
  LANCEUR AUTOMATIQUE - BORNE DE COMMANDE PUBLIQUE FRENCHNET
  --------------------------------------------------------------------------
  A placer a la RACINE de l'ordinateur de la borne (/startup.lua).
  La borne est accessible a tous les joueurs : elle doit se relancer seule
  apres un rechargement de chunk, un redemarrage du serveur ou une
  manipulation malheureuse d'un visiteur.

  Le marqueur /borne/.arret_manuel, depose par la touche Q du menu ou par
  Ctrl+T, empeche le redemarrage automatique : c'est le mode maintenance.
--------------------------------------------------------------------------------]]

local CHEMIN_PROGRAMME = "/borne/borne.lua"
local MARQUEUR_ARRET   = "/borne/.arret_manuel"
local DELAI_REBOOT     = 10

term.clear()
term.setCursorPos(1, 1)

if not fs.exists(CHEMIN_PROGRAMME) then
  print("[LANCEUR] Programme introuvable : " .. CHEMIN_PROGRAMME)
  print("[LANCEUR] Installez la borne puis redemarrez l'ordinateur.")
  return
end

for _, requis in ipairs({ "/commun/journal.lua", "/commun/protocole.lua",
                          "/commun/inventaire.lua", "/borne/config_borne.lua" }) do
  if not fs.exists(requis) then
    print("[LANCEUR] Fichier manquant : " .. requis)
    print("[LANCEUR] Reprenez l'installation complete (voir README).")
    return
  end
end

if fs.exists(MARQUEUR_ARRET) then
  pcall(fs.delete, MARQUEUR_ARRET)
end

print("[LANCEUR] Demarrage de la borne de commande publique...")
shell.run(CHEMIN_PROGRAMME)

if fs.exists(MARQUEUR_ARRET) then
  print("[LANCEUR] Arret manuel detecte. Aucun redemarrage automatique.")
  print("[LANCEUR] Relancez avec : " .. CHEMIN_PROGRAMME)
  return
end

print("[LANCEUR] Sortie anormale de la borne.")
print("[LANCEUR] Redemarrage dans " .. DELAI_REBOOT .. "s (Ctrl+T pour annuler).")
sleep(DELAI_REBOOT)
os.reboot()
