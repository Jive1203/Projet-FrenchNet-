--[[----------------------------------------------------------------------------
  INTERFACE DE REGLAGE - AUTOPILOTE FRENCHNET (AERONAUTICS WARFARE)
  --------------------------------------------------------------------------
  Interface visuelle facon systeme d'exploitation, dans le style des autres
  outils FrenchNet : barre de titre, panneau de sections a gauche, champs a
  droite, barre d'etat en bas. Clavier ET souris (ordinateurs avances).

  Deux ecrans :
    1. CONFIGURATION  - tous les reglages du vehicule, section par section.
                        Se lance au sol, sans GPS et sans moteurs.
    2. REGLAGE EN VOL - ajustement a chaud des gains PID de chaque axe, avec
                        affichage temps reel de l'erreur, de la vitesse cible,
                        de la vitesse reelle, de la commande envoyee, et d'un
                        historique des dernieres secondes pour voir tout de
                        suite si le reglage oscille ou traine.

  Usage :
      interface              -- ecran de configuration
      interface vol          -- autopilote en maintien + menu de reglage en vol
      interface journal      -- consultation du journal

  Ce fichier est aussi une BIBLIOTHEQUE : un programme de mission peut faire
      local interface = dofile("/autopilote/interface.lua")
      parallel.waitForAny(ap.executer, function() interface.reglageEnVol(ap) end)
  pour offrir le menu de reglage pendant une vraie mission.
--------------------------------------------------------------------------------]]

local CHEMIN_MODULE = "/autopilote/autopilote.lua"
local autopilote = dofile(CHEMIN_MODULE)

local interface = {}
interface.VERSION = "1.0.0"

--------------------------------------------------------------------------------
-- 1. BOITE A OUTILS D'AFFICHAGE
--    Tout degrade proprement sur un ordinateur non couleur : les fonctions de
--    couleur deviennent des appels sans effet.
--------------------------------------------------------------------------------

local ecran = {}

local function couleurDisponible()
  return term.isColour and term.isColour()
end

local PALETTE = {
  fond        = colors.black,
  fondPanneau = colors.gray,
  fondBarre   = colors.cyan,
  texteBarre  = colors.black,
  texte       = colors.white,
  texteFaible = colors.lightGray,
  selection   = colors.lightBlue,
  texteSelect = colors.black,
  valeur      = colors.yellow,
  verrou      = colors.orange,
  alerte      = colors.red,
  bon         = colors.lime,
  accent      = colors.magenta,
}

local function fond(couleur)
  if couleurDisponible() then term.setBackgroundColour(couleur)
  else term.setBackgroundColour(colors.black) end
end

local function encre(couleur)
  if couleurDisponible() then term.setTextColour(couleur)
  else term.setTextColour(colors.white) end
end

