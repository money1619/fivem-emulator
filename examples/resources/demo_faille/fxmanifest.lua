fx_version 'cerulean'
game 'gta5'
lua54 'yes'

description 'Ressource VOLONTAIREMENT mal protégée : montre ce que trouve emu:fuzz. Ne pas copier.'

shared_scripts {
    '@ox_lib/init.lua',
    '@es_extended/imports.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/main.lua',
}

dependencies { 'es_extended', 'oxmysql' }
