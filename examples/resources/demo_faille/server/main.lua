-- Chaque événement ci-dessous contient une faille classique. emu:fuzz doit toutes les trouver.

-- Faille 1 : récompense sans délai ni « déjà reçue » (spam), et sans contrôle de position
RegisterNetEvent('faille:recompense', function()
    local xPlayer = ESX.GetPlayerFromId(source)
    if xPlayer then xPlayer.addAccountMoney('bank', 100, 'récompense') end
end)

-- Faille 2 : virement sans contrôle du montant : un montant négatif prend l'argent du destinataire
RegisterNetEvent('faille:virement', function(targetId, amount)
    local xPlayer, xTarget = ESX.GetPlayerFromId(source), ESX.GetPlayerFromId(targetId)
    amount = tonumber(amount)
    if not xPlayer or not xTarget or not amount then return end
    local bank = xPlayer.getAccount('bank').money
    if bank < amount then return end
    xPlayer.setAccountMoney('bank', bank - amount, 'virement')
    xTarget.setAccountMoney('bank', xTarget.getAccount('bank').money + amount, 'virement')
end)

-- Faille 3 : texte du joueur collé dans la requête SQL au lieu d'un paramètre ?
RegisterNetEvent('faille:journal', function(message)
    MySQL.insert("INSERT INTO faille_journal (message) VALUES ('" .. tostring(message) .. "')")
end)

-- Correct : montant vérifié (entier, positif, plafonné) et solde contrôlé
RegisterNetEvent('faille:don', function(amount)
    local xPlayer = ESX.GetPlayerFromId(source)
    amount = math.tointeger(tonumber(amount))
    if not xPlayer or not amount or amount < 1 or amount > 1000 then return end
    if xPlayer.getAccount('bank').money < amount then return end
    xPlayer.removeAccountMoney('bank', amount, 'don')
end)
