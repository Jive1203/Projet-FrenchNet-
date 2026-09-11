--[[----------------------------------------------------------------------------
  PAGE SA - SITUATION TACTIQUE (PHASE 2)
  Carte des contacts autour du ballon, avec la symbologie de FrenchNet Command
  reutilisee verbatim (carte.glyphe / carte.couleurContact).

  POURQUOI LA MEME SYMBOLOGIE QU'AU SOL, SANS LA REECRIRE
  Un equipage qui lit « rouge » a bord et un controleur qui lit « orange » au
  sol pour le meme contact ne se comprendront pas par radio. Deux tables de
  couleurs divergent au premier changement : il n'y en a donc qu'une.

    VERT   code allie, libre passage      BLEU   code general
    ORANGE inconnu, hors zone ou non engage
    ROUGE  confirme ennemi ou engagement en cours
    *  missile   ^  aeronef   o  joueur en vol   #  vehicule   i  infanterie

  La liste de droite est triee par MENACE puis par distance - l'ordre dans
  lequel on veut lire des contacts, pas l'ordre alphabetique.
--------------------------------------------------------------------------------]]

-- Le repertoire d'installation est pose par vaisseau.lua : un ballon installe
-- ailleurs que dans /vaisseau chargeait jusqu'ici des pages sans widgets, donc
-- aucune page du tout. Le repli garde le cas ou la page est ouverte seule.
local W = dofile((_G.VAISSEAU_REPERTOIRE or "/vaisseau") .. "/widgets.lua")

local page = { titre = "SA", periode = 1 }

local carte, noyau

local RACINE = _G.VAISSEAU_REPERTOIRE or "/vaisseau"

local function charger(chemin)
  local f = loadfile(RACINE .. chemin)
  if not f then return nil end
  local ok, m = pcall(f)
  if ok then return m end
end

-- Les cles de couleur de carte.lua, traduites pour un terminal CC.
local COULEURS = {
  allie = colors.lime, general = colors.lightBlue,
  inconnu = colors.orange, engage = colors.red,
}

function page.init(ctx)
  carte = charger("/carte.lua")
  noyau = charger("/noyau.lua")
  ctx.sa_vue = ctx.sa_vue or (carte and carte.nouvelle({
    centreX = (ctx.position or {}).x or 0, centreZ = (ctx.position or {}).z or 0,
    echelle = 128, suivi = "LIBRE" }))
  if not carte and ctx.journal then
    ctx.journal("AVERT", "sa", "carte.lua absent de /vaisseau : la page SA " ..
      "affichera la liste des contacts sans carte. Copiez command/carte.lua a bord.")
  end
end

local function couleurDe(piste)
  if not carte then return colors.white end
  local cle = carte.couleurContact(piste)
  return COULEURS[cle] or colors.white
end

-- Rend aussi la table { [ligneEcran] = indexPiste } : sans elle, le clic ne
-- pourrait pas savoir sur QUEL contact il est tombe.
local function dessinerListe(f, pistes, x0, largeur, hauteur, selection)
  local lignes = {}
  W.texte(f, x0, 2, "CONTACTS", W.PALETTE.titre)
  if #pistes == 0 then
    W.texte(f, x0, 3, "ciel clair", W.PALETTE.attenue)
    return lignes
  end
  local y = 3
  for i, p in ipairs(pistes) do
    if y > hauteur - 1 then break end
    lignes[y] = i
    local glyphe = carte and carte.glyphe(p) or "?"
    local etiquette = ("%s%s %s"):format(selection == i and ">" or " ", glyphe,
      tostring(p.nom or p.id or "?"))
    W.texte(f, x0, y, etiquette:sub(1, largeur), couleurDe(p))
    y = y + 1
    if y <= hauteur - 1 then
      -- Distance, cap, rapprochement : les trois chiffres qu'on annonce a la
      -- radio. Un rapprochement inconnu s'ecrit « ? », jamais « 0 ».
      W.texte(f, x0 + 1, y, ("%s %s %s"):format(
        p.distance and ("%.0fb"):format(p.distance) or "?b",
        p.cap and ("%03.0f"):format(p.cap) or "---",
        p.rapprochement and ("%+.0f"):format(p.rapprochement) or "?"
        ):sub(1, largeur - 1), W.PALETTE.attenue)
      lignes[y] = i
      y = y + 1
    end
  end
  return lignes
end

