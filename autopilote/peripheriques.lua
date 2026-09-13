--[[----------------------------------------------------------------------------
  CLASSES DE PERIPHERIQUES ET QUARANTAINE - AUTOPILOTE FRENCHNET
  --------------------------------------------------------------------------
  L'autopilote ne touche JAMAIS a un peripherique qu'il ne sait pas nommer.

  La raison est simple et elle est de securite. La calibration cherche les
  commandes de vol en envoyant du courant dans des sorties pour voir ce qui
  bouge. Faire cela sur un bloc dont on ignore la nature, c'est accepter qu'il
  s'agisse d'une batterie de canons, d'un largueur d'ancre ou d'une soute. Le
  module refuse donc de deviner : tout peripherique non reconnu part en
  QUARANTAINE, la calibration s'arrete, et un operateur lui attribue une CLASSE
  a la main avec le programme 'classer'.

  A QUOI SERT UNE CLASSE
  ----------------------
  Ce n'est pas une etiquette decorative : chaque classe designe la case de la
  configuration que le peripherique a le droit de remplir. Classer une boussole
  en CAPTEUR_CAP, c'est renseigner config.cap ; classer un bloc en ARMEMENT,
  c'est l'exclure definitivement de toute commande. Une classe est une
  autorisation, pas un commentaire.

  Chargement :  local peripheriques = dofile("/autopilote/peripheriques.lua")
--------------------------------------------------------------------------------]]

local peripheriques = { VERSION = "1.0.0" }

peripheriques.CHEMIN_REGISTRE = "/autopilote/registre_peripheriques.lua"
peripheriques.VERSION_REGISTRE = 1

--------------------------------------------------------------------------------
-- 1. TAXONOMIE
--    'code'        cle stable, ecrite dans le registre
--    'libelle'     nom court affiche a l'operateur
--    'description' ce qu'il doit comprendre AVANT de choisir
--    'role'        ce que l'autopilote en fait concretement
--    'cible'       case de la configuration que la classe autorise a remplir
--    'ecrivable'   l'autopilote a-t-il le droit d'ecrire sur ce peripherique
--    'champs'      questions complementaires, propres a la classe
--------------------------------------------------------------------------------

local function champ(nom, question, genre, options)
  local c = { nom = nom, question = question, genre = genre or "texte" }
  if options then for cle, valeur in pairs(options) do c[cle] = valeur end end
  return c
end

