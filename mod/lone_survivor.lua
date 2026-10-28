-- HELLDIVERS 1: actual LoadoutSettings and component interfaces, verified locally.
assert(type(LoadoutSettings)=='table' and type(InventoryComponent)=='table', 'Game scripts are not ready yet.')
local M=rawget(_G,'LoneSurvivorV2')
if not M then
 M={hooks={},runtime=setmetatable({}, {__mode='k'}),counts={},last_reward='No rewards processed yet'}
 rawset(_G,'LoneSurvivorV2',M)
end
-- Replace older wrappers once when updating a live session, without nesting them.
if M.revision~='2.1.0' then
 for _,h in pairs(M.hooks) do if h.owner[h.key]==h.wrapper then h.owner[h.key]=h.original end end
 M.hooks={};M.revision='2.1.0'
end
M.config=config
local function shallow(t) local r={};for k,v in pairs(t) do r[k]=v end;return r end
local function hook(owner,key,id,factory)
 assert(type(owner)=='table' and type(owner[key])=='function', 'Missing game function: '..id)
 local h=M.hooks[id]
 if h and owner[key]==h.wrapper then return end
 local old=owner[key];local wrapped=factory(old)
 M.hooks[id]={owner=owner,key=key,original=old,wrapper=wrapped};owner[key]=wrapped
end
hook(LoadoutSettings,'get_upgraded_stratagem','stratagems',function(old)
 return function(...)
  local d=old(...)
  if M.config.stratagems then
   d=shallow(d);d.cooldown_time=0;d.num_uses=nil
  end
  return d
 end
end)

function M.patch_inventory(component,entities)
 for _,entity in pairs(entities or {}) do
  local state=entity.state
  if state and type(state.stratagems)=='table' then
   for _,s in ipairs(state.stratagems) do
    local base=LoadoutSettings.stratagems[s.id]
    local previous=M.runtime[s]
    if base and M.config.stratagems then
     if not previous then previous={uses=s.uses_left};M.runtime[s]=previous end
     -- Use the engine's protected-key setter; assigning these fields directly
     -- bypasses its state tracking and can raise errors.
     if type(s.cooldown_timer)=='number' and s.cooldown_timer~=0 then component:set_protected(s,'cooldown_timer',0) end
     if s.uses_left~=nil then component:set_protected(s,'uses_left',nil) end
     previous.active=true;M.counts.inventory=(M.counts.inventory or 0)+1
    elseif previous and previous.active then
     component:set_protected(s,'uses_left',previous.uses)
     previous.active=false
    end
   end
  end
 end
end
hook(InventoryComponent,'update_masters','inventory',function(old)
 return function(self,entities,dt,...)
  M.patch_inventory(self,entities)
  return old(self,entities,dt,...)
 end
end)

-- Upgrade only this hook; preserve the accepted core and reward wrappers.
if M.autoreload_revision~='1.2' then
 local h=M.hooks.autoreload
 if h and h.owner[h.key]==h.wrapper then h.owner[h.key]=h.original end
 M.hooks.autoreload=nil;M.autoreload_revision='1.2'
end
local reload_states={}
for _,name in ipairs({'CharacterStateIdle','CharacterStateWalk','CharacterStateAim','CharacterStateAimWalk',
 'CharacterStateFire','CharacterStateWalkFire','CharacterStateAimFire','CharacterStateAimWalkFire',
 'CharacterStateSprint','CharacterStateCrawl','CharacterStateDownedIdle','CharacterStateDownedAim',
 'CharacterStateDownedAimFire','CharacterStateDownedCrawl','CharacterStateCarry'}) do
 local state=rawget(_G,name);if state then reload_states[state]=true end
