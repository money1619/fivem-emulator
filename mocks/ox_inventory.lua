-- mocks/ox_inventory.lua — ox_inventory 2.45.0 simulé côté serveur (inventaires en mémoire), d'après
-- modules/inventory/server.lua, modules/items/server.lua et modules/hooks/server.lua de la version installée.
--
--   local inv = require('mocks.ox_inventory')(emu, {
--       items = { water = { label = 'Eau', weight = 500 }, phone = { label = 'Téléphone', weight = 190, stack = false } },
--   })
--   local p = emu:addPlayer({ inventory = { water = 2 } })     -- sans ESX : inventaire créé à la connexion
--   exports.ox_inventory:AddItem(source, 'water', 1)           -- dans une ressource testée
--   inv:count(p, 'water')                                      -- dans le test
--
-- Comme ox_inventory : objets empilables par défaut (stack = true), poids 0 par défaut, empilement seulement si
-- les métadonnées sont identiques (table.matches), AddItem ne contrôle pas le poids (CanCarryItem le fait),
-- RemoveItem compare les métadonnées strictement par défaut, crochets createItem / swapItems avec filtres.
-- Avec le mock ESX en mode ox, l'inventaire est créé par ESX et l'argent liquide est l'objet « money ».
-- Non simulé : armes, conteneurs, usure dans le temps, boutiques, fouilles, dépôts au sol, base de données.
local unpack = table.unpack

-- table.contains et table.matches d'ox_lib (imports/table/shared.lua)
local function contains(tbl, value)
    if type(value) ~= 'table' then
        for _, v in pairs(tbl) do if v == value then return true end end
        return false
    end
    local set = {}
    for _, v in pairs(tbl) do set[v] = true end
    for _, v in pairs(value) do if not set[v] then return false end end
    return true
end

local function matches(t1, t2)
    local type1, type2 = type(t1), type(t2)
    if type1 ~= type2 then return false end
    if type1 ~= 'table' and type2 ~= 'table' then return t1 == t2 end
    for k, v1 in pairs(t1) do
        local v2 = t2[k]
        if v2 == nil or not matches(v1, v2) then return false end
    end
    for k in pairs(t2) do if t1[k] == nil then return false end end
    return true
end

local function clone(t) local r = {} for k, v in pairs(t) do r[k] = v end return r end

