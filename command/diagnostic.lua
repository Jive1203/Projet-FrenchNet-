--[[----------------------------------------------------------------------------
  FRENCHNET - DIAGNOSTIC DE PERIPHERIQUE RADAR
  --------------------------------------------------------------------------
  A lancer sur la station radar (ou sur le poste) quand l'ordinateur ne trouve
  pas le radar, ou quand il le trouve mais n'en tire rien.

      diagnostic            affiche le rapport a l'ecran
      diagnostic sauver     ecrit aussi diagnostic.txt a cote

  Le rapport donne trois choses, dans cet ordre d'utilite :

    1. TOUS les peripheriques visibles, avec TOUS leurs types et TOUTES leurs
       methodes. Si le radar n'apparait pas ici, le probleme est physique :
       le bloc ne touche pas l'ordinateur et n'est pas relie par un modem
       filaire. Aucun reglage logiciel n'y changera quoi que ce soit.

    2. Le resultat de la detection FrenchNet, avec son motif exact.

    3. Pour chaque methode de balayage reconnue, un ECHO BRUT complet : tous
       les champs rendus par le mod, avec leur type. C'est ce qui permet de
       verifier que le systeme lit les bons champs - position, nom,
       proprietaire, equipe - et d'en exploiter davantage.

  Ce rapport est exactement ce qu'il faut coller dans un ticket : il contient
  le nom reel du peripherique, ses methodes reelles et le format reel des
  donnees, c'est-a-dire les trois inconnues du probleme.
--------------------------------------------------------------------------------]]

local ECHANTILLON_MAX = 3      -- echos detailles par methode
local PROFONDEUR_MAX  = 3      -- profondeur d'exploration des tables imbriquees

local function repertoire()
  if shell and shell.getRunningProgram then
    local ok, chemin = pcall(shell.getRunningProgram)
    if ok and chemin then
      local d = fs.getDir(chemin)
      if d and d ~= "" and d ~= "." then return d end
    end
  end
  return ""
end

local CHEMIN_SCANNER = fs.combine(repertoire(), "scanner.lua")
local CHEMIN_RAPPORT = fs.combine(repertoire(), "diagnostic.txt")

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

