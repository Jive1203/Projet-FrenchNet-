-- Banc d'essai de balise.lua, hors du jeu, sur un interpreteur Lua 5.4.
--   Usage : lua5.4 tests/test_balise.lua   (depuis la racine du depot)
-- Simule CraftOS via tests/craftos.lua : evenements, minuteurs, rednet, modem,
-- GPS, parallel. Verifie le fonctionnement nominal ET le comportement en panne.

local RACINE = (arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."
local SCR    = RACINE .. "/tests"
local SRC    = RACINE .. "/balise"
local BANC   = "/tmp/banc_balise_frenchnet"

package.path = SCR .. "/?.lua;" .. package.path

local echecs, total = 0, 0

local function preparer(configLua)
  os.execute("rm -rf " .. BANC .. " && mkdir -p " .. BANC .. "/balise")
  os.execute("cp " .. SRC .. "/balise.lua " .. BANC .. "/balise/")
  if configLua ~= false then
    local f = io.open(BANC .. "/balise/config_balise.lua", "w")
    f:write(configLua or "")
    f:close()
  end
end

local function verifier(nom, condition, detail)
  total = total + 1
  if condition then
    print(string.format("  [OK]   %s", nom))
  else
    echecs = echecs + 1
    print(string.format("  [ECHEC] %s %s", nom, detail and ("-> " .. detail) or ""))
  end
end

local function contient(sorties, motif)
  for _, ligne in ipairs(sorties) do
    if ligne:find(motif, 1, true) then return true, ligne end
  end
  return false
end

local CONFIG_NOMINALE = [[
return {
  identifiant = "BAL-01-NORD",
  designation = "Secteur nord",
  positionManuelle = { x = 1200, y = 210, z = -2600 },
  intervalleSecondes = 5,
  protocoleRednet = "frenchnet_balise",
  hoteGps = true,
  ecouterPairs = true,
  journalFichier = true,
  journalNiveauEcran = "DEBUG",
  battementSecondes = 60,
}
]]

--------------------------------------------------------------------------------
print("\n== TEST 1 : fonctionnement nominal (position manuelle, hote GPS) ==")
do
  preparer(CONFIG_NOMINALE)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({ racine = BANC })
  craftos.injecterModem("back", 65534, 12, "PING")
  craftos.injecterRednet(9, {
    protocole = "FRENCHNET_BALISE", identifiant = "BAL-02-EST",
    x = 4300, y = 95, z = 500,
  }, "frenchnet_balise")

  local motif = craftos.executer(BANC .. "/balise/balise.lua", 200)

  verifier("le programme tourne sans se terminer", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("modem Ender detecte", (contient(etat.sorties, "modem Ender detecte")))
  verifier("rednet ouvert", (contient(etat.sorties, "rednet ouvert")))
  verifier("hote GPS actif", (contient(etat.sorties, "service hote GPS actif")))
  verifier("diffusions emises (>30 en 200s a 5s)", #etat.diffusions >= 35, "#" .. #etat.diffusions)

  local m = etat.diffusions[1] and etat.diffusions[1].message
  verifier("payload : coordonnees correctes",
    m and m.x == 1200 and m.y == 210 and m.z == -2600)
  verifier("payload : identifiant present", m and m.identifiant == "BAL-01-NORD")
  verifier("payload : protocole rednet", etat.diffusions[1].protocole == "frenchnet_balise")
  verifier("payload : sequence incrementale",
    etat.diffusions[3] and etat.diffusions[3].message.sequence == 3)
  verifier("reponse a la requete GPS PING", #etat.transmissions >= 1
    and etat.transmissions[1].message[1] == 1200
    and etat.transmissions[1].message[3] == -2600)
  verifier("balise voisine detectee", (contient(etat.sorties, "balise voisine detectee : BAL-02-EST")))
  verifier("battement de coeur periodique", (contient(etat.sorties, "reponses GPS=")))

  local log = io.open(BANC .. "/balise/balise.log", "r")
  local contenu = log and log:read("a") or ""
  if log then log:close() end
  verifier("journal ecrit sur disque", #contenu > 200, #contenu .. " octets")
  verifier("journal horodate et etiquete", contenu:find("[etape: ", 1, true) ~= nil)
end

--------------------------------------------------------------------------------
print("\n== TEST 2 : panne reseau (rednet.broadcast en erreur) ==")
do
  preparer(CONFIG_NOMINALE)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({ racine = BANC })
  etat.echecBroadcast = true

  local motif = craftos.executer(BANC .. "/balise/balise.lua", 200)

  verifier("aucun plantage du programme", motif == "LIMITE_TEMPS", tostring(motif))
  local ok, ligne = contient(etat.sorties, "erreur detectee a l'etape 'envoi rednet (broadcast)'")
  verifier("erreur localisee a l'etape d'envoi rednet", ok, ligne)
  verifier("reinitialisation apres 5 echecs",
    (contient(etat.sorties, "echecs d'emission consecutifs")))
  verifier("redemarrage automatique annonce",
    (contient(etat.sorties, "redemarrage automatique n1")))
  verifier("plusieurs cycles de relance",
    (contient(etat.sorties, "redemarrage automatique n2")))
end

--------------------------------------------------------------------------------
print("\n== TEST 3 : configuration invalide (identifiant manquant) ==")
do
  preparer([[return { positionManuelle = { x = 1, y = 2, z = 3 } }]])
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({ racine = BANC })
  local motif = craftos.executer(BANC .. "/balise/balise.lua", 120)

  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  local ok, ligne = contient(etat.sorties, "[etape: validation de la configuration]")
  verifier("erreur localisee a l'etape de validation", ok, ligne)
  verifier("message explicite sur l'identifiant",
    (contient(etat.sorties, "identifiant' manquant")))
  verifier("temporisation progressive (backoff)",
    (contient(etat.sorties, "redemarrage automatique n3")))
end

--------------------------------------------------------------------------------
print("\n== TEST 4 : fichier de configuration absent ==")
do
  preparer(false)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({ racine = BANC })
  local motif = craftos.executer(BANC .. "/balise/balise.lua", 120)
  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  local ok, ligne = contient(etat.sorties, "[etape: chargement de la configuration]")
  verifier("erreur localisee au chargement de la config", ok, ligne)
end

--------------------------------------------------------------------------------
print("\n== TEST 5 : disparition du modem en cours de route ==")
do
  preparer(CONFIG_NOMINALE)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({ racine = BANC })
  -- Le modem est arrache apres 20 s de fonctionnement.
  local anciennePresence = etat.modemPresent
  local craftosEtat = etat
  local horlogeHook = env.os.clock
  env.os.clock = function()
    local t = horlogeHook()
    if t > 20 then craftosEtat.modemPresent = false end
    return t
  end
  local motif = craftos.executer(BANC .. "/balise/balise.lua", 200)
  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  local ok, ligne = contient(etat.sorties, "[etape: surveillance du materiel (modem/rednet)]")
  verifier("panne localisee a l'etape de surveillance", ok, ligne)
  verifier("tentative de reinitialisation",
    (contient(etat.sorties, "aucun modem sans fil detecte"))
    or (contient(etat.sorties, "le modem a disparu")))
end

--------------------------------------------------------------------------------
print("\n== TEST 6 : mode GPS pur (sans position manuelle) ==")
do
  preparer([[
return {
  identifiant = "BAL-03-SUD",
  intervalleSecondes = 5,
  rafraichirPositionToutes = 60,
  journalNiveauEcran = "DEBUG",
}
]])
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({ racine = BANC, gps = { x = -800, y = 74, z = 3300 } })
  local motif = craftos.executer(BANC .. "/balise/balise.lua", 200)

  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  verifier("position obtenue via gps.locate", (contient(etat.sorties, "position gps : X=-800")))
  verifier("hote GPS refuse sans position manuelle",
    (contient(etat.sorties, "hote GPS desactive")))
  local m = etat.diffusions[1] and etat.diffusions[1].message
  verifier("diffusion des coordonnees GPS", m and m.x == -800 and m.z == 3300)
  verifier("source de position signalee", m and m.positionSource == "gps")
end

--------------------------------------------------------------------------------
print("\n== TEST 7 : mode GPS sans constellation disponible ==")
do
  preparer([[return { identifiant = "BAL-04-OUEST", intervalleSecondes = 5 }]])
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({ racine = BANC, gps = nil })
  local motif = craftos.executer(BANC .. "/balise/balise.lua", 200)
  verifier("aucun plantage", motif == "LIMITE_TEMPS", tostring(motif))
  local ok, ligne = contient(etat.sorties, "[etape: resolution de la position GPS]")
  verifier("erreur localisee a la resolution de position", ok, ligne)
  verifier("diagnostic explicite (4 hotes)", (contient(etat.sorties, "moins de 4 hotes GPS")))
  verifier("relance automatique malgre tout", (contient(etat.sorties, "redemarrage automatique")))
end

--------------------------------------------------------------------------------
print("\n== TEST 8 : identifiant duplique sur le reseau ==")
do
  preparer(CONFIG_NOMINALE)
  local craftos = dofile(SCR .. "/craftos.lua")
  local env, etat = craftos.creer({ racine = BANC })
  craftos.injecterRednet(42, {
    protocole = "FRENCHNET_BALISE", identifiant = "BAL-01-NORD", x = 0, y = 0, z = 0,
  }, "frenchnet_balise")
  local motif = craftos.executer(BANC .. "/balise/balise.lua", 100)
  verifier("conflit d'identifiant signale",
    (contient(etat.sorties, "CONFLIT D'IDENTIFIANT")))
end

--------------------------------------------------------------------------------
local BASE=[[return { identifiant="BAL-05-ZENITH", positionManuelle={x=10,y=250,z=-40},
  intervalleSecondes=5, journalNiveauEcran="DEBUG", ARRET }]]

print("\n== TEST 9 : Ctrl+T avec arretParTerminate = true ==")
do
  preparer(BASE:gsub("ARRET","arretParTerminate = true"))
  local craftos=dofile(SCR .. "/craftos.lua")
  local env,etat=craftos.creer({racine=BANC})
  -- terminate injecte apres quelques evenements
  env.os.queueEvent("terminate")
  local motif=craftos.executer(BANC.."/balise/balise.lua", 200)
  verifier("le programme se termine proprement", motif=="PLUS_D_EVENEMENTS" or motif==nil, tostring(motif))
  verifier("arret manuel journalise", (contient(etat.sorties,"arret manuel demande")))
  verifier("balise stoppee", (contient(etat.sorties,"balise stoppee")))
  local f=io.open(BANC.."/balise/.arret_manuel","r")
  verifier("marqueur .arret_manuel depose pour le lanceur", f~=nil)
  if f then f:close() end
end

print("\n== TEST 10 : Ctrl+T avec arretParTerminate = false (autonomie totale) ==")
do
  preparer(BASE:gsub("ARRET","arretParTerminate = false"))
  local craftos=dofile(SCR .. "/craftos.lua")
  local env,etat=craftos.creer({racine=BANC})
  env.os.queueEvent("terminate")
  local motif=craftos.executer(BANC.."/balise/balise.lua", 200)
  verifier("la balise continue de tourner", motif=="LIMITE_TEMPS", tostring(motif))
  verifier("tentative d'arret ignoree et journalisee", (contient(etat.sorties,"tentative d'arret manuel ignoree")))
  verifier("diffusion reprise apres la tentative d'arret", #etat.diffusions>=10, "#"..#etat.diffusions)
  local f=io.open(BANC.."/balise/.arret_manuel","r")
  verifier("aucun marqueur d'arret depose", f==nil)
  if f then f:close() end
end

print("\n== TEST 11 : rotation du journal ==")
do
  preparer([[return { identifiant="BAL-06", positionManuelle={x=1,y=2,z=3},
    intervalleSecondes=1, journalNiveauEcran="DEBUG", journalTailleMax=2048, battementSecondes=10 }]])
  local craftos=dofile(SCR .. "/craftos.lua")
  local env,etat=craftos.creer({racine=BANC})
  craftos.executer(BANC.."/balise/balise.lua", 400)
  local a=io.open(BANC.."/balise/balise.log","r")
  local b=io.open(BANC.."/balise/balise.log.1","r")
  verifier("journal courant present", a~=nil)
  verifier("archive balise.log.1 creee par rotation", b~=nil)
  if a then local n=a:seek("end") a:close() verifier("journal courant borne (<12 ko)", n<12288, n.." octets") end
  if b then b:close() end
end

print(string.format("\n===== %d/%d verifications reussies =====", total - echecs, total))
os.exit(echecs == 0 and 0 or 1)
