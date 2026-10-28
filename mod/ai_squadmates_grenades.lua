-- Native hand grenades: bounded arc checks and exclusive, finite inventory actions.
return function(M,C,B,S,P,emit)
 if M.grenades then M.grenades.install();return M.grenades end
 local G={hooks={},released={},next_action=0};M.grenades=G
 local function live(u)return u~=nil and Unit.alive(u)end
 local function state(u,n,master)
  if not live(u) then return {} end
  if master and EntityAux.has_component_master(u,n) then return EntityAux.state_master(u,n) or {} end
  if EntityAux.has_component(u,n) then return EntityAux.state(u,n) or {} end
  return {}
 end
 local function pos(u)if live(u) then return P.point(Unit.world_position(u,0)) end end
 local function settings(path)
  if not path or not LuaSettingsManager or not LuaSettingsManager.get_modified_settings then return end
  local ok,cfg=pcall(LuaSettingsManager.get_modified_settings,LuaSettingsManager,path,0)
  if ok and type(cfg)=='table' then return cfg end
 end
 function G.profile(path)
  local cfg=settings(path);local e=cfg and cfg.explosive_info;local ti=cfg and cfg.throwable_info
  if not e or not ti or not P.finite(e.blast_radius) or e.ignore_arm_on_thrown then return end
  local fuse=e.explode_on_impact and 0 or e.time_until_explosion
  if not P.finite(fuse) or fuse<0 or not P.finite(ti.throw_distance_min) or not P.finite(ti.throw_distance_max)
   or ti.throw_distance_min<0 or ti.throw_distance_max<=0 or ti.throw_distance_max<ti.throw_distance_min then return end
  local kind=path:find('smoke',1,true) and 'smoke' or path:find('stun',1,true) and 'stun'
   or path:find('incendiary',1,true) and 'incendiary' or 'frag'
  if e.on_explode_unit_path and e.on_explode_unit_path:find('napalm',1,true) then kind='incendiary' end
  if kind=='frag' and (e.on_explode_unit_path or not P.finite(e.blast_power) or e.blast_power<=0) then return end
  local radius=e.blast_radius;local duration=0
  if e.on_explode_unit_path then
   local effect=settings(e.on_explode_unit_path);local area=effect and effect.explosive_info;local field=effect and effect.field_info
   if not area or not field or not P.finite(area.blast_radius) then return end
   radius=math.max(radius,area.blast_radius)
   duration=field.time_until_end
   if not P.finite(duration) or duration<0 then return end
  end
  if radius<=0 then return end
  return {kind=kind,radius=radius,fuse=fuse,duration=duration,minimum=ti.throw_distance_min,maximum=ti.throw_distance_max,
   explosive=e,path=path}
 end
 function G.safe(b,target,profile,flight)
  local T=M.tactics;if not T or T.protected_unknown or T.asset_unknown or not target then return false end
  local horizon=profile.fuse+(flight or 1)+profile.duration
  for _,a in ipairs(T.actors or {}) do if a.position then
   local v=a.velocity or {};local reach=math.min(horizon,4)
   local q={x=a.position.x+(v.x or 0)*reach,y=a.position.y+(v.y or 0)*reach,z=a.position.z}
   local d=C.direction(a.position,q);local length=C.distance(a.position,q)
   local t=math.max(0,math.min(length,(target.x-a.position.x)*d.x+(target.y-a.position.y)*d.y))
   local near={x=a.position.x+d.x*t,y=a.position.y+d.y*t}
   local speed=math.sqrt((v.x or 0)^2+(v.y or 0)^2)
   local margin=(a.radius or .8)+.75+math.min(2,horizon*speed*.3)
   if math.abs((target.z or 0)-(a.position.z or 0))<3 and C.distance(near,target)<profile.radius+margin then return false end
  end end
  return true
 end
 function G.landing(b,target,profile,power,origin)
  origin=origin or (M.stratagem_native and M.stratagem_native.throw_origin(b))
  if not origin then return end
  local c=state(b.unit,'character',true);local multiplier=c.throw_range_multiplier or 1
  if power==nil then
   local distance=P.fit_throw(C.distance(origin,target),origin.z-target.z,profile.minimum,profile.maximum,multiplier)
   power=distance and P.throw_power(distance,origin.z-target.z,profile.minimum,profile.maximum,multiplier)
  end
  if not P.finite(power) or power<0 or power>1 then return end
  local horizontal=math.sqrt(math.max(0,profile.minimum+power*multiplier*(profile.maximum-profile.minimum))*9)
  local h=origin.z-target.z;local root=horizontal*horizontal+36*h
  if root<0 then return end
  local flight=(horizontal+math.sqrt(root))/18;local d=C.direction(origin,target)
  return {x=origin.x+d.x*horizontal*flight,y=origin.y+d.y*horizontal*flight,z=target.z},flight,horizontal,power
 end
 function G.choose(b,p,profile)
  local T=M.tactics;local best,score
  for _,enemy in ipairs(T and T.targets or {}) do if live(enemy.unit) and enemy.position then
   local q=G.landing(b,enemy.position,profile);local d=q and C.distance(p,q) or 0
   if q and d>=4 then
    local count=0
    for _,other in ipairs(T.targets) do
     if live(other.unit) and C.distance(q,other.position)<=profile.radius*.8 then
      local armor=tonumber((other.health or {}).armor_min or ((other.health or {}).health_info or {}).armor_min) or 0
      if profile.kind~='frag' or profile.explosive.ignore_armor or armor<=(tonumber(profile.explosive.armorpiercing) or 0) then count=count+1 end
     end
    end
    local value=0
    if (profile.kind=='frag' or profile.kind=='incendiary') and count>=3 then value=count end
    if profile.kind=='stun' and count>=2 and C.distance(q,M.player_anchor or p)<12 then value=count+1 end
    if profile.kind=='smoke' and count>=2 then
     for _,a in ipairs(T.actors) do if a.protected and state(a.unit,'health').is_downed and C.distance(q,a.position)<18 then value=4 end end
     local motion=M.leader_motion
     if motion and motion.speed>1 then
      local away=C.direction(q,M.player_anchor or p);local v=motion.velocity or {}
      if away.x*(v.x or 0)+away.y*(v.y or 0)>1 then value=math.max(value,3) end
     end
    end
    if value>0 and G.safe(b,q,profile) and (not score or value>score) then best=P.point(q);score=value end
   end
  end end
  return best
 end
 local function valid(b,a)
  return b.active and M.units[b.unit]==b and live(b.unit) and a.session==M.session and a.generation==M.generation
   and b.grenade_action==a and not (M.mobility and M.mobility.human(b.unit))
 end
 function G.finish(b,reason)
  local a=b.grenade_action;if not a then return end
  b.grenade_action=nil;if G.active==b then G.active=nil end
  if M.retain_rays then M.retain_rays(a.rays,a.tokens) end
  b.next_grenade=M.clock+5;G.next_action=M.clock+3
  emit('grenade_action_finished',{reason=reason,kind=a.profile.kind,target=a.target},b.id)
 end
 function G.arc(b,a)
  local A=M.stratagem_native;local origin=A and A.throw_origin(b);local c=state(b.unit,'character',true)
  if not origin then return false end
  local target,flight,horizontal,power=G.landing(b,a.target,a.profile,a.forced_power)
  if not target then return false end;a.target=target
  if horizontal<.01 then return false end
  local direction=C.direction(origin,a.target)
  a.power=power;a.flight=flight;a.origin=origin;a.points={origin};a.arc_index=0;a.arc_clear=nil
  for i=1,12 do local t=flight*i/12
   a.points[#a.points+1]={x=origin.x+direction.x*horizontal*t,y=origin.y+direction.y*horizontal*t,z=origin.z+horizontal*t-9*t*t}
  end
  a.points[#a.points].z=a.target.z+.1
  return true
 end
 function G.probe(b,a,budget)
  if a.pending then
   if M.clock-a.pending>.75 then
    a.pending=nil;a.probe_serial=(a.probe_serial or 0)+1;a.timeouts=(a.timeouts or 0)+1
    a.blocked=a.timeouts>=3 or nil
    emit('grenade_probe_timeout',{attempt=a.timeouts},b.id)
   end
   return
  end
  if not a.points and not G.arc(b,a) then a.blocked=true;return end
  if a.arc_index>#a.points-1 then a.arc_clear=M.clock;return end
  if not budget or (budget.route or 0)<=0 then return end
  local floor=a.arc_index==0
  local from=floor and {x=a.target.x,y=a.target.y,z=a.target.z+1} or a.points[a.arc_index]
  local to=floor and {x=a.target.x,y=a.target.y,z=a.target.z-1} or a.points[a.arc_index+1]
  local dx,dy,dz=to.x-from.x,to.y-from.y,to.z-from.z
  local n=math.sqrt(dx*dx+dy*dy+dz*dz);if n<.01 then a.arc_index=a.arc_index+1;return end
  budget.route=budget.route-1;a.pending=M.clock;local index=a.arc_index;local token={};a.tokens=a.tokens or {};a.tokens[token]=true
  a.probe_serial=(a.probe_serial or 0)+1;local serial=a.probe_serial
  local ray=PhysicsWorld.make_raycast(World.physics_world(M.session.world_proxy:get_world()),S.guard(b,'grenade_arc',function(hits)
   a.tokens[token]=nil
   if not valid(b,a) or a.arc_index~=index or a.probe_serial~=serial then return end
   a.pending=nil;local hit,distance
   assert(type(hits)=='table','Unknown grenade collision result')
   if type(hits)=='table' then
    for _,h in ipairs(hits) do local _,d,_,actor=unpack(h);local u=actor and Actor.unit(actor)
     assert(P.finite(d) and d>=0,'Invalid grenade collision distance')
     if floor and (not h[3] or not P.finite(h[3].z) or h[3].z<.5) then a.blocked=true;return end
     if (not u or u~=b.unit and u~=a.marker) and (not distance or d<distance) then hit=true;distance=d end
    end
   else hit=hits==true end
   if floor then
    if not hit or not distance or math.abs(distance-1)>.4 then a.blocked=true;return end
   elseif hit and not (index==#a.points-1 and distance and distance>=n-.3) then a.blocked=true;return end
   a.arc_index=a.arc_index+1
  end,function()a.tokens[token]=nil;if valid(b,a) and a.probe_serial==serial then a.pending=nil;a.blocked=true end end),
   'all','collision_filter',floor and 'spawn_check' or 'npc_ai_feeler')
  a.rays=a.rays or {};a.rays[#a.rays+1]=ray
  ray:cast(Vector3(from.x,from.y,from.z),Vector3(dx/n,dy/n,dz/n),n)
 end
 function G.input(b,p,input,danger,budget)
  local a=b.grenade_action;local inv=state(b.unit,'inventory',true);local c=state(b.unit,'character',true);local h=state(b.unit,'health')
  if not a then
   if not M.tactics or not M.tactics.enabled or G.active or M.clock<G.next_action or M.clock<(b.next_grenade or 0)
    or not M.bot_origins[b.unit] or (M.is_original_body and M.is_original_body(b.unit)) or (M.mobility and M.mobility.human(b.unit))
    or h.is_dead or h.is_downed or danger or b.equipment_action or b.job or b.objective or b.post or b.guard_request or b.vehicle_order or b.tactical_job
    or b.stratagem_intent or b.rejoin_probe or b.rejoin_commit or b.rejoin_corridor or c.current_seat_unit or c.current_carry_unit or state(b.unit,'interactor',true).busy
    or live(inv.held_grenade) or (tonumber(inv.num_grenades) or 0)<=0 or M.tactics.preparing then return input end
   if M.clock<(b.grenade_scan or 0) then return input end;b.grenade_scan=M.clock+.5
   local profile=G.profile(inv.grenade_unit_path);if not profile then return input end
   local target=G.choose(b,p,profile);if not target then return input end
   local context=M.stratagem_native and M.stratagem_native.contexts[b.unit]
   local charge=context and context.context.settings and (context.context.settings.character_info or {}).throw_time_to_max
   if not P.finite(charge) or charge<=0 then return input end
   a={profile=profile,target=target,session=M.session,generation=M.generation,epoch=b.rejoin_epoch,charge_time=charge,started=M.clock}
   b.grenade_action=a;G.active=b;emit('grenade_selected',{kind=profile.kind,target=target},b.id)
  end
  if not valid(b,a) then G.finish(b,'context_changed');return input end
  local held=live(inv.held_grenade);a.marker=held and inv.held_grenade or a.marker
  if held and M.clock-a.started>3 and G.active==b then G.active=nil end
  if not held and c.current_state~=CharacterStateThrow and M.clock-a.started>3 then G.finish(b,'prepare_timeout');return input end
  local safe=G.safe(b,a.target,a.profile,a.flight)
  if (not safe or a.blocked or danger) and not held and c.current_state~=CharacterStateThrow then G.finish(b,'unsafe_before_prepare');return input end
  if (not safe or a.blocked) and not a.pending then
   -- Prepared grenades are unarmed until native throw. Find an empty safe landing.
   for i=1,12 do local angle=i*math.pi/6;local n=math.min(8,a.profile.maximum)
    local q=G.landing(b,{x=p.x+math.cos(angle)*n,y=p.y+math.sin(angle)*n,z=p.z},a.profile)
    if q and G.safe(b,q,a.profile) then a.target=q;a.points=nil;a.arc_clear=nil;a.blocked=nil;a.pending=nil;break end
   end
  end
  local origin=M.stratagem_native and M.stratagem_native.throw_origin(b)
  if a.arc_clear and (M.clock-a.arc_clear>.25 or not origin or C.distance(origin,a.origin)>.15) then a.points=nil;a.arc_clear=nil end
  for i=1,4 do if not a.arc_clear and not a.blocked then G.probe(b,a,budget) end end
  local out=C.neutral();out.aim=C.direction(p,a.target)
  if not held and c.current_state~=CharacterStateThrow then
   if a.arc_clear and G.safe(b,a.target,a.profile,a.flight) then out.throw=true end
  else
   a.hold_at=a.hold_at or M.clock
   local facing=Quaternion.forward(Unit.world_rotation(b.unit,0));local aligned=facing.x*out.aim.x+facing.y*out.aim.y>.995
   local velocity=(c.mover_state or {}).velocity or {};local still=(velocity.x or 0)^2+(velocity.y or 0)^2<.0225
   local charge=P.finite(c.throw_timer) and c.throw_timer/a.charge_time or (M.clock-a.hold_at)/a.charge_time
   local actual=math.max(0,math.min(1,charge))
   if actual>(a.power or 1)+.04 then
    local q=G.landing(b,a.target,a.profile,actual)
    if q then a.target=q;a.forced_power=actual;a.points=nil;a.arc_clear=nil end
   end
   out.throw=not (a.arc_clear and G.safe(b,a.target,a.profile,a.flight) and still and aligned and actual>=a.power)
  end
  return out
 end
 function G.tick()
  for _,b in ipairs(M.bots or (G.active and {G.active} or {})) do local a=b.grenade_action
   if a then local h=state(b.unit,'health')
    if not valid(b,a) or h.is_dead or h.is_downed then G.finish(b,'native_interruption') end
   end
  end
  for i=#M.behaviors.hazards,1,-1 do if M.behaviors.hazards[i].source=='hand_grenade' then table.remove(M.behaviors.hazards,i) end end
  for i=#G.released,1,-1 do local r=G.released[i]
   if M.clock>=r.expires then table.remove(G.released,i) else
    r.position=pos(r.unit) or r.position
    M.behaviors.hazards[#M.behaviors.hazards+1]={position=r.position,radius=r.radius,height=3,source='hand_grenade',kind='grenade'}
   end
  end
 end
 local function hook(object,key,factory)
  if not object or type(object[key])~='function' or G.hooks[key] then return end
  local old=object[key];local wrapper=factory(old);object[key]=wrapper;G.hooks[key]={object=object,key=key,old=old,wrapper=wrapper}
 end
 function G.install()
  hook(rawget(_G,'InventoryComponent'),'command_master',function(old)return function(self,u,e,name,data,...)
   local b=M.units[u];local a=b and b.grenade_action
   local marker=a and e.state.held_grenade
   local h=state(u,'health');local c=state(u,'character',true)
   if a and marker and name=='throw' and valid(b,a) and not h.is_dead and not h.is_downed and data and (data.power or 0)>0 then
    local origin=P.point(data.position) or pos(marker);local direction=P.point(data.direction)
    local q,flight
    if origin and direction and P.finite(data.power) then
     local length=math.sqrt(direction.x^2+direction.y^2+direction.z^2)
     local speed=math.sqrt(math.max(0,a.profile.minimum+data.power*(a.profile.maximum-a.profile.minimum))*18)
     if length>.001 then
      local vz=direction.z/length*speed;local root=vz*vz+36*(origin.z-a.target.z)
      if root>=0 then flight=(vz+math.sqrt(root))/18
       q={x=origin.x+direction.x/length*speed*flight,y=origin.y+direction.y/length*speed*flight,z=a.target.z}
      end
     end
    end
    if not q or not a.arc_clear or M.clock-a.arc_clear>.25 or not a.origin or C.distance(origin,a.origin)>.15
     or C.distance(q,a.target)>.25 or not G.safe(b,q,a.profile,flight) then
     c.has_thrown=false;c.throw_done=false;if c.input then c.input.throw=true end
     if q and G.safe(b,q,a.profile,flight) then a.target=q end
     a.points=nil;a.arc_clear=nil
     if M.clock>=(a.next_block_log or 0) then a.next_block_log=M.clock+2;emit('grenade_release_held',{reason='native_payload_not_checked'},b.id) end
     return
    end
   end
   local result=old(self,u,e,name,data,...)
   if a and name=='throw' and marker and e.state.grenade_thrown then
    G.released[#G.released+1]={unit=marker,position=a.target,radius=a.profile.radius,expires=M.clock+a.profile.fuse+a.profile.duration+(a.flight or 1)+1}
    emit('grenade_released',{kind=a.profile.kind,target=a.target,remaining=e.state.num_grenades},b.id);G.finish(b,'native_release')
   end
   return result
  end end)
  hook(rawget(_G,'CharacterStateThrow'),'update',function(old)return function(u,e,dt,component,...)
   local b=M.units[u];local a=b and b.grenade_action
   if a and valid(b,a) and not e.state.throw_done then
    local safe=a.arc_clear and M.clock-a.arc_clear<=.25 and G.safe(b,a.target,a.profile,a.flight)
    if not safe then e.state.input.throw=true;e.state.has_thrown=false end
   end
   return old(u,e,dt,component,...)
  end end)
 end
 function G.uninstall()
  for _,h in pairs(G.hooks) do if h.object[h.key]==h.wrapper then h.object[h.key]=h.old end end
  G.hooks={};G.active=nil;G.released={}
 end
 G.install();return G
end