peripheriques.CLASSES = {
  {
    code        = "COMMUNICATION",
    libelle     = "Communication",
    description = "Modem. Porte rednet : liaison avec les ordinateurs de sortie "
               .. "deportes (satellites) et avec la tour de controle.",
    role        = "Ouverture de rednet. Jamais actionne comme une commande de vol.",
    cible       = "sorties.distant.coteModem",
    ecrivable   = false,
    champs      = {},
  },
  {
    code        = "SORTIE_REDSTONE",
    libelle     = "Sortie redstone",
    description = "Bloc capable d'emettre du courant sur ses faces (integrateur "
               .. "redstone, relais). Il prolonge les six faces de l'ordinateur.",
    role        = "Ses faces deviennent des candidates pour la calibration.",
    cible       = "sorties.axes",
    ecrivable   = true,
    champs      = {
      champ("cotes", "Faces utilisables, separees par des virgules "
        .. "(top,bottom,left,right,front,back ; vide = toutes)", "liste",
        { facultatif = true }),
      champ("methode", "Methode d'ecriture (setOutput | setAnalogOutput)",
        "texte", { defaut = "setAnalogOutput" }),
    },
  },
  {
    code        = "CAPTEUR_CAP",
    libelle     = "Capteur de cap",
    description = "Bloc qui renvoie l'orientation du vehicule (boussole, lecteur "
               .. "de navire, gyroscope). C'est le peripherique le plus precieux "
               .. "pour un autopilote : le GPS donne un point, jamais un cap.",
    role        = "Renseigne config.cap et permet d'identifier les commandes de "
               .. "lacet du premier coup pendant la calibration.",
    cible       = "cap",
    ecrivable   = false,
    champs      = {
      champ("methode", "Methode renvoyant le cap", "texte", { defaut = "getYaw" }),
      champ("convention", "Convention d'angle (minecraft = 0 au sud | "
        .. "boussole = 0 au nord)", "texte", { defaut = "minecraft" }),
      champ("facteur", "Facteur multiplicatif de la valeur lue", "nombre",
        { defaut = 1 }),
      champ("decalage", "Decalage a ajouter, en degres", "nombre", { defaut = 0 }),
    },
  },
  {
    code        = "CAPTEUR_SOL",
    libelle     = "Capteur de hauteur sol",
    description = "Telemetre, scanner ou detecteur qui mesure la distance au sol. "
               .. "Le GPS ne donne que l'altitude absolue : sans ce capteur, "
               .. "l'enveloppe de securite au ras du relief est aveugle.",
    role        = "Renseigne config.sol : protection sol et bridage de vitesse.",
    cible       = "sol",
    ecrivable   = false,
    champs      = {
      champ("methode", "Methode renvoyant la distance au sol", "texte",
        { defaut = "getDistance" }),
      champ("facteur", "Facteur de conversion en blocs", "nombre", { defaut = 1 }),
      champ("decalage", "Decalage a ajouter, en blocs", "nombre", { defaut = 0 }),
    },
  },
  {
    code        = "JAUGE_CARBURANT",
    libelle     = "Jauge de carburant",
    description = "Cuve, reservoir ou detecteur d'energie dont on lit le niveau.",
    role        = "Renseigne config.carburant : declenche le retour au "
               .. "ravitaillement sous le seuil bas.",
    cible       = "carburant",
    ecrivable   = false,
    champs      = {
      champ("methode", "Methode de lecture du niveau", "texte", { defaut = "tanks" }),
      champ("fluide", "Nom du fluide a surveiller (vide = le premier venu)",
        "texte", { facultatif = true }),
      champ("max", "Capacite totale si elle n'est pas remontee", "nombre",
        { facultatif = true }),
    },
  },
  {
    code        = "COMMANDE_VOL",
    libelle     = "Commande de vol par methode",
    description = "Controleur de navire ou moteur pilotable par appel de methode, "
               .. "sans passer par la redstone. Plus precis quand il existe.",
    role        = "Cable un axe en mode 'peripherique' : l'axe n'est alors pas "
               .. "recherche par la calibration, il est deja connu.",
    cible       = "sorties.axes",
    ecrivable   = true,
    champs      = {
      champ("axe", "Axe commande (avance | vertical | lacet | lateral)", "texte"),
      champ("methode", "Methode a appeler", "texte"),
      champ("facteur", "Facteur applique a la commande (-1 a 1)", "nombre",
        { defaut = 1 }),
    },
  },
  {
    code        = "AFFICHAGE",
    libelle     = "Affichage",
    description = "Moniteur de passerelle, haut-parleur.",
    role        = "Recopie de l'etat de vol. Jamais actionne comme une commande.",
    cible       = nil,
    ecrivable   = false,
    champs      = {},
  },
  {
    code        = "STOCKAGE",
    libelle     = "Stockage",
    description = "Coffre, baril, soute, lecteur de disquette.",
    role        = "Inventaire pour la telemetrie. Jamais actionne.",
    cible       = nil,
    ecrivable   = false,
    champs      = {},
  },
  {
    code        = "ARMEMENT",
    libelle     = "Armement",
    description = "ATTENTION : tout ce qui tire, largue, explose ou ancre. Un "
               .. "canon declenche pendant une calibration n'est pas un bogue "
               .. "mineur, c'est un incident.",
    role        = "EXCLU de la calibration et du vol. L'autopilote ne l'actionne "
               .. "sous aucun pretexte, et ses faces ne sont jamais essayees.",
    cible       = nil,
    ecrivable   = false,
    champs      = {
      champ("cotes", "Faces a ne JAMAIS actionner, separees par des virgules "
        .. "(vide = toutes)", "liste", { facultatif = true }),
      champ("confirmation", "Confirmez-vous que ce bloc ne doit JAMAIS etre "
        .. "actionne par l'autopilote ?", "booleen", { exige = true }),
    },
  },
  {
    code        = "IGNORE",
    libelle     = "Ignore",
    description = "Bloc sans role de vol : decoration, module d'un autre systeme, "
               .. "peripherique en panne.",
    role        = "Retire de l'inventaire. Plus jamais signale.",
    cible       = nil,
    ecrivable   = false,
    champs      = {},
  },
}

