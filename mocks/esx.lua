-- mocks/esx.lua — es_extended 1.12.4 simulé (serveur et client), recopié des sources de la version installée.
--
--   local esx = require('mocks.esx')(emu, {
--       jobs = { police = { label = 'Police', grades = { [0] = { name = 'recruit', label = 'Recrue', salary = 20 } } } },
--       items = { bread = { label = 'Pain', weight = 1 } },  -- inventaire ESX d'origine (sans ox_inventory)
--   })
--   local p = emu:addPlayer({ name = 'Alice', esx = { accounts = { money = 500 }, job = 'police', grade = 0, group = 'admin' } })
--   esx:waitLoaded(p)
--
-- Connexion comme ESX sans multipersonnage : le client envoie esx:onPlayerJoined (après ~600 ms), le serveur crée
-- le xPlayer, déclenche esx:playerLoaded côté serveur (TriggerEvent) puis l'envoie au client par le réseau.
-- Options par joueur (addPlayer{ esx = {...} }) : identifier, accounts = { money, bank, black_money }, job, grade,
-- group ('user'), inventory = { nom = nombre } (ou liste ox), metadata, firstName, lastName, coords, isNew.
-- Mode « ox » : si le mock ox_inventory est chargé avant ESX (ou opts.oxInventory = true), comme
-- Config.CustomInventory = "ox" : les méthodes du xPlayer sont celles de server/classes/overrides/oxinventory.lua.
-- Non simulé : base de données (les joueurs viennent des options), paie automatique, armes en mode ESX d'origine
-- (Config.Weapons), state bags, menus ESX.UI, ESX.Game. Les messages d'erreur d'ESX restent en anglais.
local unpack = table.unpack

local LOCALE = {
    commanderror_argumentmismatch = 'Invalid Argument Count (passed %s, wanted %s)',
    commanderror_argumentmismatch_number = 'Invalid Argument #%s data type (passed string, wanted number)',
    commanderror_argumentmismatch_string = 'Invalid Argument #%s data type (passed number, wanted string)',
    commanderror_invaliditem = 'Invalid item',
    commanderror_invalidweapon = 'Invalid weapon',
    commanderror_console = 'Command Cannot be executed from console',
    commanderror_invalidplayerid = 'Specified Player is not online',
    act_imp = 'Cannot Perform Action',
}
local function TranslateCap(key, ...) return (LOCALE[key] or key):format(...) end

