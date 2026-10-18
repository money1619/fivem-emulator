fx_version 'cerulean'
game 'gta5'
lua54 'yes'

shared_script '@inclus/partage.lua'
shared_scripts { 'shared/*.lua' }
server_scripts {
    '@absent/rien.lua',
    'server/**/*.lua',
}
client_script 'client/main.lua'
files { 'data/*.json' }
data_file 'DLC_ITYP_REQUEST' 'stream/exemple.ytyp'
