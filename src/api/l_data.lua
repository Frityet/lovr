local ffi = require 'ffi'
local data = ...
local floor = math.floor

local ARRAY_MAGIC = 0x4c444152
local SPAN_MAGIC = 0x4c445350
local ALIGNMENT = 32
local UINT32_MAX = 0xffffffff

ffi.cdef[[
typedef struct __attribute__((aligned(32))) {
  const uint32_t magic;
  const uint32_t length;
  const uint32_t stride;
  const uint32_t size;
  const uint32_t element;
  const uint32_t reserved[3];
  uint8_t data[?] __attribute__((aligned(32)));
} lovr_data_array;

typedef struct {
  const uint32_t magic;
  const uint32_t length;
  const uint32_t stride;
  const uint32_t size;
  const uint32_t element;
  const uint32_t reserved;
  uint8_t* const data;
} lovr_data_span;
]]

local aliases = {
  byte = 'uint8_t',
  i8 = 'int8_t',
  u8 = 'uint8_t',
  i8x4 = 'int8_t[4]',
  u8x4 = 'uint8_t[4]',
  sn8x4 = 'int8_t[4]',
  un8x4 = 'uint8_t[4]',
  sn10x3 = 'uint32_t',
  un10x3 = 'uint32_t',
  i16 = 'int16_t',
  i16x2 = 'int16_t[2]',
  i16x4 = 'int16_t[4]',
  u16 = 'uint16_t',
  u16x2 = 'uint16_t[2]',
  u16x4 = 'uint16_t[4]',
  sn16x2 = 'int16_t[2]',
  sn16x4 = 'int16_t[4]',
  un16x2 = 'uint16_t[2]',
  un16x4 = 'uint16_t[4]',
  int = 'int32_t',
  i32 = 'int32_t',
  i32x2 = 'int32_t[2]',
  i32x3 = 'int32_t[3]',
  i32x4 = 'int32_t[4]',
  uint = 'uint32_t',
  u32 = 'uint32_t',
  u32x2 = 'uint32_t[2]',
  u32x3 = 'uint32_t[3]',
  u32x4 = 'uint32_t[4]',
  f16x2 = 'uint16_t[2]',
  f16x4 = 'uint16_t[4]',
  float = 'float',
  f32 = 'float',
  vec2 = 'float[2]',
  f32x2 = 'float[2]',
  vec3 = 'float[3]',
  f32x3 = 'float[3]',
  vec4 = 'float[4]',
  f32x4 = 'float[4]',
  mat2 = 'float[4]',
  mat3 = 'float[9]',
  mat4 = 'float[16]',
  index16 = 'uint16_t',
  index32 = 'uint32_t'
}

local elementTypes = {}
local arrayMethods = {}
local spanMethods = {}
local arrayCType
local spanCType

local function checked_integer(value, label, allowZero)
  assert(
    type(value) == 'number' and
    value >= (allowZero and 0 or 1) and
    value <= UINT32_MAX and
    floor(value) == value,
    label .. ' must be ' .. (allowZero and 'a nonnegative' or 'a positive') .. ' integer'
  )
  return value
end

local function resolve_element_type(spec)
  if type(spec) == 'string' then
    spec = aliases[spec] or spec
  end

  local ok, ctype = pcall(ffi.typeof, spec)
  assert(ok, 'invalid DataArray element ctype: ' .. tostring(ctype))

  local sizeOk, size = pcall(ffi.sizeof, ctype)
  assert(sizeOk and size > 0 and size <= UINT32_MAX, 'DataArray element ctype must have a fixed nonzero size')

  local alignment = ffi.alignof(ctype)
  assert(alignment <= ALIGNMENT, 'DataArray element alignment exceeds 32 bytes')

  for i = 1, #elementTypes do
    if elementTypes[i].ctype == ctype then
      return elementTypes[i]
    end
  end

  local info = {
    id = #elementTypes + 1,
    ctype = ctype,
    pointer = ffi.typeof('$ *', ctype),
    size = size,
    alignment = alignment,
    name = tostring(ctype)
  }
  elementTypes[info.id] = info
  return info
end

local function get_info(container)
  local info = elementTypes[tonumber(container.element)]
  assert(info, 'DataArray element type is not registered in this Lua state')
  return info
end

local function is_array(value)
  return type(value) == 'cdata' and ffi.typeof(value) == arrayCType
end

local function is_span(value)
  return type(value) == 'cdata' and ffi.typeof(value) == spanCType
