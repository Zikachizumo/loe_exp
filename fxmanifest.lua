fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'loe_exp'
author 'Legends of Empire'
description 'LOE - Aktif oyun süresine dayalı 1-100 seviye ve EXP sistemi'
version '1.0.0'

-- Hem sunucu hem istemci tarafında yüklenen dosyalar
shared_scripts {
    'config.lua',
    'shared/sh_level.lua',
}

-- Yalnızca sunucuda çalışan dosyalar (istemciye gönderilmez)
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'config_server.lua',
    'server/sv_bridge.lua',
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
}
