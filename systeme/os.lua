--[[----------------------------------------------------------------------------
  FRENCHNET OS - Systeme d'exploitation embarque du navire intercepteur
  --------------------------------------------------------------------------
  Ce n'est pas un menu pose devant un programme : c'est un systeme.

    * un NOYAU MULTITACHE (systeme/noyau_taches.lua) fait tourner cote a cote
      l'interface et le systeme d'interception, chacun dans sa fenetre. Les
      evenements de terminal ne vont qu'a la tache au premier plan ; rednet,
      les minuteurs et les peripheriques vont a tout le monde. L'equipage peut
      donc regler l'armement pendant que le navire poursuit sa cible.
    * un AMORCAGE verifie le materiel et les fichiers avant de lancer quoi que
      ce soit, et dit precisement ce qui manque.
    * des PAGES : Etat, Mission, Armement, Autopilote, Journal, Systeme,
      Console.
    * une tache qui tombe ne noircit pas l'ecran : son erreur est conservee et
      lisible depuis la page Console.

  Lancement :
      os_frenchnet              -- systeme complet (interception + interface)
      os_frenchnet interface    -- interface seule, navire au sol
--------------------------------------------------------------------------------]]

local VERSION_OS = "1.0.0"

local REPERTOIRE = (function()
  if shell and shell.getRunningProgram then
    local ok, chemin = pcall(shell.getRunningProgram)
    if ok and chemin then
      local dossier = fs.getDir(chemin)
      if dossier and dossier ~= "" and dossier ~= "." then return dossier end
    end
  end
  return "systeme"
end)()

local function charger(nom, ...)
  local chemin = fs.combine(REPERTOIRE, nom .. ".lua")
  if not fs.exists(chemin) then error("module systeme manquant : " .. chemin, 0) end
  local fichier = fs.open(chemin, "r")
  local source = fichier.readAll()
  fichier.close()
  local morceau, err = load(source, "@" .. chemin, "t", _G)
  if not morceau then error("module illisible : " .. chemin .. " -> " .. tostring(err), 0) end
  return morceau(...)
end

local ui       = charger("ui")
local taches   = charger("noyau_taches")
local arsenalF = charger("arsenal_fichier")
local P        = ui.PALETTE

local CHEMIN_INTERCEPTEUR = "/intercepteur/intercepteur.lua"
local CHEMIN_CONFIG_NAVIRE = "/intercepteur/config_intercepteur.lua"
local CHEMIN_AUTOPILOTE   = "/autopilote/autopilote.lua"
local CHEMIN_CONFIG_VEHICULE = "/autopilote/config_vehicule.lua"
local CHEMIN_INTERFACE_AP = "/autopilote/interface.lua"
local CHEMIN_JOURNAL      = "/intercepteur/intercepteur.log"
local MARQUEUR_REARMEMENT = "/intercepteur/.rearmement_requis"

--------------------------------------------------------------------------------
-- 1. TABLEAU DE BORD PARTAGE
--    Alimente par le systeme d'interception. Lecture seule ici : le systeme
--    d'exploitation affiche, il ne commande pas le vol.
--------------------------------------------------------------------------------

local function tableauDeBord()
  local t = rawget(_G, "__FRENCHNET_TABLEAU_DE_BORD")
  return type(t) == "table" and t or {}
end

local function fraicheur(t)
  if not t.majA then return nil end
  return os.clock() - t.majA
end

--------------------------------------------------------------------------------
-- 2. AMORCAGE
--    On verifie AVANT de lancer. Un navire arme qui demarre a moitie est plus
--    dangereux qu'un navire qui refuse de demarrer en disant pourquoi.
--------------------------------------------------------------------------------

