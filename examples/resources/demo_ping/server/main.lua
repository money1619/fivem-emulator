local lastHello = {}

-- /ping [texte] : renvoie le texte au joueur, qui affiche un marqueur pendant 1 s
RegisterCommand('ping', function(source, args)
    TriggerClientEvent('demo_ping:pong', source, { text = args[1] or 'pong', sentAt = GetGameTimer() })
end, false)

-- /annonce : réservée aux joueurs qui ont l'ACE command.annonce
RegisterCommand('annonce', function(_, args)
    TriggerClientEvent('demo_ping:welcome', -1, table.concat(args, ' '))
end, true)

lib.callback.register('demo_ping:time', function(source)
    return GetGameTimer(), GetPlayerName(source)
end)

RegisterNetEvent('demo_ping:hello', function(message)
    local src = source
    local now = GetGameTimer()
    if lastHello[src] and now - lastHello[src] < Config.helloCooldownMs then
        TriggerClientEvent('demo_ping:refused', src, 'cooldown')
        return
    end
    lastHello[src] = now
    print(('bonjour de %s : %s'):format(GetPlayerName(src), tostring(message)))
    TriggerClientEvent('demo_ping:welcome', -1, GetPlayerName(src))
end)

AddEventHandler('playerDropped', function()
    lastHello[source] = nil
end)
