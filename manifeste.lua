--[[--------------------------------------------------------------------------
  MANIFESTE FRENCHNET - GENERE, NE PAS EDITER A LA MAIN
    lua5.4 outils/generer_manifeste.lua [version]

  Liste, pour chaque poste, les fichiers a installer et leur somme de
  controle. Les postes le telechargent pour savoir ce qui a change.

  'siAbsent' marque un fichier installe UNE SEULE FOIS, jamais ecrase :
  ce sont les configurations, qui contiennent les zones du theatre, les
  codes transpondeur et le mot de passe de la console.
----------------------------------------------------------------------------]]

return {
  version = "1.0.0",
  genere  = "2026-09-11",
  postes = {
    balise = { fichiers = {
      { chemin = "balise/balise.lua", somme = 1465246662, taille = 34219 },
      { chemin = "balise/recepteur.lua", somme = 3689209363, taille = 4118 },
      { chemin = "balise/config_balise.lua", somme = 3541597924, taille = 4581, siAbsent = true },
      { chemin = "balise/startup.lua", cible = "/startup.lua", somme = 130510849, taille = 2913 },
      { chemin = "maj/maj.lua", somme = 3426157212, taille = 23898 },
      { chemin = "maj/update.lua", somme = 632284915, taille = 12184 },
      { chemin = "maj/config_maj.lua", somme = 3084821908, taille = 4705, siAbsent = true },
    } },
    command = { fichiers = {
      { chemin = "command/command.lua", somme = 3247216360, taille = 100537 },
      { chemin = "command/noyau.lua", somme = 3271321214, taille = 47966 },
      { chemin = "command/carte.lua", somme = 1145651875, taille = 16585 },
      { chemin = "command/terrain.lua", somme = 3166628545, taille = 16767 },
      { chemin = "command/scanner.lua", somme = 4183380518, taille = 18078 },
      { chemin = "command/interface.lua", somme = 4182433038, taille = 65801 },
      { chemin = "command/diagnostic.lua", somme = 3093686111, taille = 8470 },
      { chemin = "command/config_command.lua", somme = 1967452007, taille = 24036, siAbsent = true },
      { chemin = "command/startup.lua", cible = "/startup.lua", somme = 546746581, taille = 3092 },
      { chemin = "maj/serveur_maj.lua", somme = 2991137445, taille = 7348 },
      { chemin = "maj/maj.lua", somme = 3426157212, taille = 23898 },
      { chemin = "maj/update.lua", somme = 632284915, taille = 12184 },
      { chemin = "maj/config_maj.lua", somme = 3084821908, taille = 4705, siAbsent = true },
    } },
    lanceur = { fichiers = {
      { chemin = "lanceur/lanceur.lua", somme = 1944618018, taille = 16091 },
      { chemin = "lanceur/config_lanceur.lua", somme = 2984435198, taille = 3239, siAbsent = true },
      { chemin = "lanceur/startup.lua", cible = "/startup.lua", somme = 1428075199, taille = 3105 },
      { chemin = "maj/maj.lua", somme = 3426157212, taille = 23898 },
      { chemin = "maj/update.lua", somme = 632284915, taille = 12184 },
      { chemin = "maj/config_maj.lua", somme = 3084821908, taille = 4705, siAbsent = true },
    } },
    radar = { fichiers = {
      { chemin = "radar/radar.lua", somme = 2902512894, taille = 18971 },
      { chemin = "radar/diagnostic.lua", somme = 3093686111, taille = 8470 },
      { chemin = "command/scanner.lua", cible = "/radar/scanner.lua", somme = 4183380518, taille = 18078 },
      { chemin = "radar/config_radar.lua", somme = 841151182, taille = 4032, siAbsent = true },
      { chemin = "radar/startup.lua", cible = "/startup.lua", somme = 2241701525, taille = 3069 },
      { chemin = "maj/maj.lua", somme = 3426157212, taille = 23898 },
      { chemin = "maj/update.lua", somme = 632284915, taille = 12184 },
      { chemin = "maj/config_maj.lua", somme = 3084821908, taille = 4705, siAbsent = true },
    } },
    transpondeur = { fichiers = {
      { chemin = "command/transpondeur.lua", cible = "/transpondeur.lua", somme = 3242212572, taille = 3611 },
      { chemin = "maj/maj.lua", somme = 3426157212, taille = 23898 },
      { chemin = "maj/update.lua", somme = 632284915, taille = 12184 },
      { chemin = "maj/config_maj.lua", somme = 3084821908, taille = 4705, siAbsent = true },
    } },
    vaisseau = { fichiers = {
      { chemin = "vaisseau/vaisseau.lua", somme = 3557197294, taille = 34224 },
      { chemin = "vaisseau/mfd.lua", somme = 3517456106, taille = 11723 },
      { chemin = "vaisseau/hal.lua", somme = 3904346860, taille = 8481 },
      { chemin = "vaisseau/liaisons.lua", somme = 2746599202, taille = 6269 },
      { chemin = "vaisseau/surveillance.lua", somme = 215051101, taille = 6115 },
      { chemin = "vaisseau/widgets.lua", somme = 4086572184, taille = 4172 },
      { chemin = "vaisseau/sa.lua", somme = 161377817, taille = 12409 },
      { chemin = "vaisseau/inventaire.lua", somme = 979269319, taille = 6711 },
      { chemin = "vaisseau/audio.lua", somme = 3640430097, taille = 5979 },
      { chemin = "vaisseau/musique.lua", somme = 4013060395, taille = 5825 },
      { chemin = "vaisseau/diagnostic.lua", somme = 117510369, taille = 6678 },
      { chemin = "vaisseau/pages/propulsion.lua", somme = 2258794785, taille = 4331 },
      { chemin = "vaisseau/pages/portance.lua", somme = 436957862, taille = 3533 },
      { chemin = "vaisseau/pages/navigation.lua", somme = 3893036963, taille = 6385 },
      { chemin = "vaisseau/pages/sa.lua", somme = 760538395, taille = 7957 },
      { chemin = "vaisseau/pages/ew.lua", somme = 3343511693, taille = 4945 },
      { chemin = "vaisseau/pages/armement.lua", somme = 2213857460, taille = 5669 },
      { chemin = "vaisseau/pages/liaison.lua", somme = 1567534081, taille = 4030 },
      { chemin = "vaisseau/pages/alertes.lua", somme = 529438134, taille = 4722 },
      { chemin = "command/noyau.lua", cible = "/vaisseau/noyau.lua", somme = 3271321214, taille = 47966 },
      { chemin = "command/carte.lua", cible = "/vaisseau/carte.lua", somme = 1145651875, taille = 16585 },
      { chemin = "command/scanner.lua", cible = "/vaisseau/scanner.lua", somme = 4183380518, taille = 18078 },
      { chemin = "vaisseau/config_vaisseau.lua", somme = 2508566430, taille = 12626, siAbsent = true },
      { chemin = "vaisseau/startup.lua", cible = "/startup.lua", somme = 3855266758, taille = 3097 },
      { chemin = "maj/maj.lua", somme = 3426157212, taille = 23898 },
      { chemin = "maj/update.lua", somme = 632284915, taille = 12184 },
      { chemin = "maj/config_maj.lua", somme = 3084821908, taille = 4705, siAbsent = true },
    } },
  },
}
