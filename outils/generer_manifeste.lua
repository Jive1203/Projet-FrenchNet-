--[[----------------------------------------------------------------------------
  GENERATEUR DE MANIFESTE - FRENCHNET
    lua5.4 outils/generer_manifeste.lua [version]

  Ecrit manifeste.lua a la racine du depot : la liste des fichiers de chaque
  poste, leur destination a bord, leur taille et leur somme de controle.

  La somme est calculee par maj.somme, LE MEME code que celui qui verifiera a
  bord. Un generateur avec sa propre implementation finirait par diverger d'une
  version, et tous les postes du serveur refuseraient de se mettre a jour sans
  qu'on comprenne pourquoi.

  tests/test_maj.lua verifie que ce fichier est a jour : oublier de le
  relancer apres une modification fait echouer le banc, pas le serveur.
--------------------------------------------------------------------------------]]

local RACINE = (arg[0] or ""):match("^(.*)/outils/[^/]+$") or "."
local maj = dofile(RACINE .. "/maj/maj.lua")

--[[
  Composition des postes.
    'chemin' : le fichier dans le depot
    'cible'  : sa destination sur l'ordinateur (par defaut, le meme chemin)
    'siAbsent' : installe une seule fois, JAMAIS ecrase - configurations.
]]
local BIBLIO_MAJ = {
  { chemin = "maj/maj.lua" },
  { chemin = "maj/update.lua" },
  { chemin = "maj/config_maj.lua", siAbsent = true },
}

-- Le poste de distribution n'est utile que sur les serveurs sans HTTP : il
-- n'est livre qu'au poste de commandement, qui est celui qu'on administre.
local DISTRIBUTION = { chemin = "maj/serveur_maj.lua" }

