-- Scope native camera targets to the controlled human, including their vehicle.
return function(M)
 local F=M.camera_focus or {vehicles=setmetatable({}, {__mode='k'})};M.camera_focus=F
 local function live(u)return u~=nil and Unit.alive(u)end
 local function state(u,n)
  if not live(u) then return end
  if EntityAux.has_component_master(u,n) then return EntityAux.state_master(u,n) end
  if EntityAux.has_component(u,n) then return EntityAux.state(u,n) end
 end
 local function human()
  local sm=Boot and Boot.state_machine;local s=M.session
  if not M.enabled or not s or not sm or sm.state~=s or sm.current_state_name~='game' or s.wants_exit then return end
  local count,u=0
  for _,p in ipairs(s.players or {}) do
   local go=p.player_go
   if go and go:exists() then
    count=count+1
    if go:owned() and go:has('avatar_unit') then u=go:get('avatar_unit') end
   end
  end
  if count==1 and live(u) then return u end
 end
 local function friendly(u,player)
  local t=M.takeover or {}
  return u~=nil and (u==player or M.units[u] or (M.bot_origins or {})[u]
   or (t.records or {})[u] or (t.humans or {})[u])
 end
 local function tracked(u,player)
  if not live(u) then return false end
  if F.vehicles[u] or state(u,'vehicle') then F.vehicles[u]=true;return true end
  local a=state(u,'seat') or {}
  for _,occupant in pairs(a.seated_units or {}) do
   if friendly(occupant,player) then F.vehicles[u]=true;return true end
  end
  return false
 end
 function F.install()
  if F.hook or type(CameraTargetComponent)~='table' or type(CameraTargetComponent.update_slaves)~='function' then return end
  local object=CameraTargetComponent;local old=object.update_slaves
  local wrapper=function(self,entities,dt,...)
   if F.session~=M.session then F.session=M.session;F.vehicles=setmetatable({}, {__mode='k'}) end
   local player=human()
   if not player then return old(self,entities,dt,...) end
   local c=state(player,'character') or {};local seat=c.current_seat_unit
   local attached=state(seat,'stationary_weapon') or {}
   local vehicle=live(attached.attached_to_unit) and attached.attached_to_unit or seat
   local target=live(vehicle) and entities[vehicle] and vehicle
    or live(seat) and entities[seat] and seat or player
   local views,changed={},{}
   for u,e in pairs(entities) do
    local gun=state(u,'stationary_weapon') or {}
    -- A tank cannon is a separate camera target, without a vehicle/seat component.
    if tracked(u,player) or friendly(gun.controller_unit,player) or tracked(gun.attached_to_unit,player) then
     F.vehicles[u]=true
    end
    if u==target or friendly(u,player) or F.vehicles[u] then
     -- Keep replicated active intact. Only was_active is a camera-local cache.
     local view,ctx={},{}
     for k,v in pairs(e.state) do view[k]=v end
     for k,v in pairs(e) do ctx[k]=v end
     view.active=u==target;ctx.state=view;views[u]=ctx;changed[e.state]=view
    else views[u]=e end
   end
   local result=old(self,views,dt,...)
   for actual,view in pairs(changed) do actual.was_active=view.was_active end
   return result
  end
  F.hook={object=object,original=old,wrapper=wrapper};object.update_slaves=wrapper
 end
 function F.uninstall()
  local h=F.hook
  if h and h.object.update_slaves==h.wrapper then h.object.update_slaves=h.original end
  F.hook=nil;F.vehicles=setmetatable({}, {__mode='k'});F.session=nil
 end
 return F
end