peripheriques.PAR_CODE = {}
for _, classe in ipairs(peripheriques.CLASSES) do
  peripheriques.PAR_CODE[classe.code] = classe
end

function peripheriques.classe(code) return peripheriques.PAR_CODE[code] end

--------------------------------------------------------------------------------
-- 2. RECONNAISSANCE AUTOMATIQUE
--------------------------------------------------------------------------------

-- Types exacts renvoyes par peripheral.getType(), tous mods confondus.
local TYPES_CONNUS = {
  modem               = "COMMUNICATION",
  monitor             = "AFFICHAGE",
  speaker             = "AFFICHAGE",
  drive               = "STOCKAGE",
  printer             = "STOCKAGE",
  inventory           = "STOCKAGE",
  chest               = "STOCKAGE",
  barrel              = "STOCKAGE",
  shulker_box         = "STOCKAGE",
  computer            = "COMMUNICATION",
  turtle              = "IGNORE",
  workbench           = "IGNORE",
  redstoneIntegrator  = "SORTIE_REDSTONE",
  redstone_integrator = "SORTIE_REDSTONE",
  redstone_relay      = "SORTIE_REDSTONE",
  environmentDetector = "CAPTEUR_SOL",
  geoScanner          = "CAPTEUR_SOL",
  blockReader         = "CAPTEUR_SOL",
  energyDetector      = "JAUGE_CARBURANT",
  energy_storage      = "JAUGE_CARBURANT",
  fluid_storage       = "JAUGE_CARBURANT",
}

-- Signatures de methodes : le type est inconnu, mais les methodes exposees ne
-- laissent aucun doute. Toutes les methodes d'une entree sont exigees.
local SIGNATURES = {
  { classe = "SORTIE_REDSTONE",  methodes = { "setAnalogOutput" } },
  { classe = "SORTIE_REDSTONE",  methodes = { "setOutput", "getInput" } },
  { classe = "AFFICHAGE",        methodes = { "write", "setCursorPos", "getSize" } },
  { classe = "STOCKAGE",         methodes = { "list", "getItemDetail" } },
  { classe = "JAUGE_CARBURANT",  methodes = { "getEnergy", "getEnergyCapacity" } },
  { classe = "JAUGE_CARBURANT",  methodes = { "tanks" } },
}

