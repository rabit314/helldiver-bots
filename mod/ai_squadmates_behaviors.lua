-- Native interaction/weapon adapters and shared autonomous job reservations.
local B={revision='0.8.0'}
local function live(u) return u~=nil and Unit.alive(u) end
local function state(u,n,master)
 if not live(u) then return end
 if master then
  if EntityAux.has_component_master(u,n) then return EntityAux.state_master(u,n) end
 elseif EntityAux.has_component(u,n) then return EntityAux.state(u,n) end
end
local function pos(u,node)
 if not live(u) then return end
 local p=Unit.world_position(u,node or 0);return {x=p.x,y=p.y,z=p.z}
end
local function dist(a,b) local x,y=a.x-b.x,a.y-b.y;return math.sqrt(x*x+y*y) end
local function entities(s,n,scan,view)
 local manager=s.entity_manager;local registry=manager.component_name_to_contexts
 -- The native getter indexes registry[n].master; absent types throw before `or {}`.
 if registry and not registry[n] then
  if scan then scan.unregistered=scan.unregistered or {};scan.unregistered[#scan.unregistered+1]=n end
  return {}
 end
 if view=='slave' then return manager:get_slave_entities(n) or {} end
 return manager:get_master_entities(n) or {}
end
B.entities=entities
function B.blast_radius(u)
 local cfg=LuaSettingsManager and LuaSettingsManager:get_settings_by_unit(u) or {}
 local a=state(u,'explosive',true) or state(u,'explosive') or {}
 local info=a.explosive_info or cfg.explosive_info or {}
 local radius=tonumber(info.blast_radius or info.radius or info.explosion_radius)
 if radius and radius>0 and radius<10000 then return radius end
end
function B.weapon(u)
 if not live(u) or not EntityAux.has_interface(u,'weapon') then return {},{kind='none',range=14} end
 local a=EntityAux.state_master_interface(u,'weapon') or {}
 local kind=state(u,'arcweapon',true) and 'arc' or (state(u,'beamweapon',true) and 'beam'
  or (state(u,'launcher',true) and 'launcher' or (state(u,'flameweapon',true) and 'flame' or 'firearm')))
 local info=a.weapon_info or {};local explosive=a.explosive_info
 local radius=explosive and (explosive.blast_radius or explosive.radius or explosive.explosion_radius) or 0
 if type(radius)~='number' then radius=0 end
 return a,{kind=kind,range=math.min(24,tonumber(a.max_range_from_owner or a.range or info.range) or (kind=='flame' and 7 or 14)),
  splash=math.max(radius,kind=='launcher' and 4 or 0),semi=a.semi_automatic and not a.fully_automatic,
  charge=a.fire_on_release and (a.max_charge_time or info.max_charge_time),round_delay=a.round_delay or .2}
end
function B.dry(a)
 return a.heat==nil and type(a.rounds)=='number' and a.rounds<=0
  and type(a.num_mags)=='number' and a.num_mags<=0 and not a.is_reloading
end
function B.trigger(a,profile,m,dt,permitted)
 if not permitted then m.trigger_time=0;m.trigger_on=false;return false,false end
 if profile.kind=='arc' then
  if (a.heat or 0)>=math.max(.65,(a.min_heat_to_fire or .2)+.08) and a.charging then
   return true,false -- Keep the aiming/fire state; release only the native charge trigger.
  end
  if (a.fire_timer or 0)>0 then return true,false end
  return true,true
 end
 if profile.kind=='beam' then
  local heat=a.heat or 0
  if heat>=.85 then m.cooling=true elseif heat<=.25 then m.cooling=false end
  return not m.cooling,not m.cooling
 end
 m.trigger_time=(m.trigger_time or 0)+dt
 if profile.charge and profile.charge>0 then
  if m.trigger_time>=profile.charge+.1 then m.trigger_time=0;return true,false end
  return true,true
 end
 if profile.semi then
  local on=m.trigger_time>=math.max(.12,profile.round_delay or .2)
  if on then m.trigger_time=0 end
  return on,on
 end
 return true,true
end
function B.new() return {jobs={},claims={},deferred={},failed={},next_scan=0,hazards={},lanes={},escorts={}} end
function B.release(ctx,b,reason,now,emit)
 local job=b.job
 if not job then return end
 if ctx.claims[job.key]==b then ctx.claims[job.key]=nil end
 b.job=nil
 if reason=='timeout' or reason=='blocked' then
  if job.kind=='revive' then
   ctx.failed[job.key]=ctx.failed[job.key] or {};ctx.failed[job.key][b.id]=(now or 0)+8
  else ctx.deferred[job.key]=(now or 0)+8 end
 end
 if emit then emit('task_finished',{task=job.kind,result=reason},b.id) end
end
local function lane(ctx,u,source)
 local p=pos(u);if not p then return end
 local f=Quaternion.forward(Unit.world_rotation(u,source.node or 0))
 ctx.lanes[#ctx.lanes+1]={unit=u,position=p,direction={x=f.x,y=f.y},range=source.range or 22}
end
local function firing(u)
 local c=state(u,'character',true) or {};local inv=state(u,'inventory') or {}
 local a=live(inv.current_weapon) and EntityAux.has_interface(inv.current_weapon,'weapon')
  and EntityAux.state_master_interface(inv.current_weapon,'weapon') or {}
 local input=c.input or {}
 return input.fire_auto or input.fire or a.firing_auto or a.firing_single
end
local function add_hazard(ctx,p,radius,kind,u)
 if p then ctx.hazards[#ctx.hazards+1]={position=p,radius=radius,kind=kind,unit=u} end
end
function B.scan(ctx,s,leader,lp,bots,now)
 if now<ctx.next_scan then return end
 ctx.next_scan=now+.25;ctx.jobs={};ctx.hazards={};ctx.lanes={};ctx.escorts={}
 for key,time in pairs(ctx.deferred) do if now>time then ctx.deferred[key]=nil end end
 for key,bots_failed in pairs(ctx.failed) do
  for id,expires in pairs(bots_failed) do if now>expires then bots_failed[id]=nil end end
  if not next(bots_failed) then ctx.failed[key]=nil end
 end
 local function job(u,component,kind,priority,actor,index,p)
  p=p or pos(u);if not p then return end
  local nearby=dist(lp,p)<=12
  if kind=='revive' and not nearby then
   for _,b in ipairs(bots) do
    local h=state(b.unit,'health')
    if b.active and h and not h.is_dead and not h.is_downed and dist(pos(b.unit),p)<=8 then nearby=true;break end
   end
  end
  if not nearby then return end
  local key=kind..':'..tostring(u)..':'..tostring(index or '')
  ctx.jobs[#ctx.jobs+1]={unit=u,component=component,kind=kind,priority=priority,key=key,position=p,actor=actor,index=index}
 end
 for _,pair in ipairs({{'research_sample_pickup','research',3},{'ammo_pickup','ammo',2}}) do
  for u in pairs(entities(s,pair[1])) do
   local a=state(u,pair[1]);if a and a.enabled then job(u,pair[1],pair[2],pair[3]) end
  end
 end
 local function downed(u)
  local h=state(u,'health')
  if h and h.is_downed and not h.is_dead then job(u,'interactable_character','revive',0) end
  if h and not h.is_dead and not h.is_downed then
   local inv=state(u,'inventory') or {};local pack=state(inv.backpack,'ammo_backpack')
   if pack and (pack.num_uses or 0)>0 and (pack.backpack_info or {}).self_service then job(u,'interactable_character','ammo',2) end
  end
 end
 downed(leader)
 for _,b in ipairs(bots) do
  downed(b.unit);local ok,shooting=pcall(firing,b.unit)
  if ok and shooting then lane(ctx,b.unit,{}) end
 end
 if firing(leader) then lane(ctx,leader,{}) end
 for u in pairs(entities(s,'turret')) do
  local a=state(u,'turret',true)
  if a and (a.is_firing or ((a.fire_cooldown or 0)>0 and live(a.target_unit))) then
   local p=pos(u);local t=live(a.target_unit) and pos(a.target_unit)
   if p and t then local d=dist(p,t);if d>.01 then
    ctx.lanes[#ctx.lanes+1]={unit=u,position=p,direction={x=(t.x-p.x)/d,y=(t.y-p.y)/d},range=d+2}
   end end
  end
 end
 local allies={};if leader then allies[leader]=true end;for _,b in ipairs(bots) do allies[b.unit]=true end
 for u in pairs(entities(s,'npc_escort')) do
  local a=state(u,'npc_escort',true);local h=state(u,'health')
  if a and h and not h.is_dead and not a.finished and not a.in_goal
    and a.following_unit and live(a.follow_unit) and allies[a.follow_unit] then
   local p=pos(u)
   if p and dist(lp,p)<=22 then ctx.escorts[#ctx.escorts+1]={key=tostring(u),unit=u,position=p} end
  end
 end
 for u in pairs(entities(s,'stationary_weapon')) do
  local a=state(u,'stationary_weapon',true)
  if a and allies[a.controller_unit] and EntityAux.has_interface(u,'weapon') then
   local w=EntityAux.state_master_interface(u,'weapon') or {}
   if w.firing_auto or w.firing_single then
    lane(ctx,u,{node=Unit.node(u,(a.stationary_info or {}).rotation_node or 'root')})
   end
  end
 end
 -- The first vehicle seat drives. Secondary seats may be on attached cannon units.
 local lc=state(leader,'character',true) or {};local vehicle=lc.current_seat_unit
 local vs=state(vehicle,'seat');local human_driving=vs and vs.seated_units and vs.seated_units[1]==leader
 if human_driving then
  for u in pairs(entities(s,'seat')) do
   local a=state(u,'seat');local stationary=state(u,'stationary_weapon',true)
   if a and a.enabled and (u==vehicle or (stationary and stationary.attached_to_unit==vehicle)) then
    for actor,index in pairs(a.actor_to_seat or {}) do
     local settings=SeatComponent.get_seat_settings(u,index)
     if (u~=vehicle or index~=1) and not (a.seated_units or {})[index] and settings and settings.enter_node then
      local node=Unit.node(u,settings.enter_node)
      job(u,'seat','seat',1,actor,index,pos(u,node))
     end
    end
   end
  end
 end
 for u in pairs(entities(s,'hellpod')) do
  local a=state(u,'hellpod',true)
  if a and (a.drop_time or 0)>0 then add_hazard(ctx,a.position or pos(u),4.5,'pod',u) end
 end
 for u in pairs(entities(s,'artillery')) do
  local a=state(u,'artillery',true)
  if a and (a.is_incoming or a.is_firing) then
   add_hazard(ctx,pos(u),((a.artillery_info or {}).diameter or 12)/2+2,'bombardment',u)
  end
 end
 for u in pairs(entities(s,'hellbomb')) do
  local a=state(u,'hellbomb',true)
  if a and a.is_armed and not a.has_exploded then add_hazard(ctx,pos(u),(B.blast_radius(u) or 25)+5,'hellbomb',u) end
 end
 for u in pairs(entities(s,'airstrike')) do
  local a=state(u,'airstrike',true)
  if a then add_hazard(ctx,pos(u),8,'airstrike',u) end
 end
 for u in pairs(entities(s,'targeted_strike')) do
  local a=state(u,'targeted_strike',true)
  if a then add_hazard(ctx,live(a.target_unit) and pos(a.target_unit) or pos(u),5,'strike',u) end
 end
 for u in pairs(entities(s,'mine')) do
  local a=state(u,'mine',true)
  if a and not a.has_exploded then add_hazard(ctx,a.position or pos(u),3,'mine',u) end
 end
 for u in pairs(entities(s,'spawn_area_effect')) do
  local a=state(u,'spawn_area_effect',true);local e=a and a.explosive_info or {}
  if a and a.field_active and (e.blast_radius or 0)>0 then
   add_hazard(ctx,pos(u),e.blast_radius+1,'area_effect',u)
  end
 end
end
function B.vehicle_distance(h,p)
 local a,z=h.position,h.future;local dx,dy=z.x-a.x,z.y-a.y
 local t=math.max(0,math.min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/math.max(.0001,dx*dx+dy*dy)))
 local center={x=a.x+dx*t,y=a.y+dy*t,z=a.z}
 return dist(p,center),center
end
local function vehicle_exempt(h,own)
 local m=rawget(_G,'HelldiversSquadAI');local b=m and m.units[own]
 return b and m.vehicles and m.vehicles.exempt(b,h)
end
function B.risk(ctx,p,own)
 local risk=0
 for _,h in ipairs(ctx.hazards) do
  if not h.height or math.abs((p.z or h.position.z)-h.position.z)<h.height then risk=risk+math.max(0,h.radius-dist(p,h.position)) end
 end
 for _,h in ipairs(ctx.vehicles or {}) do
  if not vehicle_exempt(h,own) and math.abs((p.z or h.position.z)-h.position.z)<3 then
   risk=risk+math.max(0,h.radius-B.vehicle_distance(h,p))
  end
 end
 return risk
end
function B.danger(ctx,p,own)
 local x,y=0,0;local danger
 for _,h in ipairs(ctx.vehicles or {}) do
  if not vehicle_exempt(h,own) and math.abs((p.z or h.position.z)-h.position.z)<3 then
   local d,center=B.vehicle_distance(h,p)
   if d<h.radius then
    local dx,dy=p.x-center.x,p.y-center.y
    if d<.01 then dx,dy,d=-(h.velocity.y or 0),h.velocity.x or 0,1
     if dx*dx+dy*dy<.01 then dx=1 end
    end
    x=x+dx/d*(h.radius-d+1);y=y+dy/d*(h.radius-d+1);danger='vehicle_crush'
   end
  end
 end
 for _,h in ipairs(ctx.hazards) do
  local d=dist(p,h.position)
  if d<h.radius and (not h.height or math.abs((p.z or h.position.z)-h.position.z)<h.height) then
   local dx,dy=p.x-h.position.x,p.y-h.position.y
   if d<.01 then dx,dy,d=1,0,1 end
   x=x+dx/d*(h.radius-d+1);y=y+dy/d*(h.radius-d+1);danger=h.kind
  end
 end
 if danger then local n=math.sqrt(x*x+y*y);if n<.01 then x,y,n=1,0,1 end;return {x=x/n,y=y/n},danger end
 for _,l in ipairs(ctx.lanes) do
  if l.unit~=own then
   local dx,dy=p.x-l.position.x,p.y-l.position.y;local d=l.direction;local n=math.sqrt(d.x*d.x+d.y*d.y)
   if n>.01 then
    local along=(dx*d.x+dy*d.y)/n;local across=(d.x*dy-d.y*dx)/n
    if along>.6 and along<l.range and math.abs(across)<.9 then
     local sign=across>=0 and 1 or -1
     return {x=-d.y/n*sign,y=d.x/n*sign},'friendly_fire'
    end
   end
  end
 end
end
function B.valid(job,b,leader)
 if not live(job.unit) then return false end
 local a=state(job.unit,job.component)
 if not a or not a.enabled then return false end
 if job.kind=='revive' then
  local h=state(job.unit,'health');if not h or not h.is_downed or h.is_dead then return false end
 elseif job.kind=='seat' then
  local lc=state(leader,'character',true) or {};local v=lc.current_seat_unit;local vs=state(v,'seat')
  local stationary=state(job.unit,'stationary_weapon',true)
  if not vs or not vs.seated_units or vs.seated_units[1]~=leader then return false end
  if job.unit~=v and not (stationary and stationary.attached_to_unit==v) then return false end
  if (a.seated_units or {})[job.index] then return false end
 end
 if a.can_interact then
  local actor=job.actor and Unit.actor(job.unit,job.actor) or nil
  if not a.can_interact(b.unit,actor) then return false end
 end
 return true
end
function B.assign(ctx,bots,leader,lp,now,emit,enemies)
 table.sort(ctx.jobs,function(a,b)return a.priority<b.priority end)
 local followers,routine=0,0;local threatened=false
 for _,b in ipairs(bots) do
  local h=state(b.unit,'health');local c=state(b.unit,'character',true) or {}
  if b.active and h and not h.is_dead and not h.is_downed and not b.post and not b.guard_request and not c.current_seat_unit then
   followers=followers+1
   if b.job and (b.job.kind=='research' or b.job.kind=='ammo') then routine=routine+1 end
  end
 end
 for _,b in ipairs(bots) do if b.target and b.target.position and dist(lp,b.target.position)<14 then threatened=true;break end end
 for _,e in ipairs(enemies or {}) do
  if e.alive and e.enemy and e.position then
   if dist(lp,e.position)<14 then threatened=true end
   for _,escort in ipairs(ctx.escorts) do if dist(escort.position,e.position)<14 then threatened=true end end
  end
 end
 if threatened then
  for _,b in ipairs(bots) do if b.job and b.job.kind=='research' then
   B.release(ctx,b,'defending',now,emit);routine=math.max(0,routine-1)
  end end
 end
 local routine_limit=followers==1 and (threatened and 0 or 1) or math.max(1,math.floor(followers/3))
 if #ctx.escorts>0 and followers>=3 then routine_limit=math.min(routine_limit,followers-3) end
 for _,job in ipairs(ctx.jobs) do
  local background=job.kind=='research' or job.kind=='ammo'
  if not ctx.claims[job.key] and not ctx.deferred[job.key] and not B.danger(ctx,job.position)
    and (not background or routine<routine_limit) and (job.kind~='research' or not threatened) then
   local best,score
   for _,b in ipairs(bots) do
    local h=state(b.unit,'health');local c=state(b.unit,'character',true) or {}
    local free=not b.job or job.priority<b.job.priority
    local post_help=b.post and job.kind=='revive' and dist(b.post,job.position)<=6
    local failed=ctx.failed[job.key] and (ctx.failed[job.key][b.id] or 0)>now
    if b.active and free and not b.equipment_action and not b.grenade_action and not b.stratagem_intent and not b.tactical_job and (not b.post or post_help) and (not b.returning or job.kind=='revive') and not b.guard_request and not failed
      and not b.vehicle_order and not c.current_carry_unit and (not b.objective or job.kind=='revive') and h and not h.is_dead and not h.is_downed and not c.current_seat_unit then
     local needs=job.kind~='ammo'
     if not needs then
      local inv=state(b.unit,'inventory') or {};local ok,ammo=pcall(B.weapon,inv.primary_weapon or inv.current_weapon)
      needs=ok and ammo.heat==nil and type(ammo.num_mags)=='number' and ammo.num_mags==0 and (b.next_supply or 0)<=now
      local m=rawget(_G,'HelldiversSquadAI')
      if m and m.tactics and m.tactics.enabled then needs=m.tactics.ammo_job(b,job) and (b.next_supply or 0)<=now end
     end
     if needs and B.valid(job,b,leader) then
      local d=dist(pos(b.unit),job.position)
      if not score or d<score or (d==score and b.id<best.id) then best,score=b,d end
     end
    end
   end
   if best then
    B.release(ctx,best,'preempted',now,emit)
    local task={};for k,v in pairs(job) do task[k]=v end
    task.started=now;best.job=task;ctx.claims[job.key]=best
    if background then routine=routine+1 end
    if emit then emit('task_assigned',{task=job.kind,target=tostring(job.unit)},best.id) end
   end
  end
 end
end
function B.update_job(ctx,b,leader,lp,now,emit)
 local job=b.job;if not job then return end
 local c=state(b.unit,'character',true) or {};local h=state(b.unit,'health') or {}
 if h.is_downed or h.is_dead then B.release(ctx,b,'incapacitated',now,emit);return end
 local a=state(job.unit,job.component);local result
 if job.attempted then
  if job.kind=='seat' and c.current_seat_unit==job.unit then result='boarded'
  elseif job.kind=='revive' then
   local th=state(job.unit,'health');if th and not th.is_downed and not th.is_dead then result='helped_up' end
  elseif job.kind=='ammo' then
   local inv=state(b.unit,'inventory') or {};local ammo=B.weapon(inv.primary_weapon or inv.current_weapon)
   local support=B.weapon(inv.support_weapon)
   if (ammo.num_mags or 0)>(job.before_mags or 0) or (support.num_mags or 0)>(job.before_support_mags or 0)
    or (inv.num_grenades or 0)>(job.before_grenades or inv.num_grenades or 0) then result='resupplied';b.next_supply=now+10 end
  elseif job.kind=='research' and a and a.enabled==false then result='pickup_consumed' end
 end
 if result then B.release(ctx,b,result,now,emit);return end
 if not B.valid(job,b,leader) then B.release(ctx,b,'unavailable',now,emit);return end
 local p=pos(job.unit)
 if job.kind=='seat' then
  local settings=SeatComponent.get_seat_settings(job.unit,job.index)
  p=pos(job.unit,Unit.node(job.unit,settings.enter_node))
 end
 local outside=dist(lp,p)>14 and not (job.kind=='revive' and dist(pos(b.unit),p)<=18)
 if outside or (b.post and job.kind~='revive') or b.guard_request then B.release(ctx,b,'cancelled',now,emit);return end
 if now-job.started>(job.kind=='revive' and 18 or 12) then B.release(ctx,b,'timeout',now,emit);return end
 job.target_position=p;job.position=p
 if job.kind=='revive' then
  if not job.approach_angle then
   local bp=pos(b.unit);job.approach_angle=math.atan2(bp.y-p.y,bp.x-p.x)
  end
  job.position={x=p.x+math.cos(job.approach_angle)*.95,y=p.y+math.sin(job.approach_angle)*.95,z=p.z}
 end
 return job
end
function B.interact(b,job,now,emit)
 if not live(b.unit) or not live(job.unit) or (job.next_attempt or 0)>now then return false end
 local i=state(b.unit,'interactor',true)
 if not i or i.enabled==false or i.busy then return false end
 local c=state(b.unit,'character',true) or {}
 if CharacterStateInteract and c.current_state==CharacterStateInteract then return false end
 local p=pos(b.unit)
 local target=job.target_position or job.position
 if dist(p,target)>(job.kind=='revive' and 1.25 or 1.1) or math.abs((p.z or 0)-(target.z or 0))>1.3 then return false end
 if job.kind=='ammo' then
  local inv=state(b.unit,'inventory') or {};local ammo=B.weapon(inv.primary_weapon or inv.current_weapon)
  job.before_mags=ammo.num_mags
  job.before_support_mags=B.weapon(inv.support_weapon).num_mags
  job.before_grenades=inv.num_grenades
  b.next_supply=now+10
 end
 job.attempted=true
 job.next_attempt=now+(job.kind=='revive' and .45 or 2.5)
 EntityAux.queue_command_master(b.unit,'interactor','force_interaction',{
  interactable_unit=job.unit,interactable_component=job.component,
  interactable_actor=job.interactable_actor or (job.actor and Unit.actor(job.unit,job.actor) or nil)})
 if emit then emit('task_interaction_requested',{task=job.kind},b.id) end
 return true
end
return B
