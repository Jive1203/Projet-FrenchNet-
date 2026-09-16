--[[----------------------------------------------------------------------------
  CONSOLE DE NAVIGATION - AUTOPILOTE FRENCHNET (AERONAUTICS WARFARE)
  --------------------------------------------------------------------------
  L'interface de vol du vehicule. Quatre ecrans, dans le style FrenchNet :

    ITINERAIRES  - les routes enregistrees : creer, renommer, supprimer,
                   dupliquer, lancer.
    POINTS       - les points de passage d'une route, editables case par case
                   comme un tableau. L'altitude est FACULTATIVE : sans elle le
                   point est survole en croisiere, avec elle le vehicule s'y
                   rend a l'aplomb puis descend VERTICALEMENT.
    VOL          - supervision en direct : phase, etape, distance, altitude,
                   vitesse, temps restant estime. Maintien, saut d'etape et
                   interruption a portee de touche.
    CALIBRATION  - le vehicule se mesure lui-meme, en deduit ses vitesses et
                   ses gains PID, et propose de les enregistrer.

  Usage :  console
--------------------------------------------------------------------------------]]

local autopilote  = dofile("/autopilote/autopilote.lua")
local routesLib   = dofile("/autopilote/routes.lua")
local interface   = dofile("/autopilote/interface.lua")
local calibration = dofile("/autopilote/calibration.lua")

local ui = interface.ui
local P  = ui.PALETTE

local console = {}
console.VERSION = "1.0.0"

--------------------------------------------------------------------------------
-- 1. ETAT GLOBAL DE LA CONSOLE
--------------------------------------------------------------------------------

local etat = {
  routes      = {},
  route       = 1,       -- route selectionnee
  point       = 1,       -- point selectionne
  colonne     = 1,       -- colonne selectionnee dans le tableau des points
  defilement  = 0,
  message     = "",
  couleur     = nil,
  modifie     = false,
}

local COLONNES = {
  { cle = "nom",   titre = "NOM",  largeur = 14, type = "texte" },
  { cle = "x",     titre = "X",    largeur = 8,  type = "nombre" },
  { cle = "y",     titre = "Y",    largeur = 7,  type = "altitude" },
  { cle = "z",     titre = "Z",    largeur = 8,  type = "nombre" },
  { cle = "type",  titre = "TYPE", largeur = 13, type = "choix", options = routesLib.TYPES },
  { cle = "cap",   titre = "CAP",  largeur = 5,  type = "capOuVide" },
  { cle = "arret", titre = "STOP", largeur = 5,  type = "booleen" },
}

local function signaler(texte, couleur)
  etat.message = texte or ""
  etat.couleur = couleur or P.texteFaible
end

local function routeCourante()
  return etat.routes[etat.route]
end

--------------------------------------------------------------------------------
-- 2. ECRAN DES ITINERAIRES
--------------------------------------------------------------------------------

local function dessinerItineraires(config)
  local largeur, hauteur = term.getSize()
  ui.ecran.preparer()
  ui.barre(1, largeur, "FRENCHNET // NAVIGATION" .. (etat.modifie and "  *" or ""),
    tostring(config.identifiant) .. "  " .. ui.heure())

  ui.fond(P.fond)
  if #etat.routes == 0 then
    ui.encre(P.texteFaible)
    ui.ecrireA(2, 3, "Aucun itineraire enregistre.")
    ui.ecrireA(2, 5, "N : creer une route")
    ui.ecrireA(2, 6, "Une route est une suite de points de passage.")
    ui.ecrireA(2, 7, "Sans altitude, un point est survole a l'altitude")
    ui.ecrireA(2, 8, "de croisiere (" .. tostring(config.vitesses.altitudeCroisiere) .. ").")
  end

  local visibles = hauteur - 4
  for ligne = 1, visibles do
    local index = ligne + etat.defilement
    local route = etat.routes[index]
    local y = ligne + 1
    if route then
      local actif = (index == etat.route)
      ui.fond(actif and P.selection or P.fond)
      ui.encre(actif and P.texteSelect or P.texte)
      local altitude = route.altitudeCroisiere
        and string.format("%4.0f", route.altitudeCroisiere) or "croi"
      ui.ecrireA(1, y, string.format(" %-20s %3d pts  alt %s  %6.0fm",
        route.nom:sub(1, 20), #route.points, altitude,
        routesLib.longueur(route)), largeur)
    else
      ui.fond(P.fond)
      ui.ligneVide(y, largeur)
    end
  end

  ui.fond(P.fond)
  ui.encre(P.texteFaible)
  ui.ecrireA(1, hauteur - 1,
    " Entree:points  V:voler  N:nouvelle  R:renommer  D:dupliquer  Suppr", largeur)
  ui.fond(P.fondPanneau)
  ui.encre(etat.couleur or P.texteFaible)
  ui.ligneVide(hauteur, largeur)
  ui.ecrireA(2, hauteur, (etat.message ~= "" and etat.message
    or "S:enregistrer  C:calibration  Q:quitter"):sub(1, largeur - 2))
