-- Explicit posts and seats survive their operator's death. Native tasks stay native.
return function(M,C,B,S,O,V,Orders,emit)
 if M.order_inheritance then return M.order_inheritance end
 local H={pending={}};M.order_inheritance=H
 local function live(u)return u~=nil and type(u)~='boolean' and Unit.alive(u)end
 local function state(u,n)
  if not live(u) then return {} end
  if EntityAux.has_component_master(u,n) then return EntityAux.state_master(u,n) or {} end
  if EntityAux.has_component(u,n) then return EntityAux.state(u,n) or {} end
  return {}
 end
 local function point(p)return p and {x=p.x,y=p.y,z=p.z or 0}end
 local function position(u)if live(u) then return point(Unit.world_position(u,0))end end
 local function human(u)
  for _,p in ipairs(M.session and M.session.players or {}) do local go=p.player_go
   if go and go:exists() and go:has('avatar_unit') and go:get('avatar_unit')==u then return true end
  end
 end
 local function free(b)
  local h=state(b.unit,'health');local c=state(b.unit,'character')
  return b.active and live(b.unit) and not human(b.unit) and not h.is_dead and not h.is_downed
   and not c.current_seat_unit and not c.current_carry_unit and not b.post and not b.guard_request
   and not b.objective and not b.package_duty and not b.vehicle_order and not b.job and not b.tactical_job
   and not b.stratagem_intent and not b.grenade_action and not b.equipment_action and not state(b.unit,'interactor').busy
 end
 function H.depart(b,reason)
  if reason~='died' or human(b.unit) then return end
  local t=b.vehicle_order;local order
  if b.post then order={kind='post',position=point(b.post),facing=point(b.post_facing)}
  elseif b.guard_request and b.guard_request.point then order={kind='post',ground_request=b.guard_request,position=point(b.guard_request.point)}
  elseif t and (t.source=='f8' or t.route_source=='f8') then
   order={kind='vehicle',unit=t.unit,vehicle=t.vehicle,index=t.index,destination=t.route_source=='f8' and point(t.destination),position=position(t.vehicle)}
  end
  if order then
   order.session=M.session;order.generation=M.generation;order.previous=b.id
   H.pending[#H.pending+1]=order
   emit('order_waiting_for_successor',{kind=order.kind,position=order.position,previous_bot=b.id},b.id)
  end
 end
 function H.ground_ready(request,ground)
  for _,task in ipairs(H.pending) do if task.ground_request==request and task.session==M.session and task.generation==M.generation then
   task.ground_request=nil;task.position=point(ground)
   task.facing=C.direction(M.player_anchor or task.position,task.position)
  end end
 end
 function H.clear(reason)
  if #H.pending>0 then emit('inherited_orders_cleared',{reason=reason,count=#H.pending}) end
  H.pending={}
 end
 function H.tick()
  for i=#H.pending,1,-1 do local task=H.pending[i];local done=false
   if task.session~=M.session or task.generation~=M.generation then done=true
   elseif task.kind=='vehicle' then
    if not live(task.vehicle) or not live(task.unit) or state(task.vehicle,'health').is_dead then done=true
    else
     local occupant=(state(task.unit,'seat').seated_units or {})[task.index]
     if live(occupant) and not state(occupant,'health').is_dead then done=true
     else task.position=position(task.vehicle) end
    end
   end
   if task.ground_request and M.clock>task.ground_request.expires then done=true end
   if not done and not task.ground_request and task.position then
    local nearest,distance
    for _,b in ipairs(M.bots) do if free(b) then local p=position(b.unit);local q=task.position
     local d=(p.x-q.x)^2+(p.y-q.y)^2+(p.z-q.z)^2
     if not distance or d<distance or d==distance and b.id<nearest.id then nearest=b;distance=d end
    end end
    if nearest then
     local b=nearest;local accepted
     if task.kind=='post' then
      S.cancel(b);M.cancel_guard(b);b.post=point(task.position);b.post_facing=point(task.facing)
      b.post_arrived=false;b.returning=nil;b.controller={};M.order_sequence=M.order_sequence+1;b.order_sequence=M.order_sequence
      Orders.show(M.orders,b.id,b.post,M.clock);M.formation_dirty=true;accepted=true
     else
      local _,ok=V.request(M.session,task.position,b,{unit=task.vehicle,seat=task.unit,index=task.index,source='f8'})
      accepted=ok
      if accepted and task.destination then
       b.vehicle_order.destination=point(task.destination);b.vehicle_order.route_source='f8';b.vehicle_order.auto_park=nil
      end
     end
     if accepted then
      done=true;emit('order_inherited',{kind=task.kind,previous_bot=task.previous,position=task.position},b.id)
     end
    end
   end
   if done then table.remove(H.pending,i) end
  end
 end
 return H
end
