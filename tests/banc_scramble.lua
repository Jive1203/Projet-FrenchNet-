--[[----------------------------------------------------------------------------
  BANC D'ESSAI DE SCRAMBLE
  --------------------------------------------------------------------------
  Enveloppe tests/banc_vol.lua (mini-CraftOS + modele physique du vehicule +
  GPS bruite) et lui ajoute ce qui manque pour faire tourner le systeme
  embarque complet :

    * un VRAI ordonnanceur parallel. Celui du banc de vol n'execute que la
      premiere fonction, ce qui suffit a l'autopilote seul mais pas au navire
      intercepteur : sa boucle de vol, sa liaison sol, son radar, son controle
      et sa surveillance tournent cote a cote.
    * des minuteurs et un sleep qui RENDENT LA MAIN au lieu de faire avancer le
      temps sur place, sans quoi une tache monopoliserait l'horloge.
    * rednet, absent du banc de vol.

  Le temps n'avance que dans la boucle motrice, entre deux evenements, en
  appelant le pas physique du banc de vol : les commandes moteur calculees par
  le vrai module d'autopilote deplacent reellement le vehicule simule.
--------------------------------------------------------------------------------]]

local M = {}

function M.creer(cheminBancVol, options)
  local bancVol = dofile(cheminBancVol)
  local env, etat = bancVol.creer(options)

  local ordonnanceur = {
    file      = {},
    minuteurs = {},
    prochain  = 0,
  }

  ----------------------------------------------------------------- evenements
  env.os.queueEvent = function(...)
    ordonnanceur.file[#ordonnanceur.file + 1] = table.pack(...)
  end

  env.os.startTimer = function(n)
    ordonnanceur.prochain = ordonnanceur.prochain + 1
    ordonnanceur.minuteurs[ordonnanceur.prochain] = etat.horloge + (n or 0)
    return ordonnanceur.prochain
  end

  env.os.cancelTimer = function(id) ordonnanceur.minuteurs[id] = nil end

  env.os.pullEventRaw = function(filtre) return coroutine.yield(filtre) end

  env.os.pullEvent = function(filtre)
    while true do
      local e = table.pack(coroutine.yield(filtre))
      if e[1] == "terminate" then error("Terminated", 0) end
      if filtre == nil or e[1] == filtre then return table.unpack(e, 1, e.n) end
    end
  end

  env.sleep = function(n)
    local id = env.os.startTimer(n or 0)
    while true do
      local _, tid = env.os.pullEvent("timer")
      if tid == id then return end
    end
  end

  ------------------------------------------------------------------- parallel
  local function courir(fns, limite)
    local routines, filtres = {}, {}
    for i, f in ipairs(fns) do routines[i] = coroutine.create(f) end
    local ev = { n = 0 }
    local mortes = 0
    while true do
      for i, r in ipairs(routines) do
        if r and (filtres[i] == nil or filtres[i] == ev[1] or ev[1] == "terminate") then
          local ok, param = coroutine.resume(r, table.unpack(ev, 1, ev.n))
          if not ok then error(param, 0) end
          filtres[i] = param
          if coroutine.status(r) == "dead" then
            routines[i] = false
            mortes = mortes + 1
            if mortes >= limite then return i end
          end
        end
      end
      ev = table.pack(coroutine.yield())
    end
  end
  env.parallel = {
    waitForAny = function(...) return courir({ ... }, 1) end,
    waitForAll = function(...) return courir({ ... }, select("#", ...)) end,
  }

  --------------------------------------------------------------------- rednet
  -- Le banc de vol n'en a pas : c'est par la que passent les ordres du sol.
  local rednet = { ouvert = false, envois = {} }
  env.rednet = {
    open      = function() rednet.ouvert = true end,
    close     = function() rednet.ouvert = false end,
    isOpen    = function() return rednet.ouvert end,
    broadcast = function() end,
    send = function(id, message, protocole)
      rednet.envois[#rednet.envois + 1] =
        { id = id, message = message, protocole = protocole, t = etat.horloge }
    end,
    receive = function(protocole, delai)
      local minuteur = delai and env.os.startTimer(delai) or nil
      while true do
        local e = table.pack(env.os.pullEvent())
        if e[1] == "rednet_message" and (protocole == nil or e[4] == protocole) then
          return e[2], e[3], e[4]
        elseif e[1] == "timer" and minuteur and e[2] == minuteur then
          return nil
        end
      end
    end,
  }
  etat.rednet = rednet

  --------------------------------------------------------------- boucle motrice
  local function prochainEvenement()
    if #ordonnanceur.file > 0 then
      return table.remove(ordonnanceur.file, 1)
    end
    -- File vide : le temps avance jusqu'au minuteur le plus proche, et c'est
    -- LA que le vehicule simule se deplace.
    local meilleur, id
    for tid, echeance in pairs(ordonnanceur.minuteurs) do
      if not meilleur or echeance < meilleur then meilleur, id = echeance, tid end
    end
    if not meilleur then return nil end
    env.avancerSimulation(math.max(0, meilleur - etat.horloge))
    ordonnanceur.minuteurs[id] = nil
    return table.pack("timer", id)
  end

  --- Execute un programme jusqu'a epuisement du temps virtuel alloue.
  -- @return motif d'arret ("LIMITE_TEMPS", "PLUS_D_EVENEMENTS" ou une erreur)
  function M.executer(chemin, secondes)
    local source = io.open(chemin, "r"):read("a")
    local morceau = assert(load(source, "@" .. chemin, "t", env))
    local principal = coroutine.create(morceau)

    local ev, motif = { n = 0 }, nil
    while coroutine.status(principal) ~= "dead" do
      local ok, err = coroutine.resume(principal, table.unpack(ev, 1, ev.n))
      if not ok then motif = err break end
      if etat.horloge > secondes then motif = "LIMITE_TEMPS" break end
      local suivant = prochainEvenement()
      if not suivant then motif = "PLUS_D_EVENEMENTS" break end
      ev = suivant
    end
    return motif
  end

  function M.injecter(...) env.os.queueEvent(...) end

  M.env, M.etat, M.bancVol = env, etat, bancVol
  return env, etat
end

return M