end

--------------------------------------------------------------------------------
-- 3. ECRAN DES POINTS
--------------------------------------------------------------------------------

local function valeurAffichee(point, colonne, config)
  local valeur = point[colonne.cle]
  if colonne.type == "altitude" then
    if valeur == nil then return "croisi." end
    return string.format("%.0f", valeur)
  elseif colonne.type == "capOuVide" then
    if valeur == nil then return "-" end
    return string.format("%.0f", valeur)
  elseif colonne.type == "booleen" then
    return valeur and "oui" or "-"
  elseif colonne.type == "nombre" then
    return valeur and string.format("%.0f", valeur) or "?"
  end
  return tostring(valeur or "")
end

local function dessinerPoints(config)
  local largeur, hauteur = term.getSize()
  local route = routeCourante()
  ui.ecran.preparer()
  ui.barre(1, largeur, "ROUTE " .. (route and route.nom or "?"),
    string.format("%d point(s)", route and #route.points or 0))

  -- En-tete de colonnes
  ui.fond(P.fondPanneau)
  ui.encre(P.texte)
  ui.ligneVide(2, largeur)
  local x = 2
  for _, colonne in ipairs(COLONNES) do
    ui.ecrireA(x, 2, colonne.titre, colonne.largeur)
    x = x + colonne.largeur
  end

  local visibles = hauteur - 5
  if etat.point - etat.defilement > visibles then
    etat.defilement = etat.point - visibles
  elseif etat.point <= etat.defilement then
    etat.defilement = etat.point - 1
  end

  for ligne = 1, visibles do
    local index = ligne + etat.defilement
    local point = route and route.points[index]
    local y = ligne + 2
    ui.fond(P.fond)
    ui.ligneVide(y, largeur)
    if point then
      x = 2
      for indexColonne, colonne in ipairs(COLONNES) do
        local actif = (index == etat.point and indexColonne == etat.colonne)
        ui.fond(actif and P.selection or P.fond)
        if index == etat.point and not actif then
          ui.encre(P.valeur)
        else
          ui.encre(actif and P.texteSelect or P.texte)
        end
        ui.ecrireA(x, y, valeurAffichee(point, colonne, config), colonne.largeur)
        x = x + colonne.largeur
      end
    end
  end

  ui.fond(P.fond)
  ui.encre(P.texteFaible)
  ui.ecrireA(1, hauteur - 1,
    " Entree:modifier  A:ajouter ici(GPS)  Suppr  +/-:deplacer  V:voler  Q", largeur)
  ui.fond(P.fondPanneau)
  ui.encre(etat.couleur or P.texteFaible)
  ui.ligneVide(hauteur, largeur)
  ui.ecrireA(2, hauteur, (etat.message ~= "" and etat.message
    or "Altitude vide = survol en croisiere. Altitude = descente verticale."
    ):sub(1, largeur - 2))
end

--- Modifie la case selectionnee.
local function modifierCase(config)
  local route = routeCourante()
  local point = route and route.points[etat.point]
  if not point then return end
  local colonne = COLONNES[etat.colonne]

  if colonne.type == "booleen" then
    point[colonne.cle] = not point[colonne.cle]
    etat.modifie = true
    return
  end

  if colonne.type == "choix" then
    local suivant = 1
    for i, option in ipairs(colonne.options) do
      if option == point[colonne.cle] then suivant = i % #colonne.options + 1 break end
    end
    point[colonne.cle] = colonne.options[suivant]
    etat.modifie = true
    signaler("type -> " .. point[colonne.cle], P.bon)
    return
  end

  -- Saisie : la position de la case est recalculee comme a l'affichage.
  local x = 2
  for i = 1, etat.colonne - 1 do x = x + COLONNES[i].largeur end
  local y = etat.point - etat.defilement + 2
  local initiale = point[colonne.cle] ~= nil and tostring(point[colonne.cle]) or ""
  local saisie = ui.saisir(x, y, colonne.largeur, initiale)

  if colonne.type == "texte" then
    point[colonne.cle] = (saisie ~= "") and saisie or nil
  elseif colonne.type == "altitude" or colonne.type == "capOuVide" then
    -- Une case vide a un sens ici : pas d'altitude imposee, pas de cap impose.
    if saisie == "" then
      point[colonne.cle] = nil
      signaler(colonne.cle == "y"
        and "altitude libre : le point sera survole en croisiere"
        or "cap libre", P.texteFaible)
    else
      local valeur = tonumber(saisie)
      if not valeur then
        signaler("valeur numerique attendue (ou vide)", P.alerte)
        return
      end
      point[colonne.cle] = valeur
    end
  else
    local valeur = tonumber(saisie)
    if not valeur then
      signaler("valeur numerique attendue", P.alerte)
      return
    end
    point[colonne.cle] = valeur
  end
  etat.modifie = true
end

--- Ajoute un point a la position GPS courante.
local function ajouterPointIci(config)
  local route = routeCourante()
  if not route then return end
  signaler("lecture GPS...", P.texteFaible)
  dessinerPoints(config)

  local x, y, z = gps.locate(config.gps.delaiLocate or 2, false)
  local point
  if x then
    point = { x = math.floor(x + 0.5), y = math.floor(y + 0.5),
              z = math.floor(z + 0.5), type = "survol" }
    -- Message volontairement court : la barre d'etat fait 49 colonnes sur un
    -- ordinateur standard, et c'est l'avertissement qui doit survivre a la
    -- troncature, pas les coordonnees.
    signaler(string.format("ANTENNE (pas le centre) : X=%d Y=%d Z=%d",
      point.x, point.y, point.z), P.bon)
  else
    point = { x = 0, y = nil, z = 0, type = "survol" }
    signaler("GPS indisponible : point vierge ajoute, a renseigner a la main", P.alerte)
  end
  -- Insertion juste apres le point selectionne, en restant dans les bornes :
  -- sur une route encore vide, 'apres le point 1' n'existe pas.
  local position = math.min(#route.points + 1, math.max(1, etat.point + 1))
  table.insert(route.points, position, point)
  etat.point = position
  etat.modifie = true
end

--------------------------------------------------------------------------------
-- 4. ECRAN DE VOL
--------------------------------------------------------------------------------

local function dessinerVol(ap, route, suivi)
  local largeur, hauteur = term.getSize()
  local vol = ap.etat()
  ui.ecran.preparer()

  local titre = "VOL " .. (route and route.nom or "DIRECT")
  ui.barre(1, largeur, titre, tostring(vol.mode)
    .. (vol.phase and ("/" .. vol.phase) or "") .. "  " .. ui.heure())

  ui.fond(P.fond)
  local y = 3
  local function ligne(etiquette, valeur, couleur)
    ui.encre(P.texteFaible)
    ui.ecrireA(2, y, etiquette, 14)
    ui.encre(couleur or P.texte)
    ui.ecrireA(16, y, valeur, largeur - 16)
    y = y + 1
  end

  ligne("etape", string.format("%d / %d%s", vol.index or 0, vol.total or 0,
    vol.point and vol.point.nom and ("   " .. vol.point.nom) or ""))
  ligne("distance", vol.distance and string.format("%.1f blocs", vol.distance) or "-")
  ligne("altitude", vol.position
    and string.format("%.1f   (ecart %.1f)", vol.position.y, vol.ecartAltitude or 0) or "-")
  ligne("vitesse sol", string.format("%.2f blocs/s", vol.vitesseSol or 0))
  ligne("cap", string.format("%.0f deg  (%s)", vol.cap or 0, tostring(vol.sourceCap)))
  if vol.hauteurSol then
    ligne("hauteur sol", string.format("%.1f blocs (%s)%s", vol.hauteurSol,
      tostring(vol.sourceSol), vol.brideSol and "  BRIDE" or ""))
  end

  -- Temps restant estime : distance restante divisee par la vitesse du moment.
  local reste = vol.distance or 0
  if route and vol.index and vol.index < (vol.total or 0) then
    local precedent = route.points[vol.index]
    for i = (vol.index or 1) + 1, #route.points do
      local point = route.points[i]
      if precedent then
        local dx, dz = point.x - precedent.x, point.z - precedent.z
        reste = reste + math.sqrt(dx * dx + dz * dz)
      end
      precedent = point
    end
  end
  local vitesse = math.max(0.3, vol.vitesseSol or 0)
  ligne("restant", string.format("%.0f blocs, environ %d s", reste, math.floor(reste / vitesse)))

  if vol.perteGps and vol.perteGps > 0 then
    ligne("GPS", string.format("PERDU depuis %.1fs", vol.perteGps), P.alerte)
  end
  if suivi.anomalie then
    ligne("anomalie", suivi.anomalie, P.alerte)
  end

  -- Liste des points, avec l'etape courante mise en evidence.
  y = y + 1
  ui.encre(P.texteFaible)
  ui.ecrireA(2, y, "ITINERAIRE", largeur - 2)
  y = y + 1
  for index, point in ipairs((route and route.points) or {}) do
    if y >= hauteur - 2 then break end
    local courant = (index == (vol.index or 0))
    local franchi = index < (vol.index or 0)
    ui.encre(courant and P.valeur or (franchi and P.bon or P.texteFaible))
    ui.ecrireA(3, y, string.format("%s %d %-14s %6.0f %6s %6.0f",
      courant and ">" or (franchi and "\4" or " "), index,
      (point.nom or ""):sub(1, 14), point.x,
      point.y and string.format("%.0f", point.y) or "croi.", point.z), largeur - 3)
    y = y + 1
  end

  ui.fond(P.fondPanneau)
  ui.encre(suivi.couleur or P.texteFaible)
  ui.ligneVide(hauteur, largeur)
  ui.ecrireA(2, hauteur, (suivi.message
    or "H:maintien  R:reprendre  S:etape suivante  X:interrompre  Q:quitter")
    :sub(1, largeur - 2))
end

--- Lance une route et supervise le vol jusqu'a l'arrivee ou l'interruption.
local function volerRoute(config, route)
  local valide, anomalies = routesLib.valider(route, config)
  if not valide then
    signaler(anomalies[1], P.alerte)
    return
  end

  local ap = autopilote.nouveau()
  local suivi = { message = nil, couleur = nil, anomalie = nil, termine = false }

  ap.surEvenement(function(typeEvenement, donnees)
    if typeEvenement == "etape" then
      suivi.message = string.format("etape %d/%d franchie : %s",
        donnees.index, donnees.total, tostring(donnees.point.nom or ""))
      suivi.couleur = P.bon
    elseif typeEvenement == "arrivee" then
      suivi.message = string.format("ARRIVE (ecart %.2f bloc) - maintien de position",
        donnees.ecart or 0)
      suivi.couleur = P.bon
      suivi.termine = true
    elseif typeEvenement == "anomalie" then
      suivi.anomalie = tostring(donnees.motif)
      suivi.couleur = P.alerte
    end
  end)

  ap.initialiser()
  local points, options = routesLib.versMission(route)
  ap.suivreItineraire(points, options)

  local function ecran()
    local minuteur = os.startTimer(0.4)
    while true do
      dessinerVol(ap, route, suivi)
      local evenement = { os.pullEvent() }
      if evenement[1] == "timer" and evenement[2] == minuteur then
        minuteur = os.startTimer(0.4)
      elseif evenement[1] == "key" then
        local touche = evenement[2]
        if touche == keys.h then
          ap.maintenirPosition()
          suivi.message = "maintien de position demande"
          suivi.couleur = P.verrou
        elseif touche == keys.r then
          ap.suivreItineraire(points, options)
          suivi.message = "reprise de l'itineraire"
          suivi.couleur = P.bon
        elseif touche == keys.s then
          local vol = ap.etat()
          local suivant = (vol.index or 1) + 1
          if suivant <= #points then
            ap.suivreItineraire(points, options, suivant)
            suivi.message = "etape sautee : reprise au point " .. suivant
            suivi.couleur = P.verrou
          end
        elseif touche == keys.x then
          ap.arreter("interruption depuis la console")
          suivi.message = "VOL INTERROMPU : commandes neutralisees"
          suivi.couleur = P.alerte
        elseif touche == keys.q then
          return
        end
      elseif evenement[1] == "terminate" then
        return
      end
    end
  end

  parallel.waitForAny(function() ap.executer() end, ecran)
  ap.stopper()
  ap.arreter("fin de la supervision")
  signaler("vol termine", P.bon)
end

--------------------------------------------------------------------------------
-- 5. ECRAN DE CALIBRATION
--------------------------------------------------------------------------------

local function ecranCalibration(config)
  local largeur, hauteur = term.getSize()
  local lignes = {}
  local function afficher(texte, couleur)
    lignes[#lignes + 1] = { texte = texte, couleur = couleur }
    ui.ecran.preparer()
    ui.barre(1, largeur, "CALIBRATION", tostring(config.identifiant))
    ui.fond(P.fond)
    local premiere = math.max(1, #lignes - (hauteur - 5))
    local y = 3
    for i = premiere, #lignes do
      ui.encre(lignes[i].couleur or P.texte)
      ui.ecrireA(2, y, lignes[i].texte, largeur - 2)
      y = y + 1
    end
  end

  -- Avertissement : le vehicule va vraiment bouger, a pleine puissance.
  ui.ecran.preparer()
  ui.barre(1, largeur, "CALIBRATION", tostring(config.identifiant))
  ui.fond(P.fond)
  ui.encre(P.verrou)
  ui.ecrireA(2, 3, "Le vehicule va bouger A PLEINE PUISSANCE.")
  ui.encre(P.texte)
  ui.ecrireA(2, 5, "Quatre essais : marche avant, montee, virage,")
  ui.ecrireA(2, 6, "translation laterale. Environ une minute.")
  ui.ecrireA(2, 8, "Exigences :")
  ui.encre(P.texteFaible)
  ui.ecrireA(2, 9, " - espace degage sur 200 blocs dans toutes les directions")
  ui.ecrireA(2, 10, " - GPS operationnel")
  ui.ecrireA(2, 11, " - personne a bord ni dessous")
  ui.encre(P.texte)
  ui.ecrireA(2, 13, "Toute touche interrompt et neutralise les commandes.")
  ui.encre(P.bon)
  ui.ecrireA(2, 15, "Entree : lancer        Q : renoncer")
  while true do
    local _, touche = os.pullEvent("key")
    if touche == keys.q then return end
    if touche == keys.enter or touche == keys.numPadEnter then break end
  end

  afficher("Acquisition de la position...", P.texteFaible)
  local ap = autopilote.nouveau()
  ap.initialiser()
  for _ = 1, 10 do
    ap.pas()
    if ap.etat().position then break end
    sleep(config.gps.intervalle)
  end
  if not ap.etat().position then
    afficher("Position GPS introuvable : calibration impossible.", P.alerte)
    afficher("Touche pour revenir.", P.texteFaible)
    os.pullEvent("key")
    return
  end

  local resultats, motif = calibration.mesurer(ap, { afficher = function(t) afficher(t) end })
  if not resultats then
    afficher("Calibration interrompue : " .. tostring(motif), P.alerte)
    afficher("Touche pour revenir.", P.texteFaible)
    os.pullEvent("key")
    return
  end

  local propositions, detail = calibration.proposer(resultats, config)
  afficher("", nil)
  afficher("RESULTATS", P.bon)
  for _, ligne in ipairs(detail) do afficher(ligne, P.texte) end
  afficher("", nil)
  afficher("E : enregistrer dans la configuration    Q : ne rien changer", P.verrou)

  while true do
    local _, touche = os.pullEvent("key")
    if touche == keys.q then
      afficher("Aucune modification enregistree.", P.texteFaible)
      sleep(1)
      return
    end
    if touche == keys.e then
      calibration.appliquer(config, propositions)
      local fichier = fs.open(autopilote.CHEMIN_CONFIG_DEFAUT, "w")
      if fichier then
        fichier.write(autopilote.serialiserConfig(config))
        fichier.close()
        afficher("Configuration enregistree.", P.bon)
      else
        afficher("Ecriture impossible.", P.alerte)
      end
      sleep(1.5)
      return
    end
  end
end

--------------------------------------------------------------------------------
-- 6. BOUCLE PRINCIPALE
--------------------------------------------------------------------------------

function console.demarrer()
  local ok, config = pcall(autopilote.chargerConfiguration)
  if not ok then
    printError("Configuration illisible : " .. tostring(config))
    print("Lancez 'interface' pour la corriger.")
    return
  end

  local motif
  etat.routes, motif = routesLib.charger()
  if motif then signaler(motif, P.alerte) end

  local ecranCourant = "itineraires"

  local function enregistrer()
    local okEcriture, motifEcriture = routesLib.enregistrer(etat.routes)
    if okEcriture then
      etat.modifie = false
      signaler("itineraires enregistres dans " .. routesLib.CHEMIN_DEFAUT, P.bon)
    else
      signaler(tostring(motifEcriture), P.alerte)
    end
  end

  while true do
    if ecranCourant == "itineraires" then
      dessinerItineraires(config)
    else
      dessinerPoints(config)
    end

    local evenement = { os.pullEvent() }
    if evenement[1] == "terminate" then break end

    if evenement[1] == "key" then
      local touche = evenement[2]
      local route = routeCourante()

      if ecranCourant == "itineraires" then
        if touche == keys.down then
          etat.route = math.min(#etat.routes, etat.route + 1)
        elseif touche == keys.up then
          etat.route = math.max(1, etat.route - 1)
        elseif touche == keys.enter or touche == keys.numPadEnter then
          if route then
            ecranCourant, etat.point, etat.colonne, etat.defilement = "points", 1, 1, 0
          end
        elseif touche == keys.n then
          local largeur, hauteur = term.getSize()
          ui.fond(P.fondPanneau) ui.encre(P.texte)
          ui.ecrireA(2, hauteur, "Nom de la route : ", largeur - 2)
          local nom = ui.saisir(20, hauteur, 24, "ROUTE-" .. (#etat.routes + 1))
          etat.routes[#etat.routes + 1] = routesLib.nouvelle(nom)
          etat.route = #etat.routes
          etat.modifie = true
          signaler("route creee : " .. nom, P.bon)
        elseif touche == keys.r and route then
          local largeur, hauteur = term.getSize()
          local nom = ui.saisir(20, hauteur, 24, route.nom)
          if nom ~= "" then route.nom = nom etat.modifie = true end
        elseif touche == keys.d and route then
          local copie = { nom = route.nom .. "-COPIE",
            altitudeCroisiere = route.altitudeCroisiere, points = {} }
          for i, point in ipairs(route.points) do
            copie.points[i] = routesLib.normaliserPoints({ point })[1]
          end
          table.insert(etat.routes, math.min(#etat.routes + 1, etat.route + 1), copie)
          etat.modifie = true
          signaler("route dupliquee", P.bon)
        elseif touche == keys.delete and route then
          table.remove(etat.routes, etat.route)
          etat.route = math.max(1, math.min(etat.route, #etat.routes))
          etat.modifie = true
          signaler("route supprimee", P.verrou)
        elseif touche == keys.v and route then
          volerRoute(config, route)
        elseif touche == keys.c then
          ecranCalibration(config)
          local rechargee = select(1, autopilote.chargerConfiguration())
          if rechargee then config = rechargee end
        elseif touche == keys.s then
          enregistrer()
        elseif touche == keys.q then
          if etat.modifie then
            signaler("Modifications NON enregistrees. S pour enregistrer, Q pour forcer.",
              P.alerte)
            etat.modifie = false
          else
            break
          end
        end

      else -- ecran des points
        local points = route and route.points or {}
        if touche == keys.down then
          etat.point = math.min(#points, etat.point + 1)
        elseif touche == keys.up then
          etat.point = math.max(1, etat.point - 1)
        elseif touche == keys.right then
          etat.colonne = etat.colonne % #COLONNES + 1
        elseif touche == keys.left then
          etat.colonne = (etat.colonne - 2) % #COLONNES + 1
        elseif touche == keys.enter or touche == keys.numPadEnter then
          modifierCase(config)
        elseif touche == keys.a then
          ajouterPointIci(config)
        elseif touche == keys.delete and points[etat.point] then
          table.remove(points, etat.point)
          etat.point = math.max(1, math.min(etat.point, #points))
          etat.modifie = true
        elseif touche == keys.equals and etat.point > 1 then
          points[etat.point], points[etat.point - 1] = points[etat.point - 1], points[etat.point]
          etat.point = etat.point - 1
          etat.modifie = true
        elseif touche == keys.minus and etat.point < #points then
          points[etat.point], points[etat.point + 1] = points[etat.point + 1], points[etat.point]
          etat.point = etat.point + 1
          etat.modifie = true
        elseif touche == keys.v and route then
          volerRoute(config, route)
        elseif touche == keys.s then
          enregistrer()
        elseif touche == keys.q then
          ecranCourant, etat.defilement = "itineraires", 0
          signaler("")
        end
      end
    end
  end

  ui.ecran.restaurer()
  if etat.modifie then
    print("Attention : des modifications d'itineraire n'ont pas ete enregistrees.")
  end
end

local function lanceDepuisLeShell()
  if not (shell and shell.getRunningProgram) then return false end
  local ok, chemin = pcall(shell.getRunningProgram)
  if not ok or type(chemin) ~= "string" then return false end
  return chemin:gsub("^/", "") == "autopilote/console.lua"
end

if lanceDepuisLeShell() then console.demarrer() end

return console
