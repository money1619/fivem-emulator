-- examples/demo_audit_test.lua — audit anti-triche (emu:fuzz) d'une ressource volontairement mal protégée.
-- Lancer depuis la racine du dépôt : lua5.4 examples/demo_audit_test.lua
local root = (arg and arg[0] or ''):match('^(.*)/examples/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
local Emu = require('fivem_emu')

local emu = Emu.new()
local db = require('mocks.oxmysql')(emu)
local esx = require('mocks.esx')(emu)
db:on('^INSERT INTO faille_journal', { insertId = 1, affectedRows = 1 })

emu:loadResource(root .. '/examples/resources/demo_faille')
emu:start('demo_faille')

local alice = emu:addPlayer({ name = 'Alice', esx = { accounts = { bank = 1000 } } })
local bob = emu:addPlayer({ name = 'Bob', esx = { accounts = { bank = 1000 } } })
esx:waitLoaded(alice)
esx:waitLoaded(bob)

-- Trafic normal : c'est lui que l'audit rejoue et modifie
local client = emu:env(alice, 'demo_faille')
client.TriggerServerEvent('faille:recompense')
client.TriggerServerEvent('faille:virement', bob.id, 50)
client.TriggerServerEvent('faille:journal', 'bonjour')
client.TriggerServerEvent('faille:don', 10)
emu:run(1000)

local T = Emu.tester('demo_audit')
T:eq(esx:xPlayer(alice).getAccount('bank').money, 1000 + 100 - 50 - 10, 'trafic normal : 1000 + 100 - 50 - 10')

local audit = emu:fuzz()
print(audit:text())
print()

local function found(event, kind)
    for _, f in ipairs(audit.findings) do
        if f.event == event and f.kind:find(kind, 1, true) then return true end
    end
    return false
end
T:check(found('faille:recompense', 'anti-spam'), 'récompense : pas d\'anti-spam')
T:check(found('faille:recompense', 'distance'), 'récompense : aucun contrôle de distance')
T:check(found('faille:virement', 'gain (argument 2)'), 'virement : montant négatif = gain')
T:check(found('faille:virement', 'perte pour un autre joueur'), 'virement : Bob perd de l\'argent')
T:check(found('faille:journal', 'injection SQL'), 'journal : injection SQL')
local donOk = true
for _, f in ipairs(audit.findings) do if f.event == 'faille:don' and f.severity ~= 'info' then donOk = false end end
T:check(donOk, 'don (bien protégé) : rien de grave')
T:eq(#emu.errors, 0, 'les erreurs provoquées par l\'audit restent dans le résultat', emu.errors[1])
os.exit(T:summary() and 0 or 1)
