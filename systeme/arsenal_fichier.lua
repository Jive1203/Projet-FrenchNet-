--[[----------------------------------------------------------------------------
  FRENCHNET OS - Fichier d'arsenal
  --------------------------------------------------------------------------
  Lecture et ECRITURE de intercepteur/config_armement.lua, le fichier que la
  page Armement du systeme d'exploitation edite en jeu.

  Pourquoi un fichier separe de config_intercepteur.lua ? Parce qu'un
  programme qui reecrit un fichier ecrit a la main finit toujours par en
  perdre les commentaires ou par en abimer une section. L'arsenal, lui, est
  entierement gere par la page Armement : il peut donc etre regenere en
  entier sans rien perdre. config_intercepteur.lua reste intact et fournit
  l'arsenal par defaut tant que ce fichier-ci n'existe pas.

  Le fichier produit reste lisible et modifiable a la main : sections,
  commentaires et alignement sont regeneres, pas serialises a la va-vite.
--------------------------------------------------------------------------------]]

local M = {}

M.CHEMIN = "/intercepteur/config_armement.lua"

M.UTILITES = { "anti-aerien", "anti-sol", "defensif", "polyvalent" }
M.MODES    = { "peripherique", "redstone", "mixte" }
M.COTES    = { "back", "front", "left", "right", "top", "bottom" }

--- Description de chaque champ editable : libelle, type, bornes, aide.
-- C'est cette table qui pilote entierement la page Armement : ajouter un
-- champ ici l'ajoute a l'ecran, a la validation et au fichier ecrit.
M.CHAMPS = {
  { cle = "identifiant", libelle = "Identifiant",     type = "texte",
    aide = "Nom court et unique, repris dans le journal a chaque tir." },
  { cle = "nom",         libelle = "Designation",     type = "texte",
    aide = "Libelle libre, purement informatif." },
  { cle = "utilite",     libelle = "Utilite",         type = "liste", valeurs = M.UTILITES,
    aide = "Une arme polyvalente repond a tout besoin ; une specialisee passe "
        .. "avant elle sur le sien." },
  { cle = "mode",        libelle = "Mise a feu",      type = "liste", valeurs = M.MODES,
    aide = "peripherique = affut pilotable ; redstone = signal ; mixte = les deux." },
  { cle = "coteArme",    libelle = "Cote de l'affut", type = "texte", vide = true,
    aide = "Vide = premier affut libre detecte automatiquement." },
  { cle = "coteRedstone",libelle = "Cote redstone",   type = "liste", valeurs = M.COTES,
    vide = true, aide = "Obligatoire en mise a feu redstone ou mixte." },
  { cle = "porteeMini",  libelle = "Portee mini",     type = "nombre", mini = 0, maxi = 5000,
    unite = "blocs", aide = "En deca, l'arme n'est pas retenue." },
  { cle = "porteeMaxi",  libelle = "Portee maxi",     type = "nombre", mini = 1, maxi = 5000,
    unite = "blocs", aide = "Au-dela, l'arme n'est pas retenue. Le navire tient "
        .. "le CENTRE de la fenetre sous ordre de feu." },
  { cle = "vitesseObus", libelle = "Vitesse obus",    type = "nombre", mini = 1, maxi = 1000,
    unite = "b/s", aide = "A MESURER sur votre serveur : depend de la charge et "
        .. "du calibre." },
  { cle = "graviteObus", libelle = "Gravite obus",    type = "nombre", mini = 0, maxi = 100,
    unite = "b/s2", aide = "Chute compensee par l'elevation de l'affut." },
  { cle = "dureeRafale", libelle = "Duree de rafale", type = "nombre", mini = 0.1, maxi = 30,
    unite = "s", aide = "Une rafale continue chauffe sans gagner en precision." },
  { cle = "pauseRafale", libelle = "Pause entre rafales", type = "nombre", mini = 0, maxi = 60,
    unite = "s" },
  { cle = "tangageMini", libelle = "Tangage mini",    type = "nombre", mini = -90, maxi = 0,
    unite = "deg", aide = "Debattement bas de l'affut." },
  { cle = "tangageMaxi", libelle = "Tangage maxi",    type = "nombre", mini = 0, maxi = 90,
    unite = "deg", aide = "Debattement haut de l'affut." },
  { cle = "actif",       libelle = "Armee",           type = "booleen",
    aide = "Une arme non armee reste declaree mais n'est jamais choisie." },
  { cle = "note",        libelle = "Note",            type = "texte", vide = true,
    aide = "Aide-memoire pour l'equipage." },
}

