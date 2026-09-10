--[[----------------------------------------------------------------------------
  DOOMSDAY SHIP - DIAGNOSTIC DE BORD
  --------------------------------------------------------------------------
      diagnostic          affiche le rapport
      diagnostic sauver   l'ecrit aussi dans diagnostic.txt

  A LANCER AVANT TOUT REGLAGE. Le catalogue de mesures du HAL contient des noms
  de methode PLAUSIBLES, pas certains : je ne connais pas l'API de Create
  Aeronautics. Ce rapport est ce qui transforme ces suppositions en certitudes.

  Il donne, dans cet ordre :
    1. les peripheriques reels, leurs types, leurs methodes ;
    2. les mesures que le HAL a su lier tout seul, et celles qu'il n'a pas su ;
    3. un ECHANTILLON de valeur pour chaque methode sans argument, ce qui
       permet de voir immediatement laquelle donne quoi ;
    4. l'etat des modules exterieurs - autopilote, Fire Control, ADS.

  Ce rapport est exactement ce qu'il faut coller dans un ticket.
--------------------------------------------------------------------------------]]

local function repertoire()
  if shell and shell.getRunningProgram then
    local ok, chemin = pcall(shell.getRunningProgram)
    if ok and chemin then
      local d = fs.getDir(chemin)
      if d and d ~= "" and d ~= "." then return d end
    end
  end
  return "vaisseau"
end

local REPERTOIRE = repertoire()
local lignes = {}

