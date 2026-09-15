--[[----------------------------------------------------------------------------
  LANCEUR AUTOMATIQUE - CENTRALE TARIFAIRE FRENCHNET
  --------------------------------------------------------------------------
  A placer a la RACINE de l'ordinateur central (/startup.lua).
  La centrale doit se relancer seule apres un rechargement de chunk ou un
  redemarrage du serveur : tant qu'elle se tait, les navires et les bornes
  continuent d'appliquer la derniere grille recue, mais aucune modification de
  prix ne circule.

  Le marqueur /central/.arret_manuel, depose par Ctrl+T, empeche le
  redemarrage automatique : c'est le mode maintenance.

  L'ecran reste sur l'invite de code : le menu ne s'ouvre pas tout seul apres
  un redemarrage, meme si un operateur l'avait laisse deverrouille.
--------------------------------------------------------------------------------]]

local CHEMIN_PROGRAMME = "/central/central.lua"
local MARQUEUR_ARRET   = "/central/.arret_manuel"
local DELAI_REBOOT     = 10

term.clear()
term.setCursorPos(1, 1)

if not fs.exists(CHEMIN_PROGRAMME) then
  print("[LANCEUR] Programme introuvable : " .. CHEMIN_PROGRAMME)
  print("[LANCEUR] Installez la centrale puis redemarrez l'ordinateur.")
  return
end

for _, requis in ipairs({ "/commun/journal.lua", "/commun/protocole.lua",
                          "/central/config_central.lua" }) do
  if not fs.exists(requis) then
    print("[LANCEUR] Fichier manquant : " .. requis)
    print("[LANCEUR] Reprenez l'installation complete (voir README).")
    return
  end
end

if fs.exists(MARQUEUR_ARRET) then
  pcall(fs.delete, MARQUEUR_ARRET)
end

print("[LANCEUR] Demarrage de la centrale tarifaire...")
shell.run(CHEMIN_PROGRAMME)

if fs.exists(MARQUEUR_ARRET) then
  print("[LANCEUR] Arret manuel detecte. Aucun redemarrage automatique.")
  print("[LANCEUR] Relancez avec : " .. CHEMIN_PROGRAMME)
  return
end

print("[LANCEUR] Sortie anormale de la centrale.")
print("[LANCEUR] Redemarrage dans " .. DELAI_REBOOT .. "s (Ctrl+T pour annuler).")
sleep(DELAI_REBOOT)
os.reboot()