M.DEFAUTS_ARME = {
  identifiant = "ARME", nom = "Nouvelle arme", utilite = "polyvalent",
  mode = "peripherique", coteArme = nil, coteRedstone = nil,
  porteeMini = 80, porteeMaxi = 400, vitesseObus = 80, graviteObus = 9.8,
  dureeRafale = 1.5, pauseRafale = 2.0, tangageMini = -60, tangageMaxi = 60,
  actif = true, note = nil,
}

M.DEFAUTS_ARSENAL = {
  toleranceViseeDeg = 3,
  prioriteTirSurPosition = true,
  besoinParDefaut = "anti-aerien",
  margeAltitudeSol = 12,
}

--------------------------------------------------------------------------------
-- 1. LECTURE
--------------------------------------------------------------------------------

local function chargerTable(chemin)
  if not fs.exists(chemin) then return nil, "fichier absent" end
  local fichier = fs.open(chemin, "r")
  if not fichier then return nil, "lecture impossible" end
  local source = fichier.readAll()
  fichier.close()
  local morceau, err = load(source, "@" .. chemin, "t", _G)
  if not morceau then return nil, "syntaxe Lua : " .. tostring(err) end
  local ok, resultat = pcall(morceau)
  if not ok then return nil, tostring(resultat) end
  if type(resultat) ~= "table" then return nil, "le fichier doit finir par 'return { ... }'" end
  return resultat
end

