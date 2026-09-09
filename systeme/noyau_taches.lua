--[[----------------------------------------------------------------------------
  FRENCHNET OS - Noyau multitache
  --------------------------------------------------------------------------
  Petit ordonnanceur cooperatif, dans l'esprit du multishell de CC: Tweaked.

  Pourquoi ne pas se contenter de parallel.waitForAny ? Parce que parallel
  distribue TOUS les evenements a TOUTES les coroutines. Un appui sur une
  touche destine au menu du systeme serait aussi recu par le systeme
  d'interception, et inversement. Ici :

    * les evenements de TERMINAL (clavier, souris, collage, arret) ne sont
      remis qu'a la tache au premier plan ;
    * tous les autres (minuteurs, rednet, modem, peripheriques, redstone) sont
      remis a TOUTES les taches - une mission ne doit jamais rater un ordre du
      sol parce que l'equipage consulte une autre page ;
    * chaque tache dessine dans SA fenetre ; seule celle du premier plan est
      visible. Une tache de fond continue d'afficher, son ecran est simplement
      conserve jusqu'a ce qu'on l'amene devant.

  Une tache qui meurt ne tue pas le systeme : son erreur est conservee et
  affichee. C'est indispensable a bord - si le systeme d'interception tombe,
  l'equipage doit pouvoir lire pourquoi, pas se retrouver devant un ecran noir.
--------------------------------------------------------------------------------]]

local M = {}

--- Evenements reserves a la tache au premier plan.
local EVENEMENTS_TERMINAL = {
  char = true, key = true, key_up = true, paste = true, terminate = true,
  mouse_click = true, mouse_up = true, mouse_scroll = true, mouse_drag = true,
  file_transfer = true,
}

function M.creer()
  local largeur, hauteur = term.getSize()

  local noyau = {
    taches      = {},
    premierPlan = 1,
    largeur     = largeur,
    hauteur     = hauteur,
    -- Ligne du haut reservee a la barre de titre du systeme : les fenetres
    -- des taches commencent en dessous.
    ligneReservee = 1,
    actif       = true,
    terminalReel = term.current(),
  }

  --- Ajoute une tache.
  -- @param nom     libelle affiche
  -- @param fn      fonction a executer
  -- @param options { visible = booleen }
  function noyau.ajouter(nom, fn, options)
    options = options or {}
    local fenetre = window.create(noyau.terminalReel, 1, 1 + noyau.ligneReservee,
      noyau.largeur, noyau.hauteur - noyau.ligneReservee, false)

    local tache = {
      nom      = nom,
      fenetre  = fenetre,
      routine  = coroutine.create(fn),
      filtre   = nil,
      morte    = false,
      erreur   = nil,
      finieA   = nil,
      demarree = false,
    }
    noyau.taches[#noyau.taches + 1] = tache
    return #noyau.taches
  end

  --- Reprend une tache avec un evenement, en redirigeant le terminal vers sa
  -- fenetre le temps de son execution.
  local function reprendre(tache, evenement)
    if tache.morte then return end
    if tache.filtre ~= nil and evenement[1] ~= tache.filtre
       and evenement[1] ~= "terminate" then
      return
    end

    local precedent = term.redirect(tache.fenetre)
    local ok, resultat = coroutine.resume(tache.routine, table.unpack(evenement, 1, evenement.n))
    term.redirect(precedent)

    tache.demarree = true
    if not ok then
      tache.morte  = true
      tache.erreur = tostring(resultat)
      tache.finieA = os.clock()
    elseif coroutine.status(tache.routine) == "dead" then
      tache.morte  = true
      tache.finieA = os.clock()
    else
      tache.filtre = resultat
    end
  end

  --- Amene une tache au premier plan.
  function noyau.afficher(indice)
    if not noyau.taches[indice] then return false end
    if noyau.premierPlan == indice then return true end
    local ancienne = noyau.taches[noyau.premierPlan]
    if ancienne then ancienne.fenetre.setVisible(false) end
    noyau.premierPlan = indice
    local nouvelle = noyau.taches[indice]
    nouvelle.fenetre.setVisible(true)
    nouvelle.fenetre.redraw()
    return true
  end

  function noyau.tacheCourante()
    return noyau.taches[noyau.premierPlan]
  end

  --- Nombre de taches encore vivantes.
  function noyau.vivantes()
    local n = 0
    for _, tache in ipairs(noyau.taches) do
      if not tache.morte then n = n + 1 end
    end
    return n
  end

  function noyau.arreter()
    noyau.actif = false
  end

  --- Boucle principale. Rend la main quand toutes les taches sont mortes, ou
  -- quand noyau.arreter() a ete appele.
  function noyau.executer()
    -- Amorcage : chaque tache tourne une premiere fois jusqu'a son premier
    -- yield, sans quoi elle ne recevrait jamais le moindre evenement.
    for _, tache in ipairs(noyau.taches) do
      reprendre(tache, { n = 0 })
    end

    local premier = noyau.taches[noyau.premierPlan]
    if premier then
      premier.fenetre.setVisible(true)
      premier.fenetre.redraw()
    end

    while noyau.actif and noyau.vivantes() > 0 do
      local evenement = table.pack(os.pullEventRaw())
      local nom = evenement[1]

      if EVENEMENTS_TERMINAL[nom] then
        local tache = noyau.taches[noyau.premierPlan]
        if tache then reprendre(tache, evenement) end
      else
        -- Copie de la liste : une tache peut en ajouter une pendant la boucle.
        local liste = {}
        for i, tache in ipairs(noyau.taches) do liste[i] = tache end
        for _, tache in ipairs(liste) do reprendre(tache, evenement) end
      end
    end
  end

  return noyau
end

return M
