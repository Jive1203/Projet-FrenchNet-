--[[----------------------------------------------------------------------------
  CABLAGE ET PILOTAGE MANUEL - AUTOPILOTE FRENCHNET
  --------------------------------------------------------------------------
  Outil de mise en service d'un vehicule. Il sert a deux choses :

    1. VERIFIER LE CABLAGE. Il envoie les commandes moteur a la main, par le
       MEME code que l'autopilote en vol, et affiche en temps reel le niveau
       redstone reellement emis sur chaque face de l'ordinateur. Ce qu'il
       montre est donc vrai : si le vehicule ne bouge pas, le probleme est
       dans le montage, pas dans le programme.

    2. PILOTER A LA MAIN. Avancer, reculer, pivoter, monter, descendre,
       translater : de quoi sortir un vehicule d'un hangar ou le rapatrier
       sans autopilote.

  Aucun GPS n'est necessaire : l'outil ne se localise pas, il pousse.

  SECURITE : les commandes retombent a zero des que la touche est relachee,
  et un homme mort coupe tout si plus rien n'est frappe pendant quelques
  secondes. Le maintien (touche M) desactive l'homme mort : a n'utiliser que
  pour observer une manoeuvre, jamais pour laisser un vehicule sans surveillance.

  Usage :  cablage
--------------------------------------------------------------------------------]]

local CHEMIN_MODULE = "/autopilote/autopilote.lua"
local autopilote = dofile(CHEMIN_MODULE)

local DELAI_HOMME_MORT = 2.0   -- secondes sans frappe avant coupure
local PERIODE_ECRAN    = 0.15

--------------------------------------------------------------------------------
-- 1. AXES ET CONVENTIONS DE SIGNE
--    C'est la table de verite du cablage : elle dit ce que CHAQUE commande
--    doit produire sur le vehicule. Si l'observation ne correspond pas, l'axe
--    est branche a l'envers.
--------------------------------------------------------------------------------

local AXES = {
  { cle = "avance",   libelle = "AVANCE",   axeGains = "avance",
    positif = "avance (nez en avant)", negatif = "recule" },
  { cle = "lacet",    libelle = "LACET",    axeGains = "cap",
    positif = "pivote a TRIBORD (droite)", negatif = "pivote a BABORD (gauche)" },
  { cle = "vertical", libelle = "VERTICAL", axeGains = "altitude",
    positif = "MONTE", negatif = "DESCEND" },
  { cle = "lateral",  libelle = "LATERAL",  axeGains = "derive",
    positif = "glisse a TRIBORD", negatif = "glisse a BABORD" },
}

--------------------------------------------------------------------------------
-- 2. AFFICHAGE
--------------------------------------------------------------------------------

local function couleurDisponible() return term.isColour and term.isColour() end
local function fond(c) term.setBackgroundColour(couleurDisponible() and c or colors.black) end
local function encre(c) term.setTextColour(couleurDisponible() and c or colors.white) end

