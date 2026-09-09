-- Banc d'essai du systeme d'exploitation embarque.
--   Usage : lua5.4 tests/test_systeme.lua   (depuis la racine du depot)
--
-- Le noyau multitache est la piece dont une erreur ne se voit pas : un
-- mauvais routage d'evenement ne plante rien, il fait simplement rater un
-- ordre du sol pendant que l'equipage consulte une page. C'est donc lui que
-- ce banc verifie en priorite.

local RACINE = (arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."

local echecs, total = 0, 0
local function verifier(nom, condition, detail)
  total = total + 1
  if condition then print(string.format("  [OK]   %s", nom))
  else
    echecs = echecs + 1
    print(string.format("  [ECHEC] %s %s", nom, detail and ("-> " .. tostring(detail)) or ""))
  end
end

--------------------------------------------------------------------------------
-- ENVIRONNEMENT SIMULE : term, window, os.pullEventRaw
--------------------------------------------------------------------------------

local file = {}
local env = setmetatable({}, { __index = _G })

local function creerFenetre()
  local visible = false
  return {
    setVisible = function(v) visible = v end,
    redraw = function() end,
    getSize = function() return 51, 18 end,
    setCursorPos = function() end, write = function() end, clear = function() end,
    setBackgroundColour = function() end, setTextColour = function() end,
    isColour = function() return false end,
    estVisible = function() return visible end,
  }
end

local terminalCourant = creerFenetre()
env.term = {
  current   = function() return terminalCourant end,
  redirect  = function(nouveau)
    local ancien = terminalCourant
    terminalCourant = nouveau
    return ancien
  end,
  getSize   = function() return 51, 19 end,
  isColour  = function() return false end,
  clear = function() end, setCursorPos = function() end, write = function() end,
  setBackgroundColour = function() end, setTextColour = function() end,
}
env.window = { create = function() return creerFenetre() end }
env.os = setmetatable({
  clock = os.clock,
  -- Fidele a CraftOS : dans une TACHE (coroutine), pullEventRaw rend la main
  -- a l'ordonnanceur ; dans le NOYAU, qui est la boucle la plus externe, il
  -- lit la file d'evenements. Confondre les deux fait passer un noyau casse
  -- pour un noyau correct.
  pullEventRaw = function(filtre)
    if coroutine.isyieldable() then return coroutine.yield(filtre) end
    if #file == 0 then error("FILE_VIDE", 0) end
    return table.unpack(table.remove(file, 1))
  end,
}, { __index = os })
env.colors = setmetatable({}, { __index = function() return 1 end })
env.colours = env.colors
env._G = env

local function charger(chemin, ...)
  local source = io.open(RACINE .. "/" .. chemin, "r"):read("a")
  return assert(load(source, "@" .. chemin, "t", env))(...)
end

local taches = charger("systeme/noyau_taches.lua")

--------------------------------------------------------------------------------
print("\n== TEST 1 : routage des evenements ==")
do
  local recus = { [1] = {}, [2] = {} }
  local noyau = taches.creer()

  local function tache(indice)
    return function()
      while true do
        local e = table.pack(env.os.pullEventRaw())
        recus[indice][#recus[indice] + 1] = e[1]
      end
    end
  end
  noyau.ajouter("Interface", tache(1))
  noyau.ajouter("Interception", tache(2))

  file = {
    table.pack("key", 32),              -- terminal -> premier plan seulement
    table.pack("rednet_message", 9, {}),-- reseau   -> tout le monde
    table.pack("timer", 1),             -- minuteur -> tout le monde
    table.pack("mouse_click", 1, 5, 5), -- terminal -> premier plan seulement
    table.pack("modem_message"),        -- reseau   -> tout le monde
  }
  pcall(noyau.executer)

  local function compte(liste, nom)
    local n = 0
    for _, e in ipairs(liste) do if e == nom then n = n + 1 end end
    return n
  end

  verifier("la touche va a la tache au premier plan", compte(recus[1], "key") == 1,
    compte(recus[1], "key"))
  verifier("la touche ne va PAS a la tache de fond", compte(recus[2], "key") == 0,
    compte(recus[2], "key"))
  verifier("le clic va au premier plan seulement",
    compte(recus[1], "mouse_click") == 1 and compte(recus[2], "mouse_click") == 0)
  verifier("l'ordre rednet va aux DEUX taches",
    compte(recus[1], "rednet_message") == 1 and compte(recus[2], "rednet_message") == 1,
    string.format("%d / %d", compte(recus[1], "rednet_message"),
      compte(recus[2], "rednet_message")))
  verifier("le minuteur va aux deux taches",
    compte(recus[1], "timer") == 1 and compte(recus[2], "timer") == 1)
  verifier("le message modem va aux deux taches",
    compte(recus[1], "modem_message") == 1 and compte(recus[2], "modem_message") == 1)
end

--------------------------------------------------------------------------------
print("\n== TEST 2 : basculement de premier plan ==")
do
  local recus = { [1] = 0, [2] = 0 }
  local noyau = taches.creer()
  noyau.ajouter("A", function()
    while true do env.os.pullEventRaw() recus[1] = recus[1] + 1 end
  end)
  noyau.ajouter("B", function()
    while true do env.os.pullEventRaw() recus[2] = recus[2] + 1 end
  end)

  file = { table.pack("key", 1) }
  pcall(noyau.executer)
  verifier("avant bascule : A recoit la touche", recus[1] == 1 and recus[2] == 0,
    string.format("%d / %d", recus[1], recus[2]))

  verifier("bascule vers la tache 2 acceptee", noyau.afficher(2))
  verifier("tache courante mise a jour", noyau.tacheCourante().nom == "B",
    noyau.tacheCourante().nom)

  file = { table.pack("key", 2) }
  pcall(noyau.executer)
  -- Chaque appel a executer() reamorce les taches par un tour a vide : on
  -- verifie donc que B a bien recu quelque chose, et A rien de plus.
  local avantA = recus[1]
  verifier("apres bascule : B recoit la touche", recus[2] >= 1, recus[2])
  file = { table.pack("key", 3) }
  pcall(noyau.executer)
  verifier("apres bascule : A ne recoit plus les touches",
    recus[1] == avantA + 1, string.format("%d -> %d", avantA, recus[1]))
  verifier("bascule vers une tache inexistante refusee", noyau.afficher(9) == false)
end

--------------------------------------------------------------------------------
print("\n== TEST 3 : une tache qui tombe ne tue pas le systeme ==")
do
  local vivante = 0
  local noyau = taches.creer()
  noyau.ajouter("Fragile", function()
    env.os.pullEventRaw()
    error("panne simulee du systeme d'interception", 0)
  end)
  noyau.ajouter("Robuste", function()
    while true do env.os.pullEventRaw() vivante = vivante + 1 end
  end)

  file = { table.pack("timer", 1), table.pack("timer", 2) }
  pcall(noyau.executer)

  verifier("la tache fragile est marquee arretee", noyau.taches[1].morte)
  verifier("son erreur est conservee pour l'equipage",
    noyau.taches[1].erreur
      and noyau.taches[1].erreur:find("panne simulee", 1, true) ~= nil,
    noyau.taches[1].erreur)
  verifier("la tache robuste a continue de tourner", vivante >= 2, vivante)
  verifier("le decompte des taches vivantes est juste", noyau.vivantes() == 1,
    noyau.vivantes())
end

--------------------------------------------------------------------------------
print("\n== TEST 4 : arret propre ==")
do
  local noyau = taches.creer()
  local tours = 0
  noyau.ajouter("Boucle", function()
    while true do env.os.pullEventRaw() tours = tours + 1 end
  end)
  file = { table.pack("timer", 1), table.pack("timer", 2), table.pack("timer", 3) }
  -- Arret demande depuis l'exterieur apres le premier evenement.
  local original = env.os.pullEventRaw
  local appels = 0
  env.os.pullEventRaw = function()
    appels = appels + 1
    if appels > 2 then noyau.arreter() end
    return original()
  end
  pcall(noyau.executer)
  env.os.pullEventRaw = original
  verifier("noyau.arreter() interrompt la boucle", noyau.actif == false)
end

--------------------------------------------------------------------------------
print("\n== TEST 5 : les modules du systeme se chargent ==")
do
  local ok, ui = pcall(charger, "systeme/ui.lua")
  verifier("systeme/ui.lua se charge", ok and type(ui) == "table", ok and "" or ui)
  if ok then
    verifier("palette definie", type(ui.PALETTE) == "table")
    verifier("outils d'affichage exposes",
      type(ui.barre) == "function" and type(ui.saisir) == "function"
      and type(ui.confirmer) == "function" and type(ui.jauge) == "function")
    verifier("rotation dans une liste fermee",
      ui.suivantDansListe("b", { "a", "b", "c" }, 1) == "c"
      and ui.suivantDansListe("c", { "a", "b", "c" }, 1) == "a"
      and ui.suivantDansListe("a", { "a", "b", "c" }, -1) == "c")
  end

  -- os.lua est un programme, pas un module : on verifie seulement qu'il
  -- compile, la boucle d'interface n'a pas de sens hors du jeu.
  local source = io.open(RACINE .. "/systeme/os.lua", "r"):read("a")
  local compile, err = load(source, "@os.lua", "t", env)
  verifier("systeme/os.lua compile", compile ~= nil, err)

  local sourceLanceur = io.open(RACINE .. "/systeme/startup.lua", "r"):read("a")
  verifier("systeme/startup.lua compile",
    load(sourceLanceur, "@startup.lua", "t", env) ~= nil)
  -- Un navire rentre a sec de munitions doit le rester apres un redemarrage :
  -- aucun lanceur ne doit toucher au marqueur de rearmement.
  verifier("le lanceur du systeme ne touche pas au marqueur de rearmement",
    sourceLanceur:find("rearmement_requis", 1, true) == nil)
  local lanceurNavire = io.open(RACINE .. "/intercepteur/startup.lua", "r"):read("a")
  verifier("le lanceur du navire ne le supprime pas non plus",
    lanceurNavire:find("rearmement", 1, true) ~= nil
    and lanceurNavire:find("fs.delete", 1, true) ~= nil
    and lanceurNavire:find("N'EST JAMAIS SUPPRIME", 1, true) ~= nil)
end

--------------------------------------------------------------------------------
print(string.format("\n===== %d/%d verifications reussies =====", total - echecs, total))
os.exit(echecs == 0 and 0 or 1)
