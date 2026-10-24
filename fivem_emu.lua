-- fivem_emu.lua — émulateur FiveM hors jeu pour tester des ressources sans joueur connecté (Lua 5.4)
--
-- Charge le vrai code d'une ressource (fxmanifest.lua, scripts serveur et client) dans des environnements séparés :
-- un côté serveur et un côté client par joueur émulé. Les natives sont simulées, l'horloge est virtuelle et le
-- réseau entre le serveur et chaque joueur a sa propre latence, gigue et perte.
--
-- Ce que ce n'est pas : un client GTA. Aucun rendu, aucune physique GTA, aucune synchronisation OneSync réelle.
-- Les natives non simulées provoquent une erreur claire (« attempt to call a nil value (global 'X') ») et
-- apparaissent dans le rapport ; on les ajoute avec emu:native().
local Emu = {}
Emu.__index = Emu
Emu.VERSION = '0.3.0'

local unpack = table.unpack

-------------------------------------------------------------------------------
-- Outils
-------------------------------------------------------------------------------

-- Vecteurs CfxLua (vector2/3/4) : .x .y .z .w, [1..4], .xy/.xyz…, + - * / avec un vecteur ou un nombre, #v = longueur
local VEC = {}
local AXES = { 'x', 'y', 'z', 'w' }

local function vecSize(v) return v.w ~= nil and 4 or v.z ~= nil and 3 or 2 end

local function makeVec(c)
    return setmetatable({ x = c[1], y = c[2], z = c[3], w = c[4] }, VEC)
end

