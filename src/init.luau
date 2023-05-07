local Refcoder = {}

local function minByteSize(maxInt: number)
	return math.max(1, math.ceil(math.log(maxInt + 1, 256)))
end

local function encodeRefId(refId: number)
	local refSize = minByteSize(math.max(0, refId))
	return string.pack(`<BI{refSize}`, refSize, refId)
end
local function decodeRefId(data: string)
	local refSize, pointer = string.unpack("<B", data)
	return string.unpack(`I{refSize}`, data, pointer)
end
local function encodeRefArray(refs: {number})
	local refSize = minByteSize(math.max(0, table.unpack(refs)))
	return string.pack(`<I4B{string.rep(`I{refSize}`, #refs)}`, #refs, refSize, table.unpack(refs))
end
local function decodeRefArray(data: string, readStart: number?)
	local length, refSize, pointer = string.unpack("<I4B", data, readStart)

	local refs = table.create(length)
	local refId
	for i=1, length do
		refId, pointer = string.unpack(`I{refSize}`, data, pointer)
		table.insert(refs, refId)
	end
	return refs, pointer
end

local function encodeStringArray(strings: {string})
	return string.pack(`<I4{string.rep("s8", #strings)}`, #strings, table.unpack(strings))
end
local function decodeStringArray(data: string, readStart: number?)
	local length, pointer = string.unpack("<I4", data, readStart)

	local refs = table.create(length)
	local value
	for i=1, length do
		value, pointer = string.unpack("s8", data, pointer)
		table.insert(refs, value)
	end
	return refs, pointer
end

local function encodeRefTable(indices: {number}, values: {number})
	return `{encodeRefArray(indices)}{encodeRefArray(values)}`
end
local function decodeRefTable(data: string, readStart: number?)
	local indices, pointer = decodeRefArray(data, readStart)
	local values
	values, pointer = decodeRefArray(data, pointer)

	return indices, values, pointer
end

local RAD_90 = math.rad(90)
local RAD_180 = math.rad(180)

-- https://dom.rojo.space/binary.html#cframe
local CFRAME_SPECIAL_CASES = {
	CFrame.Angles(0, 0, 0);			CFrame.Angles(0, RAD_180, 0);
	CFrame.Angles(RAD_90, 0, 0);		CFrame.Angles(-RAD_90, -RAD_180, 0);
	CFrame.Angles(0, RAD_180, RAD_180);	CFrame.Angles(0, 0, RAD_180);
	CFrame.Angles(-RAD_90, 0, 0);		CFrame.Angles(RAD_90, RAD_180, 0);
	CFrame.Angles(0, RAD_180, RAD_90);	CFrame.Angles(0, 0, -RAD_90);
	CFrame.Angles(0, RAD_90, RAD_90);	CFrame.Angles(0, -RAD_90, -RAD_90);
	CFrame.Angles(0, 0, RAD_90);		CFrame.Angles(0, -RAD_180, -RAD_90);
	CFrame.Angles(0, -RAD_90, RAD_90);	CFrame.Angles(0, RAD_90, -RAD_90);
	CFrame.Angles(-RAD_90, -RAD_90, 0);	CFrame.Angles(RAD_90, RAD_90, 0);
	CFrame.Angles(0, -RAD_90, 0);		CFrame.Angles(0, RAD_90, 0);
	CFrame.Angles(RAD_90, -RAD_90, 0);	CFrame.Angles(-RAD_90, RAD_90, 0);
	CFrame.Angles(0, RAD_90, RAD_180);	CFrame.Angles(0, -RAD_90, RAD_180);
}

local VALID_TYPES = { "string", "number", "boolean", "table", "Vector3", "CFrame", "static", "copy_of" }
local TYPE_COPY_OF = assert(table.find(VALID_TYPES, "copy_of"))

type EncodeState = {
	References: {[any]: number};
	Encodings: {[number]: any};
	EncodingsToRefs: {[string]: number};
	Top: number;
	Statics: {[any]: any};
}
type DecodeState = {
	Decodings: {[number]: any};
	Encodings: {[number]: any};
	Statics: {[any]: any};
}

local encode
local function encodeValue(encoded: string, typeIndex: number)
	if not typeIndex or not encoded then return end
	return `{string.pack("<B", typeIndex)}{encoded}`
end

local function getRefId(value: any, state: EncodeState, isStatic: boolean?)
	if value ~= value then return 0 end
	if value == nil then return nil end
	
	local refId = state.References[value]
	if refId then return refId end
	
	-- Select the next reference ID
	refId = state.Top
	state.Top += 1
	
	-- Insert the encoding & ref ID
	state.References[value] = refId
	
	-- Encode the value & pack it
	local encoded, typeIndex = encode(value, state, isStatic)
	local packed = encodeValue(encoded, typeIndex)
	
	-- Look for a ref with duplicate data
	local encodingId = state.EncodingsToRefs[packed]
	if encodingId then
		-- Replace with a copy_of for the encoded data
		packed = encodeValue(encodeRefId(encodingId), TYPE_COPY_OF)
	else
		-- Store the ref ID of this data
		state.EncodingsToRefs[packed] = refId
	end
	
	state.Encodings[refId] = packed
	return refId
end

function encode(value: any, state: EncodeState, isStatic: boolean?)
	local static = if not isStatic then state.Statics[value] else nil
	if static ~= nil then
		return encodeRefId(getRefId(static, state, true)), table.find(VALID_TYPES, "static")
	end
	
	local typeIndex = table.find(VALID_TYPES, typeof(value))
	if not typeIndex then return end
	
	if type(value) == "string" then
		return value, typeIndex
	elseif type(value) == "number" then
		return string.pack("<n", value), typeIndex
	elseif type(value) == "boolean" then
		return if value then "\0" else "", typeIndex
	elseif typeof(value) == "Vector3" then
		return string.pack("<nnn", value.X, value.Y, value.Z), typeIndex
	elseif typeof(value) == "CFrame" then
		local caseId = table.find(CFRAME_SPECIAL_CASES, value.Rotation)
		local packFormat = string.rep("nnn", if caseId == nil then 4 else 1)
		return string.pack(`<B<{packFormat}`, caseId or 0, value:GetComponents()), typeIndex
	elseif type(value) == "table" then
		-- Count all entries
		local size = 0
		for _index, _value in pairs(value) do
			size += 1
		end
		
		-- Collect all index/value refs into an indices/values list
		local indices = table.create(size)
		local values = table.create(size)
		
		for subIndex, subValue in pairs(value) do
			table.insert(indices, getRefId(subIndex, state))
			table.insert(values, getRefId(subValue, state))
		end
		
		-- Encode the keys/values
		return encodeRefTable(indices, values), typeIndex
	end
	return nil
end

local decodeByRefId
local function decode(refId: number, encoded: string, state: DecodeState)
	local valueTypeId, pointer = string.unpack("<B", encoded)
	
	local valueType = VALID_TYPES[valueTypeId]
	if not valueType then return nil end
	
	local value = string.sub(encoded, pointer)
	if valueType == "static" then
		return state.Statics[decodeByRefId(decodeRefId(value), state)]
	elseif valueType == "string" then
		return value
	elseif valueType == "number" then
		return string.unpack("<n", value)
	elseif valueType == "boolean" then
		return value == "\0"
	elseif valueType == "Vector3" then
		return Vector3.new(string.unpack("<nnn", value))
	elseif valueType == "CFrame" then
		local cframeCase, pointer = string.unpack("<B", value)
		if cframeCase ~= 0 then
			local x, y, z = string.unpack("<nnn", value, pointer)
			return CFrame.new(x, y, z) * CFRAME_SPECIAL_CASES[cframeCase]
		else
			local x, y, z, R00, R01, R02, R10, R11, R12, R20, R21, R22 = string.unpack(`<{string.rep("nnn", 4)}`, value, pointer)
			return CFrame.new(x, y, z, R00, R01, R02, R10, R11, R12, R20, R21, R22)
		end
	elseif valueType == "table" then
		local decoded = {}
		state.Decodings[refId] = decoded
		
		local indices, values = decodeRefTable(value)
		
		for i, indexRefId in ipairs(indices) do
			local valueRefId = values[i]
			local index = decodeByRefId(indexRefId, state)
			local value = decodeByRefId(valueRefId, state)

			if index == nil or value == nil then continue end

			decoded[index] = value
		end
		return decoded
	elseif valueType == "copy_of" then
		local encodingId = decodeRefId(value)
		if not encodingId then return nil end

		-- Grab the data stored for the target ref directly, and decode it
		return decode(refId, state.Encodings[encodingId], state)
	end
	return nil
end

function decodeByRefId(refId: number, state: DecodeState)
	-- NaN
	if refId == 0 then return 0/0 end
	
	-- Look up the decoded value, and return it if it already exists
	local decoded = state.Decodings[refId]
	if decoded ~= nil then return decoded end
	
	-- Look up the encoded value, if it is defined
	local encoded = state.Encodings[refId]
	if not encoded then return nil end
	
	-- Decode the encoded value
	decoded = decode(refId, encoded, state)
	state.Decodings[refId] = decoded
	
	return decoded
end

local function invertTable<K, V>(tab: {[K]: V}): {[V]: K}
	local out = table.create(#tab)
	for index, value in tab do
		out[value] = index
	end
	return out
end

function Refcoder.encode<K, V>(data, statics: {[K]: V}?)
	-- Define state
	local state = {
		References = {};
		Encodings = {};
		EncodingsToRefs = {};
		Top = 1;
		Statics = statics or {};
	}
	
	-- Reserve a refId for the data
	local refId = getRefId(data, state)
	if refId == 0 then
		state.Encodings[state.Top] = encodeValue(encode(0/0, state, true))
	end
	return encodeStringArray(state.Encodings)
end

function Refcoder.decode<K, V>(data, statics: {[K]: V}?, readStart: number?)
	-- Define state
	local state = {
		Encodings = decodeStringArray(data, readStart);
		Decodings = {};
		Statics = invertTable(statics or {});
	}
	return decodeByRefId(1, state)
end

return Refcoder
