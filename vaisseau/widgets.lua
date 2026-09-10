--[[ DOOMSDAY SHIP - primitives d'affichage partagees par les pages.
     Ecrivent dans une FENETRE (window.create), jamais dans le terminal global.
     REGLE : une valeur nil s'affiche INDISPO, jamais 0. Un reservoir vide et
     un capteur muet ne se ressemblent pas ; les confondre se paie cher. ]]

local W = { VERSION = "2.0.0" }
local C = colors

W.PALETTE = {
  fond = C.black, texte = C.white, attenue = C.lightGray, titre = C.cyan,
  ok = C.lime, attention = C.yellow, alarme = C.orange, critique = C.red,
  indispo = C.gray, jauge = C.gray,
}
local P = W.PALETTE

local function coul(f, fg, bg)
  if fg then pcall(f.setTextColour, fg) end
  if bg then pcall(f.setBackgroundColour, bg) end
end

function W.effacer(f, fond) coul(f, P.texte, fond or P.fond) pcall(f.clear) end

function W.texte(f, x, y, t, fg, bg)
  coul(f, fg or P.texte, bg or P.fond)
  pcall(f.setCursorPos, x, y) pcall(f.write, tostring(t))
end

function W.entete(f, titre, sous)
  local l = select(1, f.getSize())
  coul(f, C.black, P.titre)
  pcall(f.setCursorPos, 1, 1) pcall(f.write, string.rep(" ", l))
  pcall(f.setCursorPos, 2, 1) pcall(f.write, tostring(titre):sub(1, l - 2))
  if sous then
    local s, x = tostring(sous), math.max(2, l - #tostring(sous))
    pcall(f.setCursorPos, x, 1) pcall(f.write, s:sub(1, l - x + 1))
  end
  coul(f, P.texte, P.fond)
end

--[[ seuils.sensInverse : la gravite monte quand la valeur BAISSE (pression,
     gaz, munitions). C'est le cas le plus frequent a bord d'un ballon. ]]
function W.couleurSeuils(v, s)
  if v == nil then return P.indispo end
  if not s then return P.texte end
  local function passe(seuil)
    if seuil == nil then return false end
    if s.sensInverse then return v <= seuil end
    return v >= seuil
  end
  if passe(s.critique) then return P.critique end
  if passe(s.alarme) then return P.alarme end
  if passe(s.attention) then return P.attention end
  return P.ok
end

-- Libelle a gauche, valeur a droite. Rend le nombre de lignes consommees.
function W.mesure(f, y, libelle, v, unite, seuils, motif)
  local l = select(1, f.getSize())
  W.texte(f, 2, y, tostring(libelle), P.attenue)
  local t, c
  if v == nil then t, c = "INDISPO", P.indispo
  else t, c = string.format("%.0f%s", v, unite and (" " .. unite) or ""),
              W.couleurSeuils(v, seuils) end
  W.texte(f, math.max(2 + #libelle + 1, l - #t), y, t, c)
  -- Savoir POURQUOI une mesure manque vaut mieux que constater qu'elle manque.
  if v == nil and motif and l >= 30 then
    W.texte(f, 3, y + 1, tostring(motif):sub(1, l - 4), P.indispo)
    return 2
  end
  return 1
end

-- nil -> barre hachuree, pas une barre a zero : une jauge a zero se lirait
-- « reservoir vide », ce qui serait un mensonge.
function W.jauge(f, x, y, larg, pct, seuils)
  if pct == nil then return W.texte(f, x, y, string.rep("-", larg), P.indispo) end
  local n = math.max(0, math.min(larg,
    math.floor(larg * math.max(0, math.min(100, pct)) / 100 + 0.5)))
  coul(f, C.black, W.couleurSeuils(pct, seuils))
  pcall(f.setCursorPos, x, y) pcall(f.write, string.rep(" ", n))
  coul(f, P.texte, P.jauge) pcall(f.write, string.rep(" ", larg - n))
  coul(f, P.texte, P.fond)
end

-- Libelle + pourcentage a droite + jauge dessous. Rend les lignes consommees.
-- Mutualise parce que trois blocs identiques diverges, c'est trois seuils qui
-- finissent par ne plus dire la meme chose que l'alarme.
function W.bandeau(f, y, libelle, pct, seuils)
  local l = select(1, f.getSize())
  W.texte(f, 2, y, libelle, P.attenue)
  if pct then
    W.texte(f, l - 5, y, string.format("%3.0f%%", pct), W.couleurSeuils(pct, seuils))
  else
    W.texte(f, l - 7, y, "INDISPO", P.indispo)
  end
  W.jauge(f, 2, y + 1, l - 2, pct, seuils)
  return 3
end

function W.duree(s)
  if s == nil then return nil end
  s = math.max(0, s)
  local j, h = math.floor(s / 86400), math.floor(s % 86400 / 3600)
  local m, sec = math.floor(s % 3600 / 60), math.floor(s % 60)
  if j > 0 then return string.format("%dj %02dh", j, h) end
  if h > 0 then return string.format("%dh %02dm", h, m) end
  if m > 0 then return string.format("%dm %02ds", m, sec) end
  return string.format("%ds", sec)
end

return W
