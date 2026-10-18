lib.callback.register('rappel_a:nom', function(source, x)
    return 'A', source, x
end)

RegisterNetEvent('rappel_a:demander', function()
    local src = source
    local id = lib.callback.await('rappel_a:client', src, 'q')
    print(('client %d a répondu %s'):format(src, tostring(id)))
    lib.notify(src, { description = 'fini A' })
end)
