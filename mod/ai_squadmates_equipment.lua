-- Native special equipment inputs. No direct health/ammunition/objective writes.
return function(M,C,B,S,F,emit)
 if M.equipment then M.equipment.install();return M.equipment end
 local K={hooks={}};M.equipment=K
 local P=M.tactics.model
 local function live(u)return u~=nil and type(u)~='boolean' and Unit.alive(u)end
 local function state(u,n)
  if not live(u) then return {} end
  if EntityAux.has_component_master(u,n) then return EntityAux.state_master(u,n) or {} end
  if EntityAux.has_component(u,n) then return EntityAux.state(u,n) or {} end
  return {}
 end
 local function pos(u)if live(u) then return P.point(Unit.world_position(u,0))end end
 local function cfg(u)
  if not live(u) or not LoadoutSettings or not LoadoutSettings.get_upgraded_settings then return end
  return LoadoutSettings.get_upgraded_settings(u)
 end
 local function autonomous(b)
  return b.active and M.units[b.unit]==b and M.bot_origins[b.unit] and not (M.mobility and M.mobility.human(b.unit))
   and not (M.is_original_body and M.is_original_body(b.unit))
 end
 function K.launch_origin(b,w,a)
  local offset=a.ray_source_offset
  if not offset or not P.finite(offset.x) or not P.finite(offset.y) or not P.finite(offset.z) or a.attach_node==nil then return end
  local rotation=Unit.world_rotation(b.unit,a.attach_node);local forward=Quaternion.forward(rotation)
  local p=Unit.world_position(w,0);local q=Quaternion.rotate(rotation,Vector3Aux.unbox(offset))
  return {x=p.x+q.x+forward.x,y=p.y+q.y+forward.y,z=p.z+q.z+1},forward
 end
 function K.finish(b,reason)
  local a=b.equipment_action;if not a then return end
  local h=state(b.unit,'health')
  if a.kind=='satchel' and live(state(b.unit,'inventory').held_grenade) and autonomous(b) and not h.is_dead and not h.is_downed then a.cancelled=true;return end
  if M.retain_rays then M.retain_rays(a.rays,a.tokens) end
  b.equipment_action=nil;b.next_equipment=M.clock+2
  emit('equipment_action_finished',{kind=a.kind,reason=reason},b.id)
 end
 function K.safe(point,radius,horizon,ignore)
  local T=M.tactics
  if T.protected_unknown or T.asset_unknown or not point then return false end
  for _,a in ipairs(T.actors) do if a.unit~=ignore then
   local zone={position=point,radius=radius+1,prediction=horizon or 1}
   if P.intersects(zone,a,horizon or 1,true) then return false end
  end end
  return true
 end
 function K.trajectory(origin,target,ti,power,z)
  if not origin or not target or not ti or not P.finite(ti.throw_distance_min) or not P.finite(ti.throw_distance_max) or not P.finite(power) then return end
  z=z or 1;local dir=P.direction(origin,target);local n=math.sqrt(1+z*z)
  local speed=math.sqrt(math.max(0,ti.throw_distance_min+power*(ti.throw_distance_max-ti.throw_distance_min))*18)
  local vx,vz=speed/n,speed*z/n;local root=vz*vz+36*(origin.z-target.z)
  if root<0 then return end
  local time=(vz+math.sqrt(root))/18;local points={origin}
  for i=1,12 do local t=time*i/12;points[#points+1]={x=origin.x+dir.x*vx*t,y=origin.y+dir.y*vx*t,z=origin.z+vz*t-9*t*t} end
  return points,points[#points],time
 end
 function K.arc_safe(points,radius,time,ignore)
  if not points or M.tactics.protected_unknown or M.tactics.asset_unknown then return false end
  for i=2,#points do local p,q=points[i-1],points[i]
   for _,a in ipairs(M.tactics.actors) do if a.unit~=ignore then
    local v=a.velocity or {};local dt=time*(i-1)/(#points-1)
    local next_position={x=a.position.x+(v.x or 0)*dt,y=a.position.y+(v.y or 0)*dt}
    local margin=radius+(a.radius or 1)+.75
    if math.min(p.z,q.z)<(a.position.z or 0)+(a.height or 2)+radius
     and F.segment_distance(a.position,next_position,p,q)<margin then return false end
   end end
  end
  return true
 end
 function K.plan_arcs(a,wi)
  a.segments={};a.landings={};local drop=0
  local bursts=a.kind=='mortar' and (wi.burst_rounds or 1) or 1
  local maximum=a.kind=='mortar' and wi.power+(wi.charge_max_extra_power or 0) or (a.multiplier or 1)
  for n=1,bursts do
   drop=drop+(n-1)*(wi.burst_round_power_decrease or 0)
   for _,extra in ipairs({0,.25}) do
    local power=math.max(0,math.min(maximum,a.power+extra)-drop)
    for _,side in ipairs({-1,0,1}) do
     local direction=P.direction(a.origin,a.point);local angle=math.rad(wi.spread or 0)*side
     local target={x=a.origin.x+direction.x*math.cos(angle)*20-direction.y*math.sin(angle)*20,
      y=a.origin.y+direction.x*math.sin(angle)*20+direction.y*math.cos(angle)*20,z=a.point.z}
     local points,landing,flight=K.trajectory(a.origin,target,a.ti,power,a.z)
     if not points or not K.safe(landing,a.blast,flight+2) or not K.arc_safe(points,a.blast,flight,a.owner) then return false end
     a.landings[#a.landings+1]={point=landing,time=flight}
     a.segments[#a.segments+1]={from={x=landing.x,y=landing.y,z=landing.z+1},to={x=landing.x,y=landing.y,z=landing.z-1},floor=true}
     for i=2,#points do a.segments[#a.segments+1]={from=points[i-1],to=points[i],landing=i==#points} end
    end
   end
  end
  a.index=0;a.clear=nil;return true
 end
 function K.safe_alternate(b,a,wi,power)
  local origin=M.stratagem_native.throw_origin(b)
  if not origin then return false end
  for i=0,15 do
   local angle=i*math.pi/8
   local point={x=origin.x+math.cos(angle)*20,y=origin.y+math.sin(angle)*20,z=pos(b.unit).z}
   local points,landing,flight=K.trajectory(origin,point,a.ti,power,1)
   if points and K.safe(landing,a.blast,flight+2) and K.arc_safe(points,a.blast,flight,b.unit) then
    a.serial=(a.serial or 0)+1;a.pending=nil;a.failed=nil;a.points=points;a.point=point
    a.origin=origin;a.power=power;a.landing=landing;a.flight=flight
    if K.plan_arcs(a,wi) then return true end
   end
  end
  a.clear=nil;return false
 end
 local function valid(b,a)
  return autonomous(b) and b.equipment_action==a and a.session==M.session and a.generation==M.generation
 end
 function K.probe(b,a,budget)
  if a.pending then
   if M.clock-a.pending>.75 then a.serial=(a.serial or 0)+1;a.pending=nil;a.failed=true end
   return
  end
  if a.clear or a.failed or not budget or (budget.route or 0)<=0 then return end
  a.index=a.index or 0
  local total=a.segments and #a.segments or #a.points
  if a.index>=total then a.clear=M.clock;return end
  local index=a.index;local endpoint=a.points[#a.points]
  local segment=a.segments and a.segments[index+1]
  local floor=segment and segment.floor or not segment and index==0
  local from=segment and segment.from or (index==0 and {x=endpoint.x,y=endpoint.y,z=endpoint.z+1} or a.points[index])
  local to=segment and segment.to or (index==0 and {x=endpoint.x,y=endpoint.y,z=endpoint.z-1} or a.points[index+1])
  local dx,dy,dz=to.x-from.x,to.y-from.y,to.z-from.z;local length=math.sqrt(dx*dx+dy*dy+dz*dz)
  if length<.001 then a.index=index+1;return end
  budget.route=budget.route-1;a.pending=M.clock;a.serial=(a.serial or 0)+1;local serial=a.serial
  a.tokens=a.tokens or {};a.rays=a.rays or {};local token={};a.tokens[token]=true
  local ray=PhysicsWorld.make_raycast(World.physics_world(M.session.world_proxy:get_world()),S.guard(b,'equipment_arc',function(hits)
   a.tokens[token]=nil
   if not valid(b,a) or a.serial~=serial then return end
   a.pending=nil
   if type(hits)~='table' then a.failed=true;return end
   local floor_found=false
   for _,hit in ipairs(hits) do local _,distance,normal,actor=unpack(hit);local unit=actor and Actor.unit(actor)
    if not P.finite(distance) then a.failed=true;return end
    if floor then
     if normal and normal.z and normal.z>=.5 and math.abs(distance-1)<.4 then floor_found=true else a.failed=true;return end
    elseif unit~=b.unit and unit~=a.weapon and not (segment and segment.landing and normal and (normal.z or 0)>=.5 and distance>=length-.3) then a.failed=true;return end
   end
   if floor and not floor_found then a.failed=true;return end
   a.index=index+1
  end,function()a.tokens[token]=nil;if valid(b,a) and a.serial==serial then a.pending=nil;a.failed=true end end),
   'all','collision_filter',floor and 'spawn_check' or 'npc_ai_feeler')
  a.rays[#a.rays+1]=ray;ray:cast(Vector3(from.x,from.y,from.z),Vector3(dx/length,dy/length,dz/length),length)
 end
 function K.target(b,radius,minimum)
  local best,score
  for _,e in ipairs(M.tactics.targets or {}) do
   local p=pos(e.unit);local count=0
   if p and P.distance(pos(b.unit),p)>minimum then
    for _,other in ipairs(M.tactics.targets) do if live(other.unit) and P.distance(p,other.position)<radius then count=count+(other.weight or 1) end end
    if count>=3 and (not score or count>score) then best=e;score=count end
   end
  end
  return best
 end
 function K.need(b,cap,pressure)
  local current=state(b.unit,'inventory').support_weapon
  if live(current) then
   local path=Unit.get_data and Unit.get_data(current,'unit_path')
   for _,out in ipairs(cap.outputs or {}) do if out.weapon_path==path then return 0 end end
   if cap.path==path then return 0 end
  end
  if cap.name=='stratagem_repairtool' then
   for _,a in ipairs(M.tactics.actors) do if a.kind=='asset' then local h=state(a.unit,'health');local hi=h.health_info or {}
    if not h.is_dead and P.finite(h.hitpoints) and P.finite(hi.max_health or hi.health or hi.hitpoints or h.max_hitpoints) and h.hitpoints<(hi.max_health or hi.health or hi.hitpoints or h.max_hitpoints)*.85 then return 7 end
   end end
   return 0
  end
  if cap.name=='stratagem_metaldetector' then
   return next(B.entities(M.session,'hidden_sweep_object')) and pressure==0 and 5 or 0
  end
  if cap.name=='stratagem_satchelcharge' or cap.name=='stratagem_mortar' then return pressure>=3 and K.target(b,4,5) and 6 or 0 end
 end
 function K.input(b,p,input,danger,budget)
  if not autonomous(b) then return input end
  local inv=state(b.unit,'inventory');local c=state(b.unit,'character');local health=state(b.unit,'health')
  local held_satchel=b.equipment_action and b.equipment_action.kind=='satchel' and live(inv.held_grenade)
  if health.is_dead or health.is_downed or c.current_seat_unit or c.current_carry_unit or b.objective or b.job or b.post or b.guard_request
   or b.stratagem_intent or b.grenade_action or state(b.unit,'interactor').busy then
   K.finish(b,'priority');if not held_satchel or health.is_dead or health.is_downed then return input end
  end
  local w=inv.support_weapon;local settings=cfg(w);local wi=settings and settings.weapon_info or {}
  local ammo=B.weapon(w)
  if wi.heal_per_second then
   local target,best
   for _,actor in ipairs(M.tactics.actors) do if actor.kind=='asset' and live(actor.unit) then
    local h=state(actor.unit,'health');local hi=h.health_info or {};local maximum=hi.max_health or hi.health or hi.hitpoints or h.max_hitpoints
    local point=pos(actor.unit);local distance=point and P.distance(p,point)
    if not h.is_dead and maximum and h.hitpoints and h.hitpoints<maximum*.95 and distance<(wi.range or 0)-1 and (not best or distance<best) then target=actor.unit;best=distance end
   end end
   if target and not danger then
    input.fire=false;input.fire_auto=false
    if inv.current_weapon~=w then input.switch_weapon='switch_to_support';return input end
    local point=pos(target);input.aim=P.direction(p,point);input.movement={x=0,y=0,z=0};input.sprint=false
    local check=b.repair_check
    if not check or check.target~=target or M.clock-check.time>.25 then
     S.probe(b,p,point,budget,function(clear)b.repair_check={target=target,time=M.clock,clear=clear}end,target)
    end
    local forward=Quaternion.forward(Unit.world_rotation(b.unit,0))
    local clear=check and check.target==target and M.clock-check.time<.25 and check.clear
    input.fire=clear and input.aim.x*forward.x+input.aim.y*forward.y>.995;input.fire_auto=input.fire
    return input
   elseif inv.current_weapon==w then input.fire=false;input.fire_auto=false;input.switch_weapon='switch_to_primary';return input end
  end
  if live(inv.current_weapon) and EntityAux.has_component_master(inv.current_weapon,'sweep_detector') then
   input.fire=false;input.fire_auto=false
   if not danger and next(B.entities(M.session,'hidden_sweep_object')) then input.fire=true;input.fire_auto=true;input.sprint=false end
   return input
  end
  local backpack=cfg(inv.backpack);local bi=backpack and backpack.backpack_info
  if bi and bi.enables_jump and not danger and not b.equipment_action and not M.tactics.preparing and M.player_anchor
   and P.distance(p,M.player_anchor)>14 and M.clock>=(b.next_jump or 0) then
   local dir=P.direction(p,M.player_anchor);local endpoint={x=p.x+dir.x*12.5,y=p.y+dir.y*12.5,z=p.z}
   local proof=b.jump_check
   if proof and proof.clear and M.clock-proof.time<.25 and P.distance(p,proof.from)<.4
    and K.safe(endpoint,1,1.4,b.unit) and not B.danger(M.behaviors,endpoint,b.unit) then
    input.dodge=true;input.movement=dir;input.fire=false;input.fire_auto=false;b.next_jump=M.clock+8
    emit('checked_jump_requested',{landing=endpoint},b.id);return input
   end
   S.probe(b,p,endpoint,budget,function(clear)b.jump_check={clear=clear,time=M.clock,from=p}end)
  end
  if wi.throwable_unit_path or ammo.fire_on_release and wi.projectile and wi.z_direction then
   local kind=wi.throwable_unit_path and 'satchel' or 'mortar'
   local projectile=F.settings(wi.throwable_unit_path or wi.projectile)
   local ti=projectile and projectile.throwable_info;local blast=projectile and F.explosion(projectile)
   if not ti or not blast then if inv.current_weapon==w then input.fire=false;input.fire_auto=false end;return input end
   if kind=='satchel' then
    local wa=state(w,'throwable_weapon');local children=wa.child_units or {};local useful=false;local safe=true
    for _,unit in ipairs(children) do if live(unit) then
     local point=pos(unit);safe=safe and K.safe(point,blast,.5)
     for _,e in ipairs(M.tactics.targets or {}) do if live(e.unit) and P.distance(point,e.position)<blast then useful=true end end
    end end
    if #children>0 then
     K.finish(b,'charge_placed')
     input.fire=false;input.fire_auto=false
     if useful and safe then EntityAux.queue_command_master(w,'throwable_weapon','trigger_child_units');emit('satchel_detonation_requested',{},b.id) end
     return input
    end
   end
   local a=b.equipment_action
   if not a then
    if danger or M.clock<(b.next_equipment or 0) or (M.tactics.preparing~=nil) then return input end
    local target=K.target(b,math.max(3,blast),5)
    if not target then if inv.current_weapon==w then input.fire=false;input.fire_auto=false end;return input end
    local origin
    if kind=='mortar' then origin=K.launch_origin(b,w,ammo) else origin=M.stratagem_native.throw_origin(b) end
    local point=target.position
    if not origin then return input end
    local distance=P.distance(origin,point);local z=kind=='mortar' and wi.z_direction or 1
    local denominator=origin.z-point.z+z*distance
    local span=ti.throw_distance_max-ti.throw_distance_min
    if denominator<=0 or span<=0 then return input end
    local power=(distance*distance*(1+z*z)/(2*denominator)-ti.throw_distance_min)/span
    local multiplier=c.throw_range_multiplier or 1
    local charge=kind=='mortar' and (power-wi.power)/(wi.charge_max_extra_power or 0) or power/multiplier
    if not P.finite(charge) or charge<0 or charge>1 then return input end
    local points,landing,flight=K.trajectory(origin,point,ti,power,z)
    if not points or not K.safe(landing,blast+distance*math.tan(math.rad(wi.spread or 0)),flight) then return input end
    a={kind=kind,weapon=w,target=target.unit,point=point,points=points,landing=landing,flight=flight,origin=origin,
     charge=charge,power=power,multiplier=multiplier,blast=blast,ti=ti,z=z,owner=b.unit,started=M.clock,session=M.session,generation=M.generation}
    if not K.plan_arcs(a,wi) then return input end
    b.equipment_action=a;emit('equipment_action_selected',{kind=kind},b.id)
   end
   local out=C.neutral();out.aim=P.direction(p,a.point)
   if (a.weapon~=w or not live(a.target) or danger or a.failed or M.clock-a.started>30) and not held_satchel then
    K.finish(b,'interrupted');return out
   end
   for i=1,4 do K.probe(b,a,budget) end
   if inv.current_weapon~=w then out.switch_weapon='switch_to_support';return out end
   local forward=Quaternion.forward(Unit.world_rotation(b.unit,0));local aligned=forward.x*out.aim.x+forward.y*out.aim.y>.995
   if held_satchel then
    local context=M.stratagem_native.contexts[b.unit];local ci=context and context.context.settings.character_info
    local maximum=ci and ci.throw_time_to_max
    local charge=maximum and math.min(1,(c.throw_timer or 0)/maximum) or 0
    out.fire=true
    if (a.cancelled or a.failed or not K.safe(a.landing,a.blast,a.flight)) and M.clock>=(a.alternate_at or 0) then
     a.alternate_at=M.clock+.5
     if K.safe_alternate(b,a,wi,charge*(c.throw_range_multiplier or 1)) then a.charge=charge;a.cancelled=nil end
     out.aim=P.direction(p,a.point)
     aligned=forward.x*out.aim.x+forward.y*out.aim.y>.995
    end
    if a.failed and M.clock>=(a.retry_at or 0) then
     a.failed=nil;a.serial=(a.serial or 0)+1;a.pending=nil;a.index=0;a.clear=nil;a.retry_at=M.clock+1
    end
    if charge>a.charge+.04 then
     local power=charge*(c.throw_range_multiplier or 1)
     local points,landing,flight=K.trajectory(M.stratagem_native.throw_origin(b),a.point,a.ti,power,1)
     if points then a.serial=(a.serial or 0)+1;a.pending=nil;a.origin=M.stratagem_native.throw_origin(b);a.points=points;a.landing=landing;a.flight=flight;a.power=power;a.charge=charge;K.plan_arcs(a,wi) end
    end
    local velocity=(c.mover_state or {}).velocity or {};local still=(velocity.x or 0)^2+(velocity.y or 0)^2<.0225
    if a.clear and aligned and still and charge>=a.charge and K.safe(a.landing,a.blast,a.flight) then out.fire=false end
   elseif a.clear and aligned and K.safe(a.landing,a.blast,a.flight) then
    if kind=='mortar' then
     local maximum=ammo.max_charge_time or wi.max_charge_time
     local charge=maximum and (ammo.shot_charge_timer or 0)/maximum or 0
     out.fire=charge<a.charge;out.fire_auto=out.fire
    else out.fire=true;out.fire_auto=false end
   end
   return out
  end
  return input
 end
 local function hook(object,key,make)
  if type(object)~='table' or type(object[key])~='function' then return end
  K.hooks[object]=K.hooks[object] or {};if K.hooks[object][key] then return end
  local old=object[key];local wrapper=make(old);object[key]=wrapper;K.hooks[object][key]={old=old,wrapper=wrapper}
 end
 function K.install()
  hook(rawget(_G,'CharacterStateJump'),'update',function(old)return function(u,e,dt,component,...)
   local b=M.units[u];local target=e.state.jump_target
   if b and autonomous(b) and target then
    local point=Vector3Aux.unbox(target)
    if not K.safe(point,1,1.4,b.unit) or B.danger(M.behaviors,point,b.unit) then
     CharacterStateMachine.change_state(u,e,CharacterStateIdle);return
    end
   end
   return old(u,e,dt,component,...)
  end end)
  hook(rawget(_G,'LauncherComponent'),'do_fire',function(old)return function(self,u,a,...)
   local b=M.weapon_owners[u]
   if b and autonomous(b) and a.fire_on_release and a.z_direction and a.projectile then
    local action=b.equipment_action
    local power=self:calculate_charge_power(u,a)
    local origin,forward=K.launch_origin(b,u,a)
    local profile=F.settings(a.projectile);local ti=profile and profile.throwable_info
    local target=action and action.point
    local points,landing,flight=K.trajectory(origin,target,ti,power,a.z_direction)
    local wanted=origin and target and P.direction(origin,target)
    if not action or action.kind~='mortar' or not action.clear or not points or not wanted
     or forward.x*wanted.x+forward.y*wanted.y<.995 or P.distance(origin,action.origin)>.3 or math.abs(origin.z-action.origin.z)>.3
     or power>action.power+.25 or power<action.power-(a.burst_rounds or 1)*(a.burst_rounds or 1)*(a.burst_round_power_decrease or 0)
     or not K.safe(landing,action.blast+P.distance(origin,landing)*math.tan(math.rad(a.spread or 0)),flight)
     or not K.arc_safe(points,action.blast,flight,b.unit) then
     a.firing_single=false;a.firing_auto=true;a.waiting_for_charge_release=true
     return
    end
   end
   return old(self,u,a,...)
  end end)
  hook(rawget(_G,'InventoryComponent'),'command_master',function(old)return function(self,u,e,name,data,...)
   local b=M.units[u];local a=b and b.equipment_action;local h=state(u,'health')
   if a and a.kind=='satchel' and autonomous(b) and name=='throw' and data and (data.power or 0)>0 and not h.is_dead and not h.is_downed then
    local origin=P.point(data.position);local dir=P.point(data.direction)
    local target=origin and dir and {x=origin.x+dir.x*10,y=origin.y+dir.y*10,z=a.point.z}
    local points,landing,flight=K.trajectory(origin,target,a.ti,data.power,dir and dir.z)
    if not a.clear or not points or P.distance(landing,a.landing)>.25 or not K.safe(landing,a.blast,flight) then
     local c=state(u,'character');c.has_thrown=false;c.throw_done=false;if c.input then c.input.fire=true end
     a.clear=nil;a.index=0;return
    end
   end
   return old(self,u,e,name,data,...)
  end end)
 end
 function K.uninstall()
  for object,keys in pairs(K.hooks) do for key,h in pairs(keys) do if object[key]==h.wrapper then object[key]=h.old end end end
  K.hooks={}
 end
 function K.tick()
  K.install()
  local budget={route=5,rays=1}
  for unit,t in pairs(F.owned) do if live(unit) and EntityAux.has_component_master(unit,'hellbomb') and not t.arming_ordered then
   local a=state(unit,'hellbomb');local b=t.bot
   local settings=cfg(unit);local radius=settings and F.explosion(settings)
   if radius and b and autonomous(b) and not b.objective and not b.job and not b.post and not b.grenade_action and not a.is_armed
    and K.safe(pos(unit),radius+5,3,b.unit) then
    local direction=P.direction(pos(unit),pos(b.unit));local point=pos(unit)
    local retreat={x=point.x+direction.x*(radius+6),y=point.y+direction.y*(radius+6),z=point.z}
    if b.hellbomb_escape and b.hellbomb_escape.unit==unit and b.hellbomb_escape.clear and M.clock-b.hellbomb_escape.time<.5 then
     local _,ok=M.objectives.request(M.session,point,b);t.arming_ordered=ok==true
    else S.probe(b,pos(b.unit),retreat,budget,function(clear)b.hellbomb_escape={unit=unit,clear=clear,time=M.clock}end) end
   end
  end end
 end
 K.install()
 return K
end
