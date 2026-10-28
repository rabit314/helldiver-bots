-- Shared recipients and quiet-period readiness. Native interactions perform all work.
return function(M,C,B,S,V,T,P,A,emit,H)
 if T.readiness then return T.readiness end
 local R={index={},next_index=0,quiet=false,vehicles={},replacement={},discarded=setmetatable({}, {__mode='k'})}
 T.readiness=R
 local state,pos,inventory,owned=H.state,H.pos,H.inventory,H.owned
 local function live(u)return u~=nil and Unit.alive(u)end
 local function settings(path,upgrade)
  if not path or not LuaSettingsManager or not LuaSettingsManager.get_modified_settings then return end
  local ok,cfg=pcall(LuaSettingsManager.get_modified_settings,LuaSettingsManager,path,upgrade or 0)
  if ok and type(cfg)=='table' then return cfg end
 end
 local function role(cap)return cap and cap.policy.role end
 function R.is_item(u,path)
  if not live(u) or not path then return false end
  if H.path(u)==path then return true end
  if type(Unit.is_a)=='function' then local ok,value=pcall(Unit.is_a,u,path);return ok and value==true end
  return false
 end
 function R.session()
  if R.saved==T.saved then return end
  R.saved=T.saved;R.saved.readiness=R.saved.readiness or {vehicles={},replacement={}}
  R.vehicles=R.saved.readiness.vehicles;R.replacement=R.saved.readiness.replacement
  R.started=M.clock;R.last_combat=M.clock;R.quiet=false;R.index={};R.next_index=0
 end
 function R.build_index()
  if M.clock<R.next_index then return end
  R.next_index=M.clock+5
  for _,item in ipairs(LoadoutSettings and LoadoutSettings.stratagems or {}) do
   local policy=P.policies[item.name]
   if policy and policy.enabled and (policy.role=='weapon' or policy.role=='backpack') then
    local cap=A.capability({id=item.id,upgrade_value=0})
    if cap and cap.enabled then for _,out in ipairs(cap.outputs or {}) do
     local path=out.weapon_path or out.backpack_path
     if path then
      local entry=R.index[path] or {name=cap.name,path=path,required_by={}}
      entry.policy=out.backpack_path and {role='backpack',enabled=true} or cap.policy
      entry.heat=cap.name=='stratagem_lasercannon';R.index[path]=entry
      if out.backpack_path then
       for _,weapon in ipairs(cap.outputs or {}) do if weapon.weapon_path then
        local cfg=settings(weapon.weapon_path,cap.upgrade);local required=cfg and (cfg.weapon_info or {}).self_reload_required_item
        if required==path then entry.required_by[weapon.weapon_path]=true end
       end end
      end
     end
    end end
   end
  end
  for _,item in ipairs(LoadoutSettings and LoadoutSettings.primary_weapon or {}) do
   if item.unit_path and item.group~='support' and item.group~='support_non_lethal' and item.group~='melee' then
    R.index[item.unit_path]={name=item.name,path=item.unit_path,slot='primary_weapon',policy={role='weapon',enabled=true},
     heat=item.group=='laserrifle' or item.group=='arcrifle'}
   end
  end
 end
 function R.describe(resource)
  local path=resource.weapon_path or resource.backpack_path;local base=path and R.index[path]
  if not base then return end
  local up=state(resource.unit,'upgradeable',true) or state(resource.unit,'upgradeable') or {}
  local upgrade=tonumber(up.upgrade_value or resource.state.upgrade_value) or 0
  local cfg=settings(path,upgrade);if not cfg then return end
  local rounds,mags=resource.state.num_rounds,resource.state.num_mags
  local capacity=tonumber((cfg.weapon_info or {}).magazine_capacity)
  if role(base)=='weapon' and not base.heat and capacity and capacity>0 and rounds==0 and mags==0 then return end
  return {name=base.name,policy=base.policy,path=path,settings=cfg,upgrade=upgrade,ground=true,slot=base.slot,required_by=base.required_by}
 end
 function R.weapon(cap)
  if cap.path then return cap.settings end
  for _,out in ipairs(cap.outputs or {}) do if out.weapon_path then return settings(out.weapon_path,cap.upgrade) end end
 end
 local function usable(unit)
  if not live(unit) then return false end
  local a,profile=B.weapon(unit)
  return profile.kind~='none' and not B.dry(a)
 end
 function R.human_claim(resource)
  for _,actor in ipairs(T.actors) do if actor.kind=='human' then
   local i=state(actor.unit,'interactor',true) or state(actor.unit,'interactor') or {}
   if i.interactable_unit==resource.unit or P.distance(actor.position,resource.position)<=1.6 then return true end
  end end
  return false
 end
 function R.value(b,cap,pressure)
  if M.equipment then local value=M.equipment.need(b,cap,pressure);if value~=nil then return value,value>=6 end end
  local inv=inventory(b.unit);local kind=role(cap);local need=T.needs[b.unit] or {}
  if kind=='backpack' then
   local weapon=inv.support_weapon;local weapon_path=H.path(weapon)
   if cap.required_by and next(cap.required_by) then
    local cfg=live(weapon) and H.config(weapon) or {};local required=(cfg.weapon_info or {}).self_reload_required_item
    if (weapon_path and cap.required_by[weapon_path] or required==cap.path) and not R.is_item(inv.backpack,cap.path) then return 9,true end
    return 0
   end
   if live(inv.backpack) then return 0 end
   return R.quiet and 4 or pressure>0 and math.min(5,pressure+1) or 0,false
  end
  if kind~='weapon' then return 0 end
  local current=inv[cap.slot or 'support_weapon'];local effective=usable(current)
  local candidate=R.weapon(cap);if not candidate then return 0 end
  local cw=candidate.weapon_info or candidate
  local known_gain=false
  local present=live(current) and B.weapon(current) or B.weapon(inv.primary_weapon)
  for _,target in ipairs(T.targets or {}) do
   local fit,why=P.effectiveness(present,target.health);local better,bwhy=P.effectiveness(cw,target.health)
   if why=='known_armor_gap' and bwhy=='penetration_possible' and better>fit then known_gain=true;break end
  end
  if not known_gain and R.quiet and R.recent_armor and M.clock-R.recent_armor.time<60 then
   local fit,why=P.effectiveness(present,R.recent_armor.health);local better,bwhy=P.effectiveness(cw,R.recent_armor.health)
   known_gain=why=='known_armor_gap' and bwhy=='penetration_possible' and better>fit
  end
  local essential=known_gain or live(current) and not effective
  if effective and not known_gain then return 0 end
  if not essential and M.clock<(b.gear_swap_until or 0) then return 0 end
  if known_gain then return 8,true end
  if not effective and live(current) then return 6,true end
  if R.quiet then return 4,false end
  if pressure>0 then return math.min(7,pressure*1.4),false end
  return need.demand==1 and 3 or 0,need.demand==1
 end
 function R.promised(cap,b)
  for _,t in ipairs(T.pending) do if not t.finished and t.phase~='cancelled' and role(t.cap)==role(cap) then
   if role(cap)=='ammo' then return true end
   if t.recipient==b or t.cap.name==cap.name and (not t.recipient or not t.recipient.active or not live(t.recipient.unit)) then return true end
  end end
  return false
 end
 function R.recipient(cap,pressure)
  local best,value,essential
  for _,b in ipairs(M.bots) do if H.free(b) and M.clock>=(b.tactical_retry or 0) and not R.promised(cap,b)
   and pos(b.unit) and P.distance(pos(b.unit),R.leader_position)<=14 then
   local v,e=R.value(b,cap,pressure)
   if v>0 and (not value or v>value or v==value and b.id<best.id) then best,value,essential=b,v,e end
  end end
  return best,value or 0,essential
 end
 function R.job_valid(b,j)
  local h=state(b.unit,'health') or {};local lp=M.player_anchor or R.leader_position
  if not b.active or h.is_dead or h.is_downed or owned(b.unit) then return false,'recipient_unavailable' end
  if lp and pos(j.unit) and P.distance(lp,pos(j.unit))>18 then return false,'squad_departed' end
  for _,r in ipairs(T.resources) do if r.unit==j.unit and R.human_claim(r) then return false,'human_priority' end end
  for _,a in ipairs(T.actors) do if a.kind~='asset' and (state(a.unit,'health') or {}).is_downed
   and (a.protected or P.distance(a.position,pos(b.unit))<=18) then return false,'friendly_casualty' end end
  return true
 end
 function R.collected(b,j)
  b.gear_swap_until=M.clock+8
  local old=j.cap.policy.role=='weapon' and (j.cap.slot=='primary_weapon' and j.before_primary or j.before_support) or j.before_backpack
  if live(old) then
   local path=H.path(old);if path then b.gear_discarded=b.gear_discarded or {};b.gear_discarded[path]=M.clock+20 end
  end
  R.kit(b)
 end
 function R.kit(b)
  local inv=inventory(b.unit);local weapon=inv.support_weapon;local path=H.path(weapon)
  local cfg=live(weapon) and H.config(weapon) or {};local required=(cfg.weapon_info or {}).self_reload_required_item
  if not required and path then cfg=settings(path,0);required=cfg and (cfg.weapon_info or {}).self_reload_required_item end
  if not required then b.required_kit=nil;return end
  local complete=R.is_item(inv.backpack,required)
  local old=b.required_kit
  if not old or old.weapon~=weapon or old.complete~=complete then
   b.required_kit={weapon=weapon,backpack_path=required,complete=complete}
   emit(complete and 'paired_kit_complete' or 'paired_kit_incomplete',{weapon=path,backpack=required},b.id)
  end
 end
 function R.reuse(leader,lp,pressure)
  local best,score,chosen,capability
  for _,r in ipairs(T.resources) do if (r.component=='weapon_pickup' or r.component=='backpack_pickup')
   and not T.claims[r.unit] and P.distance(r.position,lp)<=14 and not R.human_claim(r) and not B.danger(M.behaviors,r.position) then
   local cap=R.describe(r)
   if cap then for _,b in ipairs(M.bots) do if H.free(b) and M.clock>=(b.tactical_retry or 0)
    and not (T.failed[r.unit] and (T.failed[r.unit][b.unit] or 0)>M.clock) then
    local distance=P.distance(pos(b.unit),r.position);local value,essential=R.value(b,cap,pressure)
    local discard=b.gear_discarded and b.gear_discarded[cap.path]
    if distance<=12 and value>0 and (essential or not discard or discard<=M.clock) then
     local utility=value-distance*.08
     if not score or utility>score or utility==score and b.id<best.id then best,score,chosen,capability=b,utility,r,cap end
    end
   end end end
  end end
  if best then H.new_job(best,chosen,capability);return true end
 end
 function R.capacity()
  local seen,count={},0
  local function add(u)
   local h=state(u,'health');if live(u) and h and not h.is_dead and not seen[u] then seen[u]=true;count=count+1 end
  end
  for _,a in ipairs(T.actors) do if a.kind=='human' or a.kind=='bot' or a.kind=='main' then add(a.unit) end end
  return count>=5 and 2 or 1,1,count
 end
 local function kind_of(t)return role(t.cap)=='exo' and 'exo' or role(t.cap)=='tank' and 'tank' end
 local function credit(kind)
  local value=R.replacement[kind];return type(value)=='number' and value or value==true and 1 or 0
 end
 local function adjust_credit(kind,delta)
  local value=math.max(0,credit(kind)+delta);R.replacement[kind]=value>0 and value or nil
 end
 function R.reserve(t)
  local kind=kind_of(t);if not kind then return end
  local serial=tostring(M.generation)..':'..tostring(t.ticket.serial)..':'..tostring(t.started)
  local rec={kind=kind,transaction=t,tag=serial,state='reserved',session=M.session,level=T.level}
  if t.essential and credit(kind)>0 then rec.replacement_credit=true;adjust_credit(kind,-1) end
  R.vehicles[#R.vehicles+1]=rec;t.vehicle_record=rec
 end
 function R.delivered(t,unit)
  local rec=t and t.vehicle_record
  if not rec or rec.session~=M.session or rec.level~=T.level or not live(unit) then return end
  rec.unit=unit;rec.state='arrived';t.observed=unit;t.delivery_safe=false;t.provenance=true
  emit('readiness_vehicle_arrived',{transaction=t.ticket.serial,kind=rec.kind,unit=tostring(unit),evidence='native transaction spawn data'},t.bot.id)
 end
 local function vehicle_usable(u)
  local health=state(u,'health') or {};local vs=state(u,'vehicle',true) or state(u,'vehicle') or {}
  if health.is_dead or health.is_downed then return false,'destroyed_or_disabled' end
  local spawning={rawget(_G,'ExosuitStateSpawning'),rawget(_G,'ApcStateSpawning'),rawget(_G,'MannableTurretStateSpawning')}
  for _,s in pairs(spawning) do if vs.current_state==s then return true end end
  local weapons,seen={},{}
  local function add(w)if live(w) and not seen[w] and EntityAux.has_interface(w,'weapon') then seen[w]=true;weapons[#weapons+1]=w end end
  add(u)
  for su in pairs(B.entities(M.session,'seat')) do
   local sw=state(su,'stationary_weapon',true) or {}
   if su==u or sw.attached_to_unit==u then
    add(su);local seats=state(su,'seat',true) or state(su,'seat') or {}
    for _,w in ipairs(seats.seat_weapon_units or {}) do add(w) end
   end
  end
  local known_empty=#weapons>0
  for _,w in ipairs(weapons) do local a=B.weapon(w);if not B.dry(a) then known_empty=false;break end end
  if known_empty then return false,'ammunition_exhausted' end
  return true
 end
 R.vehicle_usable=vehicle_usable
 function R.vehicle_count(kind)
  local count=0
  for _,rec in ipairs(R.vehicles) do
   local t=rec.transaction
   if rec.state~='unavailable' then
    if rec.state=='reserved' and t.ticket.state=='cancelled' then
     rec.state='cancelled';if rec.replacement_credit then adjust_credit(rec.kind,1);rec.replacement_credit=nil end
    elseif rec.unit then
     local useful,why
     if live(rec.unit) then useful,why=vehicle_usable(rec.unit) end
     if not live(rec.unit) or not useful then
      rec.state='unavailable';rec.reason=why or 'native_removed';adjust_credit(rec.kind,1)
      emit('readiness_vehicle_unavailable',{kind=rec.kind,reason=rec.reason,unit=tostring(rec.unit)})
     end
    end
   end
   if rec.kind==kind and rec.state~='cancelled' and rec.state~='unavailable' then count=count+1 end
  end
  return count
 end
 local function vehicle_present(kind,lp)
  for _,r in ipairs(T.resources) do if r.component=='vehicle' and P.distance(r.position,lp)<=14 then
   local v=state(r.unit,'vehicle',true) or r.state;local k=(v.vehicle_info or {}).vehicle_type
   local fits=kind=='exo' and k=='exosuit' or kind=='tank' and (k=='apc' or k=='bike') and M.mobility and M.mobility.bot_delivery(r.unit)
   if fits and vehicle_usable(r.unit) then
    local seat=V.find and V.find(M.session,r.position,nil,{unit=r.unit,automatic=true})
    if seat then return true end
   end
  end end
  return false
 end
 function R.evaluate(caller,cap,pressure)
  local kind=role(cap)
  if kind=='strike' or kind=='field' or kind=='denial' or kind=='turret' or kind=='smoke' or kind=='lure' or kind=='recon' or kind=='objective' then return end
  if R.casualty then return 0 end
  if kind=='weapon' or kind=='backpack' then
   local recipient,value,essential=R.recipient(cap,pressure)
   return value,nil,recipient,essential
  end
  if kind=='ammo' then
   local total=0;local essential=false
   for u,n in pairs(T.needs) do local h=state(u,'health')
    if live(u) and h and not h.is_dead and pos(u) and P.distance(pos(u),R.leader_position)<=32 then
     total=total+(n.demand or 0)*(owned(u) and 2 or 1);essential=essential or (n.demand or 0)>0
    end
   end
   if R.promised(cap) then return 0 end
   return total*5,nil,nil,essential
  end
  if kind=='exo' or kind=='tank' then
   if not A.provenance_ready then return 0 end
   local exos,tanks=R.capacity();local cap_count=kind=='exo' and exos or tanks
   if R.vehicle_count(kind)>=cap_count or vehicle_present(kind,R.leader_position) then return 0 end
   if not R.quiet and pressure<2 then return 0 end
   local recipient
   if kind=='exo' or kind=='tank' then
    for _,b in ipairs(M.bots) do if H.free(b) and pos(b.unit) and P.distance(pos(b.unit),R.leader_position)<=14 then recipient=b;break end end
    if not recipient then return 0 end
   end
   return R.quiet and 4 or math.min(8,pressure*1.2),nil,recipient,credit(kind)>0
  end
  if kind=='emplacement' then
   if pressure<2 then return 0 end
   return nil
  end
  return 0
 end
 function R.allow(caller,cap,essential)
  if R.quiet and P.remaining(T.ledger,caller.unit,cap.id)==1 and not essential then return false,'call_reserved' end
  return true
 end
 function R.known_supply(b)
  for _,r in ipairs(T.resources) do if r.component=='ammo_pickup' and P.distance(pos(b.unit),r.position)<=12
   and not B.danger(M.behaviors,r.position,b.unit) then
   local key='ammo:'..tostring(r.unit)..':'
   if not M.behaviors.deferred[key] then return true end
  end end
  return false
 end
 function R.quiet_ammo(unit)
  local need=T.needs[unit];if not need or not R.quiet then return end
  local function adjust(n)
   if not n or n.heat or n.total==nil then return end
   local a=B.weapon(n.weapon);local cap=tonumber(a.magazine_capacity or (a.weapon_info or {}).magazine_capacity)
   if not cap or cap<=0 then return end
   local max_mags=tonumber(a.magazines_max);local target=(n.rate or 0)>0 and math.max(cap,n.rate*20) or cap*2
   if max_mags then target=math.min(target,cap*(max_mags+1)) end
   n.preparation_target=target
   n.demand=math.max(n.demand or 0,math.max(0,math.min(1,(target-n.total)/math.max(1,target))))
  end
  adjust(need);adjust(need.support)
  if need.support then need.demand=math.max(need.demand,need.support.demand or 0) end
 end
 function R.update(leader,lp,pressure,targets)
  R.session();R.leader=leader;R.leader_position=lp;R.build_index()
  if pressure>0 or (A.last_combat or -math.huge)>R.last_combat then R.last_combat=M.clock end
  local function firing(u)
   local a=B.weapon(inventory(u).current_weapon);local input=(state(u,'character',true) or {}).input or {}
   if a.firing_auto or a.firing_single or a.charging or input.fire or input.fire_auto then R.last_combat=M.clock end
  end
  if leader then firing(leader) end
  for _,b in ipairs(M.bots) do if b.active then firing(b.unit) end end
  R.quiet=M.clock-R.last_combat>=8
  R.casualty=false
  for _,a in ipairs(T.actors) do if a.kind~='asset' and (state(a.unit,'health') or {}).is_downed then R.casualty=true;break end end
  for _,target in ipairs(targets) do if target.heavy then R.recent_armor={time=M.clock,health=target.health};break end end
  for _,a in ipairs(T.actors) do R.quiet_ammo(a.unit) end
  for _,b in ipairs(M.bots) do if b.active then R.kit(b) end end
  for _,b in ipairs(M.bots) do if b.tactical_job then
   local valid,why=R.job_valid(b,b.tactical_job);if not valid then T.release_job(b,why) end
  end end
  if T.preparing and T.preparing.ticket.state=='reserved' then
   local t=T.preparing
   if t.optional_preparation and (not R.quiet or R.casualty or P.distance(lp,t.position)>18) then
    A.cancel(t,R.casualty and 'friendly_casualty' or not R.quiet and 'combat_reassessment' or 'squad_departed')
   end
  end
  R.vehicle_count('exo');R.vehicle_count('tank')
  for i=#R.vehicles,1,-1 do local rec=R.vehicles[i]
   if rec.state=='unavailable' or rec.state=='cancelled' then
    A.deliveries[rec.tag]=nil;table.remove(R.vehicles,i)
   elseif rec.unit and live(rec.unit) and V.find and V.find(M.session,pos(rec.unit),nil,{unit=rec.unit}) then
    rec.transaction.delivery_safe=true
   end
  end
  if not R.casualty then R.reuse(leader,lp,pressure) end
  if V.policy and not R.casualty then V.policy.assign(leader,lp,pressure,T.resources) end
 end
 function R.arrival(t)
  -- All ground deliveries are handled by the shared resource scan. Vehicle
  -- identity is established only by native spawn data, never by proximity.
  if t.vehicle_record then return true end
  return role(t.cap)=='weapon' or role(t.cap)=='backpack' or role(t.cap)=='emplacement'
 end
 return R
end
