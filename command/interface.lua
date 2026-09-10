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

--[[
  ATTENTE D'EVENEMENT SANS SE FAIRE TUER PAR Ctrl+T.

  os.pullEvent LEVE une erreur "Terminated" des qu'un Ctrl+T arrive. Une
  interface batie dessus meurt donc avant d'avoir pu demander le mot de passe
  console - le verrou serait contournable en appuyant simplement sur deux
  touches.

  Toute l'interface attend donc en pullEventRaw et IGNORE les evenements
  'terminate' : c'est la boucle de terminaison du poste qui les traite, en
  levant un drapeau que l'interface consulte pour poser la question.
]]
local function attendre(filtre)
  while true do
    local evenement = table.pack(os.pullEventRaw())
    if evenement[1] ~= "terminate"
       and (filtre == nil or evenement[1] == filtre) then
      return table.unpack(evenement, 1, evenement.n)
    end
  end
end

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
  attendre("key")
end

local function confirmer(question)
  ecran.effacer(PALETTE.fond)
  ecran.bande(1, " CONFIRMATION", PALETTE.titreTexte, PALETTE.avertissement)
  ecran.texte(2, 3, couper(question, ecran.largeur - 2), PALETTE.texte, PALETTE.fond)
  ecran.texte(2, 5, "O = oui    toute autre touche = annuler", PALETTE.attenue, PALETTE.fond)
  local _, touche = attendre("char")
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
local rasterMoniteur     -- meme grille, aux dimensions du moniteur externe
local moniteur           -- peripherique moniteur adopte, ou nil
local moniteurNom
local zoneMoniteur = { x = 1, y = 2, largeur = 0, hauteur = 0 }
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
  -- L'ecran de situation est la premiere chose qu'on croit en panne quand il
  -- reste noir : son etat s'affiche donc ici, pas seulement dans le journal.
  ecran.texte(2, 11, string.format("Ecran situation %s",
    moniteur and ("moniteur " .. tostring(moniteurNom)) or "aucun (carte dans l'onglet)"),
    moniteur and PALETTE.texte or PALETTE.attenue, PALETTE.fond)

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
    local discordant = p.identification and p.identification.concordance == "DISCORDANT"
    local etiquette = etat.demandesAG[p.id] and "AG!"
      or (discordant and "IFF?" or (p.categorie or "-"):sub(1, 6))
    ecran.texte(16, y, couper(etiquette, 7),
      etat.demandesAG[p.id] and PALETTE.avertissement
      or (discordant and PALETTE.danger or PALETTE.attenue), PALETTE.fond)
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

--[[
  TAMPONS D'AFFICHAGE REUTILISES.
  Reallouer la trame entiere a chaque rafraichissement - plus de six mille
  cases pour un moniteur 3x3, deux fois par seconde - revient a faire tourner
  le ramasse-miettes en permanence pour redessiner la meme grille. Les tampons
  sont donc conserves entre deux images et simplement reecrits ; ils ne sont
  reconstruits que si les dimensions changent.
  Un tampon par surface : le terminal et le moniteur n'ont pas la meme taille.
]]
local tampons = {}

local function nouveauTampon(largeur, hauteur, fond, surface)
  surface = surface or "terminal"
  local t = tampons[surface]

  if not t or t.largeur ~= largeur or t.hauteur ~= hauteur then
    t = { largeur = largeur, hauteur = hauteur }
    for l = 1, hauteur do
      local ligne = { ch = {}, fg = {}, bg = {} }
      for c = 1, largeur do
        ligne.ch[c], ligne.fg[c], ligne.bg[c] = " ", PALETTE.texte, fond
      end
      t[l] = ligne
    end
    tampons[surface] = t
    return t
  end

  for l = 1, hauteur do
    local ligne = t[l]
    local ch, fg, bg = ligne.ch, ligne.fg, ligne.bg
    for c = 1, largeur do
      ch[c], fg[c], bg[c] = " ", PALETTE.texte, fond
    end
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
-- Tables de travail du rendu, reutilisees d'une ligne a l'autre et d'une image
-- a l'autre : elles ne servent qu'a alimenter table.concat.
local scratchFg, scratchBg = {}, {}

