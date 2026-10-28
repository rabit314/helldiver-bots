-- Observational mission recorder. Native actions and return values are untouched.
local previous=rawget(_G,'HelldiversGameplayRecorder')
if previous and previous.revision~='2.1' then previous.stop();previous=nil end
if previous then previous.heartbeat=0;return 'Gameplay recorder '..previous.revision..' ready' end
assert(type(StateGame)=='table' and type(StateGame.post_update)=='function','Mission scripts not ready')
local R={revision='2.1',clock=0,heartbeat=0,generation=0,hooks={},enabled=true,
 log=Telemetry.new(config.instance,16384),ids={},next_id=0,known={},inputs={},last_positions={},
 activity={},enemy_requests=setmetatable({}, {__mode='k'}),covered_components={},next_positions=0,noise_counts={},next_noise=10}
rawset(_G,'HelldiversGameplayRecorder',R)
local function emit(kind,data)
 R.log:emit('gameplay',kind,data,R.clock)
end
local function attempt(fn,...)
 local ok,err=pcall(fn,...)
 if not ok then
  R.failures=(R.failures or 0)+1
  if not R.next_error or R.clock>=R.next_error then
   R.next_error=R.clock+1;emit('recorder_error',{message=tostring(err),failures=R.failures})
  end
 end
end
local function active()
 local sm=Boot and Boot.state_machine
 return R.enabled and R.session and R.heartbeat<20 and sm and sm.current_state_name=='game' and sm.state==R.session
end
local function alive(u) return u and Unit.alive(u) or false end
local function id(u)
 if not u then return nil end
 if not R.ids[u] then R.next_id=R.next_id+1;R.ids[u]=tostring(R.generation)..':'..R.next_id end
 return R.ids[u]
end
local function vector(v)
 if v==nil then return nil end
 -- Copy transient native vectors immediately, before any other native call.
 local x,y,z=v.x,v.y,v.z
 return {x=x,y=y,z=z}
end
local function state(u,name)
 if alive(u) and EntityAux.has_component(u,name) then return EntityAux.state(u,name) end
end
local function role(u)
 if not alive(u) then return 'removed' end
 for _,p in ipairs(R.session.players or {}) do
  local go=p.player_go
  if go and go:exists() and go:get('avatar_unit')==u then return 'player' end
 end
 local m=rawget(_G,'HelldiversSquadAI')
 if m and m.units and m.units[u] then return 'bot' end
 if EntityAux.has_component(u,'enemy') then return 'enemy' end
 if EntityAux.has_component(u,'character') then return 'character' end
 return 'object'
end
local function actor(u)
 if not u then return nil end
 local a={id=id(u)}
 if not alive(u) then a.role='removed';return a end
 a.position=vector(Unit.world_position(u,0));a.role=role(u)
 return a
end
local function copy(v,depth,seen)
 local t=type(v)
 if t=='nil' or t=='number' or t=='boolean' then return v end
 if t=='string' then return v:sub(1,512) end
 if (t=='userdata' or t=='table') and R.ids[v] then return {entity_id=R.ids[v]} end
 if t~='table' then return tostring(v) end
 if depth<=0 or seen[v] then return '<table omitted>' end
 seen[v]=true;local out={};local n=0
 for k,x in pairs(v) do
  n=n+1;if n>48 then out._truncated=true;break end
  out[tostring(k)]=copy(x,depth-1,seen)
 end
 seen[v]=nil;return out
end
local function data(v) return copy(v,3,{}) end
local noise={set_movement=true,set_velocity=true,set_look=true,look=true,aim=true,
 set_aim=true,set_target=true,update_target=true,animation_event=true,input=true}
