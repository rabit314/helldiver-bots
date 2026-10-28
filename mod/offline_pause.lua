-- Native ESC menu pause for one local offline player; independent of directives.
local P=rawget(_G,'HelldiversOfflinePause')
if P and P.revision=='1.1' then return P end
if P then P.set_enabled(false) end
P={revision='1.1',enabled=false,hooks={},events={}}
rawset(_G,'HelldiversOfflinePause',P)
local function note(active,reason)
 local e={active=active,reason=reason,revision=P.revision,status=P.status}
 P.events[#P.events+1]=e;if #P.events>16 then table.remove(P.events,1) end
 local r=rawget(_G,'HelldiversGameplayRecorder')
 if r and r.log then pcall(r.log.emit,r.log,'gameplay','offline_pause_changed',e,r.clock) end
end
function P.release(reason)
 if not P.held then return end
 if rawget(_G,'PAUSED')==true then rawset(_G,'PAUSED',P.prior_pause) end
 P.held=false;P.session=nil;P.prior_pause=nil;note(false,reason)
end
local function eligible()
 local sm=Boot and Boot.state_machine;local s=sm and sm.state
 if not P.enabled then return nil,'disabled' end
 if not sm or sm.current_state_name~='game' or not s or not s.is_server or s.wants_exit then return nil,'not_local_host_mission' end
 if not s.players or #s.players~=1 then return nil,'human_count' end
 local go=s.players[1].player_go
 if not go or not go:exists() or not go:owned() then return nil,'human_not_locally_owned' end
 local n=s.network_session_handler
 if not n or type(n.get_other_peers)~='function' or type(n.get_state)~='function' then return nil,'session_roster_unknown' end
 if n:get_state()~='connected' then return nil,'session_transition' end
 local peers=n:get_other_peers()
 if type(peers)~='table' then return nil,'session_roster_unknown' end
 if next(peers) or type(n.other_peers)=='table' and next(n.other_peers) then return nil,'remote_or_joining_peer' end
 if type(n.is_game_session_host)~='function' or not n:is_game_session_host() then return nil,'host_ownership_unknown' end
 local lan=NetworkBackend and NetworkBackend.backend_type=='LAN'
 local offline=NetworkGlobal and type(NetworkGlobal.is_online)=='function' and NetworkGlobal:is_online()==false
 if not lan and not offline then return nil,'offline_status_unknown_or_online' end
 if not s.component_manager or type(ComponentManager)~='table'
   or type(ComponentManager.update)~='function' then return nil,'simulation_not_ready' end
 if not P.menu or P.menu.parent~=s or s.active_screen~=P.menu then return nil,'ready' end
 return s
end
function P.sync()
 local sm=Boot and Boot.state_machine;local current=sm and sm.state
 local screen=current and current.active_screen
 if screen~=P.closing_menu then P.closing_menu=nil end
 if current and current.screens and screen==current.screens.main and screen~=P.closing_menu then P.menu=screen end
 local ok,s,reason=pcall(eligible)
 if not ok then s=nil;reason='eligibility_error' end
 P.status=s and 'held' or reason
 if not s then
  P.release(reason)
  if P.menu and reason~=P.last_rejection then P.last_rejection=reason;note(false,reason) end
  return
 end
 P.last_rejection=nil
 if P.held and P.session~=s then P.release('session_changed') end
 if not P.held then
  P.prior_pause=rawget(_G,'PAUSED');P.session=s;P.held=true;rawset(_G,'PAUSED',true)
  note(true,'offline_solo_menu')
 end
 rawset(_G,'PAUSED',true)
end
local function held(s)return P.enabled and (P.held and P.session==s or P.frame_hold and P.frame_session==s) end
local function hook(object,key,factory)
 if type(object)~='table' or type(object[key])~='function' then return end
 for _,h in ipairs(P.hooks) do if h.object==object and h.key==key then return end end
 local old=object[key];local wrapper=factory(old)
 P.hooks[#P.hooks+1]={object=object,key=key,original=old,wrapper=wrapper};object[key]=wrapper
end
function P.bind()
 hook(MenuScreenMain,'set_active_pause',function(old)return function(self,active,...)
  local result=old(self,active,...)
  if active then P.menu=self;P.closing_menu=nil;P.sync()
  elseif P.menu==self then P.menu=nil;P.closing_menu=self;P.release('menu_closed') end
  return result
 end end)
 hook(MenuScreenMain,'update',function(old)return function(self,dt,...)
  if held(self.parent) and self==P.menu then dt=P.frame_dt or ENGINE_DT or dt end
  return old(self,dt,...)
 end end)
 hook(StateGame,'pre_update',function(old)return function(self,dt,...)
  if held(self) then
   -- Keep receive polling alive so a joining human can end solo eligibility.
   local network=self.network_session_handler
   if network and type(network.update_receive)=='function' then network:update_receive(0) end
   P.sync()
   return
  end
  return old(self,dt,...)
 end end)
 for _,key in ipairs({'pre_update','update','post_update'}) do
  hook(ComponentManager,key,function(old)return function(self,dt,...)
   local s=P.held and P.session or P.frame_hold and P.frame_session
   if P.enabled and s and s.component_manager==self then return end
   return old(self,dt,...)
  end end)
 end
 local ai=rawget(_G,'HelldiversSquadAI')
 -- F6 may replace tick during staging. Remove only our obsolete tick entry.
 for i=#P.hooks,1,-1 do local h=P.hooks[i]
  if h.object==ai and h.key=='tick' and ai.tick~=h.wrapper then table.remove(P.hooks,i) end
 end
 hook(ai,'tick',function(old)return function(s,dt,...)
  if held(s) then return end
  return old(s,dt,...)
 end end)
end
function P.set_enabled(enabled)
 if not enabled then
  P.enabled=false;P.menu=nil;P.status='disabled';P.release('controller_disabled')
  for i=#P.hooks,1,-1 do local h=P.hooks[i]
   if h.object[h.key]==h.wrapper then h.object[h.key]=h.original;table.remove(P.hooks,i) end
  end
  return
 end
 P.enabled=true;P.bind()
 hook(_G,'update',function(old)return function(dt,...)
  P.frame_dt=dt;P.frame_hold=false
  if P.enabled then P.bind();P.sync() end
  P.frame_hold=P.held;P.frame_session=P.session
  old(dt,...)
  P.frame_hold=false
  if P.enabled then P.sync() end
 end end)
 -- Applying/reopening while the menu is already visible also pauses it.
 local sm=Boot and Boot.state_machine;local s=sm and sm.state
 local menu=s and s.active_screen
 if menu and s.screens and s.screens.main==menu then P.menu=menu end
 P.sync()
end
return P
