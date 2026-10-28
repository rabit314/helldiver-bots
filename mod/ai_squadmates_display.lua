-- Native HUD drawing only; no retained GUI handles or player-slot changes.
return function(M,emit)
 local D=M.display or {hooks={}};M.display=D
 local function live(u)return u~=nil and Unit.alive(u)end
 local function state(u,n)
  if live(u) and EntityAux.has_component(u,n) then return EntityAux.state(u,n) end
 end
 local function active()
  local sm=Boot and Boot.state_machine;local s=M.session
  if not M.enabled or not s or not sm or sm.state~=s or sm.current_state_name~='game' or s.wants_exit then return false end
  local count,owned=0,false
  for _,p in ipairs(s.players or {}) do
   local go=p.player_go
   if go and go:exists() then count=count+1;owned=owned or go:owned() end
  end
  return count==1 and owned
 end
 local function present(b)
  local h=state(b.unit,'health')
  return b.active and h and not h.is_dead
 end
 local function draw_safe(fn,...)
  local ok,err=pcall(fn,...)
  if not ok and not D.failed then
   D.failed=true;emit('squad_display_error',{message=tostring(err)},nil,'errors')
  end
 end
 function D.count(gui)
  if not active() or not gui then return end
  local controlled={}
  for _,p in ipairs(M.session.players or {}) do local go=p.player_go
   if go and go:exists() and go:has('avatar_unit') then controlled[go:get('avatar_unit')]=true end
  end
  local n=0;for _,b in ipairs(M.bots) do if present(b) and not controlled[b.unit] then n=n+1 end end
  local design=gui.design_resolution or {width=1280,height=720}
  local resolution=gui.ui_scale_resolution or 1
  local screen=gui.screen_resolution or {width=design.width*resolution,height=design.height*resolution}
  local scale=gui.ignore_size_scale and 1 or (gui.ui_scale or 1)
  if screen.width<=0 or screen.height<=0 or scale<=0 then return end
  local pending=math.max(0,M.pending_count or 0)
  local digits=tostring(math.max(99,n,pending));local label_width=61;local number_width=#digits*7
  if type(gui.get_text_extents)=='function' then
   label_width=gui:get_text_extents('ON GROUND',nil,11,true)
   number_width=gui:get_text_extents(digits,nil,11,true)
  end
  local width=math.ceil(label_width+number_width+12);local height=28
  local px=screen.width-12*resolution-width*scale
  local py=screen.height-24*resolution-height*scale
  -- Plugin drawing can disable position scaling while still scaling sizes.
  -- Use pixel anchors in a private view; preserve the shared HUD's flags/offset.
  local view=setmetatable({offset={x=0,y=0,z=0},ignore_position_scale=true},{__index=gui})
  view:rect(Vector3(px,py,40),Vector2(width,height),Color(150,0,0,0))
  local color=Color(240,100,225,240)
  view:text('CALLED',Vector3(px+3*scale,py+2*scale,41),color,nil,11)
  view:text('ON GROUND',Vector3(px+3*scale,py+15*scale,41),color,nil,11)
  view:text(tostring(pending),Vector3(px+(label_width+9)*scale,py+2*scale,41),color,nil,11)
  view:text(tostring(n),Vector3(px+(label_width+9)*scale,py+15*scale,41),color,nil,11)
 end
 function D.map(self,info,gui,origin)
  if M.recovery then M.recovery.observe_map(info) end
  if not active() or not gui or not info or (info.fade or 0)<=0 then return end
  local level=self.generated_level or self.custom_level
  if not level or not level.map_size or not level.width or not level.height then return end
  local size=Vector2Aux.unbox(level.map_size);local sx,sy=size.x*48,size.y*48
  if sx<=0 or sy<=0 then return end
  local scale=math.min(350/sx,350/sy)*(info.map_zoom or 1)
  local rotate=Quaternion(Vector3(0,0,-1),math.rad(-45))
  local off=gui.offset or {};local ox,oy,oz=off.x or 0,off.y or 0,off.z or 0
  local ok,err=pcall(function()
   gui:move(Vector3(origin.x,origin.y,origin.z))
   for _,b in ipairs(M.bots) do if present(b) then
    local u=b.unit
    if EntityAux.has_component_master(u,'character') then
     local c=EntityAux.state_master(u,'character');if live(c.current_seat_unit) then u=c.current_seat_unit end
    end
    local p=Unit.world_position(u,0);local x,y=p.x,p.y
    local q=Quaternion.rotate(rotate,Vector3(x-level.width*12,y-level.height*12,0))
    local h=state(b.unit,'health');local alpha=255*(info.fade or 1)
    local color=h.is_downed and Color(alpha,255,185,70) or Color(alpha,65,220,245)
    -- Fixed small dots, independent of map zoom; native map clipping stays active.
    local x,y=q.x*scale*2,q.y*scale*2
    gui:rect(Vector3(x-3,y-3,18),Vector2(6,6),Color(220*(info.fade or 1),0,0,0))
    gui:rect(Vector3(x-1.75,y-1.75,19),Vector2(3.5,3.5),color)
   end end
  end)
  gui:move(Vector3(ox,oy,oz));if not ok then error(err) end
 end
 function D.install()
  if type(Hud)~='table' then return end
  local function hook(name,make)
   if D.hooks[name] or type(Hud[name])~='function' then return end
   local old=Hud[name];local wrapper=make(old)
   D.hooks[name]={object=Hud,original=old,wrapper=wrapper};Hud[name]=wrapper
  end
  hook('draw_plugins',function(old)return function(self,...)
   local result=old(self,...)
   if self.plugins_enabled~=false then draw_safe(D.count,self.hd_gui) end
   return result
  end end)
  hook('draw_map',function(old)return function(self,a,b,info,gui,...)
   local offset=gui and gui.offset or {};local origin={x=offset.x or 0,y=offset.y or 0,z=offset.z or 0}
   local result=old(self,a,b,info,gui,...)
   draw_safe(D.map,self,info,gui,origin);return result
  end end)
 end
 function D.uninstall()
  for name,h in pairs(D.hooks) do if h.object[name]==h.wrapper then h.object[name]=h.original end end
  D.hooks={};D.failed=nil
 end
 D.install();return D
end