--[[
  RENDU DIFFERENTIEL - la mesure anti-lag la plus importante du poste.

  Un moniteur Minecraft n'est pas un ecran : chaque modification de son contenu
  est un paquet envoye a TOUS les joueurs a portee. Redessiner les trente-six
  lignes d'un 3x3 a chaque seconde, c'est envoyer trente-six lignes de texte a
  tout le monde autour, en permanence - y compris quand rien n'a bouge, ce qui
  est le cas la plupart du temps.

  On compare donc chaque ligne a ce qui y est deja affiche, et on n'ecrit QUE
  les lignes qui ont reellement change. Ciel vide et carte immobile : zero
  ecriture, zero paquet. Un contact qui traverse : une ou deux lignes.
]]
local function rendreTampon(t, x0, y0, forcer)
  local hauteur = t.hauteur or #t
  local largeur = t.largeur
  local couleur = ecran.couleur and term.blit
  local precedent = t.precedent
  if not precedent or forcer then
    precedent = {}
    t.precedent = precedent
  end

  local ecrites = 0
  for l = 1, hauteur do
    local ligne = t[l]
    local n = largeur or #ligne.ch
    local texte = table.concat(ligne.ch, "", 1, n)
    local avant, arriere

    if couleur then
      local fg, bg = ligne.fg, ligne.bg
      for c = 1, n do
        scratchFg[c] = BLIT[fg[c]] or "0"
        scratchBg[c] = BLIT[bg[c]] or "f"
      end
      avant   = table.concat(scratchFg, "", 1, n)
      arriere = table.concat(scratchBg, "", 1, n)
    end

    local memo = precedent[l]
    local identique = memo and memo.texte == texte
      and memo.avant == avant and memo.arriere == arriere

    if not identique then
      term.setCursorPos(x0, y0 + l - 1)
      if couleur then
        pcall(term.blit, texte, avant, arriere)
      else
        term.write(texte)
      end
      precedent[l] = { texte = texte, avant = avant, arriere = arriere }
      ecrites = ecrites + 1
    end
  end
  return ecrites
end

--[[
  Meme principe pour les bandeaux de titre et d'etat : une bande reecrite a
  l'identique reste un paquet envoye a tous les joueurs alentour.
]]
local bandesAffichees = {}

local function bandeSiChangee(cle, y, texte, fg, bg)
  local empreinte = tostring(texte) .. "\1" .. tostring(fg) .. "\1" .. tostring(bg)
  if bandesAffichees[cle] == empreinte then return false end
  bandesAffichees[cle] = empreinte
  ecran.bande(y, texte, fg, bg)
  return true
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

  -- Le terminal est integralement efface a chaque image par ecran.effacer :
  -- son memo differentiel n'a plus de sens, on force la reecriture. Le
  -- moniteur, lui, n'est jamais efface et beneficie pleinement du differentiel.
  local t = nouveauTampon(zoneCarte.largeur, zoneCarte.hauteur, PALETTE.fond, "terminal")
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

  rendreTampon(t, zoneCarte.x, zoneCarte.y, true)

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
    ecran.texte(1, y + 3, "+/- zoom  fleches  C poste  M menace  clic cible  IFF? discordance",
      PALETTE.attenue, PALETTE.fond)
    return
  end

  ---------------------------------------------------------- panneau d'ordre
  local distance = math.sqrt((piste.x - poste.x) ^ 2 + (piste.z - poste.z) ^ 2)
  local ident = piste.identification
  -- Les deux voies d'identification sont affichees cote a cote : c'est la
  -- seule facon de voir d'un coup d'oeil qu'un code valide est porte par un
  -- engin que le radar n'aime pas.
  local mentionVoies = ""
  if ident then
    mentionVoies = string.format("  T:%s R:%s",
      (ident.transpondeur.statut or "?"):sub(1, 3),
      (ident.radar.statut or "?"):sub(1, 3))
  end
  ecran.texte(1, y, couper(string.format("> %s  %s  %s  %s  %.0fm%s",
    piste.nom, piste.categorie or "?", piste.iff or "?",
    piste.classeZone or "hors zone", distance, mentionVoies), ecran.largeur),
    (ident and ident.concordance == "DISCORDANT") and PALETTE.danger or PALETTE.texte,
    PALETTE.fond)

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
  elseif ident and ident.alerte then
    -- Une discordance entre les deux voies est ce qu'un operateur doit lire
    -- AVANT de cocher quoi que ce soit.
    ecran.texte(1, y + 3, couper("! " .. ident.alerte, ecran.largeur),
      colors.black, PALETTE.danger)
  else
    local mention = piste.allieManuel and "  [deja declare ALLIE a la main]" or ""
    ecran.texte(1, y + 3, couper(string.format("verdict automatique : %s%s",
      piste.verdictNom or "aucun", mention), ecran.largeur),
      PALETTE.attenue, PALETTE.fond)
  end