local enemy_edges={aggro=true,patrol=true,aimed_at=true,add_group_members=true,remove_from_group=true,remove_group_member=true}
-- Observe native outcomes, not every internal mover/camera/controller update.
-- Unknown queue commands are excluded until their diagnostic value is established.
local queue_observed={
 hellbomb={arm_bomb=true,time_to_die=true},explosive={arm=true},
 stratagem={set_thrown_direction=true},npc_escort={interact=true,follow=true},
 objective_escort={interact=true},equipment={wield=true,holster=true,wielder=true},
 seat={enter_seat=true,exit_seat=true},extract_beacon={interact=true},
 hellpod={close_hellpod=true}}
local function suppressed(component,command)
 local key=tostring(component)..'.'..tostring(command)
 if R.noise_counts[key] then R.noise_counts[key]=R.noise_counts[key]+1
 elseif (R.noise_keys or 0)<64 then R.noise_counts[key]=1;R.noise_keys=(R.noise_keys or 0)+1
 else R.noise_other=(R.noise_other or 0)+1 end
end
local function same(a,b,depth)
 if type(a)~=type(b) then return false end
 if type(a)~='table' then return a==b end
 if depth<=0 then return false end
 for k,v in pairs(a) do if not same(v,b[k],depth-1) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end
 return true
end
local function result_state(context)
 local s=context and context.state or {}
 return data({hitpoints=s.hitpoints,hitpoints_real=s.hitpoints_real,is_dead=s.is_dead,is_downed=s.is_downed,
  num_grenades=s.num_grenades,interact_action=s.interact_action,interact_time=s.interact_time,
  current_weapon=id(s.current_weapon),rounds=s.rounds,magazines=s.num_mags,
  reloading=s.is_reloading,heat=s.heat})
