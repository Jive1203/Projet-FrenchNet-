-- Banc d'essai de la mise a jour automatique, hors du jeu.
--   Usage : lua5.4 tests/test_maj.lua   (depuis la racine du depot)
--
-- Ce module merite le banc le plus severe du depot : un bug ici ne casse pas
-- un poste, il les casse TOUS a la fois, et il les casse a distance. Ce qui
-- est verifie en priorite n'est donc pas qu'il installe, mais qu'il REFUSE
-- d'installer quand quelque chose cloche, et qu'il sait revenir en arriere.

local RACINE = (arg[0] or ""):match("^(.*)/tests/[^/]+$") or "."
local majModule = dofile(RACINE .. "/maj/maj.lua")

local echecs, total = 0, 0

local function verifier(nom, condition, detail)
  total = total + 1
  if condition then
    print(("  [OK]   %s"):format(nom))
  else
    echecs = echecs + 1
    print(("  [ECHEC] %s %s"):format(nom, detail and ("-> " .. detail) or ""))
  end
end

local function egal(nom, obtenu, attendu)
  verifier(nom, obtenu == attendu,
    ("obtenu '%s', attendu '%s'"):format(tostring(obtenu), tostring(attendu)))
end

--------------------------------------------------------------------------------
-- Systeme de fichiers simule : en memoire, donc sans effet de bord sur le
-- depot. Un banc de mise a jour qui ecrirait vraiment finirait par se mettre
-- a jour lui-meme en cours de route.
--------------------------------------------------------------------------------

