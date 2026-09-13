--[[----------------------------------------------------------------------------
  CLASSEMENT DES PERIPHERIQUES - CONSOLE OPERATEUR
  --------------------------------------------------------------------------
  A lancer des que la calibration refuse de demarrer en signalant des
  peripheriques inconnus.

  Pourquoi une intervention humaine est indispensable
  ---------------------------------------------------
  Le systeme reconnait seul les blocs qu'il connait : modems, moniteurs,
  integrateurs redstone, inventaires, capteurs usuels. Face a un bloc d'un mod
  qu'il n'a jamais vu, il n'a que deux choix : deviner, ou demander. Deviner
  reviendrait a envoyer du courant dedans pour observer ce qui se passe --
  inacceptable quand le bloc peut etre une batterie de canons. Il demande donc,
  et refuse d'y toucher en attendant.

  Ce que fait ce programme :
    - liste les peripheriques du bord et leur classe actuelle ;
    - presente les classes une par une, avec ce que chacune autorise ;
    - fait remplir les champs propres a la classe choisie ;
    - ecrit le registre, et reporte dans la configuration du vehicule ce qui
      peut l'etre (capteur de cap, capteur sol, jauge, commande par methode).

  Usage :  classer
--------------------------------------------------------------------------------]]

local autopilote    = dofile("/autopilote/autopilote.lua")
local peripheriques = dofile("/autopilote/peripheriques.lua")

--------------------------------------------------------------------------------
-- AFFICHAGE ET SAISIE
--------------------------------------------------------------------------------

local function encre(c)
  if term.isColour and term.isColour() then pcall(term.setTextColour, c) end
end

local function titre(texte)
  encre(colors.yellow)
  print("")
  print("== " .. texte .. " ==")
  encre(colors.white)
end

--- Decoupe un texte a la largeur du terminal, sans couper les mots.
local function paragraphe(texte, indentation)
  indentation = indentation or ""
  local largeur = (term.getSize() or 51) - #indentation - 1
  local ligne = ""
  for mot in tostring(texte):gmatch("%S+") do
    if #ligne + #mot + 1 > largeur then
      print(indentation .. ligne)
      ligne = mot
    else
      ligne = (ligne == "") and mot or (ligne .. " " .. mot)
    end
  end
  if ligne ~= "" then print(indentation .. ligne) end
end

local function pause()
  encre(colors.lightGray)
  write("-- Entree pour continuer --")
  encre(colors.white)
  read()
end

local function demander(question, defaut)
  encre(colors.lightBlue)
  if defaut ~= nil and defaut ~= "" then
    write(question .. " [" .. tostring(defaut) .. "] : ")
  else
    write(question .. " : ")
  end
  encre(colors.white)
  local reponse = read()
  if reponse == nil or reponse == "" then return defaut end
  return reponse
end

local function ouiNon(question, defaut)
  while true do
    local reponse = tostring(demander(question .. " (oui/non)",
      defaut and "oui" or "non")):lower()
    if reponse == "oui" or reponse == "o" then return true end
    if reponse == "non" or reponse == "n" then return false end
    print("Repondez par oui ou non.")
  end
end

--------------------------------------------------------------------------------
-- CATALOGUE DES CLASSES
--------------------------------------------------------------------------------

local function afficherCatalogue(detaille)
  titre("CLASSES DISPONIBLES")
  for index, classe in ipairs(peripheriques.CLASSES) do
    encre(classe.ecrivable and colors.orange or colors.white)
    print(string.format("%2d. %s%s", index, classe.libelle,
      classe.ecrivable and "  (l'autopilote peut ecrire dessus)" or ""))
    encre(colors.lightGray)
    paragraphe(classe.description, "    ")
    if detaille then
      paragraphe("Role : " .. classe.role, "    ")
      if classe.cible then
        paragraphe("Remplit : config." .. classe.cible, "    ")
      end
    end
    encre(colors.white)
  end
end

--------------------------------------------------------------------------------
-- REMPLISSAGE D'UNE FICHE
--------------------------------------------------------------------------------

