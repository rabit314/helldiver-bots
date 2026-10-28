-- Pure stratagem policies, budgets, geometry and demand. No engine writes.
local P={revision='0.21.0',allowance=2,policies={}}
local function add(names,kind,role,enabled,reason)
 for name in names:gmatch('%S+') do P.policies['stratagem_'..name]={kind=kind,role=role,enabled=enabled,reason=reason} end
end
add('resupply','supply','ammo',true)
add('machinegun machinegun_oneuse lasercannon 20mm_cannon grenadelauncher flamethrower chemthrower recoilless law missile_launcher','supply','weapon',true)
add('mortar','supply','weapon',false,'mortar aiming and firing contract requires live verification')
add('drone_heal_backpack projected_shield shield_generator_pack','supply','backpack',true)
add('drone_defensive_backpack','supply','backpack',false,'native drone firing does not enforce protected-body corridors')
add('ammo_backpack','supply','backpack',false,'native teammate distribution workflow is not verified')
add('jumppack','supply','backpack',false,'checked autonomous jump landing is not verified')
add('repairtool','supply','weapon',false,'dedicated friendly repair targeting is not verified')
add('satchelcharge','supply','weapon',false,'placement and remote detonation are not verified')
add('exosuit exosuit_2 exosuit_3','supply','exo',true)
add('tankdestroyer','supply','tank',true)
add('bike apc apc_cannon','supply','tank',true)
add('airstrike dive_bomb','offensive','strike',true)
add('strafingrun strafingrun_heavy close_air_support','offensive','strike',false,'native firing corridor and complete attack sequence require verification')
add('missile_barrage artillery precision_artillery orbital_strike','offensive','strike',false,'complete salvo and scatter envelope requires verification')
add('missile_strike railcannon_strike','offensive','strike',false,'native alternative-target safety requires verification')
add('napalmstrike staticfield','offensive','field',false,'persistent effect and protected-route interaction require verification')
add('uav_drone','defensive','recon',false,'native revealed information and useful reconnaissance demand require verification')
add('distractor','defensive','lure',false,'native attraction and safe withdrawal corridor require verification')
add('mannable_turret','defensive','emplacement',true)
add('turret turret_railcannon turret_grenadelauncher','defensive','turret',false,'native autonomous firing cannot yet protect the main body reliably')
add('tesla_tower','defensive','field',false,'effect propagation envelope requires verification')
add('minedrop minedrop_stun barricade','defensive','denial',false,'persistent friendly route and escort clearance requires verification')
add('artillery_smoke','defensive','smoke',false,'native perception benefit requires verification')
add('reinforce','special','reinforce',false,'native Reinforce is unavailable in the supported one-human mission')
add('emergency_beacon','special','sos',false,'online SOS is outside the supported solo companion workflow')
add('hellbomb','special','objective',false,'autonomous objective selection and safe arming require verification; F8 remains available')
add('metaldetector','special','objective',false,'native detector mission workflow requires verification')
function P.finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
function P.point(v)
 if v and P.finite(v.x) and P.finite(v.y) and P.finite(v.z or 0) then return {x=v.x,y=v.y,z=v.z or 0} end
end
function P.distance(a,b)
 local x,y=a.x-b.x,a.y-b.y;return math.sqrt(x*x+y*y)
end
function P.direction(a,b)
 local d=P.distance(a,b);if d<.00001 then return {x=0,y=1,z=0},0 end
 return {x=(b.x-a.x)/d,y=(b.y-a.y)/d,z=0},d
end
function P.new_ledger()return {bodies=setmetatable({}, {__mode='k'}),sequence=0} end
function P.body(ledger,u)
 local b=ledger.bodies[u];if not b then b={entries={}};ledger.bodies[u]=b end;return b
end
function P.remaining(ledger,u,id)
 local b=ledger.bodies[u];local e=b and b.entries[id]
 return e and math.max(0,P.allowance-e.spent-e.reserved) or P.allowance
