--[[----------------------------------------------------------------------------
  DOOMSDAY SHIP - PRIMITIVES D'AFFICHAGE PARTAGEES PAR LES PAGES
  --------------------------------------------------------------------------
  Une page ne doit pas reinventer une jauge. Ces primitives ecrivent dans une
  FENETRE (objet rendu par window.create), jamais dans le terminal global.

  REGLE COMMUNE A TOUTES : une valeur nil s'affiche « INDISPO » et non « 0 ».
  Un reservoir vide et un capteur muet ne se ressemblent pas ; les confondre
  sur une page de portance se paie cher.
--------------------------------------------------------------------------------]]

local widgets = { VERSION = "1.0.0" }

widgets.PALETTE = {
  fond      = colors.black,
  texte     = colors.white,
  attenue   = colors.lightGray,
  titre     = colors.cyan,
  ok        = colors.lime,
  attention = colors.yellow,
  alarme    = colors.orange,
  critique  = colors.red,
  indispo   = colors.gray,
  jauge     = colors.gray,
}

local function couleurs(fenetre, fg, bg)
  if fg then pcall(fenetre.setTextColour, fg) end
  if bg then pcall(fenetre.setBackgroundColour, bg) end
end

function widgets.effacer(fenetre, fond)
  couleurs(fenetre, widgets.PALETTE.texte, fond or widgets.PALETTE.fond)
  pcall(fenetre.clear)
end

function widgets.texte(fenetre, x, y, texte, fg, bg)
  couleurs(fenetre, fg or widgets.PALETTE.texte, bg or widgets.PALETTE.fond)
  pcall(fenetre.setCursorPos, x, y)
  pcall(fenetre.write, tostring(texte))
end

function widgets.entete(fenetre, titre, sousTitre)
  local largeur = select(1, fenetre.getSize())
  couleurs(fenetre, colors.black, widgets.PALETTE.titre)
  pcall(fenetre.setCursorPos, 1, 1)
  pcall(fenetre.write, string.rep(" ", largeur))
  pcall(fenetre.setCursorPos, 2, 1)
  pcall(fenetre.write, tostring(titre):sub(1, largeur - 2))
  if sousTitre then
    local s = tostring(sousTitre)
    local x = math.max(2, largeur - #s)
    pcall(fenetre.setCursorPos, x, 1)
    pcall(fenetre.write, s:sub(1, largeur - x + 1))
  end
  couleurs(fenetre, widgets.PALETTE.texte, widgets.PALETTE.fond)
end

--[[
  Couleur d'une valeur selon des seuils croissants de gravite.
  seuils = { attention = , alarme = , critique = , sensInverse = bool }
  sensInverse : la gravite augmente quand la valeur BAISSE (pression, gaz,
  munitions). C'est le cas le plus frequent a bord d'un ballon.
]]
function widgets.couleurSeuils(valeur, seuils)
  if valeur == nil then return widgets.PALETTE.indispo end
  if not seuils then return widgets.PALETTE.texte end
  local P = widgets.PALETTE
  local function depasse(seuil)
    if seuil == nil then return false end
    if seuils.sensInverse then return valeur <= seuil end
    return valeur >= seuil
  end
  if depasse(seuils.critique)  then return P.critique end
  if depasse(seuils.alarme)    then return P.alarme end
  if depasse(seuils.attention) then return P.attention end
  return P.ok
end

--[[
  Ligne de mesure : libelle a gauche, valeur a droite.
  valeur = nil -> « INDISPO » en gris, et le motif est affiche si la place le
  permet : savoir POURQUOI une mesure manque vaut mieux que constater qu'elle
  manque.
]]
function widgets.mesure(fenetre, y, libelle, valeur, unite, seuils, motif)
  local largeur = select(1, fenetre.getSize())
  widgets.texte(fenetre, 2, y, tostring(libelle), widgets.PALETTE.attenue)

  local texte, couleur
  if valeur == nil then
    texte, couleur = "INDISPO", widgets.PALETTE.indispo
  else
    texte = string.format("%.0f%s", valeur, unite and (" " .. unite) or "")
    couleur = widgets.couleurSeuils(valeur, seuils)
  end

  local x = math.max(2 + #libelle + 1, largeur - #texte)
  widgets.texte(fenetre, x, y, texte, couleur)

  if valeur == nil and motif and largeur >= 30 then
    local court = tostring(motif):sub(1, largeur - 4)
    widgets.texte(fenetre, 3, y + 1, court, widgets.PALETTE.indispo)
    return 2
  end
  return 1
end

--[[
  Jauge horizontale. pourcentage = nil -> barre vide hachuree, pas une barre a
  zero : une jauge a zero se lit « reservoir vide », ce qui serait un mensonge.
]]
function widgets.jauge(fenetre, x, y, largeur, pourcentage, seuils)
  local P = widgets.PALETTE
  if pourcentage == nil then
    widgets.texte(fenetre, x, y, string.rep("-", largeur), P.indispo)
    return
  end
  local rempli = math.max(0, math.min(largeur,
    math.floor(largeur * math.max(0, math.min(100, pourcentage)) / 100 + 0.5)))
  local couleur = widgets.couleurSeuils(pourcentage, seuils)
  couleurs(fenetre, colors.black, couleur)
  pcall(fenetre.setCursorPos, x, y)
  pcall(fenetre.write, string.rep(" ", rempli))
  couleurs(fenetre, P.texte, P.jauge)
  pcall(fenetre.write, string.rep(" ", largeur - rempli))
  couleurs(fenetre, P.texte, P.fond)
end

-- Compte a rebours lisible : 2j 04h, 3h 12m, 45s.
function widgets.duree(secondes)
  if secondes == nil then return nil end
  if secondes < 0 then secondes = 0 end
  local j = math.floor(secondes / 86400)
  local h = math.floor((secondes % 86400) / 3600)
  local m = math.floor((secondes % 3600) / 60)
  local s = math.floor(secondes % 60)
  if j > 0 then return string.format("%dj %02dh", j, h) end
  if h > 0 then return string.format("%dh %02dm", h, m) end
  if m > 0 then return string.format("%dm %02ds", m, s) end
  return string.format("%ds", s)
end

return widgets
