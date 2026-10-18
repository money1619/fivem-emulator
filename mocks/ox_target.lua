-- mocks/ox_target.lua — ox_target 1.18.0 simulé côté client, d'après client/api.lua et client/main.lua.
--
--   local target = require('mocks.ox_target')(emu)
--   -- la ressource testée appelle exports.ox_target:addBoxZone({ coords = vec3(…), options = { … } })
--   local ok, info = player:target('shop:open')          -- ou target:select(player, 'shop:open')
--
-- Il n'y a ni caméra ni rayon : le joueur « vise » le centre de la zone (ou opts.coords, ou l'entité opts.entity).
-- Une option est choisie comme ox_target : le point visé doit être dans la zone, distance joueur → point visé
-- ≤ option.distance (7 par défaut), groups / items vérifiés, puis canInteract(entity, distance, coords, name, bone).
-- L'action est ensuite celle d'ox_target : onSelect, export, event, serverEvent ou command.
-- Filtre : nom d'option, libellé, ou fonction(option, zone) → booléen.
-- Approximations : la hauteur d'une zone boîte / polygone est ± moitié de son épaisseur ; bones et offset ignorés ;
-- seules les entités locales (CreateObject/CreatePed/CreateVehicle du joueur) et son propre ped sont visables.

-- table.type d'ox_lib
local function tableType(t)
    local n = #t
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    if count == 0 then return 'empty' end
    if count == n then return 'array' end
    if n == 0 then return 'hash' end
    return 'mixed'
end

local function clone(t) local r = {} for k, v in pairs(t) do r[k] = v end return r end