local function ligne(texte)
  texte = tostring(texte or "")
  lignes[#lignes + 1] = texte
  print(texte)
end

local function titre(texte)
  ligne("")
  ligne("== " .. texte .. " " .. string.rep("=", math.max(0, 44 - #texte)))
end

local function module(nom)
  local charge = loadfile(fs.combine(REPERTOIRE, nom))
  if not charge then return nil end
  local ok, m = pcall(charge)
  return ok and m or nil
end

term.clear() term.setCursorPos(1, 1)
ligne("DIAGNOSTIC DE BORD - DOOMSDAY SHIP")
ligne("ordinateur #" .. os.getComputerID()
  .. (os.getComputerLabel() and (" (" .. os.getComputerLabel() .. ")") or ""))

local halModule      = module("hal.lua")
local liaisonsModule = module("liaisons.lua")
local cfg = module("config_vaisseau.lua") or {}

--------------------------------------------------------------------------------
titre("1. PERIPHERIQUES DU BALLON")

if not halModule then
  ligne("hal.lua INTROUVABLE : le systeme ne peut pas demarrer.")
else
  local hal = halModule.nouveau(cfg, peripheral, function() end)
  local inventaire = hal:dresserInventaire()

  if #inventaire == 0 then
    ligne("AUCUN peripherique visible.")
    ligne("")
    ligne("C'est un probleme PHYSIQUE, pas un reglage :")
    ligne("  - le bloc doit toucher l'ordinateur par une de ses six faces ;")
    ligne("  - ou etre relie par un modem FILAIRE : un modem colle a chaque")
    ligne("    bloc, du cable entre les deux, et les DEUX modems actives d'un")
    ligne("    clic droit (ils deviennent rouges).")
    ligne("  - un modem sans fil ou Ender ne transporte PAS un peripherique.")
  else
    ligne(#inventaire .. " peripherique(s) :")
    for _, p in ipairs(inventaire) do
      ligne("")
      ligne("  " .. p.nom)
      ligne("    types    : " .. (#p.types > 0 and table.concat(p.types, ", ") or "?"))
      ligne("    methodes : " .. (#p.methodes > 0 and table.concat(p.methodes, ", ")
        or "aucune"))
    end
  end

  --------------------------------------------------------------------------------
  titre("2. MESURES")

  local liees, manquantes = hal:decouvrir()
  ligne(string.format("%d liee(s), %d manquante(s)", liees, manquantes))

  local cles = {}
  for cle in pairs(halModule.MESURES) do cles[#cles + 1] = cle end
  table.sort(cles)

  ligne("")
  ligne("LIEES :")
  local aucune = true
  for _, cle in ipairs(cles) do
    local liaison = hal.liaisons[cle]
    if liaison then
      aucune = false
      local valeur, motif = hal:lire(cle)
      ligne(string.format("  %-26s %s.%s() = %s",
        cle, liaison.peripherique, liaison.methode,
        valeur and string.format("%.2f", valeur) or ("nil (" .. tostring(motif) .. ")")))
    end
  end
  if aucune then ligne("  aucune") end

  ligne("")
  ligne("MANQUANTES (les pages afficheront INDISPO) :")
  aucune = true
  for _, cle in ipairs(cles) do
    if hal.manquantes[cle] then
      aucune = false
      ligne(string.format("  %-26s %s", cle, hal.manquantes[cle]))
    end
  end
  if aucune then ligne("  aucune") end

  --------------------------------------------------------------------------------
  titre("3. ECHANTILLON DE CHAQUE METHODE")
  ligne("Appel sans argument. C'est ce tableau qui dit quelle methode donne")
  ligne("quelle grandeur - et donc quoi mettre dans 'mesures' de la config.")

  for _, p in ipairs(inventaire) do
    if #p.methodes > 0 then
      ligne("")
      ligne("  " .. p.nom)
      for _, methode in ipairs(p.methodes) do
        local ok, valeur = pcall(peripheral.call, p.nom, methode)
        local rendu
        if not ok then
          rendu = "erreur : " .. tostring(valeur):sub(1, 40)
        elseif type(valeur) == "table" then
          local champs = {}
          for cle, v in pairs(valeur) do
            if type(v) ~= "table" and type(v) ~= "function" then
              champs[#champs + 1] = tostring(cle) .. "=" .. tostring(v)
            end
            if #champs >= 4 then break end
          end
          rendu = "table { " .. table.concat(champs, ", ") .. " }"
        else
          rendu = tostring(valeur) .. " (" .. type(valeur) .. ")"
        end
        ligne(string.format("    %-24s -> %s", methode .. "()", rendu))
      end
    end
  end
end

--------------------------------------------------------------------------------
titre("4. MODULES EXTERIEURS")

if not liaisonsModule then
  ligne("liaisons.lua INTROUVABLE.")
else
  local liaisons = liaisonsModule.nouveau(cfg, function() end)
  liaisons:charger()
  for _, l in ipairs(liaisons:rapport()) do
    ligne(string.format("  %-12s %-8s %s", l.module, l.statut, l.detail))
  end
  ligne("")
  ligne("Un module ABSENT n'est pas une panne : c'est un module qui n'existe")
  ligne("pas encore dans le depot. Les pages concernees affichent l'absence")
  ligne("au lieu de simuler une integration. Voir docs/api_notes.md.")
end

--------------------------------------------------------------------------------
titre("5. RESEAU")
ligne("HTTP sortant : " .. (http and "DISPONIBLE" or "DESACTIVE sur ce serveur"))
if not http then
  ligne("  -> le module musique de la phase 4 sera impossible tel que specifie.")
end
local modem = false
for _, nom in ipairs(peripheral.getNames()) do
  if peripheral.getType(nom) == "modem" then modem = true end
end
ligne("Modem : " .. (modem and "present" or
  "ABSENT - le ballon sera invisible de FrenchNet et classe INCONNU"))
ligne("GPS : " .. ((gps.locate(2, false)) and "position acquise" or
  "AUCUNE position - constellation de balises hors de portee"))

--------------------------------------------------------------------------------
titre("FIN")
ligne("Relevez les coordonnees du ballon avec F3 si le GPS est absent.")

local argument = ({ ... })[1]
if argument == "sauver" or argument == "save" then
  local f = fs.open(fs.combine(REPERTOIRE, "diagnostic.txt"), "w")
  if f then
    f.write(table.concat(lignes, "\n"))
    f.close()
    print("")
    print("Rapport ecrit dans " .. fs.combine(REPERTOIRE, "diagnostic.txt"))
  end
else
  print("")
  print("Relancez avec 'diagnostic sauver' pour ecrire le rapport dans un fichier.")
end
