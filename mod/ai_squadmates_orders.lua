-- Cursor projection and temporary world markers for explicit guard orders.
local O={revision='0.11.2'}
function O.new() return {markers={}} end
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<1e8 end
local function snapshot(data)
 local c=data and data.cursor
 if c then
  local x,y=c.x,c.y
  if finite(x) and finite(y) then return {x=x,y=y} end
 end
end
function O.install(M)
 if M.cursor_hook or not InputComponent or not InputComponent.update_masters then return end
 local old=InputComponent.update_masters
 local wrapper=function(self,entities,dt,...)
  -- Input vectors are temporary native values. Copy coordinates before the
  -- native input update makes more vectors and before a bridge command runs.
  for u,e in pairs(entities) do
   local s=e.state;local c=s and s.pad_number~=nil and snapshot(s.input_data)
   if c and s.input_data.is_active~=false and s.has_focus~=false then
    M.cursor_sample={unit=u,x=c.x,y=c.y,time=M.clock}
   end
  end
  return old(self,entities,dt,...)
 end
 InputComponent.update_masters=wrapper;M.cursor_hook={original=old,wrapper=wrapper}
end
function O.cursor(M,u,data)
 local c=snapshot(data)
 if c then return c,'direct_snapshot' end
 local s=M.cursor_sample
 if s and s.unit==u and M.clock-s.time<=.35 then return {x=s.x,y=s.y},'native_frame_snapshot' end
 return nil,'cursor_nonfinite'
end
function O.uninstall(M)
 local h=M.cursor_hook
 if h and InputComponent.update_masters==h.wrapper then InputComponent.update_masters=h.original end
 M.cursor_hook=nil;M.cursor_sample=nil
end
function O.ground_point(cursor,plane)
 cursor={x=cursor.x,y=cursor.y}
 if not finite(cursor.x) or not finite(cursor.y) then return nil,'cursor_nonfinite' end
 local viewport=CameraManager:get_viewport();local camera=CameraManager:camera()
 if not viewport or not camera then return nil,'camera_missing' end
 local f=Camera.local_position(camera);local from={x=f.x,y=f.y,z=f.z}
 local v=viewport:screen_to_world(cursor.x,cursor.y,CameraManager.follow_distance)
 local point={x=v.x,y=v.y,z=v.z};local mode='native_depth'
 local dz=point.z-from.z
 if finite(dz) and math.abs(dz)<.00001 then
  -- A zero/degenerate follow-depth sample is not a failed cursor ray. Build
  -- the same screen ray using two independent nonzero depths instead.
  local a=viewport:screen_to_world(cursor.x,cursor.y,1);from={x=a.x,y=a.y,z=a.z}
  local b=viewport:screen_to_world(cursor.x,cursor.y,100);point={x=b.x,y=b.y,z=b.z}
  dz=point.z-from.z;mode='two_depth_ray'
 end
 if not finite(dz) or math.abs(dz)<.00001 then return nil,'projection_parallel',
  {from=from,sample=point,depth=CameraManager.follow_distance,cursor={x=cursor.x,y=cursor.y}} end
 -- Match InputAux.project_onto_unit_plane. screen_to_world is a depth sample,
 -- not a forward-only terrain ray; rejecting negative t rejects native aims.
 local t=(plane.z-from.z)/dz
 local p={x=from.x+(point.x-from.x)*t,y=from.y+(point.y-from.y)*t,z=plane.z}
 if not p or not finite(p.x) or not finite(p.y) or not finite(p.z) then return nil,'projection_invalid' end
 return {x=p.x,y=p.y,z=p.z},nil,mode
end
function O.show(ctx,id,p,now)
 ctx.markers[id]={position={x=p.x,y=p.y,z=p.z},expires=now+6}
end
function O.remove(ctx,id) ctx.markers[id]=nil end
local function reset(ctx)
 if ctx.line then LineObject.reset(ctx.line) end
end
function O.release(ctx)
 -- World destruction invalidates this raw native handle. Forget it without
 -- calling LineObject, including when the next world reuses the same address.
 ctx.markers={};ctx.line=nil;ctx.world=nil;ctx.failed=false
end
function O.clear(ctx,world)
 ctx.markers={}
 -- Only a caller still executing in the owning mission can reset the line.
 -- pcall cannot protect an expired pointer from a native access violation.
 if not world or ctx.world~=world then O.release(ctx);return end
 if ctx.line then pcall(reset,ctx) end
end
function O.draw(ctx,world,now,emit)
 local any=false
 for id,marker in pairs(ctx.markers) do
  if now>=marker.expires then ctx.markers[id]=nil else any=true end
 end
 if ctx.world~=world then ctx.world=world;ctx.line=nil;ctx.failed=false end
 if ctx.failed or (not any and not ctx.line) then return end
 local ok,err=pcall(function()
  if not ctx.line then ctx.line=World.create_line_object(world,false) end
  reset(ctx)
  for _,marker in pairs(ctx.markers) do
   local p=marker.position;local center=Vector3(p.x,p.y,p.z+.08)
   local color=marker.kind=='stratagem' and Color(220,255,100,60) or Color(255,70,220,255)
   for _,radius in ipairs(marker.radius and {marker.radius} or {.8,.9}) do
    LineObject.add_circle(ctx.line,color,center,radius,Vector3(0,0,1),32)
   end
  end
  LineObject.dispatch(world,ctx.line)
 end)
 if not ok then
  ctx.failed=true
  if ctx.line then pcall(reset,ctx) end
  emit('guard_marker_error',{message=tostring(err)},nil,'errors')
 end
end
return O
