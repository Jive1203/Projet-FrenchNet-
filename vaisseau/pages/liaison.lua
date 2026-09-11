--[[----------------------------------------------------------------------------
  PAGE LIAISON - ETAT REEL DES INTEGRATIONS (PHASE 2)
  Le tableau de bord de ce que le systeme sait faire et de ce qu'il ne sait pas.

  POURQUOI UNE PAGE ENTIERE POUR CA
  Toutes les autres pages disent « INDISPO » sans pouvoir expliquer pourquoi -
  elles n'ont la place que pour le symptome. Celle-ci porte le diagnostic :
  quel module manque, a quel chemin il est attendu, quelles fonctions il devra
  exposer, et combien de fois on a deja essaye de l'appeler.

  C'est la page a lire AVANT de croire qu'une commande a fonctionne, et c'est
  ce qu'il faut recopier dans un ticket.
--------------------------------------------------------------------------------]]

-- Le repertoire d'installation est pose par vaisseau.lua : un ballon installe
-- ailleurs que dans /vaisseau chargeait jusqu'ici des pages sans widgets, donc
-- aucune page du tout. Le repli garde le cas ou la page est ouverte seule.
local W = dofile((_G.VAISSEAU_REPERTOIRE or "/vaisseau") .. "/widgets.lua")

local page = { titre = "LIAISON", periode = 3 }

local COULEUR_STATUT = {
  OK = W.PALETTE.ok, PARTIEL = W.PALETTE.attention, ABSENT = W.PALETTE.critique,
}

function page.dessiner(fenetre, ctx)
  local largeur, hauteur = fenetre.getSize()
  W.effacer(fenetre)
  W.entete(fenetre, "LIAISONS", ctx.config and ctx.config.identifiant or nil)

  local y = 3

  --------------------------------------------------------- modules exterieurs
  W.texte(fenetre, 2, y, "MODULES", W.PALETTE.titre)
  y = y + 1
  if not ctx.liaisons then
    W.texte(fenetre, 2, y, "couture d'integration absente", W.PALETTE.critique)
    y = y + 1
  else
    for _, l in ipairs(ctx.liaisons:rapport()) do
      if y > hauteur - 6 then break end
      W.texte(fenetre, 2, y, l.module, W.PALETTE.attenue)
      W.texte(fenetre, math.max(2, largeur - #l.statut), y, l.statut,
        COULEUR_STATUT[l.statut] or W.PALETTE.texte)
      y = y + 1
      if y <= hauteur - 6 and largeur >= 30 then
        W.texte(fenetre, 4, y, tostring(l.detail):sub(1, largeur - 5), W.PALETTE.indispo)
        y = y + 1
      end
    end
    -- Le compteur de refus est la mesure honnete de ce qui ne marche pas : il
    -- ne baisse jamais tant que le module manque.
    if y <= hauteur - 5 then
      W.texte(fenetre, 2, y, ("%d appel(s), %d refus")
        :format(ctx.liaisons.appels or 0, ctx.liaisons.refus or 0), W.PALETTE.attenue)
      y = y + 1
    end
  end

  ------------------------------------------------------------------ materiel
  if y <= hauteur - 4 then
    y = y + 1
    W.texte(fenetre, 2, y, "MATERIEL ET RESEAU", W.PALETTE.titre)
    y = y + 1

    if ctx.hal then
      local liees, manquantes, lectures, echecs = ctx.hal:resume()
      W.texte(fenetre, 2, y, ("mesures %d liees / %d manquantes"):format(liees, manquantes),
        manquantes == 0 and W.PALETTE.ok or W.PALETTE.attention)
      y = y + 1
      if y <= hauteur - 2 then
        W.texte(fenetre, 2, y, ("lectures %d, echecs %d"):format(lectures, echecs),
          echecs == 0 and W.PALETTE.attenue or W.PALETTE.alarme)
        y = y + 1
      end
    end

    if ctx.sa and y <= hauteur - 2 then
      local pistes, stations = ctx.sa:resume()
      W.texte(fenetre, 2, y, ("radar %d piste(s), %d station(s)"):format(pistes, stations),
        stations > 0 and W.PALETTE.attenue or W.PALETTE.critique)
      y = y + 1
    end

    if ctx.inventaire and y <= hauteur - 2 then
      local soutes, objets = ctx.inventaire:resume()
      W.texte(fenetre, 2, y, ("soutes %d, %d objet(s)"):format(soutes, objets),
        soutes > 0 and W.PALETTE.attenue or W.PALETTE.indispo)
      y = y + 1
    end

    if ctx.audio and y <= hauteur - 2 then
      local hp = ctx.audio:resume()
      W.texte(fenetre, 2, y, ("haut-parleurs %d"):format(hp),
        hp > 0 and W.PALETTE.attenue or W.PALETTE.attention)
      y = y + 1
    end
  end

  W.texte(fenetre, 2, hauteur, "voir docs/api_notes.md", W.PALETTE.indispo)
end

return page