-- Fonctions partagées d'ESX (shared/modules/math.lua, table.lua, shared/functions.lua)
local function sharedFunctions(ESX, Config)
    ESX.Math = {}
    function ESX.Math.Round(value, numDecimalPlaces)
        if numDecimalPlaces then
            local power = 10 ^ numDecimalPlaces
            return math.floor((value * power) + 0.5) / power
        else
            return math.floor(value + 0.5)
        end
    end
    function ESX.Math.Trim(value) return (string.gsub(tostring(value), '^%s*(.-)%s*$', '%1')) end
    ESX.Table = {}
    function ESX.Table.SizeOf(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
    function ESX.Table.ToArray(t) local a = {} for _, v in pairs(t) do a[#a + 1] = v end return a end
    function ESX.Round(value, numDecimalPlaces) return ESX.Math.Round(value, numDecimalPlaces) end
    function ESX.GetConfig() return Config end
    function ESX.IsFunctionReference(val)
        local mt = type(val) == 'table' and getmetatable(val)
        return type(val) == 'function' or (mt and type(mt.__call) == 'function') or false
    end
end

return function(emu, opts)
    opts = opts or {}
    local mock = { client = {} }
    emu.mocks.esx = mock

    -- Métiers : { nom = { label, grades = { [0] = { name, label, salary } } } } ; « unemployed » existe toujours
    local function buildJobs()
        local jobs = {
            unemployed = { name = 'unemployed', label = 'Unemployed',
                           grades = { ['0'] = { job_name = 'unemployed', grade = 0, name = 'unemployed', label = 'Unemployed', salary = 200 } } },
        }
        for name, j in pairs(opts.jobs or {}) do
            local grades = {}
            for g, data in pairs(j.grades or {}) do
                local grade = tonumber(g)
                grades[tostring(grade)] = { job_name = name, grade = grade, name = data.name or tostring(grade),
                                            label = data.label or data.name or tostring(grade), salary = data.salary or 0,
                                            skin_male = data.skin_male, skin_female = data.skin_female }
            end
            jobs[name] = { id = j.id, name = name, label = j.label or name, whitelisted = j.whitelisted, grades = grades }
        end
        return jobs
    end

    local function makeConfig(ox)
        return {
            CustomInventory = ox and 'ox' or false,
            OxInventory = ox,
            Accounts = opts.accounts or {
                bank = { label = 'Bank', round = true },
                black_money = { label = 'Dirty Money', round = true },
                money = { label = 'Cash', round = true },
            },
            StartingAccountMoney = opts.startingAccountMoney or { bank = 50000 },
            DefaultSpawns = { { x = 222.2027, y = -864.0162, z = 30.2922, heading = 1.0 } },
            AdminGroups = { owner = true, admin = true },
            MaxWeight = opts.maxWeight or 120,
            EnableDebug = false,
            DefaultJobDuty = true,
            Multichar = false,
            EnableDefaultInventory = not ox,
        }
    end

    ---------------------------------------------------------------------------
    -- Serveur
    ---------------------------------------------------------------------------
    local function server(env)
        local ox = opts.oxInventory
        if ox == nil then ox = emu.mocks.ox_inventory ~= nil end
        local Config = makeConfig(ox)
        local ESX, Core = {}, { PlayerFunctionOverrides = {}, UsableItemsCallbacks = {}, RegisteredCommands = {},
                                playersByIdentifier = {}, JobsPlayerCount = {} }
        mock.ESX, mock.Core, mock.Config, mock.ox = ESX, Core, Config, ox
        sharedFunctions(ESX, Config)
        ESX.Players, ESX.Jobs, ESX.Items = {}, buildJobs(), {}

        local TriggerClientEvent, TriggerEvent, print = env.TriggerClientEvent, env.TriggerEvent, env.print
        local ExecuteCommand, GetPlayerPed, DropPlayer = env.ExecuteCommand, env.GetPlayerPed, env.DropPlayer
        local GetInvokingResource, json = env.GetInvokingResource, env.json
        local function Inventory()
            local inv = emu.mocks.ox_inventory
            if not inv then error('mode ox d\'ESX sans le mock ox_inventory (require(\'mocks.ox_inventory\'))', 3) end
            return inv.Inventory
        end
        -- GetInvokingResource côté ESX : ressource qui appelle la fonction (export ou fil en cours)
        local function invokingResource() return GetInvokingResource() or emu:callerResource(emu.server) end

        if not ox then
            for name, item in pairs(opts.items or {}) do
                ESX.Items[name] = { name = name, label = item.label or name, weight = item.weight or 1,
                                    rare = item.rare or false, canRemove = item.canRemove ~= false }
            end
        else
            -- server/bridge/inventory/oxinventory.lua : ESX.Items = liste d'ox_inventory
            ESX.Items = emu.mocks.ox_inventory and emu.mocks.ox_inventory.items or {}
            function ESX.GetItemLabel(item)
                item = env.exports.ox_inventory:Items(item)
                if item then return item.label end
            end
        end

        env.exports('getSharedObject', function() return ESX end)
        env.AddEventHandler('esx:getSharedObject', function(cb)
            if ESX.IsFunctionReference(cb) then cb(ESX) end
            print(('^3[WARNING]^0 Resource ^5%s^0 used the ^5getSharedObject^0 event.'):format(tostring(GetInvokingResource())))
        end)

        -- server/functions.lua
        function ESX.Trace(msg) if Config.EnableDebug then print(('[^2TRACE^7] %s^7'):format(msg)) end end
        function ESX.TriggerClientEvent(eventName, playerIds, ...)
            if type(playerIds) == 'number' then
                TriggerClientEvent(eventName, playerIds, ...)
                return
            end
            for i = 1, #playerIds do TriggerClientEvent(eventName, playerIds[i], ...) end
        end
        ESX.GetPlayers = env.GetPlayers
        local function checkTable(key, val, xPlayer, xPlayers)
            for valIndex = 1, #val do
                local value = val[valIndex]
                if not xPlayers[value] then xPlayers[value] = {} end
                if (key == 'job' and xPlayer.job.name == value) or xPlayer[key] == value then
                    xPlayers[value][#xPlayers[value] + 1] = xPlayer
                end
            end
        end
        function ESX.GetExtendedPlayers(key, val)
            if not key then return ESX.Table.ToArray(ESX.Players) end
            local xPlayers = {}
            if type(val) == 'table' then
                for _, xPlayer in pairs(ESX.Players) do checkTable(key, val, xPlayer, xPlayers) end
                return xPlayers
            end
            for _, xPlayer in pairs(ESX.Players) do
                if (key == 'job' and xPlayer.job.name == val) or xPlayer[key] == val then xPlayers[#xPlayers + 1] = xPlayer end
            end
            return xPlayers
        end
        function ESX.GetNumPlayers(key, val)
            if not key then return #env.GetPlayers() end
            if type(val) == 'table' then
                local numPlayers = {}
                if key == 'job' then
                    for _, v in ipairs(val) do numPlayers[v] = (Core.JobsPlayerCount[v] or 0) end
                    return numPlayers
                end
                for i, v in pairs(ESX.GetExtendedPlayers(key, val)) do numPlayers[i] = (#v or 0) end
                return numPlayers
            end
            if key == 'job' then return (Core.JobsPlayerCount[val] or 0) end
            return #ESX.GetExtendedPlayers(key, val)
        end
        function ESX.GetPlayerFromId(source) return ESX.Players[tonumber(source)] end
        function ESX.GetPlayerFromIdentifier(identifier) return Core.playersByIdentifier[identifier] end
        function ESX.GetIdentifier(playerId)
            local identifier = env.GetPlayerIdentifierByType(tostring(playerId), 'license')
            return identifier and identifier:gsub('license:', '')
        end
        function ESX.RegisterUsableItem(item, cb) Core.UsableItemsCallbacks[item] = cb end
        function ESX.UseItem(source, item, ...)
            if ESX.Items[item] then
                local itemCallback = Core.UsableItemsCallbacks[item]
                if itemCallback then
                    local success, result = pcall(itemCallback, source, item, ...)
                    if not success then
                        return result and print(result) or print(('[^3WARNING^7] An error occured when using item ^5"%s"^7! This was not caused by ESX.'):format(item))
                    end
                end
            else
                print(('[^3WARNING^7] Item ^5"%s"^7 was used but does not exist!'):format(item))
            end
        end
        if not ox then
            function ESX.GetItemLabel(item)
                if ESX.Items[item] then return ESX.Items[item].label end
                print(('[^3WARNING^7] Attemting to get invalid Item -> ^5%s^7'):format(item))
            end
        end
        function ESX.GetJobs() return ESX.Jobs end
        function ESX.GetItems() return ESX.Items end
        function ESX.GetUsableItems()
            local usables = {}
            for k in pairs(Core.UsableItemsCallbacks) do usables[k] = true end
            return usables
        end
        function ESX.DoesJobExist(job, grade)
            return (ESX.Jobs[job] and ESX.Jobs[job].grades[tostring(grade)] ~= nil) or false
        end
        function Core.IsPlayerAdmin(playerId)
            playerId = tostring(playerId)
            if env.IsPlayerAceAllowed(playerId, 'command') or env.GetConvar('sv_lan', '') == 'true' then return true end
            local xPlayer = ESX.Players[playerId]
            return (xPlayer and Config.AdminGroups[xPlayer.group] and true) or false
        end

        -- ESX.RegisterCommand : commande restreinte + add_ace group.<groupe> command.<nom> allow
        function ESX.RegisterCommand(name, group, cb, allowConsole, suggestion)
            if type(name) == 'table' then
                for _, v in ipairs(name) do ESX.RegisterCommand(v, group, cb, allowConsole, suggestion) end
                return
            end
            if Core.RegisteredCommands[name] then
                print(('[^3WARNING^7] Command ^5"%s" ^7already registered, overriding command'):format(name))
                if Core.RegisteredCommands[name].suggestion then TriggerClientEvent('chat:removeSuggestion', -1, ('/%s'):format(name)) end
            end
            if suggestion then
                if not suggestion.arguments then suggestion.arguments = {} end
                if not suggestion.help then suggestion.help = '' end
                TriggerClientEvent('chat:addSuggestion', -1, ('/%s'):format(name), suggestion.help, suggestion.arguments)
            end
            Core.RegisteredCommands[name] = { group = group, cb = cb, allowConsole = allowConsole, suggestion = suggestion }
            env.RegisterCommand(name, function(playerId, args)
                local command = Core.RegisteredCommands[name]
                if not command.allowConsole and playerId == 0 then
                    print(('[^3WARNING^7] ^5%s'):format(TranslateCap('commanderror_console')))
                    return
                end
                local xPlayer, err = ESX.Players[playerId], nil
                if command.suggestion then
                    if command.suggestion.validate and #args ~= #command.suggestion.arguments then
                        err = TranslateCap('commanderror_argumentmismatch', #args, #command.suggestion.arguments)
                    end
                    if not err and command.suggestion.arguments then
                        local newArgs = {}
                        for k, v in ipairs(command.suggestion.arguments) do
                            if v.type then
                                if v.type == 'number' then
                                    local newArg = tonumber(args[k])
                                    if newArg then newArgs[v.name] = newArg else err = TranslateCap('commanderror_argumentmismatch_number', k) end
                                elseif v.type == 'player' or v.type == 'playerId' then
                                    local targetPlayer = tonumber(args[k])
                                    if args[k] == 'me' then targetPlayer = playerId end
                                    if targetPlayer then
                                        local xTargetPlayer = ESX.GetPlayerFromId(targetPlayer)
                                        if xTargetPlayer then
                                            newArgs[v.name] = v.type == 'player' and xTargetPlayer or targetPlayer
                                        else
                                            err = TranslateCap('commanderror_invalidplayerid')
                                        end
                                    else
                                        err = TranslateCap('commanderror_argumentmismatch_number', k)
                                    end
                                elseif v.type == 'string' then
                                    if not tonumber(args[k]) then newArgs[v.name] = args[k] else err = TranslateCap('commanderror_argumentmismatch_string', k) end
                                elseif v.type == 'item' then
                                    if ESX.Items[args[k]] then newArgs[v.name] = args[k] else err = TranslateCap('commanderror_invaliditem') end
                                elseif v.type == 'any' then
                                    newArgs[v.name] = args[k]
                                elseif v.type == 'merge' then
                                    local length = 0
                                    for i = 1, k - 1 do length = length + string.len(args[i]) + 1 end
                                    newArgs[v.name] = string.sub(table.concat(args, ' '), length)
                                elseif v.type == 'coordinate' then
                                    local coord = tonumber(tostring(args[k]):match('(-?%d+%.?%d*)'))
                                    if coord then newArgs[v.name] = coord else err = TranslateCap('commanderror_argumentmismatch_number', k) end
                                end
                            end
                            if v.validate ~= nil and not v.validate then err = nil end
                            if err then break end
                        end
                        args = newArgs
                    end
                end
                if err then
                    if playerId == 0 then print(('[^3WARNING^7] %s^7'):format(err)) else xPlayer.showNotification(err) end
                else
                    cb(xPlayer or false, args, function(msg)
                        if playerId == 0 then print(('[^3WARNING^7] %s^7'):format(msg)) else xPlayer.showNotification(msg) end
                    end)
                end
            end, true)
            for _, g in ipairs(type(group) == 'table' and group or { group }) do
                ExecuteCommand(('add_ace group.%s command.%s allow'):format(g, name))
            end
        end

        -- server/modules/callback.lua
        local Callbacks = { requests = {}, storage = {}, id = 0 }
        function Callbacks:Register(name, resource, cb) self.storage[name] = { resource = resource, cb = cb } end
        function Callbacks:Execute(cb, ...)
            local success, errorString = pcall(cb, ...)
            if not success then
                print(('[^1ERROR^7] Failed to execute Callback with RequestId: ^5%s^7'):format(self.currentId))
                error(errorString)
            end
            self.currentId = nil
        end
        function Callbacks:Trigger(player, event, cb, invoker, ...)
            self.requests[self.id] = cb
            TriggerClientEvent('esx:triggerClientCallback', player, event, self.id, invoker, ...)
            self.id = self.id + 1
        end
        function Callbacks:ServerRecieve(player, event, requestId, invoker, ...)
            self.currentId = requestId
            if not self.storage[event] then
                return error(('Server Callback with requestId ^5%s^1 Was Called by ^5%s^1 but does not exist.'):format(event, invoker))
            end
            local returnCb = function(...) TriggerClientEvent('esx:serverCallback', player, requestId, invoker, ...) end
            self:Execute(self.storage[event].cb, player, returnCb, ...)
        end
        function Callbacks:RecieveClient(requestId, invoker, ...)
            self.currentId = requestId
            if not self.requests[self.currentId] then
                return error(('Client Callback with requestId ^5%s^1 Was Called by ^5%s^1 but does not exist.'):format(self.currentId, invoker))
            end
            self:Execute(self.requests[self.currentId], ...)
            self.requests[requestId] = nil
        end
        function ESX.TriggerClientCallback(player, eventName, callback, ...)
            local r = invokingResource()
            Callbacks:Trigger(player, eventName, callback, (r and r ~= 'Unknown') and r or 'es_extended', ...)
        end
        function ESX.RegisterServerCallback(eventName, callback)
            local r = invokingResource()
            Callbacks:Register(eventName, (r and r ~= 'Unknown') and r or 'es_extended', callback)
        end
        function ESX.DoesServerCallbackExist(eventName) return Callbacks.storage[eventName] ~= nil end
        env.RegisterNetEvent('esx:clientCallback', function(requestId, invoker, ...) Callbacks:RecieveClient(requestId, invoker, ...) end)
        env.RegisterNetEvent('esx:triggerServerCallback', function(eventName, requestId, invoker, ...)
            local source = env.source
            Callbacks:ServerRecieve(source, eventName, requestId, invoker, ...)
        end)
        env.AddEventHandler('onResourceStop', function(resource)
            for k, v in pairs(Callbacks.storage) do if v.resource == resource then Callbacks.storage[k] = nil end end
        end)
        mock.callbacks = Callbacks

        -- server/classes/player.lua (Player(src).state non simulé)
        local function CreateExtendedPlayer(playerId, identifier, group, accounts, inventory, weight, job, loadout, name, coords, metadata)
            local self = {}
            self.accounts = accounts
            self.coords = coords
            self.group = group
            self.identifier = identifier
            self.inventory = inventory
            self.job = job
            self.loadout = loadout
            self.name = name
            self.playerId = playerId
            self.source = playerId
            self.variables = {}
            self.weight = weight
            self.maxWeight = Config.MaxWeight
            self.metadata = metadata
            self.lastPlaytime = self.metadata.lastPlaytime or 0
            self.paycheckEnabled = true
            self.admin = Core.IsPlayerAdmin(playerId)
            self.license = ('license:%s'):format(identifier)
            if type(self.metadata.jobDuty) ~= 'boolean' then
                self.metadata.jobDuty = self.job.name ~= 'unemployed' and Config.DefaultJobDuty or false
            end
            job.onDuty = self.metadata.jobDuty
            ExecuteCommand(('add_principal identifier.%s group.%s'):format(self.license, self.group))

            function self.triggerEvent(eventName, ...)
                assert(type(eventName) == 'string', 'eventName should be string!')
                TriggerClientEvent(eventName, self.source, ...)
            end
            function self.togglePaycheck(toggle) self.paycheckEnabled = toggle end
            function self.isPaycheckEnabled() return self.paycheckEnabled end
            function self.setCoords(coordinates)
                local ped = GetPlayerPed(self.source)
                env.SetEntityCoords(ped, coordinates.x, coordinates.y, coordinates.z, false, false, false, false)
                env.SetEntityHeading(ped, coordinates.w or coordinates.heading or 0.0)
            end
            function self.getCoords(vector, heading)
                local ped = GetPlayerPed(self.source)
                local entityCoords = env.GetEntityCoords(ped)
                local entityHeading = env.GetEntityHeading(ped)
                local coordinates = { x = entityCoords.x, y = entityCoords.y, z = entityCoords.z }
                if vector then
                    coordinates = (heading and env.vector4(entityCoords.x, entityCoords.y, entityCoords.z, entityHeading) or entityCoords)
                elseif heading then
                    coordinates.heading = entityHeading
                end
                return coordinates
            end
            function self.kick(reason) DropPlayer(tostring(self.source), reason) end
            function self.getPlayTime()
                local p = emu.players[self.source]
                return self.lastPlaytime + (p and math.floor((emu.now - p.joinedAt) / 1000) or 0)
            end
            function self.setMoney(money)
                assert(type(money) == 'number', 'money should be number!')
                money = ESX.Math.Round(money)
                self.setAccountMoney('money', money)
            end
            function self.getMoney() return self.getAccount('money').money end
            function self.addMoney(money, reason)
                money = ESX.Math.Round(money)
                self.addAccountMoney('money', money, reason)
            end
            function self.removeMoney(money, reason)
                money = ESX.Math.Round(money)
                self.removeAccountMoney('money', money, reason)
            end
            function self.getIdentifier() return self.identifier end
            function self.setGroup(newGroup)
                local lastGroup = self.group
                ExecuteCommand(('remove_principal identifier.%s group.%s'):format(self.license, self.group))
                self.group = newGroup
                TriggerEvent('esx:setGroup', self.source, self.group, lastGroup)
                self.triggerEvent('esx:setGroup', self.group, lastGroup)
                ExecuteCommand(('add_principal identifier.%s group.%s'):format(self.license, self.group))
            end
            function self.getGroup() return self.group end
            function self.set(k, v) self.variables[k] = v end
            function self.get(k) return self.variables[k] end
            function self.getAccounts(minimal)
                if not minimal then return self.accounts end
                local minimalAccounts = {}
                for i = 1, #self.accounts do minimalAccounts[self.accounts[i].name] = self.accounts[i].money end
                return minimalAccounts
            end
            function self.getAccount(account)
                account = string.lower(account)
                for i = 1, #self.accounts do
                    if string.lower(self.accounts[i].name) == account then return self.accounts[i] end
                end
                return nil
            end
            function self.getInventory(minimal)
                if minimal then
                    local minimalInventory = {}
                    for _, v in ipairs(self.inventory) do
                        if v.count > 0 then minimalInventory[v.name] = v.count end
                    end
                    return minimalInventory
                end
                return self.inventory
            end
            function self.getJob() return self.job end
            function self.getLoadout(minimal)
                if not minimal then return self.loadout end
                local minimalLoadout = {}
                for _, v in ipairs(self.loadout) do minimalLoadout[v.name] = { ammo = v.ammo } end
                return minimalLoadout
            end
            function self.getName() return self.name end
            function self.setName(newName) self.name = newName end
            function self.setAccountMoney(accountName, money, reason)
                reason = reason or 'unknown'
                if not tonumber(money) then
                    error(('Tried To Set Account ^5%s^1 For Player ^5%s^1 To An Invalid Number -> ^5%s^1'):format(accountName, self.playerId, money))
                    return
                end
                if money >= 0 then
                    local account = self.getAccount(accountName)
                    if account then
                        money = account.round and ESX.Math.Round(money) or money
                        self.accounts[account.index].money = money
                        self.triggerEvent('esx:setAccountMoney', account)
                        TriggerEvent('esx:setAccountMoney', self.source, accountName, money, reason)
                    else
                        error(('Tried To Set Invalid Account ^5%s^1 For Player ^5%s^1!'):format(accountName, self.playerId))
                    end
                else
                    error(('Tried To Set Account ^5%s^1 For Player ^5%s^1 To An Invalid Number -> ^5%s^1'):format(accountName, self.playerId, money))
                end
            end
            function self.addAccountMoney(accountName, money, reason)
                reason = reason or 'Unknown'
                if not tonumber(money) then
                    error(('Tried To Set Account ^5%s^1 For Player ^5%s^1 To An Invalid Number -> ^5%s^1'):format(accountName, self.playerId, money))
                    return
                end
                if money > 0 then
                    local account = self.getAccount(accountName)
                    if account then
                        money = account.round and ESX.Math.Round(money) or money
                        self.accounts[account.index].money = self.accounts[account.index].money + money
                        self.triggerEvent('esx:setAccountMoney', account)
                        TriggerEvent('esx:addAccountMoney', self.source, accountName, money, reason)
                    else
                        error(('Tried To Set Add To Invalid Account ^5%s^1 For Player ^5%s^1!'):format(accountName, self.playerId))
                    end
                else
                    error(('Tried To Set Account ^5%s^1 For Player ^5%s^1 To An Invalid Number -> ^5%s^1'):format(accountName, self.playerId, money))
                end
            end
            -- Attention (vraie 1.12.4) : aucun contrôle du solde, le compte peut devenir négatif, rien n'est renvoyé
            function self.removeAccountMoney(accountName, money, reason)
                reason = reason or 'Unknown'
                if not tonumber(money) then
                    error(('Tried To Set Account ^5%s^1 For Player ^5%s^1 To An Invalid Number -> ^5%s^1'):format(accountName, self.playerId, money))
                    return
                end
                if money > 0 then
                    local account = self.getAccount(accountName)
                    if account then
                        money = account.round and ESX.Math.Round(money) or money
                        if self.accounts[account.index].money - money > self.accounts[account.index].money then
                            error(('Tried To Underflow Account ^5%s^1 For Player ^5%s^1!'):format(accountName, self.playerId))
                            return
                        end
                        self.accounts[account.index].money = self.accounts[account.index].money - money
                        self.triggerEvent('esx:setAccountMoney', account)
                        TriggerEvent('esx:removeAccountMoney', self.source, accountName, money, reason)
                    else
                        error(('Tried To Set Add To Invalid Account ^5%s^1 For Player ^5%s^1!'):format(accountName, self.playerId))
                    end
                else
                    error(('Tried To Set Account ^5%s^1 For Player ^5%s^1 To An Invalid Number -> ^5%s^1'):format(accountName, self.playerId, money))
                end
            end
            function self.getInventoryItem(itemName)
                for _, v in ipairs(self.inventory) do if v.name == itemName then return v end end
                return nil
            end
            function self.addInventoryItem(itemName, count)
                local item = self.getInventoryItem(itemName)
                if item then
                    count = ESX.Math.Round(count)
                    item.count = item.count + count
                    self.weight = self.weight + (item.weight * count)
                    TriggerEvent('esx:onAddInventoryItem', self.source, item.name, item.count)
                    self.triggerEvent('esx:addInventoryItem', item.name, item.count)
                end
            end
            function self.removeInventoryItem(itemName, count)
                local item = self.getInventoryItem(itemName)
                if item then
                    count = ESX.Math.Round(count)
                    if count > 0 then
                        local newCount = item.count - count
                        if newCount >= 0 then
                            item.count = newCount
                            self.weight = self.weight - (item.weight * count)
                            TriggerEvent('esx:onRemoveInventoryItem', self.source, item.name, item.count)
                            self.triggerEvent('esx:removeInventoryItem', item.name, item.count)
                        end
                    else
                        error(('Player ID:^5%s Tried remove a Invalid count -> %s of %s'):format(self.playerId, count, itemName))
                    end
                end
            end
            function self.setInventoryItem(itemName, count)
                local item = self.getInventoryItem(itemName)
                if item and count >= 0 then
                    count = ESX.Math.Round(count)
                    if count > item.count then
                        self.addInventoryItem(item.name, count - item.count)
                    else
                        self.removeInventoryItem(item.name, item.count - count)
                    end
                end
            end
            function self.getWeight() return self.weight end
            function self.getMaxWeight() return self.maxWeight end
            function self.canCarryItem(itemName, count)
                if ESX.Items[itemName] then
                    return self.weight + (ESX.Items[itemName].weight * count) <= self.maxWeight
                end
                print(('[^3WARNING^7] Item ^5"%s"^7 was used but does not exist!'):format(itemName))
                return false
            end
            function self.canSwapItem(firstItem, firstItemCount, testItem, testItemCount)
                local firstItemObject = self.getInventoryItem(firstItem)
                if not firstItemObject then return false end
                local testItemObject = self.getInventoryItem(testItem)
                if not testItemObject then return false end
                if firstItemObject.count >= firstItemCount then
                    local weightWithoutFirstItem = ESX.Math.Round(self.weight - (firstItemObject.weight * firstItemCount))
                    local weightWithTestItem = ESX.Math.Round(weightWithoutFirstItem + (testItemObject.weight * testItemCount))
                    return weightWithTestItem <= self.maxWeight
                end
                return false
            end
            function self.setMaxWeight(newWeight)
                self.maxWeight = newWeight
                self.triggerEvent('esx:setMaxWeight', self.maxWeight)
            end
            function self.setJob(newJob, grade, onDuty)
                grade = tostring(grade)
                local lastJob = self.job
                if not ESX.DoesJobExist(newJob, grade) then
                    return print(('[ESX] [^3WARNING^7] Ignoring invalid ^5.setJob()^7 usage for ID: ^5%s^7, Job: ^5%s^7'):format(self.source, newJob))
                end
                if newJob == 'unemployed' then onDuty = false end
                if type(onDuty) ~= 'boolean' then onDuty = Config.DefaultJobDuty end
                local jobObject, gradeObject = ESX.Jobs[newJob], ESX.Jobs[newJob].grades[grade]
                self.job = {
                    id = jobObject.id, name = jobObject.name, label = jobObject.label, onDuty = onDuty,
                    grade = tonumber(grade), grade_name = gradeObject.name, grade_label = gradeObject.label,
                    grade_salary = gradeObject.salary,
                    skin_male = gradeObject.skin_male and json.decode(gradeObject.skin_male) or {},
                    skin_female = gradeObject.skin_female and json.decode(gradeObject.skin_female) or {},
                }
                self.metadata.jobDuty = onDuty
                TriggerEvent('esx:setJob', self.source, self.job, lastJob)
                self.triggerEvent('esx:setJob', self.job, lastJob)
            end
            function self.hasWeapon(weaponName)
                for _, v in ipairs(self.loadout) do if v.name == weaponName then return true end end
                return false
            end
            function self.getWeapon(weaponName)
                for k, v in ipairs(self.loadout) do if v.name == weaponName then return k, v end end
                return nil, nil
            end
            function self.getWeaponTint(weaponName)
                local _, weapon = self.getWeapon(weaponName)
                return weapon and weapon.tintIndex or 0
            end
            function self.hasItem(item)
                for _, v in ipairs(self.inventory) do
                    if v.name == item and v.count >= 1 then return v, v.count end
                end
                return false
            end
            function self.showNotification(msg, notifyType, length)
                self.triggerEvent('esx:showNotification', msg, notifyType, length)
            end
            function self.showAdvancedNotification(sender, subject, msg, textureDict, iconType, flash, saveToBrief, hudColorIndex)
                self.triggerEvent('esx:showAdvancedNotification', sender, subject, msg, textureDict, iconType, flash, saveToBrief, hudColorIndex)
            end
            function self.showHelpNotification(msg, thisFrame, beep, duration)
                self.triggerEvent('esx:showHelpNotification', msg, thisFrame, beep, duration)
            end
            function self.getMeta(index, subIndex)
                if not index then return self.metadata end
                if type(index) ~= 'string' then
                    error('xPlayer.getMeta ^5index^1 should be ^5string^1!')
                    return
                end
                local metaData = self.metadata[index]
                if metaData == nil then
                    return Config.EnableDebug and error(('xPlayer.getMeta ^5%s^1 not exist!'):format(index)) or nil
                end
                if subIndex and type(metaData) == 'table' then
                    local _type = type(subIndex)
                    if _type == 'string' then return metaData[subIndex] end
                    if _type == 'table' then
                        local returnValues = {}
                        for i = 1, #subIndex do
                            local key = subIndex[i]
                            if type(key) == 'string' then
                                returnValues[key] = self.getMeta(index, key)
                            else
                                error(('xPlayer.getMeta subIndex should be ^5string^1 or ^5table^1! that contains ^5string^1, received ^5%s^1!, skipping...'):format(type(key)))
                            end
                        end
                        return returnValues
                    end
                    error(('xPlayer.getMeta subIndex should be ^5string^1 or ^5table^1!, received ^5%s^1!'):format(_type))
                    return
                end
                return metaData
            end
            function self.setMeta(index, value, subValue)
                if not index then return error('xPlayer.setMeta ^5index^1 is Missing!') end
                if type(index) ~= 'string' then return error('xPlayer.setMeta ^5index^1 should be ^5string^1!') end
                if value == nil then return error('xPlayer.setMeta value is missing!') end
                local _type = type(value)
                if not subValue then
                    if _type ~= 'number' and _type ~= 'string' and _type ~= 'table' then
                        return error(('xPlayer.setMeta ^5%s^1 should be ^5number^1 or ^5string^1 or ^5table^1!'):format(value))
                    end
                    self.metadata[index] = value
                else
                    if _type ~= 'string' then
                        return error(('xPlayer.setMeta ^5value^1 should be ^5string^1 as a subIndex!'):format(value))
                    end
                    if not self.metadata[index] or type(self.metadata[index]) ~= 'table' then self.metadata[index] = {} end
                    self.metadata[index][value] = subValue
                end
                self.triggerEvent('esx:updatePlayerData', 'metadata', self.metadata)
            end
            function self.clearMeta(index, subValues)
                if not index then return error('xPlayer.clearMeta ^5index^1 is Missing!') end
                if type(index) ~= 'string' then return error('xPlayer.clearMeta ^5index^1 should be ^5string^1!') end
                local metaData = self.metadata[index]
                if metaData == nil then
                    return Config.EnableDebug and error(('xPlayer.clearMeta ^5%s^1 does not exist!'):format(index)) or nil
                end
                if not subValues then
                    self.metadata[index] = nil
                elseif type(subValues) == 'string' then
                    if type(metaData) == 'table' then metaData[subValues] = nil
                    else return error(('xPlayer.clearMeta ^5%s^1 is not a table! Cannot clear subValue ^5%s^1.'):format(index, subValues)) end
                elseif type(subValues) == 'table' then
                    for i = 1, #subValues do
                        local subValue = subValues[i]
                        if type(subValue) == 'string' then
                            if type(metaData) == 'table' then metaData[subValue] = nil
                            else error(('xPlayer.clearMeta ^5%s^1 is not a table! Cannot clear subValue ^5%s^1.'):format(index, subValue)) end
                        else
                            error(('xPlayer.clearMeta subValues should contain ^5string^1, received ^5%s^1, skipping...'):format(type(subValue)))
                        end
                    end
                else
                    return error(('xPlayer.clearMeta ^5subValues^1 should be ^5string^1 or ^5table^1, received ^5%s^1!'):format(type(subValues)))
                end
                self.triggerEvent('esx:updatePlayerData', 'metadata', self.metadata)
            end

            for _, funcs in pairs(Core.PlayerFunctionOverrides) do
                for fnName, fn in pairs(funcs) do self[fnName] = fn(self) end
            end
            return self
        end
        mock.CreateExtendedPlayer = CreateExtendedPlayer

        -- server/classes/overrides/oxinventory.lua
        if ox then
            local function noop() return function() end end
            Core.PlayerFunctionOverrides.OxInventory = {
                getInventory = function(self)
                    return function(minimal)
                        if not minimal then return self.inventory end
                        local minimalInventory = {}
                        for k, v in pairs(self.inventory) do
                            if v.count and v.count > 0 then
                                local metadata = v.metadata
                                if v.metadata and next(v.metadata) == nil then metadata = nil end
                                minimalInventory[#minimalInventory + 1] = { name = v.name, count = v.count, slot = k, metadata = metadata }
                            end
                        end
                        return minimalInventory
                    end
                end,
                getLoadout = function() return function() return {} end end,
                setAccountMoney = function(self)
                    return function(accountName, money, reason)
                        reason = reason or 'unknown'
                        if money < 0 then return end
                        local account = self.getAccount(accountName)
                        if not account then return end
                        money = account.round and ESX.Math.Round(money) or money
                        self.accounts[account.index].money = money
                        self.triggerEvent('esx:setAccountMoney', account)
                        TriggerEvent('esx:setAccountMoney', self.source, accountName, money, reason)
                        if Inventory().accounts[accountName] then Inventory().SetItem(self.source, accountName, money) end
                    end
                end,
                addAccountMoney = function(self)
                    return function(accountName, money, reason)
                        reason = reason or 'unknown'
                        if money < 1 then return end
                        local account = self.getAccount(accountName)
                        if not account then return end
                        money = account.round and ESX.Math.Round(money) or money
                        self.accounts[account.index].money = self.accounts[account.index].money + money
                        self.triggerEvent('esx:setAccountMoney', account)
                        TriggerEvent('esx:addAccountMoney', self.source, accountName, money, reason)
                        if Inventory().accounts[accountName] then Inventory().AddItem(self.source, accountName, money) end
                    end
                end,
                -- en mode ox aussi : pas de contrôle du solde ; montant < 1 ignoré sans erreur
                removeAccountMoney = function(self)
                    return function(accountName, money, reason)
                        reason = reason or 'unknown'
                        if money < 1 then return end
                        local account = self.getAccount(accountName)
                        if not account then return end
                        money = account.round and ESX.Math.Round(money) or money
                        self.accounts[account.index].money = self.accounts[account.index].money - money
                        self.triggerEvent('esx:setAccountMoney', account)
                        TriggerEvent('esx:removeAccountMoney', self.source, accountName, money, reason)
                        if Inventory().accounts[accountName] then Inventory().RemoveItem(self.source, accountName, money) end
                    end
                end,
                getInventoryItem = function(self) return function(name, metadata) return Inventory().GetItem(self.source, name, metadata) end end,
                addInventoryItem = function(self) return function(name, count, metadata, slot) return Inventory().AddItem(self.source, name, count or 1, metadata, slot) end end,
                removeInventoryItem = function(self) return function(name, count, metadata, slot) return Inventory().RemoveItem(self.source, name, count or 1, metadata, slot) end end,
                setInventoryItem = function(self) return function(name, count, metadata) return Inventory().SetItem(self.source, name, count, metadata) end end,
                canCarryItem = function(self) return function(name, count, metadata) return Inventory().CanCarryItem(self.source, name, count, metadata) end end,
                canSwapItem = function(self)
                    return function(firstItem, firstItemCount, testItem, testItemCount)
                        return Inventory().CanSwapItem(self.source, firstItem, firstItemCount, testItem, testItemCount)
                    end
                end,
                setMaxWeight = function(self)
                    return function(newWeight)
                        self.maxWeight = newWeight
                        self.triggerEvent('esx:setMaxWeight', self.maxWeight)
                        return Inventory().SetMaxWeight(self.source, newWeight)
                    end
                end,
                addWeapon = noop, addWeaponComponent = noop, addWeaponAmmo = noop, updateWeaponAmmo = noop,
                setWeaponTint = noop, getWeaponTint = noop, removeWeapon = noop, removeWeaponComponent = noop,
                removeWeaponAmmo = noop, getWeapon = noop,
                hasWeaponComponent = function() return function() return false end end,
                hasWeapon = function() return function() return false end end,
                hasItem = function(self) return function(name, metadata) return Inventory().GetItem(self.source, name, metadata) end end,
                syncInventory = function(self)
                    return function(weight, maxWeight, items, money)
                        self.weight, self.maxWeight = weight, maxWeight
                        self.inventory = items
                        if not money then return end
                        for accountName, amount in pairs(money) do
                            local account = self.getAccount(accountName)
                            if account and ESX.Math.Round(account.money) ~= amount then
                                account.money = amount
                                self.triggerEvent('esx:setAccountMoney', account)
                                TriggerEvent('esx:setAccountMoney', self.source, accountName, amount, 'Sync account with item')
                            end
                        end
                    end
                end,
            }
        end

        -- server/main.lua : loadESXPlayer, avec les données du joueur émulé à la place de la base
        local accountNames = {}
        for name in pairs(Config.Accounts) do accountNames[#accountNames + 1] = name end
        table.sort(accountNames)

        local function loadESXPlayer(identifier, playerId, isNew)
            local p = emu.players[playerId]
            local o = (p and p.opts.esx) or {}
            local userData = {
                accounts = {}, inventory = {}, loadout = {}, weight = 0,
                name = env.GetPlayerName(playerId), identifier = identifier,
                firstName = 'John', lastName = 'Doe', dateofbirth = '01/01/2000', height = 120, dead = false,
            }
            local startAccounts = o.accounts or {}
            for _, account in ipairs(accountNames) do
                local data = Config.Accounts[account]
                data.round = data.round or data.round == nil
                local index = #userData.accounts + 1
                userData.accounts[index] = { name = account, money = startAccounts[account] or Config.StartingAccountMoney[account] or 0,
                                             label = data.label, round = data.round, index = index }
            end
            local job, grade = o.job or 'unemployed', tostring(o.grade or 0)
            if not ESX.DoesJobExist(job, grade) then
                print(('[^3WARNING^7] Ignoring invalid job for ^5%s^7 [job: ^5%s^7, grade: ^5%s^7]'):format(identifier, job, grade))
                job, grade = 'unemployed', '0'
            end
            local jobObject, gradeObject = ESX.Jobs[job], ESX.Jobs[job].grades[grade]
            userData.job = {
                id = jobObject.id, name = jobObject.name, label = jobObject.label,
                grade = tonumber(grade), grade_name = gradeObject.name, grade_label = gradeObject.label,
                grade_salary = gradeObject.salary,
                skin_male = gradeObject.skin_male and json.decode(gradeObject.skin_male) or {},
                skin_female = gradeObject.skin_female and json.decode(gradeObject.skin_female) or {},
            }
            if not ox then
                local inventory = o.inventory or {}
                for name, item in pairs(ESX.Items) do
                    local count = inventory[name] or 0
                    userData.weight = userData.weight + (count * item.weight)
                    userData.inventory[#userData.inventory + 1] = {
                        name = name, count = count, label = item.label, weight = item.weight,
                        usable = Core.UsableItemsCallbacks[name] ~= nil, rare = item.rare, canRemove = item.canRemove,
                    }
                end
                table.sort(userData.inventory, function(a, b) return a.label < b.label end)
            elseif o.inventory then
                userData.inventory = emu.netCopy(o.inventory)
            end
            userData.group = o.group == 'superadmin' and 'admin' or o.group or 'user'
            userData.coords = o.coords or { x = p.pos.x, y = p.pos.y, z = p.pos.z, heading = p.heading }
            userData.skin = o.skin or { sex = 0 }
            userData.metadata = emu.netCopy(o.metadata or {})

            local xPlayer = CreateExtendedPlayer(playerId, identifier, userData.group, userData.accounts, userData.inventory,
                userData.weight, userData.job, userData.loadout, env.GetPlayerName(playerId), userData.coords, userData.metadata)
            ESX.Players[playerId] = xPlayer
            Core.playersByIdentifier[identifier] = xPlayer

            if o.firstName then
                userData.firstName, userData.lastName = o.firstName, o.lastName or ''
                local name = ('%s %s'):format(userData.firstName, userData.lastName)
                userData.name = name
                xPlayer.set('firstName', userData.firstName)
                xPlayer.set('lastName', userData.lastName)
                xPlayer.setName(name)
                for _, k in ipairs({ 'dateofbirth', 'sex', 'height' }) do
                    if o[k] then userData[k] = o[k] xPlayer.set(k, o[k]) end
                end
            end

            TriggerEvent('esx:playerLoaded', playerId, xPlayer, isNew)
            userData.money = xPlayer.getMoney()
            userData.maxWeight = xPlayer.getMaxWeight()
            xPlayer.triggerEvent('esx:playerLoaded', userData, isNew, userData.skin)

            if ox then
                -- server/bridge/inventory/oxinventory.lua : setPlayerInventory
                env.exports.ox_inventory:setPlayerInventory(xPlayer, userData.inventory)
                if isNew then
                    local shared = json.decode(env.GetConvar('inventory:accounts', '["money"]'))
                    for i = 1, #shared do
                        local account = Config.StartingAccountMoney[shared[i]]
                        if account then env.exports.ox_inventory:AddItem(playerId, shared[i], account) end
                    end
                end
            end
            print(('[^2INFO^0] Player ^5"%s"^0 has connected to the server. ID: ^5%s^7'):format(xPlayer.getName(), playerId))
        end
        mock.loadESXPlayer = loadESXPlayer

        local function onPlayerJoined(playerId)
            local p = emu.players[playerId]
            local identifier = (p and p.opts.esx and p.opts.esx.identifier) or ESX.GetIdentifier(playerId)
            if not identifier then
                return DropPlayer(playerId, 'there was an error loading your character!\nError code: identifier-missing-ingame')
            end
            if ESX.GetPlayerFromIdentifier(identifier) then
                DropPlayer(playerId, ('there was an error loading your character!\nError code: identifier-active-ingame\n\nYour Rockstar identifier: %s'):format(identifier))
            else
                loadESXPlayer(identifier, playerId, (p and p.opts.esx and p.opts.esx.isNew) == true)
            end
        end

        env.RegisterNetEvent('esx:onPlayerJoined', function()
            local _source = env.source
            while not next(ESX.Jobs) do env.Wait(50) end
            if not ESX.Players[_source] then onPlayerJoined(_source) end
        end)

        env.AddEventHandler('playerDropped', function(reason)
            local playerId = env.source
            local xPlayer = ESX.GetPlayerFromId(playerId)
            if xPlayer then
                TriggerEvent('esx:playerDropped', playerId, reason)
                local job = xPlayer.getJob().name
                local currentJob = Core.JobsPlayerCount[job]
                Core.JobsPlayerCount[job] = ((currentJob and currentJob > 0) and currentJob or 1) - 1
                Core.playersByIdentifier[xPlayer.identifier] = nil
                ESX.Players[playerId] = nil
            end
        end)

        env.AddEventHandler('esx:playerLoaded', function(_, xPlayer)
            local job = xPlayer.getJob().name
            Core.JobsPlayerCount[job] = (Core.JobsPlayerCount[job] or 0) + 1
        end)

        env.AddEventHandler('esx:setJob', function(_, job, lastJob)
            local currentLastJob = Core.JobsPlayerCount[lastJob.name]
            Core.JobsPlayerCount[lastJob.name] = ((currentLastJob and currentLastJob > 0) and currentLastJob or 1) - 1
            Core.JobsPlayerCount[job.name] = (Core.JobsPlayerCount[job.name] or 0) + 1
        end)

        if not ox then
            env.RegisterNetEvent('esx:useItem', function(itemName)
                local source = env.source
                local xPlayer = ESX.GetPlayerFromId(source)
                local count = xPlayer.getInventoryItem(itemName).count
                if count < 1 then return xPlayer.showNotification(TranslateCap('act_imp')) end
                ESX.UseItem(source, itemName)
            end)
        end
    end

    ---------------------------------------------------------------------------
    -- Client (un ESX par joueur)
    ---------------------------------------------------------------------------
    local function client(env, _, player)
        local ox = mock.ox
        local Config = makeConfig(ox)
        local ESX, Core = {}, { Events = {} }
        mock.client[player.id] = ESX
        sharedFunctions(ESX, Config)
        ESX.PlayerData = {}
        ESX.PlayerLoaded = false
        ESX.playerId = env.PlayerId()
        ESX.serverId = env.GetPlayerServerId(ESX.playerId)
        ESX.UI = { Menu = {} }
        ESX.Game = {}
        local TriggerEvent, TriggerServerEvent, GetInvokingResource = env.TriggerEvent, env.TriggerServerEvent, env.GetInvokingResource
        local function notify(kind, data)
            data.kind = kind
            player.notifications[#player.notifications + 1] = { t = emu.now, data = data, resource = 'es_extended' }
        end

        env.exports('getSharedObject', function() return ESX end)
        env.AddEventHandler('esx:getSharedObject', function(cb) if ESX.IsFunctionReference(cb) then cb(ESX) end end)

        function ESX.IsPlayerLoaded() return ESX.PlayerLoaded end
        function ESX.GetPlayerData() return ESX.PlayerData end
        function ESX.SecureNetEvent(name, func)
            local invoker = GetInvokingResource() or emu:callerResource(player.side)
            local invokingResource = invoker and invoker ~= 'unknown' and invoker or 'es_extended'
            if not Core.Events[invokingResource] then Core.Events[invokingResource] = {} end
            local event = env.RegisterNetEvent(name, function(...)
                if env.source == '' then return end
                local success, result = pcall(func, ...)
                if not success then error(('%s'):format(result)) end
            end)
            Core.Events[invokingResource][#Core.Events[invokingResource] + 1] = event
        end
        function ESX.SetPlayerData(key, val)
            local current = ESX.PlayerData[key]
            ESX.PlayerData[key] = val
            if key ~= 'inventory' and key ~= 'loadout' then
                if type(val) == 'table' or val ~= current then TriggerEvent('esx:setPlayerData', key, val, current) end
            end
        end
        function ESX.GetAccount(account)
            for i = 1, #ESX.PlayerData.accounts, 1 do
                if ESX.PlayerData.accounts[i].name == account then return ESX.PlayerData.accounts[i] end
            end
            return nil
        end
        function ESX.SearchInventory(items, count)
            local item
            if type(items) == 'string' then item, items = items, { items } end
            local data = {}
            for i = 1, #ESX.PlayerData.inventory do
                local e = ESX.PlayerData.inventory[i]
                for ii = 1, #items do
                    if e.name == items[ii] then
                        data[table.remove(items, ii)] = count and e.count or e
                        break
                    end
                end
                if #items == 0 then break end
            end
            return not item and data or data[item]
        end
        -- Notifications : enregistrées dans player.notifications (esx_notify n'est pas simulé)
        function ESX.ShowNotification(message, notifyType, length)
            notify('notification', { message = message, type = notifyType, length = length })
        end
        function ESX.ShowAdvancedNotification(sender, subject, msg, textureDict, iconType, flash, saveToBrief, hudColorIndex)
            notify('advanced', { sender = sender, subject = subject, message = msg, textureDict = textureDict, iconType = iconType })
        end
        function ESX.ShowHelpNotification(msg, thisFrame, beep, duration)
            notify('help', { message = msg, thisFrame = thisFrame, beep = beep, duration = duration })
        end
        function ESX.TextUI(message, notifyType) notify('textui', { message = message, type = notifyType }) end
        function ESX.HideUI() notify('hideui', {}) end

        -- client/modules/callback.lua
        local Callbacks = { requests = {}, storage = {}, id = 0 }
        function Callbacks:Trigger(event, cb, invoker, ...)
            self.requests[self.id] = { await = type(cb) == 'boolean', cb = cb or env.promise:new() }
            local request = self.requests[self.id]
            TriggerServerEvent('esx:triggerServerCallback', event, self.id, invoker, ...)
            self.id = self.id + 1
            return request.cb
        end
        function Callbacks:Execute(cb, id, ...)
            local success, errorString = pcall(cb, ...)
            if not success then
                env.print(('[^1ERROR^7] Failed to execute Callback with RequestId: ^5%s^7'):format(id))
                error(errorString)
            end
        end
        function Callbacks:ServerRecieve(requestId, invoker, ...)
            if not self.requests[requestId] then
                return error(('Server Callback with requestId ^5%s^1 Was Called by ^5%s^1 but does not exist.'):format(requestId, invoker))
            end
            local callback = self.requests[requestId]
            self.requests[requestId] = nil
            if callback.await then callback.cb:resolve({ ... }) else self:Execute(callback.cb, requestId, ...) end
        end
        function Callbacks:Register(name, resource, cb) self.storage[name] = { resource = resource, cb = cb } end
        function Callbacks:ClientRecieve(eventName, requestId, invoker, ...)
            if not self.storage[eventName] then
                return error(('Client Callback with requestId ^5%s^1 Was Called by ^5%s^1 but does not exist.'):format(eventName, invoker))
            end
            local returnCb = function(...) TriggerServerEvent('esx:clientCallback', requestId, invoker, ...) end
            self:Execute(self.storage[eventName].cb, requestId, returnCb, ...)
        end
        local function invoker()
            local r = GetInvokingResource() or emu:callerResource(player.side)
            return (r and r ~= 'unknown') and r or 'es_extended'
        end
        function ESX.TriggerServerCallback(eventName, callback, ...)
            Callbacks:Trigger(eventName, callback, invoker(), ...)
        end
        -- Comme la 1.12.4 : le délai de 15 s compare p.state à "pending" alors que l'état est un nombre,
        -- donc l'attente ne s'arrête jamais si le serveur ne répond pas
        function ESX.AwaitServerCallback(eventName, ...)
            local p = Callbacks:Trigger(eventName, false, invoker(), ...)
            if not p then return end
            env.SetTimeout(15000, function()
                if p.state == 'pending' then p:reject('Server Callback Timed Out') end
            end)
            env.Citizen.Await(p)
            return unpack(p.value)
        end
        function ESX.RegisterClientCallback(eventName, callback) Callbacks:Register(eventName, invoker(), callback) end
        function ESX.DoesClientCallbackExist(eventName) return Callbacks.storage[eventName] ~= nil end
        ESX.SecureNetEvent('esx:triggerClientCallback', function(...) Callbacks:ClientRecieve(...) end)
        ESX.SecureNetEvent('esx:serverCallback', function(...) Callbacks:ServerRecieve(...) end)

        -- client/modules/events.lua
        env.RegisterNetEvent('esx:playerLoaded', function(xPlayer, _, skin)
            ESX.PlayerData = xPlayer
            -- ESX.SpawnPlayer : le ped apparaît aux coordonnées enregistrées si le test en a donné
            local o = player.opts.esx or {}
            if o.coords then
                player.pos = { x = o.coords.x, y = o.coords.y, z = o.coords.z }
                player.heading = o.coords.heading or o.coords.w or player.heading
            end
            ESX.SetPlayerData('ped', env.PlayerPedId())
            TriggerEvent('esx:onPlayerSpawn')
            while not env.DoesEntityExist(ESX.PlayerData.ped) do env.Wait(20) end
            ESX.PlayerLoaded = true
        end)
        ESX.SecureNetEvent('esx:onPlayerLogout', function()
            ESX.PlayerLoaded = false
        end)
        ESX.SecureNetEvent('esx:setMaxWeight', function(newMaxWeight) ESX.SetPlayerData('maxWeight', newMaxWeight) end)
        ESX.SecureNetEvent('esx:setAccountMoney', function(account)
            for i = 1, #ESX.PlayerData.accounts do
                if ESX.PlayerData.accounts[i].name == account.name then
                    ESX.PlayerData.accounts[i] = account
                    break
                end
            end
            ESX.SetPlayerData('accounts', ESX.PlayerData.accounts)
        end)
        if not ox then
            ESX.SecureNetEvent('esx:addInventoryItem', function(item, count)
                for k, v in ipairs(ESX.PlayerData.inventory) do
                    if v.name == item then ESX.PlayerData.inventory[k].count = count break end
                end
            end)
            ESX.SecureNetEvent('esx:removeInventoryItem', function(item, count)
                for i = 1, #ESX.PlayerData.inventory do
                    if ESX.PlayerData.inventory[i].name == item then ESX.PlayerData.inventory[i].count = count break end
                end
            end)
        end
        ESX.SecureNetEvent('esx:setJob', function(Job) ESX.SetPlayerData('job', Job) end)
        ESX.SecureNetEvent('esx:setGroup', function(group) ESX.SetPlayerData('group', group) end)
        ESX.SecureNetEvent('esx:updatePlayerData', function(key, val) ESX.SetPlayerData(key, val) end)
        ESX.SecureNetEvent('esx:showNotification', ESX.ShowNotification)
        ESX.SecureNetEvent('esx:showAdvancedNotification', ESX.ShowAdvancedNotification)
        ESX.SecureNetEvent('esx:showHelpNotification', ESX.ShowHelpNotification)
        env.AddEventHandler('onResourceStop', function(resource)
            if Core.Events[resource] then
                for i = 1, #Core.Events[resource] do env.RemoveEventHandler(Core.Events[resource][i]) end
            end
        end)

        -- client/main.lua : le client signale qu'il est prêt (NetworkIsPlayerActive + 500 ms)
        env.CreateThread(function()
            env.Wait(100)
            env.Wait(500)
            TriggerServerEvent('esx:onPlayerJoined')
        end)
    end

    emu:defineResource('es_extended', { server = server, client = client })

    -- Inclusion '@es_extended/imports.lua'
    emu:provide('@es_extended/imports.lua', function(env, side)
        env.ESX = env.exports['es_extended']:getSharedObject()
        env.ESX.currentResourceName = env.GetCurrentResourceName()
        env.OnPlayerData = function() end
        if side.kind == 'client' then
            env.AddEventHandler('esx:setPlayerData', function(key, val, last)
                if env.GetInvokingResource() == 'es_extended' then
                    env.ESX.PlayerData[key] = val
                    if env.OnPlayerData then env.OnPlayerData(key, val, last) end
                end
            end)
            env.RegisterNetEvent('esx:playerLoaded', function(xPlayer)
                env.ESX.PlayerData = xPlayer
                while not env.ESX.PlayerData.ped or not env.DoesEntityExist(env.ESX.PlayerData.ped) do env.Wait(0) end
                env.ESX.PlayerLoaded = true
            end)
        end
    end)

    -- Inclusion '@es_extended/locale.lua' : Locales, Translate / TranslateCap (alias _ et _U), comme ESX
    emu:provide('@es_extended/locale.lua', function(env)
        env.Locales = env.Locales or {}
        local function lookup(str, ...)
            local lang = (rawget(env, 'Config') and env.Config.Locale) or 'en'
            local t = env.Locales[lang] or env.Locales.en
            local s = t and t[str]
            if s == nil then return ('Translation [%s][%s] does not exist'):format(lang, tostring(str)) end
            local ok, r = pcall(string.format, s, ...)
            return ok and r or s
        end
        env.Translate = lookup
        env.TranslateCap = function(str, ...)
            local s = lookup(str, ...)
            return (s:gsub('^%l', string.upper))
        end
        env._ = env.Translate
        env._U = env.TranslateCap
    end)

    -- Aides pour les tests
    function mock:xPlayer(player) return self.ESX.Players[type(player) == 'table' and player.id or tonumber(player)] end
    function mock:clientESX(player) return self.client[type(player) == 'table' and player.id or tonumber(player)] end
    -- Avance l'horloge jusqu'à ce que le client du joueur ait reçu esx:playerLoaded
    function mock:waitLoaded(player, timeoutMs)
        return emu:runUntil(function()
            local c = self.client[player.id]
            return c ~= nil and c.PlayerLoaded == true
        end, timeoutMs or 10000)
    end
    -- Le joueur utilise un objet (inventaire ESX d'origine) : esx:useItem part au serveur par le réseau
    function mock:useItem(player, itemName)
        emu:_env(player.side, 'es_extended').TriggerServerEvent('esx:useItem', itemName)
    end

    -- Sonde pour emu:fuzz : comptes du joueur, et inventaire ESX d'origine (en mode ox, la sonde d'ox_inventory compte)
    emu:addProbe('esx', function(player)
        local xPlayer = mock.ESX and mock.ESX.Players[player.id]
        if not xPlayer then return nil end
        local r = {}
        for _, account in ipairs(xPlayer.accounts or {}) do r[account.name] = account.money end
        if not mock.ox then
            for _, item in ipairs(xPlayer.inventory or {}) do if item.count ~= 0 then r['item:' .. item.name] = item.count end end
        end
        return r
    end)

    if opts.autostart ~= false then emu:start('es_extended') end
    return mock
end
