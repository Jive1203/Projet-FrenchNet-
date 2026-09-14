--[[----------------------------------------------------------------------------
  FRENCHNET / LIVRAISON - Manipulation d'inventaires (CC: Tweaked)
  --------------------------------------------------------------------------
  Toute la manutention repose sur les deux fonctions officielles de l'API
  "inventory" de CC: Tweaked :

      inventaire.pushItems(nomCible, emplacementSource, [limite], [emplacementCible])
      inventaire.pullItems(nomSource, emplacementSource, [limite], [emplacementCible])

  Points de la documentation officielle qui dictent la forme du code ci-dessous :

  1. Les deux fonctions retournent le NOMBRE d'objets reellement transferes.
     Ce nombre peut etre inferieur a la limite demandee (cible pleine, pile
     maximale atteinte, filtre du conteneur). On boucle donc toujours jusqu'a
     obtenir le compte voulu, et on s'arrete des qu'un appel renvoie 0.
  2. 'limite' est plafonnee par la taille de pile de l'objet : un seul appel ne
     deplace jamais plus d'une pile. Pour un bulk container du mod Create qui
     contient plusieurs dizaines de milliers d'objets, il faut donc des
     centaines d'appels : la boucle cede la main regulierement (os.sleep(0))
     pour ne jamais declencher "Too long without yielding".
  3. Le nom passe en premier argument est le NOM RESEAU du peripherique
     (celui rendu par peripheral.getName), pas un cote ni un objet enveloppe.
     Les deux inventaires doivent etre sur le MEME reseau de modems filaires.
  4. list() renvoie une table creuse indexee par emplacement : il faut la
     parcourir avec pairs() et non ipairs(), sous peine de manquer des
     emplacements apres un trou.

  La logique de prelevement (lire le contenu, filtrer par nom d'objet, ne
  deplacer que la quantite demandee sans toucher au reste du stock) suit la
  meme structure que celle presentee dans les tutoriels d'inventaire
  ComputerCraft : lister -> filtrer -> transferer par lots -> verifier.
--------------------------------------------------------------------------------]]

local M = {}

M.PAUSE_TOUS_LES = 24   -- nombre d'appels avant de rendre la main au systeme
M.MAX_ITERATIONS = 20000 -- garde-fou absolu contre une boucle infinie

--------------------------------------------------------------------------------
-- Enveloppe un inventaire et verifie qu'il expose bien l'API attendue.
--------------------------------------------------------------------------------
function M.envelopper(nom)
  if type(nom) ~= "string" or nom == "" then
    return nil, "nom de peripherique vide"
  end
  local ok, p = pcall(peripheral.wrap, nom)
  if not ok or not p then
    return nil, ("peripherique '%s' introuvable"):format(nom)
  end
  if type(p.list) ~= "function" then
    return nil, ("le peripherique '%s' n'est pas un inventaire"):format(nom)
  end
  return p
end

