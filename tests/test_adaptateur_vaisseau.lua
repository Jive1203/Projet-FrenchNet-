-- Banc d'essai de l'adaptateur d'autopilote du Doomsday Ship.
--   Usage : lua5.4 tests/test_adaptateur_vaisseau.lua   (depuis la racine)
--
-- La couture d'integration du ballon (vaisseau/liaisons.lua) reservait une
-- case a un autopilote et cette case etait vide : la page NAVIGATION
-- construisait des routes que personne ne volait, la page PORTANCE proposait
-- un largage de ballast que personne n'executait.
--
-- Ce banc verifie que l'adaptateur remplit la case SANS MENTIR : il refuse
-- tout ce qu'il ne peut pas tenir, et dit pourquoi.

local RACINE = (arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."
local SCR    = RACINE .. "/tests"
local BANC   = "/tmp/banc_adaptateur_frenchnet"

local echecs, total = 0, 0

local function verifier(nom, condition, detail)
  total = total + 1
  if condition then
    print(string.format("  [OK]   %s", nom))
  else
    echecs = echecs + 1
    print(string.format("  [ECHEC] %s %s", nom, detail and ("-> " .. tostring(detail)) or ""))
  end
end

--- Monte un ballon simule. 'options.autopilote' installe (ou non) le module
-- standard, 'options.axes' cable (ou non) les sorties.
local function monter(options)
  options = options or {}
  os.execute("rm -rf " .. BANC .. " && mkdir -p " .. BANC .. "/vaisseau "
    .. BANC .. "/autopilote")
  os.execute(("cp %s/vaisseau/autopilote.lua %s/vaisseau/"):format(RACINE, BANC))
  os.execute(("cp %s/vaisseau/liaisons.lua %s/vaisseau/"):format(RACINE, BANC))

  if options.autopilote ~= false then
    os.execute(("cp %s/autopilote/*.lua %s/autopilote/"):format(RACINE, BANC))
    -- Cablage des axes : c'est justement ce que 'calibrer' produit.
    if options.axes ~= false then
      local f = io.open(BANC .. "/autopilote/config_vehicule.lua", "r")
      local source = f:read("a")
      f:close()
      source = source:gsub('avance%s+= { mode = "analogique".-\n',
        'avance   = { mode = "analogique", cote = "front", neutre = 0, amplitude = 15 },\n', 1)
      f = io.open(BANC .. "/autopilote/config_vehicule.lua", "w")
      f:write(source)
      f:close()
    else
      -- Aucun axe cable : l'etat d'un ballon qui sort du hangar.
      local f = io.open(BANC .. "/autopilote/config_vehicule.lua", "r")
      local source = f:read("a")
      f:close()
      source = source:gsub("sorties = {.-\n  },\n", [[sorties = {
    type = "redstone",
    distant = { actif = false, protocole = "frenchnet_sortie" },
    axes = {
      avance   = { mode = "aucun" }, vertical = { mode = "aucun" },
      lacet    = { mode = "aucun" }, lateral  = { mode = "aucun" },
    },
  },
]], 1)
      f = io.open(BANC .. "/autopilote/config_vehicule.lua", "w")
      f:write(source)
      f:close()
    end
  end

  -- Configuration minimale du ballon : seule la section 'ballast' compte ici.
  local f = io.open(BANC .. "/vaisseau/config_vaisseau.lua", "w")
  f:write("return { identifiant = \"DOOMSDAY-TEST\", ballast = "
    .. (options.ballast or "nil") .. " }")
  f:close()

  local banc = dofile(SCR .. "/banc_vol.lua")
  local env, etat = banc.creer({
    racine = BANC, budget = options.budget or 600,
    bruitGps = 0.05, decalageGps = { x = 0, y = 2, z = 4 },
    vehicule = { x = 100, y = 150, z = 100, cap = 0, vMax = 4 },
  })
  local adaptateur = banc.charger(RACINE .. "/vaisseau/autopilote.lua")
  return { env = env, etat = etat, banc = banc, adaptateur = adaptateur }
end

--------------------------------------------------------------------------------
print("\n== TEST 1 : conformite au contrat declare par la couture ==")
do
  local m = monter({})
  local liaisons = m.banc.charger(RACINE .. "/vaisseau/liaisons.lua")
  local besoins = liaisons.MODULES.autopilote.besoins

  verifier("le contrat declare au moins les six fonctions attendues",
    #besoins >= 6, #besoins)

  local manquantes = {}
  for _, besoin in ipairs(besoins) do
    if type(m.adaptateur[besoin]) ~= "function" then
      manquantes[#manquantes + 1] = besoin
    end
  end
  verifier("l'adaptateur expose TOUT ce que la couture reclame",
    #manquantes == 0, table.concat(manquantes, ", "))

  -- Le piege deja paye une fois : la page PORTANCE appelait largerBallast()
  -- sans que la couture ne le reclame, donc sans que personne ne le verifie.
  local declare = {}
  for _, besoin in ipairs(besoins) do declare[besoin] = true end
  verifier("'largerBallast' figure bien au contrat", declare.largerBallast == true)
  verifier("'pas' figure bien au contrat", declare.pas == true)

  verifier("le module se charge en table, comme loadfile l'exige",
    type(m.adaptateur) == "table")
end

--------------------------------------------------------------------------------
print("\n== TEST 2 : module d'autopilote absent -> refus explicite ==")
do
  local m = monter({ autopilote = false })

  local ok, motif = m.adaptateur.engager()
  verifier("l'engagement est refuse", ok == false)
  verifier("le motif nomme le fichier manquant",
    tostring(motif):find("autopilote.lua", 1, true) ~= nil, motif)
  verifier("le motif nomme le poste d'installation",
    tostring(motif):find("vehicule", 1, true) ~= nil, motif)

  local okRoute, motifRoute = m.adaptateur.definirRoute({ { nom = "A", x = 10, z = 20 } })
  verifier("une route est refusee, pas acceptee en silence", okRoute == false)
  verifier("le refus de route porte le meme motif",
    tostring(motifRoute):find("autopilote.lua", 1, true) ~= nil, motifRoute)

  local etat = m.adaptateur.etat()
  verifier("l'etat se declare indisponible", etat.disponible == false)
  verifier("l'etat porte le motif", etat.motif ~= nil, etat.motif)

  local okPas = m.adaptateur.pas()
  verifier("un cycle sans engagement ne fait rien et ne plante pas", okPas == false)
end

--------------------------------------------------------------------------------
print("\n== TEST 3 : aucun axe cable -> refus qui nomme 'calibrer' ==")
do
  local m = monter({ axes = false })

  local ok, motif = m.adaptateur.engager()
  verifier("l'engagement est refuse", ok == false)
  verifier("le motif dit qu'aucun axe n'est cable",
    tostring(motif):find("aucun axe", 1, true) ~= nil, motif)
  verifier("le motif nomme l'outil qui repare",
    tostring(motif):find("calibrer", 1, true) ~= nil, motif)

  -- C'est la regle de la maison : ne jamais accepter ce qu'on ne peut pas tenir.
  local okRoute = m.adaptateur.definirRoute({ { nom = "A", x = 10, z = 20 } })
  verifier("la route est refusee tant que rien n'est cable", okRoute == false)
end

--------------------------------------------------------------------------------
print("\n== TEST 4 : cablage present -> engagement et route acceptes ==")
do
  local m = monter({})

  local ok, motif = m.adaptateur.engager()
  verifier("l'engagement reussit", ok == true, motif)

  local etat = m.adaptateur.etat()
  verifier("l'etat se declare engage", etat.engage == true)
  verifier("l'etat se declare disponible", etat.disponible == true)

  -- Une altitude absente ne doit pas valoir zero : un point de carte n'a pas
  -- de hauteur, et un ballon envoye a Y=0 finit dans le sol.
  local okRoute, nombre = m.adaptateur.definirRoute({
    { nom = "ALPHA", x = 200, z = 300 },
    { nom = "BRAVO", x = 400, z = 500, y = 180 },
  })
  verifier("la route est acceptee", okRoute == true, nombre)
  verifier("les deux points sont retenus", nombre == 2, nombre)

  local etatApres = m.adaptateur.etat()
  verifier("l'etat compte les points de la route", etatApres.route == 2, etatApres.route)

  local okPas = m.adaptateur.pas()
  verifier("un cycle d'asservissement s'execute", okPas == true)

  verifier("le desengagement rend la main", m.adaptateur.desengager() == true)
  verifier("apres desengagement, plus aucun cycle",
    m.adaptateur.pas() == false)
end

--------------------------------------------------------------------------------
print("\n== TEST 5 : route vide et waypoints malformes ==")
do
  local m = monter({})
  m.adaptateur.engager()

  local ok, motif = m.adaptateur.definirRoute({})
  verifier("une route vide est refusee", ok == false)
  verifier("le motif le dit", tostring(motif):find("vide", 1, true) ~= nil, motif)

  local ok2, motif2 = m.adaptateur.definirRoute({ { nom = "SANS-COORD" } })
  verifier("un waypoint sans coordonnees est refuse", ok2 == false)
  verifier("le motif nomme le rang du point fautif",
    tostring(motif2):find("waypoint 1", 1, true) ~= nil, motif2)

  local ok3 = m.adaptateur.definirRoute("pas une table")
  verifier("un argument qui n'est pas une liste est refuse", ok3 == false)
end

--------------------------------------------------------------------------------
print("\n== TEST 6 : ballast non declare -> largage refuse ==")
do
  local m = monter({})
  local ok, motif = m.adaptateur.largerBallast()
  verifier("le largage est refuse", ok == false)
  verifier("le motif explique comment le declarer",
    tostring(motif):find("ballast = ", 1, true) ~= nil, motif)
  verifier("le motif nomme le fichier a editer",
    tostring(motif):find("config_vaisseau.lua", 1, true) ~= nil, motif)
end

--------------------------------------------------------------------------------
print("\n== TEST 7 : ballast declare -> impulsion reelle puis retour a zero ==")
do
  local m = monter({ ballast = '{ cote = "back", duree = 0.5, niveau = 15 }' })

  local ok, compte = m.adaptateur.largerBallast()
  verifier("le largage est execute", ok == true, compte)
  verifier("le largage est compte", compte == 1, compte)
  verifier("la face est retombee a zero apres l'impulsion",
    (m.etat.redstone.back or 0) == 0, m.etat.redstone.back)

  local ok2, compte2 = m.adaptateur.largerBallast()
  verifier("un second largage s'execute aussi", ok2 == true)
  verifier("le compteur avance", compte2 == 2, compte2)

  local etat = m.adaptateur.etat()
  verifier("l'etat remonte le nombre de largages", etat.largages == 2, etat.largages)
end

--------------------------------------------------------------------------------
print("\n== TEST 8 : diagnostic ==")
do
  local m = monter({})
  local rapport = m.adaptateur.diagnostic()

  verifier("le module standard est vu present", rapport.present == true)
  verifier("le vehicule est nomme", rapport.vehicule ~= nil, rapport.vehicule)
  verifier("l'axe avance est rapporte cable",
    rapport.axes.avance == "analogique", rapport.axes and rapport.axes.avance)
  verifier("le cablage est juge suffisant", rapport.cablageSuffisant == true)
  verifier("le ballast est rapporte non declare",
    rapport.ballast == "non declare", rapport.ballast)

  local sansModule = monter({ autopilote = false }).adaptateur.diagnostic()
  verifier("sans module standard, le diagnostic le dit",
    sansModule.present == false and sansModule.motif ~= nil, sansModule.motif)
end

print(string.format("\n===== %d/%d verifications reussies =====", total - echecs, total))
os.exit(echecs == 0 and 0 or 1)