end
function P.reserve(ledger,u,id)
 if P.remaining(ledger,u,id)<=0 then return nil,'autonomous_allowance_exhausted' end
 local b=P.body(ledger,u);local e=b.entries[id] or {spent=0,reserved=0};b.entries[id]=e
 ledger.sequence=ledger.sequence+1;e.reserved=e.reserved+1
 return {serial=ledger.sequence,unit=u,id=id,entry=e,state='reserved'}
end
function P.commit(t)
 if not t or t.state~='reserved' then return false end
 t.entry.reserved=t.entry.reserved-1;t.entry.spent=t.entry.spent+1;t.state='spent';return true
end
function P.refund(t)
 if not t or t.state~='reserved' then return false end
 t.entry.reserved=t.entry.reserved-1;t.state='cancelled';return true
end
-- Native modified settings accept a unit path and the exact inventory upgrade.
function P.envelope(info,settings)
 if not info or not settings then return nil,'settings_unavailable' end
 if info.stratagem_type~='offensive' then
  local v=settings.vehicle_info or {};local r=tonumber(v.collision_radius or v.radius)
  return {radius=math.max(4.5,r and r+2 or 0),duration=6,kind='delivery',support=true}
 end
 local a,e=settings.airstrike_info,settings.explosive_info
 if not a or not e or not P.finite(e.blast_radius) or not P.finite(a.bomb_area_length)
  or not P.finite(a.num_bombs) or not P.finite(a.time_until_bombs) then return nil,'attack_geometry_unavailable' end
 if e.on_explode_unit_path or e.on_explode_spawn_unit_path then return nil,'secondary_effect_unverified' end
 local offset=math.max(math.abs(a.bomb_position_offset_min or 0),math.abs(a.bomb_position_offset_max or 0))
 -- A disk enclosing the entire oriented bomb line is conservative under rotation,
 -- scatter and an interruption. It is not the old guessed eight-metre circle.
 local radius=math.abs(a.bomb_area_length)+offset+e.blast_radius+2
 local finish=a.time_until_bombs+math.max(0,a.num_bombs-1)*math.max(a.time_between_bombs_min or 0,a.time_between_bombs_max or 0)
 return {radius=radius,duration=math.max(15,finish+2),kind='strike',support=false,
  length=a.bomb_area_length,blast=e.blast_radius,first=a.time_until_bombs}
end
function P.intersects(zone,actor,horizon,allies)
 if not actor or not actor.position or (not allies and not actor.protected) then return false end
 if math.abs((zone.position.z or 0)-(actor.position.z or 0))>3+(actor.height or 0) then return false end
 local p=actor.position;local v=actor.velocity or {};local dt=math.max(0,math.min(horizon or 0,zone.prediction or math.huge))
 local q={x=p.x+(v.x or 0)*dt,y=p.y+(v.y or 0)*dt,z=p.z}
 local dx,dy=q.x-p.x,q.y-p.y
 local t=math.max(0,math.min(1,((zone.position.x-p.x)*dx+(zone.position.y-p.y)*dy)/math.max(.00001,dx*dx+dy*dy)))
 local closest={x=p.x+dx*t,y=p.y+dy*t}
 local margin=(actor.radius or .65)+(actor.uncertainty or .5)+math.min(actor.max_uncertainty or 3,dt*(actor.uncertainty_growth or .15))
 return P.distance(zone.position,closest)<=zone.radius+margin
end
-- A mobile controlled player can leave the outer footprint during native warning.
-- Four metres/second and .75 seconds to react are a policy estimate, not a route guarantee.
function P.can_evade(zone,a)
 if zone.a or zone.persistent then return false end
 if zone.support or not a.can_dodge or not P.finite(zone.warning) or zone.warning<1.5 then return false end
 local distance=P.distance(zone.position,a.position);local body=(a.radius or .8)+.25
 return distance>(zone.blast or zone.radius)+body and zone.radius+body-distance<=(zone.warning-.75)*4
