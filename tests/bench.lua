-- Banc de MESURE de FrenchNet Command, hors du jeu.
--   Usage : lua5.4 tests/bench.lua   (depuis la racine du depot)
--
-- Optimiser sans mesurer, c'est deviner. Ce banc chronometre les chemins
-- reellement chauds du poste de commandement, avec des tailles realistes :
-- huit zones, un theatre de plusieurs milliers de blocs, un moniteur 3x3, une
-- douzaine de plateformes. Il affiche pour chaque chemin le temps par appel ET
-- la memoire allouee - sur un ordinateur CC: Tweaked, le ramasse-miettes coute
-- souvent plus cher que le calcul lui-meme.
--
-- A relancer apres toute modification touchant la carte, le terrain ou la
-- geometrie des zones. Les ordres de grandeur mesures sur cette machine ne
-- sont pas ceux du jeu, mais les RAPPORTS entre eux, si.
--
-- Reperes obtenus apres optimisation (lua5.4, machine de developpement) :
--   zonePourPoint hors zone .............. 0.0037 ms   (etait 0.0058)
--   rasteriserZones 51x11 ................ 0.32   ms   (etait 3.85)
--   rasteriserZones 58x36 (moniteur 3x3) . 0.65   ms   (etait 12.75)
--   terrain.hauteurSol releve direct ..... 0.0004 ms   (etait 0.0013)
--   terrain.echantillonner ............... 0.015  ms   (etait 0.224)
--   tampon d'affichage 58x36 ............. 0.054  ms   (etait 0.145)

local RACINE = (arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."
local noyau   = dofile(RACINE .. "/command/noyau.lua")
local terrain = dofile(RACINE .. "/command/terrain.lua")
local carte   = dofile(RACINE .. "/command/carte.lua")

local function chrono(nom, iterations, fn)
  collectgarbage("collect")
  local memAvant = collectgarbage("count")
  local t0 = os.clock()
  for i = 1, iterations do fn(i) end
  local dt = os.clock() - t0
  local memApres = collectgarbage("count")
  print(string.format("%-42s %8.2f ms total  %9.4f ms/appel  %+8.0f ko",
    nom, dt * 1000, dt * 1000 / iterations, memApres - memAvant))
  return dt
end

-- Theatre realiste : 8 zones, dont 4 polygones et 4 cercles
local zones = {}
for i = 1, 4 do
  local cx, cz = i * 400, i * 300
  zones[#zones+1] = { nom="R"..i, classe="ALPHA", forme="rectangle", points = noyau.ordonnerCoins{
    {x=cx-200,z=cz-200},{x=cx+200,z=cz-200},{x=cx+200,z=cz+200},{x=cx-200,z=cz+200} } }
  zones[#zones+1] = { nom="C"..i, classe="BRAVO", forme="cercle",
    centre={x=-cx,z=cz}, rayon=250 }
end

print("== GEOMETRIE ==")
chrono("zonePourPoint (8 zones, hors zone)", 20000, function(i)
  noyau.zonePourPoint(zones, 9000 + i % 10, 100, 9000)
end)
chrono("zonePourPoint (8 zones, dans un rect)", 20000, function(i)
  noyau.zonePourPoint(zones, 400 + i % 10, 100, 300)
end)

print("\n== CARTE : rasterisation du fond ==")
local vue = carte.nouvelle({ centreX = 400, centreZ = 300, echelle = 32 })
-- terminal 51x11 puis moniteur 3x3 a l'echelle 0.5 (58x36)
for _, dim in ipairs({ {51,11,"terminal 51x11"}, {58,36,"moniteur 3x3 58x36"} }) do
  chrono("rasteriserZones " .. dim[3], 20, function()
    carte.rasteriserZones(vue, dim[1], dim[2], zones, noyau, 100)
  end)
end

print("\n== TERRAIN ==")
local m = terrain.nouveau({ resolution = 16, altitudeDefaut = 64, cellulesMax = 4000 })
for i = 1, 3000 do
  terrain.echantillonner(m, (i % 60) * 16, 70 + i % 8, math.floor(i / 60) * 16, "contact", i)
end
chrono("hauteurSol (releve direct)", 20000, function(i)
  terrain.hauteurSol(m, (i % 60) * 16, math.floor((i % 3000) / 60) * 16)
end)
chrono("hauteurSol (interpolation, 3 anneaux)", 5000, function(i)
  terrain.hauteurSol(m, 5000 + i, 5000)
end)
chrono("echantillonner", 20000, function(i)
  terrain.echantillonner(m, (i % 60) * 16, 70, math.floor(i / 60) * 16, "contact", i)
end)

print("\n== DESIGNATION ==")
local plateformes = {}
for i = 1, 12 do
  plateformes[i] = { nom = "P" .. i, x = i * 100, y = 100, z = 0,
                     munitions = i, tirs = i * 2, portee = 2000 }
end
chrono("designer (12 plateformes)", 20000, function()
  noyau.designer(plateformes, { x = 500, y = 150, z = 0, categorie = "AERIENNE" }, {})
end)

print("\n== CONFIRMATION DE DESTRUCTION ==")
local piste = { present = true, echantillons = {} }
for i = 1, 20 do piste.echantillons[i] = { t = i, x = i * 10, y = 150, z = 0 } end
chrono("evaluerDestruction (20 echantillons)", 20000, function()
  noyau.evaluerDestruction(piste, { ordreA = 0 }, { porteeRadar = 500 }, 20)
end)

print("\n== TAMPON DE JOURNAL (table.remove en tete) ==")
local tampon = {}
chrono("ecriture journal, tampon 200 lignes", 20000, function(i)
  tampon[#tampon + 1] = { niveau = "DEBUG", texte = "ligne " .. i }
  while #tampon > 200 do table.remove(tampon, 1) end
end)

print("\n== TAMPON D'AFFICHAGE ==")
local PALETTE = { texte = 1, fond = 32768 }
local function nouveauTampon(largeur, hauteur, fond)
  local t = {}
  for l = 1, hauteur do
    local ligne = { ch = {}, fg = {}, bg = {} }
    for c = 1, largeur do
      ligne.ch[c], ligne.fg[c], ligne.bg[c] = " ", PALETTE.texte, fond
    end
    t[l] = ligne
  end
  return t
end
chrono("nouveauTampon 58x36 (alloue a chaque image)", 500, function()
  nouveauTampon(58, 36, PALETTE.fond)
end)

local reutilise
local function tamponReutilise(largeur, hauteur, fond)
  local t = reutilise
  if not t or t.largeur ~= largeur or t.hauteur ~= hauteur then
    t = nouveauTampon(largeur, hauteur, fond)
    t.largeur, t.hauteur = largeur, hauteur
    reutilise = t
    return t
  end
  for l = 1, hauteur do
    local ligne = t[l]
    for c = 1, largeur do
      ligne.ch[c], ligne.fg[c], ligne.bg[c] = " ", PALETTE.texte, fond
    end
  end
  return t
end
chrono("tampon reutilise 58x36", 500, function()
  tamponReutilise(58, 36, PALETTE.fond)
end)
