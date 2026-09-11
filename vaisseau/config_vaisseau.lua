--[[----------------------------------------------------------------------------
  CONFIGURATION DU SYSTEME EMBARQUE - DOOMSDAY SHIP
  --------------------------------------------------------------------------
  A EDITER A BORD.

  AVANT TOUT REGLAGE : lancez 'diagnostic' sur l'ordinateur du ballon. Il
  affiche les peripheriques reels, leurs methodes reelles, et les mesures que
  le systeme a su lier tout seul. Les noms de methode du catalogue par defaut
  sont des CANDIDATS plausibles, pas des certitudes : le diagnostic est ce qui
  les transforme en certitudes.

  Une mesure non liee s'affiche INDISPO sur les pages. C'est voulu : un chiffre
  invente sur une page de portance se paie plus cher qu'une case vide.
--------------------------------------------------------------------------------]]

return {

  ---------------------------------------------------------------- IDENTITE ----

  identifiant = "DOOMSDAY-01",
  designation = "Ballon lourd",

  -- Code transpondeur emis vers FrenchNet Command. SANS LUI, le poste au sol
  -- classe ce ballon INCONNU - avec les consequences prevues par la doctrine
  -- de zone. Doit correspondre a codeAllie ou codeGeneral du poste.
  codeTranspondeur = "FN-ALLIE-0000",

  ------------------------------------------------------------- AFFICHAGE -----

  --[[
    LAYOUT DES ECRANS.
    Cle = nom du peripherique moniteur ("monitor_0", "left"...) ou "terminal".
    Les positions sont des FRACTIONS de la surface, de 0 a 1, jamais des
    caracteres : un 3x3 et un 2x2 n'ont pas la meme taille, et une disposition
    figee en caracteres serait fausse sur l'un des deux.

      x, y : coin superieur gauche      l, h : largeur et hauteur
      { page = "propulsion", x = 0, y = 0, l = 0.5, h = 1 }  -> moitie gauche

    Une surface sans consigne affiche 'pageParDefaut' en plein ecran.

    Pages disponibles : propulsion, portance, navigation, sa, ew, armement,
    liaison, alertes. Les pages 'ew' et 'armement' sont completes a l'affichage
    et INERTES a la commande tant que l'ADS et le Fire Control Embarque sont
    absents du depot - elles l'annoncent en clair.
  ]]
  layout = {
    pageParDefaut = "propulsion",

    terminal = {
      fenetres = {
        { page = "sa", x = 0, y = 0, l = 1, h = 1 },
      },
    },

    -- Exemple pour un moniteur 3x3 : propulsion et portance cote a cote,
    -- navigation en dessous. A adapter au nom reel rendu par 'diagnostic'.
    ["monitor_0"] = {
      echelle = nil,          -- nil = plus grande echelle encore lisible
      largeurMini = 50, hauteurMini = 20,
      fenetres = {
        { page = "propulsion", x = 0,   y = 0,    l = 0.5, h = 0.55 },
        { page = "portance",   x = 0.5, y = 0,    l = 0.5, h = 0.55 },
        { page = "sa",         x = 0,   y = 0.55, l = 1,   h = 0.45 },
      },
    },
  },

  -- Taille minimale d'une fenetre, en caracteres. En dessous, la fenetre est
  -- refusee et journalisee : mieux vaut une page absente qu'une page illisible
  -- sur laquelle on croit pouvoir compter.
  largeurMiniFenetre = 26,
  hauteurMiniFenetre = 8,

  ------------------------------------------------------- LIAISON MATERIELLE --

  --[[
    FORCAGE DES MESURES, a remplir avec la sortie de 'diagnostic'.

      mesures = {
        ["propulsion.stress"] = { peripherique = "back", methode = "getStress",
                                  facteur = 1, decalage = 0 },
        ["portance.gaz"]      = false,   -- absente sur ce ballon, ne pas alerter
      }

    Une entree a 'false' declare la mesure volontairement absente : le systeme
    cesse de la signaler comme anomalie. Utile sur un ballon qui n'a pas de
    ballast, par exemple.
  ]]
  mesures = {},

  ------------------------------------------------------------- INTEGRATIONS --

  -- Chemins des modules exterieurs. AUCUN n'est present dans le depot au
  -- moment ou ceci est ecrit (voir docs/api_notes.md) : les pages afficheront
  -- leur absence au lieu de simuler.
  chemins = {
    autopilote  = "/vaisseau/autopilote.lua",
    fireControl = "/vaisseau/fire_control.lua",
    ads         = "/vaisseau/ads.lua",
  },

  ------------------------------------------------------------------ SEUILS ---

  --[[
    Seuils d'alarme, par mesure. Chaque niveau est facultatif.
    Pour les mesures a 'sens inverse' - pression, gaz, energie, variometre -
    la gravite augmente quand la valeur BAISSE : les seuils sont donc
    decroissants, et un variometre s'exprime en negatif.
  ]]
  seuils = {
    ["propulsion.charge"]     = { attention = 70, alarme = 85, critique = 95 },
    ["energie.pourcentage"]   = { attention = 40, alarme = 20, critique = 10 },
    ["portance.pression"]     = { attention = 70, alarme = 50, critique = 30 },
    ["portance.gaz"]          = { attention = 60, alarme = 40, critique = 20 },
    ["vol.vitesseVerticale"]  = { attention = -3, alarme = -6, critique = -10 },
  },

  -- Marge de retour avant qu'une alarme soit levee, dans l'unite de la mesure.
  -- Sans elle, une valeur qui oscille autour du seuil ferait clignoter l'ecran
  -- sans repit, exactement quand l'equipage a besoin de le lire.
  hysteresis = 5,

  -- Seuils propres a la page propulsion (affichage seulement).
  seuilsPages = {
    propulsion = { chargeAttention = 70, chargeAlarme = 85, chargeCritique = 95 },
    portance   = { pressionAttention = 70, pressionAlarme = 50, pressionCritique = 30,
                   varioAttention = -3, varioAlarme = -6, varioCritique = -10 },
  },

  ------------------------------------------------- CARBURANT NUCLEAIRE -------

  --[[
    ECHEANCE TENUE PAR LE SYSTEME, PAS MESUREE.
    Aucune API connue n'expose la duree restante d'un coeur nucleaire. Le
    compte a rebours part donc de la duree declaree ici et de la date du
    dernier renouvellement, que l'equipage valide d'un clic sur la page
    propulsion. La page l'annonce comme « declare » : un equipage qui croit
    lire un capteur alors qu'il lit un minuteur ne verifiera jamais le reacteur.
  ]]
  carburantNucleaire = {
    dureeSecondes = 6 * 3600,
    attention     = 2 * 3600,
    alarme        = 3600,
    critique      = 600,
  },

  -- Biofuel : mesure du HAL a utiliser, si le ballon en porte.
  biofuel = nil,   -- exemple : { mesure = "energie.stock", unite = "mB", alarme = 2000 }

  --------------------------------------------------- SITUATION TACTIQUE ------

  --[[
    CODES D'IDENTIFICATION, IDENTIQUES A CEUX DU POSTE AU SOL.
    L'IFF du bord est celui de FrenchNet Command, appele en bibliotheque
    (noyau.lua). Des codes differents a bord et au sol feraient voir rouge a
    l'equipage ce que le controleur voit vert - et le premier tir fratricide
    viendrait de la. Recopiez-les depuis config_command.lua.
  ]]
  codes = {
    codeAllie            = "FN-ALLIE-0000",
    codeGeneral          = "FN-GEN-0000",
    codeAlliePrecedent   = nil,
    codeGeneralPrecedent = nil,
    rotationAllieA       = nil,
    rotationGeneraleA    = nil,
  },

  -- Un transpondeur entendu il y a plus de 'validiteTranspondeur' secondes ne
  -- vaut plus laissez-passer, et la grace couvre une rotation de code en cours.
  validiteTranspondeur = 15,
  graceRotation        = 300,

  --[[
    ZONES DU THEATRE.
    Le poste au sol NE LES DIFFUSE PAS : aucun protocole ne s'en charge
    (verifie dans command/command.lua). Sans elles, la carte du bord n'a pas de
    fond et la doctrine de zone n'est pas appliquee a bord. Recopiez-les depuis
    l'etat du poste, au meme format :
      { nom = "ALPHA-1", classe = "ALPHA", forme = "rectangle",
        points = { {x=,z=}, {x=,z=}, {x=,z=}, {x=,z=} } }
      { nom = "ROMEO-1", classe = "ROMEO", forme = "cercle",
        centre = { x =, z = }, rayon = 200, yMin =, yMax = }
  ]]
  zones = {},

  -- Listes d'identification par la voie radar, deuxieme canal de l'IFF.
  nomsAllies   = {},
  nomsHostiles = {},

  --[[
    SEUILS DE MENACE. Le critere principal est le TEMPS AVANT CONTACT, pas la
    distance : un engin a 400 blocs qui fonce a 50 b/s est a huit secondes,
    un engin a 250 blocs qui s'eloigne n'est a rien du tout.
  ]]
  preavisSecondes      = 20,    -- en dessous : ATTENTION (ou IMMINENTE si missile)
  missileImminent      = 200,   -- un missile plus pres que cela est imminent
  menaceProche         = 300,   -- inconnu plus pres que cela : ATTENTION
  menaceVeille         = 800,   -- au dela : plus suivi
  perimeSecondes       = 12,    -- piste non revue depuis : oubliee (jamais « detruite »)
  intervalleSA         = 1,

  ------------------------------------------------------------ RADAR DU BORD --

  -- Nom du peripherique radar, si la detection automatique se trompe.
  peripheriqueRadar = nil,
  porteeRadar       = 512,
  intervalleRadar   = 2,

  -- Le ballon emet ses contacts au sol au format FRENCHNET_RADAR : il devient
  -- une station mobile. Mettre a false pour le rendre silencieux.
  emettreRadar = true,

  --[[
    REFERENTIEL DES ECHOS. Certains radars rendent des coordonnees relatives a
    leur propre bloc, d'autres des coordonnees absolues du monde. La deduction
    automatique suppose un radar LOIN de l'origine du monde, ce qu'un ballon en
    mouvement ne garantit pas. FIGEZ LA VALEUR ICI apres un 'diagnostic' :
    se tromper decale toutes les pistes de plusieurs milliers de blocs.
      true  = les echos sont relatifs au bloc radar
      false = les echos sont deja absolus
      nil   = deduction automatique (a eviter a bord)
  ]]
  radarPositionsRelatives = nil,

  --------------------------------------------------------------- SOUTES ------

  -- Recensement lent par choix : chaque lecture de coffre est un appel sur le
  -- thread principal du serveur, et un coffre ne se vide pas en une seconde.
  intervalleInventaire = 15,

  -- Peripheriques a ne jamais compter comme soute (un coffre de decor, par ex.).
  souteExclue = {},

  -- Familles d'objets reconnues. Les motifs sont cherches en sous-chaine dans
  -- l'identifiant Minecraft, insensible a la casse. Laisser a nil garde les
  -- familles par defaut de inventaire.lua (obus, poudre, leurres, missiles,
  -- carburant, reparation) ; les redefinir ici les remplace entierement.
  famillesInventaire = nil,

  ---------------------------------------------------------------- AUDIO ------

  --[[
    Le son est la seule alarme qui atteigne un equipage qui ne regarde pas
    l'ecran. C'est aussi la seule qu'il peut couper - d'ou un silence qui
    EXPIRE tout seul : un ballon muet pour le reste de la partie n'entendrait
    pas la prochaine alarme.
  ]]
  audioActif       = true,
  volume           = 1,       -- multiplicateur, plafonne a 3 par CC
  silenceSecondes  = 120,     -- duree d'un silence demande par clic
  intervallePas    = 0.25,    -- pas du motif sonore

  --------------------------------------------------------------- MUSIQUE -----

  --[[
    CE MODULE PEUT ETRE BLOQUE PAR LE SERVEUR, ET C'EST NORMAL.
    'http' est nil quand l'administrateur ne l'a pas autorise dans
    computercraft-server.toml. Aucun code ne contourne cela. Deux modes :
      HTTP   - urlRelais renseigne ET http disponible ;
      RESEAU - un ordinateur exterieur interroge le relais et pousse une trame
               { protocole = "FRENCHNET_MUSIQUE", titre =, artiste =, ... } ;
      AUCUN  - la page affiche l'absence, jamais un titre vide.
    Lancez 'diagnostic' section 5 pour savoir dans quel cas vous etes.
  ]]
  musiqueActive     = true,
  urlRelais         = nil,     -- exemple : "http://192.168.1.10:8080/nowplaying"
  entetesRelais     = nil,
  musiqueParReseau  = true,
  musiquePeremption = 60,      -- au dela, le titre est oublie : un titre fige
                               -- se lirait comme un relais qui marche
  intervalleMusique = 20,

  ------------------------------------------------------------------ RESEAU ---

  protocoleTranspondeur = "frenchnet_transpondeur",
  protocoleAnnonce      = "frenchnet_annonce",
  protocoleRadar        = "frenchnet_radar",
  intervalleTranspondeur = 4,

  ----------------------------------------------------------------- BOUCLE ----

  -- Periode de lecture des capteurs et d'evaluation des alarmes.
  intervalleMesures = 1,

  ---------------------------------------------------------------- JOURNAL ----

  journalFichier       = true,
  journalNiveauEcran   = "INFO",
  journalNiveauFichier = "INFO",
  journalTailleMax     = 65536,
  journalLot           = 24,
  journalAgeMax        = 5,
  battementSecondes    = 60,

  --------------------------------------------------------------- ROBUSTESSE --

  arretParTerminate   = true,
  redemarrageDelaiMax = 60,
}