-- vector3(1, 2, 3), vector3(v.xy, 5), vector3(1) → (1, 1, 1) ; size = nil : taille déduite (vec(...))
local function vecFrom(size, ...)
    local c = {}
    for i = 1, select('#', ...) do
        local a = select(i, ...)
        if getmetatable(a) == VEC then
            for j = 1, vecSize(a) do c[#c + 1] = a[AXES[j]] end
        else
            c[#c + 1] = a
        end
    end
    size = size or #c
    if #c == 1 and size > 1 then for i = 2, size do c[i] = c[1] end end
    if size < 2 or size > 4 then error(('vecteur de taille %d non pris en charge'):format(size), 3) end
    for i = 1, size do
        if type(c[i]) ~= 'number' then error(('vector%d : composante %d invalide (%s)'):format(size, i, type(c[i])), 3) end
    end
    return makeVec({ unpack(c, 1, size) })
end

local function vecOp(op)
    return function(a, b)
        local va, vb = getmetatable(a) == VEC, getmetatable(b) == VEC
        local n = va and vecSize(a) or vecSize(b)
        local c = {}
        for i = 1, n do
            local k = AXES[i]
            c[i] = op(va and a[k] or a, vb and b[k] or b)
        end
        return makeVec(c)
    end
end
VEC.__add = vecOp(function(x, y) return x + y end)
VEC.__sub = vecOp(function(x, y) return x - y end)
VEC.__mul = vecOp(function(x, y) return x * y end)
VEC.__div = vecOp(function(x, y) return x / y end)
VEC.__unm = function(a) return a * -1 end
VEC.__len = function(a)
    local s = 0
    for i = 1, vecSize(a) do local x = a[AXES[i]] s = s + x * x end
    return math.sqrt(s)
end
VEC.__eq = function(a, b)
    if vecSize(a) ~= vecSize(b) then return false end
    for i = 1, vecSize(a) do if a[AXES[i]] ~= b[AXES[i]] then return false end end
    return true
end
VEC.__tostring = function(a)
    local parts = {}
    for i = 1, vecSize(a) do parts[i] = ('%g'):format(a[AXES[i]]) end
    return ('vector%d(%s)'):format(vecSize(a), table.concat(parts, ', '))
end
VEC.__index = function(t, k)
    if type(k) == 'number' then return AXES[k] and rawget(t, AXES[k]) end
    if type(k) == 'string' and #k >= 2 and #k <= 4 and not k:find('[^xyzw]') then
        local c = {}
        for i = 1, #k do
            c[i] = rawget(t, k:sub(i, i))
            if c[i] == nil then return nil end
        end
        return makeVec(c)
    end
end

local function vec3(x, y, z) return vecFrom(3, x, y, z) end
Emu.vec3 = vec3
Emu.vec = function(...) return vecFrom(nil, ...) end
Emu.isVector = function(v) return getmetatable(v) == VEC end

-- Copie profonde d'une donnée envoyée sur le réseau. Les fonctions et userdata ne passent pas le réseau FiveM.
local function netCopy(v, path, depth)
    local t = type(v)
    if t == 'table' then
        if getmetatable(v) == VEC then return makeVec({ v.x, v.y, v.z, v.w }) end
        depth = (depth or 0) + 1
        if depth > 64 then error(('table trop profonde ou cyclique dans %s'):format(path or 'les arguments'), 0) end
        local r = {}
        for k, x in pairs(v) do r[netCopy(k, path, depth)] = netCopy(x, (path or '') .. '.' .. tostring(k), depth) end
        return r
    elseif t == 'function' or t == 'userdata' or t == 'thread' then
        error(('valeur non sérialisable (%s) dans %s'):format(t, path or 'les arguments'), 0)
    end
    return v
end
Emu.netCopy = netCopy

-- Taille estimée en msgpack (format des événements FiveM), sans les en-têtes réseau
local function packSize(v)
    local t = type(v)
    if t == 'nil' or t == 'boolean' then return 1 end
    if t == 'number' then
        if math.type(v) == 'integer' then
            if v >= 0 then
                return v <= 127 and 1 or v <= 0xFF and 2 or v <= 0xFFFF and 3 or v <= 0xFFFFFFFF and 5 or 9
            end
            return v >= -32 and 1 or v >= -128 and 2 or v >= -32768 and 3 or v >= -2147483648 and 5 or 9
        end
        return 9
    end
    if t == 'string' then
        local n = #v
        return (n <= 31 and 1 or n <= 255 and 2 or n <= 65535 and 3 or 5) + n
    end
    if t == 'table' then
        -- vecteurs : type d'extension msgpack (2, 3 ou 4 flottants de 32 bits)
        if getmetatable(v) == VEC then return ({ 10, 15, 18 })[vecSize(v) - 1] end
        local n, count, values, keys = #v, 0, 0, 0
        for k, x in pairs(v) do
            count = count + 1
            values = values + packSize(x)
            keys = keys + packSize(k)
        end
        local isArray = count == n
        local size = isArray and values or values + keys
        return size + (count <= 15 and 1 or count <= 65535 and 3 or 5)
    end
    return 1
end
Emu.packSize = packSize

-- Taille d'un événement : nom + tableau msgpack des arguments (les nil comptent)
local function eventSize(name, args)
    local n = args.n or #args
    local size = #name + (n <= 15 and 1 or n <= 65535 and 3 or 5)
    for i = 1, n do size = size + packSize(args[i]) end
    return size
end
Emu.eventSize = eventSize

-- Hash Jenkins one-at-a-time (GetHashKey / `nom` en CfxLua), renvoyé signé sur 32 bits comme dans FiveM
local function joaat(s)
    s = s:lower()
    local h = 0
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = h ~ (h >> 6)
    end
    h = (h + (h << 3)) & 0xFFFFFFFF
    h = h ~ (h >> 11)
    h = (h + (h << 15)) & 0xFFFFFFFF
    if h >= 0x80000000 then h = h - 0x100000000 end
    return h
end
Emu.joaat = joaat

-- JSON minimal (global `json` de FiveM : encode / decode)
local json = {}
do
    local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    local function enc(v, out)
        local t = type(v)
        if t == 'nil' then out[#out + 1] = 'null'
        elseif t == 'boolean' then out[#out + 1] = tostring(v)
        elseif t == 'number' then
            if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = 'null'
            elseif math.type(v) == 'integer' then out[#out + 1] = tostring(v)
            else out[#out + 1] = string.format('%.14g', v) end
        elseif t == 'string' then
            out[#out + 1] = '"' .. v:gsub('[%c"\\]', function(c) return escapes[c] or ('\\u%04x'):format(c:byte()) end) .. '"'
        elseif t == 'table' then
            local n = #v
            local isArray = n > 0 or next(v) == nil
            if isArray then for k in pairs(v) do if math.type(k) ~= 'integer' or k < 1 or k > n then isArray = false break end end end
            if isArray then
                out[#out + 1] = '['
                for i = 1, n do if i > 1 then out[#out + 1] = ',' end enc(v[i], out) end
                out[#out + 1] = ']'
            else
                local keys = {}
                for k in pairs(v) do keys[#keys + 1] = k end
                table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
                out[#out + 1] = '{'
                for i, k in ipairs(keys) do
                    if i > 1 then out[#out + 1] = ',' end
                    enc(tostring(k), out); out[#out + 1] = ':'; enc(v[k], out)
                end
                out[#out + 1] = '}'
            end
        else error('json.encode : type non pris en charge ' .. t) end
    end
    function json.encode(v) local out = {} enc(v, out) return table.concat(out) end

    function json.decode(s)
        if type(s) ~= 'string' then return nil end
        local pos = 1
        local function ws() pos = s:find('[^ \t\r\n]', pos) or #s + 1 end
        local value
        local function str()
            local out, i = {}, pos + 1
            while true do
                local c = s:sub(i, i)
                if c == '"' then pos = i + 1 return table.concat(out) end
                if c == '' then error('json.decode : chaîne non terminée') end
                if c == '\\' then
                    local e = s:sub(i + 1, i + 1)
                    if e == 'u' then
                        out[#out + 1] = utf8.char(tonumber(s:sub(i + 2, i + 5), 16)); i = i + 6
                    else
                        out[#out + 1] = ({ b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' })[e] or e; i = i + 2
                    end
                else out[#out + 1] = c; i = i + 1 end
            end
        end
        function value()
            ws()
            local c = s:sub(pos, pos)
            if c == '{' then
                local r = {}
                pos = pos + 1; ws()
                if s:sub(pos, pos) == '}' then pos = pos + 1 return r end
                while true do
                    ws(); local k = str(); ws()
                    assert(s:sub(pos, pos) == ':', 'json.decode : « : » attendu'); pos = pos + 1
                    r[k] = value(); ws()
                    local d = s:sub(pos, pos); pos = pos + 1
                    if d == '}' then return r end
                    assert(d == ',', 'json.decode : « , » attendu')
                end
            elseif c == '[' then
                local r = {}
                pos = pos + 1; ws()
                if s:sub(pos, pos) == ']' then pos = pos + 1 return r end
                while true do
                    r[#r + 1] = value(); ws()
                    local d = s:sub(pos, pos); pos = pos + 1
                    if d == ']' then return r end
                    assert(d == ',', 'json.decode : « , » attendu')
                end
            elseif c == '"' then return str()
            elseif s:sub(pos, pos + 3) == 'true' then pos = pos + 4 return true
            elseif s:sub(pos, pos + 4) == 'false' then pos = pos + 5 return false
            elseif s:sub(pos, pos + 3) == 'null' then pos = pos + 4 return nil
            else
                local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
                assert(num and #num > 0, 'json.decode : valeur invalide à la position ' .. pos)
                pos = pos + #num
                return math.tointeger(tonumber(num)) or tonumber(num)
            end
        end
        local ok, r = pcall(value)
        if not ok then return nil end
        return r
    end
end
Emu.json = json

-- Syntaxe CfxLua courante → Lua standard : `nom` (hash) et affectations composées (x += 1, t.n -= 2, a <<= 1…)
local COMPOUND_OPS = { ['<<'] = true, ['>>'] = true, ['+'] = true, ['-'] = true, ['*'] = true, ['/'] = true,
                       ['&'] = true, ['|'] = true, ['^'] = true }

-- Sépare le code d'une ligne de son commentaire final, sans se tromper sur les -- dans les chaînes
local function splitComment(line)
    local i, quote = 1, nil
    while i <= #line do
        local c = line:sub(i, i)
        if quote then
            if c == '\\' then i = i + 1 elseif c == quote then quote = nil end
        elseif c == '"' or c == "'" then quote = c
        elseif c == '-' and line:sub(i + 1, i + 1) == '-' then return line:sub(1, i - 1), line:sub(i) end
        i = i + 1
    end
    return line, ''
end

-- Début de la cible d'une affectation composée qui finit à la position e (nom, .champ, [index])
local function targetStart(code, e)
    local i = e
    while i >= 1 do
        local c = code:sub(i, i)
        if c == ']' then
            local depth = 0
            while i >= 1 do
                local d = code:sub(i, i)
                if d == ']' then depth = depth + 1 elseif d == '[' then depth = depth - 1 if depth == 0 then break end end
                i = i - 1
            end
            i = i - 1
        elseif c:match('[%w_%.]') then
            i = i - 1
        else
            break
        end
    end
    return i + 1
end

-- Fin de la valeur d'une affectation composée : « ; », ou end/else/elseif au niveau 0, ou fin de ligne
local function valueEnd(code, s)
    local depth, quote, i = 0, nil, s
    while i <= #code do
        local c = code:sub(i, i)
        if quote then
            if c == '\\' then i = i + 1 elseif c == quote then quote = nil end
        elseif c == '"' or c == "'" then quote = c
        elseif c == '(' or c == '[' or c == '{' then depth = depth + 1
        elseif c == ')' or c == ']' or c == '}' then depth = depth - 1
        elseif depth == 0 then
            if c == ';' then return i - 1 end
            if c:match('[%a_]') and not code:sub(i - 1, i - 1):match('[%w_]') then
                local word = code:match('^[%a_][%w_]*', i)
                if word == 'end' or word == 'else' or word == 'elseif' then return i - 1 end
                i = i + #word - 1
            end
        end
        i = i + 1
    end
    return #code
end

local function convertCompound(code)
    local i, quote = 1, nil
    while i <= #code do
        local c = code:sub(i, i)
        if quote then
            if c == '\\' then i = i + 1 elseif c == quote then quote = nil end
        elseif c == '"' or c == "'" then quote = c
        else
            local op = code:sub(i, i + 1)
            if not (COMPOUND_OPS[op] and code:sub(i + 2, i + 2) == '=') then
                op = c
                if not (COMPOUND_OPS[op] and code:sub(i + 1, i + 1) == '=') then op = nil end
            end
            local after = op and i + #op + 1
            if op and code:sub(after, after) ~= '=' then
                local e = i - 1
                while e >= 1 and code:sub(e, e):match('%s') do e = e - 1 end
                local s = targetStart(code, e)
                local target = code:sub(s, e)
                if target:match('^[%a_]') then
                    local vEnd = valueEnd(code, after)
                    local val = code:sub(after, vEnd):match('^%s*(.-)%s*$')
                    local rest = code:sub(vEnd + 1)
                    return code:sub(1, s - 1) .. ('%s = %s %s (%s)'):format(target, target, op, val)
                        .. (rest ~= '' and ' ' .. convertCompound(rest:match('^%s*(.*)$')) or '')
                end
            end
        end
        i = i + 1
    end
    return code
end

-- `nom` → hash, seulement dans le code : jamais dans une chaîne ('…', "…", [[…]]) ni un commentaire
local function replaceHashes(src)
    local out, i, n = {}, 1, #src
    while i <= n do
        local c = src:sub(i, i)
        if c == '-' and src:sub(i, i + 1) == '--' then
            local level = src:match('^%-%-%[(=*)%[', i)
            local stop
            if level then
                stop = select(2, src:find(']' .. level .. ']', i, true)) or n
            else
                stop = (src:find('\n', i, true) or n + 1) - 1
            end
            out[#out + 1] = src:sub(i, stop)
            i = stop + 1
        elseif c == '[' and src:match('^%[=*%[', i) then
            local level = src:match('^%[(=*)%[', i)
            local stop = select(2, src:find(']' .. level .. ']', i, true)) or n
            out[#out + 1] = src:sub(i, stop)
            i = stop + 1
        elseif c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local d = src:sub(j, j)
                if d == '\\' then j = j + 2
                elseif d == c or d == '\n' then break
                else j = j + 1 end
            end
            out[#out + 1] = src:sub(i, j)
            i = j + 1
        elseif c == '`' then
            local stop = src:find('[`\n]', i + 1)
            if stop and src:sub(stop, stop) == '`' then
                out[#out + 1] = tostring(joaat(src:sub(i + 1, stop - 1)))
                i = stop + 1
            else
                out[#out + 1] = c
                i = i + 1
            end
        else
            local j = src:find('[%-%[\'"`]', i + 1) or n + 1
            out[#out + 1] = src:sub(i, j - 1)
            i = j
        end
    end
    return table.concat(out)
end

local function preprocess(src)
    src = replaceHashes(src)
    local out = {}
    for line in (src .. '\n'):gmatch('(.-)\n') do
        if line:find('[%+%-%*/&|%^<>]=') then
            local code, comment = splitComment(line)
            local converted = convertCompound(code)
            if converted ~= code then line = converted .. (comment ~= '' and ' ' .. comment or '') end
        end
        out[#out + 1] = line
    end
    return table.concat(out, '\n')
end
Emu.preprocess = preprocess

local function readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

-- Liste les fichiers d'un dossier (chemins relatifs), sans dépendance externe
local function listFiles(root)
    local windows = package.config:sub(1, 1) == '\\'
    -- Windows : dir /s /b donne des chemins absolus ; « cd » affiche d'abord le chemin absolu de la racine
    local cmd = windows
        and ('cd /d "%s" 2>nul && cd && dir /s /b /a-d 2>nul'):format((root:gsub('/', '\\')))
        or ('find "%s" -type f 2>/dev/null'):format(root)
    local p = io.popen(cmd)
    local files = {}
    if p then
        local prefix
        if not windows then prefix = root end
        for line in p:lines() do
            line = line:gsub('\r$', '')
            if not prefix then
                prefix = line:gsub('[\\/]$', '')
            else
                files[#files + 1] = (line:sub(#prefix + 2):gsub('\\', '/'))
            end
        end
        p:close()
    end
    table.sort(files)
    return files
end

-- Motifs du manifeste : * et ? dans un nom, ** = zéro, un ou plusieurs dossiers
local function segPattern(seg)
    return '^' .. seg:gsub('[%.%+%-%^%$%(%)%%%[%]]', '%%%0'):gsub('%*', '.*'):gsub('%?', '.') .. '$'
end

local function globMatch(glob, gi, path, pi)
    if gi > #glob then return pi > #path end
    if glob[gi] == '**' then
        for k = pi, #path + 1 do
            if globMatch(glob, gi + 1, path, k) then return true end
        end
        return false
    end
    if pi > #path or not path[pi]:match(segPattern(glob[gi])) then return false end
    return globMatch(glob, gi + 1, path, pi + 1)
end

local function splitPath(s)
    local r = {}
    for part in s:gmatch('[^/]+') do r[#r + 1] = part end
    return r
end

-------------------------------------------------------------------------------
-- Ordonnanceur à horloge virtuelle (ms)
-------------------------------------------------------------------------------

-- opts : serverTickMs (10), seed, maxEvents, maxInstructions (par reprise de fil), convars = { nom = valeur }, echo
function Emu.new(opts)
    opts = opts or {}
    local self = setmetatable({
        now = 0, seq = 0, heap = {},
        serverTickMs = opts.serverTickMs or 10,
        maxEvents = opts.maxEvents or 5000000,
        maxInstructions = opts.maxInstructions or 200000000,
        rngState = opts.seed or 0x2545F491,
        errors = {}, warnings = {},
        resources = {}, started = {}, startOrder = {}, resGen = {},
        providers = {},
        players = {}, playerList = {}, nextPlayerId = 1,
        extraNatives = { shared = {}, server = {}, client = {} },
        missing = {},
        convars = opts.convars or {},
        aces = {}, principals = {},
        timeouts = {}, nextTimeout = 0,
        mocks = {}, reporters = {}, probes = {},
        nextBagCookie = 0,
        echo = opts.echo,
    }, Emu)
    self.server = self:_newSide('server', nil)
    self:_installDefaultProviders()
    return self
end

function Emu:rand()
    self.rngState = (self.rngState * 1103515245 + 12345) % 2147483648
    return self.rngState / 2147483648
end

function Emu:at(t, fn)
    self.seq = self.seq + 1
    local h, item = self.heap, { t = t, seq = self.seq, fn = fn }
    h[#h + 1] = item
    local i = #h
    while i > 1 do
        local p = i // 2
        if h[p].t < item.t or (h[p].t == item.t and h[p].seq < item.seq) then break end
        h[p], h[i] = h[i], h[p]
        i = p
    end
end

local function heapPop(h)
    local top, last = h[1], table.remove(h)
    if #h > 0 then
        h[1] = last
        local i = 1
        while true do
            local l, r, s = i * 2, i * 2 + 1, i
            if l <= #h and (h[l].t < h[s].t or (h[l].t == h[s].t and h[l].seq < h[s].seq)) then s = l end
            if r <= #h and (h[r].t < h[s].t or (h[r].t == h[s].t and h[r].seq < h[s].seq)) then s = r end
            if s == i then break end
            h[s], h[i] = h[i], h[s]
            i = s
        end
    end
    return top
end

-- Avance l'horloge virtuelle de `ms` millisecondes en exécutant tout ce qui est prévu
function Emu:run(ms)
    local tEnd = self.now + (ms or 0)
    local count = 0
    while #self.heap > 0 and self.heap[1].t <= tEnd do
        local item = heapPop(self.heap)
        self.now = item.t
        item.fn()
        count = count + 1
        if count > self.maxEvents then
            error(('plus de %d événements en %d ms virtuelles : boucle sans Wait ?'):format(self.maxEvents, ms), 2)
        end
    end
    self.now = tEnd
end

-- Avance jusqu'à ce que `cond()` soit vraie, au plus `timeoutMs`. Renvoie true si la condition est atteinte.
function Emu:runUntil(cond, timeoutMs, stepMs)
    local limit = self.now + (timeoutMs or 60000)
    stepMs = stepMs or 10
    while self.now < limit do
        if cond() then return true end
        self:run(math.min(stepMs, limit - self.now))
    end
    return cond() and true or false
end

function Emu:_error(side, msg)
    local e = ('[%s t=%.0fms] %s'):format(side and side.name or 'émulateur', self.now, msg)
    self.errors[#self.errors + 1] = e
    if self.echo then io.write(e, '\n') end
end

function Emu:_warn(msg)
    self.warnings[#self.warnings + 1] = ('[t=%.0fms] %s'):format(self.now, msg)
end

-------------------------------------------------------------------------------
-- Côtés (serveur, client de chaque joueur), fils et événements
-------------------------------------------------------------------------------

function Emu:_newSide(kind, player)
    return {
        kind = kind, player = player, emu = self,
        name = kind == 'server' and 'serveur' or ('client ' .. player.id),
        handlers = {}, netEvents = {}, envs = {}, exports = {},
        threads = 0, commands = {}, log = {},
        bags = {}, bagHandlers = {},
        frameMs = player and (1000 / (player.fps or 60)) or nil,
        dead = false,
    }
end

-- Prochain instant où un fil en attente reprend : premier tick serveur (ou image client) à partir de now + ms,
-- jamais l'instant courant (Wait(0) rend la main jusqu'au tick suivant, comme dans FiveM)
function Emu:_nextTick(side, ms)
    local step = side.kind == 'server' and self.serverTickMs or side.frameMs
    local t = self.now + math.max(ms or 0, 0)
    -- toujours k * step (k entier) : deux fils qui attendent la même image tombent au même instant exact
    local k = math.ceil(t / step - 1e-9)
    if k * step <= self.now then k = math.floor(self.now / step + 1e-9) + 1 end
    return k * step
end

-- Lance une coroutine « fil FiveM ». `immediate` = démarrer tout de suite (gestionnaire d'événement).
-- Un fil meurt avec sa ressource (emu:stop) ou son joueur ; une boucle sans Wait est coupée par un compteur.
function Emu:_spawn(side, resource, fn, immediate, ...)
    local co = coroutine.create(fn)
    side.threads = side.threads + 1
    local args = table.pack(...)
    local emu = self
    local gen = resource and self.resGen[resource]
    local budget = 0
    debug.sethook(co, function()
        budget = budget + 1
        if budget * 1000000 > emu.maxInstructions then
            error(('plus de %d instructions sans Wait (boucle infinie ?)'):format(emu.maxInstructions), 2)
        end
    end, '', 1000000)
    local function step(...)
        if side.dead or (resource and emu.resGen[resource] ~= gen) then
            side.threads = side.threads - 1
            return
        end
        local prev = side.currentResource
        side.currentResource = resource
        budget = 0
        local ok, ms = coroutine.resume(co, ...)
        side.currentResource = prev
        if not ok then
            side.threads = side.threads - 1
            emu:_error(side, ('erreur dans %s : %s'):format(resource or '?', debug.traceback(co, tostring(ms))))
            return
        end
        if coroutine.status(co) == 'dead' then
            side.threads = side.threads - 1
            return
        end
        if type(ms) == 'table' and ms.await then
            ms.resume = function(...) local r = table.pack(...) emu:at(emu.now, function() step(unpack(r, 1, r.n)) end) end
            return
        end
        emu:at(emu:_nextTick(side, ms), step)
    end
    if immediate then step(unpack(args, 1, args.n)) else emu:at(emu:_nextTick(side, 0), function() step(unpack(args, 1, args.n)) end) end
end

-- Suspend le fil courant jusqu'à ce que start(done) appelle done(...) ; renvoie les valeurs passées à done.
-- Sert aux mocks (requêtes SQL, callbacks) : l'attente ne bloque que ce fil, l'horloge continue.
function Emu:awaitCallback(start)
    if not coroutine.isyieldable() then error('attente hors d\'un fil (CreateThread, événement ou commande)', 3) end
    local token, early = { await = true }, nil
    start(function(...)
        if token.resume then token.resume(...) elseif not early then early = table.pack(...) end
    end)
    if early then return unpack(early, 1, early.n) end
    return coroutine.yield(token)
end

-- Ressource qui appelle une fonction de mock : export en cours, sinon ressource du fil en cours
function Emu:callerResource(side)
    return side.invoking or side.currentResource
end

-- Déclenche les gestionnaires `name` d'un côté.
-- src = valeur de `source` vue par les gestionnaires : '' pour un événement local (comme FiveM), l'id du joueur
-- pour un événement réseau reçu par le serveur, 65535 pour un événement reçu du serveur par un client.
-- `source` est remis à sa valeur précédente dès que le gestionnaire rend la main (Wait) : lisez-le au début.
function Emu:_dispatch(side, name, args, src, fromNet, invoker)
    if side.dead then return end
    local list = side.handlers[name]
    local safe = side.netEvents[name]
    if fromNet and not safe then
        self:_warn(('%s : événement réseau « %s » reçu sans RegisterNetEvent, ignoré (comme FiveM)'):format(side.name, name))
        return
    end
    if not list then return end
    if src == nil then src = '' end
    local snapshot = table.move(list, 1, #list, 1, {})
    for _, h in ipairs(snapshot) do
        -- un événement réseau n'atteint que les ressources qui l'ont déclaré avec RegisterNetEvent
        if not h.removed and (not fromNet or safe[h.resource]) then
            local env = h.env
            local prevSource, prevInvoking = rawget(env, 'source'), side.invoking
            rawset(env, 'source', src)
            side.invoking = invoker
            self:_spawn(side, h.resource, h.fn, true, unpack(args, 1, args.n or #args))
            rawset(env, 'source', prevSource)
            side.invoking = prevInvoking
        end
    end
end

-------------------------------------------------------------------------------
-- Réseau : un canal fiable et ordonné par joueur et par sens (comme les événements FiveM)
-------------------------------------------------------------------------------

function Emu:_send(player, dir, name, args, onDeliver)
    if player.dropped or player.dropping then return end
    local ok, copy = pcall(netCopy, args)
    if not ok then
        self:_error(dir == 'down' and self.server or player.side, ('envoi de « %s » : %s'):format(name, copy))
        return
    end
    local size = eventSize(name, args)
    local net = player.net
    local stats = dir == 'down' and net.down or net.up
    stats.bytes, stats.packets = stats.bytes + size, stats.packets + 1
    local p = player.profile
    local delay = p.rtt / 2 + (p.jitter or 0) * self:rand()
    -- paquet perdu : retransmis après un aller-retour
    if self:rand() < (p.loss or 0) then delay = delay + p.rtt end
    local t = self.now + delay
    if p.freeze and t >= p.freeze[1] and t < p.freeze[2] then t = p.freeze[2] + delay end
    if p.chaos then
        if p.dropEvents and p.dropEvents[name] then return end
    else
        if t < net[dir .. 'Last'] then t = net[dir .. 'Last'] end
        net[dir .. 'Last'] = t
    end
    local deliver = function()
        if player.dropped then return end
        onDeliver(netCopy(copy))
    end
    self:at(t, deliver)
    if p.chaos and self:rand() < (p.duplicate or 0) then self:at(t + 50 + 300 * self:rand(), deliver) end
end

-------------------------------------------------------------------------------
-- State bags : GlobalState, Player(id).state, Entity(ent).state, LocalPlayer.state
-------------------------------------------------------------------------------
-- Comme FiveM : la valeur est copiée (msgpack) à l'écriture et à chaque lecture ; les gestionnaires
-- AddStateBagChangeHandler sont appelés AVANT que la valeur change (state.x y donne encore l'ancienne valeur).
-- Le serveur réplique vers tous les clients ; un client ne peut répliquer que son propre sac (player:<id>),
-- et ce qu'il y écrit arrive au serveur puis aux autres joueurs.

function Emu:_bag(side, name)
    local b = side.bags[name]
    if not b then b = { data = {}, replicated = {} } side.bags[name] = b end
    return b
end

function Emu:_applyState(side, bagName, key, value, replicated)
    if side.dead then return end
    local list = side.bagHandlers
    for _, h in ipairs(table.move(list, 1, #list, 1, {})) do
        if not h.removed and (h.key == nil or h.key == '' or h.key == key)
            and (h.bag == nil or h.bag == '' or h.bag == bagName) then
            self:_spawn(side, h.resource, h.fn, true, bagName, key, netCopy(value), 0, replicated == true)
        end
    end
    local b = self:_bag(side, bagName)
    b.data[key] = value
    b.replicated[key] = replicated and true or nil
end

function Emu:_replicateState(p, bagName, key, value)
    self:_send(p, 'down', 'statebag:' .. bagName, table.pack(key, value), function(c)
        self:_applyState(p.side, bagName, c[1], c[2], true)
    end)
end

function Emu:_setState(side, bagName, key, value, replicated)
    local ok, copy = pcall(netCopy, value)
    if not ok then
        self:_error(side, ('state bag %s, clé %s : %s'):format(bagName, tostring(key), copy))
        return
    end
    if side.kind == 'server' then
        self:_applyState(side, bagName, key, copy, replicated)
        if replicated then
            for _, p in ipairs(self.playerList) do self:_replicateState(p, bagName, key, copy) end
        end
        return
    end
    local p = side.player
    if replicated and bagName ~= 'player:' .. p.id then
        self:_warn(('%s : écriture refusée dans le state bag %s (clé %s) : un client ne réplique que son propre sac')
            :format(side.name, bagName, tostring(key)))
        return
    end
    self:_applyState(side, bagName, key, copy, replicated)
    if not replicated then return end
    self:_send(p, 'up', 'statebag:' .. bagName, table.pack(key, copy), function(c)
        self:_applyState(self.server, bagName, c[1], c[2], true)
        for _, other in ipairs(self.playerList) do
            if other ~= p then self:_replicateState(other, bagName, c[1], c[2]) end
        end
    end)
end

-- Objet `state` : state.cle (copie), state.cle = v (répliqué côté serveur, local côté client, comme FiveM),
-- state:set(cle, v, repliquer)
function Emu:_stateProxy(side, bagName)
    local emu = self
    return setmetatable({ __data = bagName }, {
        __index = function(_, k)
            if k == 'set' then
                return function(_, key, value, replicated) emu:_setState(side, bagName, key, value, replicated) end
            end
            local b = side.bags[bagName]
            local v = b and b.data[k]
            if type(v) == 'table' then return netCopy(v) end
            return v
        end,
        __newindex = function(_, k, v) emu:_setState(side, bagName, k, v, side.kind == 'server') end,
    })
end

-- Valeurs d'un state bag vues par le serveur (p = nil) ou par un joueur, pour les tests : emu:stateBag('global')
function Emu:stateBag(bagName, p)
    local b = (p and p.side or self.server).bags[bagName]
    return b and netCopy(b.data) or {}
end

-------------------------------------------------------------------------------
-- Promesses (promise de FiveM) : états 0 = en attente, 3 = résolue, 4 = rejetée
-------------------------------------------------------------------------------

local Promise = {}
Promise.__index = Promise
local promiseLib = {}

function promiseLib.new(executor)
    local p = setmetatable({ state = 0, waiters = {} }, Promise)
    if type(executor) == 'function' then
        executor(function(v) p:resolve(v) end, function(e) p:reject(e) end)
    end
    return p
end

function Promise:_settle(state, v)
    if self.state ~= 0 then return end
    self.state, self.value = state, v
    local waiters = self.waiters
    self.waiters = {}
    for _, f in ipairs(waiters) do f() end
end
function Promise:resolve(v) self:_settle(3, v) end
function Promise:reject(e) self:_settle(4, e) end
function Promise:next(onResolved, onRejected)
    local p2 = promiseLib.new()
    local function run()
        local f = self.state == 3 and onResolved or onRejected
        if not f then
            if self.state == 3 then p2:resolve(self.value) else p2:reject(self.value) end
            return
        end
        local ok, r = pcall(f, self.value)
        if ok then p2:resolve(r) else p2:reject(r) end
    end
    if self.state == 0 then table.insert(self.waiters, run) else run() end
    return p2
end

local function citizenAwait(p)
    if not coroutine.isyieldable() then error('Citizen.Await appelé hors d\'un fil', 2) end
    if p.state == 0 then
        local token = { await = true }
        table.insert(p.waiters, function() token.resume() end)
        coroutine.yield(token)
    end
    if p.state == 4 then error(p.value, 2) end
    return p.value
end

-------------------------------------------------------------------------------
-- Natives
-------------------------------------------------------------------------------

function Emu:_nativesFor(side, resource, env)
    local emu = self
    local N = {}
    local function wait(ms)
        if not coroutine.isyieldable() then error('Wait appelé hors d\'un fil (CreateThread)', 2) end
        coroutine.yield(ms or 0)
    end
    N.Wait = wait
    N.CreateThread = function(fn) emu:_spawn(side, resource, fn, false) end
    N.SetTimeout = function(ms, fn)
        emu.nextTimeout = emu.nextTimeout + 1
        local id = emu.nextTimeout
        emu:at(emu:_nextTick(side, ms), function()
            if emu.timeouts[id] then emu.timeouts[id] = nil return end
            emu:_spawn(side, resource, fn, true)
        end)
        return id
    end
    N.ClearTimeout = function(id) if id then emu.timeouts[id] = true end end
    N.promise = promiseLib
    N.Citizen = {
        Wait = wait, CreateThread = N.CreateThread, SetTimeout = N.SetTimeout, ClearTimeout = N.ClearTimeout,
        CreateThreadNow = function(fn) emu:_spawn(side, resource, fn, true) end,
        Await = citizenAwait,
        Trace = function(s) side.log[#side.log + 1] = tostring(s) end,
    }
    N.GetGameTimer = function() return math.floor(emu.now + (side.player and side.player.clockOffset or 0)) end
    N.GetCurrentResourceName = function() return resource end
    N.GetInvokingResource = function() return side.invoking end
    N.GetResourceState = function(name)
        if emu.started[name] then return 'started' end
        return emu.resources[name] and 'stopped' or 'missing'
    end
    N.GetHashKey = joaat
    N.joaat = joaat
    N.json = json
    N.vector2 = function(...) return vecFrom(2, ...) end
    N.vector3 = function(...) return vecFrom(3, ...) end
    N.vector4 = function(...) return vecFrom(4, ...) end
    N.vec2, N.vec3, N.vec4 = N.vector2, N.vector3, N.vector4
    N.vec = function(...) return vecFrom(nil, ...) end
    N.vector = N.vec
    -- type() renvoie 'vector3' etc. pour les vecteurs, comme en CfxLua
    N.type = function(v)
        if getmetatable(v) == VEC then return 'vector' .. vecSize(v) end
        return type(v)
    end
    N.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local line = table.concat(parts, '\t')
        side.log[#side.log + 1] = line
        if emu.echo then io.write(('[%s] %s\n'):format(side.name, line)) end
    end
    N.GetConvar = function(name, default)
        local v = emu.convars[name]
        if v == nil then return default end
        return tostring(v)
    end
    N.GetConvarInt = function(name, default) return math.tointeger(tonumber(emu.convars[name])) or default end
    N.LoadResourceFile = function(res, file)
        local r = emu.resources[res]
        return r and r.dir and readFile(r.dir .. '/' .. file) or nil
    end
    N.AddEventHandler = function(name, fn)
        side.handlers[name] = side.handlers[name] or {}
        local h = { fn = fn, resource = resource, env = env, name = name }
        table.insert(side.handlers[name], h)
        return h
    end
    N.RegisterNetEvent = function(name, fn)
        side.netEvents[name] = side.netEvents[name] or {}
        side.netEvents[name][resource] = true
        if fn then return N.AddEventHandler(name, fn) end
    end
    N.RegisterServerEvent = N.RegisterNetEvent
    N.RemoveEventHandler = function(h)
        if type(h) ~= 'table' then return end
        h.removed = true
        for _, list in pairs(side.handlers) do
            for i = #list, 1, -1 do if list[i] == h then table.remove(list, i) end end
        end
    end
    N.TriggerEvent = function(name, ...)
        emu:_dispatch(side, name, table.pack(...), '', false, resource)
    end

    -- exports : exports('nom', fn), exports.ressource:nom(...) ou exports['ressource']['nom'](self, ...).
    -- Comme dans FiveM, le premier argument (self) est toujours ignoré.
    N.exports = setmetatable({}, {
        __call = function(_, name, fn)
            side.exports[resource] = side.exports[resource] or {}
            side.exports[resource][name] = fn
        end,
        __index = function(_, res)
            return setmetatable({}, { __index = function(_, fname)
                return function(_, ...)
                    local list = side.exports[res]
                    local fn = list and list[fname]
                    if not fn then error(('export introuvable : %s.%s (ressource démarrée ?)'):format(res, fname), 2) end
                    local prev = side.invoking
                    side.invoking = resource
                    local r = table.pack(pcall(fn, ...))
                    side.invoking = prev
                    if not r[1] then error(r[2], 2) end
                    return unpack(r, 2, r.n)
                end
            end })
        end,
    })

    -- State bags. Entity(ent).state utilise directement le numéro d'entité (pas de netId sans OneSync émulé).
    N.GlobalState = emu:_stateProxy(side, 'global')
    N.Player = function(id)
        local n = tonumber(id)
        return { __data = n, state = emu:_stateProxy(side, 'player:' .. tostring(n)) }
    end
    N.Entity = function(ent) return { __data = ent, state = emu:_stateProxy(side, 'entity:' .. tostring(ent)) } end
    N.AddStateBagChangeHandler = function(key, bag, fn)
        emu.nextBagCookie = emu.nextBagCookie + 1
        table.insert(side.bagHandlers, { key = key, bag = bag, fn = fn, resource = resource, cookie = emu.nextBagCookie })
        return emu.nextBagCookie
    end
    N.RemoveStateBagChangeHandler = function(cookie)
        for i = #side.bagHandlers, 1, -1 do
            local h = side.bagHandlers[i]
            if h.cookie == cookie then h.removed = true table.remove(side.bagHandlers, i) end
        end
    end
    N.GetPlayerFromStateBagName = function(name)
        local id = tonumber(tostring(name):match('^player:(%d+)$'))
        if not id then return 0 end
        return side.kind == 'server' and id or id - 1
    end
    N.GetEntityFromStateBagName = function(name) return tonumber(tostring(name):match('^entity:(%-?%d+)$')) or 0 end
    N.GetStateBagValue = function(bag, key)
        local b = side.bags[bag]
        return b and netCopy(b.data[key])
    end
    N.GetStateBagKeys = function(bag)
        local r = {}
        for k in pairs(side.bags[bag] and side.bags[bag].data or {}) do r[#r + 1] = k end
        table.sort(r, function(a, b) return tostring(a) < tostring(b) end)
        return r
    end
    N.StateBagHasKey = function(bag, key) return side.bags[bag] ~= nil and side.bags[bag].data[key] ~= nil end

    if side.kind == 'server' then
        N.IsDuplicityVersion = function() return true end
        N.RegisterCommand = function(name, fn, restricted)
            emu.server.commands[name] = { fn = fn, restricted = restricted, resource = resource, env = env }
        end
        N.ExecuteCommand = function(line) emu:command(nil, line) end
        N.SetConvar = function(name, value) emu.convars[name] = value end
        N.SetConvarReplicated = N.SetConvar
        N.SetConvarServerInfo = N.SetConvar
        N.TriggerClientEvent = function(name, target, ...)
            local args = table.pack(...)
            local targets = {}
            if tonumber(target) == -1 then
                for _, p in ipairs(emu.playerList) do if not p.dropped then targets[#targets + 1] = p end end
                emu.broadcasts = (emu.broadcasts or 0) + 1
            else
                local p = emu.players[tonumber(target)]
                if p then targets[1] = p end
            end
            for _, p in ipairs(targets) do
                p.sentToClient[#p.sentToClient + 1] = { t = emu.now, name = name }
                emu:_send(p, 'down', name, args, function(copy)
                    p.received[#p.received + 1] = { t = emu.now, name = name }
                    emu:_dispatch(p.side, name, copy, 65535, true)
                end)
            end
        end
        N.TriggerLatentClientEvent = function(name, target, _, ...) N.TriggerClientEvent(name, target, ...) end
        N.GetPlayers = function()
            local r = {}
            for _, p in ipairs(emu.playerList) do if not p.dropped then r[#r + 1] = tostring(p.id) end end
            return r
        end
        local function P(src) local p = emu.players[tonumber(src)] if p and not p.dropped then return p end end
        N.GetPlayerName = function(src) local p = P(src) return p and p.name end
        N.GetPlayerPed = function(src) local p = P(src) return p and p.ped or 0 end
        N.GetPlayerPing = function(src) local p = P(src) return p and p.profile.rtt or 0 end
        N.GetPlayerEndpoint = function(src) local p = P(src) return p and ('127.0.0.' .. p.id) end
        N.GetPlayerIdentifiers = function(src)
            local p = P(src)
            local r = {}
            if p then for _, id in ipairs(p.identifiers) do r[#r + 1] = id end end
            return r
        end
        N.GetNumPlayerIdentifiers = function(src) local p = P(src) return p and #p.identifiers or 0 end
        N.GetPlayerIdentifier = function(src, i) local p = P(src) return p and p.identifiers[(i or 0) + 1] end
        N.GetPlayerIdentifierByType = function(src, kind)
            local p = P(src)
            if not p then return nil end
            for _, id in ipairs(p.identifiers) do if id:sub(1, #kind + 1) == kind .. ':' then return id end end
        end
        N.GetPlayerRoutingBucket = function(src) local p = P(src) return p and p.bucket or 0 end
        N.SetPlayerRoutingBucket = function(src, b) local p = P(src) if p then p.bucket = b end end
        N.IsPlayerAceAllowed = function(src, ace) local p = P(src) return p and emu:_aceAllowed(p, ace) or false end
        N.DropPlayer = function(src, reason) local p = P(src) if p then emu:dropPlayer(p, reason) end end
        local function pedOwner(ped) for _, p in ipairs(emu.playerList) do if p.ped == ped and not p.dropped then return p end end end
        N.GetEntityCoords = function(ped) local p = pedOwner(ped) return p and vec3(p.pos.x, p.pos.y, p.pos.z) or vec3(0, 0, 0) end
        N.GetEntityHeading = function(ped) local p = pedOwner(ped) return p and p.heading or 0.0 end
        N.GetEntityHealth = function(ped) local p = pedOwner(ped) return p and p.health or 0 end
        N.GetVehiclePedIsIn = function(ped) local p = pedOwner(ped) return p and p.vehicle or 0 end
        N.DoesEntityExist = function(ent) return pedOwner(ent) ~= nil end
        N.SetEntityCoords = function(ped, x, y, z) local p = pedOwner(ped) if p then p.pos = { x = x, y = y, z = z } end end
        N.SetEntityHeading = function(ped, h) local p = pedOwner(ped) if p then p.heading = h end end
    else
        local player = side.player
        N.IsDuplicityVersion = function() return false end
        N.LocalPlayer = N.Player(player.id)
        N.TriggerServerEvent = function(name, ...)
            local args = table.pack(...)
            -- copie des arguments : emu:fuzz rejoue ce trafic réel en le modifiant
            local ok, copy = pcall(netCopy, args)
            player.sentToServer[#player.sentToServer + 1] = { t = emu.now, name = name, args = ok and copy or nil }
            emu:_send(player, 'up', name, args, function(copy)
                emu:_dispatch(emu.server, name, copy, player.id, true)
            end)
        end
        N.TriggerLatentServerEvent = function(name, _, ...) N.TriggerServerEvent(name, ...) end
        N.ExecuteCommand = function(line) emu:command(player, line) end
        N.PlayerId = function() return player.id - 1 end
        N.GetPlayerServerId = function(pid) if pid == player.id - 1 then return player.id end return 0 end
        N.PlayerPedId = function() return player.ped end
        N.GetPlayerPed = function(pid) if pid == -1 or pid == player.id - 1 then return player.ped end return 0 end
        N.GetEntityCoords = function(ent)
            if ent == player.ped then return vec3(player.pos.x, player.pos.y, player.pos.z) end
            local o = player.entities[ent]
            if o then return vec3(o.x, o.y, o.z) end
            return vec3(0, 0, 0)
        end
        N.GetEntityHeading = function(ent) if ent == player.ped then return player.heading end return 0.0 end
        N.GetEntityHealth = function(ent) if ent == player.ped then return player.health end return 0 end
        N.GetEntityModel = function(ent)
            if ent == player.ped then return player.model or joaat('mp_m_freemode_01') end
            local o = player.entities[ent]
            return o and o.model or 0
        end
        -- 1 = ped, 2 = véhicule, 3 = objet
        N.GetEntityType = function(ent)
            if ent == player.ped then return 1 end
            local o = player.entities[ent]
            return o and o.type or 0
        end
        N.IsPedAPlayer = function(ent) return ent == player.ped end
        N.NetworkGetEntityIsNetworked = function(ent) local o = player.entities[ent] return o and o.network or false end
        N.IsEntityDead = function(ent) return ent == player.ped and player.health <= 0 end
        N.IsPedDeadOrDying = N.IsEntityDead
        N.GetVehiclePedIsIn = function(ent) if ent == player.ped then return player.vehicle end return 0 end
        N.IsPedInAnyVehicle = function(ent) return ent == player.ped and player.vehicle ~= 0 end
        N.GetFrameTime = function() return side.frameMs / 1000 end
        N.GetFrameCount = function() return math.floor(emu.now / side.frameMs) end
        N.IsControlPressed = function(_, c) return player.controls[c] == true end
        N.IsControlJustPressed = N.IsControlPressed
        N.IsControlJustReleased = function() return false end
        N.IsDisabledControlJustPressed = N.IsControlPressed
        N.DisableControlAction = function() end
        -- Dessin : tout est enregistré avec l'instant de l'image
        N.DrawMarker = function(mtype, x, y, z, dx, dy, dz, rx, ry, rz, sx, sy, sz, r, g, b, a)
            player.draws[#player.draws + 1] = { t = emu.now, kind = 'marker', type = mtype, x = x, y = y, z = z,
                rx = rx, ry = ry, rz = rz, sx = sx, sy = sy, sz = sz, r = r, g = g, b = b, a = a, resource = resource }
        end
        N.DrawLine = function(x1, y1, z1, x2, y2, z2, r, g, b, a)
            player.draws[#player.draws + 1] = { t = emu.now, kind = 'line', x = x1, y = y1, z = z1, x2 = x2, y2 = y2, z2 = z2, r = r, g = g, b = b, a = a }
        end
        N.DrawRect = function(x, y, w, h, r, g, b, a)
            player.draws[#player.draws + 1] = { t = emu.now, kind = 'rect', x = x, y = y, w = w, h = h, r = r, g = g, b = b, a = a }
        end
        for _, n in ipairs({ 'SetTextFont', 'SetTextScale', 'SetTextProportional', 'SetTextOutline', 'SetTextColour',
                             'SetTextCentre', 'SetTextDropshadow', 'SetTextEdge', 'SetTextWrap', 'SetTextJustification',
                             'BeginTextCommandDisplayText', 'SetTextEntry', 'BeginTextCommandThefeedPost',
                             'EndTextCommandThefeedPostTicker', 'SetNotificationTextEntry' }) do
            N[n] = function() end
        end
        local function text(s) player.texts[#player.texts + 1] = { t = emu.now, text = tostring(s), resource = resource } end
        N.AddTextComponentSubstringPlayerName = text
        N.AddTextComponentString = text
        N.EndTextCommandDisplayText = function() end
        N.DrawText = function() end
        -- NUI : messages et focus enregistrés ; les callbacks NUI s'appellent avec player:nuiCallback()
        N.SendNUIMessage = function(msg) player.nui[#player.nui + 1] = { t = emu.now, msg = netCopy(msg), resource = resource } end
        N.SendNuiMessage = function(s) player.nui[#player.nui + 1] = { t = emu.now, msg = json.decode(s), resource = resource } end
        N.SetNuiFocus = function(focus, cursor) player.nuiFocus = { focus = focus, cursor = cursor, t = emu.now } end
        N.IsNuiFocused = function() return player.nuiFocus ~= nil and player.nuiFocus.focus == true end
        N.RegisterNUICallback = function(name, fn) player.nuiCallbacks[name] = { fn = fn, resource = resource } end
        N.RegisterCommand = function(name, fn) player.clientCommands[name] = { fn = fn, resource = resource } end
        -- Entités locales : créées et suivies pour vérifier le nettoyage
        -- CreateObject(model, x, y, z, isNetwork…) ; CreatePed(type, model, x, y, z, heading, isNetwork…) ;
        -- CreateVehicle(model, x, y, z, heading, isNetwork…)
        local function create(kind)
            return function(...)
                local a = { ... }
                local o
                if kind == 1 then o = { model = a[2], x = a[3], y = a[4], z = a[5], heading = a[6], network = a[7] == true }
                elseif kind == 2 then o = { model = a[1], x = a[2], y = a[3], z = a[4], heading = a[5], network = a[6] == true }
                else o = { model = a[1], x = a[2], y = a[3], z = a[4], network = a[5] == true } end
                if type(o.model) == 'string' then o.model = joaat(o.model) end
                o.type, o.t, o.resource = kind, emu.now, resource
                player.nextEntity = (player.nextEntity or (100000 + player.id * 10000)) + 1
                player.entities[player.nextEntity] = o
                return player.nextEntity
            end
        end
        N.RequestModel = function() end
        N.HasModelLoaded = function() return true end
        N.SetModelAsNoLongerNeeded = function() end
        N.IsModelValid = function() return true end
        N.CreateObject = create(3)
        N.CreateObjectNoOffset = N.CreateObject
        N.CreatePed = create(1)
        N.CreateVehicle = create(2)
        N.DeleteEntity = function(e) player.entities[e] = nil end
        N.DeleteObject = N.DeleteEntity
        N.DeletePed = N.DeleteEntity
        N.DeleteVehicle = N.DeleteEntity
        N.DoesEntityExist = function(e) return e == player.ped or player.entities[e] ~= nil end
        N.SetEntityCoords = function(e, x, y, z)
            if e == player.ped then player.pos = { x = x, y = y, z = z }
            elseif player.entities[e] then local o = player.entities[e] o.x, o.y, o.z = x, y, z end
        end
        N.SetEntityCoordsNoOffset = N.SetEntityCoords
        N.SetEntityRotation = function(e, rx, ry, rz) local o = player.entities[e] if o then o.rx, o.ry, o.rz = rx, ry, rz end end
        N.SetEntityHeading = function(e, h) if e == player.ped then player.heading = h end end
        for _, n in ipairs({ 'FreezeEntityPosition', 'SetEntityCollision', 'SetEntityInvincible', 'SetEntityAlpha',
                             'SetEntityVisible', 'SetEntityAsMissionEntity', 'PlaceObjectOnGroundProperly' }) do
            N[n] = function() end
        end
    end

    -- Natives ajoutées par l'utilisateur (emu:native)
    for name, fn in pairs(self.extraNatives.shared) do N[name] = fn end
    for name, fn in pairs(self.extraNatives[side.kind]) do N[name] = fn end
    return N
end

-- Ajoute ou remplace une native. side = 'server', 'client' ou 'shared'. fn reçoit les arguments de la native ;
-- pour un client, la table du joueur est accessible avec emu:currentPlayer().
function Emu:native(name, fn, side)
    self.extraNatives[side or 'shared'][name] = fn
end

-- Valeur lue par GetConvar / GetConvarInt
function Emu:setConvar(name, value)
    self.convars[name] = value
end

-------------------------------------------------------------------------------
-- Environnements et chargement des scripts
-------------------------------------------------------------------------------

function Emu:_env(side, resource)
    if side.envs[resource] then return side.envs[resource] end
    local emu = self
    local env = {}
    local natives = self:_nativesFor(side, resource, env)
    setmetatable(env, { __index = function(_, k)
        local v = natives[k]
        if v ~= nil then return v end
        v = _G[k]
        if v ~= nil then return v end
        if type(k) == 'string' and k:match('^%u') then
            emu.missing[k] = emu.missing[k] or { count = 0, sides = {}, resource = resource }
            emu.missing[k].count = emu.missing[k].count + 1
            emu.missing[k].sides[side.kind] = true
            emu.missing[k].envs = emu.missing[k].envs or {}
            emu.missing[k].envs[env] = true
        end
        return nil
    end })
    side.envs[resource] = env
    return env
end

function Emu:_loadScript(side, resource, path, displayName)
    local env = self:_env(side, resource)
    local src = readFile(path)
    if not src then
        self:_error(side, ('fichier introuvable : %s'):format(path))
        return false
    end
    local chunk, err = load(preprocess(src), '@' .. (displayName or path), 't', env)
    if not chunk then
        self:_error(side, ('erreur de syntaxe : %s'):format(err))
        return false
    end
    -- Le corps d'un script s'exécute comme un fil : il peut appeler Wait
    self:_spawn(side, resource, chunk, true)
    return true
end

-------------------------------------------------------------------------------
-- Ressources : lecture du fxmanifest.lua
-------------------------------------------------------------------------------

local LIST_DIRECTIVES = {
    client_script = 'client', client_scripts = 'client',
    server_script = 'server', server_scripts = 'server',
    shared_script = 'shared', shared_scripts = 'shared',
    file = 'files', files = 'files',
    dependency = 'dependencies', dependencies = 'dependencies',
}

-- Lit le manifeste d'une ressource. `dir` = dossier de la ressource ; `name` facultatif (sinon nom du dossier).
function Emu:loadResource(dir, name)
    dir = dir:gsub('[/\\]+$', '')
    name = name or dir:match('([^/\\]+)$')
    local manifestPath = dir .. '/fxmanifest.lua'
    local src = readFile(manifestPath) or readFile(dir .. '/__resource.lua')
    assert(src, 'fxmanifest.lua introuvable dans ' .. dir)
    local res = { name = name, dir = dir, client = {}, server = {}, shared = {}, files = {}, dependencies = {}, meta = {} }
    local env = setmetatable({}, { __index = function(_, k)
        local target = LIST_DIRECTIVES[k]
        return function(v)
            local list = type(v) == 'table' and v or { v }
            if target then
                for _, x in ipairs(list) do table.insert(res[target], x) end
            else
                res.meta[k] = v
            end
            -- forme « directive 'clé' 'valeur' » (ex. data_file 'X' 'y.meta')
            return function(v2) res.meta[k] = { v, v2 } end
        end
    end })
    local chunk = assert(load(preprocess(src), '@' .. manifestPath, 't', env))
    chunk()
    self.resources[name] = res
    return res
end

-- Fausse ressource écrite en Lua (mock d'ESX, d'ox_inventory…) : def.server(env, emu) / def.client(env, emu, player)
function Emu:defineResource(name, def)
    self.resources[name] = { name = name, virtual = def, client = {}, server = {}, shared = {}, files = {},
                             dependencies = def.dependencies or {}, meta = {} }
    return self.resources[name]
end

-- Fournisseur pour une inclusion « @ressource/fichier.lua » : fn(env, side, emu)
function Emu:provide(include, fn)
    self.providers[include] = fn
end

function Emu:_expand(res, entry)
    if entry:sub(1, 1) == '@' then return { { include = entry } } end
    if not entry:find('[%*%?]') then return { { path = res.dir .. '/' .. entry, rel = entry } } end
    res._files = res._files or listFiles(res.dir)
    local glob = splitPath(entry)
    local r = {}
    for _, rel in ipairs(res._files) do
        if rel:match('%.lua$') and globMatch(glob, 1, splitPath(rel), 1) then r[#r + 1] = { path = res.dir .. '/' .. rel, rel = rel } end
    end
    return r
end

function Emu:_runSideScripts(side, res, kinds)
    if res.virtual then
        local fn = res.virtual[side.kind]
        if fn then
            local env = self:_env(side, res.name)
            self:_spawn(side, res.name, function() fn(env, self, side.player) end, true)
        end
        return
    end
    for _, kind in ipairs(kinds) do
        for _, entry in ipairs(res[kind]) do
            for _, item in ipairs(self:_expand(res, entry)) do
                if item.include then
                    local provider = self.providers[item.include]
                    if provider then
                        provider(self:_env(side, res.name), side, self)
                    else
                        self:_warn(('%s : inclusion %s non fournie (emu:provide), ignorée'):format(res.name, item.include))
                    end
                else
                    self:_loadScript(side, res.name, item.path, res.name .. '/' .. item.rel)
                end
            end
        end
    end
end

-- Démarre une ressource (déjà lue) : scripts partagés + serveur, puis client chez chaque joueur connecté
function Emu:start(name)
    local res = type(name) == 'table' and name or self.resources[name]
    assert(res, 'ressource inconnue : ' .. tostring(name))
    if self.started[res.name] then return res end
    for _, dep in ipairs(res.dependencies) do
        local depName = type(dep) == 'string' and dep:match('^([^/]+)') or nil
        if depName and self.resources[depName] and not self.started[depName] then self:start(depName) end
    end
    self.started[res.name] = true
    self.resGen[res.name] = (self.resGen[res.name] or 0) + 1
    table.insert(self.startOrder, res.name)
    self:_runSideScripts(self.server, res, { 'shared', 'server' })
    self:_dispatch(self.server, 'onResourceStart', table.pack(res.name), '', false)
    self:_dispatch(self.server, 'onServerResourceStart', table.pack(res.name), '', false)
    for _, p in ipairs(self.playerList) do
        if not p.dropped then self:_startClientResource(p, res) end
    end
    return res
end

function Emu:_startClientResource(p, res)
    self:_runSideScripts(p.side, res, { 'shared', 'client' })
    self:_dispatch(p.side, 'onClientResourceStart', table.pack(res.name), '', false)
    self:_dispatch(p.side, 'onResourceStart', table.pack(res.name), '', false)
end

-- Arrête une ressource : événements onResourceStop des deux côtés, puis ses gestionnaires, exports, commandes
-- et fils sont coupés
function Emu:stop(name)
    if not self.started[name] then return end
    local sides = { self.server }
    for _, p in ipairs(self.playerList) do if not p.dropped then sides[#sides + 1] = p.side end end
    for _, side in ipairs(sides) do
        self:_dispatch(side, 'onResourceStop', table.pack(name), '', false)
        local extra = side.kind == 'client' and 'onClientResourceStop' or 'onServerResourceStop'
        self:_dispatch(side, extra, table.pack(name), '', false)
    end
    self:run(0)
    self.resGen[name] = self.resGen[name] + 1
    for _, side in ipairs(sides) do
        for _, list in pairs(side.handlers) do
            for i = #list, 1, -1 do if list[i].resource == name then list[i].removed = true table.remove(list, i) end end
        end
        for _, set in pairs(side.netEvents) do set[name] = nil end
        for i = #side.bagHandlers, 1, -1 do
            if side.bagHandlers[i].resource == name then side.bagHandlers[i].removed = true table.remove(side.bagHandlers, i) end
        end
        side.envs[name] = nil
        side.exports[name] = nil
        if side.player then
            for k, c in pairs(side.player.clientCommands) do if c.resource == name then side.player.clientCommands[k] = nil end end
            for k, c in pairs(side.player.nuiCallbacks) do if c.resource == name then side.player.nuiCallbacks[k] = nil end end
        end
    end
    for k, c in pairs(self.server.commands) do if c.resource == name then self.server.commands[k] = nil end end
    for i = #self.startOrder, 1, -1 do if self.startOrder[i] == name then table.remove(self.startOrder, i) end end
    self.started[name] = nil
end

-------------------------------------------------------------------------------
-- Joueurs émulés
-------------------------------------------------------------------------------

-- opts : name, fps (60), rtt (ms, 40), jitter (ms, 0), loss (0-1, retransmission = +rtt), freeze = {début, fin},
-- chaos = true (désordre, hors garanties FiveM), duplicate (0-1), dropEvents = { nom = true }, clockOffset,
-- pos = {x,y,z}, heading, health (200), identifiers, aces = { 'command', 'monscript.admin' }, bucket.
-- Les mocks lisent aussi leurs propres options (esx = {...}, inventory = {...}) dans player.opts.
function Emu:addPlayer(opts)
    opts = opts or {}
    local id = self.nextPlayerId
    self.nextPlayerId = id + 1
    local p = {
        id = id, name = opts.name or ('Joueur' .. id), ped = 1000 + id, opts = opts,
        pos = opts.pos or { x = 0.0, y = 0.0, z = 30.0 }, heading = opts.heading or 0.0,
        health = opts.health or 200, vehicle = 0, bucket = opts.bucket or 0,
        identifiers = opts.identifiers or { 'license:emu' .. string.format('%040d', id), 'fivem:' .. (100000 + id) },
        aces = opts.aces or {}, clockOffset = opts.clockOffset or math.floor(self:rand() * 1e7),
        fps = opts.fps or 60,
        profile = { rtt = opts.rtt or 40, jitter = opts.jitter or 0, loss = opts.loss or 0, freeze = opts.freeze,
                    chaos = opts.chaos, duplicate = opts.duplicate, dropEvents = opts.dropEvents },
        net = { down = { bytes = 0, packets = 0 }, up = { bytes = 0, packets = 0 }, downLast = 0, upLast = 0 },
        draws = {}, texts = {}, nui = {}, nuiCallbacks = {}, clientCommands = {}, entities = {}, controls = {},
        notifications = {},
        -- interface ox_lib : menu contextuel, dialogues, barre de progression, TextUI (voir les aides plus bas)
        ui = { contexts = {}, progressLog = {}, contextLog = {} },
        received = {}, sentToClient = {}, sentToServer = {}, dropped = false, joinedAt = self.now,
    }
    p.side = self:_newSide('client', p)
    local emu = self
    function p:command(line) return emu:command(self, line) end
    function p:clientCommand(line) return emu:clientCommand(self, line) end
    function p:nuiCallback(name, data, cb) return emu:nuiCallback(self, name, data, cb) end
    function p:frames(from, to) return emu:frames(self, from, to) end
    function p:setPosition(x, y, z, heading) self.pos = { x = x, y = y, z = z } self.heading = heading or self.heading end
    function p:kill() self.health = 0 end
    function p:enterVehicle(veh) self.vehicle = veh or 5000 + self.id end
    function p:drop(reason) return emu:dropPlayer(self, reason) end
    -- Dernière notification reçue (lib.notify, ESX.ShowNotification…) dont le texte contient `text` (facultatif)
    function p:lastNotification(text)
        for i = #self.notifications, 1, -1 do
            local n = self.notifications[i]
            if not text or json.encode(n.data):find(text, 1, true) then return n end
        end
    end
    -- ox_lib : ce que le joueur ferait dans l'interface
    function p:menu() return emu:_openMenu(self) end
    function p:selectMenu(which) return emu:_selectMenu(self, which) end
    function p:closeMenu() return emu:_closeMenu(self) end
    function p:answerInput(values) return emu:_answerInput(self, values) end
    function p:answerAlert(answer) return emu:_answerAlert(self, answer) end
    function p:cancelProgress() return emu:_cancelProgress(self, true) end
    function p:progress() return self.ui.progress end
    function p:textUI() return self.ui.textUI end
    self.players[id] = p
    self.playerList[#self.playerList + 1] = p
    -- State bags : le nouveau client reçoit l'état répliqué déjà présent (sans appeler les gestionnaires)
    for bagName, b in pairs(self.server.bags) do
        for k in pairs(b.replicated) do self:_bag(p.side, bagName).data[k] = netCopy(b.data[k]) end
    end
    -- Côté serveur : arrivée du joueur ; côté client : ressources déjà démarrées
    self:_dispatch(self.server, 'playerJoining', table.pack(tostring(id)), id, false)
    for _, name in ipairs(self.startOrder) do
        if self.started[name] then self:_startClientResource(p, self.resources[name]) end
    end
    return p
end

-- Déconnexion : playerDropped est déclenché pendant que le joueur existe encore (GetPlayerName marche),
-- puis plus rien ne lui est envoyé
function Emu:dropPlayer(p, reason)
    if p.dropped or p.dropping then return end
    p.dropping = true
    p.side.dead = true
    self:_dispatch(self.server, 'playerDropped', table.pack(reason or 'émulation : déconnexion'), p.id, false)
    p.dropping = nil
    p.dropped = true
    p.droppedAt = self.now
    -- le sac du joueur disparaît avec lui
    self.server.bags['player:' .. p.id] = nil
    for _, other in ipairs(self.playerList) do other.side.bags['player:' .. p.id] = nil end
end

-- ACL minimale, comme add_ace / add_principal : le joueur est « player.<id> », hérite de « identifier.<id> »
-- pour chacun de ses identifiants et de « builtin.everyone ». Un refus (deny) l'emporte.
function Emu:addAce(principal, object, allow)
    self.aces[principal] = self.aces[principal] or {}
    self.aces[principal][object] = allow ~= false
end

function Emu:removeAce(principal, object)
    if self.aces[principal] then self.aces[principal][object] = nil end
end

function Emu:addPrincipal(child, parent)
    self.principals[child] = self.principals[child] or {}
    self.principals[child][parent] = true
end

function Emu:removePrincipal(child, parent)
    if self.principals[child] then self.principals[child][parent] = nil end
end

function Emu:_aceAllowed(p, ace)
    local function covers(obj) return obj == ace or ace:sub(1, #obj + 1) == obj .. '.' end
    -- raccourci : aces donnés directement au joueur (addPlayer{ aces = … })
    for _, a in ipairs(p.aces) do if covers(a) then return true end end
    local queue, seen, allowed = { 'player.' .. p.id, 'builtin.everyone' }, {}, false
    for _, id in ipairs(p.identifiers) do queue[#queue + 1] = 'identifier.' .. id end
    local i = 1
    while queue[i] do
        local pr = queue[i]
        i = i + 1
        if not seen[pr] then
            seen[pr] = true
            for obj, allow in pairs(self.aces[pr] or {}) do
                if covers(obj) then
                    if not allow then return false end
                    allowed = true
                end
            end
            for parent in pairs(self.principals[pr] or {}) do queue[#queue + 1] = parent end
        end
    end
    return allowed
end

-- Commandes de la console serveur gérées par l'émulateur
function Emu:_builtinCommand(name, args)
    if name == 'add_ace' and #args >= 2 then self:addAce(args[1], args[2], args[3] ~= 'deny') return true end
    if name == 'remove_ace' and #args >= 2 then self:removeAce(args[1], args[2]) return true end
    if name == 'add_principal' and #args >= 2 then self:addPrincipal(args[1], args[2]) return true end
    if name == 'remove_principal' and #args >= 2 then self:removePrincipal(args[1], args[2]) return true end
    return false
end

local function splitCommand(line)
    local args = {}
    for w in line:gsub('^%s*/', ''):gmatch('%S+') do args[#args + 1] = w end
    local name = table.remove(args, 1)
    return name, args, line:gsub('^%s*/', '')
end

-- Commande tapée par un joueur (ou la console si p = nil).
-- Joueur : une commande client passe en premier (comme FiveM) ; sinon la ligne part au serveur par le réseau
-- du joueur et s'exécute à l'arrivée. Les commandes restreintes demandent l'ACE command.<nom> ; la réponse
-- (true, ou false + 'unknown' / 'access_denied') est donnée tout de suite.
function Emu:command(p, line)
    local name, args, raw = splitCommand(line)
    if not name then return false, 'unknown' end
    if p and p.clientCommands[name] then return self:clientCommand(p, line) end
    if not p and self:_builtinCommand(name, args) then return true end
    local cmd = self.server.commands[name]
    if not cmd then
        self:_warn(('commande inconnue : %s'):format(tostring(name)))
        return false, 'unknown'
    end
    local function allowed() return not cmd.restricted or not p or self:_aceAllowed(p, 'command.' .. name) end
    if not allowed() then
        p.denied = (p.denied or 0) + 1
        return false, 'access_denied'
    end
    local function run()
        local current = self.server.commands[name]
        if not current then return end
        self:_spawn(self.server, current.resource, function() current.fn(p and p.id or 0, args, raw) end, true)
    end
    if not p then run() return true end
    self:_send(p, 'up', '/' .. name, table.pack(raw), function()
        if allowed() then run() else p.denied = (p.denied or 0) + 1 end
    end)
    return true
end

function Emu:clientCommand(p, line)
    local name, args, raw = splitCommand(line)
    local cmd = p.clientCommands[name]
    if not cmd then return false, 'unknown' end
    self:_spawn(p.side, cmd.resource, function() cmd.fn(0, args, raw) end, true)
    return true
end

-- Simule un appel NUI → Lua (fetch depuis la page). cb reçoit la réponse du script.
function Emu:nuiCallback(p, name, data, cb)
    local h = p.nuiCallbacks[name]
    if not h then return false, 'unknown' end
    self:_spawn(p.side, h.resource, function() h.fn(netCopy(data or {}), function(r) if cb then cb(r) end end) end, true)
    return true
end

-- Images dessinées par un joueur (groupées par instant), entre from et to (ms virtuelles)
function Emu:frames(p, from, to)
    local frames, byT = {}, {}
    for _, d in ipairs(p.draws) do
        if (not from or d.t >= from) and (not to or d.t <= to) then
            local f = byT[d.t]
            if not f then f = { t = d.t, draws = {} } byT[d.t] = f frames[#frames + 1] = f end
            f.draws[#f.draws + 1] = d
        end
    end
    return frames
end

function Emu:currentPlayer(side)
    return side and side.player
end

-- Environnement (globales + natives) d'une ressource, côté serveur (target = nil) ou chez un joueur.
-- Sert dans les tests à agir « depuis » une ressource : emu:env(p, 'ma_ressource').TriggerServerEvent('x')
function Emu:env(target, resource)
    return self:_env(target and target.side or self.server, resource)
end

-------------------------------------------------------------------------------
-- Rapport
-------------------------------------------------------------------------------

function Emu:report()
    local lines = {}
    local function add(s) lines[#lines + 1] = s end
    add(('fivem_emu %s — t = %.1f s virtuelles, %d joueur(s)'):format(Emu.VERSION, self.now / 1000, #self.playerList))
    add(('erreurs : %d'):format(#self.errors))
    for _, e in ipairs(self.errors) do add('  ' .. e) end
    if #self.warnings > 0 then
        add(('avertissements : %d'):format(#self.warnings))
        for i = 1, math.min(#self.warnings, 20) do add('  ' .. self.warnings[i]) end
    end
    local missing = {}
    for k, m in pairs(self.missing) do
        local definedLater = false
        for env in pairs(m.envs or {}) do if rawget(env, k) ~= nil then definedLater = true end end
        if not definedLater then missing[#missing + 1] = k end
    end
    table.sort(missing)
    if #missing > 0 then
        add('globales lues mais jamais définies (natives à simuler avec emu:native ?) : ' .. table.concat(missing, ', '))
    end
    if self.broadcasts then add(('TriggerClientEvent vers tous (-1) : %d fois'):format(self.broadcasts)) end
    for _, p in ipairs(self.playerList) do
        add(('joueur %d (%s, RTT %d ms) : reçu %d paquets / %.1f Ko, envoyé %d / %.1f Ko, %d dessins, %d entités locales restantes%s')
            :format(p.id, p.name, p.profile.rtt, p.net.down.packets, p.net.down.bytes / 1024, p.net.up.packets,
                p.net.up.bytes / 1024, #p.draws, (function() local n = 0 for _ in pairs(p.entities) do n = n + 1 end return n end)(),
                p.dropped and ', déconnecté' or ''))
    end
    for _, fn in ipairs(self.reporters) do fn(add) end
    return table.concat(lines, '\n')
end

-------------------------------------------------------------------------------
-- Audit anti-triche : emu:fuzz
-------------------------------------------------------------------------------
-- Rejoue les événements réseau serveur comme le ferait un tricheur (exécuteur Lua) : le vrai trafic observé
-- pendant le test, modifié argument par argument avec des valeurs piégées, envoyé en rafale, depuis trop loin.
-- Des sondes mesurent l'argent et les objets de chaque joueur avant et après chaque tentative ; tout ce qui
-- rapporte plus que l'appel normal, ou fait perdre quelque chose à un autre joueur, est signalé.

-- Sonde : fn(joueur) → { clé = nombre }. Les mocks ESX et ox_inventory ajoutent les leurs.
function Emu:addProbe(name, fn)
    self.probes[name] = fn
end

local INJECTION = "emu' OR '1'='1"
local HOSTILE = {
    { label = 'nil' }, { label = '-1', value = -1 }, { label = '0', value = 0 }, { label = '-100000', value = -100000 },
    { label = '1e9', value = 1000000000 }, { label = '2^31', value = 2147483648 }, { label = '0.5', value = 0.5 },
    { label = 'NaN', value = 0 / 0 }, { label = 'inf', value = math.huge }, { label = "''", value = '' },
    { label = 'chaîne de 10 Ko', value = string.rep('A', 10000) }, { label = 'injection SQL', value = INJECTION },
    { label = '{}', value = {} }, { label = 'true', value = true },
}
local SEVERITY = { critique = 1, attention = 2, info = 3 }

function Emu:_probeAll()
    local snap = {}
    for _, p in ipairs(self.playerList) do
        if not p.dropped then
            local s = {}
            for name, fn in pairs(self.probes) do
                local ok, r = pcall(fn, p)
                if ok and type(r) == 'table' then
                    for k, v in pairs(r) do if type(v) == 'number' then s[name .. ':' .. k] = v end end
                end
            end
            snap[p.id] = s
        end
    end
    return snap
end

local function probeDelta(a, b)
    local d = {}
    for id, after in pairs(b) do
        local before = a[id] or {}
        local keys = {}
        for k in pairs(after) do keys[k] = true end
        for k in pairs(before) do keys[k] = true end
        for k in pairs(keys) do
            local x1, x0 = after[k] or 0, before[k] or 0
            local x = x1 - x0
            -- déjà corrompue avant la tentative : ce n'est pas cette tentative qui l'a cassée
            if x ~= 0 and x0 == x0 and math.abs(x0) ~= math.huge then d[id] = d[id] or {} d[id][k] = x end
        end
    end
    return d
end

local function fmtNum(x) return math.type(x) == 'integer' and ('%+d'):format(x) or ('%+.2f'):format(x) end

-- opts : resources = { noms } (par défaut : ressources lues sur disque), events = { noms } (filtre), skip = { noms },
-- player = joueur tricheur (par défaut : celui qui a envoyé le trafic observé, sinon le premier),
-- settle (ms d'attente après chaque envoi), spam (10 envois en rafale), maxCalls (2 appels observés par événement).
-- Renvoie { findings = { { severity, event, kind, detail, args } }, attempts, events } et r:text().
-- À lancer en fin de test : les tentatives modifient l'état (argent, objets…). Les erreurs Lua provoquées
-- sont rangées dans le résultat, pas dans emu.errors.
function Emu:fuzz(opts)
    opts = opts or {}
    local emu = self
    local result = { findings = {}, attempts = 0, events = {} }
    local seen = {}

    local targets = {}
    if opts.resources then
        for _, r in ipairs(opts.resources) do targets[r] = true end
    else
        for name in pairs(self.started) do
            local r = self.resources[name]
            if r and not r.virtual then targets[name] = true end
        end
    end
    local only, skip = nil, {}
    if opts.events then only = {} for _, e in ipairs(opts.events) do only[e] = true end end
    for _, e in ipairs(opts.skip or {}) do skip[e] = true end

    local function display(name)
        local cb = name:match('^__emu_ox_cb:(.+)$')
        return cb and ('lib.callback « %s »'):format(cb) or name
    end

    -- Événements visés et leur nombre de paramètres (debug.getinfo), triés pour un résultat reproductible
    local events = {}
    for name, set in pairs(self.server.netEvents) do
        local wanted = false
        for r in pairs(set) do if targets[r] then wanted = true end end
        if wanted and not skip[name] and (not only or only[name]) and name ~= '__emu_ox_cb:reply' then
            local arity, vararg = 0, false
            for _, h in ipairs(self.server.handlers[name] or {}) do
                if targets[h.resource] then
                    local info = debug.getinfo(h.fn, 'u')
                    arity = math.max(arity, info.nparams)
                    vararg = vararg or info.isvararg
                end
            end
            if vararg then arity = math.max(arity, 3) end
            events[#events + 1] = { name = name, arity = arity }
        end
    end
    table.sort(events, function(a, b) return a.name < b.name end)

    local function anyPlayer()
        for _, p in ipairs(self.playerList) do if not p.dropped then return p end end
    end

    -- Trafic réel observé : par événement, les premiers appels distincts et leur expéditeur
    local observed = {}
    for _, p in ipairs(self.playerList) do
        for _, m in ipairs(p.sentToServer) do
            if m.args then
                local list = observed[m.name] or {}
                observed[m.name] = list
                local key = json.encode(m.args)
                if #list < (opts.maxCalls or 2) and not list[key] then
                    list[key] = true
                    list[#list + 1] = { sender = p, args = m.args }
                end
            end
        end
    end

    local function sqlLogSize() return self.mocks.oxmysql and #self.mocks.oxmysql.log or 0 end

    local function attempt(sender, name, args, copies)
        local before = self:_probeAll()
        local nErr, nWarn, nSql = #self.errors, #self.warnings, sqlLogSize()
        for _ = 1, copies or 1 do
            self:_send(sender, 'up', name, args, function(copy) self:_dispatch(self.server, name, copy, sender.id, true) end)
        end
        local settle = opts.settle or ((sender.profile.rtt + (sender.profile.jitter or 0)) * 2 + 500)
        self:run(settle)
        result.attempts = result.attempts + 1
        local r = { delta = probeDelta(before, self:_probeAll()), errors = {}, dropped = sender.dropped }
        for i = nErr + 1, #self.errors do r.errors[#r.errors + 1] = self.errors[i] end
        for i = #self.errors, nErr + 1, -1 do self.errors[i] = nil end
        for i = #self.warnings, nWarn + 1, -1 do self.warnings[i] = nil end
        if self.mocks.oxmysql then
            for i = nSql + 1, #self.mocks.oxmysql.log do
                local q = self.mocks.oxmysql.log[i].query
                if type(q) == 'string' and q:find(INJECTION, 1, true) then r.sql = q end
            end
        end
        return r
    end

    local function add(severity, event, kind, detail, args)
        local key = event .. '|' .. kind
        if seen[key] then return end
        seen[key] = true
        result.findings[#result.findings + 1] = { severity = severity, event = display(event), kind = kind,
                                                  detail = detail, args = args }
    end

    local function hasPositive(delta, id)
        for _, x in pairs(delta[id] or {}) do if x > 0 then return true end end
        return false
    end
    local function bad(x) return x ~= x or x == math.huge or x == -math.huge end

    -- Ce qui change par rapport à l'appel normal :
    --  gain = le tricheur finit avec plus qu'avant et plus qu'avec l'appel normal (payer moins n'est pas un gain) ;
    --  moins cher = au moins tout ce que donne l'appel normal, en payant moins ;
    --  perte = un autre joueur finit avec moins qu'avant et moins qu'avec l'appel normal ;
    --  une valeur qui devient NaN ou infinie compte toujours.
    local function compare(sender, r, control)
        local gains, losses = {}, {}
        local mine, ref = r.delta[sender.id] or {}, control.delta[sender.id] or {}
        for k, x in pairs(mine) do
            local base = ref[k] or 0
            if bad(x) then
                gains[#gains + 1] = ('%s devient %s (valeur corrompue)'):format(k, tostring(x))
            elseif x > 0 and x > base then
                gains[#gains + 1] = ('%s %s (appel normal : %s)'):format(k, fmtNum(x), fmtNum(base))
            end
        end
        if #gains == 0 and hasPositive(control.delta, sender.id) then
            local keys, better, worse = {}, {}, false
            for k in pairs(mine) do keys[k] = true end
            for k in pairs(ref) do keys[k] = true end
            for k in pairs(keys) do
                local x, base = mine[k] or 0, ref[k] or 0
                if x < base then worse = true end
                if x > base then better[#better + 1] = ('%s %s (appel normal : %s)'):format(k, fmtNum(x), fmtNum(base)) end
            end
            if not worse and #better > 0 then
                table.sort(better)
                gains[1] = 'même résultat pour moins cher : ' .. table.concat(better, ', ')
            end
        end
        for id, d in pairs(r.delta) do
            if id ~= sender.id then
                local cref = control.delta[id] or {}
                for k, x in pairs(d) do
                    local base = cref[k] or 0
                    if bad(x) or (x < 0 and x < base) then
                        losses[#losses + 1] = ('joueur %d : %s %s (appel normal : %s)'):format(id, k, fmtNum(x), fmtNum(base))
                    end
                end
            end
        end
        table.sort(gains)
        table.sort(losses)
        return gains, losses
    end

    -- Effet « qui rapporte » : le joueur reçoit quelque chose, ou un autre joueur perd quelque chose
    local function rewarding(delta, id)
        if hasPositive(delta, id) then return true end
        for other, d in pairs(delta) do
            if other ~= id then for _, x in pairs(d) do if x < 0 then return true end end end
        end
        return false
    end

    local function victimOf(sender)
        for _, p in ipairs(self.playerList) do if p ~= sender and not p.dropped then return p end end
    end

    -- Remplace par un nouveau joueur identique un tricheur expulsé (DropPlayer = protection qui marche) ou dont
    -- une valeur est devenue NaN / infinie (les mesures suivantes n'auraient plus de sens)
    local function ensureAlive(sender)
        if not sender.dropped then
            for _, v in pairs(self:_probeAll()[sender.id] or {}) do
                if v ~= v or v == math.huge or v == -math.huge then
                    self:dropPlayer(sender, 'audit : valeurs corrompues')
                    break
                end
            end
        end
        if not sender.dropped then return sender end
        local clone = self:addPlayer(sender.opts)
        self:run(opts.joinMs or 3000)
        return clone
    end

    for _, ev in ipairs(events) do
        local name = ev.name
        result.events[#result.events + 1] = display(name)
        local calls = observed[name]
        local isCallback = name:find('^__emu_ox_cb:') ~= nil
        if not calls then
            local sender = opts.player or anyPlayer()
            if not sender then break end
            local args = { n = ev.arity }
            if isCallback then args[1], args.n = 'fuzz', math.max(args.n, 2) end
            calls = { { sender = sender, args = args, synthetic = true } }
        end
        for _, call in ipairs(calls) do
            local sender = ensureAlive(opts.player or call.sender)
            local base = call.args
            local control = attempt(sender, name, base)
            if control.dropped then
                add('info', name, 'expulsion', 'l\'appel normal expulse déjà le joueur (DropPlayer)', base)
                sender = ensureAlive(sender)
            end

            -- Variantes : chaque argument (et chaque champ d'un argument table) remplacé par une valeur piégée
            local variants = {}
            local first = isCallback and 2 or 1
            local victim = victimOf(sender)
            for i = first, math.max(base.n or #base, ev.arity) do
                local values = table.move(HOSTILE, 1, #HOSTILE, 1, {})
                if victim then values[#values + 1] = { label = ('id d\'un autre joueur (%d)'):format(victim.id), value = victim.id } end
                for _, h in ipairs(values) do
                    local a = netCopy(base)
                    a.n = math.max(a.n or #a, i)
                    a[i] = netCopy(h.value)
                    variants[#variants + 1] = { args = a, pos = ('argument %d'):format(i - first + 1), label = h.label }
                end
                if type(base[i]) == 'table' and getmetatable(base[i]) ~= VEC then
                    local fields = {}
                    for k in pairs(base[i]) do fields[#fields + 1] = k end
                    table.sort(fields, function(x, y) return tostring(x) < tostring(y) end)
                    for f = 1, math.min(#fields, 8) do
                        for _, h in ipairs(values) do
                            local a = netCopy(base)
                            a[i][fields[f]] = netCopy(h.value)
                            variants[#variants + 1] = { args = a, label = h.label,
                                pos = ('argument %d.%s'):format(i - first + 1, tostring(fields[f])) }
                        end
                    end
                end
            end

            for _, v in ipairs(variants) do
                local r = attempt(sender, name, v.args)
                local gains, losses = compare(sender, r, control)
                local with = ('valeur %s'):format(v.label)
                if #gains > 0 then
                    add('critique', name, ('gain (%s)'):format(v.pos), ('%s → %s'):format(with, table.concat(gains, ', ')), v.args)
                end
                if #losses > 0 then
                    add('critique', name, ('perte pour un autre joueur (%s)'):format(v.pos),
                        ('%s → %s'):format(with, table.concat(losses, ', ')), v.args)
                end
                if r.sql then add('critique', name, ('injection SQL (%s)'):format(v.pos), 'requête envoyée : ' .. r.sql, v.args) end
                if #r.errors > 0 and #control.errors == 0 then
                    add('info', name, ('erreur Lua (%s)'):format(v.pos),
                        ('%s → %s'):format(with, (r.errors[1]:gsub('\n.*', ''))), v.args)
                end
                sender = ensureAlive(sender)
            end

            -- Rafale : un gain répété à chaque envoi = pas d'anti-spam (cooldown, verrou, état « déjà fait »)
            if hasPositive(control.delta, sender.id) then
                local n = opts.spam or 10
                local r = attempt(sender, name, base, n)
                local gains = {}
                for k, x in pairs(r.delta[sender.id] or {}) do
                    local one = (control.delta[sender.id] or {})[k] or 0
                    if one > 0 and x >= 2 * one then gains[#gains + 1] = ('%s %s (1 envoi : %s)'):format(k, fmtNum(x), fmtNum(one)) end
                end
                table.sort(gains)
                if #gains > 0 then
                    add('attention', name, 'pas d\'anti-spam', ('%d envois en rafale : %s'):format(n, table.concat(gains, ', ')), base)
                end
                sender = ensureAlive(sender)
            end

            -- Distance : le même gain depuis 10 km = la position n'est pas vérifiée côté serveur
            if rewarding(control.delta, sender.id) then
                local pos = sender.pos
                sender.pos = { x = pos.x + 10000.0, y = pos.y + 10000.0, z = pos.z }
                local r = attempt(sender, name, base)
                sender.pos = pos
                if Emu.deepEqual(r.delta, control.delta) then
                    add('attention', name, 'aucun contrôle de distance', 'même effet à 10 km de la position du test', base)
                end
                sender = ensureAlive(sender)
            end
        end
    end

    table.sort(result.findings, function(a, b)
        if SEVERITY[a.severity] ~= SEVERITY[b.severity] then return SEVERITY[a.severity] < SEVERITY[b.severity] end
        if a.event ~= b.event then return a.event < b.event end
        return a.kind < b.kind
    end)

    function result:count(severity)
        local n = 0
        for _, f in ipairs(self.findings) do if not severity or f.severity == severity then n = n + 1 end end
        return n
    end
    function result:text()
        local lines = { ('Audit anti-triche : %d événement(s), %d tentative(s), %d critique(s), %d attention, %d info')
            :format(#self.events, self.attempts, self:count('critique'), self:count('attention'), self:count('info')) }
        for _, f in ipairs(self.findings) do
            lines[#lines + 1] = ('  %-9s %s — %s : %s'):format(f.severity:upper(), f.event, f.kind, f.detail)
        end
        return table.concat(lines, '\n')
    end
    return result
end

-------------------------------------------------------------------------------
-- Vérifications pour les scripts de test
-------------------------------------------------------------------------------

local function deepEqual(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
Emu.deepEqual = deepEqual

-- local T = Emu.tester('titre') ; T:check(cond, 'libellé', détail) ; T:eq(obtenu, attendu, 'libellé') ;
-- T:same(t1, t2, 'libellé') (comparaison profonde) ; T:summary() affiche le bilan et renvoie true si tout passe
function Emu.tester(title, opts)
    opts = opts or {}
    local T = { passed = 0, failed = 0, failures = {} }
    if title then print('== ' .. title) end
    function T:check(cond, label, detail)
        if cond then
            self.passed = self.passed + 1
            if not opts.quiet then print('  ok     ' .. label) end
        else
            self.failed = self.failed + 1
            self.failures[#self.failures + 1] = label
            print('  ÉCHEC  ' .. label .. (detail ~= nil and (' — ' .. tostring(detail)) or ''))
        end
        return cond and true or false
    end
    function T:eq(got, expected, label)
        return self:check(got == expected, label, ('obtenu %s, attendu %s'):format(tostring(got), tostring(expected)))
    end
    function T:same(got, expected, label)
        return self:check(deepEqual(got, expected), label, ('obtenu %s, attendu %s'):format(json.encode(got), json.encode(expected)))
    end
    function T:section(name) print('-- ' .. name) end
    function T:summary()
        print(('%d vérifications : %d réussies, %d échouées'):format(self.passed + self.failed, self.passed, self.failed))
        return self.failed == 0
    end
    return T
end

-------------------------------------------------------------------------------
-- Fournisseurs intégrés pour les inclusions courantes
-------------------------------------------------------------------------------

function Emu:_installDefaultProviders()
    local emu = self
    local function notify(player, data, resource)
        player.notifications[#player.notifications + 1] = { t = emu.now, data = netCopy(data), resource = resource }
    end
    -- Ressource ox_lib minimale : reçoit les lib.notify envoyés par le serveur
    self:defineResource('ox_lib', {
        client = function(env, _, player)
            env.RegisterNetEvent('ox_lib:notify', function(data) notify(player, data, 'ox_lib') end)
        end,
    })
    self:start('ox_lib')

    -- ox_lib : lib.callback (aller-retour réseau émulé), lib.notify (enregistré), lib.print, cache
    self:provide('@ox_lib/init.lua', function(env, side)
        local lib = {}
        local resource = env.GetCurrentResourceName()
        local pending, nextId = {}, 0
        local cbEvent = '__emu_ox_cb:'
        lib.callback = setmetatable({}, { __call = function(_, name, delay, cb, ...)
            local args = table.pack(...)
            env.CreateThread(function() cb(lib.callback.await(name, delay, unpack(args, 1, args.n))) end)
        end })
        function lib.callback.register(name, fn)
            env.RegisterNetEvent(cbEvent .. name, function(key, ...)
                local src = env.source
                -- côté serveur le rappel reçoit (source, ...), côté client seulement (...)
                local r
                if side.kind == 'server' then r = table.pack(pcall(fn, src, ...)) else r = table.pack(pcall(fn, ...)) end
                if not r[1] then
                    emu:_error(side, ('lib.callback « %s » : %s'):format(name, tostring(r[2])))
                    r = { n = 1 }
                else
                    r = table.pack(unpack(r, 2, r.n))
                end
                if side.kind == 'server' then
                    env.TriggerClientEvent(cbEvent .. 'reply', src, key, unpack(r, 1, r.n))
                else
                    env.TriggerServerEvent(cbEvent .. 'reply', key, unpack(r, 1, r.n))
                end
            end)
        end
        env.RegisterNetEvent(cbEvent .. 'reply', function(key, ...)
            local waiter = pending[key]
            if waiter then
                pending[key] = nil
                waiter.resume(...)
            end
        end)
        function lib.callback.await(name, delay, ...)
            nextId = nextId + 1
            -- clé unique par côté et par ressource : deux ressources ne se volent pas leurs réponses
            local key = ('%s:%s:%d'):format(side.name, resource, nextId)
            local token = { await = true }
            pending[key] = token
            if side.kind == 'client' then
                env.TriggerServerEvent(cbEvent .. name, key, ...)
            else
                env.TriggerClientEvent(cbEvent .. name, delay, key, ...)
            end
            return coroutine.yield(token)
        end
        if side.kind == 'server' then
            function lib.notify(playerId, data) env.TriggerClientEvent('ox_lib:notify', playerId, data) end
        else
            function lib.notify(data) notify(side.player, data, resource) end
        end
        lib.print = setmetatable({}, { __index = function() return function(...) env.print(...) end end })
        lib.locale = function() end
        lib.context = side.kind
        env.lib = lib
        env.locale = function(key, ...) return key end
        env.cache = { resource = resource, game = 'fivem', playerId = side.player and side.player.id - 1,
                      serverId = side.player and side.player.id, ped = side.player and side.player.ped }
        emu:_oxlibExtras(lib, env, side, resource)
    end)
end

-------------------------------------------------------------------------------
-- ox_lib : modules au-delà des rappels (zones, points, commandes, interface, outils)
-------------------------------------------------------------------------------

local function xyz(c)
    if c == nil then return 0.0, 0.0, 0.0 end
    return c.x or c[1] or 0.0, c.y or c[2] or 0.0, c.z or c[3] or 0.0
end

local function distance3(c, x, y, z)
    local cx, cy, cz = xyz(c)
    return math.sqrt((x - cx) ^ 2 + (y - cy) ^ 2 + (z - cz) ^ 2)
end

-- Zones ox_lib : sphere (rayon, 2 par défaut), box (taille, rotation en degrés autour de z), poly (points, épaisseur 4)
local function zoneContains(zone, px, py, pz)
    if zone.__kind == 'sphere' then
        return distance3(zone.coords, px, py, pz) < zone.radius
    elseif zone.__kind == 'box' then
        local x, y, z = xyz(zone.coords)
        local sx, sy, sz = xyz(zone.size)
        local r = -math.rad(zone.rotation or 0)
        local dx, dy = px - x, py - y
        local lx, ly = dx * math.cos(r) - dy * math.sin(r), dx * math.sin(r) + dy * math.cos(r)
        return math.abs(lx) <= sx / 2 and math.abs(ly) <= sy / 2 and math.abs(pz - z) <= sz / 2
    end
    -- polygone : test de parité en x/y, hauteur = z moyen des points ± épaisseur / 2
    local pts, inside, sumZ = zone.points, false, 0
    local j = #pts
    for i = 1, #pts do
        local xi, yi, zi = xyz(pts[i])
        local xj, yj = xyz(pts[j])
        sumZ = sumZ + zi
        if (yi > py) ~= (yj > py) and px < (xj - xi) * (py - yi) / (yj - yi) + xi then inside = not inside end
        j = i
    end
    return inside and math.abs(pz - sumZ / #pts) <= zone.thickness / 2
end

local function tableMatches(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do if not tableMatches(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function deepclone(t)
    if type(t) ~= 'table' then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = deepclone(v) end
    return setmetatable(r, getmetatable(t))
end

function Emu:_oxlibExtras(lib, env, side, resource)
    local emu = self

    -- Attend que cb() renvoie autre chose que nil (1 s par défaut, false = sans limite), comme lib.waitFor
    function lib.waitFor(cb, errMessage, timeout)
        local value = cb()
        if value ~= nil then return value end
        if timeout == nil or (timeout and type(timeout) ~= 'number') then timeout = 1000 end
        local start = emu.now
        while value == nil do
            env.Wait(0)
            local elapsed = emu.now - start
            if timeout and elapsed > timeout then
                error(('%s (waited %.1fms)'):format(errMessage or 'failed to resolve callback', elapsed), 2)
            end
            value = cb()
        end
        return value
    end

    lib.table = {
        -- valeur, ou table de valeurs qui doivent toutes être présentes
        contains = function(tbl, value)
            if type(value) ~= 'table' then
                for _, v in pairs(tbl) do if v == value then return true end end
                return false
            end
            for _, needed in pairs(value) do
                local found = false
                for _, v in pairs(tbl) do if v == needed then found = true break end end
                if not found then return false end
            end
            return true
        end,
        matches = tableMatches,
        deepclone = deepclone,
        merge = function(t1, t2, addDuplicateNumbers)
            if addDuplicateNumbers == nil then addDuplicateNumbers = true end
            for k, v in pairs(t2) do
                local v1 = t1[k]
                if type(v1) == 'table' and type(v) == 'table' then lib.table.merge(v1, v, addDuplicateNumbers)
                elseif addDuplicateNumbers and type(v1) == 'number' and type(v) == 'number' then t1[k] = v1 + v
                else t1[k] = v end
            end
            return t1
        end,
    }

    -- Joueurs proches : { id, ped, coords } ; id = id serveur côté serveur, index de joueur côté client
    local function nearbyPlayers(coords, maxDistance, skipId)
        local r = {}
        local x, y, z = xyz(coords)
        for _, o in ipairs(emu.playerList) do
            if not o.dropped and o.id ~= skipId then
                local d = distance3(o.pos, x, y, z)
                if d <= (maxDistance or 2.0) then
                    r[#r + 1] = { id = side.kind == 'server' and o.id or o.id - 1, ped = o.ped,
                                  coords = vec3(o.pos.x, o.pos.y, o.pos.z), distance = d }
                end
            end
        end
        return r
    end
    local function closest(list)
        local best
        for _, o in ipairs(list) do if not best or o.distance < best.distance then best = o end end
        if best then return best.id, best.ped, best.coords end
    end

    if side.kind == 'server' then
        function lib.getNearbyPlayers(coords, maxDistance, ignorePlayerId)
            local r = nearbyPlayers(coords, maxDistance, ignorePlayerId)
            for _, o in ipairs(r) do o.distance = nil end
            return r
        end
        function lib.getClosestPlayer(coords, maxDistance, ignorePlayerId)
            return closest(nearbyPlayers(coords, maxDistance, ignorePlayerId))
        end
        function lib.addAce(principal, ace, allow) emu:addAce(principal, ace, allow) end
        function lib.removeAce(principal, ace) emu:removeAce(principal, ace) end
        function lib.addPrincipal(child, parent) emu:addPrincipal(child, parent) end
        function lib.removePrincipal(child, parent) emu:removePrincipal(child, parent) end

        -- Arguments typés comme ox_lib : number, string (pas un nombre), playerId ('me' = soi), longString (le reste).
        -- Un argument invalide ou manquant (non optionnel) : message dans la console et la commande ne s'exécute pas.
        local function parseArguments(source, args, raw, params)
            for i = 1, #params do
                local arg, param = args[i], params[i]
                local value
                if param.type == 'number' then value = tonumber(arg)
                elseif param.type == 'string' then value = not tonumber(arg) and arg
                elseif param.type == 'playerId' then
                    value = arg == 'me' and source or tonumber(arg)
                    local o = value and emu.players[value]
                    if not o or o.dropped then value = false end
                elseif param.type == 'longString' and i == #params then
                    if arg then
                        local start = raw:find(arg, 1, true)
                        value = start and raw:sub(start)
                    end
                else value = arg end
                if not value and (not param.optional or arg) then
                    env.Citizen.Trace(("command '%s' received an invalid %s for argument %s (%s), received '%s'")
                        :format(raw:match('^(%S+)') or raw, tostring(param.type), i, tostring(param.name), tostring(arg)))
                    return nil
                end
                args[param.name] = value or nil
                args[i] = nil
            end
            return args
        end

        -- lib.addCommand('nom' ou { 'a', 'b' }, { help, params, restricted = 'group.admin' | true }, fn(source, args, raw))
        function lib.addCommand(commandName, properties, cb)
            local names = type(commandName) == 'table' and commandName or { commandName }
            local params = properties and properties.params
            local restricted = properties and properties.restricted
            for _, name in ipairs(names) do
                env.RegisterCommand(name, function(source, args, raw)
                    if params then
                        args = parseArguments(source, args, raw, params)
                        if not args then return end
                    end
                    cb(source, args, raw)
                end, restricted and true or false)
                if type(restricted) == 'string' then emu:addAce(restricted, 'command.' .. name, true)
                elseif type(restricted) == 'table' then
                    for _, principal in ipairs(restricted) do emu:addAce(principal, 'command.' .. name, true) end
                end
            end
        end
        return
    end

    local player = side.player
    local ui = player.ui

    function lib.getNearbyPlayers(coords, maxDistance, includePlayer)
        local r = nearbyPlayers(coords, maxDistance, not includePlayer and player.id or nil)
        for _, o in ipairs(r) do o.distance = nil end
        return r
    end
    function lib.getClosestPlayer(coords, maxDistance, includePlayer)
        return closest(nearbyPlayers(coords, maxDistance, not includePlayer and player.id or nil))
    end

    -- Chargement d'assets : tout est déjà « chargé » ; requestModel renvoie le hash
    function lib.requestModel(model) return type(model) == 'string' and joaat(model) or model end
    for _, n in ipairs({ 'requestAnimDict', 'requestAnimSet', 'requestNamedPtfxAsset', 'requestStreamedTextureDict',
                         'requestWeaponAsset', 'requestScaleformMovie', 'requestAudioBank' }) do
        lib[n] = function(asset) return asset end
    end
    function lib.onCache() end

    -- Zones et points : entrées / sorties évaluées toutes les 300 ms, inside et nearby à chaque image (comme ox_lib)
    local zones, points, looping, nextZone = {}, {}, false, 0
    local function call(obj, fname)
        local ok, err = pcall(obj[fname], obj)
        if not ok then emu:_error(side, ('ox_lib %s (%s) : %s'):format(fname, resource, tostring(err))) end
    end
    local function startLoop()
        if looping then return end
        looping = true
        env.CreateThread(function()
            while true do
                local px, py, pz = player.pos.x, player.pos.y, player.pos.z
                for _, zone in ipairs(table.move(zones, 1, #zones, 1, {})) do
                    zone.distance = distance3(zone.coords, px, py, pz)
                    local inside = zoneContains(zone, px, py, pz)
                    if inside and not zone.insideZone then
                        zone.insideZone = true
                        if zone.onEnter then call(zone, 'onEnter') end
                    elseif not inside and zone.insideZone then
                        zone.insideZone = false
                        if zone.onExit then call(zone, 'onExit') end
                    end
                end
                local best
                for _, point in ipairs(table.move(points, 1, #points, 1, {})) do
                    local d = distance3(point.coords, px, py, pz)
                    if d <= point.distance then
                        point.currentDistance = d
                        if not best or d < best.currentDistance then best = point end
                        if not point.__near then
                            point.__near = true
                            if point.onEnter then call(point, 'onEnter') end
                        end
                    elseif point.__near then
                        point.__near, point.currentDistance = false, nil
                        if point.onExit then call(point, 'onExit') end
                    end
                end
                for _, point in ipairs(points) do point.isClosest = point == best end
                env.Wait(300)
            end
        end)
        env.CreateThread(function()
            while true do
                for _, zone in ipairs(table.move(zones, 1, #zones, 1, {})) do
                    if zone.insideZone and zone.inside then call(zone, 'inside') end
                end
                for _, point in ipairs(table.move(points, 1, #points, 1, {})) do
                    if point.__near and point.nearby then call(point, 'nearby') end
                end
                env.Wait(0)
            end
        end)
    end
    local function removeFrom(list, obj)
        for i = #list, 1, -1 do if list[i] == obj then table.remove(list, i) end end
    end

    local function newZone(kind, data)
        data.__kind = kind
        if kind == 'sphere' then
            data.radius = data.radius or 2.0
        elseif kind == 'box' then
            data.size = data.size or vec3(2.0, 2.0, 2.0)
            data.rotation = data.rotation or 0
        else
            data.thickness = data.thickness or 4
            local sx, sy, sz = 0, 0, 0
            for _, pt in ipairs(data.points) do local x, y, z = xyz(pt) sx, sy, sz = sx + x, sy + y, sz + z end
            local n = #data.points
            data.coords = data.coords or vec3(sx / n, sy / n, sz / n)
        end
        nextZone = nextZone + 1
        data.id = nextZone
        function data.remove(self) removeFrom(zones, self) end
        function data.contains(self, coords) return zoneContains(self, xyz(coords)) end
        zones[#zones + 1] = data
        startLoop()
        return data
    end
    lib.zones = {
        sphere = function(data) return newZone('sphere', data) end,
        box = function(data) return newZone('box', data) end,
        poly = function(data) return newZone('poly', data) end,
        getAllZones = function() return zones end,
        getCurrentZones = function()
            local r = {}
            for _, zone in ipairs(zones) do if zone.insideZone then r[#r + 1] = zone end end
            return r
        end,
    }

    -- lib.points.new({ coords, distance, onEnter, onExit, nearby, … }) ou new(coords, distance, data)
    lib.points = {
        new = function(a, b, c)
            local data = a
            if getmetatable(a) == VEC or a.coords == nil then data = c or {} data.coords, data.distance = a, b end
            data.distance = data.distance or 1.0
            function data.remove(self) removeFrom(points, self) end
            points[#points + 1] = data
            startLoop()
            return data
        end,
        getAllPoints = function() return points end,
        getNearbyPoints = function()
            local r = {}
            for _, point in ipairs(points) do if point.__near then r[#r + 1] = point end end
            return r
        end,
        getClosestPoint = function() for _, point in ipairs(points) do if point.isClosest then return point end end end,
    }

    -- Barre de progression : bloque le fil jusqu'à la fin (true) ou l'annulation (false) ;
    -- annulée par p:cancelProgress() (si canCancel), lib.cancelProgress(), ou la mort sans useWhileDead
    local function progress(kind, data)
        if ui.progress then return false end
        local entry = { kind = kind, label = data.label, duration = data.duration or 0, canCancel = data.canCancel == true,
                        data = data, t = emu.now, resource = resource }
        ui.progress = entry
        ui.progressLog[#ui.progressLog + 1] = entry
        local endAt = emu.now + entry.duration
        while not entry.cancelled do
            if not data.useWhileDead and player.health <= 0 then entry.cancelled = 'mort' break end
            if emu.now >= endAt - 1e-9 then break end
            env.Wait(0)
        end
        ui.progress = nil
        entry.finished, entry.endedAt = not entry.cancelled, emu.now
        return entry.finished
    end
    function lib.progressBar(data) return progress('bar', data) end
    function lib.progressCircle(data) return progress('circle', data) end
    function lib.progressActive() return ui.progress ~= nil end
    function lib.cancelProgress() return emu:_cancelProgress(player, false) end

    -- Menu contextuel : registerContext / showContext ; le test choisit avec p:selectMenu(index ou titre)
    function lib.registerContext(context)
        local list = context.id and { context } or context
        for _, c in ipairs(list) do ui.contexts[c.id] = { def = c, env = env, resource = resource } end
    end
    function lib.showContext(id)
        if not ui.contexts[id] then error('No context menu of such id found.', 2) end
        ui.context = id
        ui.contextLog[#ui.contextLog + 1] = { t = emu.now, id = id }
    end
    function lib.hideContext(onExit)
        local c = ui.context and ui.contexts[ui.context]
        ui.context = nil
        if onExit and c and c.def.onExit then c.def.onExit() end
    end
    function lib.getOpenContextMenu() return ui.context end

    -- Dialogues : bloquent le fil jusqu'à p:answerInput(valeurs | nil) / p:answerAlert('confirm' | 'cancel')
    function lib.inputDialog(heading, rows, options)
        if ui.input then return nil end
        local norm = {}
        for i, row in ipairs(rows) do norm[i] = type(row) == 'string' and { type = 'input', label = row } or row end
        return emu:awaitCallback(function(done)
            ui.input = { heading = heading, rows = norm, options = options, done = done, t = emu.now, resource = resource }
        end)
    end
    function lib.closeInputDialog()
        local dialog = ui.input
        if dialog then ui.input = nil dialog.done(nil) end
    end
    function lib.alertDialog(data)
        if ui.alert then return nil end
        return emu:awaitCallback(function(done) ui.alert = { data = data, done = done, t = emu.now, resource = resource } end)
    end
    function lib.closeAlertDialog(reason)
        local alert = ui.alert
        if alert then ui.alert = nil alert.done(reason) end
    end

    function lib.showTextUI(text, options) ui.textUI = { text = text, options = options, t = emu.now, resource = resource } end
    function lib.hideTextUI() ui.textUI = nil end
    function lib.isTextUIOpen() return ui.textUI ~= nil, ui.textUI and ui.textUI.text end
end

-- Aides de test (p:menu(), p:selectMenu(), …) : ce que ferait le joueur dans l'interface ox_lib

local function menuOptions(def)
    local list, opts = {}, def.options or {}
    if opts[1] ~= nil then
        for _, o in ipairs(opts) do list[#list + 1] = o end
    else
        local keys = {}
        for k in pairs(opts) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            local o = opts[k]
            if o.title == nil then o.title = k end
            list[#list + 1] = o
        end
    end
    return list
end

function Emu:_openMenu(p)
    local c = p.ui.context and p.ui.contexts[p.ui.context]
    if not c then return nil end
    return { id = c.def.id, title = c.def.title, menu = c.def.menu, options = menuOptions(c.def) }
end

-- Choisit une option (index ou titre) : sous-menu (menu), sinon onSelect(args), event, serverEvent puis fermeture.
-- Renvoie true, ou false + raison (no_menu, no_option, disabled, no_action)
function Emu:_selectMenu(p, which)
    local c = p.ui.context and p.ui.contexts[p.ui.context]
    if not c then return false, 'no_menu' end
    local list = menuOptions(c.def)
    local o = type(which) == 'number' and list[which] or nil
    if not o then for _, x in ipairs(list) do if x.title == which then o = x break end end end
    if not o then return false, 'no_option' end
    if o.disabled or o.readOnly then return false, 'disabled' end
    if o.menu then
        if not p.ui.contexts[o.menu] then return false, 'no_menu' end
        p.ui.context = o.menu
        p.ui.contextLog[#p.ui.contextLog + 1] = { t = self.now, id = o.menu }
        return true
    end
    if not (o.onSelect or o.event or o.serverEvent) then return false, 'no_action' end
    p.ui.context = nil
    local env = c.env
    self:_spawn(p.side, c.resource, function()
        if o.onSelect then o.onSelect(o.args) end
        if o.event then env.TriggerEvent(o.event, o.args) end
        if o.serverEvent then env.TriggerServerEvent(o.serverEvent, o.args) end
    end, true)
    return true
end

-- Échap : ferme le menu et appelle onExit
function Emu:_closeMenu(p)
    local c = p.ui.context and p.ui.contexts[p.ui.context]
    if not c then return false end
    p.ui.context = nil
    if c.def.onExit then self:_spawn(p.side, c.resource, c.def.onExit, true) end
    return true
end

-- Valeurs par index de ligne ou par libellé ; nil = annuler. Contrôle required, min et max comme l'interface.
function Emu:_answerInput(p, values)
    local dialog = p.ui.input
    if not dialog then return false, 'no_dialog' end
    if values == nil then
        p.ui.input = nil
        dialog.done(nil)
        return true
    end
    local out = {}
    for i, row in ipairs(dialog.rows) do
        local v = values[i]
        if v == nil and row.label ~= nil then v = values[row.label] end
        if v == nil then v = row.default end
        if row.type == 'checkbox' then
            if v == nil then v = row.checked == true end
        elseif (row.type == 'number' or row.type == 'slider') and v ~= nil then
            v = tonumber(v)
            if v and ((row.min and v < row.min) or (row.max and v > row.max)) then
                return false, ('hors limites : %s'):format(row.label or i)
            end
        end
        if row.required and (v == nil or v == '') then return false, ('champ requis : %s'):format(row.label or i) end
        out[i] = v
    end
    p.ui.input = nil
    dialog.done(out)
    return true
end

function Emu:_answerAlert(p, answer)
    local alert = p.ui.alert
    if not alert then return false, 'no_dialog' end
    answer = answer or 'confirm'
    if answer == 'cancel' and not alert.data.cancel then return false, 'no_cancel' end
    p.ui.alert = nil
    alert.done(answer)
    return true
end

-- byPlayer = touche d'annulation du joueur : seulement si canCancel
function Emu:_cancelProgress(p, byPlayer)
    local pr = p.ui.progress
    if not pr or (byPlayer and not pr.canCancel) then return false end
    pr.cancelled = byPlayer and 'joueur' or 'script'
    return true
end

return Emu
