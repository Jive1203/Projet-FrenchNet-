--[[----------------------------------------------------------------------------
  PAGE EW - GUERRE ELECTRONIQUE ET CONTRE-MESURES (PHASES 2 ET 3)

  DEUX MOITIES QUI N'ONT PAS LE MEME STATUT, ET LA PAGE LE DIT
  - DETECTION (phase 2) : elle marche. Les menaces viennent de sa.lua, qui
    fusionne les stations radar FrenchNet et le radar du bord.
  - LARGAGE (phase 3) : il est BLOQUE. Le module ADS n'existe pas dans le
    depot. Le bouton est donc affiche INACTIF, et un clic journalise un refus
    motive au lieu d'un succes.

  C'est le point ou mentir couterait le plus cher de tout le systeme : un
  equipage qui croit avoir largue ses leurres ne manoeuvre pas, et prend le
  missile. « Largage commande » sans destinataire serait pire que pas de page
  du tout.

  Le stock de leurres a DEUX sources possibles, jamais confondues a l'ecran :
  l'ADS s'il existe (ce qui est pret au largage), et le recensement des soutes
  sinon (ce qu'il y a dans les coffres). Un leurre en soute n'est pas un leurre
  en tube.
--------------------------------------------------------------------------------]]

-- Le repertoire d'installation est pose par vaisseau.lua : un ballon installe
-- ailleurs que dans /vaisseau chargeait jusqu'ici des pages sans widgets, donc
-- aucune page du tout. Le repli garde le cas ou la page est ouverte seule.
local W = dofile((_G.VAISSEAU_REPERTOIRE or "/vaisseau") .. "/widgets.lua")

local page = { titre = "EW", periode = 1 }

local COULEUR_MENACE = {
  [0] = colors.gray, [1] = colors.lightBlue, [2] = colors.orange, [3] = colors.red,
}

function page.dessiner(fenetre, ctx)
  local largeur, hauteur = fenetre.getSize()
  local pistes, pire = ctx.sa_pistes or {}, ctx.sa_menace or 0
  local saModule = ctx.sa_module

  W.effacer(fenetre)
  W.entete(fenetre, "GUERRE ELECTRONIQUE",
    saModule and saModule.NOM_MENACE[pire] or nil)

  local y = 3

  ------------------------------------------------------------------- menaces
  W.texte(fenetre, 2, y, "MENACES", W.PALETTE.titre)
  y = y + 1
  local comptees = 0
  for _, p in ipairs(pistes) do
    if (p.menace or 0) >= 2 and y <= hauteur - 6 then
      comptees = comptees + 1
      W.texte(fenetre, 2, y, ("%s %s"):format(p.nature == "MISSILE" and "*" or "!",
        tostring(p.nom or p.id or "?")):sub(1, largeur - 12), COULEUR_MENACE[p.menace])
      local droite = p.distance and ("%.0fb"):format(p.distance) or "?b"
      W.texte(fenetre, math.max(2, largeur - #droite), y, droite, COULEUR_MENACE[p.menace])
      y = y + 1
      if y <= hauteur - 6 and p.motifMenace then
        W.texte(fenetre, 4, y, tostring(p.motifMenace):sub(1, largeur - 5), W.PALETTE.attenue)
        y = y + 1
      end
    end
  end
  if comptees == 0 then
    W.texte(fenetre, 2, y, "aucune menace classee", W.PALETTE.ok)
    y = y + 1
  end

  ------------------------------------------------------------------- leurres
  y = math.max(y + 1, hauteur - 5)
  local adsPresent = ctx.liaisons and ctx.liaisons:disponible("ads")
  local stock, sourceStock, motifStock

  if adsPresent then
    local ok, valeur = ctx.liaisons:appeler("ads", "stock")
    if ok and type(valeur) == "number" then stock, sourceStock = valeur, "ADS"
    else motifStock = tostring(valeur) end
  else
    _, motifStock = ctx.liaisons and ctx.liaisons:module("ads")
    -- Repli honnete : ce qu'il y a dans les coffres, annonce comme tel.
    if ctx.inventaire then
      local compte = ctx.inventaire:compter("leurres")
      if compte then stock, sourceStock = compte, "SOUTE" end
    end
  end

  W.texte(fenetre, 2, y, "Leurres", W.PALETTE.attenue)
  local texte = stock and ("%d (%s)"):format(stock, sourceStock) or "INDISPO"
  W.texte(fenetre, math.max(2, largeur - #texte), y,
    texte, stock and (sourceStock == "ADS" and W.PALETTE.ok or W.PALETTE.attention)
    or W.PALETTE.indispo)
  y = y + 1

  if sourceStock == "SOUTE" and y < hauteur then
    -- Le mot compte : « en soute » n'est pas « en tube ».
    W.texte(fenetre, 3, y, "compte en soute, PAS pret au largage",
      W.PALETTE.attention)
    y = y + 1
  elseif not stock and motifStock and y < hauteur then
    W.texte(fenetre, 3, y, tostring(motifStock):sub(1, largeur - 4), W.PALETTE.indispo)
    y = y + 1
  end

  W.texte(fenetre, 2, hauteur,
    adsPresent and "clic : larguer leurres" or "LARGAGE INDISPONIBLE (ADS absent)",
    adsPresent and W.PALETTE.attention or W.PALETTE.critique)
end

-- Le largage passe par la couture d'integration et par elle seule. ADS absent
-- -> refus motive, journalise, affiche. Jamais un succes simule.
function page.clic(ctx)
  if not ctx.liaisons then return end
  local ok, motif = ctx.liaisons:appeler("ads", "larguer", "TOUT")
  if ctx.journal then
    ctx.journal(ok and "INFO" or "AVERT", "ew",
      ok and "largage de leurres commande"
      or ("largage de leurres IMPOSSIBLE : " .. tostring(motif)))
  end
  ctx.ew_dernierRefus = (not ok) and motif or nil
end

return page
