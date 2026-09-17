--[[----------------------------------------------------------------------------
  CALIBRATION AUTOMATIQUE - AUTOPILOTE FRENCHNET
  --------------------------------------------------------------------------
  Mesure ce que le vehicule sait REELLEMENT faire, puis en deduit ses vitesses
  et un jeu de gains PID de depart. Fini les valeurs devinees a la main : le
  vehicule se mesure lui-meme.

  Pourquoi c'est necessaire : si 'vitesses.croisiere' est inscrite plus haut
  que la vitesse reelle du vehicule, la boucle de vitesse demande en
  permanence l'impossible, sature, et le vol devient une suite d'a-coups.
  Trop basse, le vehicule traine. Aucun reglage de gains ne rattrape cela.

  Principe : chaque axe est pousse a fond pendant quelques secondes. On en
  tire deux nombres.
     K   = vitesse atteinte a pleine commande (le GAIN du vehicule)
     tau = temps pour atteindre 63 % de cette vitesse (son INERTIE)
  Tout le reste s'en deduit :
     boucle interne   kp = 2 / K        ki = kp / (3 tau)    kd = kp tau / 6
     boucle externe   kp = 1 / (3 tau)
  Ces formules placent la boucle fermee a environ trois fois la rapidite du
  vehicule, ce qui est vif sans etre instable, et elles retrouvent d'elles
  memes l'ordre de grandeur des reglages livres.

  SECURITE : le vehicule bouge vraiment, a pleine puissance.
    - a faire dans un espace DEGAGE, loin du relief et des constructions ;
    - toute touche interrompt immediatement et neutralise les commandes ;
    - un ecart de plus de 'rayonMax' blocs du point de depart interrompt ;
    - une perte GPS interrompt ;
    - rien n'est ecrit dans la configuration sans confirmation explicite.

  Usage :  interface calibration        (ou depuis le menu de l'interface)
--------------------------------------------------------------------------------]]

local calibration = {}
calibration.VERSION = "1.0.0"

local ETAPES = {
  PREPARATION = "preparation de la calibration",
  MESURE      = "mesure d'un axe",
  ANALYSE     = "analyse des mesures",
  RESULTAT    = "resultat de la calibration",
  ABANDON     = "abandon de la calibration",
}

--- Essais menes, dans l'ordre. 'commandes' est ce qu'on pousse ; 'lire' dit
--- quelle grandeur observer dans l'etat de l'autopilote.
local ESSAIS = {
  {
    cle = "avance", libelle = "MARCHE AVANT",
    commandes = { avance = 1 },
    lire = function(vol) return vol.diagnostics and vol.diagnostics.vitesseAvanceMesure end,
    repli = function(vol) return vol.vitesseSol end,
    unite = "blocs/s",
    axeGains = "avance",
    reglage = "croisiere",
  },
  {
    cle = "vertical", libelle = "MONTEE",
    commandes = { vertical = 1 },
    lire = function(vol) return vol.vitesse and vol.vitesse.y end,
    unite = "blocs/s",
    axeGains = "altitude",
    reglage = "verticaleMax",
  },
  {
    cle = "lacet", libelle = "VIRAGE",
    -- On avance en meme temps : sans deplacement, un vehicule sans capteur de
    -- cap ne peut pas mesurer sa propre rotation (sa route n'existe pas).
    commandes = { avance = 0.5, lacet = 1 },
    lire = function(vol) return vol.tauxLacet end,
    unite = "degres/s",
    axeGains = "cap",
    reglage = "tauxVirageMax",
  },
  {
    cle = "lateral", libelle = "TRANSLATION LATERALE",
    commandes = { lateral = 1 },
    lire = function(vol)
      return vol.diagnostics and vol.diagnostics.vitesseLateraleMesure
    end,
    unite = "blocs/s",
    axeGains = "derive",
    reglage = "lateraleMax",
    facultatif = true,
  },
}

local DEFAUTS = {
  duree        = 9,     -- secondes de poussee par essai
  repos        = 4,     -- secondes de retour au calme entre deux essais
  rayonMax     = 220,   -- ecart maximal tolere par rapport au point de depart
  margeVitesse = 0.85,  -- on inscrit 85 % de la vitesse mesuree
  partRegime   = 0.4,   -- derniere fraction de l'essai servant de regime etabli
  facteursMaintien = { kp = 1.6, ki = 2.5, kd = 1.6 },
}

local function nombreValide(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--------------------------------------------------------------------------------
-- ANALYSE D'UN ESSAI
--------------------------------------------------------------------------------

--- @param echantillons liste de { t = , v = }
--- @return K (regime etabli), tau (constante de temps), ou nil
local function analyser(echantillons, partRegime)
  if #echantillons < 6 then return nil, nil, "trop peu de mesures" end

  -- Regime etabli : moyenne de la derniere fraction de l'essai. On ignore le
  -- debut, qui n'est que la montee en vitesse.
  local debutRegime = math.floor(#echantillons * (1 - partRegime)) + 1
  local somme, compte = 0, 0
  for i = debutRegime, #echantillons do
    somme = somme + echantillons[i].v
    compte = compte + 1
  end
  if compte == 0 then return nil, nil, "regime etabli vide" end
  local K = somme / compte

  if math.abs(K) < 0.05 then
    return nil, nil, "aucun mouvement mesure : axe non equipe, mal cable, ou inverse"
  end

  -- Constante de temps : instant ou 63 % du regime est atteint.
  local seuil = K * 0.632
  local tau = nil
  local t0 = echantillons[1].t
  for _, echantillon in ipairs(echantillons) do
    if (K > 0 and echantillon.v >= seuil) or (K < 0 and echantillon.v <= seuil) then
      tau = echantillon.t - t0
      break
    end
  end
  -- Reponse trop rapide pour la periode d'echantillonnage : on plafonne par
  -- le bas plutot que d'inventer une inertie nulle.
  if not tau or tau < 0.2 then tau = 0.2 end

  return K, tau, nil
end

--- Retard PUR introduit par un actionneur a crans, en secondes. Un selecteur
-- ne change que d'un cran toutes les cyclesEntreRapports + cyclesImpulsion
-- periodes : ce n'est pas de l'inertie, c'est du temps mort, et une boucle
-- plus vive que ce temps mort ne fait qu'osciller.
local function retardActionneur(config, cleAxe)
  local reglageAxe = ((config.sorties or {}).axes or {})[cleAxe]
  if not reglageAxe or reglageAxe.mode ~= "boite_vitesses" then return 0 end
  local cycles = math.max(1, math.floor(reglageAxe.cyclesEntreRapports or 2))
    + math.max(1, math.floor(reglageAxe.cyclesImpulsion or 1))
  return cycles * ((config.gps or {}).intervalle or 0.4)
end

--- Gains deduits du gain vehicule K et de son inertie tau.
-- @param retard temps mort de l'actionneur, en secondes (0 pour du continu).
local function gainsDeduits(K, tau, retard)
  local amplitude = math.abs(K)
  if amplitude < 1e-6 then return nil end
  -- Le temps mort s'ajoute a l'inertie du point de vue de la boucle : c'est
  -- sur cette constante-la qu'il faut regler, pas sur la seule inertie.
  local tauEffectif = tau + (retard or 0)
  local kp = 2 / amplitude
  if retard and retard > 0 then
    -- Un actionneur a crans ne delivre pas une commande continue : il saute
    -- d'un palier a l'autre. On rend la boucle interne plus douce dans le
    -- meme rapport que le temps mort allonge la reponse.
    kp = kp * (tau / tauEffectif)
  end
  return {
    position  = 1 / (3 * tauEffectif),
    kp = kp,
    ki = kp / (3 * tauEffectif),
    kd = kp * tauEffectif / 6,
    tauEffectif = tauEffectif,
    retard = retard or 0,
  }
end

--------------------------------------------------------------------------------
-- DEROULEMENT
--------------------------------------------------------------------------------

--- @param ap      autopilote deja initialise (position acquise)
--- @param options { duree, rayonMax, afficher = fn(texte, couleur), config }
--- @return resultats (table par axe) ou nil, motif
function calibration.mesurer(ap, options)
  options = options or {}
  local reglages = {}
  for cle, valeur in pairs(DEFAUTS) do reglages[cle] = valeur end
  for cle, valeur in pairs(options.reglages or {}) do reglages[cle] = valeur end

  local journal = ap.journal
  local afficher = options.afficher or function() end
  local vol = ap.etat()
  if not vol.position then
    return nil, "position inconnue : l'autopilote doit avoir acquis le GPS"
  end
  local depart = { x = vol.position.x, y = vol.position.y, z = vol.position.z }
  local periode = ap.config.gps.intervalle

  journal.info(ETAPES.PREPARATION, string.format(
    "calibration depuis X=%.1f Y=%.1f Z=%.1f, %d essais de %ds",
    depart.x, depart.y, depart.z, #ESSAIS, reglages.duree))

  local resultats = {}
  local abandon = nil

  --- Interruption : une touche, une perte GPS, un ecart trop grand.
  local function verifierSecurite()
    local nom, touche = nil, nil
    -- os.pullEvent bloquerait : on regarde s'il y a une touche en attente.
    while true do
      local minuteur = os.startTimer(0)
      local evenement = { os.pullEvent() }
      if evenement[1] == "timer" and evenement[2] == minuteur then break end
      if evenement[1] == "key" or evenement[1] == "terminate" then
        nom, touche = evenement[1], evenement[2]
        os.cancelTimer(minuteur)
        break
      end
    end
    if nom then return "interruption au clavier" end

    local etatVol = ap.etat()
    if not etatVol.position then return "position GPS perdue" end
    local dx = etatVol.position.x - depart.x
    local dy = etatVol.position.y - depart.y
    local dz = etatVol.position.z - depart.z
    local ecart = math.sqrt(dx * dx + dy * dy + dz * dz)
    if ecart > reglages.rayonMax then
      return string.format("ecart de %.0f blocs du point de depart", ecart)
    end
    return nil
  end

  --- Pousse un axe et enregistre sa reponse.
  local function mener(essai)
    local reglageAxe = ((ap.config.sorties or {}).axes or {})[essai.cle]
    if essai.facultatif and (not reglageAxe or (reglageAxe.mode or "aucun") == "aucun") then
      afficher(essai.libelle .. " : axe non equipe, essai ignore")
      return nil
    end

    afficher("Essai " .. essai.libelle .. " : poussee a fond...")
    journal.info(ETAPES.MESURE, "essai " .. essai.cle .. " : commande maximale")

    local echantillons = {}
    ap.piloterManuellement(essai.commandes)
    local debut = os.clock()
    while os.clock() - debut < reglages.duree do
      ap.pas()
      local etatVol = ap.etat()
      local valeur = essai.lire(etatVol)
      if not nombreValide(valeur) and essai.repli then valeur = essai.repli(etatVol) end
      if nombreValide(valeur) then
        echantillons[#echantillons + 1] = { t = os.clock(), v = valeur }
      end
      local motif = verifierSecurite()
      if motif then
        ap.piloterManuellement({})
        ap.pas()
        return nil, motif
      end
      sleep(periode)
    end

    -- Retour au calme avant l'essai suivant : une vitesse residuelle
    -- fausserait la mesure du gain de l'axe suivant.
    ap.piloterManuellement({})
    afficher(essai.libelle .. " : retour au calme...")
    local finRepos = os.clock() + reglages.repos
    while os.clock() < finRepos do
      ap.pas()
      sleep(periode)
    end

    local K, tau, motif = analyser(echantillons, reglages.partRegime)
    if not K then
      afficher(essai.libelle .. " : " .. tostring(motif))
      journal.avert(ETAPES.ANALYSE, "essai " .. essai.cle .. " inexploitable : "
        .. tostring(motif))
      return nil
    end

    journal.info(ETAPES.ANALYSE, string.format(
      "axe %s : gain %.2f %s a pleine commande, inertie %.2fs (%d mesures)",
      essai.cle, K, essai.unite, tau, #echantillons))
    afficher(string.format("%s : %.2f %s, inertie %.2fs",
      essai.libelle, K, essai.unite, tau))

    return { K = K, tau = tau, mesures = #echantillons, essai = essai }
  end

  for _, essai in ipairs(ESSAIS) do
    local resultat, motif = mener(essai)
    if motif then
      abandon = motif
      break
    end
    if resultat then resultats[essai.cle] = resultat end
  end

  ap.piloterManuellement({})
  ap.pas()
  ap.reprendreAutomatique()

  if abandon then
    journal.avert(ETAPES.ABANDON, "calibration interrompue : " .. abandon)
    return nil, abandon
  end
  if not next(resultats) then
    return nil, "aucun axe n'a pu etre mesure"
  end
  return resultats
end

--------------------------------------------------------------------------------
-- TRADUCTION EN CONFIGURATION
--------------------------------------------------------------------------------

--- Traduit des mesures en vitesses et en gains, sans rien ecrire.
-- @return propositions { vitesses = {...}, gains = {...} }, lignes lisibles
function calibration.proposer(resultats, configActuelle, options)
  options = options or {}
  local marge = options.margeVitesse or DEFAUTS.margeVitesse
  local facteurs = options.facteursMaintien or DEFAUTS.facteursMaintien

  local propositions = { vitesses = {}, gains = {} }
  local lignes = {}

  for _, essai in ipairs(ESSAIS) do
    local resultat = resultats[essai.cle]
    if resultat then
      local amplitude = math.abs(resultat.K)
      local vitesse = amplitude * marge
      propositions.vitesses[essai.reglage] = vitesse

      local retard = retardActionneur(configActuelle or {}, essai.cle)
      local gains = gainsDeduits(resultat.K, resultat.tau, retard)
      if gains then
        if retard > 0 then
          lignes[#lignes + 1] = string.format(
            "%-12s axe A CRANS : %.1fs de temps mort ajoutes a l'inertie "
            .. "mesuree (%.2fs) avant le calcul des gains",
            essai.libelle, retard, resultat.tau)
        end
        propositions.gains[essai.axeGains] = {
          position  = { kp = gains.position },
          croisiere = { kp = gains.kp, ki = gains.ki, kd = gains.kd },
          maintien  = {
            kp = gains.kp * facteurs.kp,
            ki = gains.ki * facteurs.ki,
            kd = gains.kd * facteurs.kd,
          },
        }
        lignes[#lignes + 1] = string.format(
          "%-12s mesure %6.2f %-9s -> %s %.2f  kp %.3f ki %.4f kd %.4f",
          essai.libelle, resultat.K, essai.unite, essai.reglage, vitesse,
          gains.kp, gains.ki, gains.kd)
      end
    end
  end

  -- L'approche se deduit de la croisiere : un quart, jamais moins d'un bloc/s.
  if propositions.vitesses.croisiere then
    propositions.vitesses.approche = math.max(1.0, propositions.vitesses.croisiere * 0.25)
    lignes[#lignes + 1] = string.format(
      "%-12s deduite                     -> approche %.2f", "APPROCHE",
      propositions.vitesses.approche)
  end

  -- Un axe lateral non mesure vaut zero : mieux vaut le declarer absent que
  -- laisser le guidage compter sur une translation qui n'existe pas.
  if not propositions.vitesses.lateraleMax then
    propositions.vitesses.lateraleMax = 0
  end

  return propositions, lignes
end

--- Applique les propositions a une configuration vive (sans ecrire le fichier).
function calibration.appliquer(config, propositions)
  for cle, valeur in pairs(propositions.vitesses or {}) do
    config.vitesses[cle] = valeur
  end
  for axe, jeux in pairs(propositions.gains or {}) do
    if config.gains[axe] then
      for jeu, gains in pairs(jeux) do
        config.gains[axe][jeu] = config.gains[axe][jeu] or {}
        for nom, valeur in pairs(gains) do
          config.gains[axe][jeu][nom] = valeur
        end
      end
    end
  end
  return config
end

calibration.ESSAIS  = ESSAIS
calibration.DEFAUTS = DEFAUTS
calibration.interne = { analyser = analyser, gainsDeduits = gainsDeduits }

return calibration
