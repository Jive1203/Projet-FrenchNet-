--[[----------------------------------------------------------------------------
  FRENCHNET - PROGRAMME DE MISE A JOUR
      update                verifie, prepare, et installe si la politique et
                            l'occupation du poste le permettent
      update verifier       dit ce qui changerait, n'ecrit rien
      update appliquer      installe une mise a jour deja preparee, ou force
                            l'installation maintenant
      update restaurer      revient a la version precedente
      update etat           version installee, derniere verification
      update auto           boucle de verification periodique (service)

  A LANCER AVANT LE POSTE, pas pendant. Le lanceur startup.lua s'en charge :
  au demarrage, rien n'est engage, et c'est le seul moment ou une bascule ne
  peut pas interrompre un tir.

  'update restaurer' est la commande a connaitre par coeur : c'est elle qui
  ramene un poste apres une version fautive, sans avoir a aller chercher
  l'ordinateur dans un chunk force a l'autre bout de la carte.
--------------------------------------------------------------------------------]]

local ARGUMENT = ({ ... })[1] or "maj"

--------------------------------------------------------------------------------
-- Chargement
--------------------------------------------------------------------------------

local function repertoire()
  if shell and shell.getRunningProgram then
    local ok, chemin = pcall(shell.getRunningProgram)
    if ok and chemin then
      local d = fs.getDir(chemin)
      if d and d ~= "" and d ~= "." then return d end
    end
  end
  return "maj"
end

local REPERTOIRE = repertoire()

local function charger(nom)
  local f = loadfile(fs.combine(REPERTOIRE, nom))
  if not f then return nil end
  local ok, m = pcall(f)
  return ok and m or nil
end

local majModule = charger("maj.lua")
if not majModule then
  printError("[MAJ] maj/maj.lua introuvable ou invalide : mise a jour impossible.")
  return
end
local cfg = charger("config_maj.lua") or {}

--------------------------------------------------------------------------------
-- Journal : une seule ouverture de fichier par execution. Une mise a jour
-- ecrit peu, mais elle tourne au demarrage de CHAQUE poste du serveur.
--------------------------------------------------------------------------------

local enAttente = {}

