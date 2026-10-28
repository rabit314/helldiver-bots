-- Small, deterministic, unseen EXO relocation after persistent noncombat blockage.
return function(M,C,S,V,emit)
 local R=M.recovery or {reservations={}};M.recovery=R
 local function live(u)return u~=nil and Unit.alive(u)end
 local function point(p)return {x=p.x,y=p.y,z=p.z or 0}end
 local function finite(x)return type(x)=='number' and x==x and math.abs(x)<math.huge end
 local function state(u,name,master)
  if not live(u) then return {} end
  if master and EntityAux.has_component_master(u,name) then return EntityAux.state_master(u,name) end
  if not master and EntityAux.has_component(u,name) then return EntityAux.state(u,name) end
  return {}
 end
 local function note(b,reason,data)
  if M.clock<(b.next_recovery_note or 0) and reason==b.recovery_note then return end
  b.next_recovery_note=M.clock+5;b.recovery_note=reason
  data=data or {};data.reason=reason
  emit('hidden_recovery_deferred',data,b.id)
 end
 function R.observe_map(info)
  if info and type(info.fade)=='number' and info.fade>0 then R.map_until=M.clock+.6 end
 end
 function R.map_closed()
  if M.clock<(R.map_until or 0) then return false,'map_fading_or_open' end
  local count=0
  for _,player in ipairs(M.session and M.session.players or {}) do
   local go=player.player_go
   if go and go:exists() then
    count=count+1
    if not go:owned() or not go:has('avatar_unit') then return false,'human_view_unknown' end
    local u=go:get('avatar_unit')
    if not live(u) or CharacterComponent.get_hud_state(u)~='normal' then return false,'map_or_hud_state' end
    local cs=state(u,'character',true);local input=state(u,'input',true)
    for _,v in ipairs({cs.input or {},input.input_data or {},input.output_table or {}}) do
     if v.map or v.map_pressed or v.show_map then return false,'map_input' end
    end
    local seat=cs.current_seat_unit
    if live(seat) and state(seat,'vehicle',true).show_map then return false,'vehicle_map' end
   end
  end
  return count==1,count==1 and nil or 'human_view_unknown'
 end
 function R.hidden(p,extent)
  if not CameraManager or type(CameraManager.get_viewport)~='function' then return false,'camera_unknown' end
  local viewport=CameraManager:get_viewport()
  if not viewport or type(viewport.window)~='function' or type(viewport.world_to_screen)~='function' then return false,'projection_unknown' end
  local w,h,ox,oy=viewport:window()
  if not finite(w) or not finite(h) or not finite(ox) or not finite(oy) or w<=0 or h<=0 then return false,'viewport_unknown' end
  local x0,y0,x1,y1=math.huge,math.huge,-math.huge,-math.huge
  local near,far=math.huge,-math.huge
  -- Include arms/body height and a margin, not merely the root point.
  local width=extent and extent.width or 4;local height=extent and extent.height or 4
  for _,x in ipairs({-width,width}) do for _,y in ipairs({-width,width}) do for _,z in ipairs({0,height}) do
   local v=viewport:world_to_screen(Vector3(p.x+x,p.y+y,p.z+z))
   if not v or not finite(v.x) or not finite(v.y) or not finite(v.z) then return false,'projection_unknown' end
   near=math.min(near,v.z);far=math.max(far,v.z)
   x0=math.min(x0,v.x);x1=math.max(x1,v.x);y0=math.min(y0,v.y);y1=math.max(y1,v.y)
  end end end
  local pad=math.max(64,math.min(w,h)*.08)
  local view={depth_min=near,depth_max=far,x_min=x0,x_max=x1,y_min=y0,y_max=y1}
  -- Native ViewportProxy maps Camera's signed forward depth to z.
  -- All eight corners behind the eye proves the whole convex body is hidden.
  if far<-.01 then return true,'behind_camera',view end
  if near<=.01 then return false,'camera_plane_intersection',view end
  return x1<ox-pad or x0>ox+w+pad or y1<oy-pad or y0>oy+h+pad,'screen_bounds',view
 end
 function R.edge(p)
  local unseen,_,view=R.hidden(p)
  if not unseen or not view then return end
  if view.depth_max<-.01 then return 'behind' end
  local viewport=CameraManager:get_viewport();local w,h,x,y=viewport:window()
  local pad=math.max(64,math.min(w,h)*.08)
  local edges={{'left',(x-pad-view.x_max)/w},{'right',(view.x_min-x-w-pad)/w},
   {'top',(y-pad-view.y_max)/h},{'bottom',(view.y_min-y-h-pad)/h}}
  local best,score
  for _,e in ipairs(edges) do if e[2]>0 and (not score or e[2]>score) then best,score=e[1],e[2] end end
  return best
 end
 local function combat(b,m)
  local status=b.vehicle_status or {};local firing=status.visible and b.target and b.target.alive and b.target.enemy
  for _,w in ipairs(status.weapons or {}) do if w.trigger or w.permitted then firing=true end end
  local rounds={}
  for _,w in ipairs(m.weapons or {}) do
   local a=w.ammo or {}
   if a.firing_auto or a.firing_single or a.charging or a.charging_shot then firing=true end
   if type(a.rounds)=='number' then
    rounds[w.unit]=a.rounds
    if b.recovery_rounds and b.recovery_rounds[w.unit] and a.rounds<b.recovery_rounds[w.unit] then firing=true end
   end
  end
  b.recovery_rounds=rounds
  local hp=state(m.vehicle,'health').hitpoints_real or state(m.vehicle,'health').hitpoints
  if type(hp)=='number' and b.recovery_hp and hp<b.recovery_hp then firing=true end
  b.recovery_hp=hp
  if firing then b.recovery_combat_until=M.clock+8 end
  return firing or M.clock<(b.recovery_combat_until or 0)
 end
 local function same_side(source,p,leader)
  if C.distance(p,leader)<10 or C.distance(p,source)>12.1 then return false end
  local a,z=C.direction(leader,source),C.direction(leader,p)
  return a.x*z.x+a.y*z.y>=.85
 end
 local function actors(b,p,z)
  if S.vehicle_route_reject and S.vehicle_route_reject(b,p,z) then return false end
  for id,r in pairs(R.reservations) do
   if r.expires<M.clock or r.generation~=M.generation then R.reservations[id]=nil
   elseif id~=b.id and C.distance(p,r.position)<6.5 then return false end
  end
  return true
 end
 function R.cancel(b,reason)
  local q=b.hidden_recovery;if not q then return end
  b.hidden_recovery=nil;b.recovery_probe=nil
  S.cancel(b);S.invalidate(b)
  if b.active and live(b.unit) then S.create_probes(b,M.session) end
  note(b,reason,{from=q.source,leader=q.leader,candidate=q.candidate,stage=q.stage,
   generation=q.generation,rejected=q.rejected,checked_segments=#q.path,last_probe=b.last_probe_evidence})
 end
 local function current(b,m,q)
  return b.hidden_recovery==q and b.active and live(b.unit) and live(m.vehicle)
   and q.order==b.vehicle_order
   and b.mounted and b.mounted.vehicle==m.vehicle and q.generation==M.generation and q.session==M.session
 end
 local function next_candidate(b,q,reason)
  q.rejected[#q.rejected+1]={position=q.candidate,reason=reason}
  q.candidate=nil;q.stage='candidate';q.pending=nil;q.last_rejection=reason;q.tried=q.tried+1
 end
 local function cast(b,m,q,a,z,budget,callback)
  if b.edge_probe then return end
  b.recovery_probe=true
  local accepted=S.probe(b,a,z,budget,function(clear,ground,reason)
   if current(b,m,q) then q.pending=nil;callback(clear,ground,reason) end
  end,m.vehicle)
  b.recovery_probe=nil
  if accepted and b.edge_probe then q.pending=true end
  return accepted
 end
 local function end_goal(b,p,leader)
  local d=C.direction(leader,p)
  if C.distance(p,leader)>30 then
   local v={x=p.x-d.x*18,y=p.y-d.y*18,z=p.z}
   if actors(b,v,v) then return v end
   return
  end
  for _,angle in ipairs({0,math.pi/8,-math.pi/8,math.pi/4,-math.pi/4}) do
   local c,s=math.cos(angle),math.sin(angle)
   local v={x=leader.x+(d.x*c-d.y*s)*7,y=leader.y+(d.x*s+d.y*c)*7,z=leader.z}
   if actors(b,v,v) then return v end
  end
 end
 local function overlap(b,m,q)
  q.pending=true;local token={};q.overlap=token
  local ignore={[b.unit]=true,[m.vehicle]=true};if m.seat then ignore[m.seat]=true end
  for _,w in ipairs(m.weapons or {}) do ignore[w.unit]=true end
  local p=q.candidate;local width=(m.clearance or 1.45)+.3
  PhysicsWorld.overlap(World.physics_world(M.session.world_proxy:get_world()),
   S.guard(b,'recovery_landing_overlap',function(found)
    if not current(b,m,q) or q.overlap~=token then return end
    assert(type(found)=='table','Invalid landing overlap reply')
    q.pending=nil
    for _,a in ipairs(found) do local u=Actor.unit(a)
     if not ignore[u] then next_candidate(b,q,'landing_occupied');return end
    end
    q.stage='commit';q.landing_checked=M.clock
   end,function()if current(b,m,q) then next_candidate(b,q,'overlap_error') end end),
   'shape','capsule','position',Vector3(p.x,p.y,p.z+width+.65),'size',Vector3(width,.5,0),
   'rotation',Quaternion.look(Vector3.up(),Vector3.forward()),'collision_filter','spawn_check')
 end
 local function commit(b,m,q,leader)
  local p=point(Unit.world_position(m.vehicle,0));local candidate=q.candidate
  local closed,why=R.map_closed()
  if not closed then R.cancel(b,why);return end
  local source_hidden=R.hidden(p);local target_hidden=R.hidden(candidate)
  if not source_hidden or not target_hidden then R.cancel(b,'source_or_destination_visible');return end
  if C.distance(p,q.source)>.35 or not same_side(q.source,candidate,leader) or not actors(b,candidate,candidate)
    or M.clock-(q.landing_checked or 0)>.25 or M.clock-(q.path_checked or 0)>2 then R.cancel(b,'conditions_changed');return end
  if C.distance(q.leader,leader)>2 and C.distance(q.goal,leader)>C.distance(candidate,leader)-6 then
   q.goal=end_goal(b,candidate,leader);q.leader=point(leader);q.cursor=point(candidate)
   q.path={point(candidate)};q.stage='path';return
  end
  if combat(b,m) then R.cancel(b,'combat');return end
  local cs=state(b.unit,'character',true);local seat=state(m.seat or m.vehicle,'seat',true)
  if cs.current_seat_unit~=(m.seat or m.vehicle) or (seat.seated_units or {})[1]~=b.unit then R.cancel(b,'pilot_changed');return end
  if not Unit.mover(m.vehicle) or not EntityAux.has_component_master(m.vehicle,'mover')
    or not EntityAux.has_component(m.vehicle,'mover') then R.cancel(b,'native_mover_unavailable');return end
  local payload={};Vector3Aux.box(payload,Vector3(candidate.x,candidate.y,candidate.z))
  b.vehicle_input.output_table=C.neutral()
  -- Execute both halves together while the same map/camera checks still apply.
  q.warp_started=true
  -- Native master queues its slave half. Execute that exact command now so
  -- no delayed duplicate can move the suit back after visibility changes.
  local queued=EntityAux.queue_command_slave;local delivered=false
  EntityAux.queue_command_slave=function(u,component,command,data,...)
   if u==m.vehicle and component=='mover' and command=='teleport' then
    assert(not delivered,'Duplicate native relocation');delivered=true
    return EntityAux.command_slave_immediately(u,component,command,data)
   end
   return queued(u,component,command,data,...)
  end
  local ok,err=pcall(EntityAux.command_master_immediately,m.vehicle,'mover','position_teleport',payload)
  EntityAux.queue_command_slave=queued
  if not ok then error(err,0) end
  assert(delivered,'Native relocation was not delivered')
  local actual=point(Unit.world_position(m.vehicle,0))
  b.hidden_recovery=nil;b.recovery_probe=nil;b.recovery_anchor=actual;b.recovery_anchor_time=M.clock
  b.recovery_next=M.clock+25;b.vehicle_step=nil;b.vehicle_progress=nil;b.vehicle_stuck=0
  b.vehicle_push=nil;b.vehicle_contacts=nil;b.vehicle_block=nil;b.vehicle_visited=nil;b.coarse_route=nil
  b.navigation_observation=nil;b.last_position=nil;b.step_check=nil;b.interaction_check=nil
  S.cancel(b);S.invalidate(b);S.create_probes(b,M.session)
  if C.distance(actual,candidate)>.3 or math.abs(actual.z-candidate.z)>.3 then
   note(b,'native_relocation_not_confirmed',{from=q.source,requested=candidate,actual=actual});return
  end
  q.path[1]=point(actual)
  b.route={status='ready',origin=actual,goal=q.path[#q.path],destination=q.goal,path=q.path,index=2,
   follow=true,count=#q.path,tolerance=.1,arrival=.15,ready_at=M.clock}
  b.recovery_path_until=M.clock+15
  R.reservations[b.id]={position=actual,expires=M.clock+2,generation=M.generation}
  emit('hidden_recovery_relocated',{from=q.source,to=actual,requested=candidate,leader=point(leader),
   distance=C.distance(q.source,actual),bearing_preserved=true,map_closed=true,source_hidden=true,destination_hidden=true,
   checked_path=q.path,checked_segments=#q.path,corridor_scope=C.distance(candidate,leader)>30 and 'local_escape' or 'follow_ring',landing_checked=q.landing_checked,path_checked=q.path_checked,
   candidates_rejected=q.tried,last_rejection=q.last_rejection,rejected=q.rejected,generation=M.generation},b.id)
 end
 function R.drive(b,m,leader,dt,budget,friends,spacing)
  if not m.pilot or not b.vehicle_order or b.vehicle_order.destination or not live(m.vehicle) then R.cancel(b,'not_following');return false end
  local p=point(Unit.world_position(m.vehicle,0));local health=state(b.unit,'health')
  local fighting=combat(b,m) or spacing~=nil
  if health.is_downed or health.is_dead or fighting or M.session.wants_exit then
   R.cancel(b,fighting and 'combat' or 'unavailable');b.recovery_anchor=p;b.recovery_anchor_time=M.clock;return false
  end
  if b.recovery_vehicle~=m.vehicle or b.recovery_generation~=M.generation then
   b.recovery_vehicle=m.vehicle;b.recovery_generation=M.generation;b.recovery_anchor=p;b.recovery_anchor_time=M.clock
   b.hidden_recovery=nil;b.recovery_next=0
  end
  if C.distance(p,b.recovery_anchor)>.8 then
   R.cancel(b,'movement_resumed');b.recovery_anchor=p;b.recovery_anchor_time=M.clock;return false
  end
  local q=b.hidden_recovery
  if q and q.order~=b.vehicle_order then
   R.cancel(b,'follow_order_changed');b.recovery_anchor=p;b.recovery_anchor_time=M.clock;return false
  end
  if not q then
   if M.clock-(b.recovery_anchor_time or M.clock)<12 or M.clock<(b.recovery_next or 0) or C.distance(p,leader)<12 then return false end
   local closed,why=R.map_closed();if not closed then note(b,why);return false end
   local hidden,view,evidence=R.hidden(p);if not hidden then note(b,'source_visible_or_unknown',{view=view,projection=evidence});return false end
   if type(Unit.mover)~='function' or type(EntityAux.command_master_immediately)~='function'
    or type(EntityAux.command_slave_immediately)~='function' or type(EntityAux.queue_command_slave)~='function'
    or not Vector3Aux or type(Vector3Aux.box)~='function'
    or type(PhysicsWorld.overlap)~='function' then note(b,'native_recovery_api_unavailable');return false end
   q={session=M.session,generation=M.generation,order=b.vehicle_order,source=p,leader=point(leader),started=M.clock,index=0,tried=0,stage='candidate',path={},rejected={}}
   b.hidden_recovery=q;S.cancel(b);S.invalidate(b);S.create_probes(b,M.session)
   emit('hidden_recovery_started',{position=p,leader=point(leader),stationary_seconds=M.clock-b.recovery_anchor_time,stationary_radius=.8,max_shift=12,source_visibility=view,projection=evidence},b.id)
  end
  local closed,why=R.map_closed()
  if not closed then R.cancel(b,why);return false end
  if M.clock-q.started>8 or (q.index>=40 and q.stage=='candidate') then
   R.cancel(b,'no_checked_hidden_landing');b.recovery_next=M.clock+10;return false
  end
  if q.pending then return true end
  if q.stage=='candidate' then
   q.index=q.index+1
   local angles={0,math.pi/4,-math.pi/4,math.pi/2,-math.pi/2,3*math.pi/4,-3*math.pi/4,math.pi}
   local radii={3.6,5.4,7.2,9,12};local radius=radii[math.floor((q.index-1)/8)+1]
   if not radius then return true end
   local d=C.direction(q.source,leader);local angle=angles[(q.index-1)%8+1];local c,s=math.cos(angle),math.sin(angle)
   local candidate={x=q.source.x+(d.x*c-d.y*s)*radius,y=q.source.y+(d.x*s+d.y*c)*radius,z=q.source.z}
   q.candidate=candidate
   local rejection=not same_side(q.source,candidate,leader) and 'bearing_or_range'
    or (not R.hidden(candidate) and 'landing_visible_or_unknown') or (not actors(b,candidate,candidate) and 'landing_actor')
   if rejection then next_candidate(b,q,rejection);return true end
   q.candidate=candidate;q.goal=end_goal(b,candidate,leader);q.leader=point(leader);q.path={point(candidate)};q.cursor=point(candidate)
   if not q.goal then next_candidate(b,q,'follow_ring_occupied');return true end
   q.stage='path'
  end
  if q.stage=='path' then
   if not q.goal then next_candidate(b,q,'missing_goal');return true end
   local d=C.direction(q.cursor,q.goal);local length=math.min(1.8,C.distance(q.cursor,q.goal))
   if length<.15 then q.path_checked=M.clock;q.floor_index=0;q.stage='floor';return true end
   local to={x=q.cursor.x+d.x*length,y=q.cursor.y+d.y*length,z=q.cursor.z}
   if #q.path>64 or not actors(b,q.cursor,to) then next_candidate(b,q,'corridor_actor');return true end
   cast(b,m,q,q.cursor,to,budget,function(clear,ground,reason)
    if not clear or not ground then next_candidate(b,q,reason or 'corridor_unchecked');return end
    if #q.path==1 then q.candidate.z=ground.z end
    q.cursor=point(ground);q.path[#q.path+1]=point(ground)
   end)
  elseif q.stage=='floor' then
   local width=(m.clearance or 1.45)+.3;local offsets={{0,0},{width,0},{-width,0},{0,width},{0,-width}}
   q.floor_index=q.floor_index+1;local offset=offsets[q.floor_index]
   if not offset then q.stage='overlap';return true end
   local a={x=q.candidate.x+offset[1],y=q.candidate.y+offset[2],z=q.candidate.z}
   local submitted=cast(b,m,q,a,{x=a.x+.12,y=a.y,z=a.z},budget,function(clear,ground,reason)
    if not clear or not ground or math.abs(ground.z-q.candidate.z)>.35 then next_candidate(b,q,reason or 'landing_floor');return end
   end)
   if not submitted then q.floor_index=q.floor_index-1 end
  elseif q.stage=='overlap' then overlap(b,m,q)
  elseif q.stage=='commit' then commit(b,m,q,leader) end
  return true
 end
 function R.safe_drive(...)
  local b=select(1,...);local ok,held=pcall(R.drive,...)
  if ok then return held end
  pcall(R.cancel,b,'recovery_error');b.recovery_next=M.clock+25
  if M.clock>=(b.next_recovery_error or 0) then
   b.next_recovery_error=M.clock+5
   local printed,message=pcall(tostring,held)
   pcall(emit,'hidden_recovery_error',{message=printed and message or 'Unprintable recovery error',policy='recovery deferred'},b.id,'errors')
  end
  return false
 end
 return R
end
