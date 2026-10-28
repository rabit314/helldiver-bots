-- Human identity follows control; inventory and condition stay with the body.
return function(M,C,emit)
 local T=M.takeover or {handled=setmetatable({}, {__mode='k'})};M.takeover=T
 T.records=T.records or setmetatable({}, {__mode='k'});T.humans=T.humans or setmetatable({}, {__mode='k'})
 local function live(u)return u~=nil and Unit.alive(u)end
 local function state(u,n)
  -- Death/downed flags belong to replicated health, not master health.
  -- Native HealthComponent.update_slaves sets them before on_player_death.
  if n=='health' and live(u) and EntityAux.has_component(u,n) then return EntityAux.state(u,n) end
  if live(u) and EntityAux.has_component_master(u,n) then return EntityAux.state_master(u,n) end
 end
 local function cmd(u,c,n,d)if live(u) then EntityAux.queue_command_master(u,c,n,d)end end
 local function pos(u)assert(live(u),'Expired takeover unit');local p=Unit.world_position(u,0);return {x=p.x,y=p.y,z=p.z}end
 local function anchor(u)
  M.player_anchor=pos(u);M.leader_motion={position=M.player_anchor,heading={x=0,y=1},velocity={x=0,y=0},speed=0}
 end
 local function record(s,u)
  local count,p,index=0
  for i,v in ipairs(s.players or {}) do
   local go=v.player_go
   if go and go:exists() then
    count=count+1
    if go:owned() and go:has('avatar_unit') and go:get('avatar_unit')==u then p=v;index=i end
   end
  end
  if count==1 then return p,index end
 end
 local function strata(u,fallback)
  local inv=state(u,'inventory');local result={}
  for i,a in ipairs(inv and inv.stratagems or fallback or {}) do
   local entry={}
   for k,v in pairs(a) do
    if type(k)=='string' and (type(v)=='number' or type(v)=='boolean' or type(v)=='string') then entry[k]=v end
   end
   result[i]=entry
  end
  return result
 end
 local function bind(u,pad,active)
  cmd(u,'input','pad_number',pad)
  cmd(u,'camera_target',active and 'activate' or 'deactivate')
 end
 local function neutral(u)
  local c=state(u,'character') or {}
  if not c.current_seat_unit then cmd(u,'mover','set_movement',{x=0,y=0,z=0}) end
  cmd(u,'character','input',C.neutral())
 end
 local function seated_ready(u,c)
  if not c.current_seat_unit then return true end
  local seat=state(c.current_seat_unit,'seat')
  return not c.is_exiting and (tonumber(c.enter_seat_timer) or 0)<=0 and seat
   and (seat.seated_units or {})[c.current_seat_index]==u
 end
 local function ready(b,allow_downed,allow_seated)
  local h=state(b.unit,'health');local c=state(b.unit,'character')
  if not b.active or not h or h.is_dead then return false,'dead_or_missing' end
  if h.is_downed and not allow_downed then return false,'downed' end
  if not c then return false,'missing_character' end
  if c.current_seat_unit then
   if not allow_seated then return false,'not_on_foot' end
   if not seated_ready(b.unit,c) then return false,'seat_transition' end
  end
  for _,n in ipairs({'input','inventory','camera_target'}) do if not state(b.unit,n) then return false,'missing_'..n end end
  return true
 end
 function T.is_body(u)return M.bot_origins and M.bot_origins[u]==true end
 function T.is_original_body(u)return T.humans[u]==true and T.tracking_session==M.session end
 function T.count_death(s,u)
  if not T.is_body(u) then s.player_deaths=(s.player_deaths or 0)+1 end
 end
 function T.track(s,u)
  if T.tracking_session~=s then
   T.tracking_session=s;T.original=nil;T.current_id=0;T.original_stratagems=nil
   T.records=setmetatable({}, {__mode='k'});T.humans=setmetatable({}, {__mode='k'})
  end
  if live(u) and not T.is_body(u) then
   T.humans[u]=true
   local h=state(T.original,'health')
   if not h or h.is_dead then T.original=u end
   if u==T.original then T.original_stratagems=strata(u,T.original_stratagems) end
  end
 end
 local function transfer(s,p,u,b,home)
  local source=T.possessed or T.records[u]
  if not source then source=M.body_record(u);T.records[u]=source end
  local mounted=b.vehicle_order
  local ok,err=pcall(function()
   M.detach_bot(b,'control_switched')
   local c=state(u,'character') or {}
   if c.current_interact_objective_unit then
    cmd(u,'input','change_controls',{remove_static={'move'}})
    cmd(u,'character','exit_interact_objective')
   end
   neutral(u);neutral(b.unit);bind(u,nil,false)
   p.player_go:set('avatar_unit',b.unit);bind(b.unit,p.pad_number,true)
  end)
  if not ok then
   pcall(p.player_go.set,p.player_go,'avatar_unit',u);pcall(bind,u,p.pad_number,true)
   pcall(bind,b.unit,nil,false);pcall(M.rejoin_bot,b,mounted)
   emit('squad_switch_failed',{message=tostring(err)},b.id,'errors');return 'Control switch failed; previous body retained'
  end
  T.records[b.unit]=b;T.current_id=b.id;T.possessed=not home and b or nil;T.player=p;T.session=s
  p.is_respawning=false;p.spawn_timer=0;p.has_sent_respawn_request=false;p.spawn_owner_unit=nil
  p.stratagems=strata(b.unit);M.rejoin_bot(source)
  anchor(b.unit);M.waiting_for_player=false;M.cursor_sample=nil
  M.control_epoch=(M.control_epoch or 0)+1
  emit('squad_switched',{original=home,from=source.id,extra_lives=p.extra_lives},b.id)
  return home and 'Controlling your first Helldiver; no respawn point spent' or ('Controlling bot '..b.id..'; no respawn point spent')
 end
 function T.cycle(s,u)
  local p=record(s,u)
  if not p or s~=M.session or not M.enabled or s.wants_exit or s.game_state=='game_over' then return 'Switch needs the current solo mission' end
  T.track(s,u)
  if T.pending then return 'Wait for your requested Helldiver to arrive' end
  local h=state(u,'health');local c=state(u,'character') or {}
  if not h or h.is_dead or p.is_respawning then return 'Wait for the current respawn to finish' end
  if not seated_ready(u,c) then return 'Wait for vehicle entry or exit to finish' end
  local best,first
  for _,b in ipairs(M.bots) do if b.unit~=T.original and ready(b,false,true) then
   if not first or b.id<first.id then first=b end
   if b.id>(T.current_id or 0) and (not best or b.id<best.id) then best=b end
  end end
  best=best or first
  if not best then return 'No other standing bot available to control' end
  return transfer(s,p,u,best,false)
 end
 function T.home(s,u,force)
  local p=record(s,u)
  if not p or s~=M.session or (not force and (s.wants_exit or s.game_state=='game_over')) then return 'Return needs the current solo mission' end
  T.track(s,u)
  if u==T.original then return 'You already control your first Helldiver' end
  if T.pending then return 'Your requested Helldiver is already arriving' end
  local b=T.records[T.original] or M.units[T.original];local h=state(T.original,'health')
  if not h or h.is_dead then return 'Your first Helldiver is dead; F11 requests a replacement for one point' end
  if b and not b.active then M.rejoin_bot(b) end
  if not b or not ready(b,true,true) then return 'Your first Helldiver is unavailable or changing seats' end
  if not seated_ready(u,state(u,'character') or {}) then return 'Wait for vehicle entry or exit to finish' end
  return transfer(s,p,u,b,true)
 end
 function T.death(s,u)
  if T.handled[u] then return true end
  if not M.enabled or s~=M.session or not s.is_server or s.wants_exit or s.game_state=='game_over' then return false end
  local p=record(s,u);local h=state(u,'health')
  if not p or not h or not h.is_dead then return false end
  T.track(s,u)
  if p.player_go:has('has_extracted') and p.player_go:get('has_extracted') then return false end
  if T.pending then
   -- This replacement is already paid for. A death while it is arriving must
   -- neither charge a second life nor queue a second pod.
   T.handled[u]=true;T.pending.source_died=true;T.count_death(s,u);p.is_respawning=true
   M.player_anchor=pos(u);T.pending.position=M.player_anchor
   T.pending.stratagems=strata(u,T.pending.stratagems)
   emit('takeover_waiting_paid_return',{},T.possessed and T.possessed.id);return true
  end
  local origin=pos(u);local candidates={};local skipped={}
  for _,b in ipairs(M.bots) do
   local eligible,reason=ready(b,true,true)
   if eligible then
    local bp=pos(b.unit);local d=C.distance(origin,bp)
    local height=math.abs(bp.z-origin.z)
    candidates[#candidates+1]={bot=b,distance=d,height=height,rank=math.sqrt(d*d+height*height),downed=state(b.unit,'health').is_downed==true}
   else skipped[#skipped+1]={id=b.id,reason=reason}
   end
  end
  emit('takeover_checked',{candidates=#candidates,bots=#M.bots,skipped=skipped,position=origin})
  table.sort(candidates,function(a,b)
   if a.downed~=b.downed then return not a.downed end
   return a.rank<b.rank or (a.rank==b.rank and a.bot.id<b.bot.id)
  end)
  for _,candidate in ipairs(candidates) do
   local b=candidate.bot
   if ready(b,true,true) and (state(b.unit,'health').is_downed==true)==candidate.downed then
    -- Keep the occupied seat and its order available if the handoff rolls back.
    local mounted=b.vehicle_order
    local detached=false
    local ok,err=pcall(function()
     M.detach_bot(b,'possessed');detached=true
     neutral(b.unit);bind(u,nil,false)
     local h=state(b.unit,'health');local c=state(b.unit,'character')
     assert(h and not h.is_dead and (h.is_downed==true)==candidate.downed and c and seated_ready(b.unit,c),'Takeover casualty changed before binding')
     p.player_go:set('avatar_unit',b.unit)
     bind(b.unit,p.pad_number,true)
    end)
    if ok then
     T.handled[u]=true;T.possessed=b;T.player=p;T.session=s
     T.records[b.unit]=b;T.current_id=b.id
     if b.unit==T.original then T.possessed=nil end
     p.is_respawning=false;p.spawn_timer=0;p.has_sent_respawn_request=false;p.spawn_owner_unit=nil
     p.stratagems=strata(b.unit)
     T.count_death(s,u)
     anchor(b.unit);M.waiting_for_player=false
     if live(u) then M.retire_body(u,T.records[u]) end
     M.control_epoch=(M.control_epoch or 0)+1
     emit('takeover_complete',{distance=candidate.distance,height=candidate.height,downed=candidate.downed,extra_lives=p.extra_lives,equipment=b.kit and b.kit.names},b.id)
     return true
    end
    -- One failed cleanup command must not skip the remaining rollback steps.
    pcall(p.player_go.set,p.player_go,'avatar_unit',u)
    pcall(bind,b.unit,nil,false)
    if detached and live(b.unit) then pcall(M.rejoin_bot,b,mounted) end
    emit('takeover_failed',{message=tostring(err)},b.id,'errors')
   end
  end
  emit('takeover_fallback',{reason=#candidates==0 and 'no_eligible_nearby_bot' or 'handoff_failed',extra_lives=p.extra_lives})
  return false
 end
 local function count_finish(s,r)
  if not r.counted then return end
  r.counted=false;s.num_respawning_players=math.max(0,(s.num_respawning_players or 1)-1)
  s.mission_manager:set_respawning_players(s.num_respawning_players)
 end
 function T.cancel(reason)
  local r=T.pending;if not r then return end
  T.pending=nil;r.cancelled=true;M.landings[r.zone]=nil
  local s=r.session
  for i=#(s.spawn_manager.queued_spawns or {}),1,-1 do
   if s.spawn_manager.queued_spawns[i].callback_object==r.callback then table.remove(s.spawn_manager.queued_spawns,i) end
  end
  count_finish(s,r)
  if r.charged then
   s:set_extra_lives(r.player,(tonumber(r.player.extra_lives) or 0)+1);r.charged=false
  end
  r.player.is_respawning=false;r.player.spawn_timer=0
  emit('original_return_cancelled',{reason=reason})
  local sm=Boot and Boot.state_machine
  if r.source_died and sm and sm.state==s and not s.wants_exit and s.game_state~='game_over' and T.native_death then
   if live(r.source.unit) then
    T.native_death(s,r.source.unit)
   elseif (tonumber(r.player.extra_lives) or 0)>0 or s.infinite_respawns then
    -- The corpse may have expired during the wait. Native death reads its
    -- position without checking the handle. Resume the native RPC/timer from
    -- the cached position instead, retaining the existing main-body death total.
    if not s.infinite_respawns then s:set_extra_lives(r.player,r.player.extra_lives-1) end
    r.player.extra_lives_maxed=false;r.player.is_respawning=true
    r.player.has_sent_respawn_request=true;r.player.stratagems=r.stratagems
    local p=r.position
    s.network_router:transmit_to_all('rpc_on_respawn',Vector3(p.x,p.y,p.z),nil,false,{r.player.player_go:get('index')})
   end
  end
 end
 function T.request(s,u)
  T.track(s,u)
  local original=state(T.original,'health')
  if T.original~=u and original and not original.is_dead then return T.home(s,u) end
  local p,index=record(s,u);local b=T.possessed;local h=state(u,'health')
  if not p or not s.is_server or s.wants_exit or s.game_state=='game_over' or not b or b.unit~=u then return 'You are already in your original Helldiver' end
  if T.pending then return 'Original Helldiver is already arriving' end
  if not h or h.is_dead or h.is_downed then return 'Return needs a living, standing controlled bot' end
  if p.player_go:has('has_extracted') and p.player_go:get('has_extracted') then return 'Cannot return after extraction' end
  if (tonumber(p.extra_lives) or 0)<1 then return 'No respawn points remain' end
  local c=state(u,'character') or {}
  if c.current_seat_unit then return 'Leave the vehicle before returning to your Helldiver' end
  if type(s.on_entity_spawned)~='function' or not s.mission_manager or type(s.set_extra_lives)~='function' then return 'Native replacement path is not ready' end
  local point=M.return_point and M.return_point(u)
  if not point then return 'Waiting for a clear landing area; no point spent' end
  local r={session=s,player=p,source=b,generation=M.generation,started=M.clock,index=index,zone='original_return',
   position=pos(u),stratagems=strata(u,p.stratagems),original_stratagems=strata(T.original,T.original_stratagems)}
  T.pending=r;M.landings[r.zone]={position=point,radius=4.5,expires=M.clock+30}
  local function failed(reason)
   if T.pending~=r then return end
   T.cancel(reason)
  end
  r.callback={squad_owner=M}
  r.callback.on_entity_spawn_failed=function()failed('spawn_failed')end
  r.callback.on_entity_spawn_inside_screen_failed=function()failed('no_safe_ground')end
  r.callback.on_entity_spawned=function(_,unit,path,pv,rot,data)
   if T.pending~=r or r.cancelled or M.session~=s or M.generation~=r.generation or s.wants_exit then
    if live(unit) then s.entity_spawner:despawn_entity(unit) end;return
   end
   if not live(unit) then failed('replacement_missing');return end
   local old=u;local values=r.original_stratagems
   local name=p.player_go:get('name');local previous=s.player_stratagems and s.player_stratagems[name]
   local count_before=s.num_respawning_players
   local ok,err=pcall(function()
    neutral(old);bind(old,nil,false)
    -- Native on_entity_spawned would decay a living possessed bot. Hide only
    -- this avatar during this synchronous callback, then use native loadout/UI setup.
    p.player_go:set('avatar_unit',nil)
    s.player_stratagems=s.player_stratagems or {};s.player_stratagems[name]=values
    s:on_entity_spawned(unit,path,pv,rot,{player_index=index,pad_number=p.pad_number})
    assert(p.player_go:get('avatar_unit')==unit,'Native replacement did not bind the avatar')
   end)
   r.counted=s.num_respawning_players==count_before
   if not ok then
    pcall(function()p.player_go:set('avatar_unit',old);bind(old,p.pad_number,true)end)
    s.player_stratagems[name]=previous
    s.entity_spawner:despawn_entity(unit);failed(tostring(err));return
   end
   count_finish(s,r);T.pending=nil;r.charged=false;M.landings[r.zone]=nil
   T.possessed=nil;T.player=nil;T.session=nil
   T.original=unit;T.humans[unit]=true;T.current_id=0
   T.original_stratagems=values;p.stratagems=values
   local oldhealth=state(old,'health')
   if oldhealth and not oldhealth.is_dead then
    M.rejoin_bot(b)
   elseif live(old) then M.retire_body(old,b) end
   anchor(unit)
   emit('original_return_complete',{extra_lives=p.extra_lives},b.id)
  end
  local ok,err=pcall(function()
   s:set_extra_lives(p,p.extra_lives-1);r.charged=true;p.extra_lives_maxed=false
   s.num_respawning_players=(s.num_respawning_players or 0)+1;r.counted=true
   s.mission_manager:set_respawning_players(s.num_respawning_players)
   s.spawn_manager:queue_spawn('characters/helldiver_private_01/helldiver_private_01',
    Vector3(point.x,point.y,point.z),nil,r.callback,{player_index=index,pad_number=p.pad_number},nil,true)
  end)
  if not ok then failed(tostring(err));return 'Return failed: '..tostring(err) end
  emit('original_return_requested',{extra_lives=p.extra_lives},b.id)
  return 'Original Helldiver requested: 1 respawn point spent'
 end
 function T.tick(s)
  local r=T.pending
  if r and (r.session~=s or M.clock-r.started>25) then T.cancel('replacement_timeout') end
  if T.session and T.session~=s then T.possessed=nil;T.player=nil;T.session=nil;T.handled=setmetatable({}, {__mode='k'}) end
  if T.possessed and T.player and not T.pending and T.player.player_go:get('avatar_unit')~=T.possessed.unit then
   T.possessed=nil;T.player=nil;T.session=nil
  end
  for _,p in ipairs(s.players or {}) do
   local go=p.player_go
   if go and go:exists() and go:owned() and go:has('avatar_unit') then T.track(s,go:get('avatar_unit'));break end
  end
 end
 return T
end
