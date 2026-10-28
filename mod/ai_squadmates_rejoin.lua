-- Persistent follow recovery. Engine geometry is checked asynchronously; no body is respawned.
return function(M,C,B,S,N,V,emit)
 local R=M.recovery
 if M.rejoin then R.safe_drive=M.rejoin.safe_drive;return M.rejoin end
 local J={};M.rejoin=J
 local function live(u)return u~=nil and Unit.alive(u)end
 local function point(p)return {x=p.x,y=p.y,z=p.z or 0}end
 local function state(u,n,master)
  if not live(u) then return {} end
  if master and EntityAux.has_component_master(u,n) then return EntityAux.state_master(u,n) end
  if not master and EntityAux.has_component(u,n) then return EntityAux.state(u,n) end
  return {}
 end
 local function note(b,reason,data)
  if b.rejoin_note==reason and M.clock<(b.rejoin_note_at or 0) then return end
  b.rejoin_note=reason;b.rejoin_note_at=M.clock+5
  data=data or {};data.reason=reason;emit('rejoin_deferred',data,b.id)
 end
 local function hidden(b,m,p)
  if M.mobility then return M.mobility.hidden(b,m,p) end
  return R.hidden(p)
 end
 local function reset(b,p)
  b.rejoin_anchor=point(p);b.rejoin_since=M.clock
 end
 function J.cancel(b,reason,detail)
  local q=b.rejoin_probe;if not q then return end
  if reason=='no_checked_rejoin' then b.rejoin_candidate_cursor=q.index%48 end
  local reservation=R.reservations[b.id];if reservation and reservation.provisional then R.reservations[b.id]=nil end
  b.rejoin_probe=nil;if M.mobility then M.mobility.release_recovery(b) end;S.cancel(b);S.invalidate(b)
  if b.active and live(b.unit) then S.create_probes(b,M.session) end
  note(b,reason,detail or {from=q.source,candidate=q.candidate,stage=q.stage,rejected=q.rejected})
 end
 local function eligible(b,m)
  if not b.active or M.units[b.unit]~=b or not live(b.unit) or not M.session or M.session.wants_exit then return false end
  local h=state(b.unit,'health');local c=state(b.unit,'character',true)
  if h.is_dead or h.is_downed or b.post or b.guard_request or b.objective or b.job or b.grenade_action or b.stratagem_intent or b.tactical_job
   or live(c.current_carry_unit) or state(b.unit,'interactor',true).busy then return false end
  for _,player in ipairs(M.session.players or {}) do
   local go=player.player_go
   if go and go:exists() and go:has('avatar_unit') and go:get('avatar_unit')==b.unit then return false end
  end
  if m then
   if not m.pilot or not live(m.vehicle) or not b.vehicle_order or b.vehicle_order.destination
    or M.mobility and M.mobility.human_aboard(m.vehicle) then return false end
   local h=state(m.vehicle,'health');local seat=state(m.seat or m.vehicle,'seat',true)
   return not h.is_dead and c.current_seat_unit==(m.seat or m.vehicle) and (seat.seated_units or {})[1]==b.unit
  end
  if b.mounted or b.vehicle_order or live(c.current_seat_unit) then return false end
  local name=c.current_state and c.current_state.name or ''
  for _,v in ipairs({'Interact','Carry','Throw','Dodge','Jump','Dead','Downed','Teleport','Cutscene','Extract','Reload','Stratagem','Seated'}) do
   if string.find(name,v,1,true) then return false end
  end
  return true
 end
 local function combat(b,m,visible)
  local firing=visible==true;local rounds={}
  local inv=state(b.unit,'inventory');local weapons=m and m.weapons or {{unit=inv.current_weapon or inv.primary_weapon}}
  for _,w in ipairs(weapons) do
   local a=w.ammo or (live(w.unit) and B.weapon(w.unit)) or {}
   if a.firing_auto or a.firing_single or a.charging or a.charging_shot or a.is_reloading then firing=true end
   if type(a.rounds)=='number' and w.unit then
    rounds[w.unit]=a.rounds
    if b.rejoin_rounds and b.rejoin_rounds[w.unit] and a.rounds<b.rejoin_rounds[w.unit] then firing=true end
   end
  end
  b.rejoin_rounds=rounds
  local h=state(b.unit,'health');local vh=m and state(m.vehicle,'health') or {}
  local hp=h.hitpoints_real or h.hitpoints;local vhp=vh.hitpoints_real or vh.hitpoints
  if type(hp)=='number' and b.rejoin_hp and hp<b.rejoin_hp then firing=true end
  if type(vhp)=='number' and b.rejoin_vhp and vhp<b.rejoin_vhp then firing=true end
  b.rejoin_hp=hp;b.rejoin_vhp=vhp
  local status=b.vehicle_status or {}
  if m then
   if status.visible and b.target and b.target.alive and b.target.enemy then firing=true end
   for _,w in ipairs(status.weapons or {}) do if w.trigger or w.permitted then firing=true end end
  end
  if firing then b.rejoin_combat_until=M.clock+8 end
  return firing or M.clock<(b.rejoin_combat_until or 0)
 end
 local function current(b,q)
  return b.rejoin_probe==q and q.session==M.session and q.generation==M.generation
   and q.epoch==b.rejoin_epoch and q.order==b.vehicle_order and q.body==b.unit
   and eligible(b,q.mounted)
 end
 local function actors(b,m,a,z)
  local width=m and (m.clearance or 1.45)+.3 or .53
  local function separated(p,gap)
   if math.abs((p.z or 0)-(a.z or 0))>2 then return true end
   local d=C.direction(a,z);local n=C.distance(a,z)
   local t=math.max(0,math.min(n,(p.x-a.x)*d.x+(p.y-a.y)*d.y))
   return C.distance({x=a.x+d.x*t,y=a.y+d.y*t},p)>=gap
  end
  for _,player in ipairs(M.session.players or {}) do
   local go=player.player_go;local u=go and go:exists() and go:has('avatar_unit') and go:get('avatar_unit')
   if live(u) and not separated(Unit.world_position(u,0),2+width) then return false end
  end
  for _,other in ipairs(M.bots) do if other~=b and other.active and live(other.unit) and not (m and M.mobility and M.mobility.root(other.unit)==m.vehicle) then
   local om=other.mounted;local u=om and om.pilot and om.vehicle or other.unit
   if live(u) and not separated(Unit.world_position(u,0),width+(om and om.pilot and 2.8 or .8)) then return false end
  end end
  for _,v in ipairs(M.behaviors.vehicles or {}) do
   if (not m or v.unit~=m.vehicle) and not separated(v.position,width+(v.radius or 2.8)+.5) then return false end
  end
  for id,r in pairs(R.reservations) do
   if r.expires<M.clock or r.generation~=M.generation then R.reservations[id]=nil
   elseif id~=b.id and not separated(r.position,width+(r.radius or 3.25)) then return false end
  end
  return true
 end
 local function reject(b,q,reason,detail)
  local record=detail or {};record.position=q.candidate;record.reason=reason;q.rejected[#q.rejected+1]=record
  q.stage='candidate';q.pending=nil;q.overlap=nil;q.candidate=nil;q.route=nil;q.path=nil
  q.path_checked=nil;q.landing_checked=nil;q.floor=0
 end
 local function cast(b,q,a,z,budget,callback)
  if b.edge_probe then return false end
  b.recovery_probe=true
  local accepted=S.probe(b,a,z,budget,function(clear,ground,reason)
   if not current(b,q) then return end
   q.pending=nil;callback(clear,ground,reason)
  end,q.mounted and q.mounted.vehicle)
  b.recovery_probe=nil
  if accepted and b.edge_probe then q.pending=M.clock end
  return accepted
 end
 local function clear_motion(b)
  S.cancel(b);S.invalidate(b);S.create_probes(b,M.session)
  b.coarse_route=nil;b.step_check=nil;b.interaction_check=nil;b.obstacles=nil
  b.last_position=nil;b.progress_origin=nil;b.progress_time=0;b.stuck_seconds=0;b.was_moving=false
  b.foot_push=nil;b.foot_movement=nil;b.foot_contacts=nil;b.foot_search_level=0
  b.vehicle_step=nil;b.vehicle_progress=nil;b.vehicle_stuck=0;b.vehicle_push=nil
  b.vehicle_contacts=nil;b.vehicle_block=nil;b.vehicle_visited=nil;b.navigation_observation=nil
 end
 function J.same_side(q,p,leader)
  local d=C.distance(p,leader);local source_gap=C.distance(q.source,leader)
  if d>source_gap-.5 then return false end
  if d<=8 then return true end
  local v=C.direction(leader,p);local direction=q.direction or C.direction(q.leader,q.source)
  return v.x*direction.x+v.y*direction.y>=math.cos(math.pi/6)-.0001
 end
 local function commit(b,q,leader)
  if not current(b,q) then return end
  local m=q.mounted;local u=m and m.vehicle or b.unit;local p=point(Unit.world_position(u,0))
  local closed=R.map_closed()
  if not actors(b,m,q.candidate,q.candidate) or B.risk(M.behaviors,q.candidate,b.unit)>0 then
   reject(b,q,'landing_changed');return
  end
  if not J.same_side(q,q.candidate,leader) or (q.source_side and (R.edge(p)~=q.source_side or R.edge(q.candidate)~=q.source_side))
   or not closed or not hidden(b,m,p) or not hidden(b,m,q.candidate) or (not b.catchup and combat(b,m,q.visible))
   or C.distance(p,q.source)>1.5 or C.distance(q.candidate,leader)>64.1
   or C.distance(q.goal,leader)>32 or C.distance(q.goal,leader)>C.distance(q.candidate,leader)+1 or not actors(b,m,q.candidate,q.candidate)
   or B.risk(M.behaviors,q.candidate,b.unit)>0
   or M.clock-q.landing_checked>.25 or M.clock-q.path_checked>2 then
   J.cancel(b,'commit_conditions_changed',{source_shift=C.distance(p,q.source),landing_age=M.clock-q.landing_checked,
    path_age=M.clock-q.path_checked,goal_gap=C.distance(q.goal,leader),landing_gap=C.distance(q.candidate,leader),
    actors_clear=actors(b,m,q.candidate,q.candidate),risk=B.risk(M.behaviors,q.candidate,b.unit),
    source_hidden=hidden(b,m,p),destination_hidden=hidden(b,m,q.candidate),map_closed=closed});return
  end
  if not Unit.mover(u) or not EntityAux.has_component_master(u,'mover') or not EntityAux.has_component(u,'mover') then
   J.cancel(b,'native_mover_unavailable');return
  end
  local payload={};Vector3Aux.box(payload,Vector3(q.candidate.x,q.candidate.y,q.candidate.z))
  b.release_permitted=false;b.vehicle_permissions={}
  if m then for _,other in ipairs(M.bots) do if other.active and other.mounted and other.mounted.vehicle==m.vehicle then
   other.release_permitted=false;other.vehicle_permissions={}
   if other.vehicle_input then other.vehicle_input.output_table=C.neutral() end
  end end end
  if m then b.vehicle_input.output_table=C.neutral() else
   EntityAux.command_master_immediately(b.unit,'character','input',C.neutral())
  end
  local queued=EntityAux.queue_command_slave;local delivered=false
  EntityAux.queue_command_slave=function(unit,component,command,data,...)
   if unit==u and component=='mover' and command=='teleport' then
    assert(not delivered,'Duplicate native rejoin');delivered=true
    return EntityAux.command_slave_immediately(unit,component,command,data)
   end
   return queued(unit,component,command,data,...)
  end
  local ok,err=pcall(EntityAux.command_master_immediately,u,'mover','position_teleport',payload)
  EntityAux.queue_command_slave=queued
  if not ok then error(err,0) end
  assert(delivered,'Native rejoin was not delivered')
  b.rejoin_probe=nil;b.rejoin_commit=q;q.committed=M.clock;q.deadline=M.clock+1
  b.recovery_next=M.clock+5
  if M.mobility then M.mobility.release_recovery(b) end
  b.relocated_at=M.clock;b.rejoin_candidate_cursor=nil;b.follow_progress=nil;b.catchup=nil;clear_motion(b)
  emit('rejoin_commit_requested',{from=q.source,to=q.candidate,source_side=q.source_side},b.id)
 end
 local function acknowledge(b,q,leader)
  if q.session~=M.session or q.generation~=M.generation or q.epoch~=b.rejoin_epoch or not b.active or q.body~=b.unit then
   b.rejoin_commit=nil;return false
  end
  local m=q.mounted;local u=m and m.vehicle or b.unit
  if not live(u) then b.rejoin_commit=nil;return false end
  local actual=point(Unit.world_position(u,0))
  if C.distance(actual,q.candidate)>.3 or math.abs(actual.z-q.candidate.z)>.3 then
   if M.clock<=q.deadline then return true end
   b.rejoin_commit=nil;b.rejoin_unconfirmed=q;b.recovery_next=M.clock+5
   note(b,'native_rejoin_ack_timeout',{requested=q.candidate,actual=actual,seconds=M.clock-q.committed});return false
  end
  b.rejoin_commit=nil;b.relocated_at=M.clock;reset(b,actual);b.recovery_next=M.clock+5
  q.path[1]=actual
  b.route={status='ready',origin=actual,goal=q.goal,destination=q.goal,path=q.path,index=2,follow=true,
   count=#q.path,tolerance=m and .1 or .65,arrival=m and .15 or .7,ready_at=M.clock}
  b.recovery_path_until=M.clock+15
  b.rejoin_corridor=q
  R.reservations[b.id]={position=actual,radius=m and 3.25 or 1,expires=M.clock+2,generation=M.generation}
  b.rejoin_result={position=actual,time=M.clock,moved=false,rejoined=false}
  emit('rejoin_relocated',{from=q.source,to=actual,leader=point(leader),distance=C.distance(q.source,actual),
   body=m and ((not M.mobility or M.mobility.profile(m.vehicle).kind=='exosuit') and 'exo' or 'vehicle') or 'foot',vehicle_kind=m and M.mobility and M.mobility.profile(m.vehicle).kind,stationary_seconds=q.stationary,path=q.path,rejected=q.rejected,
   map_closed=true,source_hidden=true,destination_hidden=true,source_side=q.source_side,ack_seconds=M.clock-q.committed,generation=M.generation},b.id)
 end
 function J.tick(b,m,leader,goal,budget,visible)
  local u=m and m.vehicle or b.unit;if not live(u) then return false end
  local p=point(Unit.world_position(u,0))
  if b.rejoin_commit then return acknowledge(b,b.rejoin_commit,leader) end
  if M.mobility then M.mobility.observe(b,leader,M.mobility.following(b)) end
  local fighting=not b.catchup and combat(b,m,visible)
  local context=b.rejoin_context
  if not context or context.generation~=M.generation or context.body~=u or context.epoch~=b.rejoin_epoch
   or context.order~=b.vehicle_order then
   J.cancel(b,'follow_context_changed');reset(b,p);b.foot_contacts=nil;b.foot_search_level=0
   b.rejoin_local_tried=false;b.rejoin_candidate_cursor=nil
   b.rejoin_unconfirmed=nil
   b.rejoin_context={generation=M.generation,body=u,epoch=b.rejoin_epoch,order=b.vehicle_order}
  end
  if not eligible(b,m) or fighting then J.cancel(b,fighting and 'combat' or 'action_or_order');reset(b,p);return false end
  if b.rejoin_unconfirmed then return false end
  local result=b.rejoin_result
  if result then
   if not result.moved and C.distance(p,result.position)>2 then
    result.moved=true;emit('rejoin_walking_resumed',{position=p,seconds=M.clock-result.time,generation=M.generation},b.id)
   end
   if not result.rejoined and C.distance(p,leader)<=math.max(8,C.distance(goal,leader)+1) then
    result.rejoined=true;emit('rejoin_follow_range',{position=p,leader=point(leader),walking_observed=result.moved,generation=M.generation},b.id)
   end
   if M.clock-result.time>90 then b.rejoin_result=nil end
  end
  if not b.rejoin_anchor or (not b.catchup and C.distance(p,b.rejoin_anchor)>1.5) or C.distance(p,leader)<12 then
   J.cancel(b,'movement_resumed');reset(b,p);b.rejoin_local_tried=false;return false
  end
  local q=b.rejoin_probe
  if q and not current(b,q) then J.cancel(b,'follow_context_changed');return false end
  if not q then
   if (not b.catchup and M.clock-b.rejoin_since<6) or M.clock<(b.recovery_next or 0) or M.clock<(b.rejoin_retry or 0) then return false end
   local closed,why=R.map_closed();if not closed then note(b,why);return false end
   local unseen,view_reason,projection=hidden(b,m,p)
   if not unseen then note(b,'source_visible_or_unknown',{visibility=M.mobility and M.mobility.visibility(b,m,p),
    view_reason=view_reason,projection=projection});return false end
   if type(Unit.mover)~='function' or type(EntityAux.command_master_immediately)~='function'
    or type(EntityAux.command_slave_immediately)~='function' or type(EntityAux.queue_command_slave)~='function'
    or not Vector3Aux or type(Vector3Aux.box)~='function' or type(PhysicsWorld.overlap)~='function' then
    note(b,'native_rejoin_api_unavailable');return false
   end
   if not Unit.mover(u) or not EntityAux.has_component_master(u,'mover') or not EntityAux.has_component(u,'mover') then
    note(b,'native_mover_unavailable');return false
   end
   if M.mobility and not M.mobility.claim_recovery(b) then note(b,'recovery_queued');return false end
   R.cancel(b,'near_player_rejoin');S.cancel(b);S.invalidate(b);S.create_probes(b,M.session)
   q={session=M.session,generation=M.generation,epoch=b.rejoin_epoch,order=b.vehicle_order,body=b.unit,
    mounted=m,source=p,leader=point(leader),goal=point(goal),follow_gap=C.distance(goal,leader),started=M.clock,
    stationary=M.clock-b.rejoin_since,index=b.rejoin_candidate_cursor or 0,stage='candidate',rejected={},visible=visible}
   q.direction=C.direction(q.leader,q.source);q.source_side=R.edge and R.edge(p)
   q.goal={x=leader.x+q.direction.x*math.max(4.8,q.follow_gap),y=leader.y+q.direction.y*math.max(4.8,q.follow_gap),z=leader.z}
   b.rejoin_probe=q;emit('rejoin_started',{position=p,leader=point(leader),stationary_seconds=q.stationary,body=m and ((not M.mobility or M.mobility.profile(m.vehicle).kind=='exosuit') and 'exo' or 'vehicle') or 'foot',vehicle_kind=m and M.mobility and M.mobility.profile(m.vehicle).kind,generation=M.generation},b.id)
  end
  q.visible=visible
  local closed,why=R.map_closed()
  local unseen,view_reason,projection=hidden(b,m,p)
  if not closed or not unseen then J.cancel(b,why or 'source_visible',
   {visibility=M.mobility and M.mobility.visibility(b,m,p),view_reason=view_reason,projection=projection,map_closed=closed});return false end
  if M.clock-q.started>20 or (q.index>=48 and q.stage=='candidate') then
   J.cancel(b,'no_checked_rejoin');b.rejoin_retry=M.clock+5;return false
  end
  if q.pending then
   if M.clock-q.pending>.75 then
    S.invalidate(b);S.create_probes(b,M.session);reject(b,q,'probe_timeout')
   end
   return true
  end
  if q.stage=='candidate' then
   q.index=q.index+1
   local radii={10,16,24,32,48,64};local angles={0,math.pi/12,-math.pi/12,math.pi/6,-math.pi/6,math.pi/18,-math.pi/18,0}
   local radius=radii[math.floor((q.index-1)/8)+1];if not radius then return true end
   local d=C.direction(q.leader,q.source);local angle=angles[(q.index-1)%8+1];local c,s=math.cos(angle),math.sin(angle)
   q.candidate={x=q.leader.x+(d.x*c-d.y*s)*radius,y=q.leader.y+(d.x*s+d.y*c)*radius,z=q.leader.z}
   if not J.same_side(q,q.candidate,leader) or (q.source_side and R.edge(q.candidate)~=q.source_side) then reject(b,q,'wrong_approach_side');return true end
   if C.distance(q.candidate,q.source)<3.6 then reject(b,q,'insufficient_shift');return true end
   local unseen,view_reason,projection=hidden(b,m,q.candidate)
   if not unseen then
    reject(b,q,'landing_visibility',{view_reason=view_reason,projection=projection});return true
   end
   if not actors(b,m,q.candidate,q.candidate) then reject(b,q,'landing_occupied');return true end
   q.route=N.new(q.candidate,q.goal,M.clock);q.route.limit=1024;q.route.bounds=math.min(72,math.max(24,C.distance(q.candidate,q.goal)+4));q.route.timeout=12;q.route.weight=1.25
   q.stage='path'
  end
  if q.stage=='path' then
   for advance=1,12 do
   N.advance(q.route,M.clock,function(a,z,cb)
    if not J.same_side(q,z,leader) or not actors(b,m,a,z) then cb(false);return true end
    return cast(b,q,a,z,budget,cb)
   end)
   if q.route.pending or q.route.status~='planning' then break end
   end
   if q.route.status=='failed' then reject(b,q,q.route.reason)
   elseif q.route.status=='ready' then
    q.path={point(q.candidate)};for _,v in ipairs(q.route.path) do q.path[#q.path+1]=point(v) end
    q.path_checked=M.clock;q.floor=0;q.stage='floor'
   end
  elseif q.stage=='floor' then
   local width=m and (m.clearance or 1.45)+.3 or .53
   local length=m and M.mobility and M.mobility.profile(m.vehicle).length+.3 or width
   local offsets={{0,0},{width,0},{-width,0},{0,length},{0,-length},
    {width,length},{width,-length},{-width,length},{-width,-length}}
   local offset=offsets[q.floor+1]
   if not offset then q.stage='overlap';return true end
   local a={x=q.candidate.x+offset[1],y=q.candidate.y+offset[2],z=q.candidate.z}
   cast(b,q,a,{x=a.x+.12,y=a.y,z=a.z},budget,function(clear,ground,reason)
    if not clear or not ground or math.abs(ground.z-q.candidate.z)>.35 then reject(b,q,reason or 'landing_floor');return end
    if q.floor==0 then q.candidate.z=ground.z end;q.floor=q.floor+1
   end)
  elseif q.stage=='overlap' then
   q.pending=M.clock;local token={};q.overlap=token;local width=m and (m.clearance or 1.45)+.3 or .53
   if m and M.mobility then width=math.max(width,M.mobility.profile(m.vehicle).length+.3) end
   PhysicsWorld.overlap(World.physics_world(M.session.world_proxy:get_world()),S.guard(b,'rejoin_overlap',function(found)
    if not current(b,q) or q.overlap~=token then return end
    assert(type(found)=='table','Invalid rejoin overlap reply');q.pending=nil
    local ignore={[b.unit]=true};if m then ignore[m.vehicle]=true;if m.seat then ignore[m.seat]=true end
     for _,w in ipairs(m.weapons or {}) do ignore[w.unit]=true end end
    if m and M.mobility then for _,v in ipairs(M.mobility.assembly(m.vehicle)) do ignore[v]=true end end
    for _,actor in ipairs(found) do if not ignore[Actor.unit(actor)] then reject(b,q,'landing_occupied');return end end
    q.landing_checked=M.clock;q.stage='commit'
   end,function()if current(b,q) then reject(b,q,'overlap_error') end end),
   'shape','capsule','position',Vector3(q.candidate.x,q.candidate.y,q.candidate.z+width+.65),
   'size',Vector3(width,.5,0),'rotation',Quaternion.look(Vector3.up(),Vector3.forward()),'collision_filter','spawn_check')
  elseif q.stage=='commit' then commit(b,q,leader) end
  return true
 end
 function J.safe(b,...)
  local ok,held=pcall(J.tick,b,...)
  if ok then return held end
  local printed,message=pcall(tostring,held)
  pcall(J.cancel,b,'rejoin_error',{message=printed and message or 'Unprintable rejoin error'});b.rejoin_retry=M.clock+5
  pcall(note,b,'rejoin_error',{message=printed and message or 'Unprintable rejoin error'});return false
 end
 function J.foot(b,leader,goal,budget,job,interacting,danger,visible)
  if b.rejoin_commit then return J.safe(b,nil,leader,goal,budget,visible) end
  if job or interacting or danger then J.cancel(b,'action_or_hazard');reset(b,Unit.world_position(b.unit,0));return false end
  return J.safe(b,nil,leader,goal,budget,visible)
 end
 function R.safe_drive(b,m,leader,dt,budget,friends,spacing)
  local d=C.direction(leader,Unit.world_position(m.vehicle,0))
  local gap=math.max(4.8,(m.clearance or 1.45)+3)
  local goal={x=leader.x+d.x*gap,y=leader.y+d.y*gap,z=leader.z}
  return J.safe(b,m,leader,goal,budget,spacing~=nil)
 end
 J.safe_drive=R.safe_drive
 local native_navigate=S.navigate
 function S.navigate(b,p,goal,budget,follow)
  local q=b.rejoin_corridor
  if q then
   local leader=M.player_anchor or q.leader
   if q.session~=M.session or q.generation~=M.generation or q.epoch~=b.rejoin_epoch
    or q.order~=b.vehicle_order or not eligible(b,b.mounted) or C.distance(p,leader)<=8 then
    b.rejoin_corridor=nil
   else
    -- Keep checking this approach side until ordinary follow range is reached.
    -- A blocked or displaced corridor is replanned through native navigation.
    goal={x=leader.x+q.direction.x*4.8,y=leader.y+q.direction.y*4.8,z=leader.z}
    b.recovery_path_until=M.clock+1
    if b.route and b.route.status=='ready' then
     for i=b.route.index or 1,#b.route.path do if not J.same_side(q,b.route.path[i],leader) then S.cancel(b);break end end
    end
    if not b.route then
     local d=C.direction(p,goal);local gap=math.min(12,C.distance(p,goal))
     local endpoint={x=p.x+d.x*gap,y=p.y+d.y*gap,z=goal.z}
     b.route=N.new(p,endpoint,M.clock);b.route.destination=goal;b.route.follow=true
    end
    if b.route.status=='ready' then goal=b.route.destination or b.route.goal end
   end
  end
  return native_navigate(b,p,goal,budget,follow)
 end
 local old_config=S.vehicle_route_config
 function S.vehicle_route_config(b,q)
  old_config(b,q)
  if not b.mounted and not q.foot_configured then
   q.foot_configured=true;q.limit=({196,512,1024})[(b.foot_search_level or 0)+1];q.bounds=24
  end
 end
 local old_partial=S.vehicle_partial_route
 function S.vehicle_partial_route(b,q)
  if not b.mounted and not q.foot_failed then
   q.foot_failed=true;b.foot_search_level=math.min(2,(b.foot_search_level or 0)+1)
  end
  return old_partial(b,q)
 end
 local old_reject=S.vehicle_route_reject
 function S.vehicle_route_reject(b,a,z)
  local q=b.rejoin_corridor
  if q and not J.same_side(q,z,M.player_anchor or q.leader) then return true end
  if b.mounted then return old_reject(b,a,z) end
  for i=#(b.foot_contacts or {}),1,-1 do local q=b.foot_contacts[i]
   if M.clock>q.expires then table.remove(b.foot_contacts,i)
   elseif C.distance(a,q.position)<1.1 then
    local d=C.direction(a,z)
    if d.x*q.direction.x+d.y*q.direction.y>.5 then return true end
   end
  end
  return false
 end
 function J.contact(b,p,dt,movement)
  if b.mounted then return end
  local attempted=b.foot_movement
  if movement then b.foot_movement=point(movement) end
  local epoch=b.rejoin_epoch
  if b.foot_epoch~=epoch then b.foot_epoch=epoch;b.foot_contacts=nil;b.foot_push=nil;b.foot_search_level=0 end
  if not attempted or attempted.x*attempted.x+attempted.y*attempted.y<.01 or b.rejoin_probe then b.foot_push=nil;return end
  local push=b.foot_push
  if not push or C.distance(push.position,p)>.18 then push={position=point(p),seconds=0};b.foot_push=push end
  push.seconds=push.seconds+dt
  if push.seconds>=1.2 then
   local d=C.direction({x=0,y=0},attempted)
   if d.x*d.x+d.y*d.y<.01 then return end
   local contacts=b.foot_contacts or {};b.foot_contacts=contacts
   contacts[#contacts+1]={position=point(p),direction=d,expires=M.clock+18};if #contacts>8 then table.remove(contacts,1) end
   b.foot_push=nil;S.cancel(b);b.route_retry=0;b.stuck_seconds=1.1
   emit('foot_contact_blocked',{position=p,direction=d,expires=M.clock+18},b.id)
  end
 end
 return J
end
