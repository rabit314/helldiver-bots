-- Engine-independent squad decisions. Native character states own speed and turning.
local C={revision='0.11.4'}
local sqrt=math.sqrt
local function v(x,y,z) return {x=x or 0,y=y or 0,z=z or 0} end
local function distance(a,b)
 local x,y=a.x-b.x,a.y-b.y
 return sqrt(x*x+y*y)
end
local function direction(a,b)
 local x,y=b.x-a.x,b.y-a.y;local n=sqrt(x*x+y*y)
 if n<0.0001 then return v() end
 return v(x/n,y/n,0)
end
C.distance=distance
C.direction=direction
local function dot(a,b) return a.x*b.x+a.y*b.y end
local function unit(a) return direction(v(),a) end
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
function C.guard_slot(index,count)
 local ring,radius,capacity=1,3.6,8
 while index>capacity do
  index=index-capacity;count=count-capacity;ring=ring+1;radius=radius+2.6
  capacity=math.floor(2*math.pi*radius/2.7)
 end
 local size=math.min(count,capacity);local angle=(index-1)*2*math.pi/size+(ring-1)*.37
 return {x=math.cos(angle)*radius,y=math.sin(angle)*radius,z=0},ring,radius
end
function C.landing_clear(p,occupied,reservations,own_id)
 for _,o in ipairs(occupied or {}) do
  if distance(p,o.position)<(o.radius or 3.5) then return false,'occupied' end
 end
 for _,r in pairs(reservations or {}) do
  if r.id~=own_id and distance(p,r.position)<(r.radius or 4.5) then return false,'reserved' end
 end
 return true
end
function C.drop_point(origin,id,occupied,reservations,attempts)
 for ring=0,3 do
  local radius=5.5+ring*2
  for n=0,23 do
   local angle=(id+(attempts or 0)*17)*2.3999632297+n*math.pi/12
   local p=v(origin.x+math.cos(angle)*radius,origin.y+math.sin(angle)*radius,origin.z)
   if C.landing_clear(p,occupied,reservations,id) then return p end
  end
 end
end
function C.neutral()
 return {movement=v(),aim=v(),map_pan=v(),map_zoom=v(),
  fire=false,fire_auto=false,reload=false,sprint=false,dodge=false,interact=false,
  throw=false,stratagems=false,switch_weapon=false,melee=false,map=false,
  up=false,down=false,left=false,right=false}
end
-- Stable spacing, including an opposite escape direction for coincident bots.
function C.separation(p,neighbors,id)
 local x,y=0,0
 for _,n in ipairs(neighbors or {}) do
  local q=n.position;local dx,dy=p.x-q.x,p.y-q.y;local d=sqrt(dx*dx+dy*dy)
  if d<1.6 then
   if d<.05 then
    local other=n.id or 0;local a=(math.min(id or 1,other)*13+math.max(id or 1,other))*2.3999632297
    local sign=(id or 1)>other and 1 or -1;dx,dy,d=math.cos(a)*sign,math.sin(a)*sign,1
    x=x+dx;y=y+dy
   else local f=(1.6-d)/1.6;x=x+dx/d*f;y=y+dy/d*f end
  end
 end
 local n=sqrt(x*x+y*y);if n>1 then x,y=x/n,y/n end
 return v(x,y)
end
function C.steer(move,s,m)
 local separation=C.separation(s.position,s.neighbors,s.id)
 local length=sqrt(dot(move,move))
 local d=unit(v(move.x+separation.x*.85,move.y+separation.y*.85))
 local traffic=false
 for _,zone in ipairs(s.landing_zones or {}) do
  local gap=distance(s.position,zone.position)
  if gap<(zone.radius or 3.5) then
   d=direction(zone.position,s.position)
   if dot(d,d)<.01 then local a=(s.id or 1)*2.3999632297;d=v(math.cos(a),math.sin(a)) end
   length=math.max(length,.8);traffic=true
  end
 end
 if length<.01 and dot(separation,separation)<.04 and not traffic then return v(),false,v() end
 if length>.01 then
  local forward=unit(move);local lateral=0
  for _,n in ipairs(s.neighbors or {}) do
   local dx,dy=n.position.x-s.position.x,n.position.y-s.position.y
   local ahead=dx*forward.x+dy*forward.y;local across=forward.x*dy-forward.y*dx
   if ahead>0 and ahead<1.6 and math.abs(across)<.8 then
    -- Pass on the right when centered; otherwise keep moving away from the neighbor.
    local side=across>=0 and -1 or 1
    lateral=lateral+side*(1-ahead/1.8)*.9;traffic=true
   end
  end
  lateral=clamp(lateral,-1,1)
  d=unit(v(d.x-forward.y*lateral,d.y+forward.x*lateral))
 end
 local wanted=d
 local obstacles=s.obstacles;local avoiding=traffic
 if obstacles and dot(d,obstacles.direction)>.65 then
  local front,left,right=obstacles.front,obstacles.left,obstacles.right
  if front<2 or ((s.stuck_seconds or 0)>.9 and not s.checked_route) then
   if left<.85 and right<.85 then return v(),true,wanted end
   if not m.avoid_side or (m.avoid_side==1 and left<.85) or (m.avoid_side==-1 and right<.85) then
    m.avoid_side=math.abs(left-right)>.25 and (left>right and 1 or -1) or ((s.id or 1)%2==0 and 1 or -1)
   end
   local side=m.avoid_side;d=unit(v(d.x*.2-d.y*side,d.y*.2+d.x*side));avoiding=true
  else m.avoid_side=nil end
 end
 -- Analog input eases arrival; never writes a native speed/stamina setting.
 local scale=math.max(length,math.min(.65,sqrt(dot(separation,separation))))
 return v(d.x*scale,d.y*scale),avoiding,wanted
