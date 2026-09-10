--[[ DOOMSDAY SHIP - FRAMEWORK D'AFFICHAGE MULTIFONCTION
     SURFACE = un ecran physique. FENETRE = une zone d'une surface.
     PAGE = un module Lua qui se dessine dans une fenetre.

     Quatre choix deliberes :
     - layout en FRACTIONS (0..1), jamais en caracteres : un 3x3 et un 2x2
       n'ont pas la meme taille, une disposition figee serait fausse sur l'un ;
     - registre de pages : en ajouter une ne touche a aucune ligne d'ici ;
     - dessin entre setVisible(false/true) : CC accumule et ne pousse qu'une
       image. Sur un moniteur, chaque modification est un paquet envoye a tous
       les joueurs a portee ;
     - les alarmes forment une PILE : l'ecran d'avant est RESTITUE a la levee.
       L'ecraser obligerait l'equipage a le retrouver a la main, en avarie.
     Dependances injectables : testable seul. ]]

local mfd = { VERSION = "2.0.0" }
local NIV = { INFO = 1, ATTENTION = 2, ALARME = 3, CRITIQUE = 4 }
mfd.NIVEAUX_ALARME = NIV
local ECHELLES = { 5, 4, 3, 2.5, 2, 1.5, 1, 0.5 }

