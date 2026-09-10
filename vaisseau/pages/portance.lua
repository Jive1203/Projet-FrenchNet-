--[[----------------------------------------------------------------------------
  PAGE PORTANCE / ENVELOPPE
  Absente de la demande initiale, ajoutee parce qu'un ballon qui perd sa
  portance ne le signale nulle part ailleurs : la page propulsion montrerait un
  moteur en parfait etat pendant toute la descente.

  Ses alarmes sont DISTINCTES des alarmes moteur, volontairement : une alarme
  unique « avarie » obligerait a diagnostiquer avant d'agir, et couper la
  poussee ne remonte pas un ballon, larguer du ballast si.
--------------------------------------------------------------------------------]]

local W = dofile("/vaisseau/widgets.lua")

local page = { titre = "PORTANCE", periode = 1 }

function page.dessiner(fenetre, ctx)
  local largeur, hauteur = fenetre.getSize()
  local hal, cfg = ctx.hal, ctx.config
  local s = (cfg.seuils and cfg.seuils.portance) or {}

  W.effacer(fenetre)
  W.entete(fenetre, "PORTANCE / ENVELOPPE")

  -- sensInverse : sur une enveloppe, c'est la valeur BASSE qui est grave.
  local seuilsGaz = {
    attention = s.pressionAttention or 70, alarme = s.pressionAlarme or 50,
    critique = s.pressionCritique or 30, sensInverse = true,
  }

  local y = 3
  local pression, motifPression = hal:lire("portance.pression")
  y = y + W.bandeau(fenetre, y, "Pression enveloppe", pression, seuilsGaz)
  if not pression and motifPression and hauteur > 12 then
    W.texte(fenetre, 3, y, tostring(motifPression):sub(1, largeur - 4), W.PALETTE.indispo)
    y = y + 1
  end

  y = y + W.bandeau(fenetre, y, "Cellules de gaz", hal:lire("portance.gaz"), seuilsGaz)

  -- Ballast sans seuils : plein ou vide, aucun des deux n'est une avarie.
  local ballast = hal:lire("portance.ballast")
  y = y + W.bandeau(fenetre, y, "Ballast", ballast)

  y = y + W.mesure(fenetre, y, "Altitude", hal:lire("vol.altitude"), "b")

  local vario = hal:lire("vol.vitesseVerticale")
  W.texte(fenetre, 2, y, "Variometre", W.PALETTE.attenue)
  if vario then
    -- Signe force : « 2.0 b/s » sans signe se lit monter alors qu'on descend.
    local texte = string.format("%+.1f b/s", vario)
    W.texte(fenetre, math.max(2, largeur - #texte), y, texte, W.couleurSeuils(vario, {
      attention = s.varioAttention or -3, alarme = s.varioAlarme or -6,
      critique = s.varioCritique or -10, sensInverse = true }))
  else
    W.texte(fenetre, largeur - 7, y, "INDISPO", W.PALETTE.indispo)
  end
  y = y + 1

  if y < hauteur then
    local possible = ballast ~= nil and ballast > 0
    W.texte(fenetre, 2, hauteur,
      possible and "clic : larguer du ballast" or "largage indisponible",
      possible and W.PALETTE.attention or W.PALETTE.indispo)
  end
end

-- Largage manuel via la couture d'integration : aucun module de ballast n'etant
-- present, l'ordre est REFUSE avec son motif plutot qu'accepte en silence. Un
-- equipage qui croit avoir largue continue de descendre en pensant remonter.
function page.clic(ctx)
  if not ctx.liaisons then return end
  local ok, motif = ctx.liaisons:appeler("autopilote", "largerBallast")
  if ctx.journal then
    ctx.journal(ok and "INFO" or "AVERT", "portance",
      ok and "largage de ballast commande"
      or ("largage de ballast IMPOSSIBLE : " .. tostring(motif)))
  end
end

return page