local function saisirChamp(definition)
  while true do
    if definition.genre == "booleen" then
      return ouiNon(definition.question, definition.defaut and true or false)
    end

    local brut = demander(definition.question, definition.defaut)
    if brut == nil or brut == "" then
      if definition.facultatif then return nil end
      if definition.defaut ~= nil then return definition.defaut end
      print("Ce champ est obligatoire.")
    elseif definition.genre == "nombre" then
      local valeur = tonumber(brut)
      if valeur then return valeur end
      print("Saisissez un nombre.")
    elseif definition.genre == "liste" then
      local liste = {}
      for morceau in tostring(brut):gmatch("[^,%s]+") do liste[#liste + 1] = morceau end
      return liste
    else
      return brut
    end
  end
end

--- @return true si une fiche a ete enregistree
local function classer(fiche, registre)
  titre("PERIPHERIQUE : " .. fiche.nom)
  print("Type declare par le jeu : " .. tostring(fiche.type))
  if fiche.motif then
    encre(colors.lightGray)
    paragraphe("Motif : " .. fiche.motif)
    encre(colors.white)
  end

  local methodes = fiche.methodes or {}
  encre(colors.lightGray)
  if #methodes > 0 then
    paragraphe("Methodes exposees : " .. table.concat(methodes, ", "))
  else
    print("Aucune methode exposee.")
  end
  encre(colors.white)

  afficherCatalogue(false)

  local choix
  while true do
    local brut = demander("Numero de classe pour '" .. fiche.nom .. "' (0 = passer)")
    local numero = tonumber(brut)
    if numero == 0 then return false end
    if numero and peripheriques.CLASSES[numero] then
      choix = peripheriques.CLASSES[numero]
      break
    end
    print("Numero invalide.")
  end

  encre(colors.yellow)
  print("Classe retenue : " .. choix.libelle)
  encre(colors.lightGray)
  paragraphe(choix.role)
  encre(colors.white)

  local details = {}
  for _, definition in ipairs(choix.champs) do
    details[definition.nom] = saisirChamp(definition)
  end

  local nouvelle = {
    nom = fiche.nom, classe = choix.code, details = details,
    note = demander("Note libre (facultatif)", "") or "",
  }

  local valide, anomalies = peripheriques.validerFiche(nouvelle)
  if not valide then
    encre(colors.red)
    print("Fiche refusee :")
    for _, anomalie in ipairs(anomalies) do paragraphe("- " .. anomalie) end
    encre(colors.white)
    return false
  end

  registre.fiches[fiche.nom] = nouvelle
  encre(colors.lime)
  print("Enregistre : " .. fiche.nom .. " -> " .. choix.code)
  encre(colors.white)
  return true
end

--------------------------------------------------------------------------------
-- INVENTAIRE
--------------------------------------------------------------------------------

local function afficherInventaire(inventaire)
  titre("INVENTAIRE DE BORD")
  if #inventaire.ordre == 0 then
    print("Aucun peripherique detecte.")
    return
  end
  for _, nom in ipairs(inventaire.ordre) do
    local fiche = inventaire.fiches[nom]
    if fiche.classe then
      encre(fiche.origine == "operateur" and colors.lime or colors.white)
      print(string.format("%-16s %s", nom:sub(1, 16), fiche.classe))
      encre(colors.lightGray)
      print(string.format("   type %s (%s)", tostring(fiche.type), fiche.origine))
    else
      encre(colors.red)
      print(string.format("%-16s QUARANTAINE", nom:sub(1, 16)))
      encre(colors.lightGray)
      print(string.format("   type %s", tostring(fiche.type)))
    end
    encre(colors.white)
  end
end

--------------------------------------------------------------------------------
-- ENREGISTREMENT
--------------------------------------------------------------------------------

local function enregistrer(registre)
  local ok, err = pcall(peripheriques.enregistrer,
    peripheriques.CHEMIN_REGISTRE, registre)
  if not ok then
    encre(colors.red)
    print("ECHEC d'ecriture du registre : " .. tostring(err))
    encre(colors.white)
    return false
  end
  encre(colors.lime)
  print("Registre ecrit : " .. peripheriques.CHEMIN_REGISTRE)
  encre(colors.white)

  -- Report dans la configuration du vehicule de ce qui peut l'etre : un capteur
  -- de cap classe ne sert a rien s'il reste dans un registre que l'autopilote
  -- ne consulte pas au moment de lire son cap.
  local okConfig, config = pcall(autopilote.chargerConfiguration)
  if not okConfig then
    encre(colors.orange)
    paragraphe("Configuration vehicule illisible : le registre est enregistre, "
      .. "mais rien n'a pu y etre reporte. " .. tostring(config))
    encre(colors.white)
    return true
  end

  local inventaire = peripheriques.inventorier(registre)
  local appliques = peripheriques.appliquerA(config, inventaire)
  if #appliques == 0 then
    print("Rien a reporter dans la configuration du vehicule.")
    return true
  end

  titre("REPORT DANS LA CONFIGURATION")
  for _, ligne in ipairs(appliques) do paragraphe("- " .. ligne) end

  if not ouiNon("Ecrire ces reglages dans config_vehicule.lua ?", true) then
    print("Configuration laissee inchangee.")
    return true
  end

  local fichier = fs.open(autopilote.CHEMIN_CONFIG_DEFAUT, "w")
  if not fichier then
    encre(colors.red)
    print("Ecriture impossible : " .. autopilote.CHEMIN_CONFIG_DEFAUT)
    encre(colors.white)
    return false
  end
  fichier.write(autopilote.serialiserConfig(config))
  fichier.close()
  encre(colors.lime)
  print("Configuration mise a jour : " .. autopilote.CHEMIN_CONFIG_DEFAUT)
  encre(colors.white)
  return true
end

--------------------------------------------------------------------------------
-- PROGRAMME
--------------------------------------------------------------------------------

local function principal()
  term.clear()
  term.setCursorPos(1, 1)
  encre(colors.yellow)
  print("=== FRENCHNET // CLASSEMENT DES PERIPHERIQUES ===")
  encre(colors.white)
  print("Ordinateur #" .. os.getComputerID())

  local registre, erreur = peripheriques.charger(peripheriques.CHEMIN_REGISTRE)
  if erreur then
    encre(colors.red)
    paragraphe(erreur)
    encre(colors.white)
  end

  local modifie = false

  while true do
    local inventaire = peripheriques.inventorier(registre)
    local enQuarantaine = #inventaire.quarantaine

    titre("MENU")
    encre(enQuarantaine > 0 and colors.red or colors.lime)
    print(string.format("%d peripherique(s) en quarantaine", enQuarantaine))
    encre(colors.white)
    print("1. Classer les peripheriques inconnus")
    print("2. Voir l'inventaire complet")
    print("3. Reclasser un peripherique deja classe")
    print("4. Lire le catalogue des classes en detail")
    print("5. Enregistrer et quitter")
    print("6. Quitter sans enregistrer")

    local choix = demander("Votre choix", "1")

    if choix == "1" then
      if enQuarantaine == 0 then
        print("Rien en quarantaine : tous les peripheriques sont classes.")
      else
        for _, fiche in ipairs(inventaire.quarantaine) do
          if classer(fiche, registre) then modifie = true end
        end
      end
      pause()

    elseif choix == "2" then
      afficherInventaire(inventaire)
      pause()

    elseif choix == "3" then
      afficherInventaire(inventaire)
      local nom = demander("Nom du peripherique a reclasser")
      local fiche = nom and inventaire.fiches[nom]
      if fiche then
        if classer(fiche, registre) then modifie = true end
      else
        print("Peripherique introuvable : " .. tostring(nom))
      end
      pause()

    elseif choix == "4" then
      afficherCatalogue(true)
      pause()

    elseif choix == "5" then
      if modifie then enregistrer(registre) else print("Aucune modification.") end
      return

    elseif choix == "6" then
      if not modifie then return end
      if ouiNon("Des modifications seront perdues. Quitter quand meme ?", false) then
        return
      end

    else
      print("Choix inconnu.")
    end
  end
end

local ok, err = pcall(principal)
if not ok and tostring(err):find("Terminated", 1, true) == nil then
  encre(colors.red)
  print("Console interrompue : " .. tostring(err))
  encre(colors.white)
end