local function fauxFs(initial)
  local F = { fichiers = {} }
  for k, v in pairs(initial or {}) do F.fichiers[k] = v end

  F.exists = function(c)
    if F.fichiers[c] then return true end
    for nom in pairs(F.fichiers) do
      if nom:sub(1, #c + 1) == c .. "/" then return true end   -- dossier
    end
    return false
  end
  F.isDir = function(c)
    if F.fichiers[c] then return false end
    return F.exists(c)
  end
  F.getDir = function(c) return (c:match("^(.*)/[^/]*$")) or "" end
  F.makeDir = function() end
  F.list = function(c)
    local vus, liste = {}, {}
    for nom in pairs(F.fichiers) do
      if nom:sub(1, #c + 1) == c .. "/" then
        local reste = nom:sub(#c + 2)
        local premier = reste:match("^([^/]+)")
        if premier and not vus[premier] then vus[premier] = true liste[#liste + 1] = premier end
      end
    end
    table.sort(liste)
    return liste
  end
  F.delete = function(c)
    for nom in pairs(F.fichiers) do
      if nom == c or nom:sub(1, #c + 1) == c .. "/" then F.fichiers[nom] = nil end
    end
  end
  F.open = function(c, mode)
    if mode == "r" then
      local contenu = F.fichiers[c]
      if not contenu then return nil end
      return { readAll = function() return contenu end, close = function() end }
    end
    local tampon = {}
    return {
      write = function(t) tampon[#tampon + 1] = t end,
      writeLine = function(t) tampon[#tampon + 1] = t .. "\n" end,
      close = function() F.fichiers[c] = table.concat(tampon) end,
    }
  end
  return F
end

-- Depot simule. On retire la BASE de l'URL plutot que de deviner le chemin
-- par motif : deviner marchait pour "essai/mod.lua" et ratait "manifeste.lua",
-- ce qui faisait echouer tout le cycle pour une raison sans rapport.
local BASE = "http://exemple/depot"

local function fauxHttp(depot, pannes)
  return { get = function(url)
    local chemin = url:sub(#BASE + 2)      -- + la barre obliq
    if pannes and pannes[chemin] then error(pannes[chemin], 0) end
    local contenu = depot[chemin]
    if not contenu then return nil end
    return { readAll = function() return contenu end, close = function() end }
  end }
end

local function construire(fsSim, depot, config, pannes)
  local cfg = { urlBase = BASE, cheminManifeste = "manifeste.lua" }
  for k, v in pairs(config or {}) do cfg[k] = v end
  return majModule.nouveau(cfg, {
    fs = fsSim, http = fauxHttp(depot or {}, pannes), load = load,
    horloge = function() return cfg._horloge or 1000 end,
  }, function(niveau, _, m) if cfg._dits then cfg._dits[#cfg._dits + 1] = m end end), cfg
end

local function manifesteDe(version, fichiers)
  local lignes = { ("return { version = %q, postes = { essai = { fichiers = {"):format(version) }
  for _, f in ipairs(fichiers) do
    local champs = { ("chemin = %q"):format(f.chemin) }
    if f.cible then champs[#champs + 1] = ("cible = %q"):format(f.cible) end
    champs[#champs + 1] = ("somme = %d"):format(f.somme)
    if f.siAbsent then champs[#champs + 1] = "siAbsent = true" end
    lignes[#lignes + 1] = ("{ %s },"):format(table.concat(champs, ", "))
  end
  lignes[#lignes + 1] = "} } } }"
  return table.concat(lignes, "\n")
end

--------------------------------------------------------------------------------
print("\n== TEST 1 : sommes et versions ==")
do
  egal("somme stable", majModule.somme("bonjour"), majModule.somme("bonjour"))
  verifier("somme sensible a un octet",
    majModule.somme("bonjour") ~= majModule.somme("bonjouq"))
  -- Une troncature est le defaut le plus frequent d'un telechargement.
  verifier("somme sensible a une troncature",
    majModule.somme("abcdefgh") ~= majModule.somme("abcdefg"))
  egal("chaine vide", majModule.somme(""), 1)

  -- Calcul par paquets : le resultat ne doit pas dependre du decoupage.
  local long = string.rep("x", 5000) .. "FIN"
  egal("somme identique sur un contenu depassant un paquet",
    majModule.somme(long), majModule.somme(long))

  egal("1.0.0 < 1.0.1", majModule.comparerVersions("1.0.0", "1.0.1"), -1)
  egal("2.0.0 > 1.9.9", majModule.comparerVersions("2.0.0", "1.9.9"), 1)
  egal("egalite", majModule.comparerVersions("1.2.3", "1.2.3"), 0)
  verifier("version illisible", majModule.comparerVersions("abc", "1.0.0") == nil)
end

--------------------------------------------------------------------------------
print("\n== TEST 2 : plan, et la regle des configurations ==")
do
  local ancien = "return { a = 1 }\n"
  local nouveau = "return { a = 2 }\n"
  local config = "return { motDePasse = 'secret du joueur' }\n"

  local F = fauxFs({
    ["/essai/mod.lua"] = ancien,
    ["/essai/stable.lua"] = nouveau,
    ["/essai/config.lua"] = config,
  })
  local M = construire(F, {})
  local manifeste = M:analyserManifeste(manifesteDe("1.0.0", {
    { chemin = "essai/mod.lua", somme = majModule.somme(nouveau) },
    { chemin = "essai/stable.lua", somme = majModule.somme(nouveau) },
    { chemin = "essai/config.lua", somme = majModule.somme(nouveau), siAbsent = true },
    { chemin = "essai/neuf.lua", somme = majModule.somme(nouveau) },
  }))
  local plan, identiques = M:planifier(manifeste, "essai")

  local cibles = {}
  for _, e in ipairs(plan) do cibles[e.cible] = e end
  verifier("un fichier modifie est au plan", cibles["/essai/mod.lua"] ~= nil)
  verifier("un fichier identique n'y est pas", cibles["/essai/stable.lua"] == nil)
  verifier("un fichier absent y est, marque neuf",
    cibles["/essai/neuf.lua"] and cibles["/essai/neuf.lua"].nouveau == true)

  --[[
    LA REGLE QUI COMPTE LE PLUS ICI. Un fichier de configuration existant n'est
    JAMAIS remplace, meme si sa somme differe. Le remplacer rendrait les zones
    du theatre, les codes transpondeur et le mot de passe de la console a leurs
    valeurs d'usine - en silence, a chaque version. Cela desarmerait la defense
    et rouvrirait la console a tout le monde.
  ]]
  verifier("une configuration existante n'est JAMAIS ecrasee",
    cibles["/essai/config.lua"] == nil)
  egal("elle est comptee comme identique", identiques, 2)

  -- Mais une configuration absente doit bien etre posee la premiere fois.
  local F2 = fauxFs({})
  local M2 = construire(F2, {})
  local plan2 = M2:planifier(manifeste, "essai")
  local trouve = false
  for _, e in ipairs(plan2) do if e.cible == "/essai/config.lua" then trouve = true end end
  verifier("une configuration absente est installee la premiere fois", trouve)

  local _, _, motif = M:planifier(manifeste, "inconnu")
  verifier("un poste absent du manifeste est refuse avec son motif",
    motif and motif:find("inconnu", 1, true) ~= nil, tostring(motif))
end

--------------------------------------------------------------------------------
print("\n== TEST 3 : ce qui doit etre REFUSE ==")
do
  local bon = "return { a = 2 }\n"

  --[[
    LUA INVALIDE. Commit casse, page d'erreur d'un proxy, coupure en plein
    telechargement : le fichier ne doit JAMAIS atteindre le disque. C'est la
    panne la plus probable de toutes, et celle qui laisserait un poste de
    defense mort dans un chunk force.
  ]]
  local F = fauxFs({ ["/essai/mod.lua"] = "return { a = 1 }\n" })
  local casse = "return { a = "        -- Lua tronque
  local M = construire(F, { ["essai/mod.lua"] = casse })
  local prets, motif = M:preparer({
    { depot = "essai/mod.lua", cible = "/essai/mod.lua", somme = majModule.somme(casse) } })
  verifier("du Lua invalide est refuse", prets == nil)
  verifier("et le motif le dit", motif and motif:find("Lua invalide", 1, true) ~= nil,
    tostring(motif))
  egal("le fichier d'origine est intact", F.fichiers["/essai/mod.lua"], "return { a = 1 }\n")

  -- SOMME INCORRECTE : telechargement tronque, ou manifeste perime.
  local M2 = construire(F, { ["essai/mod.lua"] = bon })
  local prets2, motif2 = M2:preparer({
    { depot = "essai/mod.lua", cible = "/essai/mod.lua", somme = 12345 } })
  verifier("une somme incorrecte est refusee", prets2 == nil)
  verifier("et le motif parle de troncature",
    motif2 and motif2:find("tronque", 1, true) ~= nil, tostring(motif2))

  -- RESEAU COUPE EN PLEIN LOT : rien ne doit etre installe, pas meme la
  -- partie deja telechargee. Un poste moitie neuf moitie ancien est pire que
  -- les deux versions.
  local M3 = construire(F, { ["essai/a.lua"] = bon }, nil, { ["essai/b.lua"] = "coupure" })
  local prets3, motif3 = M3:preparer({
    { depot = "essai/a.lua", cible = "/essai/a.lua", somme = majModule.somme(bon) },
    { depot = "essai/b.lua", cible = "/essai/b.lua", somme = majModule.somme(bon) } })
  verifier("une coupure en plein lot annule tout le lot", prets3 == nil, tostring(motif3))
  verifier("et rien n'a ete pose", F.fichiers["/essai/a.lua"] == nil)

  -- MANIFESTE HOSTILE : il est lu dans un environnement VIDE. La difference
  -- entre lire une donnee et executer un programme, et elle compte : le
  -- manifeste vient du reseau.
  local M4 = construire(fauxFs({}), {})
  local hostile, motifH = M4:analyserManifeste(
    'return { version = "1.0.0", postes = {}, x = fs.delete("/") }')
  verifier("un manifeste qui appelle fs est neutralise", hostile == nil, tostring(motifH))
  verifier("un manifeste sans version est refuse",
    M4:analyserManifeste("return { postes = {} }") == nil)
  verifier("un manifeste illisible est refuse",
    M4:analyserManifeste("ceci n'est pas du Lua") == nil)
end

--------------------------------------------------------------------------------
print("\n== TEST 4 : bascule, verification apres coup et retour arriere ==")
do
  local ancien, nouveau = "return 1\n", "return 2\n"
  local F = fauxFs({ ["/essai/mod.lua"] = ancien })
  local M = construire(F, { ["essai/mod.lua"] = nouveau })

  local prets = M:preparer({
    { depot = "essai/mod.lua", cible = "/essai/mod.lua", somme = majModule.somme(nouveau) } })
  egal("un fichier prepare", #prets, 1)
  egal("rien n'est encore pose", F.fichiers["/essai/mod.lua"], ancien)

  egal("bascule", M:appliquer(prets), 1)
  egal("le nouveau est en place", F.fichiers["/essai/mod.lua"], nouveau)

  --[[
    RETOUR ARRIERE. C'est la commande a connaitre par coeur : elle ramene un
    poste apres une version fautive sans avoir a aller chercher l'ordinateur
    dans un chunk force a l'autre bout de la carte.
  ]]
  local rendus = M:restaurer()
  egal("un fichier restaure", rendus, 1)
  egal("l'ancien est revenu", F.fichiers["/essai/mod.lua"], ancien)

  --[[
    Un fichier NEUF n'a pas de version precedente : le retour arriere doit
    l'EFFACER, sans quoi le poste garderait un morceau de la version refusee.
  ]]
  local F2 = fauxFs({})
  local M2 = construire(F2, { ["essai/neuf.lua"] = nouveau })
  local prets2 = M2:preparer({
    { depot = "essai/neuf.lua", cible = "/essai/neuf.lua", somme = majModule.somme(nouveau) } })
  M2:appliquer(prets2)
  verifier("le fichier neuf est pose", F2.fichiers["/essai/neuf.lua"] == nouveau)
  local _, supprimes = M2:restaurer(prets2)
  egal("le retour arriere l'efface", supprimes, 1)
  verifier("il n'en reste rien", F2.fichiers["/essai/neuf.lua"] == nil)
end

--------------------------------------------------------------------------------
print("\n== TEST 5 : le verrou d'occupation ==")
do
  local nouveau = "return 2\n"
  local fichiers = { { chemin = "essai/mod.lua", somme = majModule.somme(nouveau) } }
  local depot = { ["essai/mod.lua"] = nouveau, ["manifeste.lua"] = manifesteDe("2.0.0", fichiers) }

  --[[
    POSTE OCCUPE. La bascule est REPORTEE, pas annulee : les fichiers restent
    prets et s'installeront au prochain demarrage, quand rien n'est engage.
    Redemarrer un poste de defense au moment ou il conduit un tir est la seule
    facon de transformer une mise a jour en perte de materiel.
  ]]
  local F = fauxFs({
    ["/essai/mod.lua"] = "return 1\n",
    ["/.maj/occupation.dat"] = '{ instant = 995, occupe = true, motif = "2 engagements" }',
  })
  local M = construire(F, depot, { fichierOccupation = "/.maj/occupation.dat",
                                   occupationPeremption = 30 })
  local resultat, detail = M:cycle("essai")
  egal("poste occupe : bascule reportee", resultat, majModule.RESULTATS.REPORTE)
  verifier("le motif nomme l'engagement", detail:find("engagement", 1, true) ~= nil, detail)
  egal("l'ancien fichier est intact", F.fichiers["/essai/mod.lua"], "return 1\n")

  -- Un operateur devant l'ecran, lui, peut forcer.
  local resultatF = M:cycle("essai", { forcer = true })
  egal("l'operateur peut forcer", resultatF, majModule.RESULTATS.INSTALLE)
  egal("et le nouveau est pose", F.fichiers["/essai/mod.lua"], nouveau)

  --[[
    VERROU PERIME. Un poste qui a plante laisserait sinon un verrou eternel et
    bloquerait justement la mise a jour qui repare. Un poste muet n'est pas
    occupe, il est mort.
  ]]
  local F2 = fauxFs({
    ["/essai/mod.lua"] = "return 1\n",
    ["/.maj/occupation.dat"] = '{ instant = 10, occupe = true, motif = "engagement" }',
  })
  local M2 = construire(F2, depot, { fichierOccupation = "/.maj/occupation.dat",
                                     occupationPeremption = 30 })
  local occupe, raison = M2:occupation()
  verifier("un verrou perime n'occupe plus", occupe == false)
  verifier("et le motif dit que le poste ne repond plus",
    raison:find("ne repond plus", 1, true) ~= nil, raison)
  egal("la mise a jour passe", M2:cycle("essai"), majModule.RESULTATS.INSTALLE)

  -- Verrou illisible : on n'invente pas une occupation, on passe.
  local F3 = fauxFs({ ["/.maj/occupation.dat"] = "n'importe quoi" })
  local M3 = construire(F3, depot, { fichierOccupation = "/.maj/occupation.dat" })
  verifier("un verrou illisible n'occupe pas", (M3:occupation()) == false)
end

--------------------------------------------------------------------------------
print("\n== TEST 6 : cycle complet, politique et garde anti-boucle ==")
do
  local nouveau = "return 2\n"
  local fichiers = { { chemin = "essai/mod.lua", somme = majModule.somme(nouveau) } }
  local depot = { ["essai/mod.lua"] = nouveau, ["manifeste.lua"] = manifesteDe("2.0.0", fichiers) }

  -- Deja a jour.
  local F = fauxFs({ ["/essai/mod.lua"] = nouveau })
  local M2 = construire(F, depot)
  egal("rien a faire", M2:cycle("essai"), majModule.RESULTATS.A_JOUR)

  -- Politique manuelle : prepare, n'installe pas.
  local F3 = fauxFs({ ["/essai/mod.lua"] = "return 1\n" })
  local M3 = construire(F3, depot)
  local r3, d3 = M3:cycle("essai", { preparerSeulement = true })
  egal("politique manuelle : prepare seulement", r3, majModule.RESULTATS.PREPARE)
  egal("rien n'est installe", F3.fichiers["/essai/mod.lua"], "return 1\n")
  verifier("et l'etat garde la version prete",
    M3:lireEtat().prepare == "2.0.0", d3)

  --[[
    GARDE ANTI-BOUCLE. Si l'etat dit que la version est deja installee et que
    des fichiers different quand meme, une somme ne se stabilise jamais.
    Installer puis redemarrer recommencerait sans fin - et sur un ordinateur
    dans un chunk force a l'autre bout de la carte, une boucle de redemarrage
    est pire que l'absence de mise a jour : le poste ne defend plus rien et il
    faut aller le chercher a pied.
  ]]
  local F4 = fauxFs({
    ["/essai/mod.lua"] = "return 1\n",
    ["/.maj/etat.dat"] = '{ version = "2.0.0" }',
  })
  local M4 = construire(F4, depot)
  local r4, d4 = M4:cycle("essai")
  egal("boucle evitee", r4, majModule.RESULTATS.ECHEC)
  verifier("et elle est nommee", d4:find("boucle", 1, true) ~= nil, d4)
  egal("rien n'a bouge", F4.fichiers["/essai/mod.lua"], "return 1\n")

  -- Aucun transport : le module le dit au lieu d'echouer obscurement.
  local M5 = majModule.nouveau({}, { fs = fauxFs({}), load = load }, function() end)
  local _, motif = M5:recuperer("essai/mod.lua")
  verifier("sans HTTP ni repli, le motif est explicite",
    motif:find("aucun transport", 1, true) ~= nil, motif)
end

--------------------------------------------------------------------------------
print("\n== TEST 7 : le manifeste du depot est a jour ==")
do
  --[[
    Ce test echoue si quelqu'un modifie un fichier sans relancer le
    generateur. C'est voulu : un manifeste perime ferait que tous les postes
    du serveur telechargent puis REFUSENT la mise a jour pour somme
    incorrecte - un echec bruyant et incomprehensible, a repetition, sur
    chaque ordinateur. Mieux vaut que le banc le dise ici.
      lua5.4 outils/generer_manifeste.lua
  ]]
  local manifeste = dofile(RACINE .. "/manifeste.lua")
  verifier("le manifeste se charge et porte une version",
    type(manifeste) == "table" and majModule.analyserVersion(manifeste.version) ~= nil)

  local perimes, comptes, configs = {}, 0, 0
  for _, poste in pairs(manifeste.postes or {}) do
    for _, fichier in ipairs(poste.fichiers or {}) do
      local f = io.open(RACINE .. "/" .. fichier.chemin, "r")
      if not f then
        perimes[#perimes + 1] = fichier.chemin .. " (absent du depot)"
      else
        local contenu = f:read("a") f:close()
        comptes = comptes + 1
        if majModule.somme(contenu) ~= fichier.somme then
          perimes[#perimes + 1] = fichier.chemin .. " (somme perimee)"
        end
        if fichier.siAbsent then configs = configs + 1 end
      end
    end
  end
  verifier(("les %d entrees du manifeste correspondent au depot"):format(comptes),
    #perimes == 0, table.concat(perimes, ", ") .. "  -> lua5.4 outils/generer_manifeste.lua")

  -- Toute configuration listee DOIT etre marquee siAbsent : c'est la seule
  -- protection contre l'ecrasement des codes et du mot de passe.
  local nonProtegees = {}
  for nom, poste in pairs(manifeste.postes or {}) do
    for _, fichier in ipairs(poste.fichiers or {}) do
      if fichier.chemin:match("config_[%w_]+%.lua$") and not fichier.siAbsent then
        nonProtegees[#nonProtegees + 1] = nom .. ":" .. fichier.chemin
      end
    end
  end
  verifier("toute configuration est marquee siAbsent",
    #nonProtegees == 0, table.concat(nonProtegees, ", "))
  verifier(("%d configuration(s) protegee(s)"):format(configs), configs > 0)

  -- Chaque poste doit embarquer de quoi se mettre a jour ET revenir en arriere.
  local sansMaj = {}
  for nom, poste in pairs(manifeste.postes or {}) do
    local aMaj, aUpdate = false, false
    for _, f in ipairs(poste.fichiers or {}) do
      if f.chemin == "maj/maj.lua" then aMaj = true end
      if f.chemin == "maj/update.lua" then aUpdate = true end
    end
    if not (aMaj and aUpdate) then sansMaj[#sansMaj + 1] = nom end
  end
  verifier("chaque poste embarque la mise a jour", #sansMaj == 0,
    table.concat(sansMaj, ", "))
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
print("\n== TEST 8 : le programme 'update' execute pour de vrai ==")
do
  --[[
    Les tests ci-dessus eprouvent la bibliotheque. Celui-ci lance le PROGRAMME
    dans l'emulateur, avec un vrai systeme de fichiers, un vrai http et un
    vrai shell. C'est la lecon deja payee sur ce depot : un module correct
    pris un par un peut etre mal cable, et seul un demarrage reel le montre.
  ]]
  package.path = RACINE .. "/tests/?.lua;" .. package.path
  local BANC = "/tmp/banc_maj_frenchnet"

  local ANCIEN = "-- version 1\nreturn { valeur = 1 }\n"
  local NOUVEAU = "-- version 2\nreturn { valeur = 2 }\n"
  local CONFIG_LOCALE = "return { secret = \"code du joueur\" }\n"

  local function manifesteDepot(version, sommeMod, sommeConf)
    return ("return {\n  version = %q,\n  postes = {\n    essai = { fichiers = {\n" ..
      "      { chemin = \"essai/mod.lua\", somme = %d },\n" ..
      "      { chemin = \"essai/config_essai.lua\", somme = %d, siAbsent = true },\n" ..
      "    } },\n  },\n}\n"):format(version, sommeMod, sommeConf)
  end

  local function preparerBanc(configSupplement)
    os.execute("rm -rf " .. BANC .. " && mkdir -p " .. BANC .. "/maj " .. BANC .. "/essai")
    os.execute(("cp %s/maj/maj.lua %s/maj/update.lua %s/maj/"):format(RACINE, RACINE, BANC))
    local f = io.open(BANC .. "/essai/mod.lua", "w") f:write(ANCIEN) f:close()
    f = io.open(BANC .. "/essai/config_essai.lua", "w") f:write(CONFIG_LOCALE) f:close()
    f = io.open(BANC .. "/maj/config_maj.lua", "w")
    f:write(([[
return {
  poste = "essai",
  urlBase = "http://depot",
  cheminManifeste = "manifeste.lua",
  dossierPrepare = "/.maj/prepare",
  dossierSauvegarde = "/.maj/sauvegarde",
  fichierEtat = "/.maj/etat.dat",
  fichierJournal = "/.maj/maj.log",
  fichierOccupation = "/.maj/occupation.dat",
  occupationPeremption = 30,
  redemarrerApres = false,
  %s
}
]]):format(configSupplement or ""))
    f:close()
  end

  local function lire(chemin)
    local f = io.open(BANC .. "/" .. chemin, "r")
    if not f then return nil end
    local c = f:read("a") f:close()
    return c
  end

  local depot = {
    ["manifeste.lua"] = manifesteDepot("2.0.0",
      majModule.somme(NOUVEAU), majModule.somme("peu importe")),
    ["essai/mod.lua"] = NOUVEAU,
    ["essai/config_essai.lua"] = "return { secret = \"VALEUR D USINE\" }\n",
  }

  ------------------------------------------------------------------ cas nominal
  preparerBanc()
  local craftos = dofile(RACINE .. "/tests/craftos.lua")
  local env, etat = craftos.creer({ racine = BANC, programme = "maj/update.lua",
                                    http = depot, urlBase = "http://depot" })
  local motif = craftos.executer(BANC .. "/maj/update.lua", 30)
  verifier("le programme se termine normalement",
    motif == nil or motif == "PLUS_D_EVENEMENTS", tostring(motif))
  egal("le module est mis a jour", lire("essai/mod.lua"), NOUVEAU)

  --[[
    LA VERIFICATION QUI COMPTE LE PLUS. La configuration locale contient le
    secret du joueur. Le depot en propose une version d'usine. Elle ne doit
    PAS avoir bouge - sinon chaque mise a jour remettrait les codes
    transpondeur et le mot de passe de la console a leurs valeurs par defaut,
    en silence.
  ]]
  egal("la configuration locale est INTACTE", lire("essai/config_essai.lua"), CONFIG_LOCALE)

  local etatMaj = lire(".maj/etat.dat")
  verifier("l'etat note la version installee",
    etatMaj and etatMaj:find("2.0.0", 1, true) ~= nil, tostring(etatMaj))
  verifier("une sauvegarde existe pour le retour arriere",
    lire(".maj/sauvegarde/essai/mod.lua") == ANCIEN)

  ------------------------------------------------------- relance : rien a faire
  local craftos2 = dofile(RACINE .. "/tests/craftos.lua")
  local env2, etat2 = craftos2.creer({ racine = BANC, programme = "maj/update.lua",
                                       http = depot, urlBase = "http://depot" })
  craftos2.executer(BANC .. "/maj/update.lua", 30)
  local dit = table.concat(etat2.sorties, " | ")
  verifier("relance : le poste se declare a jour", dit:find("a jour", 1, true) ~= nil, dit)
  --[[
    Et il ne retelecharge pas les fichiers : seul le manifeste est demande.
    Quinze postes qui redemarrent ensemble - ce qui arrive a chaque relance du
    serveur - ne doivent pas marteler le depot.
  ]]
  egal("une seule requete : le manifeste", #etat2.requetes, 1)

  ------------------------------------------------------------- retour arriere
  -- 'update restaurer' : la commande a connaitre par coeur, celle qui ramene
  -- un poste apres une version fautive sans aller le chercher a pied.
  local craftos4 = dofile(RACINE .. "/tests/craftos.lua")
  local env4, etat4 = craftos4.creer({ racine = BANC, programme = "maj/update.lua",
                                       http = depot, urlBase = "http://depot" })
  craftos4.executer(BANC .. "/maj/update.lua", 30, { "restaurer" })
  egal("'update restaurer' ramene la version precedente", lire("essai/mod.lua"), ANCIEN)
  verifier("et il le dit",
    table.concat(etat4.sorties, " | "):find("restaur", 1, true) ~= nil,
    table.concat(etat4.sorties, " | "))

  --------------------------------------------------- poste occupe : report
  preparerBanc()
  local o = io.open(BANC .. "/.maj_occupation_tmp", "w") o:close()
  os.execute("mkdir -p " .. BANC .. "/.maj")
  f = io.open(BANC .. "/.maj/occupation.dat", "w")
  -- L'emulateur rend une epoque fixe : le verrou doit etre frais pour elle.
  f:write('{ instant = 99999999999, occupe = true, motif = "3 engagements en cours" }')
  f:close()

  local craftos5 = dofile(RACINE .. "/tests/craftos.lua")
  local env5, etat5 = craftos5.creer({ racine = BANC, programme = "maj/update.lua",
                                       http = depot, urlBase = "http://depot" })
  craftos5.executer(BANC .. "/maj/update.lua", 30)
  local dit5 = table.concat(etat5.sorties, " | ")
  verifier("un poste occupe n'est pas bascule",
    lire("essai/mod.lua") == ANCIEN, lire("essai/mod.lua"))
  verifier("et le report est annonce avec son motif",
    dit5:find("report", 1, true) ~= nil and dit5:find("engagement", 1, true) ~= nil, dit5)

  --------------------------------------------- depot injoignable : rien ne bouge
  preparerBanc()
  local craftos6 = dofile(RACINE .. "/tests/craftos.lua")
  local env6, etat6 = craftos6.creer({ racine = BANC, programme = "maj/update.lua",
                                       http = depot, urlBase = "http://depot",
                                       httpPanne = "connexion refusee" })
  craftos6.executer(BANC .. "/maj/update.lua", 30)
  egal("depot injoignable : le fichier reste en place", lire("essai/mod.lua"), ANCIEN)
  verifier("et l'echec est journalise",
    table.concat(etat6.sorties, " | "):find("ERREUR", 1, true) ~= nil,
    table.concat(etat6.sorties, " | "))

  ------------------------------------------------ depot qui sert du Lua casse
  preparerBanc()
  local depotCasse = {
    ["manifeste.lua"] = manifesteDepot("2.0.0", majModule.somme("return { valeur = "), 0),
    ["essai/mod.lua"] = "return { valeur = ",     -- tronque
  }
  local craftos7 = dofile(RACINE .. "/tests/craftos.lua")
  local env7, etat7 = craftos7.creer({ racine = BANC, programme = "maj/update.lua",
                                       http = depotCasse, urlBase = "http://depot" })
  craftos7.executer(BANC .. "/maj/update.lua", 30)
  egal("du Lua casse n'atteint jamais le disque", lire("essai/mod.lua"), ANCIEN)
  verifier("et le refus est explicite",
    table.concat(etat7.sorties, " | "):find("Lua invalide", 1, true) ~= nil,
    table.concat(etat7.sorties, " | "))
end

print(("\n===== %d verification(s), %d echec(s) ====="):format(total, echecs))
if echecs > 0 then os.exit(1) end
os.exit(0)