end

local function is_view(value)
  return is_array(value) or is_span(value)
end

local function pointer(container)
  return ffi.cast(get_info(container).pointer, container.data)
end

local function checked_range(container, first, count)
  local length = tonumber(container.length)
  first = first == nil and 1 or checked_integer(first, 'DataSpan first index', false)
  count = count == nil and length - first + 1 or checked_integer(count, 'DataSpan count', true)
  assert(first <= length + (count == 0 and 1 or 0), 'DataSpan first index is out of bounds')
  assert(count <= length - first + 1, 'DataSpan range is out of bounds')
  return first, count
end

local function make_span(owner, info, bytePointer, count)
  local size = count * info.size
  local result = spanCType(SPAN_MAGIC, count, info.size, size, info.id, 0, bytePointer)

  -- LuaJIT's cdata finalizer retains this closure, and the closure retains the
  -- source allocation.  The finalizer itself has no cleanup work to perform.
  local anchor = owner
  return ffi.gc(result, function()
    anchor = nil
  end)
end

local function view_span(container, first, count)
  first, count = checked_range(container, first, count)
  local info = get_info(container)
  local bytes = ffi.cast('uint8_t*', container.data) + (first - 1) * info.size
  return make_span(container, info, bytes, count)
end

local function view_index(container, key, methods, label)
  if type(key) == 'number' then
    local index = floor(key)
    if index == key and index >= 1 and index <= tonumber(container.length) then
      return pointer(container)[index - 1]
    end
    error(label .. ' index is out of bounds', 2)
  end

  local method = methods[key]
  if method ~= nil then return method end
  error(('attempt to index field %s of %s'):format(tostring(key), label), 2)
end

local function view_newindex(container, key, value, label)
  if type(key) == 'number' then
    local index = floor(key)
    if index == key and index >= 1 and index <= tonumber(container.length) then
      pointer(container)[index - 1] = value
      return
    end
    error(label .. ' index is out of bounds', 2)
  end
  error(('attempt to assign field %s of %s'):format(tostring(key), label), 2)
end

local function view_fill(container, value, first, count)
  first, count = checked_range(container, first, count)
  local elements = pointer(container)
  for i = first - 1, first + count - 2 do
    elements[i] = value
  end
  return container
end

local function view_clear(container, first, count)
  first, count = checked_range(container, first, count)
  local stride = tonumber(container.stride)
  ffi.fill(ffi.cast('uint8_t*', container.data) + (first - 1) * stride, count * stride)
  return container
end

local function view_copy(destination, source, destinationFirst, sourceFirst, count)
  assert(is_view(source), 'DataArray copy source must be a DataArray or DataSpan')
  local destinationInfo = get_info(destination)
  local sourceInfo = get_info(source)
  assert(destinationInfo.ctype == sourceInfo.ctype, 'DataArray copy element types must match')

  destinationFirst = destinationFirst == nil and 1 or checked_integer(destinationFirst, 'destination index', false)
  sourceFirst = sourceFirst == nil and 1 or checked_integer(sourceFirst, 'source index', false)
  local available = math.min(
    tonumber(destination.length) - destinationFirst + 1,
    tonumber(source.length) - sourceFirst + 1
  )
  count = count == nil and available or checked_integer(count, 'copy count', true)
  assert(destinationFirst <= tonumber(destination.length) + (count == 0 and 1 or 0), 'destination index is out of bounds')
  assert(sourceFirst <= tonumber(source.length) + (count == 0 and 1 or 0), 'source index is out of bounds')
  assert(count <= available, 'DataArray copy range is out of bounds')

  local bytes = count * destinationInfo.size
  local destinationData = ffi.cast('uint8_t*', destination.data) + (destinationFirst - 1) * destinationInfo.size
  local sourceData = ffi.cast('uint8_t*', source.data) + (sourceFirst - 1) * sourceInfo.size

  if bytes > 0 then
    -- ffi.copy is memcpy, so preserve overlap semantics explicitly.
    if destinationData > sourceData and destinationData < sourceData + bytes then
      for i = bytes - 1, 0, -1 do
        destinationData[i] = sourceData[i]
      end
    elseif sourceData > destinationData and sourceData < destinationData + bytes then
      for i = 0, bytes - 1 do
        destinationData[i] = sourceData[i]
      end
    else
      ffi.copy(destinationData, sourceData, bytes)
    end
  end
  return destination
