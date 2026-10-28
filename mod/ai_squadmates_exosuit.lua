-- EXO combat spacing and shared mobile-vehicle evacuation through native exits.
return function(M,C,S,V,emit)
 local X={evacuations={},blocked=setmetatable({}, {__mode='k'})}
 local function live(u)return u~=nil and Unit.alive(u)end
 local function state(u,n)
  if not live(u) then return end
  if EntityAux.has_component_master(u,n) then return EntityAux.state_master(u,n) end
  if EntityAux.has_component(u,n) then return EntityAux.state(u,n) end
 end
 local function pos(u)
  local p=Unit.world_position(u,0);return {x=p.x,y=p.y,z=p.z}
 end
 function X.critical(u)
  local v=state(u,'vehicle') or {}
  if not V.mobile(u) then return end
  local h=state(u,'health') or v.health_state or {}
  if h.is_dead then return end -- Native destruction already happened.
  local hp=tonumber(h.hitpoints_real or h.hitpoints)
  local max=tonumber(h.max_hitpoints)
  if h.is_downed or (v.health_state or {}).is_downed or (hp and hp<=0) then return 'disabled',hp,max end
  -- Low health alone is still usable. Leave only when native disable begins.
 end
 function X.clear(b)
  if b.exo_close then S.cancel(b);b.vehicle_step=nil end
  b.exo_close=nil
 end
 function X.unavailable(u)
  if X.critical(u) then return true end
  return M.clock<(X.blocked[u] or 0)
 end
 local function leave(b,t,reason,hp,max)
  if X.evacuating(b,t.vehicle) then return end
  local p=pos(t.vehicle);local v=state(t.vehicle,'vehicle') or {}
  local explosive=(v.vehicle_info or {}).explosive_info or {}
  local r={unit=t.vehicle,seat=t.unit,index=t.index,position=p,reason=reason,
   radius=reason=='disabled' and math.max(8,(tonumber(explosive.blast_radius) or 0)+2) or nil,
   expires=M.clock+12,next_retry=M.clock+.35,generation=M.generation,bot=b}
  X.evacuations[b.id]=r
  if b.vehicle_input then b.vehicle_input.output_table=C.neutral() end
  local c=state(b.unit,'character') or {};local a=state(t.unit,'seat') or {}
  local seated=c.current_seat_unit==t.unit or (a.seated_units or {})[t.index]==b.unit
  local exit_reason=reason=='disabled' and 'vehicle_critical' or 'vehicle_follow_blocked'
  V.release(b,exit_reason)
  if seated then b.next_exit=0;V.exit(b,t.unit,exit_reason) end
  local kind=(v.vehicle_info or {}).vehicle_type
  emit(kind=='exosuit' and reason=='disabled' and 'exosuit_evacuating' or 'vehicle_evacuating',
   {reason=reason,vehicle_kind=kind,seat_index=t.index,hitpoints=hp,max_hitpoints=max,position=p,radius=r.radius},b.id)
 end
 local function leave_assembly(b,t,reason,hp,max)
  -- Release bot occupants together; no command is issued for a human occupant.
  for _,other in ipairs(M.bots) do if other.active then
   local order=other.vehicle_order;local c=state(other.unit,'character') or {}
   local seat=c.current_seat_unit
   if order and order.vehicle==t.vehicle then leave(other,order,reason,hp,max)
   elseif live(seat) and V.root(seat)==t.vehicle and c.current_seat_index then
    leave(other,{unit=seat,vehicle=t.vehicle,index=c.current_seat_index},reason,hp,max)
   end
  end end
  if not X.evacuating(b,t.vehicle) then leave(b,t,reason,hp,max) end
 end
 function X.emergency(b,t)
  if not t or not live(t.vehicle) then return false end
  local reason,hp,max=X.critical(t.vehicle)
  if not reason then return false end
  leave_assembly(b,t,reason,hp,max)
  return true
 end
 function X.stranded(b,m)
  local H=M.mobility;local q=b.follow_progress
  if not H or not m.pilot or not (m.order or b.vehicle_order) or not H.following(b) or H.human_aboard(m.vehicle) or b.rejoin_probe or b.rejoin_commit
   or not q or q.root~=m.vehicle or not q.intended or q.gap<12 or q.blocked_seconds<12 then return false end
  -- A visible/unchecked assembly cannot warp. Park and recover normally on foot.
  X.blocked[m.vehicle]=M.clock+30
  emit('vehicle_follow_abandoned',{position=pos(m.vehicle),gap=q.gap,blocked_seconds=q.blocked_seconds,
   reason=b.rejoin_note,vehicle=tostring(m.vehicle)},b.id)
  leave_assembly(b,m.order or b.vehicle_order,'follow_blocked')
  return true
 end
 function X.evacuating(b,u)
  local r=X.evacuations[b.id]
  return r and r.unit==u and r.generation==M.generation and M.clock<r.expires
 end
 function X.tick()
  local hazards=M.behaviors.hazards
  local seen={}
  for i=#hazards,1,-1 do if hazards[i].source=='exosuit_evacuation' then table.remove(hazards,i) end end
  for id,r in pairs(X.evacuations) do
   local b=r.bot
   if not b.active or not live(b.unit) or r.generation~=M.generation or M.clock>=r.expires then
    X.evacuations[id]=nil
   else
    if live(r.unit) then
     r.position=pos(r.unit)
     local c=state(b.unit,'character') or {};local a=state(r.seat,'seat') or {}
     if (c.current_seat_unit==r.seat or (a.seated_units or {})[r.index]==b.unit) and M.clock>=r.next_retry then
      b.next_exit=0;V.exit(b,r.seat,r.reason=='disabled' and 'vehicle_critical' or 'vehicle_follow_blocked');r.next_retry=M.clock+.35
     end
    end
    if r.radius and not seen[r.unit] then
     seen[r.unit]=true;hazards[#hazards+1]={position=r.position,radius=r.radius,height=3,kind='vehicle_explosion',source='exosuit_evacuation'}
    end
   end
  end
 end
 function X.reset()
  X.evacuations={};X.blocked=setmetatable({}, {__mode='k'})
  X.tick()
 end
 local function usable(w)
  local a=w.ammo
  return a.heat~=nil or type(a.rounds)~='number' or a.rounds>0 or (tonumber(a.num_mags) or 0)>0 or a.is_reloading
 end
 function X.spacing(b,m,p,goal,friends)
  local target=b.target;local status=b.vehicle_status
  if not m.pilot or not target or not target.alive or not target.enemy or not live(target.id)
    or not status or not status.visible or math.abs((target.position.z or 0)-p.z)>3 then X.clear(b);return end
  local utility=false;local splash=math.huge
  for _,w in ipairs(m.weapons or {}) do if usable(w) then
   if w.profile.splash<=0 then utility=true else splash=math.min(splash,w.profile.splash) end
  end end
  local close=utility and 5 or (splash<math.huge and math.max(5,splash+3) or 5)
  local v=state(m.vehicle,'vehicle') or {};local inventory=state(m.vehicle,'exosuit_inventory') or {}
  if not utility and splash==math.huge and (v.vehicle_info or {}).has_grenade_launcher
    and (tonumber(inventory.num_grenades) or 0)>0 then close=9 end
  local release=close+1.5;local distance=C.distance(p,target.position)
  local previous=b.exo_close
  local active=previous and previous.target==target.id and distance<release+1.5
  if distance>=close and (not active or C.distance(goal,target.position)>=release) then X.clear(b);return end
  local away=C.direction(target.position,p)
  if distance<.1 then
   local f=Quaternion.forward(Unit.world_rotation(m.vehicle,0));away={x=-f.x,y=-f.y}
  end
  if not previous or previous.target~=target.id then
   S.cancel(b);b.vehicle_step=nil;b.vehicle_progress=nil;b.vehicle_stuck=0
   emit('exosuit_close_target',{distance=distance,spacing=release},b.id,'behavior')
  end
  local function clear(q)
   local dir=C.direction(p,q);local step=math.min(1.8,C.distance(p,q))
   return V.pedestrian_clear(p,{x=p.x+dir.x*step,y=p.y+dir.y*step,z=p.z},friends or {})
  end
  if previous and previous.target==target.id and previous.goal and C.distance(previous.goal,target.position)>=release-.3
    and C.distance(previous.target_position,target.position)<.6 and clear(previous.goal) then return previous.goal end
  local chosen
  -- Back away first, then try a diagonal or lateral step around a person behind us.
  for _,angle in ipairs({0,math.pi/3,-math.pi/3,math.pi/2,-math.pi/2}) do
   local c,s=math.cos(angle),math.sin(angle)
   local dir={x=away.x*c-away.y*s,y=away.x*s+away.y*c}
   local projection=(p.x-target.position.x)*dir.x+(p.y-target.position.y)*dir.y
   local length=math.max(0,-projection+math.sqrt(math.max(0,projection*projection+release*release-distance*distance)))
   local q={x=p.x+dir.x*length,y=p.y+dir.y*length,z=p.z}
   chosen=chosen or q
   if clear(q) then chosen=q;break end
  end
  b.exo_close={target=target.id,goal=chosen,target_position={x=target.position.x,y=target.position.y,z=target.position.z}}
  return chosen
 end
 return X
end
