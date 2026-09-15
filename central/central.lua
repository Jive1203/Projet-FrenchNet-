--[[----------------------------------------------------------------------------
  FRENCHNET / AERONAUTICS WARFARE
  Ordinateur central - grille tarifaire et penalites
  --------------------------------------------------------------------------
  Role   : detenir LA grille de prix du reseau -- un prix par objet, plus les
           reglages generaux et le regime de penalites -- derriere un menu
           verrouille par code, et la diffuser aux navires et aux bornes.
  Cible  : ordinateur avance, pose dans un local ferme, + modem Ender.

  Personne d'autre ne fixe les prix : les bornes affichent ce que le central
  diffuse, et les navires exigent a l'arrivee ce que le central a diffuse. Une
  borne publique n'a donc aucun moyen de brader une expedition.

  SUR LA SERRURE. Le code n'est jamais ecrit sur le disque : seule une
  empreinte salee l'est, dans central/code.dat. Cela empeche de LIRE le code
  en ouvrant les fichiers ; cela n'empeche pas celui qui a acces physique a
  l'ordinateur de casser le disque ou de remplacer le programme. Protegez la
  piece, pas seulement le fichier.

  NOTE SUR LES ACCENTS : chaines d'ecran volontairement sans accents, le
  terminal de CC: Tweaked etant oriente octet.
--------------------------------------------------------------------------------]]

local VERSION_PROGRAMME = "1.0.0"

local ETAPES = {
  DEMARRAGE         = "demarrage du central",
  CHARGEMENT_CONFIG = "chargement de la configuration du central",
  CHARGEMENT_MODULES= "chargement des modules communs",
  SERRURE           = "verification du code d'acces",
  CREATION_CODE     = "creation du code d'acces",
  CHARGEMENT_GRILLE = "chargement de la grille tarifaire",
  SAUVEGARDE_GRILLE = "sauvegarde de la grille tarifaire",
  MODIFICATION      = "modification de la grille",
  DETECTION_MODEM   = "detection du modem",
  OUVERTURE_REDNET  = "ouverture rednet",
  DIFFUSION         = "diffusion de la grille",
  DEMANDE           = "reponse a une demande de grille",
  CATALOGUE         = "reception d'un catalogue de navire",
  BOUCLE_PRINCIPALE = "boucle principale du central",
  ARRET             = "arret du central",
}

--------------------------------------------------------------------------------
-- Chemins et chargeur
--------------------------------------------------------------------------------

local function repertoireProgramme()
  if shell and shell.getRunningProgram then
    local ok, chemin = pcall(shell.getRunningProgram)
    if ok and chemin then
      local dossier = fs.getDir(chemin)
      if dossier and dossier ~= "" and dossier ~= "." then return dossier end
    end
  end
  return ""
end

local REPERTOIRE = repertoireProgramme()
local RACINE     = fs.getDir(REPERTOIRE) or ""
if RACINE == "." then RACINE = "" end

local function versRacine(chemin)
  if chemin == nil then return nil end
  if chemin:sub(1, 1) == "/" then return chemin end
  return fs.combine(RACINE, chemin)
end

local function charger(chemin)
  if not fs.exists(chemin) then error("fichier introuvable : " .. tostring(chemin), 0) end
  local f = fs.open(chemin, "r")
  local source = f.readAll()
  f.close()
  local morceau, err = load(source, "@" .. chemin, "t", _ENV)
  if not morceau then error(err, 0) end
  return morceau()
end

local CHEMIN_CONFIG  = fs.combine(REPERTOIRE, "config_central.lua")
local CHEMIN_GRILLE  = fs.combine(REPERTOIRE, "tarifs.dat")
local CHEMIN_CODE    = fs.combine(REPERTOIRE, "code.dat")
local MARQUEUR_ARRET = fs.combine(REPERTOIRE, ".arret_manuel")

--------------------------------------------------------------------------------
-- Variables de cycle
--------------------------------------------------------------------------------

local config, journal, Protocole
local coteModem
local grille          -- { sequence, tarif, penalites }
local catalogueConnu = {}   -- objets vus dans les catalogues des navires
local deverrouilleJusqua = 0

local function log(niveau, etape, message, ...)
  if journal and journal[niveau] then journal[niveau](etape, message, ...) end
