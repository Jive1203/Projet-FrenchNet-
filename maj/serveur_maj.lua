--[[----------------------------------------------------------------------------
  FRENCHNET - POSTE DE DISTRIBUTION DES MISES A JOUR
  Pour les serveurs ou HTTP est coupe sur les ordinateurs du jeu.

  UN SEUL ordinateur telecharge depuis le depot ; les autres lui demandent les
  fichiers par rednet. Cela evite aussi que quinze postes martelent GitHub a
  chaque demarrage du serveur.

  CE QU'IL FAUT SAVOIR AVANT DE S'EN SERVIR
  Ce poste distribue du code executable a tout ordinateur qui le demande, et
  les postes clients font confiance au PREMIER qui repond. Sur un serveur ou
  n'importe qui peut poser un ordinateur et un modem, quelqu'un peut donc
  repondre a votre place et faire executer son code par votre poste de
  commandement. Il n'y a pas de remede propre : CC: Tweaked n'offre aucune
  signature.

  Deux attenuations, et elles valent ce qu'elles valent :
    - 'postesAutorises' limite les identifiants d'ordinateur servis ;
    - 'motDePasse' exige un secret partage dans la demande.
  Les deux se contournent par quelqu'un qui ecoute le reseau. Si votre serveur
  n'est pas de confiance, mettez a jour a la main.

  Le poste ne sert QUE des fichiers listes dans le manifeste : une demande
  pour un chemin arbitraire est refusee. Sans cela, n'importe qui pourrait
  faire lire n'importe quel fichier de cet ordinateur - y compris les
  configurations, qui contiennent les codes transpondeur et le mot de passe de
  la console.
--------------------------------------------------------------------------------]]

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
local cfg = charger("config_maj.lua") or {}
if not majModule then
  printError("maj/maj.lua introuvable : distribution impossible.")
  return
end

if not http then
  printError("HTTP est DESACTIVE sur cet ordinateur.")
  printError("Le poste de distribution est justement celui qui doit l'avoir :")
  printError("demandez a l'administrateur d'autoriser raw.githubusercontent.com,")
  printError("au moins pour cet ordinateur.")
  return
end

local PROTOCOLE = cfg.protocoleMaj or "frenchnet_maj"
local AUTORISES = cfg.postesAutorises        -- nil = tous
local SECRET    = cfg.motDePasseDistribution -- nil = aucun

local M = majModule.nouveau(cfg, {
  fs = fs, http = http, load = load,
  horloge = function() return math.floor((os.epoch("utc") or 0) / 1000) end,
}, function(niveau, _, message) print(("[%s] %s"):format(niveau, message)) end)

--------------------------------------------------------------------------------

local cote
for _, nom in ipairs(peripheral.getNames()) do
  if peripheral.getType(nom) == "modem" then cote = nom break end
end
if not cote then
  printError("Aucun modem : ce poste ne peut rien distribuer.")
  return
end
rednet.open(cote)

term.clear() term.setCursorPos(1, 1)
print("POSTE DE DISTRIBUTION FRENCHNET")
print("ordinateur #" .. os.getComputerID() .. "  protocole " .. PROTOCOLE)
print("source : " .. tostring(cfg.urlBase))
print(AUTORISES and ("postes autorises : " .. #AUTORISES) or
  "postes autorises : TOUS (voir postesAutorises)")
print(SECRET and "mot de passe : exige" or "mot de passe : AUCUN")
print("")

--[[
  Cache des fichiers servis. Sans lui, dix postes qui redemarrent ensemble -
  ce qui arrive a chaque relance du serveur - declenchent dix telechargements
  identiques. Il est volontairement court : un cache long servirait l'ancienne
  version bien apres une correction urgente.
]]
local cache, cacheA = {}, {}
local DUREE_CACHE = cfg.dureeCache or 60

local function fichierAutorise(manifeste, chemin)
  for _, poste in pairs(manifeste.postes or {}) do
    for _, fichier in ipairs(poste.fichiers or {}) do
      if fichier.chemin == chemin then return true end
    end
  end
  return false
end

local function servir(chemin)
  local maintenant = os.clock()
  if cache[chemin] and (maintenant - (cacheA[chemin] or 0)) < DUREE_CACHE then
    return cache[chemin], "cache"
  end
  local contenu, motif = M:recuperer(chemin)
  if contenu then
    cache[chemin], cacheA[chemin] = contenu, maintenant
    return contenu, motif
  end
  return nil, motif
end

local servis, refuses = 0, 0

while true do
  -- pullEventRaw : Ctrl+T ne doit pas tuer la distribution en plein
  -- telechargement d'un autre poste.
  local e = table.pack(os.pullEventRaw())

  if e[1] == "terminate" then
    print("")
    print(("Arret. %d fichier(s) servis, %d refus."):format(servis, refuses))
    return

  elseif e[1] == "rednet_message" then
    local expediteur, message, protocole = e[2], e[3], e[4]
    if protocole == PROTOCOLE and type(message) == "table"
       and message.protocole == "FRENCHNET_MAJ_DEMANDE" then

      local refus
      if AUTORISES then
        local autorise = false
        for _, id in ipairs(AUTORISES) do if id == expediteur then autorise = true end end
        if not autorise then refus = "ordinateur non autorise" end
      end
      if not refus and SECRET and message.motDePasse ~= SECRET then
        refus = "mot de passe incorrect"
      end

      local chemin = message.fichier
      if not refus and type(chemin) ~= "string" then refus = "demande sans nom de fichier" end

      --[[
        Le manifeste fait office de liste blanche. Servir un chemin arbitraire
        laisserait n'importe qui lire n'importe quel fichier de cet
        ordinateur - a commencer par les configurations, qui contiennent les
        codes transpondeur et le mot de passe de la console.
      ]]
      if not refus and chemin ~= (cfg.cheminManifeste or "manifeste.lua") then
        local texteManifeste = servir(cfg.cheminManifeste or "manifeste.lua")
        local manifeste = texteManifeste and M:analyserManifeste(texteManifeste)
        if not manifeste then
          refus = "manifeste indisponible : rien ne peut etre autorise"
        elseif not fichierAutorise(manifeste, chemin) then
          refus = "fichier hors manifeste : " .. tostring(chemin)
        end
      end

      if refus then
        refuses = refuses + 1
        print(("REFUS  #%d  %s"):format(expediteur, refus))
        pcall(rednet.send, expediteur,
          { protocole = "FRENCHNET_MAJ_REFUS", fichier = chemin, motif = refus }, PROTOCOLE)
      else
        local contenu, source = servir(chemin)
        if contenu then
          servis = servis + 1
          print(("SERVI  #%d  %s (%d o, %s)"):format(expediteur, chemin, #contenu,
            tostring(source)))
          pcall(rednet.send, expediteur,
            { protocole = "FRENCHNET_MAJ_REPONSE", fichier = chemin, contenu = contenu },
            PROTOCOLE)
        else
          refuses = refuses + 1
          print(("ECHEC  #%d  %s : %s"):format(expediteur, chemin, tostring(source)))
          pcall(rednet.send, expediteur,
            { protocole = "FRENCHNET_MAJ_REFUS", fichier = chemin, motif = tostring(source) },
            PROTOCOLE)
        end
      end
    end
  end
end