end

--------------------------------------------------------------------------------
-- 5 ter. ECRAN DE SITUATION SUR MONITEUR EXTERNE
--
--   Un moniteur accole a l'ordinateur est detecte et adopte sans reglage.
--   Il ne DUPLIQUE pas le terminal : il affiche la carte tactique en plein
--   ecran pendant que le terminal garde l'interface, les menus et la saisie.
--   C'est la disposition d'un vrai poste de controle - et c'est aussi la
--   seule qui rende un 3x3 reellement utile : dupliquer un terminal de 51
--   colonnes sur un mur de 3 metres ne sert a rien.
--
--   Le clic sur le moniteur selectionne un contact ; le panneau d'ordre
--   s'ouvre sur le terminal, la ou se trouve le clavier.
--------------------------------------------------------------------------------

-- Echelles de texte acceptees par CC: Tweaked, de la plus grande a la plus
-- petite. On cherche la PLUS GRANDE qui laisse encore assez de place : du
-- texte lisible de loin prime sur du texte minuscule et une carte immense.
local ECHELLES_MONITEUR = { 5, 4, 3, 2.5, 2, 1.5, 1, 0.5 }

local function choisirEchelle(ecranMoniteur, largeurMini, hauteurMini)
  local meilleure, meilleureL, meilleureH
  for _, echelle in ipairs(ECHELLES_MONITEUR) do
    local ok = pcall(ecranMoniteur.setTextScale, echelle)
    if ok then
      local l, h = ecranMoniteur.getSize()
      meilleure, meilleureL, meilleureH = meilleure or echelle, meilleureL or l, meilleureH or h
      if l >= largeurMini and h >= hauteurMini then
        return echelle, l, h
      end
    end
  end
  -- Aucune echelle n'atteint le minimum : on prend la plus fine, qui donne le
  -- plus de place, et on le signale.
  pcall(ecranMoniteur.setTextScale, 0.5)
  local l, h = ecranMoniteur.getSize()
  return 0.5, l, h
end

local function detecterMoniteur()
  local cfg = ctx.cfg
  if cfg.moniteur == false then
    ctx.journal.ecrire("INFO", "carte tactique",
      "moniteur externe desactive en configuration")
    return
  end

  local candidat
  if type(cfg.moniteur) == "string" then
    if peripheral.isPresent(cfg.moniteur)
       and peripheral.getType(cfg.moniteur) == "monitor" then
      candidat = cfg.moniteur
    else
      ctx.journal.ecrire("AVERT", "carte tactique",
        "moniteur force '" .. cfg.moniteur .. "' introuvable, detection automatique")
    end
  end

  if not candidat then
    -- Le PLUS GRAND moniteur accole : sur un poste qui en porte plusieurs,
    -- c'est celui qui est fait pour la situation tactique.
    local meilleureSurface = 0
    for _, nom in ipairs(peripheral.getNames()) do
      if peripheral.getType(nom) == "monitor" then
        local m = peripheral.wrap(nom)
        local ok, l, h = pcall(m.getSize)
        if ok and l and h and (l * h) > meilleureSurface then
          meilleureSurface, candidat = l * h, nom
        end
      end
    end
  end

  if not candidat then
    ctx.journal.ecrire("INFO", "carte tactique",
      "aucun moniteur externe : la carte reste dans l'onglet du terminal")
    return
  end

  moniteur, moniteurNom = peripheral.wrap(candidat), candidat
  pcall(moniteur.setBackgroundColour, PALETTE.fond)
  pcall(moniteur.clear)

  local echelle, largeur, hauteur
  if type(ctx.cfg.echelleMoniteur) == "number" then
    echelle = ctx.cfg.echelleMoniteur
    pcall(moniteur.setTextScale, echelle)
    largeur, hauteur = moniteur.getSize()
  else
    echelle, largeur, hauteur = choisirEchelle(moniteur,
      ctx.cfg.carteLargeurMini or 50, ctx.cfg.carteHauteurMini or 20)
  end

  local couleur = moniteur.isColour and moniteur.isColour()
  ctx.journal.ecrire("INFO", "carte tactique", string.format(
    "moniteur '%s' adopte comme ecran de situation : %dx%d caracteres a l'echelle %.1f%s",
    candidat, largeur, hauteur, echelle, couleur and "" or " (monochrome)"))

  if largeur < (ctx.cfg.carteLargeurMini or 50) or hauteur < (ctx.cfg.carteHauteurMini or 20) then
    ctx.journal.ecrire("AVERT", "carte tactique", string.format(
      "moniteur trop petit pour la carte demandee (%dx%d obtenus, %dx%d voulus) : " ..
      "agrandissez le moniteur ou baissez carteLargeurMini / carteHauteurMini",
      largeur, hauteur, ctx.cfg.carteLargeurMini or 50, ctx.cfg.carteHauteurMini or 20))
  end
