--[[----------------------------------------------------------------------------
  PAGE PROPULSION / ENERGIE
  Tout vient du HAL. Une mesure non liee s'affiche INDISPO avec son motif,
  jamais un zero : « 0 rpm » se lirait « moteur a l'arret » et enverrait
  l'equipage chercher une panne inexistante.

  Le compte a rebours du carburant nucleaire n'est PAS lu du mod (aucune API
  connue ne l'expose) : il est tenu par le systeme, a partir de la duree
  configuree et d'un acquittement de l'equipage. Le libelle dit « declare »
  et non « mesure » - un equipage qui croit lire un capteur alors qu'il lit un
  minuteur ne verifiera jamais le reacteur.
--------------------------------------------------------------------------------]]

-- Le repertoire d'installation est pose par vaisseau.lua : un ballon installe
-- ailleurs que dans /vaisseau chargeait jusqu'ici des pages sans widgets, donc
-- aucune page du tout. Le repli garde le cas ou la page est ouverte seule.
local W = dofile((_G.VAISSEAU_REPERTOIRE or "/vaisseau") .. "/widgets.lua")

local page = { titre = "PROPULSION", periode = 1 }

function page.init(ctx) ctx.propulsion = ctx.propulsion or {} end

-- Mesure + son motif d'indisponibilite en un seul appel au HAL.
local function ligne(f, y, hal, cle, libelle, unite, seuils)
  local v, motif = hal:lire(cle)
  return W.mesure(f, y, libelle, v, unite, seuils, motif)
end

function page.dessiner(fenetre, ctx)
  local largeur, hauteur = fenetre.getSize()
  local hal, cfg = ctx.hal, ctx.config
  local s = (cfg.seuilsPages and cfg.seuilsPages.propulsion) or {}

  W.effacer(fenetre)
  W.entete(fenetre, "PROPULSION", ctx.etat and ctx.etat.mode or nil)

  local y = 3
  y = y + ligne(fenetre, y, hal, "propulsion.stress", "Stress", "su")

  local capacite = hal:lire("propulsion.capacite")
  if capacite then y = y + W.mesure(fenetre, y, "Capacite", capacite, "su") end

  local charge = hal:pourcentage("propulsion.stress", "propulsion.capacite")
  if charge then
    y = y + W.bandeau(fenetre, y, "Charge reseau", charge,
      { attention = s.chargeAttention or 70, alarme = s.chargeAlarme or 85,
        critique = s.chargeCritique or 95 })
  end

  y = y + ligne(fenetre, y, hal, "propulsion.vitesse", "Regime", "rpm")
  y = y + ligne(fenetre, y, hal, "propulsion.poussee", "Poussee", "%")

  local energie = y < hauteur - 4 and hal:pourcentage("energie.stock", "energie.capacite")
  if energie then
    y = y + 1 + W.bandeau(fenetre, y + 1, "Energie", energie,
      { attention = 40, alarme = 20, critique = 10, sensInverse = true })
  end

  local nuc = cfg.carburantNucleaire
  if nuc and y < hauteur - 2 then
    local reste
    if nuc.dureeSecondes and ctx.propulsion.renouvelleA then
      reste = nuc.dureeSecondes - (os.clock() - ctx.propulsion.renouvelleA)
    end
    local texte = W.duree(reste) or "non initialise"
    -- Seuils en 'if' explicite : un ternaire enchaine ici finirait par masquer
    -- le cas 'reste == nil', qui doit rester gris et non vert.
    local couleur = W.PALETTE.ok
    if reste == nil then couleur = W.PALETTE.indispo
    elseif reste <= (nuc.critique or 600) then couleur = W.PALETTE.critique
    elseif reste <= (nuc.alarme or 3600) then couleur = W.PALETTE.alarme
    elseif reste <= (nuc.attention or 7200) then couleur = W.PALETTE.attention end

    W.texte(fenetre, 2, y, "Nucleaire (declare)", W.PALETTE.attenue)
    W.texte(fenetre, math.max(2, largeur - #texte), y, texte, couleur)
    y = y + 1
  end

  local bio = cfg.biofuel and hal:lire(cfg.biofuel.mesure or "energie.stock")
  if bio and y < hauteur then
    y = y + W.mesure(fenetre, y, "Biofuel", bio, cfg.biofuel.unite or "mB",
      { attention = cfg.biofuel.attention, alarme = cfg.biofuel.alarme,
        critique = cfg.biofuel.critique, sensInverse = true })
  end

  if y < hauteur then
    W.texte(fenetre, 2, hauteur, "clic : carburant renouvele", W.PALETTE.indispo)
  end
end

-- Un clic acquitte le renouvellement du carburant nucleaire.
function page.clic(ctx)
  ctx.propulsion = ctx.propulsion or {}
  ctx.propulsion.renouvelleA = os.clock()
  if ctx.journal then
    ctx.journal("INFO", "propulsion", "renouvellement du carburant nucleaire " ..
      "declare par l'equipage : compte a rebours relance")
  end
  if ctx.enregistrerEtat then ctx.enregistrerEtat() end
end

return page
