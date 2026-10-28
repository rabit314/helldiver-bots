-- Guard native delayed interactions and the invalid-peer native crash boundary.
return function(M,C,B,emit)
 if M.action_safety then M.action_safety.install();return M.action_safety end
 local A={hooks={},states=setmetatable({}, {__mode='kv'})};M.action_safety=A
 local function live(u)return u~=nil and Unit.alive(u)end
 local function state(u,n)
  if live(u) and EntityAux.has_component(u,n) then return EntityAux.state(u,n) end
 end
 local function supported()return M.enabled and M.session and M.session.is_server and not M.session.wants_exit end
 local function living(u)
  local h=state(u,'health');if not h or h.is_dead then return false end
  if EntityAux.has_component_master(u,'health') then
   local m=EntityAux.state_master(u,'health') or {}
   if m.is_dead or type(m.hitpoints_real)=='number' and type(m.constitution)=='number' and m.hitpoints_real<=m.constitution then return false end
  end
  return true
 end
 local function hook(object,key,factory)
  if not object or type(object[key])~='function' or A.hooks[key] then return end
  local old=object[key];local wrapper=factory(old);object[key]=wrapper
  A.hooks[key]={object=object,key=key,old=old,wrapper=wrapper}
 end
 function A.guard(u,cache)
  local s=cache and cache.state;if not s or type(s.on_interact)~='function' or A.states[s]==s.on_interact then return end
  local original=s.on_interact
  s.on_interact=function(actor,...)
   local info=original(actor,...)
   if not supported() or not info or type(info.interact_action)~='function' then return info end
   local action=info.interact_action;local session=M.session;local generation=M.generation
   local epoch=M.control_epoch or 0;local bot=M.units[actor];local body_epoch=bot and bot.rejoin_epoch
   local health=state(u,'health')
   local revive=health and health.is_downed and type(info.interact_event)=='string' and info.interact_event:find('help_up',1,true)==1
   local pack=not revive and (state(u,'inventory') or {}).backpack
   local completed=false
   info.interact_action=function(...)
    local h=state(u,'health');local actor_health=state(actor,'health')
    local valid=supported() and M.session==session and M.generation==generation and (M.control_epoch or 0)==epoch
     and live(u) and live(actor) and state(u,'interactable_character')==s
     and (not bot or bot.active and bot.rejoin_epoch==body_epoch and M.units[actor]==bot)
     and not completed and actor_health and living(actor) and not actor_health.is_downed
     and (not revive or h and h.is_downed and living(u))
     and (not pack or live(pack) and living(u) and (state(u,'inventory') or {}).backpack==pack)
    if not valid then emit('interaction_completion_cancelled',{revive=revive,target=tostring(u),reason='expired_context'});return end
    completed=true;return action(...)
   end
   return info
  end
  A.states[s]=s.on_interact
 end
 function A.install()
  hook(rawget(_G,'InteractableCharacterComponent'),'setup_slave',function(old)return function(self,u,e,...)
   local result=old(self,u,e,...);A.guard(u,e);return result
  end end)
  hook(rawget(_G,'NetworkRouter'),'transmit_to',function(old)return function(self,peer,name,...)
   if peer==nil and supported() then
    local u,owner,attacker,hp=...
    local h=state(u,'health')
    local local_health=name=='rpc_set_hitpoints_request' and live(u) and h and h.is_downed and living(u)
     and hp==75 and EntityAux.has_component_master(u,'health')
    if local_health then EntityAux.queue_command_master(u,'health','set_hitpoints',hp) end
    local pack=state(u,'ammo_backpack')
    local local_ammo=name=='rpc_ammo_backpack_used' and live(u) and EntityAux.has_component_master(u,'ammo_backpack')
     and pack and (pack.num_uses or 0)>0
    if local_ammo then EntityAux.queue_command_master(u,'ammo_backpack','backpack_used') end
    if M.clock>=(A.next_note or 0) then
     A.next_note=M.clock+2;emit('invalid_peer_request_blocked',{rpc=name,local_health=not not local_health,local_ammo=not not local_ammo,target=tostring(u)})
    end
    return
   end
   return old(self,peer,name,...)
  end end)
  if supported() and M.session.entity_manager and type(M.session.entity_manager.get_slave_entities)=='function' and M.clock>=(A.next_scan or 0) then
   A.next_scan=M.clock+1
   for u,e in pairs(B.entities(M.session,'interactable_character',nil,'slave')) do A.guard(u,e) end
  end
 end
 function A.uninstall()
  for _,h in pairs(A.hooks) do if h.object[h.key]==h.wrapper then h.object[h.key]=h.old end end
  A.hooks={}
 end
 A.install();return A
end
