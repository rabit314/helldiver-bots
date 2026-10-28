-- Bounded, sequenced telemetry. Python persists and rotates these records.
local T={}
local function quote(s)
 return '"'..tostring(s):gsub('[%z\1-\31\\"]',function(c)
  if c=='"' then return '\\"' elseif c=='\\' then return '\\\\' end
  return string.format('\\u%04x',string.byte(c))
 end)..'"'
end
local function encode(v)
 local t=type(v)
 if t=='nil' then return 'null' end
 if t=='boolean' then return v and 'true' or 'false' end
 if t=='number' then
  return (v==v and v~=math.huge and v~=-math.huge) and tostring(v) or 'null'
 end
 if t=='table' then
  local fields={}
  for k,value in pairs(v) do fields[#fields+1]=quote(k)..':'..encode(value) end
  return '{'..table.concat(fields,',')..'}'
 end
 return quote(v)
end
function T.new(instance,capacity)
 local log={instance=tostring(instance),sequence=0,capacity=capacity or 2048,records={}}
 function log:emit(channel,kind,fields,clock,bot_id)
  self.sequence=self.sequence+1
  local record={seq=self.sequence,channel=channel,kind=kind,sim_time=clock,bot_id=bot_id,data=fields or {}}
  self.records[((self.sequence-1)%self.capacity)+1]=record
 end
 function log:batch(after,instance,limit,status,bots,pending)
  if tostring(instance)~=self.instance then after=0 end
  after=math.max(0,tonumber(after) or 0)
  limit=math.max(1,math.min(tonumber(limit) or 48,96))
  local oldest=math.max(1,self.sequence-self.capacity+1)
  local first=math.max(after+1,oldest)
  local rows,bytes,last={},0,math.min(after,self.sequence)
  for seq=first,math.min(self.sequence,first+limit-1) do
   local record=self.records[((seq-1)%self.capacity)+1]
   local row=encode(record)
   if bytes+#row>48000 and #rows>0 then break end
   rows[#rows+1]=row;bytes=bytes+#row;last=seq
  end
  return '{"instance":'..quote(self.instance)..',"cursor":'..last..
   ',"gap":'..math.max(0,oldest-after-1)..',"has_more":'..tostring(last<self.sequence)..
   ',"active":'..bots..',"pending":'..pending..',"status":'..quote(status)..
   ',"events":['..table.concat(rows,',')..']}'
 end
 return log
end
return T