end

--------------------------------------------------------------------------------
-- Affichage
--------------------------------------------------------------------------------

local function couleur(c)
  if term.isColour and term.isColour() then pcall(term.setTextColour, c) end
end

local function entete(sousTitre)
  term.clear()
  term.setCursorPos(1, 1)
  couleur(colors.yellow)
  print("== " .. (config and config.titre or "CENTRALE TARIFAIRE") .. " ==")
  couleur(colors.lightGray)
  print(("Grille n%d | %d prix specifiques | %d objets connus")
    :format(grille.sequence, (function()
      local n = 0
      for _ in pairs(grille.tarif.parObjet or {}) do n = n + 1 end
      return n
    end)(), #catalogueConnu))
  if sousTitre then
    couleur(colors.white)
    print("-- " .. sousTitre)
  end
  couleur(colors.white)
  print(("-"):rep(math.min(50, ({ term.getSize() })[1] or 50)))
end

local function pause(message)
  couleur(colors.lightGray)
  print(message or "Appuyez sur une touche...")
  couleur(colors.white)
  os.pullEvent("key")
end

local function saisir(invite, defaut)
  couleur(colors.white)
  write(invite)
  if defaut ~= nil and defaut ~= "" then write(" [" .. tostring(defaut) .. "] ") end
  local texte = read()
  if texte == nil or texte == "" then return defaut end
  return texte
end

--------------------------------------------------------------------------------
-- Serrure
--------------------------------------------------------------------------------

local function lireFichier(chemin)
  if not fs.exists(chemin) then return nil end
  local ok, valeur = pcall(function()
    local f = fs.open(chemin, "r")
    local texte = f.readAll()
    f.close()
    return textutils.unserialise(texte)
  end)
  if ok then return valeur end
  return nil
end

local function ecrireFichier(chemin, valeur)
  local ok, err = pcall(function()
    local dossier = fs.getDir(chemin)
    if dossier and dossier ~= "" and not fs.exists(dossier) then fs.makeDir(dossier) end
    local f = fs.open(chemin, "w")
    f.write(textutils.serialise(valeur))
    f.close()
  end)
  if not ok then
    log("erreur", ETAPES.SAUVEGARDE_GRILLE, "ecriture impossible de %s : %s",
      chemin, tostring(err))
  end
  return ok
end

local function selAleatoire()
  local morceaux = {}
  for i = 1, 8 do morceaux[i] = string.format("%02x", math.random(0, 255)) end
  return table.concat(morceaux)
end

local function definirCode()
  local minimum = config.serrure.longueurMinimale or 4
  entete("PREMIER DEMARRAGE - CHOIX DU CODE D'ACCES")
  print("Aucun code n'est encore defini pour cette centrale.")
  print("")
  print("Le code n'est jamais ecrit sur le disque : seule une empreinte")
  print("salee est conservee. Notez-le, il ne pourra pas etre relu.")
  print("")
  while true do
    write(("Nouveau code (%d caracteres minimum) : "):format(minimum))
    local code = read("*")
    if type(code) ~= "string" or #code < minimum then
      couleur(colors.red)
      print(("Trop court : %d caracteres minimum."):format(minimum))
      couleur(colors.white)
    else
      write("Confirmez le code : ")
      local confirmation = read("*")
      if confirmation ~= code then
        couleur(colors.red)
        print("Les deux saisies different.")
        couleur(colors.white)
      else
        local sel = selAleatoire()
        ecrireFichier(CHEMIN_CODE, {
          sel = sel, empreinte = Protocole.empreinte(sel .. code), version = 1,
        })
        log("avert", ETAPES.CREATION_CODE, "code d'acces defini")
        couleur(colors.lime)
        print("Code enregistre.")
        couleur(colors.white)
        pause()
        return true
      end
    end
  end
end

-- Retourne true si l'operateur est authentifie.
local function deverrouiller()
  local fiche = lireFichier(CHEMIN_CODE)
  if type(fiche) ~= "table" or type(fiche.empreinte) ~= "string" then
    return definirCode()
  end

  local tentatives = config.serrure.tentativesMax or 3
  for essai = 1, tentatives do
    entete("ACCES VERROUILLE")
    print("Cette centrale fixe les prix du reseau.")
    print("")
    write(("Code d'acces (essai %d/%d) : "):format(essai, tentatives))
    local code = read("*")
    if Protocole.empreinte(fiche.sel .. tostring(code)) == fiche.empreinte then
      log("info", ETAPES.SERRURE, "acces accorde")
      deverrouilleJusqua = os.clock() + (config.serrure.inactiviteSecondes or 120)
      return true
    end
    log("avert", ETAPES.SERRURE, "code errone (essai %d/%d)", essai, tentatives)
    couleur(colors.red)
    print("Code errone.")
    couleur(colors.white)
    os.sleep(1)
  end

  local blocage = config.serrure.verrouillageSecondes or 300
  log("erreur", ETAPES.SERRURE,
    "%d codes errones : acces bloque %d s", tentatives, blocage)
  entete("ACCES BLOQUE")
  couleur(colors.red)
  print(("%d codes errones. Acces bloque %d secondes."):format(tentatives, blocage))
  print("L'incident est inscrit au journal.")
  couleur(colors.white)
  os.sleep(blocage)
  return false
end

local function changerCode()
  local fiche = lireFichier(CHEMIN_CODE)
  entete("CHANGEMENT DU CODE")
  write("Code actuel : ")
  local actuel = read("*")
  if not fiche or Protocole.empreinte(fiche.sel .. tostring(actuel)) ~= fiche.empreinte then
    log("avert", ETAPES.SERRURE, "changement de code refuse : code actuel errone")
    couleur(colors.red)
    print("Code actuel errone.")
    couleur(colors.white)
    pause()
    return
  end
  fs.delete(CHEMIN_CODE)
  definirCode()
end

--------------------------------------------------------------------------------
-- Grille tarifaire
--------------------------------------------------------------------------------

local function grilleNeuve()
  local tarif = {}
  for cle, valeur in pairs(config.tarifInitial or {}) do
    if type(valeur) == "table" then
      local copie = {}
      for k, v in pairs(valeur) do copie[k] = v end
      tarif[cle] = copie
    else
      tarif[cle] = valeur
    end
  end
  tarif.parObjet = tarif.parObjet or {}
  return {
    version    = 1,
    sequence   = 1,
    tarif      = tarif,
    penalites  = config.penalitesInitiales or {},
  }
end

local function chargerGrille()
  local lue = lireFichier(CHEMIN_GRILLE)
  if type(lue) == "table" and type(lue.tarif) == "table"
     and type(lue.sequence) == "number" then
    grille = lue
    grille.penalites = grille.penalites or config.penalitesInitiales or {}
    log("info", ETAPES.CHARGEMENT_GRILLE,
      "grille n%d relue : %d prix specifiques", grille.sequence, (function()
        local n = 0
        for _ in pairs(grille.tarif.parObjet or {}) do n = n + 1 end
        return n
      end)())
  else
    grille = grilleNeuve()
    log("avert", ETAPES.CHARGEMENT_GRILLE,
      "aucune grille sur disque : grille initiale de la configuration")
  end
end

-- Toute modification incremente la sequence : une ancienne grille rejouee sur
-- le reseau sera refusee par les navires comme par les bornes.
local function publier(motif)
  grille.sequence = grille.sequence + 1
  ecrireFichier(CHEMIN_GRILLE, grille)
  log("info", ETAPES.MODIFICATION, "grille n%d publiee : %s", grille.sequence,
    tostring(motif))
  return grille.sequence
end

local function messageTarif()
  return Protocole.enveloppe(Protocole.TYPES.TARIF, {
    central     = config.identifiant,
    tarif       = grille.tarif,
    penalites   = grille.penalites,
    sequence    = grille.sequence,
    signature   = Protocole.signerTarif(grille.tarif, grille.sequence, config.jeton),
    version_programme = VERSION_PROGRAMME,
  })
end

local function diffuser(motif)
  local ok, err = pcall(rednet.broadcast, messageTarif(), Protocole.PROTOCOLE)
  if not ok then
    log("avert", ETAPES.DIFFUSION, "diffusion impossible : %s", tostring(err))
    return false
  end
  log("debug", ETAPES.DIFFUSION, "grille n%d diffusee (%s)", grille.sequence,
    tostring(motif or "periodique"))
  return true
end

--------------------------------------------------------------------------------
-- Reseau
--------------------------------------------------------------------------------

local function detecterModem()
  if config.coteModem then
    if peripheral.isPresent(config.coteModem) then return config.coteModem end
    error(("aucun modem sur le cote configure '%s'"):format(config.coteModem), 0)
  end
  local sansFil, filaire
  for _, nom in ipairs(peripheral.getNames()) do
    local estModem = false
    if peripheral.hasType then
      local ok, res = pcall(peripheral.hasType, nom, "modem")
      estModem = ok and res == true
    else
      estModem = peripheral.getType(nom) == "modem"
    end
    if estModem then
      local p = peripheral.wrap(nom)
      if p and type(p.isWireless) == "function" and p.isWireless() then
        sansFil = sansFil or nom
      else
        filaire = filaire or nom
      end
    end
  end
  local choisi = sansFil or filaire
  if not choisi then error("aucun modem detecte sur le central", 0) end
  return choisi
end

local function ouvrirReseau()
  coteModem = detecterModem()
  log("info", ETAPES.DETECTION_MODEM, "modem retenu : cote '%s'", coteModem)
  rednet.open(coteModem)
  if not rednet.isOpen(coteModem) then
    error("rednet.open a echoue sur le cote " .. coteModem, 0)
  end
  log("info", ETAPES.OUVERTURE_REDNET, "rednet ouvert, protocole '%s'", Protocole.PROTOCOLE)
end

local function noterCatalogue(articles)
  local vus = {}
  for _, nom in ipairs(catalogueConnu) do vus[nom] = true end
  local ajoutes = 0
  for _, article in ipairs(articles or {}) do
    if type(article) == "table" and type(article.nom) == "string" and not vus[article.nom] then
      catalogueConnu[#catalogueConnu + 1] = article.nom
      vus[article.nom] = true
      ajoutes = ajoutes + 1
    end
  end
  if ajoutes > 0 then
    table.sort(catalogueConnu)
    log("debug", ETAPES.CATALOGUE, "%d objet(s) nouveaux au catalogue (%d connus)",
      ajoutes, #catalogueConnu)
  end
end

local function cycleServeur()
  while true do
    local expediteur, message = rednet.receive(Protocole.PROTOCOLE, 30)
    if expediteur and Protocole.valide(message) then
      if message.type == Protocole.TYPES.TARIF_DEMANDE then
        log("info", ETAPES.DEMANDE, "grille n%d transmise a l'ordinateur %d",
          grille.sequence, expediteur)
        pcall(rednet.send, expediteur, messageTarif(), Protocole.PROTOCOLE)
      elseif message.type == Protocole.TYPES.CATALOGUE then
        -- Les navires annoncent le contenu du stockage source : c'est ce qui
        -- alimente la liste d'objets tarifables du menu.
        noterCatalogue(message.articles)
      end
    end
  end
end

local function cycleDiffusion()
  while true do
    diffuser("periodique")
    os.sleep(config.diffusionSecondes or 60)
  end
end

--------------------------------------------------------------------------------
-- Menu verrouille
--------------------------------------------------------------------------------

local function objetsTarifables()
  local vus, liste = {}, {}
  for nom in pairs(grille.tarif.parObjet or {}) do
    if not vus[nom] then vus[nom] = true liste[#liste + 1] = nom end
  end
  for _, nom in ipairs(catalogueConnu) do
    if not vus[nom] then vus[nom] = true liste[#liste + 1] = nom end
  end
  table.sort(liste)
  return liste
end

local function prixExemple(nomObjet, quantite)
  local articles = { { nom = nomObjet, quantite = quantite } }
  local lent = Protocole.calculerPaiement(articles, Protocole.VITESSES.LENT, grille.tarif)
  local rapide = Protocole.calculerPaiement(articles, Protocole.VITESSES.RAPIDE, grille.tarif)
  return lent, rapide
end

local function menuPrixParObjet()
  local page, parPage, filtre = 1, 10, nil
  while true do
    local tous = objetsTarifables()
    local liste = {}
    for _, nom in ipairs(tous) do
      if not filtre or nom:lower():find(filtre:lower(), 1, true) then
        liste[#liste + 1] = nom
      end
    end

    entete("PRIX PAR OBJET (par unite transportee)")
    if #liste == 0 then
      print("Aucun objet connu. Les navires alimentent cette liste en")
      print("diffusant le catalogue de leur stockage source.")
      print("Vous pouvez aussi ajouter un identifiant a la main.")
    else
      local debut = (page - 1) * parPage + 1
      local fin = math.min(#liste, debut + parPage - 1)
      for i = debut, fin do
        local nom = liste[i]
        local propre = (grille.tarif.parObjet or {})[nom]
        couleur(propre and colors.white or colors.lightGray)
        print(("%2d. %-34s %s"):format(i, nom:sub(1, 34),
          propre and ("%.4f"):format(propre)
                 or ("defaut " .. tostring(grille.tarif.prixUnitaireDefaut))))
      end
      couleur(colors.lightGray)
      print(("Page %d / %d"):format(page, math.max(1, math.ceil(#liste / parPage))))
      couleur(colors.white)
    end

    print("")
    print("[numero] fixer  [a]jouter un objet  [s]uivant  [p]recedent")
    print("[c]hercher  [q]uitter")
    local choix = saisir("> ", "q")

    if choix == "q" or choix == nil then return end
    if choix == "s" then
      if page * parPage < #liste then page = page + 1 end
    elseif choix == "p" then
      if page > 1 then page = page - 1 end
    elseif choix == "c" then
      filtre = saisir("Filtre (vide = tout) : ", "")
      if filtre == "" then filtre = nil end
      page = 1
    elseif choix == "a" then
      local nom = saisir("Identifiant de l'objet (ex. minecraft:iron_ingot) : ", "")
      if nom and nom ~= "" then
        catalogueConnu[#catalogueConnu + 1] = nom
        table.sort(catalogueConnu)
      end
    else
      local index = tonumber(choix)
      local nom = index and liste[index]
      if not nom then
        print("Numero inconnu.")
        pause()
      else
        local actuel = (grille.tarif.parObjet or {})[nom]
        print("")
        print(nom)
        print(("Prix unitaire actuel : %s"):format(
          actuel and ("%.4f"):format(actuel)
                 or ("defaut " .. tostring(grille.tarif.prixUnitaireDefaut))))
        local lent, rapide = prixExemple(nom, 1000)
        print(("Pour 1000 unites : slow %d %s | fast %d %s"):format(
          lent.quantite, lent.objet, rapide.quantite, rapide.objet))
        print("")
        local saisie = saisir("Nouveau prix unitaire ('-' pour revenir au defaut) : ", "")
        if saisie == "-" then
          grille.tarif.parObjet[nom] = nil
          publier("prix propre retire pour " .. nom)
          diffuser("modification")
        else
          local valeur = tonumber(saisie)
          if not valeur or valeur < 0 then
            print("Valeur refusee : nombre positif attendu.")
            pause()
          else
            grille.tarif.parObjet = grille.tarif.parObjet or {}
            grille.tarif.parObjet[nom] = valeur
            publier(("prix de %s -> %.4f"):format(nom, valeur))
            diffuser("modification")
            local l, r = prixExemple(nom, 1000)
            print(("Enregistre. 1000 unites : slow %d | fast %d"):format(
              l.quantite, r.quantite))
            pause()
          end
        end
      end
    end
  end
end

local function menuReglagesGeneraux()
  local champs = {
    { cle = "objetPaiement",      libelle = "Objet de paiement",        type = "texte" },
    { cle = "forfaitBase",        libelle = "Forfait de base",          type = "nombre" },
    { cle = "prixUnitaireDefaut", libelle = "Prix unitaire par defaut", type = "nombre" },
    { cle = "prixMinimum",        libelle = "Prix minimum",             type = "nombre" },
    { cle = "prixMaximum",        libelle = "Prix maximum",             type = "nombre" },
  }
  while true do
    entete("REGLAGES GENERAUX")
    for i, champ in ipairs(champs) do
      print(("%d. %-24s %s"):format(i, champ.libelle, tostring(grille.tarif[champ.cle])))
    end
    local coefficients = grille.tarif.coefficientVitesse or {}
    print(("6. %-24s %s"):format("Coefficient fast ship", tostring(coefficients.fast)))
    print(("7. %-24s %s"):format("Coefficient slow ship", tostring(coefficients.slow)))
    print("")
    local lent, rapide = prixExemple("minecraft:iron_ingot", 1000)
    couleur(colors.lightGray)
    print(("Exemple - 1000 lingots de fer : slow %d %s | fast %d %s")
      :format(lent.quantite, lent.objet, rapide.quantite, rapide.objet))
    couleur(colors.white)
    print("")
    local choix = tonumber(saisir("[numero] modifier  [Entree] quitter : ", ""))
    if not choix then return end

    if choix >= 1 and choix <= #champs then
      local champ = champs[choix]
      local saisie = saisir(champ.libelle .. " : ", tostring(grille.tarif[champ.cle]))
      if champ.type == "nombre" then
        local valeur = tonumber(saisie)
        if not valeur then
          print("Nombre attendu.")
          pause()
        else
          grille.tarif[champ.cle] = valeur
          publier(champ.libelle .. " -> " .. tostring(valeur))
          diffuser("modification")
        end
      elseif saisie and saisie ~= "" then
        grille.tarif[champ.cle] = saisie
        publier(champ.libelle .. " -> " .. saisie)
        diffuser("modification")
      end
    elseif choix == 6 or choix == 7 then
      local cle = (choix == 6) and "fast" or "slow"
      local valeur = tonumber(saisir("Coefficient " .. cle .. " : ",
        tostring(coefficients[cle])))
      if not valeur or valeur <= 0 then
        print("Nombre strictement positif attendu.")
        pause()
      else
        grille.tarif.coefficientVitesse = grille.tarif.coefficientVitesse or {}
        grille.tarif.coefficientVitesse[cle] = valeur
        publier("coefficient " .. cle .. " -> " .. tostring(valeur))
        diffuser("modification")
      end
    end
  end
end

local function menuPenalites()
  while true do
    local p = grille.penalites or {}
    entete("PENALITES")
    print("Appliquees par les navires au client qui laisse repartir une")
    print("livraison sans l'avoir payee.")
    print("")
    print(("1. Mode                      %s"):format(tostring(p.mode)))
    print(("2. Duree (secondes)          %s"):format(tostring(p.duree)))
    print(("3. Incidents avant penalite  %s"):format(tostring(p.incidentsAvantPenalite)))
    print(("4. Oubli d'un incident (s)   %s"):format(tostring(p.effacerApres)))
    print("")
    couleur(colors.lightGray)
    print("prepaiement : ses commandes exigent un paiement a la borne")
    print("refus       : ses commandes sont refusees jusqu'a expiration")
    couleur(colors.white)
    print("")
    local choix = tonumber(saisir("[numero] modifier  [Entree] quitter : ", ""))
    if not choix then return end

    grille.penalites = grille.penalites or {}
    if choix == 1 then
      grille.penalites.mode = (p.mode == Protocole.MODES_PENALITE.PREPAIEMENT)
        and Protocole.MODES_PENALITE.REFUS or Protocole.MODES_PENALITE.PREPAIEMENT
      publier("mode de penalite -> " .. grille.penalites.mode)
      diffuser("modification")
    elseif choix >= 2 and choix <= 4 then
      local cles = { [2] = "duree", [3] = "incidentsAvantPenalite", [4] = "effacerApres" }
      local valeur = tonumber(saisir("Nouvelle valeur : ", tostring(p[cles[choix]])))
      if not valeur or valeur < 0 then
        print("Nombre positif attendu.")
        pause()
      else
        grille.penalites[cles[choix]] = valeur
        publier(cles[choix] .. " -> " .. tostring(valeur))
        diffuser("modification")
      end
    end
  end
end

local function menuPrincipal()
  while true do
    entete(nil)
    print("[1] Prix par objet")
    print("[2] Reglages generaux")
    print("[3] Penalites")
    print("[4] Diffuser la grille maintenant")
    print("[5] Changer le code d'acces")
    print("[V] Verrouiller")
    print("")
    local choix = saisir("> ", "")
    deverrouilleJusqua = os.clock() + (config.serrure.inactiviteSecondes or 120)

    if choix == "1" then
      journal.proteger(ETAPES.MODIFICATION, menuPrixParObjet)
    elseif choix == "2" then
      journal.proteger(ETAPES.MODIFICATION, menuReglagesGeneraux)
    elseif choix == "3" then
      journal.proteger(ETAPES.MODIFICATION, menuPenalites)
    elseif choix == "4" then
      diffuser("demande manuelle")
      print("Grille n" .. grille.sequence .. " diffusee.")
      pause()
    elseif choix == "5" then
      journal.proteger(ETAPES.SERRURE, changerCode)
    elseif choix == "v" or choix == "V" then
      log("info", ETAPES.SERRURE, "verrouillage manuel")
      return
    end
  end
end

local function cycleMenu()
  while true do
    if deverrouiller() then
      menuPrincipal()
    end
    entete("VERROUILLE")
    couleur(colors.lightGray)
    print("Le central continue de diffuser la grille.")
    print("Appuyez sur une touche pour saisir le code.")
    couleur(colors.white)
    os.pullEvent("key")
  end
end

--------------------------------------------------------------------------------
-- Cycle complet et superviseur
--------------------------------------------------------------------------------

local function cyclePrincipal()
  config = charger(CHEMIN_CONFIG)
  if type(config) ~= "table" then error("config_central.lua doit retourner une table", 0) end
  config.serrure    = config.serrure or {}
  config.journal    = config.journal or {}
  config.robustesse = config.robustesse or {}

  local Journal = charger(fs.combine(RACINE, "commun/journal.lua"))
  journal = Journal.creer({
    chemin      = versRacine(config.journal.fichier or "central/central.log"),
    tailleMax   = config.journal.tailleMax,
    niveauEcran = config.journal.niveauEcran or "AVERT",
  })
  log("info", ETAPES.DEMARRAGE, "centrale tarifaire FrenchNet v%s (%s)",
    VERSION_PROGRAMME, tostring(config.identifiant))

  Protocole = charger(fs.combine(RACINE, "commun/protocole.lua"))
  log("info", ETAPES.CHARGEMENT_MODULES, "modules communs charges")

  if config.jeton == nil or config.jeton == "" then
    log("critique", ETAPES.CHARGEMENT_CONFIG,
      "aucun jeton partage : la grille sera diffusee SANS signature")
  elseif config.jeton:find("CHANGEZ-MOI", 1, true) then
    log("avert", ETAPES.CHARGEMENT_CONFIG,
      "le jeton partage est encore celui de l'exemple : changez-le sur TOUS"
      .. " les ordinateurs du reseau")
  end

  chargerGrille()
  ouvrirReseau()
  diffuser("demarrage")

  parallel.waitForAny(cycleServeur, cycleDiffusion, cycleMenu)
end

local function superviser()
  local redemarrages = 0
  while true do
    if fs.exists(MARQUEUR_ARRET) then
      print("[ARRET] marqueur '.arret_manuel' present : supprimez-le pour relancer.")
      return
    end

    local ok, erreur = xpcall(cyclePrincipal, function(err)
      if debug and debug.traceback then return debug.traceback(tostring(err), 2) end
      return tostring(err)
    end)
    if ok then erreur = "la boucle du central s'est terminee" end

    if tostring(erreur):find("Terminated", 1, true) then
      local f = fs.open(MARQUEUR_ARRET, "w")
      if f then f.write("arret manuel") f.close() end
      print("[ARRET] interruption clavier.")
      return
    end

    redemarrages = redemarrages + 1
    local etapeCourante = journal and journal.etapeCourante or ETAPES.DEMARRAGE
    if journal then
      log("critique", etapeCourante, "plantage a l'etape '%s' : %s",
        tostring(etapeCourante), tostring(erreur))
    else
      print("[CRITIQUE] [etape: " .. tostring(etapeCourante) .. "] " .. tostring(erreur))
    end

    if coteModem then pcall(rednet.close, coteModem) end
    coteModem = nil

    local minimum = (config and config.robustesse.redemarrageDelaiMin) or 3
    local maximum = (config and config.robustesse.redemarrageDelaiMax) or 30
    local delai = math.min(maximum, minimum * (2 ^ math.min(redemarrages - 1, 8)))
    print(("[AVERT] relance automatique n%d dans %d s"):format(redemarrages, delai))

    journal = nil
    os.sleep(delai)
  end
end

superviser()