end

--[[
  Rendu de la carte sur le moniteur. On redirige temporairement le terminal
  vers le moniteur pour reutiliser exactement les memes primitives de dessin :
  une seule implementation de la carte, donc une seule a maintenir et a
  corriger.
]]
local function dessinerCarteMoniteur()
  if not (moniteur and ctx.carte and vue) then return end
  local C, etat = ctx.carte, ctx.etat

  local ancien = term.redirect(moniteur)
  local sauveL, sauveH, sauveC = ecran.largeur, ecran.hauteur, ecran.couleur

  local ok = pcall(function()
    ecran.largeur, ecran.hauteur = term.getSize()
    ecran.couleur = term.isColour and term.isColour()

    zoneMoniteur.x, zoneMoniteur.y = 1, 2
    zoneMoniteur.largeur = ecran.largeur
    zoneMoniteur.hauteur = math.max(1, ecran.hauteur - 2)

    local poste = positionPoste()
    local guerre = (etat.mode == ctx.noyau.MODES.GUERRE)

    -- Bandeau : etat du theatre, visible de l'autre bout de la salle.
    local titre = string.format(" FRENCHNET %s  %s%s",
      ctx.cfg.identifiant, etat.mode,
      etat.alerteMax and "  *** ALERTE MAXIMALE ***" or "")
    bandeSiChangee("moniteurTitre", 1, titre, colors.white,
      etat.alerteMax and PALETTE.alerte or (guerre and PALETTE.guerre or PALETTE.titre))

    local altitudeSonde = poste.y or 64
    rasterMoniteur = C.rasterCache(rasterMoniteur, vue,
      zoneMoniteur.largeur, zoneMoniteur.hauteur,
      etat.zones, ctx.noyau, etat.versionZones, altitudeSonde)

    local t = nouveauTampon(zoneMoniteur.largeur, zoneMoniteur.hauteur, PALETTE.fond, "moniteur")
    for ligne = 1, zoneMoniteur.hauteur do
      for col = 1, zoneMoniteur.largeur do
        local classe = rasterMoniteur.grille[ligne] and rasterMoniteur.grille[ligne][col]
        if classe then t[ligne].bg[col] = FOND_CLASSE[classe] or PALETTE.fond end
      end
    end

    local function poserMonde(x, z, glyphe, fg, bg)
      local col, li, visible = C.versEcran(vue, x, z,
        zoneMoniteur.largeur, zoneMoniteur.hauteur)
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
        poserMonde(lanceur.x, lanceur.z, C.SYMBOLE_INFRA.LANCEUR,
          (lanceur.munitions or 1) <= 0 and colors.red or colors.lime)
      end
    end

    local visibles = 0
    for id, piste in pairs(etat.pistes) do
      if type(piste.x) == "number" then
        local col, li, visible = C.versEcran(vue, piste.x, piste.z,
          zoneMoniteur.largeur, zoneMoniteur.hauteur)
        if visible then
          visibles = visibles + 1
          local glyphe, cle = C.symbole(piste)
          local fg, bg = COULEUR_ETAT[cle] or PALETTE.texte, nil
          if cle == "engage" then bg = colors.white end
          if etat.demandesAG[id] then bg = colors.yellow fg = colors.black end
          if id == pisteSelectionnee then bg = colors.white fg = colors.black end
          poser(t, col, li, glyphe, fg, bg)
        end
      end
    end

    etat.lignesMoniteur = rendreTampon(t, zoneMoniteur.x, zoneMoniteur.y)

    local largeurMonde, hauteurMonde = C.etendue(vue,
      zoneMoniteur.largeur, zoneMoniteur.hauteur)
    local mentionAG = etat.nombreDemandesAG > 0
      and string.format("  %d AG A VALIDER", etat.nombreDemandesAG) or ""
    bandeSiChangee("moniteurEtat", ecran.hauteur, string.format(
      " %d b/car  %.0fx%.0f b  %s  %d/%d radar  %d contact(s)%s",
      C.echelle(vue), largeurMonde, hauteurMonde, vue.suivi,
      etat.stationsActives, etat.nombreStations, visibles, mentionAG),
      etat.nombreDemandesAG > 0 and colors.black or PALETTE.boutonTexte,
      etat.nombreDemandesAG > 0 and PALETTE.avertissement or PALETTE.fondPanneau)
  end)

  ecran.largeur, ecran.hauteur, ecran.couleur = sauveL, sauveH, sauveC
  term.redirect(ancien)
  return ok
