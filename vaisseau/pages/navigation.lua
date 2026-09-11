--[[----------------------------------------------------------------------------
  PAGE CARTE / WAYPOINTS
  Reutilise command/carte.lua (projection, echelles, symbologie) plutot que de
  redessiner une carte a cote : deux cartes divergeraient au premier
  changement, et l'equipage ne saurait plus laquelle croire.

  Rendu en caracteres : un moniteur CC n'a pas de couche graphique, et chaque
  caractere modifie est un paquet envoye aux joueurs alentour. La « basse
  resolution » n'est pas une concession, c'est la seule forme possible.

  L'ENVOI A L'AUTOPILOTE PASSE PAR LA COUTURE D'INTEGRATION. Aucun autopilote
  n'existe dans le depot (docs/api_notes.md) : la route est construite,
  affichee, enregistree, et l'envoi ECHOUE avec son motif en clair. Afficher
  « route transmise » sans destinataire serait le pire des mensonges sur une
  page de navigation.
--------------------------------------------------------------------------------]]

-- Le repertoire d'installation est pose par vaisseau.lua : un ballon installe
-- ailleurs que dans /vaisseau chargeait jusqu'ici des pages sans widgets, donc
-- aucune page du tout. Le repli garde le cas ou la page est ouverte seule.
local W = dofile((_G.VAISSEAU_REPERTOIRE or "/vaisseau") .. "/widgets.lua")

local page = { titre = "NAVIGATION", periode = 1 }

local carte, noyau   -- charges paresseusement : la page reste utilisable sans

local RACINE = _G.VAISSEAU_REPERTOIRE or "/vaisseau"

local function charger(chemin)
  local f = loadfile(RACINE .. chemin)
  if not f then return nil end
  local ok, module = pcall(f)
  if ok then return module end
end

function page.init(ctx)
  carte = charger("/carte.lua")
  noyau = charger("/noyau.lua")

  ctx.navigation = ctx.navigation or {}
  ctx.waypoints = ctx.waypoints or {}
  if carte and not ctx.navigation.vue then
    local p = ctx.position or { x = 0, y = 64, z = 0 }
    ctx.navigation.vue = carte.nouvelle(
      { centreX = p.x, centreZ = p.z, echelle = 64, suivi = "LIBRE" })
  end
  if not carte and ctx.journal then
    ctx.journal("AVERT", "navigation", "carte.lua absent de /vaisseau : la page " ..
      "affiche la liste des waypoints sans fond de carte. Copiez command/carte.lua a bord.")
  end
end

local function dessinerListe(f, ctx, x0, largeur, hauteur)
  W.texte(f, x0, 2, "WAYPOINTS", W.PALETTE.titre)
  if #ctx.waypoints == 0 then
    return W.texte(f, x0, 3, "aucun", W.PALETTE.indispo)
  end
  local y = 3
  for i, w in ipairs(ctx.waypoints) do
    if y > hauteur - 2 then break end
    local actif = (ctx.navigation.actif == i)
    W.texte(f, x0, y, ("%d %s"):format(i, tostring(w.nom or "?")):sub(1, largeur),
      actif and W.PALETTE.ok or W.PALETTE.texte)
    y = y + 1
    if actif and y <= hauteur - 2 then
      W.texte(f, x0 + 1, y, ("%.0f/%.0f"):format(w.x or 0, w.z or 0):sub(1, largeur - 1),
        W.PALETTE.attenue)
      y = y + 1
    end
  end
end

local function dessinerCarte(f, ctx, largeur, hauteur, position)
  local vue, hauteurCarte = ctx.navigation.vue, hauteur - 3

  -- Fond de zones seulement si le ballon connait les zones du theatre : mieux
  -- vaut une carte noire qu'un fond invente.
  if noyau and ctx.zones and #ctx.zones > 0 then
    local grille = carte.rasteriserZones(vue, largeur, hauteurCarte, ctx.zones, noyau, position.y)
    for ligne = 1, hauteurCarte do
      for col = 1, largeur do
        if grille[ligne] and grille[ligne][col] then
          W.texte(f, col, ligne + 2, " ", nil, colors.gray)
        end
      end
    end
  end

  -- Waypoints puis le ballon PAR-DESSUS : c'est lui qu'on doit voir quand deux
  -- symboles se superposent.
  for i, w in ipairs(ctx.waypoints) do
    local col, lig, visible = carte.versEcran(vue, w.x, w.z, largeur, hauteurCarte)
    if visible then
      W.texte(f, col, lig + 2, tostring(i):sub(1, 1),
        (ctx.navigation.actif == i) and W.PALETTE.ok or W.PALETTE.attention)
    end
  end
  local col, lig, visible = carte.versEcran(vue, position.x, position.z, largeur, hauteurCarte)
  if visible then W.texte(f, col, lig + 2, "+", colors.white) end

  W.texte(f, 1, hauteur, ("%d b/car  clic: waypoint"):format(carte.echelle(vue)),
    W.PALETTE.indispo)
end

function page.dessiner(fenetre, ctx)
  local largeur, hauteur = fenetre.getSize()
  local position = ctx.position or { x = 0, y = 64, z = 0 }

  W.effacer(fenetre)
  W.entete(fenetre, "NAVIGATION", ("%.0f/%.0f"):format(position.x, position.z))

  -- Colonne de liste a droite si la fenetre est assez large, sinon liste seule.
  local largeurListe = (largeur >= 40) and 16 or largeur
  local largeurCarte = largeur - largeurListe

  if carte and ctx.navigation.vue and largeurCarte >= 12 then
    dessinerCarte(fenetre, ctx, largeurCarte, hauteur, position)
  else
    W.texte(fenetre, 2, 3, carte and "fenetre trop etroite pour la carte"
      or "carte.lua absent", W.PALETTE.indispo)
  end

  if largeurCarte <= 0 then
    dessinerListe(fenetre, ctx, 2, largeur - 2, hauteur)
  elseif largeurListe < largeur then
    dessinerListe(fenetre, ctx, largeurCarte + 1, largeurListe, hauteur)
  end

  -- Etat de la liaison autopilote, en clair et en permanence : sans lui, tout
  -- ce qui est au-dessus n'est qu'un brouillon.
  local dispo = ctx.liaisons and ctx.liaisons:disponible("autopilote")
  W.texte(fenetre, math.max(1, largeur - 12), hauteur,
    dispo and "AP CONNECTE" or "AP ABSENT",
    dispo and W.PALETTE.ok or W.PALETTE.critique)
end

-- Un clic fait defiler la selection : sur un moniteur sans clavier, c'est le
-- seul geste disponible.
function page.clic(ctx)
  local nombre = #ctx.waypoints
  if nombre == 0 then return end
  ctx.navigation.actif = ((ctx.navigation.actif or 0) % nombre) + 1
end

-- Retourne ok, motif - affiche tel quel. Tant que l'autopilote est absent
-- cette fonction echoue toujours, et c'est le comportement voulu.
function page.envoyerRoute(ctx)
  if #ctx.waypoints == 0 then return false, "aucun waypoint a transmettre" end
  if not ctx.liaisons then return false, "couture d'integration absente" end

  local ok, motif = ctx.liaisons:appeler("autopilote", "definirRoute", ctx.waypoints)
  if ctx.journal then
    ctx.journal(ok and "INFO" or "AVERT", "navigation",
      ok and ("route de %d waypoint(s) transmise a l'autopilote"):format(#ctx.waypoints)
      or ("route NON transmise : " .. tostring(motif)))
  end
  return ok, motif
end

return page
