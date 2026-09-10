--[[----------------------------------------------------------------------------
  PAGE CARTE / WAYPOINTS
  --------------------------------------------------------------------------
  Reutilise command/carte.lua - projection, echelles, symbologie - plutot que
  de redessiner une carte a cote. Deux cartes divergeraient au premier
  changement, et l'equipage ne saurait plus laquelle croire.

  Rendu en caracteres, pas en texture : un moniteur CC n'a pas de couche
  graphique, et chaque caractere modifie est un paquet envoye aux joueurs
  alentour. Une carte « basse resolution » n'est pas une concession ici, c'est
  la seule forme possible.

  L'ENVOI A L'AUTOPILOTE PASSE PAR LA COUTURE D'INTEGRATION. Aucun autopilote
  n'etant present dans le depot (voir docs/api_notes.md), la route est
  construite, affichee, enregistree - et l'envoi echoue avec son motif, en
  clair sur la page. Afficher « route transmise » sans destinataire serait le
  pire des mensonges pour une page de navigation.
--------------------------------------------------------------------------------]]

local widgets = dofile("/vaisseau/widgets.lua")

local page = { titre = "NAVIGATION", periode = 1 }

local carte, noyau   -- charges paresseusement : la page reste utilisable sans

function page.init(ctx)
  local chargeCarte = loadfile("/vaisseau/carte.lua")
  if chargeCarte then
    local ok, module = pcall(chargeCarte)
    if ok then carte = module end
  end
  local chargeNoyau = loadfile("/vaisseau/noyau.lua")
  if chargeNoyau then
    local ok, module = pcall(chargeNoyau)
    if ok then noyau = module end
  end

  ctx.navigation = ctx.navigation or {}
  if carte and not ctx.navigation.vue then
    local p = ctx.position or { x = 0, y = 64, z = 0 }
    ctx.navigation.vue = carte.nouvelle({ centreX = p.x, centreZ = p.z, echelle = 64,
                                          suivi = "LIBRE" })
  end
  ctx.waypoints = ctx.waypoints or {}
  if not carte and ctx.journal then
    ctx.journal("AVERT", "navigation",
      "carte.lua absent de /vaisseau : la page affiche la liste des waypoints " ..
      "sans fond de carte. Copiez command/carte.lua a bord.")
  end
end

local function dessinerListe(fenetre, ctx, x0, largeur, hauteur)
  widgets.texte(fenetre, x0, 2, "WAYPOINTS", widgets.PALETTE.titre)
  local y = 3
  if #ctx.waypoints == 0 then
    widgets.texte(fenetre, x0, y, "aucun", widgets.PALETTE.indispo)
    return
  end
  for i, w in ipairs(ctx.waypoints) do
    if y > hauteur - 2 then break end
    local actif = (ctx.navigation.actif == i)
    local etiquette = string.format("%d %s", i, tostring(w.nom or "?"))
    widgets.texte(fenetre, x0, y, etiquette:sub(1, largeur),
      actif and widgets.PALETTE.ok or widgets.PALETTE.texte)
    y = y + 1
    if actif and y <= hauteur - 2 then
      widgets.texte(fenetre, x0 + 1, y,
        string.format("%.0f/%.0f", w.x or 0, w.z or 0):sub(1, largeur - 1),
        widgets.PALETTE.attenue)
      y = y + 1
    end
  end
end

function page.dessiner(fenetre, ctx)
  local largeur, hauteur = fenetre.getSize()
  widgets.effacer(fenetre)

  local position = ctx.position or { x = 0, y = 64, z = 0 }
  widgets.entete(fenetre, "NAVIGATION",
    string.format("%.0f/%.0f", position.x, position.z))

  -- Colonne de liste a droite si la fenetre est assez large, sinon liste seule.
  local largeurListe = (largeur >= 40) and 16 or largeur
  local largeurCarte = largeur - largeurListe

  if carte and ctx.navigation.vue and largeurCarte >= 12 then
    local vue = ctx.navigation.vue
    local hauteurCarte = hauteur - 3
    local grille = {}

    -- Le fond de zones n'est dessine que si le ballon connait les zones du
    -- theatre. Sans elles, la carte reste noire : mieux vaut un fond vide
    -- qu'un fond invente.
    if noyau and ctx.zones and #ctx.zones > 0 then
      grille = carte.rasteriserZones(vue, largeurCarte, hauteurCarte,
        ctx.zones, noyau, position.y)
    end

    for ligne = 1, hauteurCarte do
      for col = 1, largeurCarte do
        local classe = grille[ligne] and grille[ligne][col]
        if classe then
          widgets.texte(fenetre, col, ligne + 2, " ", nil, colors.gray)
        end
      end
    end

    -- Waypoints, puis le ballon par-dessus : c'est lui qu'on doit voir en
    -- premier quand deux symboles se superposent.
    for i, w in ipairs(ctx.waypoints) do
      local col, lig, visible = carte.versEcran(vue, w.x, w.z, largeurCarte, hauteurCarte)
      if visible then
        widgets.texte(fenetre, col, lig + 2,
          tostring(i):sub(1, 1),
          (ctx.navigation.actif == i) and widgets.PALETTE.ok or widgets.PALETTE.attention)
      end
    end

    local col, lig, visible = carte.versEcran(vue, position.x, position.z,
      largeurCarte, hauteurCarte)
    if visible then
      widgets.texte(fenetre, col, lig + 2, "+", colors.white)
    end

    widgets.texte(fenetre, 1, hauteur,
      string.format("%d b/car  clic: waypoint", carte.echelle(vue)),
      widgets.PALETTE.indispo)
  else
    widgets.texte(fenetre, 2, 3,
      carte and "fenetre trop etroite pour la carte" or "carte.lua absent",
      widgets.PALETTE.indispo)
  end

  if largeurCarte > 0 and largeurListe < largeur then
    dessinerListe(fenetre, ctx, largeurCarte + 1, largeurListe, hauteur)
  elseif largeurCarte <= 0 then
    dessinerListe(fenetre, ctx, 2, largeur - 2, hauteur)
  end

  -- Etat de la liaison autopilote, en clair et en permanence.
  local disponible = ctx.liaisons and ctx.liaisons:disponible("autopilote")
  widgets.texte(fenetre, math.max(1, largeur - 12), hauteur,
    disponible and "AP CONNECTE" or "AP ABSENT",
    disponible and widgets.PALETTE.ok or widgets.PALETTE.critique)
end

function page.clic(ctx, x, y)
  local nombre = #ctx.waypoints
  if nombre == 0 then return end
  -- Un clic fait defiler la selection : sur un moniteur sans clavier, c'est
  -- le seul geste disponible.
  ctx.navigation.actif = ((ctx.navigation.actif or 0) % nombre) + 1
end

--[[
  Transmission de la route. Retourne ok, motif - et le motif est affiche tel
  quel. Tant que l'autopilote est absent, cette fonction echoue toujours, et
  c'est le comportement voulu.
]]
function page.envoyerRoute(ctx)
  if #ctx.waypoints == 0 then return false, "aucun waypoint a transmettre" end
  if not ctx.liaisons then return false, "couture d'integration absente" end

  local ok, motif = ctx.liaisons:appeler("autopilote", "definirRoute", ctx.waypoints)
  if ctx.journal then
    ctx.journal(ok and "INFO" or "AVERT", "navigation",
      ok and string.format("route de %d waypoint(s) transmise a l'autopilote", #ctx.waypoints)
      or ("route NON transmise : " .. tostring(motif)))
  end
  return ok, motif
end

return page