end
function M.should_reload(entity)
 if not M.config.autoreload then return false end
 local s=entity and entity.state
 if not s or not reload_states[s.current_state] or s.new_state or type(s.input)~='table' then return false end
 local input=s.input
 if s.current_state==rawget(_G,'CharacterStateCarry') and
  (s.is_dropping or s.carry_is_map or s.carry_is_switching_weapon or s.carry_is_reloading or input.map) then return false end
 -- Let deliberate actions finish before requesting a reload.
 if input.reload or input.dodge or input.throw or input.melee or input.interact or input.stratagems or input.switch_weapon then return false end
 if s.health_state and s.health_state.is_dead then return false end
 local weapon=s.current_weapon
 if not weapon or not Unit.alive(weapon) or not EntityAux.has_interface(weapon,'weapon') then return false end
 local ammo=EntityAux.state_master_interface(weapon,'weapon')
 return ammo and ammo.reloadable and not ammo.is_reloading and type(ammo.rounds)=='number'
  and ammo.rounds==ammo.rounds and ammo.rounds>-math.huge and ammo.rounds<=0
  and type(ammo.num_mags)=='number' and ammo.num_mags>0
end
hook(CharacterStateMachine,'update','autoreload',function(old)
 return function(unit,entity,dt,component)
  if not M.should_reload(entity) then return old(unit,entity,dt,component) end
  local state=entity.state;local original=state.input;local input=shallow(original)
  input.reload=true;input.fire=false;input.fire_auto=false
  state.input=input
  -- Use the exact input path used by the reload key, then restore the input
  -- snapshot. The game performs its usual animation and consumes a spare mag.
  local ok,result=pcall(old,unit,entity,dt,component)
  if state.input==input then state.input=original end
  if not ok then error(result,0) end
  if state.current_state==rawget(_G,'CharacterStateReload') or state.current_state==rawget(_G,'CharacterStateDownedReload') or state.carry_is_reloading then
   M.counts.reloads=(M.counts.reloads or 0)+1
  end
  return result
 end
end)

function M.recover(entities,dt)
 if not M.config.stamina then return end
 for _,entity in pairs(entities or {}) do
  local s=entity.state;local info=entity.settings and entity.settings.character_info
  if s and info and type(s.sprint_stamina)=='number' and type(info.sprint_stamina)=='number'
   and s.current_state~=CharacterStateSprint and s.current_substate~=CharacterSubstateSprint and s.current_state~=CharacterStateMelee then
   s.sprint_stamina=math.min(info.sprint_stamina,s.sprint_stamina+math.max(0,dt or 0)*4)
   M.counts.stamina=(M.counts.stamina or 0)+1
  end
 end
end
hook(CharacterComponent,'update_masters','stamina',function(old)
 return function(self,entities,dt,...)
  local result=old(self,entities,dt,...)
  M.recover(entities,dt)
  return result
 end
end)

-- Boost the game's mission-XP calculation before rank/unlock evaluation.
-- Scope it to reward processing so previews and saved balances are not multiplied.
hook(ProgressionSettings,'get_mission_xp_gain','xp',function(old)
 return function(...)
  local xp=old(...)
  if M.reward_context and M.config.multiplier>1 and type(xp)=='number' then
   return math.floor(xp*M.config.multiplier)
  end
  return xp
 end
end)
hook(PlanetRewardSettings,'get_xp_boost_amount','planet_xp',function(old)
 return function(...)
  local xp=old(...)
  if M.reward_context and M.config.multiplier>1 and type(xp)=='number' then return math.floor(xp*M.config.multiplier) end
  return xp
 end
end)
-- Upgrade only the reward hooks; leave the accepted gameplay hooks in place.
if M.research_revision~='1.0' then
 for _,id in ipairs({'research','rewards'}) do
  local h=M.hooks[id]
  assert(not h or h.owner[h.key]==h.wrapper,'Another mod replaced the reward hook: '..id)
 end
 for _,id in ipairs({'research','rewards'}) do
  local h=M.hooks[id]
  if h then h.owner[h.key]=h.original;M.hooks[id]=nil end
 end
 M.research_revision='1.0'
