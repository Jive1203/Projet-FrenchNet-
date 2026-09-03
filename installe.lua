--[[----------------------------------------------------------------------------
  INSTALLATEUR FRENCHNET - AERONAUTICS WARFARE (CC: Tweaked)
  --------------------------------------------------------------------------
  Installe en une seule commande un poste FrenchNet, en verifiant chaque
  fichier telecharge. Evite de retaper cinq adresses de trente caracteres,
  et surtout de garder un fichier corrompu sans le savoir : un telechargement
  rate produit une page d'erreur HTML que l'ordinateur enregistrerait comme du
  Lua, pour ne planter que plus tard, en vol.

  Usage :
      installe balise      -- balise GPS fixe
      installe vehicule    -- autopilote d'un vehicule aerien
      installe satellite   -- ordinateur de sortie deporte
      installe tout        -- les trois jeux de fichiers

  Options :
      -f                   -- ecrase aussi les fichiers de configuration
      -b <branche>         -- installe depuis une autre branche du depot

  IMPORTANT : le depot doit etre PUBLIC. CC: Tweaked n'a aucun moyen de
  s'authentifier sur GitHub ; sur un depot prive, toutes les adresses
  renvoient 404 et wget echoue quoi qu'on fasse.
--------------------------------------------------------------------------------]]

local DEPOT    = "Jive1203/Projet-FrenchNet-"
local BRANCHE  = "claude/autopilote-lua-module-kfnu2k"
local BASE     = "https://raw.githubusercontent.com/"

