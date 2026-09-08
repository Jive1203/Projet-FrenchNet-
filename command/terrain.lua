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
    cases          = {},
    nombreCases    = 0,
    echantillons   = 0,
  }
end

local function cle(modele, x, z)
  local cx = math.floor(x / modele.resolution)
  local cz = math.floor(z / modele.resolution)
  return cx .. ":" .. cz, cx, cz
end
terrain.cle = cle

--------------------------------------------------------------------------------
-- 2. INGESTION D'ECHANTILLONS
--------------------------------------------------------------------------------

-- Eviction : on sacrifie les cases les moins etayees, puis les plus anciennes.
local function evincer(modele)
  local pire, pireCle
  for k, c in pairs(modele.cases) do
    local note = c.poids * 1000 - (c.maj or 0)
    if not pire or note < pire then pire, pireCle = note, k end
  end
  if pireCle then
    modele.cases[pireCle] = nil
    modele.nombreCases = modele.nombreCases - 1
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
function terrain.echantillonner(modele, x, y, z, source, instant)
  if not (nombreValide(x) and nombreValide(y) and nombreValide(z)) then
    return nil, "coordonnees invalides"
  end
  local poids = terrain.POIDS_SOURCE[source] or 1
  local k = cle(modele, x, z)
  local c = modele.cases[k]

  if not c then
    if modele.nombreCases >= modele.cellulesMax then evincer(modele) end
    c = { y = y, poids = poids, n = 1, min = y, max = y, maj = instant or 0, source = source }
    modele.cases[k] = c
    modele.nombreCases = modele.nombreCases + 1
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
  return c, string.format("case %s : sol %.0f (%d releve(s), amplitude %.0f, source %s)",
    k, c.y, c.n, c.max - c.min, tostring(c.source))
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
function terrain.hauteurSol(modele, x, z)
  if not (nombreValide(x) and nombreValide(z)) then
    return modele.altitudeDefaut, 0, "coordonnees invalides"
  end

  local k, cx, cz = cle(modele, x, z)
  local directe = modele.cases[k]
  if directe then
    -- Un releve unique reste un indice ; trois releves concordants font une
    -- mesure. La confiance sature a 1 apres quelques observations.
    local confiance = math.min(1, 0.5 + 0.1 * math.min(directe.n, 5))
    local amplitude = directe.max - directe.min
    if amplitude > 8 then
      -- Falaise, mur ou batiment : on garde la mesure mais on baisse la garde.
      confiance = confiance * 0.6
    end
    return directe.y, confiance, string.format(
      "releve direct case %s (%d echantillon(s), amplitude %.0f)", k, directe.n, amplitude)
  end

  -- Aucun releve ici : moyenne ponderee des cases voisines par anneaux
  -- successifs, au plus jusqu'au rayon de recherche.
  for rayon = 1, math.floor(modele.rayonRecherche) do
    local somme, poidsTotal, trouvees = 0, 0, 0
    for dx = -rayon, rayon do
      for dz = -rayon, rayon do
        -- Seul l'anneau, pas l'interieur deja explore.
        if math.max(math.abs(dx), math.abs(dz)) == rayon then
          local voisine = modele.cases[(cx + dx) .. ":" .. (cz + dz)]
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
      return altitude, confiance, string.format(
        "interpole depuis %d case(s) a %d case(s) de distance", trouvees, rayon)
    end
  end

  return modele.altitudeDefaut, 0, "aucun releve de terrain a proximite, altitude de repli"
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

  local sol, confiance, motif = terrain.hauteurSol(modele, contact.x, contact.z)

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
  -- Une resolution differente rendrait toutes les cles fausses : on refuse
  -- plutot que d'inventer une correspondance.
  if nombreValide(donnees.resolution) and donnees.resolution ~= modele.resolution then
    return false, string.format("resolution incompatible (%s enregistree, %s configuree)",
      tostring(donnees.resolution), tostring(modele.resolution))
  end
  local n = 0
  for k, c in pairs(donnees.cases) do
    if type(c) == "table" and nombreValide(c.y) then
      modele.cases[k] = {
        y = c.y, poids = c.poids or 1, n = c.n or 1,
        min = c.min or c.y, max = c.max or c.y, maj = c.maj or 0, source = c.source or "import",
      }
      n = n + 1
    end
  end
  modele.nombreCases  = n
  modele.echantillons = donnees.echantillons or n
  return true, string.format("%d case(s) de terrain restauree(s)", n)
end

function terrain.statistiques(modele)
  local etayees, amplitudeMax = 0, 0
  for _, c in pairs(modele.cases) do
    if c.n >= 3 then etayees = etayees + 1 end
    amplitudeMax = math.max(amplitudeMax, c.max - c.min)
  end
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
