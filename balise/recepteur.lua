--[[----------------------------------------------------------------------------
  RECEPTEUR / MONITEUR DE CONSTELLATION - FRENCHNET
  --------------------------------------------------------------------------
  Programme de controle, a installer sur n'importe quel ordinateur equipe d'un
  modem Ender (tour de controle, avion, poste au sol). Il n'est PAS necessaire
  au fonctionnement des balises : il sert a verifier d'un coup d'oeil que la
  constellation emet correctement.

  Affiche pour chaque balise : identifiant, X/Y/Z, age de la derniere trame,
  role d'hote GPS, et distance depuis le recepteur si celui-ci sait se situer.

  Usage : recepteur [protocole]
--------------------------------------------------------------------------------]]

local PROTOCOLE = ({ ... })[1] or "frenchnet_balise"
local SEUIL_ALERTE = 30 -- secondes sans trame avant de signaler une balise muette

local balises = {}
local maPosition = nil

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

-- Position du recepteur (facultatif) : permet d'afficher les distances.
do
  local x, y, z = gps.locate(3, false)
  if x then maPosition = { x = x, y = y, z = z } end
end

------------------------------------------------------------------------ affichage
local function distance(p)
  if not maPosition then return nil end
  local dx, dy, dz = p.x - maPosition.x, p.y - maPosition.y, p.z - maPosition.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function redessiner()
  term.clear()
  term.setCursorPos(1, 1)
  local largeur = term.getSize()

  print("CONSTELLATION FRENCHNET - protocole '" .. PROTOCOLE .. "'")
  if maPosition then
    print(string.format("Recepteur : X=%.0f Y=%.0f Z=%.0f", maPosition.x, maPosition.y, maPosition.z))
  else
    print("Recepteur : position inconnue (moins de 4 hotes GPS a portee)")
  end
  print(string.rep("-", largeur))

  local noms = {}
  for identifiant in pairs(balises) do noms[#noms + 1] = identifiant end
  table.sort(noms)

  if #noms == 0 then
    print("En attente de trames...")
  end

  local maintenant = os.clock()
  local actives = 0

  for _, identifiant in ipairs(noms) do
    local b = balises[identifiant]
    local age = maintenant - b.vuA
    local muette = age > SEUIL_ALERTE

    if term.isColour and term.isColour() then
      term.setTextColour(muette and colors.red or colors.lime)
    end
    write(string.format("%-14s", identifiant:sub(1, 14)))

    if term.isColour and term.isColour() then term.setTextColour(colors.white) end
    write(string.format(" %6.0f %4.0f %6.0f", b.x, b.y, b.z))

    local d = distance(b)
    if d then write(string.format("  %6.0fm", d)) end
    write(muette and string.format("  MUETTE %ds", math.floor(age))
                 or string.format("  %ds", math.floor(age)))
    if b.hoteGps then write(" GPS") end
    print("")

    if not muette then actives = actives + 1 end
  end

  print(string.rep("-", largeur))
  print(string.format("%d balise(s) active(s) / %d connue(s) - Ctrl+T pour quitter",
    actives, #noms))
end

--------------------------------------------------------------------------- boucle
local function ecouter()
  while true do
    local ok, expediteur, message = pcall(rednet.receive, PROTOCOLE, 5)
    if ok and expediteur and type(message) == "table"
       and message.protocole == "FRENCHNET_BALISE" then
      balises[tostring(message.identifiant)] = {
        x = message.x or 0, y = message.y or 0, z = message.z or 0,
        hoteGps = message.hoteGps,
        idOrdinateur = expediteur,
        vuA = os.clock(),
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