local function controlesAmorcage()
  local controles = {}

  local function verifier(libelle, condition, detail, bloquant)
    controles[#controles + 1] = {
      libelle = libelle, ok = condition and true or false,
      detail = detail, bloquant = bloquant ~= false,
    }
  end

  verifier("Module d'autopilote", fs.exists(CHEMIN_AUTOPILOTE),
    fs.exists(CHEMIN_AUTOPILOTE) and CHEMIN_AUTOPILOTE
      or (CHEMIN_AUTOPILOTE .. " introuvable : le navire ne peut pas voler"))

  verifier("Reglage du vehicule", fs.exists(CHEMIN_CONFIG_VEHICULE),
    fs.exists(CHEMIN_CONFIG_VEHICULE) and CHEMIN_CONFIG_VEHICULE
      or (CHEMIN_CONFIG_VEHICULE .. " introuvable : reglez le vehicule d'abord"))

  verifier("Systeme d'interception", fs.exists(CHEMIN_INTERCEPTEUR),
    fs.exists(CHEMIN_INTERCEPTEUR) and CHEMIN_INTERCEPTEUR
      or (CHEMIN_INTERCEPTEUR .. " introuvable"))

  verifier("Configuration du navire", fs.exists(CHEMIN_CONFIG_NAVIRE),
    fs.exists(CHEMIN_CONFIG_NAVIRE) and CHEMIN_CONFIG_NAVIRE
      or (CHEMIN_CONFIG_NAVIRE .. " introuvable"))

  local arsenal, source = arsenalF.charger()
  local anomalies, armees = arsenalF.verifier(arsenal)
  verifier("Arsenal", #anomalies == 0,
    #anomalies == 0
      and string.format("%d arme(s) declaree(s), %d armee(s) - %s",
            #arsenal.armes, armees, source)
      or (#anomalies .. " anomalie(s) : " .. anomalies[1]))

  -- Materiel : non bloquant, on veut pouvoir regler au sol sans tout monter.
  local modem, radar, affut = false, false, false
  for _, nom in ipairs(peripheral.getNames()) do
    local ok, type_ = pcall(peripheral.getType, nom)
    if ok and type(type_) == "string" then
      local t = type_:lower()
      if t == "modem" then modem = true end
      if t:find("radar", 1, true) then radar = true end
      if t:find("cannon", 1, true) or t:find("mount", 1, true) then affut = true end
    end
  end
  verifier("Modem (ordres du sol)", modem,
    modem and "detecte" or "absent : aucun ordre ne parviendra au navire", false)
  verifier("Radar embarque", radar,
    radar and "detecte" or "absent : aucune poursuite possible", false)
  verifier("Affut", affut,
    affut and "detecte" or "absent (normal si toutes les armes sont en redstone)", false)

  return controles, arsenal
end

local function ecranAmorcage(controles)
  local largeur, hauteur = term.getSize()
  ui.effacer()
  ui.barre(1, largeur, "FRENCHNET OS " .. VERSION_OS, "ordinateur #" .. os.getComputerID())

  ui.fond(P.fond)
  ui.encre(P.texteFaible)
  ui.ecrireA(2, 3, "Amorcage du systeme embarque...", largeur - 2)

  local ligne = 5
  local bloquants = 0
  for _, controle in ipairs(controles) do
    if ligne >= hauteur - 2 then break end
    ui.fond(P.fond)
    ui.encre(controle.ok and P.bon or (controle.bloquant and P.alerte or P.valeur))
    ui.ecrireA(2, ligne, controle.ok and "[ OK ]" or (controle.bloquant and "[ECHEC]" or "[AVERT]"))
    ui.encre(P.texte)
    ui.ecrireA(9, ligne, controle.libelle, largeur - 10)
    ligne = ligne + 1
    if controle.detail and ligne < hauteur - 2 then
      ui.encre(P.texteFaible)
      ui.ecrireA(9, ligne, controle.detail, largeur - 10)
      ligne = ligne + 1
    end
    if not controle.ok and controle.bloquant then bloquants = bloquants + 1 end
    sleep(0.12)
  end

  return bloquants
end

--------------------------------------------------------------------------------
-- 3. PAGES
--------------------------------------------------------------------------------

local pages = {}

local etatShell = {
  pageCourante = 1,
  message      = nil,
  messageA     = 0,
  messageAlerte = false,
  arsenal      = nil,
  arsenalSource = nil,
  arsenalModifie = false,
  selectionArme = 1,
  champSelectionne = 1,
  editionArme  = nil,
  defilementJournal = 0,
  filtreJournal = "TOUT",
  noyau        = nil,
  indiceConsole = nil,
  autonome     = false,
}

local function signaler(texte, alerte)
  etatShell.message = texte
  etatShell.messageA = os.clock()
  etatShell.messageAlerte = alerte and true or false
end

--------------------------------------------------------------- 3a. PAGE ETAT ---

pages[1] = { nom = "Etat", touche = "1" }

pages[1].dessiner = function(x, y, largeur, hauteur)
  local t = tableauDeBord()
  local age = fraicheur(t)

  if not t.etat then
    ui.encre(P.valeur)
    ui.ecrireA(x, y, "Systeme d'interception non demarre.", largeur)
    ui.encre(P.texteFaible)
    ui.ecrireA(x, y + 2, etatShell.autonome
      and "Mode interface seule : lancez 'os_frenchnet' sans argument."
      or "En cours de demarrage, ou arrete (voir la page Console).", largeur)
    return
  end

  ui.section(x, y, largeur, "NAVIRE")
  local l = y + 2
  ui.ligneValeur(x, l, largeur, 16, "Identifiant", tostring(t.identifiant or "?")) l = l + 1
  ui.ligneValeur(x, l, largeur, 16, "Etat",
    tostring(t.etat),
    (t.etat == "TIR" or t.etat == "EVASION") and P.alerte
      or (t.etat == "VEILLE" and P.texteFaible or P.bon)) l = l + 1
  ui.ligneValeur(x, l, largeur, 16, "Depuis",
    string.format("%.0f s", os.clock() - (t.etatDepuis or os.clock()))) l = l + 1
  ui.ligneValeur(x, l, largeur, 16, "Vol (autopilote)", tostring(t.modeVol or "?")) l = l + 1
  ui.ligneValeur(x, l, largeur, 16, "Pilotage", tostring(t.modePilotage or "?"),
    (t.modePilotage and t.modePilotage:find("ZONE_MORTE", 1, true)) and P.valeur or P.bon) l = l + 1

  if t.position then
    ui.ligneValeur(x, l, largeur, 16, "Position", string.format("%.0f %.0f %.0f",
      t.position.x, t.position.y, t.position.z)) l = l + 1
  end
  ui.ligneValeur(x, l, largeur, 16, "Vitesse", string.format("%.1f b/s", t.vitesse or 0)) l = l + 1
  l = l + 1

  ui.section(x, l, largeur, "CIBLE")
  l = l + 2
  local piste = t.piste
  if piste and piste.position then
    ui.ligneValeur(x, l, largeur, 16, "Position", string.format("%.0f %.0f %.0f",
      piste.position.x, piste.position.y, piste.position.z)) l = l + 1
    local c = t.consigne
    if c then
      ui.ligneValeur(x, l, largeur, 16, "Distance",
        string.format("%.0f blocs", c.distanceActuelle or 0)) l = l + 1
      ui.ligneValeur(x, l, largeur, 16, "Position horaire",
        tostring(c.positionHoraire or "?"),
        (c.relevementActuel and c.relevementActuel >= 120 and c.relevementActuel <= 240)
          and P.bon or P.valeur) l = l + 1
      ui.ligneValeur(x, l, largeur, 16, "Impact predit",
        string.format("%.1f s", c.tempsInterception or 0)) l = l + 1
      ui.ligneValeur(x, l, largeur, 16, "Engagement",
        tostring(c.modeEngagement or "position")) l = l + 1
    end
  else
    ui.encre(P.texteFaible)
    ui.ecrireA(x, l, "aucune piste radar", largeur) l = l + 1
  end
  l = l + 1

  ui.section(x, l, largeur, "ARMEMENT")
  l = l + 2
  ui.ligneValeur(x, l, largeur, 16, "Feu",
    t.feuAutorise and "AUTORISE" or "interdit",
    t.feuAutorise and P.alerte or P.texteFaible) l = l + 1
  ui.ligneValeur(x, l, largeur, 16, "Regle",
    t.prioriteTir and "tir > position" or "position > tir",
    t.prioriteTir and P.alerte or P.valeur) l = l + 1
  ui.ligneValeur(x, l, largeur, 16, "Arme retenue", tostring(t.armeRetenue or "-")) l = l + 1
  ui.ligneValeur(x, l, largeur, 16, "Rafales", tostring(t.coups or 0)) l = l + 1
  ui.ligneValeur(x, l, largeur, 16, "Degats subis", tostring(t.degatsSubis or 0),
    (t.degatsSubis or 0) > 0 and P.alerte or P.bon) l = l + 1

  if t.rearmementRequis then
    l = l + 1
    ui.encre(P.alerte)
    ui.ecrireA(x, l, "REARMEMENT MANUEL REQUIS - page Mission pour valider", largeur)
  end

  if age and age > 5 then
    ui.encre(P.valeur)
    ui.ecrireA(x, hauteur + y - 1, string.format(
      "donnees vieilles de %.0f s : le systeme d'interception repond-il ?", age), largeur)
  end
end

pages[1].touche = function() return false end

------------------------------------------------------------ 3b. PAGE MISSION ---

pages[2] = { nom = "Mission", touche = "2" }

pages[2].dessiner = function(x, y, largeur, hauteur)
  local t = tableauDeBord()

  ui.section(x, y, largeur, "DERNIER ORDRE RECU")
  local l = y + 2
  if t.ordre then
    ui.ligneValeur(x, l, largeur, 16, "Type", tostring(t.ordre.type)) l = l + 1
    ui.ligneValeur(x, l, largeur, 16, "Reference", tostring(t.ordre.identifiantOrdre)) l = l + 1
    ui.ligneValeur(x, l, largeur, 16, "Poste emetteur", "#" .. tostring(t.ordre.expediteur)) l = l + 1
    if t.ordre.cible then
      ui.ligneValeur(x, l, largeur, 16, "Cible designee", string.format("%.0f %.0f %.0f",
        t.ordre.cible.x, t.ordre.cible.y, t.ordre.cible.z)) l = l + 1
    end
  else
    ui.encre(P.texteFaible)
    ui.ecrireA(x, l, "aucun ordre recu depuis le demarrage", largeur) l = l + 1
  end
  l = l + 1

  ui.section(x, l, largeur, "INDEPENDANCE DU SOL")
  l = l + 2
  ui.encre(P.texteFaible)
  ui.ecrireA(x, l, "Le navire n'accepte que deux ordres : SCRAMBLE et FEU.", largeur) l = l + 1
  ui.ecrireA(x, l, "Il ignore toute zone et toute classe : ces notions", largeur) l = l + 1
  ui.ecrireA(x, l, "appartiennent au systeme de defense au sol.", largeur) l = l + 2

  ui.section(x, l, largeur, "ACTIONS")
  l = l + 2
  ui.encre(P.texte)
  if t.rearmementRequis then
    ui.encre(P.alerte)
    ui.ecrireA(x, l, "R  Valider le rearmement (remet le navire en ligne)", largeur)
  else
    ui.encre(P.texteFaible)
    ui.ecrireA(x, l, "R  Valider le rearmement (aucun en attente)", largeur)
  end
  l = l + 1
  ui.encre(P.texteFaible)
  ui.ecrireA(x, l, "Le rearmement reste une action manuelle : le navire refuse", largeur) l = l + 1
  ui.ecrireA(x, l, "tout scramble tant qu'il n'a pas ete valide.", largeur)
end

pages[2].touche = function(touche)
  if touche == keys.r then
    if not fs.exists(MARQUEUR_REARMEMENT) then
      signaler("Aucun rearmement en attente.", false)
      return true
    end
    if ui.confirmer("Rearmement", {
        "Confirmer que le navire a ete rearme ?",
        "Il redeviendra disponible pour un scramble.",
      }) then
      local ok = pcall(fs.delete, MARQUEUR_REARMEMENT)
      signaler(ok and "Rearmement valide : navire de nouveau disponible."
        or "Suppression du marqueur impossible.", not ok)
    end
    return true
  end
  return false
end

----------------------------------------------------------- 3c. PAGE ARMEMENT ---
-- La page demandee : ajouter des armes, leur portee et leur utilite.

pages[3] = { nom = "Armement", touche = "3" }

local function arsenalCourant()
  if not etatShell.arsenal then
    etatShell.arsenal, etatShell.arsenalSource = arsenalF.charger()
  end
  return etatShell.arsenal
end

local function dessinerListeArmes(x, y, largeur, hauteur)
  local arsenal = arsenalCourant()

  ui.section(x, y, largeur, "ARSENAL DU BORD")
  local l = y + 2

  if #arsenal.armes == 0 then
    ui.encre(P.valeur)
    ui.ecrireA(x, l, "Aucune arme declaree.", largeur) l = l + 1
    ui.encre(P.texteFaible)
    ui.ecrireA(x, l, "A pour en ajouter une.", largeur)
  else
    -- En-tete de colonnes.
    ui.encre(P.texteFaible)
    ui.ecrireA(x, l, string.format("%-14s %-12s %-11s %s",
      "IDENTIFIANT", "UTILITE", "PORTEE", "ETAT"), largeur)
    l = l + 1

    for indice, arme in ipairs(arsenal.armes) do
      if l >= y + hauteur - 6 then break end
      local selectionne = (indice == etatShell.selectionArme)
      ui.fond(selectionne and P.selection or P.fond)
      ui.encre(selectionne and P.texteSelect or P.texte)
      ui.ecrireA(x, l, string.format("%-14s %-12s %4.0f-%-6.0f %s",
        tostring(arme.identifiant):sub(1, 14),
        tostring(arme.utilite):sub(1, 12),
        arme.porteeMini or 0, arme.porteeMaxi or 0,
        arme.actif and "armee" or "-"), largeur)
      l = l + 1
    end
    ui.fond(P.fond)
  end

  -- Couverture de portee : le trou de portee est ce qui manque le plus
  -- souvent a l'equipage.
  l = l + 1
  local couverture = arsenalF.couverture(arsenal, arsenal.besoinParDefaut)
  ui.section(x, l, largeur, "COUVERTURE " .. string.upper(tostring(arsenal.besoinParDefaut)))
  l = l + 2
  if not couverture.mini then
    ui.encre(P.alerte)
    ui.ecrireA(x, l, "aucune arme armee pour ce besoin", largeur)
  else
    ui.encre(P.bon)
    ui.ecrireA(x, l, string.format("couvert de %.0f a %.0f blocs",
      couverture.mini, couverture.maxi), largeur)
    l = l + 1
    if #couverture.trous > 0 then
      ui.encre(P.alerte)
      local morceaux = {}
      for _, trou in ipairs(couverture.trous) do
        morceaux[#morceaux + 1] = string.format("%.0f-%.0f", trou.de, trou.a)
      end
      ui.ecrireA(x, l, "TROU DE PORTEE : " .. table.concat(morceaux, ", "), largeur)
    end
  end
end

local function dessinerEditionArme(x, y, largeur, hauteur)
  local arme = etatShell.editionArme
  ui.section(x, y, largeur, "ARME : " .. tostring(arme.identifiant))
  local l = y + 2

  local premier = math.max(1, etatShell.champSelectionne - (hauteur - 9))
  for indice = premier, #arsenalF.CHAMPS do
    local champ = arsenalF.CHAMPS[indice]
    if l >= y + hauteur - 5 then break end
    local selectionne = (indice == etatShell.champSelectionne)
    local valeur = arme[champ.cle]
    local texte
    if champ.type == "booleen" then
      texte = valeur and "oui" or "non"
    elseif valeur == nil or valeur == "" then
      texte = "(vide)"
    else
      texte = tostring(valeur)
      if champ.unite then texte = texte .. " " .. champ.unite end
    end

    ui.fond(selectionne and P.selection or P.fond)
    ui.encre(selectionne and P.texteSelect or P.texteFaible)
    ui.ecrireA(x, l, " " .. champ.libelle, 22)
    ui.encre(selectionne and P.texteSelect or P.valeur)
    ui.ecrireA(x + 22, l, texte, largeur - 22)
    l = l + 1
  end

  ui.fond(P.fond)
  local champ = arsenalF.CHAMPS[etatShell.champSelectionne]
  if champ and champ.aide then
    ui.encre(P.texteFaible)
    ui.ecrireA(x, y + hauteur - 4, champ.aide, largeur)
  end
end

pages[3].dessiner = function(x, y, largeur, hauteur)
  if etatShell.editionArme then
    dessinerEditionArme(x, y, largeur, hauteur)
  else
    dessinerListeArmes(x, y, largeur, hauteur)
  end
end

local function enregistrerArsenal()
  local arsenal = arsenalCourant()
  local anomalies = arsenalF.verifier(arsenal)
  if #anomalies > 0 then
    ui.message("Arsenal refuse", anomalies, P.alerte)
    return false
  end
  local ok, detail = arsenalF.enregistrer(arsenal)
  if ok then
    etatShell.arsenalModifie = false
    etatShell.arsenalSource = detail
    signaler("Arsenal enregistre dans " .. detail
      .. " - redemarrez le systeme pour l'appliquer.", false)
  else
    signaler(detail, true)
  end
  return ok
end

pages[3].touche = function(touche)
  local arsenal = arsenalCourant()

  ---------------------------------------------------------------- edition d'une arme
  if etatShell.editionArme then
    local champ = arsenalF.CHAMPS[etatShell.champSelectionne]

    if touche == keys.up then
      etatShell.champSelectionne = math.max(1, etatShell.champSelectionne - 1)
    elseif touche == keys.down then
      etatShell.champSelectionne = math.min(#arsenalF.CHAMPS, etatShell.champSelectionne + 1)
    elseif touche == keys.escape then
      etatShell.editionArme = nil
    elseif touche == keys.left or touche == keys.right then
      if champ.type == "booleen" then
        etatShell.editionArme[champ.cle] = not etatShell.editionArme[champ.cle]
        etatShell.arsenalModifie = true
      elseif champ.type == "liste" then
        etatShell.editionArme[champ.cle] = ui.suivantDansListe(
          etatShell.editionArme[champ.cle], champ.valeurs,
          touche == keys.right and 1 or -1)
        etatShell.arsenalModifie = true
      end
    elseif touche == keys.enter then
      local largeur = select(1, term.getSize())
      local ligneChamp = 0
      -- La saisie se fait a l'emplacement du champ : l'ecran est redessine
      -- juste apres, la position exacte importe peu.
      if champ.type == "nombre" then
        local valeur, erreur = ui.saisirNombre(3 + 22, 6 + ligneChamp, 20,
          etatShell.editionArme[champ.cle], champ.mini, champ.maxi)
        if erreur then
          signaler(erreur, true)
        elseif valeur ~= nil then
          etatShell.editionArme[champ.cle] = valeur
          etatShell.arsenalModifie = true
        end
      elseif champ.type == "texte" then
        local texte = ui.saisir(3 + 22, 6 + ligneChamp, 26,
          etatShell.editionArme[champ.cle] or "")
        if texte ~= nil then
          etatShell.editionArme[champ.cle] = (texte ~= "") and texte or nil
          etatShell.arsenalModifie = true
        end
      elseif champ.type == "booleen" then
        etatShell.editionArme[champ.cle] = not etatShell.editionArme[champ.cle]
        etatShell.arsenalModifie = true
      elseif champ.type == "liste" then
        etatShell.editionArme[champ.cle] = ui.suivantDansListe(
          etatShell.editionArme[champ.cle], champ.valeurs, 1)
        etatShell.arsenalModifie = true
      end
    end
    return true
  end

  ------------------------------------------------------------------- liste d'armes
  if touche == keys.up then
    etatShell.selectionArme = math.max(1, etatShell.selectionArme - 1)

  elseif touche == keys.down then
    etatShell.selectionArme = math.min(math.max(#arsenal.armes, 1),
      etatShell.selectionArme + 1)

  elseif touche == keys.enter then
    local arme = arsenal.armes[etatShell.selectionArme]
    if arme then
      etatShell.editionArme = arme
      etatShell.champSelectionne = 1
    end

  elseif touche == keys.a then
    local arme = arsenalF.nouvelleArme(#arsenal.armes + 1)
    arsenal.armes[#arsenal.armes + 1] = arme
    etatShell.selectionArme = #arsenal.armes
    etatShell.editionArme = arme
    etatShell.champSelectionne = 1
    etatShell.arsenalModifie = true
    signaler("Arme ajoutee. Reglez sa portee et son utilite.", false)

  elseif touche == keys.d then
    local arme = arsenal.armes[etatShell.selectionArme]
    if arme and ui.confirmer("Supprimer une arme", {
        "Supprimer " .. tostring(arme.identifiant) .. " ?",
        "Cette arme ne sera plus embarquee.",
      }) then
      table.remove(arsenal.armes, etatShell.selectionArme)
      etatShell.selectionArme = math.max(1, etatShell.selectionArme - 1)
      etatShell.arsenalModifie = true
      signaler("Arme supprimee.", false)
    end

  elseif touche == keys.space then
    local arme = arsenal.armes[etatShell.selectionArme]
    if arme then
      arme.actif = not arme.actif
      etatShell.arsenalModifie = true
      signaler(tostring(arme.identifiant) .. (arme.actif and " armee." or " desarmee."), false)
    end

  elseif touche == keys.p then
    arsenal.prioriteTirSurPosition = not arsenal.prioriteTirSurPosition
    etatShell.arsenalModifie = true
    signaler("Regle d'engagement : " .. (arsenal.prioriteTirSurPosition
      and "LE TIR PRIME SUR LA POSITION" or "la position prime sur le tir"), false)

  elseif touche == keys.s then
    enregistrerArsenal()

  elseif touche == keys.r then
    etatShell.arsenal, etatShell.arsenalSource = arsenalF.charger()
    etatShell.arsenalModifie = false
    signaler("Arsenal recharge depuis le disque.", false)

  else
    return false
  end
  return true
end

pages[3].aide = function()
  if etatShell.editionArme then
    return "Fleches: champ  Gauche/Droite: valeur  Entree: saisir  Echap: retour"
  end
  return "Entree: editer  A: ajouter  D: supprimer  Espace: armer  P: regle  S: enregistrer"
end

--------------------------------------------------------- 3d. PAGE AUTOPILOTE ---

pages[4] = { nom = "Autopilote", touche = "4" }

pages[4].dessiner = function(x, y, largeur, hauteur)
  local t = tableauDeBord()

  ui.section(x, y, largeur, "MODULE D'AUTOPILOTE")
  local l = y + 2
  ui.encre(P.texteFaible)
  ui.ecrireA(x, l, "Le systeme d'interception n'ecrit aucune loi de vol :", largeur) l = l + 1
  ui.ecrireA(x, l, "cascade, PID et repli en zone morte appartiennent au", largeur) l = l + 1
  ui.ecrireA(x, l, "module d'autopilote, qui est appele, jamais reimplemente.", largeur) l = l + 2

  ui.ligneValeur(x, l, largeur, 20, "Module",
    fs.exists(CHEMIN_AUTOPILOTE) and CHEMIN_AUTOPILOTE or "INTROUVABLE",
    fs.exists(CHEMIN_AUTOPILOTE) and P.bon or P.alerte) l = l + 1
  ui.ligneValeur(x, l, largeur, 20, "Reglage vehicule",
    fs.exists(CHEMIN_CONFIG_VEHICULE) and CHEMIN_CONFIG_VEHICULE or "INTROUVABLE",
    fs.exists(CHEMIN_CONFIG_VEHICULE) and P.bon or P.alerte) l = l + 1

  local instantane = t.instantaneVol
  if instantane then
    l = l + 1
    ui.section(x, l, largeur, "VOL EN COURS")
    l = l + 2
    ui.ligneValeur(x, l, largeur, 20, "Mode", tostring(instantane.mode or "?")) l = l + 1
    ui.ligneValeur(x, l, largeur, 20, "Phase", tostring(instantane.phase or "-")) l = l + 1
    if instantane.distance then
      ui.ligneValeur(x, l, largeur, 20, "Distance au point",
        string.format("%.1f blocs", instantane.distance)) l = l + 1
    end
    if instantane.modesAxes then
      local morceaux = {}
      for axe, mode in pairs(instantane.modesAxes) do
        morceaux[#morceaux + 1] = axe .. "=" .. tostring(mode)
      end
      table.sort(morceaux)
      ui.ligneValeur(x, l, largeur, 20, "Axes", table.concat(morceaux, " ")) l = l + 1
    end
    ui.ligneValeur(x, l, largeur, 20, "Consignes emises",
      tostring(t.consignesEmises or 0)) l = l + 1
    if instantane.perteGps then
      ui.encre(P.alerte)
      ui.ecrireA(x, l, "PERTE GPS SIGNALEE PAR L'AUTOPILOTE", largeur) l = l + 1
    end
  end

  l = l + 1
  ui.section(x, l, largeur, "REGLAGE")
  l = l + 2
  ui.encre(fs.exists(CHEMIN_INTERFACE_AP) and P.texte or P.texteFaible)
  ui.ecrireA(x, l, "C  Ouvrir l'interface de reglage du vehicule", largeur) l = l + 1
  ui.encre(P.texteFaible)
  ui.ecrireA(x, l, fs.exists(CHEMIN_INTERFACE_AP)
    and "Gabarit, moteurs, gains PID, vitesses, tolerances."
    or (CHEMIN_INTERFACE_AP .. " absent."), largeur)
end

pages[4].touche = function(touche)
  if touche == keys.c then
    if not fs.exists(CHEMIN_INTERFACE_AP) then
      signaler("Interface de reglage absente : " .. CHEMIN_INTERFACE_AP, true)
      return true
    end
    if tableauDeBord().etat and tableauDeBord().etat ~= "VEILLE" then
      if not ui.confirmer("Reglage en vol", {
          "Le navire est en mission (" .. tostring(tableauDeBord().etat) .. ").",
          "Ouvrir l'interface de reglage maintenant ?",
        }) then
        return true
      end
    end
    ui.effacer()
    local ok, err = pcall(function() shell.run(CHEMIN_INTERFACE_AP) end)
    if not ok then signaler("Interface interrompue : " .. tostring(err), true) end
    return true
  end
  return false
end

pages[4].aide = function() return "C: interface de reglage du vehicule" end

------------------------------------------------------------ 3e. PAGE JOURNAL ---

pages[5] = { nom = "Journal", touche = "5" }

local NIVEAUX_FILTRE = { "TOUT", "INFO", "AVERT", "ERREUR" }

local function lireJournal(maximum)
  if not fs.exists(CHEMIN_JOURNAL) then return {} end
  local fichier = fs.open(CHEMIN_JOURNAL, "r")
  if not fichier then return {} end
  local lignes = {}
  local ligne = fichier.readLine()
  while ligne do
    lignes[#lignes + 1] = ligne
    -- Fenetre glissante : un journal de 90 ko ne tient pas en memoire utile.
    if #lignes > (maximum or 400) then table.remove(lignes, 1) end
    ligne = fichier.readLine()
  end
  fichier.close()
  return lignes
end

pages[5].dessiner = function(x, y, largeur, hauteur)
  local lignes = lireJournal(400)
  local filtre = etatShell.filtreJournal

  local retenues = {}
  for _, ligne in ipairs(lignes) do
    local garder = (filtre == "TOUT")
      or (filtre == "INFO"   and ligne:find("[INFO]", 1, true))
      or (filtre == "AVERT"  and (ligne:find("[AVERT]", 1, true)
                                  or ligne:find("[ERREUR]", 1, true)
                                  or ligne:find("[CRITIQUE]", 1, true)))
      or (filtre == "ERREUR" and (ligne:find("[ERREUR]", 1, true)
                                  or ligne:find("[CRITIQUE]", 1, true)))
    if garder then retenues[#retenues + 1] = ligne end
  end

  ui.encre(P.texteFaible)
  ui.ecrireA(x, y, string.format("%s  |  %d ligne(s)  |  filtre %s",
    CHEMIN_JOURNAL, #retenues, filtre), largeur)

  local visibles = hauteur - 2
  local depart = math.max(1, #retenues - visibles + 1 - etatShell.defilementJournal)
  local l = y + 2
  for indice = depart, math.min(#retenues, depart + visibles - 1) do
    local ligne = retenues[indice]
    local couleur = P.texteFaible
    if ligne:find("[CRITIQUE]", 1, true) then couleur = P.accent
    elseif ligne:find("[ERREUR]", 1, true) then couleur = P.alerte
    elseif ligne:find("[AVERT]", 1, true) then couleur = P.valeur
    elseif ligne:find("[INFO]", 1, true) then couleur = P.texte end
    -- L'horodatage complet mange la largeur d'un ecran d'ordinateur : on ne
    -- garde que l'heure, l'etape et le message.
    local court = ligne:gsub("^%[%d+%-%d+%-%d+ ", "["):gsub("%] %[etape: ", "] [")
    ui.encre(couleur)
    ui.ecrireA(x, l, court, largeur)
    l = l + 1
  end
  if l <= y + hauteur - 1 then
    ui.fond(P.fond)
    for ligne = l, y + hauteur - 2 do ui.ligneVide(ligne, largeur, x) end
  end
end

pages[5].touche = function(touche)
  if touche == keys.up then
    etatShell.defilementJournal = etatShell.defilementJournal + 1
  elseif touche == keys.down then
    etatShell.defilementJournal = math.max(0, etatShell.defilementJournal - 1)
  elseif touche == keys.pageUp then
    etatShell.defilementJournal = etatShell.defilementJournal + 10
  elseif touche == keys.pageDown then
    etatShell.defilementJournal = math.max(0, etatShell.defilementJournal - 10)
  elseif touche == keys["end"] then
    etatShell.defilementJournal = 0
  elseif touche == keys.f then
    etatShell.filtreJournal = ui.suivantDansListe(etatShell.filtreJournal, NIVEAUX_FILTRE, 1)
  else
    return false
  end
  return true
end

pages[5].aide = function() return "Fleches/PgUp/PgDn: defiler  Fin: bas  F: filtre" end

------------------------------------------------------------ 3f. PAGE SYSTEME ---

pages[6] = { nom = "Systeme", touche = "6" }

pages[6].dessiner = function(x, y, largeur, hauteur)
  ui.section(x, y, largeur, "SYSTEME")
  local l = y + 2
  ui.ligneValeur(x, l, largeur, 20, "FrenchNet OS", VERSION_OS) l = l + 1
  ui.ligneValeur(x, l, largeur, 20, "Ordinateur", "#" .. os.getComputerID()) l = l + 1
  ui.ligneValeur(x, l, largeur, 20, "Etiquette", tostring(os.getComputerLabel() or "-")) l = l + 1
  ui.ligneValeur(x, l, largeur, 20, "En service depuis",
    string.format("%.0f s", os.clock())) l = l + 1
  l = l + 1

  ui.section(x, l, largeur, "TACHES")
  l = l + 2
  local noyau = etatShell.noyau
  if noyau then
    for indice, tache in ipairs(noyau.taches) do
      ui.encre(tache.morte and P.alerte or P.bon)
      ui.ecrireA(x, l, tache.morte and "[ARRETEE]" or "[ACTIVE ]")
      ui.encre(P.texte)
      ui.ecrireA(x + 10, l, tache.nom, largeur - 10)
      l = l + 1
      if tache.erreur then
        ui.encre(P.alerte)
        ui.ecrireA(x + 10, l, tache.erreur, largeur - 10)
        l = l + 1
      end
    end
  end
  l = l + 1

  ui.section(x, l, largeur, "PERIPHERIQUES")
  l = l + 2
  local noms = peripheral.getNames()
  if #noms == 0 then
    ui.encre(P.valeur)
    ui.ecrireA(x, l, "aucun peripherique detecte", largeur) l = l + 1
  end
  for _, nom in ipairs(noms) do
    if l >= y + hauteur - 3 then break end
    local ok, type_ = pcall(peripheral.getType, nom)
    ui.encre(P.texteFaible)
    ui.ecrireA(x, l, string.format("%-12s %s", nom, ok and tostring(type_) or "?"), largeur)
    l = l + 1
  end
end

pages[6].touche = function(touche)
  if touche == keys.q then
    if ui.confirmer("Quitter", {
        "Arreter le systeme d'exploitation ?",
        "Le systeme d'interception sera arrete aussi.",
      }) then
      -- Marqueur d'arret volontaire : le lanceur ne redemarrera pas
      -- l'ordinateur, ce qui laisse la main pour la maintenance.
      local ok, fichier = pcall(fs.open, "/systeme/.arret_manuel", "w")
      if ok and fichier then
        fichier.writeLine("arret demande depuis la page Systeme")
        fichier.close()
      end
      if etatShell.noyau then etatShell.noyau.arreter() end
      return true
    end
    return true
  elseif touche == keys.b then
    if ui.confirmer("Redemarrer", { "Redemarrer l'ordinateur de bord ?" }) then
      os.reboot()
    end
    return true
  end
  return false
end

pages[6].aide = function() return "Q: quitter  B: redemarrer l'ordinateur" end

------------------------------------------------------------ 3g. PAGE CONSOLE ---

pages[7] = { nom = "Console", touche = "7" }

pages[7].dessiner = function(x, y, largeur, hauteur)
  ui.section(x, y, largeur, "CONSOLE DU SYSTEME D'INTERCEPTION")
  local l = y + 2
  ui.encre(P.texteFaible)
  ui.ecrireA(x, l, "La sortie brute du systeme d'interception tourne dans sa", largeur) l = l + 1
  ui.ecrireA(x, l, "propre fenetre. Entree pour l'afficher en plein ecran ;", largeur) l = l + 1
  ui.ecrireA(x, l, "Echap depuis cette fenetre pour revenir au systeme.", largeur) l = l + 2

  local noyau = etatShell.noyau
  if not noyau or not etatShell.indiceConsole then
    ui.encre(P.valeur)
    ui.ecrireA(x, l, "Systeme d'interception non lance (mode interface seule).", largeur)
    return
  end

  local tache = noyau.taches[etatShell.indiceConsole]
  ui.ligneValeur(x, l, largeur, 20, "Tache", tache.nom) l = l + 1
  ui.ligneValeur(x, l, largeur, 20, "Etat",
    tache.morte and "ARRETEE" or "active",
    tache.morte and P.alerte or P.bon) l = l + 1
  if tache.erreur then
    l = l + 1
    ui.encre(P.alerte)
    ui.ecrireA(x, l, "Erreur :", largeur) l = l + 1
    -- L'erreur peut tenir sur plusieurs lignes (pile d'appels).
    for morceau in (tache.erreur .. "\n"):gmatch("([^\n]*)\n") do
      if l >= y + hauteur - 2 then break end
      ui.encre(P.texte)
      ui.ecrireA(x, l, morceau, largeur)
      l = l + 1
    end
  end
end

pages[7].touche = function(touche)
  if touche == keys.enter and etatShell.noyau and etatShell.indiceConsole then
    etatShell.basculerConsole = true
    return true
  end
  return false
end

pages[7].aide = function() return "Entree: afficher la console en plein ecran" end

--------------------------------------------------------------------------------
-- 4. SHELL
--------------------------------------------------------------------------------

local function dessinerShell()
  local largeur, hauteur = term.getSize()
  local t = tableauDeBord()

  ui.effacer()

  -- Barre de titre.
  local droite = (t.etat and (t.etat .. "  ") or "") .. ui.heure()
  ui.barre(1, largeur, "FRENCHNET OS  " .. tostring(t.identifiant or ""), droite)

  -- Panneau de pages a gauche.
  local largeurPanneau = 13
  ui.fond(P.fondPanneau)
  for ligne = 2, hauteur - 1 do ui.ligneVide(ligne, largeurPanneau, 1) end

  for indice, page in ipairs(pages) do
    local ligne = 2 + indice
    local courante = (indice == etatShell.pageCourante)
    ui.fond(courante and P.selection or P.fondPanneau)
    ui.encre(courante and P.texteSelect or P.texte)
    ui.ecrireA(1, ligne, " " .. page.touche .. " " .. page.nom, largeurPanneau)
  end

  -- Marqueurs discrets d'alerte dans le panneau.
  ui.fond(P.fondPanneau)
  if etatShell.arsenalModifie then
    ui.encre(P.valeur)
    ui.ecrireA(1, 2 + 3, "*", 1)
  end
  if t.rearmementRequis then
    ui.encre(P.alerte)
    ui.ecrireA(1, 2 + 2, "!", 1)
  end

  -- Contenu.
  local x = largeurPanneau + 2
  local largeurContenu = largeur - x
  local hauteurContenu = hauteur - 3
  ui.fond(P.fond)
  for ligne = 2, hauteur - 1 do ui.ligneVide(ligne, largeurContenu + 1, x - 1) end

  local page = pages[etatShell.pageCourante]
  local ok, err = pcall(page.dessiner, x, 3, largeurContenu, hauteurContenu)
  if not ok then
    ui.fond(P.fond)
    ui.encre(P.alerte)
    ui.ecrireA(x, 3, "Erreur d'affichage de la page :", largeurContenu)
    ui.ecrireA(x, 4, tostring(err), largeurContenu)
  end

  -- Barre d'etat.
  local aide = page.aide and page.aide() or "Chiffres ou Tab: changer de page"
  if etatShell.message and (os.clock() - etatShell.messageA) < 6 then
    ui.barre(hauteur, largeur, etatShell.message, nil,
      etatShell.messageAlerte and P.alerte or P.bon,
      etatShell.messageAlerte and P.texte or P.texteBarre)
  else
    ui.barre(hauteur, largeur, aide, nil, P.fondPanneau, P.texteFaible)
  end
end

local function boucleShell()
  local minuteur = os.startTimer(0.5)

  while true do
    dessinerShell()

    local evenement = table.pack(os.pullEvent())
    local nom = evenement[1]

    if nom == "timer" and evenement[2] == minuteur then
      minuteur = os.startTimer(0.5)

    elseif nom == "key" then
      local touche = evenement[2]

      -- Changement de page : chiffres et Tab, sauf si la page consomme la touche.
      local traitee = pages[etatShell.pageCourante].touche
        and pages[etatShell.pageCourante].touche(touche) or false

      if not traitee then
        if touche == keys.tab then
          etatShell.pageCourante = (etatShell.pageCourante % #pages) + 1
        else
          for indice, page in ipairs(pages) do
            if touche == keys[page.touche] then
              etatShell.pageCourante = indice
              break
            end
          end
        end
      end

      if etatShell.basculerConsole then
        etatShell.basculerConsole = false
        if etatShell.noyau and etatShell.indiceConsole then
          etatShell.noyau.afficher(etatShell.indiceConsole)
          -- On attend le retour : Echap dans la console rend la main.
          while true do
            local _, t2 = os.pullEvent("key")
            if t2 == keys.escape then break end
          end
          etatShell.noyau.afficher(1)
        end
      end

    elseif nom == "mouse_click" then
      local _, _, mx, my = table.unpack(evenement, 1, 4)
      if mx <= 13 then
        local indice = my - 2
        if pages[indice] then etatShell.pageCourante = indice end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- 5. POINT D'ENTREE
--------------------------------------------------------------------------------

local arguments = { ... }
etatShell.autonome = (arguments[1] == "interface")

local controles, arsenal = controlesAmorcage()
local bloquants = ecranAmorcage(controles)

if bloquants > 0 and not etatShell.autonome then
  local largeur, hauteur = term.getSize()
  ui.fond(P.fond)
  ui.encre(P.alerte)
  ui.ecrireA(2, hauteur - 3, string.format(
    "%d controle(s) bloquant(s) : le systeme d'interception ne sera PAS lance.",
    bloquants), largeur - 2)
  ui.encre(P.texteFaible)
  ui.ecrireA(2, hauteur - 2, "L'interface reste disponible pour corriger. Une touche...",
    largeur - 2)
  os.pullEvent("key")
  etatShell.autonome = true
else
  ui.fond(P.fond)
  ui.encre(P.bon)
  local largeur, hauteur = term.getSize()
  ui.ecrireA(2, hauteur - 2, etatShell.autonome
    and "Interface seule. Une touche pour continuer..."
    or "Tous les controles sont passes. Une touche pour demarrer...", largeur - 2)
  os.pullEvent("key")
end

local noyau = taches.creer()
etatShell.noyau = noyau

noyau.ajouter("Interface FrenchNet OS", boucleShell)

if not etatShell.autonome then
  etatShell.indiceConsole = noyau.ajouter("Systeme d'interception", function()
    -- Le systeme d'interception est un programme complet : on le lance tel
    -- quel dans sa fenetre. Il garde son superviseur et sa journalisation.
    shell.run(CHEMIN_INTERCEPTEUR)
  end)
end

noyau.executer()

term.redirect(noyau.terminalReel)
ui.effacer()
term.setCursorPos(1, 1)
print("FrenchNet OS arrete.")
for _, tache in ipairs(noyau.taches) do
  if tache.erreur then
    print("  " .. tache.nom .. " : " .. tache.erreur)
  end
end
