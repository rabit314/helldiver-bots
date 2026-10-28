-- Finite local-player supplies. Native setters retain protected state tracking.
local S=rawget(_G,'HelldiversPlayerSupplies')
if not S then
  S={revision='1.3',hooks={},lives=setmetatable({}, {__mode='k'}),grenades=setmetatable({}, {__mode='k'})}
 rawset(_G,'HelldiversPlayerSupplies',S)
end
if S.revision~='1.3' then
 for _,pair in ipairs({{StateGame,'update'},{StateGame,'on_objective_completed'},
  {InventoryComponent,'set_loadout'},{InventoryComponent,'ammo_pickup'},
  {InventoryComponent,'command_master'},{InventoryComponent,'has_full_ammo'}}) do
  local owner,key=unpack(pair);local h=S.hooks[tostring(owner)..':'..key]
  if h then assert(owner[key]==h.wrapper,'Another mod replaced supplies hook '..key);owner[key]=h.original end
 end
 S.hooks={};S.revision='1.3'
end
S.respawns_enabled=config.playerrespawns==true or (config.playerrespawns==nil and config.playersupplies==true)
S.grenades_enabled=config.playergrenades==true or (config.playergrenades==nil and config.playersupplies==true)
S.enabled=S.respawns_enabled or S.grenades_enabled
S.respawn_count=config.respawn_count or 4
S.grenade_count=config.grenade_count or 3
local function context(s)
 local sm=Boot and Boot.state_machine
 s=s or (sm and sm.current_state_name=='game' and sm.state)
 if not s or not s.is_server or not s.generated_level then return end
 local count,record=0,nil
 for _,p in ipairs(s.players or {}) do
  local go=p.player_go
  if go and go:exists() then count=count+1;if go:owned() and not record then record=p end end
 end
 if count~=1 or not record then return end
 local go=record.player_go;local u=go:has('avatar_unit') and go:get('avatar_unit')
 return s,record,u and Unit.alive(u) and u or nil
end
local function inventory(u)
 if u and Unit.alive(u) and EntityAux.has_component_master(u,'inventory') then return EntityAux.state_master(u,'inventory') end
end
local function set_grenades(component,u,state,value)
 component:set_protected(state,'num_grenades',value);state.dirty=true
 S.grenades[state]={component=component,unit=u,target=S.grenade_count}
end
local function grant_grenades(component,u,entity,refill)
 local _,_,player=context();local state=entity and entity.state
 local ai=rawget(_G,'HelldiversSquadAI')
 if ai and ai.is_bot_body and ai.is_bot_body(u) then return end
 local original=ai and ai.is_original_body and ai.is_original_body(u)
 if not S.grenades_enabled or (u~=player and not original) or not state or type(state.num_grenades)~='number' then return end
 if refill then set_grenades(component,u,state,S.grenade_count)
 elseif not S.grenades[state] then
  set_grenades(component,u,state,math.max(0,math.min(S.grenade_count,state.num_grenades+S.grenade_count-2)))
 end
end
function S.refresh(s)
 local mission,p=context(s);if not mission then return end
 local entry=S.lives[p]
 if entry and entry.mission~=mission then S.lives[p]=nil;entry=nil end
 if S.respawns_enabled then
  if not entry and type(p.extra_lives)=='number' and p.extra_lives_protected then
   local bonus=S.respawn_count-p.extra_lives
   mission:set_extra_lives(p,p.extra_lives+bonus)
   entry={bonus=bonus,mission=mission,target=S.respawn_count};S.lives[p]=entry
  elseif entry and (entry.target or 4)~=S.respawn_count then
   local desired=math.max(0,p.extra_lives+S.respawn_count-(entry.target or 4))
   entry.bonus=entry.bonus+desired-p.extra_lives;entry.target=S.respawn_count
   mission:set_extra_lives(p,desired)
  end
  if entry then p.extra_lives_maxed=p.extra_lives>=S.respawn_count end
 elseif entry then
  mission:set_extra_lives(p,math.max(0,p.extra_lives-entry.bonus))
  p.extra_lives_maxed=p.extra_lives>=2;S.lives[p]=nil
 end
end
local function hook(owner,key,factory)
 local id=tostring(owner)..':'..key
 local h=S.hooks[id]
 if h then
  local present=owner[key]==h.wrapper
  local ai=rawget(_G,'HelldiversSquadAI')
  local loadout=ai and ai.loadouts and ai.loadouts.hook
  if loadout and key=='set_loadout' and loadout.object==owner
   and owner[key]==loadout.wrapper and loadout.original==h.wrapper then present=true end
  -- The menu's recorder wraps inventory commands after the first Apply.
  -- Keep that known outer layer intact when sliders or toggles are changed.
  local recorder=rawget(_G,'HelldiversGameplayRecorder')
  for _,layer in ipairs(recorder and recorder.hooks or {}) do
   if layer.obj==owner and layer.key==key and owner[key]==layer.wrapper and layer.old==h.wrapper then present=true end
  end
  assert(present,'Another mod replaced supplies hook '..key);return
 end
 local old=assert(owner[key],'Missing supplies function '..key)
 local wrapper=factory(old);S.hooks[id]={wrapper=wrapper,original=old};owner[key]=wrapper
end
if S.enabled then
 hook(StateGame,'update',function(old)
  return function(self,...)
   S.refresh(self);return old(self,...)
  end
 end)
 hook(StateGame,'on_objective_completed',function(old)
  return function(self,...)
   S.refresh(self)
   local mission,p,u=context(self);local before=p and p.extra_lives
   local result=old(self,...)
   if S.respawns_enabled and mission and u and EntityAux.owned(u) then
    local desired=math.min(S.respawn_count,before+1)
    if p.extra_lives~=desired then self:set_extra_lives(p,desired) end
    p.extra_lives_maxed=p.extra_lives>=S.respawn_count
   end
   return result
  end
 end)
 for _,key in ipairs({'set_loadout','ammo_pickup'}) do
  hook(InventoryComponent,key,function(old)
   return function(self,u,entity,...)
    local result=old(self,u,entity,...);grant_grenades(self,u,entity,true);return result
   end
  end)
 end
 hook(InventoryComponent,'command_master',function(old)
  return function(self,u,entity,...)
   grant_grenades(self,u,entity,false);return old(self,u,entity,...)
  end
 end)
 hook(InventoryComponent,'has_full_ammo',function(old)
  return function(state,...)
   local _,_,u=context()
   local ai=rawget(_G,'HelldiversSquadAI');local bot=ai and ai.is_bot_body and ai.is_bot_body(u)
   local original=state and S.grenades[state]
   if S.grenades_enabled and state and ((not bot and state==inventory(u)) or
      (original and ai and ai.is_original_body and ai.is_original_body(original.unit))) then
    if (state.num_grenades or 0)<S.grenade_count then return false end
    local view={};for k,v in pairs(state) do view[k]=v end;view.num_grenades=2
    return old(view,...)
   end
   return old(state,...)
  end
 end)
end
for state,entry in pairs(S.grenades) do
 if Unit.alive(entry.unit) and type(state.num_grenades)=='number' then
  if S.grenades_enabled then
   local previous=entry.target or 3
   if previous~=S.grenade_count then
    set_grenades(entry.component,entry.unit,state,math.max(0,math.min(S.grenade_count,state.num_grenades+S.grenade_count-previous)))
   end
  elseif state.num_grenades>2 then
   entry.component:set_protected(state,'num_grenades',2);state.dirty=true
  end
 end
 if not S.grenades_enabled then S.grenades[state]=nil end
end
S.refresh()
return S