local function avecMaj(liste)
  for _, e in ipairs(BIBLIO_MAJ) do liste[#liste + 1] = e end
  return liste
end

local POSTES = {
  command = avecMaj({
    { chemin = "command/command.lua" },     { chemin = "command/noyau.lua" },
    { chemin = "command/carte.lua" },       { chemin = "command/terrain.lua" },
    { chemin = "command/scanner.lua" },     { chemin = "command/interface.lua" },
    { chemin = "command/diagnostic.lua" },
    { chemin = "command/config_command.lua", siAbsent = true },
    { chemin = "command/startup.lua", cible = "/startup.lua" },
    DISTRIBUTION,
  }),

  radar = avecMaj({
    { chemin = "radar/radar.lua" },      { chemin = "radar/diagnostic.lua" },
    { chemin = "command/scanner.lua", cible = "/radar/scanner.lua" },
    { chemin = "radar/config_radar.lua", siAbsent = true },
    { chemin = "radar/startup.lua", cible = "/startup.lua" },
  }),

  lanceur = avecMaj({
    { chemin = "lanceur/lanceur.lua" },
    { chemin = "lanceur/config_lanceur.lua", siAbsent = true },
    { chemin = "lanceur/startup.lua", cible = "/startup.lua" },
  }),

  balise = avecMaj({
    { chemin = "balise/balise.lua" },   { chemin = "balise/recepteur.lua" },
    { chemin = "balise/config_balise.lua", siAbsent = true },
    { chemin = "balise/startup.lua", cible = "/startup.lua" },
  }),

  transpondeur = avecMaj({
    { chemin = "command/transpondeur.lua", cible = "/transpondeur.lua" },
  }),

  vaisseau = avecMaj({
    { chemin = "vaisseau/vaisseau.lua" },     { chemin = "vaisseau/mfd.lua" },
    { chemin = "vaisseau/hal.lua" },          { chemin = "vaisseau/liaisons.lua" },
    { chemin = "vaisseau/surveillance.lua" }, { chemin = "vaisseau/widgets.lua" },
    { chemin = "vaisseau/sa.lua" },           { chemin = "vaisseau/inventaire.lua" },
    { chemin = "vaisseau/audio.lua" },        { chemin = "vaisseau/musique.lua" },
    { chemin = "vaisseau/diagnostic.lua" },
    { chemin = "vaisseau/pages/propulsion.lua" }, { chemin = "vaisseau/pages/portance.lua" },
    { chemin = "vaisseau/pages/navigation.lua" }, { chemin = "vaisseau/pages/sa.lua" },
    { chemin = "vaisseau/pages/ew.lua" },         { chemin = "vaisseau/pages/armement.lua" },
    { chemin = "vaisseau/pages/liaison.lua" },    { chemin = "vaisseau/pages/alertes.lua" },
    -- Modules du poste au sol, reutilises VERBATIM a bord : deux copies
    -- divergentes feraient lire rouge a l'equipage ce que le sol lit vert.
    { chemin = "command/noyau.lua",   cible = "/vaisseau/noyau.lua" },
    { chemin = "command/carte.lua",   cible = "/vaisseau/carte.lua" },
    { chemin = "command/scanner.lua", cible = "/vaisseau/scanner.lua" },
    { chemin = "vaisseau/config_vaisseau.lua", siAbsent = true },
    { chemin = "vaisseau/startup.lua", cible = "/startup.lua" },
  }),
}

--------------------------------------------------------------------------------

local function lire(chemin)
  local f = io.open(RACINE .. "/" .. chemin, "r")
  if not f then return nil end
  local contenu = f:read("a")
  f:close()
  return contenu
end

local function serialiser(valeur)
  if type(valeur) == "string" then return string.format("%q", valeur) end
  return tostring(valeur)
end

local version = arg[1] or os.getenv("FRENCHNET_VERSION")
if not version then
  -- Sans version explicite, on reprend celle du manifeste existant en
  -- incrementant le correctif : oublier de la changer ferait qu'aucun poste
  -- ne saurait qu'il y a du neuf.
  local ancien = loadfile(RACINE .. "/manifeste.lua")
  local ok, donnees = pcall(ancien or function() end)
  local base = (ok and type(donnees) == "table" and donnees.version) or "0.0.0"
  local v = maj.analyserVersion(base) or { 0, 0, 0 }
  version = ("%d.%d.%d"):format(v[1], v[2], v[3] + 1)
end

local noms = {}
for nom in pairs(POSTES) do noms[#noms + 1] = nom end
table.sort(noms)

local lignes = {
  "--[[--------------------------------------------------------------------------",
  "  MANIFESTE FRENCHNET - GENERE, NE PAS EDITER A LA MAIN",
  "    lua5.4 outils/generer_manifeste.lua [version]",
  "",
  "  Liste, pour chaque poste, les fichiers a installer et leur somme de",
  "  controle. Les postes le telechargent pour savoir ce qui a change.",
  "",
  "  'siAbsent' marque un fichier installe UNE SEULE FOIS, jamais ecrase :",
  "  ce sont les configurations, qui contiennent les zones du theatre, les",
  "  codes transpondeur et le mot de passe de la console.",
  "----------------------------------------------------------------------------]]",
  "",
  "return {",
  ("  version = %q,"):format(version),
  ("  genere  = %q,"):format(os.date("!%Y-%m-%d")),
  "  postes = {",
}

local total, manquants = 0, {}
for _, nom in ipairs(noms) do
  lignes[#lignes + 1] = ("    %s = { fichiers = {"):format(nom)
  for _, fichier in ipairs(POSTES[nom]) do
    local contenu = lire(fichier.chemin)
    if not contenu then
      manquants[#manquants + 1] = fichier.chemin
    else
      local champs = { ("chemin = %q"):format(fichier.chemin) }
      if fichier.cible then champs[#champs + 1] = ("cible = %q"):format(fichier.cible) end
      champs[#champs + 1] = ("somme = %d"):format(maj.somme(contenu))
      champs[#champs + 1] = ("taille = %d"):format(#contenu)
      if fichier.siAbsent then champs[#champs + 1] = "siAbsent = true" end
      lignes[#lignes + 1] = ("      { %s },"):format(table.concat(champs, ", "))
      total = total + 1
    end
  end
  lignes[#lignes + 1] = "    } },"
end
lignes[#lignes + 1] = "  },"
lignes[#lignes + 1] = "}"

if #manquants > 0 then
  io.stderr:write("FICHIERS INTROUVABLES :\n")
  for _, m in ipairs(manquants) do io.stderr:write("  " .. m .. "\n") end
  os.exit(1)
end

local sortie = assert(io.open(RACINE .. "/manifeste.lua", "w"))
sortie:write(table.concat(lignes, "\n") .. "\n")
sortie:close()
print(("manifeste.lua : version %s, %d poste(s), %d fichier(s)")
  :format(version, #noms, total))
