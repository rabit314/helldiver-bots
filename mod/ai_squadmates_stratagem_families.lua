-- Native effect descriptions. Unknown child effects never become guessed radii.
return function(M,C,B,S,V,P,emit)
 if M.stratagem_families then return M.stratagem_families end
 local F={owned=setmetatable({}, {__mode='k'}),hooks={},tags={},blocked=setmetatable({}, {__mode='k'})};M.stratagem_families=F
 for name,policy in pairs(P.policies) do
  if policy.kind=='special' then
   policy.enabled=false;policy.reason='Mission-specific stratagems are reserved for manual use'
  else policy.enabled=true;policy.reason=nil end
 end
 P.policies.stratagem_metaldetector.role='weapon'
 local function live(u)return u~=nil and type(u)~='boolean' and Unit.alive(u)end
 local function pos(u)if live(u) then return P.point(Unit.world_position(u,0))end end
 local function state(u,n)
  if not live(u) then return {} end
  if EntityAux.has_component_master(u,n) then return EntityAux.state_master(u,n) or {} end
  if EntityAux.has_component(u,n) then return EntityAux.state(u,n) or {} end
  return {}
 end
 function F.settings(path,upgrade)
  if not path or not LuaSettingsManager or type(LuaSettingsManager.get_modified_settings)~='function' then return end
  local ok,v=pcall(LuaSettingsManager.get_modified_settings,LuaSettingsManager,path,upgrade or 0)
  if ok and type(v)=='table' then return v end
 end
 local function positive(n)return P.finite(n) and n>=0 end
 function F.explosion(cfg,upgrade,depth)
  if not cfg or (depth or 0)>4 then return end
  local e=cfg.explosive_info;local field=cfg.field_info
  if not e or not positive(e.blast_radius) then return end
  local radius=e.blast_radius;local duration=0
  if field then
   if not positive(field.time_until_end) then return end
   duration=field.time_until_end+(field.time_until_activation or 0)
  end
  local child=e.on_explode_unit_path or e.on_explode_spawn_unit_path
  if child then
   local r,d=F.explosion(F.settings(child,upgrade),upgrade,(depth or 0)+1)
   if not r then return end
   radius=math.max(radius,r);duration=duration+d
  end
  return radius,duration
 end
 local original_envelope=P.envelope
 function P.envelope(info,cfg)
  if not info or not cfg then return nil,'settings_unavailable' end
  local a=cfg.airstrike_info
  if a then
   local radius,duration=F.explosion(cfg,info.upgrade_value)
   if not radius or not positive(a.bomb_area_length) or not positive(a.num_bombs) or a.num_bombs<1
    or not positive(a.time_until_bombs) or not positive(a.time_between_bombs_max or 0) then return nil,'complete_bomb_settings_unknown' end
   local spread=math.max(math.abs(a.bomb_position_offset_min or 0),math.abs(a.bomb_position_offset_max or 0))
   local start=-a.bomb_area_length/2;local finish=start+a.bomb_area_length/a.num_bombs*(a.num_bombs-1)
   local width=radius+spread+2
   return {radius=math.max(math.abs(start),math.abs(finish))+width,duration=math.max(15,a.time_until_bombs+(a.num_bombs-1)*(a.time_between_bombs_max or 0)+duration+2),
    first=a.time_until_bombs,blast=radius,kind='strike',support=false,start=start,finish=finish,width=width,
    rotation=(cfg.stratagem_info or {}).rotation_offset or 0,random=(cfg.stratagem_info or {}).random_rotation,persistent=duration>0}
  end
  local s=cfg.strafingrun_info
  if s then
   local w=cfg.weapon_info;local radius=0
   if not w or not positive(w.spread) or not positive(s.distance) or not positive(s.duration)
    or not P.finite(s.length_start) or not P.finite(s.length_end) then return nil,'complete_strafing_settings_unknown' end
   if cfg.explosive_info then radius=F.explosion(cfg,info.upgrade_value);if not radius then return nil,'strafing_secondary_unknown' end end
   -- Complete travel line plus the full ground-ray distance and spread cone.
   local width=(s.weapon_separation or 0)*(s.weapons or 1)+s.distance*math.tan(math.rad(w.spread))+radius+2
   local length=math.max(math.abs(s.length_start),math.abs(s.length_end))+s.distance
   for _,spawn in ipairs(cfg.spawn_unit_info or {}) do
    local child=F.settings(spawn.unit_path,info.upgrade_value);local r=F.explosion(child,info.upgrade_value)
    if not r or type(spawn.offset)~='table' then return nil,'strafing_secondary_effect_unknown' end
    local x,y=spawn.offset[1],spawn.offset[2]
    if not P.finite(x) or not P.finite(y) then return nil,'strafing_secondary_offset_unknown' end
    width=math.max(width,math.abs(x)+s.distance+r+2);length=math.max(length,math.abs(y)+s.distance+r+2)
   end
   return {radius=length+width,duration=(s.flyby_delay or 0)+s.duration+3,first=s.flyby_delay or 0,blast=radius,
    start=-length,finish=length,width=width,rotation=(cfg.stratagem_info or {}).rotation_offset or 0,kind='strike',support=false}
  end
  local artillery=cfg.artillery_info
  if artillery then
   local child=F.settings(artillery.artillery_unit_path,info.upgrade_value)
   local radius,duration=F.explosion(child,info.upgrade_value)
   if not radius or not positive(artillery.diameter) or not positive(artillery.duration) then return nil,'complete_artillery_settings_unknown' end
   local tail=(artillery.salvo_rounds or 1)*((artillery.bomb_interval or 0)+math.abs(artillery.bomb_interval_offset or 0))
   return {radius=artillery.diameter/2+radius+2,duration=artillery.duration+duration+tail+(artillery.salvo_incoming_trigger_time or 0)+3,
    first=artillery.salvo_incoming_trigger_time or 0,blast=radius,kind='strike',support=false,persistent=duration>0}
  end
  local targeted=cfg.targeted_strike_info
  if targeted then
   local radius,duration=0,0
   if type(targeted.units_to_spawn)~='table' then return nil,'targeted_sequence_unknown' end
   for _,unit in ipairs(targeted.units_to_spawn) do
    local child=F.settings(unit.unit_path,info.upgrade_value)
    local r,d=F.explosion(child,info.upgrade_value)
    if not r then return nil,'targeted_child_effect_unknown' end
    radius=math.max(radius,r+(unit.offset_max or 0)+(targeted.target_radius or 0))
    duration=math.max(duration,(unit.delay or 0)+(unit.follow_time or 0)+d)
   end
   return {radius=radius+2,duration=duration+(targeted.removal_time or 0)+3,blast=radius,kind='strike',support=false,targeted=true}
  end
  local mines=cfg.minedrop_info
  if mines then
   local child=mines.mine_unit_path and F.settings(mines.mine_unit_path,info.upgrade_value) or cfg
   local radius=F.explosion(child,info.upgrade_value)
   if not radius or not positive(mines.mine_area_length) or not positive(mines.num_mines) then return nil,'mine_or_barrier_effect_unknown' end
   return {radius=mines.mine_area_length/2+(mines.mine_position_offset_max or 0)+radius+2,duration=20,
    first=mines.time_until_mines or 0,blast=radius,kind='field',support=false,persistent=true,unbounded=true}
  end
  if cfg.field_info then
   local radius,duration=F.explosion(cfg,info.upgrade_value)
   if not radius then return nil,'persistent_field_settings_unknown' end
   return {radius=radius+2,duration=duration+3,blast=radius,first=cfg.field_info.time_until_activation or 0,kind='field',support=false,persistent=true}
  end
  if info.stratagem_type=='offensive' then
   local radius,duration=F.explosion(cfg,info.upgrade_value)
   if radius then return {radius=radius+2,blast=radius,duration=math.max(3,duration+3),kind='strike',support=false,persistent=duration>0} end
   return nil,'native_attack_adapter_settings_unknown'
  end
  local envelope,reason=original_envelope(info,cfg)
  if envelope and cfg.tesla_info then
   local t=cfg.tesla_info
   if not positive(t.range) then return nil,'tesla_range_unknown' end
   envelope.radius=math.max(envelope.radius,t.range+3);envelope.persistent=true;envelope.unbounded=true
  end
  return envelope,reason
 end
 local original_intersects=P.intersects
 local function point_distance(p,a,b)
  local dx,dy=b.x-a.x,b.y-a.y;local l=dx*dx+dy*dy
  local t=l>0 and math.max(0,math.min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/l)) or 0
  return P.distance(p,{x=a.x+t*dx,y=a.y+t*dy})
 end
 local function cross(a,b,c)return (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)end
 function F.segment_distance(a,b,c,d)
  if cross(a,b,c)*cross(a,b,d)<0 and cross(c,d,a)*cross(c,d,b)<0 then return 0 end
  return math.min(point_distance(a,c,d),point_distance(b,c,d),point_distance(c,a,b),point_distance(d,a,b))
 end
 function F.zone(t,position)
  local e=t.cap.envelope;local zone={position=position or t.position,radius=e.radius,support=e.support,prediction=.75,blast=e.blast,persistent=e.persistent}
  if e.start and not e.random and t.staging then
   local dir=t.throw_direction or P.direction(t.staging,t.position);local angle=e.rotation or 0
   local x,y=dir.x*math.cos(angle)-dir.y*math.sin(angle),dir.x*math.sin(angle)+dir.y*math.cos(angle)
   zone.a={x=zone.position.x+x*e.start,y=zone.position.y+y*e.start}
   zone.b={x=zone.position.x+x*e.finish,y=zone.position.y+y*e.finish};zone.width=e.width
  end
  return zone
 end
 function P.intersects(zone,actor,horizon,allies)
  if not zone.a then return original_intersects(zone,actor,horizon,allies) end
  if not actor or not actor.position or not allies and not actor.protected then return false end
  local dt=math.max(0,math.min(horizon or 0,zone.prediction or math.huge));local v=actor.velocity or {}
  local q={x=actor.position.x+(v.x or 0)*dt,y=actor.position.y+(v.y or 0)*dt}
  return F.segment_distance(actor.position,q,zone.a,zone.b)<=zone.width+(actor.radius or .8)+(actor.uncertainty or .5)+math.min(3,dt*.15)
 end
 function F.safe(t,T)
  local e=t.cap.envelope;if not e.persistent or t.cap.policy.role=='smoke' then return true end
  local z=F.zone(t);z.prediction=e.duration
  for _,a in ipairs(T.actors) do
   if P.intersects(z,a,math.min(e.duration,4),true) then return false,'persistent_friendly_route' end
   if M.player_anchor and a.unit~=t.bot.unit then
    local route={position=a.position,velocity={x=M.player_anchor.x-a.position.x,y=M.player_anchor.y-a.position.y},radius=a.radius}
    z.prediction=1;if P.intersects(z,route,1,true) then return false,'persistent_return_corridor' end
   end
  end
  for _,b in ipairs(M.bots) do local goal=b.post or b.objective and pos(b.objective.unit) or b.job and b.job.position
   local p=pos(b.unit)
   if goal and p then z.prediction=1
    if P.intersects(z,{position=p,velocity={x=goal.x-p.x,y=goal.y-p.y},radius=1},1,true) then return false,'persistent_assigned_route' end
   end
  end
  return true
 end
 function F.benefit(b,cap,pressure,targets)
  local role=cap.policy.role
  if role~='strike' and role~='weapon' and role~='backpack' then
   for _,t in ipairs(M.tactics.pending) do if not t.finished and t.phase~='cancelled' and t.cap.name==cap.name then return 0 end end
  end
  if role=='field' or role=='denial' then
   if pressure<3 then return 0 end
   local target,best
   for _,e in ipairs(targets) do if not best or e.weight>best then target=e;best=e.weight end end
   return target and math.min(8,pressure) or 0,target
  end
  if role=='turret' then return pressure>=3 and math.min(8,pressure) or 0 end
  if role=='smoke' or role=='lure' then
   local motion=M.leader_motion;local retreat=motion and motion.speed>1
   for _,a in ipairs(M.tactics.actors) do if state(a.unit,'health').is_downed then retreat=true end end
   return retreat and pressure>=2 and 5 or 0,targets[1]
  end
  if role=='recon' then
   local s=M.session;local count=0
   for _,component in ipairs({'objective_interact_object','objective_destroy_object','hidden_sweep_object'}) do
    for u in pairs(B.entities(s,component)) do local a=state(u,component)
     if a.revealed~=true and a.mission_state~='complete' and a.mission_state~='failed' then count=count+1 end
    end
   end
   return count>0 and pressure==0 and 4 or 0
  end
  if role=='objective' and cap.name=='stratagem_hellbomb' then
   for u in pairs(B.entities(M.session,'objective_destroy_object')) do local a=state(u,'objective_destroy_object');local h=state(u,'health')
    local armor=h.armor_min or (h.health_info or {}).armor_min;local point=pos(u)
    if point and P.finite(armor) and armor>=3 and not h.is_dead and a.mission_state~='complete' and a.mission_state~='failed'
     and P.distance(point,M.player_anchor)<30 then return 7,{unit=u,position=point,weight=7} end
   end
   return 0
  end
 end
 function F.track(t,u)
  if F.session==nil then F.session=M.session end
  if live(u) then F.owned[u]=t;t.native_units=t.native_units or setmetatable({}, {__mode='k'});t.native_units[u]=true end
 end
 function F.refresh()
  local T=M.tactics;if not T then return false end
  if T.refresh_actors then
   local leader
   for _,p in ipairs(M.session and M.session.players or {}) do local go=p.player_go
    if go and go:exists() and go:has('avatar_unit') then leader=go:get('avatar_unit');break end
   end
   if not pcall(T.refresh_actors,leader) then return false end
  end
  return not T.protected_unknown and not T.asset_unknown
 end
 function F.impact_safe(t,p)
  if not F.refresh() or not p or not t.cap.envelope then return false end
  local e=t.cap.envelope
  return P.safe({position=p,radius=(e.blast or e.radius)+2,prediction=math.min(e.duration or 1,4),persistent=true},M.tactics.actors,math.min(e.duration or 1,4))
 end
 function F.fire_safe(u,target)
  local T=M.tactics;local origin=pos(u);local point=pos(target)
  if T and T.refresh_actors then
   local leader
   for _,p in ipairs(M.session and M.session.players or {}) do local go=p.player_go
    if go and go:exists() and go:has('avatar_unit') then leader=go:get('avatar_unit');break end
   end
   local ok=pcall(T.refresh_actors,leader);if not ok then return false end
  end
  if not T or T.protected_unknown or T.asset_unknown or not origin or not point then return false end
  local cfg=LoadoutSettings and LoadoutSettings.get_upgraded_settings and LoadoutSettings.get_upgraded_settings(u)
  local w=cfg and cfg.weapon_info;if not w or not positive(w.range) then return false end
  local radius=0
  if w.projectile then
   radius=F.explosion(F.settings(w.projectile));if not radius then return false end
  elseif cfg.explosive_info then radius=F.explosion(cfg);if not radius then return false end end
  local dir=P.direction(origin,point);local forward=Quaternion.forward(Unit.world_rotation(u,0))
  local distance=math.max(P.distance(origin,point),w.range)
  local spread=math.tan(math.rad(tonumber(w.spread) or 0))*distance
  for _,a in ipairs(T.actors or {}) do if a.unit~=u then
   local margin=(a.radius or 1)+spread+1.2;local v=a.velocity or {}
   local q={x=a.position.x+(v.x or 0)*.75,y=a.position.y+(v.y or 0)*.75}
   for _,d in ipairs({dir,forward}) do
    if F.segment_distance(a.position,q,origin,{x=origin.x+d.x*distance,y=origin.y+d.y*distance})<margin then return false end
   end
   if radius>0 and P.distance(point,q)<radius+margin then return false end
  end end
  return true
 end
 local function hook(object,key,make)
  if type(object)~='table' or type(object[key])~='function' then return end
  F.hooks[object]=F.hooks[object] or {}
  if F.hooks[object][key] then return end
  local old=object[key];local wrapper=make(old);object[key]=wrapper
  F.hooks[object][key]={old=old,wrapper=wrapper}
 end
 function F.install()
  hook(rawget(_G,'PhysicsWorld'),'make_raycast',function(old)return function(world,callback,...)
   local t=F.context;local session=M.session;local generation=M.generation
   if t and type(callback)=='function' then
    local native=callback
    callback=function(...)
     if M.session~=session or M.generation~=generation then return end
     local hit,point=...
     if t.cap.envelope and t.cap.envelope.targeted and hit and not F.impact_safe(t,P.point(point)) then
      emit('stratagem_effect_held',{reason='targeted_impact_unsafe'},t.bot and t.bot.id);return
     end
     local previous=F.context;F.context=t
     local ok,result=pcall(native,...);F.context=previous
     if not ok then error(result,0) end;return result
    end
   end
   return old(world,callback,...)
  end end)
  hook(rawget(_G,'EntityAux'),'queue_command_master',function(old)return function(u,component,command,data,...)
   local t=F.context
   if t and type(data)=='table' and component=='inventory' then
    local tag='item:'..tostring(M.generation)..':'..tostring(t.ticket.serial)
    F.tags[tag]=t;data.__hd_squad_item=tag
   end
   return old(u,component,command,data,...)
  end end)
  hook(rawget(_G,'EntitySpawner'),'spawn_entity',function(old)return function(self,path,p,q,f,data,...)
   local A=M.stratagem_native;local t=F.context or A and A.delivery_context
   if not t and data and data.__hd_squad_delivery then local A=M.stratagem_native;t=A and A.deliveries[data.__hd_squad_delivery] end
   if t and data and data.__hd_squad_delivery then F.tags[data.__hd_squad_delivery]=t end
   local previous=F.context;F.context=t or previous
   local ok,u=pcall(old,self,path,p,q,f,data,...);F.context=previous
   if not ok then error(u,0) end
   if t then F.track(t,u) end;return u
  end end)
  -- Context propagates only through descendants of a proven bot delivery.
  for _,name in ipairs({'TurretComponent','DroneComponent','DroneStationComponent','SpawnUnitComponent','MinedropComponent','ArtilleryComponent','AirstrikeComponent',
   'TargetedStrikeComponent','FieldComponent','ExplosiveComponent','SupplyCrateComponent','BackpackPickupComponent','WeaponPickupComponent','InventoryComponent'}) do
   local object=rawget(_G,name)
   for _,phase in ipairs({'update_masters','update_slaves'}) do
   hook(object,phase,function(old)return function(self,entities,dt,...)
    local other={}
    for u,e in pairs(entities) do
     local t=F.owned[u]
     if t then
      local previous=F.context;F.context=t
      if name=='TargetedStrikeComponent' and phase=='update_slaves' and live(e.state.targeted_unit)
       and not F.impact_safe(t,pos(e.state.targeted_unit)) then
       e.state.targeted_unit=nil
       emit('stratagem_tracking_stopped',{reason='target_entered_friendly_area'},t.bot and t.bot.id)
      end
      local rounds=e.state.rounds_remaining;F.blocked[u]=nil
      local ok,err=pcall(old,self,{[u]=e},dt,...);F.context=previous
      if not ok then error(err,0) end
      if phase=='update_masters' and name=='TurretComponent' and F.blocked[u] then
       e.state.rounds_remaining=rounds
       if type(self.queue_command_master_interface)=='function' then self:queue_command_master_interface(u,'weapon','firing_auto',false) end
      end
     else other[u]=e end
    end
    if next(other) then return old(self,other,dt,...) end
   end end)
   end
   hook(object,'command_master',function(old)return function(self,u,e,command,data,...)
    local previous=F.context
    F.context=F.owned[u] or type(data)=='table' and F.tags[data.__hd_squad_item] or previous
    local ok,result=pcall(old,self,u,e,command,data,...);F.context=previous
    if not ok then error(result,0) end;return result
   end end)
  end
  hook(rawget(_G,'Unit'),'flow_event',function(old)return function(u,event,...)
   local t=F.owned[u]
   if event=='fire_round' and t and t.cap.policy.role=='turret' and EntityAux.has_component_master(u,'turret')
    and not F.fire_safe(u,state(u,'turret').target_unit) then F.blocked[u]=true;return end
   return old(u,event,...)
  end end)
  hook(rawget(_G,'TurretComponent'),'trigger_rpc_event',function(old)return function(self,event,u,...)
   if event=='rpc_turret_fire_single' and F.owned[u] and not F.fire_safe(u,state(u,'turret').target_unit) then F.blocked[u]=true;return end
   return old(self,event,u,...)
  end end)
  hook(rawget(_G,'DroneComponent'),'queue_command_master_interface',function(old)return function(self,u,interface,command,data,...)
   local t=F.owned[u]
   if t and t.cap.name=='stratagem_drone_defensive_backpack' and interface=='weapon' and command=='firing_auto' and data then
    local target=state(u,'drone').drone_target_unit
    if not F.fire_safe(u,target) then data=false end
   end
   return old(self,u,interface,command,data,...)
  end end)
 end
 function F.tick()
  if F.session~=M.session then F.session=M.session;F.owned=setmetatable({}, {__mode='k'});F.tags={} end
  F.install()
  for i=#M.behaviors.hazards,1,-1 do if M.behaviors.hazards[i].source=='bot_deployed_effect' then table.remove(M.behaviors.hazards,i) end end
  for u,t in pairs(F.owned) do
   if not live(u) or t.bot and t.bot.generation and t.bot.generation~=M.generation then F.owned[u]=nil
   else
    local mine=state(u,'mine');local tesla=state(u,'tesla');local field=state(u,'field')
    local relevant=EntityAux.has_component_master(u,'mine') or EntityAux.has_component_master(u,'tesla') or EntityAux.has_component_master(u,'field')
    if relevant and not state(u,'health').is_dead and not mine.has_exploded then
     local cfg=LuaSettingsManager and LuaSettingsManager:get_settings_by_unit(u)
     local radius=cfg and F.explosion(cfg)
     if cfg and cfg.tesla_info then radius=cfg.tesla_info.range end
     if radius and pos(u) then M.behaviors.hazards[#M.behaviors.hazards+1]={unit=u,position=pos(u),radius=radius+2,height=3,source='bot_deployed_effect',kind='persistent_stratagem'} end
    end
   end
  end
  for tag,t in pairs(F.tags) do
   if t.finished and (not t.native_units or not next(t.native_units)) then F.tags[tag]=nil end
  end
 end
 function F.uninstall()
  for object,keys in pairs(F.hooks) do for key,h in pairs(keys) do if object[key]==h.wrapper then object[key]=h.old end end end
  F.hooks={};F.tags={};F.owned=setmetatable({}, {__mode='k'})
 end
 F.install();return F
end
