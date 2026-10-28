-- Original HELLDIVERS 1 companion runtime. No configured bot-count cap.
assert(type(Core)=='table' and Core.revision=='0.11.4','Missing squadmate decision module')
assert(type(Orders)=='table' and Orders.revision=='0.11.2','Missing guard order module')
assert(type(Perimeter)=='table' and Perimeter.revision=='0.8.0','Missing perimeter module')
assert(type(RandomLoadout)=='table' and type(Telemetry)=='table','Missing AI modules')
assert(type(StateGame)=='table' and type(StateGame.pre_update)=='function','Mission scripts not ready')
assert(type(EntityAux)=='table' and type(EntityAux.queue_command_master)=='function','Entity commands unavailable')
local M=rawget(_G,'HelldiversSquadAI')
if not M then
 M={revision='0.23.1',hooks={},generation=0,enabled=false,clock=0,heartbeat=0,order_sequence=0,
    bots={},units={},retired={},pending={},pending_count=0,next_bot_id=0,landings={},formation_dirty=true,
    waiting={first=1,last=0,items={}},stats={requests=0,spawns=0,shots=0,reloads=0,steps=0,despawns=0},
    events={},log=Telemetry.new(config.instance or config.seed)}
 rawset(_G,'HelldiversSquadAI',M)
