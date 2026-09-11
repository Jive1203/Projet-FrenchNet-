--[[----------------------------------------------------------------------------
  PAGE ARMEMENT (PHASE 3)
  AAA, MS-GA, ML-GA, M-GG, Artillerie.

  CETTE PAGE EST VOLONTAIREMENT INERTE, ET ELLE L'ANNONCE
  Le Fire Control Embarque n'existe pas dans le depot (verifie branche par
  branche, docs/api_notes.md). Ecrire ici 'fireControl.engager(cible)' en
  devinant le nom produirait une page qui a l'air de fonctionner jusqu'au
  premier engagement reel - le moment ou personne ne peut plus verifier.

  Ce qui marche quand meme, et qui n'est pas une simulation :
    - la SELECTION de cible, prise de sa.lua ;
    - le COMPTE EN SOUTE des obus et de la poudre, lu sur de vrais coffres par
      l'API d'inventaire de CC, qui est documentee et stable.

  Ce qui ne marche pas et ne fera pas semblant : l'etat des pieces, leurs
  munitions en culasse, la mise en securite, le tir. Le jour ou le Fire Control
  arrive, il y a un seul fichier a modifier : vaisseau/liaisons.lua.
--------------------------------------------------------------------------------]]

-- Le repertoire d'installation est pose par vaisseau.lua : un ballon installe
-- ailleurs que dans /vaisseau chargeait jusqu'ici des pages sans widgets, donc
-- aucune page du tout. Le repli garde le cas ou la page est ouverte seule.
local W = dofile((_G.VAISSEAU_REPERTOIRE or "/vaisseau") .. "/widgets.lua")

local page = { titre = "ARMEMENT", periode = 2 }

-- Les cinq systemes du cahier des charges. Tant que le Fire Control est
-- absent, ils ne sont qu'une liste : c'est exactement ce que la page montre.
page.SYSTEMES = {
  { cle = "AAA",       libelle = "AAA",          role = "defense rapprochee" },
  { cle = "MS-GA",     libelle = "MS-GA",        role = "missile sol-air court" },
  { cle = "ML-GA",     libelle = "ML-GA",        role = "missile sol-air long" },
  { cle = "M-GG",      libelle = "M-GG",         role = "missile sol-sol" },
  { cle = "ARTILLERY", libelle = "Artillerie",   role = "tir indirect" },
}

function page.dessiner(fenetre, ctx)
  local largeur, hauteur = fenetre.getSize()
  local present = ctx.liaisons and ctx.liaisons:disponible("fireControl")

  W.effacer(fenetre)
  W.entete(fenetre, "ARMEMENT", present and nil or "INERTE")

  local y = 3

  ----------------------------------------------------------------- les pieces
  local declarees
  if present then
    local ok, liste = ctx.liaisons:appeler("fireControl", "armes")
    if ok and type(liste) == "table" then declarees = liste end
  end

  for _, s in ipairs(page.SYSTEMES) do
    if y > hauteur - 6 then break end
    local etat = declarees and declarees[s.cle]
    local texte, couleur
    if etat == nil then
      -- nil, pas « 0 coup » : un systeme dont on ignore l'etat et un systeme
      -- vide n'appellent pas les memes ordres.
      texte, couleur = "INDISPO", W.PALETTE.indispo
    else
      texte = tostring(etat.munitions or "?") .. " cp"
      couleur = etat.pret and W.PALETTE.ok or W.PALETTE.attention
    end
    W.texte(fenetre, 2, y, s.libelle, W.PALETTE.attenue)
    W.texte(fenetre, math.max(2, largeur - #texte), y, texte, couleur)
    y = y + 1
  end

  ------------------------------------------------------------------ la soute
  if y < hauteur - 3 then
    y = y + 1
    W.texte(fenetre, 2, y, "EN SOUTE", W.PALETTE.titre)
    y = y + 1
    for _, cle in ipairs({ "obus", "poudre", "missiles" }) do
      if y >= hauteur - 1 then break end
      local n = ctx.inventaire and ctx.inventaire:compter(cle)
      y = y + W.mesure(fenetre, y, cle:sub(1, 1):upper() .. cle:sub(2), n, nil, nil,
        n == nil and "aucune soute reliee, ou motif inconnu de la configuration" or nil)
    end
  end

  ---------------------------------------------------------------- la verite
  if not present then
    -- Ecrit en rouge et en bas, la ou on regarde avant d'agir.
    local _, motif = ctx.liaisons and ctx.liaisons:module("fireControl")
    W.texte(fenetre, 2, hauteur - 1, "TIR IMPOSSIBLE : Fire Control absent",
      W.PALETTE.critique)
    if motif then
      W.texte(fenetre, 2, hauteur, tostring(motif):sub(1, largeur - 2), W.PALETTE.indispo)
    end
  else
    local cible = (ctx.sa_pistes or {})[ctx.sa_selection or 0]
    W.texte(fenetre, 2, hauteur,
      cible and ("clic : engager " .. tostring(cible.nom or cible.id or "?")):sub(1, largeur - 2)
      or "aucune cible selectionnee (page SA)",
      cible and W.PALETTE.attention or W.PALETTE.indispo)
  end
end

--[[
  Engagement. Il ne part JAMAIS sans cible selectionnee sur la page SA : un
  « tirer sur quelque chose » implicite est exactement le genre d'ordre qui
  touche un allie. Et sans Fire Control, il ne part pas du tout.
]]
function page.clic(ctx)
  if not ctx.liaisons then return end
  local cible = (ctx.sa_pistes or {})[ctx.sa_selection or 0]
  if not cible then
    if ctx.journal then
      ctx.journal("AVERT", "armement",
        "engagement refuse : aucune cible selectionnee sur la page SA")
    end
    return
  end
  if cible.iff == "ALLIE" or cible.allieManuel then
    -- Garde-fou local, en plus de la doctrine du sol : refuser ici coute une
    -- ligne, laisser passer coute un allie.
    if ctx.journal then
      ctx.journal("AVERT", "armement", ("engagement REFUSE : %s porte un code allie")
        :format(tostring(cible.nom or cible.id or "?")))
    end
    return
  end

  local ok, motif = ctx.liaisons:appeler("fireControl", "engager", cible)
  if ctx.journal then
    ctx.journal(ok and "INFO" or "AVERT", "armement",
      ok and ("engagement commande sur %s"):format(tostring(cible.nom or cible.id))
      or ("engagement IMPOSSIBLE : " .. tostring(motif)))
  end
end

return page
