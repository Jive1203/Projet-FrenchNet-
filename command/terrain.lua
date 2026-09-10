--[[----------------------------------------------------------------------------
  FRENCHNET COMMAND - MODELE DE TERRAIN OBSERVE
  --------------------------------------------------------------------------
  Role : savoir, pour un point (X, Z) donne, a quelle altitude se trouve le sol,
         afin de trancher si un contact est AU SOL ou EN VOL.

  POURQUOI PAS LA SEED DU MONDE
  Reconstituer la generation de Minecraft 1.21.1 a partir de la seed est hors
  de portee d'un ordinateur CC: Tweaked, et pas qu'un peu :
    - il faut la pile complete des density functions, les splines de terrain,
      les parametres de climat et les surface rules du jeu ;
    - il faut reproduire exactement XoroshiroRandomSource, donc de l'arithmetique
      64 bits, alors que Lua sous Cobalt travaille en nombres flottants ;
    - une seule colonne de terrain demande des dizaines d'evaluations de bruit :
      un ordinateur du jeu mettrait des minutes par colonne ;
    - et le resultat ignorerait tout ce que les joueurs ont construit ou creuse,
      c'est-a-dire precisement ce qui compte sur un serveur de guerre.

  CE QUE FAIT CE MODULE A LA PLACE
  Le terrain est APPRIS PAR OBSERVATION. Tout ce dont on connait la position et
  dont on sait qu'il touche le sol est une sonde d'altitude :
    - chaque station radar (posee au sol, position declaree) ;
    - chaque plateforme de defense et chaque lanceur ;
    - chaque balise GPS FrenchNet ;
    - chaque JOUEUR qui marche : un contact a vitesse verticale nulle plusieurs
      balayages d'affilee est, de fait, un releve d'altitude du sol ;
    - un import de heightmap, si le serveur peut en exporter un (c'est la seule
      facon d'injecter de vraies donnees de generation dans le systeme).

  Le modele s'ameliore donc avec le temps et connait le relief REEL, remblais
  et forteresses compris. La couverture et la confiance sont affichables :
  le systeme sait ce qu'il ne sait pas, et le dit.

  Aucune API du jeu n'est utilisee ici : ce module est testable hors du jeu.
--------------------------------------------------------------------------------]]

local terrain = { VERSION = "1.0.0" }

local function nombreValide(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Fiabilite relative des sources d'echantillon. Une position declaree en
-- configuration vaut mieux qu'un joueur peut-etre pose sur un toit.
terrain.POIDS_SOURCE = {
  import     = 5,   -- heightmap exportee du serveur
  radar      = 4,   -- station radar, position declaree
  plateforme = 4,   -- lanceur ou plateforme de defense
  balise     = 4,   -- balise GPS FrenchNet
  manuel     = 4,   -- releve saisi par un controleur
  contact    = 1,   -- joueur ou vehicule observe immobile verticalement
}

--------------------------------------------------------------------------------
-- 1. CONSTRUCTION
--------------------------------------------------------------------------------

--[[
  resolution     : cote d'une case en blocs (8 a 32 ; 16 est un bon compromis)
  rayonRecherche : nombre de cases explorees autour d'un point sans releve
  cellulesMax    : plafond memoire ; au-dela, les cases les plus anciennes et
                   les moins etayees sont evincees
  altitudeDefaut : altitude rendue quand le modele ne sait rien
]]
function terrain.nouveau(config)
  config = config or {}
  return {
    resolution     = nombreValide(config.resolution) and math.max(1, math.floor(config.resolution)) or 16,
    rayonRecherche = nombreValide(config.rayonRecherche) and config.rayonRecherche or 3,
    cellulesMax    = nombreValide(config.cellulesMax) and config.cellulesMax or 4000,
    altitudeDefaut = nombreValide(config.altitudeDefaut) and config.altitudeDefaut or 64,
    -- Grille a DEUX NIVEAUX : cases[cx][cz]. La version a cle textuelle
    -- ("cx:cz") allouait une chaine a chaque lecture comme a chaque ecriture,
    -- et le terrain est interroge pour chaque contact a chaque balayage.
    cases          = {},
    nombreCases    = 0,
    echantillons   = 0,
  }
end

local function coordonnees(modele, x, z)
  local resolution = modele.resolution
  return math.floor(x / resolution), math.floor(z / resolution)
end
terrain.coordonnees = coordonnees

local function caseA(modele, cx, cz)
  local colonne = modele.cases[cx]
  return colonne and colonne[cz]
end

local function poserCase(modele, cx, cz, cellule)
  local colonne = modele.cases[cx]
  if not colonne then
    colonne = {}
    modele.cases[cx] = colonne
  end
  if colonne[cz] == nil then modele.nombreCases = modele.nombreCases + 1 end
  colonne[cz] = cellule
end

local function retirerCase(modele, cx, cz)
  local colonne = modele.cases[cx]
  if not (colonne and colonne[cz]) then return end
  colonne[cz] = nil
  modele.nombreCases = modele.nombreCases - 1
  if next(colonne) == nil then modele.cases[cx] = nil end
end

-- Parcours de toutes les cases, sans allouer de table intermediaire.
local function pourChaqueCase(modele, fn)
  for cx, colonne in pairs(modele.cases) do
    for cz, cellule in pairs(colonne) do
      fn(cx, cz, cellule)
    end
  end
end
terrain.pourChaqueCase = pourChaqueCase

--------------------------------------------------------------------------------
-- 2. INGESTION D'ECHANTILLONS
--------------------------------------------------------------------------------

--[[
  EVICTION AMORTIE.
  Chercher la pire case coute un parcours complet du modele. Le faire a chaque
  nouvelle case, une fois le plafond atteint, revenait a payer ce parcours des
  milliers de fois par minute des qu'une cible survolait un secteur inexplore.

  On evince donc un LOT d'un coup - quelques pour cent du plafond - ce qui
  amortit le parcours sur autant d'insertions suivantes, gratuites. Le critere
  ne change pas : les cases les moins etayees partent en premier, puis les plus
  anciennes.
]]
local function evincer(modele)
  local aRetirer = math.max(1, math.floor(modele.cellulesMax * 0.05))
  local candidats = {}
  pourChaqueCase(modele, function(cx, cz, cellule)
    candidats[#candidats + 1] = { cx = cx, cz = cz,
      note = cellule.poids * 1000 - (cellule.maj or 0) }
  end)
  table.sort(candidats, function(a, b) return a.note < b.note end)
  for i = 1, math.min(aRetirer, #candidats) do
    retirerCase(modele, candidats[i].cx, candidats[i].cz)
  end
end

--[[
  Enregistre un releve de sol. Retourne la case mise a jour et un motif
  journalisable.

  Les releves sont moyennes en ponderant par la fiabilite de la source. L'ecart
  min/max est conserve : une case dont l'amplitude depasse quelques blocs est
  une falaise, un mur ou un batiment - le systeme le signale plutot que de
  pretendre a une altitude unique.
]]
-- 'avecMotif' : meme raison que pour hauteurSol. Les releves arrivent en
-- continu, le motif ne sert qu'au journal de mise au point.
function terrain.echantillonner(modele, x, y, z, source, instant, avecMotif)
  if not (nombreValide(x) and nombreValide(y) and nombreValide(z)) then
    return nil, "coordonnees invalides"
  end
  local poids = terrain.POIDS_SOURCE[source] or 1
  local cx, cz = coordonnees(modele, x, z)
  local c = caseA(modele, cx, cz)

  if not c then
    if modele.nombreCases >= modele.cellulesMax then evincer(modele) end
    c = { y = y, poids = poids, n = 1, min = y, max = y, maj = instant or 0, source = source }
    poserCase(modele, cx, cz, c)
  else
    local total = c.poids + poids
    c.y     = (c.y * c.poids + y * poids) / total
    c.poids = total
    c.n     = c.n + 1
    c.min   = math.min(c.min, y)
    c.max   = math.max(c.max, y)
    c.maj   = instant or c.maj
    -- La source la plus fiable observee reste affichee.
    if (terrain.POIDS_SOURCE[source] or 0) > (terrain.POIDS_SOURCE[c.source] or 0) then
      c.source = source
    end
  end

  modele.echantillons = modele.echantillons + 1
  if not avecMotif then return c end
  return c, string.format("case %d:%d : sol %.0f (%d releve(s), amplitude %.0f, source %s)",
    cx, cz, c.y, c.n, c.max - c.min, tostring(c.source))
end

--------------------------------------------------------------------------------
-- 3. INTERROGATION
--------------------------------------------------------------------------------

--[[
  Altitude du sol en (X, Z).
  Retourne : altitude, confiance (0 a 1), motif journalisable.

  confiance = 0    -> le modele ne sait rien, altitude de repli
  confiance < 0.5  -> deduite de cases voisines, a prendre avec precaution
  confiance >= 0.5 -> releve direct, plusieurs echantillons concordants
]]
--[[
  'avecMotif' commande la construction du motif journalisable. Il est faux la
  plupart du temps : le terrain est interroge pour CHAQUE contact a CHAQUE
  balayage, alors que le motif ne sert qu'au journal, c'est-a-dire quand la
  classification change. Formater une chaine des dizaines de fois par seconde
  pour la jeter est le genre de gaspillage qui ne se voit pas et qui coute.
]]
function terrain.hauteurSol(modele, x, z, avecMotif)
  if not (nombreValide(x) and nombreValide(z)) then
    return modele.altitudeDefaut, 0, avecMotif and "coordonnees invalides" or nil
  end

  local cx, cz = coordonnees(modele, x, z)
  local directe = caseA(modele, cx, cz)
  if directe then
    -- Un releve unique reste un indice ; trois releves concordants font une
    -- mesure. La confiance sature a 1 apres quelques observations.
    local confiance = math.min(1, 0.5 + 0.1 * math.min(directe.n, 5))
    local amplitude = directe.max - directe.min
    if amplitude > 8 then
      -- Falaise, mur ou batiment : on garde la mesure mais on baisse la garde.
      confiance = confiance * 0.6
    end
    return directe.y, confiance, avecMotif and string.format(
      "releve direct case %d:%d (%d echantillon(s), amplitude %.0f)",
      cx, cz, directe.n, amplitude) or nil
  end

  -- Aucun releve ici : moyenne ponderee des cases voisines par anneaux
  -- successifs, au plus jusqu'au rayon de recherche.
  for rayon = 1, math.floor(modele.rayonRecherche) do
    local somme, poidsTotal, trouvees = 0, 0, 0
    for dx = -rayon, rayon do
      for dz = -rayon, rayon do
        -- Seul l'anneau, pas l'interieur deja explore.
        if math.max(math.abs(dx), math.abs(dz)) == rayon then
          local voisine = caseA(modele, cx + dx, cz + dz)
          if voisine then
            local p = voisine.poids / rayon
            somme = somme + voisine.y * p
            poidsTotal = poidsTotal + p
            trouvees = trouvees + 1
          end
        end
      end
    end
    if trouvees > 0 then
      local altitude = somme / poidsTotal
      -- Plus on s'eloigne, moins on sait. Jamais au-dessus de 0.45 : une
      -- interpolation ne vaut pas un releve.
      local confiance = math.min(0.45, 0.45 / rayon)
      return altitude, confiance, avecMotif and string.format(
        "interpole depuis %d case(s) a %d case(s) de distance", trouvees, rayon) or nil
    end
  end

  return modele.altitudeDefaut, 0,
    avecMotif and "aucun releve de terrain a proximite, altitude de repli" or nil
end

--------------------------------------------------------------------------------
-- 4. UN CONTACT EST-IL AU SOL ?
--------------------------------------------------------------------------------

--[[
  Retourne : auSol (booleen), hauteurRelative, confiance, motif.

  Quand le modele ne sait rien (confiance nulle), on retombe sur le sol de
  reference de la zone puis sur celui de la configuration : le systeme reste
  operationnel avant d'avoir appris quoi que ce soit, il est simplement moins
  fin - et le journal le dit explicitement.
]]
function terrain.evaluerContact(modele, contact, config, zone)
  config = config or {}
  local seuil = nombreValide(config.hauteurAerienne) and config.hauteurAerienne or 25

  local sol, confiance, motif = terrain.hauteurSol(modele, contact.x, contact.z, true)

  if confiance <= 0 then
    sol = (zone and nombreValide(zone.solY) and zone.solY)
       or (nombreValide(config.altitudeSolReference) and config.altitudeSolReference)
       or modele.altitudeDefaut
    motif = "terrain inconnu ici, sol de reference " .. string.format("%.0f", sol)
  end

  local hauteur = (nombreValide(contact.y) and contact.y or sol) - sol
  return hauteur < seuil, hauteur, confiance, string.format(
    "sol %.0f, hauteur %.0f, seuil %.0f, confiance %.2f [%s]",
    sol, hauteur, seuil, confiance, motif)
end

--[[
  Un contact est-il une sonde d'altitude exploitable ?
  Regle : il faut qu'il soit POSE. On l'exige immobile verticalement sur
  plusieurs balayages consecutifs, et pas en train de planer.

  Sans cette precaution le raisonnement serait circulaire : on se servirait
  d'un aeronef pour decider ou est le sol, puis du sol pour decider que
  l'aeronef vole.
]]
function terrain.contactEstUneSonde(piste, config)
  config = config or {}
  local echantillonsMini  = nombreValide(config.sondeEchantillons) and config.sondeEchantillons or 3
  local toleranceVerticale = nombreValide(config.sondeToleranceVerticale)
                             and config.sondeToleranceVerticale or 0.5

  local ech = piste.echantillons or {}
  if #ech < echantillonsMini then return false, "historique trop court" end

  local reference = ech[#ech].y
  for i = #ech - echantillonsMini + 1, #ech do
    if math.abs(ech[i].y - reference) > toleranceVerticale then
      return false, "altitude instable, contact probablement en vol"
    end
  end

  -- Un vehicule stationnaire en vol stationnaire passerait le test precedent.
  -- On exige donc en plus qu'il se deplace horizontalement OU qu'il soit un
  -- joueur : un joueur immobile est pose, un aeronef immobile ne l'est pas.
  if piste.nature ~= "JOUEUR" then
    local horizontale = piste.vitesseHorizontale or 0
    if horizontale < 0.5 then
      return false, "vehicule immobile : vol stationnaire indiscernable d'un stationnement"
    end
    local vitesseSolMax = nombreValide(config.sondeVitesseSolMax) and config.sondeVitesseSolMax or 12
    if horizontale > vitesseSolMax then
      return false, string.format("trop rapide pour un vehicule au sol (%.1f b/s)", horizontale)
    end
  end

  return true, string.format("%d releve(s) a altitude stable", echantillonsMini)
end

--------------------------------------------------------------------------------
-- 5. PERSISTANCE ET STATISTIQUES
--------------------------------------------------------------------------------

function terrain.exporter(modele)
  return {
    resolution = modele.resolution,
    cases      = modele.cases,
    echantillons = modele.echantillons,
  }
end

function terrain.importer(modele, donnees)
  if type(donnees) ~= "table" or type(donnees.cases) ~= "table" then
    return false, "donnees de terrain illisibles"
  end
  -- Une resolution differente rendrait toutes les coordonnees fausses : on
  -- refuse plutot que d'inventer une correspondance.
  if nombreValide(donnees.resolution) and donnees.resolution ~= modele.resolution then
    return false, string.format("resolution incompatible (%s enregistree, %s configuree)",
      tostring(donnees.resolution), tostring(modele.resolution))
  end

  local function restaurer(cx, cz, c)
    if type(c) == "table" and nombreValide(c.y) then
      poserCase(modele, cx, cz, {
        y = c.y, poids = c.poids or 1, n = c.n or 1,
        min = c.min or c.y, max = c.max or c.y,
        maj = c.maj or 0, source = c.source or "import",
      })
    end
  end

  modele.cases, modele.nombreCases = {}, 0
  for cle, contenu in pairs(donnees.cases) do
    if type(cle) == "number" and type(contenu) == "table" then
      -- Format a deux niveaux : cases[cx][cz]
      for cz, c in pairs(contenu) do restaurer(cle, cz, c) end
    elseif type(cle) == "string" then
      -- Format historique a cle textuelle "cx:cz" : relu sans broncher, pour
      -- qu'une mise a jour du programme ne jette pas le relief deja appris.
      local cx, cz = cle:match("^(-?%d+):(-?%d+)$")
      if cx then restaurer(tonumber(cx), tonumber(cz), contenu) end
    end
  end

  modele.echantillons = donnees.echantillons or modele.nombreCases
  return true, string.format("%d case(s) de terrain restauree(s)", modele.nombreCases)
end

function terrain.statistiques(modele)
  local etayees, amplitudeMax = 0, 0
  pourChaqueCase(modele, function(_, _, c)
    if c.n >= 3 then etayees = etayees + 1 end
    local amplitude = c.max - c.min
    if amplitude > amplitudeMax then amplitudeMax = amplitude end
  end)
  return {
    cases        = modele.nombreCases,
    etayees      = etayees,
    echantillons = modele.echantillons,
    resolution   = modele.resolution,
    -- Surface couverte, en blocs carres.
    surface      = modele.nombreCases * modele.resolution * modele.resolution,
    amplitudeMax = amplitudeMax,
  }
end

return terrain
