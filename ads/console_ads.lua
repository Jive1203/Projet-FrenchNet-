--[[----------------------------------------------------------------------------
  CONSOLE ADS - FRENCHNET / AERONAUTICS WARFARE
  --------------------------------------------------------------------------
  Moniteur de supervision, a installer sur n'importe quel ordinateur equipe
  d'un modem Ender (tour de controle, porte-nefs, poste au sol). Il n'est PAS
  necessaire au fonctionnement de l'ADS : il sert a voir d'un coup d'oeil
  quels navires sont armes, lesquels sont en engagement, et l'etat de leurs
  soutes a leurres.

  Cette console est en LECTURE SEULE. Elle n'envoie aucun ordre : l'ADS de
  chaque navire est independant par conception.

  Usage : console_ads [protocole]
--------------------------------------------------------------------------------]]

local PROTOCOLE = ({ ... })[1] or "frenchnet_ads"
local SEUIL_ALERTE = 15 -- secondes sans telemetrie avant de signaler un navire muet

local navires = {}

--------------------------------------------------------------------------- setup
local cote
for _, nom in ipairs(peripheral.getNames()) do
  if peripheral.getType(nom) == "modem" then
    local modem = peripheral.wrap(nom)
    local ok, sansFil = pcall(modem.isWireless)
    if ok and sansFil then
      cote = nom
      break
    end
  end
end

if not cote then
  printError("Aucun modem sans fil detecte. Ajoutez un modem Ender.")
  return
end

rednet.open(cote)

------------------------------------------------------------------------ affichage
local COULEURS_ETAT = {
  VEILLE     = colors.lime,
  MENACE     = colors.red,
  DEGAGEMENT = colors.orange,
  REPRISE    = colors.yellow,
}

local function redessiner()
  term.clear()
  term.setCursorPos(1, 1)
  local largeur = term.getSize()

  print("CONSOLE ADS FRENCHNET - protocole '" .. PROTOCOLE .. "'")
  print(string.rep("-", largeur))

  local noms = {}
  for identifiant in pairs(navires) do noms[#noms + 1] = identifiant end
  table.sort(noms)

  if #noms == 0 then
    print("En attente de telemetrie ADS...")
  end

  local maintenant = os.clock()
  local armes, enMenace = 0, 0

  for _, identifiant in ipairs(noms) do
    local n = navires[identifiant]
    local age = maintenant - n.vuA
    local muet = age > SEUIL_ALERTE

    if term.isColour and term.isColour() then
      term.setTextColour(muet and colors.gray or (COULEURS_ETAT[n.etat] or colors.white))
    end
    write(string.format("%-14s %-10s", identifiant:sub(1, 14), muet and "MUET" or n.etat))

    if term.isColour and term.isColour() then term.setTextColour(colors.white) end

    -- Ligne compacte : leurres restants, engagements, contacts suivis.
    write(string.format(" L=%-4s E=%-3d C=%-3d",
      n.leurresRestants and tostring(n.leurresRestants) or "inf",
      n.engagement or 0, n.contacts or 0))
    if muet then write(string.format(" %ds", math.floor(age))) end
    print("")

    -- Detail de la menace en cours : c'est l'information qui compte.
    if n.menace and not muet then
      if term.isColour and term.isColour() then term.setTextColour(colors.red) end
      print(string.format("   -> %s a %.0fb, impact dans %.1fs (passage a %.0fb)",
        tostring(n.menace.nom):sub(1, 18), n.menace.distance or 0,
        n.menace.tCpa or 0, n.menace.distanceCpa or 0))
      if term.isColour and term.isColour() then term.setTextColour(colors.white) end
    end

    if not muet then
      armes = armes + 1
      if n.etat == "MENACE" or n.etat == "DEGAGEMENT" then enMenace = enMenace + 1 end
    end
  end

  print(string.rep("-", largeur))
  print(string.format("%d arme(s) / %d connu(s) - %d en engagement - Ctrl+T pour quitter",
    armes, #noms, enMenace))
end

--------------------------------------------------------------------------- boucle
local function ecouter()
  while true do
    local ok, expediteur, message = pcall(rednet.receive, PROTOCOLE, 5)
    if ok and expediteur and type(message) == "table"
       and message.protocole == "FRENCHNET_ADS" and message.type == "ETAT" then
      navires[tostring(message.navire)] = {
        etat            = message.etat or "?",
        engagement      = message.engagement,
        contacts        = message.contacts,
        leurresRestants = message.leurresRestants,
        menace          = message.menace,
        idOrdinateur    = expediteur,
        vuA             = os.clock(),
      }
    end
  end
end

local function rafraichir()
  while true do
    pcall(redessiner)
    sleep(1)
  end
end

parallel.waitForAny(ecouter, rafraichir)