end

--------------------------------------------------------------------------------
-- 6. MENU PROTEGE
--------------------------------------------------------------------------------

--[[
  VERROU DE LA CONSOLE CraftOS
  Sortir de l'interface, c'est se retrouver devant un shell avec acces a tous
  les fichiers du poste : codes transpondeur, zones, journal. La porte est
  donc gardee, et chaque tentative journalisee.
]]
local function demanderConsole()
  local saisie = saisir("Mot de passe d'acces a la console",
    "Le poste s'arretera et cessera de decider", true)
  ctx.etat.demandeConsole = false
  if saisie == nil or saisie == "" then
    return false
  end
  local ok = ctx.actions.ouvrirConsole(saisie)
  if not ok then
    message("ACCES REFUSE", {
      "Mot de passe console incorrect.",
      "",
      "La tentative a ete journalisee.",
    }, PALETTE.danger)
  end
  return ok
end

-- Verrouillage au demarrage : l'ecran reste noir tant que le mot de passe
-- console n'a pas ete donne. Desactive par defaut, parce qu'en salle de
-- controle la bascule guerre / paix doit rester accessible en un clic.
local function ecranVerrouille()
  while not ctx.etat.arret do
    ecran.effacer(PALETTE.fond)
    ecran.bande(1, " FRENCHNET COMMAND - POSTE VERROUILLE",
      PALETTE.titreTexte, PALETTE.danger)
    ecran.texte(2, 3, "Poste " .. tostring(ctx.cfg.identifiant), PALETTE.texte, PALETTE.fond)
    ecran.texte(2, 5, "Le systeme de defense continue de decider.", PALETTE.attenue, PALETTE.fond)
    ecran.texte(2, 6, "Seul l'affichage est verrouille.", PALETTE.attenue, PALETTE.fond)
    local saisie = saisir("Mot de passe", "Acces a l'interface de controle", true)
    if saisie == ctx.cfg.motDePasseConsole then
      ctx.journal.ecrire("INFO", "interface de controle",
        "poste deverrouille par un controleur")
      return
    end
    ctx.journal.ecrire("AVERT", "interface de controle",
      "deverrouillage du poste refuse : mot de passe incorrect")
    message("ACCES REFUSE", { "Mot de passe incorrect." }, PALETTE.danger)
  end
