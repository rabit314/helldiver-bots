-- Native route probes and scoped input adapters. No physical controller is created.
return function(M,C,B,N,emit)
 local S={}
 local function live(u)return u~=nil and Unit.alive(u)end
 local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
 local function vector(v)
  local kind=type(v)
  return (kind=='table' or kind=='userdata' or kind=='cdata') and finite(v.x) and finite(v.y) and finite(v.z)
 end
 function S.select_hits(hits,ignore)
  assert(type(hits)=='table','Physics all-hit reply must be a table')
  local nearest=math.huge;local selected;local skipped=0
  for _,h in ipairs(hits) do
   assert(type(h)=='table' and finite(h[2]) and h[2]>=0 and vector(h[1]) and vector(h[3]),'Malformed physics hit')
   local u=h[4] and Actor.unit(h[4])
   if u and ignore and ignore[u] then skipped=skipped+1
   elseif h[2]<nearest then nearest=h[2];selected=h end
  end
  return selected,skipped
 end
 local function message(err)
  local ok,value=pcall(tostring,err);return ok and value or 'Unprintable Lua callback error'
 end
 local function callback_fault(b,purpose,err,recovery_error)
  b.callback_faults=(b.callback_faults or 0)+1
  b.step_check=nil;b.vehicle_step=nil;b.visibility=nil;b.release_permitted=false
  b.vehicle_permissions={};b.vehicle_triggers={}
  if b.route then b.route.status='failed';b.route.pending=nil;b.route.reason='physics_callback_error' end
  if b.vehicle_input then b.vehicle_input.output_table=C.neutral() end
  pcall(function()
   if b.active and live(b.unit) then
    if not b.mounted then EntityAux.queue_command_master(b.unit,'mover','set_movement',{x=0,y=0,z=0}) end
    EntityAux.queue_command_master(b.unit,'character','input',C.neutral())
   end
  end)
  if M.clock>=(b.next_callback_error or 0) then
   b.next_callback_error=M.clock+5
   pcall(emit,'physics_callback_error',{purpose=purpose,message=message(err),
    recovery_error=recovery_error and message(recovery_error),count=b.callback_faults,
    recovery='affected movement/fire stopped; fresh checks required'},b.id,'errors')
  end
 end
 function S.guard(b,purpose,handler,recover)
  return function(...)
   local ok,err=pcall(handler,...)
   if not ok then
    local recovery_error
    if recover then
     local repaired,why=pcall(recover,err)
     if not repaired then recovery_error=why end
    end
    -- Errors from recovery, diagnostics or neutralization must not escape the
    -- engine's update_scene callback either. Native memory faults are separate.
    pcall(callback_fault,b,purpose,err,recovery_error)
   end
  end
 end
 local function master(u,n)
  if live(u) and EntityAux.has_component_master(u,n) then return EntityAux.state_master(u,n) end
 end
 local function slave(u,n)
  if live(u) and EntityAux.has_component(u,n) then return EntityAux.state(u,n) end
 end
 local function clear_route(b)
  N.cancel(b.route);b.route=nil
 end
 S.cancel=clear_route
 function S.navigation_target(b)
  local t=b.objective or b.vehicle_order or b.job
  if not t then return end
  if b.objective and (b.objective.surface_offset or b.objective.cursor_active) then return end
  return t.unit
 end
 function S.invalidate(b)
  b.edge_probe=nil;b.interaction_check=nil;b.step_check=nil
 end
 function S.create_probes(b,s)
  if M.retain_rays then M.retain_rays(b.route_rays) end
  local physics=World.physics_world(s.world_proxy:get_world());b.route_rays={}
  local ray_set=b.route_rays
  ray_set.pending={}
  local function finish(q)
   if q.count~=(q.expected or 5) or q.delivered then return end
   q.delivered=true;if b.edge_probe==q then b.edge_probe=nil end
   b.last_probe_evidence={from=q.from,to=q.target,hits=q.hits}
   if b.active and live(b.unit) and q.generation==M.generation then q.callback(q.clear,q.ground,q.reason) end
  end
  for _,key in ipairs({'left','right','middle','outer_left','outer_right','end_ground','mid_ground'}) do
   local ground=key=='end_ground' or key=='mid_ground'
   local answering
   b.route_rays[key]=PhysicsWorld.make_raycast(physics,S.guard(b,'route_probe:'..key,function(hit,p,d,normal,actor)
    answering=nil
    ray_set.pending[key]=nil
    local q=b.edge_probe
    if not q or not b.active or not live(b.unit) or b.route_rays~=ray_set or q.generation~=M.generation then return end
    answering=q
    -- Drain the whole batch before recycling its native ray objects, even on cancellation.
    if q.answers[key] then return end
    q.answers[key]=true;q.count=q.count+1
    -- Closest-only casts stop inside the suit itself and conceal the wall or
    -- floor beyond it. Select the nearest relevant result from the native list.
    local skipped=0
    if type(hit)=='table' then
     -- The native all-hit callback also supplies a numeric query tag (-1).
     -- Its presence never changes the first argument's list contract.
     local selected;selected,skipped=S.select_hits(hit,q.ignore)
     hit=selected~=nil
     p,d,normal,actor=nil,nil,nil,nil
     if selected then p,d,normal,actor=unpack(selected) end
    elseif hit then
     assert(hit==true and vector(p) and finite(d) and vector(normal),'Malformed closest-hit reply')
    end
    local hit_unit=hit and actor and Actor.unit(actor)
    local target_body=hit_unit and q.ignore[hit_unit]
    q.hits=q.hits or {}
    if hit then q.hits[key]={position=p and {x=p.x,y=p.y,z=p.z},normal=normal and {x=normal.x,y=normal.y,z=normal.z},
     distance=d,unit=hit_unit and tostring(hit_unit),unit_id=M.navigation_trace and M.navigation_trace.id(hit_unit),
     ignored=target_body==true,ignored_hits=skipped,query='all',filter=ground and 'spawn_check' or 'npc_ai_feeler'}
    elseif skipped>0 then q.hits[key]={ignored_hits=skipped,query='all',no_relevant_hit=true,
     filter=ground and 'spawn_check' or 'npc_ai_feeler'} end
    if ground then
     if target_body then
      if key=='end_ground' then q.ground=q.target end
     elseif not hit or not p or not normal or normal.z<.65 or math.abs(p.z-q.from.z)>1 then
      q.clear=false;q.reason='ground'
     elseif key=='end_ground' then q.ground={x=p.x,y=p.y,z=p.z} end
    elseif hit and hit_unit~=b.unit and not target_body then q.clear=false;q.reason='obstacle' end
    finish(q)
   end,function()
    ray_set.pending[key]=nil
    local q=answering
    if q and b.route_rays==ray_set and q.generation==M.generation then
     if not q.answers[key] then q.answers[key]=true;q.count=q.count+1 end
     q.clear=false;q.reason='physics_callback_error';finish(q)
    end
   end),'all','collision_filter',ground and 'spawn_check' or 'npc_ai_feeler')
  end
 end
 function S.probe(b,a,p,budget,callback,ignore_unit)
  if b.edge_probe and M.clock-(b.edge_probe.started or M.clock)>.75 then
   -- Replace the entire ray set so a late result cannot answer a newer batch.
   emit('probe_timeout',{purpose=b.job and b.job.kind or (b.objective and 'objective' or 'movement')},b.id)
   b.edge_probe=nil;S.create_probes(b,M.session)
  end
  local wide=b.mounted and b.mounted.pilot and (b.recovery_probe or (b.route and b.route.status=='planning'))
  local expected=wide and 7 or 5
  if b.edge_probe or budget.route<expected or not b.route_rays then return false end
  local start_risk=B.risk(M.behaviors,a,b.unit);local end_risk=B.risk(M.behaviors,p,b.unit)
  local mid_risk=B.risk(M.behaviors,{x=(a.x+p.x)/2,y=(a.y+p.y)/2,z=((a.z or 0)+(p.z or 0))/2},b.unit)
  if (end_risk>0 and end_risk>=start_risk) or (mid_risk>0 and mid_risk>=start_risk) then
   callback(false,nil,'hazard');return true
  end
  budget.route=budget.route-expected
  local d=C.direction(a,p);local length=C.distance(a,p)
  if length<.1 then d={x=1,y=0};length=.1 end
  local ignore={[b.unit]=true};if ignore_unit then ignore[ignore_unit]=true end
  local mounted=b.mounted
  if mounted and mounted.pilot then
   if mounted.seat then ignore[mounted.seat]=true end
   if mounted.vehicle then ignore[mounted.vehicle]=true end
   for _,w in ipairs(mounted.weapons or {}) do ignore[w.unit]=true end
   if M.mobility then
    for _,v in ipairs(M.mobility.assembly(mounted.vehicle)) do ignore[v]=true end
    if not b.recovery_probe then for _,e in ipairs(M.enemy_cache or {}) do
     if live(e.id) and M.mobility.crushable(e.id,mounted.vehicle) then ignore[e.id]=true end
    end end
   end
  end
  b.edge_probe={from=a,target=p,ignore_unit=ignore_unit,ignore=ignore,callback=callback,answers={},count=0,expected=expected,clear=true,generation=M.generation,started=M.clock}
  for _,key in ipairs(wide and {'left','right','middle','outer_left','outer_right'} or {'left','right','middle'}) do
   local width=b.mounted and b.mounted.pilot and (b.mounted.clearance or 1.45) or .38
   local side=key=='left' and width or (key=='right' and -width or 0)
   if key=='outer_left' then side=width+.3 elseif key=='outer_right' then side=-width-.3 end
   b.route_rays.pending[key]=true
   b.route_rays[key]:cast(Vector3(a.x-d.y*side,a.y+d.x*side,a.z+.55),Vector3(d.x,d.y,0),length)
  end
  for _,key in ipairs({'end_ground','mid_ground'}) do
   local t=key=='end_ground' and 1 or .5
   b.route_rays.pending[key]=true
   b.route_rays[key]:cast(Vector3(a.x+(p.x-a.x)*t,a.y+(p.y-a.y)*t,a.z+1.2),Vector3(0,0,-1),2.4)
  end
  return true
 end
 function S.interaction_ready(b,p,job,budget)
  if job.native_interaction then
   local i=master(b.unit,'interactor') or {}
   return i.enabled~=false and not i.busy and i.interactable_unit==job.unit
    and i.interactable_component==job.component
  end
  local target=job.target_position or job.position
  if math.abs((p.z or 0)-(target.z or 0))>1.3 then return false end
  local check=b.interaction_check
  if check and check.key==job.key and M.clock-check.time<.5
    and C.distance(p,check.from)<.3 and C.distance(target,check.target)<.3 then return check.clear end
  local key=job.key
  S.probe(b,p,target,budget,function(clear,_,reason)
   b.interaction_check={key=key,from=p,target=target,time=M.clock,clear=clear,reason=reason}
   if job.kind=='revive' then
    job.approach_blocked=not clear
    if not clear and M.clock>=(job.next_side_step or 0) then
     job.approach_angle=(job.approach_angle or 0)+math.pi/3
     job.approach_index=(job.approach_index or 0)+1;job.next_side_step=M.clock+1
     emit('revive_approach_blocked',{reason=reason,attempt=job.approach_index},b.id)
    end
   elseif job.kind=='objective' and b.objective==job.objective and not clear then
    M.objectives.next_approach(b,reason or 'interaction_path_blocked')
   end
  end,job.unit)
  return false
 end
 function S.navigate(b,p,goal,budget,follow)
  b.follow_navigation=follow==true and not b.mounted
  if S.coarse_goal then goal=S.coarse_goal(b,p,goal) end
  local q=b.route
  if q then
   local a,z=C.direction(p,q.goal),C.direction(p,goal)
   local changed=C.distance(q.destination or q.goal,goal)>2
    and (not follow or not q.follow or a.x*z.x+a.y*z.y<-.5)
   local stalled=q.status=='ready' and q.ready_at and M.clock-q.ready_at>2 and b.stuck_seconds>1.6
   -- A moving perimeter is not a new order. Finish the bounded checked detour
   -- instead of restarting its async search every two metres of leader travel.
   if changed or stalled then clear_route(b);b.stuck_seconds=0 end
  end
  if not b.route and b.stuck_seconds>1 and M.clock>=(b.route_retry or 0) then
   local endpoint=goal
   if C.distance(p,goal)>12 then
    local d=C.direction(p,goal);endpoint={x=p.x+d.x*12,y=p.y+d.y*12,z=p.z}
   end
   b.route=N.new(p,endpoint,M.clock);b.route.destination=goal;b.route.follow=follow==true
   emit('route_started',{goal=endpoint},b.id)
  end
  q=b.route
  if not q then return goal,false end
  if S.vehicle_route_config then S.vehicle_route_config(b,q) end
  if q.pending and b.mounted and b.mounted.pilot and b.edge_probe
    and M.clock-b.edge_probe.started>.75 then q.status='failed';q.reason='route_probe_timeout';q.pending=nil end
  if q.status=='planning' and b.mounted and b.mounted.pilot and q.slice_at and M.clock>=q.slice_at and not q.pending then
   q.slice_at=M.clock+2;q.reason='route_slice'
   if S.vehicle_partial_route then S.vehicle_partial_route(b,q) end
   if q.status=='planning' then q.reason=nil end
  end
  for advance=1,12 do
  N.advance(q,M.clock,function(a,z,cb)
   if S.vehicle_route_reject and S.vehicle_route_reject(b,a,z) then cb(false);return true end
   return S.probe(b,a,z,budget,cb,
   (b.mounted and b.mounted.pilot and b.mounted.vehicle) or
   (b.objective and not b.objective.surface_offset and not b.objective.cursor_active and b.objective.unit))end)
  if q.pending or q.status~='planning' or not (b.mounted and b.mounted.pilot) then break end
  end
  if q.status=='planning' and b.mounted and b.mounted.pilot and q.slice_at and M.clock>=q.slice_at and not q.pending then
   q.slice_at=M.clock+2;q.reason='route_slice'
   if S.vehicle_partial_route then S.vehicle_partial_route(b,q) end
   if q.status=='planning' then q.reason=nil end
  end
  if q.status=='failed' and S.vehicle_partial_route then S.vehicle_partial_route(b,q) end
  if q.status=='failed' then
   if M.navigation_trace then M.navigation_trace.route(b,q,'failed') end
   if b.objective and M.objectives then M.objectives.route_failed(b) end
   emit('route_failed',{reason=q.reason},b.id)
   B.release(M.behaviors,b,'blocked',M.clock,emit);clear_route(b);b.route_retry=M.clock+4;b.stuck_seconds=0
   return goal,true
  end
  local waypoint=N.waypoint(q,p)
  if waypoint then
   if not q.ready_at then
    q.ready_at=M.clock;b.stuck_seconds=0;b.progress_time=0;b.progress_distance=0;b.progress_origin=nil
    if b.controller then b.controller.avoid_side=nil end
    emit('route_ready',{waypoints=#q.path,nodes=q.count},b.id)
    if M.navigation_trace then M.navigation_trace.route(b,q,q.partial_reason and 'checked_partial' or 'checked_route') end
   end
   if C.distance(p,q.goal)<(q.arrival or .7) then clear_route(b) end
   return waypoint,false
  end
  return goal,true
 end
 -- Check the next step for holes as well as walls. Results expire and are tied to direction.
 function S.ground_guard(b,p,input,budget,ignore_unit)
  local move=input.movement;if move.x*move.x+move.y*move.y<.01 then return end
  local d=C.direction({x=0,y=0},move);local check=b.step_check
  local function valid(q)
   return q and M.clock-q.time<.65 and C.distance(p,q.from)<.5
    and d.x*q.direction.x+d.y*q.direction.y>.85 and q.ignore_unit==ignore_unit
  end
  -- Renew before clearance expires. Waiting until expiry inserts a zero-input
  -- frame on every refresh, repeatedly stopping/restarting native sprint.
  if not valid(check) or (check.clear and (C.distance(p,check.from)>=.15 or M.clock-check.time>.25)) then
   local length=1.1
   if b.objective and (b.objective.surface_offset or b.objective.cursor_active) and b.job_goal then length=math.min(length,C.distance(p,b.job_goal)) end
   local target={x=p.x+d.x*length,y=p.y+d.y*length,z=p.z}
   S.probe(b,p,target,budget,function(clear)
    b.step_check={from=p,direction=d,time=M.clock,clear=clear,ignore_unit=ignore_unit}
   end,ignore_unit)
  end
  -- Hazard rejection can call back synchronously; use its updated result too.
  check=b.step_check
  if not valid(check) or not check.clear then input.movement={x=0,y=0,z=0};input.sprint=false end
 end
 function S.mounted(b,leader)
  local c=master(b.unit,'character') or {};local seat=c.current_seat_unit
  if not live(seat) then b.vehicle_input=nil;return end
  local lc=master(leader,'character') or {};local vehicle=lc.current_seat_unit
  local vs=slave(vehicle,'seat');local attached=master(seat,'stationary_weapon') or {}
  local keep=vs and vs.seated_units and vs.seated_units[1]==leader and (seat==vehicle or attached.attached_to_unit==vehicle)
  if (not keep or b.post or b.guard_request) and M.clock>=(b.next_exit or 0) then
   EntityAux.queue_command_master(seat,'seat','exit_seat',{unit=b.unit,force=false});b.next_exit=M.clock+1
  end
  local gun
  for _,u in ipairs(c.current_stationary_weapon_units or {}) do
   local a=master(u,'stationary_weapon')
   if a and a.controller_unit==b.unit and EntityAux.has_interface(u,'weapon') then gun=u;break end
  end
  local a=master(gun,'stationary_weapon') or {}
  b.vehicle_input=b.vehicle_input or {output_table=C.neutral()}
  return {seat=seat,vehicle=vehicle,gun=gun,info=a.stationary_info or {},keep=keep}
 end
 function S.install()
  if M.input_hook then return end
  local original=EntityAux.state_master
  local wrapper=function(u,name,...)
   local b=M.units[u]
   if name=='input' and b and b.active and (b.vehicle_input or b.objective_input) then return b.vehicle_input or b.objective_input end
   return original(u,name,...)
  end
  M.input_hook={original=original,wrapper=wrapper};EntityAux.state_master=wrapper
  -- Releasing a charged weapon fires it. Suppress an unsafe release only for a tracked
  -- companion weapon; native heat, charge speed, ammunition and damage stay unchanged.
  M.weapon_hooks={}
  for _,name in ipairs({'ArcweaponComponent','LauncherComponent'}) do
   local component=rawget(_G,name)
   if component and component.command_master then
    local old=component.command_master
    local wrapped=function(self,u,ctx,cmd,data,...)
     local b=M.weapon_owners and M.weapon_owners[u];local a=ctx.state
     local permitted=b and b.vehicle_permissions and b.vehicle_permissions[u]
     if permitted==nil then permitted=b and b.release_permitted end
     if b and b.active and cmd=='firing_auto' and not data and not permitted
       and ((a.charging and a.heat~=nil) or (a.fire_on_release and a.charging_shot)) then data=true end
     return old(self,u,ctx,cmd,data,...)
    end
    M.weapon_hooks[#M.weapon_hooks+1]={component=component,original=old,wrapper=wrapped}
    component.command_master=wrapped
   end
  end
 end
 function S.uninstall()
  local h=M.input_hook
  if h and EntityAux.state_master==h.wrapper then EntityAux.state_master=h.original end
  M.input_hook=nil
  for _,w in ipairs(M.weapon_hooks or {}) do
   if w.component.command_master==w.wrapper then w.component.command_master=w.original end
  end
  M.weapon_hooks={}
 end
 return S
end
