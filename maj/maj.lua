--[[----------------------------------------------------------------------------
  FRENCHNET - MISE A JOUR AUTOMATIQUE
  Bibliotheque de mise a jour, commune a tous les postes.

  CE QU'IL FAUT SAVOIR AVANT DE L'ACTIVER
  Un systeme de mise a jour automatique est un canal d'EXECUTION DE CODE A
  DISTANCE vers chaque ordinateur du serveur. Quiconque controle la source
  controle le poste de commandement. Ce module ne pretend pas resoudre cela :
  il n'y a ni signature ni chiffrement, parce que CC: Tweaked n'offre aucune
  primitive cryptographique digne de ce nom. La somme de controle ci-dessous
  detecte un telechargement TRONQUE, pas un attaquant.

  Ce qu'il protege reellement, et qui est le risque le plus probable :
    1. VERIFICATION AVANT INSTALLATION - un fichier telecharge est compile
       avant d'etre ecrit. Du Lua invalide n'atteint jamais le disque.
    2. TOUT OU RIEN - les fichiers sont prepares a cote, puis bascules d'un
       bloc. Une coupure en plein vol laisse l'ancienne version intacte.
    3. SAUVEGARDE ET RETOUR ARRIERE - la version precedente est conservee, et
       restauree automatiquement si la nouvelle ne se charge pas.
    4. JAMAIS PENDANT UN ENGAGEMENT - un poste occupe repousse la bascule.
       Redemarrer un poste de defense au moment ou il conduit un tir est la
       seule facon de transformer une mise a jour en perte de materiel.

  'env' est injectable (fs, http, load, horloge) : ce module est testable hors
  du jeu, et c'est indispensable - un bug ici casse TOUS les postes a la fois.
--------------------------------------------------------------------------------]]

local maj = { VERSION = "1.0.0" }

--------------------------------------------------------------------------------
-- 1. SOMME DE CONTROLE
--    Adler-32, en arithmetique pure : ni bit32 (absent de Lua 5.4) ni
--    operateurs binaires (absents du Lua de CC). Le meme calcul doit donner le
--    meme resultat dans le jeu et sur le banc d'essai, sinon le manifeste
--    genere ici serait rejete la-bas.
--------------------------------------------------------------------------------

local PAQUET = 1024

function maj.somme(texte, respirer)
  if type(texte) ~= "string" then return nil end
  local a, b = 1, 0
  local n = #texte
  local i = 1
  while i <= n do
    local fin = math.min(i + PAQUET - 1, n)
    local octets = { string.byte(texte, i, fin) }
    for k = 1, #octets do
      a = (a + octets[k]) % 65521
      b = (b + a) % 65521
    end
    i = fin + 1
    -- CC coupe un programme qui calcule trop longtemps sans rendre la main.
    if respirer then respirer() end
  end
  return b * 65536 + a
end

--------------------------------------------------------------------------------
-- 2. VERSIONS
--------------------------------------------------------------------------------

function maj.analyserVersion(texte)
  if type(texte) ~= "string" then return nil end
  local a, b, c = texte:match("^(%d+)%.(%d+)%.(%d+)")
  if not a then return nil end
  return { tonumber(a), tonumber(b), tonumber(c) }
end

-- -1 si a < b, 0 si egales, 1 si a > b. nil si l'une est illisible.
function maj.comparerVersions(a, b)
  local va, vb = maj.analyserVersion(a), maj.analyserVersion(b)
  if not (va and vb) then return nil end
  for i = 1, 3 do
    if va[i] ~= vb[i] then return va[i] < vb[i] and -1 or 1 end
  end
  return 0
end

--------------------------------------------------------------------------------
-- 3. CONSTRUCTION
--------------------------------------------------------------------------------

function maj.nouveau(config, env, journal)
  env = env or {}
  return setmetatable({
    config  = config or {},
    fs      = env.fs or fs,
    http    = env.http,            -- nil = pas de transport HTTP, et c'est dit
    load    = env.load or load,
    horloge = env.horloge or function() return 0 end,
    respirer = env.respirer,
    reseau  = env.reseau,          -- transport rednet, pour les serveurs sans HTTP
    journal = journal or function() end,
    telecharges = 0, echecs = 0, appliques = 0,
  }, { __index = maj })
