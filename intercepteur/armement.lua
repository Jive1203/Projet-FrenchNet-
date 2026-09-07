--[[----------------------------------------------------------------------------
  FRENCHNET / AERONAUTICS WARFARE - Arme embarquee (Create Big Cannons)
  --------------------------------------------------------------------------
  Role : pointer l'arme sur la solution de tir calculee et declencher le tir,
         SANS jamais autoriser le navire a quitter son arc arriere.

  Deux modes de commande, choisis dans la configuration :
    * "peripherique" : affut motorise expose comme peripherique CC: Tweaked
      (setYaw / setPitch / fire). C'est le mode nominal.
    * "redstone"     : l'arme est declenchee par un signal redstone sur un
      cote donne. Montage le plus courant sur un serveur, et le seul possible
      si l'affut n'expose pas de peripherique.
  Les deux peuvent etre combines : pointage par peripherique, mise a feu par
  redstone ("mixte").

  L'orientation est exprimee en lacet Minecraft (0 = sud/+Z, 90 = ouest/-X),
  qui est exactement la convention de relevement du noyau : aucune conversion
  n'est necessaire entre la solution de tir et la commande d'affut.

  Chargement : local noyau = ...
--------------------------------------------------------------------------------]]

local noyau = ...
local E = noyau.ETAPES
local journal = noyau.journal

local M = {}

--------------------------------------------------------------------------------
-- 1. DETECTION DE L'AFFUT
--------------------------------------------------------------------------------

local METHODES = {
  lacet     = { "setYaw", "setYawTarget", "yaw", "definirLacet" },
  tangage   = { "setPitch", "setPitchTarget", "pitch", "definirTangage" },
  feu       = { "fire", "shoot", "tirer", "trigger", "fireAll" },
  lireLacet = { "getYaw", "yaw", "obtenirLacet" },
  lireTangage = { "getPitch", "pitch", "obtenirTangage" },
  pret      = { "isRunning", "isAssembled", "canFire", "estPret" },
}

local function estAffut(nom)
  local ok, typePeripherique = pcall(peripheral.getType, nom)
  if not ok or type(typePeripherique) ~= "string" then return false end
  local t = typePeripherique:lower()
  return t:find("cannon", 1, true) ~= nil
      or t:find("mount", 1, true) ~= nil
      or t:find("canon", 1, true) ~= nil
end

--------------------------------------------------------------------------------
-- 2. CONTEXTE D'ARMEMENT
--------------------------------------------------------------------------------

