-- Shared, stable guard sectors. More pressure gets spare guards, never every guard.
local P={revision='0.8.0'}
local pi=math.pi
local function copy(p)return {x=p.x,y=p.y,z=p.z or 0}end
local function distance(a,b)local x,y=a.x-b.x,a.y-b.y;return math.sqrt(x*x+y*y)end
local function angle(a,b)return math.atan2(b.y-a.y,b.x-a.x)end
local function sector(a)return math.floor(((a+pi/4)%(2*pi))/(pi/2))+1 end
local function slot_position(g,s)
 return {x=g.position.x+s.offset.x,y=g.position.y+s.offset.y,z=g.position.z or 0}
end
function P.new()return {groups={},next_plan=0,assignments={}}end
function P.groups(leader,escorts)
 local groups={{key='player',kind='player',position=copy(leader),members={}}}
 local sorted={};for _,e in ipairs(escorts or {}) do sorted[#sorted+1]=e end
 table.sort(sorted,function(a,b)return a.key<b.key end)
 for _,e in ipairs(sorted) do
  -- Civilians close enough to the player share the player's perimeter.
  if distance(e.position,leader)>4 then
   local group
   for i=2,#groups do if distance(groups[i].position,e.position)<6 then group=groups[i];break end end
   if not group then
    group={key='escort:'..e.key,kind='escort',position=copy(e.position),members={}}
    groups[#groups+1]=group
   end
   group.members[#group.members+1]=e
   local n=#group.members
   group.position.x=group.position.x+(e.position.x-group.position.x)/n
   group.position.y=group.position.y+(e.position.y-group.position.y)/n
   group.position.z=group.position.z+((e.position.z or 0)-group.position.z)/n
  end
 end
 return groups
end
local function pressure(g,enemies,old)
 local result={1,1,1,1};local strongest,best=0,1
 for _,e in ipairs(enemies or {}) do
  if e.alive and e.enemy and e.position then
   local gap=distance(g.position,e.position)
   if gap<20 then
    local k=sector(angle(g.position,e.position));local weight=(20-gap)/5
    result[k]=result[k]+weight
    if result[k]>strongest then strongest=result[k];best=k end
   end
  end
 end
 if old then for k=1,4 do result[k]=old[k]*.55+result[k]*.45 end end
 g.pressure=result;g.strongest=strongest>0 and best or nil
end
function P.slots(g,count,old)
 local slots={};if count==0 then return slots end
 local function add(k,n,angle_value,radius)
  -- Static variation gives breathing room without continuously orbiting the center.
  local jitter=math.sin((k*17+n*7)*1.7)*.12
  local r=radius+jitter
  slots[#slots+1]={key=g.key..':'..k..':'..n,sector=k,angle=angle_value,radius=r,
   offset={x=math.cos(angle_value)*r,y=math.sin(angle_value)*r,z=0}}
 end
 if count<4 then
  -- Two guards cover opposing sides; three cover thirds of the perimeter.
  local phase=old and old.phase or ((g.strongest and (g.strongest-1)*pi/2) or 0)
  g.phase=phase
  for n=1,count do add(n,1,phase+(n-1)*2*pi/count,3.6) end
 else
  local counts={1,1,1,1};local weights=g.pressure or {1,1,1,1}
  for n=5,count do
   local best,score=1,-1
   for k=1,4 do local value=weights[k]/counts[k]
    if value>score then best,score=k,value end
   end
   counts[best]=counts[best]+1
  end
  for k=1,4 do
   local remaining=counts[k];local ring,n=0,0
   while remaining>0 do
    local size=math.min(3+ring,remaining)
    for j=1,size do
     local a=(k-1)*pi/2+(j-(size+1)/2)*(pi/3)/math.max(1,size-1)
     n=n+1;add(k,n,a,3.6+ring*2.4)
    end
    remaining=remaining-size;ring=ring+1
   end
  end
 end
 return slots
end
local function assign_slots(ctx,g,bots,slots,risk,now)
 local pairs_to_match={}
 for _,b in ipairs(bots) do for _,slot in ipairs(slots) do
  local p=slot_position(g,slot);local old=ctx.assignments[b.id]
  local score=distance(b.position,p)
  if old and old.key==slot.key then score=score-2 end
  if risk then score=score+risk(p)*4 end
  pairs_to_match[#pairs_to_match+1]={bot=b,slot=slot,score=score}
 end end
 table.sort(pairs_to_match,function(a,b)
  if a.score~=b.score then return a.score<b.score end
  if a.bot.id~=b.bot.id then return a.bot.id<b.bot.id end
  return a.slot.key<b.slot.key
 end)
 local used_bots,used_slots={},{}
 for _,pair in ipairs(pairs_to_match) do
  local b,slot=pair.bot,pair.slot
  if not used_bots[b.id] and not used_slots[slot.key] then
   used_bots[b.id]=true;used_slots[slot.key]=true
   ctx.pending[b.id]={key=slot.key,group=g.key,kind=g.kind,offset=slot.offset,
    angle=slot.angle,radius=slot.radius,sector=slot.sector,assigned=now}
  end
 end
end
function P.update(ctx,bots,leader,escorts,enemies,now,risk)
 local groups=P.groups(leader,escorts);local by_key={};local changed=false
 for _,g in ipairs(groups) do
  by_key[g.key]=g
  if not ctx.groups[g.key] then changed=true end
 end
 for key in pairs(ctx.groups) do if not by_key[key] then changed=true end end
 local signature={};for _,b in ipairs(bots) do signature[#signature+1]=b.id end
 table.sort(signature);signature=table.concat(signature,':')
 if signature~=ctx.signature then changed=true end
 -- Centers follow live units every frame. Sector/team assignments change at most once/second.
 if now<ctx.next_plan and not changed then
  for key,g in pairs(by_key) do
   local old=ctx.groups[key];old.position=g.position;old.members=g.members
  end
  return
 end
 ctx.next_plan=now+1;ctx.signature=signature;ctx.pending={}
 for _,g in ipairs(groups) do pressure(g,enemies,ctx.groups[g.key] and ctx.groups[g.key].pressure) end
 local available={};for _,b in ipairs(bots) do available[#available+1]=b end
 local escort_budget=#groups>1 and #bots>=3 and math.floor(#bots*.4) or 0
 -- Prefer nearby escort clusters when too few guards can cover every cluster.
 table.sort(groups,function(a,b)
  if a.kind~=b.kind then return a.kind=='player' end
  local da,db=distance(a.position,leader),distance(b.position,leader)
  if da==db then return a.key<b.key end;return da<db
 end)
 local escort_counts={}
 for n=1,escort_budget do
  local best=2
  for i=3,#groups do
   if (escort_counts[groups[i].key] or 0)<(escort_counts[groups[best].key] or 0) then best=i end
  end
  local key=groups[best].key;escort_counts[key]=(escort_counts[key] or 0)+1
 end
 for i=2,#groups do
  local g=groups[i];local team={};local count=escort_counts[g.key] or 0
  for n=1,count do
   local index,score
   for j,b in ipairs(available) do
    local old=ctx.assignments[b.id];local value=distance(b.position,g.position)
    if old and old.group==g.key then value=value-3 end
    if not score or value<score or (value==score and b.id<available[index].id) then index,score=j,value end
   end
   if index then team[#team+1]=table.remove(available,index) end
  end
  g.count=#team;g.slots=P.slots(g,#team,ctx.groups[g.key])
  assign_slots(ctx,g,team,g.slots,risk,now)
 end
 local human=groups[1];human.count=#available;human.slots=P.slots(human,#available,ctx.groups.player)
 assign_slots(ctx,human,available,human.slots,risk,now)
 ctx.groups=by_key;ctx.assignments=ctx.pending;ctx.pending=nil
end
function P.goal(ctx,id,now)
 local a=ctx.assignments[id];local g=a and ctx.groups[a.group]
 if not g then return end
 local p={x=g.position.x+a.offset.x,y=g.position.y+a.offset.y,z=g.position.z}
 -- Scan within the assigned arc. Each guard looks independently; feet keep their post.
 local sweep=math.sin(now*.35+id*1.7)*.32
 local look={x=math.cos(a.angle+sweep),y=math.sin(a.angle+sweep),z=0}
 return p,look,g.position,a
end
return P
