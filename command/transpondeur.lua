--[[----------------------------------------------------------------------------
  TRANSPONDEUR FRENCHNET - a installer sur un VEHICULE
  --------------------------------------------------------------------------
  Programme a poser sur l'ordinateur embarque d'un aeronef ou d'un vehicule
  terrestre, avec un modem Ender. Il diffuse en continu le code transpondeur
  du vehicule ainsi que sa position, ce qui permet a FrenchNet Command de
  l'identifier comme allie ou comme porteur du code general.

  SANS CE PROGRAMME, OU AVEC UN CODE INVALIDE, LE VEHICULE EST CLASSE
  « INCONNU » - avec toutes les consequences prevues par la doctrine de zone.

  Usage : transpondeur [code]
          transpondeur                 -> lit transpondeur.cfg
  Le code peut aussi etre place dans le fichier /transpondeur.cfg (une ligne).

  La position est resolue par GPS (constellation de balises FrenchNet). Sans
  GPS, le transpondeur emet quand meme son code : Command l'appariera alors
  par nom declare, a condition que ce nom corresponde a l'echo radar.
--------------------------------------------------------------------------------]]

local PROTOCOLE    = "frenchnet_transpondeur"
local INTERVALLE   = 4      -- secondes ; Command accepte un code jusqu'a 15 s
local DELAI_GPS    = 3
local CHEMIN_CFG   = "/transpondeur.cfg"

local arguments = { ... }

--------------------------------------------------------------------- code emis
local code = arguments[1]
if not code and fs.exists(CHEMIN_CFG) then
  local f = fs.open(CHEMIN_CFG, "r")
  if f then
    code = (f.readLine() or ""):gsub("%s+$", "")
    f.close()
  end
end

if not code or code == "" then
  printError("Aucun code transpondeur.")
  printError("Usage : transpondeur <code>")
  printError("ou placez le code dans " .. CHEMIN_CFG)
  return
end

-- Le code saisi en argument est memorise, pour survivre a un redemarrage.
if arguments[1] then
  local f = fs.open(CHEMIN_CFG, "w")
  if f then f.writeLine(code) f.close() end
end

local nom = os.getComputerLabel() or ("VEH-" .. os.getComputerID())

-------------------------------------------------------------------------- modem
local cote
for _, peripherique in ipairs(peripheral.getNames()) do
  if peripheral.getType(peripherique) == "modem" then
    local modem = peripheral.wrap(peripherique)
    local ok, sansFil = pcall(modem.isWireless)
    if ok and sansFil then cote = peripherique break end
    cote = cote or peripherique
  end
end

if not cote then
  printError("Aucun modem detecte. Ajoutez un modem Ender au vehicule.")
  return
end

rednet.open(cote)

------------------------------------------------------------------------ boucle
term.clear()
term.setCursorPos(1, 1)
print("TRANSPONDEUR FRENCHNET")
print("Vehicule : " .. nom)
print("Code     : " .. code)
print("Emission toutes les " .. INTERVALLE .. "s - Ctrl+T pour arreter")
print(string.rep("-", 40))

local emissions, sansGps = 0, 0

while true do
  local x, y, z = gps.locate(DELAI_GPS, false)
  if not x then sansGps = sansGps + 1 end

  local ok = pcall(rednet.broadcast, {
    protocole   = "FRENCHNET_TRANSPONDEUR",
    identifiant = nom,
    nom         = nom,
    code        = code,
    x = x, y = y, z = z,
  }, PROTOCOLE)

  emissions = emissions + 1
  term.setCursorPos(1, 6)
  term.clearLine()
  if ok and x then
    write(string.format("Emission %d - X=%.0f Y=%.0f Z=%.0f", emissions, x, y, z))
  elseif ok then
    write(string.format("Emission %d - position GPS indisponible (%d fois)", emissions, sansGps))
  else
    write(string.format("Emission %d - ECHEC RESEAU", emissions))
  end

  sleep(INTERVALLE)
end