end
function P.safe(zone,actors,horizon)
 local casualties,dodging=0,0
 for _,a in ipairs(actors or {}) do
  if P.intersects(zone,a,horizon,zone.support) then
   if P.can_evade(zone,a) then dodging=dodging+1
   else return false,a.protected and 'protected_actor' or 'friendly_delivery_overlap' end
  end
  if not zone.support and not a.protected and P.intersects(zone,a,horizon,true) then casualties=casualties+1 end
 end
 return true,nil,casualties,dodging
end
function P.ammunition(a,profile)
 a=a or {};profile=profile or {}
 if a.heat~=nil or profile.kind=='beam' or profile.kind=='arc' then return nil,'heat_weapon' end
 local cap=tonumber(a.magazine_capacity or (a.weapon_info or {}).magazine_capacity)
 local mags,rounds=tonumber(a.num_mags),tonumber(a.rounds)
 if not rounds or not mags or rounds<0 or mags<0 then return nil,'unknown_ammunition' end
 if mags>0 and not cap then return nil,'unknown_magazine_capacity' end
 return rounds+mags*(cap or 0)
end
function P.demand(ammo,rate,horizon,pressure)
 if ammo==nil then return 0 end
 if ammo<=0 then return 1 end
 if not rate or rate<=0 or not pressure or pressure<=0 then return 0 end
 local required=rate*math.max(0,horizon or 0)*(1+math.min(1,pressure/8)*.25)
 return math.max(0,math.min(1,(required-ammo)/math.max(1,required)))
end
function P.effectiveness(weapon,health)
 local wi=weapon and (weapon.weapon_info or weapon) or {};local hi=health or {}
 local penetration=tonumber(wi.armorpiercing or (weapon or {}).armorpiercing)
 local armor=tonumber(hi.armor_min or (hi.health_info or {}).armor_min)
 if penetration and armor and penetration<armor then return 0,'known_armor_gap' end
 if penetration and armor then return 1,'penetration_possible' end
 return .5,'unknown_armor'
end
function P.utility(benefit,casualties,remaining,travel,exposure)
 local scarcity=remaining==1 and 1.35 or 1
 return benefit/scarcity-(casualties or 0)*1.5-(travel or 0)*.08-(exposure or 0)
end
-- Native ThrowableComponent uses sqrt(distance*18) at a 45-degree direction.
-- Solve for hand height rather than assuming the charged distance is the landing.
function P.throw_range(power,height,minimum,maximum,multiplier)
 if not P.finite(power) or not P.finite(height) or not P.finite(minimum) or not P.finite(maximum)
  or maximum<minimum or not P.finite(multiplier) or multiplier<=0 then return nil end
 local horizontal=math.sqrt(math.max(0,minimum+power*multiplier*(maximum-minimum))*9)
 local discriminant=horizontal*horizontal+36*height
 if discriminant<0 then return nil end
 return horizontal*(horizontal+math.sqrt(discriminant))/18
end
function P.throw_power(distance,height,minimum,maximum,multiplier)
 if not P.finite(distance) or distance<=0 or not P.finite(height) or distance+height<=0
  or not P.throw_range(1,height,minimum,maximum,multiplier) then return nil,'invalid_geometry' end
 local span=(maximum-minimum)*multiplier
 if span==0 then
  local range=P.throw_range(0,height,minimum,maximum,multiplier)
  if range and math.abs(range-distance)<=.15 then return 0 end
  return nil,'fixed_range_mismatch'
 end
 local power=(distance*distance/(distance+height)-minimum)/span
 if power<0 or power>1 then return nil,'outside_native_range' end
 return power
end
function P.fit_throw(distance,height,minimum,maximum,multiplier)
 local lo=P.throw_range(0,height,minimum,maximum,multiplier) or 0
 local hi=P.throw_range(1,height,minimum,maximum,multiplier)
 if not hi or hi<=0 then return end
 local margin=math.min(.6,(hi-lo)/4)
 return math.max(lo+margin,math.min(distance,hi-margin))
end
return P
