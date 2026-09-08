--[[----------------------------------------------------------------------------
  LANCEUR AUTOMATIQUE - VEHICULE AERIEN FRENCHNET
  --------------------------------------------------------------------------
  A placer a la RACINE de l'ordinateur du vehicule (/startup.lua).
  Assure le demarrage a chaque allumage, rechargement de chunk ou redemarrage
  du serveur, sans aucune intervention humaine.

  Comportement :
    - si /autopilote/mission.lua existe, c'est LUI qui est lance : c'est le
      programme de mission du vehicule (livraison, scramble, patrouille...) ;
    - sinon, l'autopilote est lance en veille : il relit sa position, reprend
      une eventuelle mission interrompue par un plantage, et se contente
      sinon de tenir sa position en attendant un ordre ;
    - si le programme rend la main de facon anormale, l'ordinateur redemarre
      apres une temporisation (ultime filet de securite) ;
    - un arret manuel (Ctrl+T) depose le marqueur /autopilote/.arret_manuel :
      le lanceur ne redemarre alors PAS, ce qui laisse la main pour la
      maintenance au sol.
--------------------------------------------------------------------------------]]

local CHEMIN_MODULE  = "/autopilote/autopilote.lua"
local CHEMIN_MISSION = "/autopilote/mission.lua"
local MARQUEUR_ARRET = "/autopilote/.arret_manuel"
local DELAI_REBOOT   = 15

term.clear()
term.setCursorPos(1, 1)
print("=== FRENCHNET - AUTOPILOTE (AERONAUTICS WARFARE) ===")

if not fs.exists(CHEMIN_MODULE) then
  printError("[LANCEUR] Module introuvable : " .. CHEMIN_MODULE)
  print("[LANCEUR] Installez l'autopilote puis redemarrez l'ordinateur.")
  return
end

if fs.exists(MARQUEUR_ARRET) then pcall(fs.delete, MARQUEUR_ARRET) end

--- Veille : aucune mission propre, mais un vehicule qui reste pilotable.
local function veille()
  local autopilote = dofile(CHEMIN_MODULE)
  local ap = autopilote.nouveau()
  ap.initialiser()          -- relit la position AVANT tout mouvement
  ap.maintenirPosition()    -- ne bouge pas tant qu'aucun ordre n'arrive
  ap.executer()             -- reprend seule une mission interrompue
end

local ok, err
if fs.exists(CHEMIN_MISSION) then
  print("[LANCEUR] Demarrage du programme de mission : " .. CHEMIN_MISSION)
  ok, err = pcall(shell.run, CHEMIN_MISSION)
else
  print("[LANCEUR] Aucun programme de mission : autopilote en veille.")
  ok, err = pcall(veille)
end

-- Arret manuel : on rend la main sans redemarrer.
local estArretManuel = (not ok) and type(err) == "string"
  and (err == "Terminated" or err:match("^Terminated\n") ~= nil)

if estArretManuel then
  local fichier = fs.open(MARQUEUR_ARRET, "w")
  if fichier then
    fichier.writeLine(tostring(os.day()))
    fichier.close()
  end
  print("[LANCEUR] Arret manuel detecte. Aucun redemarrage automatique.")
  return
end

if not ok then
  printError("[LANCEUR] Sortie anormale : " .. tostring(err))
else
  print("[LANCEUR] Le programme a rendu la main.")
end

print("[LANCEUR] Redemarrage dans " .. DELAI_REBOOT .. "s (Ctrl+T pour annuler).")
sleep(DELAI_REBOOT)
os.reboot()