local function nb(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

function mfd.nouveau(o)
  o = o or {}
  local e = o.environnement or {}
  return setmetatable({
    peripheriques = e.peripheral or peripheral, term = e.term or term,
    window = e.window or window, journal = o.journal or function() end,
    pages = {}, surfaces = {}, layout = o.layout or {}, contexte = o.contexte or {},
    largeurMini = o.largeurMini or 26, hauteurMini = o.hauteurMini or 8,
    compteurs = { dessins = 0, fenetres = 0, alarmes = 0 },
  }, { __index = mfd })
end

--[[ Contrat d'une page, tout facultatif sauf 'dessiner' :
     titre, periode, init(ctx), dessiner(fenetre, ctx, geometrie),
     clic(ctx, x, y, geometrie)  -- x,y LOCAUX a la fenetre ]]
function mfd:enregistrerPage(nom, page)
  if type(nom) ~= "string" or nom == "" then return false, "nom de page invalide" end
  if type(page) ~= "table" or type(page.dessiner) ~= "function" then
    return false, "une page doit exposer dessiner(fenetre, ctx, geometrie)"
  end
  page.nom, page.titre, page.periode = nom, page.titre or nom:upper(), page.periode or 1
  self.pages[nom] = page
  return true
end

function mfd:pagesConnues()
  local n = {}
  for nom in pairs(self.pages) do n[#n + 1] = nom end
  table.sort(n) return n
end

-- Plus grande echelle qui laisse encore la place : du texte lisible de loin
-- prime sur une page immense en caracteres minuscules.
function mfd:choisirEchelle(mon, lMini, hMini)
  for _, e in ipairs(ECHELLES) do
    if pcall(mon.setTextScale, e) then
      local l, h = mon.getSize()
      if l >= lMini and h >= hMini then return e, l, h end
    end
  end
  pcall(mon.setTextScale, 0.5)
  local l, h = mon.getSize() return 0.5, l, h
end

-- Rejouable a chaud : c'est elle qu'on rappelle sur peripheral/_detach.
function mfd:detecterSurfaces()
  local vues, S = {}, self.surfaces

  local l, h = self.term.getSize()
  if S.terminal then S.terminal.largeur, S.terminal.hauteur = l, h
  else
    S.terminal = { nom = "terminal", cible = self.term, estTerminal = true,
                   largeur = l, hauteur = h, fenetres = {}, pile = {} }
    self.journal("INFO", "affichage", ("surface 'terminal' : %dx%d"):format(l, h))
  end
  vues.terminal = true

  local ok, noms = pcall(self.peripheriques.getNames)
  for _, nom in ipairs((ok and type(noms) == "table") and noms or {}) do
    local okT, typ = pcall(self.peripheriques.getType, nom)
    if okT and typ == "monitor" then
      local mon = self.peripheriques.wrap(nom)
      if mon then
        local reg = self.layout[nom] or {}
        local ech, lm, hm
        if nb(reg.echelle) then
          pcall(mon.setTextScale, reg.echelle) ech = reg.echelle lm, hm = mon.getSize()
        else
          ech, lm, hm = self:choisirEchelle(mon, reg.largeurMini or self.largeurMini,
                                                 reg.hauteurMini or self.hauteurMini)
        end
        local s = S[nom]
        if not s then
          S[nom] = { nom = nom, cible = mon, largeur = lm, hauteur = hm,
                     echelle = ech, fenetres = {}, pile = {} }
          self.journal("INFO", "affichage", ("surface '%s' adoptee : %dx%d a l'echelle %.1f%s")
            :format(nom, lm, hm, ech, (mon.isColour and mon.isColour()) and "" or " (monochrome)"))
        elseif s.largeur ~= lm or s.hauteur ~= hm then
          s.largeur, s.hauteur, s.echelle, s.fenetres = lm, hm, ech, {}
          self.journal("INFO", "affichage", ("surface '%s' redimensionnee : %dx%d"):format(nom, lm, hm))
        end
        vues[nom] = true
      end
    end
  end

  for nom, s in pairs(S) do
    if not vues[nom] and not s.estTerminal then
      S[nom] = nil
      self.journal("AVERT", "affichage", "surface '" .. nom .. "' perdue : moniteur retire")
    end
  end
  return S
end

local function geo(s, d)
  local l = math.max(1, math.floor(s.largeur * (d.l or 1) + 0.5))
  local h = math.max(1, math.floor(s.hauteur * (d.h or 1) + 0.5))
  local x = math.max(1, math.floor(s.largeur * (d.x or 0) + 0.5) + 1)
  local y = math.max(1, math.floor(s.hauteur * (d.y or 0) + 0.5) + 1)
  -- On rogne plutot que de laisser CC tronquer en silence.
  if x + l - 1 > s.largeur then l = s.largeur - x + 1 end
  if y + h - 1 > s.hauteur then h = s.hauteur - y + 1 end
  return x, y, l, h
end
mfd.geometrieDepuisFraction = geo

function mfd:appliquerLayout(layout)
  if layout then self.layout = layout end
  self.compteurs.fenetres = 0

  for nom, s in pairs(self.surfaces) do
    local reg = self.layout[nom]
    local defs = reg and reg.fenetres
    -- Sans consigne : une seule page plein ecran. Un ecran vide n'aide personne.
    if not defs or #defs == 0 then
      local d = (reg and reg.page) or self.layout.pageParDefaut or (self:pagesConnues())[1]
      defs = d and { { page = d } } or {}
    end

    s.fenetres = {}
    for _, d in ipairs(defs) do
      local page = self.pages[d.page]
      if not page then
        self.journal("AVERT", "affichage",
          ("surface '%s' : page '%s' inconnue"):format(nom, tostring(d.page)))
      else
        local x, y, l, h = geo(s, d)
        -- Mieux vaut une page absente qu'une page illisible sur laquelle on
        -- croit pouvoir compter.
        if l < self.largeurMini or h < self.hauteurMini then
          self.journal("AVERT", "affichage",
            ("surface '%s' : fenetre '%s' trop petite (%dx%d < %dx%d), ignoree")
            :format(nom, d.page, l, h, self.largeurMini, self.hauteurMini))
        else
          if not page.initialisee then
            if type(page.init) == "function" then pcall(page.init, self.contexte) end
            page.initialisee = true
          end
          s.fenetres[#s.fenetres + 1] = {
            page = page, fenetre = self.window.create(s.cible, x, y, l, h, true),
            geometrie = { x = x, y = y, largeur = l, hauteur = h }, dernierDessin = -1e9,
          }
          self.compteurs.fenetres = self.compteurs.fenetres + 1
        end
      end
    end
  end
  return self.compteurs.fenetres
end

-- Pile ordonnee par NIVEAU : une critique passe devant une attention deja
-- affichee, et celle-ci reapparait quand la critique est levee.
function mfd:alarme(cle, niveau, titre, lignes, visees)
  local a = { cle = cle, niveau = niveau, rang = NIV[niveau] or NIV.ALARME,
              titre = titre, lignes = lignes or {}, poseeA = os.clock() }
  for nom, s in pairs(self.surfaces) do
    if not visees or visees[nom] then
      local remplacee = false
      for i, x in ipairs(s.pile) do
        if x.cle == cle then s.pile[i] = a remplacee = true break end
      end
      if not remplacee then s.pile[#s.pile + 1] = a s.forcer = true end
      table.sort(s.pile, function(p, q)
        if p.rang ~= q.rang then return p.rang > q.rang end
        return p.poseeA < q.poseeA
      end)
    end
  end
  self.compteurs.alarmes = self.compteurs.alarmes + 1
  self.journal(a.rang >= NIV.ALARME and "AVERT" or "INFO", "alarme",
    ("[%s] %s"):format(niveau, titre))
  return a
end

function mfd:leverAlarme(cle)
  local n = 0
  for _, s in pairs(self.surfaces) do
    for i = #s.pile, 1, -1 do
      if s.pile[i].cle == cle then
        table.remove(s.pile, i) n = n + 1
        s.forcer = true   -- l'affichage d'avant doit revenir intact
      end
    end
  end
  if n > 0 then self.journal("INFO", "alarme", "alarme '" .. tostring(cle) .. "' levee") end
  return n
end

function mfd:alarmeActive(s) return s.pile[1] end

local FOND_ALARME = { INFO = colors.blue, ATTENTION = colors.yellow,
                      ALARME = colors.orange, CRITIQUE = colors.red }

local function dessinerAlarme(s, a)
  local c = s.cible
  pcall(function()
    c.setBackgroundColour(FOND_ALARME[a.niveau] or colors.red)
    c.setTextColour(colors.white) c.clear()
    c.setCursorPos(1, math.max(1, math.floor(s.hauteur / 2) - #a.lignes))
    c.write((" " .. tostring(a.titre)):sub(1, s.largeur))
    local y = math.max(2, math.floor(s.hauteur / 2) - #a.lignes + 2)
    for _, l in ipairs(a.lignes) do
      c.setCursorPos(2, y) c.write(tostring(l):sub(1, s.largeur - 2)) y = y + 1
    end
    c.setCursorPos(1, s.hauteur)
    c.write((" " .. a.niveau .. " - toute touche pour acquitter"):sub(1, s.largeur))
  end)
end

-- Rend le nombre de fenetres redessinees. Zero sur situation stable = le
-- systeme ne gaspille pas de trafic vers les joueurs alentour.
function mfd:dessiner(maintenant)
  maintenant = maintenant or os.clock()
  local n = 0

  for _, s in pairs(self.surfaces) do
    local a = self:alarmeActive(s)
    if a then
      if s.alarmeAffichee ~= a or s.forcer then
        dessinerAlarme(s, a) s.alarmeAffichee, s.forcer = a, false n = n + 1
      end
    else
      -- Retour au normal : image complete, sinon le fond de l'alarme reste
      -- sous les fenetres.
      if s.alarmeAffichee then
        s.alarmeAffichee, s.forcer = nil, true
        pcall(function() s.cible.setBackgroundColour(colors.black) s.cible.clear() end)
      end
      for _, p in ipairs(s.fenetres) do
        if s.forcer or (maintenant - p.dernierDessin) >= (p.page.periode or 1) then
          pcall(p.fenetre.setVisible, false)
          local ok, err = pcall(p.page.dessiner, p.fenetre, self.contexte, p.geometrie)
          pcall(p.fenetre.setVisible, true)
          if not ok then
            self.journal("ERREUR", "affichage",
              ("page '%s' a echoue au dessin : %s"):format(p.page.nom, tostring(err)))
          end
          p.dernierDessin = maintenant n = n + 1
        end
      end
      s.forcer = false
    end
  end
  self.compteurs.dessins = self.compteurs.dessins + n
  return n
end

-- Rend true si l'evenement a ete consomme.
function mfd:evenement(nom, p1, p2, p3)
  if nom == "peripheral" or nom == "peripheral_detach"
     or nom == "monitor_resize" or nom == "term_resize" then
    self:detecterSurfaces() self:appliquerLayout()
    for _, s in pairs(self.surfaces) do s.forcer = true end
    return true
  end

  if nom == "monitor_touch" or nom == "mouse_click" then
    local nomS, x, y
    if nom == "monitor_touch" then nomS, x, y = p1, p2, p3
    else nomS, x, y = "terminal", p2, p3 end
    local s = self.surfaces[nomS]
    if not s then return false end

    local a = self:alarmeActive(s)
    if a then self:leverAlarme(a.cle) return true end

    for _, p in ipairs(s.fenetres) do
      local g = p.geometrie
      if x >= g.x and x < g.x + g.largeur and y >= g.y and y < g.y + g.hauteur then
        if type(p.page.clic) == "function" then
          pcall(p.page.clic, self.contexte, x - g.x + 1, y - g.y + 1, g)
        end
        p.dernierDessin = -1e9
        return true
      end
    end
  end
  return false
end

return mfd
