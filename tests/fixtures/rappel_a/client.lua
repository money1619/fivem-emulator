lib.callback.register('rappel_a:client', function(q)
    return q .. GetPlayerServerId(PlayerId())
end)

CreateThread(function()
    local nom, src, x = lib.callback.await('rappel_a:nom', false, 7)
    print(nom, src, x)
    TriggerServerEvent('rappel_a:demander')
end)