function page.dessiner(fenetre, ctx)
  local largeur, hauteur = fenetre.getSize()
  local origine = ctx.position or { x = 0, y = 64, z = 0 }
  local pistes = ctx.sa_pistes or {}

  W.effacer(fenetre)
  local pire = ctx.sa_menace or 0
  W.entete(fenetre, "SITUATION TACTIQUE",
    pire >= 3 and "MENACE IMMINENTE" or (#pistes .. " contact(s)"))

  local largeurListe = (largeur >= 40) and 18 or largeur
  local largeurCarte = largeur - largeurListe

  if carte and ctx.sa_vue and largeurCarte >= 12 then
    local vue, hauteurCarte = ctx.sa_vue, hauteur - 3
    -- La carte suit le ballon : pendant un engagement, personne n'a le temps
    -- de la repousser a la main.
    carte.centrer(vue, origine.x, origine.z, "LIBRE")

    if noyau and ctx.zones and #ctx.zones > 0 then
      local grille = carte.rasteriserZones(vue, largeurCarte, hauteurCarte,
        ctx.zones, noyau, origine.y)
      for l = 1, hauteurCarte do
        for c = 1, largeurCarte do
          if grille[l] and grille[l][c] then
            W.texte(fenetre, c, l + 2, " ", nil, colors.gray)
          end
        end
      end
    end

    -- Les contacts du MOINS menacant au PLUS menacant, pour que le plus grave
    -- soit dessine en dernier et reste visible sous une superposition.
    for i = #pistes, 1, -1 do
      local p = pistes[i]
      if p.x and p.z then
        local col, lig, visible = carte.versEcran(vue, p.x, p.z, largeurCarte, hauteurCarte)
        if visible then
          W.texte(fenetre, col, lig + 2, carte.glyphe(p), couleurDe(p))
        end
      end
    end
    local col, lig, visible = carte.versEcran(vue, origine.x, origine.z,
      largeurCarte, hauteurCarte)
    if visible then W.texte(fenetre, col, lig + 2, "+", colors.white) end

    W.texte(fenetre, 1, hauteur, ("%db/car"):format(carte.echelle(vue)), W.PALETTE.indispo)
  else
    W.texte(fenetre, 2, 3, carte and "fenetre trop etroite" or "carte.lua absent",
      W.PALETTE.indispo)
  end

  -- Memorise la geometrie de la liste pour que le clic sache ou il tombe.
  ctx.sa_lignes, ctx.sa_listeX = nil, nil
  if largeurCarte <= 0 then
    ctx.sa_lignes = dessinerListe(fenetre, pistes, 2, largeur - 2, hauteur, ctx.sa_selection)
    ctx.sa_listeX = 2
  elseif largeurListe < largeur then
    ctx.sa_lignes = dessinerListe(fenetre, pistes, largeurCarte + 1, largeurListe,
      hauteur, ctx.sa_selection)
    ctx.sa_listeX = largeurCarte + 1
  end

  -- Provenance des pistes, en permanence : une carte alimentee par une seule
  -- station a des angles morts, et l'equipage doit le savoir avant d'y croire.
  local stations = ctx.sa and select(2, ctx.sa:resume()) or 0
  W.texte(fenetre, math.max(1, largeur - 11), hauteur,
    ("%d station(s)"):format(stations),
    stations > 0 and W.PALETTE.attenue or W.PALETTE.critique)
end

--[[
  CLIC SUR LA LISTE : premier clic sur une ligne = selection, second clic sur
  la MEME ligne = declaration d'allie (et un troisieme la retire).

  C'est la seule facon de couvrir a la main un ami dont le transpondeur est
  detruit ou dont l'ordinateur a saute, sans attendre une rotation de code.
  C'est une decision humaine assumee : elle est journalisee, et elle se defait
  du meme geste. Un clic ailleurs que sur la liste ne fait RIEN - declarer un
  allie par megarde en cliquant sur la carte serait la pire des ergonomies.
]]
function page.clic(ctx, x, y)
  local pistes = ctx.sa_pistes or {}
  if #pistes == 0 or not ctx.sa then return end
  local lignes = ctx.sa_lignes
  if not lignes or not ctx.sa_listeX or x < ctx.sa_listeX then return end

  local index = lignes[y]
  if not index or not pistes[index] then return end

  if ctx.sa_selection == index then
    local p = pistes[index]
    --[[
      On lit l'etat FAISANT FOI (sa.alliesManuels), pas la copie posee sur la
      piste : celle-ci n'est rafraichie qu'une fois par seconde par la boucle
      SA. Deux clics plus rapides que le rafraichissement liraient tous les
      deux l'ancienne valeur, et la declaration ne pourrait plus se retirer.
    ]]
    local declare = ctx.sa.alliesManuels[p.cle] and true or false
    ctx.sa:declarerAllie(p.cle, not declare)
    p.allieManuel = (not declare) or nil   -- l'ecran suit sans attendre la boucle
  else
    ctx.sa_selection = index
  end
end

return page
