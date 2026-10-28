-- Automatic seat utility and a native exit lease for stationary gunners.
return function(M,C,B,S,V,emit)
 if V.policy then return V.policy end
 local Q={};V.policy=Q
 local function live(u)return u~=nil and Unit.alive(u)end
 local function state(u,n)
  if not live(u) then return {} end
  if EntityAux.has_component_master(u,n) then return EntityAux.state_master(u,n) or {} end
  if EntityAux.has_component(u,n) then return EntityAux.state(u,n) or {} end
  return {}
 end
 local function pos(u)if live(u) then local p=Unit.world_position(u,0);return {x=p.x,y=p.y,z=p.z}end end
 local function human(u)
  for _,p in ipairs(M.session and M.session.players or {}) do local go=p.player_go
   if go and go:exists() and go:has('avatar_unit') and go:get('avatar_unit')==u then return true end
  end
 end
 local function free(b)
  local h=state(b.unit,'health');local c=state(b.unit,'character')
  return b.active and live(b.unit) and not h.is_dead and not h.is_downed and not human(b.unit)
   and not c.current_seat_unit and not c.current_carry_unit and not b.post and not b.guard_request
   and not b.objective and not b.job and not b.tactical_job and not b.stratagem_intent and not b.vehicle_order
   and not b.returning and not b.seat_exit and not b.rejoin_probe and not state(b.unit,'interactor').busy
 end
 Q.free=free
 function Q.is_tank(u)
  local info=state(u,'vehicle').vehicle_info or {};local path=Unit.get_data and Unit.get_data(u,'unit_path')
  return info.vehicle_type=='tank' or info.vehicle_type=='tankdestroyer'
   or path=='gameobjects/gameobject_tankdestroyer_01'
 end
 function Q.guns(t)
  local list,seen={},{}
  local function add(u)
   if live(u) and not seen[u] and EntityAux.has_interface(u,'weapon') then
    local a,p=B.weapon(u);seen[u]=true;list[#list+1]={unit=u,ammo=a,profile=p}
   end
  end
  if t.index==1 then add(t.unit) end
  local a=state(t.unit,'seat')
  for i,u in ipairs(a.seat_weapon_units or {}) do if (a.weapon_index_to_seat or {})[i]==t.index then add(u) end end
  return list
 end
 function Q.opportunity(b,t,budget)
  local guns=Q.guns(t);local origin=pos(t.vehicle);if not origin then return false end
  local leader=M.player_anchor or Q.leader_position or origin
  for _,enemy in ipairs(M.enemy_cache or {}) do
   local h=state(enemy.id,'health');local p=pos(enemy.id)
   if p and not h.is_dead and enemy.alive and enemy.enemy and C.distance(p,leader)<=30 then
    for _,gun in ipairs(guns) do
     local a,profile=gun.ammo,gun.profile;local distance=C.distance(pos(gun.unit),p)
     local fit=M.tactics and M.tactics.model.effectiveness(a,state(enemy.id,'health'))
     if not B.dry(a) and fit~=0 and distance<=profile.range and distance>profile.splash+1
      and not B.danger(M.behaviors,pos(t.unit),b.unit) then
      if not budget then return true end
      local target={id=enemy.id,position=p,alive=true,enemy=true}
      local mounted={seat=t.unit,vehicle=t.vehicle,weapons=guns}
      if V.sight(b,mounted,gun,target,budget) then return true end
     end
    end
   end
  end
  return false
 end
 function Q.human_driving(t,leader)
  local c=state(leader,'character');local seats=state(t.vehicle,'seat')
  return c.current_seat_unit==t.vehicle and (seats.seated_units or {})[1]==leader
 end
 function Q.preboard(b,t,budget)
  if t.source=='f8' or t.pilot then return true end
  if Q.human_driving(t,Q.leader) then return true end
  if not Q.opportunity(b,t) then V.release(b,'combat_ended',true);return false end
  -- Use the existing barrel ray budget before interaction, without firing.
  if budget and not Q.opportunity(b,t,budget) then
   t.sight_wait=t.sight_wait or M.clock;t.defending=true
   if M.clock-t.sight_wait>2 then
    b.seat_retry={vehicle=t.vehicle,until_time=M.clock+5};V.release(b,'no_firing_opportunity',true)
   end
   return false
  end
  t.sight_wait=nil
  return true
 end
 local function edge(p)
  if not CameraManager or type(CameraManager.get_viewport)~='function' then return false end
  local viewport=CameraManager:get_viewport()
  if not viewport or type(viewport.window)~='function' or type(viewport.world_to_screen)~='function' then return false end
  local w,h,x,y=viewport:window()
  if type(w)~='number' or type(h)~='number' or type(x)~='number' or type(y)~='number' or w<=0 or h<=0 then return false end
  local q=viewport:world_to_screen(Vector3(p.x,p.y,p.z+1))
  if not q or type(q.x)~='number' or type(q.y)~='number' or type(q.z)~='number' then return false end
  return q.z<0 or q.x<x+w*.1 or q.x>x+w*.9 or q.y<y+h*.1 or q.y>y+h*.9
 end
 Q.edge=edge
 function Q.begin_exit(b,t,reason)
  b.seat_exit={unit=t.unit,vehicle=t.vehicle,reason=reason,started=M.clock}
  b.seat_reboard={vehicle=t.vehicle,until_time=math.huge}
  V.release(b,reason,true)
 end
 function Q.tick(leader,lp)
  Q.leader=leader;Q.leader_position=lp
  if M.clock<(Q.next_tick or 0) then return end;Q.next_tick=M.clock+.25
  for _,b in ipairs(M.bots) do
   local c=state(b.unit,'character');local h=state(b.unit,'health')
   if human(b.unit) then
    b.seat_departure=nil;b.seat_exit=nil
    if b.seat_reboard then b.seat_reboard.until_time=M.clock+5 end
   elseif b.active and not h.is_dead then
    local exiting=b.seat_exit
    if exiting then
     if c.current_seat_unit==exiting.unit or (state(exiting.unit,'seat').seated_units or {})[c.current_seat_index or 1]==b.unit then
      if b.vehicle_input then b.vehicle_input.output_table=C.neutral() end
      V.exit(b,exiting.unit,exiting.reason)
     else
      b.seat_exit=nil;b.returning=true;S.cancel(b)
      if b.seat_reboard and not b.bike_exit_lock then b.seat_reboard.until_time=M.clock+5 end
      emit('gunner_rejoined',{reason=exiting.reason,seconds=M.clock-exiting.started},b.id)
     end
    end
    local t=b.vehicle_order
    if t and not t.pilot and (t.turret or V.mobile(t.vehicle) or Q.is_tank(t.vehicle)) then
     local p=pos(t.vehicle)
     if p and leader and lp then
      local distance=C.distance(lp,p);local obs=b.seat_departure
      if not obs or obs.leader~=leader or obs.vehicle~=t.vehicle then
       obs={leader=leader,vehicle=t.vehicle,time=M.clock,distance=distance};b.seat_departure=obs
      end
      if M.clock-obs.time>=1 then obs.away=distance-obs.distance>=1;obs.distance=distance;obs.time=M.clock end
      local depart=not Q.human_driving(t,leader) and not (M.mobility and M.mobility.driver(t.vehicle)) and (distance>=18 or distance>=12 and obs.away and edge(p))
      if depart then obs.since=obs.since or M.clock else obs.since=nil end
      if obs.since and M.clock-obs.since>=.75 then Q.begin_exit(b,t,'squad_departed') end
     end
    else b.seat_departure=nil end
   end
  end
 end
 function Q.assign(leader,lp,pressure,resources)
  Q.leader=leader;Q.leader_position=lp
  local R=M.tactics and M.tactics.readiness
  for _,r in ipairs(resources) do if r.component=='vehicle' and C.distance(r.position,lp)<=14 then
   local v=state(r.unit,'vehicle');local kind=(v.vehicle_info or {}).vehicle_type
   local exo=kind=='exosuit';local turret=kind=='mannable_turret';local tank=Q.is_tank(r.unit)
   if (V.mobile(r.unit) or turret) and (not R or R.vehicle_usable(r.unit)) then
    for _,b in ipairs(M.bots) do if free(b) and C.distance(pos(b.unit),r.position)<=12 then
     local recent=b.seat_reboard
     local may_board=not recent or recent.vehicle~=r.unit or M.clock>=recent.until_time and C.distance(lp,r.position)<=10
     if b.seat_retry and b.seat_retry.vehicle==r.unit and M.clock<b.seat_retry.until_time then may_board=false end
     local t=may_board and V.find(M.session,r.position,b,{unit=r.unit,automatic=true})
     local selected=state(leader,'interactor').interactable_unit
     if t and not Q.human_driving(t,leader) and (selected==t.unit or selected==t.vehicle or C.distance(lp,t.position)<1.6) then t=nil end
     local prepared=R and R.quiet
     if t and ((t.pilot and (prepared or pressure>=2)) or (not t.pilot and (Q.human_driving(t,leader) or pressure>0 and Q.opportunity(b,t)))) then
      local _,assigned=V.request(M.session,r.position,b,{unit=r.unit,index=t.index,source='automatic'})
      if assigned then return true end
     end
    end end
   end
  end end
 end
 return Q
end
