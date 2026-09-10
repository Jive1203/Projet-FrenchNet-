--[[----------------------------------------------------------------------------
  DOOMSDAY SHIP - FRAMEWORK D'AFFICHAGE MULTIFONCTION (MFD)
  --------------------------------------------------------------------------
  Prerequis a tout le reste du systeme embarque. Il ne sait rien du ballon :
  il place des PAGES dans des FENETRES posees sur des SURFACES.

    SURFACE  un ecran physique - le terminal, ou un moniteur accole.
    FENETRE  une zone rectangulaire d'une surface, creee via window.create.
    PAGE     un module Lua independant qui se dessine dans une fenetre.

  CE QUI EST DELIBERE
  - Le layout est exprime en FRACTIONS de surface (0 a 1), jamais en
    caracteres. Un moniteur 3x3 et un 2x2 ne font pas la meme taille, et une
    disposition figee en caracteres serait fausse sur l'un des deux.
  - Les pages sont enregistrees dans un registre : en ajouter une ne demande
    de toucher a aucune ligne de ce fichier.
  - Le dessin passe par window.setVisible(false/true) : CC accumule les
    ecritures et ne pousse qu'une image complete. Sur un moniteur Minecraft,
    chaque modification est un paquet envoye a tous les joueurs a portee -
    accumuler, c'est diviser ce trafic par le nombre de lignes.
  - Les alarmes forment une PILE par surface : une alarme prend l'ecran, et
    l'ecran d'avant est restitue quand elle est levee. Une alarme qui ferait
    perdre l'affichage precedent obligerait l'equipage a le retrouver a la
    main, en pleine avarie.

  Aucune dependance au reste du systeme : ce module est testable seul.
--------------------------------------------------------------------------------]]

local mfd = { VERSION = "1.0.0" }

local NIVEAUX_ALARME = { INFO = 1, ATTENTION = 2, ALARME = 3, CRITIQUE = 4 }
mfd.NIVEAUX_ALARME = NIVEAUX_ALARME

-- Echelles de texte acceptees par CC: Tweaked, de la plus grande a la plus fine.
local ECHELLES = { 5, 4, 3, 2.5, 2, 1.5, 1, 0.5 }

