lib.callback.register('rappel_b:nom', function(source, x)
    return 'B', source, x
end)

RegisterNetEvent('rappel_b:demander', function()
    local src = source
    local id = lib.callback.await('rappel_b:client', src, 'q')
    print(('client %d a répondu %s'):format(src, tostring(id)))
    lib.notify(src, { description = 'fini B' })
end)