--- Methodes exposees par un peripherique, sous forme d'ensemble et de liste.
function peripheriques.methodesDe(nom)
  if not peripheral then return {}, {} end
  local ok, liste = pcall(peripheral.getMethods, nom)
  if ok and type(liste) == "table" then
    local ensemble = {}
    for _, methode in ipairs(liste) do ensemble[methode] = true end
    return ensemble, liste
  end
  -- Repli : certaines versions n'exposent pas getMethods, on lit la table.
  local okWrap, materiel = pcall(peripheral.wrap, nom)
  if okWrap and type(materiel) == "table" then
    local ensemble, noms = {}, {}
    for cle, valeur in pairs(materiel) do
      if type(valeur) == "function" then
        ensemble[cle] = true
        noms[#noms + 1] = cle
      end
    end
    table.sort(noms)
    return ensemble, noms
  end
  return {}, {}
end

--- Reconnait un peripherique sans intervention humaine.
-- @return code de classe, motif  |  nil, motif du refus
function peripheriques.reconnaitre(nom)
  if not peripheral then return nil, "API peripheral absente" end
  local okType, typePeripherique = pcall(peripheral.getType, nom)
  typePeripherique = okType and typePeripherique or nil

  if typePeripherique then
    if TYPES_CONNUS[typePeripherique] then
      return TYPES_CONNUS[typePeripherique], "type connu '" .. typePeripherique .. "'"
    end
    -- Beaucoup de mods prefixent le type ("minecraft:chest", "create:xxx").
    local court = typePeripherique:match("[^:]+$")
    if court and TYPES_CONNUS[court] then
      return TYPES_CONNUS[court], "type connu '" .. court .. "'"
    end
  end

  local ensemble = peripheriques.methodesDe(nom)
  for _, signature in ipairs(SIGNATURES) do
    local complet = true
    for _, methode in ipairs(signature.methodes) do
      if not ensemble[methode] then complet = false break end
    end
    if complet then
      return signature.classe,
        "signature de methodes (" .. table.concat(signature.methodes, ", ") .. ")"
    end
  end

  return nil, "type '" .. tostring(typePeripherique)
    .. "' inconnu et aucune signature de methodes reconnue"
end

--------------------------------------------------------------------------------
-- 3. REGISTRE PERSISTANT
--    Fichier Lua serialise : lisible et corrigible a la main en cas d'urgence.
--------------------------------------------------------------------------------

function peripheriques.registreVide()
  return { version = peripheriques.VERSION_REGISTRE, fiches = {} }
end

local function cleValide(cle)
  return type(cle) == "string" and cle:match("^[%a_][%w_]*$") ~= nil
end

local function serialiser(valeur, indentation)
  indentation = indentation or ""
  local genre = type(valeur)
  if genre == "string" then return string.format("%q", valeur) end
  if genre == "number" or genre == "boolean" then return tostring(valeur) end
  if genre ~= "table" then return "nil" end

  local cles = {}
  for cle in pairs(valeur) do cles[#cles + 1] = cle end
  table.sort(cles, function(a, b) return tostring(a) < tostring(b) end)

  local morceaux = { "{\n" }
  local suivante = indentation .. "  "
  for _, cle in ipairs(cles) do
    local rendu = cleValide(cle) and (cle .. " = ")
      or ("[" .. serialiser(cle) .. "] = ")
    morceaux[#morceaux + 1] = suivante .. rendu
      .. serialiser(valeur[cle], suivante) .. ",\n"
  end
  morceaux[#morceaux + 1] = indentation .. "}"
  return table.concat(morceaux)
end
peripheriques.serialiser = serialiser

function peripheriques.charger(chemin)
  chemin = chemin or peripheriques.CHEMIN_REGISTRE
  if not fs.exists(chemin) then return peripheriques.registreVide() end
  local fichier = fs.open(chemin, "r")
  if not fichier then
    return peripheriques.registreVide(), "lecture impossible : " .. chemin
  end
  local source = fichier.readAll()
  fichier.close()

  local morceau, err = load(source, "@" .. chemin, "t", {})
  if not morceau then
    return peripheriques.registreVide(),
      "registre illisible (syntaxe Lua) : " .. tostring(err)
  end
  local ok, contenu = pcall(morceau)
  if not ok or type(contenu) ~= "table" or type(contenu.fiches) ~= "table" then
    return peripheriques.registreVide(),
      "registre malforme : il doit finir par 'return { version = 1, fiches = { ... } }'"
  end
  return contenu
end

function peripheriques.enregistrer(chemin, registre)
  chemin = chemin or peripheriques.CHEMIN_REGISTRE
  local dossier = fs.getDir(chemin)
  if dossier and dossier ~= "" and not fs.exists(dossier) then fs.makeDir(dossier) end
  local fichier = fs.open(chemin, "w")
  if not fichier then error("ecriture impossible : " .. chemin, 0) end
  fichier.writeLine("-- REGISTRE DES PERIPHERIQUES - AUTOPILOTE FRENCHNET")
  fichier.writeLine("-- Genere et maintenu par le programme 'classer'.")
  fichier.writeLine("-- Corrigible a la main, mais respectez la structure.")
  fichier.writeLine("return " .. serialiser(registre))
  fichier.close()
  return chemin
end

--------------------------------------------------------------------------------
-- 4. VALIDATION D'UNE FICHE
--------------------------------------------------------------------------------

--- @return true | false, liste d'anomalies
function peripheriques.validerFiche(fiche)
  local anomalies = {}
  if type(fiche) ~= "table" then return false, { "la fiche doit etre une table" } end
  if type(fiche.nom) ~= "string" or fiche.nom == "" then
    anomalies[#anomalies + 1] = "'nom' du peripherique manquant"
  end

  local classe = peripheriques.PAR_CODE[fiche.classe]
  if not classe then
    anomalies[#anomalies + 1] = "classe inconnue : " .. tostring(fiche.classe)
    return false, anomalies
  end

  for _, definition in ipairs(classe.champs) do
    local valeur = (fiche.details or {})[definition.nom]
    local absent = (valeur == nil or valeur == "")

    if definition.exige then
      if valeur ~= true then
        anomalies[#anomalies + 1] = "'" .. definition.nom
          .. "' doit etre confirme explicitement pour la classe " .. classe.code
      end
    elseif absent then
      if not definition.facultatif and definition.defaut == nil then
        anomalies[#anomalies + 1] = "'" .. definition.nom
          .. "' manquant pour la classe " .. classe.code
      end
    elseif definition.genre == "nombre" and type(valeur) ~= "number" then
      anomalies[#anomalies + 1] = "'" .. definition.nom .. "' doit etre un nombre"
    elseif definition.genre == "booleen" and type(valeur) ~= "boolean" then
      anomalies[#anomalies + 1] = "'" .. definition.nom .. "' doit etre oui ou non"
    elseif definition.genre == "liste" and type(valeur) ~= "table" then
      anomalies[#anomalies + 1] = "'" .. definition.nom .. "' doit etre une liste"
    end
  end

  -- Une commande de vol doit designer un axe qui existe.
  if fiche.classe == "COMMANDE_VOL" then
    local axe = (fiche.details or {}).axe
    local connus = { avance = true, vertical = true, lacet = true, lateral = true }
    if axe and not connus[axe] then
      anomalies[#anomalies + 1] = "axe inconnu : " .. tostring(axe)
        .. " (attendus : avance, vertical, lacet, lateral)"
    end
  end

  return #anomalies == 0, anomalies
end

--------------------------------------------------------------------------------
-- 5. INVENTAIRE
--    Croise les peripheriques presents, la reconnaissance automatique et le
--    registre operateur. Ce qui reste sans classe part en quarantaine.
--------------------------------------------------------------------------------

--- @param registre table  registre charge par peripheriques.charger
-- @return table { fiches = {[nom]=fiche}, ordre = {...}, quarantaine = {...} }
function peripheriques.inventorier(registre)
  registre = registre or peripheriques.registreVide()
  local resultat = { fiches = {}, ordre = {}, quarantaine = {} }

  local noms = {}
  if peripheral then
    local ok, liste = pcall(peripheral.getNames)
    if ok and type(liste) == "table" then noms = liste end
  end
  table.sort(noms)

  for _, nom in ipairs(noms) do
    local okType, typePeripherique = pcall(peripheral.getType, nom)
    local _, methodes = peripheriques.methodesDe(nom)

    local fiche = {
      nom      = nom,
      type     = okType and typePeripherique or "inconnu",
      methodes = methodes,
    }

    local manuelle = registre.fiches[nom]
    if manuelle and peripheriques.PAR_CODE[manuelle.classe] then
      -- Une fiche operateur prime TOUJOURS sur la reconnaissance automatique :
      -- c'est l'humain qui a vu le bloc, pas le programme.
      fiche.classe  = manuelle.classe
      fiche.details = manuelle.details or {}
      fiche.origine = "operateur"
      fiche.note    = manuelle.note
    else
      local code, motif = peripheriques.reconnaitre(nom)
      fiche.motif = motif
      if code then
        fiche.classe  = code
        fiche.details = {}
        fiche.origine = "automatique"
      else
        fiche.origine = "quarantaine"
        resultat.quarantaine[#resultat.quarantaine + 1] = fiche
      end
    end

    resultat.fiches[nom] = fiche
    resultat.ordre[#resultat.ordre + 1] = nom
  end

  return resultat
end

--- Peripheriques d'une classe donnee, dans l'ordre de l'inventaire.
function peripheriques.parClasse(inventaire, code)
  local liste = {}
  for _, nom in ipairs(inventaire.ordre or {}) do
    local fiche = inventaire.fiches[nom]
    if fiche and fiche.classe == code then liste[#liste + 1] = fiche end
  end
  return liste
end

--------------------------------------------------------------------------------
-- 6. FACES INTERDITES
--    Traduction de la quarantaine et de l'armement en faces a ne jamais
--    actionner. C'est ce que la calibration consomme.
--------------------------------------------------------------------------------

local COTES = { "top", "bottom", "left", "right", "front", "back" }

--- @return table { [cote] = motif }  faces que la calibration doit eviter
function peripheriques.facesInterdites(inventaire)
  local interdites = {}

  for _, fiche in ipairs(peripheriques.parClasse(inventaire, "ARMEMENT")) do
    local cotes = (fiche.details or {}).cotes
    if type(cotes) ~= "table" or #cotes == 0 then cotes = COTES end
    for _, cote in ipairs(cotes) do
      interdites[cote] = "armement '" .. fiche.nom .. "'"
    end
  end

  -- Un peripherique en quarantaine accole a l'ordinateur occupe une face :
  -- celle-ci ne doit etre ni essayee, ni consideree comme libre.
  for _, fiche in ipairs(inventaire.quarantaine or {}) do
    for _, cote in ipairs(COTES) do
      if fiche.nom == cote then
        interdites[cote] = "peripherique non classe '" .. fiche.nom .. "'"
      end
    end
  end

  return interdites
end

--------------------------------------------------------------------------------
-- 7. REPORT DANS LA CONFIGURATION
--    Les classes qui designent une case de configuration la remplissent.
--------------------------------------------------------------------------------

--- @return liste des reglages effectivement appliques (pour le journal)
function peripheriques.appliquerA(config, inventaire)
  local appliques = {}

  local capteurCap = peripheriques.parClasse(inventaire, "CAPTEUR_CAP")[1]
  if capteurCap then
    local d = capteurCap.details or {}
    config.cap = config.cap or {}
    config.cap.source       = "peripherique"
    config.cap.peripherique = capteurCap.nom
    config.cap.methode      = d.methode or "getYaw"
    config.cap.convention   = d.convention or "minecraft"
    config.cap.facteur      = d.facteur or 1
    config.cap.decalage     = d.decalage or 0
    appliques[#appliques + 1] = string.format(
      "cap lu sur '%s'.%s (convention %s)", capteurCap.nom,
      config.cap.methode, config.cap.convention)
  end

  local capteurSol = peripheriques.parClasse(inventaire, "CAPTEUR_SOL")[1]
  if capteurSol then
    local d = capteurSol.details or {}
    config.sol = config.sol or {}
    config.sol.source = "peripherique"
    config.sol.peripherique = {
      nom      = capteurSol.nom,
      methode  = d.methode or "getDistance",
      facteur  = d.facteur or 1,
      decalage = d.decalage or 0,
    }
    appliques[#appliques + 1] = string.format(
      "hauteur sol lue sur '%s'.%s", capteurSol.nom, config.sol.peripherique.methode)
  end

  local jauge = peripheriques.parClasse(inventaire, "JAUGE_CARBURANT")[1]
  if jauge then
    local d = jauge.details or {}
    config.carburant = config.carburant or {}
    config.carburant.source = "peripherique"
    config.carburant.peripherique = {
      nom = jauge.nom, methode = d.methode or "tanks",
      fluide = d.fluide, max = d.max,
    }
    appliques[#appliques + 1] = string.format(
      "carburant lu sur '%s'.%s", jauge.nom, config.carburant.peripherique.methode)
  end

  -- Un axe commande par methode n'a pas a etre cherche par la calibration :
  -- il est deja connu, et on l'ecrit tel quel.
  for _, fiche in ipairs(peripheriques.parClasse(inventaire, "COMMANDE_VOL")) do
    local d = fiche.details or {}
    if d.axe then
      config.sorties = config.sorties or {}
      config.sorties.axes = config.sorties.axes or {}
      config.sorties.axes[d.axe] = {
        mode = "peripherique", nom = fiche.nom,
        methode = d.methode, facteur = d.facteur or 1,
      }
      appliques[#appliques + 1] = string.format(
        "axe %s commande par '%s'.%s", d.axe, fiche.nom, tostring(d.methode))
    end
  end

  return appliques
end

return peripheriques
