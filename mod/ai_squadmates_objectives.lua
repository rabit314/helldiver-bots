-- Explicit persistent orders. Native objective logic owns progress/timers/rewards.
return function(M,C,B,Orders,emit)
 local O=M.objectives or {tasks={},next_assign=0};M.objectives=O
 local component='objective_interact_object'
 local function live(u)return u~=nil and Unit.alive(u)end
 local function state(u,n,master)
  if not live(u) then return end
  if master and EntityAux.has_component_master(u,n) then return EntityAux.state_master(u,n) end
  if not master and EntityAux.has_component(u,n) then return EntityAux.state(u,n) end
 end
 local function position(u)
  assert(live(u),'Expired objective unit')
  local p=Unit.world_position(u,0);return {x=p.x,y=p.y,z=p.z}
 end
 local function surface(t,root)
  if M.clock>=(t.next_surface or 0) then
   t.next_surface=M.clock+.5;t.surface=nil;t.surface_offset=nil
   local settings=LuaSettingsManager and LuaSettingsManager:get_settings_by_unit(t.unit)
   local name=settings and settings.interact_info and settings.interact_info.interact_draw_node
   if name and type(Unit.node)=='function' and (not Unit.has_node or Unit.has_node(t.unit,name)) then
    local ok,node=pcall(Unit.node,t.unit,name)
    if ok and type(node)=='number' and node>=0 and node%1==0 then
     local v=Unit.world_position(t.unit,node)
     if v and v.x==v.x and v.y==v.y and C.distance(root,v)<16 then
      t.surface={x=v.x,y=v.y,z=root.z};t.surface_offset=C.distance(root,v)>.25 or nil
     end
    end
   end
  end
  return t.surface_offset and t.surface or root
 end
 O.marker=surface
 local function emit_status(t,value,reason)
  if t.status~=value or t.reason~=reason then
   t.status=value;t.reason=reason
   emit('objective_status',{status=value,reason=reason,target=tostring(t.unit),stage=t.stage},t.owner and t.owner.id)
  end
 end
 local function changed(t,b)
  t.approach_index=(t.approach_index or 0)+1;t.last_motion=M.clock;t.best_distance=nil
  b.interaction_check=nil;b.step_check=nil
  if t.approach_changed then t.approach_changed(b) end
 end
 local function release_input(b,reason)
  b.objective_input=nil
  local t=b.objective;local a=t and state(t.unit,component,true)
  if t and O.detach then return O.detach(b,t,reason) end
  if a and a.interacting_unit==b.unit and not b.objective_exiting then
   EntityAux.queue_command_master(b.unit,'character','exit_interact_objective');b.objective_exiting=true
  end
 end
 function O.release(b,reason,retain)
  local t=b.objective;if not t then return end
  release_input(b,reason);b.objective=nil;b.objective_exiting=nil
  t.owner=nil;t.operating=false;t.last_progress=nil;t.pulse=nil
  Orders.remove(M.orders,b.id)
  if not retain then O.tasks[t.unit]=nil end
  emit_status(t,retain and 'waiting_for_operator' or (reason or 'cancelled'))
  M.formation_dirty=true
 end
 function O.clear(reason)
  local tasks={};for _,t in pairs(O.tasks) do tasks[#tasks+1]=t end
  for _,t in ipairs(tasks) do if t.owner then O.release(t.owner,reason) end end
  O.tasks={}
 end
 local function available(b)
  local h=state(b.unit,'health');local c=state(b.unit,'character',true) or {}
  return b.active and h and not h.is_dead and not h.is_downed and not b.post and not b.guard_request
   and not b.returning and not b.objective and not b.vehicle_order and not c.current_seat_unit and not c.current_carry_unit
   and not b.grenade_action and not b.equipment_action and not b.stratagem_intent and not (b.job and b.job.kind=='revive')
 end
 local function assign(t,preferred)
  if not live(t.unit) then return false end
  local p=position(t.unit);local best,score=preferred
  if best then
   local h=state(best.unit,'health');local c=state(best.unit,'character',true) or {}
   if not best.active or not h or h.is_dead or h.is_downed or c.current_seat_unit then return false end
  end
  for _,b in ipairs(M.bots) do
   if not preferred and available(b) then
    local q=position(b.unit);local d=(q.x-p.x)^2+(q.y-p.y)^2+(q.z-p.z)^2
    if not score or d<score or (d==score and b.id<best.id) then best=b;score=d end
   end
  end
  if not best then return false end
  O.release(best,'reassigned')
  if M.vehicles then M.vehicles.release(best,'terminal_order') end
  if M.cancel_guard then M.cancel_guard(best) end
  B.release(M.behaviors,best,'objective_order',M.clock,emit)
  M.order_sequence=M.order_sequence+1;best.order_sequence=M.order_sequence
  best.post=nil;best.post_arrived=nil;best.objective=t;best.controller={};best.interaction_check=nil;best.returning=nil
  t.owner=best;t.started=M.clock;t.last_change=M.clock;t.last_progress=nil;t.operating=false;t.retries=0
  Orders.show(M.orders,best.id,t.cursor_point or p,M.clock);M.formation_dirty=true
  emit_status(t,'travelling');return true
 end
 function O.find(s,point)
  local found,score;local info={candidates=0}
  for u,e in pairs(B.entities(s,component,info)) do
   local a=state(u,component,true) or e.state
   if live(u) and a and a.mission_state~='complete' and a.mission_state~='failed' then
    local p=position(u);local d=C.distance(point,p)
    info.candidates=info.candidates+1
    if not info.nearest_distance or d<info.nearest_distance then info.nearest_distance=d;info.nearest_height=math.abs(p.z-point.z) end
    if d<=5 and math.abs(p.z-point.z)<3 and (not score or d<score) then found=u;score=d end
   end
  end
  return found,info
 end
 function O.request(s,point,preferred)
  O.install()
  if not M.objective_hook then return 'Terminal controls are not ready; order not accepted' end
  local found=O.find(s,point)
  if not found then return 'No supported objective terminal at the cursor (aim within 5 m)' end
  local existing=O.tasks[found]
  if existing and not existing.owner then return 'Objective is waiting for an available bot' end
  local t=existing or {unit=found,session=s,generation=M.generation}
  t.cursor_point=C.distance(point,position(found))>.3 and {x=point.x,y=point.y,z=point.z} or nil
  -- Re-aim an existing order without interrupting native entry or operation.
  if not t.operating and not t.pending_interaction and not t.native_attaching then
   t.cursor_active=t.cursor_point and true;t.approach=nil;t.best_distance=nil;t.last_motion=M.clock
   t.console_regions=nil;t.console_query=nil;t.console_search_started=nil
   if t.owner then changed(t,t.owner) end
  end
  if existing then
   Orders.show(M.orders,t.owner.id,point,M.clock)
   return 'Bot '..t.owner.id..': updated terminal approach',true
  end
  if not assign(t,preferred) then return 'No available bot on foot for this objective' end
  Orders.show(M.orders,t.owner.id,point,M.clock)
  O.tasks[found]=t
  emit('objective_ordered',{target=tostring(found),position=position(found),approach_point=t.cursor_point},t.owner.id)
  return 'Bot '..t.owner.id..': complete the objective at the cursor',true
 end
 function O.tick(s)
  O.install()
  if M.clock<O.next_assign then return end
  O.next_assign=M.clock+.5
  local gone={}
  for u,t in pairs(O.tasks) do
   if not live(u) or t.session~=s or t.generation~=M.generation then gone[#gone+1]=t
   elseif not t.owner then assign(t) end
  end
  for _,t in ipairs(gone) do
   if t.owner then O.release(t.owner,'target_unavailable') else O.tasks[t.unit]=nil end
  end
 end
 function O.route_failed(b)
  local t=b.objective;if not t then return end
  t.retries=(t.retries or 0)+1
  if t.retries>=6 then O.release(b,'blocked') else O.next_approach(b,'route_blocked');emit_status(t,'retrying_route') end
 end
 function O.next_approach(b,reason)
  local t=b.objective;if not t or M.clock<(t.next_approach or 0) then return end
  t.cursor_active=nil
  t.approach=(t.approach or 0)+math.pi/4;t.next_approach=M.clock+1
  if t.surface_offset and t.surface_base then
   local angles={0,math.pi/4,-math.pi/4,math.pi/2,-math.pi/2}
   t.approach=t.surface_base+angles[((t.approach_index or 0)+1)%#angles+1]
  end
  t.approach_outer=true
  t.pending_interaction=nil;t.next_attempt=nil
  -- A checked route to an old side must not keep overriding the new endpoint.
  changed(t,b)
  emit('objective_approach_changed',{reason=reason,attempt=t.approach_index,stage=t.stage},b.id)
 end
 function O.job(b,p,danger)
  local t=b.objective;if not t then return end
  local a=state(t.unit,component,true);local slave=state(t.unit,component)
  if not a then O.release(b,'target_unavailable');return end
  if a.mission_state=='complete' then O.release(b,'complete');return end
  if a.mission_state=='failed' then O.release(b,'failed');return end
  if O.observe and O.observe(b,t,a)==false then return end
  local h=state(b.unit,'health') or {};local root=position(t.unit);local center=O.surface and O.surface(t,root) or surface(t,root)
  if b.objective~=t then return end
  local interactor=state(b.unit,'interactor',true) or {}
  local current=a.current_stage or (a.stages and a.stages[a.current_stage_index]);local kind=current and current.interact_type
  local can=current and slave and slave.enabled and slave.can_interact and slave.can_interact(b.unit)
  local native_near=interactor.interactable_unit==t.unit and interactor.interactable_component==component
   and interactor.enabled~=false and not interactor.busy and C.distance(p,center)<=3.5
   and math.abs(p.z-center.z)<1.5 and can
  local token=tostring(a.current_stage_index)..':'..tostring(a.progress)..':'..tostring(a.enabled)
  if token~=t.last_progress then
   t.last_progress=token;t.last_change=M.clock;t.stage=a.current_stage_index;t.pulse=nil;t.awaiting=nil
   t.pending_interaction=nil;t.last_motion=M.clock;t.best_distance=nil
  end
  local reason
  if h.is_downed then reason='downed'
  elseif b.job then reason='helping_teammate'
  elseif danger then reason='avoiding_danger'
  elseif b.target and b.target.position and C.distance(p,b.target.position)<5 then reason='fighting'
  elseif a.interacting_unit and a.interacting_unit~=b.unit then reason='terminal_in_use'
  elseif not current then reason='waiting_for_stage'
  elseif t.surface_wait and not t.cursor_active then reason='locating_console'
  elseif kind~='combo' and kind~='buttonmash' and kind~='countdown' then reason='requires_player_action:'..tostring(kind)
  elseif kind=='countdown' or (tonumber(a.event_duration) or 0)>0 or a.enabled==false or current.interactor_disabled then reason='defending' end
  t.operating=false
  if reason then
   t.last_change=M.clock
   if reason~='defending' then release_input(b,reason) else b.objective_input=nil end
   emit_status(t,reason)
  end
  if M.clock-(t.last_change or t.started)>90 and kind~='countdown' and reason~='terminal_in_use' and not (reason and reason:find('requires_player_action',1,true)) then
   O.release(b,'no_progress');return
  end
  if b.job or h.is_downed then return end
  local cursor=t.cursor_active and t.cursor_point
  if cursor and (native_near or a.interacting_unit==b.unit or C.distance(p,cursor)<.65) then
   t.cursor_active=nil;cursor=nil;changed(t,b)
   emit('objective_cursor_reached',{point=t.cursor_point,native_selected=native_near==true},b.id)
  end
  local d=C.direction(center,p)
  if not t.approach then
   local settings=LuaSettingsManager and LuaSettingsManager:get_settings_by_unit(t.unit)
   if t.cursor_point and C.distance(center,t.cursor_point)>.3 then
    d=C.direction(center,t.cursor_point);t.approach_outer=nil
   elseif t.surface_offset then
    d=t.surface_outward or C.direction(root,center);t.surface_base=math.atan2(d.y,d.x);t.approach_outer=true
    emit('objective_surface',{root=root,console=center,source='interact_draw_node',
     approach_direction=d,collision_policy='route around objective body'},b.id)
   elseif not can and settings and (settings.interact_info or {}).interact_angle then
    local f=Quaternion.forward(Unit.world_rotation(t.unit,0));local sign=d.x*(-f.y)+d.y*f.x<0 and -1 or 1
    d={x=-f.y*sign,y=f.x*sign};t.approach_outer=true
   end
   t.approach=math.atan2(d.y,d.x)
  end
  local function approach_goal()
   if t.cursor_active then return t.cursor_point end
   local radius=t.approach_outer and 2.2 or (t.surface_offset and .65 or .9)
   return {x=center.x+math.cos(t.approach)*radius,y=center.y+math.sin(t.approach)*radius,z=center.z}
  end
  local goal=approach_goal()
  if not cursor and t.approach_outer and C.distance(p,goal)<.35 then
   t.approach_outer=nil;t.best_distance=nil;t.last_motion=M.clock;b.step_check=nil
   if t.approach_changed then t.approach_changed(b) end
   goal=approach_goal()
  end
  local owned=a.interacting_unit==b.unit
  if not owned then b.objective_exiting=nil end
  local distance=C.distance(p,goal)
  if not t.best_distance or distance<t.best_distance-.15 then t.best_distance=distance;t.last_motion=M.clock end
  if not reason and not owned and M.clock-(t.last_motion or M.clock)>4 and distance<3 then
   O.next_approach(b,'approach_stalled');goal=approach_goal()
  end
  if not reason and not owned and t.pending_interaction and M.clock-t.pending_interaction>3 then
   O.next_approach(b,'interaction_not_acknowledged');goal=approach_goal()
  end
  if not cursor and not reason and not owned and C.distance(p,center)<1.4 and slave and slave.can_interact and not slave.can_interact(b.unit) then
   O.next_approach(b,'native_interaction_side');goal=approach_goal()
  end
  if not reason and owned and not b.objective_exiting and (not O.ready or O.ready(b,t)) then
   t.operating=true;emit_status(t,'operating')
   b.objective_input=b.objective_input or {output_table=C.neutral()}
  elseif not reason then emit_status(t,C.distance(p,goal)>1.1 and 'travelling' or 'approaching') end
  if native_near and not reason then goal={x=p.x,y=p.y,z=p.z} end
  if t.surface_wait and not t.cursor_active then goal={x=p.x,y=p.y,z=p.z} end
  if not owned and not reason and M.clock>=(t.next_wait_log or 0) then
   t.next_wait_log=M.clock+3
   emit('objective_approach_wait',{distance=C.distance(p,center),native_selected=native_near==true,
    selected=interactor.interactable_unit and tostring(interactor.interactable_unit),
    approach=t.approach_index,outer=t.approach_outer==true,can_interact=can==true,
    enabled=interactor.enabled,busy=interactor.busy,position=p,root=root,console=center,goal=goal,
    cursor_approach=t.cursor_active==true,probe=b.interaction_check and b.interaction_check.reason},b.id)
  end
  return {kind='objective',unit=t.unit,component=component,key='objective:'..tostring(t.unit),priority=1,
   position=goal,target_position=native_near and goal or center,native_interaction=native_near,
   interactable_actor=native_near and interactor.interactable_actor,defending=reason~=nil,operating=t.operating,
   next_attempt=t.next_attempt,objective=t,approach_index=t.approach_index,
   cursor_approach=t.cursor_active==true,pending_interaction=t.pending_interaction~=nil}
 end
 function O.interact(b,job,now)
  local t=job.objective
  if job.cursor_approach or job.defending or t.operating or (t.next_attempt or 0)>now then return end
  local a=state(job.unit,component,true);local slave=state(job.unit,component)
  if not a or a.interacting_unit or not slave or not slave.enabled or not slave.can_interact or not slave.can_interact(b.unit) then return end
  if B.interact(b,job,now,emit) then
   t.next_attempt=now+2.5;t.pending_interaction=now;emit_status(t,'starting_interaction')
  elseif now>=(t.next_wait_log or 0) then
   t.next_wait_log=now+3
   local i=state(b.unit,'interactor',true) or {}
   emit('objective_interaction_wait',{enabled=i.enabled,busy=i.busy,stage=t.stage},b.id)
  end
 end
 function O.input(b,job,p,input)
  if job.defending then
   local a=state(job.unit,component,true)
   if job.objective.status=='defending' and a and a.interacting_unit==b.unit then return C.neutral() end
   return input
  end
  -- The native request can acknowledge after this frame's job was calculated.
  -- Neutralize the request frame too, before walk/aim can abort native entry.
  if job.operating or job.objective.pending_interaction or job.objective.native_attaching then return C.neutral() end
  local center=job.target_position or position(job.unit)
  if C.distance(p,center)<4 then input.aim=C.direction(p,center);input.sprint=false end
  return input
 end
 function O.native_input(b,a)
  local t=b.objective;local output=C.neutral()
  if not t or not t.operating or t.unit==nil or a.interacting_unit~=b.unit or b.objective_exiting then return output end
  local current=a.current_stage or {};local kind=current.interact_type
  if kind=='buttonmash' then
   -- No physical pad is registered for a bot. The native controller branch reads
   -- one boolean interact edge per update; alternate true/false updates.
   if t.mash then t.mash=false;return output end
   if M.clock>=(t.next_mash or 0) then t.mash=true;t.next_mash=M.clock+.12;output.interact=true end
   return output
  end
  if kind~='combo' or type(current.combo)~='table' then return output end
  local progress=tonumber(a.progress) or 0
  if t.release then t.release=false;return output end
  if M.clock<(t.next_key or 0) then return output end
  if t.awaiting and t.awaiting==progress and M.clock<(t.retry_key or 0) then return output end
  local direction=current.combo[progress+1]
  if direction~='up' and direction~='down' and direction~='left' and direction~='right' then return output end
  output['stratagem_'..direction]=true;t.release=true;t.awaiting=progress
  t.next_key=M.clock+.12;t.retry_key=M.clock+.8
  return output
 end
 function O.install()
  if M.objective_hook or type(ObjectiveInteractObjectComponent)~='table' or type(ObjectiveInteractObjectComponent.update_masters)~='function' then return end
  local object=ObjectiveInteractObjectComponent;local old=object.update_masters
  local wrapper=function(self,entities,dt,...)
   local prepared={}
   for u,e in pairs(entities) do
    local a=e.state;local b=a and M.units[a.interacting_unit]
    if b and b.active and b.objective and b.objective.unit==u then
     b.objective_input=b.objective_input or {output_table=C.neutral()}
     b.objective_input.output_table=O.native_input(b,a);prepared[#prepared+1]=b
    end
   end
   local result={pcall(old,self,entities,dt,...)}
   for _,b in ipairs(prepared) do if b.objective_input then b.objective_input.output_table=C.neutral() end end
   if not result[1] then error(result[2]) end
   return unpack(result,2)
  end
  object.update_masters=wrapper;M.objective_hook={object=object,original=old,wrapper=wrapper}
 end
 function O.uninstall()
  O.clear('unloaded');local h=M.objective_hook
  if h and h.object.update_masters==h.wrapper then h.object.update_masters=h.original end
  M.objective_hook=nil
 end
 O.install();return O
end