end

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
--[[
  Tout se change ici, en jeu : les DEUX codes transpondeur et les DEUX mots de
  passe. Les nouvelles valeurs sont enregistrees dans etat.dat et PRIMENT sur
  config_command.lua, qui n'amorce qu'un poste neuf. Sans cette priorite,
  chaque redemarrage ramenerait les codes d'usine et toute la flotte deja
  reconfiguree deviendrait INCONNUE d'un coup.
]]
local function dessinerCodes()
  local cfg = ctx.cfg
  ecran.texte(2, 3, "CODES ET MOTS DE PASSE", PALETTE.attenue, PALETTE.fond)

  local function resteDeGrace(instantRotation)
    if not instantRotation then return nil end
    local reste = (cfg.graceRotation or 300) - (os.clock() - instantRotation)
    if reste > 0 then return reste end
    return nil
  end

  ----------------------------------------------------------------- code allie
  ecran.texte(2, 5, "Code allie - libre passage", PALETTE.attenue, PALETTE.fond)
  ecran.texte(2, 6, couper(tostring(cfg.codeAllie), 26), PALETTE.ok, PALETTE.fond)
  bouton(29, 6, "Tourner", function()
    local nouveau = saisir("Nouveau code ALLIE",
      "L'ancien reste accepte pendant la periode de grace")
    if nouveau and nouveau ~= "" then
      local ok, motif = ctx.actions.changerCodeAllie(nouveau)
      message(ok and "CODE ALLIE TOURNE" or "REFUS", ok and {
        "Nouveau code allie : " .. nouveau,
        "",
        "L'ancien reste accepte " .. tostring(cfg.graceRotation) .. "s.",
        "Reconfigurez les transpondeurs AVANT la fin",
        "de ce delai, sinon la flotte sera declassee.",
      } or { tostring(motif) }, ok and PALETTE.ok or PALETTE.danger)
    end
  end, colors.black, PALETTE.ok, 10)

  local resteAllie = resteDeGrace(cfg.rotationAllieA)
  if cfg.codeAlliePrecedent and resteAllie then
    ecran.texte(2, 7, string.format("ancien accepte encore %ds", math.floor(resteAllie)),
      PALETTE.avertissement, PALETTE.fond)
  end

  --------------------------------------------------------------- code general
  ecran.texte(2, 9, "Code general - acces conditionnel", PALETTE.attenue, PALETTE.fond)
  ecran.texte(2, 10, couper(tostring(cfg.codeGeneral), 26), PALETTE.avertissement, PALETTE.fond)
  bouton(29, 10, "Tourner", function()
    local nouveau = saisir("Nouveau code GENERAL",
      "L'ancien reste accepte pendant la periode de grace")
    if nouveau and nouveau ~= "" then
      local ok, motif = ctx.actions.changerCodeGeneral(nouveau)
      message(ok and "CODE GENERAL TOURNE" or "REFUS", ok and {
        "Nouveau code general : " .. nouveau,
        "",
        "L'ancien reste accepte " .. tostring(cfg.graceRotation) .. "s.",
      } or { tostring(motif) }, ok and PALETTE.ok or PALETTE.danger)
    end
  end, colors.black, PALETTE.avertissement, 10)

  local resteGeneral = resteDeGrace(cfg.rotationGeneraleA)
  if cfg.codeGeneralPrecedent and resteGeneral then
    ecran.texte(2, 11, string.format("ancien accepte encore %ds", math.floor(resteGeneral)),
      PALETTE.avertissement, PALETTE.fond)
  end

  ------------------------------------------------------------ mots de passe
  local function changerMotDePasse(libelle, action)
    local ancien = saisir("Mot de passe " .. libelle .. " ACTUEL",
      "Sans lui, aucun changement n'est possible", true)
    if not ancien then return end
    local nouveau = saisir("NOUVEAU mot de passe " .. libelle,
      "4 caracteres minimum", true)
    if not nouveau then return end
    local confirmation = saisir("Confirmez le nouveau mot de passe", nil, true)
    if confirmation ~= nouveau then
      message("REFUS", { "Les deux saisies ne concordent pas." }, PALETTE.danger)
      return
    end
    local ok, motif = action(ancien, nouveau)
    message(ok and "MOT DE PASSE CHANGE" or "REFUS",
      { ok and ("Mot de passe " .. libelle .. " mis a jour.") or tostring(motif) },
      ok and PALETTE.ok or PALETTE.danger)
  end

  ecran.texte(2, 13, "Mots de passe", PALETTE.attenue, PALETTE.fond)
  local x = bouton(2, 14, "Menu protege", function()
    changerMotDePasse("MENU", ctx.actions.changerCodeAccesMenu)
  end, PALETTE.boutonTexte, PALETTE.fondPanneau, 16)
  bouton(x + 1, 14, "Console CraftOS", function()
    changerMotDePasse("CONSOLE", ctx.actions.changerMotDePasseConsole)
  end, PALETTE.boutonTexte, PALETTE.fondPanneau, 19)

  -- Avertissement tant que les valeurs d'usine sont en place : elles figurent
  -- en clair dans le depot public, donc elles ne protegent rien.
  local usine = (cfg.codeAccesMenu == "1234") or (cfg.motDePasseConsole == "578933")
  if usine then
    ecran.bande(16, " ! mot(s) de passe d'usine : publics, donc sans effet",
      colors.black, PALETTE.danger)
  else
    ecran.texte(2, 16, "Valeurs enregistrees dans etat.dat, elles", PALETTE.attenue, PALETTE.fond)
    ecran.texte(2, 17, "priment sur config_command.lua.", PALETTE.attenue, PALETTE.fond)
  end
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
    local evenement = { attendre() }
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
    local evenement = { attendre() }
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

  ecran.largeur, ecran.hauteur = term.getSize()
  ecran.couleur = term.isColour and term.isColour()

  if ctx.carte then
    local poste = positionPoste()
    vue = ctx.carte.nouvelle({
      centreX = poste.x, centreZ = poste.z,
      echelle = ctx.cfg.echelleCarte, suivi = ctx.cfg.suiviCarte,
    })
  end

  -- Le moniteur externe devient l'ecran de situation : carte en plein ecran,
  -- pendant que le terminal garde l'interface et le clavier.
  pcall(detecterMoniteur)

  if ctx.cfg.verrouillageDemarrage == true then ecranVerrouille() end

  local minuteur = os.startTimer(1)

  while not ctx.etat.arret do
    -- Ctrl+T a ete presse : la boucle de terminaison a leve le drapeau
    -- plutot que d'arreter, pour que le mot de passe soit demande ici.
    if ctx.etat.demandeConsole then
      if demanderConsole() then break end
    end

    -- Le menu protege se verrouille des qu'on le quitte.
    if (ecranCourant == "MENU" or ecranCourant == "ZONES" or ecranCourant == "CODES") then
      if not demanderCode() then
        -- demanderCode a deja renvoye sur l'accueil.
      end
    end

    pcall(dessiner)
    if moniteur then pcall(dessinerCarteMoniteur) end

    local evenement = { attendre() }
    local nom = evenement[1]

    if nom == "timer" and evenement[2] == minuteur then
      minuteur = os.startTimer(1)

    elseif nom == "monitor_touch" and moniteur and ctx.carte and vue then
      --[[
        Clic sur l'ECRAN DE SITUATION. Il ne porte aucun bouton : il ne sert
        qu'a designer. Le contact selectionne ouvre le panneau d'ordre sur le
        TERMINAL, la ou se trouve le clavier - un moniteur ne se tape pas.
      ]]
      local x, y = evenement[3], evenement[4]
      local col   = x - zoneMoniteur.x + 1
      local ligne = y - zoneMoniteur.y + 1
      if col >= 1 and col <= zoneMoniteur.largeur
         and ligne >= 1 and ligne <= zoneMoniteur.hauteur then
        local piste = ctx.carte.pisteSous(ctx.etat.pistes, vue, col, ligne,
          zoneMoniteur.largeur, zoneMoniteur.hauteur, 1)
        pisteSelectionnee = piste and piste.id or nil
        ordre.scramble, ordre.attaque, ordre.allie = false, false, false
        if piste then
          ecranCourant = "CARTE"
          ctx.journal.ecrire("DEBUG", "carte tactique",
            "contact " .. tostring(piste.nom) .. " designe depuis l'ecran de situation")
        end
      end

    elseif nom == "mouse_click" then
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

    elseif nom == "term_resize" then
      ecran.largeur, ecran.hauteur = term.getSize()

    elseif nom == "monitor_resize" then
      -- Le moniteur a change de taille : on refait le choix d'echelle et on
      -- invalide son cache de fond de carte.
      rasterMoniteur = nil
      pcall(detecterMoniteur)

    elseif nom == "peripheral" or nom == "peripheral_detach" then
      -- Un moniteur vient d'etre pose ou casse : on reprend la detection.
      rasterMoniteur = nil
      moniteur, moniteurNom = nil, nil
      pcall(detecterMoniteur)
    end
  end

  -- On laisse l'ecran de situation propre : un moniteur fige sur une vieille
  -- situation tactique est pire qu'un moniteur eteint.
  if moniteur then
    pcall(function()
      moniteur.setBackgroundColour(PALETTE.fond)
      moniteur.clear()
      moniteur.setCursorPos(1, 1)
      moniteur.setTextColour(PALETTE.attenue)
      moniteur.write("FRENCHNET COMMAND - poste arrete")
    end)
  end
end

return interface
