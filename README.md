# PingBar

Petite app macOS de barre de menu qui affiche le ping actuel vers une cible.

Par defaut, la cible est `1.1.1.1`. Depuis le menu, vous pouvez changer la cible, configurer l'intervalle de ping, ou quitter l'app.

L'app garde un process `ping` continu au lieu de relancer `/sbin/ping` a chaque mesure, ce qui limite les creations de process et l'impact CPU.
Si `ping` rencontre une erreur fatale, PingBar le relance automatiquement avec un delai progressif pour eviter une boucle CPU.

## Developpement

```sh
swift test
swift run PingBar
```

`swift run PingBar` lance l'app sans packaging. Elle apparait dans la barre de menu et se ferme depuis le menu `Quitter`.

## Creer l'app macOS

```sh
make package
open PingBar.app
```

Le bundle `PingBar.app` est configure avec `LSUIElement`, donc il n'affiche pas d'icone dans le Dock.
