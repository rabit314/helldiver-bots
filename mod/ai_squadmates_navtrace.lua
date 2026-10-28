-- Bounded incident evidence, collision-edge memory and mission identity.
return function(M,C,S,N,V,emit)
 if M.navigation_trace then return M.navigation_trace end
 local D={generation=-1,ids=setmetatable({}, {__mode='k'}),next_id=0,incidents=0}
 M.navigation_trace=D
 local function point(p)
  if not p then return end
  return {x=p.x,y=p.y,z=p.z or 0}
 end
 local function live(u)return u~=nil and Unit.alive(u)end
 function D.id(u)
  if not u then return end
  if not D.ids[u] then D.next_id=D.next_id+1;D.ids[u]=D.next_id end
  return D.ids[u]
 end
 local function scalars(source)
  local result={}
  if type(source)=='table' then for k,v in pairs(source) do
   if type(k)=='string' and (k:find('seed') or k:find('name') or k:find('type') or k=='id')
    and (type(v)=='string' or type(v)=='number' or type(v)=='boolean') then result[k]=v end
  end end
  return result
 end
 function D.context()
  local s=M.session or {};local level=s.generated_level or {}
  local identity=tostring(level.seed)..':'..tostring(level.mission_type_name)..':'..tostring(s.planet_name)
  if D.generation==M.generation and D.level==level and D.identity==identity then return end
  D.level=level;D.identity=identity
  D.generation=M.generation;D.cache={};D.cache_order={};D.cache_cursor=1;D.edges=D.edges or 0;D.next_map_batch=0
  D.map_tiles={};D.map_cursor=1;local seen={};local omitted=0
  for _,source in ipairs({level.collision_map or {},level.edge_map or {}}) do if type(source)=='table' then
   for key in pairs(source) do if type(key)=='number' and not seen[key] then
    seen[key]=true
    if #D.map_tiles<4096 then
     local y=math.floor(key/2000)-1000;local x=key-(y+1000)*2000-1000
     D.map_tiles[#D.map_tiles+1]={x=x,y=y,edge=not not (level.edge_map and level.edge_map[key]),
      present=not not (level.collision_map and level.collision_map[key])}
    else omitted=omitted+1 end
   end end
  end end
  emit('navigation_context',{generation=M.generation,runtime=M.revision,level=scalars(level),session=scalars(s),
   mission=scalars(s.mission_manager),map_identity_complete=false,
   identity_note='Only exposed fields; absent planet/seed/name are unknown. Geometry can change during play.',
   backend='native_generated_level_waypoints_and_cached_collision_astar',
   native_route_query=type(level.get_waypoints)=='function' and 'available; coarse suggestions require hull checks' or 'unavailable',
   edge_memory_limit=4096,incident_edge_limit=2048,map_tile_count=#D.map_tiles,map_tiles_omitted=omitted,
   tile_size=24,map_note='Native generated tile layout; current physical props and EXO clearance require ray evidence'})
 end
 function S.coarse_goal(b,p,goal)
  if not ((b.mounted and b.mounted.pilot) or b.follow_navigation) then return goal end
  if b.route and b.route.status=='ready' and M.clock<(b.recovery_path_until or 0) then return goal end
  local s=M.session;local level=s and s.generated_level
  if not level or type(level.get_waypoints)~='function' or type(level.is_position_on_level)~='function' then return goal end
  local route=b.coarse_route
  local changed=not route or route.generation~=M.generation or C.distance(route.destination,goal)>18
   or math.floor(route.destination.x/24)~=math.floor(goal.x/24) or math.floor(route.destination.y/24)~=math.floor(goal.y/24)
  if changed and M.clock>=(b.next_coarse_query or 0) and C.distance(p,goal)>28 then
   b.next_coarse_query=M.clock+2
   local start=Vector3(p.x,p.y,p.z or 0);local target=Vector3(goal.x,goal.y,goal.z or 0)
   local valid,onlevel=pcall(level.is_position_on_level,level,start)
   if valid and onlevel then
    local ok,path=pcall(level.get_waypoints,level,start,target)
    if ok and type(path)=='table' and #path>0 and #path<=128 then
     local copied={};local finite=true
     for _,v in ipairs(path) do
      if type(v.x)~='number' or type(v.y)~='number' or v.x~=v.x or v.y~=v.y or math.abs(v.x)>100000 or math.abs(v.y)>100000 then finite=false;break end
      copied[#copied+1]={x=v.x,y=v.y,z=p.z}
     end
     if finite then
      route={generation=M.generation,destination=point(goal),path=copied,index=1};b.coarse_route=route
      if #copied>1 and math.floor(p.x/24)==math.floor(copied[1].x/24) and math.floor(p.y/24)==math.floor(copied[1].y/24) then route.index=2 end
      emit('navigation_coarse_route',{position=point(p),destination=point(goal),path=copied,
       source='GeneratedLevel.get_waypoints',clearance='coarse only; every driven segment requires live ground/hull clearance'},b.id,'behavior')
     end
    else
     emit('navigation_coarse_unavailable',{position=point(p),destination=point(goal),reason=ok and 'no_native_suggestion' or tostring(path)},b.id)
    end
   end
  end
  if not route or route.generation~=M.generation or C.distance(route.destination,goal)>24 then return goal end
  while route.index<=#route.path do
   local waypoint=route.path[route.index]
   local same_tile=math.floor(p.x/24)==math.floor(waypoint.x/24) and math.floor(p.y/24)==math.floor(waypoint.y/24)
   if C.distance(p,waypoint)<6 or (route.index<#route.path and same_tile) then route.index=route.index+1 else break end
  end
  if math.floor(p.x/24)==math.floor(goal.x/24) and math.floor(p.y/24)==math.floor(goal.y/24) then return goal end
  return route.path[route.index] or goal
 end
 local function edge_key(a,z,width)
  return string.format('%.3f,%.3f,%.3f>%.3f,%.3f,%.3f:%.2f',a.x,a.y,a.z or 0,z.x,z.y,z.z or 0,width or 0)
 end
 function D.edge(b,a,z,clear,ground,reason,hits,cached)
  local buffer=b.navigation_edges or {};b.navigation_edges=buffer
  D.edges=(D.edges or 0)+1
  local record={edge=D.edges,route=b.route and b.route.id,from=point(a),to=point(z),ground=point(ground),
   clear=clear==true,reason=reason,hits=hits,cached=cached==true,time=M.clock}
  buffer[#buffer+1]=record
  if #buffer>128 then table.remove(buffer,1);b.navigation_edges_overwritten=(b.navigation_edges_overwritten or 0)+1 end
 end
 local function flush(b,incident)
  local buffer=b.navigation_edges or {};local batch={};local count=0
  for _,r in ipairs(buffer) do
   if r.edge>(incident.cursor or 0) then
    incident.cursor=r.edge
    if incident.edges<2048 and count<16 then
     batch[#batch+1]=r;count=count+1;incident.edges=incident.edges+1
    else incident.omitted=incident.omitted+1 end
   end
  end
  if #batch>0 then emit('navigation_edges',{incident=incident.id,edges=batch,
   prior_ring_overwrites=b.navigation_edges_overwritten or 0,omitted=incident.omitted},b.id,'behavior') end
 end
 local original_probe=S.probe
 function S.probe(b,a,z,budget,callback,ignore)
  D.context()
  local mounted=b.mounted and b.mounted.pilot
  local planning=mounted and b.route and b.route.status=='planning'
  local width=mounted and b.mounted.clearance or .38
  local key=planning and edge_key(a,z,width)
  -- Dynamic hazards are checked again in the underlying adapter. Cache only
  -- terrain observations; the driver always casts fresh execution probes.
  local cached=key and D.cache[key]
  local risk=M.behaviors and M.behaviors.hazards or {}
  if cached and M.clock<cached.expires and #risk==0 and not b.edge_probe then
   D.edge(b,a,z,cached.clear,cached.ground,cached.reason,nil,true)
   callback(cached.clear,point(cached.ground),cached.reason);return true
  end
  return original_probe(b,a,z,budget,function(clear,ground,reason)
   local q=b.last_probe_evidence
   D.edge(b,a,z,clear,ground,reason,q and q.hits,false)
   if key and reason~='hazard' then
    if not D.cache[key] then
     local order=D.cache_order;local old=order[D.cache_cursor]
     if old then D.cache[old]=nil end
     order[D.cache_cursor]=key;D.cache_cursor=D.cache_cursor%4096+1
    end
    D.cache[key]={clear=clear,ground=point(ground),reason=reason,from=point(a),to=point(z),expires=M.clock+(clear and 45 or 3)}
   end
   callback(clear,ground,reason)
  end,ignore)
 end
 local original_reject=S.vehicle_route_reject
 function S.vehicle_route_reject(b,a,z)
  local rejected=original_reject and original_reject(b,a,z)
  if rejected then D.edge(b,a,z,false,nil,'actor_or_contact',nil,false) end
  return rejected
 end
 local previous_config=S.vehicle_route_config
 local route_serial=0
 function S.vehicle_route_config(b,q)
  previous_config(b,q)
  if q.trace_configured then return end
  q.trace_configured=true;route_serial=route_serial+1;q.id=route_serial
  if b.mounted and b.mounted.pilot then
   -- Keep reusable terrain edges, with a checked connector from the actual
   -- hull to the nearest cell as well as its surrounding alternatives.
   local step=N.step;local root=q.nodes and q.nodes['0:0']
   if root and q.count==1 then
    root.x=math.floor(q.origin.x/step+.5);root.y=math.floor(q.origin.y/step+.5)
    local key=root.x..':'..root.y
    q.grid_origin={x=0,y=0};q.root_x=root.x;q.root_y=root.y
    local p={x=root.x*step,y=root.y*step,z=q.origin.z}
    if C.distance(p,q.origin)>.05 then
     q.nodes={start=root};q.entry={node=root,p=p,key=key}
    else q.nodes={[key]=root} end
   end
   q.slice_at=M.clock+2
  end
 end
 function D.route(b,q,result)
  local route={id=q.id,result=result,reason=q.reason,origin=point(q.origin),goal=point(q.goal),destination=point(q.destination),
   nodes=q.count,limit=q.limit,bounds=q.bounds,age=M.clock-(q.started or M.clock),search_complete=q.status=='ready' and not q.partial_reason,
   coverage='bounded; unexplored connections remain unknown',path={}}
  for i,p in ipairs(q.path or {}) do if i<=128 then route.path[i]=point(p) end end
  route.path_omitted=math.max(0,#(q.path or {})-128)
  emit('navigation_route',route,b.id,'behavior')
 end
 function D.vehicle(b,m,lp,input)
  if not live(m.vehicle) or not live(b.unit) then return end
  D.context();local p=point(Unit.world_position(m.vehicle,0));local old=b.navigation_observation
  if M.clock>=(D.next_map_batch or 0) and D.map_tiles and D.map_cursor<=#D.map_tiles then
   D.next_map_batch=M.clock+.5;local cells={}
   for i=1,32 do local cell=D.map_tiles[D.map_cursor];if not cell then break end;cells[#cells+1]=cell;D.map_cursor=D.map_cursor+1 end
   emit('navigation_map_tiles',{generation=M.generation,tile_size=24,cells=cells,complete=D.map_cursor>#D.map_tiles},nil,'behavior')
  end
  if not old or old.vehicle~=m.vehicle then old={vehicle=m.vehicle,position=p,time=M.clock,anchor=p,anchor_time=M.clock,history={}};b.navigation_observation=old end
  if M.clock-old.time<.5 then return end
  local dt=M.clock-old.time;local delta=C.distance(p,old.position);local drive=(b.vehicle_status or {}).drive or {}
  local speed=delta/math.max(.001,dt);local move=point(input.movement)
  local guns=(b.vehicle_status or {}).weapons or {};local active_fire=false
  for _,w in pairs(guns) do if w.trigger and w.permitted then active_fire=true end end
  local native_activity=false;local spent=0;local rounds={}
  for _,w in ipairs(m.weapons or {}) do
   local a=w.ammo or {};local id=D.id(w.unit)
   if a.firing_auto or a.firing_single or a.charging or a.charging_shot then native_activity=true end
   if type(a.rounds)=='number' and id then
    rounds[id]=a.rounds
    if old.rounds and old.rounds[id] and a.rounds<old.rounds[id] then spent=spent+old.rounds[id]-a.rounds end
   end
  end
  old.rounds=rounds
  local combat=native_activity or spent>0 or drive.reason=='combat_spacing' or drive.reason=='combat_reposition'
  local health=EntityAux.has_component(b.unit,'health') and EntityAux.state(b.unit,'health') or {}
  local view=M.mobility and M.mobility.visibility(b,m,p) or {status='unknown',reason='visibility_adapter_unavailable'}
  local snapshot={time=M.clock,position=p,leader=point(lp),distance=C.distance(p,lp),vehicle_id=D.id(m.vehicle),
   speed=speed,displacement=delta,final_input=move,reason=drive.reason,goal=point(drive.goal),waypoint=point(drive.waypoint),
   route=drive.route,route_id=b.route and b.route.id,route_nodes=drive.nodes,search_level=drive.search_level,
   combat={active=combat,firing_requested=active_fire,native_weapon_activity=native_activity,rounds_consumed=spent,
    target=b.target and D.id(b.target.id),target_position=b.target and point(b.target.position)},pilot_downed=health.is_downed==true,
   screen_visibility=view.status,visibility=view,native_controls={move_forward=input.move_forward,move_back=input.move_back,
    move_left=input.move_left,move_right=input.move_right},rotation_angle=(M.mobility and M.mobility.state(m.vehicle,'vehicle') or {}).rotation_angle,
   follow_progress=b.follow_progress and
    {gap=b.follow_progress.gap,blocked_seconds=b.follow_progress.blocked_seconds,advancing=b.follow_progress.advancing,catchup=b.catchup==true},
   probe_pending=b.edge_probe~=nil,probe_age=b.edge_probe and M.clock-b.edge_probe.started}
  local history=old.history;history[#history+1]=snapshot;if #history>12 then table.remove(history,1) end
  if C.distance(p,old.anchor)>.35 then
   b.navigation_failure=nil
   old.anchor=p;old.anchor_time=M.clock
   if old.incident then
    flush(b,old.incident);emit('navigation_recovered',{incident=old.incident.id,position=p,elapsed=M.clock-old.incident.started,
     resolution='movement_resumed',leader_distance=snapshot.distance,edges_omitted=old.incident.omitted},b.id)
    old.incident=nil
   end
  end
  if drive.reason=='following_distance' or drive.reason=='ordered_position' then
   b.navigation_failure=nil;old.anchor=p;old.anchor_time=M.clock
   if old.incident then
    flush(b,old.incident);emit('navigation_recovered',{incident=old.incident.id,position=p,
     resolution='destination_within_range',leader_distance=snapshot.distance},b.id);old.incident=nil
   end
  end
  local stationary=M.clock-old.anchor_time
  local blocked=not (health.is_downed or health.is_dead) and (drive.reason=='planning' or drive.reason=='obstacle' or drive.reason=='ground' or drive.reason=='vehicle'
   or drive.reason=='pedestrian' or drive.reason=='hazard' or drive.reason=='clearance_pending'
   or (move and C.distance({x=0,y=0},move)>.1))
  if stationary>=3 and blocked and not old.incident then
   D.incidents=D.incidents+1;old.incident={id=D.incidents,started=old.anchor_time,edges=0,omitted=0}
   local invalidated=0
   for key,cached in pairs(D.cache or {}) do
    if (cached.from and C.distance(cached.from,p)<6) or (cached.to and C.distance(cached.to,p)<6) then
     D.cache[key]=nil;invalidated=invalidated+1
    end
   end
   local prelude={};for i,r in ipairs(history) do prelude[i]=r end
   emit('navigation_stalled',{incident=D.incidents,generation=M.generation,stationary_seconds=stationary,
    observation=snapshot,prelude=prelude,nearby_cached_edges_invalidated=invalidated,
    alternate_route='unknown_pending_search'},b.id)
  end
  if old.incident then
   flush(b,old.incident)
   if not old.incident.next_sample or M.clock>=old.incident.next_sample then
    old.incident.next_sample=M.clock+2
    emit('navigation_stall_update',{incident=old.incident.id,stationary_seconds=stationary,observation=snapshot,
     alternatives='See checked edges and navigation_route; bounded search failure does not prove disconnection',
     edges_omitted=old.incident.omitted},b.id,'behavior')
   end
   if stationary>=15 and not old.incident.reported then
    old.incident.reported=true;b.navigation_failure=string.format('Route blocked at %.1f, %.1f; checking alternatives',p.x,p.y)
    emit('navigation_failure',{incident=old.incident.id,position=p,stationary_seconds=stationary,
     reason=drive.reason,conclusion='no route found yet; physical disconnection unproven'},b.id)
   end
  elseif (not old.next_sample or M.clock>=old.next_sample) and snapshot.distance>20 then
   old.next_sample=M.clock+2;emit('vehicle_motion',snapshot,b.id,'behavior')
  end
  old.position=p;old.time=M.clock
 end
 return D
end
