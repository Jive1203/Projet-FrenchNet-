--[[----------------------------------------------------------------------------
  CALIBRATION AUTOMATIQUE DU CABLAGE - PROGRAMME DE MISE EN SERVICE
  --------------------------------------------------------------------------
  Trouve tout seul quelle face redstone commande quel axe, et ecrit le resultat
  dans config_vehicule.lua.

  C'est le pendant automatique de l'outil 'cablage' : celui-ci verifie un
  cablage deja declare, celui-la le decouvre.

  CE QUE LE VEHICULE VA FAIRE PENDANT LA MANOEUVRE
  -----------------------------------------------
  Il va bouger. Chaque face est mise sous tension quelques secondes, l'une
  apres l'autre, et le deplacement observe au GPS revele ce qu'elle commande.
  Entre deux essais, le programme repousse le vehicule dans l'autre sens quand
  il le peut, mais il derive quand meme. Trois conditions :

    1. en vol stationnaire, en l'air, loin du relief et des constructions ;
    2. la constellation de balises GPS doit etre montee et chargee ;
    3. personne a bord et personne dessous.

  Au moindre incident -- perte du GPS, eloignement excessif, Ctrl+T -- toutes
  les commandes retombent a zero.

  Usage :  calibrer
--------------------------------------------------------------------------------]]

local autopilote    = dofile("/autopilote/autopilote.lua")
local peripheriques = dofile("/autopilote/peripheriques.lua")
local calibration   = loadfile("/autopilote/calibration.lua")(autopilote)

--------------------------------------------------------------------------------
-- AFFICHAGE
--------------------------------------------------------------------------------

local function encre(c)
  if term.isColour and term.isColour() then pcall(term.setTextColour, c) end
end

local function titre(texte)
  encre(colors.yellow)
  print("")
  print("== " .. texte .. " ==")
  encre(colors.white)
end

local function paragraphe(texte, indentation)
  indentation = indentation or ""
  local largeur = (term.getSize() or 51) - #indentation - 1
  local ligne = ""
  for mot in tostring(texte):gmatch("%S+") do
    if #ligne + #mot + 1 > largeur then
      print(indentation .. ligne)
      ligne = mot
    else
      ligne = (ligne == "") and mot or (ligne .. " " .. mot)
    end
  end
  if ligne ~= "" then print(indentation .. ligne) end
end

local function demander(question, defaut)
  encre(colors.lightBlue)
  write(question .. (defaut and (" [" .. tostring(defaut) .. "]") or "") .. " : ")
  encre(colors.white)
  local reponse = read()
  if reponse == nil or reponse == "" then return defaut end
  return reponse
end

local function ouiNon(question, defaut)
  while true do
    local reponse = tostring(demander(question .. " (oui/non)",
      defaut and "oui" or "non")):lower()
    if reponse == "oui" or reponse == "o" then return true end
    if reponse == "non" or reponse == "n" then return false end
    print("Repondez par oui ou non.")
  end
end

--- Journal a l'ecran, colore par niveau. La calibration est longue : il faut
-- voir ce qu'elle fait pendant qu'elle le fait.
local function journalEcran()
  local j = {}
  local function poser(niveau, couleur)
    return function(etape, message)
      if niveau == "DEBUG" then return end
      encre(couleur)
      paragraphe(message)
      encre(colors.white)
    end
  end
  j.debug    = function() end
  j.info     = poser("INFO", colors.white)
  j.avert    = poser("AVERT", colors.orange)
  j.erreur   = poser("ERREUR", colors.red)
  j.critique = poser("CRITIQUE", colors.red)
  return j
end

--------------------------------------------------------------------------------
-- PROGRAMME
--------------------------------------------------------------------------------

term.clear()
term.setCursorPos(1, 1)
encre(colors.yellow)
print("=== FRENCHNET // CALIBRATION DU CABLAGE ===")
encre(colors.white)