end
function C.corridor_clear(origin,target,friends,radius)
 local dx,dy=target.x-origin.x,target.y-origin.y
 local n=dx*dx+dy*dy
 if n<0.0001 then return false end
 for _,p in ipairs(friends or {}) do
  local t=((p.x-origin.x)*dx+(p.y-origin.y)*dy)/n
  if t>0 and t<1.04 then
   local x,y=origin.x+t*dx-p.x,origin.y+t*dy-p.y
   if x*x+y*y<(radius or .9)^2 then return false end
  end
 end
 return true
end
function C.choose_target(origin,candidates,current,range,protect)
 local best,score=nil,math.huge
 for _,e in ipairs(candidates or {}) do
  if e.alive and e.enemy and e.position then
   local d=distance(origin,e.position)
   if d<=(range or 14) then
    local s=d-(e.id==current and 2 or 0)+(protect and math.min(18,distance(protect,e.position))*.35 or 0)
    if s<score then best,score=e,s end
   end
  end
 end
 return best
end
function C.decide(s)
 local input=C.neutral()
 local m=s.memory or {};local dt=clamp(s.dt or 0,0,.1)
 if not s.alive or s.downed or not s.leader or not s.leader_alive then
  m.sprinting=false;m.aim_time=0;m.target=nil;m.aim_dot=nil;m.wanted_movement=v()
  return input,'idle'
 end
 local gap=distance(s.position,s.leader)
 local ammo=s.ammo or {}
 local reload=ammo.reloadable and not ammo.is_reloading and type(ammo.rounds)=='number'
  and ammo.rounds==ammo.rounds and ammo.rounds>-math.huge and ammo.rounds<=0
   and type(ammo.num_mags)=='number' and ammo.num_mags>0
 input.reload=not not reload
 local reloading=reload or ammo.is_reloading
 local goal=s.goal or s.leader
 local follow_gap=distance(s.position,goal)
 if s.hold then gap=follow_gap end
 local start=s.goal and (s.guard and .9 or 1.35) or 3.2;local stop=s.goal and .5 or 2.5
 -- Offset interaction goals must be reached accurately. Formation hysteresis
 -- can otherwise stop 1.45 m from a casualty, outside its 1.25 m reach.
 if s.approach then start=.12;stop=.08 end
 m.following=follow_gap>(m.following and stop or start)
 local guard_radius=s.hold and 0 or (s.guard_radius or 0)
 m.regroup=gap>(m.regroup and math.max(5.5,guard_radius+1.5) or math.max(9,guard_radius+4))
 local function finish(mode,may_sprint)
  if s.perimeter and not s.danger and follow_gap>2.5 then
   input.movement=direction(s.position,goal)
  end
  if s.catchup and not s.danger and not s.hold then input.movement=direction(s.position,goal) end
  local avoiding;input.movement,avoiding,m.wanted_movement=C.steer(input.movement,s,m)
  local landing_danger=not not s.danger
  for _,zone in ipairs(s.landing_zones or {}) do
   if distance(s.position,zone.position)<(zone.radius or 3.5) then landing_danger=true end
  end
  if s.hold and s.hold_arrived and not landing_danger then
   -- Keep combat shuffles/separation local to the fixed post. Never pursue enemies.
   local outward=direction(goal,s.position);local radial=dot(input.movement,outward)
   if follow_gap>2 then
    input.movement=direction(s.position,goal);m.wanted_movement=input.movement
    mode='guard_return';may_sprint=false
   elseif follow_gap>1.6 and radial>0 then
    input.movement=v(input.movement.x-outward.x*radial,input.movement.y-outward.y*radial)
   end
  end
  local moving=dot(input.movement,input.movement)>.01
  local stamina=s.stamina
  if type(stamina)=='number' then
   if stamina<.2 then m.resting=true elseif stamina>.9 then m.resting=false end
  end
  local catchup=gap>math.max(7,guard_radius+3) or (not s.hold and (s.leader_speed or 0)>3.5 and follow_gap>3.5)
  if m.sprinting then catchup=gap>math.max(4.5,guard_radius+1.5) or follow_gap>2 end
  local facing_ok=not s.facing or dot(unit(input.movement),unit(s.facing))>.7
  input.sprint=not not (may_sprint and moving and catchup and not reloading and not m.resting and not avoiding and facing_ok)
  m.sprinting=input.sprint
  if input.sprint then input.aim=v();input.fire=false;input.fire_auto=false end
  if avoiding then mode='avoid/'..mode end
  if s.seated or s.route_wait or s.interacting then input.movement=v();input.sprint=false end
  return input,mode
 end
 if s.danger then
  input.movement=s.danger;input.dodge=s.danger_kind=='friendly_fire';m.following=false
  return finish('evade/'..s.danger_kind,false)
 end
 if s.interacting then m.aim_time=0;input.aim=s.interaction_aim or v();return input,'interact' end
 local toward=direction(s.position,goal)
 local speed=clamp(follow_gap/1.8,.3,1)
 if m.following then input.movement=v(toward.x*speed,toward.y*speed) end
 if m.regroup and not s.seated and s.task_kind~='revive' and not s.order_travel then
  m.aim_time=0;m.target=nil;m.aim_dot=nil
  return finish(reload and 'regroup/reload' or 'regroup',true)
 end
 local target=s.target
 if s.task and not s.seated and (s.task_kind=='revive' or not target or distance(s.position,target.position)>4) then
  m.aim_time=0;return finish(s.task_kind=='revive' and 'rescue' or 'task',true)
 end
 if target and target.alive and target.enemy and target.position then
  local aim=direction(s.position,target.position)
  if m.target~=target.id then m.target=target.id;m.aim_time=0 end
  local can_track=s.visible or gap<5
  if can_track then
   input.aim=aim;m.aim_time=(m.aim_time or 0)+dt
   local aligned=s.facing and dot(unit(s.facing),aim)>.9945 -- six degrees
   m.aim_dot=s.facing and dot(unit(s.facing),aim) or nil
   local clear=C.corridor_clear(s.position,target.position,s.friends,.9)
   local range=distance(s.position,target.position);local profile=s.profile or {}
   local splash=profile.splash or 0
   local safe_blast=range>splash+1
   if splash>0 then for _,f in ipairs(s.friends or {}) do
    if distance(f,target.position)<splash+1 then safe_blast=false end
   end end
   if s.dry and not s.seated then
    input.fire=false;input.fire_auto=false
    if range<1.65 and clear then input.melee=true;input.movement=v()
    elseif range<5 and gap<7 and not s.hold and not s.order_travel then input.movement=aim end
    return finish('melee',false)
   end
   if s.visible and not clear then
    -- Move out of a blocked firing lane instead of standing behind a teammate.
    local side=(s.id or 1)%2==0 and 1 or -1
    input.movement=v(-aim.y*side*.65,aim.x*side*.65)
    return finish('reposition',false)
   end
   if distance(s.position,target.position)<3 then
    input.movement=v(-aim.x*.7,-aim.y*.7)
   elseif follow_gap<(s.guard and .5 or 3) then input.movement=v() end
   local sprinting=s.native_sprinting
   if not reloading and not sprinting and aligned and m.aim_time>=.12
     and ((type(ammo.rounds)=='number' and ammo.rounds>0) or profile.kind=='beam' or profile.kind=='arc')
     and range<=(profile.range or 14) and safe_blast and s.visible and clear then
    -- Check both the requested line and the real barrel direction.
    local f=s.facing;local range=distance(s.position,target.position)
    local endpoint=v(s.position.x+f.x*range,s.position.y+f.y*range)
    if C.corridor_clear(s.position,endpoint,s.friends,1) then input.fire=true;input.fire_auto=true end
   end
   return finish(reload and 'reload' or (ammo.is_reloading and 'reloading' or (input.fire and 'engage' or 'aim')),false)
  end
  m.aim_time=0;m.aim_dot=nil
 else
  m.target=nil;m.aim_time=0;m.aim_dot=nil
 end
 if m.following then
  return finish(reload and 'follow/reload' or 'follow',true)
 end
 if s.guard then input.aim=s.guard_look or (s.hold and (s.hold_facing or v(0,1)) or direction(s.leader,s.position)) end
 return finish(reload and 'reload' or (ammo.is_reloading and 'reloading' or 'guard'),false)
end
return C
