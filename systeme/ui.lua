--[[----------------------------------------------------------------------------
  FRENCHNET OS - Boite a outils d'affichage
  --------------------------------------------------------------------------
  Meme langage visuel que l'interface de reglage de l'autopilote : barre de
  titre, panneau de sections a gauche, contenu a droite, barre d'etat en bas.
  Clavier ET souris sur les ordinateurs avances.

  Tout degrade proprement sur un ordinateur monochrome : les appels de couleur
  deviennent sans effet plutot que de planter.
--------------------------------------------------------------------------------]]

local M = {}

M.PALETTE = {
  fond        = colors.black,
  fondPanneau = colors.gray,
  fondBarre   = colors.cyan,
  texteBarre  = colors.black,
  texte       = colors.white,
  texteFaible = colors.lightGray,
  selection   = colors.lightBlue,
  texteSelect = colors.black,
  valeur      = colors.yellow,
  verrou      = colors.orange,
  alerte      = colors.red,
  bon         = colors.lime,
  accent      = colors.magenta,
}

local P = M.PALETTE

local function couleurDisponible()
  return term.isColour and term.isColour()
end
M.couleurDisponible = couleurDisponible

function M.fond(couleur)
  if couleurDisponible() then term.setBackgroundColour(couleur)
  else term.setBackgroundColour(colors.black) end
end

function M.encre(couleur)
  if couleurDisponible() then term.setTextColour(couleur)
  else term.setTextColour(colors.white) end
end

