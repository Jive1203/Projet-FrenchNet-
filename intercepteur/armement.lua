--[[----------------------------------------------------------------------------
  FRENCHNET / AERONAUTICS WARFARE - Arsenal embarque (Create Big Cannons)
  --------------------------------------------------------------------------
  Le navire ne porte plus UNE arme mais un ARSENAL : une liste d'armes
  declarees dans la configuration, chacune avec sa portee, son utilite, sa
  balistique et son mode de declenchement. A chaque engagement, le systeme
  choisit l'arme adaptee a la distance et a la nature de la cible.

  Une arme se decrit ainsi :

      {
        identifiant = "CANON-AA-1",
        nom         = "Canon automatique 4 pouces",
        utilite     = "anti-aerien",   -- ou anti-sol / defensif / polyvalent
        mode        = "peripherique",  -- ou redstone / mixte
        coteArme    = nil,             -- nil = detection automatique
        coteRedstone= nil,
        porteeMini  = 80,   porteeMaxi  = 420,
        vitesseObus = 80,   graviteObus = 9.8,
        dureeRafale = 1.5,  pauseRafale = 2.0,
        actif       = true,
      }

  REGLE D'ENGAGEMENT : l'ordre de tir prime sur la position. La selection
  d'arme ne tient donc compte QUE de ce qui rend le coup possible - portee et
  utilite - jamais de la place du navire dans son arc arriere.

  Une arme qui ne repond pas au demarrage est marquee indisponible et
  journalisee, mais ne compromet jamais les autres : un navire avec trois
  canons dont un casse est un navire avec deux canons, pas un navire au sol.

  Chargement : local noyau = ...
--------------------------------------------------------------------------------]]

local noyau = ...
local E = noyau.ETAPES
local journal = noyau.journal

local M = {}

--------------------------------------------------------------------------------
-- 1. UTILITES RECONNUES
--    'polyvalent' repond a toute demande ; une arme specialisee ne repond
--    qu'a la sienne. C'est ce qui evite de tirer un obus anti-sol sur un
--    intercepteur, ou l'inverse.
--------------------------------------------------------------------------------

M.UTILITES = {
  ["anti-aerien"] = { libelle = "anti-aerien", repond = { ["anti-aerien"] = true } },
  ["anti-sol"]    = { libelle = "anti-sol",    repond = { ["anti-sol"] = true } },
  ["defensif"]    = { libelle = "defensif",    repond = { ["defensif"] = true } },
  ["polyvalent"]  = { libelle = "polyvalent",
    repond = { ["anti-aerien"] = true, ["anti-sol"] = true, ["defensif"] = true } },
}

function M.utiliteValide(nom)
  return M.UTILITES[tostring(nom)] ~= nil
end

--- Une arme d'utilite 'utiliteArme' peut-elle traiter un besoin 'besoin' ?
function M.repondA(utiliteArme, besoin)
  local u = M.UTILITES[tostring(utiliteArme)]
  if not u then return false end
  return u.repond[tostring(besoin)] == true
end

--------------------------------------------------------------------------------
-- 2. DETECTION DES AFFUTS
--------------------------------------------------------------------------------

local METHODES = {
  lacet       = { "setYaw", "setYawTarget", "yaw", "definirLacet" },
  tangage     = { "setPitch", "setPitchTarget", "pitch", "definirTangage" },
  feu         = { "fire", "shoot", "tirer", "trigger", "fireAll" },
  lireLacet   = { "getYaw", "yaw", "obtenirLacet" },
  lireTangage = { "getPitch", "pitch", "obtenirTangage" },
  pret        = { "isRunning", "isAssembled", "canFire", "estPret" },
}

local function estAffut(nom)
  local ok, typePeripherique = pcall(peripheral.getType, nom)
  if not ok or type(typePeripherique) ~= "string" then return false end
  local t = typePeripherique:lower()
  return t:find("cannon", 1, true) ~= nil
      or t:find("mount", 1, true) ~= nil
      or t:find("canon", 1, true) ~= nil
end