end
hook(SaveManager,'user_set','research',function(old)
 return function(self,key,value,user_id,...)
  if M.reward_context and M.config.multiplier>1 and key=='research_samples' and type(value)=='number' then
   local before=self:user_get(key,user_id) or 0
   local gained=math.max(0,value-before)
   if gained>0 then
    local multiplier=M.config.multiplier
    value=before+math.floor(gained*multiplier)
    -- Points and partial-bar progress share the game's research_samples balance.
    -- Add whole points for bars filled by the boosted collected samples, once.
    -- Level-up points already receive the normal research multiplier above.
    local per_point=GameSettings.NUM_RESEARCH_SAMPLES_PER_REQUISITION_POINT
    local state=M.reward_context.state
    local picked=state and state.max_local_research_samples_picked
    if type(per_point)=='number' and per_point>0 and type(picked)=='number' and picked>0 then
     local samples=math.floor(math.min(gained,picked)*multiplier)
     local completed=math.floor((before%per_point+samples)/per_point)
     value=value+completed*(multiplier-1)*per_point
    end
    value=math.min(GameSettings.MAX_NUM_RESEARCH_SAMPLES,value)
    M.last_reward='Research balance gained '..tostring(value-before)..' ('..multiplier..'x samples / completed-bar points); total '..value
    M.counts.rewards=(M.counts.rewards or 0)+1
    if M.reward_context.players then
     for _,p in ipairs(M.reward_context.players) do
      if p.pad_number and UserManager:get_user_id(p.pad_number)==user_id then
       M.reward_context.bonus_by_pad=M.reward_context.bonus_by_pad or {}
       M.reward_context.bonus_by_pad[p.pad_number]=value
      end
     end
    end
   end
  end
  return old(self,key,value,user_id,...)
 end
end)
hook(MissionEndStateWaitingForData,'update','rewards',function(old)
 return function(self,...)
  local previous=M.reward_context
  local context={players=self.players,state=self};M.reward_context=context
  local pg=ProvinggroundsSettings and ProvinggroundsSettings.max_xp
  if type(pg)=='table' and M.config.multiplier>1 then
   local boosted=shallow(pg)
   for k,v in pairs(boosted) do if type(v)=='number' then boosted[k]=v*M.config.multiplier end end
   ProvinggroundsSettings.max_xp=boosted
  end
  local ok,result=pcall(old,self,...)
  if pg then ProvinggroundsSettings.max_xp=pg end
  M.reward_context=previous
  if not ok then error(result,0) end
  -- Keep the debrief's research total in agreement with the saved payout.
  if context.bonus_by_pad and type(self.player_stats)=='table' then
   for _,p in pairs(self.player_stats) do
    if type(p)=='table' and context.bonus_by_pad[p.pad_number] then p.research_samples=context.bonus_by_pad[p.pad_number] end
   end
  end
  return result
 end
end)

function M.status()
 local out={'VERIFIED v2.1', 'Game state: '..tostring(Boot and Boot.state_machine and Boot.state_machine.current_state_name)}
 local count=0
 for _,base in ipairs(LoadoutSettings.stratagems) do
  if M.config.stratagems then
   -- Check every valid upgrade so upgrades cannot silently undo a directive.
   for upgrade=0,#(base.upgrades or {}) do
    local d=LoadoutSettings.get_upgraded_stratagem(base.id,upgrade)
    local normal=M.hooks.stratagems.original(base.id,upgrade)
    assert(d.cooldown_time==0,base.name..' cooldown did not verify')
    assert(d.num_uses==nil,base.name..' requisitions did not verify')
    assert(d.activation_time==normal.activation_time and d.despawn_time==normal.despawn_time
      and d.extra_activation_time==normal.extra_activation_time,base.name..' delivery timing changed')
   end
   count=count+1
  end
 end
 out[#out+1]='All stratagems: '..(M.config.stratagems and (count..' definitions + upgrades verified; 0s cooldown / unlimited uses') or 'normal')
 out[#out+1]='Orbital delivery times: unchanged'
 out[#out+1]='Auto-reload on empty: '..(M.config.autoreload and 'on; normal animations / spare magazines' or 'off')
 out[#out+1]='Stamina recovery: '..(M.config.stamina and '5x; component hook installed' or 'normal')
 out[#out+1]='Mission XP / earned research: '..M.config.multiplier..'x; reward hooks installed'
 out[#out+1]='Research rewards 1.0: samples and completed-bar points multiplied; level-up points multiplied once'
 out[#out+1]='Active inventory updates: '..(M.counts.inventory or 0)..'; auto-reloads: '..(M.counts.reloads or 0)
 out[#out+1]=M.last_reward
 return table.concat(out,'\n')
end
return M.status()