local okConfig, config = pcall(autopilote.chargerConfiguration)
if not okConfig then
  printError("Configuration illisible : " .. tostring(config))
  print("Corrigez /autopilote/config_vehicule.lua (ou lancez 'interface').")
  return
end

print("Vehicule : " .. tostring(config.nom) .. " (" .. tostring(config.identifiant) .. ")")

--------------------------------------------------------------- peripheriques
local registre, erreurRegistre = peripheriques.charger(peripheriques.CHEMIN_REGISTRE)
if erreurRegistre then
  encre(colors.orange)
  paragraphe(erreurRegistre)
  encre(colors.white)
end

local inventaire = peripheriques.inventorier(registre)
local facesInterdites = peripheriques.facesInterdites(inventaire)

if #inventaire.quarantaine > 0 then
  titre("PERIPHERIQUES INCONNUS")
  encre(colors.red)
  paragraphe(#inventaire.quarantaine .. " peripherique(s) ne sont pas classes :")
  encre(colors.white)
  for _, fiche in ipairs(inventaire.quarantaine) do
    paragraphe(string.format("- '%s' (type '%s')", fiche.nom, tostring(fiche.type)))
  end
  encre(colors.orange)
  paragraphe("La calibration envoie du courant dans des sorties pour voir ce qui "
    .. "bouge. Tant qu'un bloc n'est pas identifie, cette manoeuvre peut tout "
    .. "aussi bien declencher un canon ou larguer une ancre.")
  encre(colors.white)
  paragraphe("Lancez le programme 'classer' : il presente les classes une par "
    .. "une et fait remplir les champs correspondants.")

  if (config.peripheriques or {}).exigerClassement == false then
    encre(colors.orange)
    paragraphe("'exigerClassement = false' : on continue quand meme, leurs faces "
      .. "ne seront pas essayees.")
    encre(colors.white)
  else
    return
  end
end

local classes = {}
for _, nom in ipairs(inventaire.ordre) do
  local fiche = inventaire.fiches[nom]
  local code = fiche.classe or "QUARANTAINE"
  classes[code] = (classes[code] or 0) + 1
end
local resume = {}
for code, nombre in pairs(classes) do resume[#resume + 1] = code .. "=" .. nombre end
table.sort(resume)
print("Peripheriques : " .. (#resume > 0 and table.concat(resume, " ") or "aucun"))

local motifs = {}
for cote, motif in pairs(facesInterdites) do
  motifs[#motifs + 1] = cote .. " (" .. motif .. ")"
end
if #motifs > 0 then
  encre(colors.orange)
  paragraphe("Faces exclues de la calibration : " .. table.concat(motifs, ", "))
  encre(colors.white)
end

--------------------------------------------------------------------- consignes
titre("AVANT DE COMMENCER")
paragraphe("Le vehicule va bouger : chaque face est mise sous tension quelques "
  .. "secondes, l'une apres l'autre.")
paragraphe("1. en l'air, en stationnaire, loin du relief et des constructions ;")
paragraphe("2. constellation GPS montee et chunks charges ;")
paragraphe("3. personne a bord, personne dessous.")
paragraphe("Ctrl+T coupe tout a n'importe quel moment.")

local reglages = config.calibration or {}
print("")
print(string.format("Impulsion %.1fs | rayon de securite %d blocs",
  reglages.impulsion or calibration.DEFAUTS.impulsion,
  reglages.rayonSecurite or calibration.DEFAUTS.rayonSecurite))

if not ouiNon("Le vehicule est-il en vol stationnaire et degage ?", false) then
  print("Calibration annulee.")
  return
end

--------------------------------------------------------------------- execution
local moteur = calibration.nouveau({
  config          = config,
  journal         = journalEcran(),
  quarantaine     = inventaire.quarantaine,
  facesInterdites = facesInterdites,
})

titre("CALIBRATION EN COURS")
local debut = os.clock()
local ok, resultat = pcall(moteur.executer)
local duree = os.clock() - debut

-- Quoi qu'il arrive, aucune sortie ne reste sous tension.
pcall(moteur.neutraliser)

if not ok then
  encre(colors.red)
  titre("CALIBRATION INTERROMPUE")
  paragraphe(tostring(resultat))
  encre(colors.white)
  paragraphe("Toutes les commandes ont ete remises a zero.")
  return
end

--------------------------------------------------------------------- resultat
titre("RESULTAT")
print(string.format("%d essai(s) en %.0f s", resultat.essais, duree))

local LIBELLES = {
  avance = "AVANCE", vertical = "VERTICAL", lacet = "LACET", lateral = "LATERAL",
}
for _, nomAxe in ipairs(calibration.ORDRE_AXES) do
  local axe = resultat.axes[nomAxe] or { mode = "aucun" }
  local texte
  if axe.mode == "bipolaire" then
    texte = string.format("bipolaire  +%s / -%s", axe.cotePositif, axe.coteNegatif)
  elseif axe.mode == "analogique" then
    texte = string.format("analogique %s (%d +/- %d)%s", axe.cote,
      axe.neutre or 0, axe.amplitude or 15, axe.inverse and " INVERSE" or "")
  elseif axe.mode == "peripherique" then
    texte = string.format("peripherique %s.%s", tostring(axe.nom), tostring(axe.methode))
  else
    texte = "non equipe"
  end
  encre(axe.mode == "aucun" and colors.lightGray or colors.lime)
  print(string.format("%-9s %s%s", LIBELLES[nomAxe] or nomAxe, texte,
    axe.ordinateur and ("  [sat #" .. axe.ordinateur .. "]") or ""))
  encre(colors.white)
end

if #resultat.manquants > 0 then
  encre(colors.orange)
  titre("AXES ESSENTIELS NON TROUVES")
  paragraphe(table.concat(resultat.manquants, ", "))
  paragraphe("Verifiez le cablage, ou declarez-les a la main dans "
    .. "config_vehicule.lua, section sorties.axes.")
  encre(colors.white)
end

if not resultat.lacetObservable then
  encre(colors.orange)
  titre("LACET NON OBSERVABLE")
  paragraphe("Ni capteur de cap, ni decalage GPS horizontal : une rotation ne "
    .. "deplace pas le point GPS, elle est donc invisible.")
  if #resultat.suspectesLacet > 0 then
    paragraphe("Faces sans effet mesurable, candidates a une rotation : "
      .. table.concat(resultat.suspectesLacet, ", "))
  end
  paragraphe("Remedes : renseignez 'decalageGps' si l'ordinateur n'est pas au "
    .. "centre du vehicule, equipez un capteur de cap et classez-le avec "
    .. "'classer', ou declarez les faces de lacet a la main.")
  encre(colors.white)
end

if #resultat.anomalies > 0 then
  encre(colors.orange)
  titre("REMARQUES")
  for _, anomalie in ipairs(resultat.anomalies) do paragraphe("- " .. anomalie) end
  encre(colors.white)
end

--------------------------------------------------------------------- ecriture
titre("ENREGISTREMENT")
if not ouiNon("Ecrire ce cablage dans config_vehicule.lua ?", #resultat.manquants == 0) then
  print("Configuration laissee inchangee.")
  print("Relancez 'calibrer' apres correction du cablage.")
  return
end

calibration.appliquerA(config, resultat.axes)
local okEcriture, err = pcall(calibration.ecrireConfiguration, config)
if not okEcriture then
  encre(colors.red)
  paragraphe("Ecriture impossible : " .. tostring(err))
  encre(colors.white)
  return
end

encre(colors.lime)
print("Cablage enregistre dans " .. autopilote.CHEMIN_CONFIG_DEFAUT)
encre(colors.white)
paragraphe("Verifiez maintenant le SENS de chaque axe avec l'outil 'cablage' "
  .. "(touche T, test guide) : la calibration trouve les faces, l'oeil de "
  .. "l'operateur confirme qu'elles poussent du bon cote.")
