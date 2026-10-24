# fivem-emulator

Un émulateur FiveM hors jeu, en Lua 5.4, pour **tester des ressources FiveM (ESX, ox) sans lancer GTA et sans joueur connecté**.

Il charge le vrai code de votre ressource (`fxmanifest.lua`, scripts serveur, partagés et client) et le fait tourner :

- un côté **serveur**, et un côté **client par joueur émulé**, chacun avec ses propres environnements par ressource ;
- une **horloge virtuelle** : `Wait`, `CreateThread`, `SetTimeout` suivent les ticks du serveur (10 ms) et les images du client (60 i/s par défaut) ; une minute de jeu se teste en une fraction de seconde ;
- un **réseau par joueur** : latence (RTT), gigue, perte de paquets (retransmission), gel, et un mode chaos ; les événements restent fiables et ordonnés comme dans FiveM ; la taille des messages est estimée (msgpack) ;
- des **mocks fidèles** d'ESX 1.12.4, oxmysql 2.12.0, ox_inventory 2.45.0 et ox_target 1.18.0, écrits à partir des sources de ces versions ;
- les **state bags** (`GlobalState`, `Player(id).state`, `Entity(ent).state`, `LocalPlayer.state`) répliqués sur le réseau émulé, et une bonne partie d'**ox_lib** (zones, points, `addCommand`, barres de progression, menus, dialogues) ;
- un **audit anti-triche** (`emu:fuzz`) qui rejoue vos événements réseau comme un tricheur et signale ce qui rapporte de l'argent ou des objets.

Vous écrivez un script de test qui ajoute des joueurs, tape des commandes, vise des zones ox_target, avance l'horloge, puis vérifie ce qui s'est passé (argent, inventaire, notifications, requêtes SQL, images dessinées, trafic réseau…).

## Limites (à lire avant de s'y fier)

- **Pas de rendu GTA ni de physique GTA.** Les natives de dessin (`DrawMarker`, `DrawText`…) sont seulement enregistrées. Pas de collisions, pas de véhicules qui roulent, pas de raycast réel.
- **Pas de OneSync réel.** Pas d'entités réseau partagées ni de « scope » : tout ce qui est répliqué (state bags compris) arrive à tous les joueurs. `Entity(ent).state` utilise le numéro d'entité tel quel (pas de netId). Pas de routage par bucket au-delà d'un simple champ.
- **Natives : seules les plus courantes sont simulées.** Une native absente provoque l'erreur Lua habituelle (`attempt to call a nil value (global 'X')`) et apparaît dans `emu:report()`. Ajoutez-la avec `emu:native(nom, fonction, côté)`.
- **Syntaxe CfxLua : seulement les backticks** (`` `adder` `` → hash) **et les affectations composées** (`+=`, `-=`, `*=`, `/=`, `<<=`, `>>=`, `&=`, `|=`, `^=`), sur une seule ligne. **Pas de `?.`** (navigation sûre), pas de `in` pour déstructurer, pas de `defer`. Un fichier qui les utilise donne une erreur de syntaxe.
- `exports` et `TriggerEvent` passent les tables par référence dans l'émulateur (FiveM les copie). Les données envoyées **sur le réseau** sont bien copiées, et les fonctions y sont refusées.
- Les mocks ne couvrent que ce qui est décrit plus bas. Exemples de choses non simulées : base de données réelle, paie ESX, menus `ESX.UI`, `ESX.Game`, armes ESX d'origine, boutiques/fouilles/dépôts au sol d'ox_inventory, raycast et os (bones) d'ox_target.
- Les messages d'erreur imités d'ESX et d'oxmysql restent en anglais, comme dans la console FiveM.

Ce n'est pas un remplaçant d'un essai en jeu : c'est un filet de sécurité rapide pour la logique serveur/client, le réseau et les cas limites.

## Installation

Il suffit de Lua 5.4 (aucune dépendance) :

```sh
sudo apt install lua5.4          # Debian / Ubuntu
git clone https://github.com/money1619/fivem-emulator.git
cd fivem-emulator
lua5.4 tests/run.lua             # vérifie que tout marche
```

Sous Windows, prenez un binaire Lua 5.4 et lancez `lua tests/run.lua` ; la liste des fichiers d'une ressource utilise `dir`, le reste est du Lua pur.

## Démarrage rapide

