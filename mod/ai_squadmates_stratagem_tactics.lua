-- Shared needs, one preparation owner, native actions and opportunistic retrieval.
return function(M,C,B,S,V,P,Native,emit)
 if M.tactics then
  if M.stratagem_families then M.stratagem_families.install() end
  M.tactics.native.install();return M.tactics
 end
 local T={pending={},claims={},failed=setmetatable({}, {__mode='k'}),resource_settings=setmetatable({}, {__mode='k'}),resources={},actors={},history=setmetatable({}, {__mode='k'}),enemy_motion=setmetatable({}, {__mode='k'}),
  needs=setmetatable({}, {__mode='k'}),cap_status={},next_scan=0,model=P}
 M.tactics=T
 local family=(rawget(_G,'HelldiversSquadAIStage') or {}).StratagemFamilies
 if family then T.families=family(M,C,B,S,V,P,emit) end
 local A=Native(M,C,B,S,P,emit);T.native=A
 local store=rawget(_G,'HelldiversStratagemAllowances')
 if not store then store={missions=setmetatable({}, {__mode='k'})};rawset(_G,'HelldiversStratagemAllowances',store) end
 local function live(u)return u~=nil and Unit.alive(u)end
 local function state(u,n,master)
  if not live(u) then return end
  if master and EntityAux.has_component_master(u,n) then return EntityAux.state_master(u,n) end
  if not master and EntityAux.has_component(u,n) then return EntityAux.state(u,n) end
 end
 local function pos(u)
  if live(u) then return P.point(Unit.world_position(u,0)) end
 end
 local function inventory(u)return state(u,'inventory',true) or state(u,'inventory') or {} end
 local function config(u)
  if not live(u) or not LuaSettingsManager then return {} end
  local upgrade=state(u,'upgradeable',true) or state(u,'upgradeable') or {}
  local cached=T.resource_settings[u]
  if cached and cached.upgrade==upgrade.upgrade_value then return cached.settings end
  if LoadoutSettings and LoadoutSettings.get_upgraded_settings then
   local ok,a=pcall(LoadoutSettings.get_upgraded_settings,u)
   if ok and type(a)=='table' then T.resource_settings[u]={upgrade=upgrade.upgrade_value,settings=a};return a end
  end
  if LuaSettingsManager.get_settings_by_unit then return LuaSettingsManager:get_settings_by_unit(u) or {} end
  return {}
 end
 local function note(b,reason,data)
  b.tactical_notes=b.tactical_notes or {}
  if M.clock<(b.tactical_notes[reason] or 0) then return end
  b.tactical_notes[reason]=M.clock+5;data=data or {};data.reason=reason
  data.decision='deferred';data.phase=b.stratagem_intent and b.stratagem_intent.phase or 'evaluating'
  emit('stratagem_deferred',data,b.id,'behavior')
 end
 local function owned(u)
  for _,p in ipairs(M.session and M.session.players or {}) do local go=p.player_go
   if go and go:exists() and go:has('avatar_unit') and go:get('avatar_unit')==u then return true end
  end
 end
 local function path(u)
  if live(u) and type(Unit.get_data)=='function' then return Unit.get_data(u,'unit_path') end
 end
 function T.session(s)
  if T.session_id==s and T.level==s.generated_level then return end
  for _,t in ipairs(T.pending) do A.cancel(t,'mission_changed');A.finish(t) end
  T.session_id=s;T.level=s.generated_level;T.pending={};T.claims={};T.preparing=nil;T.next_scan=0;T.resources={};T.assets={};T.history=setmetatable({}, {__mode='k'})
  local saved=store.missions[s]
  T.ledger=saved and saved.level==T.level and saved.ledger or P.new_ledger()
  saved=saved and saved.level==T.level and saved or {level=T.level,ledger=T.ledger}
  store.missions[s]=saved;T.saved=saved;A.ledger=T.ledger
 end
 function T.end_session(s)
  store.missions[s]=nil
  if T.session_id==s then A.deliveries={} end
  if T.session_id==s then T.session_id=nil;T.level=nil;T.ledger=nil end
 end
 local function actor(u,protected,kind)
  local p=pos(u);if not p then return end
  local h=state(u,'health') or {};if h.is_dead then return end
  local old=T.history[u];local velocity={x=0,y=0}
  if old and M.clock>old.time then
   local dt=M.clock-old.time;velocity={x=(p.x-old.position.x)/dt,y=(p.y-old.position.y)/dt}
   if velocity.x^2+velocity.y^2>625 then velocity={x=0,y=0} end
  elseif old then velocity=old.velocity end
  T.history[u]={position=p,time=M.clock,velocity=velocity}
  local c=state(u,'character',true) or {}
  local radius=kind=='asset' and 2 or .8
  if c.current_seat_unit then
   local attached=state(c.current_seat_unit,'stationary_weapon',true) or {};local root=attached.attached_to_unit or c.current_seat_unit
   radius=2.5
   for _,h in ipairs(M.behaviors.vehicles or {}) do if h.unit==root then radius=math.max(radius,h.radius or 0) end end
  end
  return {unit=u,position=p,velocity=velocity,protected=protected,kind=kind,radius=radius,uncertainty=.25,
   max_uncertainty=0,uncertainty_growth=0,can_dodge=kind=='human' and not h.is_downed
    and not c.current_seat_unit and not c.current_carry_unit}
 end
 function T.refresh_actors(leader)
  T.protected_unknown=false
  local actors,seen={},{}
  local function add(u,priority,kind)
   if seen[u] then if priority then seen[u].protected=true end;return end
   local a=actor(u,priority,kind);if a then actors[#actors+1]=a;seen[u]=a
   elseif priority and live(u) and not (state(u,'health') or {}).is_dead then T.protected_unknown=true end
  end
  if leader then add(leader,true,'human') end
  for u in pairs(M.takeover and M.takeover.humans or {}) do add(u,true,'main') end
  for _,b in ipairs(M.bots) do if b.active then add(b.unit,M.is_original_body and M.is_original_body(b.unit),'bot') end end
  for _,u in ipairs(T.assets or {}) do add(u,true,'asset') end
  T.actors=actors
 end
 local function scan_resources(s,lp)
  T.resources={};T.assets={};T.asset_unknown=false
  for _,component in ipairs({'ammo_pickup','weapon_pickup','backpack_pickup','supply_crate','vehicle'}) do
   for u in pairs(B.entities(s,component)) do
    local a=state(u,component,true) or state(u,component);local p=pos(u)
    if a and p and P.distance(p,lp)<=32 then
     if component=='supply_crate' then
      if not a.is_empty then T.resources[#T.resources+1]={unit=u,component=component,position=p,state=a} end
     elseif component=='vehicle' then
      local h=state(u,'health') or {};if not h.is_dead then T.resources[#T.resources+1]={unit=u,component=component,position=p,state=a} end
     elseif a.enabled then
      local settings=config(u);local pi=a.pickup_info or settings.pickup_info or {}
      T.resources[#T.resources+1]={unit=u,component=component,position=p,state=a,
       weapon_path=pi.weapon_path,backpack_path=pi.backpack_path}
     end
    end
   end
  end
  for _,component in ipairs({'npc_escort','convoy_target','objective_defend_object','objective_fortify_object',
    'objective_interact_object','extract_beacon','droppoint','objective_carry_object'}) do
   for u in pairs(B.entities(s,component)) do local p=pos(u)
    if p then T.assets[#T.assets+1]=u
    elseif live(u) and not p then T.asset_unknown=true end
   end
  end
 end
 local function weapon_need(u,w,old,pressure,horizon)
  local a,profile=B.weapon(w);local total=P.ammunition(a,profile)
  old=old or {};local rate=old.weapon==w and old.rate or 0
  local record=A.shots[u];local shot=record and record.weapons[w];local used
  if old.weapon==w and shot and old.shot_total and shot.total>old.shot_total then used=shot.total-old.shot_total
  elseif old.weapon==w and old.rounds and type(a.rounds)=='number' and a.rounds<old.rounds then used=old.rounds-a.rounds end
  if used and M.clock>old.time then
   local observed=used/(M.clock-old.time)
   rate=rate>0 and rate*.65+observed*.35 or observed
  end
  local demand=P.demand(total,rate,horizon,pressure)
  return {weapon=w,rounds=a.rounds,total=total,rate=rate,time=M.clock,demand=demand,shot_total=shot and shot.total or 0,
   heat=profile.kind=='beam' or profile.kind=='arc' or a.heat~=nil}
 end
 local function ammo(u,pressure,horizon)
  local inv=inventory(u);local w=live(inv.primary_weapon) and inv.primary_weapon or inv.current_weapon
  local old=T.needs[u] or {};local need=weapon_need(u,w,old,pressure,horizon)
  if live(inv.support_weapon) then
   local support=weapon_need(u,inv.support_weapon,old.support,pressure,horizon);need.support=support
   local useful=inv.current_weapon==inv.support_weapon or need.total==0
   local primary=B.weapon(w)
   for _,target in ipairs(T.targets or {}) do if P.effectiveness(primary,target.health)==0 then useful=true;break end end
   if useful then need.demand=math.max(need.demand,support.demand) end
  end
  need.grenades=tonumber(inv.num_grenades)
  need.grenade_demand=need.grenades==0 and 1 or 0
  need.demand=math.max(need.demand,need.grenade_demand)
  T.needs[u]=need;return need.demand
 end
 local function free(b)
  local h=state(b.unit,'health');local c=state(b.unit,'character',true) or {};local inv=inventory(b.unit)
  local i=state(b.unit,'interactor',true) or {};local wa=B.weapon(inv.current_weapon)
  return b.active and h and not h.is_dead and not h.is_downed and not owned(b.unit)
   and not b.job and not b.objective and not b.vehicle_order and not b.guard_request and not b.post and not b.returning
   and not b.equipment_action and not b.stratagem_intent and not b.grenade_action and not b.tactical_job and not b.rejoin_probe and not b.rejoin_commit and not b.recovery_probe
   and not c.current_seat_unit and not c.current_carry_unit and not i.busy
   and not wa.is_reloading and not wa.charging and not live(inv.held_grenade)
 end
 function T.pressure(lp)
  local pressure,targets=0,{}
  for _,e in ipairs(M.enemy_cache or {}) do
   local p=pos(e.id);local h=state(e.id,'health');local hm=state(e.id,'health',true) or h
   if p and h and not h.is_dead and P.distance(p,lp)<=30 then
    local d=P.distance(p,lp);local weight=math.max(0,1-d/35)
    local heavy=hm and ((tonumber(hm.armor_min) or 0)>0)
    if heavy then weight=weight*2 end
    local old=T.enemy_motion[e.id];local velocity={x=0,y=0}
    if old and M.clock>old.time then
     local dt=M.clock-old.time;velocity={x=(p.x-old.position.x)/dt,y=(p.y-old.position.y)/dt}
     if velocity.x^2+velocity.y^2>400 then velocity={x=0,y=0} end
    end
    T.enemy_motion[e.id]={position=p,time=M.clock,velocity=velocity}
    pressure=pressure+weight;targets[#targets+1]={unit=e.id,position=p,velocity=velocity,health=hm,weight=weight,heavy=heavy}
   end
  end
  return pressure,targets
 end
 local function outputs(cap)
  if cap.outputs then return cap.outputs end
  cap.outputs={}
  local crate=cap.settings.supply_crate_info
  for _,content in ipairs(crate and crate.content or {}) do
   local ok,cfg=pcall(LuaSettingsManager.get_modified_settings,LuaSettingsManager,content.unit_path,cap.upgrade)
   local pi=ok and cfg and cfg.pickup_info
   if pi and (pi.weapon_path or pi.backpack_path) then cap.outputs[#cap.outputs+1]={weapon_path=pi.weapon_path,backpack_path=pi.backpack_path} end
  end
  return cap.outputs
 end
 local function matching(cap,r)
  for _,o in ipairs(outputs(cap)) do
   if o.weapon_path and o.weapon_path==r.weapon_path or o.backpack_path and o.backpack_path==r.backpack_path then return true end
  end
  return false
 end
 local function new_job(b,r,cap)
  T.job_serial=(T.job_serial or 0)+1
  local inv=inventory(b.unit)
  local job={kind='stratagem_pickup',component=r.component,unit=r.unit,position=r.position,target_position=r.position,
   key='tactical_pickup:'..T.job_serial,started=M.clock,cap=cap,before_primary=inv.primary_weapon,
   before_support=inv.support_weapon,before_backpack=inv.backpack}
  b.tactical_job=job;T.claims[r.unit]=b;S.cancel(b)
  emit('stratagem_retrieval_assigned',{stratagem=cap.name,target=tostring(r.unit),component=r.component},b.id)
  return job
 end
 function T.release_job(b,reason)
  local job=b.tactical_job;if not job then return end
  if T.claims[job.unit]==b then T.claims[job.unit]=nil end
  b.tactical_job=nil;S.cancel(b);b.tactical_retry=M.clock+3
  if reason=='interrupted_or_unreachable' then
   T.failed[job.unit]=T.failed[job.unit] or {};T.failed[job.unit][b.unit]=M.clock+12
  end
  emit('stratagem_retrieval_finished',{reason=reason,stratagem=job.cap.name},b.id)
 end
 function T.job(b,p,danger)
  local t=b.stratagem_intent
  if t and not t.finished and not t.detached and t.ticket.state=='reserved' then
   return {kind='stratagem_prepare',position=t.staging,target_position=t.staging,key='stratagem:'..t.ticket.serial,
    no_interaction=true,unit=b.unit,started=t.started}
  end
  local j=b.tactical_job;if not j then return end
  local inv=inventory(b.unit);local c=state(b.unit,'character',true) or {}
  local success=j.cap.policy.role=='backpack' and live(inv.backpack) and inv.backpack~=j.before_backpack
   or j.cap.policy.role=='weapon' and (j.cap.slot=='primary_weapon' and live(inv.primary_weapon) and inv.primary_weapon~=j.before_primary
    or j.cap.slot~='primary_weapon' and live(inv.support_weapon) and inv.support_weapon~=j.before_support)
  if success and j.cap.path and T.readiness then
   local item=j.cap.policy.role=='backpack' and inv.backpack or j.cap.slot=='primary_weapon' and inv.primary_weapon or inv.support_weapon
   success=T.readiness.is_item(item,j.cap.path)
  end
  if success then
   if T.readiness then T.readiness.collected(b,j) end
   if j.cap.slot~='primary_weapon' then b.preferred_support=inv.support_weapon end
   T.release_job(b,'inventory_confirmed');return
  end
  if T.readiness then local valid,why=T.readiness.job_valid(b,j);if not valid then T.release_job(b,why);return end end
  local a=state(j.unit,j.component,true) or state(j.unit,j.component)
  if not live(j.unit) or not a or not a.enabled then
   if j.attempted then
    j.result_wait=j.result_wait or M.clock+1
    if M.clock<j.result_wait then j.no_interaction=true;return j end
   end
   T.release_job(b,'taken_or_destroyed');return
  end
  if M.clock-j.started>18 or b.post or b.guard_request or b.objective or c.current_seat_unit or owned(b.unit)
    or (b.route and b.route.status=='failed') then T.release_job(b,'interrupted_or_unreachable');return end
  if danger then return end
  j.position=pos(j.unit);j.target_position=j.position
  return j
 end
 local function active_promise(role,b,target)
  for _,t in ipairs(T.pending) do
   if not t.finished and t.phase~='cancelled' and t.cap.policy.role==role then
    if role=='ammo' or (role=='strike' and t.target==target) or (role~='strike' and t.bot==b) then return true end
   end
  end
 end
 local function benefit(b,cap,pressure,targets)
  if T.families then local value,target=T.families.benefit(b,cap,pressure,targets);if value~=nil then return value,target end end
  local inv=inventory(b.unit);local role=cap.policy.role
  if role=='ammo' then
   if active_promise(role) then return 0 end
   local total=0;for u,n in pairs(T.needs) do if live(u) then total=total+n.demand*((owned(u) or (M.is_original_body and M.is_original_body(u))) and 2 or 1) end end
   return total*5
  end
  if role=='backpack' then
   if live(inv.backpack) or active_promise(role,b) then return 0 end
   local h=state(b.unit,'health') or {};local hp,max=tonumber(h.hitpoints_real or h.hitpoints),tonumber(h.max_hitpoints)
   local injured=hp and max and max>0 and math.max(0,1-hp/max) or 0
   return pressure>0 and math.min(5,pressure+injured*3) or 0
  end
  if role=='weapon' then
   if active_promise(role,b) then return 0 end
   if live(inv.support_weapon) then
    local a,pr=B.weapon(inv.support_weapon);if not B.dry(a) or pr.kind=='beam' or pr.kind=='arc' then return 0 end
   end
   return pressure>0 and math.min(7,pressure*1.4) or ((T.needs[b.unit] or {}).demand==1 and 3 or 0)
  end
  if role=='exo' or role=='emplacement' then
   if pressure<2 or active_promise(role,b) then return 0 end
   for _,r in ipairs(T.resources) do
    if r.component=='vehicle' and P.distance(r.position,pos(b.unit))<14 then
     local candidate=V.find(M.session,r.position,b)
     if candidate then return 0 end
    end
   end
   return math.min(8,pressure*1.2)
  end
  if role=='strike' then
   local best,score
   local current=B.weapon(inv.current_weapon)
   for _,target in ipairs(targets) do
    if not active_promise(role,b,target.unit) then
     local fit,reason=P.effectiveness(current,target.health);local value=0
     for _,other in ipairs(targets) do if P.distance(other.position,target.position)<=math.max(2,cap.envelope.blast or 3) then value=value+other.weight end end
     if reason=='known_armor_gap' then value=value+2 end
     local observed=A.performance(b.unit,target.unit)
     local hp=tonumber((target.health or {}).hitpoints_real or (target.health or {}).hitpoints)
     if observed and hp and observed.dps>0 then
      local to_squad=P.direction(target.position,M.player_anchor or (T.actors[1] or {}).position or target.position)
      local velocity=target.velocity or {};local closing=(velocity.x or 0)*to_squad.x+(velocity.y or 0)*to_squad.y
      local distance=P.distance(target.position,M.player_anchor or (T.actors[1] or {}).position or target.position)
      if closing>.1 and hp/observed.dps>distance/closing then value=value+1.5 end
     end
     -- Existing, ready anti-armor fire is a cheaper alternative than a call.
     for _,mate in ipairs(M.bots) do if mate.active then
      local mi=inventory(mate.unit);local wa=B.weapon(mi.support_weapon)
      local eff,why=P.effectiveness(wa,target.health)
      if live(mi.support_weapon) and not B.dry(wa) and why=='penetration_possible' and eff>0
       and mate.visibility and mate.visibility.clear and mate.target and mate.target.id==target.unit then value=value*.35;break end
     end end
     if value>2 and (not score or value>score) then best,score=target,value end
    end
   end
   if best then return score,best end
  end
  return 0
 end
 function T.safety(t,caller)
  if T.protected_unknown or T.asset_unknown or not P.point(caller) or not P.point(t.position) then return false,'protected_state_unknown' end
  local cap=t.cap;local warning=(cap.info.activation_time or 0)+(t.extra_activation or 0)+(cap.envelope.first or 0)
  local zone={position=t.position,radius=cap.envelope.radius,support=cap.envelope.support,
   prediction=.75,warning=warning,blast=cap.envelope.blast}
  if T.families then
   zone=T.families.zone(t);zone.warning=warning
   local safe,reason=T.families.safe(t,T);if not safe then return false,reason end
  end
  local clear,why,cost,dodging=P.safe(zone,T.actors,.75)
  t.warning_seconds=warning;t.dodging_players=dodging or 0
  if not clear then return false,why end
  for _,other in ipairs(T.pending) do if other~=t and not other.finished and other.phase~='cancelled' then
   local q=other.landed or other.position
   if P.distance(q,t.position)<other.cap.envelope.radius+cap.envelope.radius then return false,'deployment_overlap' end
  end end
  for _,h in ipairs(M.behaviors.hazards) do
   if h.source~='tactical_stratagem' and P.distance(t.position,h.position)<h.radius+zone.radius then return false,'existing_hazard' end
  end
  if zone.support then for _,h in ipairs(M.behaviors.vehicles or {}) do
   if B.vehicle_distance(h,t.position)<(h.radius or 0)+zone.radius then return false,'vehicle_delivery_overlap' end
  end end
  for _,h in pairs(M.landings or {}) do
   if h.id~=(t.ticket and 'stratagem:'..t.ticket.serial) and P.distance(t.position,h.position)<(h.radius or 4.5)+zone.radius then return false,'reserved_landing' end
  end
  for _,h in pairs(M.recovery and M.recovery.reservations or {}) do
   if (not h.expires or h.expires>M.clock) and P.distance(t.position,h.position)<zone.radius+3 then return false,'reserved_recovery_landing' end
  end
  return true,nil,cost
 end
 local function placement(b,cap,target,lp)
  local bp=pos(b.unit);if not bp then return end
  local profile=A.throw_profile(b,cap);local hand=A.throw_origin(b)
  local outward=P.direction(lp,target and target.position or bp)
  local radius=target and math.max(10.5,P.distance(lp,target.position)-12) or 10.5
  for n=target and -1 or 0,7 do
   local step=target and math.pi/12 or math.pi/3
   local a=math.atan2(outward.y,outward.x)+(n==0 and 0 or (n%2==1 and 1 or -1)*math.ceil(n/2)*step)
   local staging={x=lp.x+math.cos(a)*radius,y=lp.y+math.sin(a)*radius,z=bp.z}
   if n==-1 then staging=P.point(bp) end
   local side=a+(n%2==0 and 1 or -1)*math.pi/3
   local p=target and target.position or {x=lp.x+math.cos(side)*radius,y=lp.y+math.sin(side)*radius,z=staging.z}
   if target and n>=4 then
    local offset=math.min(3,(cap.envelope.blast or 3)*.6)*(n%2==0 and 1 or -1)
    p={x=target.position.x-outward.y*offset,y=target.position.y+outward.x*offset,z=target.position.z}
   end
   if hand then
    local origin={x=staging.x+hand.x-bp.x,y=staging.y+hand.y-bp.y,z=staging.z+hand.z-bp.z}
    local distance=P.distance(origin,p)
    local fit=P.fit_throw(distance,origin.z-p.z,profile.minimum,profile.maximum,profile.multiplier)
    if fit and not target then
     local direction=P.direction(origin,p)
     p={x=origin.x+direction.x*fit,y=origin.y+direction.y*fit,z=p.z}
    elseif fit and target and not P.throw_power(distance,origin.z-p.z,profile.minimum,profile.maximum,profile.multiplier) then
     local direction=P.direction(p,origin)
     staging={x=p.x+direction.x*fit-(hand.x-bp.x),y=p.y+direction.y*fit-(hand.y-bp.y),z=staging.z}
    end
   end
   local t={bot=b,cap=cap,position=P.point(p),staging=P.point(staging),target=target and target.unit,
    extra_activation=tonumber(inventory(b.unit).stratagem_extra_activation_time) or 0}
   if target then t.aim_offset={x=p.x-target.position.x,y=p.y-target.position.y} end
   local safe,_,cost=T.safety(t,staging)
   if safe and P.distance(staging,p)<=18 and P.distance(staging,bp)<=30 then
    t.preparation_seconds=12+P.distance(staging,bp)/2.5;return t,cost
   end
  end
 end
 local function known_supply(b)
  local p=pos(b.unit)
  for _,r in ipairs(T.resources) do
   if r.component=='ammo_pickup' and P.distance(p,r.position)<=12 and not B.danger(M.behaviors,r.position,b.unit) then
    -- A previous failed approach does not suppress a useful new drop forever.
    local key='ammo:'..tostring(r.unit)..':'
    if not M.behaviors.deferred[key] then return true end
   elseif r.component=='supply_crate' and P.distance(p,r.position)<=12 then return true end
  end
 end
 function T.plan(leader,lp,pressure,targets)
  if T.preparing or (M.grenades and M.grenades.active) or #T.pending>=16 or not A.ready or not leader or M.waiting_for_player then return end
  local best,score
  for _,b in ipairs(M.bots) do
   if free(b) and A.authorized(b.unit) and M.clock>=(b.tactical_retry or 0) then
    local inv=inventory(b.unit);local seen={}
    local evaluation={considered=0,gated=0,no_need=0,unavailable=0,no_safe_placement=0,below_threshold=0,candidates=0,exhausted=0}
    for _,entry in ipairs(inv.stratagems or {}) do
     if not seen[entry.id] then
      seen[entry.id]=true
      evaluation.considered=evaluation.considered+1
      local cap,why=A.capability(entry)
      local retry=b.stratagem_backoff and b.stratagem_backoff[entry.id]
      local waiting=retry and retry.until_time>M.clock
      if cap and not T.cap_status[cap.name] then
       T.cap_status[cap.name]=true
       emit('stratagem_capability',{stratagem=cap.name,enabled=cap.enabled,reason=cap.reason,upgrade=cap.upgrade},b.id)
      end
      if cap and not cap.enabled then evaluation.gated=evaluation.gated+1
      elseif cap and P.remaining(T.ledger,b.unit,cap.id)<=0 then evaluation.exhausted=evaluation.exhausted+1 end
      if waiting then
       evaluation.unavailable=evaluation.unavailable+1
       note(b,'retry_backoff',{stratagem=cap and cap.name,previous_reason=retry.reason,seconds_left=retry.until_time-M.clock})
      end
      if cap and cap.enabled and P.remaining(T.ledger,b.unit,cap.id)>0 and not waiting then
       local value,target,recipient,essential
       if T.readiness then value,target,recipient,essential=T.readiness.evaluate(b,cap,pressure) end
       if value==nil then value,target=benefit(b,cap,pressure,targets) end
       if T.readiness and not T.readiness.allow(b,cap,essential) then value=0;note(b,'call_reserved',{stratagem=cap.name}) end
       local supply=cap.policy.role=='ammo' and (T.readiness and T.readiness.known_supply(b) or not T.readiness and known_supply(b))
       if supply or not T.readiness and cap.policy.role=='weapon' and pressure<=0 and known_supply(b) then value=0 end
       if value<=0 then evaluation.no_need=evaluation.no_need+1 end
       local present=false
       if not T.readiness and value>0 and not b.tactical_job and (cap.policy.role=='weapon' or cap.policy.role=='backpack') then
        for _,r in ipairs(T.resources) do
         if not T.claims[r.unit] and not (T.failed[r.unit] and (T.failed[r.unit][b.unit] or 0)>M.clock)
          and P.distance(pos(b.unit),r.position)<=12 and matching(cap,r)
          and not B.danger(M.behaviors,r.position,b.unit) then new_job(b,r,cap);present=true;break end
        end
       end
       if value>0 and not present and not b.tactical_job then
        local available,reason=A.available(b,cap)
        if available then
         local t,casualties=placement(b,cap,target,lp)
         if t then
          t.recipient=recipient;t.essential=essential
          t.optional_preparation=T.readiness and T.readiness.quiet and not essential
          local travel=P.distance(pos(b.unit),t.staging)
          local utility=P.utility(value,casualties,P.remaining(T.ledger,b.unit,cap.id),travel,pressure*.1)
          if utility>1 and (not score or utility>score or utility==score and b.id<best.bot.id) then best,score=t,utility end
          if utility>1 then evaluation.candidates=evaluation.candidates+1 else evaluation.below_threshold=evaluation.below_threshold+1 end
         else evaluation.no_safe_placement=evaluation.no_safe_placement+1;note(b,'no_safe_preparation_or_landing',{stratagem=cap.name}) end
        else evaluation.unavailable=evaluation.unavailable+1;note(b,reason,{stratagem=cap.name}) end
       end
      elseif why then evaluation.unavailable=evaluation.unavailable+1;note(b,why) end
     end
    end
    if M.clock>=(b.next_tactical_evaluation or 0) then
     b.next_tactical_evaluation=M.clock+10
     evaluation.decision=evaluation.candidates>0 and 'candidate_available' or 'no_call'
     evaluation.pressure=pressure;emit('stratagem_evaluation',evaluation,b.id,'behavior')
    end
   end
  end
  if best and free(best.bot) then
   best.existing={};for _,r in ipairs(T.resources) do best.existing[r.unit]=true end
   best.ticket=P.reserve(T.ledger,best.bot.unit,best.cap.id)
   if best.ticket and A.start(best,T.ledger) then
    if T.readiness then T.readiness.reserve(best) end
    T.pending[#T.pending+1]=best;T.preparing=best;S.cancel(best.bot)
    best.utility=score
    emit('stratagem_selected',{transaction=best.ticket.serial,stratagem=best.cap.name,utility=score,
     staging=best.staging,position=best.position,target=best.target and tostring(best.target),
     safety_policy='responsive',warning_seconds=best.warning_seconds,dodging_players=best.dodging_players,
     remaining=P.remaining(T.ledger,best.bot.unit,best.cap.id)},best.bot.id)
   elseif best.ticket then P.refund(best.ticket) end
  end
 end
 function T.detach(b,reason)
  local t=b.stratagem_intent
  if t then A.cancel(t,reason);t.detached=true;b.stratagem_intent=nil;if T.preparing==t then T.preparing=nil end end
  T.release_job(b,reason)
 end
 function T.clear(reason)
  for _,t in ipairs(T.pending) do A.cancel(t,reason);A.finish(t) end
  T.pending={};T.preparing=nil;T.claims={}
  for _,b in ipairs(M.bots) do T.release_job(b,reason) end
  -- The separate mission/body ledger deliberately survives controller disable/reapply.
 end
 function T.reconcile(t)
  local ms=state(t.marker,'stratagem',true)
  if ms and ms.has_been_thrown then
   if P.commit(t.ticket) then t.committed=M.clock;t.phase='committed' end
   t.released=t.released or M.clock
   t.actual=pos(t.marker) or t.actual
   if ms.has_started_countdown then t.landed=t.actual;t.activation_started=t.activation_started or M.clock end
  end
  if t.phase=='cancelled' then
   if M.clock-(t.cancelled_at or t.started)>1 then A.finish(t) end;return
  end
  if t.held_guard then
   local inv=inventory(t.bot.unit);local h=state(t.bot.unit,'health') or {}
   if live(inv.held_grenade) and inv.held_grenade==t.marker and not h.is_dead and not h.is_downed and A.authorized(t.bot.unit) then
    if T.preparing==t then T.preparing=nil end
    return
   end
   t.held_guard=nil
  end
  if t.ticket.state=='reserved' and t.target then
   local target=pos(t.target);local health=state(t.target,'health')
   if not target or not health or health.is_dead then
    local replacement,best
    for _,candidate in ipairs(T.targets or {}) do if live(candidate.unit) and not (state(candidate.unit,'health') or {}).is_dead
     and P.distance(candidate.position,t.position)<=math.max(3,t.cap.envelope.blast or 3) then
     local count=0;for _,other in ipairs(T.targets) do if live(other.unit) and P.distance(candidate.position,other.position)<=math.max(3,t.cap.envelope.blast or 3) then count=count+(other.weight or 1) end end
     if count>2 and (not best or count>best) then replacement=candidate;best=count end
    end end
    if replacement then t.target=replacement.unit;t.position=P.point(replacement.position);t.aim_offset=nil
     emit('stratagem_retargeted',{transaction=t.ticket.serial,stratagem=t.cap.name},t.bot.id)
    else A.cancel(t,'target_gone') end
   elseif t.phase=='positioning' or t.phase=='radio' then
    local motion=T.enemy_motion[t.target];local velocity=motion and motion.velocity or {}
    local tau=(t.cap.info.activation_time or 0)+(t.cap.envelope.first or 0)+1.5
    local offset=t.aim_offset or {}
    t.position={x=target.x+(velocity.x or 0)*tau+(offset.x or 0),y=target.y+(velocity.y or 0)*tau+(offset.y or 0),z=target.z}
    if P.distance(t.staging,t.position)>18 then A.cancel(t,'target_left_throw_range') end
   end
  end
  if t.ticket.state=='reserved' and (not t.bot.active or not live(t.bot.unit) or M.clock-t.started>(t.preparation_seconds or 16)) then A.cancel(t,'preparation_expired') end
  if t.ticket.state=='spent' then
   if T.preparing==t then T.preparing=nil end
   local inv=inventory(t.bot.unit);local c=state(t.bot.unit,'character',true) or {}
   if inv.grenade_thrown or c.current_state~=CharacterStateStratagemsThrow then t.bot.stratagem_intent=nil end
   local base=t.activation_started or t.committed or t.started
   t.expires=base+(t.cap.info.activation_time or 0)+t.extra_activation+t.cap.envelope.duration+8
   if not t.observed then
    for _,r in ipairs(T.resources) do
     if not (t.existing or {})[r.unit] and P.distance(r.position,t.landed or t.position)<=8 then
      if t.cap.policy.role=='ammo' and r.component=='ammo_pickup'
       or (t.cap.policy.role=='weapon' or t.cap.policy.role=='backpack') and matching(t.cap,r)
       or not t.vehicle_record and (t.cap.policy.role=='exo' or t.cap.policy.role=='emplacement') and path(r.unit)==t.cap.info.unit then
       t.observed=r.unit
       t.delivery_safe=r.component~='vehicle'
       emit('stratagem_arrival_observed',{transaction=t.ticket.serial,stratagem=t.cap.name,position=r.position,unit=tostring(r.unit),
        evidence='new matching resource near marker; concurrent human delivery may also satisfy need'},t.bot.id)
       break
      end
     end
    end
   end
   if not (T.readiness and T.readiness.arrival(t)) and live(t.observed) and not t.detached and not t.retrieval_assigned and t.bot.active and not owned(t.bot.unit) and not t.bot.objective
    and not t.bot.job and not t.bot.post and not t.bot.guard_request and M.clock>=(t.next_retrieval or 0) then
    t.next_retrieval=M.clock+.5
    if t.cap.policy.role=='exo' or t.cap.policy.role=='emplacement' then
     local _,assigned=V.request(M.session,pos(t.observed),t.bot);t.retrieval_assigned=assigned==true
     t.delivery_safe=t.retrieval_assigned
    elseif t.cap.policy.role=='weapon' or t.cap.policy.role=='backpack' then
     for _,r in ipairs(T.resources) do if r.unit==t.observed and not t.bot.tactical_job and not T.claims[r.unit] then
      new_job(t.bot,r,t.cap);t.retrieval_assigned=true;break
     end end
    end
   end
   if M.clock>=t.expires then
    emit('stratagem_finished',{transaction=t.ticket.serial,stratagem=t.cap.name,arrival_observed=not not t.observed,
     result=t.observed and 'delivery_observed' or (t.cap.policy.role=='strike' and 'effect_window_elapsed' or 'arrival_not_observed')},t.bot.id)
    A.finish(t);t.bot.tactical_retry=M.clock+3
   end
  end
 end
 function T.tick(s,leader,lp)
  T.session(s);A.install();T.enabled=A.ready==true and not T.faulted and not A.faulted
  if T.families then T.families.tick() end
  if not A.ready then return end
  local scan=M.clock>=T.next_scan
  if scan then T.next_scan=M.clock+.5;scan_resources(s,lp) end
  T.refresh_actors(leader)
  if T.preparing then
   for _,a in ipairs(T.actors) do local h=state(a.unit,'health') or {}
    if a.protected and h.is_downed and T.preparing.cap.policy.role~='smoke' and T.preparing.cap.policy.role~='lure' then T.detach(T.preparing.bot,'protected_casualty');break end
   end
  end
  for i=#T.pending,1,-1 do local t=T.pending[i];T.reconcile(t);if t.finished then
   if T.preparing==t then T.preparing=nil end;table.remove(T.pending,i)
  end end
  for i=#M.behaviors.hazards,1,-1 do if M.behaviors.hazards[i].source=='tactical_stratagem' then table.remove(M.behaviors.hazards,i) end end
  for _,t in ipairs(T.pending) do
   local key='stratagem:'..t.ticket.serial
   if t.ticket.state=='reserved' and t.phase~='cancelled' then
    M.landings[key]={id=key,position=t.position,radius=t.cap.envelope.radius,expires=M.clock+1}
   else M.landings[key]=nil end
   if t.ticket.state=='spent' and not (t.cap.envelope.support and t.delivery_safe) then
    local p=t.actual or t.position
    M.behaviors.hazards[#M.behaviors.hazards+1]={position=p,radius=t.cap.envelope.radius,kind='incoming_stratagem',
     source='tactical_stratagem',height=3,expires=t.expires}
    if M.orders and M.orders.markers then M.orders.markers[key]={position=p,radius=t.cap.envelope.radius,
     kind='stratagem',expires=M.clock+1} end
   end
  end
  if scan then
   local pressure,targets=T.pressure(lp);T.current_pressure=pressure;T.targets=targets
   local horizon=20
   if leader then ammo(leader,pressure,horizon) end
   for _,b in ipairs(M.bots) do if b.active then ammo(b.unit,pressure,horizon) end end
   for u,b in pairs(T.claims) do if not live(u) or not b.active or not b.tactical_job or b.tactical_job.unit~=u then T.claims[u]=nil end end
   if T.readiness and T.enabled then T.readiness.update(leader,lp,pressure,targets) end
   if T.enabled then T.plan(leader,lp,pressure,targets) end
  end
 end
 function T.ammo_job(b,job)
  local need=T.needs[b.unit]
  if not need or need.demand<=0 then return false end
  -- Reserve the nearest available box for an ammo-starved human. AI main bodies
  -- can use the other boxes through the same native job system.
  local human_need
  for _,a in ipairs(T.actors) do if a.kind=='human' and a.unit~=b.unit then
   local n=T.needs[a.unit];if n and n.demand>0 then human_need=a;break end
  end end
  if human_need then
   local closest,d
   for _,r in ipairs(T.resources) do if r.component=='ammo_pickup' then
    local x=P.distance(human_need.position,r.position);if not d or x<d then closest=r.unit;d=x end
   end end
   if closest==job.unit then return false end
  end
  return true
 end
 function T.held_input(b,t,p,budget)
  local c=state(b.unit,'character',true) or {};local inv=inventory(b.unit)
  if not A.authorized(b.unit) or inv.held_grenade~=t.marker then return end
  local out=C.neutral();out.throw=not t.held_payload
  t.guard_session=t.guard_session or M.session;t.guard_generation=t.guard_generation or M.generation
  local origin=A.throw_origin(b);local profile=A.throw_profile(b,t.cap,t.marker)
  if not origin or not P.finite(profile.charge_time) or profile.charge_time<=0 then return out end
  if not t.held_payload and (not P.finite(c.throw_timer) or c.throw_timer<profile.charge_time) then return out end
  local power=t.held_payload and t.held_payload.power or profile.multiplier
  if not t.guard_landing then
   t.guard_side=((t.guard_side or -1)+1)%16
   local angle=t.guard_side*math.pi/8
   local range=P.throw_range(power,origin.z-p.z,profile.minimum,profile.maximum,1)
   if not range then return out end
   t.position={x=origin.x+math.cos(angle)*range,y=origin.y+math.sin(angle)*range,z=p.z}
   t.staging=P.point(p);t.throw_direction={x=math.cos(angle),y=math.sin(angle)}
   if T.safety(t,p) then t.guard_landing=true;t.ground_clear=nil;t.probe_pending=nil end
  end
  out.aim=P.direction(p,t.position)
  if t.guard_landing then
   if not T.safety(t,p) or t.ground_from and P.distance(p,t.ground_from)>.25 then
    t.guard_landing=nil;t.ground_clear=nil;t.probe_serial=(t.probe_serial or 0)+1;t.probe_pending=nil
   elseif not t.ground_clear and not t.probe_pending then
    t.probe_serial=(t.probe_serial or 0)+1;local serial=t.probe_serial;t.probe_pending=true;t.probe_started=M.clock
    local started=S.probe(b,p,t.position,budget,function(clear,ground)
     if t.finished or not t.held_guard or serial~=t.probe_serial or A.actions[b.unit]~=t
      or t.guard_session~=M.session or t.guard_generation~=M.generation then return end
     t.probe_pending=nil;t.ground_clear=clear;t.ground_from=P.point(p)
     if clear and P.point(ground) and math.abs(ground.z-t.position.z)<.2 then t.ground_target=P.point(ground)
     else t.guard_landing=nil;t.ground_clear=nil end
    end)
    if not started then t.probe_pending=nil end
   end
  end
  if t.probe_pending and M.clock-(t.probe_started or M.clock)>.9 then
   t.probe_pending=nil;t.guard_landing=nil;t.probe_serial=(t.probe_serial or 0)+1
  end
  local forward=Quaternion.forward(Unit.world_rotation(b.unit,0))
  if t.ground_clear and forward.x*out.aim.x+forward.y*out.aim.y>.998 and T.safety(t,p) then
   out.throw=false
   if t.held_payload and not t.release_queued then
    t.release_queued=M.clock;t.release_token={}
    EntityAux.queue_command_master(b.unit,'inventory','throw',{
     position=Vector3Aux.box({},Vector3(origin.x,origin.y,origin.z)),
     direction=Vector3Aux.box({},Vector3(out.aim.x,out.aim.y,1)),power=power,__hd_squad_deferred=t.release_token})
    emit('stratagem_deferred_release_requested',{transaction=t.ticket.serial,power=power},b.id)
   end
  end
  return out
 end
 function T.input(b,p,input,danger,budget)
  local held=A.actions[b.unit]
  if held and held.held_guard then local guarded=T.held_input(b,held,p,budget);if guarded then return guarded end end
  if not T.enabled then return input end
  local t=b.stratagem_intent
  if t then
   if danger or b.job and b.job.kind=='revive' or b.objective or b.post or b.guard_request then A.cancel(t,'priority_or_danger');return input end
   if t.phase=='positioning' then
    local gap=P.distance(p,t.staging)
    if not t.best_gap or gap<t.best_gap-.2 then t.best_gap=gap;t.progress_at=M.clock end
    if gap>.65 and M.clock-(t.progress_at or t.started)>1.5 and (t.preparation_changes or 0)<3 then
     local origin=A.throw_origin(b);local profile=A.throw_profile(b,t.cap)
     local power=origin and P.throw_power(P.distance(origin,t.position),origin.z-t.position.z,profile.minimum,profile.maximum,profile.multiplier)
     local old_position=t.position
     if not power and origin and not t.target then
      local fit=P.fit_throw(P.distance(origin,t.position),origin.z-t.position.z,profile.minimum,profile.maximum,profile.multiplier)
      if fit then local direction=P.direction(origin,t.position)
       t.position={x=origin.x+direction.x*fit,y=origin.y+direction.y*fit,z=t.position.z}
       power=P.throw_power(fit,origin.z-t.position.z,profile.minimum,profile.maximum,profile.multiplier)
      end
     end
     if power and T.safety(t,p) then
      S.cancel(b);t.staging=P.point(p);t.ground_clear=nil;t.probe_pending=nil;t.probe_serial=(t.probe_serial or 0)+1
      t.preparation_changes=(t.preparation_changes or 0)+1;t.progress_at=M.clock;t.best_gap=0
      t.preparation_seconds=math.min(30,math.max(t.preparation_seconds or 16,M.clock-t.started+6))
      emit('stratagem_preparation_reanchored',{transaction=t.ticket.serial,position=t.staging,previous_gap=gap},b.id)
     else t.position=old_position end
    end
   end
   if t.probe_pending and M.clock-(t.probe_started or M.clock)>.9 then
    t.probe_pending=nil;t.probe_serial=(t.probe_serial or 0)+1;t.probe_retries=(t.probe_retries or 0)+1
    emit('stratagem_clearance_retry',{transaction=t.ticket.serial,reason='callback_timeout',retry=t.probe_retries},b.id)
   end
   if t.ground_clear and t.ground_from and (P.distance(p,t.ground_from)>.4 or P.distance(t.position,t.ground_target)>.3) then t.ground_clear=nil end
   if t.phase=='positioning' and P.distance(p,t.staging)<.7 and not t.ground_clear and not t.probe_pending then
    t.probe_pending=true;t.probe_started=M.clock;t.probe_serial=(t.probe_serial or 0)+1
    local serial=t.probe_serial;local from=P.point(p);local target=P.point(t.position)
    local started=S.probe(b,p,t.position,budget,function(clear,ground,why)
     if serial~=t.probe_serial or b.stratagem_intent~=t or t.finished or t.ticket.state~='reserved' then return end
     t.probe_pending=nil;t.ground_clear=clear;t.ground_at=M.clock;t.ground_from=from;t.ground_target=target
     if clear and P.point(ground) then t.position=P.point(ground);t.ground_target=P.point(ground) end
     if not clear then A.cancel(t,why or 'deployment_ground_blocked') end
    end)
    if not started then t.probe_pending=nil end
   end
   if t.ground_clear and t.phase=='positioning' and M.clock-(t.ground_at or 0)>.6 then t.ground_clear=nil end
   local safe,why=T.safety(t,p)
   if safe and t.dodging_players>0 and not t.dodge_logged then
    t.dodge_logged=true;emit('stratagem_dodge_window',{transaction=t.ticket.serial,stratagem=t.cap.name,
     warning_seconds=t.warning_seconds,players=t.dodging_players,safety_policy='responsive'},b.id)
   end
   local gap=P.distance(p,t.staging)
   local velocity=(state(b.unit,'character',true) or {}).mover_state or {};velocity=velocity.velocity or {}
   t.readiness={phase=t.phase,staging_distance=gap,ground_clear=t.ground_clear==true,
    probe_pending=t.probe_pending==true,safe=safe==true,reason=why,
    speed=math.sqrt((velocity.x or 0)^2+(velocity.y or 0)^2)}
   if not safe then note(b,why,{stratagem=t.cap.name}) end
   b.release_permitted=false
   return A.input(t,p,input,safe)
  end
  local inv=inventory(b.unit);local support=inv.support_weapon
  local target=b.target and (state(b.target.id,'health',true) or state(b.target.id,'health')) or {}
  local heavy=(tonumber(target.armor_min or (target.health_info or {}).armor_min) or 0)>0
  local crowd=(T.current_pressure or 0)>=3
  if support==inv.current_weapon and live(support) then
   local _,profile=B.weapon(support)
   if profile.kind=='launcher' and not heavy and not crowd and live(inv.primary_weapon) and not B.dry(B.weapon(inv.primary_weapon)) then
    input.switch_weapon='switch_to_primary';input.fire=false;input.fire_auto=false
   end
  end
  if live(support) and support~=inv.current_weapon and not danger and not b.tactical_job and not b.job and not b.objective then
   local a,profile=B.weapon(support)
   if b.target and (profile.kind~='launcher' or heavy or crowd or B.dry(B.weapon(inv.primary_weapon)))
    and (not B.dry(a) or profile.kind=='beam' or profile.kind=='arc') then
    input.switch_weapon='switch_to_support';input.fire=false;input.fire_auto=false
   end
  end
  return input
 end
 function T.fail(err)
  T.faulted=true;T.enabled=false
  for _,t in ipairs(T.pending) do if t.ticket.state=='reserved' then
   local ok=pcall(A.cancel,t,'tactical_fault');if not ok then P.commit(t.ticket);t.committed=M.clock;t.phase='committed';t.detached=true end
  end end
  pcall(emit,'stratagem_ai_fault',{message=tostring(err),recovery='new calls disabled; ordinary squad behavior retained'},nil,'errors')
 end
 function T.guarded_input(b,p,input,danger,budget)
  local ok,value=pcall(T.input,b,p,input,danger,budget)
  if ok then return value end
  T.fail(value);return C.neutral()
 end
 function T.status()
  local enabled,disabled=0,0
  for _,p in pairs(P.policies) do if p.enabled then enabled=enabled+1 else disabled=disabled+1 end end
  return string.format('Stratagem AI: %s | %d policy-enabled / %d gated | incoming=%d | 2 calls/body/item\nCalls: %d commands / %d markers released / %d cancelled | last: %s',T.faulted and 'faulted; restart needed' or (T.enabled and 'active' or 'native adapter waiting'),enabled,disabled,#T.pending,A.stats.commands,A.stats.released,A.stats.cancelled,A.last_result or 'evaluating needs')
 end
 function T.uninstall()T.clear('unloaded');A.uninstall()end
 local factory=(rawget(_G,'HelldiversSquadAIStage') or {}).Readiness
 if factory then factory(M,C,B,S,V,T,P,A,emit,{state=state,pos=pos,inventory=inventory,config=config,
  owned=owned,path=path,free=free,new_job=new_job,note=note}) end
 return T
end
