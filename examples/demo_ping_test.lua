-- examples/demo_ping_test.lua — test complet de la ressource demo_ping, sans joueur connecté.
-- Lancer depuis la racine du dépôt : lua5.4 examples/demo_ping_test.lua
local root = (arg and arg[0] or ''):match('^(.*)/examples/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
local Emu = require('fivem_emu')

local emu = Emu.new({ seed = 7 })
emu:loadResource(root .. '/examples/resources/demo_ping')
emu:start('demo_ping')

-- Trois joueurs avec des réseaux différents
local alice = emu:addPlayer({ name = 'Alice', rtt = 30, aces = { 'command.annonce' } })
local bob = emu:addPlayer({ name = 'Bob', rtt = 180, jitter = 60, loss = 0.2 })
local carol = emu:addPlayer({ name = 'Carol', rtt = 90, fps = 30 })
emu:run(500)

local T = Emu.tester('demo_ping')

-- /ping : le serveur répond, le client dessine un marqueur pendant 1 s
local t0 = emu.now
T:check(alice:command('ping'), '/ping accepté')
emu:run(2000)
local frames = alice:frames(t0)
T:eq(#frames, 60, 'Alice (60 i/s) dessine le marqueur sur 60 images')
T:eq(frames[1].draws[1].type, 1, 'marqueur de type 1 (cylindre)')
carol:command('ping')
emu:run(2000)
T:eq(#carol:frames(), 30, 'Carol (30 i/s) dessine 30 images pour la même seconde')

-- /annonce : réservée à l'ACE command.annonce
T:same({ bob:command('annonce piratage') }, { false, 'access_denied' }, 'Bob sans ACE : /annonce refusée')
T:check(alice:command('annonce Ouverture du serveur'), 'Alice avec ACE : /annonce acceptée')
emu:run(1000)
for _, p in ipairs({ alice, bob, carol }) do
    T:check(p:lastNotification('Ouverture du serveur') ~= nil, ('%s reçoit l\'annonce'):format(p.name))
end

-- hello : anti-spam de 2 s par joueur côté serveur
bob:clientCommand('hello coucou')
bob:clientCommand('hello encore')
emu:run(2000)
T:check(bob:lastNotification('cooldown') ~= nil, 'deuxième hello de Bob trop rapide : refusé (cooldown)')
T:check(alice:lastNotification('Bob') ~= nil, 'premier hello de Bob : bienvenue envoyée à tous')

-- lib.callback : heure du serveur
carol:clientCommand('heure')
emu:run(1000)
T:check(carol.side.log[#carol.side.log]:find('je suis Carol', 1, true) ~= nil, 'callback ox_lib : le serveur répond à Carol')

-- Départ d'un joueur : l'anti-spam l'oublie, plus rien ne lui est envoyé
bob:drop('fin du test')
alice:command('annonce Au revoir')
emu:run(1000)
T:check(bob:lastNotification('Au revoir') == nil, 'Bob déconnecté ne reçoit plus rien')
T:eq(#emu.errors, 0, 'aucune erreur')

print()
print(emu:report())
print()
os.exit(T:summary() and 0 or 1)
