--[[----------------------------------------------------------------------------
  LANCEUR AUTOMATIQUE - DIRIGEABLE DE LIVRAISON FRENCHNET
  --------------------------------------------------------------------------
  A placer a la RACINE du calculateur embarque (/startup.lua).
  Assure le demarrage du systeme de livraison a chaque allumage, rechargement
  de chunk ou redemarrage du serveur, sans aucune intervention humaine.

  Comportement :
    - lance /navire/livraison.lua ;
    - si le programme rend la main de facon anormale, l'ordinateur redemarre
      apres une temporisation (ultime filet de securite, au-dessus du
      superviseur interne du programme) ;
    - un arret manuel (Ctrl+T) depose le marqueur /navire/.arret_manuel :
      le lanceur ne redemarre alors PAS l'ordinateur, ce qui laisse la main
      pour la maintenance en vol.

  ATTENTION : au redemarrage, le programme relit sa position et rejoint seul
  un point de retour de securite s'il n'y est pas deja. Ne coupez donc pas
  l'ordinateur pendant une livraison en supposant qu'il restera immobile.
--------------------------------------------------------------------------------]]

local CHEMIN_PROGRAMME = "/navire/livraison.lua"
local MARQUEUR_ARRET   = "/navire/.arret_manuel"
local DELAI_REBOOT     = 15

term.clear()
term.setCursorPos(1, 1)

if not fs.exists(CHEMIN_PROGRAMME) then
  print("[LANCEUR] Programme introuvable : " .. CHEMIN_PROGRAMME)
  print("[LANCEUR] Installez le systeme de livraison puis redemarrez.")
  return
end

for _, requis in ipairs({ "/commun/journal.lua", "/commun/protocole.lua",
                          "/commun/inventaire.lua", "/navire/autopilote.lua" }) do
  if not fs.exists(requis) then
    print("[LANCEUR] Fichier manquant : " .. requis)
    print("[LANCEUR] Reprenez l'installation complete (voir README).")
    return
  end
end

-- Le module d'autopilote et sa configuration vehicule appartiennent a l'autre
-- depot : sans eux le navire demarre mais refuse de decoller, et le journal le
-- dit en CRITIQUE. Autant le signaler tout de suite.
for _, requis in ipairs({ "/autopilote/autopilote.lua",
                          "/autopilote/config_vehicule.lua" }) do
  if not fs.exists(requis) then
    print("[LANCEUR] ATTENTION : " .. requis .. " est absent.")
    print("[LANCEUR] Le navire ne pourra pas voler tant qu'il manquera.")
  end
end

if fs.exists(MARQUEUR_ARRET) then
  pcall(fs.delete, MARQUEUR_ARRET)
end

print("[LANCEUR] Demarrage du systeme de livraison FrenchNet...")
shell.run(CHEMIN_PROGRAMME)

-- Ici, le programme a rendu la main : soit arret volontaire, soit anomalie.
if fs.exists(MARQUEUR_ARRET) then
  print("[LANCEUR] Arret manuel detecte. Aucun redemarrage automatique.")
  print("[LANCEUR] Relancez avec : " .. CHEMIN_PROGRAMME)
  return
end

print("[LANCEUR] Sortie anormale du systeme de livraison.")
print("[LANCEUR] Redemarrage de l'ordinateur dans " .. DELAI_REBOOT .. "s (Ctrl+T pour annuler).")
sleep(DELAI_REBOOT)
os.reboot()