local function nombreValide(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--------------------------------------------------------------------------------
-- 1. CONSTRUCTION
--------------------------------------------------------------------------------

--[[
  environnement permet d'injecter peripheral / term / window pour les tests.
  En jeu, les valeurs par defaut sont les API globales.
]]
function mfd.nouveau(options)
  options = options or {}
  local env = options.environnement or {}
  local systeme = {
    peripheriques = env.peripheral or peripheral,
    term          = env.term or term,
    window        = env.window or window,
    journal       = options.journal or function() end,
    pages         = {},      -- [nom] = module de page
    surfaces      = {},      -- [nom] = surface
    layout        = options.layout or {},
    contexte      = options.contexte or {},
    largeurMini   = options.largeurMini or 26,
    hauteurMini   = options.hauteurMini or 8,
    compteurs     = { dessins = 0, fenetres = 0, alarmes = 0 },
  }
  return setmetatable(systeme, { __index = mfd })
end

--------------------------------------------------------------------------------
-- 2. REGISTRE DE PAGES
--
--   Contrat d'une page - tout est facultatif sauf 'dessiner' :
--     titre      chaine affichee dans l'en-tete de la fenetre
--     init(ctx)  appelee une fois, au premier placement
--     dessiner(fenetre, ctx, geometrie)   OBLIGATOIRE
--     periode    secondes entre deux redessins (defaut 1)
--     clic(ctx, x, y, geometrie)          coordonnees LOCALES a la fenetre
--     touche(ctx, code, geometrie)
--------------------------------------------------------------------------------

function mfd:enregistrerPage(nom, page)
  if type(nom) ~= "string" or nom == "" then return false, "nom de page invalide" end
  if type(page) ~= "table" or type(page.dessiner) ~= "function" then
    return false, "une page doit exposer une fonction dessiner(fenetre, ctx, geometrie)"
  end
  page.nom = nom
  page.titre = page.titre or nom:upper()
  page.periode = page.periode or 1
  self.pages[nom] = page
  return true
end

function mfd:pagesConnues()
  local noms = {}
  for nom in pairs(self.pages) do noms[#noms + 1] = nom end
  table.sort(noms)
  return noms
end

--------------------------------------------------------------------------------
-- 3. DETECTION DES SURFACES
--
--   Le terminal est toujours une surface. Chaque moniteur accole en devient
--   une. La detection est rejouable a chaud : c'est elle qu'on rappelle sur
--   les evenements peripheral et peripheral_detach.
--------------------------------------------------------------------------------

-- Plus grande echelle de texte qui laisse encore la place demandee. Du texte
-- lisible de loin prime sur une page immense en caracteres minuscules.
function mfd:choisirEchelle(moniteur, largeurMini, hauteurMini)
  for _, echelle in ipairs(ECHELLES) do
    local ok = pcall(moniteur.setTextScale, echelle)
    if ok then
      local l, h = moniteur.getSize()
      if l >= largeurMini and h >= hauteurMini then return echelle, l, h end
    end
  end
  pcall(moniteur.setTextScale, 0.5)
  local l, h = moniteur.getSize()
  return 0.5, l, h
end

function mfd:detecterSurfaces()
  local vues = {}

  -- Terminal : toujours present, jamais retire.
  do
    local l, h = self.term.getSize()
    local existante = self.surfaces.terminal
    if existante then
      existante.largeur, existante.hauteur = l, h
    else
      self.surfaces.terminal = {
        nom = "terminal", cible = self.term, estTerminal = true,
        largeur = l, hauteur = h, fenetres = {}, pile = {},
      }
      self.journal("INFO", "affichage", string.format(
        "surface 'terminal' : %dx%d caracteres", l, h))
    end
    vues.terminal = true
  end

  -- Moniteurs accoles.
  local noms = {}
  local ok, liste = pcall(self.peripheriques.getNames)
  if ok and type(liste) == "table" then noms = liste end

  for _, nom in ipairs(noms) do
    local typeOk, typ = pcall(self.peripheriques.getType, nom)
    if typeOk and typ == "monitor" then
      local moniteur = self.peripheriques.wrap(nom)
      if moniteur then
        local surface = self.surfaces[nom]
        local reglage = (self.layout[nom] or {})
        local echelle, l, h

        if nombreValide(reglage.echelle) then
          pcall(moniteur.setTextScale, reglage.echelle)
          echelle = reglage.echelle
          l, h = moniteur.getSize()
        else
          echelle, l, h = self:choisirEchelle(moniteur,
            reglage.largeurMini or self.largeurMini,
            reglage.hauteurMini or self.hauteurMini)
        end

        if not surface then
          self.surfaces[nom] = {
            nom = nom, cible = moniteur, largeur = l, hauteur = h,
            echelle = echelle, fenetres = {}, pile = {},
          }
          self.journal("INFO", "affichage", string.format(
            "surface '%s' adoptee : %dx%d caracteres a l'echelle %.1f%s",
            nom, l, h, echelle, (moniteur.isColour and moniteur.isColour())
              and "" or " (monochrome)"))
        elseif surface.largeur ~= l or surface.hauteur ~= h then
          surface.largeur, surface.hauteur, surface.echelle = l, h, echelle
          surface.fenetres = {}   -- geometrie perimee : a reconstruire
          self.journal("INFO", "affichage", string.format(
            "surface '%s' redimensionnee : %dx%d", nom, l, h))
        end
        vues[nom] = true
      end
    end
  end

  -- Surfaces disparues : moniteur casse ou detache.
  for nom, surface in pairs(self.surfaces) do
    if not vues[nom] and not surface.estTerminal then
      self.surfaces[nom] = nil
      self.journal("AVERT", "affichage",
        "surface '" .. nom .. "' perdue : moniteur retire ou casse")
    end
  end

  return self.surfaces
end

--------------------------------------------------------------------------------
-- 4. PLACEMENT DES FENETRES
--
--   Le layout decrit, par surface, une liste de fenetres exprimees en
--   FRACTIONS : x et y de 0 a 1, largeur et hauteur de 0 a 1. Une fenetre
--   { page = "propulsion", x = 0, y = 0, l = 0.5, h = 1 } occupe la moitie
--   gauche, quelle que soit la taille reelle de l'ecran.
--
--   Une fenetre trop petite pour etre lisible est refusee et journalisee :
--   mieux vaut une page absente qu'une page illisible sur laquelle on croit
--   pouvoir compter.
--------------------------------------------------------------------------------

local function geometrieDepuisFraction(surface, definition)
  local l = math.max(1, math.floor(surface.largeur * (definition.l or 1) + 0.5))
  local h = math.max(1, math.floor(surface.hauteur * (definition.h or 1) + 0.5))
  local x = math.max(1, math.floor(surface.largeur * (definition.x or 0) + 0.5) + 1)
  local y = math.max(1, math.floor(surface.hauteur * (definition.y or 0) + 0.5) + 1)
  -- Debordement : on rogne plutot que de laisser CC tronquer en silence.
  if x + l - 1 > surface.largeur then l = surface.largeur - x + 1 end
  if y + h - 1 > surface.hauteur then h = surface.hauteur - y + 1 end
  return x, y, l, h
end
mfd.geometrieDepuisFraction = geometrieDepuisFraction

function mfd:appliquerLayout(layout)
  if layout then self.layout = layout end
  self.compteurs.fenetres = 0

  for nom, surface in pairs(self.surfaces) do
    local reglage = self.layout[nom] or self.layout[surface.estTerminal and "terminal" or nil]
    local definitions = reglage and reglage.fenetres

    -- Sans consigne, la surface affiche une seule page : la premiere declaree
    -- par defaut, ou la premiere du registre. Un ecran vide n'aide personne.
    if not definitions or #definitions == 0 then
      local defaut = (reglage and reglage.page)
        or (self.layout.pageParDefaut)
        or (self:pagesConnues())[1]
      definitions = defaut and { { page = defaut } } or {}
    end

    surface.fenetres = {}
    for _, definition in ipairs(definitions) do
      local page = self.pages[definition.page]
      if not page then
        self.journal("AVERT", "affichage", string.format(
          "surface '%s' : page '%s' inconnue, ignoree", nom, tostring(definition.page)))
      else
        local x, y, l, h = geometrieDepuisFraction(surface, definition)
        if l < self.largeurMini or h < self.hauteurMini then
          self.journal("AVERT", "affichage", string.format(
            "surface '%s' : fenetre '%s' trop petite (%dx%d, minimum %dx%d), ignoree",
            nom, definition.page, l, h, self.largeurMini, self.hauteurMini))
        else
          local fenetre = self.window.create(surface.cible, x, y, l, h, true)
          if not page.initialisee then
            if type(page.init) == "function" then pcall(page.init, self.contexte) end
            page.initialisee = true
          end
          surface.fenetres[#surface.fenetres + 1] = {
            page = page, fenetre = fenetre,
            geometrie = { x = x, y = y, largeur = l, hauteur = h },
            dernierDessin = -1e9,
          }
          self.compteurs.fenetres = self.compteurs.fenetres + 1
        end
      end
    end
  end
  return self.compteurs.fenetres
end

--------------------------------------------------------------------------------
-- 5. ALARMES - pile de prise d'ecran
--
--   Une alarme prend la surface, quel que soit ce qui y etait affiche, et la
--   rend telle quelle une fois levee. La pile ordonne par NIVEAU : une alarme
--   critique passe devant une alarme d'attention deja affichee, et celle-ci
--   reapparait quand la critique est levee.
--------------------------------------------------------------------------------

function mfd:alarme(cle, niveau, titre, lignes, surfacesVisees)
  local rang = NIVEAUX_ALARME[niveau] or NIVEAUX_ALARME.ALARME
  local alarme = {
    cle = cle, niveau = niveau, rang = rang, titre = titre,
    lignes = lignes or {}, poseeA = os.clock(),
  }

  for nom, surface in pairs(self.surfaces) do
    if not surfacesVisees or surfacesVisees[nom] then
      local remplacee = false
      for i, a in ipairs(surface.pile) do
        if a.cle == cle then surface.pile[i] = alarme remplacee = true break end
      end
      if not remplacee then
        surface.pile[#surface.pile + 1] = alarme
        surface.forcer = true
      end
      table.sort(surface.pile, function(a, b)
        if a.rang ~= b.rang then return a.rang > b.rang end
        return a.poseeA < b.poseeA
      end)
    end
  end

  self.compteurs.alarmes = self.compteurs.alarmes + 1
  self.journal(rang >= NIVEAUX_ALARME.ALARME and "AVERT" or "INFO", "alarme",
    string.format("[%s] %s", niveau, titre))
  return alarme
end

function mfd:leverAlarme(cle)
  local levees = 0
  for _, surface in pairs(self.surfaces) do
    for i = #surface.pile, 1, -1 do
      if surface.pile[i].cle == cle then
        table.remove(surface.pile, i)
        levees = levees + 1
        -- L'affichage d'avant doit revenir intact, pas a moitie efface.
        surface.forcer = true
      end
    end
  end
  if levees > 0 then
    self.journal("INFO", "alarme", "alarme '" .. tostring(cle) .. "' levee")
  end
  return levees
end

function mfd:alarmeActive(surface)
  return surface.pile[1]
end

--------------------------------------------------------------------------------
-- 6. DESSIN
--------------------------------------------------------------------------------

local function dessinerAlarme(surface, alarme)
  local cible = surface.cible
  local couleurs = {
    INFO = colors.blue, ATTENTION = colors.yellow,
    ALARME = colors.orange, CRITIQUE = colors.red,
  }
  local fond = couleurs[alarme.niveau] or colors.red

  pcall(function()
    cible.setBackgroundColour(fond)
    cible.setTextColour(colors.white)
    cible.clear()
    local largeur = surface.largeur

    local bandeau = " " .. tostring(alarme.titre)
    cible.setCursorPos(1, math.max(1, math.floor(surface.hauteur / 2) - #alarme.lignes))
    cible.write(bandeau:sub(1, largeur))

    local y = math.max(2, math.floor(surface.hauteur / 2) - #alarme.lignes + 2)
    for _, ligne in ipairs(alarme.lignes) do
      cible.setCursorPos(2, y)
      cible.write(tostring(ligne):sub(1, largeur - 2))
      y = y + 1
    end

    cible.setCursorPos(1, surface.hauteur)
    cible.write((" " .. alarme.niveau .. " - toute touche pour acquitter"):sub(1, largeur))
  end)
end

--[[
  Dessine tout ce qui doit l'etre. Retourne le nombre de fenetres redessinees :
  un compteur nul sur une situation stable est le signe que le systeme ne
  gaspille pas de trafic vers les joueurs alentour.
]]
function mfd:dessiner(maintenant)
  maintenant = maintenant or os.clock()
  local redessinees = 0

  for _, surface in pairs(self.surfaces) do
    local alarme = self:alarmeActive(surface)

    if alarme then
      if surface.alarmeAffichee ~= alarme or surface.forcer then
        dessinerAlarme(surface, alarme)
        surface.alarmeAffichee = alarme
        surface.forcer = false
        redessinees = redessinees + 1
      end
    else
      -- Retour a l'affichage normal apres une alarme : on force une image
      -- complete, sinon il resterait le fond de l'alarme sous les fenetres.
      if surface.alarmeAffichee then
        surface.alarmeAffichee = nil
        surface.forcer = true
        pcall(function()
          surface.cible.setBackgroundColour(colors.black)
          surface.cible.clear()
        end)
      end

      for _, place in ipairs(surface.fenetres) do
        local page = place.page
        local du = maintenant - place.dernierDessin
        if surface.forcer or du >= (page.periode or 1) then
          local fenetre = place.fenetre
          -- On masque pendant le dessin : CC accumule les ecritures et ne
          -- pousse qu'une image complete au lieu de chaque caractere.
          pcall(fenetre.setVisible, false)
          local ok, err = pcall(page.dessiner, fenetre, self.contexte, place.geometrie)
          pcall(fenetre.setVisible, true)
          if not ok then
            self.journal("ERREUR", "affichage", string.format(
              "page '%s' a echoue au dessin : %s", page.nom, tostring(err)))
          end
          place.dernierDessin = maintenant
          redessinees = redessinees + 1
        end
      end
      surface.forcer = false
    end
  end

  self.compteurs.dessins = self.compteurs.dessins + redessinees
  return redessinees
end

--------------------------------------------------------------------------------
-- 7. EVENEMENTS
--------------------------------------------------------------------------------

--[[
  Retourne true si l'evenement a ete consomme par le framework.
  Le programme appelant garde la main sur tout le reste.
]]
function mfd:evenement(nom, p1, p2, p3)
  if nom == "peripheral" or nom == "peripheral_detach"
     or nom == "monitor_resize" or nom == "term_resize" then
    self:detecterSurfaces()
    self:appliquerLayout()
    for _, surface in pairs(self.surfaces) do surface.forcer = true end
    return true
  end

  if nom == "monitor_touch" or nom == "mouse_click" then
    local nomSurface = (nom == "monitor_touch") and p1 or "terminal"
    local x = (nom == "monitor_touch") and p2 or p2
    local y = (nom == "monitor_touch") and p3 or p3
    if nom == "mouse_click" then x, y = p2, p3 end

    local surface = self.surfaces[nomSurface]
    if not surface then return false end

    -- Une alarme affichee capte le clic : elle s'acquitte.
    local alarme = self:alarmeActive(surface)
    if alarme then
      self:leverAlarme(alarme.cle)
      return true
    end

    for _, place in ipairs(surface.fenetres) do
      local g = place.geometrie
      if x >= g.x and x < g.x + g.largeur and y >= g.y and y < g.y + g.hauteur then
        if type(place.page.clic) == "function" then
          pcall(place.page.clic, self.contexte, x - g.x + 1, y - g.y + 1, g)
        end
        place.dernierDessin = -1e9   -- redessin immediat
        return true
      end
    end
  end

  return false
end

return mfd
