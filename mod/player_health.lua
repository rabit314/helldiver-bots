-- Local main-player health add-on. All changes are per-component state, never shared settings.
local H=rawget(_G,'HelldiversPlayerHealth')
if not H then
 H={revision='1.4',entries=setmetatable({}, {__mode='k'})}
 rawset(_G,'HelldiversPlayerHealth',H)
end
if H.revision~='1.4' and H.wrapper then
 assert(HealthComponent.update_masters==H.wrapper,'Another mod replaced the player health hook')
 HealthComponent.update_masters=H.original;H.wrapper=nil
end
H.revision='1.4'
local function main_player()
 local sm=Boot and Boot.state_machine;local s=sm and sm.state
 if not s or sm.current_state_name~='game' or not s.is_server or not s.generated_level then return nil end
 for _,p in ipairs(s.players or {}) do
  local go=p.player_go
  if go and go:exists() and go:owned() and go:has('avatar_unit') then
   local unit=go:get('avatar_unit')
   local ai=rawget(_G,'HelldiversSquadAI')
   if ai and ai.is_bot_body and ai.is_bot_body(unit) then return nil end
   return unit and Unit.alive(unit) and unit or nil
  end
 end
end
local function scale(component,s,unit,multiplier)
 local entry=H.entries[s]
 local previous=entry and entry.multiplier or 1
 if multiplier==previous then return end
 if type(s.max_hitpoints)~='number' or type(s.hitpoints_real)~='number' then return end
 -- Preserve the health fraction on toggles, and preserve downed/dead values.
 local base=(entry and s.max_hitpoints==entry.maximum) and s.max_hitpoints/previous or s.max_hitpoints
 local maximum=base*multiplier;local ratio=maximum/s.max_hitpoints
 s.max_hitpoints=maximum
 if s.hitpoints_real>0 and not s.is_dead and not s.is_downed then
  component:set_protected(s,'hitpoints_real',math.min(maximum,s.hitpoints_real*ratio))
  s.hitpoints=math.ceil(s.hitpoints_real)
 end
 s.dirty=true
 H.entries[s]=multiplier~=1 and {unit=unit,component=component,multiplier=multiplier,maximum=maximum} or nil
end
H.enabled=config.playerhealth==true
H.multiplier=config.health_multiplier or 2.5
assert(type(HealthComponent)=='table' and type(HealthComponent.update_masters)=='function','Health component not ready')
if not H.wrapper then
 H.original=HealthComponent.update_masters
 H.wrapper=function(self,entities,dt,...)
  local player=H.enabled and main_player() or nil
  local ai=rawget(_G,'HelldiversSquadAI')
  for unit,entity in pairs(entities or {}) do
   local s=entity.state
   local original=H.enabled and (unit==player or (ai and ai.is_original_body and ai.is_original_body(unit)))
   if s and (original or H.entries[s]) then scale(self,s,unit,original and H.multiplier or 1) end
  end
  return H.original(self,entities,dt,...)
 end
 HealthComponent.update_masters=H.wrapper
end
if not H.enabled then
 for s,entry in pairs(H.entries) do
  if entry.unit and Unit.alive(entry.unit) then scale(entry.component,s,entry.unit,1) else H.entries[s]=nil end
 end
end
return H
