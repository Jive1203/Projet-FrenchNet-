--[[----------------------------------------------------------------------------
  CONFIGURATION DE LA MISE A JOUR - FRENCHNET
  A EDITER SUR CHAQUE POSTE. Ce fichier n'est JAMAIS ecrase par une mise a
  jour : il est marque 'siAbsent' dans le manifeste.

  AVERTISSEMENT QU'IL FAUT AVOIR LU
  La mise a jour automatique est un canal d'execution de code a distance vers
  cet ordinateur. Quiconque controle 'urlBase' - le depot, le compte GitHub,
  ou la resolution DNS du serveur - fait executer son code par ce poste. Il
  n'y a ni signature ni chiffrement : CC: Tweaked n'offre rien pour cela.

  Si ce poste commande des armes, le reglage prudent est :
      automatique = false
  Les mises a jour sont alors telechargees, verifiees et PREPAREES, mais
  installees seulement quand vous lancez 'update appliquer'.
--------------------------------------------------------------------------------]]

return {

  ------------------------------------------------------------------- IDENTITE --

  -- Quel poste est cet ordinateur. Doit exister dans manifeste.lua :
  --   command, radar, lanceur, balise, vaisseau, transpondeur
  poste = "command",

  ---------------------------------------------------------------------- SOURCE --

  --[==[
    Racine du depot, en HTTP brut.

    ATTENTION A LA BRANCHE : ce depot n'a PAS de branche 'main'. L'URL
    ci-dessous pointe la branche de developpement. Changez-la si vous
    fusionnez ailleurs, sinon les postes suivront une branche qui bouge sous
    leurs pieds.

    L'administrateur du serveur doit autoriser l'hote dans
    config/computercraft-server.toml :

        [http]
            enabled = true
            [[http.rules]]
                host = "raw.githubusercontent.com"
                action = "allow"

    Lancez 'diagnostic' section 5 pour savoir si HTTP est disponible ici.

    Ce commentaire est en crochets longs de niveau 2 : le double crochet
    fermant de la regle TOML ci-dessus fermerait un commentaire ordinaire en
    plein milieu du fichier.
  ]==]
  urlBase = "https://raw.githubusercontent.com/Jive1203/Projet-FrenchNet-/"
         .. "claude/frenchnet-command-defense-xm41dc",

  cheminManifeste = "manifeste.lua",

  --[[
    REPLI RESEAU, pour les serveurs ou HTTP est coupe.
    Un ordinateur qui, lui, a le droit HTTP fait tourner maj/serveur_maj.lua
    et distribue les fichiers par rednet. Mettre a false pour l'interdire.

    A savoir : ce repli fait confiance au premier poste qui repond. Sur un
    serveur ou n'importe qui peut poser un ordinateur, c'est une porte
    ouverte - laissez-le a false et mettez a jour a la main.
  ]]
  replliReseau = false,
  protocoleMaj = "frenchnet_maj",
  delaiReseau  = 5,

  --------------------------------------------------------------------- POLITIQUE --

  --[[
    automatique = true  : installe des qu'une version est disponible ET que le
                          poste n'est pas occupe.
    automatique = false : telecharge, verifie, prepare - et attend
                          'update appliquer'. Reglage prudent pour un poste
                          qui commande des armes.
  ]]
  automatique = true,

  -- Verification au demarrage, avant que le poste ne se lance. C'est le
  -- moment le plus sur qui existe : rien n'est engage, par construction.
  auDemarrage = true,

  -- Verification periodique pendant le service, en secondes. 0 = jamais.
  -- Une mise a jour trouvee ici est PREPAREE ; elle ne bascule que si le
  -- poste n'est pas occupe.
  intervalleVerification = 0,

  ------------------------------------------------------------------ OCCUPATION --

  --[[
    Verrou d'occupation. Le poste y ecrit « je conduis un engagement », et la
    mise a jour ne bascule pas tant qu'il est frais. Redemarrer un poste de
    defense au moment ou il conduit un tir est la seule facon de transformer
    une mise a jour en perte de materiel.

    La peremption n'est pas decorative : sans elle, un poste qui a plante
    laisserait un verrou eternel et bloquerait justement la mise a jour qui
    repare. Un poste muet n'est pas occupe, il est mort.
  ]]
  fichierOccupation    = "/.maj/occupation.dat",
  occupationPeremption = 30,

  ------------------------------------------------------------------ EMPLACEMENTS --

  dossierPrepare    = "/.maj/prepare",
  dossierSauvegarde = "/.maj/sauvegarde",
  fichierEtat       = "/.maj/etat.dat",
  fichierJournal    = "/.maj/maj.log",

  -- Redemarrage apres une installation reussie. Sans lui, le poste continue
  -- de faire tourner l'ANCIEN code deja charge en memoire : les fichiers sont
  -- neufs, le programme non, et on croit a tort avoir mis a jour.
  redemarrerApres = true,
  delaiRedemarrage = 5,
}
