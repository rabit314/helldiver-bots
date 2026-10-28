-- Observe the native abandonment warning; never alter extraction's timer/rules.
return function(M,C,B,S,V,H,emit)
 if M.extraction_cleanup then return M.extraction_cleanup end
 local E={pending={},warnings={},hooks={}};M.extraction_cleanup=E
 local state=H.state
 local function live(u)return u~=nil and Unit.alive(u)end
 local function pos(u)if live(u) then local p=Unit.world_position(u,0);return {x=p.x,y=p.y,z=p.z} end end
 local function human()
  for _,p in ipairs(M.session and M.session.players or {}) do local go=p.player_go
   if go and go:exists() and go:owned() and go:has('avatar_unit') then
    local u=go:get('avatar_unit');if live(u) and not state(u,'health').is_dead then return u end
   end
  end
 end
 local function report(b,reason,data)
  if b.extract_reason==reason and M.clock<(b.extract_note_at or 0) then return end
  b.extract_reason=reason;b.extract_note_at=M.clock+2;data=data or {};data.reason=reason
  emit('extraction_bot_exempt',data,b.id)
 end
 function E.recall(b)
  if not (b.post or b.guard_request or b.objective or b.tactical_job or b.stratagem_intent
    or b.vehicle_order and (b.vehicle_order.destination or not b.vehicle_order.pilot)) then return false end
  if M.cancel_guard then M.cancel_guard(b) end
  if M.objectives then M.objectives.release(b,'extraction_recall') end
  if M.tactics then M.tactics.detach(b,'extraction_recall') end
  B.release(M.behaviors,b,'extraction_recall',M.clock,emit)
  if not V.regroup(b) then V.release(b,'extraction_recall',true) end
  b.post=nil;b.post_arrived=nil;b.returning=true;b.follow_progress=nil;b.catchup=nil;S.cancel(b)
  emit('extraction_bot_recalled',{},b.id);return true
 end
 local function rescuer_coming(b)
  for _,other in ipairs(M.bots) do local j=other.job;local q=other.follow_progress
   if other~=b and other.active and j and j.kind=='revive' and (j.unit==b.unit or j.target==b.unit)
    and q and (q.advancing or C.distance(q.position,pos(b.unit))<2) then return true end
  end
  return false
 end
 function E.kill(b,root,evidence)
  if E.pending[b.unit] then return end
  if root~=b.unit then
   local driver=H.driver(root)
   if driver then
    driver.vehicle_input.output_table=C.neutral();H.adapt(driver,driver.mounted or {vehicle=root},driver.vehicle_input.output_table)
    -- Native braking, without changing configured speeds or damaging the vehicle.
    EntityAux.queue_command_master(root,'mover','set_movement',{x=0,y=0,z=0})
   end
  end
  if M.tactics then M.tactics.detach(b,'extraction_stuck') end
  S.cancel(b)
  local h=state(b.unit,'health');local hp=math.min(-1,(tonumber(h.constitution) or -100)-1)
  evidence.new_hitpoints=hp;evidence.unit=tostring(b.unit)
  E.pending[b.unit]={bot=b,requested=M.clock,generation=M.generation}
  emit('extraction_stuck_death_requested',evidence,b.id)
  -- The native health command emits on_killed and owns replication/death effects.
  local command=EntityAux.command_master_immediately or EntityAux.queue_command_master
  local ok,err=pcall(command,b.unit,'health','set_hitpoints',hp)
  if not ok then E.pending[b.unit]=nil;emit('extraction_stuck_death_error',{message=tostring(err)},b.id,'errors') end
 end
 function E.evaluate(unit,entity)
  if not M.enabled or not M.session or M.session.wants_exit then return end
  local a=entity.state;local cfg=(entity.settings or {}).extract_beacon_info or {}
  local warning=not not (a.activated and a.too_far_away==true and type(a.too_far_away_timer)=='number' and a.too_far_away_timer>0)
  if warning~=not not E.warnings[unit] then
   E.warnings[unit]=warning or nil
   emit(warning and 'extraction_distance_warning_started' or 'extraction_distance_warning_ended',
    {beacon=tostring(unit),timer=a.too_far_away_timer,radius=cfg.too_far_away_distance})
  end
  if not warning then return end
  local player=human();local lp=pos(player);local center=pos(unit);local radius=tonumber(cfg.too_far_away_distance)
  if not lp or not center or not radius or C.distance(lp,center)>radius or state(player,'health').is_downed then return end
  local bots={};for _,b in ipairs(M.bots) do bots[#bots+1]=b end
  for _,b in ipairs(bots) do if b.active and live(b.unit) and not state(b.unit,'health').is_dead then
   local root=H.root(b.unit);local p=pos(root);local h=state(b.unit,'health')
   local reason
   if not (M.bot_origins or {})[b.unit] or H.human(b.unit) or M.is_original_body and M.is_original_body(b.unit) then reason='protected_body'
   elseif not p or C.distance(p,lp)<=18 or C.distance(p,center)<=radius then reason='nearby'
   elseif root~=b.unit and H.human_aboard(root) then reason='human_aboard'
   elseif E.recall(b) then reason='recalled_order'
   else
    local q=b.follow_progress
    if not q or q.root~=root or q.session~=M.session or M.clock-((q.samples[#q.samples] or {}).time or -math.huge)>.75 then reason='movement_history_unavailable'
    elseif h.is_downed and rescuer_coming(b) then reason='rescuer_advancing'
    elseif q.advancing then reason='advancing'
    elseif q.blocked_seconds<6 or not q.intended and not h.is_downed then reason='not_confirmed_stuck'
    else
     E.kill(b,root,{beacon=tostring(unit),timer=a.too_far_away_timer,position=p,human=lp,
      distance=C.distance(p,lp),blocked_seconds=q.blocked_seconds,root=tostring(root),downed=h.is_downed})
    end
   end
   if reason then report(b,reason,{position=p}) end
  end end
 end
 function E.tick()
  for u,q in pairs(E.pending) do
   if q.generation~=M.generation then E.pending[u]=nil
   elseif not live(u) or state(u,'health').is_dead then
    emit('extraction_stuck_death_confirmed',{seconds=M.clock-q.requested},q.bot.id);E.pending[u]=nil
   elseif M.clock-q.requested>2 then
    emit('extraction_stuck_death_unconfirmed',{seconds=M.clock-q.requested},q.bot.id,'errors');E.pending[u]=nil
   end
  end
 end
 function E.install()
  if E.hook then return end
  local object=rawget(_G,'ExtractBeaconComponent')
  if not object or type(object.update_masters)~='function' then return end
  local old=object.update_masters
  local wrapper=function(self,entities,dt,...)
   local result=old(self,entities,dt,...)
   for u,e in pairs(entities) do
    local ok,err=pcall(E.evaluate,u,e)
    if not ok and M.clock>=(E.error_at or 0) then
     E.error_at=M.clock+5;emit('extraction_cleanup_error',{message=tostring(err)},nil,'errors')
    end
   end
   return result
  end
  E.hook={object=object,old=old,wrapper=wrapper};object.update_masters=wrapper
 end
 function E.reset()E.pending={};E.warnings={}end
 function E.uninstall()
  local h=E.hook;if h and h.object.update_masters==h.wrapper then h.object.update_masters=h.old end
  E.hook=nil;E.reset()
 end
 E.install();return E
end
