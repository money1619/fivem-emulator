-- mocks/oxmysql.lua — oxmysql 2.12.0 simulé : même API Lua que lib/MySQL.lua et mêmes exports, mais la base
-- de données est remplacée par des réponses écrites dans le test.
--
--   local db = require('mocks.oxmysql')(emu, { latency = 5 })
--   db:on('^SELECT money FROM users', function(query, params) return { { money = 500 } } end)
--   db:on('^UPDATE users', { affectedRows = 1 })
--
-- Une réponse (fonction ou valeur fixe) donne le résultat brut de MySQL :
--   SELECT → tableau de lignes ; INSERT / UPDATE / DELETE → { insertId = n, affectedRows = n }.
-- Le mock le met en forme comme oxmysql : query → lignes, single → première ligne, scalar → première colonne,
-- insert → insertId, update → affectedRows, prepare → valeur / ligne / lignes selon le nombre de résultats,
-- transaction → true ou false. Une erreur levée dans une réponse simule une erreur SQL.
-- La réponse enregistrée en dernier est essayée en premier ; une requête sans réponse est une erreur (emu.errors).
-- Les messages d'erreur imités d'oxmysql restent en anglais, comme dans la console FiveM.
local unpack = table.unpack

return function(emu, opts)
    opts = opts or {}
    local db = { log = {}, handlers = {}, latency = opts.latency or 0, unhandled = 0 }
    emu.mocks.oxmysql = db

    -- motif : motif Lua cherché dans la requête, ou fonction(requête, paramètres) → booléen
    function db:on(match, result)
        table.insert(self.handlers, { match = match, result = result })
        return self
    end

    function db:clear()
        self.handlers, self.log, self.unhandled = {}, {}, 0
    end

    -- Requêtes journalisées dont le texte contient le motif Lua (toutes si motif = nil)
    function db:queries(pattern)
        local r = {}
        for _, e in ipairs(self.log) do if not pattern or e.query:find(pattern) then r[#r + 1] = e end end
        return r
    end

    local function findHandler(query, params)
        for i = #db.handlers, 1, -1 do
            local h = db.handlers[i]
            if type(h.match) == 'function' then
                if h.match(query, params) then return h end
            elseif query:find(h.match) then
                return h
            end
        end
    end

    -- Exécute une requête : true, résultat brut ou false, message d'erreur SQL
    local function execute(resource, method, query, params)
        local entry = { t = emu.now, resource = resource, method = method, query = query, params = params }
        db.log[#db.log + 1] = entry
        local h = findHandler(query, params)
        if not h then
            db.unhandled = db.unhandled + 1
            entry.error = 'aucune réponse prévue'
            emu:_error(emu.server, ('oxmysql : aucune réponse prévue pour la requête « %s » de %s (paramètres %s) : ajoutez db:on(...)')
                :format(query, tostring(resource), emu.json.encode(params or {})))
            return false, 'no handler for this query (fivem_emu)'
        end
        local result = h.result
        if type(result) == 'function' then
            local ok, r = pcall(result, query, params, entry)
            if not ok then entry.error = tostring(r) return false, tostring(r) end
            result = r
        end
        -- comme une vraie base : le script reçoit une copie, jamais la table du test
        result = result ~= nil and emu.netCopy(result) or nil
        entry.result = result
        return true, result
    end

    local function isArray(t)
        if type(t) ~= 'table' then return false end
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        return n == #t
    end

    -- Premier paramètre fixe de parseArguments : trop de paramètres pour les « ? » de la requête
    local function checkArguments(query, params)
        if type(query) ~= 'string' then error(("Expected query to be a string but received %s instead."):format(type(query)), 0) end
        if type(params) ~= 'table' or not isArray(params) then return end
        local placeholders = 0
        for i = 1, #query do
            if query:sub(i, i) == '?' and query:sub(i + 1, i + 1) ~= '?' then placeholders = placeholders + 1 end
        end
        if #params > placeholders then
            error(('Expected %d parameters, but received %d.'):format(placeholders, #params), 0)
        end
    end

    local function firstColumn(row)
        if type(row) ~= 'table' then return nil end
        local k = next(row)
        if k == nil then return nil end
        if next(row, k) ~= nil then
            -- une ligne Lua n'a pas d'ordre de colonnes : on prend la première par ordre alphabétique
            local keys = {}
            for key in pairs(row) do keys[#keys + 1] = tostring(key) end
            table.sort(keys)
            emu:_warn(('oxmysql : scalar sur une ligne à plusieurs colonnes (%s), « %s » choisie ; renvoyez une seule colonne')
                :format(table.concat(keys, ', '), keys[1]))
            return row[keys[1]]
        end
        return row[k]
    end

    -- parseResponse d'oxmysql
    local function parseResponse(kind, result)
        local t = type(result) == 'table'
        if kind == 'insert' then return t and result.insertId or nil end
        if kind == 'update' then return t and result.affectedRows or nil end
        if kind == 'single' then return t and result[1] or nil end
        if kind == 'scalar' then return firstColumn(t and result[1]) end
        return result
    end

    -- Les callbacks des scripts s'exécutent dans un fil de la ressource appelante
    local function callback(resource, cb, ...)
        local args = table.pack(...)
        emu:_spawn(emu.server, resource, function() cb(unpack(args, 1, args.n)) end, true)
    end

    local function later(steps, fn)
        emu:at(emu.now + db.latency * math.max(steps, 1), fn)
    end

    -- logError : avec .await l'erreur remonte au script, sinon elle s'affiche dans la console
    local function fail(resource, cb, isPromise, err, query, params)
        local output = ('%s was unable to execute a query!%s\n%s'):format(tostring(resource), query and ('\nQuery: ' .. tostring(query)) or '', err)
        emu:_dispatch(emu.server, 'oxmysql:error', table.pack({ query = query, parameters = params, message = err, resource = resource }), '', false, 'oxmysql')
        if cb and isPromise then
            callback(resource, cb, nil, output)
            return
        end
        emu:_error(emu.server, 'oxmysql : ' .. output)
    end

    local function setCallback(params, cb)
        if type(cb) == 'function' then return cb end
        if type(params) == 'function' then return params end
    end

    -- query, single, scalar, insert, update (rawQuery)
    local function rawQuery(kind, method)
        return function(query, params, cb, resource, isPromise)
            resource = resource or emu:callerResource(emu.server)
            cb = setCallback(params, cb)
            if type(params) == 'function' then params = nil end
            local ok, err = pcall(checkArguments, query, params)
            if not ok then return fail(resource, cb, isPromise, err, query, params) end
            later(1, function()
                local success, result = execute(resource, method, query, params)
                if not success then return fail(resource, cb, isPromise, result, query, params) end
                if cb then callback(resource, cb, parseResponse(kind, result)) end
            end)
        end
    end

    -- Type d'une requête pour prepare : premier mot exact, en majuscules (comme executeType d'oxmysql)
    local function executeType(query)
        local word = query:match('^([^ ]*) ')
        if word == 'INSERT' then return 'insert' end
        if word == 'UPDATE' or word == 'DELETE' then return 'update' end
        return nil
    end

    -- prepare (unpack = true) et rawExecute (unpack = false) : un jeu de paramètres, ou un tableau de jeux
    local function rawExecute(unpackResult, method)
        return function(query, params, cb, resource, isPromise)
            resource = resource or emu:callerResource(emu.server)
            cb = setCallback(params, cb)
            if type(params) == 'function' then params = nil end
            if type(query) ~= 'string' then
                return fail(resource, cb, isPromise, ('Expected query to be a string but received %s instead.'):format(type(query)), query, params)
            end
            local kind = executeType(query)
            local sets
            if type(params) ~= 'table' or next(params) == nil then
                sets = { params or {} }
            else
                local allTables = true
                for _, v in pairs(params) do if type(v) ~= 'table' then allTables = false break end end
                sets = allTables and params or { params }
            end
            later(#sets, function()
                local response = {}
                for _, values in ipairs(sets) do
                    local success, result = execute(resource, method, query, values)
                    if not success then return fail(resource, cb, isPromise, result, query, params) end
                    if type(result) == 'table' and isArray(result) and #result > 1 then
                        for _, row in ipairs(result) do response[#response + 1] = unpackResult and parseResponse(kind, row) or row end
                    else
                        response[#response + 1] = unpackResult and parseResponse(kind, result) or result
                    end
                end
                if not cb then return end
                if #response == 1 then
                    if unpackResult and kind == nil then
                        local row = type(response[1]) == 'table' and response[1][1] or nil
                        local k = type(row) == 'table' and next(row)
                        if k ~= nil and k ~= false and next(row, k) == nil then callback(resource, cb, row[k]) else callback(resource, cb, row) end
                    else
                        callback(resource, cb, response[1])
                    end
                else
                    callback(resource, cb, response)
                end
            end)
        end
    end

    -- transaction : tableau de requêtes (chaînes + paramètres communs, { query =, parameters/values = } ou { requête, paramètres })
    local function transaction(queries, params, cb, resource, isPromise)
        resource = resource or emu:callerResource(emu.server)
        cb = setCallback(params, cb)
        if type(params) ~= 'table' then params = nil end
        local list = {}
        local ok, err = pcall(function()
            if type(queries) ~= 'table' or not isArray(queries) then
                error(("Transaction queries must be array, received '%s'."):format(type(queries)), 0)
            end
            if type(queries[1]) == 'table' and queries[1].query == nil then
                for _, q in ipairs(queries) do
                    if type(q[2]) ~= 'table' then error(("Transaction parameters must be array or object, received '%s'."):format(type(q[2])), 0) end
                    checkArguments(q[1], q[2])
                    list[#list + 1] = { query = q[1], params = q[2] }
                end
            else
                for _, q in ipairs(queries) do
                    local query = type(q) == 'table' and q.query or q
                    local p = type(q) == 'table' and (q.parameters or q.values) or params
                    checkArguments(query, p)
                    list[#list + 1] = { query = query, params = p }
                end
            end
        end)
        if not ok then return fail(resource, cb, isPromise, err) end
        later(#list, function()
            local response = true
            for _, q in ipairs(list) do
                local success, e = execute(resource, 'transaction', q.query, q.params)
                if not success then
                    response = false
                    local msg = ('%s was unable to complete a transaction!\n%s\n%s'):format(tostring(resource), q.query, e)
                    emu:_error(emu.server, 'oxmysql : ' .. msg)
                    emu:_dispatch(emu.server, 'oxmysql:transaction-error', table.pack({ query = q.query, parameters = params, message = e, resource = resource }), '', false, 'oxmysql')
                    break
                end
            end
            if cb then callback(resource, cb, response) end
        end)
    end

    local core = {
        query = rawQuery(nil, 'query'),
        single = rawQuery('single', 'single'),
        scalar = rawQuery('scalar', 'scalar'),
        update = rawQuery('update', 'update'),
        insert = rawQuery('insert', 'insert'),
        transaction = transaction,
        prepare = rawExecute(true, 'prepare'),
        rawExecute = rawExecute(false, 'rawExecute'),
        isReady = function() return true end,
        awaitConnection = function() return true end,
        store = function(query, cb) cb(query) end,
    }
    core.execute = core.query
    core.fetch = core.query
    db.core = core

    -- Ressource « oxmysql » : exports.oxmysql:query(...) etc.
    emu:defineResource('oxmysql', {
        server = function(env)
            for name, fn in pairs(core) do env.exports(name, fn) end
        end,
    })

    -- Inclusion '@oxmysql/lib/MySQL.lua' : copie du comportement de lib/MySQL.lua
    emu:provide('@oxmysql/lib/MySQL.lua', function(env, side)
        if side.kind ~= 'server' then return end
        local resourceName = env.GetCurrentResourceName()
        local queryStore = {}

        local function await(fn, query, parameters)
            local result, err = emu:awaitCallback(function(done)
                fn(query, parameters, function(r, e) done(r, e) end, resourceName, true)
            end)
            if err then error(err, 3) end
            return result
        end

        local function safeArgs(query, parameters, cb, isTransaction)
            local queryType = type(query)
            if queryType == 'number' then
                query = queryStore[query]
                assert(query, "First argument received invalid query store reference")
            elseif isTransaction then
                if queryType ~= 'table' then
                    error(("First argument expected table, received '%s'"):format(query))
                end
            elseif queryType ~= 'string' then
                error(("First argument expected string, received '%s'"):format(query))
            end
            if parameters then
                local paramType = type(parameters)
                if paramType ~= 'table' and paramType ~= 'function' then
                    error(("Second argument expected table or function, received '%s'"):format(parameters))
                end
                if paramType == 'function' then
                    cb = parameters
                    parameters = nil
                end
            end
            if cb and parameters and type(cb) ~= 'function' then
                error(("Third argument expected function, received '%s'"):format(cb))
            end
            return query, parameters, cb
        end

        local MySQL = setmetatable({}, {
            __index = function(_, index)
                return function(...)
                    local fn = core[index]
                    if not fn then error(('export introuvable : oxmysql.%s'):format(index), 2) end
                    return fn(...)
                end
            end,
        })

        for _, method in pairs({ 'scalar', 'single', 'query', 'insert', 'update', 'prepare', 'transaction', 'rawExecute' }) do
            MySQL[method] = setmetatable({
                method = method,
                await = function(query, parameters)
                    query, parameters = safeArgs(query, parameters, nil, method == 'transaction')
                    return await(core[method], query, parameters)
                end,
            }, {
                __call = function(_, query, parameters, cb)
                    query, parameters, cb = safeArgs(query, parameters, cb, method == 'transaction')
                    return core[method](query, parameters, cb, resourceName, false)
                end,
            })
        end

        local alias = { fetchAll = 'query', fetchScalar = 'scalar', fetchSingle = 'single', insert = 'insert',
                        execute = 'update', transaction = 'transaction', prepare = 'prepare' }
        local function addStore(query, cb)
            assert(type(query) == 'string', 'The SQL Query must be a string')
            local storeN = #queryStore + 1
            queryStore[storeN] = query
            return cb and cb(storeN) or storeN
        end
        local function aliasTable(sync)
            return setmetatable({ store = addStore }, { __index = function(self, key)
                local name = alias[key]
                if name then
                    local fn = sync and MySQL[name].await or MySQL[name]
                    rawset(self, key, fn)
                    return fn
                end
            end })
        end
        MySQL.Sync = aliasTable(true)
        MySQL.Async = aliasTable(false)

        local function onReady(cb)
            while env.GetResourceState('oxmysql') ~= 'started' do env.Wait(50) end
            return cb and cb() or true
        end
        MySQL.ready = setmetatable({ await = onReady }, {
            __call = function(_, cb) env.Citizen.CreateThreadNow(function() onReady(cb) end) end,
        })

        env.MySQL = MySQL
    end)

    table.insert(emu.reporters, function(add)
        add(('oxmysql (simulé) : %d requête(s), %d sans réponse prévue'):format(#db.log, db.unhandled))
    end)

    if opts.autostart ~= false then emu:start('oxmysql') end
    return db
end
