--[[----------------------------------------------------------------------------
  FRENCHNET / LIVRAISON - Journal commun (navire + borne publique)
  --------------------------------------------------------------------------
  Format d'une ligne :

      [2026-09-14 11:02:33] [ERREUR] [etape: chargement de la cargaison] ...

  L'ETAPE est la cle du diagnostic : toute fonction critique du systeme
  journalise l'etape exacte dans laquelle elle se trouve, si bien qu'un
  plantage se localise sans avoir a relire le code.

  NOTE SUR LES ACCENTS : les chaines ecrites a l'ecran ou dans le fichier
  journal sont volontairement sans accents (le terminal de CC: Tweaked est
  oriente octet). Les commentaires, jamais affiches, sont rediges normalement.
--------------------------------------------------------------------------------]]

local M = {}

M.NIVEAUX = { DEBUG = 0, INFO = 1, AVERT = 2, ERREUR = 3, CRITIQUE = 4 }

local COULEURS = {
  DEBUG    = "lightGray",
  INFO     = "white",
  AVERT    = "yellow",
  ERREUR   = "red",
  CRITIQUE = "magenta",
}

local function horodatage()
  local ok, texte = pcall(function()
    return os.date("!%Y-%m-%d %H:%M:%S", math.floor(os.epoch("utc") / 1000))
  end)
  if ok and texte then return texte end
  -- Repli si os.epoch / os.date sont indisponibles : temps du monde Minecraft.
  local ok2, texte2 = pcall(function()
    return string.format("jour %d %s", os.day(), textutils.formatTime(os.time(), true))
  end)
  if ok2 and texte2 then return texte2 end
  return "??"
end

--------------------------------------------------------------------------------
-- creer{ chemin=, tailleMax=, niveauEcran=, prefixe=, ecrireFichier= }
--------------------------------------------------------------------------------
function M.creer(options)
  options = options or {}

  local j = {
    chemin        = options.chemin,
    tailleMax     = options.tailleMax or (64 * 1024),
    seuilEcran    = M.NIVEAUX[options.niveauEcran or "INFO"] or 1,
    prefixe       = options.prefixe,
    fichierActif  = false,
    lignes        = 0,
    compteurs     = { DEBUG = 0, INFO = 0, AVERT = 0, ERREUR = 0, CRITIQUE = 0 },
    etapeCourante = "demarrage",
  }

  -- Ouverture du fichier : un echec ici n'est jamais fatal, le journal
  -- bascule simplement en mode ecran seul.
  if options.ecrireFichier ~= false and j.chemin then
    local ok = pcall(function()
      local f = fs.open(j.chemin, "a")
      if f then
        f.writeLine(("[%s] [INFO] [etape: ouverture du journal] --- nouvelle session ---")
          :format(horodatage()))
        f.close()
        j.fichierActif = true
      end
    end)
    if not ok then j.fichierActif = false end
  end

  function j.rotation()
    -- Aucune journalisation interne ici : appelee depuis ecrire(), la moindre
    -- erreur journalisee provoquerait une recursion infinie.
    if not j.fichierActif or not j.chemin then return end
    if not fs.exists(j.chemin) then return end
    if fs.getSize(j.chemin) < j.tailleMax then return end
    local archive = j.chemin .. ".1"
    if fs.exists(archive) then fs.delete(archive) end
    fs.move(j.chemin, archive)
  end

  function j.ecrire(niveau, etape, message, ...)
    local texte = tostring(message)
    if select("#", ...) > 0 then
      local ok, formate = pcall(string.format, texte, ...)
      if ok then texte = formate end
    end
    if j.prefixe then texte = j.prefixe .. " " .. texte end

    local premiere = texte:match("^[^\n]*") or texte
    local multiligne = premiere ~= texte
    local entete = string.format("[%s] [%s] [etape: %s] ",
      horodatage(), niveau, tostring(etape or j.etapeCourante))

    j.compteurs[niveau] = (j.compteurs[niveau] or 0) + 1

    -- Sortie ecran, filtree par le niveau configure.
    if (M.NIVEAUX[niveau] or 1) >= j.seuilEcran then
      local couleur
      if term and term.isColour and term.isColour() then
        couleur = colors[COULEURS[niveau] or "white"]
        pcall(term.setTextColour, couleur)
      end
      print(entete .. premiere
        .. ((multiligne and j.fichierActif) and " [trace complete dans le journal]" or ""))
      if couleur then pcall(term.setTextColour, colors.white) end
    end

    -- Sortie fichier : toujours integrale, tous niveaux confondus.
    if j.fichierActif then
      pcall(function()
        j.rotation()
        local f = fs.open(j.chemin, "a")
        if f then
          f.writeLine(entete .. texte)
          f.close()
          j.lignes = j.lignes + 1
        end
      end)
    end
  end

  -- Raccourcis : j.info("etape", "message %d", 3)
  for _, niveau in ipairs({ "DEBUG", "INFO", "AVERT", "ERREUR", "CRITIQUE" }) do
    j[niveau:lower()] = function(etape, message, ...)
      j.ecrire(niveau, etape, message, ...)
    end
  end

  -- Memorise l'etape en cours : sert de contexte par defaut et de valeur
  -- reprise par le superviseur quand une erreur non capturee remonte.
  function j.etape(nom)
    j.etapeCourante = nom
    j.ecrire("DEBUG", nom, "entree dans l'etape")
    return nom
  end

  -- Execute une fonction en la rattachant a une etape nommee.
  -- Retourne : ok, resultat|erreur
  function j.proteger(nom, fn, ...)
    j.etapeCourante = nom
    -- xpcall a arguments variadiques n'existe qu'a partir de Lua 5.2 : on passe
    -- par une fermeture, forme acceptee par toutes les versions de CC: Tweaked.
    local arguments = table.pack(...)
    local retours = table.pack(xpcall(function()
      return fn(table.unpack(arguments, 1, arguments.n))
    end, function(err)
      local trace = err
      if debug and debug.traceback then
        trace = debug.traceback(tostring(err), 2)
      end
      return trace
    end))
    if not retours[1] then
      j.ecrire("ERREUR", nom, "echec a l'etape '%s' : %s", nom, tostring(retours[2]))
    end
    return table.unpack(retours, 1, retours.n)
  end

  function j.resume()
    return string.format("lignes=%d erreurs=%d avertissements=%d",
      j.lignes, (j.compteurs.ERREUR or 0) + (j.compteurs.CRITIQUE or 0),
      j.compteurs.AVERT or 0)
  end

  return j
end

return M