function M.creerContexte(configArme)
  local contexte = {
    config       = configArme,
    mode         = configArme.mode or "peripherique",
    affut        = nil,
    cote         = nil,
    lien         = {},
    coteRedstone = configArme.coteRedstone,
    enRafale     = false,
    debutRafale  = 0,
    finRafale    = 0,
    coups        = 0,
    dernierLacet = nil,
    dernierTangage = nil,
  }

  if contexte.mode == "peripherique" or contexte.mode == "mixte" then
    local candidats = {}
    if type(configArme.coteArme) == "string" and configArme.coteArme ~= "" then
      candidats[1] = configArme.coteArme
    else
      for _, nom in ipairs(peripheral.getNames()) do
        if estAffut(nom) then candidats[#candidats + 1] = nom end
      end
    end

    for _, nom in ipairs(candidats) do
      local affut = peripheral.wrap(nom)
      local correspondances = {}
      for role, noms in pairs(METHODES) do
        local fn, nomRetenu = noyau.resoudreMethode(affut, noms)
        if fn then
          contexte.lien[role] = fn
          correspondances[#correspondances + 1] = role .. " -> " .. nomRetenu .. "()"
        end
      end
      if contexte.lien.lacet and contexte.lien.tangage then
        contexte.affut, contexte.cote = affut, nom
        journal.info(E.DETECTION_ARME, "affut detecte sur '" .. nom .. "'")
        journal.info(E.DETECTION_ARME, "correspondance d'API : "
          .. table.concat(correspondances, ", "))
        break
      end
    end

    if not contexte.affut then
      if contexte.mode == "peripherique" then
        error("aucun affut Create Big Cannons pilotable detecte. Reglez "
          .. "'arme.mode' sur \"redstone\" si l'arme est declenchee par signal, "
          .. "ou renseignez 'arme.coteArme'.", 0)
      end
      journal.avert(E.DETECTION_ARME,
        "aucun affut pilotable : le pointage sera assure par le vol du navire, "
        .. "la mise a feu par redstone")
    end
  end

  if contexte.mode == "redstone" or contexte.mode == "mixte" then
    if type(contexte.coteRedstone) ~= "string" or contexte.coteRedstone == "" then
      error("mode de tir redstone demande mais 'arme.coteRedstone' n'est pas "
        .. "renseigne dans la configuration", 0)
    end
    journal.info(E.DETECTION_ARME,
      "mise a feu par redstone sur le cote '" .. contexte.coteRedstone .. "'")
  end

  return contexte
end

--------------------------------------------------------------------------------
-- 3. POINTAGE
--------------------------------------------------------------------------------

--- Oriente l'affut sur la solution de tir.
-- @return true si l'affut a accepte la commande
function M.pointer(contexte, solution)
  if not contexte.affut then return false end

  local ok = true
  if contexte.lien.lacet then
    ok = noyau.proteger(E.SOLUTION_TIR, contexte.lien.lacet, solution.azimut) and ok
    contexte.dernierLacet = solution.azimut
  end
  if contexte.lien.tangage then
    local tangage = noyau.borner(solution.elevation,
      contexte.config.tangageMini or -60, contexte.config.tangageMaxi or 60)
    ok = noyau.proteger(E.SOLUTION_TIR, contexte.lien.tangage, tangage) and ok
    contexte.dernierTangage = tangage
  end
  return ok
end

--- Ecart angulaire entre l'orientation reelle de l'affut et la solution.
-- Sans retour d'affut, on suppose le pointage acquis : c'est la seule
-- hypothese possible, et elle est journalisee au demarrage.
function M.erreurVisee(contexte, solution)
  if not contexte.affut or not contexte.lien.lireLacet then return 0 end

  local okLacet, lacet = noyau.proteger(E.SOLUTION_TIR, contexte.lien.lireLacet)
  if not okLacet or not noyau.nombreValide(lacet) then return 0 end

  local erreur = math.abs(noyau.ecartAngulaire(lacet, solution.azimut))

  if contexte.lien.lireTangage then
    local okTangage, tangage = noyau.proteger(E.SOLUTION_TIR, contexte.lien.lireTangage)
    if okTangage and noyau.nombreValide(tangage) then
      erreur = math.max(erreur, math.abs(tangage - solution.elevation))
    end
  end
  return erreur
end

--------------------------------------------------------------------------------
-- 4. MISE A FEU
--    Le tir se fait par rafales : une rafale continue chauffe l'arme et vide
--    la soute sans gain de precision.
--------------------------------------------------------------------------------

local function declencher(contexte, actif)
  local ok = true
  if contexte.lien.feu and actif then
    ok = noyau.proteger(E.TIR, contexte.lien.feu) and ok
  end
  if contexte.coteRedstone then
    ok = noyau.proteger(E.TIR, function()
      redstone.setOutput(contexte.coteRedstone, actif)
    end) and ok
  end
  return ok
end

--- Gere la cadence de tir. A appeler a chaque cycle tant que le feu est
-- autorise ; appeler M.cesserLeFeu des que l'autorisation tombe.
-- @return true si un coup vient d'etre declenche
function M.entretenirRafale(contexte, maintenant, description)
  local dureeRafale = contexte.config.dureeRafale or 1.5
  local pauseRafale = contexte.config.pauseRafale or 2.0

  if contexte.enRafale then
    if maintenant - contexte.debutRafale >= dureeRafale then
      contexte.enRafale = false
      contexte.finRafale = maintenant
      declencher(contexte, false)
      journal.info(E.TIR, string.format(
        "fin de rafale apres %.1fs (%d rafale(s) depuis le debut de l'engagement)",
        maintenant - contexte.debutRafale, contexte.coups))
    end
    return false
  end

  if maintenant - contexte.finRafale < pauseRafale then
    return false
  end

  contexte.enRafale    = true
  contexte.debutRafale = maintenant
  contexte.coups       = contexte.coups + 1
  declencher(contexte, true)

  journal.info(E.TIR, string.format("rafale n%d ouverte | %s",
    contexte.coups, description or "solution de tir acquise"))
  return true
end

--- Interrompt immediatement le tir. Appelee des que le navire quitte l'arc,
-- passe en evasion, ou perd le contact : le silence doit etre instantane.
function M.cesserLeFeu(contexte, motif)
  if not contexte.enRafale and not contexte.coteRedstone then return end
  local etait = contexte.enRafale
  contexte.enRafale = false
  contexte.finRafale = noyau.maintenant()
  declencher(contexte, false)
  if etait then
    journal.info(E.ARME_SILENCE, "cessez-le-feu : " .. (motif or "condition de tir perdue"))
  end
end

return M
