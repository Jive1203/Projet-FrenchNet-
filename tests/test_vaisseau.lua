-- Banc d'essai du systeme embarque du Doomsday Ship, hors du jeu.
--   Usage : lua5.4 tests/test_vaisseau.lua   (depuis la racine du depot)
--
-- Les quatre modules de base - mfd, hal, surveillance, liaisons - acceptent
-- leurs dependances par injection : ils se testent donc sans emulateur, avec
-- de faux peripheriques et de fausses fenetres.
--
-- Ce que ce banc verifie en priorite n'est pas que le systeme marche quand
-- tout va bien, mais qu'il DIT LA VERITE quand quelque chose manque : une
-- mesure absente ne doit jamais devenir un zero, et un module exterieur absent
-- ne doit jamais rendre un succes.

local RACINE = (arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."

-- CC: Tweaked expose 'colors' globalement ; les modules d'affichage s'en
-- servent des leur chargement.
colors = setmetatable({}, { __index = function(_, nom) return nom end })
colours = colors

local echecs, total = 0, 0

local function verifier(nom, condition, detail)
  total = total + 1
  if condition then
    print(string.format("  [OK]   %s", nom))
  else
    echecs = echecs + 1
    print(string.format("  [ECHEC] %s %s", nom, detail and ("-> " .. detail) or ""))
  end
end

local function egal(nom, obtenu, attendu)
  verifier(nom, obtenu == attendu,
    string.format("obtenu '%s', attendu '%s'", tostring(obtenu), tostring(attendu)))
end

--------------------------------------------------------------------------------
-- Faux materiel
--------------------------------------------------------------------------------

local function fausseFenetre()
  local f = { visible = true, ecrit = 0, efface = 0, largeur = 20, hauteur = 10 }
  f.getSize = function() return f.largeur, f.hauteur end
  f.setVisible = function(v) f.visible = v end
  f.clear = function() f.efface = f.efface + 1 end
  f.clearLine = function() end
  f.setCursorPos = function() end
  f.write = function() f.ecrit = f.ecrit + 1 end
  f.setTextColour = function() end
  f.setBackgroundColour = function() end
  f.setTextColor = f.setTextColour
  f.setBackgroundColor = f.setBackgroundColour
  return f
end

local function fauxTerminal(l, h)
  local t = { efface = 0 }
  t.getSize = function() return l or 51, h or 19 end
  t.clear = function() t.efface = t.efface + 1 end
  t.setCursorPos = function() end
  t.write = function() end
  t.setTextColour = function() end
  t.setBackgroundColour = function() end
  return t
end

-- Peripheriques configurables : chaque entree = { types, methodes = {nom=fn} }
local function fauxPeripheriques(table_)
  local per = {}
  per.getNames = function()
    local noms = {}
    for nom in pairs(table_) do noms[#noms + 1] = nom end
    table.sort(noms)
    return noms
  end
  per.getType = function(nom)
    local p = table_[nom]
    if not p then return nil end
    return table.unpack(p.types or { "inconnu" })
  end
  per.isPresent = function(nom) return table_[nom] ~= nil end
  per.wrap = function(nom)
    local p = table_[nom]
    return p and p.methodes or nil
  end
  per.call = function(nom, methode, ...)
    local p = table_[nom]
    if not p or not p.methodes[methode] then error("methode absente", 0) end
    return p.methodes[methode](...)
  end
  return per
end

--------------------------------------------------------------------------------
print("\n== TEST 1 : framework MFD, surfaces et fenetres ==")
do
  local mfdModule = dofile(RACINE .. "/vaisseau/mfd.lua")

  local moniteur = fauxTerminal(60, 30)
  moniteur.setTextScale = function() end
  moniteur.isColour = function() return true end

  local per = fauxPeripheriques({
    ["monitor_0"] = { types = { "monitor" }, methodes = moniteur },
  })
  -- getType doit rendre "monitor" pour que le MFD adopte la surface.
  per.getType = function(nom) return nom == "monitor_0" and "monitor" or nil end
  per.wrap = function(nom) return nom == "monitor_0" and moniteur or nil end

  local fenetresCreees = 0
  local faux = {
    peripheral = per,
    term = fauxTerminal(51, 19),
    window = { create = function(_, x, y, l, h)
      fenetresCreees = fenetresCreees + 1
      local f = fausseFenetre()
      f.largeur, f.hauteur = l, h
      return f
    end },
  }

  local systeme = mfdModule.nouveau({ environnement = faux })

  local dessins = 0
  systeme:enregistrerPage("essai", {
    titre = "ESSAI",
    dessiner = function() dessins = dessins + 1 end,
  })
  verifier("une page sans fonction dessiner est refusee",
    not systeme:enregistrerPage("vide", { titre = "V" }))

  systeme:detecterSurfaces()
  verifier("le terminal est toujours une surface", systeme.surfaces.terminal ~= nil)
  verifier("le moniteur accole devient une surface", systeme.surfaces["monitor_0"] ~= nil)

  -- Layout en fractions : la moitie gauche d'un moniteur de 60 colonnes fait
  -- 30 colonnes, quelle que soit la taille reelle de l'ecran.
  systeme.layout = {
    ["monitor_0"] = { fenetres = {
      { page = "essai", x = 0, y = 0, l = 0.5, h = 1 },
      { page = "essai", x = 0.5, y = 0, l = 0.5, h = 1 },
    } },
    terminal = { fenetres = { { page = "essai" } } },
  }
  local placees = systeme:appliquerLayout()
  egal("trois fenetres placees", placees, 3)

  local gauche = systeme.surfaces["monitor_0"].fenetres[1].geometrie
  egal("fraction 0.5 sur 60 colonnes -> 30", gauche.largeur, 30)
  egal("la fenetre gauche commence en 1", gauche.x, 1)
  local droite = systeme.surfaces["monitor_0"].fenetres[2].geometrie
  egal("la fenetre droite commence en 31", droite.x, 31)

  -- Une fenetre trop petite est refusee, pas affichee illisible.
  systeme.layout["monitor_0"].fenetres = {
    { page = "essai", x = 0, y = 0, l = 0.05, h = 0.05 },
  }
  placees = systeme:appliquerLayout()
  egal("fenetre trop petite refusee, seul le terminal reste", placees, 1)

  systeme:dessiner(100)
  verifier("les pages sont dessinees", dessins > 0, tostring(dessins))
end

--------------------------------------------------------------------------------
print("\n== TEST 2 : MFD, pile d'alarmes ==")
do
  local mfdModule = dofile(RACINE .. "/vaisseau/mfd.lua")
  local faux = {
    peripheral = { getNames = function() return {} end },
    term = fauxTerminal(51, 19),
    window = { create = function(_, x, y, l, h)
      local f = fausseFenetre() f.largeur, f.hauteur = l, h return f
    end },
  }
  local systeme = mfdModule.nouveau({ environnement = faux })
  systeme:enregistrerPage("essai", { dessiner = function() end })
  systeme:detecterSurfaces()
  systeme:appliquerLayout({ terminal = { fenetres = { { page = "essai" } } } })

  local surface = systeme.surfaces.terminal
  verifier("aucune alarme au depart", systeme:alarmeActive(surface) == nil)

  systeme:alarme("portance", "ALARME", "PERTE DE PORTANCE", { "-8 b/s" })
  egal("l'alarme prend l'ecran",
    systeme:alarmeActive(surface) and systeme:alarmeActive(surface).cle, "portance")

  -- Une alarme plus grave passe devant, l'autre attend son tour.
  systeme:alarme("coque", "CRITIQUE", "BRECHE DE COQUE", {})
  egal("la plus grave passe devant",
    systeme:alarmeActive(surface).cle, "coque")

  systeme:leverAlarme("coque")
  egal("l'alarme precedente reapparait quand la critique est levee",
    systeme:alarmeActive(surface).cle, "portance")

  systeme:leverAlarme("portance")
  verifier("l'affichage normal est restitue", systeme:alarmeActive(surface) == nil)
  verifier("la restitution force un redessin complet", surface.forcer == true)

  -- Une alarme deja posee est remplacee, pas empilee deux fois.
  systeme:alarme("portance", "ALARME", "PERTE DE PORTANCE", {})
  systeme:alarme("portance", "CRITIQUE", "PERTE DE PORTANCE", {})
  egal("une meme cle ne s'empile pas", #surface.pile, 1)
  egal("mais son niveau est mis a jour",
    systeme:alarmeActive(surface).niveau, "CRITIQUE")

  -- Un clic acquitte l'alarme affichee.
  local consomme = systeme:evenement("mouse_click", 1, 5, 5)
  verifier("un clic acquitte l'alarme", consomme and #surface.pile == 0)
end

--------------------------------------------------------------------------------
print("\n== TEST 3 : HAL, decouverte par methode ==")
do
  local halModule = dofile(RACINE .. "/vaisseau/hal.lua")

  -- Peripherique dont le TYPE ne dit rien d'utile : c'est le cas reel, et
  -- c'est pour cela que la decouverte se fait par methode.
  local per = fauxPeripheriques({
    ["back"] = { types = { "createaeronautics:machin", "peripheral" },
                 methodes = {
                   getStress = function() return 240 end,
                   getStressCapacity = function() return 800 end,
                   getSpeed = function() return 96 end,
                 } },
  })

  local hal = halModule.nouveau({}, per, function() end)
  local liees, manquantes = hal:decouvrir()
  verifier("les mesures presentes sont liees malgre un type inconnu",
    liees >= 3, tostring(liees))
  verifier("les autres sont declarees manquantes", manquantes > 0, tostring(manquantes))

  egal("lecture directe", hal:lire("propulsion.stress"), 240)
  local charge = hal:pourcentage("propulsion.stress", "propulsion.capacite")
  verifier("pourcentage calcule", charge and math.abs(charge - 30) < 0.01, tostring(charge))

  --[[
    LE POINT QUI COMPTE : une mesure absente rend nil ET son motif, jamais
    zero. Un reservoir vide et un capteur muet ne se ressemblent pas, et les
    confondre sur une page de portance se paie cher.
  ]]
  local valeur, motif = hal:lire("portance.gaz")
  verifier("mesure absente : nil, pas zero", valeur == nil, tostring(valeur))
  verifier("mesure absente : le motif nomme les methodes cherchees",
    type(motif) == "string" and motif:find("getGas", 1, true) ~= nil, tostring(motif))

  -- Forcage par configuration, tel que le diagnostic le fera remplir.
  local halForce = halModule.nouveau({
    mesures = { ["portance.gaz"] = { peripherique = "back", methode = "getSpeed",
                                     facteur = 0.5 } },
  }, per, function() end)
  halForce:decouvrir()
  egal("mesure forcee par la configuration, avec facteur",
    halForce:lire("portance.gaz"), 48)

  -- Mesure declaree volontairement absente : ce n'est pas une anomalie.
  local halSans = halModule.nouveau({ mesures = { ["portance.ballast"] = false } },
    per, function() end)
  halSans:decouvrir()
  local _, motifSans = halSans:lire("portance.ballast")
  verifier("mesure desactivee : motif explicite",
    motifSans:find("desactivee", 1, true) ~= nil, tostring(motifSans))

  -- Aucun peripherique du tout.
  local halVide = halModule.nouveau({}, fauxPeripheriques({}), function() end)
  local l2, m2 = halVide:decouvrir()
  egal("sans peripherique : aucune liaison", l2, 0)
  verifier("sans peripherique : tout est manquant", m2 > 0, tostring(m2))
end

--------------------------------------------------------------------------------
print("\n== TEST 4 : surveillance, seuils et hysteresis ==")
do
  local survModule = dofile(RACINE .. "/vaisseau/surveillance.lua")
  local sv = survModule.nouveau({ hysteresis = 5 })

  local function alarmesDe(liste)
    local par = {}
    for _, a in ipairs(liste) do par[a.cle] = a end
    return par
  end

  -- Pression a 25 % : seuil critique (30) franchi, sens inverse.
  local poser = alarmesDe((sv:evaluer({
    ["portance.pression"] = { valeur = 25 },
    ["vol.vitesseVerticale"] = { valeur = 0 },
  }, 0)))
  egal("pression basse : niveau critique",
    poser["portance.pression"] and poser["portance.pression"].niveau, "CRITIQUE")
  egal("la famille distingue portance et propulsion",
    poser["portance.pression"].famille, "PORTANCE")

  -- Variometre a -8 : alarme (seuil -6), pas critique (-10).
  local poser2 = alarmesDe((sv:evaluer({
    ["portance.pression"] = { valeur = 25 },
    ["vol.vitesseVerticale"] = { valeur = -8 },
  }, 1)))
  egal("perte de portance : niveau alarme",
    poser2["vol.vitesseVerticale"] and poser2["vol.vitesseVerticale"].niveau, "ALARME")
  verifier("une alarme deja posee au meme niveau n'est pas reposee",
    poser2["portance.pression"] == nil)

  --[[
    HYSTERESIS. Le seuil d'attention est 70 en sens inverse ; avec 5 de marge,
    l'alarme ne se leve qu'a 75. A 72, elle doit TENIR : sans cette marge, une
    valeur qui oscille autour du seuil ferait clignoter l'ecran sans repit,
    exactement quand l'equipage a besoin de le lire.
  ]]
  local _, lever = sv:evaluer({
    ["portance.pression"] = { valeur = 72 },
    ["vol.vitesseVerticale"] = { valeur = -8 },
  }, 2)
  verifier("a 72 %, l'alarme tient encore (marge d'hysteresis)", #lever == 0,
    table.concat(lever, ","))

  local _, lever2 = sv:evaluer({
    ["portance.pression"] = { valeur = 80 },
    ["vol.vitesseVerticale"] = { valeur = -8 },
  }, 3)
  local leve = false
  for _, cle in ipairs(lever2) do if cle == "portance.pression" then leve = true end end
  verifier("a 80 %, l'alarme est levee", leve)

  --[[
    CAPTEUR MUET. Une mesure indisponible ne declenche pas l'alarme de la
    VALEUR - qui serait fausse - mais celle du CAPTEUR. Traiter un capteur muet
    comme un reservoir vide ferait larguer du ballast sans raison ; l'ignorer
    laisserait voler a l'aveugle.
  ]]
  local sv2 = survModule.nouveau({})
  local poser3 = alarmesDe((sv2:evaluer({
    ["portance.gaz"] = { valeur = nil, motif = "aucun peripherique n'expose getGas" },
  }, 0)))
  verifier("capteur muet : alarme distincte",
    poser3["capteur:portance.gaz"] ~= nil)
  verifier("capteur muet : pas d'alarme sur la valeur",
    poser3["portance.gaz"] == nil)
  verifier("capteur muet : le motif reel est remonte",
    poser3["capteur:portance.gaz"].lignes[1]:find("getGas", 1, true) ~= nil)
  verifier("capteur muet : la page est prevenue que la surveillance est inactive",
    poser3["capteur:portance.gaz"].lignes[2]:find("INACTIVE", 1, true) ~= nil)

  -- Le capteur revient : l'alarme de capteur est levee.
  local _, lever3 = sv2:evaluer({ ["portance.gaz"] = { valeur = 80 } }, 1)
  local leveCapteur = false
  for _, cle in ipairs(lever3) do
    if cle == "capteur:portance.gaz" then leveCapteur = true end
  end
  verifier("le capteur revenu leve son alarme", leveCapteur)

  -- Les seuils de la configuration priment sur ceux de la regle.
  local sv3 = survModule.nouveau({
    seuils = { ["portance.pression"] = { attention = 95, alarme = 90, critique = 85 } },
  })
  -- 92 est sous le seuil d'attention (95) mais au-dessus de l'alarme (90) :
  -- ATTENTION est la bonne reponse. 88 franchit l'alarme.
  local poser4 = alarmesDe((sv3:evaluer({ ["portance.pression"] = { valeur = 92 } }, 0)))
  egal("seuils de configuration appliques : attention",
    poser4["portance.pression"] and poser4["portance.pression"].niveau, "ATTENTION")
  local poser5 = alarmesDe((sv3:evaluer({ ["portance.pression"] = { valeur = 88 } }, 1)))
  egal("seuils de configuration appliques : alarme",
    poser5["portance.pression"] and poser5["portance.pression"].niveau, "ALARME")
end

--------------------------------------------------------------------------------
print("\n== TEST 5 : liaisons, un module absent ne ment jamais ==")
do
  local liaisonsModule = dofile(RACINE .. "/vaisseau/liaisons.lua")

  -- Une vraie zone, pour que le fond de carte soit reellement rasterise : sans
  -- elle le test ne prouverait que la branche « pas de zones connues ».
  local noyauEssai = dofile(RACINE .. "/command/noyau.lua")
  local zonesEssai = {
    { nom = "ALPHA-1", classe = "ALPHA", forme = "rectangle",
      points = noyauEssai.ordonnerCoins({ { x = 0, z = -200 }, { x = 300, z = -200 },
                                          { x = 300, z = 100 }, { x = 0, z = 100 } }) },
    { nom = "ROMEO-1", classe = "ROMEO", forme = "cercle",
      centre = { x = 120, z = -60 }, rayon = 80 },
  }

  -- Aucun module exterieur present : c'est l'etat REEL du depot aujourd'hui.
  local avertissements = {}
  local liaisons = liaisonsModule.nouveau({}, function(niveau, etape, message)
    avertissements[#avertissements + 1] = message
  end, function() return nil end)

  local presents, absents = liaisons:charger()
  egal("aucun module present", presents, 0)
  verifier("les trois modules sont signales absents", absents == 3, tostring(absents))

  local ok, motif = liaisons:appeler("autopilote", "definirRoute", {})
  verifier("un appel a un module absent ECHOUE", ok == false)
  verifier("et rend un motif lisible",
    type(motif) == "string" and motif:find("absent", 1, true) ~= nil, tostring(motif))
  verifier("le module absent est signale au journal",
    #avertissements > 0)

  -- Le motif n'est journalise qu'une fois : repeter a chaque image noierait
  -- le journal sans rien apprendre.
  local avant = #avertissements
  for _ = 1, 10 do liaisons:appeler("autopilote", "definirRoute", {}) end
  egal("le refus n'est journalise qu'une fois", #avertissements, avant)
  egal("mais chaque refus est compte", liaisons.refus, 11)

  verifier("disponible() dit non", liaisons:disponible("autopilote") == false)

  local rapport = liaisons:rapport()
  egal("le rapport couvre les trois modules", #rapport, 3)
  local tousAbsents = true
  for _, l in ipairs(rapport) do
    if l.statut ~= "ABSENT" then tousAbsents = false end
  end
  verifier("le rapport les declare tous ABSENT", tousAbsents)

  ------------------------------------------------------------ module partiel
  -- Un module present mais incomplet doit etre signale comme tel, pas accepte
  -- en bloc : « present » ne vaut pas « conforme ».
  local partiel = liaisonsModule.nouveau({}, function() end, function(chemin)
    if chemin:find("autopilote", 1, true) then
      return function()
        return { definirRoute = function() return true, "route acceptee" end }
      end
    end
    return nil
  end)
  partiel:charger()

  local rapportPartiel
  for _, l in ipairs(partiel:rapport()) do
    if l.module == "autopilote" then rapportPartiel = l end
  end
  egal("module incomplet : statut PARTIEL", rapportPartiel and rapportPartiel.statut, "PARTIEL")
  verifier("et les fonctions manquantes sont nommees",
    rapportPartiel.detail:find("etat", 1, true) ~= nil, rapportPartiel.detail)

  local ok2, resultat = partiel:appeler("autopilote", "definirRoute", {})
  verifier("la fonction presente, elle, fonctionne", ok2 == true and resultat == true)

  local ok3, motif3 = partiel:appeler("autopilote", "engager")
  verifier("la fonction absente echoue avec son motif",
    ok3 == false and motif3:find("n'existe pas", 1, true) ~= nil, tostring(motif3))
end

--------------------------------------------------------------------------------
print("\n== TEST 6 : widgets, une valeur absente ne devient jamais zero ==")
do
  local widgets = dofile(RACINE .. "/vaisseau/widgets.lua")
  local fenetre = fausseFenetre()

  -- On ne peut pas relire les pixels d'une fausse fenetre : on verifie la
  -- logique de decision, qui est la partie qui peut mentir.
  egal("valeur absente -> couleur indisponible",
    widgets.couleurSeuils(nil, { attention = 10 }), widgets.PALETTE.indispo)
  egal("sens normal : au-dessus du seuil critique",
    widgets.couleurSeuils(96, { attention = 70, alarme = 85, critique = 95 }),
    widgets.PALETTE.critique)
  egal("sens inverse : en dessous du seuil critique",
    widgets.couleurSeuils(20, { attention = 70, alarme = 50, critique = 30,
                                sensInverse = true }),
    widgets.PALETTE.critique)
  egal("dans le vert", widgets.couleurSeuils(50,
    { attention = 70, alarme = 85, critique = 95 }), widgets.PALETTE.ok)

  egal("duree en jours", widgets.duree(2 * 86400 + 4 * 3600), "2j 04h")
  egal("duree en heures", widgets.duree(3 * 3600 + 12 * 60), "3h 12m")
  egal("duree en minutes", widgets.duree(45 * 60 + 30), "45m 30s")
  egal("duree en secondes", widgets.duree(45), "45s")
  verifier("duree inconnue", widgets.duree(nil) == nil)
  egal("duree negative ramenee a zero", widgets.duree(-10), "0s")

  -- La jauge accepte nil sans exploser : elle affiche des tirets, pas une
  -- barre a zero qui se lirait « reservoir vide ».
  local ok = pcall(widgets.jauge, fenetre, 1, 1, 10, nil)
  verifier("jauge avec valeur absente : pas d'erreur", ok)
  ok = pcall(widgets.mesure, fenetre, 1, "Test", nil, "%", nil, "capteur muet")
  verifier("mesure avec valeur absente : pas d'erreur", ok)
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
print("\n== TEST 7 : les trois pages dessinent sans mentir ==")
do
  --[[
    Les pages n'etaient couvertes par rien. Or ce sont elles qui traduisent un
    nil du HAL en quelque chose que l'equipage lit : une page qui explose sur
    une mesure absente laisse l'ecran fige sur des chiffres perimes, ce qui est
    pire que pas d'ecran du tout.

    Les pages font 'dofile("/vaisseau/widgets.lua")' - chemin absolu CC. On
    detourne dofile et loadfile vers le depot le temps du test.
  ]]
  local vraiDofile, vraiLoadfile = dofile, loadfile
  local function resoudre(chemin)
    -- carte.lua et noyau.lua vivent dans command/ : c'est bien le meme fichier
    -- qu'on copie a bord, donc c'est lui qu'il faut eprouver.
    local nom = tostring(chemin):match("([^/]+)$")
    if chemin == "/vaisseau/carte.lua" then return RACINE .. "/command/carte.lua" end
    if chemin == "/vaisseau/noyau.lua" then return RACINE .. "/command/noyau.lua" end
    if tostring(chemin):sub(1, 10) == "/vaisseau/" then
      return RACINE .. "/vaisseau/" .. nom
    end
    return chemin
  end
  dofile = function(chemin) return vraiDofile(resoudre(chemin)) end
  loadfile = function(chemin) return vraiLoadfile(resoudre(chemin)) end

  local pages = {}
  for _, nom in ipairs({ "propulsion", "portance", "navigation" }) do
    pages[nom] = vraiDofile(RACINE .. "/vaisseau/pages/" .. nom .. ".lua")
  end

  local function fenetre(l, h)
    local f = fausseFenetre()
    f.largeur, f.hauteur = l, h
    return f
  end

  -- HAL sans AUCUN peripherique : toutes les mesures rendent nil + motif.
  local halModule = dofile(RACINE .. "/vaisseau/hal.lua")
  local halMuet = halModule.nouveau({}, fauxPeripheriques({}), function() end)
  halMuet:decouvrir()

  local halPlein = halModule.nouveau({}, fauxPeripheriques({
    ["back"] = { types = { "machin" }, methodes = {
      getStress = function() return 700 end,
      getStressCapacity = function() return 800 end,
      getSpeed = function() return 96 end,
      getPressure = function() return 25 end,
      getBallast = function() return 40 end,
      getAltitude = function() return 180 end,
      getVerticalSpeed = function() return -8 end,
    } } }), function() end)
  halPlein:decouvrir()

  local liaisonsModule = dofile(RACINE .. "/vaisseau/liaisons.lua")

  local function contexte(hal)
    local lien = liaisonsModule.nouveau({}, function() end, function() return nil end)
    lien:charger()
    return { config = {}, hal = hal, liaisons = lien, journal = function() end,
             etat = { mode = "VEILLE" }, position = { x = 120, y = 180, z = -60 },
             waypoints = {}, zones = zonesEssai, propulsion = {} }
  end

  --[[
    Le point qui compte : capteurs muets ET capteurs bavards, sur une fenetre
    large et sur une fenetre etroite. Les quatre combinaisons doivent dessiner
    sans erreur, parce qu'aucune d'elles n'est improbable a bord.
  ]]
  for _, nom in ipairs({ "propulsion", "portance", "navigation" }) do
    local page = pages[nom]
    verifier(nom .. " : le module se charge", type(page) == "table")
    for _, cas in ipairs({ { "capteurs muets", halMuet }, { "capteurs actifs", halPlein } }) do
      for _, taille in ipairs({ { 51, 19 }, { 18, 8 } }) do
        local ctx = contexte(cas[2])
        if page.init then pcall(page.init, ctx) end
        local ok, err = pcall(page.dessiner, fenetre(taille[1], taille[2]), ctx)
        verifier(string.format("%s : dessine en %dx%d avec %s",
          nom, taille[1], taille[2], cas[1]), ok, tostring(err))
      end
    end
  end

  -- La page navigation a bien trouve la carte : sinon le test ci-dessus
  -- passerait en n'eprouvant que la branche « carte.lua absent ».
  do
    local ctx = contexte(halPlein)
    pages.navigation.init(ctx)
    verifier("navigation : la vue de carte est construite (carte.lua trouve)",
      ctx.navigation.vue ~= nil)
  end

  --[[
    L'ACQUIT DE CARBURANT NUCLEAIRE N'EST PAS UNE MESURE. Il relance un
    minuteur tenu par le systeme ; si un clic ne le relancait pas, la page
    afficherait « non initialise » pour toujours et l'equipage cesserait de la
    regarder.
  ]]
  local ctxProp = contexte(halPlein)
  ctxProp.enregistre = false
  ctxProp.enregistrerEtat = function() ctxProp.enregistre = true end
  pages.propulsion.clic(ctxProp, 5, 5)
  verifier("propulsion : le clic date le renouvellement",
    type(ctxProp.propulsion.renouvelleA) == "number")
  verifier("propulsion : et l'etat est enregistre", ctxProp.enregistre)

  --[[
    LARGAGE DE BALLAST SANS MODULE. C'est le coeur de la regle : un equipage
    qui croit avoir largue et qui n'a rien largue continue de descendre en
    pensant remonter. Le clic doit journaliser un REFUS, jamais un succes.
  ]]
  local dit = {}
  local ctxPort = contexte(halPlein)
  ctxPort.journal = function(_, _, message) dit[#dit + 1] = message end
  pages.portance.clic(ctxPort)
  verifier("portance : le largage sans module est refuse, pas simule",
    #dit == 1 and dit[1]:find("IMPOSSIBLE", 1, true) ~= nil,
    table.concat(dit, " | "))

  -- Meme regle pour la route : « transmise » sans destinataire serait le pire
  -- des mensonges sur une page de navigation.
  local ctxNav = contexte(halPlein)
  pages.navigation.init(ctxNav)
  local okVide, motifVide = pages.navigation.envoyerRoute(ctxNav)
  verifier("navigation : pas de waypoint, pas de route",
    okVide == false and motifVide:find("aucun waypoint", 1, true) ~= nil, tostring(motifVide))

  ctxNav.waypoints = { { nom = "ALPHA", x = 100, z = 200 } }
  local okRoute, motifRoute = pages.navigation.envoyerRoute(ctxNav)
  verifier("navigation : autopilote absent -> route NON transmise",
    okRoute == false and type(motifRoute) == "string" and
    motifRoute:find("absent", 1, true) ~= nil, tostring(motifRoute))

  -- Le clic fait defiler la selection : seul geste possible sans clavier.
  ctxNav.waypoints[2] = { nom = "BRAVO", x = 0, z = 0 }
  pages.navigation.clic(ctxNav)
  egal("navigation : premier clic selectionne le waypoint 1", ctxNav.navigation.actif, 1)
  pages.navigation.clic(ctxNav)
  pages.navigation.clic(ctxNav)
  egal("navigation : la selection boucle", ctxNav.navigation.actif, 1)

  dofile, loadfile = vraiDofile, vraiLoadfile
end

print(string.format("\n===== %d verification(s), %d echec(s) =====", total, echecs))
if echecs > 0 then os.exit(1) end
os.exit(0)
