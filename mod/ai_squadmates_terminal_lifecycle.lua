-- Native terminal ownership, character attachment and cancellation acknowledgements.
return function(M,C,B,O,emit)
 local L=M.terminal_lifecycle or {hooks={},operators=setmetatable({}, {__mode='k'}),targets=setmetatable({}, {__mode='k'})};M.terminal_lifecycle=L
 local kinds={objective_interact_object='ObjectiveInteractObjectComponent',extract_beacon='ExtractBeaconComponent'}
 local function live(u)return u and Unit.alive(u)end
 local function state(u,n)
  if live(u) and EntityAux.has_component_master(u,n) then return EntityAux.state_master(u,n) end
 end
 local function human(u)
  for _,p in ipairs(M.session and M.session.players or {}) do
   local go=p.player_go
   if go and go:exists() and go:has('avatar_unit') and go:get('avatar_unit')==u then return true end
  end
  return false
 end
 function O.is_ai_operator(u)
  return u and not human(u) and (L.operators[u] or M.bot_origins[u] or (M.units[u] and M.units[u].active))
 end
 local function native_command(u,name,cmd)
  if not live(u) or not EntityAux.has_component_master(u,name) then return false end
  if type(EntityAux.command_master_immediately)=='function' then
   local ok,err=pcall(EntityAux.command_master_immediately,u,name,cmd)
   if not ok then emit('objective_native_release_error',{component=name,target=tostring(u),message=tostring(err)},nil,'errors') end
   return ok
  end
  local manager=M.session and M.session.entity_manager
  local component=manager and manager.get_component and manager:get_component(name)
  local entry=manager and B.entities(M.session,name)[u]
  if not component or not entry or type(component.command_master)~='function' then return false end
  -- Native exit handlers only clear interaction/character state. Use the actual
  -- registered component/context before forgetting or despawning its operator.
  local ok,err=pcall(component.command_master,component,u,entry,cmd)
  if not ok then emit('objective_native_release_error',{component=name,target=tostring(u),message=tostring(err)},nil,'errors') end
  return ok
 end
 function O.detach(b,t,reason)
  t=t or b.objective;if not t then return end
  local name=t.component or 'objective_interact_object'
  if not kinds[name] then return end
  L.targets[t.unit]=name
  L.operators[b.unit]=true;b.objective_input=nil;t.operating=false;t.native_attaching=nil
  local a=state(t.unit,name);local c=state(b.unit,'character');local released=true
  if (not a or a.interacting_unit~=b.unit) and (not c or c.current_interact_objective_unit~=t.unit)
   and not t.pending_interaction then b.objective_exiting=nil;return true end
  if a and a.interacting_unit==b.unit then released=native_command(t.unit,name,'exit_interact') end
  if released and c and c.current_interact_objective_unit==t.unit then
   released=native_command(b.unit,'character','exit_interact_objective')
  end
  b.objective_exiting=not released or nil
  t.pending_interaction=nil;t.release=nil;t.awaiting=nil;t.mash=nil
  t.next_attempt=M.clock+.35;t.native_since=nil;t.native_progress=nil;t.native_last_change=M.clock
  emit('objective_native_release',{order=t.order,component=name,target=tostring(t.unit),reason=reason,
   released=released,terminal_owned=a and a.interacting_unit==b.unit or false,
   character_attached=c and c.current_interact_objective_unit==t.unit or false},b.id)
  return released
 end
 function O.ready(b,t)
  local c=state(b.unit,'character')
  return c and c.current_interact_objective_unit==t.unit
   and (not CharacterStateInteractObjective or c.current_state==CharacterStateInteractObjective)
 end
 function O.observe(b,t,a)
  L.targets[t.unit]=t.component or 'objective_interact_object'
  L.operators[b.unit]=true
  if a.interacting_unit~=b.unit then t.native_since=nil;t.native_attaching=nil;b.objective_exiting=nil;return true end
  if not O.ready(b,t) then
   t.native_since=t.native_since or M.clock;t.native_attaching=true
   if M.clock-t.native_since>.75 then O.detach(b,t,'character_attachment_lost') end
   return true
  end
  t.native_attaching=nil;t.native_since=nil
  local token=tostring(a.current_stage_index)..':'..tostring(a.progress)
  if token~=t.native_progress then t.native_progress=token;t.native_last_change=M.clock end
  local current=a.current_stage or {};local kind=current.interact_type
  if a.enabled==false or (a.event_duration or 0)>0 or (kind~='combo' and kind~='buttonmash') then
   t.native_last_change=M.clock;return true
  end
  if t.operating and a.enabled~=false and (a.event_duration or 0)<=0
   and (kind=='combo' or kind=='buttonmash') and M.clock-(t.native_last_change or M.clock)>8 then
   t.native_retries=(t.native_retries or 0)+1;O.detach(b,t,'native_input_not_acknowledged')
   if t.native_retries>=3 then O.release(b,'native_input_failed');return false end
  end
  return true
 end
 local function sweep()
  if not M.session then return end
  for u,name in pairs(L.targets) do
   local a=state(u,name);local owner=a and a.interacting_unit;local b=owner and M.units[owner]
   if owner and O.is_ai_operator(owner) and (not b or not b.active or not b.objective or b.objective.unit~=u) then
    O.detach(b or {unit=owner},{unit=u,component=name},'orphaned_operator')
   end
  end
 end
 local old_clear,old_install,old_uninstall,old_native=O.clear,O.install,O.uninstall,O.native_input
 function O.clear(reason)
  old_clear(reason)
  local ok,err=pcall(sweep)
  if not ok then emit('objective_cleanup_error',{message=tostring(err)},nil,'errors') end
 end
 function O.native_input(b,a)
  local t=b.objective
  if not t or not O.ready(b,t) then return C.neutral() end
  local token=tostring(a.current_stage_index)..':'..tostring((a.current_stage or {}).interact_type)
  if token~=t.native_input_stage then
   t.native_input_stage=token;t.release=nil;t.awaiting=nil;t.mash=nil;t.next_key=nil;t.next_mash=nil
  end
  local input=old_native(b,a);local direction
  for _,d in ipairs({'up','down','left','right'}) do if input['stratagem_'..d] then direction=d end end
  if direction or input.interact then t.native_pulses=(t.native_pulses or 0)+1;t.native_last_direction=direction or 'interact' end
  return input
 end
 local function hook(object,key,make)
  if L.hooks[key] or type(object)~='table' or type(object.command_master)~='function' then return end
  local old=object.command_master;local wrapper=make(old)
  L.hooks[key]={object=object,old=old,wrapper=wrapper};object.command_master=wrapper
 end
 function O.install()
  old_install()
  for name,class in pairs(kinds) do
   local component_name=name
   hook(rawget(_G,class),name,function(old)return function(self,u,e,cmd,data,...)
    if cmd=='interact' and O.is_ai_operator(data) then
     local b=M.units[data];local t=b and b.objective
     if not M.enabled or not b or not b.active or not t or t.unit~=u then
      emit('objective_late_entry_rejected',{component=component_name,target=tostring(u)},b and b.id);return
     end
     L.operators[data]=true
     L.targets[u]=component_name
    end
    return old(self,u,e,cmd,data,...)
   end end)
  end
  hook(rawget(_G,'CharacterComponent'),'character',function(old)return function(self,u,e,cmd,data,...)
   if cmd=='enter_interact_objective' and O.is_ai_operator(u) then
    local b=M.units[u];local t=b and b.objective
    if not M.enabled or not b or not b.active or not t or t.unit~=data then
     if live(data) then
      for name in pairs(kinds) do local a=state(data,name)
       if a and a.interacting_unit==u then O.detach(b or {unit=u},{unit=data,component=name},'late_character_entry') end
      end
     end
     return
    end
   end
   return old(self,u,e,cmd,data,...)
  end end)
 end
 function O.uninstall()
  local ui=M.interaction_hooks and M.interaction_hooks.terminal_hud
  old_uninstall()
  for _,h in pairs(L.hooks) do if h.object.command_master==h.wrapper then h.object.command_master=h.old end end
  L.hooks={};M.terminal_lifecycle=nil
  local function remaining()
   for u,name in pairs(L.targets) do
    local a=state(u,name);local owner=a and a.interacting_unit
    if live(owner) and O.is_ai_operator(owner) then return true end
   end
  end
  if ui and remaining() then
   -- An exceptional native release failure must not expose a no-pad body to
   -- the original HUD while native despawn/replication is still catching up.
   local wrapper
   wrapper=function(self,...)
    if not remaining() then
     if ui.object.draw_ui==wrapper then ui.object.draw_ui=ui.old end
     return ui.old(self,...)
    end
    return ui.wrapper(self,...)
   end
   if ui.object.draw_ui==ui.old then ui.object.draw_ui=wrapper end
  end
 end
 O.install();return O
end
