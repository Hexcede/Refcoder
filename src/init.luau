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
	return string.pack(`<I4{string.rep(`s8`, #strings)}`, #strings, table.unpack(strings))
end
local function decodeStringArray(data: string, readStart: number?)
	local length, pointer = string.unpack("<I4", data, readStart)

	local refs = table.create(length)
	local value
	for i=1, length do
		value, pointer = string.unpack(`s8`, data, pointer)
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

local VALID_TYPES = { "string", "number", "boolean", "table", "Vector3", "CFrame", "static" }

type EncodeState = {
	References: {[any]: number};
	Encodings: {[number]: any};
	Top: number;
	Statics: {[any]: any};
}
type DecodeState = {
	Decodings: {[number]: any};
	Encodings: {[number]: any};
	Statics: {[any]: any};
}

local encode
local function encodeValue(value: any, state: EncodeState, isStatic: boolean?)
	local encoded, typeIndex = encode(value, state, isStatic)
	if not typeIndex or not encoded then return end
	return `{string.pack("<B", typeIndex)}{encoded}`
end

local function getRefId(value: any, state: EncodeState, isStatic: boolean?)
	if value ~= value then return 0 end
	if value == nil then return nil end

	local refId = state.References[value]
	if not refId then
		-- Select the next reference ID
		refId = state.Top
		state.Top += 1

		-- Insert the encoding & ref ID
		state.References[value] = refId
		state.Encodings[refId] = encodeValue(value, state, isStatic)
	end
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
		return string.pack(`<{string.rep("nnn", 4)}`, value:GetComponents()), typeIndex
	elseif type(value) == "table" then
		-- Count all entries
		local size = 0
		for index, value in pairs(value) do
			size += 1
		end
		
		-- Collect all index/value refs into an indices/values list
		local indices = table.create(size)
		local values = table.create(size)
		for index, value in pairs(value) do
			table.insert(indices, getRefId(index, state))
			table.insert(values, getRefId(value, state))
		end

		-- If there is no state, it's the top-most table, so we manually insert ref ID 1
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
		return CFrame.new(string.unpack(`<{string.rep("nnn", 4)}`, value))
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
		Top = 1;
		Statics = statics or {};
	}
	
	-- Reserve a refId for the data
	local refId = getRefId(data, state)
	if refId == 0 then
		state.Encodings[1] = encodeValue(0/0, state, true)
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