--- Liste les affuts detectes qui ne sont pas deja attribues a une arme.
local function affutsLibres(attribues)
  local libres = {}
  for _, nom in ipairs(peripheral.getNames()) do
    if estAffut(nom) and not attribues[nom] then libres[#libres + 1] = nom end
  end
  return libres
end

local function lierAffut(arme, nom)
  local affut = peripheral.wrap(nom)
  if type(affut) ~= "table" then return false end
  local correspondances = {}
  for role, noms in pairs(METHODES) do
    local fn, nomRetenu = noyau.resoudreMethode(affut, noms)
    if fn then
      arme.lien[role] = fn
      correspondances[#correspondances + 1] = role .. " -> " .. nomRetenu .. "()"
    end
  end
  if not (arme.lien.lacet and arme.lien.tangage) then
    arme.lien = {}
    return false
  end
  arme.affut = affut
  arme.cote  = nom
  table.sort(correspondances)
  journal.info(E.DETECTION_ARME, string.format("%s : affut sur '%s' | %s",
    arme.identifiant, nom, table.concat(correspondances, ", ")))
  return true
end

--------------------------------------------------------------------------------
-- 3. CONSTRUCTION DE L'ARSENAL
--------------------------------------------------------------------------------

local DEFAUTS_ARME = {
  utilite     = "polyvalent",
  mode        = "peripherique",
  porteeMini  = 80,
  porteeMaxi  = 420,
  vitesseObus = 80,
  graviteObus = 9.8,
  iterationsTir = 4,
  dureeRafale = 1.5,
  pauseRafale = 2.0,
  tangageMini = -60,
  tangageMaxi = 60,
  actif       = true,
}

local function completer(declaration, indice)
  local arme = {}
  for cle, valeur in pairs(DEFAUTS_ARME) do arme[cle] = valeur end
  for cle, valeur in pairs(declaration) do arme[cle] = valeur end

  arme.identifiant = tostring(arme.identifiant or ("ARME-" .. indice))
  arme.nom         = tostring(arme.nom or arme.identifiant)
  arme.lien        = {}
  arme.affut       = nil
  arme.cote        = nil
  arme.disponible  = false
  arme.enRafale    = false
  arme.debutRafale = 0
  arme.finRafale   = -math.huge
  arme.rafales     = 0
  arme.indisponibilite = nil
  return arme
end

--- Anomalies bloquantes dans la declaration d'une arme.
function M.verifierArme(arme)
  local anomalies = {}
  if not M.utiliteValide(arme.utilite) then
    local noms = {}
    for cle in pairs(M.UTILITES) do noms[#noms + 1] = cle end
    table.sort(noms)
    anomalies[#anomalies + 1] = "utilite '" .. tostring(arme.utilite)
      .. "' inconnue (valeurs acceptees : " .. table.concat(noms, ", ") .. ")"
  end
  if not (noyau.nombreValide(arme.porteeMini) and noyau.nombreValide(arme.porteeMaxi))
     or arme.porteeMini < 0 or arme.porteeMini >= arme.porteeMaxi then
    anomalies[#anomalies + 1] = "portees incoherentes : porteeMini doit etre >= 0 "
      .. "et strictement inferieure a porteeMaxi"
  end
  if not noyau.nombreValide(arme.vitesseObus) or arme.vitesseObus <= 0 then
    anomalies[#anomalies + 1] = "'vitesseObus' doit etre un nombre > 0"
  end
  local modes = { peripherique = true, redstone = true, mixte = true }
  if not modes[tostring(arme.mode)] then
    anomalies[#anomalies + 1] = "mode '" .. tostring(arme.mode)
      .. "' inconnu (peripherique, redstone ou mixte)"
  end
  if (arme.mode == "redstone" or arme.mode == "mixte")
     and (type(arme.coteRedstone) ~= "string" or arme.coteRedstone == "") then
    anomalies[#anomalies + 1] = "mode " .. arme.mode .. " sans 'coteRedstone'"
  end
  return anomalies
end

--- Construit l'arsenal a partir du bloc 'arme' de la configuration.
function M.creerArsenal(configArme)
  local arsenal = {
    config = configArme,
    armes  = {},
    coups  = 0,
  }

  local declarations = configArme.armes
  if type(declarations) ~= "table" or #declarations == 0 then
    error("aucune arme declaree : renseignez 'arme.armes' dans la configuration, "
      .. "ou utilisez la page Armement du systeme d'exploitation.", 0)
  end

  local attribues = {}
  -- Premier passage : les armes dont le cote est impose reservent leur affut,
  -- afin que la detection automatique ne le leur prenne pas.
  for _, declaration in ipairs(declarations) do
    if type(declaration.coteArme) == "string" and declaration.coteArme ~= "" then
      attribues[declaration.coteArme] = true
    end
  end

  for indice, declaration in ipairs(declarations) do
    local arme = completer(declaration, indice)
    local anomalies = M.verifierArme(arme)

    if #anomalies > 0 then
      arme.indisponibilite = table.concat(anomalies, " | ")
      journal.erreur(E.DETECTION_ARME, string.format(
        "%s ecartee : %s", arme.identifiant, arme.indisponibilite))

    elseif not arme.actif then
      arme.indisponibilite = "desactivee dans la configuration"
      journal.info(E.DETECTION_ARME, arme.identifiant .. " : desactivee, non armee")

    else
      local besoinAffut = (arme.mode == "peripherique" or arme.mode == "mixte")
      local lie = true

      if besoinAffut then
        lie = false
        if arme.coteArme then
          if peripheral.isPresent(arme.coteArme) then
            lie = lierAffut(arme, arme.coteArme)
            if not lie then
              arme.indisponibilite = "le peripherique '" .. arme.coteArme
                .. "' n'expose pas de commande de pointage"
            end
          else
            arme.indisponibilite = "aucun peripherique sur le cote impose '"
              .. arme.coteArme .. "'"
          end
        else
          for _, nom in ipairs(affutsLibres(attribues)) do
            if lierAffut(arme, nom) then
              attribues[nom] = true
              lie = true
              break
            end
          end
          if not lie then
            arme.indisponibilite = "aucun affut pilotable libre a bord"
          end
        end
      end

      if lie or arme.mode == "redstone" then
        arme.disponible = true
        if arme.mode == "redstone" or arme.mode == "mixte" then
          journal.info(E.DETECTION_ARME, string.format(
            "%s : mise a feu par redstone sur '%s'", arme.identifiant, arme.coteRedstone))
        end
        if arme.mode == "mixte" and not lie then
          journal.avert(E.DETECTION_ARME, string.format(
            "%s : aucun affut pilotable, le pointage sera assure par le vol du navire",
            arme.identifiant))
        end
      else
        journal.avert(E.DETECTION_ARME, string.format(
          "%s INDISPONIBLE : %s", arme.identifiant, tostring(arme.indisponibilite)))
      end
    end

    arsenal.armes[#arsenal.armes + 1] = arme
  end

  local disponibles = 0
  for _, arme in ipairs(arsenal.armes) do
    if arme.disponible then disponibles = disponibles + 1 end
  end

  if disponibles == 0 then
    error("aucune arme disponible sur les " .. #arsenal.armes .. " declaree(s). "
      .. "Le navire peut voler mais ne peut pas engager. Verifiez les affuts et "
      .. "la page Armement du systeme d'exploitation.", 0)
  end

  journal.info(E.DETECTION_ARME, string.format(
    "arsenal operationnel : %d arme(s) disponible(s) sur %d declaree(s) | %s",
    disponibles, #arsenal.armes, M.resume(arsenal)))

  return arsenal
end

--- Ligne de resume, pour le journal et l'ecran d'etat du systeme.
function M.resume(arsenal)
  local morceaux = {}
  for _, arme in ipairs(arsenal.armes) do
    morceaux[#morceaux + 1] = string.format("%s (%s, %.0f-%.0f blocs)%s",
      arme.identifiant, arme.utilite, arme.porteeMini, arme.porteeMaxi,
      arme.disponible and "" or " [INDISPONIBLE]")
  end
  return table.concat(morceaux, " ; ")
end

--------------------------------------------------------------------------------
-- 4. CHOIX DE L'ARME
--------------------------------------------------------------------------------

--- Selectionne l'arme la mieux adaptee.
--
-- Criteres, dans cet ordre :
--   1. disponible et active ;
--   2. utilite compatible avec le besoin ('polyvalent' repond a tout) ;
--   3. distance comprise dans sa fenetre de portee ;
--   4. a egalite, celle dont la distance tombe le plus au centre de sa
--      fenetre - une arme utilisee au milieu de sa portee est plus precise
--      qu'une arme utilisee a son extremite ;
--   5. a egalite encore, l'arme specialisee passe avant la polyvalente.
--
-- @return arme, motifRefus (quand aucune arme ne convient)
function M.choisir(arsenal, besoin, distance)
  besoin = besoin or "anti-aerien"
  local meilleure, meilleurScore = nil, -math.huge
  local horsPortee, mauvaiseUtilite, indisponibles = 0, 0, 0

  for _, arme in ipairs(arsenal.armes) do
    if not arme.disponible then
      indisponibles = indisponibles + 1
    elseif not M.repondA(arme.utilite, besoin) then
      mauvaiseUtilite = mauvaiseUtilite + 1
    elseif distance < arme.porteeMini or distance > arme.porteeMaxi then
      horsPortee = horsPortee + 1
    else
      local centre = (arme.porteeMini + arme.porteeMaxi) / 2
      local demiFenetre = math.max((arme.porteeMaxi - arme.porteeMini) / 2, 1)
      -- 1 au centre de la fenetre, 0 a ses bords.
      local score = 1 - math.abs(distance - centre) / demiFenetre
      if arme.utilite ~= "polyvalent" then score = score + 0.25 end
      if score > meilleurScore then meilleure, meilleurScore = arme, score end
    end
  end

  if meilleure then return meilleure, nil end

  return nil, string.format(
    "aucune arme utilisable a %.0f blocs pour un besoin '%s' "
    .. "(%d hors portee, %d d'utilite incompatible, %d indisponible(s))",
    distance, besoin, horsPortee, mauvaiseUtilite, indisponibles)
end

--- Distance de tir ideale de l'arme : le centre de sa fenetre de portee.
-- C'est la distance que le navire cherche a tenir sous ordre de feu, a la
-- place de la bande de l'arc arriere.
function M.distanceIdeale(arme)
  return (arme.porteeMini + arme.porteeMaxi) / 2
end

--------------------------------------------------------------------------------
-- 5. POINTAGE
--------------------------------------------------------------------------------

function M.pointer(arme, solution)
  if not arme.affut then return false end
  local ok = true
  if arme.lien.lacet then
    ok = noyau.proteger(E.SOLUTION_TIR, arme.lien.lacet, solution.azimut) and ok
    arme.dernierLacet = solution.azimut
  end
  if arme.lien.tangage then
    local tangage = noyau.borner(solution.elevation, arme.tangageMini, arme.tangageMaxi)
    ok = noyau.proteger(E.SOLUTION_TIR, arme.lien.tangage, tangage) and ok
    arme.dernierTangage = tangage
    arme.tangageSature = math.abs(tangage - solution.elevation) > 0.5
  end
  return ok
end

--- Ecart angulaire entre l'orientation reelle de l'affut et la solution.
-- Sans retour d'affut on suppose le pointage acquis : c'est la seule
-- hypothese possible, et elle est signalee au demarrage.
function M.erreurVisee(arme, solution)
  if not arme.affut or not arme.lien.lireLacet then return 0 end

  local okLacet, lacet = noyau.proteger(E.SOLUTION_TIR, arme.lien.lireLacet)
  if not okLacet or not noyau.nombreValide(lacet) then return 0 end

  local erreur = math.abs(noyau.ecartAngulaire(lacet, solution.azimut))

  if arme.lien.lireTangage then
    local okTangage, tangage = noyau.proteger(E.SOLUTION_TIR, arme.lien.lireTangage)
    if okTangage and noyau.nombreValide(tangage) then
      erreur = math.max(erreur, math.abs(tangage - solution.elevation))
    end
  end
  return erreur
end

--------------------------------------------------------------------------------
-- 6. MISE A FEU
--------------------------------------------------------------------------------

local function declencher(arme, actif)
  local ok = true
  if arme.lien.feu and actif then
    ok = noyau.proteger(E.TIR, arme.lien.feu) and ok
  end
  if arme.coteRedstone and (arme.mode == "redstone" or arme.mode == "mixte") then
    ok = noyau.proteger(E.TIR, function()
      redstone.setOutput(arme.coteRedstone, actif)
    end) and ok
  end
  return ok
end

--- Gere la cadence d'une arme. A appeler a chaque cycle tant que le feu est
-- autorise ; appeler M.cesserLeFeu des que l'autorisation tombe.
-- @return true si une rafale vient de s'ouvrir
function M.entretenirRafale(arsenal, arme, maintenant, description)
  if arme.enRafale then
    if maintenant - arme.debutRafale >= arme.dureeRafale then
      arme.enRafale = false
      arme.finRafale = maintenant
      declencher(arme, false)
      journal.info(E.TIR, string.format("%s : fin de rafale apres %.1fs (%d rafale(s))",
        arme.identifiant, maintenant - arme.debutRafale, arme.rafales))
    end
    return false
  end

  if maintenant - arme.finRafale < arme.pauseRafale then return false end

  arme.enRafale    = true
  arme.debutRafale = maintenant
  arme.rafales     = arme.rafales + 1
  arsenal.coups    = arsenal.coups + 1
  declencher(arme, true)

  journal.info(E.TIR, string.format("%s (%s) : rafale n%d ouverte | %s",
    arme.identifiant, arme.nom, arme.rafales,
    description or "solution de tir acquise"))
  return true
end

--- Interrompt le tir. Sans 'arme', tout l'arsenal fait silence : c'est ce qui
-- est appele en evasion, a la perte de contact et en fin de mission.
function M.cesserLeFeu(arsenal, motif, arme)
  local liste = arme and { arme } or arsenal.armes
  for _, a in ipairs(liste) do
    local etait = a.enRafale
    if a.enRafale or a.coteRedstone then
      a.enRafale = false
      a.finRafale = noyau.maintenant()
      declencher(a, false)
    end
    if etait then
      journal.info(E.ARME_SILENCE, string.format("%s : cessez-le-feu - %s",
        a.identifiant, motif or "condition de tir perdue"))
    end
  end
end

--- Une arme est-elle en train de tirer ?
function M.enAction(arsenal)
  for _, arme in ipairs(arsenal.armes) do
    if arme.enRafale then return true, arme end
  end
  return false, nil
end

return M
