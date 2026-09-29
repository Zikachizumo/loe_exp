fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'loe_exp'
author 'Legends of Empire'
description 'LOE - Aktif oyun süresine dayalı 1-100 seviye ve EXP sistemi (Qbox)'
version '2.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
    'shared/sh_level.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/sv_qbox.lua',
    'server/sv_database.lua',
    'server/sv_logs.lua',
    'server/sv_main.lua',
    'server/sv_exports.lua',
    'server/sv_commands.lua',
}

client_scripts {
    'client/cl_main.lua',
}

dependencies {
    'oxmysql',
    'ox_lib',
    'qbx_core',
}
