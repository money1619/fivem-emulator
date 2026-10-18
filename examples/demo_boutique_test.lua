-- examples/demo_boutique_test.lua — boutique testée avec les mocks ESX, oxmysql, ox_inventory et ox_target.
-- Lancer depuis la racine du dépôt : lua5.4 examples/demo_boutique_test.lua
local root = (arg and arg[0] or ''):match('^(.*)/examples/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
local Emu = require('fivem_emu')

local emu = Emu.new()
local db = require('mocks.oxmysql')(emu, { latency = 4 })
-- ox_inventory avant ESX : ESX passe en mode « ox » comme sur un vrai serveur
local inv = require('mocks.ox_inventory')(emu, { items = {
    water = { label = 'Eau', weight = 500 },
    bread = { label = 'Pain', weight = 200 },
} })
local esx = require('mocks.esx')(emu, { jobs = { police = { label = 'Police', grades = { [0] = { name = 'agent', label = 'Agent' } } } } })
local target = require('mocks.ox_target')(emu)

-- Base simulée : une table de ventes en mémoire
local ventes = {}
db:on('^INSERT INTO boutique_ventes', function(_, p)
    ventes[#ventes + 1] = { identifier = p[1], item = p[2], count = p[3], price = p[4] }
    return { insertId = #ventes, affectedRows = 1 }
end)
db:on('^SELECT item, count, price FROM boutique_ventes', function(_, p)
    local rows = {}
    for _, v in ipairs(ventes) do if v.identifier == p[1] then rows[#rows + 1] = v end end
    return rows
end)

emu:loadResource(root .. '/examples/resources/demo_boutique')
emu:start('demo_boutique')

local alice = emu:addPlayer({ name = 'Alice', rtt = 40, pos = { x = 25.0, y = -1346.0, z = 29.5 },
                              esx = { accounts = { money = 30 }, job = 'police' } })
local bob = emu:addPlayer({ name = 'Bob', rtt = 150, pos = { x = 60.0, y = -1346.0, z = 29.5 },
                            esx = { accounts = { money = 100 } } })
esx:waitLoaded(alice)
esx:waitLoaded(bob)

local T = Emu.tester('demo_boutique')
T:eq(esx:xPlayer(alice).getMoney(), 30, 'Alice a 30 $')
T:eq(inv:count(alice, 'money'), 30, 'en mode ox, l\'argent est aussi l\'objet « money »')

-- Achats par ox_target : onSelect (eau) puis serverEvent (pain)
T:check(alice:target('boutique:eau'), 'Alice vise le comptoir : option « eau » disponible')
emu:run(500)
T:check(alice:target('boutique:pain'), 'option « pain » (serverEvent) disponible')
emu:run(500)
T:eq(inv:count(alice, 'water'), 1, 'Alice reçoit 1 eau')
T:eq(inv:count(alice, 'bread'), 1, 'Alice reçoit 1 pain')
T:eq(esx:xPlayer(alice).getMoney(), 5, '10 $ + 15 $ débités')
T:eq(inv:clientCount(alice, 'water'), 1, 'le client d\'Alice voit l\'eau dans son inventaire')

-- Plus assez d'argent : refus propre, rien n'est retiré
alice:target('boutique:eau')
emu:run(500)
T:check(alice:lastNotification("Pas assez d'argent") ~= nil, 'troisième achat refusé faute d\'argent')
T:eq(esx:xPlayer(alice).getMoney(), 5, 'argent inchangé après le refus')

-- Bob est trop loin pour viser le comptoir, et le serveur refuse aussi un événement envoyé à la main
local ok, why = bob:target('boutique:eau')
T:check(not ok, 'Bob (34 m) ne peut pas viser le comptoir', why)
emu:env(bob, 'demo_boutique').TriggerServerEvent('boutique:acheter', 'water', 1)
emu:run(1000)
T:check(bob:lastNotification('Trop loin du comptoir') ~= nil, 'triche de Bob (événement direct) refusée par le serveur')
T:eq(esx:xPlayer(bob).getMoney(), 100, 'Bob garde ses 100 $')

-- Option réservée à la police
T:check(alice:target('boutique:inventaire'), 'Alice (police) voit « Contrôler le stock »')
bob:setPosition(25.0, -1346.0, 29.5)
T:check(not bob:target('boutique:inventaire'), 'Bob (sans métier) ne la voit pas')

-- Historique via lib.callback + oxmysql
alice:command('historique')
emu:run(1000)
T:eq(alice.side.log[#alice.side.log], '2 achat(s) en base', 'historique lu en base par lib.callback')
T:eq(#db:queries('^INSERT'), 2, 'deux ventes enregistrées')
T:eq(#emu.errors, 0, 'aucune erreur')

print()
print(emu:report())
print()
os.exit(T:summary() and 0 or 1)
