-- tests/run.lua — tests de fivem_emu et des mocks. Lancer depuis la racine du dépôt : lua5.4 tests/run.lua
-- Option -v : affiche aussi les vérifications réussies.
local root = (arg and arg[0] or ''):match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path

local Emu = require('fivem_emu')
local T = Emu.tester('fivem_emu ' .. Emu.VERSION .. ' — tests', { quiet = arg[1] ~= '-v' })
local json = Emu.json

-- Ressource écrite en Lua dans le test, démarrée tout de suite
local function res(emu, name, server, client)
    emu:defineResource(name, { server = server, client = client })
    emu:start(name)
end

local function hasText(list, text)
    for _, s in ipairs(list) do if s:find(text, 1, true) then return true end end
    return false
end

-------------------------------------------------------------------------------
T:section('Ordonnanceur et Wait')
-------------------------------------------------------------------------------
do
    local emu = Emu.new()
    local log = {}
    res(emu, 'ordre', function(env)
        env.CreateThread(function()
            log[#log + 1] = 'A0@' .. env.GetGameTimer()
            env.Wait(0)
            log[#log + 1] = 'A1@' .. env.GetGameTimer()
            env.Wait(100)
            log[#log + 1] = 'A2@' .. env.GetGameTimer()
        end)
        env.CreateThread(function()
            log[#log + 1] = 'B0@' .. env.GetGameTimer()
            env.Wait(0)
            log[#log + 1] = 'B1@' .. env.GetGameTimer()
        end)
        env.SetTimeout(25, function() log[#log + 1] = 'T@' .. env.GetGameTimer() end)
        local id = env.SetTimeout(5, function() log[#log + 1] = 'annulé' end)
        env.ClearTimeout(id)
        log[#log + 1] = 'corps@' .. env.GetGameTimer()
    end)
    emu:run(300)
    T:eq(table.concat(log, ' '), 'corps@0 A0@10 B0@10 A1@20 B1@20 T@30 A2@120',
        'corps immédiat, CreateThread au tick suivant, Wait(0) = tick suivant, Wait(100) exact, SetTimeout, ClearTimeout')

    -- Client : Wait(0) = une image (60 i/s → 16,7 ms ; 30 i/s → 33,3 ms)
    local emu2 = Emu.new()
    local frames = {}
    res(emu2, 'images', nil, function(env, _, player)
        frames[player.id] = { n = 0, times = {} }
        env.CreateThread(function()
            local start = emu2.now
            while emu2.now - start < 1000 do
                frames[player.id].n = frames[player.id].n + 1
                frames[player.id].times[#frames[player.id].times + 1] = emu2.now
                env.Wait(0)
            end
        end)
    end)
    local p60 = emu2:addPlayer({ fps = 60 })
    local p30 = emu2:addPlayer({ fps = 30 })
    emu2:run(1500)
    T:eq(frames[p60.id].n, 60, 'client à 60 i/s : 60 tours de boucle Wait(0) en 1 s')
    T:eq(frames[p30.id].n, 30, 'client à 30 i/s : 30 tours en 1 s')
    local t = frames[p60.id].times
    T:check(math.abs((t[3] - t[2]) - 1000 / 60) < 1e-6, 'écart entre deux images = 16,67 ms')
end

-------------------------------------------------------------------------------
T:section('Réseau : ordre, gigue, perte, gel, chaos, taille')
-------------------------------------------------------------------------------
do
    local emu = Emu.new({ seed = 42 })
    local got = {}
    res(emu, 'net', function(env)
        env.CreateThread(function()
            for i = 1, 50 do
                env.TriggerClientEvent('net:n', -1, i, emu.now)
                env.Wait(10)
            end
        end)
    end, function(env, _, player)
        got[player.id] = {}
        env.RegisterNetEvent('net:n', function(i, sentAt)
            got[player.id][#got[player.id] + 1] = { i = i, delay = emu.now - sentAt }
        end)
    end)
    local fiable = emu:addPlayer({ rtt = 40, jitter = 200 })
    local chaos = emu:addPlayer({ rtt = 40, jitter = 200, chaos = true })
    emu:run(3000)
    local ordered, minDelay = true, math.huge
    for k, v in ipairs(got[fiable.id]) do
        if v.i ~= k then ordered = false end
        minDelay = math.min(minDelay, v.delay)
    end
    T:eq(#got[fiable.id], 50, 'gigue 200 ms : les 50 événements arrivent')
    T:check(ordered, 'gigue 200 ms : ordre d\'envoi conservé (canal fiable et ordonné)')
    T:check(minDelay >= 20, 'délai minimal = RTT / 2', minDelay)
    local disorder = false
    for k, v in ipairs(got[chaos.id]) do if v.i ~= k then disorder = true end end
    T:check(disorder and #got[chaos.id] == 50, 'mode chaos : même trafic, ordre non garanti')

    -- Perte = retransmission après un RTT ; gel = rien n'arrive avant la fin du gel
    local emu2 = Emu.new()
    local arrivals = {}
    res(emu2, 'perte', nil, function(env, _, player)
        env.RegisterNetEvent('x', function() arrivals[player.id] = emu2.now end)
    end)
    local perdu = emu2:addPlayer({ rtt = 40, loss = 1 })
    local gele = emu2:addPlayer({ rtt = 40, freeze = { 100, 500 } })
    emu2:run(150)
    emu2:env(nil, 'perte').TriggerClientEvent('x', -1)
    emu2:run(1000)
    T:eq(arrivals[perdu.id], 150 + 20 + 40, 'perte : arrivée après RTT/2 + un RTT de retransmission')
    T:eq(arrivals[gele.id], 500 + 20, 'gel de 100 à 500 ms : arrivée à la fin du gel + RTT/2')

    -- Chaos : doublons et événements supprimés
    local emu3 = Emu.new()
    local count = { a = 0, b = 0 }
    res(emu3, 'dup', nil, function(env)
        env.RegisterNetEvent('a', function() count.a = count.a + 1 end)
        env.RegisterNetEvent('b', function() count.b = count.b + 1 end)
    end)
    emu3:addPlayer({ chaos = true, duplicate = 1, dropEvents = { b = true } })
    emu3:env(nil, 'dup').TriggerClientEvent('a', -1)
    emu3:env(nil, 'dup').TriggerClientEvent('b', -1)
    emu3:run(1000)
    T:eq(count.a, 2, 'chaos duplicate = 1 : événement reçu deux fois')
    T:eq(count.b, 0, 'chaos dropEvents : événement supprimé')

    -- Taille msgpack estimée
    T:eq(Emu.packSize(1), 1, 'msgpack : petit entier = 1 octet')
    T:eq(Emu.packSize(200), 2, 'msgpack : 200 = 2 octets')
    T:eq(Emu.packSize(-100), 2, 'msgpack : -100 = 2 octets (int8)')
    T:eq(Emu.packSize(70000), 5, 'msgpack : 70000 = 5 octets')
    T:eq(Emu.packSize(1.5), 9, 'msgpack : flottant = 9 octets')
    T:eq(Emu.packSize('abc'), 4, 'msgpack : chaîne de 3 = 4 octets')
    T:eq(Emu.packSize(('x'):rep(40)), 42, 'msgpack : chaîne de 40 = 42 octets')
    T:eq(Emu.packSize({ 1, 2, 3 }), 4, 'msgpack : tableau de 3 petits entiers = 4 octets')
    T:eq(Emu.packSize({ a = 1 }), 4, 'msgpack : { a = 1 } = 4 octets')
    T:eq(Emu.packSize(Emu.vec3(1, 2, 3)), 15, 'msgpack : vector3 = 15 octets')
    T:eq(Emu.eventSize('ev', table.pack(1, nil, 'x')), 7, 'taille d\'un événement : nom + arguments (nil compris)')
    T:eq(emu3.players[1].net.down.packets, 2, 'statistiques : paquets descendants comptés')

    -- Fonctions refusées dans les données réseau
    local emu4 = Emu.new()
    local recu = false
    res(emu4, 'fn', nil, function(env) env.RegisterNetEvent('f', function() recu = true end) end)
    emu4:addPlayer()
    emu4:env(nil, 'fn').TriggerClientEvent('f', -1, { cb = function() end })
    emu4:run(500)
    T:check(not recu and hasText(emu4.errors, 'non sérialisable (function)'), 'fonction dans les données réseau : refusée et signalée')
end

-------------------------------------------------------------------------------
T:section('Manifeste : motifs, inclusions @, fichiers')
-------------------------------------------------------------------------------
do
    local emu = Emu.new()
    emu:provide('@inclus/partage.lua', function(env) env.Inclus = 'oui' end)
    local r = emu:loadResource(root .. '/tests/fixtures/manifeste')
    emu:start('manifeste')
    local p = emu:addPlayer()
    emu:run(100)
    local senv, cenv = emu:env(nil, 'manifeste'), emu:env(p, 'manifeste')
    T:eq(rawget(senv, 'Ordre'), 'sab', 'shared puis server/**/*.lua (racine et sous-dossier, .txt ignoré)')
    T:eq(rawget(senv, 'Total'), 10, 'préprocesseur += dans un vrai fichier')
    T:eq(rawget(cenv, 'ClientOk'), true, 'client : script partagé et inclusion @ fournie')
    T:eq(rawget(cenv, 'Hash'), -1216765807, '`adder` (CfxLua) remplacé par son hash')
    T:check(hasText(emu.warnings, '@absent/rien.lua non fournie'), 'inclusion @ non fournie : avertissement')
    T:same(r.meta.data_file, { 'DLC_ITYP_REQUEST', 'stream/exemple.ytyp' }, 'directive à deux valeurs (data_file)')
    T:eq(senv.LoadResourceFile('manifeste', 'data/info.json'), '{"ok":true}\n', 'LoadResourceFile lit le fichier de la ressource')
    T:eq(#emu.errors, 0, 'aucune erreur', emu.errors[1])
end

-------------------------------------------------------------------------------
T:section('Commandes, ACE, source')
-------------------------------------------------------------------------------
do
    local emu = Emu.new()
    local calls = {}
    res(emu, 'cmd', function(env)
        env.RegisterCommand('libre', function(src, args, raw) calls[#calls + 1] = { src = src, arg = args[1], raw = raw, t = emu.now } end, false)
        env.RegisterCommand('admin', function(src) calls[#calls + 1] = { src = src, admin = true } end, true)
    end)
    local p1 = emu:addPlayer({ rtt = 40 })
    local p2 = emu:addPlayer({ aces = { 'command.admin' } })
    local p3 = emu:addPlayer()
    T:same({ p1:command('admin') }, { false, 'access_denied' }, 'commande restreinte sans ACE : refusée')
    T:same({ p2:command('admin') }, { true }, 'commande restreinte avec ACE command.admin : acceptée')
    emu:command(nil, 'add_ace group.modo command allow')
    emu:command(nil, 'add_principal identifier.' .. p3.identifiers[1] .. ' group.modo')
    T:same({ p3:command('admin') }, { true }, 'add_ace + add_principal : le groupe donne le droit')
    emu:command(nil, 'add_ace player.3 command.admin deny')
    T:same({ p3:command('admin') }, { false, 'access_denied' }, 'deny l\'emporte sur allow')
    T:same({ emu:command(nil, 'admin') }, { true }, 'console : toujours autorisée')
    p1:command('/libre bonjour monde')
    T:eq(#calls, 1, 'seule la commande console est déjà exécutée : celles des joueurs sont en route sur le réseau')
    emu:run(100)
    local last = calls[#calls]
    T:check(last.src == 1 and last.arg == 'bonjour' and last.raw == 'libre bonjour monde' and last.t == 20,
        'commande exécutée à l\'arrivée (RTT/2), source = joueur, args et ligne brute', json.encode(last))
    T:same({ p1:command('inconnue') }, { false, 'unknown' }, 'commande inconnue')
    res(emu, 'cmdclient', nil, function(env) env.RegisterCommand('libre', function() calls[#calls + 1] = { client = true } end) end)
    p1:command('libre')
    T:check(calls[#calls].client == true, 'une commande client passe avant la commande serveur du même nom')

    -- source
    local emu2 = Emu.new()
    local seen = {}
    res(emu2, 'src', function(env)
        env.RegisterNetEvent('src:test', function()
            seen.first = env.source
            env.TriggerEvent('src:local')
            env.Wait(50)
            seen.after = env.source
        end)
        env.AddEventHandler('src:local', function() seen.loc = env.source end)
        env.AddEventHandler('src:pasreseau', function() seen.notNet = true end)
    end, function(env)
        env.RegisterNetEvent('src:client', function() seen.client = env.source end)
    end)
    -- une autre ressource déclare src:pasreseau : la ressource « src » ne l'a pas déclaré, elle ne le reçoit pas
    res(emu2, 'autre', function(env) env.RegisterNetEvent('src:pasreseau', function() seen.other = true end) end)
    local p = emu2:addPlayer()
    emu2:env(p, 'src').TriggerServerEvent('src:test')
    emu2:env(p, 'src').TriggerServerEvent('src:pasreseau')
    emu2:env(p, 'src').TriggerServerEvent('src:inconnu')
    emu2:env(nil, 'src').TriggerClientEvent('src:client', p.id)
    emu2:run(500)
    T:eq(seen.first, 1, 'événement réseau reçu par le serveur : source = id du joueur (nombre)')
    T:eq(seen.loc, '', 'événement local (TriggerEvent) : source = \'\'')
    T:eq(seen.after, nil, 'après un Wait, source est remis à sa valeur d\'avant (lire source au début)')
    T:eq(seen.client, 65535, 'événement reçu du serveur par un client : source = 65535')
    T:check(seen.other and not seen.notNet, 'RegisterNetEvent vaut par ressource : AddEventHandler seul ne reçoit pas le réseau')
    T:check(hasText(emu2.warnings, '« src:inconnu » reçu sans RegisterNetEvent, ignoré'), 'événement réseau non déclaré : ignoré et signalé')
end

-------------------------------------------------------------------------------
T:section('Exports, rappels ox_lib, playerDropped')
-------------------------------------------------------------------------------
do
    local emu = Emu.new()
    local calls, r = 0, {}
    res(emu, 'fournisseur', function(env)
        env.exports('double', function(x)
            calls = calls + 1
            return x * 2, env.GetInvokingResource()
        end)
        env.exports('casse', function() error('panne interne') end)
    end)
    res(emu, 'consommateur', function(env)
        r.a, r.inv = env.exports.fournisseur:double(4)
        r.b = env.exports['fournisseur']['double'](nil, 5)
        r.ok1, r.err1 = pcall(function() return env.exports.absent:f() end)
        r.ok2, r.err2 = pcall(function() return env.exports.fournisseur:casse() end)
    end)
    T:eq(r.a, 8, 'exports.ressource:fonction(...)')
    T:eq(r.inv, 'consommateur', 'GetInvokingResource dans un export = ressource appelante')
    T:eq(r.b, 10, 'exports[\'r\'][\'f\'](self, ...) : le premier argument est ignoré comme dans FiveM')
    T:eq(calls, 2, 'chaque appel d\'export exécute la fonction une seule fois')
    T:check(not r.ok1 and tostring(r.err1):find('export introuvable', 1, true), 'export absent : erreur claire')
    T:check(not r.ok2 and tostring(r.err2):find('panne interne', 1, true), 'erreur dans un export : remonte à l\'appelant')

    -- lib.callback dans les deux sens, deux ressources en même temps (pas de mélange des réponses)
    local emu2 = Emu.new()
    emu2:loadResource(root .. '/tests/fixtures/rappel_a')
    emu2:loadResource(root .. '/tests/fixtures/rappel_b')
    emu2:start('rappel_a')
    emu2:start('rappel_b')
    local p = emu2:addPlayer({ rtt = 80 })
    emu2:run(1000)
    T:check(hasText(p.side.log, 'A\t1\t7') and hasText(p.side.log, 'B\t1\t7'), 'lib.callback client → serveur : bonnes réponses pour les deux ressources', table.concat(p.side.log, ' | '))
    T:check(hasText(emu2.server.log, 'client 1 a répondu q1'), 'lib.callback serveur → client (lib.callback.await(nom, joueur))')
    T:eq(#p.notifications, 2, 'lib.notify(joueur, données) côté serveur : reçu et enregistré chez le client')

    -- playerDropped
    local emu3 = Emu.new()
    local dropped
    res(emu3, 'depart', function(env)
        env.AddEventHandler('playerDropped', function(reason)
            dropped = { src = env.source, name = env.GetPlayerName(env.source), reason = reason }
        end)
    end, function(env) env.RegisterNetEvent('apres', function() dropped.received = true end) end)
    local alice = emu3:addPlayer({ name = 'Alice' })
    emu3:run(50)
    alice:drop('à plus')
    emu3:env(nil, 'depart').TriggerClientEvent('apres', -1)
    emu3:run(500)
    T:check(dropped and dropped.src == 1 and dropped.name == 'Alice' and dropped.reason == 'à plus',
        'playerDropped : source, raison, GetPlayerName encore valable pendant l\'événement')
    T:check(not dropped.received and #emu3:env(nil, 'depart').GetPlayers() == 0, 'après départ : plus rien n\'est envoyé, GetPlayers vide')
end

-------------------------------------------------------------------------------
T:section('Outils : joaat, préprocesseur, vecteurs, promesses, erreurs, arrêt')
-------------------------------------------------------------------------------
do
    T:eq(Emu.joaat('adder'), -1216765807, "joaat('adder') == -1216765807")
    T:eq(Emu.joaat('ADDER'), -1216765807, 'joaat ignore la casse')
    T:eq(Emu.preprocess('x += 1'), 'x = x + (1)', 'préprocesseur : x += 1')
    T:eq(Emu.preprocess('self.n -= a * 2 -- note'), 'self.n = self.n - (a * 2) -- note', 'préprocesseur : champ et commentaire final')
    -- Les accents graves ne sont convertis que dans le code, jamais dans une chaîne ou un commentaire (comme CfxLua)
    T:eq(Emu.preprocess("local q = 'SET `wins` = 1'"), "local q = 'SET `wins` = 1'", 'préprocesseur : `x` laissé dans une chaîne')
    T:eq(Emu.preprocess('local q = "a `b` c"'), 'local q = "a `b` c"', 'préprocesseur : `x` laissé dans une chaîne entre guillemets')
    T:eq(Emu.preprocess("local q = [[ `x` ]] local h = `adder`"), "local q = [[ `x` ]] local h = -1216765807", 'préprocesseur : chaîne longue ignorée, hash après')
    T:eq(Emu.preprocess("-- note `x`\nlocal h = `adder`"), "-- note `x`\nlocal h = -1216765807", 'préprocesseur : commentaire ignoré')
    T:eq(Emu.preprocess("--[[ bloc `x` ]] x = `adder`"), "--[[ bloc `x` ]] x = -1216765807", 'préprocesseur : commentaire long ignoré')
    T:eq(Emu.preprocess("local s = 'it\\'s `a`' .. `adder`"), "local s = 'it\\'s `a`' .. -1216765807", 'préprocesseur : apostrophe échappée dans une chaîne')
    T:eq(Emu.preprocess('if ok then t[k] *= 2 else t[k] /= 2 end'), 'if ok then t[k] = t[k] * (2) else t[k] = t[k] / (2) end',
        'préprocesseur : sur une ligne avec if/else/end')
    T:eq(Emu.preprocess('local s = "a += b"'), 'local s = "a += b"', 'préprocesseur : chaînes non touchées')
    T:eq(Emu.preprocess('if a <= b then end'), 'if a <= b then end', 'préprocesseur : <= non touché')

    local emu = Emu.new()
    local env = emu:env(nil, 'outils')
    local a, b = env.vector3(1, 2, 3), env.vec3(1, 2, 0)
    T:eq(#(a - b), 3.0, 'vecteurs : #(a - b) = distance')
    T:eq(tostring(a * 2), 'vector3(2, 4, 6)', 'vecteurs : produit par un nombre')
    T:eq(env.type(a), 'vector3', 'type(vector3) = "vector3" comme en CfxLua')
    T:check(a.xy == env.vector2(1, 2), 'vecteurs : a.xy (swizzle) et égalité')
    T:eq(Emu.isVector(Emu.netCopy(a)), true, 'un vecteur reste un vecteur après le réseau')

    -- promesses
    local out = {}
    res(emu, 'promesses', function(e)
        e.CreateThread(function()
            local p = e.promise.new()
            e.SetTimeout(50, function() p:resolve('ok') end)
            out.v = e.Citizen.Await(p)
            out.t = e.GetGameTimer()
            local p2 = e.promise:new()
            p2:reject('raté')
            out.ok, out.err = pcall(e.Citizen.Await, p2)
        end)
    end)
    emu:run(200)
    T:check(out.v == 'ok' and out.t >= 50, 'promise + Citizen.Await : le fil attend la résolution')
    T:check(out.ok == false and tostring(out.err):find('raté', 1, true), 'promesse rejetée : Citizen.Await lève l\'erreur')

    -- erreur dans un fil
    local emu2 = Emu.new({ maxInstructions = 2000000 })
    local ticks = 0
    res(emu2, 'fragile', function(e)
        e.CreateThread(function() e.Wait(20) error('boum') end)
        e.CreateThread(function() while true do ticks = ticks + 1 e.Wait(10) end end)
        e.CreateThread(function() e.Wait(30) while true do end end)
    end)
    local ok = pcall(emu2.run, emu2, 200)
    T:check(ok and hasText(emu2.errors, 'boum'), 'erreur dans un fil : attrapée et notée, l\'émulateur continue')
    T:check(hasText(emu2.errors, 'instructions sans Wait'), 'boucle sans Wait : coupée et signalée au lieu de bloquer')
    T:check(ticks >= 19, 'les autres fils continuent de tourner', ticks)

    -- arrêt d'une ressource
    local stopped, n = false, 0
    res(emu2, 'arret', function(e)
        e.RegisterCommand('arret_cmd', function() end, false)
        e.AddEventHandler('onResourceStop', function(name) if name == 'arret' then stopped = true end end)
        e.CreateThread(function() while true do n = n + 1 e.Wait(10) end end)
    end)
    emu2:run(100)
    emu2:stop('arret')
    local before = n
    emu2:run(100)
    T:check(stopped and n == before, 'emu:stop : onResourceStop reçu puis fils coupés')
    T:same({ emu2:command(nil, 'arret_cmd') }, { false, 'unknown' }, 'emu:stop : commandes de la ressource retirées')
end

-------------------------------------------------------------------------------
T:section('Mock oxmysql')
-------------------------------------------------------------------------------
do
    local emu = Emu.new()
    local db = require('mocks.oxmysql')(emu, { latency = 5 })
    db:on('^SELECT %* FROM users WHERE id', function(_, p) return { { id = p[1], name = 'Alice', money = 10 } } end)
    db:on('^SELECT money FROM users', { { money = 500 } })
    db:on('^SELECT name FROM users$', { { name = 'A' }, { name = 'B' } })
    db:on('^SELECT 1 FROM vide', {})
    db:on('^INSERT INTO', { insertId = 42, affectedRows = 1 })
    db:on('^UPDATE', function() return { affectedRows = 3 } end)
    db:on('^DELETE FROM casse', function() error('Table \'casse\' doesn\'t exist') end)
    local r = {}
    emu:provide('@test/run.lua', function() end)
    res(emu, 'sql', function(env)
        emu.providers['@oxmysql/lib/MySQL.lua'](env, emu.server, emu)
        local MySQL = env.MySQL
        env.CreateThread(function()
            local t0 = env.GetGameTimer()
            r.rows = MySQL.query.await('SELECT * FROM users WHERE id = ?', { 7 })
            r.waited = env.GetGameTimer() - t0
            r.single = MySQL.single.await('SELECT * FROM users WHERE id = ?', { 8 })
            r.scalar = MySQL.scalar.await('SELECT money FROM users WHERE id = ?', { 1 })
            r.insert = MySQL.insert.await('INSERT INTO logs (a) VALUES (?)', { 'x' })
            r.update = MySQL.update.await('UPDATE users SET money = ?', { 1 })
            r.prepOne = MySQL.prepare.await('SELECT money FROM users WHERE id = ?', { 1 })
            r.prepRow = MySQL.prepare.await('SELECT * FROM users WHERE id = ?', { 2 })
            r.prepMany = MySQL.prepare.await('SELECT name FROM users', {})
            r.prepNone = MySQL.prepare.await('SELECT 1 FROM vide', {})
            r.prepInsert = MySQL.prepare.await('INSERT INTO logs (a) VALUES (?)', { 'y' })
            r.prepBatch = MySQL.prepare.await('INSERT INTO logs (a) VALUES (?)', { { 'a' }, { 'b' } })
            r.raw = MySQL.rawExecute.await('SELECT * FROM users WHERE id = ?', { 3 })
            r.tx = MySQL.transaction.await({ 'UPDATE a SET b = 1', { query = 'INSERT INTO c VALUES (?)', values = { 1 } } })
            r.txFail = MySQL.transaction.await({ 'UPDATE a SET b = 1', 'DELETE FROM casse' })
            r.errOk, r.err = pcall(MySQL.query.await, 'DELETE FROM casse WHERE 1')
            r.missOk, r.miss = pcall(MySQL.scalar.await, 'SELECT inconnue')
            r.tooMany = pcall(MySQL.query.await, 'SELECT * FROM users WHERE id = ?', { 1, 2 })
            r.argOk, r.argErr = pcall(MySQL.query, true)
            r.fetchAll = MySQL.Async.fetchAll == MySQL.query
            r.syncScalar = MySQL.Sync.fetchScalar('SELECT money FROM users')
            local stored = MySQL.Async.store('SELECT money FROM users')
            r.stored = MySQL.scalar.await(stored)
            r.ready = MySQL.ready.await()
        end)
        MySQL.query('SELECT * FROM users WHERE id = ?', { 9 }, function(rows) r.cb = rows[1].id r.cbRes = env.GetCurrentResourceName() end)
        MySQL.insert('INSERT INTO x VALUES (?)', { 1 }, function(id) r.cbInsert = id end)
        env.exports.oxmysql:scalar('SELECT money FROM users', {}, function(v) r.export = v end)
        MySQL.update('DELETE FROM casse', {}, function() r.cbOnError = true end)
    end)
    emu:run(2000)
    T:check(r.rows and r.rows[1].name == 'Alice' and r.rows[1].id == 7, 'query → tableau de lignes, paramètres transmis')
    T:eq(r.waited, 5, 'latence de 5 ms : le fil reprend dès la réponse')
    T:eq(r.single and r.single.id, 8, 'single → première ligne')
    T:eq(r.scalar, 500, 'scalar → première colonne')
    T:eq(r.insert, 42, 'insert → insertId')
    T:eq(r.update, 3, 'update → affectedRows')
    T:eq(r.prepOne, 500, 'prepare : une ligne, une colonne → la valeur')
    T:eq(r.prepRow and r.prepRow.name, 'Alice', 'prepare : une ligne, plusieurs colonnes → la ligne')
    T:check(type(r.prepMany) == 'table' and #r.prepMany == 2 and r.prepMany[2].name == 'B', 'prepare : plusieurs lignes → les lignes')
    T:eq(r.prepNone, nil, 'prepare : aucune ligne → nil')
    T:eq(r.prepInsert, 42, 'prepare INSERT → insertId')
    T:same(r.prepBatch, { 42, 42 }, 'prepare avec plusieurs jeux de paramètres → une réponse par jeu')
    T:check(type(r.raw) == 'table' and r.raw[1].id == 3, 'rawExecute → résultat brut')
    T:eq(r.tx, true, 'transaction réussie → true')
    T:eq(r.txFail, false, 'transaction avec une erreur → false')
    T:check(r.errOk == false and tostring(r.err):find("doesn't exist", 1, true), 'erreur SQL simulée : .await lève l\'erreur')
    T:check(r.missOk == false and hasText(emu.errors, 'aucune réponse prévue pour la requête « SELECT inconnue »'), 'requête sans réponse : erreur claire dans emu.errors')
    T:eq(r.tooMany, false, 'trop de paramètres pour les « ? » : erreur comme oxmysql')
    T:check(r.argOk == false and tostring(r.argErr):find('First argument expected string', 1, true), 'mauvais type de requête : erreur de safeArgs')
    T:eq(r.cb, 9, 'forme avec callback')
    T:eq(r.cbRes, 'sql', 'callback exécuté dans la ressource appelante')
    T:eq(r.cbInsert, 42, 'insert avec callback')
    T:eq(r.export, 500, 'exports.oxmysql:scalar')
    T:eq(r.cbOnError, nil, 'erreur SQL avec callback : callback non appelé, erreur affichée')
    T:check(r.fetchAll and r.syncScalar == 500 and r.stored == 500, 'alias MySQL.Async / MySQL.Sync et requêtes stockées')
    T:eq(r.ready, true, 'MySQL.ready.await()')
    T:check(#db:queries('^INSERT') >= 4 and db.log[1].resource == 'sql', 'journal des requêtes (db.log, db:queries)')
end

-------------------------------------------------------------------------------
T:section('Mock ESX (inventaire ESX d\'origine)')
-------------------------------------------------------------------------------
do
    local emu = Emu.new()
    local esx = require('mocks.esx')(emu, {
        jobs = { police = { label = 'Police', grades = { [0] = { name = 'recrue', label = 'Recrue', salary = 20 }, [1] = { name = 'chef', label = 'Chef', salary = 80 } } } },
        items = { bread = { label = 'Pain', weight = 1 }, water = { label = 'Eau', weight = 1 } },
    })
    local events, r = {}, {}
    res(emu, 'jeu', function(env)
        local ESX = env.exports.es_extended:getSharedObject()
        env.AddEventHandler('esx:playerLoaded', function(id, xPlayer, isNew) events.loaded = { id = id, name = xPlayer.getName(), isNew = isNew } end)
        env.AddEventHandler('esx:playerDropped', function(id) events.dropped = id end)
        ESX.RegisterServerCallback('jeu:solde', function(source, cb, extra)
            cb(ESX.GetPlayerFromId(source).getMoney(), extra)
        end)
        ESX.RegisterUsableItem('bread', function(source) events.used = source end)
        ESX.RegisterCommand('donner', 'admin', function(xPlayer, args, showError)
            if args.montant > 1000 then return showError('trop') end
            args.cible.addMoney(args.montant)
        end, false, { help = 'donner', arguments = { { name = 'cible', type = 'player' }, { name = 'montant', type = 'number' } } })
    end, function(env, _, player)
        local ESX = env.exports.es_extended:getSharedObject()
        env.RegisterCommand('solde', function()
            ESX.TriggerServerCallback('jeu:solde', function(money, extra) r.cb = { money, extra } end, 'x')
            r.await = { ESX.AwaitServerCallback('jeu:solde', 'y') }
        end)
    end)
    local alice = emu:addPlayer({ name = 'Alice', esx = { accounts = { money = 500, bank = 1000 }, job = 'police', grade = 1, group = 'admin', inventory = { bread = 2 } } })
    local bob = emu:addPlayer({ name = 'Bob' })
    T:eq(esx:xPlayer(alice), nil, 'avant le chargement : pas encore de xPlayer')
    T:check(esx:waitLoaded(alice) and esx:waitLoaded(bob), 'esx:playerLoaded reçu par les clients')
    local xA, xB = esx:xPlayer(alice), esx:xPlayer(bob)
    T:check(events.loaded and events.loaded.isNew == false, 'esx:playerLoaded côté serveur (id, xPlayer, isNew)')
    T:check(emu.now >= 600, 'chargement après esx:onPlayerJoined (~600 ms + réseau), comme ESX', emu.now)
    T:eq(xA.getMoney(), 500, 'getMoney')
    T:eq(xA.getAccount('bank').money, 1000, 'getAccount(bank)')
    T:eq(xB.getAccount('bank').money, 50000, 'compte par défaut : StartingAccountMoney (bank 50000)')
    T:same(xA.getAccounts(true), { bank = 1000, black_money = 0, money = 500 }, 'getAccounts(true)')
    T:eq(xA.getIdentifier(), alice.identifiers[1]:gsub('license:', ''), 'getIdentifier = licence sans préfixe (ESX.GetIdentifier)')
    T:eq(esx.ESX.GetPlayerFromIdentifier(xA.getIdentifier()), xA, 'ESX.GetPlayerFromIdentifier')
    T:eq(#esx.ESX.GetExtendedPlayers(), 2, 'ESX.GetExtendedPlayers()')
    T:eq(#esx.ESX.GetExtendedPlayers('job', 'police'), 1, 'ESX.GetExtendedPlayers(\'job\', \'police\')')
    T:same(esx.ESX.GetPlayers(), { '1', '2' }, 'ESX.GetPlayers = GetPlayers')
    T:check(xA.getJob().name == 'police' and xA.getJob().grade_name == 'chef' and xA.getJob().onDuty == true, 'getJob (grade, onDuty)')
    T:eq(xA.getGroup(), 'admin', 'getGroup')
    xA.addMoney(50)
    xA.removeAccountMoney('money', 800)
    T:eq(xA.getMoney(), -250, 'removeAccountMoney ne vérifie pas le solde (1.12.4) : le compte devient négatif')
    T:eq(xA.removeAccountMoney('money', 1), nil, 'removeAccountMoney ne renvoie rien')
    T:check(not pcall(xA.removeAccountMoney, 'money', 0), 'removeAccountMoney avec un montant <= 0 : error')
    T:check(not pcall(xA.addAccountMoney, 'inconnu', 5), 'compte inconnu : error')
    T:eq(xA.getInventoryItem('bread').count, 2, 'getInventoryItem')
    xA.addInventoryItem('water', 3)
    xA.removeInventoryItem('bread', 5)
    T:eq(xA.getInventoryItem('bread').count, 2, 'removeInventoryItem sans assez d\'objets : rien ne change')
    xA.removeInventoryItem('bread', 1)
    T:check(xA.getInventoryItem('water').count == 3 and xA.getInventoryItem('bread').count == 1 and xA.getWeight() == 4, 'addInventoryItem / removeInventoryItem / poids')
    xA.setJob('police', 0)
    xB.setJob('pompier', 0)
    T:check(xA.getJob().grade_name == 'recrue' and xB.getJob().name == 'unemployed', 'setJob (métier inexistant ignoré)')
    xA.set('cle', 'valeur')
    xA.setMeta('stats', 'faim', 50)
    T:check(xA.get('cle') == 'valeur' and xA.getMeta('stats', 'faim') == 50, 'get/set, getMeta/setMeta')
    xA.showNotification('Bonjour', 'info')
    emu:run(1000)
    local cA = esx:clientESX(alice)
    T:check(cA.IsPlayerLoaded() and cA.GetPlayerData().job.grade_name == 'recrue', 'client : ESX.IsPlayerLoaded, PlayerData mis à jour par esx:setJob')
    T:eq(cA.GetAccount('money').money, -251, 'client : esx:setAccountMoney appliqué')
    T:eq(cA.GetPlayerData().metadata.stats.faim, 50, 'client : esx:updatePlayerData (métadonnées)')
    local n = alice:lastNotification('Bonjour')
    T:check(n and n.data.message == 'Bonjour' and n.data.type == 'info', 'xPlayer.showNotification → ESX.ShowNotification enregistrée chez le client')
    alice:command('solde')
    emu:run(1000)
    T:same(r.cb, { -251, 'x' }, 'ESX.TriggerServerCallback (aller-retour réseau)')
    T:same(r.await, { -251, 'y' }, 'ESX.AwaitServerCallback')
    esx:useItem(alice, 'bread')
    emu:run(200)
    T:eq(events.used, 1, 'objet utilisable : esx:useItem → ESX.UseItem')
    -- ESX.RegisterCommand : ACE par groupe (add_ace group.admin + add_principal du xPlayer)
    T:same({ bob:command('donner 1 10') }, { false, 'access_denied' }, 'ESX.RegisterCommand : groupe user refusé')
    T:same({ alice:command('donner 2 10') }, { true }, 'ESX.RegisterCommand : groupe admin accepté')
    alice:command('donner 2 5000')
    emu:run(300)
    T:eq(xB.getMoney(), 10, 'arguments typés (player, number) et rappel exécuté')
    T:check(alice:lastNotification('trop') ~= nil, 'showError → notification au joueur')
    xB.setGroup('admin')
    T:same({ bob:command('donner 2 1') }, { true }, 'setGroup : remove_principal / add_principal mis à jour')
    bob:drop()
    emu:run(10)
    T:check(events.dropped == 2 and esx:xPlayer(bob) == nil, 'déconnexion : esx:playerDropped et xPlayer retiré')
    T:eq(#emu.errors, 0, 'aucune erreur', emu.errors[1])
end

-------------------------------------------------------------------------------
T:section('Mock ox_inventory')
-------------------------------------------------------------------------------
do
    local emu = Emu.new()
    local inv = require('mocks.ox_inventory')(emu, { items = {
        water = { label = 'Eau', weight = 500 },
        phone = { label = 'Téléphone', weight = 190, stack = false },
        lingot = { label = 'Lingot', weight = 10000 },
    } })
    local hooks = {}
    res(emu, 'hooks', function(env)
        env.exports.ox_inventory:registerHook('createItem', function(payload)
            local m = payload.metadata
            m.serie = 'S' .. payload.count
            return m
        end, { itemFilter = { phone = true } })
        env.exports.ox_inventory:registerHook('swapItems', function(payload)
            hooks[#hooks + 1] = payload.action
            return payload.toInventory ~= 'coffre_interdit'
        end, { inventoryFilter = { '^coffre' } })
    end)
    local p = emu:addPlayer({ inventory = { water = 2 } })
    emu:run(100)
    local I = inv.Inventory
    T:eq(inv:count(p, 'water'), 2, 'inventaire initial (addPlayer{ inventory = … })')
    local ok, slot = I.AddItem(p.id, 'water', 3)
    T:check(ok and slot.count == 5 and slot.slot == 1, 'AddItem empile sur le même emplacement → success, response (emplacement)')
    I.AddItem(p.id, 'water', 1, { qualite = 'sale' })
    T:eq(#I.GetSlotsWithItem(p.id, 'water'), 2, 'métadonnées différentes : nouvel emplacement (table.matches)')
    local okPhone, phones = I.AddItem(p.id, 'phone', 2)
    T:check(okPhone and #phones == 2 and phones[1].count == 1, 'objet non empilable : un emplacement par unité')
    T:eq(phones[1].metadata.serie, 'S1', 'crochet createItem avec itemFilter : métadonnées modifiées')
    T:eq(I.GetItemCount(p.id, 'water'), 6, 'GetItemCount (toutes métadonnées)')
    T:eq(I.GetItemCount(p.id, 'water', { qualite = 'sale' }), 1, 'GetItemCount avec métadonnées')
    T:same({ I.RemoveItem(p.id, 'water', 10) }, { false, 'not_enough_items' }, 'RemoveItem : pas assez → false, not_enough_items')
    T:same({ I.RemoveItem(p.id, 'water', 0) }, { false, 'negative_count' }, 'RemoveItem : quantité <= 0')
    T:same({ I.RemoveItem(p.id, 'inconnu', 1) }, { false, 'invalid_item' }, 'RemoveItem : objet inconnu')
    T:same({ I.RemoveItem(p.id, 'water', 6, {}) }, { false, 'not_enough_items' }, 'RemoveItem strict par défaut : {} ne correspond qu\'aux objets sans métadonnées')
    T:same({ I.RemoveItem(p.id, 'water', 6, {}, nil, nil, false) }, { true }, 'RemoveItem strict = false : correspondance partielle')
    T:eq(I.GetItemCount(p.id, 'water'), 0, 'tout retiré')
    T:eq(I.Search(p.id, 'count', 'phone'), 2, "Search('count')")
    T:eq(#I.Search(p.id, 'slots', 'phone'), 2, "Search('slots')")
    T:check(I.GetSlotWithItem(p.id, 'phone').slot == phones[1].slot, 'GetSlotWithItem')
    T:check(#I.GetSlotsWithItem(p.id, 'phone', {}, true) == 0 and #I.GetSlotsWithItem(p.id, 'phone', {}) == 2,
        'GetSlotsWithItem : strict (table.matches) ou partiel (table.contains, qui compare les valeurs)')
    T:check(I.CanCarryItem(p.id, 'lingot', 2) and not I.CanCarryItem(p.id, 'lingot', 3), 'CanCarryItem : poids maximal 30000')
    I.SetMetadata(p.id, phones[1].slot, { serie = 'X' })
    T:eq(I.GetSlot(p.id, phones[1].slot).metadata.serie, 'X', 'SetMetadata / GetSlot')
    T:eq(inv:count(p, 'phone'), 2, 'aide de test inv:count')
    emu:run(200)
    T:eq(inv:clientCount(p, 'phone'), 2, 'copie client tenue à jour (ox_inventory:updateSlots)')
    local clientEnv = emu:env(p, 'hooks')
    T:eq(clientEnv.exports.ox_inventory:Search('count', 'phone'), 2, 'export client Search')
    -- coffres et crochet swapItems
    local senv = emu:env(nil, 'hooks')
    senv.exports.ox_inventory:RegisterStash('coffre_1', 'Coffre', 10, 50000)
    senv.exports.ox_inventory:RegisterStash('coffre_interdit', 'Coffre', 10, 50000)
    T:eq(I.AddItem('coffre_1', 'water', 4), true, 'RegisterStash : coffre créé au premier accès')
    local moved = inv:swap(p, { fromInventory = 'coffre_1', fromSlot = 1, toSlot = 10, count = 3 })
    T:check(moved and inv:count(p, 'water') == 3 and inv:count('coffre_1', 'water') == 1, 'déplacement coffre → joueur (action move)')
    local refused = inv:swap(p, { fromSlot = 10, toInventory = 'coffre_interdit', toSlot = 1, count = 1 })
    T:check(not refused and hooks[#hooks] == 'move' and #hooks == 2, 'crochet swapItems avec inventoryFilter : peut refuser')
    T:eq(#emu.errors, 0, 'aucune erreur', emu.errors[1])
end

-------------------------------------------------------------------------------
T:section('Mock ESX en mode ox_inventory')
-------------------------------------------------------------------------------
do
    local emu = Emu.new()
    local inv = require('mocks.ox_inventory')(emu, { items = { water = { label = 'Eau', weight = 500 } } })
    local esx = require('mocks.esx')(emu)
    local p = emu:addPlayer({ esx = { accounts = { money = 100 }, inventory = { water = 1 } } })
    esx:waitLoaded(p)
    local x = esx:xPlayer(p)
    T:eq(esx.Config.CustomInventory, 'ox', 'mock ox_inventory chargé avant ESX : Config.CustomInventory = "ox"')
    T:check(inv:count(p, 'money') == 100 and inv:count(p, 'water') == 1, 'argent ESX converti en objet « money » (convertInventory)')
    x.addMoney(20)
    T:eq(inv:count(p, 'money'), 120, 'addMoney ajoute aussi l\'objet money')
    inv.Inventory.RemoveItem(p.id, 'money', 70)
    T:eq(x.getMoney(), 50, 'retirer l\'objet money met à jour le compte (syncInventory)')
    x.removeAccountMoney('money', 0)
    T:eq(x.getMoney(), 50, 'mode ox : montant < 1 ignoré sans erreur (override oxinventory.lua)')
    local ok, slot = x.addInventoryItem('water', 2)
    T:check(ok and slot.count == 3 and x.getInventoryItem('water').count == 3, 'xPlayer.addInventoryItem → ox_inventory AddItem')
    T:eq(x.hasWeapon('WEAPON_PISTOL'), false, 'armes : fonctions vides du mode ox')
    T:eq(#emu.errors, 0, 'aucune erreur', emu.errors[1])
end

-------------------------------------------------------------------------------
T:section('Mock ox_target')
-------------------------------------------------------------------------------
do
    local emu = Emu.new()
    local esx = require('mocks.esx')(emu, { jobs = { police = { label = 'Police', grades = { [0] = { name = 'r', label = 'R' } } } } })
    local target = require('mocks.ox_target')(emu)
    local r = { selects = {} }
    res(emu, 'cible', function(env)
        env.RegisterNetEvent('cible:serveur', function(data) r.server = { src = env.source, name = data.name, entity = data.entity, onSelect = data.onSelect } end)
        env.RegisterCommand('cible_cmd', function(src) r.cmd = src end, false)
    end, function(env, _, player)
        local ox = env.exports.ox_target
        r.box = ox:addBoxZone({ name = 'comptoir', coords = env.vec3(10.0, 0.0, 30.0), size = env.vec3(2, 4, 2), rotation = 90, options = {
            { name = 'parler', label = 'Parler', onSelect = function(data) r.selects[#r.selects + 1] = { zone = data.zone, distance = data.distance, coords = data.coords } end },
            { name = 'loin', label = 'Loin', distance = 1.0, onSelect = function() r.loin = true end },
            { name = 'police', label = 'Police', groups = 'police', onSelect = function() r.police = true end },
            { name = 'verif', label = 'Vérif', canInteract = function(entity, distance, coords, name, bone)
                r.ci = { entity = entity, distance = distance, name = name, bone = bone, coords = coords }
                return false
            end, onSelect = function() r.verif = true end },
            { name = 'evt', label = 'Événement', event = 'cible:local' },
            { name = 'srv', label = 'Serveur', serverEvent = 'cible:serveur' },
            { name = 'cmd', label = 'Commande', command = 'cible_cmd' },
            { name = 'exp', label = 'Export', export = 'monExport' },
        } })
        r.sphere = ox:addSphereZone({ coords = env.vec3(-50.0, 0.0, 30.0), radius = 1.5, options = { label = 'Sphère', name = 'sphere', onSelect = function() r.sphereOk = true end } })
        r.poly = ox:addPolyZone({ name = 'poly', points = { env.vec3(0.0, 10.0, 30.0), env.vec3(4.0, 10.0, 30.0), env.vec3(4.0, 14.0, 30.0), env.vec3(0.0, 14.0, 30.0) },
            options = { { name = 'poly', label = 'Poly', onSelect = function() r.polyOk = true end } } })
        env.AddEventHandler('cible:local', function(data) r.event = data.name end)
        env.exports('monExport', function(data) r.export = data.name end)
        local obj = env.CreateObject(env.joaat('prop_atm_01'), 0.0, -3.0, 30.0, false)
        r.obj = obj
        ox:addModel('prop_atm_01', { name = 'atm', label = 'Distributeur', onSelect = function(data) r.atm = data.entity end })
        ox:addGlobalOption({ name = 'global', label = 'Global', onSelect = function() r.global = true end })
    end)
    local p = emu:addPlayer({ pos = { x = 8.0, y = 0.0, z = 30.0 }, esx = { job = 'unemployed' } })
    esx:waitLoaded(p)
    local ok, info = p:target('parler')
    T:check(ok and info.zone.id == r.box and math.abs(info.distance - 2.0) < 1e-9, 'option de zone boîte choisie, distance joueur → point visé')
    T:check(r.selects[1] and r.selects[1].zone == r.box and r.selects[1].distance == 2.0, 'onSelect reçoit la réponse d\'ox_target (zone, distance, coords)')
    local okLoin, why = p:target('loin')
    T:check(not okLoin and why:find('trop loin', 1, true), 'option.distance dépassée : refusée', why)
    T:check(not p:target('police'), 'groups = police : refusé pour un joueur sans ce métier')
    esx:xPlayer(p).setJob('police', 0)
    emu:run(200)
    T:check(p:target('police') and r.police, 'groups : accepté après setJob (métier ESX côté client)')
    T:check(not p:target('verif') and not r.verif, 'canInteract faux : option cachée')
    T:check(r.ci and r.ci.entity == 0 and r.ci.distance == 2.0 and r.ci.name == 'verif' and r.ci.bone == nil and r.ci.coords.x == 10.0,
        'canInteract(entity, distance, coords, name, bone)')
    p:target('evt')
    p:target('srv')
    p:target('cmd')
    p:target('exp')
    emu:run(200)
    T:eq(r.event, 'evt', 'action event : TriggerEvent local avec la réponse')
    T:check(r.server and r.server.src == 1 and r.server.name == 'srv' and r.server.entity == 0 and r.server.onSelect == nil,
        'action serverEvent : envoyé au serveur, sans les fonctions')
    T:eq(r.cmd, 1, 'action command : ExecuteCommand côté client → commande serveur')
    T:eq(r.export, 'exp', 'action export : exports[ressource][export](nil, réponse)')
    T:check(not p:target('sphere'), 'sphère trop loin (58 m) : hors de portée')
    p:setPosition(-49.0, 0.0, 30.0)
    T:check(p:target('sphere') and r.sphereOk, 'sphère : point visé dans le rayon')
    p:setPosition(2.0, 8.0, 30.0)
    T:check(p:target('poly') and r.polyOk, 'polygone')
    T:check(not p:target('parler', { coords = { x = 20.0, y = 0.0, z = 30.0 } }), 'point visé hors de la boîte : refusé')
    p:setPosition(0.0, 0.0, 30.0)
    T:check(p:target('atm', { entity = r.obj }) and r.atm == r.obj, 'addModel : option sur une entité visée (opts.entity)')
    T:check(p:target('global') and r.global, 'addGlobalOption')
    p:setPosition(8.0, 0.0, 30.0)
    T:check(target:select(p, 'parler'), 'target:select(joueur, filtre) = player:target(filtre)')
    local cenv = emu:env(p, 'cible')
    T:check(cenv.exports.ox_target:zoneExists('poly'), 'zoneExists(nom)')
    cenv.exports.ox_target:removeZone('poly')
    T:check(not cenv.exports.ox_target:zoneExists(r.poly), 'removeZone')
    cenv.exports.ox_target:disableTargeting(true)
    local okOff, whyOff = p:target('parler')
    T:check(not okOff and whyOff:find('désactivé', 1, true), 'disableTargeting(true)')
    emu:stop('cible')
    cenv = nil
    T:eq(next(target:zones(p)), nil, 'arrêt de la ressource : ses zones sont retirées')
    T:eq(#emu.errors, 0, 'aucune erreur', emu.errors[1])
end

local allOk = T:summary()
os.exit(allOk and 0 or 1)