```lua
-- mon_test.lua, lancé depuis la racine du dépôt : lua5.4 mon_test.lua
package.path = './?.lua;' .. package.path
local Emu = require('fivem_emu')

local emu = Emu.new()
emu:loadResource('chemin/vers/ma_ressource')   -- lit fxmanifest.lua
emu:start('ma_ressource')

local alice = emu:addPlayer({ name = 'Alice', rtt = 40, aces = { 'command.annonce' } })
local bob = emu:addPlayer({ name = 'Bob', rtt = 200, jitter = 50, loss = 0.1 })
emu:run(500)                                   -- 500 ms virtuelles

local T = Emu.tester('ma_ressource')
T:check(alice:command('ping'), '/ping accepté')
emu:run(2000)
T:eq(#alice:frames(), 60, 'le marqueur est dessiné pendant 60 images')
T:same({ bob:command('annonce x') }, { false, 'access_denied' }, 'Bob n\'a pas le droit')
T:eq(#emu.errors, 0, 'aucune erreur Lua')

print(emu:report())
os.exit(T:summary() and 0 or 1)
```

Les dossiers `examples/` et `tests/` contiennent des scripts complets.

## Référence de l'API

### Émulateur

| Appel | Rôle |
|---|---|
| `Emu.new(opts)` | Crée un émulateur. `opts` : `serverTickMs` (10), `seed` (hasard reproductible), `convars = { nom = valeur }`, `echo = true` (affiche les `print` des scripts), `maxInstructions` (coupe une boucle sans `Wait`, 200 millions par défaut). |
| `emu:loadResource(dossier, nom?)` | Lit `fxmanifest.lua` (ou `__resource.lua`). Motifs pris en charge : `*`, `?` et `**` (zéro ou plusieurs dossiers). |
| `emu:start(nom)` / `emu:stop(nom)` | Démarre (dépendances d'abord) ou arrête une ressource. L'arrêt envoie `onResourceStop`, puis coupe fils, gestionnaires, exports et commandes. |
| `emu:defineResource(nom, { server = fn(env, emu), client = fn(env, emu, joueur) })` | Fausse ressource écrite en Lua (c'est ainsi que sont faits les mocks). |
| `emu:provide('@ressource/fichier.lua', fn(env, côté, emu))` | Fournit une inclusion `@…` du manifeste. `@ox_lib/init.lua` est fourni d'office (voir plus bas). |
| `emu:run(ms)` | Avance l'horloge de `ms` millisecondes en exécutant tout ce qui est prévu. |
| `emu:runUntil(condition, délaiMax, pas)` | Avance jusqu'à ce que `condition()` soit vraie ; renvoie `true` ou `false`. |
| `emu:native(nom, fn, 'server' \| 'client' \| 'shared')` | Ajoute ou remplace une native (avant `start`). |
| `emu:setConvar(nom, valeur)` | Valeur lue par `GetConvar` / `GetConvarInt`. |
| `emu:addAce(principal, objet, autoriser)`, `emu:addPrincipal(enfant, parent)` | ACL comme `add_ace` / `add_principal` (aussi utilisables avec `emu:command(nil, 'add_ace …')`). Le joueur est `player.<id>` et hérite de `identifier.<id>` pour chaque identifiant. Un refus l'emporte. |
| `emu:command(nil, ligne)` | Commande tapée dans la console serveur (toujours autorisée). |
| `emu:env(joueur \| nil, ressource)` | Environnement d'une ressource (serveur si `nil`) : pratique pour agir « depuis » une ressource, par exemple `emu:env(bob, 'shop').TriggerServerEvent('shop:buy', 'water')` pour simuler un tricheur. |
| `emu:stateBag(nom, joueur?)` | Copie des valeurs d'un state bag vues par le serveur (ou par un joueur) : `emu:stateBag('global')`, `emu:stateBag('player:1', bob)`. |
| `emu:fuzz(opts)` | Audit anti-triche des événements réseau serveur (voir plus bas). |
| `emu:addProbe(nom, fn(joueur))` | Sonde de l'audit : renvoie `{ clé = nombre }` (argent, objets, points…). ESX et ox_inventory ont déjà la leur. |
| `emu:report()` | Rapport texte : erreurs, avertissements, globales lues mais jamais définies (natives manquantes), trafic par joueur, lignes ajoutées par les mocks. |
| `emu.errors`, `emu.warnings` | Erreurs Lua des fils (avec la pile d'appels) et avertissements (événement réseau non déclaré, commande inconnue…). |
| `emu.server.log`, `joueur.side.log` | Lignes écrites par `print` côté serveur / client. |

### Joueurs

`emu:addPlayer(opts)` crée un joueur et démarre chez lui le côté client des ressources déjà lancées. Options :
`name`, `fps` (60), `rtt` (40 ms), `jitter` (ms), `loss` (0 à 1 : un paquet perdu arrive un RTT plus tard), `freeze = { début, fin }` (rien n'arrive pendant ce temps), `chaos = true` (ordre non garanti, hors comportement FiveM), `duplicate` (0 à 1, avec chaos), `dropEvents = { nom = true }` (avec chaos), `pos = { x, y, z }`, `heading`, `health`, `identifiers`, `aces = { 'command.x' }`, `bucket`, `clockOffset`. Les mocks lisent aussi `esx = {…}` et `inventory = {…}`.

| Méthode | Rôle |
|---|---|
| `p:command('ping a b')` | Commande tapée par le joueur. Une commande client passe en premier ; sinon la ligne voyage jusqu'au serveur (RTT/2) et s'y exécute. Renvoie tout de suite `true`, ou `false, 'unknown'` / `false, 'access_denied'`. |
| `p:clientCommand(ligne)` | Commande client seulement. |
| `p:nuiCallback(nom, données, cb)` | Simule un `fetch` de la page NUI. |
| `p:frames(de, à)` | Images dessinées (regroupées par instant) avec leurs `DrawMarker`, `DrawLine`, `DrawRect`. |
| `p:lastNotification(texte?)` | Dernière notification reçue (`lib.notify`, `ESX.ShowNotification`…), éventuellement contenant `texte`. |
| `p:setPosition(x, y, z, cap)`, `p:kill()`, `p:enterVehicle()`, `p:drop(raison)` | État du joueur, déconnexion (`playerDropped` est déclenché pendant que `GetPlayerName` marche encore). |
| `p:menu()`, `p:selectMenu(index ou titre)`, `p:closeMenu()` | Menu contextuel ox_lib ouvert, choix d'une option (`onSelect(args)`, `event`, `serverEvent`, sous-menu `menu`), Échap (`onExit`). Renvoie `true` ou `false, raison` (`no_menu`, `no_option`, `disabled`, `no_action`). |
| `p:answerInput(valeurs \| nil)`, `p:answerAlert('confirm' \| 'cancel')` | Répond à `lib.inputDialog` (valeurs par rang ou par libellé ; `required`, `min`, `max` contrôlés ; `nil` = annuler) ou à `lib.alertDialog`. |
| `p:progress()`, `p:cancelProgress()`, `p:textUI()` | Barre de progression en cours, annulation par le joueur (seulement si `canCancel`), TextUI affiché. |
| `p.notifications`, `p.nui`, `p.nuiFocus`, `p.entities`, `p.draws`, `p.texts`, `p.received`, `p.net` | Ce que le client a reçu, affiché ou créé. |

### Ce que voient les scripts

- `source` vaut l'id du joueur (nombre) dans un événement réseau reçu par le serveur, `65535` dans un événement reçu du serveur par un client, `''` dans un événement local. Comme dans FiveM, `source` est remis à sa valeur précédente dès que le gestionnaire appelle `Wait` : lisez-le au début (`local src = source`).
- `RegisterNetEvent` vaut **par ressource** : un `AddEventHandler` seul ne reçoit pas les événements réseau. Un événement réseau non déclaré est ignoré et signalé dans `emu.warnings`.
- `exports.res:fn(...)` et `exports['res']['fn'](self, ...)` : comme FiveM, le premier argument (`self`) est ignoré. `GetInvokingResource()` donne la ressource appelante.
- Natives présentes (principales) : fils (`Wait`, `CreateThread`, `SetTimeout`, `ClearTimeout`, `Citizen.*`, `promise`, `Citizen.Await`), événements, exports, commandes (`RegisterCommand`, `ExecuteCommand`), joueurs côté serveur (`GetPlayers`, `GetPlayerName`, identifiants, `IsPlayerAceAllowed`, `DropPlayer`, bucket, coordonnées et cap du ped), côté client (`PlayerPedId`, coordonnées, santé, véhicule, contrôles, dessin, texte, NUI, entités locales avec `CreateObject` / `CreatePed` / `CreateVehicle`), `GetHashKey` / `joaat`, `json`, vecteurs (`vector2/3/4`, `vec`, `#v`, `.xy`, `type(v) == 'vector3'`), `GetConvar`, `LoadResourceFile`.

### State bags

Comme dans FiveM :

- `GlobalState.x = v` et `Player(src).state.x = v` côté serveur répliquent vers tous les joueurs (`state:set(clé, valeur, false)` pour garder une valeur côté serveur) ; la valeur arrive chez chaque joueur avec sa latence ;
- côté client, `state.x = v` reste **local** ; `LocalPlayer.state:set(clé, valeur, true)` envoie la valeur au serveur, puis aux autres joueurs. Un client ne peut répliquer que **son propre** sac : une écriture répliquée dans `GlobalState` ou le sac d'un autre est refusée et signalée dans `emu.warnings` ;
- la valeur est **copiée** à l'écriture et à chaque lecture (`state.config.prix = 1` ne change rien) ;
- `AddStateBagChangeHandler(clé, sac, fn(nomDuSac, clé, valeur, _, répliqué))` est appelé **avant** le changement : lire `state.x` dans le gestionnaire donne encore l'ancienne valeur. Aussi : `RemoveStateBagChangeHandler(cookie)`, `GetPlayerFromStateBagName` (id serveur côté serveur, index de joueur côté client), `GetEntityFromStateBagName`, `GetStateBagValue`, `GetStateBagKeys`, `StateBagHasKey` ;
- un joueur qui arrive reçoit l'état déjà répliqué (sans déclencher les gestionnaires) ; le sac d'un joueur disparaît à sa déconnexion.

Attention à ce qu'un client peut écrire dans son propre sac : le serveur ne doit jamais faire confiance à `Player(src).state` pour de l'argent ou des droits.

### ox_lib (fourni d'office)

`@ox_lib/init.lua` donne :

- `lib.callback` / `lib.callback.await` / `lib.callback.register` (aller-retour sur le réseau émulé, dans les deux sens), `lib.notify` (client : enregistré ; serveur : `lib.notify(joueur, données)` envoie au client), `lib.print`, `locale`, et `cache` (`ped`, `playerId`, `serverId`, `resource`) ;
- **zones** (client) : `lib.zones.sphere` (rayon 2 par défaut), `lib.zones.box` (taille, rotation en degrés), `lib.zones.poly` (points, épaisseur 4), avec `onEnter`, `onExit` et `inside`, `zone:remove()`, `zone:contains(coords)`, et vos propres champs dans `self`. Entrées et sorties vérifiées toutes les 300 ms, `inside` à chaque image, comme ox_lib ; déplacez le joueur avec `p:setPosition` ;
- **points** (client) : `lib.points.new({ coords, distance, onEnter, onExit, nearby })`, `currentDistance`, `isClosest`, `point:remove()` ;
- **`lib.addCommand`** (serveur) : paramètres typés (`number`, `string`, `playerId` avec `me`, `longString`, `optional`), `restricted = 'group.admin'` (ajoute l'ACE comme ox_lib). Un argument invalide écrit le message d'ox_lib dans la console et la commande ne s'exécute pas ;
- **interface** (client) : `lib.progressBar` / `lib.progressCircle` (bloquent le fil, renvoient `true` à la fin ou `false` si annulées : `p:cancelProgress()`, `lib.cancelProgress()`, ou mort sans `useWhileDead`), `lib.registerContext` / `showContext` / `hideContext`, `lib.inputDialog`, `lib.alertDialog`, `lib.showTextUI` / `hideTextUI` ; le test joue le rôle du joueur avec `p:selectMenu`, `p:answerInput`, `p:answerAlert` ;
- **outils** : `lib.waitFor`, `lib.table` (`contains`, `matches`, `deepclone`, `merge`), `lib.getClosestPlayer` / `lib.getNearbyPlayers` (client et serveur), `lib.requestModel` et autres `lib.request*` (déjà chargés), `lib.addAce` / `lib.addPrincipal`.

Non fournis : `lib.registerMenu` (menu liste), `lib.skillCheck`, `lib.getVehicleProperties`, `lib.class`, `lib.timer`, `lib.disableControls`…

### Audit anti-triche (`emu:fuzz`)

À lancer **à la fin** d'un test, une fois le trafic normal joué (achats, ventes, commandes…) :

```lua
local audit = emu:fuzz()          -- ou emu:fuzz({ resources = { 'ma_ressource' }, events = { 'shop:buy' } })
print(audit:text())
T:eq(audit:count('critique'), 0, 'aucune faille critique')
```

Pour chaque événement réseau serveur de vos ressources (`RegisterNetEvent` et `lib.callback.register`), l'audit reprend les vrais appels observés pendant le test (ou des appels vides si l'événement n'a jamais été déclenché) et les renvoie depuis le joueur, comme le ferait un exécuteur Lua :

- chaque argument, et chaque champ d'un argument table, remplacé par `nil`, `-1`, `0`, `-100000`, `1e9`, `2^31`, `0.5`, `NaN`, `inf`, `''`, une chaîne de 10 Ko, une injection SQL, `{}`, `true`, l'id d'un autre joueur, et aussi :
  - les **valeurs vues dans le trafic observé** (noms d'objets, actions, ids de plants ou de coffres…) : une action `water` devient `burn`, un id devient celui d'un autre objet ;
  - **`id - 1` et `id + 1`** pour un entier : l'objet d'un autre joueur est-il accessible ?
- l'appel normal 10 fois en rafale ;
- l'appel normal depuis 10 km.

Des sondes mesurent l'argent et les objets de chaque joueur avant et après chaque tentative, et le résultat est comparé à l'appel normal :

| Gravité | Signalé quand |
|---|---|
| `critique` | le tricheur reçoit plus qu'avec l'appel normal sans rien payer (ou obtient la même chose en payant moins), un autre joueur perd quelque chose, une valeur devient `NaN` ou infinie, le texte piégé arrive tel quel dans une requête SQL (oxmysql), ou une action en plusieurs messages donne le même résultat sans attendre sa durée (`chains`) |
| `attention` | 10 envois rapportent 10 fois (pas d'anti-spam), ou le même gain est obtenu à 10 km (position pas vérifiée) |
| `info` | une valeur piégée provoque une erreur Lua côté serveur (argument non vérifié) |

`audit.findings` liste `{ severity, event, kind, detail, args }`, `audit:count(gravité)` les compte, `audit:text()` les affiche. Un tricheur expulsé (`DropPlayer`) ou dont l'argent est devenu `NaN` est remplacé par un nouveau joueur identique. Les erreurs Lua provoquées par l'audit sont rangées dans le résultat, pas dans `emu.errors`. Options : `resources`, `events`, `skip`, `player`, `settle` (attente après chaque envoi), `spam` (10), `maxCalls` (2 appels observés par événement), `values` (valeurs à essayer en plus), `seed` (graine de `math.random`, la même à chaque tentative : un écart vient de la variante, pas du hasard).

Un échange contre autre chose (acheter un autre article de la boutique, par exemple) n'est pas compté comme un gain : l'audit ne connaît pas les prix. Le gain doit être gratuit, ou la même chose doit coûter moins cher.

**Actions en plusieurs messages** (`chains`) : beaucoup de scripts demandent l'action (`begin`), jouent une barre de progression, puis valident (`finish`). Déclarez la suite, et l'audit la rejoue avec son délai réel après chaque variante, puis une fois sans attendre :

```lua
local audit = emu:fuzz({
    chains = { ['ma_ressource:begin'] = { 'ma_ressource:finish' } },   -- noms d'événements ou de lib.callback
    reset = function(tricheur) remettreLesPlantsEtLesObjets(tricheur) end,
    maxCalls = 12,
})
```

**État de départ** (`reset`) : chaque tentative consomme quelque chose (le plant récolté n'existe plus, la graine est plantée…). `reset(tricheur)` est appelé avant chaque tentative pour tout remettre comme au début ; sans lui, les tentatives suivantes échouent pour de mauvaises raisons et l'audit ne voit plus rien.

L'audit ne voit que ce que mesurent les sondes : ajoutez les vôtres pour d'autres ressources (`emu:addProbe('xp', function(p) return { xp = monXp[p.id] } end)`). Il ne remplace pas une relecture du code : il trouve vite les oublis classiques.

### Petit outil de vérification

```lua
local T = Emu.tester('titre', { quiet = false })
T:check(condition, 'libellé', détail)   -- détail affiché en cas d'échec
T:eq(obtenu, attendu, 'libellé')
T:same(tableObtenue, tableAttendue, 'libellé')   -- comparaison profonde
T:section('partie')
T:summary()                              -- affiche « N vérifications : X réussies, Y échouées », renvoie true si tout passe
```

## Mocks

Chaque mock se charge avec `require('mocks.nom')(emu, options)` **avant** `emu:start` de votre ressource. Il crée une fausse ressource du même nom (démarrée d'office) et renvoie un objet d'aide pour les tests. Chargez `ox_inventory` **avant** `esx` si vous voulez le mode ox d'ESX (comme sur un serveur qui a ox_inventory).

### ESX 1.12.4 — `mocks/esx.lua`

```lua
local esx = require('mocks.esx')(emu, {
    jobs = { police = { label = 'Police', grades = { [0] = { name = 'recrue', label = 'Recrue', salary = 20 } } } },
    items = { bread = { label = 'Pain', weight = 1 } },        -- inventaire ESX d'origine (sans ox_inventory)
})
local p = emu:addPlayer({ name = 'Alice', esx = { accounts = { money = 500, bank = 1000 }, job = 'police', grade = 0,
                                                   group = 'admin', inventory = { bread = 2 } } })
esx:waitLoaded(p)                 -- avance jusqu'à ce que le client ait reçu esx:playerLoaded
local xPlayer = esx:xPlayer(p)    -- le xPlayer côté serveur
```

- Connexion comme ESX sans multipersonnage : le client envoie `esx:onPlayerJoined` (~600 ms après son arrivée), le serveur crée le xPlayer, déclenche `esx:playerLoaded` côté serveur `(id, xPlayer, isNew)` puis l'envoie au client.
- Serveur : `exports.es_extended:getSharedObject()`, `@es_extended/imports.lua`, `ESX.GetPlayerFromId`, `GetPlayerFromIdentifier`, `GetExtendedPlayers(clé, valeur)`, `GetNumPlayers`, `GetPlayers`, `GetIdentifier`, `RegisterServerCallback`, `TriggerClientCallback`, `RegisterUsableItem` / `UseItem`, `RegisterCommand` (avec arguments typés et ACE par groupe), `DoesJobExist`, `GetJobs`, `GetItems`, `GetItemLabel`, `TriggerClientEvent`, `Math`, `Table`, `GetConfig`.
- xPlayer recopié de `server/classes/player.lua` : `getIdentifier`, `getName`/`setName`, `getAccount(s)`, `getMoney`/`setMoney`/`addMoney`/`removeMoney`, `set/add/removeAccountMoney`, `getInventory`, `getInventoryItem`/`addInventoryItem`/`removeInventoryItem`/`setInventoryItem`, `canCarryItem`, `canSwapItem`, `getWeight`/`getMaxWeight`/`setMaxWeight`, `getJob`/`setJob`, `getGroup`/`setGroup`, `get`/`set`, `getMeta`/`setMeta`/`clearMeta`, `showNotification` (et variantes), `triggerEvent`, `getCoords`/`setCoords`, `kick`, `hasItem`, `getPlayTime`.
- **Attention, comme la vraie 1.12.4 :** `removeAccountMoney` (et donc `removeMoney`) **ne vérifie pas le solde** : le compte peut devenir négatif et rien n'est renvoyé. Un montant `<= 0` lève une erreur (en mode ox : ignoré sans erreur). Vérifiez `getMoney()` vous-même avant de retirer.
- Client : `ESX.GetPlayerData`, `ESX.IsPlayerLoaded`, `ESX.SetPlayerData`, `ESX.GetAccount`, `ESX.SearchInventory`, `ESX.ShowNotification` / `ShowHelpNotification` / `ShowAdvancedNotification` / `TextUI` (enregistrées dans `p.notifications`), `ESX.TriggerServerCallback`, `ESX.AwaitServerCallback` (comme la 1.12.4, son délai de 15 s ne se déclenche jamais), `ESX.RegisterClientCallback`. Les événements `esx:setAccountMoney`, `esx:setJob`, `esx:updatePlayerData`… tiennent `PlayerData` à jour.
- Mode ox (`Config.CustomInventory = "ox"`) : les méthodes d'inventaire et d'argent sont celles de `server/classes/overrides/oxinventory.lua` ; l'argent liquide est l'objet `money` d'ox_inventory (un inventaire de départ vide reçoit l'argent du joueur sous forme d'objet).
- Aides : `esx.ESX` (ESX serveur), `esx:xPlayer(p)`, `esx:clientESX(p)`, `esx:waitLoaded(p)`, `esx:useItem(p, nom)`.

### oxmysql 2.12.0 — `mocks/oxmysql.lua`

```lua
local db = require('mocks.oxmysql')(emu, { latency = 5 })
db:on('^SELECT money FROM users', { { money = 500 } })                    -- réponse fixe
db:on('^INSERT INTO logs', function(query, params) return { insertId = 1, affectedRows = 1 } end)
db:on(function(query, params) return query:find('DELETE') end, function() error('accès refusé') end)  -- erreur SQL
```

- Fournit `@oxmysql/lib/MySQL.lua` (`MySQL.query`, `single`, `scalar`, `insert`, `update`, `prepare`, `transaction`, `rawExecute`, chacun avec callback ou `.await`), les alias `MySQL.Async.*` / `MySQL.Sync.*` (`fetchAll`, `fetchScalar`, `fetchSingle`, `insert`, `execute`, `transaction`, `prepare`, `store`), `MySQL.ready`, et les exports `exports.oxmysql:query(…)` etc.
- Une réponse donne le résultat brut de MySQL : lignes pour un SELECT, `{ insertId, affectedRows }` sinon. Le mock le met en forme comme oxmysql : `query` → lignes, `single` → première ligne, `scalar` → première colonne, `insert` → `insertId`, `update` → `affectedRows`, `prepare` → valeur seule / ligne / lignes selon le nombre de résultats, `transaction` → `true` ou `false`.
- La réponse enregistrée en dernier gagne. Une requête **sans réponse prévue** est une erreur claire dans `emu.errors`. Une erreur levée dans une réponse simule une erreur SQL : `.await` la remonte au script, la forme avec callback ne rappelle pas et l'erreur s'affiche (comme oxmysql). Trop de paramètres pour les `?` donne l'erreur d'oxmysql.
- `db.log` (et `db:queries(motif)`) : toutes les requêtes avec ressource, méthode, paramètres et résultat. `latency` en ms par requête.
- Les paramètres nommés (`@nom`, `:nom`) sont passés tels quels à votre réponse. `MySQL.startTransaction` n'est pas fourni.

### ox_inventory 2.45.0 (serveur) — `mocks/ox_inventory.lua`

```lua
local inv = require('mocks.ox_inventory')(emu, { items = {
    water = { label = 'Eau', weight = 500 },
    phone = { label = 'Téléphone', weight = 190, stack = false },
} })
local p = emu:addPlayer({ inventory = { water = 2 } })   -- sans ESX ; avec ESX : addPlayer{ esx = { inventory = … } }
```

- Exports : `AddItem(inv, objet, nombre, métadonnées, emplacement, cb)` → `success, response`, `RemoveItem(inv, objet, nombre, métadonnées, emplacement, ignoreTotal, strict)` (strict vrai par défaut), `GetItemCount`, `Search('count' | 'slots', …)`, `GetItemSlots`, `GetSlotsWithItem` / `GetSlotWithItem` / `GetSlotIdWithItem` / `GetSlotIdsWithItem` (strict faux par défaut), `CanCarryItem`, `CanCarryAmount`, `CanCarryWeight`, `CanSwapItem`, `GetItem`, `GetSlot`, `SetItem`, `SetMetadata`, `SetMaxWeight`, `GetEmptySlot`, `GetSlotForItem`, `ClearInventory`, `GetInventory`, `GetInventoryItems`, `RegisterStash`, `Items`, `registerHook` / `removeHooks` (`createItem` et `swapItems`, filtres `itemFilter`, `inventoryFilter`, `typeFilter`).
- Comme ox_inventory : objets empilables par défaut, empilement seulement si les métadonnées sont identiques (`table.matches`), `AddItem` ne contrôle pas le poids (c'est le rôle de `CanCarryItem`), comparaison partielle avec `table.contains` d'ox_lib (qui compare les **valeurs**). 50 emplacements et 30 000 de poids par défaut (`slots`, `maxWeight`).
- Côté client : copie de l'inventaire tenue à jour par `ox_inventory:updateSlots` ; exports client `Search`, `GetItemCount`, `GetPlayerItems`, `GetPlayerWeight`, `Items`.
- Aides : `inv.Inventory` (module serveur), `inv:count(p, nom)`, `inv:clientCount(p, nom)`, `inv:inventory(p)`, `inv:swap(p, { fromInventory, fromSlot, toInventory, toSlot, count })` (glisser-déposer simplifié qui passe par le crochet `swapItems`).
- Boutiques : export `RegisterShop(type, { name, inventory = { { name, price, metadata, currency } }, locations })` et aide `inv:buy(p, type, rangArticle, nombre, rangEmplacement)`, qui contrôle comme ox_inventory la distance (10 m si la boutique a des emplacements), l'argent (objet `currency`, « money » par défaut) et la place, puis déclenche les crochets `buyItem` et `createItem`. Renvoie `true` ou `false, raison` (`too_far`, `not_enough_money`, `cannot_carry`, `hook`…). Pas d'interface de boutique ni de prix aléatoires.
- Non simulé : armes, conteneurs, usure dans le temps, fouilles, dépôts au sol, sauvegarde en base.

### ox_target 1.18.0 (client) — `mocks/ox_target.lua`

```lua
local target = require('mocks.ox_target')(emu)
local ok, info = alice:target('boutique:eau')                 -- par nom ou libellé d'option
local ok2, raison = target:select(bob, 'boutique:eau', { coords = { x = 1, y = 2, z = 3 } })
```

- Exports : `addBoxZone`, `addSphereZone`, `addPolyZone`, `removeZone`, `zoneExists`, `addGlobalPed/Vehicle/Object/Player/Option` et leurs `remove…`, `addModel`/`removeModel`, `addEntity`/`removeEntity`, `addLocalEntity`/`removeLocalEntity`, `disableTargeting`, `isActive`.
- Choix d'une option comme ox_target : le point visé (centre de la zone, ou `opts.coords`, ou l'entité `opts.entity`) doit être dans la zone et à moins de 20 m ; distance joueur → point ≤ `option.distance` (7 par défaut) ; `groups` (métier ESX), `items` (ox_inventory ou ESX) ; puis `canInteract(entity, distance, coords, name, bone)`. L'action est celle d'ox_target : `onSelect(réponse)`, `export`, `event`, `serverEvent` (sans les fonctions), `command`.
- Renvoie `true, { option, zone, distance, coords }` ou `false, raison` (par exemple « trop loin (8.0 m > 7.0 m) »).
- Approximations : hauteur des zones boîte et polygone = ± moitié de l'épaisseur ; `bones` et `offset` ignorés ; seules les entités locales du joueur sont visables.

## Exemples et sortie réelle

`lua5.4 examples/demo_ping_test.lua` (ressource `examples/resources/demo_ping` : commande `/ping`, commande restreinte `/annonce`, `lib.callback`, anti-spam, `playerDropped`) :

```
== demo_ping
  ok     /ping accepté
  ok     Alice (60 i/s) dessine le marqueur sur 60 images
  ok     marqueur de type 1 (cylindre)
  ok     Carol (30 i/s) dessine 30 images pour la même seconde
  ok     Bob sans ACE : /annonce refusée
  ok     Alice avec ACE : /annonce acceptée
  ok     Alice reçoit l'annonce
  ok     Bob reçoit l'annonce
  ok     Carol reçoit l'annonce
  ok     deuxième hello de Bob trop rapide : refusé (cooldown)
  ok     premier hello de Bob : bienvenue envoyée à tous
  ok     callback ox_lib : le serveur répond à Carol
  ok     Bob déconnecté ne reçoit plus rien
  ok     aucune erreur

fivem_emu 0.3.1 — t = 9.5 s virtuelles, 3 joueur(s)
erreurs : 0
TriggerClientEvent vers tous (-1) : 3 fois
joueur 1 (Alice, RTT 30 ms) : reçu 4 paquets / 0.1 Ko, envoyé 3 / 0.1 Ko, 60 dessins, 0 entités locales restantes
joueur 2 (Bob, RTT 180 ms) : reçu 3 paquets / 0.1 Ko, envoyé 2 / 0.0 Ko, 0 dessins, 0 entités locales restantes, déconnecté
joueur 3 (Carol, RTT 90 ms) : reçu 5 paquets / 0.2 Ko, envoyé 2 / 0.1 Ko, 30 dessins, 0 entités locales restantes

14 vérifications : 14 réussies, 0 échouées
```

`lua5.4 examples/demo_boutique_test.lua` (ressource `examples/resources/demo_boutique` : une boutique qui utilise ESX, oxmysql, ox_inventory et ox_target) :

```
== demo_boutique
  ok     Alice a 30 $
  ok     en mode ox, l'argent est aussi l'objet « money »
  ok     Alice vise le comptoir : option « eau » disponible
  ok     option « pain » (serverEvent) disponible
  ok     Alice reçoit 1 eau
  ok     Alice reçoit 1 pain
  ok     10 $ + 15 $ débités
  ok     le client d'Alice voit l'eau dans son inventaire
  ok     troisième achat refusé faute d'argent
  ok     argent inchangé après le refus
  ok     Bob (34 m) ne peut pas viser le comptoir
  ok     triche de Bob (événement direct) refusée par le serveur
  ok     Bob garde ses 100 $
  ok     Alice (police) voit « Contrôler le stock »
  ok     Bob (sans métier) ne la voit pas
  ok     historique lu en base par lib.callback
  ok     deux ventes enregistrées
  ok     aucune erreur

fivem_emu 0.3.1 — t = 4.3 s virtuelles, 2 joueur(s)
erreurs : 0
joueur 1 (Alice, RTT 40 ms) : reçu 16 paquets / 2.1 Ko, envoyé 5 / 0.3 Ko, 0 dessins, 0 entités locales restantes
joueur 2 (Bob, RTT 150 ms) : reçu 3 paquets / 0.8 Ko, envoyé 2 / 0.0 Ko, 0 dessins, 0 entités locales restantes
oxmysql (simulé) : 3 requête(s), 0 sans réponse prévue

18 vérifications : 18 réussies, 0 échouées
```

`lua5.4 examples/demo_audit_test.lua` (ressource `examples/resources/demo_faille`, **volontairement mal protégée**) :

```
Audit anti-triche : 4 événement(s), 84 tentative(s), 3 critique(s), 2 attention, 1 info
  CRITIQUE  faille:journal — injection SQL (argument 1) : requête envoyée : INSERT INTO faille_journal (message) VALUES ('emu' OR '1'='1')
  CRITIQUE  faille:virement — gain (argument 2) : valeur -1 → esx:bank +1 (appel normal : -50)
  CRITIQUE  faille:virement — perte pour un autre joueur (argument 2) : valeur -1 → joueur 2 : esx:bank -1 (appel normal : +50)
  ATTENTION faille:recompense — aucun contrôle de distance : même effet à 10 km de la position du test
  ATTENTION faille:recompense — pas d'anti-spam : 10 envois en rafale : esx:bank +1000 (1 envoi : +100)
  INFO      faille:virement — erreur Lua (argument 2) : valeur -100000 → … Tried To Set Account bank For Player 2 To An Invalid Number …
```

L'événement `faille:don`, qui vérifie son montant (entier, positif, plafonné) et le solde, ne ressort pas.

`lua5.4 tests/run.lua` lance les tests de l'émulateur et des mocks (ajoutez `-v` pour voir chaque vérification) ; il se termine par :

```
269 vérifications : 269 réussies, 0 échouées
```

## Organisation du dépôt

```
fivem_emu.lua                 l'émulateur (un seul fichier)
mocks/                        esx.lua, oxmysql.lua, ox_inventory.lua, ox_target.lua
examples/                     demo_ping_test.lua, demo_boutique_test.lua, demo_audit_test.lua et leurs ressources
tests/run.lua                 tests de l'émulateur et des mocks (ressources de test dans tests/fixtures)
```

## Licence

Distribué sous licence MIT (voir [LICENSE](LICENSE)) : vous pouvez utiliser, modifier et redistribuer le code, y compris dans un projet commercial, à condition de garder l'avis de copyright et la licence. Le logiciel est fourni tel quel, sans garantie.
