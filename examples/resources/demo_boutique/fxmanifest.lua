fx_version 'cerulean'
game 'gta5'
lua54 'yes'

description 'Petite boutique de démonstration pour fivem_emu (ESX, oxmysql, ox_inventory, ox_target)'

shared_scripts {
    '@ox_lib/init.lua',
    '@es_extended/imports.lua',
    'config.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
}

client_scripts { 'client/main.lua' }

dependencies { 'es_extended', 'oxmysql', 'ox_inventory', 'ox_target' }