end
assert(M.revision=='0.23.1','Unload the old AI runtime before updating')
M.core=Core;M.random=M.random or RandomLoadout.generator(config.seed)
if M.auto_deploy==nil then M.auto_deploy=false end
M.bot_origins=M.bot_origins or setmetatable({}, {__mode='k'})
local function event(kind,data,id,channel)
 M.log:emit(channel or 'events',kind,data,M.clock,id)
 M.events[#M.events+1]=string.format('%.2f %s%s',M.clock,kind,id and (' bot='..id) or '')
 if #M.events>30 then table.remove(M.events,1) end
 M.message=kind..(id and (' bot='..id) or '')
end
local function alive(unit) return unit~=nil and Unit.alive(unit) end
local function command(unit,component,name,data) EntityAux.queue_command_master(unit,component,name,data) end
local function position(unit)
 -- A native access violation cannot be caught by Lua pcall. Check the handle first.
 assert(alive(unit),'Expired unit rejected before native position lookup')
 local p=Unit.world_position(unit,0);return {x=p.x,y=p.y,z=p.z}
end
local function state(unit,name)
 if alive(unit) and EntityAux.has_component(unit,name) then return EntityAux.state(unit,name) end
end
local function master(unit,name)
 if alive(unit) and EntityAux.has_component_master(unit,name) then return EntityAux.state_master(unit,name) end
end
M.behaviors=M.behaviors or Behaviors.new();M.weapon_owners=M.weapon_owners or {}
M.perimeter=M.perimeter or Perimeter.new()
M.orders=M.orders or Orders.new()
local support=M.support or Support(M,Core,Behaviors,Navigation,event);M.support=support
support.install()
Orders.install(M)
local loadouts=Loadouts(M,RandomLoadout)
local takeover,objectives,vehicles,mobility,extraction
local function neutral(unit)
 if not alive(unit) then return end
 local i=M.core.neutral();local c=master(unit,'character') or {}
 if not c.current_seat_unit then command(unit,'mover','set_movement',i.movement) end
 command(unit,'character','input',i)
end
local function hook(key,factory)
 if M.hooks[key] then assert(StateGame[key]==M.hooks[key].wrapper,'Another mod replaced '..key);return end
 local original=assert(StateGame[key],key..' missing');local wrapper=factory(original)
 M.hooks[key]={original=original,wrapper=wrapper};StateGame[key]=wrapper
end
M.dead_bodies=M.dead_bodies or {}
M.ray_retention=M.ray_retention or {}
M.retain_rays=function(rays,pending)
 pending=pending or (rays and rays.pending)
 if rays and pending and next(pending) then
  M.ray_retention[#M.ray_retention+1]={rays=rays,pending=pending,session=M.session}
 end
end
M.retire_body=function(unit,bot)
 -- Native corpses own death effects, attached equipment and render resources.
 -- Stop AI immediately but let DecayManager remove the body at native timing.
 if not alive(unit) then return false end
 if M.dead_bodies[unit] then return true end
 local dm=M.session and M.session.decay_manager
 if not dm or type(dm.decay)~='function' then return false end
 local managed=type(dm.is_decaying)=='function' and dm:is_decaying(unit)
 local native=EntityAux.has_component_master(unit,'decay_on_dead')
 if not managed and not native then dm:decay(unit,5,5) end
 M.dead_bodies[unit]={bot=bot,generation=M.generation,started=M.clock}
 M.retired[unit]=true
 event('body_retired',{native_decay=not not (native or managed)},bot and bot.id)
 return true
end
local function remove_bot(bot,reason,keep)
 if not bot or not bot.active then return end
 if M.order_inheritance then M.order_inheritance.depart(bot,reason) end
 if M.tactics then M.tactics.detach(bot,reason) end
 if M.grenades then M.grenades.finish(bot,reason) end
 if objectives then objectives.release(bot,reason,reason=='died' or reason=='possessed' or reason=='control_switched' or reason=='controller_failed') end
 if vehicles then vehicles.release(bot,reason,reason~='control_switched' and reason~='possessed') end
 Behaviors.release(M.behaviors,bot,reason or 'removed',M.clock,event);support.cancel(bot)
 -- Results already queued in PhysicsWorld must not inspect dead actors or
 -- satisfy a later request if this body is controlled and rejoined again.
 if not keep then
  M.retain_rays(bot.ray,bot.visibility_pending);M.retain_rays(bot.nav_rays);M.retain_rays(bot.route_rays)
 end
 bot.query=nil;bot.nav_query=nil;support.invalidate(bot)
 Orders.remove(M.orders,bot.id)
 if bot.weapon then M.weapon_owners[bot.weapon]=nil end
 bot.active=false;if not keep then M.retired[bot.unit]=true end;M.units[bot.unit]=nil
 bot.rejoin_epoch=(bot.rejoin_epoch or 0)+1
 local last=M.bots[#M.bots];M.bots[bot.index]=last;last.index=bot.index;M.bots[#M.bots]=nil
 M.bot=M.bots[1];M.formation_dirty=true
 local corpse=not keep and reason=='died' and alive(bot.unit) and M.retire_body(bot.unit,bot)
 if not keep and not corpse and alive(bot.unit) and M.session and M.session.entity_spawner then
  local ok,err=pcall(neutral,bot.unit)
  if not ok then event('neutral_command_error',{message=tostring(err)},bot.id,'errors') end
  ok,err=pcall(M.session.entity_spawner.despawn_entity,M.session.entity_spawner,bot.unit)
  if ok then M.stats.despawns=M.stats.despawns+1
  else M.last_error=tostring(err);event('despawn_error',{message=tostring(err)},bot.id,'errors') end
 end
 event(reason or 'despawned',{shots=bot.shots,reloads=bot.reloads,distance_moved=bot.distance_moved},bot.id)
end
M.detach_bot=function(bot,reason)remove_bot(bot,reason,true)end
M.rejoin_bot=function(bot,mounted)
 if not alive(bot.unit) or M.units[bot.unit] then return end
 bot.active=true;bot.failed=nil;bot.index=#M.bots+1;bot.controller={};bot.query=nil;bot.nav_query=nil
 bot.post=nil;bot.guard_request=nil;bot.returning=true;bot.vehicle_input=nil;bot.target=nil;bot.visibility=nil
 bot.next_scan=M.clock+.5;bot.next_ray=M.clock+.5;bot.interaction_check=nil
 bot.visibility=nil;bot.obstacles=nil;bot.step_check=nil
 if M.refresh_rays then M.refresh_rays(bot) end
 M.bots[bot.index]=bot;M.units[bot.unit]=bot;M.retired[bot.unit]=nil;M.bot=M.bots[1];M.formation_dirty=true
 if vehicles then vehicles.adopt(bot,mounted) end
end
takeover=Takeover(M,Core,event);objectives=Objectives(M,Core,Behaviors,Orders,event)
vehicles=Vehicles(M,Core,Behaviors,support,Orders,event)
objectives=assert(rawget(_G,'HelldiversSquadAIStage').Interactions)(M,Core,Behaviors,objectives,support,Orders,event)
objectives=assert(rawget(_G,'HelldiversSquadAIStage').TerminalLifecycle)(M,Core,Behaviors,objectives,event)
local navtrace=assert(rawget(_G,'HelldiversSquadAIStage').NavTrace)(M,Core,support,Navigation,vehicles,event)
assert(rawget(_G,'HelldiversSquadAIStage').Surface)(M,Core,support,objectives,event)
assert(rawget(_G,'HelldiversSquadAIStage').Recovery)(M,Core,support,vehicles,event)
assert(rawget(_G,'HelldiversSquadAIStage').Rejoin)(M,Core,Behaviors,support,Navigation,vehicles,event)
local camera=CameraFocus(M);camera.install()
local display=rawget(_G,'HelldiversSquadAIStage').Display(M,event)
M.is_bot_body=takeover.is_body
M.is_original_body=takeover.is_original_body
local stage=rawget(_G,'HelldiversSquadAIStage')
if stage.StratagemTactics then stage.StratagemTactics(M,Core,Behaviors,support,vehicles,stage.StratagemModel,stage.StratagemNative,event) end
mobility=assert(stage.Mobility)(M,Core,Behaviors,support,vehicles,event)
extraction=assert(stage.Extraction)(M,Core,Behaviors,support,vehicles,mobility,event)
if stage.ActionSafety then stage.ActionSafety(M,Core,Behaviors,event) end
if stage.Grenades and stage.StratagemModel then stage.Grenades(M,Core,Behaviors,support,stage.StratagemModel,event) end
function M.cancel_pending(reason)
 if M.session and M.session.spawn_manager then
  local queue=M.session.spawn_manager.queued_spawns or {}
  for n=#queue,1,-1 do
   local cb=queue[n].callback_object
   if cb and cb.squad_owner==M then table.remove(queue,n) end
  end
 end
 for id in pairs(M.pending) do event('deployment_cancelled',{reason=reason},id) end
 M.pending={};M.pending_count=0;M.active_spawn=nil;M.waiting={first=1,last=0,items={}};M.landings={}
end
function M.cleanup(reason,live_session)
 if M.order_inheritance then M.order_inheritance.clear(reason) end
 if M.tactics then M.tactics.clear(reason) end
 vehicles.reset()
 takeover.cancel(reason);objectives.clear(reason)
 local world=live_session and live_session==M.session and live_session.world_proxy:get_world()
 Orders.clear(M.orders,world)
 M.generation=M.generation+1;M.cancel_pending(reason)
 if extraction then extraction.reset() end
 if mobility then mobility.recovery_ticket=nil;mobility.waiting={} end
 for n=#M.bots,1,-1 do
  local b=M.bots[n];local keep=takeover.is_original_body(b.unit)
  if keep then pcall(neutral,b.unit) end
  remove_bot(b,reason or 'despawned',keep)
 end
 if reason then event('squad_cleaned',{reason=reason}) end
end
function M.disable(reason)
 -- Return to the living first body before dismissing its AI record.
 local sm=Boot and Boot.state_machine
 local live_session=sm and sm.current_state_name=='game' and sm.state==M.session and M.session or nil
 if live_session then
  for _,p in ipairs(M.session.players or {}) do
   local go=p.player_go
   if go and go:exists() and go:owned() and go:has('avatar_unit') then
    local ok,err=pcall(takeover.home,M.session,go:get('avatar_unit'),true)
    if not ok then event('home_cleanup_error',{message=tostring(err)},nil,'errors') end
    break
   end
  end
 end
 M.enabled=false
 local ok,err=pcall(M.cleanup,reason or 'disabled',live_session)
 if not ok then M.last_error=tostring(err);event('cleanup_error',{message=tostring(err)},nil,'errors') end
end
function M.status()
 local controlled=takeover.possessed and ('\nControlling bot '..takeover.possessed.id..' | F9: next | hold F9: first living Helldiver') or ''
 local work='';local count=0
 for _,b in ipairs(M.bots) do
  local t=b.objective
  if t and count<3 then work=work..'\nBot '..b.id..': '..(t.component and 'objective' or ('terminal stage '..(t.stage or '?')))..' | '..(t.status or 'travelling');count=count+1
  elseif b.navigation_failure and count<3 then work=work..'\nBot '..b.id..': '..b.navigation_failure;count=count+1 end
 end
 return string.format('AI v%s | %s | bots=%d | pending=%d | deployed=%d | rounds consumed=%d | reloads=%d\n%s%s',
  M.revision,M.enabled and 'enabled' or 'disabled',#M.bots,M.pending_count,
  M.stats.spawns,M.stats.shots,M.stats.reloads,M.message or 'Ready',
  M.last_error and ('\nERROR: '..M.last_error) or '')..controlled..work..'\nAuto deploy: '..(M.auto_deploy and (M.auto_paused==M.session and 'paused for this mission' or 'minimum '..tostring(M.auto_target or 3)) or 'off')..(M.tactics and ('\n'..M.tactics.status()) or '')
end
function M.telemetry(after,instance,limit)
 return M.log:batch(after,instance,limit,M.status(),#M.bots,M.pending_count)
end
local function get_leader(s)
 local count,unit,record=0,nil,nil
 for _,p in ipairs(s.players or {}) do
  local go=p.player_go
  if go and go:exists() then
   count=count+1
   if go:owned() then record=p;if go:has('avatar_unit') then unit=go:get('avatar_unit') end end
  end
 end
 if count~=1 then return nil,nil,'Only one local human is supported' end
 if not record then return nil,nil,'Waiting for local player' end
 if record.player_go:has('has_extracted') and record.player_go:get('has_extracted') then return nil,record,'Player extracted' end
 if not alive(unit) then return nil,record,'Waiting for player deployment' end
 local health=state(unit,'health')
 if not health or health.is_dead then return nil,record,'Waiting for living player' end
 return unit,record
end
local function session(s)
 if s~=M.session then
  M.cleanup('mission_changed');M.session=s;M.spawn_attempted=false;M.order_cursor=0
  M.enemy_cache={};M.next_enemy_scan=0;M.scan_cursor=0;M.leader_motion=nil;M.player_anchor=nil;M.waiting_for_player=false
  M.behaviors=Behaviors.new();M.weapon_owners={}
  M.perimeter=Perimeter.new()
  event('mission_started',{generation=M.generation,mission=s.generated_level and s.generated_level.mission_type_name})
 end
end
M.unlocked_pools=loadouts.pools
local function make_visibility_ray(bot,s)
 M.retain_rays(bot.ray,bot.visibility_pending)
 local token={};bot.visibility_token=token
 local pending={};bot.visibility_pending=pending
 local physics=World.physics_world(s.world_proxy:get_world())
 bot.ray=PhysicsWorld.make_raycast(physics,support.guard(bot,'visibility',function(hits)
  pending.cast=nil
  if bot.visibility_token~=token then return end
  local request=bot.query;bot.query=nil
  if not bot.active or not alive(bot.unit) or not request or request.generation~=M.generation then return end
   local closest,nearest=math.huge,nil
   assert(type(hits)=='table','Invalid visibility reply')
   for _,hit in ipairs(hits) do
    local _,distance,_,actor=unpack(hit)
    assert(type(distance)=='number' and distance==distance and distance>=0 and distance<math.huge,'Invalid visibility distance')
    if actor then
     local unit=Actor.unit(actor)
     if unit~=bot.unit and unit~=request.seat and unit~=request.vehicle and unit~=request.gun and not vehicles.owns(request,unit) and distance<closest then closest=distance;nearest=unit end
    end
   end
   bot.visibility={target=request.target,clear=nearest==request.target,time=M.clock,from=request.from,to=request.to}
 end,function()pending.cast=nil;bot.query=nil;bot.visibility=nil end),'all','collision_filter','damage_ray')
end
local function make_navigation_rays(bot,s)
 M.retain_rays(bot.nav_rays)
 bot.nav_rays={}
 local ray_set=bot.nav_rays
 ray_set.pending={}
 local physics=World.physics_world(s.world_proxy:get_world())
 for _,key in ipairs({'front','left','right'}) do
  -- The native NPC FeelerModule uses this closest-hit filter and callback signature.
  bot.nav_rays[key]=PhysicsWorld.make_raycast(physics,support.guard(bot,'feeler:'..key,function(hit,point,distance,normal,actor)
   ray_set.pending[key]=nil
   if bot.nav_rays~=ray_set then return end
   local q=bot.nav_query
   if not bot.active or not alive(bot.unit) or not q or q.generation~=M.generation then return end
   if hit then assert(hit==true and type(distance)=='number' and distance==distance and distance>=0 and distance<math.huge,'Invalid feeler reply') end
   local target=actor and q.ignore_unit and Actor.unit(actor)==q.ignore_unit and support.navigation_target(bot)==q.ignore_unit
   q[key]=(hit and not target and type(distance)=='number') and distance or q.length
   if q.front and q.left and q.right then
    bot.obstacles={front=q.front,left=q.left,right=q.right,direction=q.direction,from=q.from,time=M.clock}
    bot.nav_query=nil
   end
  end,function()ray_set.pending[key]=nil;bot.nav_query=nil;bot.obstacles=nil end),'closest','collision_filter','npc_ai_feeler')
 end
end
M.refresh_rays=function(bot)
 -- Keep superseded native handles until their callbacks drain. Their private
 -- tokens make late results harmless after reassignment.
 make_visibility_ray(bot,M.session);make_navigation_rays(bot,M.session);support.create_probes(bot,M.session)
end
M.body_record=function(u)
 M.next_bot_id=M.next_bot_id+1
 local b={id=M.next_bot_id,unit=u,kit={names={}},active=false,mode='following',
  next_scan=M.clock,next_ray=M.clock,next_sample=M.clock+1,reload_observed=false,shots=0,reloads=0,
  distance_moved=0,stuck_seconds=0,controller={}}
 -- Adopt the existing body without issuing loadout, health or ammo commands.
 make_visibility_ray(b,M.session);make_navigation_rays(b,M.session);support.create_probes(b,M.session)
 return b
end
local function query_navigation(bot,wanted,budget)
 if not wanted or (wanted.x*wanted.x+wanted.y*wanted.y)<.01 then return end
 if bot.nav_query or budget.navigation<3 or M.clock<(bot.next_navigation or 0) then return end
 local p=bot.frame_position;local d=M.core.direction({x=0,y=0},wanted)
 local length=2.7
 bot.nav_query={from=p,direction=d,length=length,generation=M.generation,ignore_unit=support.navigation_target(bot)}
 bot.next_navigation=M.clock+.2;budget.navigation=budget.navigation-3
 local from=Vector3(p.x,p.y,p.z+.5)
 for _,key in ipairs({'front','left','right'}) do
  local side=key=='left' and 1 or (key=='right' and -1 or 0)
  local x,y=d.x-d.y*side,d.y+d.x*side
  local n=math.sqrt(x*x+y*y)
  bot.nav_rays.pending[key]=true
  bot.nav_rays[key]:cast(from,Vector3(x/n,y/n,0),length)
 end
end
local function finish_request(request)
 if M.pending[request.id]==request then M.pending[request.id]=nil;M.pending_count=M.pending_count-1 end
 if M.active_spawn==request then M.active_spawn=nil end
end
local function occupants(s,leader)
 local result={}
 -- Include every registered human/avatar plus every tracked bot, even when downed.
 for _,p in ipairs(s.players or {}) do
  local go=p.player_go
  if go and go:exists() and go:has('avatar_unit') then
   local u=go:get('avatar_unit')
   if alive(u) then result[#result+1]={position=position(u),radius=4.5} end
  end
 end
 for _,b in ipairs(M.bots) do
  if alive(b.unit) then
   local p=position(b.unit);result[#result+1]={position=p,radius=4.5}
   if b.velocity then result[#result+1]={position={x=p.x+b.velocity.x*.8,y=p.y+b.velocity.y*.8},radius=3.5} end
  end
 end
 local motion=M.leader_motion
 if alive(leader) and motion then
  local p=position(leader)
  result[#result+1]={position={x=p.x+motion.velocity.x*.8,y=p.y+motion.velocity.y*.8},radius=3.5}
 end
 return result
end
M.return_point=function(u)
 return M.core.drop_point(position(u),M.next_bot_id+1,occupants(M.session,u),M.landings,0)
end
local function retry_request(request,reason)
 if M.pending[request.id]~=request then return end
 if M.active_spawn==request then M.active_spawn=nil end
 M.landings[request.id]=nil;request.dispatched=nil
 request.attempts=(request.attempts or 0)+1
 local q=M.waiting;q.last=q.last+1;q.items[q.last]=request;M.next_spawn=M.clock+.3
 event('landing_recheck_deferred',{reason=reason,attempts=request.attempts},request.id)
end
function M.on_ground_checked(unit,path,pos,rotation,request)
 -- SpawnManager's native ignore_spawn mode resolves terrain without creating a pod.
 if unit~=nil then
  if alive(unit) then request.session.entity_spawner:despawn_entity(unit) end
  finish_request(request);M.landings[request.id]=nil
  event('spawn_contract_error',{reason='ignore_spawn returned a unit'},request.id,'errors');return
 end
 if M.pending[request.id]~=request or request.generation~=M.generation or not M.enabled or request.session~=M.session then return end
 local leader,_,reason=get_leader(request.session)
 if not leader then retry_request(request,reason);return end
 local p={x=pos.x,y=pos.y,z=pos.z}
 local clear,why=M.core.landing_clear(p,occupants(request.session,leader),M.landings,request.id)
 if not clear then retry_request(request,why);return end
 M.landings[request.id]={id=request.id,position=p,radius=4.5,expires=M.clock+4}
 event('landing_approved',{position=p,clearance_player=4.5,clearance_bot=4.5},request.id)
 local spawned=request.session.entity_spawner:spawn_entity(path,pos,rotation,nil,nil)
 M.on_spawned(spawned,path,pos,rotation,request)
end
function M.on_spawned(unit,path,pos,rotation,request)
 local s=request.session
 if request.generation~=M.generation or not M.enabled or s~=M.session or M.pending[request.id]~=request then
  if alive(unit) and not M.units[unit] then
   local ok,err=pcall(s.entity_spawner.despawn_entity,s.entity_spawner,unit)
   if not ok then event('late_spawn_cleanup_error',{message=tostring(err)},request.id,'errors') end
  end
  event('late_spawn_discarded',{},request.id);return
 end
 if not alive(unit) then
  finish_request(request);M.landings[request.id]=nil
  event('spawn_failed',{reason='native_spawn_returned_no_live_unit'},request.id,'errors');return
 end
 finish_request(request)
 local bot={id=request.id,unit=unit,kit=request.kit,active=true,index=#M.bots+1,mode='deploying',
  next_scan=M.clock,next_ray=M.clock,next_sample=M.clock+1,reload_observed=false,shots=0,reloads=0,
  distance_moved=0,stuck_seconds=0,controller={}}
 M.bots[bot.index]=bot;M.units[unit]=bot;M.bot_origins[unit]=true;M.bot=M.bots[1];M.formation_dirty=true
 local ok,err=pcall(function()
  assert(alive(unit) and EntityAux.has_component_master(unit,'character'),'Character setup incomplete')
  command(unit,'inventory','loadout_override',request.kit.loadout)
  command(unit,'customization','set_customization',request.kit.customization)
  command(unit,'camera_target','deactivate')
  command(unit,'customization','set_silhouette_color',GameSettings.player_colors[2])
  make_visibility_ray(bot,s)
  make_navigation_rays(bot,s)
  support.create_probes(bot,s)
 end)
 if not ok then
  M.last_error=tostring(err);event('spawn_initialization_error',{message=tostring(err)},bot.id,'errors')
  remove_bot(bot,'spawn_failed');return
 end
 M.stats.spawns=M.stats.spawns+1
 event('spawned',{equipment=bot.kit.names,position=position(unit)},bot.id)
end
local function enqueue(s,leader,record)
 M.next_bot_id=M.next_bot_id+1;local id=M.next_bot_id
 local current=state(leader,'customization') or {}
 local kit=loadouts.kit(record,current.gender)
 local request={id=id,session=s,generation=M.generation,kit=kit,requested=M.clock}
 M.pending[id]=request;M.pending_count=M.pending_count+1;M.stats.requests=M.stats.requests+1
 local q=M.waiting;q.last=q.last+1;q.items[q.last]=request
 event('deployment_requested',{equipment=kit.names,pending=M.pending_count},id)
 return id
end
if stage.Companion then stage.Companion(M,Core,Behaviors,support,objectives,vehicles,Orders,event,enqueue) end
if stage.OrderInheritance then stage.OrderInheritance(M,Core,Behaviors,support,objectives,vehicles,Orders,event) end
if stage.Equipment and M.stratagem_families then stage.Equipment(M,Core,Behaviors,support,M.stratagem_families,event) end
if M.set_auto_deploy then M.set_auto_deploy(config.auto_deploy==true,config.target_count or 3)
else M.auto_deploy=config.auto_deploy==true end
function M.request_deploy()
 if not M.enabled then return 'AI is disabled; enable the controller first' end
 local sm=Boot and Boot.state_machine;local s=sm and sm.state
 if not s or sm.current_state_name~='game' or not s.is_server or not s.generated_level or s.wants_exit then
  event('deployment_rejected',{reason='not_in_local_mission'});return 'Deploy only during a local solo mission'
 end
 local leader,record,reason=get_leader(s)
 if not leader then event('deployment_rejected',{reason=reason});return reason end
 session(s)
 local ok,id=pcall(enqueue,s,leader,record)
 if not ok then event('deployment_error',{message=tostring(id)},nil,'errors');return 'Deployment failed: '..tostring(id) end
 return 'Bot '..id..' deployment requested | active='..#M.bots..' | pending='..M.pending_count
end
local function order_context()
 local sm=Boot and Boot.state_machine;local s=sm and sm.state
 if not M.enabled or not s or sm.current_state_name~='game' or s~=M.session
   or not s.is_server or not s.generated_level or s.wants_exit then return nil,nil,'Orders need active bots in a solo mission' end
 local leader,_,why=get_leader(s)
 if not leader then return nil,nil,why end
 return s,leader
end
local function eligible(bot)
 local h=state(bot.unit,'health')
 return bot.active and h and not h.is_dead and not h.is_downed
end
M.cancel_guard=function(bot)
 bot.rejoin_epoch=(bot.rejoin_epoch or 0)+1
 local r=bot.guard_request
 if r and r.session and r.session.spawn_manager then
  local q=r.session.spawn_manager.queued_spawns or {}
  for i=#q,1,-1 do if q[i].callback_object==r.callback then table.remove(q,i) end end
 end
 bot.guard_request=nil
end
function M.request_guard()
 local s,leader,why=order_context();if not s then return why end
 local bot,first
 for _,b in ipairs(M.bots) do
  if eligible(b) then
   if not first or b.id<first.id then first=b end
   if b.id>(M.order_cursor or 0) and (not bot or b.id<bot.id) then bot=b end
  end
 end
 bot=bot or first
 if not bot then event('guard_rejected',{reason='no_available_bot'});return 'No standing bot available for an order' end
 local function rejected(reason,message,details)
  event('guard_rejected',{reason=reason,details=details},bot.id)
  return 'Guard order unavailable: '..message
 end
 -- EntityAux.state is the replicated/slave view. Cursor/input_data exist only
 -- in the local master state, just as InputComponent.update_masters reads them.
 local i=EntityAux.has_component_master(leader,'input') and EntityAux.state_master(leader,'input')
 if not i then return rejected('input_master_missing','local player input is not ready') end
 local data=i.input_data;local cursor,cursor_source=Orders.cursor(M,leader,data)
 if not data or data.is_active==false then return rejected('input_inactive','player input is inactive') end
 if i.has_focus==false then return rejected('input_unfocused','player input has no focus') end
 if i.character_input_disabled then return rejected('character_input_disabled','character controls are disabled') end
 -- The output map field is a button request, not the current map-open state.
 if CharacterComponent.get_hud_state(leader)=='map' then return rejected('map_open','close the map first') end
 if not cursor then return rejected(cursor_source,'no recent valid mouse position; point inside the game and retry') end
 local cursor_snapshot={x=cursor.x,y=cursor.y}
 local lp=position(leader)
 local ok,p,why,projection=pcall(Orders.ground_point,cursor,lp)
 if not ok then return rejected('projection_error',tostring(p)) end
 if not p then return rejected(why,'cursor ground projection is unavailable',projection) end
 if M.core.distance(lp,p)>80 then return rejected('out_of_range','cursor ground point is too far away') end
 local riding=mobility.driver(mobility.root(leader))
 if riding then return vehicles.redirect(s,p,riding) end
 local terminal,objective_scan=objectives.find(s,p)
 event('f8_target_resolved',{cursor=cursor_snapshot,position=p,leader=lp,projection=projection,
  cursor_source=cursor_source,target=terminal and tostring(terminal),scan=objective_scan},bot.id)
 if terminal then
  local reply,assigned=objectives.request(s,p,bot)
  local task=objectives.tasks[terminal];local owner=task and task.owner
  if assigned and M.tactics then M.tactics.detach(owner or bot,'explicit_objective_order') end
  if assigned then M.order_cursor=owner and owner.id or bot.id end
  event('f8_order_result',{intent='objective',accepted=assigned==true,reply=reply,assigned_bot=owner and owner.id},bot.id)
  return reply
 end
 local reply,assigned=vehicles.redirect(s,p,bot)
 if reply then if assigned then M.order_cursor=bot.id end;return reply end
 local reply,assigned=vehicles.request(s,p,bot)
 if reply then if assigned then M.order_cursor=bot.id;if M.tactics then M.tactics.detach(bot,'explicit_vehicle_order') end end;return reply end
 if M.tactics then M.tactics.detach(bot,'explicit_guard_order') end
 vehicles.release(bot,'ground_order',true)
 M.cancel_guard(bot);objectives.release(bot,'reassigned')
 Behaviors.release(M.behaviors,bot,'guard_order',M.clock,event);support.cancel(bot)
 M.order_sequence=M.order_sequence+1
 local request={sequence=M.order_sequence,generation=M.generation,session=s,expires=M.clock+8,point={x=p.x,y=p.y,z=p.z}}
 bot.guard_request=request;bot.order_sequence=request.sequence;M.formation_dirty=true
 local callback={squad_owner=M}
 local function fail(reason)
  if bot.guard_request~=request then return end
  bot.guard_request=nil;M.formation_dirty=true
  event('guard_rejected',{reason=reason},bot.id)
 end
 local function approved(_,unit,path,pos)
  -- Native ignore_spawn previews terrain only. No pod or character is created.
  if unit~=nil then
   if alive(unit) then s.entity_spawner:despawn_entity(unit) end
   fail('ground_preview_returned_unit');return
  end
  if bot.guard_request~=request or not M.enabled or not eligible(bot)
    or M.generation~=request.generation or M.session~=s then
   if M.order_inheritance and M.enabled and M.generation==request.generation and M.session==s then M.order_inheritance.ground_ready(request,pos) end
   return
  end
  bot.guard_request=nil;bot.post={x=pos.x,y=pos.y,z=pos.z};M.formation_dirty=true
  bot.post_facing=M.core.direction(lp,bot.post);bot.controller={};bot.post_arrived=false;bot.returning=nil
  Orders.show(M.orders,bot.id,bot.post,M.clock)
  event('guard_ordered',{position=bot.post,sequence=request.sequence,roam_radius=2},bot.id)
 end
 callback.on_entity_spawned=function(...)
  local ok,err=pcall(approved,...)
  if not ok then fail(tostring(err));event('guard_ground_error',{message=tostring(err)},bot.id,'errors') end
 end
 callback.on_entity_spawn_failed=function()fail('no_walkable_ground')end
 callback.on_entity_spawn_inside_screen_failed=callback.on_entity_spawn_failed
 local ok,err=pcall(s.spawn_manager.queue_spawn,s.spawn_manager,
  'characters/helldiver_private_01/helldiver_private_01',Vector3(p.x,p.y,p.z),nil,
  callback,request,nil,true,nil,nil,true,1,true)
 if not ok then fail(tostring(err));return 'Guard ground check failed' end
 request.callback=callback
 M.order_cursor=bot.id
 event('guard_requested',{position=p,sequence=request.sequence,projection=projection,cursor_source=cursor_source,objective_scan=objective_scan},bot.id)
 return 'Bot '..bot.id..': checking cursor ground for guard post'
end
function M.request_follow(all)
 if all and M.order_inheritance then M.order_inheritance.clear('recalled') end
 local s,_,why=order_context();if not s then return why end
 local selected={}
 for _,b in ipairs(M.bots) do
  local h=state(b.unit,'health')
  if b.active and h and not h.is_dead and (all or b.post or b.guard_request or b.objective or b.vehicle_order or b.stratagem_intent or b.tactical_job) then selected[#selected+1]=b end
 end
 table.sort(selected,function(a,b)return (a.order_sequence or a.id)<(b.order_sequence or b.id) end)
 local count=all and #selected or math.min(1,#selected)
 for n=1,count do
  local b=selected[n];local request=b.guard_request
  if M.tactics then M.tactics.detach(b,'explicit_recall') end
  b.rejoin_epoch=(b.rejoin_epoch or 0)+1
   objectives.release(b,'recalled')
  if not vehicles.regroup(b) then vehicles.release(b,'recalled',true) end
  if request then
   local queue=s.spawn_manager.queued_spawns or {}
   for k=#queue,1,-1 do if queue[k].callback_object==request.callback then table.remove(queue,k) end end
  end
  b.post=nil;b.guard_request=nil;b.post_arrived=nil;b.controller={}
  b.returning=true;Orders.remove(M.orders,b.id)
  Behaviors.release(M.behaviors,b,'recall_order',M.clock,event)
  support.cancel(b)
  event('follow_ordered',{all=not not all},b.id)
 end
 M.formation_dirty=true
 if all then M.order_cursor=0;objectives.clear('recalled') end
 if count==0 then return 'All bots are already following' end
 return all and ('All '..count..' bots following') or ('Bot '..selected[1].id..': following')
end
function M.request_original()
 if not M.enabled then return 'Enable the squad controller before requesting a return' end
 local sm=Boot and Boot.state_machine;local s=sm and sm.state
 if not s or sm.current_state_name~='game' or s~=M.session then return 'Return needs the current solo mission' end
 local u=get_leader(s);if not u then return 'Waiting for a living controlled body' end
 return takeover.request(s,u)
end
function M.request_switch(home)
 if not M.enabled then return 'Enable the squad controller before switching' end
 local sm=Boot and Boot.state_machine;local s=sm and sm.state
 if not s or sm.current_state_name~='game' or s~=M.session then return 'Switch needs the current solo mission' end
 local u=get_leader(s);if not u then return 'Waiting for a living controlled body' end
 return home and takeover.home(s,u) or takeover.cycle(s,u)
end
local function dispatch(s,leader)
 if M.active_spawn or M.clock<(M.next_spawn or 0) then return end
 local q=M.waiting
 if q.first>q.last then return end
 local r=q.items[q.first]
 local p=M.core.drop_point(position(leader),r.id,occupants(s,leader),M.landings,r.attempts)
 if not p then
  M.next_spawn=M.clock+.5
  if M.clock>=(r.next_wait_log or 0) then event('landing_waiting_for_space',{},r.id);r.next_wait_log=M.clock+3 end
  return
 end
 q.items[q.first]=nil;q.first=q.first+1
 M.active_spawn=r;r.dispatched=M.clock;M.next_spawn=M.clock+.25
 local function failed(reason)
  if M.pending[r.id]~=r then return end
  finish_request(r);M.landings[r.id]=nil;event('spawn_failed',{reason=reason},r.id,'errors')
 end
 r.callback={squad_owner=M,on_entity_spawned=function(_,...)
   local ok,err=pcall(M.on_ground_checked,...)
   if not ok then failed(tostring(err)) end
  end,
  on_entity_spawn_failed=function()failed('no_safe_ground')end,
  on_entity_spawn_inside_screen_failed=function()failed('no_safe_onscreen_ground')end}
 M.landings[r.id]={id=r.id,position=p,radius=4.5,expires=M.clock+16}
 local ok,err=pcall(s.spawn_manager.queue_spawn,s.spawn_manager,
  'characters/helldiver_private_01/helldiver_private_01',
  Vector3(p.x,p.y,p.z),nil,r.callback,r,nil,true,nil,nil,true,1,true)
 if not ok then failed(tostring(err)) else event('deployment_dispatched',{},r.id) end
end
local function refresh_enemies(s)
 if M.clock<(M.next_enemy_scan or 0) then return end
 M.next_enemy_scan=M.clock+.25;local result={}
 for unit in pairs(Behaviors.entities(s,'enemy')) do
  local h=state(unit,'health')
  if h and not h.is_dead then result[#result+1]={id=unit,position=position(unit),alive=true,enemy=true} end
 end
 M.enemy_cache=result
end
local function query_visibility(bot,target,budget)
 if not alive(bot.unit) or not alive(target.id) then return end
 if bot.query or budget.rays<=0 or M.clock<bot.next_ray then return end
 local p=bot.combat_position or position(bot.unit);local t=position(target.id)
 local from=Vector3(p.x,p.y,p.z+.85);local delta=Vector3(t.x,t.y,t.z+.8)-from
 local length=Vector3.length(delta);if length<.1 then return end
 local mounted=bot.mounted or {}
 bot.query={target=target.id,generation=M.generation,from=p,to=t,seat=mounted.seat,vehicle=mounted.vehicle,gun=mounted.gun,weapons=mounted.weapons}
 bot.next_ray=M.clock+.15;budget.rays=budget.rays-1
 bot.visibility_pending.cast=true
 bot.ray:cast(from,Vector3.normalize(delta),length+1)
end
local function friend_grid()
 local grid={}
 for _,b in ipairs(M.bots) do
  local p=position(b.unit);b.frame_position=p
  local key=math.floor(p.x/4)..':'..math.floor(p.y/4)
  grid[key]=grid[key] or {};grid[key][#grid[key]+1]=b
 end
 return grid
end
local function firing_friends(bot,target,lp,grid,splash)
 local friends=M.waiting_for_player and {} or {lp};local p=bot.combat_position or bot.frame_position;local t=target.position
 for _,e in ipairs(M.behaviors.escorts) do friends[#friends+1]=e.position end
 local margin=math.max(1,(splash or 0)+1)
 for x=math.floor((math.min(p.x,t.x)-margin)/4),math.floor((math.max(p.x,t.x)+margin)/4) do
  for y=math.floor((math.min(p.y,t.y)-margin)/4),math.floor((math.max(p.y,t.y)+margin)/4) do
   for _,other in ipairs(grid[x..':'..y] or {}) do
    if other~=bot then friends[#friends+1]=other.frame_position end
   end
  end
 end
 return friends
end
local function nearby_friends(bot,lp,grid)
 local result=M.waiting_for_player and {} or {{id=0,position=lp}};local p=bot.frame_position
 for _,e in ipairs(M.behaviors.escorts) do
  if M.core.distance(p,e.position)<2 then result[#result+1]={position=e.position} end
 end
 local x,y=math.floor(p.x/4),math.floor(p.y/4)
 for a=x-1,x+1 do for b=y-1,y+1 do
  for _,other in ipairs(grid[a..':'..b] or {}) do
   if other~=bot and M.core.distance(p,other.frame_position)<1.6 then
    result[#result+1]={id=other.id,position=other.frame_position}
   end
  end
 end end
 return result
end
local function update_perimeter(lp)
 local followers={}
 for _,b in ipairs(M.bots) do
  local h=state(b.unit,'health') or {};local c=master(b.unit,'character') or {}
  if b.active and not h.is_dead and not h.is_downed and not b.post and not b.guard_request
    and not b.job and not b.objective and not b.stratagem_intent and not b.tactical_job and not c.current_seat_unit then
   followers[#followers+1]={id=b.id,position=b.frame_position}
  end
 end
 Perimeter.update(M.perimeter,followers,lp,M.behaviors.escorts,M.enemy_cache,M.clock,
  function(p)return Behaviors.risk(M.behaviors,p)end)
end
local function formation_slots()
 if not M.formation_dirty then return end
 local sorted={};for _,b in ipairs(M.bots) do if not b.post and not b.objective then sorted[#sorted+1]=b end end
 table.sort(sorted,function(a,b)return a.id<b.id end)
 for index,b in ipairs(sorted) do
  b.guard_offset,b.guard_ring,b.guard_radius=M.core.guard_slot(index,#sorted);b.guard_slot=index
 end
 M.formation_dirty=false
end
local function leader_motion(lp,dt)
 local m=M.leader_motion
 if not m then m={position=lp,heading={x=0,y=1},velocity={x=0,y=0},speed=0};M.leader_motion=m end
 if dt>0 then
  local dx,dy=lp.x-m.position.x,lp.y-m.position.y
  local speed=math.sqrt(dx*dx+dy*dy)/dt
  if speed<15 then
   local blend=1-math.exp(-dt/ .18)
   m.velocity={x=m.velocity.x+(dx/dt-m.velocity.x)*blend,y=m.velocity.y+(dy/dt-m.velocity.y)*blend}
   m.speed=math.sqrt(m.velocity.x*m.velocity.x+m.velocity.y*m.velocity.y)
   if m.speed>.4 then
    local h=M.core.direction({x=0,y=0},m.velocity)
    -- Rotate through reversals too; normalized linear blending stalls at 180 degrees.
    local angle=math.atan2(m.heading.x*h.y-m.heading.y*h.x,m.heading.x*h.x+m.heading.y*h.y)
    local turn=angle*(1-math.exp(-dt/ .25));local c,s=math.cos(turn),math.sin(turn)
    m.heading={x=m.heading.x*c-m.heading.y*s,y=m.heading.x*s+m.heading.y*c}
   end
  else m.velocity={x=0,y=0};m.speed=0 end
 end
 m.position=lp;return m
end
local function update_bot(bot,leader,lp,dt,grid,budget)
 if not bot.active or not alive(bot.unit) then return end
 local h=state(bot.unit,'health') or {};local p=bot.frame_position
 local inv=state(bot.unit,'inventory') or {};local w=inv.current_weapon
 bot.mounted=support.mounted(bot,leader);local mounted=bot.mounted
 if mounted then w=mounted.gun end
 bot.combat_position=alive(w) and mounted and position(w) or p
 local ammo,profile=Behaviors.weapon(w)
 if mounted and mounted.order then profile.range=vehicles.range(mounted) end
 local perimeter_goal,guard_look,protect,assignment=Perimeter.goal(M.perimeter,bot.id,M.clock)
 if bot.weapon~=w then
  if bot.weapon then M.weapon_owners[bot.weapon]=nil end
  bot.controller.trigger_time=0;bot.controller.cooling=nil
 end
 if w then M.weapon_owners[w]=bot end
 if bot.weapon==w and type(ammo.rounds)=='number' and type(bot.rounds)=='number' and ammo.rounds<bot.rounds then
  local rounds=bot.rounds-ammo.rounds;bot.shots=bot.shots+rounds;M.stats.shots=M.stats.shots+rounds
 end
 if ammo.is_reloading and not bot.reload_observed then
  bot.reloads=bot.reloads+1;M.stats.reloads=M.stats.reloads+1
  event('reload_started',{rounds=ammo.rounds,magazines=ammo.num_mags},bot.id)
 elseif bot.reload_observed and not ammo.is_reloading then
  event('reload_finished',{rounds=ammo.rounds,magazines=ammo.num_mags},bot.id)
 end
 bot.reload_observed=not not ammo.is_reloading;bot.weapon=w;bot.rounds=ammo.rounds
 if bot.target then
  local th=state(bot.target.id,'health')
  if not th or th.is_dead or M.core.distance(p,position(bot.target.id))>profile.range then bot.target=nil;bot.visibility=nil
  else bot.target.position=position(bot.target.id) end
 end
 if M.clock>=bot.next_scan and budget.scans>0 then
  local old=bot.target and bot.target.id
  -- The quarter-second enemy cache can outlive an enemy's native unit handle.
  -- Reject dead/despawned candidates before any native position call.
  repeat
   bot.target=M.core.choose_target(p,M.enemy_cache,old,profile.range,protect or lp)
   if not bot.target then break end
   local health=state(bot.target.id,'health')
   if health and not health.is_dead then break end
   bot.target.alive=false
   event('stale_target_rejected',{},bot.id,'behavior')
  until false
  bot.next_scan=M.clock+.3;budget.scans=budget.scans-1
  if old~=(bot.target and bot.target.id) then event('target_changed',{target=bot.target and tostring(bot.target.id) or 'none'},bot.id,'behavior') end
 end
 if bot.target then bot.target.position=position(bot.target.id);query_visibility(bot,bot.target,budget) end
 local sight=bot.visibility
 local visible=bot.target and sight and sight.target==bot.target.id and sight.clear
   and M.clock-sight.time<.35 and M.core.distance(bot.combat_position,sight.from)<.6 and M.core.distance(bot.target.position,sight.to)<.9
 local motion=M.leader_motion or {speed=0,velocity={x=0,y=0}}
 local danger,danger_kind=Behaviors.danger(M.behaviors,p,bot.unit)
 local objective_job=vehicles.job(bot,leader,lp,budget) or objectives.job(bot,p,danger)
 local tactical_job=M.tactics and M.tactics.job(bot,p,danger)
 if bot.objective then bot.objective.approach_changed=support.cancel end
 local job=Behaviors.update_job(M.behaviors,bot,leader,lp,M.clock,event) or objective_job or tactical_job
 local task_key=job and (job.key..':'..tostring(job.approach_index or 0))
 if bot.route_task~=task_key then support.cancel(bot);bot.route_task=task_key end
 local offset=bot.guard_offset or {x=0,y=3.6}
 local goal=(job and job.position) or bot.post or perimeter_goal or {x=lp.x+offset.x,y=lp.y+offset.y,z=lp.z}
 if not mounted then goal=vehicles.goal(bot,p,goal) end
 local protected=not job and not bot.post and protect or lp
 if bot.returning and not job and M.core.distance(p,goal)<1.5 then bot.returning=nil end
 if bot.post and M.core.distance(p,bot.post)<.9 then bot.post_arrived=true end
 local intent=bot.stratagem_intent
 local preparing=intent and intent.ticket.state=='reserved' and 'stratagem:'..intent.ticket.serial
 local zones={};for id,zone in pairs(M.landings) do if id~=bot.id and id~=preparing then zones[#zones+1]=zone end end
 local friends=bot.target and visible and firing_friends(bot,bot.target,lp,grid,profile.splash) or (M.waiting_for_player and {} or {lp})
 local character=master(bot.unit,'character') or {}
 local forward
 if mounted and alive(w) then
  forward=Quaternion.forward(Unit.world_rotation(w,Unit.node(w,mounted.info.rotation_node or 'root')))
 else forward=Quaternion.forward(Unit.world_rotation(bot.unit,0)) end
 local facing=M.core.direction({x=0,y=0},forward)
 local native_sprinting=character.sprint_state=='sprint_in' or character.sprint_state=='sprint' or character.sprint_state=='sprint_out'
 local obstacles=bot.obstacles
 if obstacles and (M.clock-obstacles.time>.6 or M.core.distance(p,obstacles.from)>.8) then obstacles=nil end
 local previous_position=bot.last_position
 local moved=previous_position and M.core.distance(p,previous_position) or 0
 if bot.last_position and dt>0 and moved/dt<15 then
  bot.velocity={x=(p.x-bot.last_position.x)/dt,y=(p.y-bot.last_position.y)/dt}
 else bot.velocity=nil end
 bot.distance_moved=bot.distance_moved+moved;bot.last_position=p
 -- Use net displacement: collision jitter can travel back and forth without
 -- getting anywhere, and must not continually reset obstacle recovery.
 if bot.was_moving and not h.is_downed and not ammo.is_reloading and not mounted then
  bot.progress_origin=bot.progress_origin or previous_position or p
  bot.progress_time=(bot.progress_time or 0)+dt;bot.progress_distance=(bot.progress_distance or 0)+moved
  if bot.progress_time>=.4 then
   bot.observed_speed=M.core.distance(p,bot.progress_origin)/bot.progress_time
   bot.stuck_seconds=bot.observed_speed<.18 and (bot.stuck_seconds+bot.progress_time) or 0
   bot.progress_time=0;bot.progress_distance=0;bot.progress_origin=nil
  end
 elseif not (bot.route and bot.route.status=='planning') then bot.progress_time=0;bot.progress_distance=0;bot.progress_origin=nil;bot.stuck_seconds=0 end
 local follow_goal=goal;local route_wait=bot.rejoin_probe~=nil or bot.rejoin_commit~=nil
 if not mounted and not h.is_downed and not danger and not route_wait then goal,route_wait=support.navigate(bot,p,goal,budget,not job and not bot.post) end
 local interactor=master(bot.unit,'interactor') or {}
 local interaction_near=job and M.core.distance(p,job.target_position or job.position)<=(job.kind=='revive' and 1.25 or 1.1)
 local ready=interaction_near and not job.no_interaction and not job.defending and not danger and not h.is_downed and support.interaction_ready(bot,p,job,budget)
 local native_interaction=CharacterStateInteract and character.current_state==CharacterStateInteract
 local objective=job and job.kind=='objective'
 local interacting=interactor.busy or native_interaction or (objective and job.operating)
   or (not objective and interaction_near and not job.no_interaction and not job.approach_blocked)
 if ready and not job.no_interaction then
  if objective then objectives.interact(bot,job,M.clock) else Behaviors.interact(bot,job,M.clock,event) end
 end
 if not mounted then route_wait=M.rejoin.foot(bot,lp,follow_goal,budget,job,interacting,danger,visible) or route_wait end
 if not mounted and bot.rejoin_commit then bot.release_permitted=false;neutral(bot.unit);return end
 if not mounted and bot.relocated_at==M.clock then neutral(bot.unit);return end
 local dry=Behaviors.dry(ammo)
 local input,mode=M.core.decide({alive=true,downed=h.is_downed,leader=protected,leader_alive=true,
   id=bot.id,dt=dt,memory=bot.controller,position=bot.combat_position,goal=goal,ammo=ammo,profile=profile,dry=dry,
   target=bot.target,visible=visible,friends=friends,seated=mounted~=nil,
   task=job~=nil and not (objective and job.defending and job.objective and job.objective.missile),task_kind=job and job.kind,route_wait=route_wait,interacting=interacting,
   checked_route=bot.route and bot.route.status=='ready',
   approach=job~=nil and not job.defending and not job.operating,
   interaction_aim=not objective and job and M.core.direction(p,job.target_position or job.position),
   danger=not mounted and danger,danger_kind=danger_kind,
   guard=true,guard_radius=assignment and assignment.radius or bot.guard_radius,landing_zones=zones,
   perimeter=not job and not bot.post and assignment~=nil,guard_look=not job and not bot.post and guard_look,
   hold=(bot.post~=nil and not job) or (objective and job.defending),hold_arrived=bot.post_arrived or (objective and job.defending and M.core.distance(p,goal)<1.2),hold_facing=bot.post_facing,
   catchup=bot.catchup,order_travel=bot.catchup or objective or tactical_job~=nil or (not job and (bot.returning or (bot.post~=nil and not bot.post_arrived))),
   facing=facing,native_sprinting=native_sprinting,stamina=character.sprint_stamina,leader_speed=motion.speed,
   neighbors=nearby_friends(bot,lp,grid),obstacles=obstacles,stuck_seconds=bot.stuck_seconds})
 if objective then input=objectives.input(bot,job,p,input) end
 bot.release_permitted=input.fire==true
 input.fire,input.fire_auto=Behaviors.trigger(ammo,profile,bot.controller,dt,bot.release_permitted)
 if not mounted and not h.is_downed and not interacting and not danger then
  if dry and alive(inv.sidearm_weapon) and inv.sidearm_weapon~=w and not Behaviors.dry(Behaviors.weapon(inv.sidearm_weapon)) then
   input.switch_weapon='switch_to_sidearm';input.melee=false
  elseif w==inv.sidearm_weapon and alive(inv.primary_weapon) and not Behaviors.dry(Behaviors.weapon(inv.primary_weapon)) then
   input.switch_weapon='switch_to_primary'
  end
 end
 if not mounted and not h.is_downed then
  if M.tactics then input=M.tactics.guarded_input(bot,p,input,danger,budget) end
  if M.grenades then input=M.grenades.input(bot,p,input,danger,budget) end
  if M.equipment then input=M.equipment.input(bot,p,input,danger,budget) end
  query_navigation(bot,bot.controller.wanted_movement,budget)
  bot.job_goal=job and job.position
  if not route_wait then support.ground_guard(bot,p,input,budget,job and (job.kind=='revive' or (objective and not job.objective.surface_offset and not job.cursor_approach)) and job.unit or nil) end
 end
 local moving=input.movement.x~=0 or input.movement.y~=0
 if not mounted then M.rejoin.contact(bot,p,dt,input.movement) end
 local wanted=bot.controller.wanted_movement or {}
 bot.was_moving=not interacting and not route_wait and ((wanted.x or 0)^2+(wanted.y or 0)^2)>.01
 if moving then M.stats.steps=M.stats.steps+1 end
 if bot.mode~=mode and M.clock>=(bot.next_mode_log or 0) then
  event('mode_changed',{from=bot.mode,to=mode},bot.id,'behavior');bot.next_mode_log=M.clock+.5
 end
 bot.mode=mode
 if h.hitpoints~=bot.health then event('health_changed',{from=bot.health,to=h.hitpoints,downed=h.is_downed},bot.id);bot.health=h.hitpoints end
 if M.clock>=bot.next_sample and budget.samples>0 then
  event('snapshot',{position=p,health=h.hitpoints,downed=h.is_downed,mode=mode,
   leader_distance=M.core.distance(p,lp),target=bot.target and tostring(bot.target.id) or 'none',
   line_of_sight=not not visible,fire_requested=input.fire,reload_requested=input.reload,
   sprint_requested=input.sprint,native_sprinting=native_sprinting,stamina=character.sprint_stamina,
   facing=facing,aim_dot=bot.controller.aim_dot,aim_seconds=bot.controller.aim_time,
   movement=input.movement,goal=goal,observed_speed=bot.observed_speed,
   formation=bot.post and 'guard_post' or 'perimeter',task=job and job.kind,route=bot.route and bot.route.status,
   protect=not job and assignment and assignment.kind,protect_center=protected,
   guard_sector=assignment and assignment.sector,interaction_attempted=job and job.attempted,
   interaction_check=bot.interaction_check and bot.interaction_check.reason,
   weapon_kind=profile.kind,seated=mounted~=nil,vehicle=mounted and bot.vehicle_status,order=bot.post and 'guard' or (bot.guard_request and 'guard_pending' or 'follow'),
   post=bot.post,post_arrived=bot.post_arrived,returning=bot.returning,formation_slot=bot.guard_slot,formation_ring=bot.guard_ring,squad_count=#M.bots,
   obstacles=obstacles and {front=obstacles.front,left=obstacles.left,right=obstacles.right} or nil,
   rounds=ammo.rounds,magazines=ammo.num_mags,is_reloading=ammo.is_reloading,
   rounds_consumed=bot.shots,reloads=bot.reloads,distance_moved=bot.distance_moved,stuck_seconds=bot.stuck_seconds},bot.id,'behavior')
  bot.next_sample=M.clock+2;budget.samples=budget.samples-1
 end
 if mounted then
  input=vehicles.apply(bot,mounted,input,leader,lp,dt,budget)
  if not mounted.keep or bot.post or bot.guard_request or h.is_downed then input=M.core.neutral() end
  if not mounted.pilot then input.movement={x=0,y=0,z=0} end
  input.dodge=false;input.melee=false;input.switch_weapon=false
  if not mounted.order then local field=mounted.info.fire_input_field or 'fire_auto';input[field]=input.fire_auto end
  bot.vehicle_input.output_table=input
  if mounted.pilot then
   local ok,err=pcall(navtrace.vehicle,bot,mounted,lp,input)
   if not ok and M.clock>=(bot.next_trace_error or 0) then
    bot.next_trace_error=M.clock+5;event('navigation_diagnostic_error',{message=tostring(err)},bot.id,'errors')
   end
  end
  command(bot.unit,'character','input',M.core.neutral())
 else
  command(bot.unit,'mover','set_movement',input.movement);command(bot.unit,'character','input',input)
 end
end
function M.tick(s,dt)
 if not M.enabled then return end
 local pause=rawget(_G,'HelldiversOfflinePause');if pause and (pause.held and pause.session==s or pause.frame_hold and pause.frame_session==s) then return end
 dt=math.max(0,math.min(tonumber(dt) or 0,1));M.clock=M.clock+dt;M.heartbeat=M.heartbeat+dt
 if M.heartbeat>20 then M.disable('controller_heartbeat_expired');return end
 session(s)
 takeover.tick(s)
 camera.install()
 display.install()
 for id,zone in pairs(M.landings) do if M.clock>zone.expires then M.landings[id]=nil end end
 if not s.is_server or not s.generated_level or s.wants_exit then
  if #M.bots>0 or M.pending_count>0 then M.cleanup('leaving_supported_mission',s) end
  return
 end
 local leader,record,reason=get_leader(s)
 local respawning=record and (s.infinite_respawns or (tonumber(record.extra_lives) or 0)>0
   or record.is_respawning==true or (tonumber(record.spawn_timer) or 0)>0)
 local waiting=not leader and record and reason~='Player extracted' and respawning and s.game_state~='game_over'
 local lp=leader and position(leader) or M.player_anchor
 if not leader and not (waiting and lp) then
  if #M.bots>0 or M.pending_count>0 then M.cleanup(reason,s) end
  M.message=reason;return
 end
 if (not not waiting)~=(not not M.waiting_for_player) then
  event(waiting and 'player_respawn_wait' or 'player_returned',{extra_lives=record.extra_lives})
 end
 M.waiting_for_player=not not waiting
 M.player_anchor=lp;leader_motion(lp,dt)
 mobility.install();extraction.install();extraction.tick();mobility.tick(leader,lp)
 if M.companion then M.companion.bikes(leader) end
 if M.action_safety then M.action_safety.install() end
 if leader then
  if M.companion then M.companion.auto(s,leader,record)
  elseif M.auto_deploy and not M.spawn_attempted then M.spawn_attempted=true;enqueue(s,leader,record) end
  dispatch(s,leader)
 end
 if M.active_spawn and M.clock-M.active_spawn.dispatched>15 then
  local req=M.active_spawn;finish_request(req);M.landings[req.id]=nil
  local queue=s.spawn_manager.queued_spawns or {}
  for n=#queue,1,-1 do if queue[n].callback_object==req.callback then table.remove(queue,n) end end
  event('spawn_timeout',{},req.id,'errors')
 end
 for n=#M.bots,1,-1 do
  local b=M.bots[n];local h=state(b.unit,'health')
  if not alive(b.unit) or (h and h.is_dead) then remove_bot(b,'died') end
  if b.guard_request and M.clock>b.guard_request.expires then
   b.guard_request=nil;M.formation_dirty=true;event('guard_rejected',{reason='ground_check_timeout'},b.id)
  end
 end
 for unit in pairs(M.retired) do if not alive(unit) then
  local body=M.dead_bodies[unit]
  if body then event('body_removed',{corpse_seconds=M.clock-body.started},body.bot and body.bot.id) end
  M.retired[unit]=nil;M.dead_bodies[unit]=nil
 end end
 for n=#M.ray_retention,1,-1 do
  local r=M.ray_retention[n]
  if r.session~=s or not next(r.pending) then table.remove(M.ray_retention,n) end
 end
 objectives.tick(s)
 if M.order_inheritance then M.order_inheritance.tick() end
 Orders.draw(M.orders,s.world_proxy:get_world(),M.clock,event)
 if #M.bots==0 then return end
 formation_slots()
 refresh_enemies(s)
 local grid=friend_grid()
 Behaviors.scan(M.behaviors,s,leader,lp,M.bots,M.clock)
 vehicles.scan(s,dt)
 if vehicles.policy then vehicles.policy.tick(leader,lp) end
 if M.tactics then
  local ok,err=pcall(M.tactics.tick,s,leader,lp)
  if not ok then M.tactics.fail(err) end
 end
 if M.grenades then M.grenades.install();M.grenades.tick() end
 if M.equipment then M.equipment.tick() end
 Behaviors.assign(M.behaviors,M.bots,leader,lp,M.clock,event,M.enemy_cache)
 update_perimeter(lp)
 local budget={scans=4,rays=4,navigation=12,route=20,samples=4};local count=#M.bots
 if count==0 then return end
 M.scan_cursor=((M.scan_cursor or 0)%count)+1
 local updated={};local control_epoch=M.control_epoch or 0
 -- Finish bounded recovery checks before ordinary navigation spends the ray budget.
 -- The rotating cursor remains the tie breaker within each group.
 for pass=1,2 do for offset=0,count-1 do
  local bot=M.bots[((M.scan_cursor+offset-1)%count)+1]
  if (M.control_epoch or 0)~=control_epoch or not bot then return end
  if not updated[bot] and ((bot.rejoin_probe~=nil)==(pass==1)) then
   updated[bot]=true
   local ok,err=pcall(update_bot,bot,leader,lp,dt,grid,budget)
   if not ok then event('bot_update_error',{message=tostring(err)},bot.id,'errors');bot.failed=true end
  end
 end end
 for n=#M.bots,1,-1 do if M.bots[n].failed then remove_bot(M.bots[n],'controller_failed') end end
end
hook('pre_update',function(old)
 return function(self,dt,...)
  local result=old(self,dt,...)
  if M.enabled then
   local ok,err=pcall(M.tick,self,dt)
   if not ok then M.last_error=tostring(err);event('runtime_error',{message=tostring(err)},nil,'errors');M.disable('runtime_error') end
  end
  return result
 end
end)
hook('on_player_death',function(old)
 local function native_death(self,unit,...)
  if self~=M.session or not takeover.is_body(unit) then return old(self,unit,...) end
  -- Native death still owns respawn/life spending; a companion body adds no score.
  local deaths=self.player_deaths
  local ok,err=pcall(old,self,unit,...)
  self.player_deaths=deaths
  if not ok then error(err,0) end
 end
 takeover.native_death=native_death
 return function(self,unit,...)
  local ok,handled=pcall(takeover.death,self,unit)
  if ok and handled then return end
  if not ok then event('takeover_error',{message=tostring(handled)},nil,'errors') end
  local bot=M.units[unit]
  if bot or M.retired[unit] then
   if bot then
    if self==M.session and takeover.is_original_body(unit) then
     local h=state(unit,'health')
     if h and h.is_dead then takeover.count_death(self,unit);takeover.handled[unit]=true end
    end
    event('death_event',{},bot.id)
   end
   return
  end
  if M.session==self and alive(unit) then
   for _,p in ipairs(self.players or {}) do
    local go=p.player_go
    if go and go:exists() and go:owned() and go:has('avatar_unit') and go:get('avatar_unit')==unit then
     M.player_anchor=position(unit);break
    end
   end
  end
  return native_death(self,unit,...)
 end
end)
hook('on_exit',function(old)
 return function(self,...)
  if M.session==self then
   local ok,err=pcall(M.cleanup,'mission_ended',self)
   if not ok then M.last_error=tostring(err);event('exit_cleanup_error',{message=tostring(err)},nil,'errors') end
   -- Native on_exit destroys the world. No drawing handle may survive it.
   Orders.release(M.orders)
   if M.tactics then M.tactics.end_session(self) end
   M.session=nil;M.spawn_attempted=false
  end
  return old(self,...)
 end
end)
function M.uninstall()
 if M.equipment then M.equipment.uninstall() end
 mobility.uninstall();extraction.uninstall()
 if M.action_safety then M.action_safety.uninstall() end
 if M.grenades then M.grenades.uninstall() end
 if M.tactics then M.tactics.uninstall() end
 if M.stratagem_families then M.stratagem_families.uninstall() end
 loadouts.uninstall()
 M.disable('unloaded')
 objectives.uninstall()
 vehicles.uninstall()
 support.uninstall()
 camera.uninstall()
 display.uninstall()
 Orders.uninstall(M)
 for key,h in pairs(M.hooks) do if StateGame[key]==h.wrapper then StateGame[key]=h.original end end
 M.hooks={};return M.status()
end
M.heartbeat=0
if config.enabled then
 if not M.enabled then M.enabled=true;M.last_error=nil;event('enabled',{count_limit='none'}) end
else M.disable('disabled') end
return M.status()