--- Ecrit un texte a une position, tronque a la largeur donnee.
local function ecrireA(x, y, texte, largeur)
  term.setCursorPos(x, y)
  texte = tostring(texte)
  if largeur then
    if #texte > largeur then
      texte = texte:sub(1, math.max(0, largeur - 1)) .. "\26" -- fleche de troncature
    else
      texte = texte .. string.rep(" ", largeur - #texte)
    end
  end
  term.write(texte)
end

local function ligneVide(y, largeur, x)
  ecrireA(x or 1, y, "", largeur)
end

--- Barre horizontale pleine (titre ou etat).
local function barre(y, largeur, gauche, droite, couleurFond, couleurTexte)
  fond(couleurFond or PALETTE.fondBarre)
  encre(couleurTexte or PALETTE.texteBarre)
  ligneVide(y, largeur)
  ecrireA(2, y, gauche)
  if droite then
    local x = largeur - #droite
    if x > #gauche + 3 then ecrireA(x, y, droite) end
  end
end

local function heure()
  local ok, texte = pcall(function()
    return textutils.formatTime(os.time(), true)
  end)
  return ok and texte or ""
end

--- Saisie d'une chaine a l'ecran, avec curseur, sans quitter l'interface.
-- @return texte valide, ou nil si la saisie est annulee (Echap)
local function saisir(x, y, largeur, valeurInitiale)
  local tampon = tostring(valeurInitiale or "")
  local curseur = #tampon + 1
  -- La valeur existante est proposee mais consideree comme selectionnee : le
  -- premier caractere frappe la remplace. Une correction (fleches, retour
  -- arriere) repasse en edition normale.
  local remplacerALaFrappe = true

  while true do
    fond(PALETTE.selection)
    encre(PALETTE.texteSelect)
    local visible = tampon
    if #visible > largeur - 1 then visible = visible:sub(#visible - largeur + 2) end
    ecrireA(x, y, visible, largeur)
    term.setCursorPos(x + math.min(#visible, largeur - 1), y)
    term.setCursorBlink(true)

    local evenement = { os.pullEvent() }
    if evenement[1] == "char" then
      if remplacerALaFrappe then
        tampon, curseur = "", 1
        remplacerALaFrappe = false
      end
      tampon = tampon:sub(1, curseur - 1) .. evenement[2] .. tampon:sub(curseur)
      curseur = curseur + 1
    elseif evenement[1] == "key" then
      remplacerALaFrappe = false
      local touche = evenement[2]
      if touche == keys.enter or touche == keys.numPadEnter then
        term.setCursorBlink(false)
        return tampon
      elseif touche == keys.backspace then
        if curseur > 1 then
          tampon = tampon:sub(1, curseur - 2) .. tampon:sub(curseur)
          curseur = curseur - 1
        end
      elseif touche == keys.delete then
        tampon = tampon:sub(1, curseur - 1) .. tampon:sub(curseur + 1)
      elseif touche == keys.left then
        curseur = math.max(1, curseur - 1)
      elseif touche == keys.right then
        curseur = math.min(#tampon + 1, curseur + 1)
      elseif touche == keys.home then
        curseur = 1
      elseif touche == keys["end"] then
        curseur = #tampon + 1
      elseif touche == keys.tab then
        term.setCursorBlink(false)
        return tampon
      end
    elseif evenement[1] == "terminate" then
      term.setCursorBlink(false)
      error("Terminated", 0)
    end
  end
end

--- Formatage court d'une valeur pour l'affichage d'un champ.
local function formaterValeur(valeur)
  if valeur == nil then return "(vide)" end
  if type(valeur) == "boolean" then return valeur and "oui" or "non" end
  if type(valeur) == "number" then
    if valeur == math.floor(valeur) and math.abs(valeur) < 1e9 then
      return string.format("%d", valeur)
    end
    local texte = string.format("%.6f", valeur)
    texte = texte:gsub("0+$", ""):gsub("%.$", "")
    -- L'affichage sert aussi de valeur initiale a la saisie : il ne doit pas
    -- degrader la precision d'un gain qu'on se contente de survoler.
    if tonumber(texte) ~= valeur then texte = string.format("%.14g", valeur) end
    return texte
  end
  return tostring(valeur)
end

--- Trace une courbe compacte (historique) dans un rectangle donne.
-- Chaque colonne represente un echantillon : on voit immediatement si la
-- reponse oscille (dents de scie) ou traine (pente molle).
local function tracerCourbe(x, y, largeur, hauteur, valeurs, couleur, etiquette)
  fond(PALETTE.fond)
  encre(PALETTE.texteFaible)
  for ligne = 0, hauteur - 1 do ligneVide(y + ligne, largeur, x) end
  if #valeurs == 0 then return end

  local mini, maxi = math.huge, -math.huge
  local depart = math.max(1, #valeurs - largeur + 1)
  for i = depart, #valeurs do
    local v = valeurs[i] or 0
    if v < mini then mini = v end
    if v > maxi then maxi = v end
  end
  if maxi - mini < 1e-6 then mini, maxi = mini - 0.5, maxi + 0.5 end

  -- Ligne du zero, quand elle tombe dans la fenetre affichee.
  if mini < 0 and maxi > 0 then
    local ligneZero = math.floor((maxi - 0) / (maxi - mini) * (hauteur - 1) + 0.5)
    encre(PALETTE.texteFaible)
    ecrireA(x, y + ligneZero, string.rep("-", largeur))
  end

  encre(couleur)
  local colonne = 0
  for i = depart, #valeurs do
    local v = valeurs[i] or 0
    local ligne = math.floor((maxi - v) / (maxi - mini) * (hauteur - 1) + 0.5)
    ligne = math.max(0, math.min(hauteur - 1, ligne))
    term.setCursorPos(x + colonne, y + ligne)
    term.write("\7")
    colonne = colonne + 1
    if colonne >= largeur then break end
  end

  if etiquette then
    encre(couleur)
    ecrireA(x, y, etiquette:sub(1, largeur))
    encre(PALETTE.texteFaible)
    ecrireA(x + largeur - 12, y + hauteur - 1, string.format("%+7.2f", mini))
    ecrireA(x + largeur - 12, y, string.format("%+7.2f", maxi))
  end
end

function ecran.preparer()
  fond(PALETTE.fond)
  encre(PALETTE.texte)
  term.clear()
  term.setCursorPos(1, 1)
end

function ecran.restaurer()
  term.setBackgroundColour(colors.black)
  term.setTextColour(colors.white)
  term.setCursorBlink(false)
  term.clear()
  term.setCursorPos(1, 1)
end

--------------------------------------------------------------------------------
-- 2. SCHEMA DE LA CONFIGURATION
--    Une seule description pilote a la fois l'affichage, la saisie et l'aide.
--    'cle' est un chemin pointe dans la table de configuration.
--------------------------------------------------------------------------------

local CHOIX_COTES = { "front", "back", "left", "right", "top", "bottom" }

local function champsSorties(axe, libelle)
  return {
    { cle = "sorties.axes." .. axe .. ".mode", libelle = libelle .. " : mode",
      type = "choix", options = { "aucun", "analogique", "bipolaire", "peripherique" },
      aide = "aucun = axe non equipe sur ce vehicule" },
    { cle = "sorties.axes." .. axe .. ".cote", libelle = libelle .. " : cote",
      type = "choix", options = CHOIX_COTES, aide = "mode analogique uniquement" },
    { cle = "sorties.axes." .. axe .. ".neutre", libelle = libelle .. " : neutre",
      type = "nombre", aide = "niveau redstone au repos (mode analogique)" },
    { cle = "sorties.axes." .. axe .. ".amplitude", libelle = libelle .. " : amplitude",
      type = "nombre", aide = "amplitude du signal redstone" },
    { cle = "sorties.axes." .. axe .. ".cotePositif", libelle = libelle .. " : cote +",
      type = "choix", options = CHOIX_COTES, aide = "mode bipolaire" },
    { cle = "sorties.axes." .. axe .. ".coteNegatif", libelle = libelle .. " : cote -",
      type = "choix", options = CHOIX_COTES, aide = "mode bipolaire" },
    { cle = "sorties.axes." .. axe .. ".seuil", libelle = libelle .. " : seuil",
      type = "nombre", aide = "commande en deca de laquelle on n'emet rien" },
  }
end

local function champsGains(axe, libelle)
  return {
    { cle = "gains." .. axe .. ".position.kp", libelle = "Position kp", type = "nombre",
      aide = "boucle externe : erreur de position -> vitesse cible" },
    { cle = "gains." .. axe .. ".croisiere.kp", libelle = "Croisiere kp", type = "nombre",
      aide = "boucle interne en transit : erreur de vitesse -> commande" },
    { cle = "gains." .. axe .. ".croisiere.ki", libelle = "Croisiere ki", type = "nombre" },
    { cle = "gains." .. axe .. ".croisiere.kd", libelle = "Croisiere kd", type = "nombre" },
    { cle = "gains." .. axe .. ".croisiere.integraleMax", libelle = "Croisiere I max",
      type = "nombre", aide = "borne du terme integral (anti-emballement)" },
    { cle = "gains." .. axe .. ".croisiere.penteMax", libelle = "Croisiere pente max",
      type = "nombre", aide = "variation maximale de la commande par seconde" },
    { cle = "gains." .. axe .. ".croisiere.filtreDerivee", libelle = "Croisiere filtre D",
      type = "nombre", aide = "lissage du terme derive, en secondes" },
    { cle = "gains." .. axe .. ".maintien.kp", libelle = "Maintien kp", type = "nombre",
      aide = "boucle interne en maintien de position (gains plus serres)" },
    { cle = "gains." .. axe .. ".maintien.ki", libelle = "Maintien ki", type = "nombre" },
    { cle = "gains." .. axe .. ".maintien.kd", libelle = "Maintien kd", type = "nombre" },
    { cle = "gains." .. axe .. ".maintien.integraleMax", libelle = "Maintien I max",
      type = "nombre" },
    { cle = "gains." .. axe .. ".maintien.penteMax", libelle = "Maintien pente max",
      type = "nombre" },
  }
end

local SCHEMA = {
  { titre = "Identite", champs = {
    { cle = "nom", libelle = "Nom du vehicule", type = "texte",
      aide = "libelle lisible affiche par les autres systemes" },
    { cle = "identifiant", libelle = "Identifiant unique", type = "texte",
      aide = "doit etre unique sur tout le serveur" },
  }},

  { titre = "Geometrie", champs = {
    { cle = "decalageGps.x", libelle = "Decalage GPS x (tribord)", type = "nombre",
      aide = "position de l'ordinateur par rapport au centre du vehicule" },
    { cle = "decalageGps.y", libelle = "Decalage GPS y (haut)", type = "nombre" },
    { cle = "decalageGps.z", libelle = "Decalage GPS z (avant)", type = "nombre" },
    { cle = "decalageDepot.x", libelle = "Decalage depot x (tribord)", type = "nombre",
      aide = "point de depot / d'atterrissage par rapport au centre" },
    { cle = "decalageDepot.y", libelle = "Decalage depot y (haut)", type = "nombre" },
    { cle = "decalageDepot.z", libelle = "Decalage depot z (avant)", type = "nombre" },
    { cle = "decalageDansRepereVehicule", libelle = "Decalages en repere vehicule",
      type = "booleen", aide = "oui = tournes selon le cap (recommande)" },
    { cle = "gabarit.longueur", libelle = "Gabarit longueur", type = "nombre" },
    { cle = "gabarit.largeur", libelle = "Gabarit largeur", type = "nombre" },
    { cle = "gabarit.hauteur", libelle = "Gabarit hauteur", type = "nombre" },
  }},

  { titre = "Tolerances", champs = {
    { cle = "tolerances.horizontale", libelle = "Tolerance horizontale", type = "nombre",
      aide = "rayon d'acceptation autour du point, en blocs" },
    { cle = "tolerances.altitude", libelle = "Zone morte altitude", type = "nombre" },
    { cle = "tolerances.cap", libelle = "Zone morte cap", type = "nombre",
      aide = "en degres" },
    { cle = "tolerances.dureeArrivee", libelle = "Duree d'arrivee", type = "nombre",
      aide = "secondes CONTINUES dans les marges avant de declarer l'arrivee" },
    { cle = "tolerances.hysteresis.altitude", libelle = "Hysteresis altitude", type = "nombre",
      aide = "evite le yo-yo autour du seuil de la zone morte" },
    { cle = "tolerances.hysteresis.cap", libelle = "Hysteresis cap", type = "nombre" },
    { cle = "tolerances.hysteresis.horizontale", libelle = "Hysteresis horizontale",
      type = "nombre" },
  }},

  { titre = "Vitesses", champs = {
    { cle = "vitesses.croisiere", libelle = "Vitesse de croisiere", type = "nombre",
      aide = "blocs par seconde en transit" },
    { cle = "vitesses.approche", libelle = "Vitesse d'approche", type = "nombre" },
    { cle = "vitesses.verticaleMax", libelle = "Vitesse verticale max", type = "nombre" },
    { cle = "vitesses.lateraleMax", libelle = "Vitesse laterale max", type = "nombre",
      aide = "0 si le vehicule n'a pas de propulsion laterale" },
    { cle = "vitesses.tauxVirageMax", libelle = "Taux de virage max", type = "nombre",
      aide = "degres par seconde" },
    { cle = "vitesses.marcheArriere", libelle = "Marche arriere", type = "nombre",
      aide = "0 = le vehicule ne recule pas" },
    { cle = "vitesses.altitudeCroisiere", libelle = "Altitude de croisiere", type = "nombre",
      aide = "altitude de securite tenue pendant tout le transit" },
    { cle = "vitesses.margeAltitude", libelle = "Marge d'altitude", type = "nombre" },
    { cle = "vitesses.distanceApproche", libelle = "Distance d'approche", type = "nombre",
      aide = "debut du ralentissement et de la descente" },
    { cle = "vitesses.distanceMinCroisiere", libelle = "Distance min croisiere",
      type = "nombre", aide = "en deca : vol direct, sans monter en croisiere" },
    { cle = "vitesses.avanceEnMontee", libelle = "Avance en montee", type = "nombre",
      aide = "0 = montee purement verticale avant de transiter" },
    { cle = "vitesses.rayonValidationEtape", libelle = "Rayon validation etape",
      type = "nombre" },
    { cle = "vitesses.acquisitionCap", libelle = "Vitesse acquisition cap", type = "nombre",
      aide = "reptation quand le cap n'est pas encore observable" },
  }},

  { titre = "Gains altitude", champs = champsGains("altitude", "Altitude") },
  { titre = "Gains cap",      champs = champsGains("cap", "Cap") },
  { titre = "Gains avance",   champs = champsGains("avance", "Avance") },
  { titre = "Gains derive",   champs = champsGains("derive", "Derive") },

  { titre = "Pilotage", champs = {
    { cle = "pilotage.mode", libelle = "Mode de pilotage", type = "choix",
      options = { "auto", "pid", "zone_morte" },
      aide = "auto = PID avec repli automatique en zone morte" },
    { cle = "pilotage.detection.fenetre", libelle = "Detection : fenetre", type = "nombre",
      aide = "duree observee pour juger de l'instabilite" },
    { cle = "pilotage.detection.changementsSigne", libelle = "Detection : chgts de signe",
      type = "nombre" },
    { cle = "pilotage.detection.depassements", libelle = "Detection : depassements",
      type = "nombre" },
    { cle = "pilotage.detection.rapportDepassement", libelle = "Detection : rapport",
      type = "nombre" },
    { cle = "pilotage.detection.retourAutoPid", libelle = "Retour auto au PID",
      type = "booleen" },
    { cle = "pilotage.detection.dureeAvantRetour", libelle = "Duree avant retour PID",
      type = "nombre" },
    { cle = "pilotage.commandesZoneMorte.altitude", libelle = "Zone morte : cmd altitude",
      type = "nombre" },
    { cle = "pilotage.commandesZoneMorte.cap", libelle = "Zone morte : cmd cap",
      type = "nombre" },
    { cle = "pilotage.commandesZoneMorte.avance", libelle = "Zone morte : cmd avance",
      type = "nombre" },
    { cle = "pilotage.commandesZoneMorte.derive", libelle = "Zone morte : cmd derive",
      type = "nombre" },
    { cle = "pilotage.capMaxAvanceZoneMorte", libelle = "Zone morte : cap max avance",
      type = "nombre" },
    { cle = "pilotage.distanceMinCapCible", libelle = "Distance min cap cible",
      type = "nombre", aide = "en deca, l'azimut vers la cible est fige" },
    { cle = "pilotage.correctionDeriveParCap", libelle = "Corriger la derive par le cap",
      type = "booleen" },
    { cle = "pilotage.corrections.gainDeriveCap", libelle = "Gain derive -> cap",
      type = "nombre" },
    { cle = "pilotage.corrections.deriveParCapMax", libelle = "Correction cap max",
      type = "nombre" },
  }},

  { titre = "Maintien", champs = {
    { cle = "maintien.cap", libelle = "Cap en maintien", type = "choix",
      options = { "auto", "conserver", "vers_cible" },
      aide = "auto = conserve le cap si le vehicule sait translater" },
    { cle = "maintien.facteurVitesse", libelle = "Facteur de vitesse", type = "nombre" },
    { cle = "maintien.arretDansMarges", libelle = "Couper la poussee dans les marges",
      type = "booleen" },
  }},

  { titre = "GPS et filtrage", champs = {
    { cle = "gps.intervalle", libelle = "Intervalle de lecture", type = "nombre",
      aide = "secondes entre deux lectures GPS" },
    { cle = "gps.delaiLocate", libelle = "Timeout gps.locate", type = "nombre" },
    { cle = "gps.lecturesAcquisition", libelle = "Lectures d'acquisition", type = "nombre",
      aide = "lectures exigees avant d'autoriser le moindre mouvement" },
    { cle = "gps.perteToleree", libelle = "Perte GPS toleree", type = "nombre",
      aide = "secondes de navigation a l'estime avant le mode secours" },
    { cle = "gps.dtMax", libelle = "Pas de temps max", type = "nombre" },
    { cle = "gps.vitesseMaxPlausible", libelle = "Vitesse max plausible", type = "nombre",
      aide = "au-dela, la lecture est jugee aberrante" },
    { cle = "gps.sourceHorloge", libelle = "Source d'horloge", type = "choix",
      options = { "ticks", "reel" }, aide = "ticks = os.clock (recommande)" },
    { cle = "gps.seuilRalentissement", libelle = "Seuil ralentissement", type = "nombre" },
    { cle = "gps.filtre.type", libelle = "Filtre position", type = "choix",
      options = { "passe_bas", "moyenne" } },
    { cle = "gps.filtre.constanteTemps", libelle = "Filtre : constante", type = "nombre" },
    { cle = "gps.filtre.fenetre", libelle = "Filtre : fenetre", type = "nombre",
      aide = "nombre d'echantillons (moyenne glissante)" },
    { cle = "gps.filtreVitesse.constanteTemps", libelle = "Filtre vitesse : constante",
      type = "nombre" },
  }},

  { titre = "Cap", champs = {
    { cle = "cap.source", libelle = "Source du cap", type = "choix",
      options = { "route", "peripherique" },
      aide = "route = deduit du deplacement, aucun materiel requis" },
    { cle = "cap.peripherique", libelle = "Peripherique", type = "texte" },
    { cle = "cap.methode", libelle = "Methode", type = "texte" },
    { cle = "cap.convention", libelle = "Convention", type = "choix",
      options = { "minecraft", "boussole" } },
    { cle = "cap.facteur", libelle = "Facteur", type = "nombre" },
    { cle = "cap.decalage", libelle = "Decalage", type = "nombre" },
    { cle = "cap.vitesseMinRoute", libelle = "Vitesse min route", type = "nombre",
      aide = "en deca, la route ne renseigne plus le cap" },
    { cle = "cap.dureeCapValide", libelle = "Duree cap valide", type = "nombre" },
    { cle = "cap.capParDefaut", libelle = "Cap par defaut", type = "nombre" },
  }},

  { titre = "Sorties avance",   champs = champsSorties("avance", "Avance") },
  { titre = "Sorties vertical", champs = champsSorties("vertical", "Vertical") },
  { titre = "Sorties lacet",    champs = champsSorties("lacet", "Lacet") },
  { titre = "Sorties lateral",  champs = champsSorties("lateral", "Lateral") },

  { titre = "Mission", champs = {
    { cle = "mission.reprendreApresRedemarrage", libelle = "Reprise apres redemarrage",
      type = "booleen" },
    { cle = "mission.reprendreApresPerteGps", libelle = "Reprise apres perte GPS",
      type = "booleen" },
    { cle = "mission.respecterAltitudeCroisiere", libelle = "Plancher de croisiere",
      type = "booleen" },
    { cle = "mission.monteeAvantTransit", libelle = "Monter avant de transiter",
      type = "booleen" },
    { cle = "mission.fichierEtat", libelle = "Fichier d'etat", type = "texte" },
  }},

  { titre = "Journal", champs = {
    { cle = "journal.fichier", libelle = "Ecrire un fichier", type = "booleen" },
    { cle = "journal.chemin", libelle = "Chemin du journal", type = "texte" },
    { cle = "journal.tailleMax", libelle = "Taille max", type = "nombre" },
    { cle = "journal.niveauEcran", libelle = "Niveau ecran", type = "choix",
      options = { "DEBUG", "INFO", "AVERT", "ERREUR" } },
    { cle = "journal.periodeCycles", libelle = "1 cycle sur N en DEBUG", type = "nombre" },
    { cle = "journal.historique", libelle = "Historique de reglage", type = "nombre",
      aide = "echantillons gardes par axe pour le menu de reglage en vol" },
  }},

  { titre = "Ravitaillement", verrouille = true, champs = {
    { cle = "ravitaillement.nom", libelle = "Station", type = "texte", verrouille = true },
    { cle = "ravitaillement.position.x", libelle = "Position X", type = "nombre",
      verrouille = true },
    { cle = "ravitaillement.position.y", libelle = "Position Y", type = "nombre",
      verrouille = true },
    { cle = "ravitaillement.position.z", libelle = "Position Z", type = "nombre",
      verrouille = true },
    { cle = "ravitaillement.capFinal", libelle = "Cap en finale", type = "nombre",
      verrouille = true },
  }},
}

--------------------------------------------------------------------------------
-- 3. ECRAN DE CONFIGURATION
--------------------------------------------------------------------------------

local LARGEUR_SECTIONS = 17

local function valeurChamp(config, champ)
  return autopilote.interne.lire(config, champ.cle)
end

--- Applique une valeur saisie au bon type.
-- @return true | false, message
local function definirChamp(config, champ, texte)
  if champ.type == "nombre" then
    local valeur = tonumber(texte)
    if texte == "" or texte == "-" then
      autopilote.interne.ecrire(config, champ.cle, nil)
      return true
    end
    if not valeur then return false, "valeur numerique attendue" end
    if champ.mini and valeur < champ.mini then
      return false, string.format("minimum %s", tostring(champ.mini))
    end
    autopilote.interne.ecrire(config, champ.cle, valeur)
  else
    if texte == "" then
      autopilote.interne.ecrire(config, champ.cle, nil)
    else
      autopilote.interne.ecrire(config, champ.cle, texte)
    end
  end
  return true
end

function interface.configurer(options)
  options = options or {}
  local cheminConfig = options.config or autopilote.CHEMIN_CONFIG_DEFAUT
  local okChargement, config, anomalieRavitaillement = pcall(
    autopilote.chargerConfiguration, cheminConfig)

  if not okChargement then
    ecran.restaurer()
    printError("Configuration illisible : " .. tostring(config))
    print("Corrigez " .. cheminConfig .. " puis relancez l'interface.")
    return false
  end

  local etat = {
    section = 1, champ = 1, focus = "sections",
    defilementSections = 0, defilementChamps = 0,
    message = "Fleches : naviguer   Tab : changer de panneau   Entree : modifier",
    couleurMessage = PALETTE.texteFaible,
    modifie = false, sauvegardeForcee = false,
  }
  if anomalieRavitaillement then
    etat.message = "Ravitaillement illisible : " .. tostring(anomalieRavitaillement)
    etat.couleurMessage = PALETTE.alerte
  end

  local function sectionCourante() return SCHEMA[etat.section] end
  local function champCourant()
    local s = sectionCourante()
    return s and s.champs[etat.champ] or nil
  end

  local function dessiner()
    local largeur, hauteur = term.getSize()
    local lignesUtiles = hauteur - 3          -- titre + aide + etat
    ecran.preparer()

    ------------------------------------------------------------------ barre de titre
    barre(1, largeur,
      "FRENCHNET // AUTOPILOTE" .. (etat.modifie and "  *" or ""),
      tostring(config.identifiant or "?") .. "  " .. heure())

    ------------------------------------------------------------------ panneau gauche
    local visiblesSections = lignesUtiles
    if etat.section - etat.defilementSections > visiblesSections then
      etat.defilementSections = etat.section - visiblesSections
    elseif etat.section <= etat.defilementSections then
      etat.defilementSections = etat.section - 1
    end

    for ligne = 1, visiblesSections do
      local index = ligne + etat.defilementSections
      local y = 1 + ligne
      local section = SCHEMA[index]
      if section then
        local actif = (index == etat.section)
        fond(actif and PALETTE.selection or PALETTE.fondPanneau)
        encre(actif and PALETTE.texteSelect
          or (section.verrouille and PALETTE.verrou or PALETTE.texte))
        ecrireA(1, y, " " .. section.titre, LARGEUR_SECTIONS)
      else
        fond(PALETTE.fondPanneau)
        ligneVide(y, LARGEUR_SECTIONS)
      end
    end

    ------------------------------------------------------------------ panneau droit
    local xChamps = LARGEUR_SECTIONS + 2
    local largeurChamps = largeur - xChamps + 1
    local section = sectionCourante()
    local champs = section and section.champs or {}
    if etat.champ > #champs then etat.champ = math.max(1, #champs) end

    local visiblesChamps = lignesUtiles
    if etat.champ - etat.defilementChamps > visiblesChamps then
      etat.defilementChamps = etat.champ - visiblesChamps
    elseif etat.champ <= etat.defilementChamps then
      etat.defilementChamps = etat.champ - 1
    end

    local largeurLibelle = math.min(24, math.floor(largeurChamps * 0.55))
    for ligne = 1, visiblesChamps do
      local index = ligne + etat.defilementChamps
      local y = 1 + ligne
      local champ = champs[index]
      fond(PALETTE.fond)
      if champ then
        local actif = (index == etat.champ and etat.focus == "champs")
        local verrouille = champ.verrouille or (section and section.verrouille)
        fond(actif and PALETTE.selection or PALETTE.fond)
        encre(actif and PALETTE.texteSelect or PALETTE.texte)
        ecrireA(xChamps, y, (verrouille and "\4 " or "  ") .. champ.libelle, largeurLibelle)
        if not actif then encre(verrouille and PALETTE.verrou or PALETTE.valeur) end
        ecrireA(xChamps + largeurLibelle, y, formaterValeur(valeurChamp(config, champ)),
          largeurChamps - largeurLibelle)
      else
        ligneVide(y, largeurChamps, xChamps)
      end
    end

    ------------------------------------------------------------------ aide + etat
    local champ = champCourant()
    fond(PALETTE.fond)
    encre(PALETTE.texteFaible)
    local aide = ""
    if champ then
      aide = champ.aide or champ.cle
      if #champs > visiblesChamps then
        aide = string.format("[%d/%d] %s", etat.champ, #champs, aide)
      end
    end
    ecrireA(1, hauteur - 1, " " .. aide, largeur)

    encre(etat.couleurMessage)
    fond(PALETTE.fondPanneau)
    ligneVide(hauteur, largeur)
    ecrireA(2, hauteur, etat.message:sub(1, largeur - 2))
  end

  local function signaler(texte, couleur)
    etat.message = texte
    etat.couleurMessage = couleur or PALETTE.texteFaible
  end

  local function modifierChamp()
    local section = sectionCourante()
    local champ = champCourant()
    if not champ then return end
    if champ.verrouille or (section and section.verrouille) then
      signaler("Valeur verrouillee : constante de reseau, non modifiable ici",
        PALETTE.verrou)
      return
    end

    local largeur = term.getSize()
    local xChamps = LARGEUR_SECTIONS + 2
    local largeurChamps = largeur - xChamps + 1
    local largeurLibelle = math.min(24, math.floor(largeurChamps * 0.55))
    local y = 1 + (etat.champ - etat.defilementChamps)
    local valeur = valeurChamp(config, champ)

    if champ.type == "booleen" then
      autopilote.interne.ecrire(config, champ.cle, not valeur)
      etat.modifie = true
      signaler(champ.libelle .. " -> " .. (not valeur and "oui" or "non"), PALETTE.bon)
      return
    end

    if champ.type == "choix" then
      local options = champ.options or {}
      local suivant = 1
      for i, option in ipairs(options) do
        if option == tostring(valeur) then suivant = i % #options + 1 break end
      end
      autopilote.interne.ecrire(config, champ.cle, options[suivant])
      etat.modifie = true
      signaler(champ.libelle .. " -> " .. tostring(options[suivant]), PALETTE.bon)
      return
    end

    local saisie = saisir(xChamps + largeurLibelle, y, largeurChamps - largeurLibelle,
      valeur == nil and "" or formaterValeur(valeur))
    local ok, motif = definirChamp(config, champ, saisie)
    if ok then
      etat.modifie = true
      signaler(champ.libelle .. " enregistre", PALETTE.bon)
    else
      signaler("Refuse : " .. tostring(motif), PALETTE.alerte)
    end
  end

  local function sauvegarder()
    local valide, anomalie = autopilote.verifierConfiguration(config)
    if not valide and not etat.sauvegardeForcee then
      etat.sauvegardeForcee = true
      signaler("INVALIDE : " .. tostring(anomalie):sub(1, 200)
        .. "  [S de nouveau pour forcer]", PALETTE.alerte)
      return
    end
    etat.sauvegardeForcee = false
    local fichier = fs.open(cheminConfig, "w")
    if not fichier then
      signaler("Ecriture impossible : " .. cheminConfig, PALETTE.alerte)
      return
    end
    fichier.write(autopilote.serialiserConfig(config))
    fichier.close()
    etat.modifie = false
    signaler("Configuration enregistree dans " .. cheminConfig
      .. (valide and "" or " (FORCEE, invalide)"), valide and PALETTE.bon or PALETTE.alerte)
  end

  ------------------------------------------------------------------ boucle d'evenements
  while true do
    dessiner()
    local evenement = { os.pullEvent() }
    local nom = evenement[1]
    etat.couleurMessage = PALETTE.texteFaible

    if nom == "key" then
      local touche = evenement[2]
      local section = sectionCourante()
      local champs = section and section.champs or {}

      if touche == keys.down then
        if etat.focus == "sections" then
          etat.section = math.min(#SCHEMA, etat.section + 1)
          etat.champ, etat.defilementChamps = 1, 0
        else
          etat.champ = math.min(#champs, etat.champ + 1)
        end
      elseif touche == keys.up then
        if etat.focus == "sections" then
          etat.section = math.max(1, etat.section - 1)
          etat.champ, etat.defilementChamps = 1, 0
        else
          etat.champ = math.max(1, etat.champ - 1)
        end
      elseif touche == keys.right or touche == keys.tab then
        etat.focus = "champs"
      elseif touche == keys.left then
        etat.focus = "sections"
      elseif touche == keys.enter or touche == keys.numPadEnter then
        if etat.focus == "sections" then etat.focus = "champs" else modifierChamp() end
      elseif touche == keys.s then
        sauvegarder()
      elseif touche == keys.r then
        signaler("Reglage en vol : lancez 'interface vol' sur le vehicule",
          PALETTE.texteFaible)
      elseif touche == keys.j then
        interface.journal({ config = config })
      elseif touche == keys.q then
        if etat.modifie and not etat.sauvegardeForcee then
          etat.sauvegardeForcee = true
          signaler("Modifications NON enregistrees. Q de nouveau pour quitter quand meme.",
            PALETTE.alerte)
        else
          ecran.restaurer()
          return true
        end
      end

    elseif nom == "mouse_click" then
      local x, y = evenement[3], evenement[4]
      local largeur, hauteur = term.getSize()
      if y > 1 and y < hauteur - 1 then
        if x <= LARGEUR_SECTIONS then
          local index = y - 1 + etat.defilementSections
          if SCHEMA[index] then
            etat.section, etat.champ, etat.defilementChamps = index, 1, 0
            etat.focus = "sections"
          end
        else
          local section = sectionCourante()
          local index = y - 1 + etat.defilementChamps
          if section and section.champs[index] then
            etat.focus = "champs"
            if etat.champ == index then modifierChamp() else etat.champ = index end
          end
        end
      end

    elseif nom == "mouse_scroll" then
      local direction = evenement[2]
      if etat.focus == "sections" then
        etat.section = math.max(1, math.min(#SCHEMA, etat.section + direction))
        etat.champ, etat.defilementChamps = 1, 0
      else
        local section = sectionCourante()
        etat.champ = math.max(1, math.min(#(section and section.champs or {}),
          etat.champ + direction))
      end

    elseif nom == "terminate" then
      ecran.restaurer()
      return false
    end
  end
end

--------------------------------------------------------------------------------
-- 4. MENU DE REGLAGE EN VOL
--    Affiche en temps reel, pour l'axe choisi : l'erreur courante, la vitesse
--    cible, la vitesse reelle et la commande envoyee, plus l'historique des
--    dernieres secondes. On voit immediatement si le reglage oscille (dents de
--    scie serrees) ou s'il traine (pente molle qui n'arrive jamais a zero).
--    Les gains se modifient a chaud, puis se sauvegardent dans la config.
--------------------------------------------------------------------------------

local AXES_MENU = {
  { cle = "altitude", libelle = "ALTITUDE", unite = "m",   uniteVitesse = "m/s" },
  { cle = "cap",      libelle = "CAP",      unite = "deg", uniteVitesse = "deg/s" },
  { cle = "avance",   libelle = "AVANCE",   unite = "m",   uniteVitesse = "m/s" },
  { cle = "derive",   libelle = "DERIVE",   unite = "m",   uniteVitesse = "m/s" },
}

local GAINS_MENU = { "kp", "ki", "kd" }

--- @param ap instance d'autopilote deja en vol (ap.executer() tourne a cote)
function interface.reglageEnVol(ap)
  local etat = {
    axe = 1, gain = 1, pas = 0.010, jeu = "croisiere",
    message = "Tab : axe   Haut/Bas : gain   + / - : regler   [ ] : pas   F2 : sauver",
    couleurMessage = PALETTE.texteFaible,
  }

  local function axeCourant() return AXES_MENU[etat.axe] end

  local function dessiner()
    local largeur, hauteur = term.getSize()
    local vol = ap.etat()
    local axe = axeCourant()
    local historique = ap.historique(axe.cle)
    local dernier = historique[#historique] or {}
    local gains = ap.config.gains[axe.cle][etat.jeu] or {}

    ecran.preparer()
    barre(1, largeur, "REGLAGE EN VOL  " .. axe.libelle,
      tostring(vol.mode) .. (vol.phase and ("/" .. vol.phase) or "") .. "  " .. heure())

    ------------------------------------------------------------------ etat de vol
    fond(PALETTE.fond)
    local y = 2
    encre(PALETTE.texteFaible)
    ecrireA(2, y, "erreur", 9)
    ecrireA(20, y, "commande", 10)
    encre(PALETTE.texte)
    ecrireA(11, y, string.format("%+7.2f%s", dernier.erreur or 0, axe.unite), 9)
    encre((dernier.sature and PALETTE.alerte) or PALETTE.valeur)
    ecrireA(31, y, string.format("%+6.2f%s", dernier.commande or 0,
      dernier.sature and " SAT" or ""), largeur - 31)

    y = y + 1
    encre(PALETTE.texteFaible)
    ecrireA(2, y, "v. cible", 9)
    ecrireA(20, y, "v. reelle", 10)
    encre(PALETTE.texte)
    ecrireA(11, y, string.format("%+7.2f", dernier.consigne or 0), 9)
    ecrireA(31, y, string.format("%+7.2f %s", dernier.mesure or 0, axe.uniteVitesse),
      largeur - 31)

    y = y + 1
    encre(PALETTE.texteFaible)
    ecrireA(2, y, "mode axe", 9)
    ecrireA(20, y, "jeu", 10)
    encre((vol.modesAxes[axe.cle] == "zone_morte") and PALETTE.verrou or PALETTE.bon)
    ecrireA(11, y, tostring(vol.modesAxes[axe.cle]), 9)
    encre(PALETTE.texte)
    ecrireA(31, y, string.format("%s%s", tostring(vol.jeuGains or "?"),
      (etat.jeu ~= vol.jeuGains) and (" (edite: " .. etat.jeu .. ")") or ""), largeur - 31)

    y = y + 1
    encre(PALETTE.texteFaible)
    ecrireA(2, y, "position", 9)
    encre(PALETTE.texte)
    if vol.position then
      ecrireA(11, y, string.format("X%.0f Y%.0f Z%.0f  cap %.0f (%s)  dt %.2fs",
        vol.position.x, vol.position.y, vol.position.z, vol.cap or 0,
        tostring(vol.sourceCap), vol.dt or 0), largeur - 11)
    else
      encre(PALETTE.alerte)
      ecrireA(11, y, "position inconnue", largeur - 11)
    end

    ------------------------------------------------------------------ gains
    y = y + 2
    fond(PALETTE.fondPanneau)
    encre(PALETTE.texte)
    ligneVide(y, largeur)
    local x = 2
    for index, nomGain in ipairs(GAINS_MENU) do
      local actif = (index == etat.gain)
      fond(actif and PALETTE.selection or PALETTE.fondPanneau)
      encre(actif and PALETTE.texteSelect or PALETTE.texte)
      ecrireA(x, y, string.format(" %s %8.4f ", nomGain, gains[nomGain] or 0))
      x = x + 14
    end
    fond(PALETTE.fondPanneau)
    encre(PALETTE.texteFaible)
    ecrireA(x + 1, y, string.format("pas %.4f", etat.pas), largeur - x - 1)

    ------------------------------------------------------------------ courbes
    fond(PALETTE.fond)
    local hauteurCourbe = math.max(3, math.floor((hauteur - y - 4) / 2))
    local erreurs, commandes = {}, {}
    for _, ligne in ipairs(historique) do
      erreurs[#erreurs + 1] = ligne.erreur or 0
      commandes[#commandes + 1] = ligne.commande or 0
    end
    tracerCourbe(2, y + 1, largeur - 2, hauteurCourbe, erreurs, PALETTE.accent,
      "erreur " .. axe.unite)
    tracerCourbe(2, y + 1 + hauteurCourbe, largeur - 2, hauteurCourbe, commandes,
      PALETTE.bon, "commande")

    ------------------------------------------------------------------ barres du bas
    fond(PALETTE.fond)
    encre(PALETTE.texteFaible)
    ecrireA(1, hauteur - 1, string.format(
      " P:PID  Z:zone morte  A:auto  J:jeu  F2:sauver  Q:quitter   pilotage=%s",
      tostring(ap.config.pilotage.mode)), largeur)
    fond(PALETTE.fondPanneau)
    encre(etat.couleurMessage)
    ligneVide(hauteur, largeur)
    ecrireA(2, hauteur, etat.message:sub(1, largeur - 2))
  end

  local function signaler(texte, couleur)
    etat.message = texte
    etat.couleurMessage = couleur or PALETTE.texteFaible
  end

  local function ajusterGain(sens)
    local axe = axeCourant()
    local nomGain = GAINS_MENU[etat.gain]
    local gains = ap.config.gains[axe.cle][etat.jeu]
    local valeur = math.max(0, (gains[nomGain] or 0) + sens * etat.pas)
    ap.reglerGains(axe.cle, etat.jeu, { [nomGain] = valeur })
    signaler(string.format("%s.%s.%s = %.4f", axe.cle, etat.jeu, nomGain, valeur),
      PALETTE.bon)
  end

  local minuteur = os.startTimer(0.3)
  while true do
    dessiner()
    local evenement = { os.pullEvent() }
    local nom = evenement[1]

    if nom == "timer" and evenement[2] == minuteur then
      minuteur = os.startTimer(0.3)

    elseif nom == "char" then
      local caractere = evenement[2]
      if caractere == "+" or caractere == "=" then ajusterGain(1)
      elseif caractere == "-" or caractere == "_" then ajusterGain(-1)
      elseif caractere == "[" then
        etat.pas = math.max(0.0001, etat.pas / 10)
        signaler(string.format("pas de reglage : %.4f", etat.pas))
      elseif caractere == "]" then
        etat.pas = math.min(1, etat.pas * 10)
        signaler(string.format("pas de reglage : %.4f", etat.pas))
      end

    elseif nom == "key" then
      local touche = evenement[2]
      if touche == keys.tab or touche == keys.right then
        etat.axe = etat.axe % #AXES_MENU + 1
      elseif touche == keys.left then
        etat.axe = (etat.axe - 2) % #AXES_MENU + 1
      elseif touche == keys.up then
        etat.gain = math.max(1, etat.gain - 1)
      elseif touche == keys.down then
        etat.gain = math.min(#GAINS_MENU, etat.gain + 1)
      elseif touche == keys.j then
        etat.jeu = (etat.jeu == "croisiere") and "maintien" or "croisiere"
        signaler("jeu de gains edite : " .. etat.jeu)
      elseif touche == keys.p then
        ap.definirMode("pid")
        signaler("PID force sur tous les axes", PALETTE.bon)
      elseif touche == keys.z then
        ap.definirMode("zone_morte")
        signaler("ZONE MORTE forcee sur tous les axes", PALETTE.verrou)
      elseif touche == keys.a then
        ap.definirMode("auto")
        signaler("pilotage automatique (PID + repli)", PALETTE.bon)
      elseif touche == keys.f2 then
        local ok, motif = ap.sauvegarderConfig()
        signaler(ok and "Gains enregistres dans la configuration du vehicule"
          or ("Sauvegarde impossible : " .. tostring(motif)),
          ok and PALETTE.bon or PALETTE.alerte)
      elseif touche == keys.q then
        ecran.restaurer()
        return true
      end

    elseif nom == "terminate" then
      ecran.restaurer()
      error("Terminated", 0)
    end
  end
end

--------------------------------------------------------------------------------
-- 5. CONSULTATION DU JOURNAL
--------------------------------------------------------------------------------

function interface.journal(options)
  options = options or {}
  local chemin = (options.config and options.config.journal and options.config.journal.chemin)
    or "/autopilote/autopilote.log"

  local lignes = {}
  if fs.exists(chemin) then
    local fichier = fs.open(chemin, "r")
    while true do
      local ligne = fichier.readLine()
      if not ligne then break end
      lignes[#lignes + 1] = ligne
    end
    fichier.close()
  end

  local largeur, hauteur = term.getSize()
  local visibles = hauteur - 2
  local defilement = math.max(0, #lignes - visibles)

  while true do
    ecran.preparer()
    barre(1, largeur, "JOURNAL DE L'AUTOPILOTE",
      string.format("%d lignes", #lignes))
    fond(PALETTE.fond)
    for ligne = 1, visibles do
      local index = ligne + defilement
      local texte = lignes[index] or ""
      if texte:find("[ERREUR]", 1, true) or texte:find("[CRITIQUE]", 1, true) then
        encre(PALETTE.alerte)
      elseif texte:find("[AVERT]", 1, true) then
        encre(PALETTE.verrou)
      elseif texte:find("[DEBUG]", 1, true) then
        encre(PALETTE.texteFaible)
      else
        encre(PALETTE.texte)
      end
      ecrireA(1, ligne + 1, texte, largeur)
    end
    fond(PALETTE.fondPanneau)
    encre(PALETTE.texteFaible)
    ligneVide(hauteur, largeur)
    ecrireA(2, hauteur, "Haut/Bas : defiler   Q : retour   (" .. chemin .. ")")

    local evenement = { os.pullEvent() }
    if evenement[1] == "key" then
      local touche = evenement[2]
      if touche == keys.down then
        defilement = math.min(math.max(0, #lignes - visibles), defilement + 1)
      elseif touche == keys.up then
        defilement = math.max(0, defilement - 1)
      elseif touche == keys.pageDown then
        defilement = math.min(math.max(0, #lignes - visibles), defilement + visibles)
      elseif touche == keys.pageUp then
        defilement = math.max(0, defilement - visibles)
      elseif touche == keys.q then
        return true
      end
    elseif evenement[1] == "mouse_scroll" then
      defilement = math.max(0, math.min(math.max(0, #lignes - visibles),
        defilement + evenement[2]))
    elseif evenement[1] == "terminate" then
      return false
    end
  end
end

--------------------------------------------------------------------------------
-- 6. POINT D'ENTREE
--    Lance l'ecran demande si le fichier est execute depuis le shell ; se
--    contente de renvoyer la bibliotheque s'il est charge par un programme.
--------------------------------------------------------------------------------

--- Autopilote en maintien de position + menu de reglage en vol.
function interface.vol(options)
  options = options or {}
  local ap = autopilote.nouveau({ config = options.config })
  ap.surEvenement(function(typeEvenement, donnees)
    if typeEvenement == "anomalie" then
      -- Les anomalies restent visibles dans le journal, l'ecran est occupe.
      ap.journal.avert("interface", "anomalie signalee : " .. tostring(donnees.motif))
    end
  end)
  ap.initialiser()
  ap.maintenirPosition()
  parallel.waitForAny(
    function() ap.executer() end,
    function() interface.reglageEnVol(ap) ap.stopper() end)
  ap.arreter("fin du reglage en vol")
  ecran.restaurer()
  return true
end

function interface.demarrer(...)
  local arguments = { ... }
  local commande = tostring(arguments[1] or "config"):lower()
  if commande == "vol" or commande == "reglage" then
    return interface.vol()
  elseif commande == "journal" or commande == "log" then
    local ok = interface.journal()
    ecran.restaurer()
    return ok
  end
  return interface.configurer()
end

local function lanceDepuisLeShell()
  if not (shell and shell.getRunningProgram) then return false end
  local ok, chemin = pcall(shell.getRunningProgram)
  if not ok or type(chemin) ~= "string" then return false end
  return chemin:gsub("^/", "") == "autopilote/interface.lua"
end

if lanceDepuisLeShell() then
  interface.demarrer(...)
end

return interface
