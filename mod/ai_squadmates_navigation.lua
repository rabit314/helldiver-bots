-- Bounded A* over collision/ground-checked edges. The adapter owns async probes.
local N={revision='0.7.0',step=1.8,limit=196}
local function copy(p) return {x=p.x,y=p.y,z=p.z or 0} end
local function distance(a,b) local x,y=a.x-b.x,a.y-b.y;return math.sqrt(x*x+y*y) end
function N.new(start,goal,now)
 local root={x=0,y=0,p=copy(start),g=0};root.f=distance(start,goal)
 return {origin=copy(start),goal=copy(goal),open={root},nodes={['0:0']=root},count=1,
  started=now,status='planning',serial=0}
end
local function complete(q,node)
 local path={copy(q.goal)}
 while node and node.parent do table.insert(path,1,node.p);node=node.parent end
 q.path=path;q.index=1;q.status='ready';q.pending=nil
end
function N.advance(q,now,probe)
 if q.status~='planning' then return q.status end
 if now-q.started>(q.timeout or 12) then q.status='failed';q.reason='route_timeout';q.pending=nil;return q.status end
 if q.pending then return q.status end
 if q.entry and not q.entry.done then
  local e=q.entry;q.pending=true
  local accepted=probe(q.origin,e.p,function(clear,p)
   if q.status~='planning' then return end
   q.pending=nil;e.done=true
   if clear then
    local n={x=e.node.x,y=e.node.y,p=copy(p or e.p),parent=e.node}
    n.g=distance(q.origin,n.p);n.f=n.g+distance(n.p,q.goal)*(q.weight or 1)
    q.nodes[e.key]=n;q.open[#q.open+1]=n;q.count=q.count+1
   end
  end)
  if not accepted then q.pending=nil end
  return q.status
 end
 if not q.current then
  local index,best
  for i,node in ipairs(q.open) do if not node.closed and (not best or node.f<best.f) then index,best=i,node end end
  if not best then q.status='failed';q.reason='no_checked_route';return q.status end
  table.remove(q.open,index);best.closed=true;q.current=best;q.edge=0
 end
 local node=q.current
 if not node.checked_goal and distance(node.p,q.goal)<=N.step*1.5 then
  q.pending=true
  local accepted=probe(node.p,q.goal,function(clear,p)
   if q.status~='planning' then return end
   q.pending=nil;node.checked_goal=true
   if clear then q.goal=copy(p or q.goal);complete(q,node) end
  end)
  if not accepted then q.pending=nil end
  return q.status
 end
 local offsets={{1,0},{0,1},{-1,0},{0,-1}}
 while q.edge<#offsets do
  q.edge=q.edge+1;local d=offsets[q.edge];local x,y=node.x+d[1],node.y+d[2];local key=x..':'..y
  local origin=q.grid_origin or q.origin
  local old=q.nodes[key];local p={x=origin.x+x*N.step,y=origin.y+y*N.step,z=node.p.z}
  local cost=distance(node.p,p)
  if math.abs(x-(q.root_x or 0))<=(q.bounds or 12) and math.abs(y-(q.root_y or 0))<=(q.bounds or 12) and (not old or (not old.closed and node.g+cost<old.g)) then
   if q.count>=(q.limit or N.limit) and not old then q.status='failed';q.reason='route_node_limit';return q.status end
   q.pending=true
   local accepted=probe(node.p,p,function(clear,ground)
    if q.status~='planning' then return end
    q.pending=nil
    if clear then
     local next_node=old or {x=x,y=y};next_node.p=copy(ground or p);next_node.g=node.g+cost
     next_node.f=next_node.g+distance(next_node.p,q.goal)*(q.weight or 1);next_node.parent=node
     if not old then q.count=q.count+1;q.nodes[key]=next_node;q.open[#q.open+1]=next_node end
    end
   end)
   if not accepted then q.pending=nil;q.edge=q.edge-1 end
   return q.status
  end
 end
 q.current=nil;return q.status
end
function N.waypoint(q,p)
 if q.status~='ready' then return nil end
 while q.index<#q.path and distance(p,q.path[q.index])<(q.tolerance or .65) do q.index=q.index+1 end
 return q.path[q.index]
end
function N.cancel(q)
 if q then q.status='cancelled';q.pending=nil end
end
return N