--------------------------------------------------------------------------------
-- Affichage recursif d'une valeur quelconque, avec son type.
--------------------------------------------------------------------------------
local function decrire(valeur, indentation, profondeur)
  indentation = indentation or "    "
  profondeur = profondeur or 1

  if type(valeur) ~= "table" then
    return string.format("%s (%s)", tostring(valeur), type(valeur))
  end
  if profondeur > PROFONDEUR_MAX then return "{...}" end

  local cles = {}
  for cle in pairs(valeur) do cles[#cles + 1] = tostring(cle) end
  table.sort(cles)

  local morceaux = {}
  for _, cle in ipairs(cles) do
    local v = valeur[cle] ~= nil and valeur[cle] or valeur[tonumber(cle)]
    morceaux[#morceaux + 1] = string.format("%s%s = %s",
      indentation, cle, decrire(v, indentation .. "  ", profondeur + 1))
  end
  if #morceaux == 0 then return "{} (table vide)" end
  return "{\n" .. table.concat(morceaux, "\n") .. "\n" .. indentation:sub(3) .. "}"
end

--------------------------------------------------------------------------------
term.clear()
term.setCursorPos(1, 1)
ligne("DIAGNOSTIC RADAR FRENCHNET")
ligne("ordinateur #" .. os.getComputerID()
  .. (os.getComputerLabel() and (" (" .. os.getComputerLabel() .. ")") or ""))

--------------------------------------------------------------------------------
titre("1. PERIPHERIQUES VISIBLES")

local scanner
do
  local charge = loadfile(CHEMIN_SCANNER)
  if charge then
    local ok, module = pcall(charge)
    if ok and type(module) == "table" then scanner = module end
  end
end

if not scanner then
  ligne("scanner.lua INTROUVABLE a cote de ce programme (" .. CHEMIN_SCANNER .. ").")
  ligne("Copiez command/scanner.lua ici, sinon la station ne peut pas fonctionner.")
end

local noms = peripheral.getNames()
if #noms == 0 then
  ligne("AUCUN peripherique visible.")
  ligne("")
  ligne("C'est un probleme PHYSIQUE, pas un reglage :")
  ligne("  - le radar doit toucher l'ordinateur par une de ses six faces ;")
  ligne("  - ou etre relie par un modem filaire : un modem colle a l'ordinateur,")
  ligne("    un modem colle au radar, du cable entre les deux, et les DEUX modems")
  ligne("    actives d'un clic droit (ils deviennent rouges).")
  ligne("  - un modem sans fil ou Ender ne transporte PAS un peripherique.")
else
  ligne(#noms .. " peripherique(s) :")
  for _, nom in ipairs(noms) do
    local types = scanner and scanner.typesDe(peripheral, nom) or { tostring(peripheral.getType(nom)) }
    local methodes = scanner and scanner.methodesDe(peripheral, nom) or {}
    ligne("")
    ligne("  " .. nom)
    ligne("    types    : " .. (#types > 0 and table.concat(types, ", ") or "?"))
    ligne("    methodes : " .. (#methodes > 0 and table.concat(methodes, ", ") or "aucune"))
  end
end

--------------------------------------------------------------------------------
titre("2. DETECTION FRENCHNET")

local radar, nomRadar, methodes
if scanner then
  local motif
  radar, nomRadar, methodes, motif = scanner.detecter(peripheral, nil)
  ligne(radar and "RESULTAT : radar trouve" or "RESULTAT : ECHEC")
  ligne("motif : " .. tostring(motif))
  if radar then
    ligne("")
    ligne("A reporter dans la configuration :")
    ligne("  peripheriqueRadar = \"" .. nomRadar .. "\",")
  end
else
  ligne("impossible : scanner.lua absent")
end

--------------------------------------------------------------------------------
titre("3. ECHOS BRUTS")

if not radar then
  ligne("Aucun radar detecte : rien a lire.")
  ligne("")
  ligne("Si la section 1 montre un peripherique qui EST votre radar, relevez")
  ligne("le nom de sa methode de balayage et ajoutez-la a scanner.METHODES,")
  ligne("puis relancez ce diagnostic.")
else
  for _, methode in ipairs(methodes) do
    ligne("")
    ligne("-- " .. methode.nom .. "() ------------------------------------")
    local ok, resultat = pcall(function() return radar[methode.nom](radar) end)

    if not ok then
      ligne("  ERREUR a l'appel : " .. tostring(resultat))
    elseif type(resultat) ~= "table" then
      ligne("  ne rend pas une table mais un " .. type(resultat)
        .. " : " .. tostring(resultat))
    elseif #resultat == 0 then
      local vide = true
      for _ in pairs(resultat) do vide = false break end
      if vide then
        ligne("  table vide : aucun contact a portee en ce moment.")
        ligne("  Faites voler quelque chose devant le radar et relancez.")
      else
        ligne("  table sans partie sequentielle. Contenu brut :")
        ligne(decrire(resultat))
      end
    else
      ligne("  " .. #resultat .. " contact(s). Detail des "
        .. math.min(#resultat, ECHANTILLON_MAX) .. " premier(s) :")
      for i = 1, math.min(#resultat, ECHANTILLON_MAX) do
        ligne("")
        ligne("  [" .. i .. "] " .. decrire(resultat[i]))
      end

      -- Lecture FrenchNet du premier echo : c'est ce qui dit si le systeme
      -- comprend le format ou s'il passe a cote.
      local echo = resultat[1]
      if type(echo) == "table" then
        ligne("")
        ligne("  LECTURE FRENCHNET DE CET ECHO :")
        local x, y, z = scanner.positionEcho(echo)
        ligne("    position   : " .. (x and string.format("X=%s Y=%s Z=%s", x, y, z)
          or "NON RECONNUE - le systeme ne saura pas placer ce contact"))
        ligne("    identifiant: " .. tostring(scanner.identifiantEcho(echo)))
        ligne("    nom        : " .. tostring(scanner.nomEcho(echo, "(aucun)")))
        ligne("    nature     : " .. tostring(scanner.natureEcho(echo, methode.nature)))
      end
    end
  end
end

--------------------------------------------------------------------------------
titre("FIN")
ligne("Coordonnees de l'ordinateur a relever avec F3 (ligne 'Block')")
ligne("et a reporter dans 'position' de la configuration.")

local sauver = ({ ... })[1]
if sauver == "sauver" or sauver == "save" then
  local f = fs.open(CHEMIN_RAPPORT, "w")
  if f then
    f.write(table.concat(lignes, "\n"))
    f.close()
    print("")
    print("Rapport ecrit dans " .. CHEMIN_RAPPORT)
  end
else
  print("")
  print("Relancez avec 'diagnostic sauver' pour ecrire le rapport dans un fichier.")
end
