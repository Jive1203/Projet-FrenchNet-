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
    { "Contacts", "CONTACTS" },
    { "Defenses", "PLATEFORMES" },
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
  ecran.texte(2, 9, string.format("Zones actives   %-4d  Radar        %s",
    #etat.zones, etat.radarNom and "OK" or "ABSENT"),
    #etat.zones > 0 and PALETTE.texte or PALETTE.avertissement, PALETTE.fond)
  ecran.texte(2, 10, string.format("Plateformes     %-4d  Inventaire   %s",
    #etat.plateformes, inventaireOk and "a jour" or "PERIME"),
    inventaireOk and PALETTE.texte or PALETTE.avertissement, PALETTE.fond)

  local c = etat.compteurs
  ecran.texte(2, 12, string.format("Feu %d  Scramble %d  Kills %d  Perdues %d",
    c.ordresFeu, c.ordresScramble, c.killsConfirmes, c.pistesPerdues),
    PALETTE.attenue, PALETTE.fond)

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
    ecran.texte(2, y, couper(p.nom, 14), PALETTE.texte, PALETTE.fond)
    ecran.texte(16, y, couper((p.categorie or "-"):sub(1, 6), 7), PALETTE.attenue, PALETTE.fond)
    ecran.texte(23, y, couper(p.iff or "-", 8),
      p.iff == "ALLIE" and PALETTE.ok or (p.iff == "INCONNU" and PALETTE.danger or PALETTE.avertissement),
      PALETTE.fond)
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
  ecran.texte(2, 3, couper("PLATEFORME", 16) .. couper("TIRS", 6) .. couper("POSITION", 20),
    PALETTE.attenue, PALETTE.fond)

  if #etat.plateformes == 0 then
    ecran.texte(2, 5, "Aucune plateforme declaree par Fire Control.",
      PALETTE.avertissement, PALETTE.fond)
    ecran.texte(2, 7, "Fire Control doit diffuser sur le protocole",
      PALETTE.attenue, PALETTE.fond)
    ecran.texte(2, 8, "'" .. tostring(ctx.cfg.protocoleFireControl) .. "' une trame",
      PALETTE.attenue, PALETTE.fond)
    ecran.texte(2, 9, "{ plateformes = { { nom=, x=, y=, z=, tirs= } } }",
      PALETTE.attenue, PALETTE.fond)
    return
  end

  local age = os.clock() - etat.inventaireRecuA
  local y = 4
  for i, p in ipairs(etat.plateformes) do
    if y >= ecran.hauteur - 1 then break end
    ecran.texte(2, y, couper(tostring(p.nom or "?"), 16),
      p.disponible == false and PALETTE.attenue or PALETTE.texte, PALETTE.fond)
    ecran.texte(18, y, couper(tostring(p.tirs or 0), 6), PALETTE.texte, PALETTE.fond)
    ecran.texte(24, y, couper(string.format("%.0f/%.0f/%.0f", p.x or 0, p.y or 0, p.z or 0), 20),
      PALETTE.attenue, PALETTE.fond)
    y = y + 1
  end

  ecran.texte(2, ecran.hauteur - 1, string.format("Inventaire recu il y a %.0fs", age),
    age <= (ctx.cfg.validiteInventaire or 60) and PALETTE.attenue or PALETTE.avertissement,
    PALETTE.fond)
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
      if b then pcall(b.action) end

    elseif nom == "mouse_scroll" then
      defilement = math.max(0, defilement + evenement[2])

    elseif nom == "key" then
      local touche = evenement[2]
      if touche == keys.down then defilement = defilement + 1
      elseif touche == keys.up then defilement = math.max(0, defilement - 1)
      elseif touche == keys.one then ecranCourant, defilement = "PRINCIPAL", 0
      elseif touche == keys.two then ecranCourant, defilement = "CONTACTS", 0
      elseif touche == keys.three then ecranCourant, defilement = "PLATEFORMES", 0
      elseif touche == keys.four then ecranCourant, defilement = "JOURNAL", 0
      elseif touche == keys.five then ecranCourant, defilement = "MENU", 0
      elseif touche == keys.g then
        -- Raccourci clavier de la bascule : meme immediatete que le bouton.
        ctx.actions.basculerMode()
      end

    elseif nom == "term_resize" or nom == "monitor_resize" then
      ecran.largeur, ecran.hauteur = term.getSize()
    end
  end

  if cible ~= term.current() then pcall(term.redirect, term.native()) end
end

return interface
