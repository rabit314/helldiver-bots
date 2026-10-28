-- Scoped native command entry and reconciliation; never creates the final drop.
return function(M,C,B,S,P,emit)
 if M.stratagem_native then return M.stratagem_native end
 local A={actions={},contexts=setmetatable({}, {__mode='k'}),hooks={},cache={},profiles=setmetatable({}, {__mode='k'}),stats={commands=0,released=0,cancelled=0},
  shots=setmetatable({}, {__mode='k'}),damage=setmetatable({}, {__mode='k'}),deliveries={}}
 M.stratagem_native=A
 local function live(u)return u~=nil and Unit.alive(u)end
 local function state(u,n,master)
  if not live(u) then return end
  if master and EntityAux.has_component_master(u,n) then return EntityAux.state_master(u,n) end
  if not master and EntityAux.has_component(u,n) then return EntityAux.state(u,n) end
 end
 local function human(u)
  for _,p in ipairs(M.session and M.session.players or {}) do
   local go=p.player_go
   if go and go:exists() and go:has('avatar_unit') and go:get('avatar_unit')==u then return true end
  end
 end
 function A.authorized(u)
  local b=M.units[u];local h=state(u,'health');local c=state(u,'character',true)
  return not A.faulted and M.enabled and b and b.active and M.bot_origins[u] and not human(u)
   and not (M.is_original_body and M.is_original_body(u)) and h and not h.is_dead and not h.is_downed
   and c and not c.current_seat_unit and not c.current_carry_unit
 end
 function A.capability(entry)
  if not entry or not LoadoutSettings or not LoadoutSettings.get_upgraded_stratagem then return nil,'catalog_unavailable' end
  local upgrade=entry.upgrade_value or 0;local key=tostring(entry.id)..':'..tostring(upgrade)
  if A.cache[key] then return A.cache[key] end
  local ok,info=pcall(LoadoutSettings.get_upgraded_stratagem,entry.id,upgrade)
  if not ok or not info or not info.name then return nil,'native_upgrade_unavailable' end
  local policy=P.policies[info.name]
  if not policy then return nil,'unrecognized_stratagem' end
  local result={id=entry.id,upgrade=upgrade,name=info.name,policy=policy,info=info,enabled=false}
  if not policy.enabled then result.reason=policy.reason;A.cache[key]=result;return result end
  if not LuaSettingsManager or type(LuaSettingsManager.get_modified_settings)~='function' or not info.unit then return nil,'settings_not_ready' end
  local good,settings=pcall(LuaSettingsManager.get_modified_settings,LuaSettingsManager,info.unit,upgrade)
  if not good or type(settings)~='table' then return nil,'settings_not_ready' end
  local envelope,reason=P.envelope(setmetatable({upgrade_value=upgrade},{__index=info}),settings)
  result.settings=settings;result.envelope=envelope;result.reason=reason;result.enabled=envelope~=nil
  if result.enabled and (policy.role=='weapon' or policy.role=='backpack') then
   result.outputs={}
   for _,content in ipairs((settings.supply_crate_info or {}).content or {}) do
    local good,cfg=pcall(LuaSettingsManager.get_modified_settings,LuaSettingsManager,content.unit_path,upgrade)
    local pi=good and cfg and cfg.pickup_info
    if pi and (pi.weapon_path or pi.backpack_path) then
     result.outputs[#result.outputs+1]={weapon_path=pi.weapon_path,backpack_path=pi.backpack_path}
    end
   end
   if #result.outputs==0 then return nil,'native_pickup_contents_not_ready' end
  end
  if envelope and type(info.combo)~='table' then result.enabled=false;result.reason='native_combo_unavailable' end
  A.cache[key]=result;return result
 end
 function A.available(b,cap)
  if not A.authorized(b.unit) then return false,'caller_not_eligible' end
  if not cap or not cap.enabled then return false,cap and cap.reason or 'capability_unavailable' end
  local c=state(b.unit,'character',true) or {};local inv=state(b.unit,'inventory',true) or state(b.unit,'inventory') or {}
  if c.stratagems_disabled or live(inv.held_grenade) then return false,'native_action_or_restriction' end
  local found
  for _,entry in ipairs(inv.stratagems or {}) do if entry.id==cap.id then
   if (entry.upgrade_value or 0)==cap.upgrade and not entry.blocked and (entry.cooldown_timer or 0)<=0 and (entry.uses_left==nil or entry.uses_left>0) then found=true end
  end end
  if not found then return false,'native_slot_unavailable' end
  local context=A.contexts[b.unit]
  if not context or not A.original_can_use or not context.component.hud then return false,'native_character_context_not_ready' end
  local ok,value=pcall(A.original_can_use,context.component,b.unit,cap.id)
  return ok and value==true,ok and 'native_availability_rejected' or 'native_availability_error'
 end
 local function hook(object,key,factory)
  if type(object)~='table' or type(object[key])~='function' then return false end
  local old=object[key];local wrapper=factory(old);object[key]=wrapper
  A.hooks[#A.hooks+1]={object=object,key=key,old=old,wrapper=wrapper};return true
 end
 local function committed(t,why)
  if P.commit(t.ticket) then
   t.committed=M.clock;t.phase='committed'
   emit('stratagem_committed',{transaction=t.ticket.serial,stratagem=t.cap.name,reason=why,
    remaining=P.remaining(A.ledger,t.bot.unit,t.cap.id)},t.bot.id)
  end
 end
 function A.hold_marker(t,reason,payload)
  local c=state(t.bot.unit,'character',true) or {}
  committed(t,reason);t.held_guard=true;t.detached=true;t.guard_landing=nil;t.ground_clear=nil;t.probe_pending=nil
  t.guard_session=M.session;t.guard_generation=M.generation
  t.probe_serial=(t.probe_serial or 0)+1
  if payload then t.held_payload={power=payload.power};t.release_queued=nil end
  if c.input then c.input.throw=true;c.input.fire=false end
  emit('stratagem_marker_held',{transaction=t.ticket.serial,stratagem=t.cap.name,reason=reason},t.bot.id)
 end
 local function fault(purpose,err)
  A.faulted=true
  if M.tactics and M.tactics.fail then pcall(M.tactics.fail,err) end
  if M.clock>=(A.next_fault or 0) then A.next_fault=M.clock+5
   pcall(emit,'stratagem_native_adapter_error',{purpose=purpose,message=tostring(err),recovery='new AI calls disabled'},nil,'errors')
  end
 end
 local function command_input(u,e,t)
  local a=e.state;local input=a.input or {}
  if not A.authorized(u) or a.stratagems_disabled or t.phase~='radio' then return end
  local direction=t.cap.info.combo[t.key or 1]
  if direction and input['stratagem_'..direction] and t.pulse and t.received~=t.pulse then
   array.insert_end(a.stratagems_queue,direction);t.received=t.pulse
  end
 end
 local function observe_inventory(t,u,e,name,data)
  if not live(u) then return end
  local inv=e.state
  if name=='use_stratagem' and data==t.cap.id and t.ticket.state=='reserved' and t.phase~='cancelled' and live(inv.held_grenade) then
   t.marker=inv.held_grenade;t.ready_at=M.clock;t.phase='ready'
   local marker_state=state(t.marker,'stratagem',true) or {}
   t.extra_activation=math.max(t.extra_activation or 0,tonumber(marker_state.extra_activation_time) or 0)
   emit('stratagem_marker_ready',{transaction=t.ticket.serial,stratagem=t.cap.name},t.bot.id)
  elseif name=='throw_stratagem' and data==t.cap.id then committed(t,'native_consumption')
  elseif name=='throw' and t.marker and inv.held_grenade==t.marker and inv.grenade_thrown then
   committed(t,'native_marker_release')
   if not t.released then
    t.released=M.clock;A.stats.released=A.stats.released+1;A.last_result='marker released'
    if t.bot.stratagem_backoff then t.bot.stratagem_backoff[t.cap.id]=nil end
    emit('stratagem_released',{transaction=t.ticket.serial,stratagem=t.cap.name,
     phase=t.phase,evidence='native_inventory_marker_release'},t.bot.id)
   end
  elseif name=='cancel_stratagem' and not live(inv.held_grenade) and t.ticket.state=='reserved' then
   P.refund(t.ticket);t.phase='cancelled';t.cancelled_at=M.clock
  end
 end
 local function observe_activation(t,info,p,marker)
  if t.marker==marker and info and info.id==t.cap.id then
   t.landed=P.point(p);t.activation_started=M.clock;committed(t,'native_activation')
   emit('stratagem_pre_activated',{transaction=t.ticket.serial,stratagem=t.cap.name,position=t.landed},t.bot.id)
  end
 end
 local function observe_shot(u,count)
  if (M.units[u] or human(u)) and P.finite(count) and count>0 then A.last_combat=M.clock end
  if not M.units[u] or human(u) or not P.finite(count) or count<=0 then return end
  local rec=A.shots[u] or {total=0,weapons=setmetatable({}, {__mode='k'})};A.shots[u]=rec;rec.total=rec.total+count;rec.time=M.clock
  local inv=state(u,'inventory',true) or state(u,'inventory') or {};local w=inv.current_weapon
  if live(w) then local s=rec.weapons[w] or {total=0};rec.weapons[w]=s;s.total=s.total+count;s.time=M.clock end
 end
 local function observe_damage(target,data)
  if type(data)~='table' or not P.finite(data.damage) or data.damage<=0 then return end
  if M.units[target] or human(target) then A.last_combat=M.clock end
  local b=M.units[data.owner_unit] or (M.weapon_owners or {})[data.attacker_unit]
  if not b or not b.active or human(b.unit) or not live(target) then return end
  A.last_combat=M.clock
  local map=A.damage[b.unit]
  if not map then map=setmetatable({}, {__mode='k'});A.damage[b.unit]=map end
  local rec=map[target]
  if not rec or M.clock-rec.last>4 then
   local count=0;local oldest,key
   for u,r in pairs(map) do count=count+1;if not oldest or r.last<oldest then oldest=r.last;key=u end end
   if count>=32 then map[key]=nil end
   rec={amount=0,hits=0,first=M.clock};map[target]=rec
  end
  rec.amount=rec.amount+data.damage;rec.hits=rec.hits+1;rec.last=M.clock
 end
 function A.performance(u,target)
  local rec=A.damage[u] and A.damage[u][target]
  if rec and rec.hits>=3 and M.clock-rec.last<=2 and rec.last-rec.first>=.6 then
   return {dps=rec.amount/(rec.last-rec.first),confirmed_damage_events=rec.hits,age=M.clock-rec.last}
  end
 end
 function A.install()
  if A.installed then return A.ready end
  if type(CharacterComponent)~='table' or type(CharacterComponent.do_stratagem_input)~='function'
   or type(CharacterComponent.can_use_stratagem)~='function' or type(InventoryComponent)~='table'
   or type(InventoryComponent.command_master)~='function' or not array or type(array.insert_end)~='function' then return false end
  A.original_can_use=CharacterComponent.can_use_stratagem
  hook(CharacterComponent,'command_master',function(old)return function(self,u,e,name,data,...)
   if M.bot_origins[u] then A.contexts[u]={component=self,context=e} end
   return old(self,u,e,name,data,...)
  end end)
  hook(CharacterComponent,'do_stratagem_input',function(old)return function(self,u,e,...)
   local b=M.units[u]
   if not b or not b.active or human(u) then return old(self,u,e,...) end
   local t=A.actions[u];if not t then return end
   local ok,err=pcall(command_input,u,e,t);if not ok then fault('command_entry',err) end
  end end)
  hook(CharacterComponent,'can_use_stratagem',function(old)return function(self,u,id,...)
   local b=M.units[u]
   if b and b.active and not human(u) then
    local t=A.actions[u]
    if not t or not A.authorized(u) or t.cap.id~=id or t.ticket.state~='reserved' then return false end
   end
   return old(self,u,id,...)
  end end)
  hook(InventoryComponent,'command_master',function(old)return function(self,u,e,name,data,...)
   local t=A.actions[u]
   if name=='throw' and data and data.__hd_squad_deferred then
    if not t or data.__hd_squad_deferred~=t.release_token or not A.authorized(u)
     or M.session~=t.guard_session or M.generation~=t.guard_generation or e.state.held_grenade~=t.marker then
     emit('stratagem_deferred_release_discarded',{reason='expired_control_or_marker'});return
    end
   end
   if not t then return old(self,u,e,name,data,...) end
   -- A queued command from a cancelled AI sequence must not become a loose flare.
   if t and t.phase=='cancelled' and name=='use_stratagem' and data==t.cap.id then
    local c=state(u,'character',true) or {}
    if c.current_stratagem~=data then return end
   end
   if name=='throw' and t.marker and e.state.held_grenade==t.marker and data and (data.power or 0)>0 and not human(u) and M.stratagem_families then
    local origin=P.point(data.position);local direction=P.point(data.direction)
    local profile=A.throw_profile(t.bot,t.cap,t.marker)
    local range=origin and P.finite(data.power) and P.throw_range(data.power,origin.z-t.position.z,profile.minimum,profile.maximum,1)
    local unit=direction and P.direction({x=0,y=0},direction)
    if not range or not unit then A.cancel(t,'native_release_geometry_unknown');return end
    local checked=P.point(t.position)
    t.throw_direction=unit;t.position={x=origin.x+unit.x*range,y=origin.y+unit.y*range,z=t.position.z}
    local safe=M.tactics.safety(t,origin)
    if not safe or not t.ground_clear or P.distance(checked,t.position)>.35 then
     A.hold_marker(t,'native_release_safety_changed',data);return
    end
   end
   local result=old(self,u,e,name,data,...)
   local ok,err=pcall(observe_inventory,t,u,e,name,data);if not ok then fault('inventory_observation',err) end
   return result
  end end)
  hook(StratagemComponent,'trigger_event',function(old)return function(self,event,info,p,owner,marker,...)
   if event=='on_stratagem_pre_activated' then
    local t=A.actions[owner]
    if t then local ok,err=pcall(observe_activation,t,info,p,marker);if not ok then fault('activation_observation',err) end end
   end
   return old(self,event,info,p,owner,marker,...)
  end end)
  for _,name in ipairs({'FirearmComponent','LauncherComponent','LauncherTurretComponent','ArcweaponComponent'}) do
   hook(rawget(_G,name),'trigger_event',function(old)return function(self,event,u,stat,count,...)
    if event=='on_add_to_stat' and stat=='shots' then
     local ok,err=pcall(observe_shot,u,count);if not ok then fault('shot_observation',err) end
    end
    return old(self,event,u,stat,count,...)
   end end)
  end
  hook(HealthComponent,'trigger_event',function(old)return function(self,event,u,data,...)
   if event=='on_damage_taken' then
    local ok,err=pcall(observe_damage,u,data);if not ok then fault('damage_observation',err) end
   end
   return old(self,event,u,data,...)
  end end)
  local spawn=hook(StratagemComponent,'spawn_stratagem_hellpod',function(old)return function(self,marker,p,d,id,upgrade,owner,...)
   local previous=A.delivery_context;local t
   for _,candidate in ipairs(M.tactics and M.tactics.pending or {}) do
    if candidate.marker==marker and candidate.cap.id==id and candidate.bot.unit==owner then t=candidate;break end
   end
   if not t then for _,record in ipairs(M.tactics and M.tactics.readiness and M.tactics.readiness.vehicles or {}) do
    local candidate=record.transaction
    if record.state~='cancelled' and record.state~='unavailable' and candidate.marker==marker and candidate.cap.id==id
     and candidate.bot.unit==owner then t=candidate;break end
   end end
   A.delivery_context=t
   local ok,result=pcall(old,self,marker,p,d,id,upgrade,owner,...)
   A.delivery_context=previous
   if not ok then error(result,0) end
   return result
  end end)
  local queue=hook(SpawnManager,'queue_spawn',function(old)return function(self,path,p,q,object,callback,data,...)
   local t=A.delivery_context
   if t and type(data)=='table' and data.owner_unit==t.bot.unit and data.stratagem_info and data.stratagem_info.id==t.cap.id then
    data.__hd_squad_delivery=t.vehicle_record and t.vehicle_record.tag or ('bot:'..tostring(M.generation)..':'..tostring(t.ticket.serial))
    A.deliveries[data.__hd_squad_delivery]=t
   end
   return old(self,path,p,q,object,callback,data,...)
  end end)
  local function delivered(data,unit)
   local tag=type(data)=='table' and data.__hd_squad_delivery
   local t=tag and A.deliveries[tag] or A.delivery_context
   if t then
    if M.stratagem_families then M.stratagem_families.track(t,unit) end
    if M.tactics and M.tactics.readiness then M.tactics.readiness.delivered(t,unit) end
    if tag then A.deliveries[tag]=nil end
   end
  end
  local vehicle=hook(VehicleComponent,'setup_master',function(old)return function(self,u,e,data,...)
   local result=old(self,u,e,data,...)
   local ok,err=pcall(delivered,data,u);if not ok then fault('vehicle_provenance',err) end
   return result
  end end)
  hook(HellpodComponent,'setup_master',function(old)return function(self,u,e,data,...)
   local result=old(self,u,e,data,...)
   local ok,err=pcall(delivered,data,e.state.stratagem_unit);if not ok then fault('hellpod_provenance',err) end
   return result
  end end)
  A.provenance_ready=spawn and queue and vehicle
  A.installed=true;A.ready=true;return true
 end
 function A.start(t,ledger)
  if not A.ready or A.actions[t.bot.unit] then return false end
  A.ledger=ledger;A.actions[t.bot.unit]=t;t.phase='positioning';t.started=M.clock;t.key=1
  t.bot.stratagem_intent=t;return true
 end
 function A.throw_profile(b,cap,marker)
  local context=A.contexts[b.unit];local c=state(b.unit,'character',true) or {}
  local ci=context and context.context.settings and context.context.settings.character_info or {}
  local settings
  if LuaSettingsManager then
   if marker and live(marker) and LuaSettingsManager.get_settings_by_unit then
    local ok,value=pcall(LuaSettingsManager.get_settings_by_unit,LuaSettingsManager,marker)
    if ok then settings=value end
   elseif LuaSettingsManager.get_modified_settings then
    local ok,value=pcall(LuaSettingsManager.get_modified_settings,LuaSettingsManager,'gameobjects/flare_01',cap.upgrade)
    if ok then settings=value end
   end
  end
  local ti=type(settings)=='table' and settings.throwable_info
  if type(ti)~='table' then ti=nil end
  if ti and P.finite(ti.throw_distance_min) and P.finite(ti.throw_distance_max) then
   A.profiles[b.unit]={minimum=ti.throw_distance_min,maximum=ti.throw_distance_max,upgrade=cap.upgrade}
  end
  local saved=A.profiles[b.unit] or {};if saved.upgrade~=cap.upgrade then saved={} end
  return {minimum=ti and ti.throw_distance_min or saved.minimum,maximum=ti and ti.throw_distance_max or saved.maximum,
   multiplier=c.throw_range_multiplier,charge_time=ci.throw_time_to_max}
 end
 function A.throw_origin(b)
  local hand=Unit.node(b.unit,'r_hand_attach')
  if type(hand)~='number' or hand<0 then return end
  return P.point(Unit.world_position(b.unit,hand))
 end
 function A.cancel(t,reason)
  if not t or t.finished then return true end
  t.cancel_reason=reason
  if t.ticket.state~='reserved' then t.detached=true;return false end
  local u=t.bot.unit;local c=state(u,'character',true) or {};local inv=state(u,'inventory',true) or state(u,'inventory') or {}
  local context=A.contexts[u]
  local h=state(u,'health') or {}
  if live(inv.held_grenade) and (h.is_dead or h.is_downed) then
   committed(t,'incapacitated_with_marker');t.detached=true;return false
  end
  if live(inv.held_grenade) or c.current_stratagem then
   if c.throw_started or c.has_thrown or not context or not EntityAux.command_master_immediately then
    A.hold_marker(t,'cancellation_uncertain');return false
   end
   if c.current_state==CharacterStateStratagemsThrow and CharacterStateStratagemsThrow and CharacterStateStratagemsThrow.update then
    -- Run the native switch-weapon cancellation branch before handoff neutral input.
    local input=C.neutral();input.switch_weapon='switch_to_primary'
    EntityAux.command_master_immediately(u,'character','input',input)
    local ok=pcall(CharacterStateStratagemsThrow.update,u,context.context,0,context.component)
    if not ok then committed(t,'native_cancel_failed');t.detached=true;return false end
   else
    committed(t,'native_cancel_state_unknown');t.detached=true;return false
   end
   EntityAux.command_master_immediately(u,'inventory','cancel_stratagem')
   local after=state(u,'inventory',true) or state(u,'inventory') or {}
   if live(after.held_grenade) then committed(t,'native_cancel_unconfirmed');t.detached=true;return false end
  end
  if live(u) and EntityAux.command_master_immediately then EntityAux.command_master_immediately(u,'character','input',C.neutral()) end
  P.refund(t.ticket);t.phase='cancelled';t.cancelled_at=M.clock
  if not t.cancel_reported then
   t.cancel_reported=true;A.stats.cancelled=A.stats.cancelled+1;A.last_result=reason
   if reason=='preparation_expired' or reason=='throw_solution_unavailable' or reason=='throw_origin_unavailable'
    or reason=='obstacle' or reason=='ground' or reason=='command_timeout' then
    local b=t.bot;b.stratagem_backoff=b.stratagem_backoff or {}
    local previous=b.stratagem_backoff[t.cap.id];local count=math.min(5,(previous and previous.failures or 0)+1)
    b.stratagem_backoff[t.cap.id]={failures=count,until_time=M.clock+math.min(30,3*2^(count-1)),reason=reason}
   end
   emit('stratagem_cancelled',{transaction=t.ticket.serial,stratagem=t.cap.name,reason=reason,
    decision=reason=='preparation_expired' and 'preparation_failed' or 'interrupted',
    elapsed=M.clock-t.started,position=t.last_position,
    staging=t.staging,staging_distance=t.staging and t.last_position and P.distance(t.last_position,t.staging),
    readiness=t.readiness,probe_retries=t.probe_retries,throw_geometry=t.throw_geometry},t.bot.id)
  end
  return true
 end
 function A.input(t,p,input,safe)
  if not t or t.finished or t.detached or t.phase=='cancelled' then return input end
  t.last_position=P.point(p)
  local b=t.bot;local c=state(b.unit,'character',true) or {};local inv=state(b.unit,'inventory',true) or state(b.unit,'inventory') or {}
  if not A.authorized(b.unit) then A.cancel(t,'authority_changed');return input end
  if t.phase=='positioning' and P.distance(p,t.staging)>.65 then return input end
  if t.phase=='positioning' then
   input.movement={x=0,y=0,z=0};input.sprint=false
   if not t.ground_clear or not safe then return input end
   local v=(c.mover_state or {}).velocity or {};local speed=math.sqrt((v.x or 0)^2+(v.y or 0)^2)
   if speed>.15 then input.movement={x=0,y=0,z=0};input.sprint=false;return input end
   t.phase='radio';t.radio_at=M.clock
   A.stats.commands=A.stats.commands+1;A.last_result='entering command'
   emit('stratagem_command_started',{transaction=t.ticket.serial,stratagem=t.cap.name},b.id)
  end
  if t.phase=='committed' then
   -- Continue native throw animation, suppress a second throw edge.
   local out=C.neutral();out.aim=t.aim or P.direction(p,t.position);return out
  end
  if not safe then A.cancel(t,'safety_changed');return C.neutral() end
  local out=C.neutral();out.aim=P.direction(p,t.position);t.aim=out.aim
  if t.phase=='radio' then
   out.stratagems=true
   if c.current_state~=CharacterStateStratagems then return out end
   if t.pulse and t.received==t.pulse then
    t.key=t.key+1;t.pulse=nil;t.next_key=M.clock+.12;return out
   end
   if M.clock>=(t.next_key or 0) then
    local direction=t.cap.info.combo[t.key]
    if direction then t.pulse=t.key;out['stratagem_'..direction]=true end
   end
   if M.clock-(t.radio_at or M.clock)>5 then A.cancel(t,'command_timeout') end
   return out
  end
  if t.phase=='ready' then
   if c.current_state~=CharacterStateStratagemsThrow then return out end
   local f=Quaternion.forward(Unit.world_rotation(b.unit,0));local d=out.aim
   local n=math.sqrt(f.x*f.x+f.y*f.y)
   if n<.01 or (f.x*d.x+f.y*d.y)/n<.998 then return out end
   if not t.power then
    local origin=A.throw_origin(b);if not origin then A.cancel(t,'throw_origin_unavailable');return out end
    local g=A.throw_profile(b,t.cap,t.marker);g.origin=origin;g.target=P.point(t.position)
    g.distance=P.distance(origin,t.position);g.height=origin.z-t.position.z
    t.power,g.reason=P.throw_power(g.distance,g.height,g.minimum,g.maximum,g.multiplier)
    t.charge_time=g.charge_time;t.throw_geometry=g
    if not P.finite(t.charge_time) or t.charge_time<=0 then g.reason='invalid_charge_time';t.power=nil end
    g.power=t.power
    emit('stratagem_throw_solution',g,b.id)
    if not t.power then A.cancel(t,'throw_solution_unavailable');return out end
   end
   if not t.hold_at then t.hold_at=M.clock end
   out.throw=not P.finite(c.throw_timer) or c.throw_timer<t.power*t.charge_time
   if not out.throw and not c.throw_started then out.throw=true end
   return out
  end
  return input
 end
 function A.finish(t)
  t.finished=true
  if t.bot.stratagem_intent==t then t.bot.stratagem_intent=nil end
  if A.actions[t.bot.unit]==t then A.actions[t.bot.unit]=nil end
 end
 function A.uninstall()
  for _,t in pairs(A.actions) do A.cancel(t,'unloaded') end
  A.enabled=false
  for i=#A.hooks,1,-1 do local h=A.hooks[i];if h.object[h.key]==h.wrapper then h.object[h.key]=h.old end end
  A.hooks={};A.installed=false;A.ready=false
 end
 A.install();return A
end
