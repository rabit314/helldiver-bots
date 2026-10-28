-- F8 native device/carry adapters. No objective flags, rewards or timers are written.
return function(M,C,B,O,S,Orders,emit)
 local components={'objective_interact_object','extract_beacon','hellbomb','objective_carry_object','custom_pickup','droppoint','objective_defend_object'}
 local labels={extract_beacon='activate extraction',hellbomb='activate Hellbomb',objective_carry_object='collect carry item',custom_pickup='collect item',droppoint='deliver carried item',objective_defend_object='activate missile launch and defend'}
 local hooks=M.interaction_hooks or {};M.interaction_hooks=hooks
 local function live(u)return u~=nil and Unit.alive(u)end
 local function state(u,n,master)
  if not live(u) then return end
  if master and EntityAux.has_component_master(u,n) then return EntityAux.state_master(u,n) end
  if not master and EntityAux.has_component(u,n) then return EntityAux.state(u,n) end
 end
 local function pos(u,node)
  if not live(u) then return end
  local p=Unit.world_position(u,node or 0);return {x=p.x,y=p.y,z=p.z}
 end
 local function settings(u)
  return LuaSettingsManager and LuaSettingsManager:get_settings_by_unit(u) or {}
 end
 local function missile(u)
  local a=settings(u).objective_info or {}
  return a.display_name_single=='mission_objective_missile_ramp_single' or a.display_name_plural=='mission_objective_missile_ramp'
 end
 local function status(t,name,reason)
  if t.status~=name or t.reason~=reason then
   t.status=name;t.reason=reason
   emit('objective_status',{order=t.order,status=name,reason=reason,component=t.component,
    target=tostring(t.unit),position=pos(t.unit),stage=t.stage},t.owner and t.owner.id)
  end
 end
 local old_find,old_request,old_job=O.find,O.request,O.job
 local old_release,old_interact,old_input,old_install,old_uninstall=O.release,O.interact,O.input,O.install,O.uninstall
 local old_route_failed=O.route_failed
 function O.resolve(s,point)
  local best,score;local info={candidates=0,types={}}
  for _,name in ipairs(components) do
   for u in pairs(B.entities(s,name,info)) do if live(u) then
    local a=state(u,name,true) or state(u,name)
    local complete=a and (a.mission_state=='complete' or a.mission_state=='failed' or a.is_armed or a.was_dead)
    if a and not complete and (name~='objective_defend_object' or missile(u)) then
     local p=pos(u);local d=C.distance(point,p);info.candidates=info.candidates+1
     info.types[name]=(info.types[name] or 0)+1
     if not info.nearest_distance or d<info.nearest_distance then info.nearest_distance=d;info.nearest_component=name;info.nearest_height=math.abs(p.z-point.z) end
     if d<=5 and math.abs(p.z-point.z)<3 and (not score or d<score) then best={unit=u,component=name};score=d end
    end
   end end
  end
  for u in pairs(B.entities(s,'objective_extract_lz',info)) do if live(u) then
   local a=state(u,'objective_extract_lz',true) or {};local beacon=a.beacon_unit
   local d=C.distance(point,pos(u))
   if live(beacon) and state(beacon,'extract_beacon',true) and d<=5 and (not score or d<score) then
    best={unit=beacon,component='extract_beacon',resolved_from='objective_extract_lz'};score=d
   end
  end end
  return best,info
 end
 function O.find(s,point)
  local found,info=O.resolve(s,point);return found and found.unit,info
 end
 local function suitable(b)
  local h=b and state(b.unit,'health');local c=b and state(b.unit,'character',true) or {}
  return b and b.active and h and not h.is_dead and not h.is_downed and not live(c.current_seat_unit)
   and not (b.job and b.job.kind=='revive')
 end
 local function pick(point,preferred,carry)
  if carry then
   for _,b in ipairs(M.bots) do
    local c=state(b.unit,'character',true) or {}
    if suitable(b) and live(c.current_carry_unit) then return b end
   end
   return
  end
  if suitable(preferred) then return preferred end
  local best,score
  for _,b in ipairs(M.bots) do if suitable(b) and not b.objective then
   local c=state(b.unit,'character',true) or {}
   if not live(c.current_carry_unit) then
    local d=C.distance(pos(b.unit),point)
    if not score or d<score then best=b;score=d end
   end
  end end
  return best
 end
 local function drop_point(u,item)
  local cfg=settings(u);local info=cfg.objective_info or {};local dp=cfg.droppoint_info or {}
  local name=info.drop_off_node or (dp.droppoint_joints or {})[1]
  local p=pos(u)
  if name and Unit.node then p=pos(u,Unit.node(u,name)) or p end
  return p
 end
 function O.request(s,point,preferred)
  O.install();local found,scan=O.resolve(s,point)
  emit('objective_target_resolved',{point=point,target=found and tostring(found.unit),component=found and found.component,scan=scan},preferred and preferred.id)
  if not found then return 'No supported objective at cursor' end
  local a=state(found.unit,found.component,true) or state(found.unit,found.component) or {}
  if found.component=='custom_pickup' and a.do_not_remove then return 'This reusable device needs a dedicated completion check' end
  local current=a.current_stage or (a.stages and a.stages[a.current_stage_index])
  local delivery=found.component=='droppoint' or (current and current.interact_type=='carry_units')
  local b=pick(point,preferred,delivery)
  if not b then return delivery and 'No available bot is carrying an item for delivery' or 'Objective requires an available bot on foot' end
  if found.component=='objective_interact_object' and not delivery then
   local reply,assigned=old_request(s,point,b)
   if assigned then
    O.next_device_order=(O.next_device_order or 0)+1
    O.tasks[found.unit].order=O.next_device_order
   end
   return reply,assigned
  end
  if found.component=='objective_carry_object' and live(a.carrier) then return 'Carry item already has a carrier' end
  local existing=O.tasks[found.unit]
  if existing and existing.owner then
   if delivery and not existing.delivery then O.release(existing.owner,'delivery_order')
   else return 'Bot '..existing.owner.id..' is already handling this objective' end
  end
  local c=state(b.unit,'character',true) or {};local item=delivery and c.current_carry_unit
  local carried=item and state(item,'objective_carry_object',true)
  if carried and live(carried.intended_drop_off_unit) and carried.intended_drop_off_unit~=found.unit then return 'This item belongs at a different delivery point' end
  O.release(b,'reassigned');if M.vehicles then M.vehicles.release(b,'objective_order') end
  if M.cancel_guard then M.cancel_guard(b) end
  B.release(M.behaviors,b,'objective_order',M.clock,emit);S.cancel(b);b.post=nil;b.post_arrived=nil;b.returning=nil;b.controller={}
  O.next_device_order=(O.next_device_order or 0)+1;local serial=O.next_device_order
  local t={unit=found.unit,component=found.component,owner=b,session=s,generation=M.generation,
   started=M.clock,last_change=M.clock,last_motion=M.clock,order=serial,item=item,delivery=delivery,
   approach=0,approach_outer=true,retries=0}
  local d=C.direction(pos(found.unit),pos(b.unit));t.approach=math.atan2(d.y,d.x)
  if found.component=='objective_defend_object' then
   t.missile=true;t.surface_offset=true;t.approach_outer=nil
   if C.distance(point,pos(found.unit))>.3 then d=C.direction(pos(found.unit),point);t.approach=math.atan2(d.y,d.x) end
  end
  b.objective=t;O.tasks[t.unit]=t;M.order_sequence=M.order_sequence+1;b.order_sequence=M.order_sequence
  Orders.show(M.orders,b.id,point,M.clock);status(t,'travelling')
  emit('objective_ordered',{order=serial,target=tostring(t.unit),component=t.component,position=pos(t.unit),delivery=delivery},b.id)
  return 'Bot '..b.id..': '..(delivery and 'deliver carried item' or labels[t.component]),true
 end
 function O.release(b,reason,retain)
  local t=b.objective
  if not t or not t.component then
   if t then emit('objective_result',{order=t.order,result=reason or 'cancelled',component='objective_interact_object',
    position=pos(b.unit),target=pos(t.unit),retained=retain==true},b.id) end
   return old_release(b,reason,retain)
  end
  local a=state(t.unit,t.component,true)
  if O.detach then O.detach(b,t,reason)
  elseif a and a.interacting_unit==b.unit then EntityAux.queue_command_master(b.unit,'character','exit_interact_objective') end
  b.objective_input=nil;b.objective=nil;b.objective_exiting=nil;t.owner=nil;t.operating=false
  Orders.remove(M.orders,b.id);S.cancel(b)
  -- Carry ownership is native; recall/possession must not silently drop the item.
  if not retain then O.tasks[t.unit]=nil end
  status(t,retain and 'waiting_for_operator' or (reason or 'cancelled'));M.formation_dirty=true
 end
 local function selected(b,t)
  local i=state(b.unit,'interactor',true) or {};local a=state(t.unit,t.component) or {}
  local can=a.enabled~=false and (not a.can_interact or a.can_interact(b.unit,i.interactable_actor))
  local p,center=pos(b.unit),pos(t.unit)
  local close=p and center and C.distance(p,center)<=3.5 and math.abs(p.z-center.z)<1.5
  return close and i.enabled~=false and not i.busy and i.interactable_unit==t.unit and i.interactable_component==t.component and can,i
 end
 local function finished(b,t,name)
  emit('objective_result',{order=t.order,result=name,component=t.component,position=pos(b.unit)},b.id)
  O.release(b,name)
 end
 function O.route_failed(b)
  local t=b.objective;local a=t and t.missile and (state(t.unit,t.component,true) or state(t.unit,t.component))
  if a and a.activated then
   t.defense_hold=pos(b.unit);S.cancel(b)
   status(t,'defending_missile','defense_position_blocked')
   return
  end
  return old_route_failed(b)
 end
 function O.job(b,p,danger)
  local t=b.objective
  if not t or not t.component then
   local job=old_job(b,p,danger)
   if job and M.clock>=(t.next_native_trace or 0) then
    t.next_native_trace=M.clock+2
    local i=state(b.unit,'interactor',true) or {};local c=state(b.unit,'character',true) or {}
    local a=state(t.unit,'objective_interact_object',true) or {}
    local queue={};local native_queue=a.input_queue or {}
    for i=1,math.min(#native_queue,64) do queue[i]=native_queue[i] end
    local f=Quaternion.forward(Unit.world_rotation(b.unit,0))
    emit('objective_transition',{order=t.order,component='objective_interact_object',status=t.status,stage=t.stage,
     position=p,target=pos(t.unit),goal=job.position,facing={x=f.x,y=f.y,z=f.z},
     native_selected=job.native_interaction,selected=i.interactable_unit and tostring(i.interactable_unit),
     selected_id=M.navigation_trace and M.navigation_trace.id(i.interactable_unit),selected_component=i.interactable_component,
     actor_position=i.interactable_actor_position and {x=i.interactable_actor_position.x,y=i.interactable_actor_position.y,z=i.interactable_actor_position.z},
     enabled=i.enabled,busy=i.busy,character_state=c.current_state and c.current_state.name,
     acknowledged=a.interacting_unit==b.unit,progress=a.progress,pending=t.pending_interaction~=nil,
     final_character_input=t.last_character_input,interact_type=(a.current_stage or {}).interact_type,
     native_character_target=c.current_interact_objective_unit and tostring(c.current_interact_objective_unit),
     native_attaching=t.native_attaching,exiting=b.objective_exiting,native_pulses=t.native_pulses,
     native_last_direction=t.native_last_direction,input_queue=queue,input_queue_omitted=math.max(0,#native_queue-64)},b.id)
   end
   return job
  end
  local a=state(t.unit,t.component,true) or state(t.unit,t.component)
  if not a then finished(b,t,'target_unavailable');return end
  if a.mission_state=='complete' then finished(b,t,'complete');return end
  if a.mission_state=='failed' then finished(b,t,'failed');return end
  local c=state(b.unit,'character',true) or {};local h=state(b.unit,'health') or {}
  local center=pos(t.unit);local goal=center;local defending=false;local operating=false
  local reason
  if h.is_downed then reason='downed' elseif b.job then reason='helping_teammate' elseif danger then reason='avoiding_danger'
  elseif a.interacting_unit and a.interacting_unit~=b.unit then reason='terminal_in_use' end
  if t.missile and a.activated then
   if not t.launch_started then
    t.launch_started=M.clock;t.pending_interaction=nil;t.operating=false;S.cancel(b)
    emit('missile_launch_confirmed',{order=t.order,target=tostring(t.unit),defend_timer=a.defend_timer},b.id)
   end
   goal=t.defense_hold or {x=center.x+math.cos(t.approach)*4,y=center.y+math.sin(t.approach)*4,z=center.z}
   status(t,'defending_missile',t.defense_hold and 'defense_position_blocked' or nil)
  elseif t.component=='hellbomb' and a.is_armed then
   if not t.retreat then
    local blast=B.blast_radius(t.unit)
    -- Unknown blast settings are explicit; use a conservative escape distance.
    t.radius=math.max(25,(blast or 25)+5);t.retreat=true;t.pending_interaction=nil;S.cancel(b)
    emit('hellbomb_armed',{order=t.order,position=center,blast_radius=blast,escape_radius=t.radius,radius_source=blast and 'native' or 'fallback'},b.id)
   end
   if C.distance(p,center)>t.radius then finished(b,t,'armed_and_clear');return end
   goal={x=center.x+math.cos(t.approach)*t.radius,y=center.y+math.sin(t.approach)*t.radius,z=p.z};reason=nil
   status(t,'retreating')
  elseif t.delivery then
   local item=t.item;local ia=state(item,'objective_carry_object',true) or state(item,'objective_carry_object')
   if not ia then finished(b,t,'item_unavailable');return end
   if ia.mission_state=='complete' or ia.drop_off_unit==t.unit then finished(b,t,'delivered');return end
   if c.current_carry_unit~=item and ia.carrier~=b.unit and not t.drop_requested then finished(b,t,'item_dropped');return end
   goal=drop_point(t.unit,item)
   if C.distance(p,goal)<.65 and not reason then
    if not t.drop_requested then t.drop_requested=M.clock;emit('carry_drop_requested',{order=t.order,position=p,destination=goal},b.id) end
    operating=true;status(t,'delivering')
    if M.clock-t.drop_requested>8 then finished(b,t,'delivery_not_acknowledged');return end
   else status(t,'travelling') end
  elseif t.component=='objective_carry_object' and (a.carrier==b.unit or c.current_carry_unit==t.unit) then
   finished(b,t,'pickup_confirmed');return
  elseif t.component=='objective_carry_object' and live(a.carrier) then
   if (state(a.carrier,'health') or {}).is_dead then status(t,'waiting_native_carrier_cleanup')
   else finished(b,t,'item_has_another_carrier');return end
  elseif t.component=='custom_pickup' and a.enabled==false and t.pending_interaction then
   finished(b,t,'pickup_confirmed');return
  elseif t.component=='extract_beacon' and a.activated then
   finished(b,t,'extraction_activated');return
  else
   local near=selected(b,t)
   if a.interacting_unit==b.unit and not reason then operating=true;t.operating=true;t.pending_interaction=nil;status(t,'operating')
   else
    t.operating=false
    local radius=t.missile and 3 or (t.approach_outer and 2.2 or .75)
    goal={x=center.x+math.cos(t.approach)*radius,y=center.y+math.sin(t.approach)*radius,z=center.z}
    if t.approach_outer and C.distance(p,goal)<.35 then t.approach_outer=nil;S.cancel(b);b.step_check=nil end
    if near then goal=p end
    local distance=C.distance(p,goal)
    if not t.best_distance or distance<t.best_distance-.12 then t.best_distance=distance;t.last_motion=M.clock end
    if not reason and not t.pending_interaction and M.clock-t.last_motion>4 then O.next_approach(b,'approach_stalled');t.best_distance=nil;S.cancel(b) end
    if t.pending_interaction and M.clock-t.pending_interaction>3 then t.pending_interaction=nil;O.next_approach(b,'interaction_not_acknowledged');S.cancel(b) end
    status(t,reason or (near and 'requesting' or 'approaching'))
   end
  end
  defending=reason~=nil or (t.missile and a.activated)==true
  if reason then
   t.pending_interaction=nil;t.last_motion=M.clock;t.last_change=M.clock;b.objective_input=nil
   if a.interacting_unit==b.unit then
    if O.detach then O.detach(b,t,reason) else EntityAux.queue_command_master(b.unit,'character','exit_interact_objective') end
   end
   status(t,reason)
  end
  if M.clock-(t.next_trace or 0)>=0 then
   t.next_trace=M.clock+2;local near,i=selected(b,t)
   emit('objective_transition',{order=t.order,status=t.status,component=t.component,position=p,target=center,goal=goal,
    native_selected=near,selected=i.interactable_unit and tostring(i.interactable_unit),enabled=i.enabled,busy=i.busy,
    character_state=c.current_state and c.current_state.name,progress=a.progress,armed=a.is_armed,activated=a.activated,
    carrier=a.carrier and tostring(a.carrier),pending=t.pending_interaction~=nil},b.id)
  end
  if not reason and not t.package_duty and not t.retreat and not (t.missile and a.activated) and M.clock-t.started>120 then finished(b,t,'no_progress');return end
  if h.is_downed or b.job then return end
  local near,i=selected(b,t)
  return {kind='objective',unit=t.unit,component=t.component,key='device:'..tostring(t.order),position=goal,
   target_position=near and p or center,native_interaction=near,interactable_actor=i.interactable_actor,
   defending=defending,operating=operating,objective=t,approach_index=t.approach_index,
   no_interaction=t.missile and a.activated or nil,
   pending_interaction=t.pending_interaction~=nil}
 end
 function O.interact(b,job,now)
  local t=job.objective;if not t.component then return old_interact(b,job,now) end
  if job.defending or t.delivery or t.retreat or t.operating or t.pending_interaction or now<(t.next_attempt or 0) then return end
  if not selected(b,t) then return end
  if B.interact(b,job,now,emit) then t.next_attempt=now+2.5;t.pending_interaction=now;status(t,'starting_interaction') end
 end
 function O.input(b,job,p,input)
  local t=job.objective
  if not t.component then
   input=old_input(b,job,p,input)
   t.last_character_input={movement={x=input.movement.x,y=input.movement.y},aim={x=input.aim.x,y=input.aim.y},sprint=input.sprint,interact=input.interact}
   return input
  end
  if t.missile then
   local c=state(b.unit,'character',true) or {}
   if CharacterStateInteract and c.current_state==CharacterStateInteract then return C.neutral() end
   if t.launch_started then return input end
  end
  if t.retreat then input.sprint=true;return input end
  if t.delivery then
   input.sprint=false;input.switch_weapon=false
   if job.operating and not job.defending then
    input=C.neutral();input.interact=not t.drop_pulse;t.drop_pulse=true
   end
   return input
  end
  if not job.defending and (t.operating or t.pending_interaction) then return C.neutral() end
  if C.distance(p,pos(t.unit))<5 then input.aim=C.direction(p,pos(t.unit));input.sprint=false end
  return input
 end
 local function hook_beacon()
  if hooks.beacon or type(ExtractBeaconComponent)~='table' or type(ExtractBeaconComponent.update_masters)~='function' then return end
  local object=ExtractBeaconComponent;local old=object.update_masters
  local wrapper=function(self,entities,dt,...)
   local prepared={}
   for u,e in pairs(entities) do
    local a=e.state;local b=a and M.units[a.interacting_unit];local t=b and b.objective
    if b and b.active and t and t.unit==u and t.component=='extract_beacon' and t.operating then
     local virtual={interacting_unit=b.unit,current_stage={interact_type='combo',combo=a.combo},progress=a.progress}
     b.objective_input={output_table=O.native_input(b,virtual)};prepared[#prepared+1]=b
    end
   end
   local result={pcall(old,self,entities,dt,...)}
   for _,b in ipairs(prepared) do if b.objective_input then b.objective_input.output_table=C.neutral() end end
   if not result[1] then error(result[2]) end;return unpack(result,2)
  end
  object.update_masters=wrapper;hooks.beacon={object=object,old=old,wrapper=wrapper}
 end
 local function hook_boarding()
  if hooks.boarding or type(ObjectiveExtractLZComponent)~='table' or type(ObjectiveExtractLZComponent.overlap_callback_extract_players)~='function' then return end
  local object=ObjectiveExtractLZComponent;local old=object.overlap_callback_extract_players
  local wrapper=function(self,args,actors,...)
   local kept,ignored={},{}
   for _,actor in pairs(actors or {}) do
    local unit=Actor.unit(actor);local b=unit and M.units[unit]
    if b and b.active then ignored[#ignored+1]=b.id else kept[#kept+1]=actor end
   end
   if #ignored>0 and M.clock>=(M.next_extract_trace or 0) then
    M.next_extract_trace=M.clock+1
    emit('extraction_ai_overlap_ignored',{bots=ignored,reason='Companion bodies do not count as human boarding'},nil)
   end
   return old(self,args,kept,...)
  end
  object.overlap_callback_extract_players=wrapper
  hooks.boarding={object=object,old=old,wrapper=wrapper,method='overlap_callback_extract_players'}
 end
 local function hook_terminal_hud()
  if hooks.terminal_hud or type(ObjectiveInteractObjectComponent)~='table'
   or type(ObjectiveInteractObjectComponent.draw_ui)~='function' then return end
  local object=ObjectiveInteractObjectComponent;local old=object.draw_ui
  local wrapper=function(self,args,...)
   local a=args and args[2] and args[2].state;local u=a and a.interacting_unit
   local b=u and M.units[u]
   local ai=O.is_ai_operator and O.is_ai_operator(u) or (not O.is_ai_operator and b and b.active)
   if not ai then return old(self,args,...) end
   -- Native button-mash UI assumes every locally owned operator has a physical
   -- pad. Companions use the existing observer UI path only during this draw.
   local owned=EntityAux.owned
   EntityAux.owned=function(unit,...)
    if unit==u then return false end
    return owned(unit,...)
   end
   local result={pcall(old,self,args,...)}
   EntityAux.owned=owned
   if not result[1] then
    emit('objective_hud_draw_error',{message=tostring(result[2])},b and b.id,'errors')
    error(result[2])
   end
   local t=b and b.objective
   if t and not t.hud_reported then
    t.hud_reported=true
    emit('objective_hud_ai_view',{order=t.order,component='objective_interact_object',view='observer',
     target=tostring(args[1]),reason='autonomous_operator_has_no_physical_pad'},b.id)
   end
   return unpack(result,2)
  end
  object.draw_ui=wrapper;hooks.terminal_hud={object=object,old=old,wrapper=wrapper,method='draw_ui'}
 end
 function O.install()old_install();hook_beacon();hook_boarding();hook_terminal_hud()end
 function O.uninstall()
  old_uninstall()
  for _,h in pairs(hooks) do local method=h.method or 'update_masters';if h.object[method]==h.wrapper then h.object[method]=h.old end end
  for key in pairs(hooks) do hooks[key]=nil end
 end
 O.install();return O
end