--- Ecrit un texte a une position, tronque ou complete a la largeur donnee.
function M.ecrireA(x, y, texte, largeur)
  term.setCursorPos(x, y)
  texte = tostring(texte)
  if largeur then
    if #texte > largeur then
      texte = texte:sub(1, math.max(0, largeur - 1)) .. "\26"
    else
      texte = texte .. string.rep(" ", largeur - #texte)
    end
  end
  term.write(texte)
end

function M.ligneVide(y, largeur, x)
  M.ecrireA(x or 1, y, "", largeur)
end

function M.effacer()
  M.fond(P.fond)
  M.encre(P.texte)
  term.clear()
end

--- Barre horizontale pleine (titre ou etat).
function M.barre(y, largeur, gauche, droite, couleurFond, couleurTexte)
  M.fond(couleurFond or P.fondBarre)
  M.encre(couleurTexte or P.texteBarre)
  M.ligneVide(y, largeur)
  M.ecrireA(2, y, gauche)
  if droite then
    local x = largeur - #droite
    if x > #gauche + 3 then M.ecrireA(x, y, droite) end
  end
end

function M.heure()
  local ok, texte = pcall(function() return textutils.formatTime(os.time(), true) end)
  return ok and texte or ""
end

--- Etiquette + valeur alignees, sur une ligne.
function M.champ(x, y, largeur, etiquette, valeur, couleurValeur)
  M.fond(P.fond)
  M.encre(P.texteFaible)
  M.ecrireA(x, y, etiquette, largeur)
  local colonne = x + math.min(#etiquette + 1, largeur)
  M.encre(couleurValeur or P.valeur)
  M.ecrireA(colonne, y, tostring(valeur), largeur - (colonne - x))
end

--- Deux colonnes : etiquette a gauche sur 'largeurEtiquette', valeur a droite.
function M.ligneValeur(x, y, largeurTotale, largeurEtiquette, etiquette, valeur, couleur)
  M.fond(P.fond)
  M.encre(P.texteFaible)
  M.ecrireA(x, y, etiquette, largeurEtiquette)
  M.encre(couleur or P.valeur)
  M.ecrireA(x + largeurEtiquette, y, tostring(valeur), largeurTotale - largeurEtiquette)
end

--- Titre de section souligne.
function M.section(x, y, largeur, titre)
  M.fond(P.fond)
  M.encre(P.accent)
  M.ecrireA(x, y, titre, largeur)
  M.encre(P.texteFaible)
  M.ecrireA(x, y + 1, string.rep("\140", math.min(#titre, largeur)), largeur)
end

--- Jauge horizontale (0..1).
function M.jauge(x, y, largeur, fraction, couleur)
  fraction = math.max(0, math.min(fraction or 0, 1))
  local pleins = math.floor(fraction * largeur + 0.5)
  M.fond(P.fond)
  M.encre(couleur or P.bon)
  M.ecrireA(x, y, string.rep("\127", pleins))
  M.encre(P.texteFaible)
  M.ecrireA(x + pleins, y, string.rep("\183", largeur - pleins))
end

--------------------------------------------------------------------------------
-- SAISIE
--------------------------------------------------------------------------------

--- Saisie d'une chaine a l'ecran, avec curseur.
-- La valeur existante est proposee mais consideree comme selectionnee : le
-- premier caractere frappe la remplace. Une correction repasse en edition.
-- @return texte valide, ou nil si la saisie est annulee (Echap)
function M.saisir(x, y, largeur, valeurInitiale)
  local tampon = tostring(valeurInitiale or "")
  local curseur = #tampon + 1
  local remplacerALaFrappe = true

  while true do
    M.fond(P.selection)
    M.encre(P.texteSelect)
    local visible = tampon
    local depart = 1
    if #visible >= largeur then
      depart = #visible - largeur + 2
      visible = visible:sub(depart)
    end
    M.ecrireA(x, y, visible, largeur)
    term.setCursorPos(x + math.min(curseur - depart, largeur - 1), y)
    term.setCursorBlink(true)

    local evenement = table.pack(os.pullEvent())
    local nom = evenement[1]

    if nom == "char" then
      if remplacerALaFrappe then tampon, curseur = "", 1 end
      remplacerALaFrappe = false
      tampon = tampon:sub(1, curseur - 1) .. evenement[2] .. tampon:sub(curseur)
      curseur = curseur + 1

    elseif nom == "paste" then
      remplacerALaFrappe = false
      tampon = tampon:sub(1, curseur - 1) .. evenement[2] .. tampon:sub(curseur)
      curseur = curseur + #evenement[2]

    elseif nom == "key" then
      local touche = evenement[2]
      remplacerALaFrappe = false
      if touche == keys.enter or touche == keys.numPadEnter then
        term.setCursorBlink(false)
        return tampon
      elseif touche == keys.escape then
        term.setCursorBlink(false)
        return nil
      elseif touche == keys.backspace and curseur > 1 then
        tampon = tampon:sub(1, curseur - 2) .. tampon:sub(curseur)
        curseur = curseur - 1
      elseif touche == keys.delete then
        tampon = tampon:sub(1, curseur - 1) .. tampon:sub(curseur + 1)
      elseif touche == keys.left and curseur > 1 then
        curseur = curseur - 1
      elseif touche == keys.right and curseur <= #tampon then
        curseur = curseur + 1
      elseif touche == keys["end"] then
        curseur = #tampon + 1
      elseif touche == keys.home then
        curseur = 1
      end
    end
  end
end

--- Saisie d'un nombre. Renvoie nil si annule, et refuse une valeur non
--- numerique ou hors bornes en le disant plutot qu'en l'acceptant.
-- @return nombre | nil, messageErreur
function M.saisirNombre(x, y, largeur, valeurInitiale, mini, maxi)
  local texte = M.saisir(x, y, largeur, valeurInitiale)
  if texte == nil then return nil, nil end
  texte = texte:gsub(",", ".")
  local valeur = tonumber(texte)
  if not valeur then
    return nil, "'" .. texte .. "' n'est pas un nombre"
  end
  if mini and valeur < mini then
    return nil, string.format("valeur minimale : %s", tostring(mini))
  end
  if maxi and valeur > maxi then
    return nil, string.format("valeur maximale : %s", tostring(maxi))
  end
  return valeur, nil
end

--- Choix dans une liste fermee, par rotation (fleches gauche/droite ou clic).
function M.suivantDansListe(valeurCourante, valeurs, sens)
  local indice = 1
  for i, v in ipairs(valeurs) do
    if v == valeurCourante then indice = i break end
  end
  indice = indice + (sens or 1)
  if indice > #valeurs then indice = 1 end
  if indice < 1 then indice = #valeurs end
  return valeurs[indice]
end

--------------------------------------------------------------------------------
-- BOITES DE DIALOGUE
--------------------------------------------------------------------------------

--- Cadre centre, renvoie x, y, largeur, hauteur de la zone interieure.
function M.cadre(largeurBoite, hauteurBoite, titre)
  local largeur, hauteur = term.getSize()
  largeurBoite = math.min(largeurBoite, largeur - 2)
  hauteurBoite = math.min(hauteurBoite, hauteur - 2)
  local x = math.floor((largeur - largeurBoite) / 2) + 1
  local y = math.floor((hauteur - hauteurBoite) / 2) + 1

  M.fond(P.fondPanneau)
  for ligne = y, y + hauteurBoite - 1 do
    M.ecrireA(x, ligne, "", largeurBoite)
  end
  if titre then
    M.fond(P.fondBarre)
    M.encre(P.texteBarre)
    M.ecrireA(x, y, " " .. titre, largeurBoite)
  end
  M.fond(P.fondPanneau)
  M.encre(P.texte)
  return x + 1, y + (titre and 2 or 1), largeurBoite - 2, hauteurBoite - (titre and 3 or 2)
end

--- Message bloquant jusqu'a une touche.
function M.message(titre, lignes, couleur)
  local hauteurBoite = #lignes + 4
  local largeurBoite = 20
  for _, ligne in ipairs(lignes) do
    largeurBoite = math.max(largeurBoite, #ligne + 4)
  end
  local x, y, largeur = M.cadre(largeurBoite, hauteurBoite, titre)
  M.encre(couleur or P.texte)
  for i, ligne in ipairs(lignes) do
    M.ecrireA(x, y + i - 1, ligne, largeur)
  end
  M.encre(P.texteFaible)
  M.ecrireA(x, y + #lignes + 1, "Une touche pour continuer.", largeur)
  os.pullEvent("key")
end

--- Confirmation oui / non. Le defaut est NON : une action destructrice ne
--- doit jamais partir sur une touche pressee par reflexe.
function M.confirmer(titre, lignes)
  local hauteurBoite = #lignes + 4
  local largeurBoite = 24
  for _, ligne in ipairs(lignes) do
    largeurBoite = math.max(largeurBoite, #ligne + 4)
  end
  local x, y, largeur = M.cadre(largeurBoite, hauteurBoite, titre)
  M.encre(P.texte)
  for i, ligne in ipairs(lignes) do
    M.ecrireA(x, y + i - 1, ligne, largeur)
  end
  M.encre(P.valeur)
  M.ecrireA(x, y + #lignes + 1, "O = oui   /   toute autre touche = non", largeur)
  local _, touche = os.pullEvent("key")
  return touche == keys.o
end

return M