end

function arrayMethods.type()
  return 'DataArray'
end

function arrayMethods.getCount(array)
  return tonumber(array.length)
end

function arrayMethods.getStride(array)
  return tonumber(array.stride)
end

function arrayMethods.getSize(array)
  return tonumber(array.size)
end

function arrayMethods.getElementType(array)
  return get_info(array).ctype
end

function arrayMethods.getPointer(array)
  return pointer(array)
end

arrayMethods.span = view_span
arrayMethods.fill = view_fill
arrayMethods.clear = view_clear
arrayMethods.copy = view_copy

function spanMethods.type()
  return 'DataSpan'
end

spanMethods.getCount = arrayMethods.getCount
spanMethods.getStride = arrayMethods.getStride
spanMethods.getSize = arrayMethods.getSize
spanMethods.getElementType = arrayMethods.getElementType
spanMethods.getPointer = arrayMethods.getPointer
spanMethods.span = view_span
spanMethods.fill = view_fill
spanMethods.clear = view_clear
spanMethods.copy = view_copy

arrayCType = ffi.metatype('lovr_data_array', {
  __index = function(array, key)
    return view_index(array, key, arrayMethods, 'DataArray')
  end,
  __newindex = function(array, key, value)
    return view_newindex(array, key, value, 'DataArray')
  end,
  __len = function(array)
    return tonumber(array.length)
  end,
  __tostring = function(array)
    return ('DataArray<%s>[%d]'):format(get_info(array).name, tonumber(array.length))
  end
})

spanCType = ffi.metatype('lovr_data_span', {
  __index = function(span, key)
    return view_index(span, key, spanMethods, 'DataSpan')
  end,
  __newindex = function(span, key, value)
    return view_newindex(span, key, value, 'DataSpan')
  end,
  __len = function(span)
    return tonumber(span.length)
  end,
  __tostring = function(span)
    return ('DataSpan<%s>[%d]'):format(get_info(span).name, tonumber(span.length))
  end
})

local Array = { ctype = arrayCType }

setmetatable(Array, {
  __call = function(_, elementType, count, initial)
    local info = resolve_element_type(elementType)
    count = checked_integer(count, 'DataArray length', true)
    assert(count <= floor(UINT32_MAX / info.size), 'DataArray byte size exceeds 4GiB')

    local size = count * info.size
    local storage = floor((size + ALIGNMENT - 1) / ALIGNMENT) * ALIGNMENT
    local array = arrayCType(storage, ARRAY_MAGIC, count, info.size, size, info.id)

    if is_view(initial) then
      array:copy(initial, 1, 1, math.min(count, tonumber(initial.length)))
    elseif type(initial) == 'table' then
      local elements = pointer(array)
      for i = 1, math.min(count, #initial) do
        elements[i - 1] = initial[i]
      end
    elseif initial ~= nil then
      array:fill(initial)
    end

    return array
  end
})

local Span = { ctype = spanCType }

function data.newSpan(source, elementType, count, first)
  if is_view(source) then
    return source:span(elementType, count)
  end

  assert(type(source) == 'cdata', 'DataSpan source must be an owning FFI array')
  local sourceType = tostring(ffi.typeof(source))
  assert(sourceType:find('%['), 'DataSpan source must be an owning FFI array, not a pointer')

  local info = resolve_element_type(elementType)
  local sourceSize = ffi.sizeof(source)
  assert(sourceSize % info.size == 0, 'DataSpan source size is not a multiple of the element stride')

  local available = sourceSize / info.size
  first = first == nil and 1 or checked_integer(first, 'DataSpan first index', false)
  count = count == nil and available - first + 1 or checked_integer(count, 'DataSpan count', true)
  assert(first <= available + (count == 0 and 1 or 0), 'DataSpan first index is out of bounds')
  assert(count <= available - first + 1, 'DataSpan range is out of bounds')

  local bytes = ffi.cast('uint8_t*', source) + (first - 1) * info.size
  local address = tonumber(ffi.cast('uintptr_t', bytes))
  assert(address % info.alignment == 0, 'DataSpan source pointer is not correctly aligned')
  return make_span(source, info, bytes, count)
end

function data.newArray(elementType, count, initial)
  return Array(elementType, count, initial)
end

function data.isArray(value)
  return is_array(value)
end

function data.isSpan(value)
  return is_span(value)
end

data.Array = Array
data.Span = Span

return arrayCType, spanCType
