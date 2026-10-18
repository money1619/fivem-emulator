lib.callback.register('rappel_b:client', function(q)
    return q .. GetPlayerServerId(PlayerId())
end)

CreateThread(function()
    local nom, src, x = lib.callback.await('rappel_b:nom', false, 7)
    print(nom, src, x)
    TriggerServerEvent('rappel_b:demander')
end)
