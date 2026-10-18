local showUntil = 0

RegisterNetEvent('demo_ping:pong', function(data)
    showUntil = GetGameTimer() + 1000
    CreateThread(function()
        while GetGameTimer() < showUntil do
            local p = GetEntityCoords(PlayerPedId())
            DrawMarker(1, p.x, p.y, p.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 0.5, 0, 229, 255, 160,
                false, false, 2, false, nil, nil, false)
            Wait(0)
        end
    end)
end)

RegisterNetEvent('demo_ping:welcome', function(name)
    lib.notify({ title = 'Bienvenue', description = name })
end)

RegisterNetEvent('demo_ping:refused', function(reason)
    lib.notify({ type = 'error', description = reason })
end)

RegisterCommand('hello', function(_, args)
    TriggerServerEvent('demo_ping:hello', table.concat(args, ' '))
end, false)

RegisterCommand('heure', function()
    local serverTime, name = lib.callback.await('demo_ping:time', false)
    print(('serveur à %d ms, je suis %s'):format(serverTime, name))
end, false)
