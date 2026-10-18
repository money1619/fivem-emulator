local function notify(xPlayer, message, kind)
    xPlayer.showNotification(message, kind)
end

-- Achat : distance au comptoir, argent (ESX), place dans l'inventaire (ox_inventory), journal en base (oxmysql)
local function buy(src, itemName, count)
    local price = Config.prices[itemName]
    count = math.floor(tonumber(count) or 1)
    if not price or count < 1 or count > Config.maxPerPurchase then return end

    local xPlayer = ESX.GetPlayerFromId(src)
    if not xPlayer then return end

    if #(GetEntityCoords(GetPlayerPed(src)) - Config.counter) > 5.0 then
        return notify(xPlayer, 'Trop loin du comptoir', 'error')
    end

    local total = price * count
    -- ESX 1.12.4 : removeMoney ne vérifie pas le solde, on le fait ici
    if xPlayer.getMoney() < total then
        return notify(xPlayer, "Pas assez d'argent", 'error')
    end
    if not exports.ox_inventory:CanCarryItem(src, itemName, count) then
        return notify(xPlayer, 'Inventaire plein', 'error')
    end

    xPlayer.removeMoney(total, 'boutique')
    exports.ox_inventory:AddItem(src, itemName, count)
    local saleId = MySQL.insert.await('INSERT INTO boutique_ventes (identifier, item, count, price) VALUES (?, ?, ?, ?)',
        { xPlayer.getIdentifier(), itemName, count, total })
    notify(xPlayer, ('Vente n°%d : %dx %s pour %d $'):format(saleId, count, itemName, total), 'success')
end

RegisterNetEvent('boutique:acheter', function(itemName, count)
    buy(source, itemName, count)
end)

-- Option ox_target « serverEvent » : reçoit la réponse d'ox_target (champs de l'option + coords, distance…)
RegisterNetEvent('boutique:acheterOption', function(data)
    buy(source, data.item, 1)
end)

lib.callback.register('boutique:historique', function(source)
    local xPlayer = ESX.GetPlayerFromId(source)
    return MySQL.query.await('SELECT item, count, price FROM boutique_ventes WHERE identifier = ?', { xPlayer.getIdentifier() })
end)
