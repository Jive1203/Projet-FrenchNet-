--[[----------------------------------------------------------------------------
  FRENCHNET COMMAND - INTERFACE DE CONTROLE
  --------------------------------------------------------------------------
  Interface facon systeme d'exploitation, dans la meme famille visuelle que le
  reste de FrenchNet : barre de titre, corps, barre d'onglets cliquables.

  DEUX NIVEAUX D'ACCES, VOLONTAIREMENT SEPARES
    - Ecran principal : la bascule GUERRE / PAIX est un bouton, accessible en
      UN clic. C'est l'action la plus frequente et la plus urgente ; la mettre
      derriere un menu couterait des vies.
    - Menu protege : la configuration des zones, la rotation des codes et les
      reglages sensibles demandent un code d'acces. Ce ne sont pas des actions
      d'urgence, et une fausse manoeuvre y est bien plus couteuse qu'une
      seconde perdue a taper quatre chiffres.

  Fonctionne au clavier ET a la souris, sur le terminal comme sur un moniteur
  externe (evenements mouse_click et monitor_touch).
--------------------------------------------------------------------------------]]

local interface = {}

--------------------------------------------------------------------------------
-- 1. PALETTE
--------------------------------------------------------------------------------

local PALETTE = {
  fond          = colors.black,
  fondPanneau   = colors.gray,
  titre         = colors.blue,
  titreTexte    = colors.white,
  texte         = colors.white,
  attenue       = colors.lightGray,
  paix          = colors.lime,
  guerre        = colors.red,
  alerte        = colors.magenta,
  bouton        = colors.gray,
  boutonTexte   = colors.white,
  ok            = colors.lime,
  avertissement = colors.yellow,
  danger        = colors.red,
  separateur    = colors.gray,
}

-- Couleur associee a chaque classe de zone, du plus permissif au plus strict.
local COULEUR_CLASSE = {
  CHARLIE = colors.lime,
  BRAVO   = colors.yellow,
  ALPHA   = colors.orange,
  ROMEO   = colors.red,
}

-- Fonds de carte par classe de zone. Volontairement sombres : ce sont les
-- symboles de contact qui doivent ressortir, pas le decor.
local FOND_CLASSE = {
  CHARLIE = colors.green,
  BRAVO   = colors.brown,
  ALPHA   = colors.purple,
  ROMEO   = colors.red,
}

--[[
  CODE COULEURS DES CONTACTS - identique sur la carte et dans les listes.
    VERT    code allie : libre passage partout
    BLEU    code general
    ORANGE  inconnu, hors zone ou non engage
    ROUGE   confirme ennemi, ou engagement en cours
  Le rouge est rare par construction : il ne s'allume que sur une destruction
  decidee ou un engagement ouvert. Un rouge permanent ne voudrait plus rien
  dire, et c'est exactement ce qu'un operateur doit pouvoir croire au premier
  coup d'oeil.
]]
local COULEUR_ETAT = {
  allie   = colors.lime,
  general = colors.lightBlue,
  inconnu = colors.orange,
  engage  = colors.red,
}
local LIBELLE_ETAT = {
  allie = "allie", general = "code general", inconnu = "inconnu", engage = "ENGAGE",
}

-- Correspondance couleur -> caractere blit, pour dessiner la carte ligne par
-- ligne au lieu de caractere par caractere. Sur un terminal CC, la difference
-- entre 11 appels et 561 par rafraichissement est tres perceptible.
local ORDRE_COULEURS = {
  colors.white, colors.orange, colors.magenta, colors.lightBlue,
  colors.yellow, colors.lime, colors.pink, colors.gray,
  colors.lightGray, colors.cyan, colors.purple, colors.blue,
  colors.brown, colors.green, colors.red, colors.black,
}
local HEX = "0123456789abcdef"
local BLIT = {}
for i, couleur in ipairs(ORDRE_COULEURS) do BLIT[couleur] = HEX:sub(i, i) end

-- Couleur associee a chaque palier d'escalade.
local COULEUR_PALIER = {
  [0] = colors.lightGray,
  [1] = colors.cyan,
  [2] = colors.yellow,
  [3] = colors.red,
}

--------------------------------------------------------------------------------
-- 2. PRIMITIVES D'AFFICHAGE
--------------------------------------------------------------------------------

local ecran = {}

function ecran.couleurs(fg, bg)
  if not ecran.couleur then return end
  if fg then term.setTextColour(fg) end
  if bg then term.setBackgroundColour(bg) end
end

function ecran.effacer(bg)
  ecran.couleurs(PALETTE.texte, bg or PALETTE.fond)
  term.clear()
  term.setCursorPos(1, 1)
end

function ecran.texte(x, y, texte, fg, bg)
  ecran.couleurs(fg, bg)
  term.setCursorPos(x, y)
  term.write(tostring(texte))
end

function ecran.bande(y, texte, fg, bg)
  ecran.couleurs(fg, bg)
  term.setCursorPos(1, y)
  term.write(string.rep(" ", ecran.largeur))
  term.setCursorPos(1, y)
  term.write(tostring(texte))
end

