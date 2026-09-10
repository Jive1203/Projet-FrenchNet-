--[[----------------------------------------------------------------------------
  PAGE PORTANCE / ENVELOPPE
  --------------------------------------------------------------------------
  Page absente de la demande initiale, ajoutee parce qu'un ballon qui perd sa
  portance ne le signale nulle part ailleurs : la page propulsion montrerait un
  moteur en parfait etat pendant toute la descente.

  L'alarme de perte de portance est DISTINCTE des alarmes moteur, volontairement.
  Une alarme unique « avarie » obligerait l'equipage a diagnostiquer avant
  d'agir, et les gestes ne sont pas les memes : couper la poussee ne remonte pas
  un ballon, larguer du ballast si.
--------------------------------------------------------------------------------]]

local widgets = dofile("/vaisseau/widgets.lua")

local page = { titre = "PORTANCE", periode = 1 }

function page.dessiner(fenetre, ctx)
  local largeur, hauteur = fenetre.getSize()
  local hal, cfg = ctx.hal, ctx.config
  local seuils = (cfg.seuils and cfg.seuils.portance) or {}

  widgets.effacer(fenetre)
  widgets.entete(fenetre, "PORTANCE / ENVELOPPE")

  local y = 3

  ---------------------------------------------------------------- enveloppe
  local pression = hal:lire("portance.pression")
  local _, motifPression = hal:lire("portance.pression")
  widgets.texte(fenetre, 2, y, "Pression enveloppe", widgets.PALETTE.attenue)
  local seuilsPression = {
    attention = seuils.pressionAttention or 70,
    alarme    = seuils.pressionAlarme or 50,
    critique  = seuils.pressionCritique or 30,
    sensInverse = true,
  }
  if pression then
    widgets.texte(fenetre, largeur - 5, y, string.format("%3.0f%%", pression),
      widgets.couleurSeuils(pression, seuilsPression))
  else
    widgets.texte(fenetre, largeur - 7, y, "INDISPO", widgets.PALETTE.indispo)
  end
  widgets.jauge(fenetre, 2, y + 1, largeur - 2, pression, seuilsPression)
  y = y + 3
  if not pression and motifPression and hauteur > 12 then
    widgets.texte(fenetre, 3, y, tostring(motifPression):sub(1, largeur - 4),
      widgets.PALETTE.indispo)
    y = y + 1
  end

  ---------------------------------------------------------------- cellules
  local gaz = hal:lire("portance.gaz")
  widgets.texte(fenetre, 2, y, "Cellules de gaz", widgets.PALETTE.attenue)
  if gaz then
    widgets.texte(fenetre, largeur - 5, y, string.format("%3.0f%%", gaz),
      widgets.couleurSeuils(gaz, seuilsPression))
  else
    widgets.texte(fenetre, largeur - 7, y, "INDISPO", widgets.PALETTE.indispo)
  end
  widgets.jauge(fenetre, 2, y + 1, largeur - 2, gaz, seuilsPression)
  y = y + 3

  ---------------------------------------------------------------- ballast
  local ballast = hal:lire("portance.ballast")
  widgets.texte(fenetre, 2, y, "Ballast", widgets.PALETTE.attenue)
  if ballast then
    widgets.texte(fenetre, largeur - 5, y, string.format("%3.0f%%", ballast),
      widgets.PALETTE.texte)
  else
    widgets.texte(fenetre, largeur - 7, y, "INDISPO", widgets.PALETTE.indispo)
  end
  widgets.jauge(fenetre, 2, y + 1, largeur - 2, ballast)
  y = y + 3

  ---------------------------------------------------------------- vol
  y = y + widgets.mesure(fenetre, y, "Altitude", hal:lire("vol.altitude"), "b")

  local vario = hal:lire("vol.vitesseVerticale")
  local seuilsVario = {
    attention = seuils.varioAttention or -3,
    alarme    = seuils.varioAlarme or -6,
    critique  = seuils.varioCritique or -10,
    sensInverse = true,
  }
  widgets.texte(fenetre, 2, y, "Variometre", widgets.PALETTE.attenue)
  if vario then
    local texte = string.format("%+.1f b/s", vario)
    widgets.texte(fenetre, math.max(2, largeur - #texte), y, texte,
      widgets.couleurSeuils(vario, seuilsVario))
  else
    widgets.texte(fenetre, largeur - 7, y, "INDISPO", widgets.PALETTE.indispo)
  end
  y = y + 1

  ---------------------------------------------------------------- largage
  if y < hauteur then
    local disponible = ballast ~= nil and ballast > 0
    widgets.texte(fenetre, 2, hauteur,
      disponible and "clic : larguer du ballast" or "largage indisponible",
      disponible and widgets.PALETTE.attention or widgets.PALETTE.indispo)
  end
end

--[[
  Largage manuel. Il passe par la couture d'integration : aucun module de
  ballast n'etant present dans le depot, l'ordre est REFUSE avec son motif
  plutot qu'accepte en silence. Un equipage qui croit avoir largue et qui n'a
  rien largue continue de descendre en pensant remonter.
]]
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