return function(emu, opts)
    opts = opts or {}
    local mock = { players = {} }
    emu.mocks.ox_target = mock
    local V = emu.vec

    local function typeError(variable, expected, received)
        error(("expected %s to have type '%s' (received %s)"):format(variable, expected, received), 3)
    end

    local function checkOptions(options)
        if type(options) ~= 'table' then typeError('options', 'table', type(options)) end
        local tt = tableType(options)
        if tt == 'hash' and options.label then
            options = { options }
        elseif tt ~= 'array' then
            typeError('options', 'array', ('%s table'):format(tt))
        end
        return options
    end

    local function toVec(c)
        if emu.isVector(c) and c.z then return c end
        return V(c.x or c[1], c.y or c[2], c.z or c[3] or 0.0)
    end

    -- Formes des zones (lib.zones d'ox_lib)
    local function boxContains(zone, p)
        local d = p - zone.coords
        local a = -math.rad(zone.rotation)
        local lx = d.x * math.cos(a) - d.y * math.sin(a)
        local ly = d.x * math.sin(a) + d.y * math.cos(a)
        return math.abs(lx) <= zone.size.x and math.abs(ly) <= zone.size.y and math.abs(d.z) <= zone.thickness / 2
    end

    local function sphereContains(zone, p) return #(zone.coords - p) < zone.radius end

    local function polyContains(zone, p)
        local inside, pts = false, zone.points
        local j = #pts
        for i = 1, #pts do
            local a, b = pts[i], pts[j]
            if ((a.y > p.y) ~= (b.y > p.y)) and (p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) then inside = not inside end
            j = i
        end
        return inside and math.abs(p.z - zone.coords.z) <= zone.thickness / 2
    end

    local function client(env, _, player)
        local state = { zones = {}, nextZone = 0, peds = {}, vehicles = {}, objects = {}, players = {}, models = {},
                        entities = {}, localEntities = {}, global = {}, disabled = false, active = false, selections = {} }
        mock.players[player.id] = state
        local GetInvokingResource = env.GetInvokingResource
        local function invoker() return GetInvokingResource() or emu:callerResource(player.side) end

        local function addZone(kind, data)
            data.resource = invoker()
            data.options = checkOptions(data.options)
            state.nextZone = state.nextZone + 1
            data.id = state.nextZone
            data.__type = kind
            if kind == 'box' then
                data.coords = toVec(data.coords)
                data.size = data.size and toVec(data.size) / 2 or V(2.0, 2.0, 2.0)
                data.thickness = data.size.z * 2
                data.rotation = data.rotation or 0
                data.contains = boxContains
            elseif kind == 'sphere' then
                data.coords = toVec(data.coords)
                data.radius = (data.radius or 2) + 0.0
                data.contains = sphereContains
            else
                data.thickness = data.thickness or 4
                local pts, sx, sy, sz = {}, 0, 0, 0
                for i, pt in ipairs(data.points) do
                    pts[i] = toVec(pt)
                    sx, sy, sz = sx + pts[i].x, sy + pts[i].y, sz + pts[i].z
                end
                data.points = pts
                data.coords = V(sx / #pts, sy / #pts, sz / #pts)
                data.contains = polyContains
            end
            function data.remove() state.zones[data.id] = nil end
            state.zones[data.id] = data
            return data.id
        end

        local function removeTarget(target, remove, resource)
            if type(remove) ~= 'table' then remove = { remove } end
            for i = #target, 1, -1 do
                local option = target[i]
                if option.resource == resource then
                    for j = #remove, 1, -1 do
                        if option.name == remove[j] then table.remove(target, i) break end
                    end
                end
            end
        end

        local function addTarget(target, options, resource)
            options = checkOptions(options)
            local checkNames = {}
            resource = resource or 'ox_target'
            for i = 1, #options do
                options[i].resource = resource
                if options[i].name then checkNames[#checkNames + 1] = options[i].name end
            end
            if checkNames[1] then removeTarget(target, checkNames, resource) end
            for i = 1, #options do target[#target + 1] = options[i] end
        end

        local api = {}
        function api.addBoxZone(data) return addZone('box', data) end
        function api.addSphereZone(data) return addZone('sphere', data) end
        function api.addPolyZone(data) return addZone('poly', data) end
        function api.zoneExists(id)
            if type(id) ~= 'number' and type(id) ~= 'string' then return false end
            if type(id) == 'number' and state.zones[id] then return true end
            for _, zone in pairs(state.zones) do if type(id) == 'string' and zone.name == id then return true end end
            return false
        end
        function api.removeZone(id, suppressWarning)
            if type(id) == 'string' then
                local found
                for _, v in pairs(state.zones) do if v.name == id then found = true v.remove() end end
                if found then return end
            elseif state.zones[id] then
                return state.zones[id].remove()
            end
            if suppressWarning then return end
            emu:_warn(('ox_target (%s) : attempted to remove a zone that does not exist (id: %s, caller: %s)'):format(player.side.name, tostring(id), invoker() or '?'))
        end
        for name, list in pairs({ Ped = 'peds', Vehicle = 'vehicles', Object = 'objects', Player = 'players', Option = 'global' }) do
            api['addGlobal' .. name] = function(options) addTarget(state[list], options, invoker()) end
            api['removeGlobal' .. name] = function(options) removeTarget(state[list], options, invoker()) end
        end
        local function keyed(store, normalize, check)
            return function(arr, options)
                if type(arr) ~= 'table' then arr = { arr } end
                local resource = invoker()
                for i = 1, #arr do
                    local key = normalize(arr[i])
                    if check(key) then
                        store[key] = store[key] or {}
                        addTarget(store[key], options, resource)
                    end
                end
            end, function(arr, options)
                if type(arr) ~= 'table' then arr = { arr } end
                local resource = invoker()
                for i = 1, #arr do
                    local key = normalize(arr[i])
                    if store[key] then
                        if options then removeTarget(store[key], options, resource) end
                        if not options or #store[key] == 0 then store[key] = nil end
                    end
                end
            end
        end
        api.addModel, api.removeModel = keyed(state.models, function(m) return tonumber(m) or emu.joaat(m) end, function() return true end)
        -- entités en réseau : non simulées, aucune n'existe
        api.addEntity, api.removeEntity = keyed(state.entities, function(n) return n end, function() return false end)
        api.addLocalEntity, api.removeLocalEntity = keyed(state.localEntities, function(e) return e end, function(e)
            if env.DoesEntityExist(e) then return true end
            emu:_warn(("ox_target : No entity with id '%s' exists in %s."):format(tostring(e), tostring(invoker())))
            return false
        end)
        function api.disableTargeting(value)
            if value then state.active = false end
            state.disabled = value
        end
        function api.isActive() return state.active end
        for name, fn in pairs(api) do env.exports(name, fn) end

        env.AddEventHandler('onClientResourceStop', function(resource)
            for _, list in ipairs({ state.peds, state.vehicles, state.objects, state.players, state.global }) do
                for j = #list, 1, -1 do if list[j].resource == resource then table.remove(list, j) end end
            end
            for _, tbl in ipairs({ state.models, state.entities, state.localEntities }) do
                for key, options in pairs(tbl) do
                    for j = #options, 1, -1 do if options[j].resource == resource then table.remove(options, j) end end
                    if #options == 0 then tbl[key] = nil end
                end
            end
            for _, zone in pairs(state.zones) do if zone.resource == resource then zone.remove() end end
        end)

        -- Objets du joueur (ox_inventory, sinon inventaire ESX) et groupes (métier ESX), comme client/utils.lua
        local function itemCount(name)
            if player.oxInventory then
                local n = 0
                for _, v in pairs(player.oxInventory.items) do if v.name == name then n = n + v.count end end
                return n
            end
            local esx = emu.mocks.esx and emu.mocks.esx.client[player.id]
            if esx and esx.PlayerData.inventory then
                for _, v in pairs(esx.PlayerData.inventory) do if v.name == name then return v.count end end
            end
            return 0
        end
        local function hasItems(filter, hasAny)
            if type(filter) == 'string' then return itemCount(filter) > 0 end
            if type(filter) == 'table' then
                local tt = tableType(filter)
                if tt == 'hash' then
                    for name, amount in pairs(filter) do
                        local has = itemCount(name) >= amount
                        if hasAny then if has then return true end elseif not has then return false end
                    end
                elseif tt == 'array' then
                    for i = 1, #filter do
                        local has = itemCount(filter[i]) > 0
                        if hasAny then if has then return true end elseif not has then return false end
                    end
                end
            end
            return not hasAny
        end
        local function hasGroup(filter)
            local esx = emu.mocks.esx and emu.mocks.esx.client[player.id]
            if not esx then return true end
            local job = esx.PlayerData.job
            if type(filter) == 'string' then return job ~= nil and filter == job.name end
            if type(filter) == 'table' then
                if tableType(filter) == 'hash' then
                    for name, grade in pairs(filter) do if job and job.name == name and grade <= job.grade then return true end end
                else
                    for i = 1, #filter do if job and job.name == filter[i] then return true end end
                end
            end
            return false
        end

        local function shouldHide(option, distance, endCoords, entityHit)
            if option.menuName ~= state.currentMenu then return 'autre menu' end
            if distance > (option.distance or 7) then return ('trop loin (%.1f m > %.1f m)'):format(distance, option.distance or 7) end
            if option.groups and not hasGroup(option.groups) then return 'groupe' end
            if option.items and not hasItems(option.items, option.anyItem) then return 'objets' end
            if option.canInteract then
                local success, resp = pcall(option.canInteract, entityHit, distance, endCoords, option.name, nil)
                if not success then
                    emu:_warn(('ox_target : canInteract de « %s » a échoué : %s'):format(tostring(option.name), tostring(resp)))
                    return 'canInteract (erreur)'
                end
                if not resp then return 'canInteract' end
            end
            return nil
        end

        local function getResponse(option, ctx, server)
            local response = clone(option)
            response.entity, response.zone, response.coords, response.distance = ctx.entity, ctx.zone, ctx.coords, ctx.distance
            if server then response.entity = 0 end
            for _, k in ipairs({ 'icon', 'groups', 'items', 'canInteract', 'onSelect', 'export', 'event', 'serverEvent', 'command' }) do
                response[k] = nil
            end
            return response
        end

        local function run(option, ctx, zone)
            if option.openMenu then
                state.currentMenu = option.openMenu ~= 'home' and option.openMenu or nil
            end
            if option.onSelect then
                local arg = option.qtarget and ctx.entity or getResponse(option, ctx)
                emu:_spawn(player.side, option.resource, function() option.onSelect(arg) end, true)
            elseif option.export then
                local res = option.resource or (zone and zone.resource)
                emu:_spawn(player.side, 'ox_target', function() env.exports[res][option.export](nil, getResponse(option, ctx)) end, true)
            elseif option.event then
                env.TriggerEvent(option.event, getResponse(option, ctx))
            elseif option.serverEvent then
                env.TriggerServerEvent(option.serverEvent, getResponse(option, ctx, true))
            elseif option.command then
                env.ExecuteCommand(option.command)
            end
        end

        -- Choisit et déclenche une option ; renvoie true, infos ou false, raison
        function state.select(filter, o)
            o = o or {}
            if state.disabled then return false, 'ciblage désactivé (disableTargeting)' end
            local function match(option, zone)
                if type(filter) == 'function' then return filter(option, zone) end
                return filter == nil or option.name == filter or option.label == filter
            end
            local pos = V(player.pos.x, player.pos.y, player.pos.z)
            local reasons = {}
            local function try(option, zone, distance, coords, entity)
                if not match(option, zone) then return nil end
                local hidden = shouldHide(option, distance, coords, entity)
                if hidden then reasons[#reasons + 1] = ('%s : %s'):format(tostring(option.name or option.label), hidden) return nil end
                local ctx = { entity = entity, zone = zone and zone.id, coords = coords, distance = distance }
                state.selections[#state.selections + 1] = { t = emu.now, name = option.name, label = option.label, zone = ctx.zone }
                run(option, ctx, zone)
                return { option = option, zone = zone, distance = distance, coords = coords }
            end
            local ids = {}
            for id in pairs(state.zones) do ids[#ids + 1] = id end
            table.sort(ids)
            for _, id in ipairs(ids) do
                local zone = state.zones[id]
                local coords = o.coords and toVec(o.coords) or zone.coords
                local distance = #(pos - coords)
                if not zone:contains(coords) then
                    reasons[#reasons + 1] = ('zone %d : point visé hors de la zone'):format(id)
                elseif distance > 20 then
                    reasons[#reasons + 1] = ('zone %d : hors de portée du rayon (%.1f m)'):format(id, distance)
                else
                    for _, option in ipairs(zone.options) do
                        local r = try(option, zone, distance, coords)
                        if r then return true, r end
                    end
                end
            end
            local entity = o.entity or 0
            if entity ~= 0 and env.DoesEntityExist(entity) then
                local coords = o.coords and toVec(o.coords) or env.GetEntityCoords(entity)
                local distance = #(pos - coords)
                local etype = env.GetEntityType(entity)
                local lists = {
                    env.IsPedAPlayer(entity) and state.players or etype == 1 and state.peds or etype == 2 and state.vehicles or state.objects,
                    state.models[env.GetEntityModel(entity)], state.localEntities[entity],
                }
                if distance <= 20 then
                    for i = 1, 3 do
                        for _, option in ipairs(lists[i] or {}) do
                            local r = try(option, nil, distance, coords, entity)
                            if r then return true, r end
                        end
                    end
                else
                    reasons[#reasons + 1] = ('entité %d : hors de portée du rayon'):format(entity)
                end
            end
            for _, option in ipairs(state.global) do
                local r = try(option, nil, 0, o.coords and toVec(o.coords) or pos, entity)
                if r then return true, r end
            end
            return false, #reasons > 0 and table.concat(reasons, ' ; ') or 'aucune option correspondante'
        end

        function player:target(filter, o) return state.select(filter, o) end
    end

    emu:defineResource('ox_target', { client = client })

    function mock:select(player, filter, o)
        local state = self.players[player.id]
        if not state then return false, 'ox_target non démarré pour ce joueur' end
        return state.select(filter, o)
    end
    -- Zones et options enregistrées chez un joueur (pour les vérifications)
    function mock:zones(player) return self.players[player.id] and self.players[player.id].zones or {} end
    function mock:state(player) return self.players[player.id] end

    if opts.autostart ~= false then emu:start('ox_target') end
    return mock
end
