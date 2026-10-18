exports.ox_target:addBoxZone({
    name = 'boutique_comptoir',
    coords = Config.counter,
    size = vec3(2.0, 2.0, 2.0),
    rotation = 45,
    options = {
        {
            name = 'boutique:eau',
            label = "Acheter de l'eau (10 $)",
            onSelect = function()
                TriggerServerEvent('boutique:acheter', 'water', 1)
            end,
        },
        {
            name = 'boutique:pain',
            label = 'Acheter du pain (15 $)',
            serverEvent = 'boutique:acheterOption',
            item = 'bread',
        },
        {
            name = 'boutique:inventaire',
            label = 'Contrôler le stock',
            groups = 'police',
            event = 'boutique:controle',
        },
    },
})

AddEventHandler('boutique:controle', function(data)
    lib.notify({ title = 'Boutique', description = ('Contrôle à %.1f m du comptoir'):format(data.distance) })
end)

RegisterCommand('historique', function()
    local ventes = lib.callback.await('boutique:historique', false)
    print(('%d achat(s) en base'):format(#ventes))
end, false)
