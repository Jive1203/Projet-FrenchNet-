--[[----------------------------------------------------------------------------
  FRENCHNET COMMAND - CARTE TACTIQUE MOUVANTE
  --------------------------------------------------------------------------
  Projection monde <-> ecran, symbologie des contacts, rasterisation des zones.

  PRINCIPE : la carte n'a pas de table de zones a elle. Pour colorier une case
  elle interroge le MEME moteur que celui qui prend les decisions
  (noyau.zonePourPoint). La carte ne peut donc pas mentir sur la doctrine :
  ce qu'on voit a l'ecran est litteralement ce que le systeme applique.

  CARACTERES NON CARRES : un caractere de terminal CC: Tweaked fait environ
  6 x 9 pixels. Sans correction, un cercle de zone s'afficherait comme une
  ellipse ecrasee et les distances seraient trompeuses a l'oeil. Le rapport
  ASPECT compense : une ligne couvre 1,5 fois plus de blocs qu'une colonne.

  Aucune API du jeu n'est utilisee ici : ce module est testable hors du jeu.
--------------------------------------------------------------------------------]]

local carte = { VERSION = "1.0.0" }

local function nombreValide(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Blocs par colonne de caractere. Du plus fin au plus large.
carte.ECHELLES = { 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024 }
carte.ASPECT   = 1.5

--------------------------------------------------------------------------------
-- 1. SYMBOLOGIE
--
--    REGLE DE LECTURE : le GLYPHE dit CE QUE C'EST, la COULEUR dit QUI C'EST.
--    Les deux informations sont independantes, donc lisibles d'un coup d'oeil
--    sans avoir a memoriser une combinatoire.
--
--    GLYPHES (nature du contact)
--      *   missile ou projectile - tout ce qui vole trop vite pour etre pilote
--      ^   aeronef ou navire volant (contraption en vol)
--      o   joueur en vol (elytre, jetpack)
--      #   vehicule au sol
--      i   infanterie
--      R   station radar   L  lanceur   +  poste de commandement
--
--    COULEURS (identification et engagement)
--      VERT    code allie : libre passage
--      BLEU    code general
--      ORANGE  inconnu, hors zone ou non engage
--      ROUGE   confirme ennemi, ou engagement en cours
--------------------------------------------------------------------------------

carte.SYMBOLE_MISSILE    = "*"
carte.SYMBOLE_AERONEF    = "^"
carte.SYMBOLE_JOUEUR_VOL = "o"
carte.SYMBOLE_VEHICULE   = "#"
carte.SYMBOLE_INFANTERIE = "i"

carte.SYMBOLE_INFRA = {
  COMMANDEMENT = "+",
  RADAR        = "R",
  PLATEFORME   = "T",
  LANCEUR      = "L",
}

-- Cles de couleur. L'interface les traduit en couleurs de terminal.
carte.COULEURS = {
  ALLIE   = "allie",    -- vert
  GENERAL = "general",  -- bleu
  INCONNU = "inconnu",  -- orange
  ENGAGE  = "engage",   -- rouge
}

--[[
  Glyphe du contact : sa nature d'abord, sa categorie ensuite.
  Un missile reste un missile quelle que soit son altitude ; un joueur en vol
  n'est ni un aeronef ni de l'infanterie, et le controleur doit pouvoir faire
  la difference avant de lancer quoi que ce soit contre lui.
]]
function carte.glyphe(piste)
  if piste.nature == "MISSILE" then return carte.SYMBOLE_MISSILE end
  if piste.categorie == "AERIENNE" then
    if piste.nature == "JOUEUR" then return carte.SYMBOLE_JOUEUR_VOL end
    return carte.SYMBOLE_AERONEF
  end
  if piste.categorie == "INFANTERIE" then return carte.SYMBOLE_INFANTERIE end
  if piste.categorie == "VEHICULE_SOL" then return carte.SYMBOLE_VEHICULE end
  -- Contact pas encore classe : on ne prejuge pas de sa nature.
  return "?"
end

--[[
  Couleur du contact.
  ROUGE est reserve a ce qui est reellement traite comme ennemi : un ordre de
  destruction decide, ou un engagement ouvert. Un inconnu qui traverse une zone
  Charlie en paix n'est pas rouge - il est ORANGE, parce que le systeme ne lui
  fait rien. Confondre les deux ferait passer la carte du orange au rouge en
  permanence, et le rouge cesserait de vouloir dire quelque chose.
]]
function carte.couleurContact(piste)
  local engage = (piste.engagement and piste.engagement.actif)
              or ((piste.verdict and piste.verdict.palier or 0) >= 3)
  if engage then return carte.COULEURS.ENGAGE, "engagement en cours ou destruction decidee" end

  local iff = piste.iff
  if piste.allieManuel or iff == "ALLIE" then
    return carte.COULEURS.ALLIE, piste.allieManuel and "allie declare par un controleur"
      or "code allie : libre passage"
  end
  if iff == "GENERAL" then return carte.COULEURS.GENERAL, "code general" end
  return carte.COULEURS.INCONNU, "inconnu, hors zone ou non engage"
end

-- Glyphe et couleur d'un coup, pour l'appelant qui ne veut pas des deux motifs.
function carte.symbole(piste)
  local couleur, motif = carte.couleurContact(piste)
  return carte.glyphe(piste), couleur, motif
end

--------------------------------------------------------------------------------
-- 2. VUE (carte mouvante)
--------------------------------------------------------------------------------

--[[
  suivi :
    "LIBRE"   -> le controleur deplace la carte lui-meme
    "POSTE"   -> recentrage permanent sur le poste de commandement
    "MENACE"  -> recentrage permanent sur le contact le plus dangereux
    <id>      -> verrouillage sur une piste precise
  C'est ce recentrage automatique qui fait la "moving map" : la carte suit la
  situation sans qu'on ait a la pousser a la main pendant un engagement.
]]
function carte.nouvelle(config)
  config = config or {}
  local echelle = nombreValide(config.echelle) and config.echelle or 32
  local index = 1
  for i, e in ipairs(carte.ECHELLES) do
    if e == echelle then index = i break end
    if e <= echelle then index = i end
  end
  return {
    centreX      = nombreValide(config.centreX) and config.centreX or 0,
    centreZ      = nombreValide(config.centreZ) and config.centreZ or 0,
    indexEchelle = index,
    suivi        = config.suivi or "MENACE",
    version      = 0,   -- incremente a chaque changement : invalide le cache
  }
end

function carte.echelle(vue) return carte.ECHELLES[vue.indexEchelle] end

function carte.zoomer(vue, sens)
  local nouveau = math.max(1, math.min(#carte.ECHELLES, vue.indexEchelle + sens))
  if nouveau == vue.indexEchelle then return false end
  vue.indexEchelle = nouveau
  vue.version = vue.version + 1
  return true, carte.echelle(vue)
end

-- Deplacement exprime en CARACTERES : un appui sur une fleche deplace d'un
-- pas constant a l'ecran, quelle que soit l'echelle.
function carte.deplacer(vue, colonnes, lignes)
  local e = carte.echelle(vue)
  vue.centreX = vue.centreX + colonnes * e
  vue.centreZ = vue.centreZ + lignes * e * carte.ASPECT
  vue.suivi = "LIBRE"
  vue.version = vue.version + 1
  return vue.centreX, vue.centreZ
end

function carte.centrer(vue, x, z, suivi)
  vue.centreX, vue.centreZ = x, z
  if suivi then vue.suivi = suivi end
  vue.version = vue.version + 1
end

--------------------------------------------------------------------------------
-- 3. PROJECTION
--    Le repere ecran est local a la zone de carte : colonne 1..largeur,
--    ligne 1..hauteur. L'appelant ajoute ses propres decalages.
--    Nord (Z decroissant) vers le haut, Est (X croissant) vers la droite.
--------------------------------------------------------------------------------

function carte.versEcran(vue, x, z, largeur, hauteur)
  local e = carte.echelle(vue)
  local col   = math.floor((x - vue.centreX) / e + largeur / 2) + 1
  local ligne = math.floor((z - vue.centreZ) / (e * carte.ASPECT) + hauteur / 2) + 1
  local visible = col >= 1 and col <= largeur and ligne >= 1 and ligne <= hauteur
  return col, ligne, visible
end

function carte.versMonde(vue, col, ligne, largeur, hauteur)
  local e = carte.echelle(vue)
  local x = vue.centreX + (col - 1 - largeur / 2 + 0.5) * e
  local z = vue.centreZ + (ligne - 1 - hauteur / 2 + 0.5) * e * carte.ASPECT
  return x, z
end

-- Etendue du monde actuellement visible, pour l'affichage de l'echelle.
function carte.etendue(vue, largeur, hauteur)
  local e = carte.echelle(vue)
  return largeur * e, hauteur * e * carte.ASPECT
end

--------------------------------------------------------------------------------
-- 4. RASTERISATION DES ZONES
--    Pour chaque case de la carte, on demande sa classe au noyau. Le resultat
--    est mis en cache : il ne change que si la vue bouge ou si les zones sont
--    modifiees. Sans cache, on referait des milliers de tests de polygone a
--    chaque rafraichissement.
--------------------------------------------------------------------------------

--[[
  Boite englobante d'une zone, en coordonnees MONDE. Memorisee sur la zone
  elle-meme : une zone n'est jamais modifiee en place, elle est remplacee, donc
  le memo ne peut pas devenir faux.
]]
local function boiteMonde(zone)
  if zone._boite then return zone._boite end
  local boite
  if zone.forme == "cercle" and zone.centre and zone.rayon then
    boite = { xMin = zone.centre.x - zone.rayon, xMax = zone.centre.x + zone.rayon,
              zMin = zone.centre.z - zone.rayon, zMax = zone.centre.z + zone.rayon }
  elseif zone.forme == "rectangle" and type(zone.points) == "table" and #zone.points >= 3 then
    local xMin, xMax = math.huge, -math.huge
    local zMin, zMax = math.huge, -math.huge
    for _, p in ipairs(zone.points) do
      if p.x < xMin then xMin = p.x end
      if p.x > xMax then xMax = p.x end
      if p.z < zMin then zMin = p.z end
      if p.z > zMax then zMax = p.z end
    end
    boite = { xMin = xMin, xMax = xMax, zMin = zMin, zMax = zMax }
  else
    return nil
  end
  zone._boite = boite
  return boite
end
carte.boiteMonde = boiteMonde

--[[
  RASTERISATION DU FOND DE CARTE

  Version naive : pour chaque case de l'ecran, demander sa classe au noyau, qui
  teste la case contre CHAQUE zone. Cout : cases x zones x test de polygone.
  Sur un moniteur 3x3 a l'echelle 0.5, cela fait 58 x 36 x 8 tests par
  reconstruction - et en mode de suivi MENACE la vue bouge a chaque
  rafraichissement, donc le cache ne sert a rien pendant un engagement, c'est-a-
  dire exactement quand il faudrait que l'affichage reste fluide.

  Version retenue : on inverse les boucles. Chaque zone est projetee en une
  BOITE ENGLOBANTE a l'ecran, et on ne teste que les cases qui tombent dedans.
  Une zone hors champ coute deux comparaisons ; une petite zone ne coute que sa
  propre surface. Les zones sont peintes par SEVERITE CROISSANTE, si bien que la
  plus stricte recouvre les autres : le resultat est identique, case par case, a
  celui de noyau.zonePourPoint - ce qui est indispensable, la carte ne devant
  jamais montrer autre chose que ce que la doctrine applique.
]]
function carte.rasteriserZones(vue, largeur, hauteur, zones, noyau, altitudeSonde)
  local grille = {}
  for ligne = 1, hauteur do grille[ligne] = {} end
  if type(zones) ~= "table" or #zones == 0 then return grille end

  -- Severite croissante : la plus stricte peint en dernier et l'emporte.
  local ordonnees = {}
  for _, zone in ipairs(zones) do
    if zone.actif ~= false and noyau.SEVERITE[zone.classe] then
      ordonnees[#ordonnees + 1] = zone
    end
  end
  table.sort(ordonnees, function(a, b)
    local sa, sb = noyau.SEVERITE[a.classe], noyau.SEVERITE[b.classe]
    if sa ~= sb then return sa < sb end
    return tostring(a.nom) < tostring(b.nom)   -- ordre stable
  end)

  for _, zone in ipairs(ordonnees) do
    local boite = boiteMonde(zone)
    if boite then
      -- La projection est monotone sur les deux axes : projeter les deux coins
      -- opposes suffit a encadrer la zone a l'ecran.
      local colMin, ligneMin = carte.versEcran(vue, boite.xMin, boite.zMin, largeur, hauteur)
      local colMax, ligneMax = carte.versEcran(vue, boite.xMax, boite.zMax, largeur, hauteur)

      -- Une case de marge : la projection arrondit vers le bas.
      colMin,   ligneMin   = math.max(1, colMin - 1),   math.max(1, ligneMin - 1)
      colMax,   ligneMax   = math.min(largeur, colMax + 1), math.min(hauteur, ligneMax + 1)

      if colMin <= colMax and ligneMin <= ligneMax then
        local classe = zone.classe
        for ligne = ligneMin, ligneMax do
          local rangee = grille[ligne]
          for col = colMin, colMax do
            local x, z = carte.versMonde(vue, col, ligne, largeur, hauteur)
            if noyau.pointDansZone(zone, x, altitudeSonde, z) then
              rangee[col] = classe
            end
          end
        end
      end
    end
  end

  return grille
end

-- Le cache n'est reconstruit que si la vue, les dimensions ou les zones ont
-- change. 'versionZones' est incremente par le systeme a chaque edition.
function carte.rasterCache(cache, vue, largeur, hauteur, zones, noyau, versionZones, altitudeSonde)
  if cache
     and cache.version == vue.version
     and cache.largeur == largeur and cache.hauteur == hauteur
     and cache.versionZones == versionZones then
    return cache, false
  end
  return {
    version = vue.version, largeur = largeur, hauteur = hauteur,
    versionZones = versionZones,
    grille = carte.rasteriserZones(vue, largeur, hauteur, zones, noyau, altitudeSonde),
  }, true
end

--------------------------------------------------------------------------------
-- 5. DESIGNATION PAR CLIC
--------------------------------------------------------------------------------

--[[
  Piste situee sous un clic. Tolerance d'une case autour du point clique :
  a 512 blocs par caractere, exiger la case exacte rendrait la selection
  impossible.
  Retourne la piste la PLUS DANGEREUSE parmi celles sous le curseur : quand
  deux contacts se superposent, c'est celui qu'on veut traiter.
]]
function carte.pisteSous(pistes, vue, col, ligne, largeur, hauteur, tolerance)
  tolerance = tolerance or 1
  local meilleure, meilleurPalier, meilleureDistance

  for _, piste in pairs(pistes) do
    if nombreValide(piste.x) and nombreValide(piste.z) then
      local c, l = carte.versEcran(vue, piste.x, piste.z, largeur, hauteur)
      local dc, dl = math.abs(c - col), math.abs(l - ligne)
      if dc <= tolerance and dl <= tolerance then
        local palier = (piste.verdict and piste.verdict.palier) or 0
        local distance = dc + dl
        if not meilleure
           or palier > meilleurPalier
           or (palier == meilleurPalier and distance < meilleureDistance) then
          meilleure, meilleurPalier, meilleureDistance = piste, palier, distance
        end
      end
    end
  end
  return meilleure
end

--------------------------------------------------------------------------------
-- 6. RECENTRAGE AUTOMATIQUE
--------------------------------------------------------------------------------

-- Contact le plus dangereux : palier le plus haut, puis le plus proche du
-- poste. C'est la cible sur laquelle la carte doit rester accrochee.
function carte.pisteLaPlusDangereuse(pistes, origine)
  local meilleure, meilleurPalier, meilleureDistance
  for _, piste in pairs(pistes) do
    local palier = (piste.verdict and piste.verdict.palier) or 0
    if palier >= 2 and nombreValide(piste.x) then
      local dx = piste.x - (origine and origine.x or 0)
      local dz = piste.z - (origine and origine.z or 0)
      local distance = math.sqrt(dx * dx + dz * dz)
      if not meilleure or palier > meilleurPalier
         or (palier == meilleurPalier and distance < meilleureDistance) then
        meilleure, meilleurPalier, meilleureDistance = piste, palier, distance
      end
    end
  end
  return meilleure
end

--[[
  Applique le mode de suivi. Retourne true si la carte a bouge.
  En mode MENACE, la carte ne bouge que si la cible suivie s'est reellement
  deplacee d'au moins une case : sans ce seuil, elle tremblerait en permanence.
]]
function carte.appliquerSuivi(vue, pistes, poste, largeur, hauteur)
  local cible
  if vue.suivi == "LIBRE" then
    return false
  elseif vue.suivi == "POSTE" then
    cible = poste
  elseif vue.suivi == "MENACE" then
    cible = carte.pisteLaPlusDangereuse(pistes, poste) or poste
  else
    cible = pistes[vue.suivi]
    if not cible then
      -- La piste suivie a disparu : on retombe sur la menace courante.
      vue.suivi = "MENACE"
      cible = carte.pisteLaPlusDangereuse(pistes, poste) or poste
    end
  end

  if not (cible and nombreValide(cible.x) and nombreValide(cible.z)) then return false end

  local e = carte.echelle(vue)
  if math.abs(cible.x - vue.centreX) < e
     and math.abs(cible.z - vue.centreZ) < e * carte.ASPECT then
    return false
  end

  vue.centreX, vue.centreZ = cible.x, cible.z
  vue.version = vue.version + 1
  return true
end

return carte