-- Chaque entree : { chemin dans le depot, chemin sur l'ordinateur, config ? }
local JEUX = {
  balise = {
    titre = "BALISE GPS",
    fichiers = {
      { "balise/balise.lua",        "/balise/balise.lua" },
      { "balise/config_balise.lua", "/balise/config_balise.lua", config = true },
      { "balise/startup.lua",       "/startup.lua" },
      { "balise/recepteur.lua",     "/recepteur.lua" },
    },
    suite = {
      "edit balise/config_balise.lua   -- identifiant + coordonnees (F3, ligne Block)",
      "reboot",
    },
  },

  vehicule = {
    titre = "AUTOPILOTE DE VEHICULE",
    fichiers = {
      { "autopilote/autopilote.lua",       "/autopilote/autopilote.lua" },
      { "autopilote/config_vehicule.lua",  "/autopilote/config_vehicule.lua", config = true },
      { "autopilote/ravitaillement.lua",   "/autopilote/ravitaillement.lua", config = true },
      { "autopilote/interface.lua",        "/autopilote/interface.lua" },
      { "autopilote/cablage.lua",          "/autopilote/cablage.lua" },
      { "autopilote/carburant.lua",        "/autopilote/carburant.lua" },
      { "autopilote/exemple_mission.lua",  "/autopilote/exemple_mission.lua" },
      { "autopilote/startup.lua",          "/startup.lua" },
    },
    suite = {
      "interface        -- reglage du vehicule a l'ecran",
      "cablage          -- verification du cablage, pilotage manuel",
    },
  },

  satellite = {
    titre = "SORTIE DEPORTEE (SATELLITE)",
    fichiers = {
      { "autopilote/satellite.lua",        "/autopilote/satellite.lua" },
      { "autopilote/config_satellite.lua", "/autopilote/config_satellite.lua", config = true },
    },
    suite = {
      "edit autopilote/config_satellite.lua   -- identifiant + vehicule maitre",
      "autopilote/satellite                   -- note le numero d'ordinateur affiche",
    },
  },
}

--------------------------------------------------------------------------------

local function ecrire(couleur, texte)
  if term.isColour and term.isColour() then term.setTextColour(couleur) end
  print(texte)
  if term.isColour and term.isColour() then term.setTextColour(colors.white) end
end

local function titre(texte)
  ecrire(colors.cyan, "== " .. texte .. " ==")
end

--- Verifie que le HTTP est reellement utilisable, avec un message qui dit quoi
--- faire plutot qu'un simple "echec".
local function verifierHttp()
  if not http then
    ecrire(colors.red, "L'API HTTP est desactivee sur ce serveur.")
    print("Cote serveur, dans serverconfig/computercraft-server.toml :")
    print("    [http]")
    print("    enabled = true")
    print("Puis redemarrez le serveur. Sans cela, aucun telechargement")
    print("n'est possible : utilisez une disquette (voir le guide).")
    return false
  end
  if http.checkURL then
    local ok, motif = http.checkURL(BASE)
    if ok == false then
      ecrire(colors.red, "Le domaine raw.githubusercontent.com est bloque : "
        .. tostring(motif))
      print("Ajoutez-le aux regles [[http.rules]] de la configuration serveur.")
      return false
    end
  end
  return true
end

--- Telecharge un fichier et REFUSE de l'ecrire s'il n'est pas du Lua valide.
--- @return true | false, motif
local function telecharger(source, destination, estConfig, forcer)
  local url = BASE .. DEPOT .. "/" .. BRANCHE .. "/" .. source

  if estConfig and fs.exists(destination) and not forcer then
    ecrire(colors.yellow, "  = " .. destination .. "  (configuration conservee)")
    return true
  end

  local reponse, erreur = http.get(url)
  if not reponse then
    return false, tostring(erreur or "aucune reponse")
  end

  local code = reponse.getResponseCode and reponse.getResponseCode() or 200
  local contenu = reponse.readAll()
  reponse.close()

  if code ~= 200 then
    return false, "code HTTP " .. tostring(code)
  end
  if not contenu or #contenu == 0 then
    return false, "fichier vide"
  end

  -- Un depot prive, une branche renommee ou un proxy renvoient une page HTML
  -- avec un code 200 : on la reconnait avant de l'enregistrer.
  if contenu:find("^%s*<") then
    return false, "page HTML recue au lieu du code Lua"
  end
  local morceau, motif = load(contenu, "@" .. destination, "t", _G)
  if not morceau then
    return false, "Lua invalide (" .. tostring(motif) .. ")"
  end

  local dossier = fs.getDir(destination)
  if dossier ~= "" and not fs.exists(dossier) then fs.makeDir(dossier) end

  local fichier = fs.open(destination, "w")
  if not fichier then return false, "ecriture impossible" end
  fichier.write(contenu)
  fichier.close()

  ecrire(colors.lime, string.format("  + %s  (%d octets)", destination, #contenu))
  return true
end

local function installerJeu(nom, forcer)
  local jeu = JEUX[nom]
  if not jeu then return false end
  titre(jeu.titre)

  local echecs = {}
  for _, entree in ipairs(jeu.fichiers) do
    local ok, motif = telecharger(entree[1], entree[2], entree.config, forcer)
    if not ok then
      ecrire(colors.red, "  ! " .. entree[2] .. " : " .. tostring(motif))
      echecs[#echecs + 1] = entree[1]
    end
  end

  if #echecs > 0 then
    ecrire(colors.red, string.format("%d fichier(s) non installe(s).", #echecs))
    print("Si le motif est 404 ou une page HTML : le depot est PRIVE.")
    print("CC: Tweaked ne peut pas s'y authentifier. Rendez-le public,")
    print("ou passez les fichiers par une disquette.")
    return false
  end

  ecrire(colors.lime, "Installation complete.")
  if jeu.suite then
    print("Etapes suivantes :")
    for _, ligne in ipairs(jeu.suite) do print("  " .. ligne) end
  end
  return true
end

--------------------------------------------------------------------------------

local arguments = { ... }
local cible, forcer = nil, false
local i = 1
while i <= #arguments do
  local argument = arguments[i]
  if argument == "-f" then
    forcer = true
  elseif argument == "-b" then
    i = i + 1
    BRANCHE = arguments[i] or BRANCHE
  else
    cible = argument
  end
  i = i + 1
end

term.clear()
term.setCursorPos(1, 1)
ecrire(colors.cyan, "=== INSTALLATEUR FRENCHNET ===")
print("depot   : " .. DEPOT)
print("branche : " .. BRANCHE)
print("")

if not cible then
  print("Usage : installe <balise|vehicule|satellite|tout> [-f] [-b branche]")
  print("")
  print("  balise     balise GPS fixe (1 ordinateur + 1 modem Ender)")
  print("  vehicule   autopilote (1 ordinateur + 1 modem Ender)")
  print("  satellite  sortie deportee (1 ordinateur + 1 modem courte portee)")
  print("  tout       les trois")
  print("")
  print("  -f         ecrase aussi les fichiers de configuration")
  return
end

if not verifierHttp() then return end

local jeux = (cible == "tout") and { "balise", "vehicule", "satellite" } or { cible }
if not JEUX[jeux[1]] and cible ~= "tout" then
  ecrire(colors.red, "Jeu de fichiers inconnu : " .. tostring(cible))
  return
end

local tout = true
for _, nom in ipairs(jeux) do
  if not installerJeu(nom, forcer) then tout = false end
  print("")
end

if tout then
  ecrire(colors.lime, "Poste FrenchNet pret.")
else
  ecrire(colors.yellow, "Installation incomplete : voir les messages ci-dessus.")
end