end

local function chemin(...)
  local morceaux = {}
  for _, m in ipairs({ ... }) do
    m = tostring(m):gsub("^/+", ""):gsub("/+$", "")
    if m ~= "" then morceaux[#morceaux + 1] = m end
  end
  return "/" .. table.concat(morceaux, "/")
end
maj.chemin = chemin

function maj:dossierPrepare() return self.config.dossierPrepare or "/.maj/prepare" end
function maj:dossierSauvegarde() return self.config.dossierSauvegarde or "/.maj/sauvegarde" end
function maj:fichierEtat() return self.config.fichierEtat or "/.maj/etat.dat" end

--------------------------------------------------------------------------------
-- 4. OCCUPATION
--    Un poste en cours d'engagement ecrit periodiquement son occupation. La
--    mise a jour la lit AVANT de basculer.
--
--    L'horodatage n'est pas decoratif : un poste qui a plante laisserait sinon
--    un verrou eternel, et bloquerait precisement la mise a jour qui repare.
--    Passe le delai, le verrou est ignore - un poste muet n'est pas occupe,
--    il est mort.
--------------------------------------------------------------------------------

function maj:declarerOccupation(cheminFichier, occupe, motif)
  local f = self.fs.open(cheminFichier or self.config.fichierOccupation, "w")
  if not f then return false end
  f.write(("{ instant = %d, occupe = %s, motif = %q }")
    :format(math.floor(self.horloge()), occupe and "true" or "false", tostring(motif or "")))
  f.close()
  return true
end

-- Retourne : occupe (booleen), motif.
function maj:occupation()
  local cheminFichier = self.config.fichierOccupation
  if not cheminFichier or not self.fs.exists(cheminFichier) then
    return false, "aucun verrou d'occupation"
  end
  local f = self.fs.open(cheminFichier, "r")
  if not f then return false, "verrou illisible" end
  local texte = f.readAll() or ""
  f.close()

  local charge = self.load("return " .. texte, "occupation", "t", {})
  local ok, donnees = pcall(charge)
  if not (ok and type(donnees) == "table") then return false, "verrou illisible" end

  local age = self.horloge() - (tonumber(donnees.instant) or 0)
  local peremption = self.config.occupationPeremption or 30
  if age > peremption then
    return false, ("verrou perime (%.0fs) : le poste ne repond plus"):format(age)
  end
  if donnees.occupe then
    return true, tostring(donnees.motif or "poste occupe")
  end
  return false, "poste disponible"
end

--------------------------------------------------------------------------------
-- 5. MANIFESTE
--------------------------------------------------------------------------------

--[[
  Le manifeste est une table Lua, lue dans un environnement VIDE : elle ne peut
  donc appeler ni fs, ni http, ni os. C'est la difference entre lire une
  donnee et executer un programme, et elle compte - le manifeste vient du
  reseau.
]]
function maj:analyserManifeste(texte)
  if type(texte) ~= "string" or texte == "" then return nil, "manifeste vide" end
  local charge, err = self.load(texte, "manifeste", "t", {})
  if not charge then return nil, "manifeste illisible : " .. tostring(err) end
  local ok, donnees = pcall(charge)
  if not ok or type(donnees) ~= "table" then
    return nil, "manifeste invalide : " .. tostring(donnees)
  end
  if not maj.analyserVersion(donnees.version) then
    return nil, "manifeste sans version exploitable"
  end
  if type(donnees.postes) ~= "table" then return nil, "manifeste sans postes" end
  return donnees
end

function maj:urlDe(cheminDepot)
  local base = self.config.urlBase
  if type(base) ~= "string" or base == "" then return nil end
  return base:gsub("/+$", "") .. "/" .. tostring(cheminDepot):gsub("^/+", "")
end

--[[
  Recuperation d'un fichier du depot. Retourne : contenu, motif.
  Deux transports, et le module dit toujours lequel il a pris :
    HTTP   - depuis le depot, si l'administrateur du serveur l'autorise ;
    RESEAU - depuis un poste de distribution, quand HTTP est coupe.
  Aucun des deux ne rend un contenu partiel sans le dire.
]]
function maj:recuperer(cheminDepot)
  if self.http then
    local url = self:urlDe(cheminDepot)
    if not url then return nil, "urlBase non configuree" end
    local ok, reponse = pcall(self.http.get, url)
    if ok and reponse then
      local corps = reponse.readAll and reponse.readAll() or nil
      if reponse.close then pcall(reponse.close) end
      if type(corps) == "string" and corps ~= "" then
        self.telecharges = self.telecharges + 1
        return corps, "HTTP"
      end
      self.echecs = self.echecs + 1
      return nil, "reponse vide de " .. url
    end
    self.echecs = self.echecs + 1
    if not self.reseau then
      return nil, ("HTTP a echoue sur %s : %s"):format(url, tostring(reponse))
    end
    -- On ne s'arrete pas la : le repli reseau existe justement pour cela.
  end

  if self.reseau then
    local corps, motif = self.reseau(cheminDepot)
    if type(corps) == "string" and corps ~= "" then
      self.telecharges = self.telecharges + 1
      return corps, "RESEAU"
    end
    self.echecs = self.echecs + 1
    return nil, motif or "le poste de distribution n'a rien rendu"
  end

  return nil, "aucun transport : ni HTTP autorise sur ce serveur, ni poste de distribution"
end

--------------------------------------------------------------------------------
-- 6. PLAN
--------------------------------------------------------------------------------

function maj:sommeLocale(cheminLocal)
  if not self.fs.exists(cheminLocal) then return nil end
  local f = self.fs.open(cheminLocal, "r")
  if not f then return nil end
  local texte = f.readAll() or ""
  f.close()
  return maj.somme(texte, self.respirer), texte
end

--[[
  Que faut-il changer ?
  On compare les SOMMES, pas les dates : l'horloge d'un ordinateur CC n'a
  aucune valeur, et un fichier edite a la main a bord doit etre vu comme
  different meme s'il est "plus recent".

  Retourne : plan (liste), identiques, motif si le poste est inconnu.
]]
function maj:planifier(manifeste, poste)
  local description = manifeste.postes[poste]
  if type(description) ~= "table" or type(description.fichiers) ~= "table" then
    return nil, nil, ("le manifeste ne decrit aucun poste '%s'"):format(tostring(poste))
  end

  local plan, identiques = {}, 0
  for _, fichier in ipairs(description.fichiers) do
    local cible = fichier.cible or chemin(fichier.chemin)
    local locale = self:sommeLocale(cible)

    --[[
      'siAbsent' : fichier installe UNE SEULE FOIS, jamais ecrase.
      C'est la regle des fichiers de configuration, et elle n'est pas
      negociable : ils contiennent les zones du theatre, les codes
      transpondeur et le mot de passe de la console. Une mise a jour qui les
      remplacerait par les valeurs d'usine desarmerait la defense et
      rouvrirait la console a tout le monde, en silence, a chaque version.
    ]]
    if fichier.siAbsent and locale ~= nil then
      identiques = identiques + 1
    elseif locale and fichier.somme and locale == fichier.somme then
      identiques = identiques + 1
    else
      plan[#plan + 1] = {
        depot = fichier.chemin, cible = cible,
        somme = fichier.somme, taille = fichier.taille,
        nouveau = locale == nil,
      }
    end
  end
  return plan, identiques
end

--------------------------------------------------------------------------------
-- 7. PREPARATION
--    Tout est telecharge et verifie A COTE. Rien n'est ecrit a sa place
--    definitive tant que le lot entier n'est pas sain : une coupure reseau au
--    milieu laisserait sinon un poste avec la moitie d'une version et l'autre
--    moitie d'une autre, ce qui est pire que les deux.
--------------------------------------------------------------------------------

local function ecrire(self, cheminFichier, contenu)
  local dossier = self.fs.getDir and self.fs.getDir(cheminFichier)
  if dossier and dossier ~= "" and not self.fs.exists(dossier) then
    pcall(self.fs.makeDir, dossier)
  end
  local f = self.fs.open(cheminFichier, "w")
  if not f then return false end
  f.write(contenu)
  f.close()
  return true
end
maj.ecrire = ecrire

-- Retourne : prets (liste), motif d'echec.
function maj:preparer(plan)
  if #plan == 0 then return {}, nil end
  pcall(self.fs.delete, self:dossierPrepare())

  local prets = {}
  for _, entree in ipairs(plan) do
    local contenu, transport = self:recuperer(entree.depot)
    if not contenu then
      return nil, ("%s : %s"):format(entree.depot, tostring(transport))
    end

    -- Somme : detecte un telechargement tronque. Ce n'est PAS une signature,
    -- et ce module ne pretend pas le contraire.
    if entree.somme then
      local obtenue = maj.somme(contenu, self.respirer)
      if obtenue ~= entree.somme then
        return nil, ("%s : somme de controle incorrecte (%s attendu, %s recu) - " ..
          "telechargement tronque ou manifeste perime")
          :format(entree.depot, tostring(entree.somme), tostring(obtenue))
      end
    end

    --[[
      LE CONTROLE QUI SERT VRAIMENT : on COMPILE avant d'ecrire. Un fichier
      Lua invalide - commit casse, reponse HTML d'un proxy, coupure - n'atteint
      jamais le disque du poste. C'est la panne la plus probable de toutes, et
      celle qui laisserait un poste de defense mort dans un chunk force.
    ]]
    if entree.cible:match("%.lua$") then
      local ok, err = self.load(contenu, entree.depot, "t", {})
      if not ok then
        return nil, ("%s : Lua invalide, installation refusee (%s)")
          :format(entree.depot, tostring(err))
      end
    end

    local provisoire = chemin(self:dossierPrepare(), entree.cible)
    if not ecrire(self, provisoire, contenu) then
      return nil, ("impossible d'ecrire %s : disque plein ?"):format(provisoire)
    end
    prets[#prets + 1] = { cible = entree.cible, provisoire = provisoire,
                          depot = entree.depot, transport = transport }
  end

  self.journal("INFO", "maj", ("%d fichier(s) prepares et verifies"):format(#prets))
  return prets
end

--------------------------------------------------------------------------------
-- 8. BASCULE ET RETOUR ARRIERE
--------------------------------------------------------------------------------

--[[
  Bascule. Sauvegarde d'abord, ecriture ensuite, verification apres.
  Si un seul fichier ne se recharge pas, TOUT est restaure : une version a
  moitie installee est le seul etat dont on ne sait pas sortir a distance.
  Retourne : nombre applique, motif d'echec.
]]
function maj:appliquer(prets)
  if #prets == 0 then return 0 end
  local sauvegarde = self:dossierSauvegarde()
  pcall(self.fs.delete, sauvegarde)

  local poses = {}
  for _, entree in ipairs(prets) do
    -- Sauvegarde de l'existant. Un fichier neuf n'a rien a sauvegarder : on
    -- le note, pour savoir qu'un retour arriere doit le SUPPRIMER.
    if self.fs.exists(entree.cible) then
      local f = self.fs.open(entree.cible, "r")
      local avant = f and f.readAll() or nil
      if f then f.close() end
      if avant then ecrire(self, chemin(sauvegarde, entree.cible), avant) end
      entree.existait = true
    else
      entree.existait = false
    end

    local f = self.fs.open(entree.provisoire, "r")
    local contenu = f and f.readAll() or nil
    if f then f.close() end
    if not contenu then
      self:restaurer(poses)
      return nil, ("fichier prepare disparu : %s"):format(entree.provisoire)
    end
    if not ecrire(self, entree.cible, contenu) then
      self:restaurer(poses)
      return nil, ("ecriture impossible : %s"):format(entree.cible)
    end
    poses[#poses + 1] = entree
  end

  -- Verification apres coup : on relit ce qui est REELLEMENT sur le disque.
  -- Verifier le contenu telecharge ne prouverait rien sur ce qui a ete ecrit.
  for _, entree in ipairs(poses) do
    if entree.cible:match("%.lua$") then
      local f = self.fs.open(entree.cible, "r")
      local relu = f and f.readAll() or ""
      if f then f.close() end
      if not self.load(relu, entree.cible, "t", {}) then
        self:restaurer(poses)
        return nil, ("%s ne se recharge pas apres ecriture : version precedente restauree")
          :format(entree.cible)
      end
    end
  end

  self.appliques = self.appliques + #poses
  pcall(self.fs.delete, self:dossierPrepare())
  self.journal("INFO", "maj", ("%d fichier(s) installes"):format(#poses))
  return #poses
end

-- Retour arriere. 'poses' limite la restauration aux fichiers deja touches ;
-- sans argument, on restaure tout ce que la sauvegarde contient.
function maj:restaurer(poses)
  local sauvegarde = self:dossierSauvegarde()
  local rendus, supprimes = 0, 0

  if poses then
    for _, entree in ipairs(poses) do
      if entree.existait then
        local f = self.fs.open(chemin(sauvegarde, entree.cible), "r")
        local avant = f and f.readAll() or nil
        if f then f.close() end
        if avant and ecrire(self, entree.cible, avant) then rendus = rendus + 1 end
      else
        -- Fichier qui n'existait pas avant : le retour arriere l'efface, sans
        -- quoi le poste garderait un morceau de la version refusee.
        if pcall(self.fs.delete, entree.cible) then supprimes = supprimes + 1 end
      end
    end
  elseif self.fs.exists(sauvegarde) then
    local function parcourir(dossier, prefixe)
      for _, nom in ipairs(self.fs.list(dossier) or {}) do
        local complet = chemin(dossier, nom)
        if self.fs.isDir(complet) then
          parcourir(complet, chemin(prefixe, nom))
        else
          local f = self.fs.open(complet, "r")
          local avant = f and f.readAll() or nil
          if f then f.close() end
          if avant and ecrire(self, chemin(prefixe, nom), avant) then rendus = rendus + 1 end
        end
      end
    end
    parcourir(sauvegarde, "/")
  end

  if rendus + supprimes > 0 then
    self.journal("AVERT", "maj",
      ("retour arriere : %d fichier(s) restaures, %d supprimes"):format(rendus, supprimes))
  end
  return rendus, supprimes
end

--------------------------------------------------------------------------------
-- 9. ETAT PERSISTANT
--------------------------------------------------------------------------------

function maj:lireEtat()
  local cheminFichier = self:fichierEtat()
  if not self.fs.exists(cheminFichier) then return {} end
  local f = self.fs.open(cheminFichier, "r")
  if not f then return {} end
  local texte = f.readAll() or ""
  f.close()
  local charge = self.load("return " .. texte, "etat", "t", {})
  local ok, donnees = pcall(charge)
  return (ok and type(donnees) == "table") and donnees or {}
end

function maj:ecrireEtat(donnees)
  local morceaux = {}
  for cle, valeur in pairs(donnees) do
    local rendu
    if type(valeur) == "string" then rendu = ("%q"):format(valeur)
    elseif type(valeur) == "number" or type(valeur) == "boolean" then rendu = tostring(valeur) end
    if rendu then morceaux[#morceaux + 1] = ("  %s = %s"):format(cle, rendu) end
  end
  return ecrire(self, self:fichierEtat(), "{\n" .. table.concat(morceaux, ",\n") .. ",\n}")
end

--------------------------------------------------------------------------------
-- 10. CYCLE COMPLET
--------------------------------------------------------------------------------

maj.RESULTATS = {
  A_JOUR = "A_JOUR", INSTALLE = "INSTALLE", REPORTE = "REPORTE",
  ECHEC = "ECHEC", PREPARE = "PREPARE",
}

--[[
  Le cycle entier, en un appel.
    poste   : cle du manifeste ("command", "radar", "vaisseau"...)
    options = {
      forcer            = ignore le verrou d'occupation. Geste d'OPERATEUR :
                          un automate ne doit jamais pouvoir couper un poste
                          en plein engagement, un humain devant l'ecran si.
      preparerSeulement = telecharge et verifie, ne bascule pas. C'est le mode
                          d'un poste qui commande des armes : preparer
                          n'engage rien, et le jour ou l'operateur dit oui,
                          l'installation est instantanee et hors ligne - meme
                          si le depot est injoignable a ce moment-la.
    }
  Retourne : resultat, detail, plan.
]]
function maj:cycle(poste, options)
  options = options or {}
  local texte, transport = self:recuperer(self.config.cheminManifeste or "manifeste.lua")
  if not texte then return maj.RESULTATS.ECHEC, "manifeste : " .. tostring(transport) end

  local manifeste, err = self:analyserManifeste(texte)
  if not manifeste then return maj.RESULTATS.ECHEC, err end

  local plan, identiques, motif = self:planifier(manifeste, poste)
  if not plan then return maj.RESULTATS.ECHEC, motif end
  if #plan == 0 then
    return maj.RESULTATS.A_JOUR,
      ("a jour en version %s, %d fichier(s) verifies"):format(manifeste.version, identiques)
  end

  --[[
    GARDE ANTI-BOUCLE DE REDEMARRAGE.
    Si l'etat dit que cette version EST DEJA installee, et que le plan trouve
    pourtant des fichiers a changer, c'est qu'une somme ne se stabilise
    jamais - manifeste perime, fichier reecrit par autre chose, transport qui
    tronque. Installer a nouveau puis redemarrer recommencerait indefiniment.

    Sur un ordinateur dans un chunk force a l'autre bout de la carte, une
    boucle de redemarrage est pire que l'absence de mise a jour : le poste ne
    defend plus rien et il faut aller le chercher a pied.
  ]]
  local etatPrecedent = self:lireEtat()
  if etatPrecedent.version == manifeste.version then
    local noms = {}
    for _, e in ipairs(plan) do noms[#noms + 1] = e.cible end
    self.journal("ERREUR", "maj", ("version %s deja installee, et pourtant %d fichier(s) " ..
      "different(s) : %s. Installation SUSPENDUE pour ne pas boucler au redemarrage. " ..
      "Regenerez le manifeste ou lancez 'update appliquer'.")
      :format(manifeste.version, #plan, table.concat(noms, ", ")))
    if not options.forcer then
      return maj.RESULTATS.ECHEC,
        ("boucle de mise a jour evitee sur la version %s"):format(manifeste.version), plan
    end
  end

  self.journal("INFO", "maj", ("version %s disponible : %d fichier(s) a installer (%s)")
    :format(manifeste.version, #plan, transport))

  local prets, echec = self:preparer(plan)
  if not prets then return maj.RESULTATS.ECHEC, echec, plan end

  --[[
    Le verrou est consulte APRES la preparation, pas avant : telecharger ne
    derange personne, basculer si. Un poste occupe garde donc sa mise a jour
    toute prete, et l'installera au premier moment calme - typiquement au
    prochain demarrage, quand rien n'est engage par construction.
  ]]
  if options.preparerSeulement then
    self:ecrireEtat({ prepare = manifeste.version, instant = math.floor(self.horloge()) })
    return maj.RESULTATS.PREPARE,
      ("version %s prete : %d fichier(s) verifies, en attente de 'update appliquer'")
        :format(manifeste.version, #prets), plan
  end

  if not options.forcer then
    local occupe, raison = self:occupation()
    if occupe then
      self:ecrireEtat({ prepare = manifeste.version, instant = math.floor(self.horloge()) })
      self.journal("AVERT", "maj", ("bascule REPORTEE : %s. La version %s est prete " ..
        "et sera installee au prochain demarrage."):format(raison, manifeste.version))
      return maj.RESULTATS.REPORTE, raison, plan
    end
  end

  local poses, echecBascule = self:appliquer(prets)
  if not poses then return maj.RESULTATS.ECHEC, echecBascule, plan end

  -- 'poses' est un NOMBRE rendu par appliquer(), pas une liste : en prendre la
  -- longueur levait une erreur au moment precis ou tout avait reussi.
  self:ecrireEtat({ version = manifeste.version, instant = math.floor(self.horloge()),
                    fichiers = poses })
  return maj.RESULTATS.INSTALLE,
    ("version %s : %d fichier(s) installes, %d inchanges")
      :format(manifeste.version, poses, identiques), plan
end

return maj