local function journal(niveau, etape, message)
  local ligne = ("[%s] [%s] [etape: %s] %s")
    :format(os.date("!%Y-%m-%d %H:%M:%S", math.floor((os.epoch("utc") or 0) / 1000)),
            niveau, etape, tostring(message))
  enAttente[#enAttente + 1] = ligne
  local couleur = (niveau == "ERREUR" and colors.red)
    or (niveau == "AVERT" and colors.orange) or nil
  if couleur and term.isColour and term.isColour() then
    local avant = term.getTextColour()
    term.setTextColour(couleur) print(ligne) term.setTextColour(avant)
  else
    print(ligne)
  end
end

local function viderJournal()
  if #enAttente == 0 or not cfg.fichierJournal then return end
  pcall(function()
    local dossier = fs.getDir(cfg.fichierJournal)
    if dossier ~= "" and not fs.exists(dossier) then fs.makeDir(dossier) end
    local f = fs.open(cfg.fichierJournal, "a")
    if f then
      for _, l in ipairs(enAttente) do f.writeLine(l) end
      f.close()
    end
  end)
  enAttente = {}
end

--------------------------------------------------------------------------------
-- Environnement injecte
--------------------------------------------------------------------------------

-- CC interrompt un programme qui calcule trop longtemps sans rendre la main.
-- Les sommes de controle portent sur des fichiers entiers : sans cette
-- respiration, un gros fichier ferait tuer la mise a jour par le systeme.
local function respirer()
  os.queueEvent("maj_respiration")
  os.pullEvent("maj_respiration")
end

--[[
  Transport de repli par rednet, actif seulement si la configuration le
  demande. Il fait confiance au PREMIER poste qui repond : sur un serveur ou
  n'importe qui peut poser un ordinateur, c'est une porte ouverte. C'est
  pourquoi il est a false par defaut.
]]
local function transportReseau(cheminDepot)
  if not cfg.replliReseau then return nil, "repli reseau desactive en configuration" end
  local cote
  for _, nom in ipairs(peripheral.getNames()) do
    if peripheral.getType(nom) == "modem" then cote = nom break end
  end
  if not cote then return nil, "aucun modem pour le repli reseau" end
  if not rednet.isOpen(cote) then pcall(rednet.open, cote) end

  local protocole = cfg.protocoleMaj or "frenchnet_maj"
  pcall(rednet.broadcast, { protocole = "FRENCHNET_MAJ_DEMANDE", fichier = cheminDepot },
    protocole)

  -- UN seul minuteur, arme avant la boucle : en creer un par tour en laisserait
  -- des dizaines en vol, et CC les compte.
  local delai = cfg.delaiReseau or 5
  local minuteur = os.startTimer(delai)
  while true do
    local e = table.pack(os.pullEventRaw())
    if e[1] == "rednet_message" then
      local message, proto = e[3], e[4]
      if proto == protocole and type(message) == "table"
         and message.protocole == "FRENCHNET_MAJ_REPONSE"
         and message.fichier == cheminDepot and type(message.contenu) == "string" then
        pcall(os.cancelTimer, minuteur)
        return message.contenu
      end
    elseif e[1] == "timer" and e[2] == minuteur then
      return nil, ("aucun poste de distribution n'a repondu en %ds"):format(delai)
    end
  end
end

local M = majModule.nouveau(cfg, {
  fs = fs, http = http, load = load, respirer = respirer,
  reseau = cfg.replliReseau and transportReseau or nil,
  horloge = function() return math.floor((os.epoch("utc") or 0) / 1000) end,
}, journal)

local POSTE = cfg.poste or "command"

--------------------------------------------------------------------------------
-- Commandes
--------------------------------------------------------------------------------

local function annoncerSource()
  if http then
    journal("INFO", "maj", "source : " .. tostring(cfg.urlBase))
  elseif cfg.replliReseau then
    journal("AVERT", "maj", "HTTP indisponible sur ce serveur : repli sur un " ..
      "poste de distribution par rednet")
  else
    journal("ERREUR", "maj", "HTTP est DESACTIVE sur ce serveur et le repli reseau " ..
      "n'est pas autorise : aucune mise a jour possible. C'est une decision " ..
      "d'administrateur serveur, pas un defaut du programme.")
    return false
  end
  return true
end

local function verifier()
  if not annoncerSource() then return end
  local texte, transport = M:recuperer(cfg.cheminManifeste or "manifeste.lua")
  if not texte then
    journal("ERREUR", "maj", "manifeste : " .. tostring(transport))
    return
  end
  local manifeste, err = M:analyserManifeste(texte)
  if not manifeste then
    journal("ERREUR", "maj", err)
    return
  end

  local plan, identiques, motif = M:planifier(manifeste, POSTE)
  if not plan then
    journal("ERREUR", "maj", motif)
    return
  end

  journal("INFO", "maj", ("depot en version %s (%s), poste '%s'")
    :format(manifeste.version, manifeste.genere or "?", POSTE))
  if #plan == 0 then
    journal("INFO", "maj", ("a jour : %d fichier(s) identiques"):format(identiques))
    return
  end
  journal("AVERT", "maj", ("%d fichier(s) a installer, %d inchanges"):format(#plan, identiques))
  for _, e in ipairs(plan) do
    print(("  %s %s"):format(e.nouveau and "+" or "~", e.cible))
  end
  print("")
  print("Rien n'a ete ecrit. 'update' pour installer, 'update appliquer' pour forcer.")
end

local function redemarrerSiDemande()
  if cfg.redemarrerApres == false then
    journal("AVERT", "maj", "fichiers installes, mais le poste tourne encore sur " ..
      "l'ANCIEN code charge en memoire. Redemarrez pour qu'ils prennent effet.")
    return
  end
  journal("INFO", "maj",
    ("redemarrage dans %ds (Ctrl+T pour annuler)"):format(cfg.delaiRedemarrage or 5))
  viderJournal()
  sleep(cfg.delaiRedemarrage or 5)
  os.reboot()
end

local function installer(forcer)
  if not annoncerSource() then return end

  --[[
    'automatique = false' n'empeche pas de TELECHARGER et de VERIFIER : cela
    n'engage rien. Seule la bascule attend un geste humain. Preparer d'avance
    fait que le jour ou l'operateur dit oui, l'installation est instantanee et
    hors ligne - y compris si le depot est injoignable a ce moment-la.
  ]]
  -- Ecrit en clair : la version precedente enchainait 'and'/'or' de facon
  -- illisible, et se trompait - un poste en politique manuelle installait
  -- quand meme des qu'on le forcait a ne pas forcer.
  local resultat, detail = M:cycle(POSTE, {
    forcer = forcer == true,
    preparerSeulement = (cfg.automatique == false) and not forcer,
  })

  if resultat == majModule.RESULTATS.A_JOUR then
    journal("INFO", "maj", detail)
  elseif resultat == majModule.RESULTATS.PREPARE then
    journal("AVERT", "maj", detail .. " (politique manuelle : automatique = false)")
  elseif resultat == majModule.RESULTATS.INSTALLE then
    journal("INFO", "maj", detail)
    redemarrerSiDemande()
  elseif resultat == majModule.RESULTATS.REPORTE then
    journal("AVERT", "maj", "installation reportee : " .. tostring(detail))
  else
    journal("ERREUR", "maj", tostring(detail))
  end
  return resultat
end

local function appliquer()
  --[[
    Forcage explicite : l'operateur est devant l'ordinateur et sait ce qu'il
    fait. C'est le seul chemin qui ignore le verrou d'occupation - un automate
    ne doit jamais pouvoir couper un poste en plein engagement, un humain si.
  ]]
  journal("AVERT", "maj", "installation FORCEE demandee par l'operateur : " ..
    "le verrou d'occupation est ignore")
  installer(true)
end

local function restaurer()
  local rendus, supprimes = M:restaurer()
  if rendus + supprimes == 0 then
    journal("AVERT", "maj", "aucune sauvegarde a restaurer")
    return
  end
  journal("INFO", "maj",
    ("%d fichier(s) restaures, %d supprimes"):format(rendus, supprimes))
  redemarrerSiDemande()
end

local function etat()
  local e = M:lireEtat()
  print("Poste      : " .. POSTE)
  print("Version    : " .. tostring(e.version or "inconnue"))
  if e.prepare then
    print("Preparee   : " .. tostring(e.prepare) .. "  ('update appliquer' pour l'installer)")
  end
  print("Source     : " .. tostring(cfg.urlBase))
  print("Politique  : " .. (cfg.automatique and "automatique" or "manuelle"))
  print("HTTP       : " .. (http and "disponible" or "DESACTIVE sur ce serveur"))
  local occupe, motif = M:occupation()
  print("Occupation : " .. (occupe and ("OCCUPE - " .. motif) or motif))
  local sauvegarde = M:dossierSauvegarde()
  print("Retour     : " .. (fs.exists(sauvegarde)
    and "possible ('update restaurer')" or "aucune sauvegarde"))
end

--[[
  Service de verification periodique. Il PREPARE ; il ne bascule que si le
  poste n'est pas occupe et que la politique l'autorise. Lance en parallele du
  poste, jamais a sa place.
]]
local function auto()
  local intervalle = cfg.intervalleVerification or 0
  if intervalle <= 0 then
    journal("INFO", "maj", "verification periodique desactivee (intervalleVerification = 0)")
    return
  end
  journal("INFO", "maj", ("verification toutes les %ds"):format(intervalle))
  while true do
    local ok, err = pcall(installer, false)
    if not ok then journal("ERREUR", "maj", "cycle interrompu : " .. tostring(err)) end
    viderJournal()
    -- Attente insensible a Ctrl+T, comme partout ailleurs dans ce depot.
    local minuteur = os.startTimer(intervalle)
    repeat
      local e, id = os.pullEventRaw()
    until e == "timer" and id == minuteur
  end
end

--------------------------------------------------------------------------------

local COMMANDES = {
  maj = function() installer(false) end,
  verifier = verifier, verify = verifier,
  appliquer = appliquer, apply = appliquer,
  restaurer = restaurer, rollback = restaurer,
  etat = etat, status = etat,
  auto = auto,
}

local commande = COMMANDES[ARGUMENT]
if not commande then
  print("Usage : update [verifier|appliquer|restaurer|etat|auto]")
  return
end

local ok, err = pcall(commande)
if not ok then journal("ERREUR", "maj", tostring(err)) end
viderJournal()
