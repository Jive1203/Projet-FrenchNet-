--[[----------------------------------------------------------------------------
  PAGE PROPULSION / ENERGIE
  --------------------------------------------------------------------------
  Toutes les valeurs viennent du HAL. Une mesure que le HAL n'a pas su lier
  s'affiche INDISPO avec son motif - jamais un zero, qui se lirait « moteur a
  l'arret » et enverrait l'equipage chercher une panne inexistante.

  Le compte a rebours du carburant nucleaire n'est PAS lu du mod : aucune API
  connue ne l'expose. Il est tenu par le systeme lui-meme, a partir de la duree
  declaree en configuration et de la date du dernier renouvellement, que
  l'equipage valide d'un clic. C'est declare comme tel a l'ecran : une
  echeance tenue a la main doit se savoir tenue a la main.
--------------------------------------------------------------------------------]]

local widgets = dofile("/vaisseau/widgets.lua")

local page = { titre = "PROPULSION", periode = 1 }

function page.init(ctx)
  ctx.propulsion = ctx.propulsion or {}
end

function page.dessiner(fenetre, ctx)
  local largeur, hauteur = fenetre.getSize()
  local hal, cfg = ctx.hal, ctx.config
  local seuils = (cfg.seuils and cfg.seuils.propulsion) or {}

  widgets.effacer(fenetre)
  widgets.entete(fenetre, "PROPULSION", ctx.etat and ctx.etat.mode or nil)

  local y = 3

  ---------------------------------------------------------------- stress
  local stress   = hal:lire("propulsion.stress")
  local capacite = hal:lire("propulsion.capacite")
  local charge   = hal:pourcentage("propulsion.stress", "propulsion.capacite")

  y = y + widgets.mesure(fenetre, y, "Stress", stress, "su",
    nil, select(2, hal:lire("propulsion.stress")))
  if capacite then
    y = y + widgets.mesure(fenetre, y, "Capacite", capacite, "su")
  end
  if charge then
    widgets.texte(fenetre, 2, y, "Charge reseau", widgets.PALETTE.attenue)
    widgets.jauge(fenetre, 2, y + 1, largeur - 2, charge,
      { attention = seuils.chargeAttention or 70,
        alarme    = seuils.chargeAlarme or 85,
        critique  = seuils.chargeCritique or 95 })
    widgets.texte(fenetre, largeur - 5, y, string.format("%3.0f%%", charge),
      widgets.couleurSeuils(charge, {
        attention = seuils.chargeAttention or 70,
        alarme = seuils.chargeAlarme or 85, critique = seuils.chargeCritique or 95 }))
    y = y + 3
  end

  ---------------------------------------------------------------- regime
  local _, motifVitesse = hal:lire("propulsion.vitesse")
  y = y + widgets.mesure(fenetre, y, "Regime", hal:lire("propulsion.vitesse"), "rpm",
    nil, motifVitesse)
  local _, motifPoussee = hal:lire("propulsion.poussee")
  y = y + widgets.mesure(fenetre, y, "Poussee", hal:lire("propulsion.poussee"), "%",
    nil, motifPoussee)

  ---------------------------------------------------------------- energie
  if y < hauteur - 4 then
    local energie = hal:pourcentage("energie.stock", "energie.capacite")
    if energie then
      y = y + 1
      widgets.texte(fenetre, 2, y, "Energie", widgets.PALETTE.attenue)
      widgets.jauge(fenetre, 2, y + 1, largeur - 2, energie,
        { attention = 40, alarme = 20, critique = 10, sensInverse = true })
      y = y + 3
    end
  end

  ------------------------------------------------- carburant nucleaire
  --[[
    Echeance tenue par le systeme, faute d'API. Le libelle le dit : « declare »
    et non « mesure ». Un equipage qui croit lire un capteur alors qu'il lit un
    minuteur ne verifiera jamais le reacteur.
  ]]
  local nucleaire = cfg.carburantNucleaire
  if nucleaire and y < hauteur - 2 then
    local reste
    if nucleaire.dureeSecondes and ctx.propulsion.renouvelleA then
      reste = nucleaire.dureeSecondes - (os.clock() - ctx.propulsion.renouvelleA)
    end
    local texte = widgets.duree(reste) or "non initialise"
    local couleur = widgets.PALETTE.ok
    if reste == nil then couleur = widgets.PALETTE.indispo
    elseif reste <= (nucleaire.critique or 600) then couleur = widgets.PALETTE.critique
    elseif reste <= (nucleaire.alarme or 3600) then couleur = widgets.PALETTE.alarme
    elseif reste <= (nucleaire.attention or 7200) then couleur = widgets.PALETTE.attention end

    widgets.texte(fenetre, 2, y, "Nucleaire (declare)", widgets.PALETTE.attenue)
    widgets.texte(fenetre, math.max(2, largeur - #texte), y, texte, couleur)
    y = y + 1
  end

  -- Biofuel : capacite restante, si le HAL a su la lier.
  local bio = cfg.biofuel and hal:lire(cfg.biofuel.mesure or "energie.stock") or nil
  if bio and y < hauteur then
    widgets.mesure(fenetre, y, "Biofuel", bio, cfg.biofuel.unite or "mB",
      { attention = cfg.biofuel.attention, alarme = cfg.biofuel.alarme,
        critique = cfg.biofuel.critique, sensInverse = true })
    y = y + 1
  end

  if y < hauteur then
    widgets.texte(fenetre, 2, hauteur, "clic : carburant renouvele",
      widgets.PALETTE.indispo)
  end
end

-- Un clic dans la page acquitte le renouvellement du carburant nucleaire.
function page.clic(ctx, x, y)
  ctx.propulsion = ctx.propulsion or {}
  ctx.propulsion.renouvelleA = os.clock()
  if ctx.journal then
    ctx.journal("INFO", "propulsion",
      "renouvellement du carburant nucleaire declare par l'equipage : compte a rebours relance")
  end
  if ctx.enregistrerEtat then ctx.enregistrerEtat() end
end

return page
