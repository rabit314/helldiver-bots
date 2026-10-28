-- Original loadout selection. Catalogs are read, never edited.
local R={revision='0.18.5'}
function R.generator(seed)
 local value=math.floor(tonumber(seed) or 1)%2147483647
 if value<=0 then value=1 end
 return function(count)
  assert(count>=1,'Empty random choice')
  value=(value*16807)%2147483647
  return (value%count)+1
 end
end
function R.collect(loadouts,customization,available)
 local p={primary_weapon={},perks={},stratagems={},groups={offensive={},defensive={},supply={}},helmet={},body={},cape={},static={},slots=0}
 local static={}
 for _,name in ipairs(loadouts.static_stratagems or {}) do
  static[name]=true;p.static[#p.static+1]=name
 end
 p.slots=math.max(0,(loadouts.nr_of_stratagem_slots or #p.static)-#p.static)
 for _,category in ipairs({'primary_weapon','perks','stratagems'}) do
  for _,item in ipairs(loadouts[category] or {}) do
   local group=category=='stratagems' and p.groups[item.stratagem_type]
   -- Match the normal loadout screen: no support drops or melee weapons.
   if item.name and not static[item.name] and item.group~='support' and item.group~='melee'
     and (category~='stratagems' or group)
     and available(item.name,category) then
    p[category][#p[category]+1]=item.name
    if group then group[#group+1]=item.name end
   end
  end
 end
 for _,category in ipairs({'helmet','body','cape'}) do
  for index,item in ipairs(customization[category] or {}) do
   if item.name and item.name~='cus_cape_tutorial' and available(item.name,'customization') then
    p[category][#p[category]+1]={index=index,name=item.name}
   end
  end
 end
 return p
end
function R.pick(p,random_index,gender)
 local function pick(category)
  local choices=p[category]
  assert(choices and #choices>0,'No unlocked '..category..' found; deployment cancelled')
  return choices[random_index(#choices)]
 end
 local gun,perk=pick('primary_weapon'),pick('perks')
 local helmet,body,cape=pick('helmet'),pick('body'),pick('cape')
 local stratagems,used={},{}
 for _,name in ipairs(p.static or {}) do stratagems[#stratagems+1]=name end
 for slot=1,p.slots or 0 do
  local group=({'offensive','defensive','supply'})[slot] or 'stratagems'
  local choices={}
  for _,name in ipairs(p.groups[group] or p.stratagems) do
   if not used[name] then choices[#choices+1]=name end
  end
  -- The wildcard repeats only if all eligible items have already been selected.
  if #choices==0 and slot>3 then choices=p.stratagems end
  assert(#choices>0,'No unlocked '..group..' stratagems found; deployment cancelled')
  local name=choices[random_index(#choices)]
  stratagems[#stratagems+1]=name;used[name]=true
 end
 return {loadout={primary_weapon=gun,sidearm_weapon='weapon_pistol',perk=perk,stratagems=stratagems},
  customization={helmet=helmet.index,body=body.index,cape=cape.index,gender=gender or 1},
  names={primary_weapon=gun,perk=perk,helmet=helmet.name,body=body.name,cape=cape.name,stratagems=stratagems}}
end
return R