return function(emu, opts)
    opts = opts or {}
    local mock = { hooks = {}, inventories = {}, stashes = {}, shops = {} }
    emu.mocks.ox_inventory = mock
    local shared = { playerslots = opts.slots or 50, playerweight = opts.maxWeight or 30000 }
    local env -- environnement serveur de la ressource ox_inventory (natives)

    -- Liste des objets (modules/items/shared.lua : poids 0, close et stack vrais par défaut)
    local ItemList = {}
    local defs = { money = { label = 'Money' }, black_money = { label = 'Argent sale' } }
    for name, def in pairs(opts.items or {}) do defs[name] = def end
    for name, def in pairs(defs) do
        local item = clone(def)
        item.name = name
        item.weight = item.weight or 0
        if item.close == nil then item.close = true end
        if item.stack == nil then item.stack = true end
        item.count = 0
        ItemList[name] = item
    end
    mock.items = ItemList

    local function Items(name)
        if not name then return ItemList end
        if type(name) ~= 'string' then return end
        name = name:lower()
        if name:sub(0, 7) == 'weapon_' then name = name:upper() end
        return ItemList[name]
    end

    ---------------------------------------------------------------------------
    -- Crochets (modules/hooks/server.lua)
    ---------------------------------------------------------------------------
    local eventHooks, hookId = {}, 0

    local function itemFilter(filter, item, secondItem)
        local itemName = type(item) == 'table' and item.name or item
        if not itemName or not filter[itemName] then
            if type(secondItem) ~= 'table' or not filter[secondItem.name] then return false end
        end
        return true
    end

    local function inventoryFilter(filter, inventory, secondInventory)
        for i = 1, #filter do
            local pattern = filter[i]
            if inventory:match(pattern) or (secondInventory and secondInventory:match(pattern)) then return true end
        end
        return false
    end

    local function TriggerEventHooks(event, payload)
        local hooks = eventHooks[event]
        if hooks then
            local fromInventory = payload.fromInventory and tostring(payload.fromInventory) or payload.inventoryId and tostring(payload.inventoryId) or payload.shopType and tostring(payload.shopType)
            local toInventory = payload.toInventory and tostring(payload.toInventory)
            for i = 1, #hooks do
                local hook = hooks[i]
                local skip = (hook.itemFilter and not itemFilter(hook.itemFilter, payload.fromSlot or payload.item or payload.itemName or payload.recipe, payload.toSlot))
                    or (hook.inventoryFilter and not inventoryFilter(hook.inventoryFilter, fromInventory, toInventory))
                    or (hook.typeFilter and not hook.typeFilter[payload.inventoryType or payload.shopType or payload.fromType])
                if not skip then
                    local ok, response = pcall(hook.fn, payload)
                    -- l'erreur d'un crochet s'affiche dans la console de sa ressource ; ox_inventory continue
                    if not ok then emu:_error(emu.server, ('crochet ox_inventory %s:%s : %s'):format(tostring(hook.resource), event, tostring(response))) end
                    if event == 'createItem' then
                        if type(response) == 'table' then payload.metadata = response end
                    elseif response == false then
                        return false
                    end
                end
            end
        end
        if event == 'createItem' then return payload.metadata end
        return true
    end

    local function registerHook(event, cb, options)
        if not eventHooks[event] then eventHooks[event] = {} end
        hookId = hookId + 1
        local hook = { fn = cb, resource = env.GetInvokingResource() or emu:callerResource(emu.server), hookId = hookId }
        if options then for k, v in pairs(options) do hook[k] = v end end
        eventHooks[event][#eventHooks[event] + 1] = hook
        return hookId
    end

    local function removeResourceHooks(resource, id)
        for _, hooks in pairs(eventHooks) do
            for i = #hooks, 1, -1 do
                local hook = hooks[i]
                if hook.resource == resource and (not id or hook.hookId == id) then table.remove(hooks, i) end
            end
        end
    end
    mock.hooks = eventHooks

    ---------------------------------------------------------------------------
    -- Inventaires
    ---------------------------------------------------------------------------
    local Inventories = mock.inventories
    local OxInventory = {}
    OxInventory.__index = OxInventory

    function OxInventory:syncSlotsWithClients(slots, syncOwner)
        for playerId in pairs(self.openedBy) do
            if self.id ~= playerId and Inventories[playerId] then
                env.TriggerClientEvent('ox_inventory:updateSlots', playerId, slots, Inventories[playerId].weight)
            end
        end
        if syncOwner and self.player then
            env.TriggerClientEvent('ox_inventory:updateSlots', self.id, slots, self.weight)
        end
    end

    local Inventory = setmetatable({ accounts = opts.accounts or { money = 0, black_money = 0 } }, {
        __call = function(_, inv)
            if type(inv) == 'table' then
                if getmetatable(inv) == OxInventory then return inv end
                inv = inv.id
            end
            local found = Inventories[inv] or Inventories[tonumber(inv)]
            if found then return found end
            -- coffre déclaré avec RegisterStash : créé au premier accès
            local stash = mock.stashes[inv]
            if stash then
                return mock.Inventory.Create(stash.name, stash.label, 'stash', stash.slots, 0, stash.maxWeight, stash.owner, {})
            end
            return false
        end,
    })
    mock.Inventory = Inventory

    local function assertMetadata(metadata)
        if metadata and type(metadata) ~= 'table' then metadata = metadata and { type = metadata or nil } end
        return metadata
    end

    function Inventory.SlotWeight(item, slot, ignoreCount)
        local weight = ignoreCount and item.weight or item.weight * (slot.count or 1)
        if not slot.metadata then slot.metadata = {} end
        if slot.metadata.weight then
            weight = weight + (ignoreCount and slot.metadata.weight or (slot.metadata.weight * (slot.count or 1)))
        end
        return weight
    end

    function Inventory.CalculateWeight(items)
        local weight = 0
        for _, v in pairs(items) do
            local item = Items(v.name)
            if item then weight = weight + Inventory.SlotWeight(item, v) end
        end
        return weight
    end

    function Inventory.Create(id, label, invType, slots, weight, maxWeight, owner, items)
        local self = {
            id = id, label = label or id, type = invType, slots = slots, weight = weight,
            maxWeight = maxWeight or shared.playerweight, owner = owner, items = type(items) == 'table' and items or {},
            open = false, openedBy = {}, changed = false, time = os.time(),
        }
        if invType ~= 'player' and owner and type(owner) ~= 'boolean' then self.id = ('%s:%s'):format(self.id, owner) end
        if weight == 0 and next(self.items) then self.weight = Inventory.CalculateWeight(self.items) end
        Inventories[self.id] = setmetatable(self, OxInventory)
        return Inventories[self.id]
    end

    function Inventory.Remove(inv)
        inv = Inventory(inv)
        if inv then Inventories[inv.id] = nil end
    end

    -- modules/bridge : synchronisation avec ESX (xPlayer.syncInventory) quand le mock ESX est en mode ox
    local function esxMode() return emu.mocks.esx and emu.mocks.esx.ox and emu.mocks.esx.ESX end

    function Inventory.GetAccountItemCounts(inv)
        inv = Inventory(inv)
        if not inv then return end
        local accounts = clone(Inventory.accounts)
        for _, v in pairs(inv.items) do
            if accounts[v.name] then accounts[v.name] = accounts[v.name] + v.count end
        end
        return accounts
    end

    local function syncInventory(inv)
        local ESX = esxMode()
        if not ESX then return end
        local accounts = Inventory.GetAccountItemCounts(inv)
        local player = accounts and ESX.GetPlayerFromId(inv.id)
        if player then player.syncInventory(inv.weight, inv.maxWeight, inv.items, accounts) end
    end

    -- Items.Metadata (sans armes ni conteneurs) avec le crochet createItem
    local function itemMetadata(inv, item, metadata, count)
        if type(inv) ~= 'table' then inv = Inventory(inv) end
        metadata = not metadata and {} or type(metadata) == 'string' and { type = metadata } or metadata
        if not count then count = 1 end
        if not metadata.durability then
            if item.degrade then
                metadata.durability = os.time() + (item.degrade * 60)
                metadata.degrade = item.degrade
            elseif item.durability then
                metadata.durability = 100
            end
        end
        if count > 1 and not item.stack then count = 1 end
        local response = TriggerEventHooks('createItem', { inventoryId = inv and inv.id, metadata = metadata, item = item, count = count })
        if type(response) == 'table' then metadata = response end
        return metadata, count
    end

    function Inventory.SetSlot(inv, item, count, metadata, slot)
        inv = Inventory(inv)
        if not inv then return end
        local currentSlot = inv.items[slot]
        local newCount = currentSlot and currentSlot.count + count or count
        local newWeight = currentSlot and inv.weight - currentSlot.weight or inv.weight
        if currentSlot and newCount < 1 then
            env.TriggerClientEvent('ox_inventory:itemNotify', inv.id, { currentSlot, 'ui_removed', currentSlot.count })
            currentSlot = nil
        else
            currentSlot = { name = item.name, label = item.label, weight = item.weight, slot = slot, count = newCount,
                            description = item.description, metadata = metadata, stack = item.stack, close = item.close }
            local slotWeight = Inventory.SlotWeight(item, currentSlot)
            currentSlot.weight = slotWeight
            newWeight = newWeight + slotWeight
            env.TriggerClientEvent('ox_inventory:itemNotify', inv.id, { currentSlot, count < 0 and 'ui_removed' or 'ui_added', math.abs(count) })
        end
        inv.weight = newWeight
        inv.items[slot] = currentSlot
        inv.changed = true
        return currentSlot
    end

    function Inventory.GetItem(inv, item, metadata, returnsCount)
        if type(item) ~= 'table' then item = Items(item) end
        if item then
            item = returnsCount and item or clone(item)
            inv = Inventory(inv)
            local count = 0
            if inv then
                metadata = assertMetadata(metadata)
                for _, v in pairs(inv.items) do
                    if v.name == item.name and (not metadata or contains(v.metadata, metadata)) then count = count + v.count end
                end
            end
            if returnsCount then return count end
            item.count = count
            return item
        end
    end

    function Inventory.GetSlot(inv, slotId)
        if not inv or type(slotId) ~= 'number' then return end
        inv = Inventory(inv)
        return inv and inv.items[slotId] or nil
    end

    function Inventory.SetMetadata(inv, slotId, metadata)
        if not inv or type(slotId) ~= 'number' then return end
        inv = Inventory(inv)
        local slot = inv and inv.items[slotId]
        if not slot then return end
        local item = Items(slot.name)
        slot.metadata = type(metadata) == 'table' and metadata or { type = metadata or nil }
        inv.changed = true
        if type(metadata) == 'table' and metadata.weight then
            inv.weight = inv.weight - slot.weight
            slot.weight = Inventory.SlotWeight(item, slot)
            inv.weight = inv.weight + slot.weight
        end
        inv:syncSlotsWithClients({ { item = slot, inventory = inv.id } }, true)
        if inv.player then syncInventory(inv) end
    end

    function Inventory.SetMaxWeight(inv, maxWeight)
        inv = Inventory(inv)
        if not inv or type(maxWeight) ~= 'number' then return end
        inv.maxWeight = maxWeight
        if inv.player then env.TriggerClientEvent('ox_inventory:refreshMaxWeight', inv.id, { inventoryId = inv.id, maxWeight = inv.maxWeight }) end
    end

    function Inventory.AddItem(inv, item, count, metadata, slot, cb)
        if type(item) ~= 'table' then item = Items(item) end
        if not item then return false, 'invalid_item' end
        if type(count) ~= 'number' then return false, 'invalid_count' end
        count = math.floor(count + 0.5)
        if count <= 0 then return false, 'negative_count' end
        inv = Inventory(inv)
        if not (inv and inv.slots) then return false, 'invalid_inventory' end
        local toSlot, slotMetadata, slotCount
        local success, response = false, nil
        metadata = assertMetadata(metadata)
        if slot then
            local slotData = inv.items[slot]
            slotMetadata, slotCount = itemMetadata(inv, item, metadata and clone(metadata) or {}, count)
            if not slotData or (item.stack and slotData.name == item.name and matches(slotData.metadata, slotMetadata)) then toSlot = slot end
        end
        if not toSlot then
            local items = inv.items
            slotMetadata, slotCount = itemMetadata(inv, item, metadata and clone(metadata) or {}, count)
            for i = 1, inv.slots do
                local slotData = items[i]
                if item.stack and slotData ~= nil and slotData.name == item.name and matches(slotData.metadata, slotMetadata) then
                    toSlot = i
                    break
                elseif not item.stack and not slotData then
                    if not toSlot then toSlot = {} end
                    toSlot[#toSlot + 1] = { slot = i, count = slotCount, metadata = slotMetadata }
                    if count == slotCount then break end
                    count = count - 1
                    slotMetadata, slotCount = itemMetadata(inv, item, metadata and clone(metadata) or {}, count)
                elseif not toSlot and not slotData then
                    toSlot = i
                end
            end
        end
        if not toSlot then return false, 'inventory_full' end
        inv.changed = true
        if type(toSlot) == 'number' then
            Inventory.SetSlot(inv, item, slotCount, slotMetadata, toSlot)
            if inv.player then syncInventory(inv) end
            inv:syncSlotsWithClients({ { item = inv.items[toSlot], inventory = inv.id } }, true)
            success, response = true, inv.items[toSlot]
        else
            for i = 1, #toSlot do
                local data = toSlot[i]
                Inventory.SetSlot(inv, item, data.count, data.metadata, data.slot)
                toSlot[i] = { item = inv.items[data.slot], inventory = inv.id }
            end
            if inv.player then syncInventory(inv) end
            inv:syncSlotsWithClients(toSlot, true)
            for i = 1, #toSlot do toSlot[i] = toSlot[i].item end
            success, response = true, toSlot
        end
        if cb then return cb(success, response) end
        return success, response
    end

    -- Recherche sur une table d'emplacements (partagée par l'export serveur et l'export client)
    local function searchSlots(inv, search, items, metadata)
        if items then
            if inv then
                if search == 'slots' then search = 1 elseif search == 'count' then search = 2 end
                if type(items) == 'string' then items = { items } end
                metadata = assertMetadata(metadata)
                local itemCount = #items
                local returnData = {}
                for i = 1, itemCount do
                    local item = string.lower(items[i])
                    if item:sub(0, 7) == 'weapon_' then item = string.upper(item) end
                    if search == 1 then returnData[item] = {} elseif search == 2 then returnData[item] = 0 end
                    for _, v in pairs(inv) do
                        if v.name == item then
                            if not v.metadata then v.metadata = {} end
                            if not metadata or contains(v.metadata, metadata) then
                                if search == 1 then
                                    returnData[item][#returnData[item] + 1] = inv[v.slot]
                                elseif search == 2 then
                                    returnData[item] = returnData[item] + v.count
                                end
                            end
                        end
                    end
                end
                if next(returnData) then return itemCount == 1 and returnData[items[1]] or returnData end
            end
        end
        return false
    end

    function Inventory.Search(inv, search, items, metadata)
        inv = Inventory(inv)
        return searchSlots(inv and inv.items, search, items, metadata)
    end

    function Inventory.GetItemSlots(inv, item, metadata, strict)
        if type(item) ~= 'table' then item = Items(item) end
        if not item then return end
        inv = Inventory(inv)
        if not (inv and inv.slots) then return end
        local totalCount, slots, emptySlots = 0, {}, inv.slots
        if strict == nil then strict = true end
        local tablematch = strict and matches or contains
        for k, v in pairs(inv.items) do
            emptySlots = emptySlots - 1
            if v.name == item.name then
                if metadata and v.metadata == nil then v.metadata = {} end
                if not metadata or tablematch(v.metadata, metadata) then
                    totalCount = totalCount + v.count
                    slots[k] = v.count
                end
            end
        end
        return slots, totalCount, emptySlots
    end

    function Inventory.RemoveItem(inv, item, count, metadata, slot, ignoreTotal, strict)
        if type(item) ~= 'table' then item = Items(item) end
        if not item then return false, 'invalid_item' end
        if type(count) ~= 'number' then return false, 'invalid_count' end
        count = math.floor(count + 0.5)
        if count <= 0 then return false, 'negative_count' end
        inv = Inventory(inv)
        if not (inv and inv.slots) then return false, 'invalid_inventory' end
        metadata = assertMetadata(metadata)
        if strict == nil then strict = true end
        local itemSlots, totalCount = Inventory.GetItemSlots(inv, item, metadata, strict)
        if not itemSlots then return false end
        if totalCount and count > totalCount then
            if not ignoreTotal then return false, 'not_enough_items' end
            count = totalCount
        end
        local removed, total, slots = 0, count, {}
        if slot and itemSlots[slot] then
            removed = count
            Inventory.SetSlot(inv, item, -count, inv.items[slot].metadata, slot)
            slots[#slots + 1] = inv.items[slot] or slot
        elseif itemSlots and totalCount > 0 then
            -- ordre des emplacements : croissant (pairs d'ox_inventory n'a pas d'ordre garanti)
            local keys = {}
            for k in pairs(itemSlots) do keys[#keys + 1] = k end
            table.sort(keys)
            for _, k in ipairs(keys) do
                local v = itemSlots[k]
                if removed < total then
                    if v == count then
                        env.TriggerClientEvent('ox_inventory:itemNotify', inv.id, { inv.items[k], 'ui_removed', v })
                        removed = total
                        inv.weight = inv.weight - inv.items[k].weight
                        inv.items[k] = nil
                        slots[#slots + 1] = inv.items[k] or k
                    elseif v > count then
                        Inventory.SetSlot(inv, item, -count, inv.items[k].metadata, k)
                        slots[#slots + 1] = inv.items[k] or k
                        removed = total
                        count = v - count
                    else
                        env.TriggerClientEvent('ox_inventory:itemNotify', inv.id, { inv.items[k], 'ui_removed', v })
                        removed = removed + v
                        count = count - v
                        inv.weight = inv.weight - inv.items[k].weight
                        inv.items[k] = nil
                        slots[#slots + 1] = k
                    end
                else break end
            end
        end
        if removed > 0 then
            inv.changed = true
            if inv.player then syncInventory(inv) end
            local array = {}
            for k, v in pairs(slots) do array[k] = { item = type(v) == 'number' and { slot = v } or v, inventory = inv.id } end
            inv:syncSlotsWithClients(array, true)
            return true
        end
        return false, 'not_enough_items'
    end

    function Inventory.SetItem(inv, item, count, metadata)
        if type(item) ~= 'table' then item = Items(item) end
        if not item then return false, 'invalid_item' end
        if type(count) ~= 'number' then return false, 'invalid_count' end
        count = math.floor(count + 0.5)
        if count < 0 then return false, 'negative_count' end
        inv = Inventory(inv)
        if not inv then return false, 'invalid_inventory' end
        inv.changed = true
        local itemCount = Inventory.GetItem(inv, item.name, metadata, true)
        if count > itemCount then
            return Inventory.AddItem(inv, item.name, count - itemCount, metadata)
        elseif count < itemCount then
            return Inventory.RemoveItem(inv, item.name, itemCount - count, metadata)
        end
    end

    function Inventory.CanCarryItem(inv, item, count, metadata)
        if type(item) ~= 'table' then item = Items(item) end
        if item then
            inv = Inventory(inv)
            if inv then
                local itemSlots, _, emptySlots = Inventory.GetItemSlots(inv, item, type(metadata) == 'table' and metadata or { type = metadata or nil })
                if not itemSlots then return end
                local weight = type(metadata) == 'table' and metadata.weight or item.weight
                if next(itemSlots) or emptySlots > 0 then
                    if not count then count = 1 end
                    if not item.stack and emptySlots < count then return false end
                    if weight == 0 then return true end
                    return inv.weight + (weight * count) <= inv.maxWeight
                end
            end
        end
    end

    function Inventory.CanCarryAmount(inv, item)
        if type(item) ~= 'table' then item = Items(item) end
        inv = Inventory(inv)
        if inv and item then return math.floor((inv.maxWeight - inv.weight) / item.weight) end
    end

    function Inventory.CanCarryWeight(inv, weight)
        inv = Inventory(inv)
        if not inv then return end
        local availableWeight = inv.maxWeight - inv.weight
        return availableWeight >= weight, availableWeight
    end

    function Inventory.CanSwapItem(inv, firstItem, firstItemCount, testItem, testItemCount)
        inv = Inventory(inv)
        if not inv then return end
        local firstItemData = Inventory.GetItem(inv, firstItem)
        local testItemData = Inventory.GetItem(inv, testItem)
        if firstItemData and testItemData and firstItemData.count >= firstItemCount then
            local weightWithoutFirst = inv.weight - (firstItemData.weight * firstItemCount)
            return weightWithoutFirst + (testItemData.weight * testItemCount) <= inv.maxWeight
        end
    end

    function Inventory.GetEmptySlot(inv)
        local inventory = Inventory(inv)
        if not inventory then return end
        for i = 1, inventory.slots do if not inventory.items[i] then return i end end
    end

    function Inventory.GetSlotForItem(inv, itemName, metadata)
        local inventory, item = Inventory(inv), Items(itemName)
        if not inventory or not item then return end
        metadata = assertMetadata(metadata)
        local emptySlot
        for i = 1, inventory.slots do
            local slotData = inventory.items[i]
            if item.stack and slotData and slotData.name == item.name and matches(slotData.metadata, metadata) then
                return i
            elseif not item.stack and not slotData and not emptySlot then
                emptySlot = i
            end
        end
        return emptySlot
    end

    local function sortedSlots(items)
        local keys = {}
        for k in pairs(items) do keys[#keys + 1] = k end
        table.sort(keys)
        return keys
    end

    -- strict : métadonnées identiques (table.matches) ; sinon partielles (table.contains). Défaut : partielles.
    function Inventory.GetSlotWithItem(inv, itemName, metadata, strict)
        local inventory, item = Inventory(inv), Items(itemName)
        if not inventory or not item then return end
        metadata = assertMetadata(metadata)
        local tablematch = strict and matches or contains
        for _, k in ipairs(sortedSlots(inventory.items)) do
            local slotData = inventory.items[k]
            if slotData.name == item.name and (not metadata or tablematch(slotData.metadata, metadata)) then return slotData end
        end
    end

    function Inventory.GetSlotIdWithItem(inv, itemName, metadata, strict)
        local slot = Inventory.GetSlotWithItem(inv, itemName, metadata, strict)
        return slot and slot.slot
    end

    function Inventory.GetSlotsWithItem(inv, itemName, metadata, strict)
        local inventory, item = Inventory(inv), Items(itemName)
        if not inventory or not item then return end
        metadata = assertMetadata(metadata)
        local response, tablematch = {}, strict and matches or contains
        for _, k in ipairs(sortedSlots(inventory.items)) do
            local slotData = inventory.items[k]
            if slotData.name == item.name and (not metadata or tablematch(slotData.metadata, metadata)) then response[#response + 1] = slotData end
        end
        return response
    end

    function Inventory.GetSlotIdsWithItem(inv, itemName, metadata, strict)
        local items = Inventory.GetSlotsWithItem(inv, itemName, metadata, strict)
        if items then
            for i = 1, #items do items[i] = items[i].slot end
            return items
        end
    end

    function Inventory.GetItemCount(inv, itemName, metadata, strict)
        local inventory, item = Inventory(inv), Items(itemName)
        if not inventory or not item then return 0 end
        metadata = assertMetadata(metadata)
        local count, tablematch = 0, strict and matches or contains
        for _, slotData in pairs(inventory.items) do
            if slotData.name == item.name and (not metadata or tablematch(slotData.metadata, metadata)) then count = count + slotData.count end
        end
        return count
    end

    function Inventory.Clear(inv, keep)
        inv = Inventory(inv)
        if not inv or not next(inv.items) then return end
        local updateSlots, newWeight = {}, 0
        for slot, v in pairs(inv.items) do
            local kept = keep and (type(keep) == 'table' and contains(keep, v.name) or keep == v.name)
            if kept then newWeight = newWeight + v.weight
            else
                inv.items[slot] = nil
                updateSlots[#updateSlots + 1] = { item = { slot = slot }, inventory = inv.id }
            end
        end
        inv.weight, inv.changed = newWeight, true
        if inv.player then syncInventory(inv) end
        inv:syncSlotsWithClients(updateSlots, true)
    end

    -- server.lua setPlayerInventory ; données au format liste { slot, name, count, metadata } ou ancien format
    -- { nom = nombre } (convertInventory : les comptes ESX deviennent des objets, emplacements par ordre alphabétique)
    local function setPlayerData(player)
        if esxMode() then
            return { source = player.source, name = player.name, groups = { [player.job.name] = player.job.grade },
                     sex = player.sex or player.variables.sex, dateofbirth = player.dateofbirth or player.variables.dateofbirth }
        end
        return { source = player.source, name = player.name, groups = player.groups or {} }
    end

    local function convertInventory(playerId, items)
        local ESX = esxMode()
        local player = ESX and ESX.GetPlayerFromId(playerId)
        if player then
            for name in pairs(Inventory.accounts) do
                if not items[name] then
                    local account = player.getAccount(name)
                    if account and account.money then items[name] = account.money end
                end
            end
        end
        local names = {}
        for name in pairs(items) do names[#names + 1] = name end
        table.sort(names)
        local returnData, totalWeight, slot = {}, 0, 0
        for _, name in ipairs(names) do
            local item, count = Items(name), items[name]
            if item and count > 0 then
                local metadata = itemMetadata(playerId, item, false, count)
                local weight = Inventory.SlotWeight(item, { count = count, metadata = metadata })
                totalWeight = totalWeight + weight
                slot = slot + 1
                returnData[slot] = { name = item.name, label = item.label, weight = weight, slot = slot, count = count,
                                     description = item.description, metadata = metadata, stack = item.stack, close = item.close }
            end
        end
        return returnData, totalWeight
    end

    function mock.setPlayerInventory(player, data)
        local inventory, totalWeight = {}, 0
        -- inventaire vide : traité comme l'ancien format pour que l'argent ESX devienne l'objet « money »
        -- (un vrai joueur ESX + ox a toujours son argent sous forme d'objet)
        if type(data) == 'table' and next(data) == nil then
            inventory, totalWeight = convertInventory(player.source, data)
        elseif type(data) == 'table' then
            for _, v in pairs(data) do
                if type(v) == 'number' or not v.count or not v.slot then
                    inventory, totalWeight = convertInventory(player.source, data)
                    break
                else
                    local item = Items(v.name)
                    if item then
                        v.metadata = v.metadata or {}
                        local weight = Inventory.SlotWeight(item, v)
                        totalWeight = totalWeight + weight
                        inventory[v.slot] = { name = item.name, label = item.label, weight = weight, slot = v.slot, count = v.count,
                                              description = item.description, metadata = v.metadata, stack = item.stack, close = item.close }
                    end
                end
            end
        end
        player.source = tonumber(player.source)
        local inv = Inventory.Create(player.source, player.name, 'player', shared.playerslots, totalWeight, shared.playerweight, player.identifier, inventory)
        if inv then
            inv.player = setPlayerData(player)
            inv.player.ped = env.GetPlayerPed(player.source)
            syncInventory(inv)
            env.TriggerClientEvent('ox_inventory:setPlayerInventory', player.source, {}, inventory, totalWeight, inv.player)
        end
    end

    -- RegisterStash(name, label, slots, maxWeight, owner) : l'inventaire est créé au premier accès
    local function registerStash(name, label, slots, maxWeight, owner, groups, coords)
        mock.stashes[name] = { name = name, label = label, owner = owner, slots = tonumber(slots), maxWeight = tonumber(maxWeight),
                               groups = groups, coords = coords }
    end

    ---------------------------------------------------------------------------
    -- Ressource « ox_inventory »
    ---------------------------------------------------------------------------
    emu:defineResource('ox_inventory', {
        server = function(e)
            env = e
            local function getInventory(inv, owner)
                if not inv then return Inventory end
                if type(inv) == 'table' or type(inv) == 'number' then return Inventory(inv) end
                return Inventory(owner and ('%s:%s'):format(inv, owner) or inv)
            end
            local exports = {
                Inventory = getInventory, GetInventory = getInventory,
                GetInventoryItems = function(inv, owner) local i = getInventory(inv, owner) return i and i.items end,
                Items = function(item) return Items(item) end, ItemList = function(item) return Items(item) end,
                GetItem = Inventory.GetItem, SetItem = Inventory.SetItem, GetSlot = Inventory.GetSlot,
                SetMetadata = Inventory.SetMetadata, SetMaxWeight = Inventory.SetMaxWeight, AddItem = Inventory.AddItem,
                Search = Inventory.Search, GetItemSlots = Inventory.GetItemSlots, RemoveItem = Inventory.RemoveItem,
                CanCarryItem = Inventory.CanCarryItem, CanCarryAmount = Inventory.CanCarryAmount,
                CanCarryWeight = Inventory.CanCarryWeight, CanSwapItem = Inventory.CanSwapItem,
                GetEmptySlot = Inventory.GetEmptySlot, GetSlotForItem = Inventory.GetSlotForItem,
                GetSlotWithItem = Inventory.GetSlotWithItem, GetSlotIdWithItem = Inventory.GetSlotIdWithItem,
                GetSlotsWithItem = Inventory.GetSlotsWithItem, GetSlotIdsWithItem = Inventory.GetSlotIdsWithItem,
                GetItemCount = Inventory.GetItemCount, ClearInventory = Inventory.Clear, RemoveInventory = Inventory.Remove,
                RegisterStash = registerStash, setPlayerInventory = mock.setPlayerInventory,
                registerHook = registerHook,
                -- Boutiques : RegisterShop(type, { name, inventory = { { name, price, metadata, currency } }, locations })
                RegisterShop = function(shopType, def) mock.shops[shopType] = emu.netCopy(def) end,
                removeHooks = function(id) removeResourceHooks(env.GetInvokingResource() or emu:callerResource(emu.server), id) end,
            }
            for name, fn in pairs(exports) do env.exports(name, fn) end
            env.AddEventHandler('onResourceStop', removeResourceHooks)
            env.TriggerEvent('ox_inventory:loadInventory', Inventory)

            -- Sans ESX en mode ox : inventaire du joueur créé à la connexion (addPlayer{ inventory = … })
            env.AddEventHandler('playerJoining', function()
                local src = tonumber(env.source)
                if esxMode() then return end
                local p = emu.players[src]
                mock.setPlayerInventory({ source = src, name = env.GetPlayerName(src),
                                          identifier = env.GetPlayerIdentifierByType(src, 'license') }, emu.netCopy(p.opts.inventory or {}))
            end)
            env.AddEventHandler('playerDropped', function() Inventory.Remove(tonumber(env.source)) end)
            env.AddEventHandler('esx:setJob', function(source, job, lastJob)
                local inventory = Inventory(source)
                if not inventory or not inventory.player then return end
                inventory.player.groups[lastJob.name] = nil
                inventory.player.groups[job.name] = job.grade
            end)
        end,

        -- Côté client : copie de l'inventaire du joueur tenue à jour par les événements du serveur
        client = function(e, _, player)
            local items, weight = {}, 0
            local state = { items = items, notify = {} }
            player.oxInventory = state
            local function count(name)
                local n = 0
                for _, v in pairs(items) do if v.name == name then n = n + v.count end end
                return n
            end
            e.RegisterNetEvent('ox_inventory:setPlayerInventory', function(_, inventory, w)
                for k in pairs(items) do items[k] = nil end
                for _, v in pairs(inventory) do items[v.slot] = v end
                weight = w
            end)
            e.RegisterNetEvent('ox_inventory:updateSlots', function(data, w)
                local changed = {}
                for i = 1, #data do
                    local v = data[i]
                    if not v.inventory or v.inventory == player.id then
                        local item = v.item
                        local cur = items[item.slot]
                        if cur and cur.name then changed[cur.name] = true end
                        if item.count and item.name then items[item.slot] = item changed[item.name] = true else items[item.slot] = nil end
                    end
                end
                weight = w or weight
                for name in pairs(changed) do e.TriggerEvent('ox_inventory:itemCount', name, count(name)) end
            end)
            e.RegisterNetEvent('ox_inventory:itemNotify', function(data) state.notify[#state.notify + 1] = { t = emu.now, data = data } end)
            e.RegisterNetEvent('ox_inventory:refreshMaxWeight', function(data) state.maxWeight = data.maxWeight end)
            e.exports('Search', function(search, item, metadata) return searchSlots(items, search, item, metadata) end)
            e.exports('GetItemCount', function(name, metadata, strict)
                local n, tablematch = 0, strict and matches or contains
                for _, v in pairs(items) do
                    if v.name == name and (not metadata or tablematch(v.metadata or {}, assertMetadata(metadata))) then n = n + v.count end
                end
                return n
            end)
            e.exports('GetPlayerItems', function() return items end)
            e.exports('GetPlayerWeight', function() return weight end)
            e.exports('Items', function(name)
                if not name then return ItemList end
                local item = Items(name)
                if item then item = clone(item) item.count = count(item.name) end
                return item
            end)
        end,
    })

    -- Aides pour les tests
    local function id(p) return type(p) == 'table' and (p.id or p) or p end
    function mock:inventory(p) return Inventory(id(p)) end
    -- Sonde pour emu:fuzz : nombre de chaque objet du joueur
    emu:addProbe('ox_inventory', function(player)
        local inv = Inventory(player.id)
        if not inv then return nil end
        local r = {}
        for _, item in pairs(inv.items) do r[item.name] = (r[item.name] or 0) + item.count end
        return r
    end)
    function mock:count(p, name, metadata, strict) return Inventory.GetItemCount(id(p), name, metadata, strict) end
    function mock:clientCount(player, name)
        local n = 0
        for _, v in pairs(player.oxInventory and player.oxInventory.items or {}) do if v.name == name then n = n + v.count end end
        return n
    end
    -- Déplacement d'objets comme le glisser-déposer de l'interface (rappel ox_inventory:swapItems, simplifié) :
    -- data = { fromInventory, fromSlot, toInventory, toSlot, count } ; renvoie true ou false (+ raison)
    -- Achat simulé comme ox_inventory:buyItem : distance (10 m) si la boutique a des emplacements, argent (objet
    -- `currency`, « money » par défaut), place dans l'inventaire, crochet buyItem, puis AddItem (crochet createItem).
    -- index = rang de l'article dans def.inventory ; shopId = rang de l'emplacement. Renvoie true ou false, raison.
    function mock:buy(player, shopType, index, count, shopId)
        count = count or 1
        local shop = mock.shops[shopType]
        if not shop then return false, 'unknown_shop' end
        local src = id(player)
        if shop.locations then
            local loc = shopId and shop.locations[shopId]
            if not loc then return false, 'no_location' end
            local p = emu.players[src]
            local dx, dy, dz = p.pos.x - loc.x, p.pos.y - loc.y, p.pos.z - loc.z
            if math.sqrt(dx * dx + dy * dy + dz * dz) > 10 then return false, 'too_far' end
        end
        local article = shop.inventory[index]
        if not article then return false, 'unknown_item' end
        local currency = article.currency or 'money'
        local price = (article.price or 0) * count
        if Inventory.GetItemCount(src, currency) < price then return false, 'not_enough_' .. currency end
        if not Inventory.CanCarryItem(src, article.name, count, article.metadata) then return false, 'cannot_carry' end
        local metadata = article.metadata and emu.netCopy(article.metadata) or nil
        if not TriggerEventHooks('buyItem', { source = src, shopType = shopType, shopId = shopId, toInventory = src,
            itemName = article.name, metadata = metadata, count = count, price = article.price, totalPrice = price,
            currency = currency }) then return false, 'hook' end
        if price > 0 and not Inventory.RemoveItem(src, currency, price) then return false, 'payment' end
        local ok, response = Inventory.AddItem(src, article.name, count, metadata)
        if not ok then return false, response end
        return true
    end

    function mock:swap(player, data)
        local from = Inventory(data.fromInventory or player.id)
        local to = Inventory(data.toInventory or player.id)
        if not from or not to then return false, 'invalid_inventory' end
        local fromData, toData = from.items[data.fromSlot], to.items[data.toSlot]
        if not fromData then return false, 'no_item' end
        local count = math.min(data.count or fromData.count, fromData.count)
        if count < 1 then return false end
        local same = from.id == to.id
        local payload = { source = player.id, fromInventory = from.id, fromSlot = fromData, fromType = from.type,
                          toInventory = to.id, toSlot = toData or data.toSlot, toType = to.type, count = count }
        if toData and (toData.name ~= fromData.name or not toData.stack or not matches(toData.metadata, fromData.metadata)) then
            payload.action = 'swap'
            if not same and (to.weight - toData.weight + fromData.weight > to.maxWeight or from.weight - fromData.weight + toData.weight > from.maxWeight) then
                return false, 'cannot_carry'
            end
            if not TriggerEventHooks('swapItems', payload) then return false, 'hook' end
            local a, b = clone(fromData), clone(toData)
            a.slot, b.slot = data.toSlot, data.fromSlot
            from.items[data.fromSlot], to.items[data.toSlot] = b, a
            if not same then
                from.weight = from.weight - fromData.weight + toData.weight
                to.weight = to.weight - toData.weight + fromData.weight
            end
        elseif toData then
            payload.action = 'stack'
            local item = Items(toData.name)
            local moved = { count = toData.count + count, metadata = toData.metadata }
            local newWeight = Inventory.SlotWeight(item, moved)
            if not same and to.weight - toData.weight + newWeight > to.maxWeight then return false, 'cannot_carry' end
            if not TriggerEventHooks('swapItems', payload) then return false, 'hook' end
            to.weight = to.weight - toData.weight + newWeight
            toData.count, toData.weight = moved.count, newWeight
            from.weight = from.weight - fromData.weight
            fromData.count = fromData.count - count
            fromData.weight = Inventory.SlotWeight(Items(fromData.name), fromData)
            from.weight = from.weight + fromData.weight
            if fromData.count < 1 then from.items[data.fromSlot] = nil end
        else
            payload.action = 'move'
            local moved = clone(fromData)
            moved.count, moved.slot = count, data.toSlot
            moved.weight = Inventory.SlotWeight(Items(moved.name), moved)
            if not same and to.weight + moved.weight > to.maxWeight then return false, 'cannot_carry_other' end
            if not TriggerEventHooks('swapItems', payload) then return false, 'hook' end
            if count < fromData.count then moved.metadata = clone(moved.metadata) end
            to.items[data.toSlot] = moved
            to.weight = to.weight + moved.weight
            from.weight = from.weight - fromData.weight
            fromData.count = fromData.count - count
            fromData.weight = Inventory.SlotWeight(Items(fromData.name), fromData)
            from.weight = from.weight + fromData.weight
            if fromData.count < 1 then from.items[data.fromSlot] = nil end
        end
        from.changed, to.changed = true, true
        for _, inv in ipairs(same and { from } or { from, to }) do
            if inv.player then
                syncInventory(inv)
                env.TriggerClientEvent('ox_inventory:updateSlots', inv.id, {
                    { item = inv.items[data.fromSlot] or { slot = data.fromSlot }, inventory = inv.id },
                    { item = inv.items[data.toSlot] or { slot = data.toSlot }, inventory = inv.id } }, inv.weight)
            end
        end
        return true
    end

    if opts.autostart ~= false then emu:start('ox_inventory') end
    return mock
end
