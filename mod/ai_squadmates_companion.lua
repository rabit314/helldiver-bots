-- Persistent companion duties and deployment policy; native actions own effects.
return function(M,C,B,S,O,V,Orders,emit,enqueue)
 if M.companion then M.companion.enqueue=enqueue;return M.companion end
 local F={duties={},enqueue=enqueue};M.companion=F
 local function live(u)return u~=nil and type(u)~='boolean' and Unit.alive(u)end
 local function state(u,n)
  if not live(u) then return {} end
  if EntityAux.has_component_master(u,n) then return EntityAux.state_master(u,n) or {} end
  if EntityAux.has_component(u,n) then return EntityAux.state(u,n) or {} end
  return {}
 end
 local function pos(u)if live(u) then local p=Unit.world_position(u,0);return {x=p.x,y=p.y,z=p.z}end end
 local function human(u)
  for _,p in ipairs(M.session and M.session.players or {}) do local g=p.player_go
   if g and g:exists() and g:has('avatar_unit') and g:get('avatar_unit')==u then return true end
  end
  return false
 end
 local function finish(d,reason)
  F.duties[d.item]=nil
  if d.owner and d.owner.package_duty==d then d.owner.package_duty=nil end
  emit('package_duty_finished',{item=tostring(d.item),reason=reason},d.owner and d.owner.id)
 end
 local function available(b)
  local h=state(b.unit,'health');local c=state(b.unit,'character')
  return b.active and live(b.unit) and not human(b.unit) and not h.is_dead and not h.is_downed
   and not c.current_seat_unit and not c.current_carry_unit and not b.package_duty and not b.objective
   and not b.post and not b.guard_request and not b.job and not b.tactical_job and not b.stratagem_intent
   and not b.grenade_action and not b.equipment_action and not b.vehicle_order and not state(b.unit,'interactor').busy
 end
 local request,release,clear,tick=O.request,O.release,O.clear,O.tick
 function O.request(s,point,preferred)
  local reply,ok=request(s,point,preferred)
  if ok then for _,b in ipairs(M.bots) do local t=b.objective
   if t and (t.component=='objective_carry_object' or t.delivery) then
    local item=t.item or t.unit;local d=F.duties[item]
    if not d then d={item=item,session=s,generation=M.generation};F.duties[item]=d end
    if d.owner and d.owner~=b then d.owner.package_duty=nil end
    d.owner=b;b.package_duty=d;t.package_duty=d
    if t.delivery then d.destination=t.unit end
   end
  end end
  return reply,ok
 end
 function O.release(b,reason,retain)
  local d=b.package_duty
  if d then
   if reason=='recalled' then d.destination=nil;d.dropping=nil
   elseif reason=='died' or reason=='controller_failed' then
    d.owner=nil;b.package_duty=nil
   elseif reason=='possessed' or reason=='control_switched' or human(b.unit) then finish(d,'human_control')
   elseif reason=='delivered' or reason=='item_unavailable' or reason=='item_has_another_carrier' then finish(d,reason)
   elseif reason~='pickup_confirmed' and reason~='item_dropped' and reason~='blocked' and not d.restoring then finish(d,reason or 'cancelled') end
   -- Orphan device tasks must never enter the generic terminal reassignment path.
   local t=b.objective
   if t and t.package_duty and retain then O.tasks[t.unit]=nil;retain=false end
  end
  return release(b,reason,retain)
 end
 function O.clear(reason)
  clear(reason)
  if reason~='recalled' then
   local list={};for _,d in pairs(F.duties) do list[#list+1]=d end
   for _,d in ipairs(list) do finish(d,reason or 'cleanup') end
  else for _,d in pairs(F.duties) do d.destination=nil;d.dropping=nil end end
 end
 local function recover(d,b)
  local p=pos(d.item);if not p then return end
  M.order_sequence=M.order_sequence+1
  local t={unit=d.item,component='objective_carry_object',owner=b,session=M.session,generation=M.generation,
   started=M.clock,last_change=M.clock,last_motion=M.clock,order=M.order_sequence,approach=0,approach_outer=true,retries=0,package_duty=d}
  O.tasks[d.item]=t;b.objective=t;b.controller={};b.returning=nil;S.cancel(b)
  Orders.show(M.orders,b.id,p,M.clock);emit('package_recovery_requested',{item=tostring(d.item)},b.id)
 end
 function O.tick(s)
  if M.clock>=(F.next_duty or 0) then
   F.next_duty=M.clock+.25
   local list={};for _,d in pairs(F.duties) do list[#list+1]=d end
   for _,d in ipairs(list) do
    local a=state(d.item,'objective_carry_object');local b=d.owner
    if not live(d.item) or d.session~=s or d.generation~=M.generation or a.mission_state=='complete' or a.mission_state=='failed' then finish(d,'native_completion_or_cleanup')
    elseif live(a.carrier) and not state(a.carrier,'health').is_dead and (not b or a.carrier~=b.unit) then finish(d,'another_carrier')
    else
     if b and (not b.active or not live(b.unit) or state(b.unit,'health').is_dead) then
      if b.objective then O.release(b,'died',true) end
      b.package_duty=nil;d.owner=nil;b=nil
     end
     if not b then
      local best,distance
      for _,candidate in ipairs(M.bots) do if available(candidate) then
       local p,q=pos(candidate.unit),pos(d.item)
       local n=p and q and math.sqrt((p.x-q.x)^2+(p.y-q.y)^2+(p.z-q.z)^2)
       if n and (not distance or n<distance or n==distance and candidate.id<best.id) then best=candidate;distance=n end
      end end
      if best then b=best;d.owner=b;b.package_duty=d;emit('package_duty_transferred',{item=tostring(d.item)},b.id) end
     end
     if b then
      local c=state(b.unit,'character');local carrying=c.current_carry_unit==d.item or a.carrier==b.unit
      if human(b.unit) then finish(d,'human_control')
      elseif carrying then
       d.missing_since=nil
       if d.destination and not b.objective and not state(b.unit,'health').is_downed and live(d.destination) then
        d.restoring=true;O.request(s,pos(d.destination),b);d.restoring=nil
       end
      elseif not state(b.unit,'health').is_downed then
       local t=b.objective
       if t and t.delivery and t.drop_requested then d.dropping=d.dropping or t.drop_requested end
       if not d.dropping then
        d.missing_since=d.missing_since or M.clock
        if M.clock-d.missing_since>=1 and not b.objective and not b.job and not b.grenade_action then recover(d,b) end
       end
      end
     end
    end
   end
  end
  return tick(s)
 end
 function M.set_auto_deploy(enabled,target)
  target=tonumber(target) or 3
  assert(target==target and target>=1 and target<math.huge and target%1==0,'Bot target must be a positive integer')
  if enabled and not M.auto_deploy then M.auto_paused=nil end
  M.auto_deploy=enabled==true;M.auto_target=target
  local kept=0;local count=0
  for _,b in ipairs(M.bots) do if b.active and live(b.unit) and not state(b.unit,'health').is_dead and not human(b.unit) then count=count+1 end end
  for _,r in pairs(M.pending) do if r.source~='automatic' or r.dispatched then kept=kept+1 end end
  local remaining=M.auto_deploy and math.max(0,target-count-kept) or 0
  local q=M.waiting;local next_queue={first=1,last=0,items={}}
  for i=q.first,q.last do local r=q.items[i]
   if r and r.source=='automatic' and not r.dispatched then
    if remaining>0 then remaining=remaining-1 else
     r.cancelled=true;if M.pending[r.id]==r then M.pending[r.id]=nil;M.pending_count=M.pending_count-1 end
     emit('deployment_cancelled',{reason='automatic_target_reduced'},r.id)
    end
   end
   if r and not r.cancelled then next_queue.last=next_queue.last+1;next_queue.items[next_queue.last]=r end
  end
  M.waiting=next_queue
  return M.status()
 end
 function M.dismiss()
  local enabled=M.enabled;M.disable('dismissed');M.auto_paused=M.session;F.session=M.session
  M.enabled=enabled;M.heartbeat=0;return M.status()
 end
 function F.auto(s,leader,record)
  if F.session~=s then F.session=s;M.auto_paused=nil;F.next_auto=0 end
  if not M.auto_deploy or M.auto_paused==s or M.waiting_for_player or M.clock<(F.next_auto or 0) then return end
  local count=0
  for _,b in ipairs(M.bots) do if b.active and live(b.unit) and not state(b.unit,'health').is_dead and not human(b.unit) then count=count+1 end end
  for _,r in pairs(M.pending) do if r.source=='automatic' then return end end
  if count+M.pending_count<(M.auto_target or 3) then
   F.next_auto=M.clock+5
   local id=F.enqueue(s,leader,record);M.pending[id].source='automatic'
  end
 end
 local function bike(u)return live(u) and (state(V.root(u),'vehicle').vehicle_info or {}).vehicle_type=='bike'end
 function F.bike_exit(root,leader)
  if not bike(root) then return end
  for _,b in ipairs(M.bots) do local c=state(b.unit,'character')
   if b.active and not human(b.unit) and live(c.current_seat_unit) and V.root(c.current_seat_unit)==root then
    local t=b.vehicle_order or {unit=c.current_seat_unit,vehicle=root}
    if b.vehicle_input then b.vehicle_input.output_table=C.neutral() end
    b.next_exit=nil;V.policy.begin_exit(b,t,'human_left_bike');b.bike_exit_lock=root
    V.exit(b,c.current_seat_unit,'human_left_bike')
   end
  end
 end
 if V.policy then V.policy.human_exited=F.bike_exit end
 function F.bikes(leader)
  local seat=state(leader,'character').current_seat_unit
  local root=live(seat) and V.root(seat)
  if F.ridden and F.rider==leader and root~=F.ridden then F.bike_exit(F.ridden,leader) end
  F.ridden=bike(root) and root or nil;F.rider=leader
  for _,b in ipairs(M.bots) do if b.bike_exit_lock then
   if root==b.bike_exit_lock then b.bike_exit_lock=nil;b.seat_reboard=nil
   else b.seat_reboard={vehicle=b.bike_exit_lock,until_time=math.huge} end
  end end
 end
 return F
end
