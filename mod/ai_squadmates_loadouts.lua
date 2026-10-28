-- Read the owner's profile; native inventory construction applies its upgrades.
return function(M,R)
 local L=M.loadouts or {};M.loadouts=L
 function L.pools(record)
  assert(record and record.pad_number~=nil,'Player controller identity unavailable')
  local user=UserManager:get_user_id(record.pad_number);assert(user~=nil,'Player profile unavailable')
  local xp=record.player_go:get('xp');assert(type(xp)=='number','Player rank unavailable')
  local unlocked={}
  for _,name in ipairs(SaveManager:user_get('item_unlocks',user) or {}) do unlocked[name]=true end
  local entitlements=DlcSettings.get_combined_entitlements(user)
  assert(type(entitlements)=='table','Player DLC ownership unavailable')
  return R.collect(LoadoutSettings,CustomizationSettings,function(name,category)
   return unlocked[name] or ProgressionSettings.can_use(name,category,xp) or DlcSettings.can_use(name,entitlements)
  end)
 end
 function L.kit(record,gender)
  local kit=R.pick(L.pools(record),M.random,gender)
  kit.profile={pad_number=record.pad_number,loadout_prefix='loadout_'}
  kit.profile_user=UserManager:get_user_id(record.pad_number)
  return kit
 end
 function L.install()
  L.enabled=true
  if L.hook or type(InventoryComponent)~='table' or type(InventoryComponent.set_loadout)~='function' then return end
  local object=InventoryComponent;local old=object.set_loadout
  local wrapper=function(self,u,e,data,override,...)
   local bot=M.units[u] or (M.takeover and M.takeover.records and M.takeover.records[u])
   local kit=bot and bot.kit
   if L.enabled and M.enabled and not data and kit and kit.profile and override==kit.loadout then
    assert(UserManager:get_user_id(kit.profile.pad_number)==kit.profile_user,'Bot owner profile changed')
    data=kit.profile
   end
   return old(self,u,e,data,override,...)
  end
  L.hook={object=object,original=old,wrapper=wrapper};object.set_loadout=wrapper
 end
 function L.uninstall()
  L.enabled=false
  local h=L.hook
  if h and h.object.set_loadout==h.wrapper then h.object.set_loadout=h.original;L.hook=nil end
  -- If another known layer encloses us, the retained wrapper is a pass-through.
 end
 L.install();return L
end
