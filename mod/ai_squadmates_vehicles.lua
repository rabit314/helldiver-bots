-- Native seats/input only. No ammunition, damage, speed or collision overrides.
return function(M,C,B,S,Orders,emit)
 if M.vehicles then
  -- F6 stages the controller again and constructs a new support adapter.
  -- Reconnect its mounted entry point to the persistent vehicle controller.
  S.mounted=M.vehicles.mounted
  M.vehicles.install()
  local policy=(rawget(_G,'HelldiversSquadAIStage') or {}).SeatPolicy
  if policy then policy(M,C,B,S,M.vehicles,emit) end
  return M.vehicles
 end
 local V={tracked={},claims={},seat_keys={},next_seat_key=0};M.vehicles=V
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
 local function root(u)
  local a=state(u,'stationary_weapon',true)
  return a and live(a.attached_to_unit) and a.attached_to_unit or u
 end
 local function exo(u)
  local a=state(u,'vehicle',true)
  return a and (a.vehicle_info or {}).vehicle_type=='exosuit'
 end
 function V.mobile(u)
  local a=state(u,'vehicle',true) or state(u,'vehicle') or {}
  local kind=(a.vehicle_info or {}).vehicle_type
  return kind=='exosuit' or kind=='apc' or kind=='bike'
 end
 V.root=root;V.position=pos
 function V.seat_key(u,index)
  -- Map actual unit/seat identity to a string accepted by the approach router.
  local seats=V.seat_keys[u]
  if not seats then seats={};V.seat_keys[u]=seats end
  if not seats[index] then
   V.next_seat_key=V.next_seat_key+1;seats[index]='seat:'..V.next_seat_key
  end
  return seats[index]
 end
 function V.adopt(b,previous)
  local c=state(b.unit,'character',true) or {};local u=c.current_seat_unit
  local a=state(u,'seat',true) or state(u,'seat');local index=c.current_seat_index
  if not a or not index or (a.seated_units or {})[index]~=b.unit then return false end
  local vehicle=root(u);local settings=SeatComponent.get_seat_settings(u,index)
  if not live(vehicle) or not settings then return false end
  local key=V.seat_key(u,index)
  if V.claims[key] and V.claims[key]~=b then return false end
  local t=previous and previous.unit==u and previous.index==index and previous or
   {kind='seat',component='seat',unit=u,vehicle=vehicle,index=index,key=key,
    pilot=u==vehicle and V.mobile(vehicle) and index==1,started=M.clock}
  t.boarded=true;b.vehicle_order=t;V.claims[key]=b
  t.turret=(state(vehicle,'vehicle',true) or {}).vehicle_info and state(vehicle,'vehicle',true).vehicle_info.vehicle_type=='mannable_turret'
  t.source=t.source or 'takeover';b.seat_departure=nil
  b.vehicle_input={output_table=C.neutral()}
  emit('vehicle_control_resumed',{seat=tostring(u),index=index,pilot=t.pilot},b.id)
  return true
 end
 local function radius(u)
  local a=state(u,'vehicle',true) or {};local k=(a.vehicle_info or {}).vehicle_type
  return k=='exosuit' and 2.8 or (k=='bike' and 2.2 or 3.8)
 end
 function V.owns(query,u)
  for _,w in ipairs(query.weapons or {}) do if w.unit==u then return true end end
  return false
 end
 function V.range(m)
  local range=14
  for _,w in ipairs(m.weapons or {}) do range=math.max(range,w.profile.range) end
  return range
 end
 local function weapons(u,index,b)
  local list,seen={},{}
  local function add(g)
   if not live(g) or seen[g] or not EntityAux.has_interface(g,'weapon') then return end
   local a=state(g,'stationary_weapon',true)
   if a and a.controller_unit~=b.unit then return end
   seen[g]=true
   local ammo,profile=B.weapon(g)
   list[#list+1]={unit=g,ammo=ammo,profile=profile,info=a and a.stationary_info or {},memory={}}
  end
  if index==1 then add(u) end
  local seat=state(u,'seat',true) or state(u,'seat') or {}
  for i,g in ipairs(seat.seat_weapon_units or {}) do
   if (seat.weapon_index_to_seat or {})[i]==index then add(g) end
  end
  local c=state(b.unit,'character',true) or {}
  for _,g in ipairs(c.current_stationary_weapon_units or {}) do add(g) end
  return list
 end
 function V.exit(b,seat,reason)
  if M.clock>=(b.next_exit or 0) then
   EntityAux.queue_command_master(seat,'seat','exit_seat',{unit=b.unit,force=false})
   b.next_exit=M.clock+1;emit('vehicle_exit_requested',{reason=reason,seat=tostring(seat)},b.id)
  end
 end
 function V.release(b,reason,exit)
  if b.vehicle_input then b.vehicle_input.output_table=C.neutral() end
  V.exosuit.clear(b)
  V.cancel_move(b)
  local t=b.vehicle_order
  if t then
   if V.claims[t.key]==b then V.claims[t.key]=nil end
   b.vehicle_order=nil;Orders.remove(M.orders,b.id)
   emit('vehicle_order_finished',{reason=reason,vehicle=tostring(t.vehicle)},b.id)
  end
  if exit then
   local c=state(b.unit,'character',true) or {}
   if live(c.current_seat_unit) then V.exit(b,c.current_seat_unit,reason) end
  end
  for u in pairs(b.vehicle_permissions or {}) do
   if M.weapon_owners[u]==b then M.weapon_owners[u]=nil end
  end
  if b.vehicle_rays and M.retain_rays then M.retain_rays(b.vehicle_rays) end
  b.vehicle_rays=nil;b.vehicle_sights=nil
  b.vehicle_permissions=nil;b.vehicle_triggers=nil;b.vehicle_step=nil;b.vehicle_progress=nil;b.vehicle_stuck=nil;b.vehicle_following=nil
  b.vehicle_push=nil;b.vehicle_contacts=nil
  b.vehicle_block=nil;b.vehicle_navigation=nil;b.vehicle_search_level=nil;b.vehicle_visited=nil
 end
 function V.reset()
  V.exosuit.reset()
  for _,b in ipairs(M.bots) do V.release(b,'cleanup',true) end
  V.restore_views()
  V.tracked={};V.claims={};V.seat_keys={};M.behaviors.vehicles={}
 end
 function V.scan(s,dt)
  V.install()
  if s.entity_manager.get_slave_entities then
   for u,e in pairs(B.entities(s,'seat',nil,'slave')) do V.prepare_view(u,e) end
  end
  local seen={};local hazards={}
  for u,e in pairs(B.entities(s,'vehicle')) do
   local a=e.state or state(u,'vehicle',true)
   local h=state(u,'health') or {}
   if live(u) and a and not h.is_dead and (a.vehicle_info or {}).vehicle_type~='mannable_turret' then
    local p=pos(u);local old=V.tracked[u];local vel=(a.mover_state or {}).velocity
    local vx,vy=0,0
    if vel then vx,vy=tonumber(vel.x) or 0,tonumber(vel.y) or 0
    elseif old and dt>0 then vx,vy=(p.x-old.position.x)/dt,(p.y-old.position.y)/dt end
    local speed=math.sqrt(vx*vx+vy*vy)
    if speed>25 then vx,vy,speed=0,0,0 end
    local q={unit=u,position=p,velocity={x=vx,y=vy},speed=speed,radius=radius(u),height=3,
      future={x=p.x+vx*.8,y=p.y+vy*.8,z=p.z}}
    V.tracked[u]=q;seen[u]=true;hazards[#hazards+1]=q
   end
  end
  for u in pairs(V.tracked) do if not seen[u] then V.tracked[u]=nil end end
  M.behaviors.vehicles=hazards
  V.exosuit.tick()
  -- Expired bot references cannot reserve seats in another mission/body.
  for k,b in pairs(V.claims) do
   if not b.active or not b.vehicle_order or b.vehicle_order.key~=k then V.claims[k]=nil end
  end
  for u in pairs(V.seat_keys) do if not live(u) then V.seat_keys[u]=nil end end
 end
 function V.closest(h,p)
  local a,z=h.position,h.future;local dx,dy=z.x-a.x,z.y-a.y
  local t=math.max(0,math.min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/math.max(.0001,dx*dx+dy*dy)))
  return {x=a.x+dx*t,y=a.y+dy*t,z=a.z}
 end
 function V.exempt(b,h)
  local c=state(b.unit,'character',true) or {}
  if live(c.current_seat_unit) and root(c.current_seat_unit)==h.unit then return true end
  local t=b.vehicle_order or b.job
  return h.speed<.3 and t and t.kind=='seat' and (t.vehicle or root(t.unit))==h.unit
 end
 function V.goal(b,p,goal)
  for _,h in ipairs(M.behaviors.vehicles or {}) do
   if not V.exempt(b,h) and math.abs((goal.z or 0)-h.position.z)<3 then
    local center=V.closest(h,goal);local d=C.distance(goal,center)
    local gap=h.radius+1.2+math.min(2,h.speed*.35)
    if d<gap then
     local direction=C.direction(center,p)
     if C.distance(center,p)<.01 then direction={x=b.id%2==0 and 1 or -1,y=0} end
     goal={x=center.x+direction.x*gap,y=center.y+direction.y*gap,z=goal.z}
    end
   end
  end
  return goal
 end
 function V.find(s,point,b,options)
  options=options or {}
  local found,score,near
  for u,e in pairs(B.entities(s,'seat')) do
   local a=state(u,'seat',true) or state(u,'seat') or e.state
   local vehicle=root(u);local h=state(vehicle,'health') or {}
   local v=state(vehicle,'vehicle',true)
   local turret=v and (v.vehicle_info or {}).vehicle_type=='mannable_turret'
   if live(u) and live(vehicle) and a and a.enabled and v and not h.is_dead and (not options.unit or vehicle==options.unit) and (not options.seat or u==options.seat) then
    local center=pos(vehicle);local d=C.distance(point,center)
    if d<=5.5 and math.abs((point.z or 0)-center.z)<3 then
     near=true
     for actor,index in pairs(a.actor_to_seat or {}) do
      -- Reserve driving seats; an emplacement's first seat operates its gun.
      local pilot=u==vehicle and V.mobile(vehicle) and index==1
      local gunner=u~=vehicle or index~=1 or turret
      local settings=SeatComponent.get_seat_settings(u,index)
      local key=V.seat_key(u,index)
      local locked=(a.seat_locked or {})[index]
      local occupied=(a.seated_units or {})[index]
      local has_gun=settings and (settings.weapon_path or next(settings.seat_weapons or {})
       or (turret and index==1 and EntityAux.has_interface(u,'weapon')))
      if not has_gun then
       local ms=state(u,'seat',true) or a
       for wi,si in pairs(ms.weapon_index_to_seat or {}) do
        if si==index and live((ms.seat_weapon_units or {})[wi]) then has_gun=true end
       end
      end
      if pilot and options.automatic and (not M.mobility or not M.mobility.bot_delivery(vehicle)) then pilot=false end
      if (pilot or (gunner and has_gun)) and (not options.index or index==options.index) and not locked and not occupied and not V.exosuit.unavailable(vehicle)
        and (not V.claims[key] or V.claims[key]==b) and settings and settings.enter_node then
       local p=pos(u,Unit.node(u,settings.enter_node));local weight=d+(pilot and 0 or .1)
       if not score or weight<score or (weight==score and index<found.index) then
        found={kind='seat',component='seat',unit=u,vehicle=vehicle,index=index,actor=actor,
         position=p,target_position=p,priority=1,key=key,pilot=pilot,turret=turret};score=weight
       end
      end
     end
    end
   end
  end
  return found,near
 end
 function V.request(s,point,b,options)
  if options and options.source=='automatic' then options.automatic=true end
  local t,near=V.find(s,point,b,options)
  if not t then return near and 'No free gunner/pilot seat, or target is occupied/unsafe' or nil end
  local c=state(b.unit,'character',true) or {}
  if c.current_seat_unit then return 'Bot '..b.id..' must leave its current vehicle first' end
  if not (options and options.automatic) then b.bike_exit_lock=nil;b.seat_reboard=nil end
  M.objectives.release(b,'vehicle_order');M.cancel_guard(b)
  B.release(M.behaviors,b,'vehicle_order',M.clock,emit);S.cancel(b);V.release(b,'reassigned')
  b.post=nil;b.post_arrived=nil;b.returning=nil;b.controller={};b.interaction_check=nil
  M.order_sequence=M.order_sequence+1;b.order_sequence=M.order_sequence
  b.vehicle_order=t;t.started=M.clock;t.last_progress=M.clock;t.last_distance=math.huge
  t.source=options and options.source or 'f8'
  V.claims[t.key]=b;M.formation_dirty=true;Orders.show(M.orders,b.id,t.position,M.clock)
  emit('vehicle_ordered',{vehicle=tostring(t.vehicle),seat=tostring(t.unit),index=t.index,pilot=t.pilot,turret=t.turret},b.id)
  return 'Bot '..b.id..': '..(t.turret and 'operate turret' or (t.pilot and (exo(t.vehicle) and 'pilot exosuit and follow' or 'drive vehicle and follow') or 'board gunner seat')),true
 end
 function V.job(b,leader,lp,budget)
  local t=b.vehicle_order;if not t then return end
  if V.exosuit.emergency(b,t) then return end
  local pending=b.vehicle_move_request
  if pending and M.clock>pending.expires then V.cancel_move(b);emit('vehicle_move_rejected',{reason='ground_timeout'},b.id) end
  local c=state(b.unit,'character',true) or {};local h=state(b.unit,'health') or {}
  local a=state(t.unit,'seat',true) or state(t.unit,'seat');local vh=state(t.vehicle,'health') or {}
  if not a or not live(t.vehicle) or vh.is_dead or h.is_dead then V.release(b,'target_unavailable',true);return end
  if c.current_seat_unit==t.unit and c.current_seat_index==t.index then
   if not t.boarded then t.boarded=true;Orders.remove(M.orders,b.id);emit('vehicle_boarded',{index=t.index,pilot=t.pilot},b.id) end
   return
  end
  local occupant=(a.seated_units or {})[t.index]
  if occupant==b.unit then
   t.entering_since=t.entering_since or M.clock
   if M.clock-t.entering_since>4 then V.release(b,'entry_not_acknowledged',true) end
   return
  end
  if t.boarded or occupant or (a.seat_locked or {})[t.index] then V.release(b,'seat_unavailable');return end
  if h.is_downed then return end
  if V.policy and not V.policy.preboard(b,t,budget) then return end
  local settings=SeatComponent.get_seat_settings(t.unit,t.index)
  if not settings or not settings.enter_node then V.release(b,'seat_unavailable');return end
  local p=pos(t.unit,Unit.node(t.unit,settings.enter_node));t.position=p;t.target_position=p
  local d=C.distance(pos(b.unit),p)
  if d<t.last_distance-.3 then t.last_distance=d;t.last_progress=M.clock end
  if M.clock-t.last_progress>30 then V.release(b,'boarding_blocked');return end
  local v=V.tracked[t.vehicle]
  local slave=state(t.unit,'seat') or {}
  local permitted=not slave.can_interact or slave.can_interact(b.unit,Unit.actor(t.unit,t.actor))
  t.defending=(v and v.speed>=.3) or not a.enabled or not permitted
  return t
 end
 local old_mounted=S.mounted
 function V.mounted(b,leader)
  local c=state(b.unit,'character',true) or {};local seat=c.current_seat_unit
  local t=b.vehicle_order
  if not live(seat) then b.vehicle_input=nil;return end
  if b.seat_exit then
   return {seat=seat,vehicle=root(seat),info={},keep=false,pilot=false,weapons={}}
  end
  if not t then return old_mounted(b,leader) end
  local keep=t.boarded and seat==t.unit and c.current_seat_index==t.index and not b.post and not b.guard_request and not b.seat_exit
  local vehicle=root(seat);local list=weapons(seat,c.current_seat_index or t.index,b)
  b.vehicle_input=b.vehicle_input or {output_table=C.neutral()}
  local gun=list[1]
  return {seat=seat,vehicle=vehicle,gun=gun and gun.unit,info=gun and gun.info or {},
    keep=keep,pilot=t.pilot,clearance=t.pilot and (M.mobility and M.mobility.profile(vehicle).width or 1.45) or nil,weapons=list,order=t}
 end
 S.mounted=V.mounted
 function V.is_pilot(b)
  local t=b.vehicle_order;local c=state(b.unit,'character',true) or {}
  return t and t.pilot and t.boarded and live(t.vehicle) and V.mobile(t.vehicle)
   and c.current_seat_unit==t.unit and c.current_seat_index==t.index
 end
 function V.cancel_move(b)
  local r=b.vehicle_move_request;b.vehicle_move_request=nil
  local queue=r and r.session.spawn_manager.queued_spawns or {}
  for i=#queue,1,-1 do if queue[i].callback_object==r.callback then table.remove(queue,i) end end
 end
 function V.regroup(b)
  if not V.is_pilot(b) then return false end
  V.cancel_move(b);b.vehicle_order.destination=nil;b.vehicle_order.arrived=nil;b.vehicle_order.auto_park=true;b.vehicle_order.human_aboard=M.mobility and M.mobility.human_aboard(b.vehicle_order.vehicle) or nil
  b.vehicle_step=nil;b.vehicle_progress=nil;b.vehicle_stuck=0;b.vehicle_following=nil
  b.vehicle_push=nil;b.vehicle_contacts=nil
  b.vehicle_block=nil;b.vehicle_navigation=nil;b.vehicle_search_level=nil;b.vehicle_visited=nil
  S.cancel(b);Orders.remove(M.orders,b.id)
  emit('vehicle_follow_ordered',{},b.id);return true
 end
 function V.redirect(s,point,b)
  if not V.is_pilot(b) then return end
  V.cancel_move(b)
  local t=b.vehicle_order
  local r={session=s,generation=M.generation,expires=M.clock+8,callback={squad_owner=M}}
  b.vehicle_move_request=r
  local function fail(reason)
   if b.vehicle_move_request~=r then return end
   b.vehicle_move_request=nil;emit('vehicle_move_rejected',{reason=reason},b.id)
  end
  r.callback.on_entity_spawned=function(_,unit,_,ground)
   if unit then
    if live(unit) then s.entity_spawner:despawn_entity(unit) end
    fail('ground_preview_returned_unit');return
   end
   if b.vehicle_move_request~=r or not M.enabled or not b.active or M.generation~=r.generation
     or M.session~=s or b.vehicle_order~=t or not V.is_pilot(b) then return end
   local h=state(b.unit,'health') or {}
   if h.is_dead or h.is_downed then fail('pilot_unavailable');return end
   b.vehicle_move_request=nil
   t.destination={x=ground.x,y=ground.y,z=ground.z};t.arrived=nil;t.auto_park=nil;t.route_source='f8'
   b.vehicle_step=nil;b.vehicle_progress=nil;b.vehicle_stuck=0;b.vehicle_following=nil
   b.vehicle_push=nil;b.vehicle_contacts=nil
   b.vehicle_block=nil;b.vehicle_navigation=nil;b.vehicle_search_level=nil;b.vehicle_visited=nil
   S.cancel(b);Orders.show(M.orders,b.id,t.destination,M.clock)
   emit('vehicle_move_ordered',{position=t.destination},b.id)
  end
  r.callback.on_entity_spawn_failed=function()fail('no_walkable_ground')end
  r.callback.on_entity_spawn_inside_screen_failed=r.callback.on_entity_spawn_failed
  local ok,err=pcall(s.spawn_manager.queue_spawn,s.spawn_manager,
   'characters/helldiver_private_01/helldiver_private_01',Vector3(point.x,point.y,point.z),nil,
   r.callback,r,nil,true,nil,nil,true,1,true)
  if not ok then fail(tostring(err));return 'Vehicle ground check failed',false end
  M.order_sequence=M.order_sequence+1;b.order_sequence=M.order_sequence
  return 'Bot '..b.id..': checking '..(exo(t.vehicle) and 'exosuit' or 'vehicle')..' destination',true
 end
 local function human()
  local sm=Boot and Boot.state_machine;local s=M.session
  if not M.enabled or not s or not sm or sm.state~=s or sm.current_state_name~='game' or s.wants_exit then return end
  for _,p in ipairs(s.players or {}) do
   local go=p.player_go
   if go and go:exists() and go:owned() and go:has('avatar_unit') then return go:get('avatar_unit') end
  end
 end
 function V.yielding_pilot(u,a,index,player)
  if index~=1 or not live(u) or not V.mobile(u) or not a.enabled
    or (a.seat_locked or {})[index] or not live(player) or player~=human() then return end
  local pc=state(player,'character',true) or {};local ph=state(player,'health') or {};local vh=state(u,'health') or {}
  if live(pc.current_seat_unit) or ph.is_dead or ph.is_downed or vh.is_dead then return end
  local p,q=pos(player),pos(u)
  if C.distance(p,q)>4.5 or math.abs(p.z-q.z)>2 then return end
  local b=M.units[(a.seated_units or {})[index]]
  local h=b and state(b.unit,'health') or {}
  if b and b.active and not h.is_dead and V.is_pilot(b) and b.vehicle_order.unit==u then return b end
 end
 V.views={};V.hooks={}
 function V.prepare_view(u,e)
  local a=e and e.state
  if not a or not live(u) or not V.mobile(u) or type(a.can_interact)~='function' then return end
  local known=V.views[a]
  if known and a.can_interact==known.wrapper then return end
  local old=a.can_interact
  local wrapper=function(player,actor)
   if not live(u) then return false end
   if old(player,actor) then return true end
   for id,index in pairs(a.actor_to_seat or {}) do
    if Unit.actor(u,id)==actor and V.yielding_pilot(u,a,index,player) then
     local settings=SeatComponent.get_seat_settings(u,index)
     return settings and (not settings.can_interact or settings.can_interact(u,e,player)) or false
    end
   end
   return false
  end
  V.views[a]={original=old,wrapper=wrapper};a.can_interact=wrapper
 end
 function V.restore_views()
  for a,h in pairs(V.views) do if a.can_interact==h.wrapper then a.can_interact=h.original end end
  V.views={}
 end
 function V.install()
  if type(SeatComponent)~='table' then return end
  local object=SeatComponent
  local function hook(name,factory)
   if V.hooks[name] or type(object[name])~='function' then return end
   local old=object[name];local wrapper=factory(old)
   V.hooks[name]={object=object,original=old,wrapper=wrapper};object[name]=wrapper
  end
  hook('reload_slave',function(old)return function(self,u,e,...)
   old(self,u,e,...);V.prepare_view(u,e)
  end end)
  hook('command_master',function(old)return function(self,u,e,name,data,...)
   local a=e.state
   local index=name=='interact' and data and (a.actor_to_seat or {})[data.actor]
   local b=index and V.yielding_pilot(u,a,index,data.interactor)
   local slave=b and state(u,'seat')
   if b and slave and slave.can_interact and slave.can_interact(data.interactor,Unit.actor(u,data.actor)) then
    if b.vehicle_input then b.vehicle_input.output_table=C.neutral() end
    V.release(b,'human_requested_seat',true)
    -- Decline this entry handshake; the next E press uses ordinary boarding.
    self:trigger_rpc_event_to(EntityAux.owner(data.interactor),'rpc_on_interact_acknowledge',u,data.interactor,false)
    return
   end
   local leaving=name=='exit_seat' and data and data.unit
   local was_human=leaving and leaving==human()
   local result=old(self,u,e,name,data,...)
   local c=leaving and state(leaving,'character',true)
   if was_human and c and not c.current_seat_unit and V.policy and V.policy.human_exited then
    V.policy.human_exited(root(u),leaving)
   end
   return result
  end end)
  hook('draw_ui',function(old)return function(self,params,...)
   local u,e=unpack(params);local a=e and e.state
   if a and V.yielding_pilot(u,a,1,human()) then
    -- Give only the HUD an empty-seat view; native occupancy stays intact.
    local view={};for k,v in pairs(a) do view[k]=v end
    view.seated_units={};for k,v in pairs(a.seated_units) do if k~=1 then view.seated_units[k]=v end end
    local ctx={};for k,v in pairs(e) do ctx[k]=v end;ctx.state=view
    return old(self,{u,ctx},...)
   end
   return old(self,params,...)
  end end)
 end
 function V.uninstall()
  V.restore_views()
  for name,h in pairs(V.hooks) do if h.object[name]==h.wrapper then h.object[name]=h.original end end
  V.hooks={}
 end
 local function available(w)
  local a=w.ammo
  if a.heat~=nil then return true end
  if type(a.rounds)=='number' then return a.rounds>0 or (tonumber(a.num_mags) or 0)>0 or a.is_reloading end
  return true -- Unknown capacity is not proof of an empty weapon.
 end
 function V.heavy(target)
  local h=target and (state(target.id,'health',true) or state(target.id,'health')) or {};local enemy=target and state(target.id,'enemy',true) or {}
  local info=enemy.enemy_info or {}
  return (tonumber(h.max_hitpoints or h.max_hitpoints_real) or 0)>=450
   or info.is_tank==true or info.is_heavy==true
 end
 function V.sight(b,m,w,target,budget)
  b.vehicle_sights=b.vehicle_sights or {};b.vehicle_rays=b.vehicle_rays or {pending={}}
  local c=b.vehicle_sights[w.unit]
  if c and c.query and M.clock-(c.query.started or M.clock)>.75 then
   if M.retain_rays then M.retain_rays(b.vehicle_rays) end
   b.vehicle_sights={};b.vehicle_rays={pending={}};c=nil
   emit('vehicle_sight_timeout',{weapon=tostring(w.unit)},b.id,'behavior')
  end
  if not c then
   c={};b.vehicle_sights[w.unit]=c
   local rays=b.vehicle_rays;local generation=M.generation;local g=w.unit
   c.ray=PhysicsWorld.make_raycast(World.physics_world(M.session.world_proxy:get_world()),S.guard(b,'vehicle_sight',function(hits)
    rays.pending[g]=nil
    local q=c.query;c.query=nil
    if not q or not b.active or not live(b.unit) or not live(g) or generation~=M.generation or not b.vehicle_sights or b.vehicle_sights[g]~=c then return end
    local nearest,distance=nil,math.huge
    assert(type(hits)=='table','Invalid vehicle sight reply')
    for _,hit in ipairs(hits) do
     local _,d,_,actor=unpack(hit)
     assert(type(d)=='number' and d==d and d>=0 and d<math.huge,'Invalid vehicle sight distance')
     local u=actor and Actor.unit(actor)
     if u and not q.ignore[u] and d<distance then nearest,distance=u,d end
    end
    c.result={target=q.target,from=q.from,to=q.to,time=M.clock,clear=nearest==q.target}
   end,function()rays.pending[g]=nil;c.query=nil;c.result=nil end),'all','collision_filter','damage_ray')
   rays[g]=c.ray
  end
  local p=pos(w.unit);local t=target.position;local result=c.result
  local valid=result and result.target==target.id and M.clock-result.time<.3
    and C.distance(p,result.from)<.4 and C.distance(t,result.to)<.7
  if not c.query and (budget.rays or 0)>0 and M.clock>=(c.next_cast or 0) then
   local ignore={[b.unit]=true,[m.seat]=true,[m.vehicle]=true}
   for _,weapon in ipairs(m.weapons) do ignore[weapon.unit]=true end
   c.query={target=target.id,from=p,to={x=t.x,y=t.y,z=t.z},ignore=ignore,started=M.clock}
   c.next_cast=M.clock+.15;budget.rays=budget.rays-1;b.vehicle_rays.pending[w.unit]=true
   local from=Vector3(p.x,p.y,p.z+.5);local delta=Vector3(t.x,t.y,t.z+.8)-from
   local length=Vector3.length(delta)
   if length>.1 then c.ray:cast(from,Vector3.normalize(delta),length+1)
   else c.query=nil;b.vehicle_rays.pending[w.unit]=nil end
  end
  return valid and result.clear
 end
 function V.fire(b,m,target,visible,dt,friends,budget)
  local output=C.neutral();local p=pos(m.vehicle);local any=false;local count=0
  b.vehicle_status={vehicle=tostring(m.vehicle),pilot=m.pilot,weapons={},visible=not not visible}
  local heavy=V.heavy(target)
  if target then
   for _,e in ipairs(M.enemy_cache or {}) do
    if e.alive and e.position and C.distance(e.position,target.position)<3.5 then count=count+1 end
   end
  end
  local utility=false
  for _,w in ipairs(m.weapons) do if w.profile.splash<=0 and available(w) then utility=true end end
  local field_used={};local aim_rank
  for _,w in ipairs(m.weapons) do
   local a,profile=w.ammo,w.profile;local g=pos(w.unit);any=any or available(w)
   local field=w.unit==m.vehicle and 'fire' or (w.info.fire_input_field or 'fire_auto')
   local safe=false
   if target and visible and available(w) and (profile.splash<=0 or heavy or count>=3 or not utility) then
    local aim=C.direction(g,target.position);local rank=(profile.splash>0 and 10 or 0)+(w.unit==m.vehicle and 0 or 1)
    if not aim_rank or rank<aim_rank then output.aim=aim;aim_rank=rank end
    local f=Quaternion.forward(Unit.world_rotation(w.unit,Unit.node(w.unit,w.info.rotation_node or 'root')))
    local facing=C.direction({x=0,y=0},f);local d=C.distance(g,target.position)
    safe=not a.is_reloading and d<=profile.range and d>profile.splash+1 and aim.x*facing.x+aim.y*facing.y>.9945
     and C.corridor_clear(g,target.position,friends,1.2)
     and C.corridor_clear(g,{x=g.x+facing.x*d,y=g.y+facing.y*d},friends,1.2)
    if profile.splash>0 then for _,f in ipairs(friends) do
     if C.distance(f,target.position)<profile.splash+1.5 then safe=false end
    end end
    if m.pilot and profile.splash>0 and C.distance(p,target.position)<profile.splash+2.8 then safe=false end
    if budget and not V.sight(b,m,w,target,budget) then safe=false end
   end
   b.vehicle_triggers=b.vehicle_triggers or {};local memory=b.vehicle_triggers[w.unit] or {};b.vehicle_triggers[w.unit]=memory
   b.vehicle_permissions=b.vehicle_permissions or {};b.vehicle_permissions[w.unit]=safe
   M.weapon_owners[w.unit]=b
   local _,auto=B.trigger(a,profile,memory,dt,safe)
   -- Two weapons sharing one native trigger cannot be selected independently:
   -- every weapon on that trigger must be safe for it to be pressed.
   local trigger=auto
   if field_used[field] then output[field]=output[field] and trigger else output[field]=trigger;field_used[field]=true end
   b.vehicle_status.weapons[#b.vehicle_status.weapons+1]={field=field,rounds=a.rounds,magazines=a.num_mags,
     heat=a.heat,splash=profile.splash,permitted=safe,trigger=trigger}
   if safe and a.reloadable and (a.rounds or 1)<=0 and (a.num_mags or 0)>0 then output.reload=true end
  end
  local inventory=state(m.vehicle,'exosuit_inventory',true) or {}
  local vehicle=state(m.vehicle,'vehicle',true) or {};local info=vehicle.vehicle_info or {}
  if m.pilot and info.has_grenade_launcher then
   local n=tonumber(inventory.num_grenades)
   if n and n>0 then
    any=true
    local shared=not field_used.throw or output.throw
    output.throw=false
    if target and visible and (heavy or count>=3) and C.distance(p,target.position)>8
      and C.corridor_clear(p,target.position,friends,1.5) then
     local safe=true;for _,f in ipairs(friends) do if C.distance(f,target.position)<7 then safe=false end end
     local forward=Quaternion.forward(Unit.world_rotation(m.vehicle,0));local aim=C.direction(p,target.position)
     if not aim_rank then output.aim=aim end
     if budget and not V.sight(b,m,{unit=m.vehicle},target,budget) then safe=false end
     if safe and aim.x*forward.x+aim.y*forward.y>.9945 and shared then output.throw=true end
    end
   end
  end
  if #m.weapons==0 then any=true end
  if not any then
   V.release(b,'ammunition_exhausted',true);return C.neutral()
  end
  return output
 end
 function V.pedestrian_clear(p,endpoint,friends)
  local toward=C.direction(p,endpoint);local length=C.distance(p,endpoint)
  for _,f in ipairs(friends) do
   if math.abs((f.z or 0)-p.z)<3 then
    local t=math.max(0,math.min(length,(f.x-p.x)*toward.x+(f.y-p.y)*toward.y))
    local nearest={x=p.x+toward.x*t,y=p.y+toward.y*t,z=p.z}
    if C.distance(nearest,f)<3.4 then return false end
   end
  end
  return true
 end
 function V.apply(b,m,input,leader,lp,dt,budget)
  for _,other in ipairs(M.bots) do
   if other.active and other.mounted and other.mounted.vehicle==m.vehicle
    and (other.rejoin_commit or other.relocated_at==M.clock) then
    b.release_permitted=false;b.vehicle_permissions={};return C.neutral()
   end
  end
  if M.mobility and m.pilot then M.mobility.destination(b,m,leader) end
  if V.exosuit.evacuating(b,m.vehicle) or V.exosuit.emergency(b,m.order) then return C.neutral() end
  if not m.order then return input end
  local friends={lp}
  for _,other in ipairs(M.bots) do if other~=b and live(other.unit) then
   local c=state(other.unit,'character',true) or {}
   if not live(c.current_seat_unit) or root(c.current_seat_unit)~=m.vehicle then
    local seated=live(c.current_seat_unit) and root(c.current_seat_unit)
    local h=seated and V.tracked[seated]
    local p=pos(seated or other.unit);friends[#friends+1]=p
    local velocity=seated and h and h.velocity or (not seated and other.velocity)
    if velocity then friends[#friends+1]={x=p.x+velocity.x*.8,y=p.y+velocity.y*.8,z=p.z} end
   end
  end end
  local lc=state(leader,'character',true) or {}
  b.vehicle_leader_vehicle=live(lc.current_seat_unit) and root(lc.current_seat_unit) or nil
  if b.vehicle_leader_vehicle then lp=pos(b.vehicle_leader_vehicle);friends[1]=lp end
  if live(lc.current_seat_unit) and root(lc.current_seat_unit)==m.vehicle then friends={}
   for _,other in ipairs(M.bots) do if other~=b and live(other.unit) and (not M.mobility or M.mobility.root(other.unit)~=m.vehicle) then friends[#friends+1]=pos(other.unit) end end
  elseif M.leader_motion then
   local h=b.vehicle_leader_vehicle and V.tracked[b.vehicle_leader_vehicle]
   local v=h and h.velocity or M.leader_motion.velocity;friends[#friends+1]={x=lp.x+v.x*.8,y=lp.y+v.y*.8,z=lp.z}
  end
  for _,e in ipairs(M.behaviors.escorts or {}) do friends[#friends+1]=e.position end
  if not m.keep then return C.neutral() end
  local sight=b.visibility;local target=b.target
  local visible=target and sight and sight.clear and sight.target==target.id and M.clock-sight.time<.25
    and C.distance(pos(m.gun or m.vehicle),sight.from)<.6 and C.distance(target.position,sight.to)<.9
  input=V.fire(b,m,target,visible,dt,friends,budget)
  if m.pilot and b.vehicle_order then
   input.movement=V.drive(b,m,lp,dt,budget,friends)
   if b.relocated_at==M.clock or b.rejoin_probe or b.rejoin_commit then input=C.neutral() end
   if M.mobility then
    if not M.mobility.braking(b,m,input.movement,friends) then
     input.movement={x=0,y=0,z=0};b.vehicle_status.drive.reason='predictive_braking'
    end
    input=M.mobility.adapt(b,m,input)
   end
  end
  if C.distance({x=0,y=0},input.aim)<.1 then input.aim=input.movement end
  return input
 end
 local factory=assert(rawget(_G,'HelldiversSquadAIStage').Exosuit,'Missing exosuit decisions')
 V.exosuit=factory(M,C,S,V,emit)
 V.drive=assert(rawget(_G,'HelldiversSquadAIStage').ExoNavigation)(M,C,S,V,emit,radius,pos)
 local policy=(rawget(_G,'HelldiversSquadAIStage') or {}).SeatPolicy
 if policy then policy(M,C,B,S,V,emit) end
 V.install();return V
end
