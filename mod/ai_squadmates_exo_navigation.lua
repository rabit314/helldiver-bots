-- Mounted navigation: shared planning/execution clearances and bounded recovery.
return function(M,C,S,V,emit,radius,pos)
 local function separated(a,z,center,gap)
  if math.abs(a.z-(center.z or 0))>=3 then return true end
  local d=C.direction(a,z);local n=C.distance(a,z)
  local along=(center.x-a.x)*d.x+(center.y-a.y)*d.y
  local t=math.max(0,math.min(n,along))
  local near={x=a.x+d.x*t,y=a.y+d.y*t}
  if C.distance(near,center)>=gap then return true end
  local start=C.distance(a,center)
  return start<gap and along<-.08 and C.distance(z,center)>start+.08
 end
 local function actors(b,a,z)
  local nav=b.vehicle_navigation
  if not nav then return true end
  for _,f in ipairs(nav.friends) do
   local width=math.max(3.4,(b.mounted and b.mounted.clearance or 1.45)+1)
   if not separated(a,z,f,width) then return false,'pedestrian' end
  end
  for _,h in ipairs(M.behaviors.vehicles or {}) do if h.unit~=nav.vehicle then
   local gap=nav.radius+h.radius+.5
   local future=h.future or h.position
   for _,p in ipairs({h.position,future,{x=(h.position.x+future.x)/2,y=(h.position.y+future.y)/2,z=h.position.z}}) do
    if not separated(a,z,p,gap) then return false,'vehicle' end
   end
  end end
  return true
 end
 function S.vehicle_route_config(b,q)
  if b.mounted and b.mounted.pilot and not q.vehicle_configured then
   q.vehicle_configured=true;q.limit=512*2^(b.vehicle_search_level or 0)
   q.bounds=24;q.timeout=30;q.tolerance=.1;q.arrival=.15;q.weight=1.25
   if q.status=='planning' and q.destination then
    local d=C.direction(q.origin,q.destination);local n=math.min(30,C.distance(q.origin,q.destination))
    q.goal={x=q.origin.x+d.x*n,y=q.origin.y+d.y*n,z=q.destination.z}
   end
  end
 end
 function V.drive(b,m,lp,dt,budget,friends)
  b.vehicle_navigation={vehicle=m.vehicle,radius=radius(m.vehicle),friends=friends or {}}
  local destination=b.vehicle_order and b.vehicle_order.destination
  local p=pos(m.vehicle);local d=C.direction(lp,p)
  local base=destination or {x=lp.x+d.x*4.8,y=lp.y+d.y*4.8,z=lp.z}
  local combat=not b.catchup and (not M.mobility or M.mobility.profile(m.vehicle).kind=='exosuit') and V.exosuit.spacing(b,m,p,base,friends) or nil;destination=combat or destination
  local distance=C.distance(p,destination or lp);local gap=destination and .65 or 4.8
  if not destination and b.vehicle_leader_vehicle then gap=math.max(gap,radius(m.vehicle)+radius(b.vehicle_leader_vehicle)+.8) end
  local diagnostic={distance=distance,gap=gap,position=p,clearance=m.clearance}
  b.vehicle_status=b.vehicle_status or {};b.vehicle_status.drive=diagnostic
  local function finish(reason,move)
   diagnostic.reason=reason;diagnostic.route=b.route and b.route.status
   diagnostic.nodes=b.route and b.route.count;diagnostic.search_level=b.vehicle_search_level or 0
   diagnostic.stuck=b.vehicle_stuck or 0;diagnostic.movement=move or {x=0,y=0,z=0}
   if move and move.x*move.x+move.y*move.y>.01 then
    local push=b.vehicle_push
    if not push or push.vehicle~=m.vehicle or C.distance(push.position,p)>.18 then
     push={vehicle=m.vehicle,position=p,seconds=0};b.vehicle_push=push
    end
    push.seconds=push.seconds+math.min(dt,.2);push.time=M.clock
    push.direction=C.direction({x=0,y=0},move)
   end
   diagnostic.push=b.vehicle_push and b.vehicle_push.seconds
   if reason=='vehicle' or reason=='pedestrian' or reason=='obstacle' or reason=='ground' or reason=='hazard' then
    local block=b.vehicle_block
    if not block or C.distance(block.position,p)>.3 then block={position=p,seconds=0};b.vehicle_block=block end
    block.seconds=block.seconds+math.min(dt,.2)
   elseif move then b.vehicle_block=nil end
   return diagnostic.movement
  end
  if M.recovery and M.recovery.safe_drive(b,m,lp,dt,budget,friends,combat) then return finish('hidden_recovery_check') end
  if V.exosuit.stranded(b,m) then return finish('vehicle_follow_abandoned') end
  -- Start promptly, but use separate start/stop distances to avoid repeated braking.
  if distance<=gap+.05 or (not destination and not b.vehicle_following and distance<gap+.8) then
   b.vehicle_following=nil;b.vehicle_progress=nil;b.vehicle_stuck=0;b.vehicle_push=nil
   b.vehicle_block=nil;b.vehicle_visited=nil;b.vehicle_search_level=nil
   return finish(combat and 'combat_spacing' or (destination and 'ordered_position' or 'following_distance'))
  end
  b.vehicle_following=true
  local goal=destination or {x=lp.x+d.x*gap,y=lp.y+d.y*gap,z=lp.z}
  if not destination and not actors(b,goal,goal) then
   -- Another suit may already occupy the radial follow point. Rejoin at an
   -- open point on the same ring instead of planning into its exclusion zone.
   for _,angle in ipairs({math.pi/4,-math.pi/4,math.pi/2,-math.pi/2,3*math.pi/4,-3*math.pi/4,math.pi}) do
    local c,s=math.cos(angle),math.sin(angle)
    local q={x=lp.x+(d.x*c-d.y*s)*gap,y=lp.y+(d.x*s+d.y*c)*gap,z=lp.z}
    if actors(b,q,q) then goal=q;break end
   end
  end
  diagnostic.goal=goal
  if b.vehicle_block and b.vehicle_block.seconds>.6 and (not b.route or b.route.status~='planning') and M.clock>=(b.route_retry or 0) then
   S.cancel(b);b.route_retry=0;b.vehicle_stuck=1.1;b.vehicle_block=nil;b.vehicle_step=nil
   b.vehicle_progress={position=p,time=M.clock}
  end
  local push=b.vehicle_push
  if push and push.vehicle==m.vehicle and push.seconds>1.2 and M.clock-push.time<.5
    and C.distance(push.position,p)<.18 then
   local contacts=b.vehicle_contacts or {};b.vehicle_contacts=contacts
   contacts[#contacts+1]={position=p,direction=push.direction,expires=M.clock+18,vehicle=m.vehicle}
   if #contacts>8 then table.remove(contacts,1) end
   S.cancel(b);b.vehicle_step=nil;b.vehicle_push=nil;b.vehicle_stuck=1.1;b.route_retry=0
   b.vehicle_progress={position=p,time=M.clock}
   emit('vehicle_contact_blocked',{position=p,direction=push.direction},b.id)
  end
  local progress=b.vehicle_progress
  if not progress then progress={position=p,time=M.clock};b.vehicle_progress=progress end
  if M.clock-progress.time>.5 then
   b.vehicle_stuck=C.distance(p,progress.position)<.1 and (b.vehicle_stuck or 0)+M.clock-progress.time or 0
   b.vehicle_progress={position=p,time=M.clock}
  end
  local saved=b.stuck_seconds;b.stuck_seconds=b.vehicle_stuck or 0
  local waypoint,waiting=S.navigate(b,p,goal,budget,not destination)
  if b.stuck_seconds<(b.vehicle_stuck or 0) then
   b.vehicle_progress={position=p,time=M.clock};b.vehicle_push=nil
  end
  b.vehicle_stuck=b.stuck_seconds;b.stuck_seconds=saved
  if waiting then return finish('planning') end
  if not b.route and C.distance(p,waypoint)<.12 then waypoint=goal end
  goal=waypoint
  diagnostic.waypoint=goal
  local toward=C.direction(p,goal);local length=math.min(1.8,C.distance(p,goal))
  if length<.04 then return finish('waypoint_arrival') end
  local check=b.vehicle_step
  local function valid(q)
   return q and q.vehicle==m.vehicle and M.clock-q.time<.45 and C.distance(q.from,p)<.4
    and q.direction.x*toward.x+q.direction.y*toward.y>.95
    and C.distance(q.from,p)+math.min(.35,length)<=q.length+.05
  end
  if not valid(check) or M.clock-check.time>.18 or C.distance(check.from,p)>.15 then
   -- Stop the probe at the checked corner; probing beyond it falsely blocks turns.
   S.probe(b,p,{x=p.x+toward.x*length,y=p.y+toward.y*length,z=p.z},budget,function(clear,_,reason)
    b.vehicle_step={time=M.clock,from=p,direction=toward,length=length,clear=clear,reason=reason,vehicle=m.vehicle}
   end,m.vehicle)
  end
  check=b.vehicle_step
  if not valid(check) then return finish('clearance_pending') end
  if not check.clear then return finish(check.reason or 'obstacle') end
  -- A swept capsule includes endpoints and predicted pedestrian positions.
  -- Terrain clearance and pedestrian clearance are deliberately independent.
  local endpoint={x=p.x+toward.x*length,y=p.y+toward.y*length,z=p.z}
  local clear,reason=actors(b,p,endpoint)
  if not clear then return finish(reason) end
  local scale=math.min(.85,math.max(.28,(distance-gap)*.3),math.max(.28,length*.7))
  return finish(combat and 'combat_reposition' or 'moving',{x=toward.x*scale,y=toward.y*scale,z=0})
 end
 -- Physical contact is stronger evidence than a clear feeler. Remember a small
 -- local cone briefly so a fresh checked route tries sideways/backwards first.
 function S.vehicle_route_reject(b,a,z)
  if not b.mounted or not b.mounted.pilot then return false end
  if not actors(b,a,z) then return true end
  for i=#(b.vehicle_contacts or {}),1,-1 do local q=b.vehicle_contacts[i]
   if M.clock>q.expires or q.vehicle~=b.mounted.vehicle then table.remove(b.vehicle_contacts,i)
   elseif C.distance(a,q.position)<1.5 then
    local d=C.direction(a,z)
    if d.x*q.direction.x+d.y*q.direction.y>.5 then return true end
   end
  end
  return false
 end
 -- A bounded search can exhaust its nodes near an unreachable patch of ground.
 -- Keep useful checked progress; do not discard every reachable approach edge.
 function S.vehicle_partial_route(b,q)
  if not b.mounted or not b.mounted.pilot or (q.reason~='route_node_limit' and q.reason~='no_checked_route' and q.reason~='route_timeout' and q.reason~='route_probe_timeout' and q.reason~='route_slice') then return end
  b.vehicle_search_level=math.min(2,(b.vehicle_search_level or 0)+1)
  -- Remember every partial origin, including apparently closer prefixes.
  -- Otherwise a sliced search repeatedly walks back into the same dead end.
  local visited=b.vehicle_visited or {};b.vehicle_visited=visited
  visited[#visited+1]={position=q.origin,time=M.clock}
  if #visited>32 then table.remove(visited,1) end
  local best,score;local distance=C.distance(q.origin,q.goal)-.9
  for _,node in pairs(q.nodes) do
   local d=C.distance(node.p,q.goal);local moved=C.distance(node.p,q.origin)
   if node.parent and moved>1.5 and (d<distance or moved>=3.5) then
    local cost=d+(node.g or 0)*.15
    for _,v in ipairs(visited) do if M.clock-v.time<90 then cost=cost+math.max(0,5-C.distance(node.p,v.position))*4 end end
    if not score or cost<score then best=node;score=cost end
   end
  end
  if not best then return end
  local path={};while best.parent do table.insert(path,1,best.p);best=best.parent end
  local reason=q.reason;q.partial_reason=reason;q.path=path;q.index=1;q.goal=path[#path];q.status='ready';q.reason=nil;q.pending=nil
  emit('vehicle_partial_route',{reason=reason,waypoints=#path,nodes=q.count,age=M.clock-q.started},b.id)
 end
 return V.drive
end
