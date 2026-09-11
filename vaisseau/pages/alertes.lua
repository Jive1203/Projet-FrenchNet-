--[[----------------------------------------------------------------------------
  PAGE ALERTES - TABLEAU DE BORD D'AMBIANCE (PHASE 4)
  Le « grand ecran » du ballon : etat general, alarmes en cours, son, et le
  titre en cours de lecture si un relais en fournit un.

  POURQUOI PAS DE VIDEO, ET POURQUOI C'EST ECRIT ICI
  Un moniteur CC n'a pas de decodeur, et chaque caractere modifie est un paquet
  reseau envoye a tous les joueurs a portee. Une video, meme basse resolution,
  saturerait le serveur pour un resultat illisible. Ce n'est pas une limite de
  code : c'est la nature du support. La page affiche donc du texte et des
  couleurs, et le dit plutot que de laisser esperer autre chose.

  Le titre en cours vient de musique.lua, qui annonce toujours sa SOURCE :
  HTTP si le relais est joignable depuis le jeu, RESEAU si un ordinateur
  exterieur le pousse par rednet, AUCUN sinon. Un titre sans source affichee
  laisserait croire que le relais marche alors qu'il est mort depuis une heure.
--------------------------------------------------------------------------------]]

-- Le repertoire d'installation est pose par vaisseau.lua : un ballon installe
-- ailleurs que dans /vaisseau chargeait jusqu'ici des pages sans widgets, donc
-- aucune page du tout. Le repli garde le cas ou la page est ouverte seule.
local W = dofile((_G.VAISSEAU_REPERTOIRE or "/vaisseau") .. "/widgets.lua")

local page = { titre = "ALERTES", periode = 2 }

local COULEUR_MENACE = {
  [0] = colors.lime, [1] = colors.lightBlue, [2] = colors.orange, [3] = colors.red,
}
local MOT_MENACE = { [0] = "CIEL CLAIR", "VEILLE", "ATTENTION", "MENACE IMMINENTE" }

function page.dessiner(fenetre, ctx)
  local largeur, hauteur = fenetre.getSize()
  W.effacer(fenetre)

  local menace = ctx.sa_menace or 0
  W.entete(fenetre, "ETAT GENERAL", ctx.config and ctx.config.identifiant or nil)

  -- Bandeau d'etat, centre et large : c'est ce qu'on lit du fond de la nacelle.
  local mot = MOT_MENACE[menace] or "?"
  W.texte(fenetre, math.max(2, math.floor((largeur - #mot) / 2) + 1), 3, mot,
    COULEUR_MENACE[menace])

  local y = 5

  --------------------------------------------------------------- alarmes en cours
  W.texte(fenetre, 2, y, "ALARMES", W.PALETTE.titre)
  y = y + 1
  local actives = ctx.alarmesActives or {}
  if #actives == 0 then
    W.texte(fenetre, 2, y, "aucune", W.PALETTE.ok)
    y = y + 1
  else
    for _, a in ipairs(actives) do
      if y > hauteur - 5 then break end
      W.texte(fenetre, 2, y, tostring(a.titre):sub(1, largeur - 2),
        a.niveau == "CRITIQUE" and W.PALETTE.critique
        or a.niveau == "ALARME" and W.PALETTE.alarme or W.PALETTE.attention)
      y = y + 1
    end
  end

  ------------------------------------------------------------------------ son
  if y <= hauteur - 3 then
    y = y + 1
    local hp, actif = 0, nil
    if ctx.audio then hp, actif = ctx.audio:resume() end
    local muet, motifMuet = ctx.audio and ctx.audio:silencieux(ctx.maintenant or 0)
    local texte, couleur
    if hp == 0 then
      texte, couleur = "AUCUN HAUT-PARLEUR", W.PALETTE.attention
    elseif muet then
      texte, couleur = tostring(motifMuet):sub(1, largeur - 8), W.PALETTE.attention
    else
      texte, couleur = actif or "veille", W.PALETTE.attenue
    end
    W.texte(fenetre, 2, y, "Son", W.PALETTE.attenue)
    W.texte(fenetre, math.max(6, largeur - #texte), y, texte, couleur)
    y = y + 1
  end

  -------------------------------------------------------------------- musique
  if y <= hauteur - 2 and ctx.musique then
    local piste, motif = ctx.musique:etat(ctx.maintenant or 0)
    W.texte(fenetre, 2, y, "Lecture", W.PALETTE.attenue)
    y = y + 1
    if piste then
      W.texte(fenetre, 3, y, tostring(piste.titre):sub(1, largeur - 4), W.PALETTE.texte)
      y = y + 1
      if y <= hauteur - 1 then
        -- La source est affichee AVEC le titre, jamais sans : un titre seul
        -- laisserait croire que le relais repond alors qu'il est peut-etre mort.
        W.texte(fenetre, 3, y, ("%s%s"):format(piste.artiste and (piste.artiste .. " ") or "",
          "[" .. tostring(piste.source) .. "]"):sub(1, largeur - 4), W.PALETTE.indispo)
        y = y + 1
      end
    else
      W.texte(fenetre, 3, y, tostring(motif or "aucun relais"):sub(1, largeur - 4),
        W.PALETTE.indispo)
      y = y + 1
    end
  end

  W.texte(fenetre, 2, hauteur, "clic : couper le son", W.PALETTE.indispo)
end

-- Le clic coupe le son, temporairement. Jamais definitivement : un ballon qui
-- vole muet pour le reste de la partie n'entendra pas la prochaine alarme.
function page.clic(ctx)
  if not ctx.audio then return end
  ctx.audio:silencier(nil, ctx.maintenant or 0)
end

return page