--- Charge l'arsenal. Ordre de priorite :
--   1. /intercepteur/config_armement.lua (edite par cette page)
--   2. le bloc 'arme' de /intercepteur/config_intercepteur.lua
--   3. un arsenal vide
-- @return arsenal, source (chaine decrivant d'ou il vient)
function M.charger()
  local arsenal, err = chargerTable(M.CHEMIN)
  local source = M.CHEMIN

  if not arsenal then
    local principale = chargerTable("/intercepteur/config_intercepteur.lua")
    if principale and type(principale.arme) == "table" then
      arsenal = principale.arme
      source = "/intercepteur/config_intercepteur.lua (bloc 'arme')"
    end
  end

  if not arsenal then
    arsenal = {}
    source = "aucun (arsenal vide)"
  end

  for cle, valeur in pairs(M.DEFAUTS_ARSENAL) do
    if arsenal[cle] == nil then arsenal[cle] = valeur end
  end
  if type(arsenal.armes) ~= "table" then arsenal.armes = {} end

  -- Completion de chaque arme : la page doit pouvoir afficher tous les champs
  -- meme sur une declaration minimale ecrite a la main.
  for _, arme in ipairs(arsenal.armes) do
    for cle, valeur in pairs(M.DEFAUTS_ARME) do
      if arme[cle] == nil and valeur ~= nil then arme[cle] = valeur end
    end
  end

  return arsenal, source, err
end

function M.nouvelleArme(numero)
  local arme = {}
  for cle, valeur in pairs(M.DEFAUTS_ARME) do arme[cle] = valeur end
  arme.identifiant = string.format("ARME-%02d", numero or 1)
  arme.nom = "Nouvelle arme"
  return arme
end

--------------------------------------------------------------------------------
-- 2. VALIDATION
--    Les memes regles que intercepteur/armement.lua, verifiees AVANT
--    l'ecriture : mieux vaut refuser une saisie a l'ecran que laisser le
--    navire decouvrir le probleme au decollage.
--------------------------------------------------------------------------------

function M.verifier(arsenal)
  local anomalies = {}

  if #arsenal.armes == 0 then
    anomalies[#anomalies + 1] = "aucune arme declaree : le navire ne pourra pas engager"
  end

  local identifiants = {}
  for indice, arme in ipairs(arsenal.armes) do
    local prefixe = string.format("arme %d (%s)", indice, tostring(arme.identifiant))

    if type(arme.identifiant) ~= "string" or arme.identifiant == "" then
      anomalies[#anomalies + 1] = prefixe .. " : identifiant vide"
    elseif identifiants[arme.identifiant] then
      anomalies[#anomalies + 1] = prefixe .. " : identifiant deja utilise par l'arme "
        .. identifiants[arme.identifiant]
    else
      identifiants[arme.identifiant] = indice
    end

    local utiliteConnue = false
    for _, u in ipairs(M.UTILITES) do
      if arme.utilite == u then utiliteConnue = true break end
    end
    if not utiliteConnue then
      anomalies[#anomalies + 1] = prefixe .. " : utilite '" .. tostring(arme.utilite)
        .. "' inconnue"
    end

    if type(arme.porteeMini) ~= "number" or type(arme.porteeMaxi) ~= "number"
       or arme.porteeMini >= arme.porteeMaxi then
      anomalies[#anomalies + 1] = prefixe .. " : portee mini doit etre "
        .. "strictement inferieure a la portee maxi"
    end

    if (arme.mode == "redstone" or arme.mode == "mixte")
       and (type(arme.coteRedstone) ~= "string" or arme.coteRedstone == "") then
      anomalies[#anomalies + 1] = prefixe .. " : mise a feu " .. tostring(arme.mode)
        .. " sans cote redstone"
    end

    if type(arme.vitesseObus) ~= "number" or arme.vitesseObus <= 0 then
      anomalies[#anomalies + 1] = prefixe .. " : vitesse d'obus invalide"
    end
  end

  -- Avertissement, pas une anomalie bloquante : un navire peut embarquer des
  -- armes toutes desactivees le temps d'un convoyage.
  local armees = 0
  for _, arme in ipairs(arsenal.armes) do
    if arme.actif then armees = armees + 1 end
  end

  return anomalies, armees
end

--- Couverture de portee : signale les trous entre les fenetres des armes.
-- C'est l'information qui manque le plus souvent a l'equipage : savoir qu'a
-- 250 blocs, aucune arme du bord ne repond.
function M.couverture(arsenal, besoin)
  besoin = besoin or "anti-aerien"
  local fenetres = {}
  for _, arme in ipairs(arsenal.armes) do
    local repond = (arme.utilite == besoin or arme.utilite == "polyvalent")
    if arme.actif and repond then
      fenetres[#fenetres + 1] = { mini = arme.porteeMini, maxi = arme.porteeMaxi,
        nom = arme.identifiant }
    end
  end
  table.sort(fenetres, function(a, b) return a.mini < b.mini end)

  local trous, couvertJusqua = {}, nil
  for _, fenetre in ipairs(fenetres) do
    if couvertJusqua == nil then
      couvertJusqua = fenetre.maxi
    elseif fenetre.mini > couvertJusqua then
      trous[#trous + 1] = { de = couvertJusqua, a = fenetre.mini }
      couvertJusqua = fenetre.maxi
    else
      couvertJusqua = math.max(couvertJusqua, fenetre.maxi)
    end
  end

  local mini = fenetres[1] and fenetres[1].mini or nil
  return { fenetres = fenetres, trous = trous, mini = mini, maxi = couvertJusqua }
end

--------------------------------------------------------------------------------
-- 3. ECRITURE
--------------------------------------------------------------------------------

local function litteral(valeur)
  if type(valeur) == "string" then return string.format("%q", valeur) end
  if type(valeur) == "boolean" then return tostring(valeur) end
  if type(valeur) == "number" then
    if valeur == math.floor(valeur) and math.abs(valeur) < 1e14 then
      return string.format("%d", valeur)
    end
    return (string.format("%.4f", valeur):gsub("0+$", ""):gsub("%.$", ""))
  end
  return "nil"
end

--- Regenere le fichier d'arsenal, commentaires compris.
-- @return true | false, message
function M.enregistrer(arsenal)
  local lignes = {}
  local function ajouter(texte) lignes[#lignes + 1] = texte or "" end

  ajouter("--[[----------------------------------------------------------------------------")
  ajouter("  ARSENAL DU NAVIRE - FRENCHNET / AERONAUTICS WARFARE")
  ajouter("  --------------------------------------------------------------------------")
  ajouter("  FICHIER GENERE par la page Armement du systeme d'exploitation de bord.")
  ajouter("  Il reste parfaitement modifiable a la main : la page le relit tel quel.")
  ajouter("")
  ajouter("  Il remplace le bloc 'arme' de config_intercepteur.lua des qu'il existe.")
  ajouter("  Supprimez-le pour revenir a l'arsenal declare dans la configuration.")
  ajouter("")
  ajouter("  utilite : anti-aerien | anti-sol | defensif | polyvalent")
  ajouter("            une arme polyvalente repond a tout besoin ; une specialisee")
  ajouter("            passe avant elle sur le sien.")
  ajouter("  mode    : peripherique (affut pilotable) | redstone | mixte")
  ajouter("  portees : fenetre d'emploi en blocs. Sous ordre de feu, le navire tient")
  ajouter("            le CENTRE de la fenetre de l'arme retenue.")
  ajouter("")
  ajouter("  Ecrit le " .. tostring(os.date and os.date("!%Y-%m-%d %H:%M:%S") or "?"))
  ajouter("--------------------------------------------------------------------------------]]")
  ajouter("")
  ajouter("return {")
  ajouter("")
  ajouter("  -- Tolerance de pointage commune, en degres.")
  ajouter("  toleranceViseeDeg = " .. litteral(arsenal.toleranceViseeDeg) .. ",")
  ajouter("")
  ajouter("  -- REGLE D'ENGAGEMENT.")
  ajouter("  --   true  : l'ordre de tir PRIME SUR LA POSITION. Le navire ouvre le feu")
  ajouter("  --           des qu'il a une solution, meme hors de son arc arriere.")
  ajouter("  --   false : l'arc arriere est un prealable au tir.")
  ajouter("  prioriteTirSurPosition = " .. litteral(arsenal.prioriteTirSurPosition) .. ",")
  ajouter("")
  ajouter("  -- Besoin d'armement par defaut pour une cible en vol.")
  ajouter("  besoinParDefaut = " .. litteral(arsenal.besoinParDefaut) .. ",")
  ajouter("  -- Une cible sous (relief + cette marge) est traitee comme cible au sol.")
  ajouter("  margeAltitudeSol = " .. litteral(arsenal.margeAltitudeSol) .. ",")
  ajouter("")
  ajouter("  armes = {")

  for _, arme in ipairs(arsenal.armes) do
    ajouter("")
    if arme.note and arme.note ~= "" then
      ajouter("    -- " .. tostring(arme.note))
    end
    ajouter("    {")
    for _, champ in ipairs(M.CHAMPS) do
      local valeur = arme[champ.cle]
      if valeur ~= nil and valeur ~= "" then
        local commentaire = champ.unite and ("  -- " .. champ.unite) or ""
        ajouter(string.format("      %-13s = %s,%s", champ.cle, litteral(valeur), commentaire))
      end
    end
    ajouter("    },")
  end

  ajouter("  },")
  ajouter("}")
  ajouter("")

  local contenu = table.concat(lignes, "\n")

  -- Verification avant remplacement : on ne remplace jamais un fichier valide
  -- par un fichier qui ne se charge pas.
  local morceau, err = load(contenu, "@arsenal", "t", _G)
  if not morceau then
    return false, "fichier genere invalide (" .. tostring(err) .. ") : rien n'a ete ecrit"
  end

  local dossier = fs.getDir(M.CHEMIN)
  if dossier ~= "" and not fs.exists(dossier) then fs.makeDir(dossier) end

  local fichier = fs.open(M.CHEMIN, "w")
  if not fichier then
    return false, "ecriture impossible dans " .. M.CHEMIN
  end
  fichier.write(contenu)
  fichier.close()
  return true, M.CHEMIN
end

return M
