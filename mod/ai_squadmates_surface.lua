-- Resolve actual SAM interaction regions; display markers are not panel surfaces.
return function(M,C,S,O,emit)
 local P={};local previous=O.next_approach
 local function point(p)return {x=p.x,y=p.y,z=p.z}end
 local function live(u)return u~=nil and Unit.alive(u)end
 function O.surface(t,root)
  local marker=O.marker(t,root)
  local settings=LuaSettingsManager and LuaSettingsManager:get_settings_by_unit(t.unit)
  local info=settings and settings.objective_info or {}
  local sam=info.display_name_plural=='mission_objective_samsite' or info.display_name_single=='mission_objective_samsite'
  if not sam then return marker end
  t.sam_surface=true
  t.console_search_started=t.console_search_started or M.clock
  if not t.console_regions and M.clock-t.console_search_started>10 then
   O.release(t.owner,'console_unavailable');return marker
  end
  local b=t.owner;local token=t.console_query
  if token and M.clock-token.started>1 then t.console_query=nil;t.next_console_query=M.clock+1 end
  if not t.console_regions and not t.console_query and M.clock>=(t.next_console_query or 0) then
   if not b or not b.active or not live(b.unit) or type(PhysicsWorld.overlap)~='function' then t.surface_wait=true;return marker end
   local q={started=M.clock,generation=M.generation,session=M.session,unit=t.unit};t.console_query=q
   local callback=S.guard(b,'sam_console_overlap',function(actors)
    if t.console_query~=q or t.owner~=b or not b.active or not live(b.unit) or not live(q.unit)
      or q.session~=M.session or q.generation~=M.generation then return end
    assert(type(actors)=='table','Invalid console overlap reply')
    local regions={}
    for _,actor in ipairs(actors) do if Actor.unit(actor)==q.unit then
     local p=Actor.position(actor)
     if p and type(p.x)=='number' and type(p.y)=='number' and type(p.z)=='number'
       and p.x==p.x and p.y==p.y and C.distance(p,marker)<6 and math.abs(p.z-root.z)<4 then
      local duplicate=false
      for _,old in ipairs(regions) do if C.distance(old,p)<.2 then duplicate=true;break end end
      if not duplicate and #regions<8 then regions[#regions+1]={x=p.x,y=p.y,z=root.z} end
     end
    end end
    table.sort(regions,function(a,z)
     local p=t.cursor_point or Unit.world_position(b.unit,0);local da,dz=C.distance(p,a),C.distance(p,z)
     if math.abs(da-dz)>.01 then return da<dz end
     if a.x~=z.x then return a.x<z.x end;return a.y<z.y
    end)
    t.console_query=nil
    if #regions>0 then t.console_regions=regions;t.console_index=1;t.approach=nil;t.surface_wait=nil
    else t.next_console_query=M.clock+2 end
    emit('objective_console_regions',{root=root,marker=marker,regions=regions,
     source='native interactor overlap actors',count=#regions},b.id)
   end,function()t.console_query=nil;t.next_console_query=M.clock+2 end)
   S.guard(b,'sam_console_submit',function()
   PhysicsWorld.overlap(World.physics_world(M.session.world_proxy:get_world()),callback,
    'shape','capsule','position',Vector3(marker.x,marker.y,root.z+.5),'size',Vector3(5,.5,0),
    'rotation',Quaternion.look(Vector3.up(),Vector3.forward()),'collision_filter','interactor')
   end,function()t.console_query=nil;t.next_console_query=M.clock+2 end)()
  end
  local region=t.console_regions and t.console_regions[t.console_index or 1]
  t.surface_wait=not region
  if not region then return marker end
  local outward=C.distance(marker,region)>.25 and C.direction(marker,region) or C.direction(root,region)
  t.surface_outward=outward;t.surface_offset=true;t.selected_surface=point(region)
  return point(region)
 end
 function O.next_approach(b,reason)
  local t=b.objective
  previous(b,reason)
  if t and t.sam_surface and t.console_regions and #t.console_regions>1 and M.clock>=(t.next_panel or 0) then
   t.console_index=(t.console_index or 1)%#t.console_regions+1;t.next_panel=M.clock+2
   t.approach=nil;t.surface_base=nil;t.best_distance=nil;t.last_motion=M.clock
  end
 end
 return P
end