function ecran.centre(y, texte, fg, bg)
  local x = math.max(1, math.floor((ecran.largeur - #texte) / 2) + 1)
  ecran.texte(x, y, texte, fg, bg)
end

-- Tronque proprement : une colonne qui deborde casse toute la mise en page.
local function couper(texte, n)
  texte = tostring(texte)
  if #texte <= n then return texte .. string.rep(" ", n - #texte) end
  return texte:sub(1, n)
end

--------------------------------------------------------------------------------
-- 3. BOUTONS
--------------------------------------------------------------------------------

local boutons = {}

local function reinitialiserBoutons() boutons = {} end

local function bouton(x, y, libelle, action, fg, bg, largeur)
  largeur = largeur or (#libelle + 2)
  local texte = " " .. libelle .. string.rep(" ", math.max(0, largeur - #libelle - 1))
  ecran.couleurs(fg or PALETTE.boutonTexte, bg or PALETTE.bouton)
  term.setCursorPos(x, y)
  term.write(texte:sub(1, largeur))
  boutons[#boutons + 1] = { x1 = x, y1 = y, x2 = x + largeur - 1, y2 = y, action = action }
  return x + largeur
end

local function boutonSous(x, y)
  for _, b in ipairs(boutons) do
    if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then return b end
  end
  return nil
end

--------------------------------------------------------------------------------
-- 4. SAISIE
--    La saisie se fait toujours plein ecran, une question a la fois : sur un
--    terminal de 51 colonnes, un formulaire multi-champs est illisible et
--    conduit a des erreurs de saisie - exactement ce que le menu protege
--    cherche a eviter.
--------------------------------------------------------------------------------

local function saisir(question, indication, masque)
  ecran.effacer(PALETTE.fond)
  ecran.bande(1, " FRENCHNET COMMAND - SAISIE", PALETTE.titreTexte, PALETTE.titre)
  ecran.texte(2, 3, question, PALETTE.texte, PALETTE.fond)
  if indication then ecran.texte(2, 4, indication, PALETTE.attenue, PALETTE.fond) end
  ecran.texte(2, 6, "> ", PALETTE.ok, PALETTE.fond)
  ecran.couleurs(PALETTE.texte, PALETTE.fond)
  term.setCursorPos(4, 6)
  local ok, saisie = pcall(read, masque and "*" or nil)
  if not ok then return nil end
  return saisie
end

local function saisirNombre(question, indication)
  local brut = saisir(question, indication)
  if brut == nil or brut == "" then return nil end
  return tonumber(brut)
end

-- Accepte "x z", "x,z", "x;z".
local function saisirPoint(question, indication)
  local brut = saisir(question, indication)
  if not brut or brut == "" then return nil end
  local a, b = brut:match("^%s*(-?%d+%.?%d*)%s*[,; ]%s*(-?%d+%.?%d*)%s*$")
  if not a then return nil end
  return { x = tonumber(a), z = tonumber(b) }
end

local function message(titre, lignes, couleur)
  ecran.effacer(PALETTE.fond)
  ecran.bande(1, " " .. titre, PALETTE.titreTexte, couleur or PALETTE.titre)
  local y = 3
  for _, ligne in ipairs(lignes) do
    ecran.texte(2, y, couper(ligne, ecran.largeur - 2), PALETTE.texte, PALETTE.fond)
    y = y + 1
  end
  ecran.texte(2, ecran.hauteur - 1, "Appuyez sur une touche...", PALETTE.attenue, PALETTE.fond)
  os.pullEvent("key")
end

local function confirmer(question)
  ecran.effacer(PALETTE.fond)
  ecran.bande(1, " CONFIRMATION", PALETTE.titreTexte, PALETTE.avertissement)
  ecran.texte(2, 3, couper(question, ecran.largeur - 2), PALETTE.texte, PALETTE.fond)
  ecran.texte(2, 5, "O = oui    toute autre touche = annuler", PALETTE.attenue, PALETTE.fond)
  local _, touche = os.pullEvent("char")
  return touche == "o" or touche == "O"
end

--------------------------------------------------------------------------------
-- 5. ECRANS
--------------------------------------------------------------------------------

local ctx           -- contexte fourni par command.lua
local ecranCourant  = "PRINCIPAL"
local defilement    = 0
local menuDeverrouille = false

-- Etat de la carte tactique.
local vue                -- objet de carte.lua
local rasterCache        -- grille de classes de zone, recalculee a la demande
local pisteSelectionnee  -- id de la piste sur laquelle le panneau d'ordre porte
local casesCarte = {}    -- zones cliquables du panneau d'ordre
local ordre = { scramble = false, attaque = false, allie = false }
local zoneCarte = { x = 1, y = 3, largeur = 0, hauteur = 0 }

---------------------------------------------------------------- barre de titre
local function dessinerEntete()
  local etat = ctx.etat
  local guerre = (etat.mode == ctx.noyau.MODES.GUERRE)
  ecran.bande(1, " FRENCHNET COMMAND  " .. ctx.cfg.identifiant,
    PALETTE.titreTexte, guerre and PALETTE.guerre or PALETTE.titre)

  local horloge = textutils.formatTime(os.time(), true)
  ecran.texte(math.max(1, ecran.largeur - #horloge), 1, horloge,
    PALETTE.titreTexte, guerre and PALETTE.guerre or PALETTE.titre)

  -- Bandeau d'alerte : ce qui doit sauter aux yeux avant tout le reste.
  if etat.alerteMax then
    ecran.bande(2, " *** ALERTE MAXIMALE - REGIME ROMEO / GUERRE PARTOUT ***",
      colors.white, PALETTE.alerte)
  elseif #etat.alertes > 0 then
    ecran.bande(2, string.format(" ! %d alerte(s) controleur non acquittee(s)", #etat.alertes),
      colors.black, PALETTE.avertissement)
  else
    ecran.bande(2, "", PALETTE.texte, PALETTE.fond)
  end
end

---------------------------------------------------------------- barre d'onglets
local function dessinerOnglets()
  local y = ecran.hauteur
  ecran.bande(y, "", PALETTE.boutonTexte, PALETTE.fondPanneau)
  local x = 1
  local onglets = {
    { "Accueil",  "PRINCIPAL" },
    { "Carte",    "CARTE" },
    { "Contacts", "CONTACTS" },
    { "Defense",  "PLATEFORMES" },
    { "Journal",  "JOURNAL" },
    { "Menu",     "MENU" },
  }
  for _, o in ipairs(onglets) do
    local actif = (ecranCourant == o[2])
      or (o[2] == "MENU" and (ecranCourant == "ZONES" or ecranCourant == "CODES"))
    x = bouton(x, y, o[1], function()
      ecranCourant = o[2]
      defilement = 0
    end, actif and colors.black or PALETTE.boutonTexte,
       actif and PALETTE.ok or PALETTE.fondPanneau)
  end
end

------------------------------------------------------------------ ecran accueil
local function dessinerPrincipal()
  local etat, cfg = ctx.etat, ctx.cfg
  local guerre = (etat.mode == ctx.noyau.MODES.GUERRE)

  ecran.texte(2, 4, "THEATRE", PALETTE.attenue, PALETTE.fond)
  -- LA bascule : un seul clic, sur l'ecran principal, sans code d'acces.
  bouton(12, 4, guerre and "  GUERRE  " or "   PAIX   ", function()
    local nouveau = ctx.actions.basculerMode()
    message("BASCULE DE THEATRE", {
      "Le theatre est desormais en temps de " .. nouveau .. ".",
      "",
      "Toutes les pistes en cours sont reevaluees",
      "immediatement sous le nouveau regime.",
    }, guerre and PALETTE.paix or PALETTE.guerre)
  end, colors.black, guerre and PALETTE.guerre or PALETTE.paix, 12)

  ecran.texte(2, 6, "ALERTE", PALETTE.attenue, PALETTE.fond)
  bouton(12, 6, etat.alerteMax and " MAX ACTIVE " or "  MAX OFF   ", function()
    if not etat.alerteMax then
      if confirmer("Declencher l'ALERTE MAXIMALE ? Regime ROMEO / GUERRE partout.") then
        ctx.actions.basculerAlerteMax()
      end
    else
      ctx.actions.basculerAlerteMax()
    end
  end, colors.black, etat.alerteMax and PALETTE.alerte or PALETTE.fondPanneau, 12)

  -- Etat operationnel resume.
  local pistes, engagees = 0, 0
  for _, p in pairs(etat.pistes) do
    pistes = pistes + 1
    if p.engagement and p.engagement.actif then engagees = engagees + 1 end
  end

  local ageInventaire = os.clock() - etat.inventaireRecuA
  local inventaireOk = ageInventaire <= (cfg.validiteInventaire or 60)

  ecran.texte(2, 8, string.format("Pistes suivies  %-4d  Engagements  %d", pistes, engagees),
    PALETTE.texte, PALETTE.fond)
  local lanceurs, munitions = 0, 0
  for _, l in pairs(etat.lanceurs) do
    lanceurs = lanceurs + 1
    munitions = munitions + (l.munitions or 0)
  end
  ecran.texte(2, 9, string.format("Zones actives   %-4d  Radars       %d/%d",
    #etat.zones, etat.stationsActives, etat.nombreStations),
    (#etat.zones > 0 and etat.stationsActives > 0) and PALETTE.texte or PALETTE.avertissement,
    PALETTE.fond)
  ecran.texte(2, 10, string.format("Lanceurs        %-4d  Munitions    %d",
    lanceurs, munitions),
    (lanceurs > 0 and munitions > 0) and PALETTE.texte or PALETTE.avertissement, PALETTE.fond)

  local c = etat.compteurs
  ecran.texte(2, 12, string.format("Feu %d  Scramble %d  Kills %d  Perdues %d",
    c.ordresFeu, c.ordresScramble, c.killsConfirmes, c.pistesPerdues),
    PALETTE.attenue, PALETTE.fond)

  -- Une demande de scramble AG attend une signature humaine : c'est la seule
  -- chose que le systeme ne peut pas resoudre seul, donc elle passe devant.
  if etat.nombreDemandesAG > 0 then
    bouton(2, 13, string.format(" %d SCRAMBLE AG A VALIDER - ouvrir la carte ",
      etat.nombreDemandesAG), function()
        ecranCourant = "CARTE"
        for id in pairs(etat.demandesAG) do pisteSelectionnee = id break end
      end, colors.black, PALETTE.avertissement, 40)
  end

  if etat.derniereDecision then
    local d = etat.derniereDecision
    ecran.texte(2, 14, "Derniere decision", PALETTE.attenue, PALETTE.fond)
    ecran.texte(2, 15, couper(string.format("%s / %s / %s",
      d.cible, d.zone or "hors zone", d.verdict), ecran.largeur - 2),
      PALETTE.texte, PALETTE.fond)
  end

  if #etat.alertes > 0 then
    bouton(2, ecran.hauteur - 2, "Acquitter les alertes", function()
      ctx.actions.acquitterAlertes()
    end, colors.black, PALETTE.avertissement)
  end
end

----------------------------------------------------------------- ecran contacts
local function dessinerContacts()
  local etat = ctx.etat
  ecran.texte(2, 3, couper("CONTACT", 14) .. couper("CAT.", 7) .. couper("IFF", 8)
    .. couper("ZONE", 8) .. "VERDICT", PALETTE.attenue, PALETTE.fond)

  local liste = {}
  for _, p in pairs(etat.pistes) do liste[#liste + 1] = p end
  -- Le plus dangereux en haut : palier decroissant, puis distance croissante.
  table.sort(liste, function(a, b)
    local pa = (a.verdict and a.verdict.palier) or -1
    local pb = (b.verdict and b.verdict.palier) or -1
    if pa ~= pb then return pa > pb end
    return (a.distanceRadar or 1e9) < (b.distanceRadar or 1e9)
  end)

  if #liste == 0 then
    ecran.texte(2, 5, "Aucun contact radar.", PALETTE.attenue, PALETTE.fond)
    return
  end

  local lignes = ecran.hauteur - 5
  defilement = math.max(0, math.min(defilement, math.max(0, #liste - lignes)))

  local y = 4
  for i = defilement + 1, math.min(#liste, defilement + lignes) do
    local p = liste[i]
    local palier = (p.verdict and p.verdict.palier) or 0
    local glyphe = ctx.carte and ctx.carte.glyphe(p) or " "
    ecran.texte(2, y, glyphe .. couper(p.nom, 13), PALETTE.texte, PALETTE.fond)
    local etiquette = etat.demandesAG[p.id] and "AG!" or (p.categorie or "-"):sub(1, 6)
    ecran.texte(16, y, couper(etiquette, 7),
      etat.demandesAG[p.id] and PALETTE.avertissement or PALETTE.attenue, PALETTE.fond)
    -- Meme code couleurs que la carte : vert allie, bleu general, orange
    -- inconnu, rouge engage. Un operateur ne doit pas avoir deux grilles de
    -- lecture selon l'ecran ou il regarde.
    local cle = ctx.carte and ctx.carte.couleurContact(p) or "inconnu"
    ecran.texte(23, y, couper(p.iff or "-", 8),
      COULEUR_ETAT[cle] or PALETTE.texte, PALETTE.fond)
    ecran.texte(31, y, couper(p.classeZone or "-", 8),
      COULEUR_CLASSE[p.classeZone] or PALETTE.attenue, PALETTE.fond)
    ecran.texte(39, y, couper(p.verdictNom or "-", ecran.largeur - 39),
      COULEUR_PALIER[palier] or PALETTE.texte, PALETTE.fond)
    y = y + 1
  end

  ecran.texte(2, ecran.hauteur - 1, string.format(
    "%d contact(s) - fleches pour defiler", #liste), PALETTE.attenue, PALETTE.fond)
end

-------------------------------------------------------------- ecran plateformes
local function dessinerPlateformes()
  local etat = ctx.etat
  local plateformes = ctx.actions.plateformesDisponibles(os.clock())

  ecran.texte(2, 3, couper("PLATEFORME", 14) .. couper("MUN", 5) .. couper("TIRS", 6)
    .. "POSITION", PALETTE.attenue, PALETTE.fond)

  local y = 4
  if #plateformes == 0 then
    ecran.texte(2, y, "Aucune plateforme joignable.", PALETTE.avertissement, PALETTE.fond)
    ecran.texte(2, y + 2, "Chaque lanceur doit faire tourner lanceur.lua", PALETTE.attenue, PALETTE.fond)
    ecran.texte(2, y + 3, "et diffuser sur '" .. tostring(ctx.cfg.protocoleLanceur) .. "'.",
      PALETTE.attenue, PALETTE.fond)
    y = y + 5
  else
    for _, p in ipairs(plateformes) do
      if y >= ecran.hauteur - 5 then break end
      local munitions = p.munitions
      local vide = munitions ~= nil and munitions <= 0
      ecran.texte(2, y, couper(tostring(p.nom or "?"), 14),
        vide and PALETTE.danger or PALETTE.texte, PALETTE.fond)
      ecran.texte(16, y, couper(munitions and tostring(munitions) or "?", 5),
        vide and PALETTE.danger or
        ((munitions or 99) <= 3 and PALETTE.avertissement or PALETTE.ok), PALETTE.fond)
      ecran.texte(21, y, couper(tostring(p.tirs or 0), 6), PALETTE.attenue, PALETTE.fond)
      ecran.texte(27, y, couper(string.format("%.0f/%.0f/%.0f", p.x or 0, p.y or 0, p.z or 0),
        ecran.largeur - 27), PALETTE.attenue, PALETTE.fond)
      y = y + 1
    end
    y = y + 1
  end

  ------------------------------------------------------------ stations radar
  ecran.texte(2, y, couper("STATION RADAR", 16) .. couper("PORTEE", 8) .. "ETAT",
    PALETTE.attenue, PALETTE.fond)
  y = y + 1

  if etat.nombreStations == 0 then
    ecran.texte(2, y, "Aucune station radar sur le reseau.", PALETTE.avertissement, PALETTE.fond)
    ecran.texte(2, y + 1, "Le poste est aveugle.", PALETTE.danger, PALETTE.fond)
    return
  end

  local maintenant = os.clock()
  for nom, station in pairs(etat.stations) do
    if y >= ecran.hauteur - 1 then break end
    local age = maintenant - (station.recuA or 0)
    ecran.texte(2, y, couper(nom, 16),
      station.muette and PALETTE.danger or PALETTE.texte, PALETTE.fond)
    ecran.texte(18, y, couper(string.format("%.0f", station.portee or 0), 8),
      PALETTE.attenue, PALETTE.fond)
    ecran.texte(26, y, couper(station.muette
      and string.format("MUETTE %.0fs", age)
      or string.format("OK  %d contact(s)", #(station.contacts or {})),
      ecran.largeur - 26),
      station.muette and PALETTE.danger or PALETTE.ok, PALETTE.fond)
    y = y + 1
  end
end

------------------------------------------------------------------ ecran journal
local function dessinerJournal()
  local tampon = ctx.journal.tampon
  local lignes = ecran.hauteur - 4
  defilement = math.max(0, math.min(defilement, math.max(0, #tampon - lignes)))

  local COULEUR_NIVEAU = {
    DEBUG = PALETTE.attenue, INFO = PALETTE.texte, AVERT = PALETTE.avertissement,
    ERREUR = PALETTE.danger, CRITIQUE = PALETTE.alerte,
  }

  local y = 3
  local debut = math.max(1, #tampon - lignes + 1 - defilement)
  for i = debut, math.min(#tampon, debut + lignes - 1) do
    local entree = tampon[i]
    -- L'horodatage complet mange la ligne : on garde l'heure et le message.
    local texte = entree.texte:gsub("^%[%d%d%d%d%-%d%d%-%d%d ", "[")
    ecran.texte(1, y, couper(texte, ecran.largeur), COULEUR_NIVEAU[entree.niveau] or PALETTE.texte,
      PALETTE.fond)
    y = y + 1
  end

  ecran.texte(2, ecran.hauteur - 1, string.format(
    "%d ligne(s) en memoire - fichier command.log", #tampon), PALETTE.attenue, PALETTE.fond)
end

--------------------------------------------------------------------------------
-- 5 bis. CARTE TACTIQUE MOUVANTE
--
--   Zones en fond de carte, contacts en symboles, infrastructure du reseau.
--   La carte se recentre seule sur la menace la plus grave (moving map), ou
--   suit le poste, ou se laisse deplacer a la main.
--
--   Le fond de carte est calcule par le MEME moteur de zones que les
--   decisions : ce qu'on voit est litteralement ce que le systeme applique.
--------------------------------------------------------------------------------

local function nouveauTampon(largeur, hauteur, fond)
  local t = {}
  for l = 1, hauteur do
    local ligne = { ch = {}, fg = {}, bg = {} }
    for c = 1, largeur do
      ligne.ch[c], ligne.fg[c], ligne.bg[c] = " ", PALETTE.texte, fond
    end
    t[l] = ligne
  end
  return t
end

local function poser(t, col, ligne, glyphe, fg, bg)
  local l = t[ligne]
  if not l or not l.ch[col] then return false end
  l.ch[col] = glyphe
  if fg then l.fg[col] = fg end
  if bg then l.bg[col] = bg end
  return true
end

-- Rendu ligne par ligne. term.blit fait le travail en un appel par ligne ;
-- sans couleurs on retombe sur une ecriture simple.
local function rendreTampon(t, x0, y0)
  for l = 1, #t do
    local ligne = t[l]
    term.setCursorPos(x0, y0 + l - 1)
    if ecran.couleur and term.blit then
      local fgs, bgs = {}, {}
      for c = 1, #ligne.ch do
        fgs[c] = BLIT[ligne.fg[c]] or "0"
        bgs[c] = BLIT[ligne.bg[c]] or "f"
      end
      pcall(term.blit, table.concat(ligne.ch), table.concat(fgs), table.concat(bgs))
    else
      term.write(table.concat(ligne.ch))
    end
  end
end

local function positionPoste()
  return ctx.cfg.positionPoste or ctx.cfg.positionRadar or { x = 0, y = 64, z = 0 }
end

local function dessinerCarte()
  local C = ctx.carte
  if not C then
    ecran.texte(2, 5, "carte.lua absent : carte tactique indisponible.",
      PALETTE.avertissement, PALETTE.fond)
    ecran.texte(2, 7, "Le poste continue de decider sans affichage tactique.",
      PALETTE.attenue, PALETTE.fond)
    return
  end

  local etat = ctx.etat
  local hauteurPanneau = 4
  zoneCarte.x, zoneCarte.y = 1, 3
  zoneCarte.largeur = ecran.largeur
  zoneCarte.hauteur = math.max(3, ecran.hauteur - 3 - 1 - 1 - hauteurPanneau)

  local poste = positionPoste()
  C.appliquerSuivi(vue, etat.pistes, poste, zoneCarte.largeur, zoneCarte.hauteur)

  ------------------------------------------------------------ fond : zones
  local altitudeSonde = poste.y or 64
  local nouveau
  rasterCache, nouveau = C.rasterCache(rasterCache, vue, zoneCarte.largeur, zoneCarte.hauteur,
    etat.zones, ctx.noyau, etat.versionZones, altitudeSonde)

  local t = nouveauTampon(zoneCarte.largeur, zoneCarte.hauteur, PALETTE.fond)
  for ligne = 1, zoneCarte.hauteur do
    for col = 1, zoneCarte.largeur do
      local classe = rasterCache.grille[ligne] and rasterCache.grille[ligne][col]
      if classe then t[ligne].bg[col] = FOND_CLASSE[classe] or PALETTE.fond end
    end
  end

  --------------------------------------------------- infrastructure du reseau
  local function poserMonde(x, z, glyphe, fg, bg)
    local col, li, visible = C.versEcran(vue, x, z, zoneCarte.largeur, zoneCarte.hauteur)
    if visible then poser(t, col, li, glyphe, fg, bg) end
  end

  poserMonde(poste.x, poste.z, C.SYMBOLE_INFRA.COMMANDEMENT, colors.white)

  for _, station in pairs(etat.stations) do
    if station.x then
      poserMonde(station.x, station.z, C.SYMBOLE_INFRA.RADAR,
        station.muette and colors.red or colors.cyan)
    end
  end

  for _, lanceur in pairs(etat.lanceurs) do
    if lanceur.x then
      local vide = (lanceur.munitions or 1) <= 0
      poserMonde(lanceur.x, lanceur.z, C.SYMBOLE_INFRA.LANCEUR,
        vide and colors.red or colors.lime)
    end
  end

  ------------------------------------------------------------------ contacts
  local visibles = 0
  for id, piste in pairs(etat.pistes) do
    if type(piste.x) == "number" then
      local col, li, visible = C.versEcran(vue, piste.x, piste.z,
        zoneCarte.largeur, zoneCarte.hauteur)
      if visible then
        visibles = visibles + 1
        local glyphe, cle = C.symbole(piste)
        local fg = COULEUR_ETAT[cle] or PALETTE.texte
        local bg
        if cle == "engage" then
          -- Video inverse : un engagement en cours doit se voir depuis l'autre
          -- bout de la piece.
          bg = colors.white
        end
        -- Un scramble AG en attente clignote a sa facon : fond jaune, parce
        -- qu'il reclame une decision humaine et rien d'autre.
        if etat.demandesAG[id] then bg = colors.yellow fg = colors.black end
        if id == pisteSelectionnee then bg = colors.white fg = colors.black end
        poser(t, col, li, glyphe, fg, bg)
      end
    end
  end

  rendreTampon(t, zoneCarte.x, zoneCarte.y)

  --------------------------------------------------------------- ligne d'etat
  local ligneEtat = zoneCarte.y + zoneCarte.hauteur
  local largeurMonde, hauteurMonde = C.etendue(vue, zoneCarte.largeur, zoneCarte.hauteur)
  local stats = ctx.terrain and ctx.terrain.statistiques(etat.terrain) or { cases = 0 }
  local mentionAG = etat.nombreDemandesAG > 0
    and string.format("  %d AG EN ATTENTE", etat.nombreDemandesAG) or ""
  ecran.bande(ligneEtat, string.format(
    " %d b/car  %.0fx%.0f b  suivi %s  %d/%d radar  %d contact(s)  terrain %d%s",
    C.echelle(vue), largeurMonde, hauteurMonde, vue.suivi,
    etat.stationsActives, etat.nombreStations, visibles, stats.cases, mentionAG),
    etat.nombreDemandesAG > 0 and colors.black or PALETTE.boutonTexte,
    etat.nombreDemandesAG > 0 and PALETTE.avertissement or PALETTE.fondPanneau)

  --------------------------------------------------------- panneau inferieur
  local y = ligneEtat + 1
  local piste = pisteSelectionnee and etat.pistes[pisteSelectionnee]

  if not piste then
    pisteSelectionnee = nil
    ecran.texte(1, y, "* missile  ^ aeronef  o joueur vol  # vehicule  i infanterie",
      PALETTE.attenue, PALETTE.fond)
    local x = 1
    for _, cle in ipairs({ "allie", "general", "inconnu", "engage" }) do
      ecran.texte(x, y + 1, "##", COULEUR_ETAT[cle], PALETTE.fond)
      ecran.texte(x + 2, y + 1, LIBELLE_ETAT[cle], PALETTE.attenue, PALETTE.fond)
      x = x + 3 + #LIBELLE_ETAT[cle]
    end
    -- Legende des zones, dans leur propre couleur de fond.
    ecran.texte(1, y + 2, "Zones ", PALETTE.attenue, PALETTE.fond)
    local x = 7
    for _, classe in ipairs(ctx.noyau.CLASSES) do
      ecran.texte(x, y + 2, " " .. classe:sub(1, 1) .. " ", colors.white, FOND_CLASSE[classe])
      ecran.texte(x + 3, y + 2, classe:sub(1, 3):lower(), PALETTE.attenue, PALETTE.fond)
      x = x + 7
    end
    ecran.texte(1, y + 3, "+/- zoom  fleches  C poste  M menace  clic cible  R station  L lanceur",
      PALETTE.attenue, PALETTE.fond)
    return
  end

  ---------------------------------------------------------- panneau d'ordre
  local distance = math.sqrt((piste.x - poste.x) ^ 2 + (piste.z - poste.z) ^ 2)
  ecran.texte(1, y, couper(string.format("> %s  %s  %s  %s  %.0fm",
    piste.nom, piste.categorie or "?", piste.iff or "?",
    piste.classeZone or "hors zone", distance), ecran.largeur),
    PALETTE.texte, PALETTE.fond)

  -- Le libelle de la case reflete le verbe reellement transmis : un scramble
  -- sur cible au sol est un « Scramble AG », et le controleur doit le voir
  -- avant de cocher, pas apres.
  local verbeScramble = ctx.noyau.verbePourOrdre("SCRAMBLE", piste.categorie, ctx.cfg)

  local x = 1
  x = bouton(x, y + 1, (ordre.scramble and "[X] " or "[ ] ") .. verbeScramble,
    function() ordre.scramble = not ordre.scramble end,
    ordre.scramble and colors.black or PALETTE.boutonTexte,
    ordre.scramble and PALETTE.avertissement or PALETTE.fondPanneau)
  x = x + 1
  x = bouton(x, y + 1, (ordre.attaque and "[X] " or "[ ] ") .. "Attaque",
    function() ordre.attaque = not ordre.attaque end,
    ordre.attaque and colors.black or PALETTE.boutonTexte,
    ordre.attaque and PALETTE.danger or PALETTE.fondPanneau)
  x = x + 1
  bouton(x, y + 1, (ordre.allie and "[X] " or "[ ] ") .. "Allie",
    function()
      ordre.allie = not ordre.allie
      -- « Allie » est exclusif : on ne declare pas ami ce qu'on vient
      -- d'ordonner d'abattre.
      if ordre.allie then ordre.scramble, ordre.attaque = false, false end
    end,
    ordre.allie and colors.black or PALETTE.boutonTexte,
    ordre.allie and PALETTE.ok or PALETTE.fondPanneau)

  x = 1
  x = bouton(x, y + 2, "TRANSMETTRE", function()
    local cible = pisteSelectionnee
    local ok, detail = ctx.actions.ordreManuel(cible, {
      scramble = ordre.scramble, attaque = ordre.attaque, allie = ordre.allie,
    })
    message(ok and "ORDRE TRANSMIS" or "ORDRE REFUSE", {
      ok and "Transmis a FrenchNet Fire Control :" or "Aucun ordre n'est parti.",
      couper(tostring(detail), ecran.largeur - 2),
    }, ok and PALETTE.ok or PALETTE.danger)
    ordre.scramble, ordre.attaque, ordre.allie = false, false, false
    pisteSelectionnee = nil
  end, colors.black, PALETTE.ok, 15)
  x = x + 1
  bouton(x, y + 2, "Annuler", function()
    pisteSelectionnee = nil
    ordre.scramble, ordre.attaque, ordre.allie = false, false, false
  end, PALETTE.boutonTexte, PALETTE.fondPanneau, 10)

  local demande = ctx.etat.demandesAG[pisteSelectionnee]
  if demande then
    -- Le systeme a deja fait son travail : il a classe, choisi la plateforme,
    -- et s'est arrete la. Il ne reste qu'une signature a donner.
    ecran.texte(1, y + 3, couper(string.format(
      "SCRAMBLE AG demande par la doctrine - plateforme %s - a valider",
      tostring(demande.plateforme)), ecran.largeur - 10),
      colors.black, PALETTE.avertissement)
    bouton(ecran.largeur - 8, y + 3, "Refuser", function()
      ctx.actions.refuserDemandeAG(pisteSelectionnee)
      pisteSelectionnee = nil
    end, colors.white, PALETTE.danger, 9)
  else
    local mention = piste.allieManuel and "  [deja declare ALLIE a la main]" or ""
    ecran.texte(1, y + 3, couper(string.format("verdict automatique : %s%s",
      piste.verdictNom or "aucun", mention), ecran.largeur),
      PALETTE.attenue, PALETTE.fond)
  end
end

--------------------------------------------------------------------------------
-- 6. MENU PROTEGE
--------------------------------------------------------------------------------

local function demanderCode()
  if menuDeverrouille then return true end
  local saisie = saisir("Code d'acces au menu protege",
    "Configuration des zones et des codes transpondeur", true)
  if saisie == ctx.cfg.codeAccesMenu then
    menuDeverrouille = true
    ctx.journal.ecrire("INFO", ctx.ETAPES and ctx.ETAPES.INTERFACE or "interface de controle",
      "menu protege deverrouille par le controleur")
    return true
  end
  ctx.journal.ecrire("AVERT", "interface de controle",
    "code d'acces au menu protege refuse")
  message("ACCES REFUSE", { "Code incorrect." }, PALETTE.danger)
  ecranCourant = "PRINCIPAL"
  return false
end

local function dessinerMenu()
  ecran.texte(2, 3, "MENU PROTEGE", PALETTE.attenue, PALETTE.fond)
  bouton(2, 5,  "Configuration des zones      ", function() ecranCourant = "ZONES" defilement = 0 end,
    PALETTE.boutonTexte, PALETTE.fondPanneau, 30)
  bouton(2, 7,  "Codes transpondeur           ", function() ecranCourant = "CODES" end,
    PALETTE.boutonTexte, PALETTE.fondPanneau, 30)
  bouton(2, 9,  "Verrouiller le menu          ", function()
    menuDeverrouille = false
    ecranCourant = "PRINCIPAL"
  end, PALETTE.boutonTexte, PALETTE.fondPanneau, 30)

  ecran.texte(2, 12, "La bascule guerre / paix reste sur", PALETTE.attenue, PALETTE.fond)
  ecran.texte(2, 13, "l'ecran d'accueil, en un seul clic.", PALETTE.attenue, PALETTE.fond)
end

------------------------------------------------------------------- ecran codes
local function dessinerCodes()
  local cfg = ctx.cfg
  ecran.texte(2, 3, "CODES TRANSPONDEUR", PALETTE.attenue, PALETTE.fond)

  ecran.texte(2, 5, "Code allie (fixe)", PALETTE.attenue, PALETTE.fond)
  ecran.texte(2, 6, couper(tostring(cfg.codeAllie), ecran.largeur - 2), PALETTE.ok, PALETTE.fond)

  ecran.texte(2, 8, "Code general (rotatif)", PALETTE.attenue, PALETTE.fond)
  ecran.texte(2, 9, couper(tostring(cfg.codeGeneral), ecran.largeur - 2),
    PALETTE.avertissement, PALETTE.fond)

  if cfg.codeGeneralPrecedent then
    local reste = (cfg.graceRotation or 300) - (os.clock() - (cfg.rotationA or 0))
    if reste > 0 then
      ecran.texte(2, 11, string.format("Code precedent encore accepte %ds", math.floor(reste)),
        PALETTE.attenue, PALETTE.fond)
    end
  end

  bouton(2, 13, "Tourner le code general", function()
    local nouveau = saisir("Nouveau code general",
      "L'ancien reste accepte pendant la periode de grace")
    if nouveau and nouveau ~= "" then
      local ok, motif = ctx.actions.changerCodeGeneral(nouveau)
      message(ok and "CODE TOURNE" or "REFUS", {
        ok and ("Nouveau code general : " .. nouveau) or tostring(motif),
        ok and ("Ancien code accepte encore " .. tostring(ctx.cfg.graceRotation) .. "s.") or "",
      }, ok and PALETTE.ok or PALETTE.danger)
    end
  end, colors.black, PALETTE.avertissement, 26)

  ecran.texte(2, 15, "Le code allie se change dans", PALETTE.attenue, PALETTE.fond)
  ecran.texte(2, 16, "config_command.lua (redemarrage requis).", PALETTE.attenue, PALETTE.fond)
end

------------------------------------------------------------------- ecran zones
local function choisirClasse()
  local classes = ctx.noyau.CLASSES
  ecran.effacer(PALETTE.fond)
  ecran.bande(1, " CLASSE DE LA ZONE", PALETTE.titreTexte, PALETTE.titre)
  ecran.texte(2, 3, "De la moins a la plus reglementee :", PALETTE.attenue, PALETTE.fond)

  reinitialiserBoutons()
  local y = 5
  local descriptions = {
    CHARLIE = "paix: code general libre - guerre: scramble",
    BRAVO   = "paix: code general libre - guerre: destruction",
    ALPHA   = "destruction + scramble dans les deux modes",
    ROMEO   = "destruction totale, mobilisation generale",
  }
  local choix
  for _, classe in ipairs(classes) do
    bouton(2, y, classe, function() choix = classe end, colors.black, COULEUR_CLASSE[classe], 10)
    ecran.texte(13, y, couper(descriptions[classe], ecran.largeur - 13), PALETTE.attenue, PALETTE.fond)
    y = y + 2
  end
  ecran.texte(2, ecran.hauteur - 1, "Clic sur une classe, ou Q pour annuler",
    PALETTE.attenue, PALETTE.fond)

  while not choix do
    local evenement = { os.pullEvent() }
    if evenement[1] == "mouse_click" or evenement[1] == "monitor_touch" then
      local x, y2 = evenement[3], evenement[4]
      local b = boutonSous(x, y2)
      if b then b.action() end
    elseif evenement[1] == "char" and (evenement[2] == "q" or evenement[2] == "Q") then
      return nil
    end
  end
  return choix
end

local function creerZone()
  local nom = saisir("Nom de la zone", "Exemple : BASE-NORD, COULOIR-EST")
  if not nom or nom == "" then return end

  ecran.effacer(PALETTE.fond)
  ecran.bande(1, " FORME DE LA ZONE", PALETTE.titreTexte, PALETTE.titre)
  reinitialiserBoutons()
  local forme
  bouton(2, 4, "Rectangle (4 coins)", function() forme = "rectangle" end,
    PALETTE.boutonTexte, PALETTE.fondPanneau, 26)
  bouton(2, 6, "Cercle (centre + rayon)", function() forme = "cercle" end,
    PALETTE.boutonTexte, PALETTE.fondPanneau, 26)
  ecran.texte(2, ecran.hauteur - 1, "Clic pour choisir, Q pour annuler", PALETTE.attenue, PALETTE.fond)

  while not forme do
    local evenement = { os.pullEvent() }
    if evenement[1] == "mouse_click" or evenement[1] == "monitor_touch" then
      local b = boutonSous(evenement[3], evenement[4])
      if b then b.action() end
    elseif evenement[1] == "char" and (evenement[2] == "q" or evenement[2] == "Q") then
      return
    end
  end

  local zone = { nom = nom, forme = forme, actif = true }

  if forme == "rectangle" then
    zone.points = {}
    for i = 1, 4 do
      local p = saisirPoint(string.format("Coin %d sur 4 : X et Z", i),
        "Format : 1200 -2600   (F3, ligne Block)")
      if not p then
        message("SAISIE INVALIDE", { "Coordonnees illisibles, creation annulee." }, PALETTE.danger)
        return
      end
      zone.points[i] = p
    end
  else
    local centre = saisirPoint("Centre du cercle : X et Z", "Format : 1200 -2600")
    if not centre then
      message("SAISIE INVALIDE", { "Coordonnees illisibles, creation annulee." }, PALETTE.danger)
      return
    end
    zone.centre = centre
    local rayon = saisirNombre("Rayon en blocs", "Exemple : 250")
    if not rayon or rayon <= 0 then
      message("SAISIE INVALIDE", { "Rayon invalide, creation annulee." }, PALETTE.danger)
      return
    end
    zone.rayon = rayon
  end

  -- Bornes verticales facultatives : par defaut la zone est une colonne
  -- infinie, ce qui est le comportement voulu pour une defense aerienne.
  local plafond = saisirNombre("Plafond Y (facultatif)",
    "Vide = colonne infinie, ce qui est le cas courant")
  if plafond then zone.yMax = plafond end
  local plancher = saisirNombre("Plancher Y (facultatif)", "Vide = aucun plancher")
  if plancher then zone.yMin = plancher end

  local classe = choisirClasse()
  if not classe then return end
  zone.classe = classe

  local ok, motif = ctx.actions.ajouterZone(zone)
  if ok then
    message("ZONE ENREGISTREE", {
      string.format("%s - classe %s", zone.nom, zone.classe),
      string.format("Forme : %s", zone.forme),
      "",
      "En cas de chevauchement avec une autre zone,",
      "la classe la plus stricte l'emporte toujours.",
    }, COULEUR_CLASSE[classe])
  else
    message("ZONE REFUSEE", { tostring(motif) }, PALETTE.danger)
  end
end

local function dessinerZones()
  local zones = ctx.etat.zones
  ecran.texte(2, 3, couper("ZONE", 16) .. couper("CLASSE", 9) .. "GEOMETRIE",
    PALETTE.attenue, PALETTE.fond)

  local lignes = ecran.hauteur - 7
  defilement = math.max(0, math.min(defilement, math.max(0, #zones - lignes)))

  if #zones == 0 then
    ecran.texte(2, 5, "Aucune zone. Tout le theatre est", PALETTE.avertissement, PALETTE.fond)
    ecran.texte(2, 6, "hors juridiction : rien ne sera engage.", PALETTE.avertissement, PALETTE.fond)
  end

  local y = 4
  for i = defilement + 1, math.min(#zones, defilement + lignes) do
    local z = zones[i]
    local geometrie
    if z.forme == "cercle" then
      geometrie = string.format("cercle r=%.0f en %.0f/%.0f", z.rayon, z.centre.x, z.centre.z)
    else
      geometrie = string.format("rectangle 4 coins")
    end
    ecran.texte(2, y, couper(z.nom, 16), PALETTE.texte, PALETTE.fond)
    ecran.texte(18, y, couper(z.classe, 9), COULEUR_CLASSE[z.classe] or PALETTE.texte, PALETTE.fond)
    ecran.texte(27, y, couper(geometrie, ecran.largeur - 27), PALETTE.attenue, PALETTE.fond)
    boutons[#boutons + 1] = {
      x1 = 1, y1 = y, x2 = ecran.largeur, y2 = y,
      action = function()
        if confirmer("Supprimer la zone " .. z.nom .. " (" .. z.classe .. ") ?") then
          ctx.actions.supprimerZone(z.nom)
        end
      end,
    }
    y = y + 1
  end

  bouton(2, ecran.hauteur - 2, "Nouvelle zone", creerZone, colors.black, PALETTE.ok, 16)
  ecran.texte(20, ecran.hauteur - 2, "clic sur une ligne = supprimer",
    PALETTE.attenue, PALETTE.fond)
end

--------------------------------------------------------------------------------
-- 7. BOUCLE D'INTERFACE
--------------------------------------------------------------------------------

local function dessiner()
  reinitialiserBoutons()
  ecran.effacer(PALETTE.fond)
  dessinerEntete()

  if ecranCourant == "PRINCIPAL" then        dessinerPrincipal()
  elseif ecranCourant == "CARTE" then        dessinerCarte()
  elseif ecranCourant == "CONTACTS" then     dessinerContacts()
  elseif ecranCourant == "PLATEFORMES" then  dessinerPlateformes()
  elseif ecranCourant == "JOURNAL" then      dessinerJournal()
  elseif ecranCourant == "MENU" then         dessinerMenu()
  elseif ecranCourant == "ZONES" then        dessinerZones()
  elseif ecranCourant == "CODES" then        dessinerCodes()
  end

  dessinerOnglets()
end

function interface.executer(contexte)
  ctx = contexte
  ctx.ETAPES = ctx.actions.ETAPES

  -- Sortie sur moniteur externe si demande. Le clavier reste celui de
  -- l'ordinateur : seule la sortie est deportee.
  local cible = term.current()
  if type(ctx.cfg.moniteur) == "string" and peripheral.isPresent(ctx.cfg.moniteur) then
    local moniteur = peripheral.wrap(ctx.cfg.moniteur)
    pcall(moniteur.setTextScale, ctx.cfg.echelleMoniteur or 0.5)
    term.redirect(moniteur)
    cible = moniteur
  end

  ecran.largeur, ecran.hauteur = term.getSize()
  ecran.couleur = term.isColour and term.isColour()

  if ctx.carte then
    local poste = positionPoste()
    vue = ctx.carte.nouvelle({
      centreX = poste.x, centreZ = poste.z,
      echelle = ctx.cfg.echelleCarte, suivi = ctx.cfg.suiviCarte,
    })
  end

  local minuteur = os.startTimer(1)

  while not ctx.etat.arret do
    -- Le menu protege se verrouille des qu'on le quitte.
    if (ecranCourant == "MENU" or ecranCourant == "ZONES" or ecranCourant == "CODES") then
      if not demanderCode() then
        -- demanderCode a deja renvoye sur l'accueil.
      end
    end

    pcall(dessiner)

    local evenement = { os.pullEvent() }
    local nom = evenement[1]

    if nom == "timer" and evenement[2] == minuteur then
      minuteur = os.startTimer(1)

    elseif nom == "mouse_click" or nom == "monitor_touch" then
      local x, y = evenement[3], evenement[4]
      local b = boutonSous(x, y)
      if b then
        pcall(b.action)
      elseif ecranCourant == "CARTE" and ctx.carte and vue
             and x >= zoneCarte.x and x < zoneCarte.x + zoneCarte.largeur
             and y >= zoneCarte.y and y < zoneCarte.y + zoneCarte.hauteur then
        -- Clic gauche sur la carte : selection du contact sous le curseur.
        -- Le panneau d'ordre s'ouvre juste en dessous ; un clic dans le vide
        -- referme la selection.
        local col   = x - zoneCarte.x + 1
        local ligne = y - zoneCarte.y + 1
        local piste = ctx.carte.pisteSous(ctx.etat.pistes, vue, col, ligne,
          zoneCarte.largeur, zoneCarte.hauteur, 1)
        pisteSelectionnee = piste and piste.id or nil
        ordre.scramble, ordre.attaque, ordre.allie = false, false, false
      end

    elseif nom == "mouse_scroll" then
      if ecranCourant == "CARTE" and ctx.carte and vue then
        -- Molette : zoom, comme sur n'importe quelle carte.
        ctx.carte.zoomer(vue, evenement[2])
      else
        defilement = math.max(0, defilement + evenement[2])
      end

    elseif nom == "key" then
      local touche = evenement[2]
      local surCarte = (ecranCourant == "CARTE") and ctx.carte and vue

      if surCarte and (touche == keys.left or touche == keys.right
                       or touche == keys.up or touche == keys.down) then
        -- Sur la carte, les fleches deplacent la vue et basculent en suivi
        -- LIBRE : le controleur reprend la main sur le recentrage automatique.
        local dc = (touche == keys.right and 8) or (touche == keys.left and -8) or 0
        local dl = (touche == keys.down and 4) or (touche == keys.up and -4) or 0
        ctx.carte.deplacer(vue, dc, dl)
      elseif touche == keys.down then defilement = defilement + 1
      elseif touche == keys.up then defilement = math.max(0, defilement - 1)
      elseif touche == keys.one then ecranCourant, defilement = "PRINCIPAL", 0
      elseif touche == keys.two then ecranCourant, defilement = "CARTE", 0
      elseif touche == keys.three then ecranCourant, defilement = "CONTACTS", 0
      elseif touche == keys.four then ecranCourant, defilement = "PLATEFORMES", 0
      elseif touche == keys.five then ecranCourant, defilement = "JOURNAL", 0
      elseif touche == keys.six then ecranCourant, defilement = "MENU", 0
      elseif touche == keys.g then
        -- Raccourci clavier de la bascule : meme immediatete que le bouton.
        ctx.actions.basculerMode()
      end

    elseif nom == "char" and ecranCourant == "CARTE" and ctx.carte and vue then
      local touche = evenement[2]
      if touche == "+" or touche == "=" then ctx.carte.zoomer(vue, -1)
      elseif touche == "-" then ctx.carte.zoomer(vue, 1)
      elseif touche == "c" or touche == "C" then
        local poste = positionPoste()
        ctx.carte.centrer(vue, poste.x, poste.z, "POSTE")
      elseif touche == "m" or touche == "M" then
        vue.suivi = "MENACE"
        vue.version = vue.version + 1
      end

    elseif nom == "term_resize" or nom == "monitor_resize" then
      ecran.largeur, ecran.hauteur = term.getSize()
    end
  end

  if cible ~= term.current() then pcall(term.redirect, term.native()) end
end

return interface