end
local function hook(obj,key,make,label)
 if type(obj)~='table' or type(obj[key])~='function' then
  emit('hook_unavailable',{hook=label or key});return
 end
 local inherited=rawget(obj,key)==nil
 local old=obj[key];local wrapper=make(old)
 R.hooks[#R.hooks+1]={obj=obj,key=key,old=old,inherited=inherited,wrapper=wrapper}
 obj[key]=wrapper;emit('hook_installed',{hook=label or key})
end
local function command_hook(class,name)
 if type(class)=='table' and type(class.command_master)=='function' then
  R.covered_components[name:gsub('Component$',''):gsub('(%l)(%u)','%1_%2'):lower()]=true
 end
 hook(class,'command_master',function(old)
  return function(self,u,context,command,value,...)
   local fields
   if active() then attempt(function()
    if command=='input' or command=='set_movement' then
     -- Input edges describe intent; actual shots are recorded separately below.
     if command~='input' or type(value)~='table' then return end
     if role(u)=='bot' then return end -- Existing AI snapshots already cover bot decisions.
     local prev=R.inputs[u] or {};local changed={};local any=false
     for _,key in ipairs({'reload','sprint','dodge','melee','interact','switch_weapon','throw','stratagems','map','up','down','left','right'}) do
      local v=value[key];if v==nil then v=false end
      if v~=(prev[key] or false) then changed[key]=v;prev[key]=v;any=true end
     end
     R.inputs[u]=prev
     if any then emit('input_changed',{actor=actor(u),input=changed,evidence='input_request'}) end
    elseif command=='firing_auto' or command=='firing_single' then
     -- Discrete weapons already emit one native record for each shot. Continuous
     -- weapons retain only firing-request transitions, never one row per frame.
     if name~='BeamweaponComponent' and name~='FlameweaponComponent' and name~='HealbeamComponent' then return end
     local prev=R.activity[u] or {};local key=name..':'..command;local v=not not value
     R.activity[u]=prev
     if v~=(prev[key] or false) then
      prev[key]=v;emit('weapon_activity',{actor=actor(u),weapon_class=name,command=command,
       value=v,evidence='firing_request_edge'})
     end
    elseif not noise[command] then
     if name=='EnemyComponent' then
      if command=='damage_taken' and R.covered_components.health then suppressed(name,command);return end
      if enemy_edges[command] then
       local previous=R.enemy_requests[u] or {};R.enemy_requests[u]=previous
       local value_copy=data(value);local last=previous[command]
       if last and same(last.value,value_copy,5) then suppressed(name,command);return end
       previous[command]={value=value_copy}
      end
     end
     fields={actor=actor(u),component=name,command=command,value=data(value),
      before=result_state(context),native_completed=false,evidence='native_command'}
     if name=='HealthComponent' then
      fields.before=data(context and context.state and {hitpoints=context.state.hitpoints,hitpoints_real=context.state.hitpoints_real})
      if type(value)=='table' then fields.source=actor(value.owner_unit) end
     end
     emit('component_action',fields)
    end
   end) end
   if fields then
    local function finished(...)
     attempt(function()
      -- The ring owns this table; enrich its one record instead of emitting a
      -- second request/result row. Native failures still leave an unfinished row.
      fields.after=result_state(context);fields.native_completed=true
     end)
     return ...
    end
    return finished(old(self,u,context,command,value,...))
   end
   return old(self,u,context,command,value,...)
  end
 end,name..'.command_master')
end
-- The native shot statistic is emitted inside each accepted firing iteration,
-- including automatic/burst and infinite-ammunition paths. No input inference.
for _,name in ipairs({'FirearmComponent','LauncherComponent','LauncherTurretComponent','ArcweaponComponent',
 'FlameweaponComponent','BeamweaponComponent','HealbeamComponent','MeleeWeaponComponent','TurretComponent'}) do
 local class=rawget(_G,name)
 hook(class,'trigger_event',function(old)
  return function(self,event,u,stat,count,...)
   if active() and event=='on_add_to_stat' and stat=='shots' then attempt(function()
    local inv=state(u,'inventory')
    emit('shot_fired',{actor=actor(u),weapon_class=name,weapon_id=inv and id(inv.current_weapon),
     count=count,evidence='native_shot_stat'})
   end) end
   return old(self,event,u,stat,count,...)
  end
 end,name..'.trigger_event')
 command_hook(class,name)
end
for _,name in ipairs({'CharacterComponent','InventoryComponent','InteractorComponent','HealthComponent',
 'EnemyComponent','ObjectiveInteractObjectComponent','VehicleComponent','SeatComponent',
 'AmmoPickupComponent','ResearchSamplePickupComponent','ThrowableWeaponComponent','ThrowableComponent',
 'WeaponPickupComponent','BackpackPickupComponent','CustomPickupComponent',
 'InteractableCharacterComponent','InteractableNpcDialogueComponent'}) do
 command_hook(rawget(_G,name),name)
end
for _,name in ipairs({'HealthComponent','CharacterComponent','InventoryComponent','InteractorComponent',
 'ObjectiveInteractObjectComponent','ResearchSamplePickupComponent','AmmoPickupComponent','EnemyComponent'}) do
 hook(rawget(_G,name),'trigger_event',function(old)
  return function(self,event,u,details,...)
   if active() and event~='on_add_to_stat' and event~='on_damage_taken' and event~='on_health_received' then
    local extra={...}
    attempt(function() emit('component_event',{actor=u and R.ids[u] and actor(u) or nil,
     subject=data(u),component=name,event=event,details=data(details),extra=data(extra),evidence='native_event'}) end)
   end
   return old(self,event,u,details,...)
  end
 end,name..'.trigger_event')
end
hook(EntityAux,'queue_command_master',function(old)
 return function(u,component,command,value,...)
  if active() and not noise[command] and not R.covered_components[component] then
   local observed=queue_observed[component]
   if observed and observed[command] then attempt(function()
    emit('command_queued',{actor=actor(u),component=component,command=command,value=data(value),evidence='queued_request'})
   end)
   else suppressed(component,command) end
  end
  return old(u,component,command,value,...)
 end
end,'EntityAux.queue_command_master')
-- Enemy native firing code queues this animation only after executing the shot.
hook(rawget(_G,'EnemyComponent'),'queue_command_slave',function(old)
 return function(self,u,component,command,value,...)
  if active() and component=='enemy' and command=='animation_event' and value=='fire' then
   attempt(function() emit('enemy_shot_fired',{actor=actor(u),evidence='native_post_shot_animation'}) end)
  end
  return old(self,u,component,command,value,...)
 end
end,'EnemyComponent.queue_command_slave')
hook(rawget(_G,'EnemyComponent'),'handle_shoot_event',function(old)
 return function(self,u,context,dt,...)
  if active() then attempt(function()
   local s=context and context.state;local event=s and s.shoot_event
   if event and not event.has_started and not event.abort_event then
    emit('enemy_attack_started',{actor=actor(u),attack=data(event),evidence='native_shoot_event'})
   end
  end) end
  return old(self,u,context,dt,...)
 end
end,'EnemyComponent.handle_shoot_event')
local function positions(s)
 local actors={};local seen={};local n=0
 local function flush()
  if n>0 then emit('positions',{actors=actors,check_interval=.5,heartbeat=5,changed_only=true});actors={};n=0 end
 end
 local function observe(u)
  if seen[u] or not alive(u) then return end
  seen[u]=true
  local a=actor(u)
  if a.role=='bot' then
   if not R.known[u] or R.known[u].role~='bot' then
    local m=rawget(_G,'HelldiversSquadAI');local b=m and m.units and m.units[u]
    emit('actor_log_source',{actor={id=a.id,role='bot'},ai_bot_id=b and b.id,source='AI_Squadmates_Behavior.jsonl'})
   end
   R.known[u]={id=a.id,role='bot'};R.last_positions[u]=nil;return
  end
  local h=state(u,'health');local c=state(u,'character');local e=state(u,'enemy')
  if h then a.health=h.hitpoints;a.health_real=h.hitpoints_real;a.downed=h.is_downed;a.dead=h.is_dead end
  if c then a.stamina=c.sprint_stamina;a.sprinting=c.is_sprinting end
  if e then a.ai_state=data(e.current_state);a.target=id(e.target_unit) end
  local inv=state(u,'inventory')
  if inv then
   a.weapon_id=id(inv.current_weapon);a.grenades=inv.num_grenades
   if alive(inv.current_weapon) and EntityAux.has_interface(inv.current_weapon,'weapon') then
    local w=EntityAux.state_master_interface(inv.current_weapon,'weapon')
    if w then a.ammo=data({rounds=w.rounds,magazines=w.num_mags,reloading=w.is_reloading,heat=w.heat}) end
   end
  end
  R.known[u]={id=a.id,role=a.role}
  local last=R.last_positions[u];local changed=not last or R.clock-last.time>=5
  if last and not changed then
   local p,q=a.position,last.actor.position
   changed=(p.x-q.x)^2+(p.y-q.y)^2+(p.z-q.z)^2>=.15^2
   local current,old={},{}
   for k,v in pairs(a) do if k~='position' then current[k]=v end end
   for k,v in pairs(last.actor) do if k~='position' then old[k]=v end end
   changed=changed or not same(current,old,5)
  end
  if changed then
   actors[a.id]=a;R.last_positions[u]={actor=a,time=R.clock}
   n=n+1;if n>=24 then flush() end
  end
 end
 for _,p in ipairs(s.players or {}) do
  local go=p.player_go;if go and go:exists() then observe(go:get('avatar_unit')) end
 end
 local m=rawget(_G,'HelldiversSquadAI')
 if m then for _,b in ipairs(m.bots or {}) do observe(b.unit) end end
 if s.entity_manager then
  for _,component in ipairs({'enemy','character'}) do
   for u in pairs(s.entity_manager:get_master_entities(component) or {}) do observe(u) end
  end
 end
 flush()
 for u,old in pairs(R.known) do
  if not seen[u] then
   emit('entity_no_longer_observed',{id=old.id,alive=alive(u)})
   R.known[u]=nil;R.inputs[u]=nil;R.last_positions[u]=nil;R.activity[u]=nil;R.enemy_requests[u]=nil
  end
 end
end
local function end_mission(reason)
 emit('mission_ended',{generation=R.generation,reason=reason})
 R.session=nil;R.ids={};R.known={};R.inputs={};R.last_positions={};R.activity={};R.enemy_requests=setmetatable({}, {__mode='k'})
end
hook(StateGame,'post_update',function(old)
 return function(s,dt,...)
  if R.enabled then attempt(function()
   R.clock=R.clock+math.max(0,tonumber(dt) or 0)
   local last=R.heartbeat;R.heartbeat=R.heartbeat+math.max(0,tonumber(dt) or 0)
   if last<20 and R.heartbeat>=20 then emit('capture_paused',{reason='controller_heartbeat_expired'}) end
   if R.session~=s then
    if R.session then end_mission('mission_changed') end
    R.session=s;R.generation=R.generation+1;R.ids={};R.known={};R.inputs={};R.last_positions={};R.activity={};R.enemy_requests=setmetatable({}, {__mode='k'});R.next_positions=0
    emit('mission_started',{generation=R.generation,mission=data(s.generated_level)})
   end
   if active() and R.clock>=R.next_positions then R.next_positions=R.clock+.5;positions(s) end
   if active() and R.clock>=R.next_noise then
    R.next_noise=R.clock+10
    if next(R.noise_counts) or R.noise_other then
     emit('noise_suppressed',{counts=R.noise_counts,other=R.noise_other or 0,interval=10})
     R.noise_counts={};R.noise_keys=0;R.noise_other=nil
    end
   end
  end) end
  return old(s,dt,...)
 end
end,'StateGame.post_update')
for _,key in ipairs({'on_entity_registered','on_entity_unregistering'}) do
 hook(StateGame,key,function(old)
  return function(s,u,...)
   if active() then attempt(function()
    if key=='on_entity_registered' then R.ids[u]=nil;R.known[u]=nil;R.inputs[u]=nil;R.last_positions[u]=nil;R.activity[u]=nil;R.enemy_requests[u]=nil end
    emit(key,{actor=actor(u)})
    if key=='on_entity_unregistering' then R.ids[u]=nil;R.known[u]=nil;R.inputs[u]=nil;R.last_positions[u]=nil;R.activity[u]=nil;R.enemy_requests[u]=nil end
   end) end
   return old(s,u,...)
  end
 end,'StateGame.'..key)
end
function R.telemetry(after,instance)
 local sm=Boot and Boot.state_machine
 if R.session and (not sm or sm.current_state_name~='game' or sm.state~=R.session) then end_mission('left_game_state') end
 if R.heartbeat>=20 then emit('capture_resumed',{unobserved_seconds=R.heartbeat-20}) end
 R.heartbeat=0
 return R.log:batch(after,instance,96,'Gameplay recorder '..R.revision,0,0)
end
function R.stop()
 emit('recorder_stopped',{});R.enabled=false;R.session=nil;R.ids={};R.known={};R.inputs={};R.last_positions={};R.activity={};R.enemy_requests=setmetatable({}, {__mode='k'})
 for i=#R.hooks,1,-1 do
  local h=R.hooks[i]
  if h.obj[h.key]==h.wrapper then
   if h.inherited then h.obj[h.key]=nil else h.obj[h.key]=h.old end
  end
 end
 rawset(_G,'HelldiversGameplayRecorder',nil)
end
emit('recorder_started',{version=R.revision,position_check_interval=.5,position_heartbeat=5,movement_threshold=.15,capacity=16384,
 coverage='native shot statistics, enemy firing paths, component commands, input edges, loaded mission actors',
 limits='changed positions only; bots use existing AI logs; continuous weapons use firing edges; not every engine operation'})
return 'Gameplay recorder '..R.revision..' ready'