local function ecrireA(x, y, texte, largeur)
  term.setCursorPos(x, y)
  texte = tostring(texte)
  if largeur then
    if #texte > largeur then texte = texte:sub(1, largeur)
    else texte = texte .. string.rep(" ", largeur - #texte) end
  end
  term.write(texte)
end

--- Jauge centree sur zero : la moitie gauche est le negatif, la droite le positif.
local function jauge(valeur, largeur)
  local demi = math.floor((largeur - 1) / 2)
  local rempli = math.floor(math.abs(valeur) * demi + 0.5)
  local gauche = string.rep(" ", demi - (valeur < 0 and rempli or 0))
    .. string.rep("\127", valeur < 0 and rempli or 0)
  local droite = string.rep("\127", valeur > 0 and rempli or 0)
    .. string.rep(" ", demi - (valeur > 0 and rempli or 0))
  return "[" .. gauche .. "|" .. droite .. "]"
end

--- Resume lisible du cablage d'un axe, tel qu'il est configure.
local function descriptionCablage(reglageAxe)
  if not reglageAxe or (reglageAxe.mode or "aucun") == "aucun" then
    return "non equipe", nil
  end
  if reglageAxe.mode == "analogique" then
    return string.format("analogique %s (%d+/-%d)", tostring(reglageAxe.cote),
      reglageAxe.neutre or 7, reglageAxe.amplitude or 7), { reglageAxe.cote }
  end
  if reglageAxe.mode == "bipolaire" then
    return string.format("bipolaire +%s / -%s", tostring(reglageAxe.cotePositif),
      tostring(reglageAxe.coteNegatif)),
      { reglageAxe.cotePositif, reglageAxe.coteNegatif }
  end
  if reglageAxe.mode == "peripherique" then
    return string.format("peripherique %s.%s", tostring(reglageAxe.nom),
      tostring(reglageAxe.methode)), nil
  end
  return tostring(reglageAxe.mode), nil
end

--------------------------------------------------------------------------------
-- 3. PROGRAMME
--------------------------------------------------------------------------------

local okConfig, config = pcall(autopilote.chargerConfiguration)
if not okConfig then
  printError("Configuration illisible : " .. tostring(config))
  print("Corrigez /autopilote/config_vehicule.lua (ou lancez 'interface').")
  return
end

local sorties = autopilote.creerSorties(config)

local etat = {
  commandes  = { avance = 0, lacet = 0, vertical = 0, lateral = 0 },
  puissance  = 0.5,
  axe        = 1,
  maintien   = false,
  modifie    = false,
  dernierAppui = os.clock(),
  message    = "Fleches : avancer et pivoter   PageUp/Down : monter et descendre",
  couleurMessage = colors.lightGray,
}

local function signaler(texte, couleur)
  etat.message = texte
  etat.couleurMessage = couleur or colors.lightGray
end

local function appliquer()
  sorties.appliquer({
    avance   = etat.commandes.avance,
    lacet    = etat.commandes.lacet,
    vertical = etat.commandes.vertical,
    lateral  = etat.commandes.lateral,
  })
end

local function toutAZero()
  for _, axe in ipairs(AXES) do etat.commandes[axe.cle] = 0 end
  appliquer()
end

local function dessiner()
  local largeur, hauteur = term.getSize()
  fond(colors.black) encre(colors.white)
  term.clear()

  fond(colors.cyan) encre(colors.black)
  ecrireA(1, 1, "", largeur)
  ecrireA(2, 1, "FRENCHNET // CABLAGE ET PILOTAGE MANUEL")
  ecrireA(largeur - #tostring(config.identifiant) - 1, 1, tostring(config.identifiant))

  fond(colors.black)
  local y = 3
  for index, axe in ipairs(AXES) do
    local reglageAxe = ((config.sorties or {}).axes or {})[axe.cle]
    local texteCablage, cotes = descriptionCablage(reglageAxe)
    local valeur = etat.commandes[axe.cle] or 0
    local actif = (index == etat.axe)

    encre(actif and colors.yellow or colors.white)
    ecrireA(2, y, (actif and ">" or " ") .. " " .. axe.libelle, 11)
    encre(math.abs(valeur) > 0.01 and colors.lime or colors.lightGray)
    ecrireA(13, y, jauge(valeur, 15))
    encre(colors.white)
    ecrireA(29, y, string.format("%+5.2f", valeur), 6)

    encre(reglageAxe and reglageAxe.inverse and colors.orange or colors.lightGray)
    local suffixe = (reglageAxe and reglageAxe.inverse) and "  INVERSE" or ""
    ecrireA(36, y, texteCablage .. suffixe, largeur - 36)

    -- Niveaux redstone reellement emis, face par face.
    y = y + 1
    encre(colors.lightGray)
    local details = ""
    if cotes then
      for _, cote in ipairs(cotes) do
        if cote then
          details = details .. string.format("%s=%d  ", cote, sorties.niveaux[cote] or 0)
        end
      end
    end
    ecrireA(13, y, details, largeur - 13)
    y = y + 1
  end

  encre(colors.lightGray)
  ecrireA(2, y, string.rep("-", largeur - 2))
  y = y + 1
  encre(colors.white)
  ecrireA(2, y, string.format("puissance %3d%%   %s   axe teste : %s",
    math.floor(etat.puissance * 100 + 0.5),
    etat.maintien and "MAINTIEN ACTIF" or "homme mort actif",
    AXES[etat.axe].libelle), largeur - 2)

  encre(colors.lightGray)
  ecrireA(1, hauteur - 2,
    " Fleches avance/lacet  PgUp/PgDn haut/bas  Home/End lateral", largeur)
  ecrireA(1, hauteur - 1,
    " Tab axe  T test guide  I inverser  1-9/0 puissance  M maintien  S sauver  Q", largeur)

  fond(colors.gray) encre(etat.couleurMessage)
  ecrireA(1, hauteur, " " .. etat.message, largeur)
  fond(colors.black)
end

--------------------------------------------------------------------------------
-- 4. TEST GUIDE D'UN AXE
--    Pousse l'axe dans un sens, puis dans l'autre, et demande a l'operateur ce
--    qu'il a vu. Une reponse "non" inscrit l'inversion dans la configuration :
--    plus besoin de redemonter quoi que ce soit sur le vehicule.
--------------------------------------------------------------------------------

local function testGuide()
  local axe = AXES[etat.axe]
  local reglageAxe = ((config.sorties or {}).axes or {})[axe.cle]
  if not reglageAxe or (reglageAxe.mode or "aucun") == "aucun" then
    signaler("Axe " .. axe.libelle .. " non equipe : rien a tester", colors.orange)
    return
  end

  local function pousser(valeur, duree, texte)
    etat.commandes[axe.cle] = valeur
    appliquer()
    local fin = os.clock() + duree
    while os.clock() < fin do
      signaler(texte, colors.yellow)
      dessiner()
      sleep(0.2)
    end
    etat.commandes[axe.cle] = 0
    appliquer()
  end

  pousser(etat.puissance, 2.5, "TEST : le vehicule doit " .. axe.positif)
  sleep(1)
  pousser(-etat.puissance, 2.5, "TEST : le vehicule doit " .. axe.negatif)

  signaler("Le vehicule a-t-il fait l'inverse de ce qui etait annonce ? O = oui, N = non",
    colors.yellow)
  dessiner()
  while true do
    local _, touche = os.pullEvent("key")
    if touche == keys.o then
      reglageAxe.inverse = not reglageAxe.inverse
      etat.modifie = true
      signaler("Axe " .. axe.libelle .. " inverse. S pour enregistrer.", colors.lime)
      return
    elseif touche == keys.n or touche == keys.q then
      signaler("Axe " .. axe.libelle .. " conforme.", colors.lime)
      return
    end
  end
end

local function sauvegarder()
  local fichier = fs.open(autopilote.CHEMIN_CONFIG_DEFAUT, "w")
  if not fichier then
    signaler("Ecriture impossible : " .. autopilote.CHEMIN_CONFIG_DEFAUT, colors.red)
    return
  end
  fichier.write(autopilote.serialiserConfig(config))
  fichier.close()
  etat.modifie = false
  signaler("Cablage enregistre dans " .. autopilote.CHEMIN_CONFIG_DEFAUT, colors.lime)
end

--------------------------------------------------------------------------------
-- 5. BOUCLE PRINCIPALE
--------------------------------------------------------------------------------

local TOUCHES = {
  [keys.up]       = { "avance",   1 },
  [keys.down]     = { "avance",  -1 },
  [keys.right]    = { "lacet",    1 },
  [keys.left]     = { "lacet",   -1 },
  [keys.pageUp]   = { "vertical", 1 },
  [keys.pageDown] = { "vertical", -1 },
  [keys["end"]]   = { "lateral",  1 },
  [keys.home]     = { "lateral", -1 },
}

local function boucle()
  local minuteur = os.startTimer(PERIODE_ECRAN)
  while true do
    dessiner()
    local evenement = { os.pullEvent() }
    local nom = evenement[1]

    if nom == "timer" and evenement[2] == minuteur then
      minuteur = os.startTimer(PERIODE_ECRAN)
      if not etat.maintien and (os.clock() - etat.dernierAppui) > DELAI_HOMME_MORT then
        local actif = false
        for _, axe in ipairs(AXES) do
          if math.abs(etat.commandes[axe.cle] or 0) > 0 then actif = true end
        end
        if actif then
          toutAZero()
          signaler("Homme mort : commandes coupees apres "
            .. DELAI_HOMME_MORT .. "s sans ordre", colors.orange)
        end
      end
      appliquer()

    elseif nom == "key" then
      local touche = evenement[2]
      etat.dernierAppui = os.clock()
      local mouvement = TOUCHES[touche]

      if mouvement then
        etat.commandes[mouvement[1]] = mouvement[2] * etat.puissance
        appliquer()
      elseif touche == keys.tab then
        etat.axe = etat.axe % #AXES + 1
      elseif touche == keys.t then
        testGuide()
      elseif touche == keys.i then
        local reglageAxe = ((config.sorties or {}).axes or {})[AXES[etat.axe].cle]
        if reglageAxe then
          reglageAxe.inverse = not reglageAxe.inverse
          etat.modifie = true
          signaler(AXES[etat.axe].libelle .. (reglageAxe.inverse and " inverse" or " remis a l'endroit")
            .. ". S pour enregistrer.", colors.lime)
        end
      elseif touche == keys.m then
        etat.maintien = not etat.maintien
        signaler(etat.maintien
          and "MAINTIEN : l'homme mort est desactive, ne quittez pas des yeux"
          or "Homme mort reactive", etat.maintien and colors.orange or colors.lime)
      elseif touche == keys.s then
        sauvegarder()
      elseif touche == keys.space then
        toutAZero()
        signaler("Arret : toutes les commandes a zero", colors.lime)
      elseif touche == keys.q or touche == keys.backspace then
        return
      else
        -- Les touches chiffrees s'appellent 'one'..'nine' et 'zero' dans CC.
        local CHIFFRES = { one = 0.1, two = 0.2, three = 0.3, four = 0.4, five = 0.5,
          six = 0.6, seven = 0.7, eight = 0.8, nine = 0.9, zero = 1.0 }
        for nomTouche, puissance in pairs(CHIFFRES) do
          if keys[nomTouche] and touche == keys[nomTouche] then
            etat.puissance = puissance
            signaler(string.format("puissance %d%%", math.floor(puissance * 100 + 0.5)))
          end
        end
      end

    elseif nom == "key_up" then
      local mouvement = TOUCHES[evenement[2]]
      if mouvement and not etat.maintien then
        etat.commandes[mouvement[1]] = 0
        appliquer()
      end

    elseif nom == "terminate" then
      return
    end
  end
end

local ok, err = pcall(boucle)

-- Quoi qu'il arrive, on ne laisse jamais un moteur sous tension.
pcall(sorties.neutraliser)
term.setBackgroundColour(colors.black)
term.setTextColour(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("Cablage : commandes neutralisees.")
if etat.modifie then
  print("ATTENTION : des inversions n'ont pas ete enregistrees (touche S).")
end
if not ok and tostring(err):find("Terminated", 1, true) == nil then
  printError(tostring(err))
end