--------------------------------------------------------------------------------
-- Liste tous les inventaires visibles sur le reseau du calculateur.
--------------------------------------------------------------------------------
function M.inventairesVisibles()
  local trouves = {}
  local ok, noms = pcall(peripheral.getNames)
  if not ok or type(noms) ~= "table" then return trouves end
  for _, nom in ipairs(noms) do
    local estInventaire = false
    if peripheral.hasType then
      local ok2, res = pcall(peripheral.hasType, nom, "inventory")
      estInventaire = ok2 and res == true
    end
    if not estInventaire then
      -- Repli pour les versions anterieures a CC: Tweaked 1.89 : on teste
      -- directement la presence de la methode list().
      local ok3, p = pcall(peripheral.wrap, nom)
      estInventaire = ok3 and type(p) == "table" and type(p.list) == "function"
    end
    if estInventaire then trouves[#trouves + 1] = nom end
  end
  table.sort(trouves)
  return trouves
end

--------------------------------------------------------------------------------
-- Contenu d'un inventaire : table creuse par emplacement + totaux par objet.
-- Retourne : { emplacements = {...}, totaux = {...}, taille = n }
--------------------------------------------------------------------------------
function M.contenu(nom)
  local inv, err = M.envelopper(nom)
  if not inv then return nil, err end

  local okListe, liste = pcall(inv.list)
  if not okListe or type(liste) ~= "table" then
    return nil, ("lecture impossible de '%s' : %s"):format(nom, tostring(liste))
  end

  local totaux, emplacements, lignes = {}, {}, 0
  -- list() est une table CREUSE : pairs() est obligatoire.
  for emplacement, pile in pairs(liste) do
    if type(pile) == "table" and pile.name then
      local n = pile.count or pile.amount or 0
      emplacements[emplacement] = { nom = pile.name, quantite = n, nbt = pile.nbt }
      totaux[pile.name] = (totaux[pile.name] or 0) + n
      lignes = lignes + 1
    end
  end

  local taille = 0
  if type(inv.size) == "function" then
    local okTaille, t = pcall(inv.size)
    if okTaille and type(t) == "number" then taille = t end
  end

  return { emplacements = emplacements, totaux = totaux, taille = taille,
           emplacementsOccupes = lignes, nom = nom }
end

--------------------------------------------------------------------------------
-- Catalogue agrege de plusieurs conteneurs sources.
-- 'details' ajoute le libelle affichable (getItemDetail), qui est COUTEUX :
-- une seule interrogation par type d'objet, jamais par emplacement.
--------------------------------------------------------------------------------
function M.catalogue(noms, details)
  local totaux, echantillon, erreurs = {}, {}, {}
  for _, nom in ipairs(noms or {}) do
    local c, err = M.contenu(nom)
    if c then
      for emplacement, pile in pairs(c.emplacements) do
        totaux[pile.nom] = (totaux[pile.nom] or 0) + pile.quantite
        if not echantillon[pile.nom] then
          echantillon[pile.nom] = { conteneur = nom, emplacement = emplacement }
        end
      end
    else
      erreurs[#erreurs + 1] = err
    end
  end

  local articles = {}
  for nomObjet, quantite in pairs(totaux) do
    local ligne = { nom = nomObjet, quantite = quantite, libelle = nomObjet }
    if details then
      local origine = echantillon[nomObjet]
      local inv = origine and M.envelopper(origine.conteneur) or nil
      if inv and type(inv.getItemDetail) == "function" then
        local ok, d = pcall(inv.getItemDetail, origine.emplacement)
        if ok and type(d) == "table" and d.displayName then
          ligne.libelle = d.displayName
          ligne.pileMax = d.maxCount
        end
      end
    end
    articles[#articles + 1] = ligne
  end

  table.sort(articles, function(a, b) return a.nom < b.nom end)
  return articles, erreurs
end

function M.total(noms, nomObjet)
  local somme = 0
  for _, nom in ipairs(noms or {}) do
    local c = M.contenu(nom)
    if c then somme = somme + (c.totaux[nomObjet] or 0) end
  end
  return somme
end

--------------------------------------------------------------------------------
-- TRANSFERT UNITAIRE
-- Deplace au plus 'quantite' objets 'nomObjet' de 'source' vers 'cible'.
-- Ne touche a RIEN d'autre : seuls les emplacements dont le nom d'objet
-- correspond exactement sont pris, et jamais au dela de la quantite demandee.
--
-- options = {
--   journal        = journal (facultatif)
--   etape          = nom d'etape pour le journal
--   parAppel       = plafond par appel pushItems (defaut 64)
--   surProgression = function(deplace, demande) end
-- }
--
-- Retourne : nombreDeplace, erreur|nil
--------------------------------------------------------------------------------
function M.transferer(source, cible, nomObjet, quantite, options)
  options = options or {}
  local journal  = options.journal
  local etape    = options.etape or "transfert d'objets"
  local parAppel = options.parAppel or 64

  if quantite == nil or quantite <= 0 then return 0 end

  local invSource, errS = M.envelopper(source)
  if not invSource then return 0, errS end
  local _, errC = M.envelopper(cible)
  if errC then return 0, errC end

  local deplace, iterations = 0, 0

  while deplace < quantite do
    local contenu, err = M.contenu(source)
    if not contenu then return deplace, err end

    -- On re-liste a chaque passe : le conteneur source peut etre alimente ou
    -- vide par d'autres machines pendant le transfert (convoyeurs Create).
    local aFait = false
    for emplacement, pile in pairs(contenu.emplacements) do
      if deplace >= quantite then break end
      if pile.nom == nomObjet and pile.quantite > 0 then
        local reste  = quantite - deplace
        local limite = math.min(parAppel, reste)

        iterations = iterations + 1
        if iterations > M.MAX_ITERATIONS then
          return deplace, ("garde-fou atteint (%d appels) pour '%s'")
            :format(M.MAX_ITERATIONS, nomObjet)
        end

        local ok, n = pcall(invSource.pushItems, cible, emplacement, limite)
        if not ok then
          -- Certains conteneurs (bulk container Create, coffres modes) refusent
          -- le push mais acceptent le pull vu depuis la cible : second essai.
          local invCible = M.envelopper(cible)
          if invCible and type(invCible.pullItems) == "function" then
            local ok2, n2 = pcall(invCible.pullItems, source, emplacement, limite)
            ok, n = ok2, n2
          end
        end

        if not ok then
          return deplace, ("pushItems/pullItems en echec sur '%s' emplacement %s : %s")
            :format(nomObjet, tostring(emplacement), tostring(n))
        end

        n = tonumber(n) or 0
        if n > 0 then
          deplace = deplace + n
          aFait = true
          if options.surProgression then
            pcall(options.surProgression, deplace, quantite)
          end
          if journal and iterations % 50 == 0 then
            journal.debug(etape, "transfert en cours : %d / %d de %s",
              deplace, quantite, nomObjet)
          end
        end

        -- Cession de la main : indispensable sur les gros volumes.
        if iterations % M.PAUSE_TOUS_LES == 0 then os.sleep(0) end
      end
    end

    if not aFait then
      -- Plus rien ne bouge : soit la source est epuisee, soit la cible est
      -- pleine. Dans les deux cas il est inutile d'insister.
      break
    end
  end

  if journal then
    journal.info(etape, "transfert termine : %d / %d de %s (%s -> %s)",
      deplace, quantite, nomObjet, source, cible)
  end

  if deplace < quantite then
    return deplace, ("quantite incomplete : %d / %d de %s"):format(deplace, quantite, nomObjet)
  end
  return deplace
end

--------------------------------------------------------------------------------
-- VIDAGE COMPLET d'un inventaire vers un autre, tous objets confondus.
-- C'est l'operation de depot chez le destinataire.
-- Retourne : nombreDeplace, resteNonLivre, erreur|nil
--------------------------------------------------------------------------------
function M.vider(source, cible, options)
  options = options or {}
  local journal  = options.journal
  local etape    = options.etape or "vidage d'inventaire"
  local parAppel = options.parAppel or 64

  local invSource, errS = M.envelopper(source)
  if not invSource then return 0, 0, errS end

  local deplace, iterations = 0, 0

  while true do
    local contenu, err = M.contenu(source)
    if not contenu then return deplace, 0, err end

    local restant, aFait = 0, false
    for emplacement, pile in pairs(contenu.emplacements) do
      restant = restant + pile.quantite
      iterations = iterations + 1
      if iterations > M.MAX_ITERATIONS then
        return deplace, restant, "garde-fou atteint pendant le vidage"
      end

      local ok, n = pcall(invSource.pushItems, cible, emplacement, parAppel)
      if not ok then
        local invCible = M.envelopper(cible)
        if invCible and type(invCible.pullItems) == "function" then
          local ok2, n2 = pcall(invCible.pullItems, source, emplacement, parAppel)
          ok, n = ok2, n2
        end
      end
      if not ok then
        return deplace, restant, ("vidage en echec sur l'emplacement %s : %s")
          :format(tostring(emplacement), tostring(n))
      end

      n = tonumber(n) or 0
      if n > 0 then
        deplace = deplace + n
        restant = restant - n
        aFait = true
      end
      if iterations % M.PAUSE_TOUS_LES == 0 then os.sleep(0) end
    end

    if not aFait then
      if journal then
        journal.info(etape, "vidage termine : %d objets deplaces, %d restants dans %s",
          deplace, restant, source)
      end
      return deplace, restant
    end
  end
end

--------------------------------------------------------------------------------
-- Espace libre estime (emplacements vides) d'un inventaire.
--------------------------------------------------------------------------------
function M.emplacementsLibres(nom)
  local c = M.contenu(nom)
  if not c then return 0 end
  if c.taille and c.taille > 0 then
    return math.max(0, c.taille - c.emplacementsOccupes)
  end
  return math.max(0, 27 - c.emplacementsOccupes)
end

return M
