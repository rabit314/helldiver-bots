-- Vehicle inputs, assembly visibility and persistent physical progress.
return function(M,C,B,S,V,emit)
 if M.mobility then return M.mobility end
 local H={hooks={},deliveries={},cursor=0};M.mobility=H
 local function live(u)return u~=nil and Unit.alive(u)end
 local function point(p)return {x=p.x,y=p.y,z=p.z or 0}end
 local function state(u,n)
  if not live(u) then return {} end
  if EntityAux.has_component_master(u,n) then return EntityAux.state_master(u,n) or {} end
  if EntityAux.has_component(u,n) then return EntityAux.state(u,n) or {} end
  return {}
 end
 H.state=state
 local function pos(u)if live(u) then return point(Unit.world_position(u,0)) end end
 function H.root(u)
  local c=state(u,'character');local seat=c.current_seat_unit
  return V.root(live(seat) and seat or u)
 end
 function H.human(u)
  for _,p in ipairs(M.session and M.session.players or {}) do local go=p.player_go
   if go and go:exists() and go:has('avatar_unit') and go:get('avatar_unit')==u then return true end
  end
  return false
 end
 function H.profile(u)
  local info=state(u,'vehicle').vehicle_info or {};local k=info.vehicle_type
  if k=='exosuit' then return {kind=k,width=1.45,length=2.8,height=5,speed=info.move_speed or 3,deceleration=info.deceleration or 6} end
  if k=='bike' then return {kind=k,width=1.5,length=3.5,height=3.5,speed=info.move_speed or 9,deceleration=info.deceleration or 3} end
  return {kind=k,width=2.2,length=4.5,height=4.5,speed=info.move_speed or 5,deceleration=info.deceleration or 6,tank=info.input_type=='tank'}
 end
 function H.bot_delivery(u)
  local R=M.tactics and M.tactics.readiness
  for _,r in ipairs(R and R.vehicles or {}) do
   if r.unit==u and r.session==M.session and r.state=='arrived' then return true end
  end
  return false
 end
 function H.driver(u)
  if not M.enabled or not M.session then return end
  local b=M.units[(state(u,'seat').seated_units or {})[1]]
  return b and b.active and V.is_pilot(b) and not H.human(b.unit) and b or nil
 end
 function H.assembly(u)
  local result,seen={},{}
  local function add(v)
   if live(v) and not seen[v] then seen[v]=true;result[#result+1]=v end
  end
  add(u)
  for seat in pairs(B.entities(M.session,'seat')) do
   if V.root(seat)==u then
    add(seat);local a=state(seat,'seat')
    for _,v in pairs(a.seated_units or {}) do add(v) end
    for _,v in pairs(a.seat_weapon_units or {}) do add(v) end
   end
  end
  for gun in pairs(B.entities(M.session,'stationary_weapon')) do
   if V.root(gun)==u then add(gun) end
  end
  return result
 end
 function H.human_aboard(u)
  for _,p in ipairs(M.session and M.session.players or {}) do local go=p.player_go
   if go and go:exists() and go:has('avatar_unit') then
    local avatar=go:get('avatar_unit')
    if live(avatar) and H.root(avatar)==u then return true end
   end
  end
  -- Unknown occupants are never safe to relocate.
  for _,v in ipairs(H.assembly(u)) do
   for _,occupant in pairs(state(v,'seat').seated_units or {}) do
    if live(occupant) and (H.human(occupant) or not M.units[occupant]) then return true end
   end
  end
  return false
 end
 function H.hidden(b,m,p)
  local root=m and m.vehicle or b.unit;local origin=pos(root)
  if not origin then return false,'assembly_position_unknown' end
  if m and H.human_aboard(root) then return false,'human_or_unknown_occupant' end
  local profile=m and H.profile(root) or {width=1.3,length=1.3,height=3}
  -- Enclose hull, barrel sweep and every linked occupant, at both endpoints.
  local extent={width=m and math.max(6,profile.length+2) or profile.width,height=profile.height}
  local function check(q,size,u)
   local ok,hidden,why,view=pcall(M.recovery.hidden,q,size)
   if not ok then return false,'projection_error',{unit=tostring(u),message=tostring(hidden)} end
   return hidden,why,{unit=tostring(u),bounds=view}
  end
  local unseen,why,view=check(p,extent,root)
  if not unseen then return false,why,view end
  for _,v in ipairs(m and H.assembly(root) or {root}) do
   local q=pos(v)
   if not q then return false,'assembly_position_unknown',{unit=tostring(v)} end
   unseen,why,view=check({x=p.x+q.x-origin.x,y=p.y+q.y-origin.y,z=p.z+q.z-origin.z},
     {width=v==root and extent.width or 2,height=v==root and extent.height or 3},v)
   if not unseen then return false,why,view end
  end
  return true,'assembly_hidden',view
 end
 function H.visibility(b,m,p)
  local unseen,why,view=H.hidden(b,m,p)
  local status=unseen and 'hidden' or ((why=='screen_bounds' or why=='camera_plane_intersection') and 'visible' or 'unknown')
  return {status=status,reason=why,assembly=view}
 end
 function H.observe(b,leader,intended)
  local u=H.root(b.unit);local p=pos(u);if not p or not leader then return end
  local epoch=tostring(b.rejoin_epoch)..':'..tostring(b.order_sequence)
  local q=b.follow_progress
  if not q or q.root~=u or q.epoch~=epoch or q.session~=M.session or q.generation~=M.generation or q.intended~=intended then
   q={root=u,epoch=epoch,session=M.session,generation=M.generation,intended=intended,started=M.clock,last_progress=M.clock,
    target=point(leader),best=C.distance(p,leader),seen={},cells={},last_fresh_position=point(p),samples={}};b.follow_progress=q
  end
  local gap=C.distance(p,leader)
  if C.distance(q.target,leader)>4 then
   q.target=point(leader);q.best=gap
   for _,sample in ipairs(q.samples) do q.best=math.min(q.best,C.distance(sample.position,leader)) end
  end
  local d=C.distance(p,q.target)
  local key=math.floor(p.x/1.5)..':'..math.floor(p.y/1.5)
  local route=b.route;local checked=route and route.status=='ready' and route.path
   or b.step_check and b.step_check.clear and M.clock-b.step_check.time<.65
  local fresh=not q.seen[key] or M.clock-q.seen[key]>120
  local last=q.samples[#q.samples]
  if intended and (d<q.best-.35 or fresh and checked and C.distance(q.last_fresh_position,p)>.6) then
   q.last_progress=M.clock;q.best=math.min(q.best,d);if fresh then q.last_fresh_position=point(p) end
  end
  if fresh then q.seen[key]=M.clock;q.cells[#q.cells+1]={key=key,time=M.clock} end
  while #q.cells>0 and (#q.cells>256 or M.clock-q.cells[1].time>120) do
   local cell=table.remove(q.cells,1);if q.seen[cell.key]==cell.time then q.seen[cell.key]=nil end
  end
  if not last or M.clock-last.time>=.25 then q.samples[#q.samples+1]={position=p,time=M.clock} end
  while #q.samples>1 and M.clock-q.samples[1].time>12 do table.remove(q.samples,1) end
  q.position=p;q.gap=gap;q.blocked_seconds=intended and M.clock-q.last_progress or 0
  q.advancing=intended and M.clock-q.last_progress<2.5
  if intended and gap>30 then q.far_since=q.far_since or M.clock else q.far_since=nil end
  b.catchup=intended and ((q.far_since and M.clock-q.far_since>=3) or gap>=12 and q.blocked_seconds>=6) or false
  return q
 end
 function H.following(b)
  local t=b.vehicle_order;local c=state(b.unit,'character')
  return not b.post and not b.guard_request and not b.objective and not b.job and not b.tactical_job
   and not b.stratagem_intent and not live(c.current_carry_unit) and not state(b.unit,'interactor').busy
   and (not t or t.pilot and not t.destination)
 end
 function H.tick(leader,lp)
  for _,b in ipairs(M.bots) do if b.active then
   local j=b.job;local rescue=j and j.kind=='revive'
   H.observe(b,rescue and (j.target_position or j.position) or lp,H.following(b) or rescue==true)
  end end
 end
 function H.claim_recovery(b)
  H.waiting=H.waiting or {};local entry=H.waiting[b] or {started=M.clock};entry.seen=M.clock;H.waiting[b]=entry
  local active=0;local oldest=b
  for other,t in pairs(H.waiting) do
   if not other.active or M.clock-t.seen>.75 and not other.rejoin_probe then H.waiting[other]=nil
   elseif other.rejoin_probe then active=active+1
   elseif t.started<H.waiting[oldest].started or t.started==H.waiting[oldest].started and other.id<oldest.id then oldest=other end
  end
  return b.rejoin_probe~=nil or active<2 and oldest==b
 end
 function H.release_recovery(b)
  if H.waiting then H.waiting[b]=nil end
 end
 function H.velocity(u)
  local a=state(u,'mover');local v=a.velocity or (state(u,'vehicle').mover_state or {}).velocity
  return v and {x=tonumber(v.x) or 0,y=tonumber(v.y) or 0} or {x=0,y=0}
 end
 function H.braking(b,m,move,friends)
  local p=pos(m.vehicle);local profile=H.profile(m.vehicle);local vel=H.velocity(m.vehicle)
  local speed=math.sqrt(vel.x*vel.x+vel.y*vel.y);local d=C.direction({x=0,y=0},speed>.2 and vel or move)
  local length=profile.length+speed*.35+speed*speed/(2*math.max(1,profile.deceleration))+.8
  local z={x=p.x+d.x*length,y=p.y+d.y*length,z=p.z}
  for _,f in ipairs(friends or {}) do if math.abs((f.z or 0)-p.z)<3 then
   local along=math.max(0,math.min(length,(f.x-p.x)*d.x+(f.y-p.y)*d.y))
   if C.distance({x=p.x+d.x*along,y=p.y+d.y*along},f)<profile.width+1 then return false end
  end end
  -- A turn sweeps a larger area than the current forward ray.
  if not V.pedestrian_clear(p,{x=p.x+move.x*math.max(2,length),y=p.y+move.y*math.max(2,length),z=p.z},friends or {}) then return false end
  return true
 end
 function H.adapt(b,m,input)
  local profile=H.profile(m.vehicle);if profile.kind=='exosuit' then return input end
  local move=input.movement or {x=0,y=0};local n=math.sqrt(move.x*move.x+move.y*move.y)
  local f=Quaternion.forward(Unit.world_rotation(m.vehicle,0));local desired=C.direction({x=0,y=0},move)
  local dot=f.x*desired.x+f.y*desired.y;local cross=f.x*desired.y-f.y*desired.x
  local turn=cross>0 and -1 or 1;local error=math.acos(math.max(-1,math.min(1,dot)))
  local throttle=n>.01 and math.min(1,n) or 0
  local steer=n>.01 and (error>.12 and turn*math.min(1,error*1.5) or 0) or 0
  local reverse=dot<-.6
  if profile.tank then
   if n>.01 and error>.35 and not reverse then throttle=0;steer=turn end
   if reverse then steer=-steer end
   steer=math.abs(steer)>.15 and (steer<0 and -1 or 1) or 0
  else
   if error>1.1 and not reverse then throttle=math.min(throttle,.3) end
   if reverse then steer=-steer end
  end
  input.move_forward=not reverse and throttle or 0;input.move_back=reverse and throttle or 0
  input.move_left=math.max(0,-steer);input.move_right=math.max(0,steer)
  -- Select native keyboard vehicle controls; gun aim/trigger fields stay independent.
  b.vehicle_input.pad_number=rawget(_G,'KEYBOARD_MOUSE_PAD_NUMBER') or 0
  b.vehicle_input.input_data=input
  return input
 end
 function H.crushable(u,vehicle)
  local h=state(u,'health');local enemy=state(u,'enemy')
  if h.is_dead or not next(enemy) then return false end
  local cfg=LuaSettingsManager and type(LuaSettingsManager.get_settings_by_unit)=='function' and LuaSettingsManager:get_settings_by_unit(vehicle) or {}
  local melee=cfg.melee_info or {};local ap=tonumber(melee.armorpiercing)
  local armor=tonumber(h.armor_min)
  return ap~=nil and armor~=nil and armor<=ap
 end
 function H.destination(b,m,leader)
  local t=b.vehicle_order;if not t then return end
  local aboard=live(leader) and H.root(leader)==m.vehicle
  if not aboard then
   t.auto_park=nil
   if t.route_source=='automatic' then t.destination=nil;t.route_source=nil;S.cancel(b) end
   t.human_aboard=false;return
  end
  if not t.human_aboard then t.auto_park=nil;t.human_aboard=true end
  local p=pos(m.vehicle)
  if t.destination and t.route_source~='automatic' and C.distance(p,t.destination)<.85 then
   t.destination=nil;t.route_source=nil;t.auto_target=nil;S.cancel(b)
  end
  if t.auto_park or t.destination and t.route_source=='f8' then return end
  local manager=M.session.mission_manager
  local objectives=manager and type(manager.get_objectives)=='function' and manager:get_objectives() or {}
  local best,distance,index
  for i,o in ipairs(objectives) do
   if o.type~='objective_extract_lz' and o.type~='mission_objective_extract' and o.state~='complete' and o.state~='failed' and o.state~='hidden' then
    local q=o.position
    if q and type(q.x)=='number' and type(q.y)=='number' then
     local d=C.distance(p,q)
     if not distance or d<distance or d==distance and i<index then best=o;distance=d;index=i end
    end
   end
  end
  if t.auto_target and t.auto_target.state~='complete' and t.auto_target.state~='failed' and t.auto_target.state~='hidden' then best=t.auto_target end
  local all_done=manager and manager.get_all_objectives_done and manager:get_all_objectives_done()
  if not best and all_done then
   for _,o in ipairs(objectives) do
    if o.type=='objective_extract_lz' or o.type=='mission_objective_extract' then best=o;break end
   end
  end
  if not best then t.destination=nil;t.auto_target=nil;t.route_source=nil;return end
  if t.auto_target~=best then
   local q=best.position;if not q then return end
   local d=C.direction(q,p);local gap=math.max(6,H.profile(m.vehicle).length+2)
   t.destination={x=q.x+d.x*gap,y=q.y+d.y*gap,z=q.z or p.z};t.route_source='automatic';t.auto_target=best
   S.cancel(b);emit('vehicle_auto_destination',{position=t.destination,objective=best.name or best.type},b.id)
  end
 end
 function H.friendly(u)
  if H.human(u) or M.units[u] or (M.bot_origins or {})[u] or M.is_original_body and M.is_original_body(u) then return true end
  for _,e in ipairs(M.behaviors.escorts or {}) do if e.unit==u or e.id==u then return true end end
  return false
 end
 local function hook(object,key,factory)
  if not object or type(object[key])~='function' then return end
  local old=object[key];local wrapper=factory(old);object[key]=wrapper
  H.hooks[#H.hooks+1]={object=object,key=key,old=old,wrapper=wrapper}
 end
 function H.install()
  if H.installed then return end;H.installed=true
  -- Native contact Flow and vehicle melee entrypoints only. WeaponUtility and
  -- ExplosionManager do not use either wrapper and retain ordinary damage.
  hook(rawget(_G,'FlowCallbacks'),'do_damage',function(old)return function(args,...)
   local source=args and args.owner_unit;local target=args and args.unit
   if live(source) and H.driver(source) and H.friendly(target) then
    emit('vehicle_contact_protected',{source=tostring(source),target=tostring(target)},H.driver(source).id,'behavior');return
   end
   return old(args,...)
  end end)
  hook(rawget(_G,'FlowCallbacks'),'shoot_damage_ray',function(old)return function(args,...)
   local source=args and (args.attacker_unit or args.owner_unit)
   if not live(source) or not H.driver(source) then return old(args,...) end
   -- This native Flow uses an immediate ray and synchronous damage dispatch.
   -- Filter only this root vehicle's contact-ray transaction, then restore the
   -- interface even if the engine boundary raises. WeaponUtility stays untouched.
   local queued=EntityAux.queue_command_interface
   EntityAux.queue_command_interface=function(target,interface,command,data,...)
    if interface=='damageable' and command=='do_damage' and H.friendly(target)
     and data and data.owner_unit==args.owner_unit and data.attacker_unit==args.attacker_unit then return end
    return queued(target,interface,command,data,...)
   end
   local result={pcall(old,args,...)};EntityAux.queue_command_interface=queued
   if not result[1] then error(result[2],0) end
   return unpack(result,2)
  end end)
  hook(rawget(_G,'MeleeComponent'),'do_damage',function(old)return function(self,data,p,target,...)
   local source=data and (data.attacker_unit or data.owner_unit)
   if live(source) and H.driver(source) and H.friendly(target) then return end
   return old(self,data,p,target,...)
  end end)
 end
 function H.uninstall()
  for _,h in ipairs(H.hooks) do if h.object[h.key]==h.wrapper then h.object[h.key]=h.old end end
  H.hooks={};H.installed=nil;H.recovery_ticket=nil
 end
 H.install();return H
end
