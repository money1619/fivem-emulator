Config = { Locale = 'fr' }
/* commentaire C
   sur deux lignes */
local vide = nil
local plein = { a = { b = 7 } }
Resultats = {
    nav = { plein?.a?.b, vide?.a, vide?.a?.b, plein?['a'].b, ("?.") },
    calc = lib.require('modules.calc').somme(2, 3),
    donnees = lib.load('modules.donnees').prix,
    memeModule = require('modules.calc') == lib.require('modules.calc'),
    charge = load('return (nil)?.x == nil /* c */ and 5 or 0')(),
    outils = Outils.double(4),
    texte = _U('titre'), format = _('bonjour', 'Max'),
    dep = lib.checkDependency('lib_partagee'), absente = lib.checkDependency('ND_Core'),
    chemin = GetResourcePath(GetCurrentResourceName()) ~= nil,
}
SetResourceKvpInt('compteur', 3)
SetResourceKvp('nom', 'aeom')
Resultats.kvpInt, Resultats.kvpTexte, Resultats.kvpAbsent = GetResourceKvpInt('compteur'), GetResourceKvpString('nom'), GetResourceKvpInt('rien')
local h = StartFindKvp('co')
Resultats.kvpTrouve = FindKvp(h)
EndFindKvp(h)
Ticks = 0
local id = SetInterval(function() Ticks = Ticks + 1 end, 100)
SetTimeout(550, function() ClearInterval(id) end)
PerformHttpRequest('https://exemple.invalid', function(code) Resultats.http = code end)
Classe = lib.class('Compteur')
function Classe:constructor(n) self.n = n end
Resultats.classe = Classe:new(9).n
